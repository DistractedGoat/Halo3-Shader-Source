#line 2 "source\rasterizer\hlsl\final_composite_base.hlsl"

#include "global.fx"
#include "hlsl_vertex_types.fx"
#include "postprocess.fx"
#include "utilities.fx"
#include "texture_xform.fx"
#include "final_composite_registers.fx"
// Temporarily disable MV texture declaration — conflicts with bloom_sampler at t2
#ifdef ENABLE_MOTION_VECTORS
#undef ENABLE_MOTION_VECTORS
#include "hlsl_constant_persist.fx"
#define ENABLE_MOTION_VECTORS 1
#else
#include "hlsl_constant_persist.fx"
#endif


LOCAL_SAMPLER_2D_IN_VIEWPORT_MAYBE(surface_sampler, 0);
LOCAL_SAMPLER_2D_IN_VIEWPORT_MAYBE(dark_surface_sampler, 1);
LOCAL_SAMPLER_2D_IN_VIEWPORT_MAYBE(bloom_sampler, 2);
LOCAL_SAMPLER_2D_IN_VIEWPORT_MAYBE(depth_sampler, 3);		// depth of field
LOCAL_SAMPLER_2D_IN_VIEWPORT_MAYBE(blur_sampler, 4);		// depth of field
LOCAL_SAMPLER_2D_IN_VIEWPORT_MAYBE(blur_grade_sampler, 5);		// weapon zoom

LOCAL_SAMPLER_3D(color_grading0, 6);
LOCAL_SAMPLER_3D(color_grading1, 7);

// AO buffer (bound by 3DMigoto at runtime, safe fallback if unbound)
LOCAL_SAMPLER_2D(ao_buffer, 10);

// Motion vector buffer — .ba channels = SH chromaticity tint (rg channels unused after Layer 2 removal)
LOCAL_SAMPLER_2D(mv_buffer, 12);


// SSGI GI color buffer (bound by 3DMigoto at ps-t15 when y==1 / F12 toggle)
// float4(.rgb=GI indirect color, .a=viewZ) from dedicated 15m-radius SSGI pass
LOCAL_SAMPLER_2D(ssgi_buffer, 15);

// Depth snapshot debug (bound by 3DMigoto at ps-t14 when z==1 / F6 toggle)
// R32_FLOAT reverse-Z depth; 0=sky/unbound. Unbound → all zeros → no-op.
Texture2D<float> depth_snapshot_debug : register(t14);

// SSR removed from final_composite — now injected per-surface (water_shading.fx etc.)

// define default functions, if they haven't been already

#ifndef COMBINE_HDR_LDR
#define COMBINE_HDR_LDR default_combine_optimized
#endif // !COMBINE_HDR_LDR

#ifndef CALC_BLOOM
#define CALC_BLOOM default_calc_bloom
#endif // !CALC_BLOOM

#ifndef CALC_BLEND
#define CALC_BLEND default_calc_blend
#endif // !CALC_BLEND



float4 default_combine_hdr_ldr(in float2 texcoord)							// supports multiple sources and formats, but much slower than the optimized version
{
#ifdef pc
	float4 accum=		sample2D(surface_sampler, texcoord);
	float4 accum_dark=	sample2D(dark_surface_sampler, texcoord) * DARK_COLOR_MULTIPLIER;
	float4 combined = accum_dark * step(accum_dark, (1).rrrr);
	combined = max(accum, combined);
#else // XENON
	
	float4 accum=		sample2D(surface_sampler, texcoord);
	if (LDR_gamma2)
	{
		accum.rgb *= accum.rgb;
	}

	float4 accum_dark=	sample2D(dark_surface_sampler, texcoord);
	if (HDR_gamma2)
	{
		accum_dark.rgb *= accum_dark.rgb;
	}
	accum_dark *= DARK_COLOR_MULTIPLIER;
	
/*	float4 combined= accum_dark - 1.0f;
	asm																		// combined = ( combined > 0.0f ) ? accum_dark : accum
	{
		cndgt combined, combined, accum_dark, accum
	};
*/
	float4 combined= max(accum, accum_dark);
#endif // XENON

	return combined;
}


float4 default_combine_optimized(in float2 texcoord)						// final game code: single sample LDR surface, use hardcoded hardware curve
{
	return sample2D(surface_sampler, texcoord);
}


float4 default_calc_bloom(in float2 texcoord)
{
	return tex2D_offset(bloom_sampler, transform_texcoord(texcoord, bloom_sampler_xform), 0, 0);
}


float3 default_calc_blend(in float2 texcoord, in float4 combined, in float4 bloom)
{
#ifdef pc
	return combined + bloom;
#else // XENON
	return combined * bloom.a + bloom.rgb;
#endif // XENON
}


float4 default_ps(SCREEN_POSITION_INPUT(screen_position), in float2 texcoord :TEXCOORD0) : SV_Target
{
	// final composite
	float4 combined= COMBINE_HDR_LDR(texcoord);									// sample and blend full resolution render targets

	// === AO — current-frame, no reprojection needed (compute runs pre-draw, zero lag) ===
	// ao_buffer carries float4(ao, ao, ao, viewZ) from GTAO pass.
	// .a = viewZ: real-surface flag (0 for sky/water) + fog distance.
	float4 ao_sample = sample2D(ao_buffer, texcoord);
	float ao = (ao_sample.a > 0.001f) ? saturate(ao_sample.r) : 1.0f;	// sky/water/unbound → ao=1.0

	float ao_viewZ = ao_sample.a;  // viewZ from GTAO output; 0 for sky/water (same sentinel)
	if (ao_viewZ > 0.001f && ao < 1.0f)
	{
		float z_view = ao_viewZ;
		float dist = min(max(z_view + v_atmosphere_constant_0.w, 0.0f), v_atmosphere_constant_1.w);
		float3 extinction = exp2(-(v_atmosphere_constant_2.xyz + v_atmosphere_constant_3.xyz) * dist);
		float fog = 1.0f - dot(extinction, float3(0.333f, 0.333f, 0.333f));
		// ao_fog_scale: higher = AO fades sooner (2.0=default, try 4-8 for heavier fog scenes)
		float ao_fog_scale = 7.0f;
		ao = lerp(ao, 1.0f, saturate(fog * ao_fog_scale));
	}

	// SH chromaticity tinted AO — ambient color from lightmap L0 DC
	float2 sh_chroma_rg = sample2D(mv_buffer, texcoord).ba;
	float3 ao_tint = float3(sh_chroma_rg.x, sh_chroma_rg.y, 1.0 - sh_chroma_rg.x - sh_chroma_rg.y);
	ao_tint = ao_tint / max(dot(ao_tint, float3(1, 1, 1)), 0.001);

	// Tuning: 0=monochrome AO, 1=full chromaticity tint
	float ao_color_saturation = 0.5;
	ao_tint = lerp(float3(0.333, 0.333, 0.333), ao_tint, ao_color_saturation);
	ao_tint = ao_tint / max(dot(ao_tint, float3(1, 1, 1)), 0.001);

	// === SSGI indirect diffuse — current-frame, no reprojection needed ===
	// Added BEFORE AO multiply so AO applies uniformly to direct+indirect — preserves AO contrast.
	{
		// ssgi_buffer = dedicated 15m-radius GI pass, float4(.rgb=GI, .a=viewZ)
		float4 gi_reproj = sample2D(ssgi_buffer, texcoord);
		float3 gi_color = gi_reproj.rgb;

		// Strength scalar applied first, before any fading
		float ssgi_strength = 7.5f;   // indirect brightness scalar
		gi_color *= ssgi_strength;

		// viewZ from SSGI buffer .a — used only for fog fade distance.
		// NOTE: do NOT gate the GI add on this value. True sky pixels are safe regardless
		// because the SSGI trace writes gi_color=(0,0,0) for sky, making the add a no-op.
		float z_view_gi = gi_reproj.a;

		// Atmospheric fade — only meaningful for scene pixels (z_view_gi > 0)
		if (z_view_gi > 0.001f)
		{
			float dist_gi = min(max(z_view_gi + v_atmosphere_constant_0.w, 0.0f), v_atmosphere_constant_1.w);
			float3 extinction_gi = exp2(-(v_atmosphere_constant_2.xyz + v_atmosphere_constant_3.xyz) * dist_gi);
			float fog_gi = 1.0f - dot(extinction_gi, float3(0.333f, 0.333f, 0.333f));
			float ssgi_fog_scale = 7.0f;
			gi_color *= saturate(1.0f - fog_gi * ssgi_fog_scale);
		}

		// Two-factor receiver: low-freq level from lit scene + high-freq detail from albedo.
		// receiverWeight: shadows suppress GI (uses actual lit luminance, not raw albedo).
		// albedoDetail: preserves local texture variation (albedo normalized to its own luminance).
		//   Soft normalization: albedo / (albedoLum + 0.1) keeps near-black from exploding.
		//   Clamped to [0.3..2.0]: no texel contributes more than 2x or less than 0.3x average.
		float ssgi_receiver_power = 1.3f;  // <1=compressed (sqrt-like), 1=linear, >1=strong hotspot
		float ssgi_receiver_floor = 0.09f;  // minimum GI contribution on fully dark surfaces (0=none)
		float ssgi_detail_blend  = 0.66f;   // 0=no texture detail, 1=full albedo detail modulation
		float receiverLum = dot(combined.rgb, float3(0.2126f, 0.7152f, 0.0722f));
		float receiverWeight = lerp(ssgi_receiver_floor, 1.0f, pow(saturate(receiverLum * 4.0f), ssgi_receiver_power));
		// albedo_texture (t16) persists from shadow_apply as a stale SRV — same mechanism as
		// normal_texture at t17. No 3DMigoto injection needed.
		float3 albedo_gi = albedo_texture.Load(int3(int2(texcoord * float2(1920.0f, 1080.0f)), 0)).rgb;
		float albedoLum_gi = dot(albedo_gi, float3(0.2126f, 0.7152f, 0.0722f));
		float3 albedoDetail = clamp(albedo_gi / (albedoLum_gi + 0.1f), 0.3f, 2.0f);
		float3 giReceiver = receiverWeight * lerp(float3(1.0f, 1.0f, 1.0f), albedoDetail, ssgi_detail_blend);
		combined.rgb += gi_color * giReceiver;
	}
	// === end SSGI ===

	// AO applied AFTER SSGI — darkens direct+indirect uniformly so AO contrast is unaffected by SSGI.
	// ao=1 → white (no effect); ao<1 → tinted toward ambient color
	float ao_scene_power    = 2.0f;    // >1 darkens AO contrast (pow curve on ao value)
	float ao_scene_strength = 1.0f;    // 0=no AO darkening, 1=full scene darkening
	float ao_dark_floor     = 0.01f;    // 0=fully black at max occlusion, 0.333=original tint floor, tune between
	float ao_darkened = pow(ao, ao_scene_power);
	float3 ao_color = lerp(ao_tint * ao_dark_floor, float3(1, 1, 1), ao_darkened);
	combined.rgb *= lerp(float3(1, 1, 1), ao_color, ao_scene_strength);
	// === end AO ===

	// SSR now injected per-surface (water_shading.fx), not here

	float4 bloom= CALC_BLOOM(texcoord);											// sample postprocessed buffer(s)
	float3 blend= CALC_BLEND(texcoord, combined, bloom);						// blend them together

	// apply hue and saturation (3 instructions)
	blend= mul(float4(blend, 1.0f), ps_postprocess_hue_saturation_matrix);

	// apply contrast (4 instructions)
	float luminance= dot(blend, float3(0.333f, 0.333f, 0.333f));
#if DX_VERSION == 11
	if (luminance > 0)
#endif
	{
		blend *= pow(luminance, ps_postprocess_contrast.x) / luminance;
	}

	// apply tone curve (4 instructions)
	float3 clamped  = min(blend, tone_curve_constants.xxx);		// default= 1.4938015821857215695824940046795		// r1

	float4 result;
	result.rgb= ((clamped.rgb * tone_curve_constants.w + tone_curve_constants.z) * clamped.rgb + tone_curve_constants.y) * clamped.rgb;		// default linear = 1.0041494251232542828239889869599, quadratic= 0, cubic= - 0.15;

   // color grading
   const float rSize = 1.0f / 16.0f;
   const float3 scale = 1.0f - rSize;
   const float3 offset = 0.5f * rSize;
   float3 cgTexC = result.rgb * scale + offset;
   float3 cg0 = sample3D(color_grading0, cgTexC).rgb;
   float3 cg1 = sample3D(color_grading1, cgTexC).rgb;
   result.rgb = lerp(cg0, cg1, cg_blend_factor.x);

	// Saturation boost — compensates for SSGI indirect diffuse washing out colors slightly
	float sat_boost = 1.1f;  // 1.0=neutral, >1=more saturated, tune to taste
	float sat_luma = dot(result.rgb, float3(0.2126f, 0.7152f, 0.0722f));
	result.rgb = lerp(sat_luma.xxx, result.rgb, sat_boost);

	result.a= sqrt( dot(result.rgb, float3(0.299, 0.587, 0.114)) );


	// === Motion vector debug (disabled — t12 now always bound for AO reproject) ===
	// To re-enable: need a separate flag mechanism (t12 is no longer conditionally bound)
	// float2 mv = sample2D(mv_debug_buffer, texcoord).rg;
	// if (abs(mv.x) + abs(mv.y) > 0.0001f)
	// {
	// 	result.rgb = float3(
	// 		saturate(log2(abs(mv.x) * 50.0f + 1.0f) / 3.0f),
	// 		saturate(log2(abs(mv.y) * 50.0f + 1.0f) / 3.0f),
	// 		0.0f
	// 	);
	// 	result.a = 1.0f;
	// }

	// === Depth snapshot debug (F6 / z-toggle) ===
	// Bind ResourceDepthSnapshot to ps-t14 via d3dx.ini [KeyDebugDepthSnapshot] to activate.
	// When ps-t14 is unbound, depth_snapshot_debug.Load() returns 0 for all pixels → no-op.
	// When bound: geometry pixels show a log-remapped heat gradient (near=red, mid=green, far=blue).
	//             Sky/water pixels (rawDbg==0) pass through unchanged — they visually identify themselves.
	// Log range: near ~0.1m → t≈0, far ~100m → t≈1. Tweak log2(101.0) to change far scale.
	{
		float rawDbg = depth_snapshot_debug.Load(int3(int2(texcoord * float2(1920.0f, 1080.0f)), 0));
		if (rawDbg > 0.00001f)
		{
			float viewZ = 0.00781f / rawDbg;
			float t = saturate(log2(viewZ + 1.0f) / log2(101.0f));  // [~0m..100m] → [0..1]
			// heat: near=red(1,0,0), mid=green(0,1,0), far=blue(0,0,1)
			result.rgb = float3(
				saturate(1.0f - t * 2.0f),
				saturate(1.0f - abs(t - 0.5f) * 4.0f),
				saturate((t - 0.5f) * 2.0f)
			);
			result.a = 1.0f;
		}
	}

	return result;
}
