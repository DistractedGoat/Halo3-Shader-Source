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
	return (curr_ndc - prev_ndc) * float2(0.5f, -0.5f);
}
#endif // ACCUM_PIXEL_HAS_MV

#endif // _MOTION_VECTORS_FX_
