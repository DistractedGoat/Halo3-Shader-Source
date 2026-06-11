#ifndef _MOTION_VECTORS_FX_
#define _MOTION_VECTORS_FX_

// halo3-ng: Shared motion vector computation
// Include this from any render method that needs per-vertex motion vectors.
// Requires: global.fx (for ACCUM_PIXEL_HAS_MV), hlsl_constant_persist.fx (for sampler_prev_vp_matrix)

#ifdef ACCUM_PIXEL_HAS_MV
float2 compute_motion_vector(float4 current_position, float3 world_position)
{
	// Load previous VP matrix from VS texture t2 (4x1 Texture2D, stored ROW-MAJOR)
	// copy_vp_to_texture.hlsl writes rows via cs-cb0 (compiler handles column-major)
	float4 r0 = sampler_prev_vp_matrix.t.Load(int3(0, 0, 0));
	float4 r1 = sampler_prev_vp_matrix.t.Load(int3(1, 0, 0));
	float4 r2 = sampler_prev_vp_matrix.t.Load(int3(2, 0, 0));
	float4 r3 = sampler_prev_vp_matrix.t.Load(int3(3, 0, 0));

	// If prev VP not injected (all zeros), output zero motion
	if (r0.x == 0 && r0.y == 0 && r0.z == 0 && r0.w == 0)
		return float2(0, 0);

	// Row-major texture data: use mul(v, M) (same convention as engine's mul(v, View_Projection))
	float4x4 prev_vp = float4x4(r0, r1, r2, r3);
	float4 prev_pos = mul(float4(world_position, 1.0f), prev_vp);
	float2 curr_ndc = current_position.xy / current_position.w;
	float2 prev_ndc = prev_pos.xy / prev_pos.w;
	// Output in UV-space: X same sign as NDC, Y flipped (NDC Y-up → UV Y-down)
	float2 mv = (curr_ndc - prev_ndc) * float2(0.5f, -0.5f);

	// halo3-ng: first-person / camera-locked geometry (weapon + hands) DOUBLE-COUNTS camera
	// motion here — world_position follows the camera, so this returns ~the camera-motion MV
	// even though the gun is fixed on screen. That broken MV makes every screen-space consumer
	// (AO/SSGI/SSS/SSR) and the compute temporals over-reproject ON the weapon. Suppress it at
	// the SOURCE so all consumers receive a correct MV and can trust it unconditionally.
	//   - current_position.w IS view-space depth in BLAM's reverse-Z infinite-far projection
	//     (clip.w = linear view-Z), and it is the PRE-viewport value → robust to any
	//     first-person depth-range compression.
	//   - Gate on depth (weapon range) AND magnitude (only LARGE MVs) so legitimate
	//     near-geometry motion is left untouched; the per-tap depth rejection in the consumers
	//     handles disocclusions.
	// BAND (June 10 2026, widened 0.12/0.30 → 0.30/0.45): the AR forend during the walk-bob
	// animation crosses w=0.12 (visible as a green |mv.y| patch in the Shift+F7 $mv_debug
	// overlay — weapon-bob MV leaking through the partial band); a single-pose depth-stencil
	// dump (docs/research/depth-stencil-weapon-mask.md) had shown weapon w ≤ 0.09, but that
	// underestimates animated poses and larger weapons. Nearest WORLD geometry measured in the
	// same dump: w = 0.52 standing (floor at bottom screen edge ~1.55 with a level camera;
	// crouch/slopes bring it lower). smoothstep(0.30, 0.45): weapon (w<0.30) fully killed,
	// world (w>0.45) keeps its full MV — still below the 0.52 world floor. Do NOT push the
	// upper edge past ~0.5: crouched/sloped ground would lose its MV (lag-smear at the feet),
	// the original failure of the old smoothstep(2,3) band, which was 30-100× too wide.
	// KEEP IN SYNC: the compute temporals' killed-MV fallback gate (currViewZ > 0.45 in
	// temporal_reproject_ao / ssgi_temporal / sss_temporal) must equal the upper band edge,
	// else killed weapon pixels in the band get camera-reprojected → long history trails.
	mv *= smoothstep(0.30f, 0.45f, current_position.w);
	return mv;
}
#endif // ACCUM_PIXEL_HAS_MV

#endif // _MOTION_VECTORS_FX_
