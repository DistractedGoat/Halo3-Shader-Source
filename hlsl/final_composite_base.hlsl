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

// Screen-space shadow factor (bound by 3DMigoto at ps-t11 when $s==1 / F5 toggle).
// float4: .r=shadow [0=fully shadowed, 1=lit]; .g=hitDistance world units (unused at composite);
//         .b=viewZ sentinel (0=sky/unbound → no darkening); .a=unused.
// When ps-t11 is unbound, Load() returns (0,0,0,0) → .b==0 → falls back to 1.0 (no shadow applied).
Texture2D<float4> sss_texture : register(t11);

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
	// ao_buffer carries float4(bent_nx, bent_ny, ao, viewZ) from GTAO pass.
	// .a = viewZ: real-surface flag (0 for sky/water) + fog distance.
	float4 ao_sample = sample2D(ao_buffer, texcoord);
	float  ao_viewZ  = ao_sample.a;
	float  ao        = (ao_viewZ > 0.001f) ? saturate(ao_sample.b) : 1.0f;  // sky/water/unbound → ao=1.0
	float2 bentN_XY  = (ao_viewZ > 0.001f) ? ao_sample.rg : float2(0.0f, 0.0f);
	float  bentN_Z   = sqrt(max(0.001f, 1.0f - min(dot(bentN_XY, bentN_XY), 1.0f)));
	// bentNormal is view-space; .xy is in-plane, .z is viewer-facing component (always positive)

	// Multi-bounce colored AO (Patapom 2018 / UE5 LumenScreenSpaceBentNormal)
	// albedo_texture (t16) persists from shadow_apply as stale SRV — same as SSGI receiver.
	// Load() returns raw sRGB bytes; square to approximate gamma-2 decode to linear.
	float3 albedo_ao = albedo_texture.Load(int3(int2(texcoord * float2(1920.0f, 1080.0f)), 0)).rgb;
	albedo_ao = albedo_ao * albedo_ao;  // sRGB → ~linear (gamma-2 approximation)
	// Patapom cubic polynomial: max(ao, poly(ao, albedo)) adds indirect bounce energy per channel.
	// Result: per-channel occlusion — red surfaces stay bright in red, dark surfaces absorb all bounces.
	// ao passed directly (not squared) — the polynomial already applies the right curve per-channel.
	float ao_d = ao;
	float3 aoV = float3(ao_d, ao_d, ao_d);
	float3 mb_a =  2.0404f * albedo_ao - 0.3324f;
	float3 mb_b = -4.7951f * albedo_ao + 0.6417f;
	float3 mb_c =  2.7552f * albedo_ao + 0.6903f;
	float3 ao_multi = max(aoV, ((aoV * mb_a + mb_b) * aoV + mb_c) * aoV);
	// ao_multi: per-channel [ao_d..1] — bright albedo channels lose less energy from occlusion

	// Fog fade: attenuate AO per-channel toward 1 at distance
	if (ao_viewZ > 0.001f && ao < 1.0f)
	{
		float dist = min(max(ao_viewZ + v_atmosphere_constant_0.w, 0.0f), v_atmosphere_constant_1.w);
		float3 extinction = exp2(-(v_atmosphere_constant_2.xyz + v_atmosphere_constant_3.xyz) * dist);
		float fog = 1.0f - dot(extinction, float3(0.333f, 0.333f, 0.333f));
		float ao_fog_scale = 7.0f;
		ao_multi = lerp(ao_multi, float3(1.0f, 1.0f, 1.0f), saturate(fog * ao_fog_scale));
	}

	// === Screen-space contact shadows (halo3-ng, F5 / $s toggle) ===
	// Applied FIRST — direct-light occlusion belongs to the lighting term, before ambient/indirect.
	// Soft blend: fog-fade with distance, lighting-aware modulation, min-floor to preserve crevice
	// detail. Atmosphere extinction reuses the same formula as AO/SSGI for visual coherence.
	// Sky / water / unbound: .b viewZ sentinel == 0 → sss_factor = 1.0 (no darkening).
	{
		int2   pix_sss  = int2(texcoord * float2(1920.0f, 1080.0f));
		float4 sss_data = sss_texture.Load(int3(pix_sss, 0));
		float  sss_raw  = sss_data.r;
		float  sss_viewZ = sss_data.b;

		if (sss_viewZ > 0.001f)
		{
			// Tunables (hardcoded — match codebase pattern; flip via shader recompile)
			const float sss_strength  = 1.0f;   // overall multiplier (0=off, 1=full)
			const float sss_min_floor = 0.12f;  // never crush past this — preserves indirect detail
			const float sss_fog_scale = 7.0f;   // matches AO/SSGI fog scale
			const float sss_lum_knee  = 0.005f; // only protect near-pitch-black pixels
			const float sss_lum_full  = 0.06f;  // most lit surfaces get full strength

			// Atmospheric fade — distant pixels are drowned in scatter, hard contact shadow
			// at 80m looks wrong. Use the same extinction formula as AO/SSGI.
			float sss_dist = min(max(sss_viewZ + v_atmosphere_constant_0.w, 0.0f), v_atmosphere_constant_1.w);
			float3 sss_extinction = exp2(-(v_atmosphere_constant_2.xyz + v_atmosphere_constant_3.xyz) * sss_dist);
			float  sss_fog = 1.0f - dot(sss_extinction, float3(0.333f, 0.333f, 0.333f));
			float  fogFade = saturate(1.0f - sss_fog * sss_fog_scale);

			// Lighting-aware: bright direct-lit pixels darken more than already-dark crevices
			// (avoids "double shadow" stacking on baked shadows from the lightmap).
			float recvLum    = dot(combined.rgb, float3(0.2126f, 0.7152f, 0.0722f));
			float lumWeight  = smoothstep(sss_lum_knee, sss_lum_full, recvLum);

			// Final blend: lerp(1, sss_raw, strength) gives base shadow, then floor it,
			// then scale strength by fog and lighting weight.
			float strength   = saturate(sss_strength * fogFade * lumWeight);
			float sss_factor = lerp(1.0f, sss_raw, strength);
			sss_factor       = max(sss_factor, sss_min_floor);

			combined.rgb *= sss_factor;
		}
	}
	// === end SSS ===

	// === AO multiply — applied AFTER SSS, BEFORE SSGI ===
	// Order: SSS (direct shadow) → AO (ambient/cavity) → SSGI (bounce light fills the dark).
	// Multi-bounce per-channel: red surfaces keep reddish tint in cavities, dark surfaces go black.
	{
		float ao_scene_strength = 1.0f;   // 0=no AO darkening, 1=full scene darkening
		float ao_dark_floor     = 0.01f;  // minimum per-channel brightness at max occlusion
		float3 ao_color = lerp(float3(ao_dark_floor, ao_dark_floor, ao_dark_floor), float3(1.0f, 1.0f, 1.0f), ao_multi);
		combined.rgb *= lerp(float3(1.0f, 1.0f, 1.0f), ao_color, ao_scene_strength);
	}
	// === end AO ===

	// === SSGI indirect diffuse — added LAST so bounce light fills SSS+AO darkened regions ===
	// Correct lighting model: SSS+AO occlude DIRECT light only; SSGI bounce is added on top.
	// receiverWeight uses post-shadow `combined` luminance, so SSGI is naturally suppressed in
	// fully-shadowed regions but the receiver_floor still allows some bounce in deep shadows.
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

	// === SSR debug overlay (F3 / z-toggle) ===
	// Bind ResourceSSRFinal to ps-t14 via d3dx.ini [KeyDebugSSR] to activate.
	// When ps-t14 is unbound, Load() returns (0,0,0,0) → confidence == 0 → no-op.
	// When bound: pixels with SSR hits show SSR color; pixels with no hit (confidence==0) pass through.
	// SSR color is pre-exposure HDR — divide by exposure to bring to display-linear before output.
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

	// === Roughness linear grayscale diagnostic (F2 / v-toggle) ===
	// Reads ResourceRoughness (ps-t8) AND ResourceCurrentDepthCopy (ps-t9) bound via d3dx.ini
	// when v==1. Emits the raw roughness value as linear [0,1] grayscale:
	//   BLACK = 0.0 (mirror)       WHITE = 1.0 (fully diffuse)
	// Sky (rawDepth == 0) passes through as the normal scene so the user keeps spatial context.
	// When v==0 (unbound): debug_depth_tex.Load() returns 0 → isSky==true everywhere → pass-through
	// (no overlay painted on geometry). Overlay only paints on real geometry pixels.
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

	return result;
}
