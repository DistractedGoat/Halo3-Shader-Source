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

// SSR debug overlay (bound by 3DMigoto at ps-t14 when z==1 / F3 toggle)
// RGBA16_FLOAT: .rgb=SSR color (pre-exposure HDR), .a=confidence. Unbound → all zeros → no-op.
Texture2D<float4> ssr_debug_overlay : register(t14);

// Roughness debug (bound by 3DMigoto at ps-t8 when $v==1 / F2 toggle)
// R16_FLOAT: roughness scalar. Unbound → Load() returns 0.0 → no-op (sky also 0.0 from clear).
// Moved from t20 → t8: 3DMigoto can't bind high-numbered ps-t slots reliably (confirmed empirically
// — ao_buffer@t10, ssr_debug@t14, ssgi@t15 all work; t20 does not).
Texture2D<float> debug_roughness_tex : register(t8);

// Current-frame raw depth (bound by 3DMigoto at ps-t9 when $v==1 / F2 toggle)
// R32_FLOAT reverse-Z depth from ResourceCurrentDepthCopy. Sky = 0.0; any geometry > 0.0.
// Used by color-band roughness diagnostic to distinguish sky from unwritten geometry.
Texture2D<float> debug_depth_tex : register(t9);

// halo3-ng: SSS moved into forward pass (ao_ssgi_inline.fx) at t32 — applied pre-fog
// so engine's `out_color * extinction + inscatter` attenuates SSS the same way it
// attenuates AO/SSGI. Old ps-t11 bind + composite-time multiply deleted.

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

	// halo3-ng: SSS contact shadows now applied in the forward pass (pre-fog) via
	// apply_ao_ssgi_inline() at ao_ssgi_inline.fx. Moving the multiply before the
	// engine's `color * extinction + inscatter` fog blend fixes the composite-time
	// bug where SSS darkened inscatter (the scattered sky light a contact shadow
	// physically cannot occlude). The old hand-tuned sss_fog_scale and luminance
	// weighting are no longer needed — the engine's real atmosphere handles fade.

	// ============================================================================
	// PHASE 2 — Specular Occlusion (NOT YET IMPLEMENTED — design notes follow)
	// ============================================================================
	//
	// Goal: Use bent normal to gate SSR confidence, removing reflections from
	// geometrically occluded cavities (corners, crevices, under overhangs).
	//
	// Algorithm: cone-cone intersection (Jimenez 2016 / UE5 SpecularOcclusion)
	//   - "Unoccluded cone" centered on bentNormal, half-angle = FastACos(ao)
	//   - "Reflection cone" centered on reflDir, half-angle = roughness * HALF_PI
	//   - specOcc = 1 if cones overlap, 0 if reflection dir is fully occluded
	//
	// Implementation (when ready):
	//   1. Bind ResourceRoughness → ps-t11 in [ShaderOverrideColorGrading] / [KeyDebugSSR]
	//      (roughness MRT requires SV_Target3 at render_target.fx — currently used by rawDepth)
	//
	//   2. Add to this file:
	//      Texture2D<float> roughness_buffer : register(t11);
	//      float roughness = roughness_buffer.Load(int3(int2(texcoord * float2(1920.0f, 1080.0f)), 0)).r;
	//
	//   3. Reconstruct view-space reflection direction:
	//      float3 viewDir = normalize(float3(
	//          g_NDCToViewMul * (texcoord * 2.0f - 1.0f) + g_NDCToViewAdd, 1.0f));
	//      float3 viewN = float3(bentN_XY, bentN_Z);  // already computed above
	//      float3 reflDir = reflect(-viewDir, viewN);
	//
	//   4. Cone-cone intersection:
	//      float specCone     = roughness * HALF_PI;
	//      float unoccCone    = FastACos(saturate(ao));
	//      float cosAngle     = saturate(dot(reflDir, float3(bentN_XY, bentN_Z)));
	//      float angleBetween = FastACos(cosAngle);
	//      float specOcc      = saturate(1.0f - smoothstep(
	//                               max(0.0f, unoccCone - specCone),
	//                               unoccCone + specCone, angleBetween));
	//
	//   5. Apply to SSR debug overlay block below:
	//      ssrDbg.a *= specOcc;
	//
	// BENT NORMAL Y-AXIS BIAS (known limitation for Phase 2):
	//   GTAO slice phi sweeps [0, PI] in screen space, so sin(phi) >= 0 always.
	//   The bent normal accumulator (bentAccum += orthoDir * sliceAO) can never
	//   accumulate a negative Y component. This means ceiling surfaces (whose
	//   unoccluded hemisphere points upward in screen Y) will have a slightly
	//   upward-biased bent normal rather than the true downward unoccluded direction.
	//   Fix (when Phase 2 warrants it): extend phi to [0, 2*PI] and halve g_SliceCount,
	//   or directly reconstruct the full-hemisphere slice by mirroring the negative-phi
	//   direction. Not urgent — specular occlusion cone test is tolerant of small bias.
	// ============================================================================

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

	// === SSR debug overlay (F3 / z-toggle) — COMPILE-TIME DISABLED ===
	// Re-enable by defining DEBUG_SSR_OVERLAY at the top of this file. Runtime-gating via
	// ssrDbg.a > 0.001f is unreliable: DX11 leaves stale SRVs bound to ps-t14 from material
	// textures with arbitrary alpha values, causing false-positive overwrites of scene color.
#ifdef DEBUG_SSR_OVERLAY
	{
		float4 ssrDbg = ssr_debug_overlay.Load(int3(int2(texcoord * float2(1920.0f, 1080.0f)), 0));
		if (ssrDbg.a > 0.001f)
		{
			if (ssrDbg.a > 1.5f)
				result.rgb = ssrDbg.rgb;  // debug sentinel (alpha=2.0): already display-linear, no exposure divide
			else
				result.rgb = ssrDbg.rgb / max(g_exposure.r, 1e-4f);  // SSR data: pre-exposure HDR, needs divide
			result.a = 1.0f;
		}
	}
#endif

	// === Roughness linear grayscale diagnostic (F2 / v-toggle) — COMPILE-TIME DISABLED ===
	// Re-enable by defining DEBUG_ROUGHNESS_OVERLAY at the top of this file. Runtime-gating
	// via "rawD > 0" was unreliable: DX11 leaves stale SRVs bound to ps-t9 from material
	// depth/mask textures, causing the block to fire on all geometry pixels and overwrite the
	// scene with grayscale (white close-up) or magenta where ps-t8 held an RGB mask.
	// This was the root cause of the "Arbiter/AR top/rock white close-up, magenta at distance"
	// artifact during Phase F2 probe-gather tuning — the diagnostic masqueraded as real GI.
#ifdef DEBUG_ROUGHNESS_OVERLAY
	{
		int2 pix_r  = int2(texcoord * float2(1920.0f, 1080.0f));
		float dbg_r = debug_roughness_tex.Load(int3(pix_r, 0));
		float rawD  = debug_depth_tex.Load(int3(pix_r, 0));
		bool isSky  = (rawD <= 0.0f);
		if (!isSky)
		{
			// Linear 0..1 grayscale — no gamma, no remap. saturate guards stray NaN/neg/>1 values.
			float r = saturate(dbg_r);
			result = float4(r, r, r, 1.0f);
		}
		// Sky (or unbound): pass-through, no overlay
	}
#endif

	return result;
}
