//#line 2 "source\rasterizer\hlsl\shadow_apply.hlsl"

// halo3-ng: shadow_apply is a darken pass — don't write motion vectors to SV_Target2
#define NO_MV_OUTPUT 1

#include "global.fx"
#include "hlsl_constant_mapping.fx"
#include "deform.fx"
#include "utilities.fx"
#include "atmosphere.fx"
#include "shadow_apply_registers.fx"

// halo3-ng (Aug 2026) — UNIFIED FILTER + BIAS ACROSS ALL FIVE APPLY VARIANTS.
//
// shadow_apply_{point,faster,bilinear,fancy}.hlsl each #define SAMPLE_PERCENTAGE_CLOSER *and*
// FASTER_SHADOWS BEFORE including this file, so the #ifndef guard that used to be here never
// fired for them, and the slope-scaled depth bias below (~line 270) was compiled out entirely.
//
// That matters more than it looks: RenderDoc analysis of the 10 captures in
// docs/research/renderdoc-captures/ shows MCC runs THREE DISTINCT apply pixel shaders in a
// single frame (in 4 of the 10) — i.e. filter quality and depth bias were changing from object
// to object inside one image. Force one policy for all of them.
//
// The variants still declare + define their own kernel functions around the #include; those
// simply become unreferenced now. They are defined AFTER this header and reference
// g_shadow_pixel_size (declared ~line 110), so they still compile.
#ifdef SAMPLE_PERCENTAGE_CLOSER
#undef SAMPLE_PERCENTAGE_CLOSER
#endif
#define SAMPLE_PERCENTAGE_CLOSER sample_percentage_closer_PCF_5x5_block

// Restore the slope-scaled depth bias for every variant. Scalable at runtime via
// $shadow_bias_scale so the peter-panning risk this reintroduces can be A/B'd on F10 without a
// rebuild (set it to 0.001 to get the old FASTER_SHADOWS "no bias" behaviour back).
#ifdef FASTER_SHADOWS
#undef FASTER_SHADOWS
#endif

// halo3-ng — runtime tuning knobs via 3DMigoto IniParams (t120), ROW 8.
// Row 8 already exists ($tonemap_toe on .x), so these reuse free channels of a LIVE texel and
// dodge the documented trap that a BRAND-NEW IniParams index does not reach the shader on a live
// F10 (the texture only resizes in CreateIniParamResources on reload).
//   .x = $tonemap_toe         final_composite_base.hlsl — not read here
//   .y = $shadow_fade_start   volume-depth at which the distance fade begins   (default 0.80)
//   .z = $shadow_debug        0 = off, 1 = per-variant tint, 2 = shadow_alpha  (default 0)
//   .w = $shadow_bias_scale   multiplier on the slope-scaled depth bias        (default 1.0)
// ROW 8 AND NOT ROW 7: row 7's .y is $ssr_reproj_off (Aug 2026, concurrent SSR/dynamic-resolution
// work). z7/w7 are left free so that effort can grow into its own texel.
// FALLBACK: with no 3DMigoto (or before the first publish) Load() returns 0 and each accessor
// below substitutes its default, which reproduces the intended behaviour rather than a zero.
Texture1D<float4> shadow_iniparams : register(t120);

float shadow_fade_start()
{
	float v = shadow_iniparams.Load(int2(8, 0)).y;
	return (v < 0.05f || v > 0.99f) ? 0.80f : v;			// guard an unset / absurd slot
}
float shadow_bias_scale()
{
	float v = shadow_iniparams.Load(int2(8, 0)).w;
	return (v <= 0.0f) ? 1.0f : v;						// 0 (unset) -> 1.0
}
float shadow_debug_mode()
{
	return shadow_iniparams.Load(int2(8, 0)).z;
}

// halo3-ng — ShaderRegex anchors. Never read (the guard at the use site is never true); they
// exist only to force a `dcl_resource_texture2d ... t100` / `t101` into the compiled DXBC so
// d3dx.ini can identify these draws by DECLARATION instead of by hash. Necessary because:
//   * the apply PS's real declaration set {s1, t0, t1, t2} collides with 1622 shader families
//     (tools/dxbc_fingerprint.py preflight --stage ps --samp 1 --tex 0 --tex 1 --tex 2),
//   * t100/t101 are free across all 4198 blobs in the corpus (--tex 100 -> 0 matches), and
//   * hashes rotate every time this file is touched, and there are five live variants.
// Two anchors so projected shadows (default_ps) and ellipsoid blob shadows (albedo_ps) can be
// hooked independently.
Texture2D<float4> ng_shadow_apply_anchor : register(t100);		// default_ps — projected shadows
Texture2D<float4> ng_shadow_blob_anchor  : register(t101);		// albedo_ps  — ellipsoid blobs

// halo3-ng — colour identity for $shadow_debug == 1. The four wrapper variants override this
// BEFORE the #include; this is the fallback for shadow_apply.hlsl compiled directly.
#ifndef SHADOW_VARIANT_TINT
#define SHADOW_VARIANT_TINT float3(1.0f, 0.0f, 1.0f)			// magenta = shadow_apply (base)
#endif

LOCAL_SAMPLER_2D_IN_VIEWPORT_ALLWAYS(zbuffer, 0);
LOCAL_SAMPLER_2D(shadow, 1);
LOCAL_SAMPLER_2D_IN_VIEWPORT_ALLWAYS(normal_buffer, 2);

#define CAMERA_TO_SHADOW_PROJECTIVE_X p_lighting_constant_0
#define CAMERA_TO_SHADOW_PROJECTIVE_Y p_lighting_constant_1
#define CAMERA_TO_SHADOW_PROJECTIVE_Z p_lighting_constant_2

#define INSCATTER_SCALE		p_lighting_constant_3
#define INSCATTER_OFFSET	p_lighting_constant_4

#define zbuffer_xform p_lighting_constant_6
#define screen_xform p_lighting_constant_7

#define ZBUFFER_SCALE (p_lighting_constant_8.r)
#define ZBUFFER_BIAS (p_lighting_constant_8.g)
#define SHADOW_PIXELSIZE (p_lighting_constant_8.b)
#define ZBUFFER_PIXELSIZE (p_lighting_constant_8.a)

#define SHADOW_DIRECTION_WORLDSPACE (p_lighting_constant_9.xyz)

//@generate tiny_position_only
//@entry default
//@entry albedo


#define LDR_ALPHA_ADJUST g_exposure.w
#define HDR_ALPHA_ADJUST g_exposure.b
#define DARK_COLOR_MULTIPLIER g_exposure.g
#include "render_target.fx"

static const float2 g_shadow_pixel_size= float2(1.0/512.0f, 1.0/512.0f);		// shadow pixel size ###ctchou $TODO THIS NEEDS TO BE PASSED IN!!!  good thing we don't care about PC...
#define PIXEL_SIZE g_shadow_pixel_size
#include "texture.fx"


#include "texture_xform.fx"

// default for hard shadow
void default_vs(
	in vertex_type vertex,
	out float4 screen_position : SV_Position)
{
    float4 local_to_world_transform[3];
	if (always_true)
	{
		deform(vertex, local_to_world_transform);
	}
	
	if (always_true)
	{
		screen_position= mul(float4(vertex.position, 1.0f), View_Projection);
	}
	else
	{
		screen_position= float4(0,0,0,0);
	}
}


float sample_percentage_closer_PCF_3x3_block(float3 fragment_shadow_position, float depth_bias)					// 9 samples, 0 predicated
{
#ifndef pc
	[isolate]		// optimization - reduces GPRs
#endif // !pc

	float2 texel= fragment_shadow_position.xy;

	float4 blend= 1.0f;
	float scale= 1.0f / 9.0f;
	
//#ifdef BILINEAR_SHADOWS
#ifndef VERTEX_SHADER
	float2 frac_pos = fragment_shadow_position.xy / g_shadow_pixel_size;
	blend.xy = frac(frac_pos);
	blend.zw= 1.0f - blend.xy;
	scale = 1.0f / 4.0f;
#endif // VERTEX_SHADER
//#endif // BILINEAR_SHADOWS

	
	float4 max_depth= depth_bias;											// x= [0,0],    y=[-1/1,0] or [0,-1/1],     z=[-1/1,-1/1],		w=[-2/2,0] or [0,-2/2]
	max_depth *= float4(-1.0f, -sqrt(20.0f), -3.0f, -sqrt(26.0f));			// make sure the comparison depth is taken from the very corner of the samples (maximum possible distance from our central point)
	max_depth += fragment_shadow_position.z;

	float color=	blend.z * blend.w * step(max_depth.z, tex2D_offset_point(shadow, texel, -1.0f, -1.0f).r) + 
					1.0f    * blend.w * step(max_depth.y, tex2D_offset_point(shadow, texel, +0.0f, -1.0f).r) +
					blend.x * blend.w * step(max_depth.z, tex2D_offset_point(shadow, texel, +1.0f, -1.0f).r) +
					blend.z * 1.0f    * step(max_depth.y, tex2D_offset_point(shadow, texel, -1.0f, +0.0f).r) +
					1.0f    * 1.0f    * step(max_depth.x, tex2D_offset_point(shadow, texel, +0.0f, +0.0f).r) +
					blend.x * 1.0f    * step(max_depth.y, tex2D_offset_point(shadow, texel, +1.0f, +0.0f).r) +
					blend.z * blend.y * step(max_depth.z, tex2D_offset_point(shadow, texel, -1.0f, +1.0f).r) +
					1.0f    * blend.y * step(max_depth.y, tex2D_offset_point(shadow, texel, +0.0f, +1.0f).r) +
					blend.x * blend.y * step(max_depth.z, tex2D_offset_point(shadow, texel, +1.0f, +1.0f).r);

	return color * scale;
}

// halo3-ng: 5x5 PCF for softer shadow edges (12-tap cross pattern)
float sample_percentage_closer_PCF_5x5_block(float3 fragment_shadow_position, float depth_bias)
{
	float2 texel= fragment_shadow_position.xy;

	float4 max_depth= depth_bias;
	max_depth *= float4(-1.0f, -sqrt(20.0f), -3.0f, -sqrt(32.0f));
	max_depth += fragment_shadow_position.z;

	// 12-tap cross: skip the 4 extreme corners of 5x5
	float color=
					                                                                                           step(max_depth.z, tex2D_offset_point(shadow, texel, +0.0f, -2.0f).r) +
					step(max_depth.z, tex2D_offset_point(shadow, texel, -1.0f, -1.0f).r) + step(max_depth.y, tex2D_offset_point(shadow, texel, +0.0f, -1.0f).r) + step(max_depth.z, tex2D_offset_point(shadow, texel, +1.0f, -1.0f).r) +
		step(max_depth.z, tex2D_offset_point(shadow, texel, -2.0f, +0.0f).r) + step(max_depth.y, tex2D_offset_point(shadow, texel, -1.0f, +0.0f).r) + step(max_depth.x, tex2D_offset_point(shadow, texel, +0.0f, +0.0f).r) + step(max_depth.y, tex2D_offset_point(shadow, texel, +1.0f, +0.0f).r) + step(max_depth.z, tex2D_offset_point(shadow, texel, +2.0f, +0.0f).r) +
					step(max_depth.z, tex2D_offset_point(shadow, texel, -1.0f, +1.0f).r) + step(max_depth.y, tex2D_offset_point(shadow, texel, +0.0f, +1.0f).r) + step(max_depth.z, tex2D_offset_point(shadow, texel, +1.0f, +1.0f).r) +
					                                                                                           step(max_depth.z, tex2D_offset_point(shadow, texel, +0.0f, +2.0f).r);

	return color / 13.0f;
}


accum_pixel default_ps(
	SCREEN_POSITION_INPUT(pixel_pos))
{
	float2 texture_pos= pixel_pos.xy;

	float pixel_depth= zbuffer.t.Load(int3(texture_pos, 0)).r;
	pixel_depth = 1.0f / (pixel_depth * ZBUFFER_SCALE + ZBUFFER_BIAS);					// convert to 'true' depth		(z)

	// calculate projected screen position
	float4 screen_position= float4(transform_texcoord(pixel_pos.xy, screen_xform) * pixel_depth, pixel_depth, 1.0f);
	
/*
	// GRADIENT NORMAL - not used cuz we have normal buffers now

	float4 fragment_shadow_position;
	fragment_shadow_position.x= dot(screen_position, CAMERA_TO_SHADOW_X);
	fragment_shadow_position.y= dot(screen_position, CAMERA_TO_SHADOW_Y);
	fragment_shadow_position.z= dot(screen_position, CAMERA_TO_SHADOW_Z);
	fragment_shadow_position.w= 1.0f;

	float3 shadow_gradient_x= ddx(fragment_shadow_position.xyz);
	float3 shadow_gradient_y= ddy(fragment_shadow_position.xyz);
	float3 normal_shadow_space= normalize(cross(shadow_gradient_y, shadow_gradient_x));
	float cosine= normal_shadow_space.z;
*/

	// NOTE: if we want projective shadows, do this dot product and divide x,y,z by w
	float3 fragment_shadow_projected;
	fragment_shadow_projected.x= dot(screen_position, CAMERA_TO_SHADOW_PROJECTIVE_X);				
	fragment_shadow_projected.y= dot(screen_position, CAMERA_TO_SHADOW_PROJECTIVE_Y);
	fragment_shadow_projected.z= dot(screen_position, CAMERA_TO_SHADOW_PROJECTIVE_Z);
	
   //float3 texel = fragment_shadow_projected;
   //float sh_res = sample2D(shadow, texel.xy).r;
   //sh_res = sh_res > texel.z;
   //return convert_to_render_target(float4(sh_res, 0.0, 0.0, 0.0), false, true);

	float3 normal_world_space= normal_buffer.t.Load(int3(texture_pos, 0)).xyz * 2.0f - 1.0f;										// ###ctchou $PERF bias this in the texture format
	float cosine= dot(normal_world_space, SHADOW_DIRECTION_WORLDSPACE.xyz);

#ifdef DOUBLE_COSINE
	float cosine_falloff= saturate(cosine) * saturate(cosine);
#else
	float cosine_falloff= saturate(cosine);
#endif

	// halo3-ng (Aug 2026) — DISTANCE FADE. Vanilla was:
	//     f = saturate(z*2-1); f *= f;  strength = alpha * (1 - f*f) * cosine
	// i.e. 1 - (2z-1)^4 in SHADOW-VOLUME depth. Because the volume is fitted to the CASTER, its
	// midpoint sits roughly one caster-height above the ground, so the shadow was already ~41%
	// gone by z=0.9 — before it properly reached the floor. That is the "shadows fade out with
	// distance" symptom; it is not a camera-distance term at all.
	//
	// The falloff's LEGITIMATE job is reaching exactly 0 at the volume's far plane so the shadow
	// doesn't terminate on a hard edge. A narrow smootherstep band does that job BETTER, not
	// worse: vanilla arrives at z=1 with slope -8, smootherstep arrives with zero first AND
	// second derivative. Containment is unchanged — both are identically 0 for z >= 1.
	float fade_start= shadow_fade_start();																				// $shadow_fade_start (IniParams y7, default 0.80)
	float ft= saturate((fragment_shadow_projected.z - fade_start) / max(1.0f - fade_start, 1e-3f));
	float shadow_falloff= ft*ft*ft*(ft*(ft*6.0f - 15.0f) + 10.0f);														// smootherstep

	float shadow_darkness= k_ps_constant_shadow_alpha.r * (1.0f - shadow_falloff) * cosine_falloff;

	float darken= 1.0f;
#ifndef pc
	[predicateBlock]
//	[predicate]
//	[branch]
#endif // !pc

	if (shadow_darkness > 0.001)		// if maximum shadow darkness is zero (or very very close), don't bother doing the expensive PCF sampling
	{
		// calculate depth_bias (the maximum allowed depth_disparity within a single pixel)
		//		depth_bias = maximum_fragment_slope * half_pixel_size
		//      maximum fragment slope is the magnitude of the surface gradient with respect to shadow-space-Z (basically, glancing pixels have high slope)
		//      half pixel size is the distance in world space from the center of a shadow pixel to a corner (dotted line in diagram)
		//          ___________
		//         |         .'|
		//         |       .'  |
		//         |     .'    |
		//         |           |
		//         |___________|
		//
		//		the basic idea is:  we know the current fragment is within half_pixel_size of the center of this pixel in the shadow projection
		//							the depth map stores the Z value of the center of the pixel, we want to determine what the Z value is at our projection
		//							our simple approximation is to assume it is at the farthest point in the pixel, and do the compare at that point

#if (defined(pc) && (DX_VERSION == 9)) || (! defined(FASTER_SHADOWS))
		cosine= max(cosine, 0.24253562503633297351890646211612);									// limits max slope to 4.0, and prevents divide by zero  ###ctchou $REVIEW could make this (4.0) a shader parameter if you have trouble with the masterchief's helmet not shadowing properly
		float slope= sqrt(1-cosine*cosine) / cosine;												// slope == tan(theta) == sin(theta)/cos(theta) == sqrt(1-cos^2(theta))/cos(theta)
		slope= slope + 0.2f;
#else
		float slope= 0.0f;
#endif // FASTER_SHADOWS

		float half_pixel_size= SHADOW_PIXELSIZE;													// the texture coordinate distance from the center of a pixel to the corner of the pixel
		// halo3-ng: runtime-scalable so the peter-panning risk from re-enabling this bias on the
		// _point/_faster/_bilinear/_fancy variants can be A/B'd on F10. 0.001 ~= bias off.
		float depth_bias= slope * half_pixel_size * shadow_bias_scale();

		// sample shadow depth
		float percentage_closer= SAMPLE_PERCENTAGE_CLOSER(fragment_shadow_projected.xyz, depth_bias);
		
		// compute darkening
		darken= saturate(1.01-shadow_darkness + percentage_closer * shadow_darkness);		// 1.001 to fix round off error..  (we want to ensure we output at least 1.0 when percentage_closer= 1, not 0.9999)
		// halo3-ng: removed darken *= darken (squaring crushed soft shadow penumbra gradients)
	}

	// halo3-ng: ShaderRegex anchor keep-alive. Never taken — k_ps_constant_shadow_alpha.r is a
	// shadow ALPHA in [0,1] — but it is a runtime cbuffer read, so fxc cannot fold the branch away
	// and the t100 declaration survives into RDEF. Do NOT replace the condition with `always_true`
	// (#define always_true true on DX11 — a literal, which fxc WOULD fold, silently deleting the
	// anchor and killing the d3dx.ini hook).
	if (k_ps_constant_shadow_alpha.r < -1.0e30f)
	{
		darken += ng_shadow_apply_anchor.Load(int3(0, 0, 0)).r;
	}

	// compute inscatter
	float3 inscatter= -pixel_depth * INSCATTER_SCALE + INSCATTER_OFFSET;

	// halo3-ng — $shadow_debug (IniParams z7). The engine's blend adds inscatter*(1-darken), so a
	// tint written here is visible ONLY inside this draw's shadow footprint, and overlapping
	// shadow groups read as the SUM of their tints — which is exactly the diagnostic we want.
	//   1 = per-variant tint: which of the five compiled apply variants drew this shadow.
	//   2 = shadow_darkness (i.e. k_ps_constant_shadow_alpha * fades) as greyscale — tells us
	//       whether the ENGINE is ramping shadow alpha down with distance, which is the one part
	//       of "shadows fade at distance" that is NOT fixable in this shader.
	float dbg= shadow_debug_mode();
	if (dbg > 0.5f)
	{
		inscatter= (dbg < 1.5f) ? (SHADOW_VARIANT_TINT * 0.35f) : float3(shadow_darkness, shadow_darkness, shadow_darkness);
	}

	//return convert_to_render_target(float4(normal_world_space, 0.0), false, true);

	// the destination contains (pixel * extinction + inscatter) - we want to change it to (pixel * darken * extinction + inscatter)
	// so we multiply by darken (aka src alpha), and add inscatter * (1-darken)
	return convert_to_render_target(float4(inscatter * g_exposure.rrr, darken), false, true);		// Note: the (inscatter*(1-darken)) clamping is not correct, but only when the inscatter is HDR already - in which case you can't see anything anyways
				// ###ctchou $PERF multiply inscatter by g_exposure before passing to this shader  :)
}


// albedo for ambient blur shadow

void albedo_vs(
	in vertex_type vertex,
	out float4 screen_position : POSITION)
{
    float4 local_to_world_transform[3];
	if (always_true)
	{
		deform(vertex, local_to_world_transform);
	}
	
	if (always_true)
	{
		screen_position= mul(float4(vertex.position, 1.0f), View_Projection);
	}
	else
	{
		screen_position= float4(0,0,0,0);
	}
}


#ifdef pc
#define		SPHERE_DATA(index, offset, registers)	occlusion_spheres[k_occlusion_sphere_stride * index + offset].registers
#else
#define		SPHERE_DATA(index, offset, registers)	occlusion_spheres[index + offset].registers
#endif

#define		SPHERE_CENTER(index)			SPHERE_DATA(index, 0, xyz)
#define		SPHERE_AXIS(index)				SPHERE_DATA(index, 1, xyz)
#define		SPHERE_RADIUS_SHORTER(index)	SPHERE_DATA(index, 0, w)
#define		SPHERE_RADIUS_LONGER(index)		SPHERE_DATA(index, 1, w)

accum_pixel albedo_ps(
	SCREEN_POSITION_INPUT(pixel_pos))
{
	// get world position of current pixel	
#ifndef pc	
	pixel_pos.xy += p_tiling_vpos_offset.xy;
#endif	
	float2 texture_pos= pixel_pos.xy;	
	float pixel_depth= zbuffer.t.Load(int3(texture_pos, 0)).r; // todo: do we need to transform this depth? [11/15/2012 paul.smirnov]
	float4 world_position= float4(transform_texcoord(pixel_pos.xy, screen_xform), pixel_depth, 1.0f);
	world_position= mul(world_position, view_inverse_matrix);
	world_position.xyz/= world_position.w;

	float percentage_closer= 1.0f;
	[loop]
	for (int sphere_index= 0; sphere_index < occlusion_spheres_count; sphere_index++)
	{
		//float3 sphere_center= SPHERE_CENTER(sphere_index);
		float3 ellipse_center= SPHERE_CENTER(sphere_index);
		float3 ellipse_axis= SPHERE_AXIS(sphere_index);
		float ellipse_radius_shorter= SPHERE_RADIUS_SHORTER(sphere_index);
		float ellipse_radius_longer= SPHERE_RADIUS_LONGER(sphere_index);

		float3 center_to_pixel_direction= ellipse_center-world_position.xyz;		
		float center_to_pixel_distance= length(center_to_pixel_direction);

		// darken by distance along light path
		float darken= 0.0f;
		{
			float3 light_to_cent= cross(center_to_pixel_direction, SHADOW_DIRECTION_WORLDSPACE);
			float light_to_cent_length= length(light_to_cent);

			// normalize light to center vector
			light_to_cent/= light_to_cent_length;
			float along_axis= abs( dot(light_to_cent, ellipse_axis) );
			float radius= lerp(ellipse_radius_shorter, ellipse_radius_longer, along_axis);

			// compute darken			
			float ratio= max(light_to_cent_length / radius, 0.5f);
			//ratio= sqrt(ratio);
			darken= saturate( 1.0f - 0.3f * ratio);		
		}

		// influence by distance and normal direction
		float influence= 0.0f;
		{
			// normalize direction
			center_to_pixel_direction/= center_to_pixel_distance;
			float radius= ellipse_radius_shorter;

			// compute influence			
			//influence= saturate(radius / center_to_pixel_distance);			
			influence= saturate(1.0f - 0.2f * center_to_pixel_distance / radius);			
			//influence*= influence;

			float avoid_self_shadow= saturate(-0.2f + 1.2f*dot(center_to_pixel_direction, SHADOW_DIRECTION_WORLDSPACE));
			influence*= avoid_self_shadow ;
		}

		//percentage_closer= min(percentage_closer, 1.0f - darken * influence);
		percentage_closer*= 1.0f - darken * influence;
	}

	float3 normal_world_space= normal_buffer.t.Load(int3(texture_pos, 0)).xyz * 2.0f - 1.0f;										// ###ctchou $PERF bias this in the texture format
	float cosine= dot(normal_world_space, SHADOW_DIRECTION_WORLDSPACE.xyz);
	float shadow_darkness= k_ps_constant_shadow_alpha.r * saturate(0.6f + 0.4f * cosine);			// z_depth_falloff= 1 - (shifted_depth)^4,    incident_falloff= cosine lobe

	// halo3-ng: t101 ShaderRegex anchor keep-alive (see the t100 note in default_ps). Separate
	// slot so the ellipsoid BLOB shadows can be hooked independently of the projected ones —
	// they are a different visibility term and may or may not belong in the unified mask.
	if (k_ps_constant_shadow_alpha.r < -1.0e30f)
	{
		shadow_darkness += ng_shadow_blob_anchor.Load(int3(0, 0, 0)).r;
	}

	//float shadow_darkness= k_ps_constant_shadow_alpha.r * 0.8;
	

	float darken= 1.0f;
	if (shadow_darkness > 0.001)		// if maximum shadow darkness is zero (or very very close), don't bother doing the expensive PCF sampling
	{		
		// compute darkening
		darken= saturate(1.01-shadow_darkness + percentage_closer * shadow_darkness);		// 1.001 to fix round off error..  (we want to ensure we output at least 1.0 when percentage_closer= 1, not 0.9999)
		// halo3-ng: removed darken *= darken (squaring crushed soft shadow penumbra gradients)
	}

	// compute inscatter
#if defined(pc) && (DX_VERSION == 9)
	float3 inscatter= -(1.0f - pixel_depth) * INSCATTER_SCALE + INSCATTER_OFFSET;
#else
	float3 inscatter= -pixel_depth * INSCATTER_SCALE + INSCATTER_OFFSET;
#endif

	// the destination contains (pixel * extinction + inscatter) - we want to change it to (pixel * darken * extinction + inscatter)
	// so we multiply by darken (aka src alpha), and add inscatter * (1-darken)
	return convert_to_render_target(float4(inscatter * g_exposure.rrr, darken), false, true);		// Note: the (inscatter*(1-darken)) clamping is not correct, but only when the inscatter is HDR already - in which case you can't see anything anyways
	// ###ctchou $PERF multiply inscatter by g_exposure before passing to this shader  :)
}
