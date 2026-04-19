#include "hlsl_constant_mapping.fx"
#include "utilities.fx"

#define ENVMAP_TYPE(env_map_type) ENVMAP_TYPE_##env_map_type
#define ENVMAP_TYPE_none 0
#define ENVMAP_TYPE_per_pixel 1
#define ENVMAP_TYPE_dynamic 2
#define ENVMAP_TYPE_from_flat_texture 3
#define ENVMAP_TYPE_from_flat_texture_as_cubemap 4

#define CALC_ENVMAP(env_map_type) calc_environment_map_##env_map_type##_ps



PARAM(float3, env_tint_color);
//PARAM(float3, env_glancing_tint_color);
PARAM(float, env_bias);								// ###ctchou $TODO replace this - use roughness instead

PARAM(float3, env_topcoat_color);
PARAM(float, env_topcoat_bias);
PARAM(float, env_roughness_scale);

// halo3-ng SSR injection — ResourceSSRFinal bound to t19 by ShaderRegexBindSSR at runtime.
// g_ssr_screen_uv set by entry_points.fx (and glass.fx) immediately before CALC_ENVMAP() call.
#ifdef ENABLE_SSR
static float2 g_ssr_screen_uv = float2(0.0f, 0.0f);
Texture2D<float4> ssr_buffer : register(t19);

// Returns ResourceSSRFinal sample: .rgb = HDR reflected scene color (pre-multiplied by g_exposure),
// .a = blend confidence [0..1] (0 = no hit / full miss, 1 = reliable hit).
float4 get_ssr(float2 screen_uv, float3 normal)
{
    return ssr_buffer.Load(int3(int2(screen_uv * float2(1920.0f, 1080.0f)), 0));
}

// Physically-based SSR blend — replaces or augments the cubemap reflection.
//
// Why this approach vs the old lerp:
//   Old: lerp(env_color, ssr_raw * spec * low_freq_light * tint, confidence)
//        low_freq_light is a baked SH lighting term used to bring static cubemaps into
//        the current lighting environment. SSR samples the LIVE HDR scene — already lit.
//        Multiplying by low_freq_light double-attenuates SSR in shadowed/interior areas.
//        env_tint_color is an artist cubemap tweak with no meaning for real reflected radiance.
//
//   New: lerp(env_color, ssr_raw * spec, fresnel_weighted_confidence)
//        - Only F0 tint (spec.xyz) — physically correct spectral tint of the reflection
//        - Schlick Fresnel multiplies confidence: no boost when no hit (ibr.a=0), maximum
//          boost at grazing angles where surfaces are physically most reflective
//        - ssr_strength: per-variant scalar to compensate for HDR cubemap scale differences
//          (dynamic/custom_map decode via alpha*256; per_pixel/flat use linear alpha ~1)
float3 apply_ssr_blend(
    float3  env_color,
    float3  view_dir,
    float3  normal,
    float4  specular_reflectance_and_roughness,
    float4  ibr,
    float   ssr_strength)
{
    float3 ssr_raw    = ibr.rgb / max(g_exposure.r, 1e-4f);
    float  F0         = dot(specular_reflectance_and_roughness.xyz, float3(0.2126f, 0.7152f, 0.0722f));
    float  ndotv      = saturate(abs(dot(view_dir, normal)));
    float  fresnel    = F0 + (1.0f - F0) * pow(1.0f - ndotv, 5.0f);
    // Scale confidence by Fresnel: moderate boost at grazing angles.
    // Old factor 2.0 tripled confidence at grazing → blew out noisy single-ray SSR.
    // 0.5 gives 50% boost at max Fresnel — enough for physically-correct emphasis
    // without amplifying noise from unconverged temporal accumulation.
    float  blendWeight = saturate(ibr.a * (1.0f + fresnel * 0.5f));
    // halo3-ng: soft-knee luminance compression on the FINAL tinted SSR.
    //   - Below knee (1.5): pass-through. NO loss of SSR brightness for normal
    //     reflections — same response as raw HDR. Hard caps reduced contribution
    //     at the cap boundary; this preserves the curve up to the knee and
    //     only asymptotically rolls off above it.
    //   - Above knee: softLum = knee + excess / (1 + excess/headroom)
    //     headroom = ceiling - knee. With knee=1.5, ceiling=3.0:
    //       lum=2.0 → 1.875,   lum=3.0 → 2.25,   lum=10 → 2.775,   lum=∞ → 3.0
    //   Single combined cap (replaces the prior pre/post double-cap) — multiplies
    //   are applied first, then a single soft-knee bounds the visible result.
    float3 ssr_tinted = ssr_raw * specular_reflectance_and_roughness.xyz * ssr_strength;
    float  ssrLum     = dot(ssr_tinted, float3(0.2126f, 0.7152f, 0.0722f));
    if (ssrLum > 1.5f)
    {
        float excess     = ssrLum - 1.5f;
        float headroom   = 1.5f;                            // ceiling 3.0 - knee 1.5
        float compressed = excess / (1.0f + excess / headroom);
        float softLum    = 1.5f + compressed;
        ssr_tinted *= softLum / max(ssrLum, 1e-4f);
    }
    return lerp(env_color, ssr_tinted, blendWeight);
}
#endif

#if ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_none
float3 calc_environment_map_none_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir,
	in float4 specular_reflectance_and_roughness,
	in float3 low_frequency_specular_color)
{
	return float3(0.0f, 0.0f, 0.0f);
}
#endif // ENVMAP_TYPE_none

#if ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_per_pixel
#if DX_VERSION == 9
samplerCUBE environment_map : register(s1);		// test
#elif DX_VERSION == 11
PARAM_SAMPLER_CUBE(environment_map);
#endif
float3 calc_environment_map_per_pixel_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir,
	in float4 specular_reflectance_and_roughness,
	in float3 low_frequency_specular_color)
{
	reflect_dir.y= -reflect_dir.y;
	
	float4 reflection;
#ifdef pc	
	reflection= sampleCUBE(environment_map, reflect_dir);
#else
	reflection= sampleCUBElod(environment_map, reflect_dir, 0.0f);
#endif
	float3 env_color_pp = reflection.rgb * specular_reflectance_and_roughness.xyz * low_frequency_specular_color * env_tint_color * reflection.a;
#ifdef USE_SSR
	env_color_pp = apply_ssr_blend(env_color_pp, view_dir, normal, specular_reflectance_and_roughness, get_ssr(g_ssr_screen_uv, normal), 1.0f);
#endif
	return env_color_pp;
}
#endif // ENVMAP_TYPE_per_pixel

#if ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_dynamic

#ifndef pc
	samplerCUBE dynamic_environment_map_0 : register(s1);		// declared by shaders\shader_options\env_map_dynamic.render_method_option
	samplerCUBE dynamic_environment_map_1 : register(s2);		// declared by shaders\shader_options\env_map_dynamic.render_method_option
#elif DX_VERSION == 11
	PARAM_SAMPLER_CUBE(dynamic_environment_map_0);		// declared by shaders\shader_options\env_map_dynamic.render_method_option
	PARAM_SAMPLER_CUBE(dynamic_environment_map_1);		// declared by shaders\shader_options\env_map_dynamic.render_method_option
#else
	LOCAL_SAMPLER_CUBE(dynamic_environment_map_0, 1);		// declared by shaders\shader_options\env_map_dynamic.render_method_option
	LOCAL_SAMPLER_CUBE(dynamic_environment_map_1, 2);		// declared by shaders\shader_options\env_map_dynamic.render_method_option
#endif 

float3 calc_environment_map_dynamic_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir,
	in float4 specular_reflectance_and_roughness,
	in float3 low_frequency_specular_color)
{
	reflect_dir.y= -reflect_dir.y;
	
	float4 reflection_0, reflection_1;
	
#ifdef pc
	float grad_x= length(ddx(reflect_dir));
	float grad_y= length(ddy(reflect_dir));
	float base_lod= 6.0f * sqrt(max(grad_x, grad_y)) - 0.6f;
	float lod= max(base_lod, specular_reflectance_and_roughness.w * env_roughness_scale * 4);
	
	reflection_0= sampleCUBElod(dynamic_environment_map_0, reflect_dir, lod);
	reflection_1= sampleCUBElod(dynamic_environment_map_1, reflect_dir, lod);
	
#else	// xenon
	float grad_x= 0.0f;
	float grad_y= 0.0f;
	float base_lod= 0.0f;
	float lod= max(base_lod, specular_reflectance_and_roughness.w * env_roughness_scale * 4);
	
	reflection_0= sampleCUBElod(dynamic_environment_map_0, reflect_dir, lod);
	reflection_1= sampleCUBElod(dynamic_environment_map_1, reflect_dir, lod);
#endif

	float3 reflection=  (reflection_0.rgb * reflection_0.a * 256) * dynamic_environment_blend.rgb + 
						(reflection_1.rgb * reflection_1.a * 256) * (1.0f-dynamic_environment_blend.rgb);
	float3 env_color_dyn = reflection * specular_reflectance_and_roughness.xyz * env_tint_color * low_frequency_specular_color;
#ifdef USE_SSR
	env_color_dyn = apply_ssr_blend(env_color_dyn, view_dir, normal, specular_reflectance_and_roughness, get_ssr(g_ssr_screen_uv, normal), 2.0f);
#endif
	return env_color_dyn;
//	return float3(lod, lod, lod) / 6.0f;
}
#endif // ENVMAP_TYPE_dynamic

/*
float3 calc_environment_map_dynamic_two_coat_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir,
	in float4 specular_reflectance_and_roughness,
	in float3 low_frequency_specular_color)
{
	reflect_dir.y= -reflect_dir.y;
	
	float4 reflection_0= texCUBEbias(dynamic_environment_map_0, float4(reflect_dir, specular_reflectance_and_roughness.w + env_bias)); 
	float4 reflection_1= texCUBEbias(dynamic_environment_map_1, float4(reflect_dir, specular_reflectance_and_roughness.w + env_bias)); 
	
	float3 reflection=  (reflection_0.rgb * reflection_0.a * 255) * dynamic_environment_blend + 
						(reflection_1.rgb * reflection_1.a * 255) * (1.0f-dynamic_environment_blend);

	float4 topcoat_0= texCUBEbias(dynamic_environment_map_0, float4(reflect_dir, env_topcoat_bias)); 
	float4 topcoat_1= texCUBEbias(dynamic_environment_map_1, float4(reflect_dir, env_topcoat_bias)); 
	
	float3 topcoat= (topcoat_0.rgb * topcoat_0.a * 255) * dynamic_environment_blend + 
					(topcoat_1.rgb * topcoat_1.a * 255) * (1.0f-dynamic_environment_blend);
	
	return ((reflection * specular_reflectance_and_roughness.xyz * env_tint_color) + (topcoat * env_topcoat_color)) * low_frequency_specular_color;
}
*/

#if (ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_from_flat_texture) || (ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_from_flat_texture_as_cubemap)

#if ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_from_flat_texture_as_cubemap
PARAM_SAMPLER_CUBE(flat_environment_map);
#else
PARAM_SAMPLER_2D(flat_environment_map);
#endif
PARAM(float4, flat_envmap_matrix_x);		// envmap rotation matrix, dot xyz with world direction returns envmap.X					w component ignored
PARAM(float4, flat_envmap_matrix_y);		// envmap rotation matrix, dot xyz with world direction returns envmap.Y					w component ignored
PARAM(float4, flat_envmap_matrix_z);		// envmap rotation matrix, dot xyz with world direction returns envmap.Z (-1 = forward)		w component ignored
PARAM(float, hemisphere_percentage);

// ###ctchou $HACK $E3 bloom override
PARAM(float4, env_bloom_override);		// input		[R, G, B tint, alpha = percentage]
PARAM(float, env_bloom_override_intensity);		// input
PARAM(float3, env_bloom_override_output);				// output
#define BLOOM_OVERRIDE env_bloom_override_output


float3 calc_environment_map_from_flat_texture_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir,								// normalized
	in float4 specular_reflectance_and_roughness,
	in float3 low_frequency_specular_color)
{
	float3 reflection= float3(1.0f, 0.0f, 0.0f);

	// fisheye projection	
	float3 envmap_dir;
	envmap_dir.x= dot(reflect_dir, flat_envmap_matrix_x.xyz);
	envmap_dir.y= dot(reflect_dir, flat_envmap_matrix_y.xyz);
	envmap_dir.z= dot(reflect_dir, flat_envmap_matrix_z.xyz);
	
	float radius= sqrt((envmap_dir.z+1.0f)/hemisphere_percentage);							// 1.0 = radius of texture (along X/Y axis)
																							// ###ctchou $PERF we could put the (+1.0f)/hemisphere percentage into the dot product with Z by modifying flat_envmap_matrix_z - but would require combining shader parameters
	
	float2 texcoord= envmap_dir.xy * radius / sqrt(dot(envmap_dir.xy, envmap_dir.xy));		// normalize x/y vector, and scale by radius to get fisheye projection
	texcoord= (1.0f+texcoord)*0.5f;															// convert to texture coordinate space (0..1)

#if ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_from_flat_texture_as_cubemap
	float3 cube_texcoord = float3(
		1.0f,
		-((texcoord.y * 2.0f) - 1.0f),
		-((texcoord.x * 2.0f) - 1.0f));
	reflection = sampleCUBE(flat_environment_map, cube_texcoord);
#else
	reflection= sample2D(flat_environment_map, texcoord);
#endif
	
	// ###ctchou $HACK $E3 bloom override
#if (! defined(pc)) || (DX_VERSION == 11)
	BLOOM_OVERRIDE= max(color_to_intensity(reflection.rgb)-env_bloom_override.a, 0.0f) * env_bloom_override.rgb * env_bloom_override_intensity * g_exposure.rrr;
#endif
/*	// perspective projection
	float3 texcoord;
	texcoord.z= dot(reflect_dir, flat_envmap_matrix_w.xyz);					// ###ctchou $TODO $PERF pass the transformed point from the vertex shader
	if (texcoord.z < -0.001f)
	{
		texcoord.x= dot(reflect_dir, flat_envmap_matrix_x.xyz);
		texcoord.y= dot(reflect_dir, flat_envmap_matrix_y.xyz);
		reflection= sample2D(flat_environment_map, texcoord.xy / texcoord.z);
	}
*/
	float3 env_color_flat = reflection * specular_reflectance_and_roughness.xyz * env_tint_color;
#ifdef USE_SSR
	env_color_flat = apply_ssr_blend(env_color_flat, view_dir, normal, specular_reflectance_and_roughness, get_ssr(g_ssr_screen_uv, normal), 1.0f);
#endif
	return env_color_flat;
}

float3 calc_environment_map_from_flat_texture_as_cubemap_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir,								// normalized
	in float4 specular_reflectance_and_roughness,
	in float3 low_frequency_specular_color)
{
	return calc_environment_map_from_flat_texture_ps(
		view_dir,
		normal,
		reflect_dir,
		specular_reflectance_and_roughness,
		low_frequency_specular_color);
}

#endif // ENVMAP_TYPE_from_flat_texture

#if ENVMAP_TYPE(envmap_type) == ENVMAP_TYPE_custom_map
PARAM_SAMPLER_CUBE(environment_map);

float calc_cubemap_lod(in float3 reflect_dir, in float roughness)
{
	float3 gradX = ddx(reflect_dir);
	float3 gradY = ddy(reflect_dir);
	float grad_x = dot(gradX, gradX);
	float grad_y = dot(gradY, gradY);
	float base_lod = 6.0f * sqrt(sqrt(max(grad_x, grad_y))) - 0.6f; // May be strange calculation?
	return max(base_lod, roughness * env_roughness_scale * 4);
}

float3 calc_environment_map_custom_map_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir,
	in float4 specular_reflectance_and_roughness,
	in float3 low_frequency_specular_color)
{
	reflect_dir.y = -reflect_dir.y;

	float lod = calc_cubemap_lod(reflect_dir, specular_reflectance_and_roughness.w);

	float4 reflection = sampleCUBElod(environment_map, reflect_dir, lod);

	reflection.rgb *= reflection.a * 256.0f;

	float3 env_color_cm = reflection.rgb * specular_reflectance_and_roughness.xyz * low_frequency_specular_color * env_tint_color;
#ifdef USE_SSR
	env_color_cm = apply_ssr_blend(env_color_cm, view_dir, normal, specular_reflectance_and_roughness, get_ssr(g_ssr_screen_uv, normal), 2.0f);
#endif
	return env_color_cm;
}
float3 sample_environment_map_custom_map_ps(in float3 reflect_dir)
{
	reflect_dir.y = -reflect_dir.y;

	float4 reflection;
#ifdef pc

	float grad_x = length(ddx(reflect_dir));
	float grad_y = length(ddy(reflect_dir));
	float base_lod = 6.0f * sqrt(max(grad_x, grad_y)) - 0.6f;

	reflection = sampleCUBElod(environment_map, reflect_dir, base_lod);
#else
	reflection = sampleCUBElod(environment_map, reflect_dir, 0.0f);
#endif

	return reflection.rgb;
}
#endif // ENVMAP_TYPE_custom_map