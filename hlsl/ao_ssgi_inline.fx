#ifndef _AO_SSGI_INLINE_FX_
#define _AO_SSGI_INLINE_FX_

// halo3-ng: forward-integrated AO/SSGI inputs (bound via [ShaderRegexBindAOSSGI] in d3dx.ini).
// ao_ssgi_buffer: .rg=oct(bentN_ws) .b=AO .a=viewZ (sentinel: a<=0 -> sky/uninitialised -> AO=1)
// gi_buffer:      .rgb=GI (POST-exposure — sourced from g_HDRScene; divided by g_exposure.r
//                 at the compose site before the caller's final exposure multiply) .a=viewZ
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

// halo3-ng RESOLUTION INDEPENDENCE (Aug 2026). The render size is published to IniParams row 6
// (.y = width, .z = height) once per frame by [CustomShaderEffectChainEarly] in d3dx.ini, which
// takes it from rt_width/rt_height at the pre-pass -> forward-lighting boundary — the same place
// the effect buffers are sized from, so the consumer and the buffers can never disagree.
//
// WHY IniParams AND NOT GetDimensions() ON ONE OF OUR OWN BUFFERS: the consumer's inputs are
// CONDITIONALLY UNBOUND — ao_ssgi_buffer (t21) is nulled when AO is off (x == 0), and
// gi_buffer / ssgi_hbil_lowfreq (t22 / t34) are nulled when SSGI is off (y == 0).
// GetDimensions() on an unbound SRV returns 0, so sizing from one of those would divide by zero
// in exactly the effects-off A/B path (F4 / F11 / Ctrl+F11) — it would break the comparison mode
// used to judge every change. t120 is 3DMigoto's reserved slot and is bound on every draw.
//
// FALLBACK: with no 3DMigoto at all (or before the first publish) t120 is unbound, Load() returns
// 0, and the guard drops to 1920x1080 — the exact pre-Aug-2026 behaviour.
float2 get_viewport_size()
{
    float2 vp = ssgi_iniparams.Load(int2(6, 0)).yz;
    return (vp.x < 16.0f || vp.y < 16.0f) ? float2(1920.0f, 1080.0f) : vp;
}

// Phase F2c — screen-probe gather upsample inputs. 120×68 probe grid (16×16 pixel tiles).
// Slots above the existing SSGI per-channel (t24-t26) and above the decorator prev_VP
// (t23). t27-t31 are confirmed free of the fxc PARAM_SAMPLER_2D range and the global
// engine persist set.
Texture2D<float4> ssgi_probe_L0  : register(t27);
Texture2D<float4> ssgi_probe_L1R : register(t28);
Texture2D<float4> ssgi_probe_L1G : register(t29);
Texture2D<float4> ssgi_probe_L1B : register(t30);
// Disocclusion-halo pass (June 2026): t31 REPURPOSED. Was ssgi_probe_depth (ResourceHiZ4)
// — declared but never sampled since the S2 pixel-temporal consumer. Now the wide
// depth-aware low-pass of the blurred AO buffer (CustomShaderAOLowFreq →
// ResourceAOLowFreqL0, bound in the x==1 block of [ShaderRegexBindAOSSGI]):
//   .b = low-frequency AO local mean — the disocclusion fill FLOOR (what AO "roughly is"
//        around here when no depth-similar tap survives), .a = viewZ (0 = sky/unbound
//        sentinel → fall back to neutral 1.0), .rg = blurred oct bentN (NOT consumed).
Texture2D<float4> ao_lowfreq : register(t31);

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

// Zero-DC corner-detail support: wide depth-aware low-pass of HBIL L0
// (CustomShaderSSGIHBILLowFreq → ResourceSSGIHBILLowFreqL0). The consumer builds
// detail = HBIL_L0 - lowpass(HBIL_L0) so flat surfaces read ~0 detail and only
// local contrast (corners / contact bleed) survives — replaces the old DC-leaky
// max(0, hbil - probe). .rgb = low-freq L0, .a = viewZ. Slot t34 (above cube_accum t33).
Texture2D<float4> ssgi_hbil_lowfreq : register(t34);

// Frame-consistent depth rejection (June 2026 "sheen" fix): previous frame's VP matrix
// (ResourcePrevVPTexture, 4×1 rows — same texture decorators read at t23 and water at t20).
// The AO/GI/SSS buffers' stored viewZ was recorded by the compute chain at the END of the
// PREVIOUS frame, i.e. in prev-frame view space. Comparing it against curr_viewZ made the
// bilateral depth test fail along the iso-depth contour z ≈ 10·v·dt under camera translation
// → a graded bright/dark band ("sheen") sliding with velocity and rotating with the camera.
// expectedPrevZ = world_position projected through THIS matrix puts both sides of the test
// in prev-frame view space → valid under arbitrary camera motion (ssgi_pixel_temporal idiom).
Texture2D<float4> prev_vp_ao : register(t35);

// Optical-flow OBJECT motion-vector residual (Part 2, June 2026). ResourceObjectMV (240×135;
// .xy = object screen-motion residual in UV, 0 unless $object_mv on). Bound at ps-t36 via
// [ShaderRegexBindAOSSGI] (unconditional, like prev_vp_ao). Camera-only MVs read ~0 on animated
// characters/weapons; this is the OBJECT component. Subtracted from the per-pixel camera reproj
// (reproj_uv -= r) so a mover's 1-frame-stale AO/GI/SSS is fetched from where the object WAS.
// Slot t36 (above prev_vp_ao t35; t≥21 avoids the fxc PARAM_SAMPLER_2D collision, lesson #18).
Texture2D<float4> g_object_mv : register(t36);
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
//   world_position   : fragment world-space position (Camera_Position_PS −
//                      fragment_to_camera_world at the entry_points/terrain call sites;
//                      decorators pass their interpolated world_position directly). Used to
//                      compute expectedPrevZ (this point's viewZ in the PREVIOUS frame's
//                      view space) for the frame-consistent bilateral depth test. Pass
//                      float3(0,0,0) when unavailable — falls back to curr_viewZ reference
//                      (the legacy behaviour, banded under camera translation).
void apply_ao_ssgi_inline(
    inout float3 diffuse_color,
    in float3 albedo_color,
    in float3 surface_normal,
    in float2 fragment_position,
    in float2 motion_vector,
    in float  raw_depth,
    in float3 world_position)
{
#ifdef HALOGRAM_SHADER
    // No-op for halograms: volumetric/additive surfaces don't receive screen-space AO/GI.
    return;
#else
    // Reproject current-frame pixel back to the UV where the compute pass wrote AO/SSGI
    // (that pass references the *previous* forward-pass geometry, so MV from the current
    // forward pass brings us to the matching sample).
    //
    // The broken first-person-weapon MV guard now lives at the SOURCE in
    // compute_motion_vector() (motion_vectors.fx) — the MV we receive here is already
    // weapon-suppressed, so we trust it unconditionally. The per-tap depth rejection below
    // still rejects disoccluded neighbours. (Previously a depth-gated magnitude guard lived
    // here; it was inverted — saturate(viewZ/3) applied MAX reprojection at the weapon and
    // killed it at distance — causing the weapon offset + the near-camera warp band.)
    // Phase-0 reprojection diagnosis (temporal/reproj overhaul). $reproj_scale (row-1 .y,
    // Shift+F6) multiplies the MV: 1.0=normal, 0.0=no reproj, 0.5/1.5/2.0=over/under probes.
    // Localizes stale-buffer vs wrong-MV-value. Diagnostic — fold away once root cause found.
    float reproj_scale = ssgi_iniparams.Load(int2(1, 0)).y;
    float2 mv_used = motion_vector * reproj_scale;

    // Resolution independence (Aug 2026): was float2(1920.0f, 1080.0f). Every buffer this
    // function samples is now allocated at the render resolution, so this must track it too.
    const float2 viewport_size = get_viewport_size();
    float2 curr_uv    = (fragment_position + float2(0.5f, 0.5f)) / viewport_size;

    float curr_viewZ  = 0.00781f / max(raw_depth, 1e-6f);
    float depth_scale = max(curr_viewZ * 0.1f, 0.05f);

    // EXACT per-pixel camera reprojection (June 2026 — supersedes the noperspective per-vertex MV).
    // The per-vertex MV (motion_vector / SV_Target2) is camera-only AND a flat-ramp-per-triangle
    // approximation of the ≈1/z parallax field (noperspective interpolation) → kinked MV bands across
    // large low-poly floors/ramps/walls (the wedges in the Shift+F7 overlay) → AO/GI/SSS warp under
    // camera motion. world_position arrives perspective-correct; projecting it through the PREVIOUS
    // VP yields the EXACT previous-frame screen UV of this pixel's surface point — tessellation-
    // independent, no triangle-edge kinks. Reuses the same pv_clip/pv_mat the expectedPrevZ depth
    // test already trusts (proven-good t35 prev_vp_ao matrix). On a static camera prev_VP==curr_VP →
    // prev_uv ≈ this pixel's own UV → MV≈0 (no large-coord subtraction, so no precision drift).
    // $reproj_scale (Shift+F6) still scales the FALLBACK per-vertex path; it is a deliberate no-op on
    // the exact path (the prev-VP projection has no scalar knob) — kept for A/B of the fallback only.
    float  expectedPrevZ = curr_viewZ;   // fallback: no prev VP yet / no world_position
    float2 prev_uv       = curr_uv;      // fallback reproj target
    bool   have_prev_uv  = false;
    {
        float4 pv_r0 = prev_vp_ao.Load(int3(0, 0, 0));
        if ((pv_r0.x != 0.0f || pv_r0.y != 0.0f || pv_r0.z != 0.0f || pv_r0.w != 0.0f)
            && dot(world_position, world_position) > 1e-8f)
        {
            float4x4 pv_mat = float4x4(
                pv_r0,
                prev_vp_ao.Load(int3(1, 0, 0)),
                prev_vp_ao.Load(int3(2, 0, 0)),
                prev_vp_ao.Load(int3(3, 0, 0)));
            float4 pv_clip = mul(float4(world_position, 1.0f), pv_mat);
            if (pv_clip.w > 1e-6f)
            {
                // expectedPrevZ: this pixel's viewZ in the PREVIOUS frame's view space (sheen fix —
                // frame-consistent reference depth for the bilateral .a test below).
                float pv_rawD = pv_clip.z / pv_clip.w;
                if (pv_rawD > 1e-5f)
                {
                    float pv_z = 0.00781f / pv_rawD;
                    // Sanity: the camera cannot translate >50% of viewZ in one frame —
                    // a larger delta means a stale/garbage matrix or bad world_position.
                    if (abs(pv_z - curr_viewZ) < 0.5f * curr_viewZ)
                        expectedPrevZ = pv_z;
                }
                // prev_uv: EXACT previous-frame screen UV of this pixel = camera reprojection target.
                // curr_viewZ > 0.45 weapon gate — the camera-locked weapon must NOT be camera-
                // reprojected (mirrors motion_vectors.fx smoothstep(0.30,0.45) + the temporals' >0.45
                // gate). The weapon falls through to the per-vertex fallback where mv_used≈0 (killed at
                // source) → reproj_uv = curr_uv (camera-locked, correct).
                if (curr_viewZ > 0.45f)
                {
                    prev_uv = float2(pv_clip.x / pv_clip.w * 0.5f + 0.5f,
                                     0.5f - pv_clip.y / pv_clip.w * 0.5f);
                    have_prev_uv = true;
                }
            }
        }
    }

    float2 reproj_uv = have_prev_uv ? prev_uv : (curr_uv - mv_used);

    // Object-motion residual (optical flow, Part 2): subtract the OBJECT screen motion so a moving
    // character's/weapon's 1-frame-stale AO/GI/SSS sample is fetched from where the object WAS.
    // reproj_uv = uv - camMV - r (matches the temporals' mv += r). ZERO unless $object_mv on (gated
    // in object_mv_finalize) -> reproj_uv unchanged -> bit-identical. Bilinear from the 240×135 field.
    // omv_-prefixed locals (no frac()/banned-identifier collision; floor used, not frac — lessons #20/#22).
    {
        // Resolution independence (Aug 2026): the residual field is no longer a fixed 240x135 —
        // it is sized by width_multiply 0.125 off the render target, so query it. ps-t36 is bound
        // UNCONDITIONALLY (d3dx.ini), but the max(...,2) guard keeps this safe on any draw where
        // it somehow is not: size (2,2) -> clamp to texel 0 -> Load returns 0 on an unbound SRV ->
        // zero residual -> reproj_uv unchanged, i.e. exactly the $object_mv-off behaviour.
        uint omv_w, omv_h;
        g_object_mv.GetDimensions(omv_w, omv_h);
        float2 omv_size = float2(max(omv_w, 2u), max(omv_h, 2u));
        float2 omv_p  = curr_uv * omv_size - 0.5f;
        float2 omv_fl = floor(omv_p);
        float2 omv_f  = omv_p - omv_fl;
        int2   omv_b  = clamp(int2(omv_fl), int2(0, 0), int2(omv_size) - 2);
        float2 omv00 = g_object_mv.Load(int3(omv_b + int2(0, 0), 0)).xy;
        float2 omv10 = g_object_mv.Load(int3(omv_b + int2(1, 0), 0)).xy;
        float2 omv01 = g_object_mv.Load(int3(omv_b + int2(0, 1), 0)).xy;
        float2 omv11 = g_object_mv.Load(int3(omv_b + int2(1, 1), 0)).xy;
        reproj_uv -= lerp(lerp(omv00, omv10, omv_f.x), lerp(omv01, omv11, omv_f.x), omv_f.y);
    }

    // Phase-0 MV debug viz ($mv_debug = row-1 .z, Shift+F7). Shows the per-pixel MV ACTUALLY USED
    // for reprojection (curr_uv - reproj_uv) as RG tint (x40) — the exact per-pixel camera MV on
    // world geometry, the per-vertex fallback on the weapon / frame-0. A horizontal pan should give
    // a SMOOTH red gradient scaling with 1/depth across low-poly floors (NO wedge/band kinks at
    // triangle edges — that banding was the per-vertex+noperspective artifact this fix removes).
    if (ssgi_iniparams.Load(int2(1, 0)).z > 0.5f)
    {
        float2 dbg_mv = curr_uv - reproj_uv;
        diffuse_color = float3(abs(dbg_mv.x) * 40.0f, abs(dbg_mv.y) * 40.0f, 0.0f);
        return;
    }

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

    // curr_viewZ + depth_scale are now computed at the top (hoisted with the per-pixel reproj block).

    // Disocclusion-halo pass (June 2026): Interleaved Gradient Noise (Jimenez 2014), keyed
    // by pixel + frame ($ssgi_frame, x1). Two consumers: (a) ±30% jitter of the depth-accept
    // threshold (gated by $disocc_dither, w2) so the accept/reject contour is per-pixel/
    // per-frame stochastic noise instead of a coherent band trailing moving objects;
    // (b) per-pixel rotation of the mode-2 ring-inpaint tap pattern below.
    // NOTE: frac() is shadowed by the `float2 frac` local above (lesson #22) — computed
    // manually as x - floor(x). All locals dz_-prefixed (lesson #20 banned-identifier list).
    float dz_ign = 0.0f;
    {
        float  dz_frame = ssgi_iniparams.Load(int2(1, 0)).x;
        float2 dz_p     = fragment_position + dz_frame * 5.588238f;
        float  dz_t     = dot(dz_p, float2(0.06711056f, 0.00583715f));
        dz_t   -= floor(dz_t);
        dz_ign  = 52.9829189f * dz_t;
        dz_ign -= floor(dz_ign);
        if (ssgi_iniparams.Load(int2(2, 0)).w > 0.5f)
            depth_scale *= 0.7f + 0.6f * dz_ign;
    }

    // (expectedPrevZ — this pixel's viewZ in the previous frame's view space, the "sheen"-fix
    // reference depth for the bilateral .a test below — is now computed at the top alongside the
    // per-pixel reproj, from the same pv_clip. The standalone block here was removed.)

    // Reveal factor (June 2026 — FSR reconstructed-prev-depth, one-sided + EvaluateSurface guard).
    // Distinguishes a GENUINE disocclusion reveal (NPC/weapon/camera) from a STABLE foreground
    // silhouette (decorator leaf, thin object, hill crest). The buffer taps' .a = prev-frame viewZ
    // of whatever was rendered at this (reprojected) location last frame; expectedPrevZ = THIS
    // fragment's own surface reprojected into prev-frame view space.
    //   rv_raw    : fragment much DEEPER than the prev surface here (bilinear mean) => occluded.
    //   rv_smooth : FSR EvaluateSurface analog (ffx_fsr3upscaler_depth_clip.h). If the footprint
    //               STRADDLES a depth cliff (large near..far spread) it's a static silhouette, NOT
    //               a reveal => suppress. A genuine reveal has the whole footprint on the occluder
    //               (small spread). This guard's absence made v1 false-fire at every thin edge /
    //               NPC silhouette / decorator leaf (the "pop"/shift/bleed regression).
    // knee + spread-onset live-tunable via IniParams (3,0).y / (3,0).z (default-guarded). The
    // failure mode of both is toward the stable strict baseline (never dark, never a pop).
    // MV-independent (works for the MV-killed weapon and animated NPCs). Sky/unbound taps
    // (a<=0.001) excluded from the bilinear weights (June 2026: was min/max — see below).
    float rv_knee = ssgi_iniparams.Load(int2(3, 0)).y;
    rv_knee = (rv_knee > 0.001f) ? rv_knee : 1.2f;
    float rv_spread_onset = ssgi_iniparams.Load(int2(3, 0)).z;
    rv_spread_onset = (rv_spread_onset > 0.001f) ? rv_spread_onset : 0.15f;
    float4 wb;  // bilinear weights (hoisted above the reveal block - zigzag fix, June 2026)
    wb.x = (1.0f - frac.x) * (1.0f - frac.y);
    wb.y = frac.x          * (1.0f - frac.y);
    wb.z = (1.0f - frac.x) * frac.y;
    wb.w = frac.x          * frac.y;

    float rv_reveal = 0.0f;
    {
        // SUB-PIXEL bilinear statistics (June 2026 zigzag fix). The old min/max over the
        // floor()-snapped 2x2 footprint stepped as sub-pixel camera motion shifted WHICH 4
        // pixels were sampled -> stair-stepped reveal outlines under motion (the Ctrl+F6
        // mode-2 overlay zigzagged on its own). Weight each tap by its bilinear weight wb
        // (-> 0 for the row/col entering or leaving at the integer boundary) so BOTH the
        // reference depth (mean) and the spread (std/mean) vary CONTINUOUSLY -> no zigzag.
        // rv_raw now tests expectedPrevZ vs the bilinear MEAN (was the min); at a clean
        // reveal mean ~= min so it fires the same, at a straddled silhouette the mean sits
        // between near/far -> partial, and the high-variance rv_smooth suppresses it.
        // rv_spread is now std/mean (NOT (max-min)/max) -> different scale, so $reveal_spread
        // (Ctrl+F9, default 0.15) likely wants lowering to ~0.10-0.12; re-tune live.
        // Sky/unbound taps (a<=0.001) excluded from the bilinear weights.
        float rv_prevZ  = curr_viewZ;                              // overlay reference (mean prev depth)
        float rv_spread = 0.0f, rv_raw = 0.0f, rv_smooth = 1.0f;   // overlay locals
        float4 rv_z   = float4(ao00.a, ao10.a, ao01.a, ao11.a);    // prev-frame viewZ of the 4 taps
        float4 rv_vw  = wb * step(0.001f, rv_z);                   // bilinear weight, sky excluded
        float  rv_vws = dot(rv_vw, 1.0f.xxxx);
        if (rv_vws > 1e-4f)
        {
            float rv_inv    = 1.0f / rv_vws;
            rv_prevZ        = dot(rv_vw, rv_z) * rv_inv;                       // continuous mean depth
            float rv_prevZ2 = dot(rv_vw, rv_z * rv_z) * rv_inv;
            float rv_var    = max(0.0f, rv_prevZ2 - rv_prevZ * rv_prevZ);
            rv_spread       = sqrt(rv_var) / max(rv_prevZ, 1e-4f);            // continuous std/mean
            rv_raw          = saturate((expectedPrevZ / max(rv_prevZ, 1e-4f) - rv_knee) / 0.6f);
            rv_smooth       = 1.0f - saturate((rv_spread - rv_spread_onset) / 0.35f);
            rv_reveal       = rv_raw * rv_smooth;
        }

        // --- rv_reveal DEBUG overlay ($reveal_debug = (3,0).w, Ctrl+F6) — diagnostic only ---
        // mode 1: R = rv_reveal (fill FIRING) | G = rv_raw*(1-rv_smooth) (a depth-jump the guard
        //         SUPPRESSED — green at static silhouettes/decorator leaf edges is CORRECT; green
        //         on an NPC trail interior means the guard is over-killing a real reveal) | B = 0.
        //         So: black = stable (no reveal), red = fill active, green = guard-suppressed jump.
        // mode 2: R = raw depth-jump magnitude (ratio-1, pre-knee) | G = footprint spread | B = 0.
        // If Ctrl+F6 shows NOTHING changing, the v2 shader isn't loaded (needs a LEVEL reload, not
        // just F10) or the IniParam (3,0).w isn't reaching the shader.
        float rv_dbg = ssgi_iniparams.Load(int2(3, 0)).w;
        if (rv_dbg > 0.5f)
        {
            if (rv_dbg < 1.5f)
                diffuse_color = float3(rv_reveal, rv_raw * (1.0f - rv_smooth), 0.0f);
            else
                diffuse_color = float3(saturate(expectedPrevZ / max(rv_prevZ, 1e-4f) - 1.0f),
                                       saturate(rv_spread), 0.0f);
            return;
        }
    }

    // (wb bilinear weights hoisted above the reveal block - zigzag fix, June 2026)

    // REVEAL-GATED depth accept (June 2026). Two regimes, blended per-pixel by rv_reveal:
    //   - stable surface (rv_reveal==0): two-sided abs() reject — deeper occluded-background taps
    //     are rejected so their dark AO/GI can't bleed across a static silhouette (the dark-ring
    //     class of bug). This is the pre-disocclusion behaviour.
    //   - genuine reveal (rv_reveal==1): one-sided, deeper-lenient (FSR depth-clip) — the now-
    //     visible deeper surface IS this fragment, so its background data is the correct fill;
    //     nearer (occluder/ghost) taps still get the strict 0-at-1x reject, far side falls to 0 at
    //     8x depth_scale. Fills the bright NPC/weapon trailing band with real background data.
    float4 wd;  // depth accept vs expectedPrevZ (0 on sky sentinel ao.a<=0)
    {
        float4 dz4 = float4(ao00.a, ao10.a, ao01.a, ao11.a) - expectedPrevZ.xxxx;
        // Reveal-gated accept (June 2026, unified — supersedes the DECORATOR_LEGACY #ifdef):
        //   strict = two-sided abs() — rejects deeper occluded-background taps (clean at stable
        //            silhouettes: decorator leaf edges, hill crests). reveal==0 here is
        //            bit-identical to the retired decorator-legacy path.
        //   reveal = one-sided deeper-lenient (FSR depth-clip) — accepts the now-visible deeper
        //            surface (correct fill at a genuine disocclusion). 0 at 1x near, 8x far.
        // lerp by rv_reveal: deeper-lenience fires ONLY where this fragment was actually occluded
        // last frame, never at a static foreground cliff (that was the dark-ring bug).
        float4 rv_wd_strict = saturate(1.0f.xxxx - abs(dz4) / depth_scale);
        float4 rv_wd_reveal = min(saturate(1.0f.xxxx + dz4 / depth_scale),
                                  saturate(1.0f.xxxx - dz4 / (8.0f * depth_scale)));
        wd = lerp(rv_wd_strict, rv_wd_reveal, rv_reveal);
        wd.x *= step(0.001f, ao00.a);
        wd.y *= step(0.001f, ao10.a);
        wd.z *= step(0.001f, ao01.a);
        wd.w *= step(0.001f, ao11.a);
    }

    float4 w    = wb * wd;
    float  wsum = dot(w, 1.0f.xxxx);

    // Disocclusion handling. `da_*` locals are prefixed to avoid colliding with the probe
    // block's later inv_w/wsum reuse and to dodge intrinsic shadowing. The weighted average is
    // always computed (cheap) so all three modes share it.
    float  da_mode  = ssgi_iniparams.Load(int2(1, 0)).w;   // $disocc_mode (Shift+F8): 2=ring-inpaint fill (default), 1=smooth fade, 0=legacy hard cliff
    float  da_inv_w = 1.0f / max(wsum, 1e-4f);
    float4 da_ao    = (ao00 * w.x + ao10 * w.y + ao01 * w.z + ao11 * w.w) * da_inv_w;
    float4 da_gi    = (gi00 * w.x + gi10 * w.y + gi01 * w.z + gi11 * w.w) * da_inv_w;
    float3 da_l1r   = (gdr00 * w.x + gdr10 * w.y + gdr01 * w.z + gdr11 * w.w) * da_inv_w;
    float3 da_l1g   = (gdg00 * w.x + gdg10 * w.y + gdg01 * w.z + gdg11 * w.w) * da_inv_w;
    float3 da_l1b   = (gdb00 * w.x + gdb10 * w.y + gdb01 * w.z + gdb11 * w.w) * da_inv_w;

    // -------------------------------------------------------------------------
    // Ring inpaint (mode 2, June 2026 disocclusion-halo pass). When the 2×2 bilateral
    // fails (newly revealed pixels behind a moving object — the buffers hold the
    // OCCLUDER's data there), search a wider ring of taps with a RELAXED depth accept:
    // the revealed background continues spatially, so depth-similar data lives a few
    // pixels outside the disoccluded band. Fill = weighted ring mean, falling back to
    // the wide low-frequency AO/GI local means (ao_lowfreq t31 / ssgi_hbil_lowfreq t34)
    // when even the ring finds nothing. NEVER neutral — neutral (AO=1, GI=0) is what
    // painted the bright trailing outline. 6 taps, two interleaved radii (3px / 6px),
    // rotation IGN-randomised per pixel per frame → residual error is noise, not a ring.
    // `[branch]` keeps the ~22 extra Loads off the hot path (tracked pixels skip it).
    // ring_-prefixed locals (lessons #20/#22).
    // -------------------------------------------------------------------------
    float  ring_fill_ao    = 1.0f;
    float3 ring_fill_gi    = float3(0.0f, 0.0f, 0.0f);
    float3 ring_fill_probe = float3(0.0f, 0.0f, 0.0f);
    float  ring_fill_sss   = 1.0f;
    // Reveal-gated ring inpaint (June 2026, unified). Fires ONLY at a genuine reveal
    // (rv_reveal > 0.5). At a stable silhouette (rv_reveal == 0) the ring is skipped, ring_fill_*
    // stay at their neutral inits (AO=1, GI=0, probe=0, sss=1), and the mode-2 compose below
    // fades AO->1/GI->0 = clean bright edge — bit-identical to the retired decorator-legacy path.
    [branch] if (da_mode > 1.5f && wsum < 0.5f && rv_reveal > 0.05f)  // 0.05 = perf-only; fill ramps smoothly via the ring_fill lerp-from-neutral above
    {
        float ring_relax = depth_scale * 3.0f;   // relaxed accept: background continuity
        float ring_a0    = dz_ign * 6.2831853f;
        // Ring reach — live-tunable via $ring_radius (IniParams (5,0).z, Ctrl+F12; default 1.0).
        // The old 6-tap / 6px ring UNDER-REACHED fast disocclusion bands: the revealed band width
        // scales with the mover's SCREEN speed (confirmed in-game via the reveal overlay — the red
        // band grows with NPC speed), so a band wider than 6px had no real background within reach
        // and fell to the crude, occluder-contaminated low-freq floor = the residual NPC
        // disocclusion artefact. A 12-tap golden-angle spiral out to ~14px (past block 3's 12px
        // disc) reaches real background for fast movers — and does it at CONSUME time (no buffer
        // write, so no foreground corruption / lag, unlike the retired block-3 pre-fill). Distance
        // falloff (ring_distw) keeps the NEAREST valid background dominant so narrow bands aren't
        // polluted by a far deeper surface; outer taps only carry weight when the inner ones miss.
        float ring_rscale = ssgi_iniparams.Load(int2(5, 0)).z;
        ring_rscale = (ring_rscale > 0.001f) ? ring_rscale : 1.0f;
        float ring_max_r = 14.0f * ring_rscale;
        const int kRingTaps = 12;
        float  ring_wsum   = 0.0f;
        float  ring_ao_acc = 0.0f;
        float3 ring_gi_acc = float3(0.0f, 0.0f, 0.0f);
        float3 ring_pr_acc = float3(0.0f, 0.0f, 0.0f);
        float  ring_ss_acc = 0.0f;
        float  ring_ss_w   = 0.0f;
        // [loop] NOT [unroll]: the ring already sits in a reveal-only [branch], so a real loop costs
        // nothing at runtime on steady-state pixels, but compiling it as a dynamic loop (one body)
        // instead of 12 inlined copies keeps apply_ao_ssgi_inline small — it's inlined into every
        // static-lighting permutation, so the unrolled 12-tap version ballooned the template sweep
        // time (~95 min). [loop] brings the per-permutation fxc cost back down. Same 12 taps/14px.
        [loop] for (int ring_k = 0; ring_k < kRingTaps; ring_k++)
        {
            float ring_t     = (float(ring_k) + 0.5f) / float(kRingTaps);  // 0..1 spiral param
            float ring_rad   = lerp(3.0f, ring_max_r, ring_t);             // inner 3px -> outer reach
            float ring_ang   = ring_a0 + float(ring_k) * 2.3999632f;       // golden angle (no axis star)
            float ring_distw = 1.0f - 0.6f * ring_t;                       // prefer nearest valid bg
            float ring_s, ring_c;
            sincos(ring_ang, ring_s, ring_c);
            int2 ring_px = clamp(pix00 + int2(int(ring_c * ring_rad), int(ring_s * ring_rad)),
                                 int2(0, 0), int2(viewport_size) - 2);
            float4 ring_ao_s = ao_ssgi_buffer.Load(int3(ring_px, 0));
            // One-sided (June 12): nearer = occluder -> reject at ring_relax; deeper =
            // background -> near-unconditional (8x falloff). In foliage the ring now
            // almost always finds usable background instead of dropping to the floor.
            float  ring_dz = ring_ao_s.a - expectedPrevZ;
            float  ring_w = min(saturate(1.0f + ring_dz / ring_relax),
                                saturate(1.0f - ring_dz / (8.0f * ring_relax)))
                          * step(0.001f, ring_ao_s.a) * ring_distw;
            ring_ao_acc += ring_ao_s.b * ring_w;
            ring_gi_acc += gi_buffer.Load(int3(ring_px, 0)).rgb * ring_w;
            ring_pr_acc += ssgi_probe_L0.Load(int3(ring_px, 0)).rgb * ring_w;
            ring_wsum   += ring_w;
            // SSS shares the ring (its viewZ lives in .b, sentinel-gated separately).
            float4 ring_ss_s = sss_buffer.Load(int3(ring_px, 0));
            float  ring_sdz  = ring_ss_s.b - expectedPrevZ;
            float  ring_sw   = min(saturate(1.0f + ring_sdz / ring_relax),
                                   saturate(1.0f - ring_sdz / (8.0f * ring_relax)))
                             * step(0.001f, ring_ss_s.b) * ring_distw;
            ring_ss_acc += ring_ss_s.r * ring_sw;
            ring_ss_w   += ring_sw;
        }
        // Low-frequency floor. Sentinel-guarded: when the low-freq buffers are unbound /
        // sky (a < 0.001 — e.g. effects toggled off via F4/F11) fall back to NEUTRAL so
        // mode 2 degrades exactly like mode 1 instead of multiplying the scene by zero.
        float4 ring_lf_ao_s = ao_lowfreq.Load(int3(pix00, 0));
        float  ring_lf_ao   = (ring_lf_ao_s.a > 0.001f) ? saturate(ring_lf_ao_s.b) : 1.0f;
        float4 ring_lf_gi_s = ssgi_hbil_lowfreq.Load(int3(pix00, 0));
        float3 ring_lf_gi   = (ring_lf_gi_s.a > 0.001f) ? ring_lf_gi_s.rgb : float3(0.0f, 0.0f, 0.0f);
        // ~1.5 accepted taps → trust the ring mean over the low-freq floor.
        float ring_conf = saturate(ring_wsum / 1.5f);
        float ring_inv  = 1.0f / max(ring_wsum, 1e-4f);
        ring_fill_ao    = lerp(ring_lf_ao, ring_ao_acc * ring_inv, ring_conf);
        ring_fill_gi    = lerp(ring_lf_gi, ring_gi_acc * ring_inv, ring_conf);
        ring_fill_probe = lerp(ring_lf_gi, ring_pr_acc * ring_inv, ring_conf);
        ring_fill_sss   = (ring_ss_w > 1e-4f) ? (ring_ss_acc / ring_ss_w) : 1.0f;
    }

    // Smooth the disocclusion fill by the reveal factor (FSR consumes the depth-clip as a smooth
    // factor, never a hard gate). ring_fill_* are at their neutral inits when the ring branch was
    // skipped (rv_reveal<=0.05) or rv_reveal==0, so these lerps are no-ops there → bit-identical to
    // the stable neutral path; they ramp to the full ring mean as rv_reveal→1. Kills the dolly "pop".
    ring_fill_ao    = lerp(1.0f,          ring_fill_ao,    rv_reveal);
    ring_fill_gi    = lerp(float3(0,0,0), ring_fill_gi,    rv_reveal);
    ring_fill_probe = lerp(float3(0,0,0), ring_fill_probe, rv_reveal);
    ring_fill_sss   = lerp(1.0f,          ring_fill_sss,   rv_reveal);

    float4 ao_s, gi_s;
    float3 l1_r, l1_g, l1_b;
    // da_conf is hoisted to function scope: the bent-normal decode, cavity kick, sky-leak,
    // and detail high-pass below must ALL be confidence-gated. The original smooth-fade
    // implementation faded only ao_s/gi_s — at conf→0, ao_s.rg→(0,0) octahedral-decodes
    // to WORLD UP with ao_s.a=curr_viewZ passing the validity gate, so the cavity kick gave
    // walls/ceilings a spurious ~50% darkening exactly at reveals (the disocclusion smear).
    float da_conf = 1.0f;
    if (da_mode > 1.5f)
    {
        // Ring-inpaint fill (mode 2). da_cf: 0 = fully disoccluded → ring/low-freq fill,
        // 1 = fully tracked → bilateral average. AO and GI crossfade to their FILLS (never
        // neutral); L1 + the detail high-pass still fade with confidence — both are
        // zero-mean directional terms whose absence is invisible, unlike the DC AO/GI.
        // curr_viewZ kept in .a so the downstream valid-gate applies the filled AO.
        float da_cf = saturate(wsum * 2.0f);
        ao_s = float4(da_ao.rg * da_cf, lerp(ring_fill_ao, da_ao.b, da_cf), curr_viewZ);
        gi_s = float4(lerp(ring_fill_gi, da_gi.rgb, da_cf), curr_viewZ);
        l1_r = da_l1r * da_cf;
        l1_g = da_l1g * da_cf;
        l1_b = da_l1b * da_cf;
        da_conf = da_cf;
    }
    else if (da_mode > 0.5f)
    {
        // Smooth disocclusion fade. confidence = accepted bilateral weight: the bilinear
        // weights sum to 1 and the depth weights are <=1, so wsum in [0,1]. At a disocclusion
        // all taps are depth-rejected → wsum→0 → the effect fades smoothly toward neutral
        // (AO=1, GI=0) instead of snapping to a hard 1-frame neutral hole trailing moving
        // edges. curr_viewZ kept in .a so the downstream valid-gate (ao_s.a > 0.001) passes
        // and applies the faded AO.
        da_conf = saturate(wsum);
        ao_s = float4(lerp(float3(0.0f, 0.0f, 1.0f), da_ao.rgb, da_conf), curr_viewZ);
        gi_s = float4(da_gi.rgb * da_conf, curr_viewZ);
        l1_r = da_l1r * da_conf;
        l1_g = da_l1g * da_conf;
        l1_b = da_l1b * da_conf;
    }
    else if (wsum < 1e-4f)
    {
        // Legacy hard cliff (A/B reference). Neutral: AO=1, GI=0.
        da_conf = 0.0f;
        ao_s = float4(0.0f, 0.0f, 1.0f, 0.001f);
        gi_s = float4(0.0f, 0.0f, 0.0f, 0.001f);
        l1_r = float3(0.0f, 0.0f, 0.0f);
        l1_g = float3(0.0f, 0.0f, 0.0f);
        l1_b = float3(0.0f, 0.0f, 0.0f);
    }
    else
    {
        ao_s = da_ao; gi_s = da_gi;
        l1_r = da_l1r; l1_g = da_l1g; l1_b = da_l1b;
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
    // da_conf gate: at low confidence ao_s.rg is faded toward (0,0), which decodes to a
    // meaningless world-up vector — don't let the cavity kick / sky-leak consume it.
    if (ao_viewZ > 0.001f && da_conf > 0.05f)
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
    // Mode-2 disocclusion fallback (June 2026): on an unoccluded open surface the bent
    // normal equals the projected surface normal (the Klehm 2011 invariant), so the surface
    // normal is the physically-correct stand-in when the stored bent normal is conf-faded.
    // Keeps the far-field sky-leak from popping to zero at reveals; the cavity kick sees
    // tilt = dot(N,N) = 1 → neutral (and is further faded by da_conf anyway).
    if (!have_bentN && da_mode > 1.5f && ao_viewZ > 0.001f)
    {
        float bn_sn2 = dot(surface_normal, surface_normal);
        if (bn_sn2 > 0.01f)
        {
            bentN_ws = surface_normal * rsqrt(bn_sn2);
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
            // Fade the kick toward neutral (1.0) with disocclusion confidence — a partially
            // faded bent normal must not darken the surface it points away from.
            ao_bn = lerp(1.0f, ao_bn, da_conf);
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
        // Resolution independence (Aug 2026): reuse the outer scope's viewport_size (same
        // function — see the `frac`-shadowing note above) rather than a second literal.
        const float2 sss_viewport_px = viewport_size;
        float2 sss_uv        = clamp(reproj_uv, float2(0, 0), float2(1, 1));
        float2 sss_texel_pos = sss_uv * sss_viewport_px - 0.5f;
        float2 sss_floor     = floor(sss_texel_pos);
        float2 sss_frac      = sss_texel_pos - sss_floor;
        int2   sss_base      = clamp(int2(sss_floor), int2(0, 0), int2(sss_viewport_px) - 2);

        float4 s00 = sss_buffer.Load(int3(sss_base, 0));
        float4 s10 = sss_buffer.Load(int3(sss_base + int2(1, 0), 0));
        float4 s01 = sss_buffer.Load(int3(sss_base + int2(0, 1), 0));
        float4 s11 = sss_buffer.Load(int3(sss_base + int2(1, 1), 0));

        // Per-tap depth rejection — matches AO/SSGI bilateral pattern above.
        // Without this, disoccluded neighbours (e.g. background geometry at a different
        // depth plane) bleed their SSS shadow scalar into the bilinear, causing visible
        // jitter when the reprojected UV straddles a depth discontinuity.
        // Reference is expectedPrevZ (NOT curr_viewZ): the SSS buffer's .b viewZ is
        // prev-frame view space — same "sheen" band fix as the AO/GI bilateral above.
        // One-sided (June 12, matches the AO/GI bilateral): nearer = occluder shadow ->
        // strict reject; deeper = background shadow -> lenient (8x falloff).
        float sss_dz0 = s00.b - expectedPrevZ;
        float sss_dz1 = s10.b - expectedPrevZ;
        float sss_dz2 = s01.b - expectedPrevZ;
        float sss_dz3 = s11.b - expectedPrevZ;
        // Reveal-gated SSS accept (unified — supersedes the DECORATOR_LEGACY #ifdef). Reuses the
        // AO-derived rv_reveal (same reproj_uv; reveal is a per-fragment geometric fact). strict
        // two-sided at stable silhouettes, one-sided deeper-lenient at genuine reveals. Sentinel
        // factored out (both old arms multiplied step(0.001, .b) identically).
        float sss_wd0 = lerp(saturate(1.0f - abs(sss_dz0) / depth_scale),
                             min(saturate(1.0f + sss_dz0 / depth_scale), saturate(1.0f - sss_dz0 / (8.0f * depth_scale))),
                             rv_reveal) * step(0.001f, s00.b);
        float sss_wd1 = lerp(saturate(1.0f - abs(sss_dz1) / depth_scale),
                             min(saturate(1.0f + sss_dz1 / depth_scale), saturate(1.0f - sss_dz1 / (8.0f * depth_scale))),
                             rv_reveal) * step(0.001f, s10.b);
        float sss_wd2 = lerp(saturate(1.0f - abs(sss_dz2) / depth_scale),
                             min(saturate(1.0f + sss_dz2 / depth_scale), saturate(1.0f - sss_dz2 / (8.0f * depth_scale))),
                             rv_reveal) * step(0.001f, s01.b);
        float sss_wd3 = lerp(saturate(1.0f - abs(sss_dz3) / depth_scale),
                             min(saturate(1.0f + sss_dz3 / depth_scale), saturate(1.0f - sss_dz3 / (8.0f * depth_scale))),
                             rv_reveal) * step(0.001f, s11.b);

        // Combine bilinear fractional weights with depth similarity.
        float  sss_w0 = (1.0f - sss_frac.x) * (1.0f - sss_frac.y) * sss_wd0;
        float  sss_w1 = sss_frac.x          * (1.0f - sss_frac.y) * sss_wd1;
        float  sss_w2 = (1.0f - sss_frac.x) * sss_frac.y         * sss_wd2;
        float  sss_w3 = sss_frac.x          * sss_frac.y         * sss_wd3;
        float  sss_ws = sss_w0 + sss_w1 + sss_w2 + sss_w3;

        float4 sss_data;
        if (sss_ws < 1e-4f)
        {
            if (da_mode > 1.5f)   // ring_fill_sss is neutral (1.0) when rv_reveal<=0.05, so no hard reveal gate needed here (smooth via the ramp above)
            {
                // Mode 2: ring-inpaint fill instead of fully-lit neutral — the missing
                // contact shadow was the SSS component of the bright trailing outline.
                // curr_viewZ in .b so the sentinel gate below applies the fill. When SSS
                // is toggled off ($s=0 → t32 nulled) ring_fill_sss stays 1.0 → no-op.
                sss_data = float4(ring_fill_sss, 0.0f, curr_viewZ, 0.0f);
            }
            else
            {
                // All neighbours rejected — neutral fallback: fully lit, sky sentinel.
                sss_data = float4(1.0f, 0.0f, 0.001f, 0.0f);
            }
        }
        else
        {
            float inv_sss_w = 1.0f / sss_ws;
            sss_data = (s00 * sss_w0 + s10 * sss_w1 + s01 * sss_w2 + s11 * sss_w3) * inv_sss_w;
            // Mode 2: crossfade partial-confidence samples toward the ring fill so the
            // shadow ramps smoothly through the disocclusion band instead of stepping.
            if (da_mode > 1.5f)
            {
                float sss_cf = saturate(sss_ws * 2.0f);
                sss_data.r = lerp(ring_fill_sss, sss_data.r, sss_cf);
            }
        }

        if (sss_data.b > 0.001f)                        // viewZ sentinel — skip sky/unbound
        {
            // Indirect-light floor (June 2026): a contact shadow blocks DIRECT sun, not the
            // omnidirectional ambient/bounce — but SSS multiplies the FULL diffuse (direct +
            // engine ambient + baked indirect), so a flat 0.05 floor over-darkens ambient-lit
            // areas. Floor the multiply by local ambient openness (AO): open surfaces (ao→1, lots
            // of sky/bounce) can't crush below sss_floor_max; tight cavities (ao→0, little ambient)
            // still reach 0.05 (the deep contact dark we want). Our additive SSGI bounce is applied
            // AFTER this and fills further. sss_floor_max = IniParams (4,0).z (Ctrl+F5), default
            // 0.20, default-guarded so an unset slot falls back to 0.20.
            float sss_floor_max = ssgi_iniparams.Load(int2(4, 0)).z;
            sss_floor_max = (sss_floor_max > 0.001f) ? sss_floor_max : 0.20f;
            diffuse_color *= max(sss_data.r, lerp(0.05f, sss_floor_max, ao));
        }
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
    // [Energy-accuracy rewrite, May 2026] k_dir = analytic clamped-cosine SH L1
    // coefficient sqrt(3)/2 ~= 0.866 (was an empirical 0.9). gi_color STARTS as the
    // HBIL reconstruction; the probe block below replaces it with the energy-correct
    // compose (probe base + HBIL high-frequency detail). gi_color is reused as the
    // single composed indirect-irradiance accumulator so downstream code is unchanged.
    static const float k_dir = 0.866f;
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
    // [May 2026] Single far-field directional term (renamed sky_contrib -> farfield_c;
    // the strength multiply is moved to the add site below so it composes with the one
    // intensity knob). This is the ONLY far-field source — the probe trace's cube-on-miss
    // strength should be reduced so off-screen radiance is not double-counted.
    float  g_SSGISkyLeakStrength = max(ssgi_iniparams.Load(int2(2, 0)).x, 0.0f);
    float3 farfield_c = float3(0.0f, 0.0f, 0.0f);
    if (g_SSGISkyLeakStrength > 0.001f && have_bentN && ao_viewZ > 0.001f)
    {
        float visibility = saturate(dot(bentN_ws, N_ws));
        // da_conf: at reveals the probe GI fades to 0 — the far-field must fade with it,
        // not pop in along a half-faded bent normal (sky-coloured flash on floors).
        // Mode 2: floor the fade at 0.3 — the far-field is cached DC ambient sampled along
        // the (surface-normal-fallback) bent normal, the least wrong thing available at a
        // reveal; letting it flash fully off was part of the bright-outline contrast.
        float ff_conf = (da_mode > 1.5f) ? max(da_conf, 0.3f) : da_conf;
        farfield_c    = _AO_SampleCubeAccum(bentN_ws) * visibility * ff_conf;
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
    // Mode 2 enters this block even at wsum≈0 (full disocclusion) so probe_c can take the
    // ring-inpaint fill instead of silently dropping the primary first bounce at reveals.
    if (g_SSGIProbeStrength > 0.001f && (wsum >= 1e-4f || da_mode > 1.5f))
    {
        float inv_w = 1.0f / max(wsum, 1e-4f);

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

        float3 probe_c;
        probe_c.r = max(0.0f, pL0.r + k_dir * dot(pL1r, N_ws));
        probe_c.g = max(0.0f, pL0.g + k_dir * dot(pL1g, N_ws));
        probe_c.b = max(0.0f, pL0.b + k_dir * dot(pL1b, N_ws));
        probe_c *= g_SSGIProbeStrength;

        // Mode 2: crossfade the tracked probe reconstruction with the ring-inpaint fill
        // (L0-only, no directional term — direction is unknowable at a reveal) so the
        // primary first bounce never drops to zero in the disoccluded band.
        if (da_mode > 1.5f)
            probe_c = lerp(ring_fill_probe * g_SSGIProbeStrength, probe_c, da_conf);

        // [Zero-DC corner-detail, June 2026] HBIL contributes ONLY its high-frequency
        // residual over its OWN low-frequency band — a true self-high-pass, so flats stay
        // constant brightness and only corners / contact gain contrast. This replaces the
        // old DC-leaky `max(0, hbil*CALIB - probe)` (HBIL bitmask norm ≠ probe Malley norm,
        // and the max() rectified a zero-mean signal → positive DC → brightened flats).
        //   lowL0 = wide depth-aware blur of HBIL L0 (CustomShaderSSGIHBILLowFreq), sampled
        //   with the SAME 2×2 bilateral as gi_s, so hp_L0 = bilateral(L0 - lowpass(L0)).
        // The per-channel L0 residual carries the corner colour-bleed; the HBIL L1
        // directional term is kept full ("L0-only high-pass" choice — HBIL L1 is ~0 on open
        // flats and significant only near geometry, so its flat-area DC is negligible).
        // probe_c stays the PRIMARY first bounce. $ssgi_detail_strength (x3, Ctrl+F5) scales
        // it live. When the probe is off the whole block is skipped → gi_color stays full HBIL.
        float  g_SSGIDetailStrength = max(ssgi_iniparams.Load(int2(3, 0)).x, 0.0f);
        float3 lowL0 = (ssgi_hbil_lowfreq.Load(int3(pix00 + int2(0, 0), 0)).rgb * w.x
                      + ssgi_hbil_lowfreq.Load(int3(pix00 + int2(1, 0), 0)).rgb * w.y
                      + ssgi_hbil_lowfreq.Load(int3(pix00 + int2(0, 1), 0)).rgb * w.z
                      + ssgi_hbil_lowfreq.Load(int3(pix00 + int2(1, 1), 0)).rgb * w.w) * inv_w;
        // Build the high-pass from the UNFADED averages (da_gi / da_l1*), then apply
        // disocclusion confidence to the WHOLE detail term. Using the conf-faded gi_s
        // against the unfaded lowL0 made hp_L0 = conf·L0 − lowpass(L0) go NEGATIVE at
        // partial disocclusions — a second dark-halo source trailing moving edges,
        // breaking the zero-mean property this high-pass exists for.
        float3 hp_L0 = da_gi.rgb - lowL0;
        float3 detail_c;
        detail_c.r = hp_L0.r + k_dir * dot(da_l1r, N_ws);
        detail_c.g = hp_L0.g + k_dir * dot(da_l1g, N_ws);
        detail_c.b = hp_L0.b + k_dir * dot(da_l1b, N_ws);
        gi_color = max(float3(0.0f, 0.0f, 0.0f), probe_c + g_SSGIDetailStrength * da_conf * detail_c);
    }

    // Saturation boost — Halo 3 diffuse albedos are aggressively desaturated (2007 engine
    // with painted-in ambient and no energy-conserving BRDF). Bouncing low-chroma light
    // yields low-chroma GI no matter how strong the math. Expand chromaticity on the GI
    // term only (not applied to direct lighting) to recover perceptual saturation.
    // 1.8 → 1.3 → 1.1: now that the Lambertian albedo multiply (below) does the real
    // chromaticity work via the BRDF, this extra lift only needs to nudge the low-chroma
    // Halo 3 palette. 1.1 is a gentle boost that doesn't fight the physical tint.
    // [June 2026 cleanup] gi_saturation chroma-expand removed (was a no-op lerp at 1.0
    // since May 2026). Chromaticity is handled by the Lambertian albedo multiply below;
    // use $ssgi_albedo_boost (F12) for deliberate artistic chroma.
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
    // [June 2026 cleanup] The consumer-side contrast-lift code here was a no-op
    // (boost=0 since May 2026) and has been removed. $ssgi_intensity is the single
    // linear knob; any per-sample non-linear lift now lives in the trace shaders.
    // The rationale comment above is kept for history.

    // Consumer gain — 0.5 → 0.8 to compensate for higher dynamic range after the
    // lift above (dim bounce sits at the same level as before; bright bounce is
    // now ~4× what it was at the 0.5 scale, so overall scene average moves up
    // modestly). 0.8 lets the F6 $ssgi_intensity knob still nudge up to ~1.0×
    // on sunlit scenes without re-tuning the lift knee/full/boost.
    //
    // Phase F1a — $ssgi_intensity runtime knob (Lumen IndirectLightingIntensity equivalent).
    // Default 1.0 → net 0.8× intrinsic. F6 cycles [0.5, 1.0, 1.5, 2.0, 3.0] for A/B tuning.
    // max() guards against accidental negative / NaN from an unbound IniParams slot.
    // [May 2026] Removed the 0.8 compensating gain. $ssgi_intensity is now the SINGLE
    // linear knob; 1.0 = physically balanced (probe L0 is irradiance/pi from Malley
    // (1/N)Sum, and the albedo multiply below uses the engine's no-/pi convention).
    float g_SSGIIntensity = max(ssgi_iniparams.Load(int2(4, 0)).x, 0.0f);

    // EXPOSURE-SPACE CORRECTION (June 11 2026 — the "look at sky → scene blows out" fix).
    // Every GI source (probe + HBIL via g_HDRScene, far-field via the cube that accumulates
    // g_HDRScene) is POST-EXPOSURE; this function adds into diffuse_color BEFORE the caller's
    // final `* g_exposure.rrr` → without this divide the GI is exposure-applied TWICE
    // (∝ exposure²). In dark scenes Halo's eye-adaption gain is high → GI/sky-leak massively
    // over-contributes (the "metallic leaves" ambient sheen); exposure swings (glance at the
    // bright sky → adaption dips → look back) propagate through the GI temporal lag as
    // transient blow-outs / "stale ambient". Same convention as the SSR consumers
    // (apply_ssr_blend: `ssr_raw = ibr.rgb / g_exposure.r`; water_shading ssr_pre_exposure).
    // Buffers lag exposure by the temporal time constants (~0.25-1s) — brief mismatch during
    // swings, converges; infinitely better than the squared error.
    float inv_exposure = 1.0f / max(g_exposure.r, 1e-4f);

    gi_color *= g_SSGIIntensity * inv_exposure;

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
    // [May 2026] Replaced the 2x->10x "hot-relax" envelope (a brightness-shaper that
    // existed to fight the double-count) with a pure high firefly/NaN guard. The energy
    // is correct now, so this only catches runaway temporal/feedback fireflies and never
    // touches normal-range bounce (post-exposure indirect sits ~0-3). Chroma preserved.
    {
        float gi_ff_lum = dot(gi_contrib, float3(0.2126f, 0.7152f, 0.0722f));
        const float FIREFLY_CEILING = 12.0f;
        if (gi_ff_lum > FIREFLY_CEILING) gi_contrib *= FIREFLY_CEILING / gi_ff_lum;
        if (any(isnan(gi_contrib)) || any(isinf(gi_contrib))) gi_contrib = float3(0.0f, 0.0f, 0.0f);
    }
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
    // [May 2026] Single far-field term (farfield_c), scaled by sky-leak strength (F5) and
    // the single intensity knob, then the Lambertian albedo*ao_multi. Kept as a separate
    // additive term (it is cached DC irradiance, not a firefly source, so it skips the
    // firefly clamp above). This is the only off-screen-radiance add — the probe's
    // cube-on-miss should be reduced to avoid double-counting far-field.
    // inv_exposure: the cube stores post-exposure radiance — same exposure-space
    // correction as gi_color above (without it, sky-leak is exposure² and the bright-sky
    // cube texels paint over-amplified patches onto upward bent normals in dark scenes).
    diffuse_color += g_SSGISkyLeakStrength * farfield_c * albedo_color * ao_multi * g_SSGIIntensity * inv_exposure;
#endif  // HALOGRAM_SHADER
}

#endif
