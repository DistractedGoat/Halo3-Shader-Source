#ifndef _AO_SSGI_INLINE_FX_
#define _AO_SSGI_INLINE_FX_

// halo3-ng: forward-integrated AO/SSGI inputs (bound via [ShaderRegexBindAOSSGI] in d3dx.ini).
// ao_ssgi_buffer: .rg=oct(bentN_ws) .b=AO .a=viewZ (sentinel: a<=0 -> sky/uninitialised -> AO=1)
// gi_buffer:      .rgb=GI (pre-exposure) .a=viewZ
// Slots t21/t22 — chosen above all known allocations:
//   t0-~t10  : fxc auto-allocated PARAM_SAMPLER_2D (material samplers + cubes)
//   t13-t18  : engine globals (hlsl_constant_persist.fx: lightprobe, dom_light, scene_ldr, albedo, normal, depth)
//   t19-t20  : SSR (ssr_direct, prev_vp_direct — water_shading.fx, bound via ShaderRegexWaterSSR)
// Previous t7/t8 caused 124/859 shader_templates to fail compilation on sampler-heavy perms
// (calc_bumpmap_detail_ps + cook_torrance + dynamic envmap auto-allocated past t6 into our slots).
//
// HALOGRAM_SHADER guard: halograms are volumetric/additive (not scene geometry) and don't
// receive AO/GI. The texture decls + function body compile away entirely, avoiding any
// register collisions with halogram's sampler allocation.
#ifndef HALOGRAM_SHADER
Texture2D<float4> ao_ssgi_buffer : register(t21);
Texture2D<float4> gi_buffer      : register(t22);
#endif

// Applies AO/SSGI inline to the running diffuse color.
// Specular/envmap/self_illum should be added AFTER this call — AO/SSGI only gates diffuse.
// Call sites must invoke this PRE-fog (before out_color * extinction + inscatter). Engine
// fog naturally attenuates AO/GI at distance — no internal fog-fade needed.
//
//   diffuse_color    : inout diffuse contribution so far (pre-specular/envmap/self_illum)
//   albedo_color     : linear albedo for Patapom multi-bounce tint + receiver detail
//   surface_normal   : per-pixel bump normal (any magnitude; internally renormalized)
//   fragment_position: pixel-space coordinate (SV_Position.xy) for screen-space buffer sample
//   motion_vector    : per-pixel MV in normalized-UV units (same as SV_Target2 content).
//                      Used to reproject current-frame fragment_position back to the UV
//                      where the AO/SSGI compute wrote this frame's data (compute runs at
//                      [Present] of the previous forward pass). prevUV = currUV - MV.
//                      Pass float2(0,0) for surfaces with no real motion (e.g. decorators,
//                      or when ACCUM_PIXEL_HAS_MV is not defined) — no reprojection.
//   raw_depth        : SV_Position.z (raw [0..1] reverse-Z) — linearized to viewZ and used
//                      as bilateral weight against ao_s.a / gi_s.a (prev-frame viewZ) to
//                      reject disoccluded neighbors (weapon/background silhouettes).
void apply_ao_ssgi_inline(
    inout float3 diffuse_color,
    in float3 albedo_color,
    in float3 surface_normal,
    in float2 fragment_position,
    in float2 motion_vector,
    in float  raw_depth)
{
#ifdef HALOGRAM_SHADER
    // No-op for halograms: volumetric/additive surfaces don't receive screen-space AO/GI.
    return;
#else
    // Reproject current-frame pixel back to the UV where the compute pass wrote AO/SSGI
    // (that pass references the *previous* forward-pass geometry, so MV from the current
    // forward pass brings us to the matching sample).
    //
    // Broken-MV guard: first-person hands/weapons double-count camera motion in
    // compute_motion_vector (world_pos follows camera), producing absurdly large MVs that
    // overshoot the reprojection. Fade to no-reprojection as |mv| grows past ~0.02 UV
    // (~38 px at 1080p). Below that threshold, legitimate fast-pan dynamic motion passes
    // through unaltered. Depth-reject below catches residual wrong-direction cases.
    float  mv_len_sq = dot(motion_vector, motion_vector);
    float  mv_scale  = 1.0f - saturate((mv_len_sq - 0.0004f) / 0.0005f);
    float2 mv_used   = motion_vector * mv_scale;

    const float2 viewport_size = float2(1920.0f, 1080.0f);
    float2 curr_uv    = (fragment_position + float2(0.5f, 0.5f)) / viewport_size;
    float2 reproj_uv  = curr_uv - mv_used;

    // Bilateral bilinear tap (4 Loads, depth-weighted). Integer-snap Load() snaps
    // fractional reproj_uv to the nearest pixel → per-frame stutter; manual bilinear kills
    // the judder. Weights combine fractional bilinear with depth similarity against
    // current-fragment viewZ, naturally rejecting disoccluded neighbors.
    float2 reproj_pix_f = reproj_uv * viewport_size - 0.5f;
    float2 pix_floor    = floor(reproj_pix_f);
    float2 frac         = saturate(reproj_pix_f - pix_floor);
    int2   pix00        = clamp(int2(pix_floor), int2(0, 0), int2(viewport_size) - 2);

    float4 ao00 = ao_ssgi_buffer.Load(int3(pix00 + int2(0, 0), 0));
    float4 ao10 = ao_ssgi_buffer.Load(int3(pix00 + int2(1, 0), 0));
    float4 ao01 = ao_ssgi_buffer.Load(int3(pix00 + int2(0, 1), 0));
    float4 ao11 = ao_ssgi_buffer.Load(int3(pix00 + int2(1, 1), 0));
    float4 gi00 = gi_buffer.Load(int3(pix00 + int2(0, 0), 0));
    float4 gi10 = gi_buffer.Load(int3(pix00 + int2(1, 0), 0));
    float4 gi01 = gi_buffer.Load(int3(pix00 + int2(0, 1), 0));
    float4 gi11 = gi_buffer.Load(int3(pix00 + int2(1, 1), 0));

    float curr_viewZ  = 0.00781f / max(raw_depth, 1e-6f);
    float depth_scale = max(curr_viewZ * 0.1f, 0.05f);

    float4 wb;  // bilinear weights
    wb.x = (1.0f - frac.x) * (1.0f - frac.y);
    wb.y = frac.x          * (1.0f - frac.y);
    wb.z = (1.0f - frac.x) * frac.y;
    wb.w = frac.x          * frac.y;

    float4 wd;  // depth similarity (0 on sky sentinel ao.a<=0)
    wd.x = saturate(1.0f - abs(ao00.a - curr_viewZ) / depth_scale) * step(0.001f, ao00.a);
    wd.y = saturate(1.0f - abs(ao10.a - curr_viewZ) / depth_scale) * step(0.001f, ao10.a);
    wd.z = saturate(1.0f - abs(ao01.a - curr_viewZ) / depth_scale) * step(0.001f, ao01.a);
    wd.w = saturate(1.0f - abs(ao11.a - curr_viewZ) / depth_scale) * step(0.001f, ao11.a);

    float4 w    = wb * wd;
    float  wsum = dot(w, 1.0f.xxxx);

    float4 ao_s, gi_s;
    if (wsum < 1e-4f)
    {
        // All neighbors rejected (disocclusion or full sky). Neutral fallback: AO=1, GI=0.
        ao_s = float4(0.0f, 0.0f, 1.0f, 0.001f);
        gi_s = float4(0.0f, 0.0f, 0.0f, 0.001f);
    }
    else
    {
        float inv_w = 1.0f / wsum;
        ao_s = (ao00 * w.x + ao10 * w.y + ao01 * w.z + ao11 * w.w) * inv_w;
        gi_s = (gi00 * w.x + gi10 * w.y + gi01 * w.z + gi11 * w.w) * inv_w;
    }

    float ao_viewZ = ao_s.a;
    float ao       = (ao_viewZ > 0.001f) ? saturate(ao_s.b) : 1.0f;
    float ao_effective = ao;

    // Bent-normal cavity kick (DecodeOct, Cigolle 2014) against local surface normal.
    if (ao_viewZ > 0.001f)
    {
        float2 e = ao_s.rg;
        float3 bentN_ws = float3(e.x, e.y, 1.0f - abs(e.x) - abs(e.y));
        float  oct_t    = saturate(-bentN_ws.z);
        bentN_ws.x += (bentN_ws.x >= 0.0f ? -oct_t : oct_t);
        bentN_ws.y += (bentN_ws.y >= 0.0f ? -oct_t : oct_t);
        bentN_ws = normalize(bentN_ws);
        float nLen2 = dot(surface_normal, surface_normal);
        if (nLen2 > 0.01f)
        {
            float3 N_ws = surface_normal * rsqrt(nLen2);
            float  tilt = saturate(dot(bentN_ws, N_ws));
            float  ao_bn = lerp(0.5f, 1.0f, pow(tilt, 2.0f));
            ao_effective = saturate(ao * ao_bn);
        }
    }

    // Patapom 2018 multi-bounce per-channel AO (gamma-2 albedo approximation).
    float3 albedo_ao = albedo_color * albedo_color;
    float3 aoV  = ao_effective.xxx;
    float3 mb_a =  2.0404f * albedo_ao - 0.3324f;
    float3 mb_b = -4.7951f * albedo_ao + 0.6417f;
    float3 mb_c =  2.7552f * albedo_ao + 0.6903f;
    float3 ao_poly  = ((aoV * mb_a + mb_b) * aoV + mb_c) * aoV;
    float3 ao_multi = lerp(aoV, max(aoV, ao_poly), 0.35f);

    // AO scene multiply. Engine fog (out_color * extinction + inscatter) attenuates downstream.
    float3 ao_color = lerp(float3(0.002f, 0.002f, 0.002f), float3(1.0f, 1.0f, 1.0f), ao_multi);
    diffuse_color *= ao_color;

    // SSGI indirect: AO-gated, receiver-weighted, albedo-detail modulated.
    // Engine fog (out_color * extinction + inscatter) attenuates GI downstream.
    float3 gi_color = gi_s.rgb * 7.5f;
    float  receiverLum    = dot(diffuse_color, float3(0.2126f, 0.7152f, 0.0722f));
    float  receiverWeight = lerp(0.03f, 1.0f, pow(saturate(receiverLum * 4.0f), 1.3f));
    float  albedoLum_gi   = dot(albedo_color, float3(0.2126f, 0.7152f, 0.0722f));
    float3 albedoDetail   = clamp(albedo_color / (albedoLum_gi + 0.1f), 0.3f, 2.0f);
    float3 giReceiver     = receiverWeight * lerp(float3(1.0f, 1.0f, 1.0f), albedoDetail, 0.66f);
    diffuse_color += gi_color * giReceiver * ao_multi;
#endif  // HALOGRAM_SHADER
}

#endif
