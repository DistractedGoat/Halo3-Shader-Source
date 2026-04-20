#ifndef __GLASS_FX_H__
#define __GLASS_FX_H__
#pragma once
/*
GLASS.FX
Copyright (c) Microsoft Corporation, 2007. all rights reserved.
1/16/2007 1:08:55 PM (haochen)
	glass render method
*/

#include "hlsl_constant_mapping.fx"
#define LDR_ALPHA_ADJUST g_exposure.w
#define HDR_ALPHA_ADJUST g_exposure.b
#define DARK_COLOR_MULTIPLIER g_exposure.g
#include "utilities.fx"
#include "deform.fx"
#include "texture_xform.fx"
#include "render_target.fx"
#include "blend.fx"
#include "atmosphere.fx"
#include "alpha_test.fx"
#include "shadow_generate.fx"
#include "clip_plane.fx"
#include "dynamic_light_clip.fx"
#include "motion_vectors.fx"

//tinting
float3 tint_color;
void calc_tinting_constant_color_ps(in float2 texcoord, out float4 tinting)
{
	tinting= float4(tint_color, 1.0f);
}

PARAM_SAMPLER_2D(tint_texture);
PARAM(float4, tint_texture_xform);
void calc_tinting_texture_ps(in float2 texcoord, out float4 tinting)
{
	tinting= sample2D(tint_texture,   transform_texcoord(texcoord, tint_texture_xform));
}

void calc_bump_mapping_default_ps()
{
}

PARAM_SAMPLER_2D(reflection_cubemap);
PARAM(float4, reflection_cubemap_xform);
float3 calc_reflection_static_cubemap_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir)
{
	reflect_dir.y= -reflect_dir.y;
	float3 reflection= texCUBE(reflection_cubemap, reflect_dir);
	return reflection;
}

float3 calc_reflection_dyanamic_cubemap_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir)
{
	return float3(1.0f, 1.0f, 1.0f);
}

float3 calc_reflection_realtime_reflection_ps(
	in float3 view_dir,
	in float3 normal,
	in float3 reflect_dir)
{
	return float3(1.0f, 1.0f, 1.0f);
}

void calc_refraction_static_texture_ps()
{
}

void calc_refraction_scene_ps()
{
}

void calc_weathering_rain_streak_ps()
{
}

void calc_weathering_snow_dust_ps()
{
}

#ifdef ENABLE_SSR
// Bound to ps-t19 by ShaderRegexBindSSR at runtime (matches dcl_output o4 — roughness output slot).
// Exposes ResourceSSRFinal to the glass reflection pass for SSR blend.
Texture2D<float4> ssr_buffer_glass : register(t19);
#endif

void albedo_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0)
{
	float4 local_to_world_transform[3];
	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	// normal, tangent and binormal are all in world space
	texcoord= vertex.texcoord;
	
	CALC_CLIP(position);
}

float4 albedo_ps(
	SCREEN_POSITION_INPUT(screen_position),
	CLIP_INPUT
	in float2 original_texcoord : TEXCOORD0) : SV_Target0
{
	float4 tinting;
	calc_tinting_ps(original_texcoord, tinting);
	return tinting;
}

void static_per_pixel_vs(
	in vertex_type vertex,
	in s_lightmap_per_pixel lightmap,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD3,
	out float3 binormal : TEXCOORD4,
	out float3 tangent : TEXCOORD5,
	out float2 lightmap_texcoord : TEXCOORD6,
	out float3 extinction : COLOR0,
	out float3 inscatter : COLOR1
#ifdef ACCUM_PIXEL_HAS_MV
	,out float2 motion_vector : TEXCOORD10
#endif
	)
{
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);

	normal= vertex.normal;
	texcoord= vertex.texcoord;
	lightmap_texcoord= lightmap.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);

#ifdef ACCUM_PIXEL_HAS_MV
	motion_vector = compute_motion_vector(position, vertex.position);
#endif
	CALC_CLIP(position);
}

accum_pixel static_per_pixel_ps(
	SCREEN_POSITION_INPUT(fragment_position),
	CLIP_INPUT
	in float2 texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD3,
	in float3 binormal : TEXCOORD4,
	in float3 tangent : TEXCOORD5,
	in float2 lightmap_texcoord : TEXCOORD6_centroid,
	in float3 extinction : COLOR0,
	in float3 inscatter : COLOR1
#ifdef ACCUM_PIXEL_HAS_MV
	,in float2 motion_vector : TEXCOORD10
#endif
	) : SV_Target
{
#ifdef ACCUM_PIXEL_HAS_MV
	g_motion_vector_passthrough.xy = motion_vector;
	g_raw_depth_passthrough        = fragment_position.z;
#endif
	float4 out_color= float4(1.0f, 1.0f, 1.0f, 1.0f);
	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);
}


void static_sh_vs(
	in vertex_type vertex,
	in s_lightmap_per_pixel lightmap,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD1,
	out float3 binormal : TEXCOORD2,
	out float3 tangent : TEXCOORD3,
	out float2 lightmap_texcoord : TEXCOORD4,
	out float3 fragment_to_camera_world : TEXCOORD5,
	out float3 extinction : COLOR0,
	out float3 inscatter : COLOR1
#ifdef ACCUM_PIXEL_HAS_MV
	,out float2 motion_vector : TEXCOORD10
#endif
	)
{
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);

	normal= vertex.normal;
	texcoord= vertex.texcoord;
	lightmap_texcoord= lightmap.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	fragment_to_camera_world= Camera_Position-vertex.position;

	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);

#ifdef ACCUM_PIXEL_HAS_MV
	motion_vector = compute_motion_vector(position, vertex.position);
#endif
	CALC_CLIP(position);
}

accum_pixel static_sh_ps(
	SCREEN_POSITION_INPUT(fragment_position),
	CLIP_INPUT
	in float2 texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD1,
	in float3 binormal : TEXCOORD2,
	in float3 tangent : TEXCOORD3,
	in float2 lightmap_texcoord : TEXCOORD4_centroid,
	in float3 fragment_to_camera_world : TEXCOORD5,
	in float3 extinction : COLOR0,
	in float3 inscatter : COLOR1
#ifdef ACCUM_PIXEL_HAS_MV
	,in float2 motion_vector : TEXCOORD10
#endif
	) : SV_Target
{
#ifdef ACCUM_PIXEL_HAS_MV
	g_motion_vector_passthrough.xy = motion_vector;
	g_raw_depth_passthrough        = fragment_position.z;
#endif
	//tint color
#if DX_VERSION == 11
	float4 tint = albedo_texture.Load(int3(fragment_position.xy, 0));
#else
	float4 tint= sample2D(albedo_texture, (fragment_position.xy + float2(0.5f, 0.5f)) / texture_size.xy);
#endif
	
	//environment map
	float3 view_dir= normalize(fragment_to_camera_world);
	float3 nromal_dir= normal;
	float3 reflect_dir= normalize( (dot(view_dir, nromal_dir) * nromal_dir - view_dir) * 2 + view_dir );
	float3 reflection= calc_reflection_ps(view_dir, nromal_dir, reflect_dir);
#ifdef ENABLE_SSR
	{
		// halo3-ng: reproject SSR sample back to prev-frame UV where compute wrote it.
		// ResourceSSRFinal is produced at [Present] referencing prev-frame geometry;
		// MV from the current forward pass brings the current fragment to the matching sample.
		const float2 viewport_size = float2(1920.0f, 1080.0f);
		float2 curr_uv   = (fragment_position.xy + float2(0.5f, 0.5f)) / viewport_size;
	#ifdef ACCUM_PIXEL_HAS_MV
		// Broken-MV guard (see ao_ssgi_inline.fx for rationale).
		float  mv_len_sq = dot(motion_vector, motion_vector);
		float  mv_scale  = 1.0f - saturate((mv_len_sq - 0.0004f) / 0.0005f);
		float2 reproj_uv = saturate(curr_uv - motion_vector * mv_scale);
	#else
		float2 reproj_uv = curr_uv;
	#endif
		// Bilinear 4-tap (Load-based) to kill integer-snap judder.
		float2 reproj_pix_f = reproj_uv * viewport_size - 0.5f;
		float2 pix_floor    = floor(reproj_pix_f);
		float2 frac         = saturate(reproj_pix_f - pix_floor);
		int2   pix00        = clamp(int2(pix_floor), int2(0, 0), int2(viewport_size) - 2);
		float4 g00 = ssr_buffer_glass.Load(int3(pix00 + int2(0, 0), 0));
		float4 g10 = ssr_buffer_glass.Load(int3(pix00 + int2(1, 0), 0));
		float4 g01 = ssr_buffer_glass.Load(int3(pix00 + int2(0, 1), 0));
		float4 g11 = ssr_buffer_glass.Load(int3(pix00 + int2(1, 1), 0));
		float4 gwb;
		gwb.x = (1.0f - frac.x) * (1.0f - frac.y);
		gwb.y = frac.x          * (1.0f - frac.y);
		gwb.z = (1.0f - frac.x) * frac.y;
		gwb.w = frac.x          * frac.y;
		float4 ssr_glass = g00 * gwb.x + g10 * gwb.y + g01 * gwb.z + g11 * gwb.w;
		float3 ssr_raw = ssr_glass.rgb / max(g_exposure.r, 1e-4f);
		reflection = lerp(reflection, ssr_raw, saturate(ssr_glass.a));
		g_roughness_passthrough = 0.05f;  // glass: near-mirror → high SSR confidence in trace
	}
#endif
	float4 out_color= float4(reflection, 0.0f);
	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);
}

void dynamic_light_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
#if DX_VERSION == 11	
	out s_dynamic_light_clip_distance clip_distance,
#endif
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD1,
	out float3 binormal : TEXCOORD2,
	out float3 tangent : TEXCOORD3,
	out float4 fragment_position_shadow : TEXCOORD5
#ifdef ACCUM_PIXEL_HAS_MV
	,out float2 motion_vector : TEXCOORD10
#endif
	)
{
	//output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);

	normal= vertex.normal;
	texcoord= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	fragment_position_shadow= mul(float4(vertex.position, 1.0f), Shadow_Projection);

#ifdef ACCUM_PIXEL_HAS_MV
	motion_vector = compute_motion_vector(position, vertex.position);
#endif
#if DX_VERSION == 11
	clip_distance = calc_dynamic_light_clip_distance(position);
#endif
}

accum_pixel dynamic_light_ps(
	SCREEN_POSITION_INPUT(fragment_position),
#if DX_VERSION == 11
	in s_dynamic_light_clip_distance clip_distance,
#endif
	in float2 original_texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD1,
	in float3 binormal : TEXCOORD2,
	in float3 tangent : TEXCOORD3,
	in float4 fragment_position_shadow : TEXCOORD5
#ifdef ACCUM_PIXEL_HAS_MV
	,in float2 motion_vector : TEXCOORD10
#endif
	)
{
#ifdef ACCUM_PIXEL_HAS_MV
	g_motion_vector_passthrough.xy = motion_vector;
	g_raw_depth_passthrough        = fragment_position.z;
#endif
	float4 out_color= float4(1.0f, 1.0f, 1.0f, 1.0f);
	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);
}

#endif //__GLASS_FX_H__
