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
// Phase C-2: PER-CHANNEL directional SH L1. Each RT stores the world-space incoming
// radiance direction scaled by that channel's intensity (signed xyz) + viewZ (w).
// Per-channel storage avoids the cross-colour cancellation that collapsed the earlier
// luminance-weighted mono L1 — a red bounce from one wall and a blue bounce from the
// opposite wall each keep their own direction vector instead of partial cancellation.
// Slots t24/t25/t26: t23 is owned by [ShaderRegexBindDecorPrevVP] for decorator prev_VP.
Texture2D<float4> gi_dir_r : register(t24);
Texture2D<float4> gi_dir_g : register(t25);
Texture2D<float4> gi_dir_b : register(t26);

// Phase F1a — runtime tuning knobs via 3DMigoto IniParams (t120).
// Layout:
//   IniParams[1].x = $ssgi_frame       (trace-side frame counter — not read here)
//   IniParams[4].x = $ssgi_intensity   (consumer gain multiplier, default 1.0)
//   IniParams[5].x = $ssgi_probe_strength (Phase F2 probe fill strength, default 1.0)
//   IniParams[6].x = $ssgi_albedo_boost (Phase F3 DiffuseColorBoost equiv — trace-side only)
Texture1D<float4> ssgi_iniparams : register(t120);

// Phase F2c — screen-probe gather upsample inputs. 120×68 probe grid (16×16 pixel tiles).
// Slots above the existing SSGI per-channel (t24-t26) and above the decorator prev_VP
// (t23). t27-t31 are confirmed free of the fxc PARAM_SAMPLER_2D range and the global
// engine persist set.
Texture2D<float4> ssgi_probe_L0  : register(t27);
Texture2D<float4> ssgi_probe_L1R : register(t28);
Texture2D<float4> ssgi_probe_L1G : register(t29);
Texture2D<float4> ssgi_probe_L1B : register(t30);
// Reuse Hi-Z mip 4 (120×68 R32_FLOAT) as the native probe depth — zero additional memory.
// ResourceHiZ4 is already built unconditionally every frame in [Present].
Texture2D<float>  ssgi_probe_depth : register(t31);

// halo3-ng: screen-space contact shadows (formerly composited in final_composite).
// Bound via [ShaderRegexBindAOSSGI] on the same t21+t22 pattern every consumer of this
// file emits, gated by the $s F5 toggle in d3dx.ini. R16G16B16A16_FLOAT layout
// (sss_blur.hlsl):
//   .r = shadow factor [0..1] (0 = fully shadowed, 1 = unlit by SSS at all)
//   .g = hit distance (PCSS softness source, unused at consumer)
//   .b = viewZ sentinel (0 = sky / water / unbound → skip multiply)
//   .a = unused
// Moved pre-fog so the engine's own `out_color * extinction + inscatter` equation
// handles atmospheric attenuation (matches AO/SSGI Phase 3 pattern).
Texture2D<float4> sss_buffer : register(t32);

// Stage 2' (April 23 2026) — world-space radiance cubemap probe for bent-normal
// directional ambient ("sky leak"). Written by CustomShaderCubemapAccumulate from the
// post-atmosphere HDR scene colour; 1536×256 R16G16B16A16_FLOAT with 6 faces packed
// horizontally (each 256×256, face order +X=0, -X=1, +Y=2, -Y=3, +Z=4, -Z=5 — same as
// cubemap_accumulate.hlsl). 5% blend rate → ~14-frame half-life → stable low-freq
// directional radiance signal that lags camera snaps gracefully.
//
// Motivation: the HBIL screen-space trace has a 3.5m world-space radius. In a dark
// cave with a bright 20m-distant opening, neither the per-pixel HBIL pass nor the
// 16-ray probe trace can reach the bright exterior — the space falls back to
// uniform-colour isotropic fill (grey/green wall bounce without directional
// yellow/orange sun tint). Sampling the world-space cubemap along the bent normal
// recovers that directional signal: surfaces facing the cave mouth pick up the
// exterior's stored radiance; surfaces facing away stay dark. Independent of trace
// radius and Malley cosine budget.
Texture2D<float4> cube_accum : register(t33);
#endif

// Stage 2' — DirectionToCube: mirrors cubemap_accumulate.hlsl line 70-95 so the
// packed-face lookup stays consistent between writer and reader. Face order and
// UV conventions must match cubemap_accumulate exactly; changing either requires
// updating both sites.
#ifndef HALOGRAM_SHADER
void _AO_DirectionToCube(float3 dir, out int face, out float2 cubeUV)
{
    float3 absDir = abs(dir);

    if (absDir.x >= absDir.y && absDir.x >= absDir.z)
    {
        face = (dir.x > 0.0f) ? 0 : 1;
        float invAbs = 1.0f / max(absDir.x, 1e-6f);
        cubeUV = float2(-sign(dir.x) * dir.z, -dir.y) * invAbs * 0.5f + 0.5f;
    }
    else if (absDir.y >= absDir.x && absDir.y >= absDir.z)
    {
        face = (dir.y > 0.0f) ? 2 : 3;
        float invAbs = 1.0f / max(absDir.y, 1e-6f);
        cubeUV = float2(dir.x, sign(dir.y) * dir.z) * invAbs * 0.5f + 0.5f;
    }
    else
    {
        face = (dir.z > 0.0f) ? 4 : 5;
        float invAbs = 1.0f / max(absDir.z, 1e-6f);
        cubeUV = float2(sign(dir.z) * dir.x, -dir.y) * invAbs * 0.5f + 0.5f;
    }
}

// Sample the packed 1536×256 cube accumulator along a world-space direction.
// Returns post-atmosphere post-exposure HDR radiance (same space as gi_color).
float3 _AO_SampleCubeAccum(float3 worldDir)
{
    int    face;
    float2 cubeUV;
    _AO_DirectionToCube(worldDir, face, cubeUV);

    const int cube_face_size = 256;
    int2 texel = int2(face * cube_face_size + int(cubeUV.x * (cube_face_size - 1)),
                                                 int(cubeUV.y * (cube_face_size - 1)));
    texel = clamp(texel, int2(0, 0), int2(1535, 255));
    return cube_accum.Load(int3(texel, 0)).rgb;
}
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
    // Phase C-2: per-channel L1 — 4 bilinear taps × 3 channels. Share bilinear/depth
    // weights with L0 (same pixels, same depth rejection).
    float3 gdr00 = gi_dir_r.Load(int3(pix00 + int2(0, 0), 0)).rgb;
    float3 gdr10 = gi_dir_r.Load(int3(pix00 + int2(1, 0), 0)).rgb;
    float3 gdr01 = gi_dir_r.Load(int3(pix00 + int2(0, 1), 0)).rgb;
    float3 gdr11 = gi_dir_r.Load(int3(pix00 + int2(1, 1), 0)).rgb;
    float3 gdg00 = gi_dir_g.Load(int3(pix00 + int2(0, 0), 0)).rgb;
    float3 gdg10 = gi_dir_g.Load(int3(pix00 + int2(1, 0), 0)).rgb;
    float3 gdg01 = gi_dir_g.Load(int3(pix00 + int2(0, 1), 0)).rgb;
    float3 gdg11 = gi_dir_g.Load(int3(pix00 + int2(1, 1), 0)).rgb;
    float3 gdb00 = gi_dir_b.Load(int3(pix00 + int2(0, 0), 0)).rgb;
    float3 gdb10 = gi_dir_b.Load(int3(pix00 + int2(1, 0), 0)).rgb;
    float3 gdb01 = gi_dir_b.Load(int3(pix00 + int2(0, 1), 0)).rgb;
    float3 gdb11 = gi_dir_b.Load(int3(pix00 + int2(1, 1), 0)).rgb;

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
    float3 l1_r, l1_g, l1_b;
    if (wsum < 1e-4f)
    {
        // All neighbors rejected (disocclusion or full sky). Neutral fallback: AO=1, GI=0.
        ao_s = float4(0.0f, 0.0f, 1.0f, 0.001f);
        gi_s = float4(0.0f, 0.0f, 0.0f, 0.001f);
        l1_r = float3(0.0f, 0.0f, 0.0f);
        l1_g = float3(0.0f, 0.0f, 0.0f);
        l1_b = float3(0.0f, 0.0f, 0.0f);
    }
    else
    {
        float inv_w = 1.0f / wsum;
        ao_s = (ao00 * w.x + ao10 * w.y + ao01 * w.z + ao11 * w.w) * inv_w;
        gi_s = (gi00 * w.x + gi10 * w.y + gi01 * w.z + gi11 * w.w) * inv_w;
        l1_r = (gdr00 * w.x + gdr10 * w.y + gdr01 * w.z + gdr11 * w.w) * inv_w;
        l1_g = (gdg00 * w.x + gdg10 * w.y + gdg01 * w.z + gdg11 * w.w) * inv_w;
        l1_b = (gdb00 * w.x + gdb10 * w.y + gdb01 * w.z + gdb11 * w.w) * inv_w;
    }

    float ao_viewZ = ao_s.a;
    float ao       = (ao_viewZ > 0.001f) ? saturate(ao_s.b) : 1.0f;
    float ao_effective = ao;

    // Bent-normal decode (DecodeOct, Cigolle 2014). Hoisted out of the cavity-kick
    // block so Stage 2' sky-leak sampling below can reuse the same vector without
    // a second decode. WORLD SPACE — matches test_ao_gradient.hlsl line 339
    // (bentNormal_ws = ViewCSToWorldNormal(bentNormal_vs) → octahedral encode).
    float3 bentN_ws = float3(0.0f, 0.0f, 1.0f);  // neutral fallback on sky sentinel
    bool   have_bentN = false;
    if (ao_viewZ > 0.001f)
    {
        float2 e = ao_s.rg;
        bentN_ws = float3(e.x, e.y, 1.0f - abs(e.x) - abs(e.y));
        float oct_t = saturate(-bentN_ws.z);
        bentN_ws.x += (bentN_ws.x >= 0.0f ? -oct_t : oct_t);
        bentN_ws.y += (bentN_ws.y >= 0.0f ? -oct_t : oct_t);
        float bn_len2 = dot(bentN_ws, bentN_ws);
        if (bn_len2 > 1e-4f)
        {
            bentN_ws = bentN_ws * rsqrt(bn_len2);
            have_bentN = true;
        }
    }

    // Bent-normal cavity kick against local surface normal (AO tilt boost for
    // convex-facing surfaces; retained from Phase 3).
    if (have_bentN)
    {
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

    // -------------------------------------------------------------------------
    // SSS pre-fog: direct-light contact shadow on diffuse only.
    //
    // Moved here from final_composite to fix two bugs in the old placement:
    //   1. Post-composite multiply darkened inscatter (an atmospheric term a
    //      surface contact shadow physically cannot occlude) → "pasted-on"
    //      shadows in hazy / fogged zones.
    //   2. Fog fade used sss_viewZ as a proxy for Rayleigh+Mie extinction —
    //      diverges from the real atmosphere.fx world-distance equation in
    //      varied terrain.
    //
    // Applying the multiply pre-fog lets the engine's own
    // `out_color * extinction + inscatter` equation handle atmospheric
    // attenuation for SSS, identical to how it already handles AO and SSGI.
    //
    // reproj_uv already computed at line 96 (curr_uv - mv_used); reuse it.
    // Decorators pass motion_vector=0 → reproj_uv == curr_uv (exact pixel) —
    // acceptable at SSS's 1m contact radius.
    //
    // Placement:
    //   · AFTER AO — both gate diffuse; AO = ambient occlusion, SSS = direct
    //   · BEFORE SSGI add — SSS must not darken bounce light
    //   · Floor 0.05 = deepest allowed contact shadow; matches previous
    //     final_composite floor so perceptual strength is unchanged.
    // -------------------------------------------------------------------------
    // Stage B of the April 24 2026 SSS stability pass: manual 4-tap bilinear on the
    // reprojected UV. The previous integer-Load snapped each reproj_uv to its floor pixel,
    // so fractional MV motion would "snap and hold" the shadow onto whichever pixel-centre
    // reproj_uv happened to fall nearest. At 1px subsampling the snap is visible as shadow
    // edges that step-and-hold under rotation. Bilinear interpolation between the 4 neighbours
    // gives sub-pixel continuous motion that reads as smooth shadow drift instead of stepping.
    //
    // Manual bilinear (vs SampleLevel + SamplerState) avoids plumbing a sampler slot through
    // 3DMigoto. Cost = 4 Loads + a few lerps on a single sample site — negligible.
    //
    // Sky-sentinel handling: neighbours with viewZ==0 (sky / unbound) would otherwise bleed
    // shadow=1.0 (fully lit) into shadowed pixels at silhouette edges. That's harmless for
    // contact shadows (it can only brighten, never darken beyond the 0.05 floor), so no
    // per-tap reject is needed — the simple bilerp is correct.
    // NOTE: this function's outer scope declares `float2 frac` at line 178 (bilateral-bilinear
    // for ao_ssgi_buffer / gi_buffer). That shadows the HLSL intrinsic `frac()`, so we compute
    // the fractional part manually here as `texel_pos - floor(texel_pos)`. Renaming the
    // locals with an `sss_` prefix to keep them disjoint from anything in outer scope.
    {
        const float2 sss_viewport_px = float2(1920.0f, 1080.0f);
        float2 sss_uv        = clamp(reproj_uv, float2(0, 0), float2(1, 1));
        float2 sss_texel_pos = sss_uv * sss_viewport_px - 0.5f;
        float2 sss_floor     = floor(sss_texel_pos);
        float2 sss_frac      = sss_texel_pos - sss_floor;
        int2   sss_base      = clamp(int2(sss_floor), int2(0, 0), int2(1918, 1078));

        float4 s00 = sss_buffer.Load(int3(sss_base, 0));
        float4 s10 = sss_buffer.Load(int3(sss_base + int2(1, 0), 0));
        float4 s01 = sss_buffer.Load(int3(sss_base + int2(0, 1), 0));
        float4 s11 = sss_buffer.Load(int3(sss_base + int2(1, 1), 0));

        float4 sss_data = lerp(lerp(s00, s10, sss_frac.x),
                               lerp(s01, s11, sss_frac.x),
                               sss_frac.y);

        if (sss_data.b > 0.001f)                        // viewZ sentinel — skip sky/unbound
            diffuse_color *= max(sss_data.r, 0.05f);
    }

    // SSGI indirect: AO-gated, receiver-weighted, albedo-detail modulated.
    // Engine fog (out_color * extinction + inscatter) attenuates GI downstream.
    //
    // Phase C-2 — per-channel clamped-cosine SH reconstruction (Ramamoorthi/Hanrahan form,
    // evaluated independently per RGB channel):
    //
    //     I_c(N) = max(0, L0_c + k · dot(L1_c, N))
    //
    // L1_c is the world-space incoming-radiance direction × channel_intensity. The analytic
    // SH coefficient for clamped-cosine two-band irradiance is √3/2 ≈ 0.866, but HBIL's
    // hemispheric undersampling shrinks the L1 magnitude relative to a Monte Carlo ground
    // truth — empirical k_dir = 1.8 restores the intended directional contrast. No gate:
    // when L1 is near-zero (isotropic field) the formula degenerates smoothly to L0, no
    // cliff. When L1 is strong (e.g. one wall lit red), it adds on the facing side and
    // the clamp prevents negative contribution on the back side.
    //
    // Safe fallback: if gi_dir_r/g/b are unbound or zero, l1_* = 0 → per-channel term = L0_c
    // → same as the isotropic path.
    float3 N_ws;
    float  sn_len2 = dot(surface_normal, surface_normal);
    if (sn_len2 > 0.01f) N_ws = surface_normal * rsqrt(sn_len2);
    else                 N_ws = float3(0.0f, 0.0f, 1.0f);

    // Analytic clamped-cosine SH L1 coefficient is √3/2 ≈ 0.866. Probe path uses
    // proper 16-ray Malley cosine sampling — no HBIL undersampling factor needed.
    // (The old 2.4 was a multiplier that over-amplified peak-facing-wall directional
    // bounce by ~2.7×, contributing to the "bounce ≈ direct" brightness issue.)
    static const float k_dir = 0.9f;
    float3 gi_color;
    gi_color.r = max(0.0f, gi_s.r + k_dir * dot(l1_r, N_ws));
    gi_color.g = max(0.0f, gi_s.g + k_dir * dot(l1_g, N_ws));
    gi_color.b = max(0.0f, gi_s.b + k_dir * dot(l1_b, N_ws));

    // -------------------------------------------------------------------------
    // Stage 2' (April 23 2026) — Bent-normal directional ambient ("sky leak").
    //
    // Samples ResourceCubeAccum (the post-atmosphere world-space radiance probe
    // accumulated from the HDR scene colour each frame, including sky pixels
    // after the April 23 accumulator fix) along the per-pixel bent normal.
    // Addresses a structural gap in the SSGI pipeline:
    //
    //   · HBIL trace has a 3.5m radius; a dark cave with a 20m-distant bright
    //     opening never sees the exterior radiance.
    //   · Probe trace with 16 Malley cosine rays over a 16×16-pixel tile has
    //     a vanishingly small probability of hitting a small-angular-size hot
    //     region — it falls back to the same cubemap as a DC term, losing
    //     all directionality.
    //
    // The bent normal (Cigolle 2014, written by test_ao_gradient.hlsl in
    // WORLD SPACE) points toward the most-open direction of the visible
    // hemisphere — i.e. toward where light can physically arrive. Sampling
    // the world cubemap along that direction gives the colour that the
    // visible-but-off-bounce-radius bright source is painting onto this
    // surface. `visibility` = saturate(dot(bentN, N)) weights the term by
    // how strongly the bent normal agrees with the surface normal (grazing
    // tilt → small contribution; facing-the-opening → full contribution).
    //
    // Deferred application — we STAGE sky_contrib here (bent normal + ao_s
    // are in scope) but add it to diffuse_color AFTER the envelope clamp
    // below. Reasons:
    //   1. The envelope clamp was designed to cap single-ray HBIL fireflies;
    //      sky-leak is cached DC irradiance (not a stochastic hit) and
    //      shouldn't be subject to the same runaway-prevention budget.
    //   2. In dark-receiver scenarios (diffuse_color ≈ 0.1, e.g. a cave wall
    //      that only gets faint engine SH ambient) the envelope ceiling
    //      collapses to ≈ 0.23 and would clip any meaningful sky-leak; but
    //      those are exactly the pixels that should benefit most from the
    //      directional term.
    //   3. `hot_relax` evaluates gi_raw_lum *after* the Lambertian albedo
    //      multiply, which crushes even a bright sky_rgb (~2-3 post-exposure)
    //      down to ~0.3 — so sky-leak never triggers the 10× env_scale and
    //      gets clamped at the 2× ambient budget instead.
    //
    // No more `openness = ao` gate — ao_multi at the Lambertian multiply
    // already handles the cavity occlusion uniformly across all GI terms.
    // Gating here would be a double-count: ao applied once explicitly, then
    // again through ao_multi below. The deferred multiply by (albedo_color
    // * ao_multi) is what converts sky_rgb from "incoming radiance" to
    // "outgoing diffuse" in the BRDF sense.
    //
    // The strength is gated by $ssgi_sky_leak_strength (F5). Default 1.0.
    // -------------------------------------------------------------------------
    float  g_SSGISkyLeakStrength = max(ssgi_iniparams.Load(int2(2, 0)).x, 0.0f);
    float3 sky_contrib = float3(0.0f, 0.0f, 0.0f);
    if (g_SSGISkyLeakStrength > 0.001f && have_bentN && ao_viewZ > 0.001f)
    {
        float  visibility = saturate(dot(bentN_ws, N_ws));
        float3 sky_rgb    = _AO_SampleCubeAccum(bentN_ws);
        sky_contrib       = sky_rgb * (visibility * g_SSGISkyLeakStrength);
    }

    // -------------------------------------------------------------------------
    // S2 — Pixel-rate temporal GI sample.
    //
    // ssgi_probe_L0/L1R/L1G/L1B are now full-resolution (1920×1080)
    // MV-reprojected + EMA-accumulated buffers produced by
    // ssgi_pixel_temporal.hlsl at [Present]. All the heavy lifting
    // (Hammersley unjitter, 3×3 Gaussian probe gather, depth bilateral,
    // frame-count EMA, camera-move reset) lives there; the consumer just
    // does a 2×2 bilinear bilateral tap at the MV-reprojected UV.
    //
    // Weights are reused from the HBIL path above — both buffers are at the
    // same resolution and share the same MV reprojection, so their viewZ
    // bilateral is identical. wsum / w / pix00 / inv_w are already in scope.
    // -------------------------------------------------------------------------
    float g_SSGIProbeStrength = max(ssgi_iniparams.Load(int2(5, 0)).x, 0.0f);
    if (g_SSGIProbeStrength > 0.001f && wsum >= 1e-4f)
    {
        float inv_w = 1.0f / wsum;

        float4 pL0_00 = ssgi_probe_L0.Load(int3(pix00 + int2(0, 0), 0));
        float4 pL0_10 = ssgi_probe_L0.Load(int3(pix00 + int2(1, 0), 0));
        float4 pL0_01 = ssgi_probe_L0.Load(int3(pix00 + int2(0, 1), 0));
        float4 pL0_11 = ssgi_probe_L0.Load(int3(pix00 + int2(1, 1), 0));
        float3 pL1r_00 = ssgi_probe_L1R.Load(int3(pix00 + int2(0, 0), 0)).rgb;
        float3 pL1r_10 = ssgi_probe_L1R.Load(int3(pix00 + int2(1, 0), 0)).rgb;
        float3 pL1r_01 = ssgi_probe_L1R.Load(int3(pix00 + int2(0, 1), 0)).rgb;
        float3 pL1r_11 = ssgi_probe_L1R.Load(int3(pix00 + int2(1, 1), 0)).rgb;
        float3 pL1g_00 = ssgi_probe_L1G.Load(int3(pix00 + int2(0, 0), 0)).rgb;
        float3 pL1g_10 = ssgi_probe_L1G.Load(int3(pix00 + int2(1, 0), 0)).rgb;
        float3 pL1g_01 = ssgi_probe_L1G.Load(int3(pix00 + int2(0, 1), 0)).rgb;
        float3 pL1g_11 = ssgi_probe_L1G.Load(int3(pix00 + int2(1, 1), 0)).rgb;
        float3 pL1b_00 = ssgi_probe_L1B.Load(int3(pix00 + int2(0, 0), 0)).rgb;
        float3 pL1b_10 = ssgi_probe_L1B.Load(int3(pix00 + int2(1, 0), 0)).rgb;
        float3 pL1b_01 = ssgi_probe_L1B.Load(int3(pix00 + int2(0, 1), 0)).rgb;
        float3 pL1b_11 = ssgi_probe_L1B.Load(int3(pix00 + int2(1, 1), 0)).rgb;

        float3 pL0  = (pL0_00.rgb * w.x + pL0_10.rgb * w.y + pL0_01.rgb * w.z + pL0_11.rgb * w.w) * inv_w;
        float3 pL1r = (pL1r_00    * w.x + pL1r_10    * w.y + pL1r_01    * w.z + pL1r_11    * w.w) * inv_w;
        float3 pL1g = (pL1g_00    * w.x + pL1g_10    * w.y + pL1g_01    * w.z + pL1g_11    * w.w) * inv_w;
        float3 pL1b = (pL1b_00    * w.x + pL1b_10    * w.y + pL1b_01    * w.z + pL1b_11    * w.w) * inv_w;

        float3 probeGI;
        probeGI.r = max(0.0f, pL0.r + k_dir * dot(pL1r, N_ws));
        probeGI.g = max(0.0f, pL0.g + k_dir * dot(pL1g, N_ws));
        probeGI.b = max(0.0f, pL0.b + k_dir * dot(pL1b, N_ws));
        probeGI *= g_SSGIProbeStrength;

        // Additive layering — HBIL sharp contact bounce + probe low-freq fill.
        // Envelope clamp below caps runaway; dark receivers get full probe fill.
        gi_color += probeGI;
    }

    // Saturation boost — Halo 3 diffuse albedos are aggressively desaturated (2007 engine
    // with painted-in ambient and no energy-conserving BRDF). Bouncing low-chroma light
    // yields low-chroma GI no matter how strong the math. Expand chromaticity on the GI
    // term only (not applied to direct lighting) to recover perceptual saturation.
    // 1.8 → 1.3 → 1.1: now that the Lambertian albedo multiply (below) does the real
    // chromaticity work via the BRDF, this extra lift only needs to nudge the low-chroma
    // Halo 3 palette. 1.1 is a gentle boost that doesn't fight the physical tint.
    static const float gi_saturation = 1.1f;
    float  gi_lum = dot(gi_color, float3(0.2126f, 0.7152f, 0.0722f));
    gi_color = lerp(gi_lum.xxx, gi_color, gi_saturation);
    gi_color = max(gi_color, 0.0f);

    // ------------------------------------------------------------------------
    // Luminance contrast lift (Phase F1c — consumer-side, fast-iteration stub)
    // ------------------------------------------------------------------------
    // Problem: with a uniform gain, the RATIO between bright-source bounce and
    // dim-source bounce stays flat. Scenes read "uniformly weak" — sun-lit walls
    // don't punch proportionally harder than ambient clutter. User asked for
    // a non-linear response where bright emitters lift more than dim ones.
    //
    // Not a gamma (pow>1 pushes dim values *further* down — opposite of goal).
    // A smoothstep-gated gain on luminance keeps dim bounce untouched and lifts
    // brights by up to `boost×`. Curve shape with defaults below:
    //   lum ≤ knee        → output = input         (no lift)
    //   lum ∈ (knee,full) → output = input × (1 + smoothstep() × boost)
    //   lum ≥ full        → output = input × (1 + boost)
    //
    // Why BEFORE the scale: `knee`/`full` are in raw reconstructed-SH luminance
    // space (scene-intrinsic brightness), decoupled from the F6 intensity knob.
    // With lift first, scale later, the F6 knob uniformly amplifies the post-lift
    // signal — preserving the curve's "bright disproportionately bright" shape
    // across all F6 positions. Lift-after-scale would push the signal through
    // the knee at low F6, collapsing the curve.
    //
    // Consumer-side (NOT trace-side) — blunt: can't distinguish "one bright
    // sample" vs "sum of dim samples averaging to mid-lum" because it sees
    // only the reconstructed aggregate. If tuning here feels right, copy the
    // same curve per-sample into ssgi_probe_trace.hlsl (at the HDR fetch,
    // before SH accumulation) — that version will also lift SH L1 directional
    // toward bright emitters correctly.
    //
    // Starting values (walk from here):
    //   knee=0.3, full=1.2, boost=3.0  — "sun-lit walls 4× lifted"
    //   knee down (0.2, 0.15) if dim feels flat; up (0.4) if too much cavity glow.
    //   boost up (5, 7) if sun-lit surfaces still don't punch.
    // Lumen-plan Stage 1: primary per-sample lift now lands inside the trace
    // (ssgi_trace.hlsl + ssgi_probe_trace.hlsl). Consumer-side boost dropped
    // 3.0 → 1.0 so we don't double-dip: trace lifts a 1-of-32 hot ray from
    // (1*15 + 31*0.3)/32 ≈ 0.76 to ≈ 2.16 mean; the 1.0 consumer tap then
    // adds a gentle final touch instead of re-shaping the curve. If Stage 1
    // in-game test shows post-trace GI looks flat, try raising this back to
    // 1.5–2.0 before touching the trace-side knee/full/boost.
    static const float gi_lift_knee  = 0.3f;
    static const float gi_lift_full  = 1.2f;
    static const float gi_lift_boost = 1.0f;
    {
        float gi_lift_lum = dot(gi_color, float3(0.2126f, 0.7152f, 0.0722f));
        float gi_lift_t   = smoothstep(gi_lift_knee, gi_lift_full, gi_lift_lum);
        gi_color *= (1.0f + gi_lift_t * gi_lift_boost);
    }

    // Consumer gain — 0.5 → 0.8 to compensate for higher dynamic range after the
    // lift above (dim bounce sits at the same level as before; bright bounce is
    // now ~4× what it was at the 0.5 scale, so overall scene average moves up
    // modestly). 0.8 lets the F6 $ssgi_intensity knob still nudge up to ~1.0×
    // on sunlit scenes without re-tuning the lift knee/full/boost.
    //
    // Phase F1a — $ssgi_intensity runtime knob (Lumen IndirectLightingIntensity equivalent).
    // Default 1.0 → net 0.8× intrinsic. F6 cycles [0.5, 1.0, 1.5, 2.0, 3.0] for A/B tuning.
    // max() guards against accidental negative / NaN from an unbound IniParams slot.
    float g_SSGIIntensity = max(ssgi_iniparams.Load(int2(4, 0)).x, 0.0f);
    gi_color *= 0.8f * g_SSGIIntensity;

    // Lambertian BRDF integration — multiply the incoming indirect irradiance
    // `gi_color` by the receiver albedo to get outgoing diffuse radiance. This
    // is the same `× albedo` the engine applies to direct lighting (simple_lights
    // and SH ambient both go through `diffuse_radiance * albedo` in the caller).
    // GI now behaves as an integrated term in the radiance equation rather than
    // a separate "layer painted on top":
    //
    //     L_out = albedo × (E_direct + E_indirect) × AO
    //           = (direct · albedo · AO)   +   (gi_color · albedo · AO)
    //             └── diffuse_color here ──┘   └──── gi_contrib ─────┘
    //
    // Replaces the earlier luminance-proxy chain (receiverWeight, albedoDetail,
    // 40% chromaticity lerp) which approximated this multiply badly:
    //   · black albedo + bright direct got a receiver-luminance-driven wash that
    //     read as glow on non-bouncing materials;
    //   · white albedo in shadow was starved because receiver-luminance was low
    //     even though the surface is exactly the kind that bounces most.
    // The engine is mixed π-convention (SH /π, simple lights no /π), and so is
    // g_HDRScene that the trace reads, so we match the simple-light convention
    // (no explicit /π here). Any residual scale mismatch is absorbed by
    // `$ssgi_intensity` (F6) and the envelope clamp below.
    float3 gi_contrib = gi_color * albedo_color * ao_multi;

    // Physical envelope clamp: a diffuse bounce cannot exceed a bounded multiple of the
    // receiver's direct-light level (the light that's already on the surface). Caps the
    // foliage-glow pathological case while preserving legitimate strong bounce into dark
    // receivers — the floor keeps the clamp from collapsing to zero where direct
    // light is near-zero (deep shadow receiving a red-wall bounce still reads correctly).
    //
    // The 0.25 floor (Lumen SkylightLeaking analogue) is gated by `ao_multi` — an
    // ungated constant floor flattens AO contrast in heavily-shadowed regions
    // (adjacent pixels with different AO all clamp to the same 0.25 ceiling →
    // local AO / detail appear "removed"). Lumen's real SkylightLeaking is also
    // AO-attenuated in the SSAO-gated path; matching that behaviour here.
    //
    // Phase F1b — loosened 2.0/0.05 → 3.0/0.25. Without the AO gate below, heavy-
    // shadow corners pinned at the constant 0.25 floor swamped direct lighting
    // variation → AO/detail wash. AO-gated floor preserves per-pixel AO contrast:
    // ao_multi ≈ 0.1 → effective floor ≈ 0.025 (barely any fill), ao_multi ≈ 0.9
    // → effective floor ≈ 0.225 (full fill).
    //
    // Brightness pass — tightened 3.0/0.25 → 1.0/0.1. The old 3.0× ceiling allowed
    // bounce to legally reach 3× direct which is physically impossible — it let the
    // 3.5×/2.4 consumer gain silently pass through on bright receivers. 1.0× is the
    // physical ceiling (single-bounce can never exceed direct in energy terms). The
    // 0.1 AO-gated floor still provides skylight leak on dark-receiver cavities.
    //
    // Phase F1c — ceiling 1.0 → 2.0 to let the contrast lift above land on dim-direct
    // receivers (dark wall next to a sun-lit wall is exactly where indirect bounce
    // should visibly dominate direct — the 1.0× clamp was crushing that case). 2.0
    // is a "bounce may briefly exceed direct by up to 2×" budget; still well short
    // of the old 3.0× ceiling.
    //
    // Pass 2 (April 23 2026) — flat 2× envelope was the primary reason small hot
    // emitters looked flat: a plasma bounce with gi_contrib ≈ 15 units onto a dim
    // receiver (diffuse_color = 0.4) was clamped to 0.88 — losing ~94% of the
    // emitter's real bounce energy. Hybrid "hot-relax" envelope keeps the 2×
    // ceiling for ambient bounce (lum < ~1 — the case that was over-bouncing on
    // low-albedo walls in Pass 1's absence) but smoothly lifts to 10× for
    // emitter-bright samples so the plasma / panel hit lands visibly.
    //
    //   gi_raw_lum ≈ 0.5   → hot_relax ≈ 0   → env_scale = 2×   (ambient-safe)
    //   gi_raw_lum ≈ 2.0   → hot_relax ≈ 0.5 → env_scale = 6×   (mid-bright)
    //   gi_raw_lum ≥ 3.0   → hot_relax  = 1   → env_scale = 10× (emitter)
    //
    // Paired with Pass 1's narrower lift knee (trace-side) so that ambient
    // bounce stays quiet while emitter bounce is both pre-lifted AND allowed
    // to land unclamped at the consumer.
    float gi_raw_lum = dot(gi_contrib, float3(0.2126f, 0.7152f, 0.0722f));
    float hot_relax  = saturate((gi_raw_lum - 1.0f) * 0.5f);
    float env_scale  = lerp(2.0f, 10.0f, hot_relax);
    float3 envelope  = diffuse_color * env_scale + 0.1f * ao_multi;
    gi_contrib = min(gi_contrib, envelope);
    diffuse_color += gi_contrib;

    // -------------------------------------------------------------------------
    // Stage 2' — Bent-normal sky-leak, applied AFTER the envelope clamp.
    //
    // sky_contrib was STAGED above (pre-Lambertian) with bent-normal visibility
    // weighting but held out of the envelope-clamped gi_contrib for the three
    // reasons documented at the stage site:
    //   1. Envelope was designed to cap HBIL single-ray fireflies; sky-leak is
    //      a cached DC irradiance tap and shouldn't be subject to that budget.
    //   2. Dark-receiver envelope collapses to ~0.23, clipping exactly the
    //      cases (cave walls / back rooms) where directional sky-leak is meant
    //      to be the strongest contributor.
    //   3. hot_relax evaluates on gi_raw_lum (already-Lambertian gi_contrib),
    //      which crushes bright sky_rgb below the 10× hot threshold so sky
    //      emitters never escape the 2× ambient clamp.
    //
    // Apply Lambertian BRDF integration here — multiply by albedo_color and
    // ao_multi so the term behaves as outgoing diffuse radiance consistent
    // with the main gi_contrib path. Scale by g_SSGIIntensity so the F6
    // master knob also governs sky-leak (sky-leak has its own F5 sub-knob
    // for A/B tuning via g_SSGISkyLeakStrength baked into sky_contrib).
    diffuse_color += sky_contrib * albedo_color * ao_multi * g_SSGIIntensity;
#endif  // HALOGRAM_SHADER
}

#endif
