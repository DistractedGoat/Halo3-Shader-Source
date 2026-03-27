#ifndef __LIGHTMAP_SAMPLING_FX_H__
#define __LIGHTMAP_SAMPLING_FX_H__

#ifdef PC_CPU
#pragma once
#endif

/*
LIGHTMAP_SAMPLING.FX
Copyright (c) Microsoft Corporation, 2007. all rights reserved.
2/3/2007 3:24:00 PM (haochen)
	shared code for sampling light probe texture

halo3-ng: L2 lightmap sampling (March 2026)
	Dual-path L1/L2 decode with sentinel detection.
	L2 data packed into the stock 8 DXT5 slices (engine-native, no 3DMigoto).
	Stock L1 Luvw decode path always available (zero regression for unmodified BSPs).
	L2 path: 9 SH coefficients in 8 slices, detected by all-white sentinel in slice 7.
*/

float3 decode_bpp16_luvw(
	in float4 val0,
	in float4 val1,
	in float l_range)
{
	float L = val0.a * val1.a * l_range;
	float3 uvw = val0.xyz + val1.xyz;
	return (uvw * 2.0f - 2.0f) * L;
}

void sample_lightprobe_texture(
	in float2 lightmap_texcoord,
	out float3 sh_coefficients[9],
	out float3 dominant_light_direction,
	out float3 dominant_light_intensity,
	out bool l2_available)
{
	float3 lightmap_texcoord_bottom = float3(lightmap_texcoord, 0.0f);

	float4 sh_dxt_vector_0;
	float4 sh_dxt_vector_1;
	float4 sh_dxt_vector_2;
	float4 sh_dxt_vector_3;
	float4 sh_dxt_vector_4;
	float4 sh_dxt_vector_5;
	float4 sh_dxt_vector_6;
	float4 sh_dxt_vector_7;
	float4 sh_dxt_vector_8;
	float4 sh_dxt_vector_9;

	TFETCH_3D(sh_dxt_vector_0, lightmap_texcoord_bottom, lightprobe_texture_array, 0.5, 8);
	TFETCH_3D(sh_dxt_vector_1, lightmap_texcoord_bottom, lightprobe_texture_array, 1.5, 8);
	TFETCH_3D(sh_dxt_vector_2, lightmap_texcoord_bottom, lightprobe_texture_array, 2.5, 8);
	TFETCH_3D(sh_dxt_vector_3, lightmap_texcoord_bottom, lightprobe_texture_array, 3.5, 8);
	TFETCH_3D(sh_dxt_vector_4, lightmap_texcoord_bottom, lightprobe_texture_array, 4.5, 8);
	TFETCH_3D(sh_dxt_vector_5, lightmap_texcoord_bottom, lightprobe_texture_array, 5.5, 8);
	TFETCH_3D(sh_dxt_vector_6, lightmap_texcoord_bottom, lightprobe_texture_array, 6.5, 8);
	TFETCH_3D(sh_dxt_vector_7, lightmap_texcoord_bottom, lightprobe_texture_array, 7.5, 8);
	TFETCH_3D(sh_dxt_vector_8, lightmap_texcoord_bottom, dominant_light_intensity_map, 0.5, 2);
	TFETCH_3D(sh_dxt_vector_9, lightmap_texcoord_bottom, dominant_light_intensity_map, 1.5, 2);

	// Sentinel detection: L2 data has all-white slice 7
	bool is_l2 = (sh_dxt_vector_7.r > 0.95f && sh_dxt_vector_7.g > 0.95f &&
	              sh_dxt_vector_7.b > 0.95f && sh_dxt_vector_7.a > 0.95f);

	if (is_l2)
	{
		// ── L2 decode: 9 coefficients from 8 packed slices ──
		// Packing: slices 0-2 RGB = coeffs 0-2, alpha = coeff 3 (R,G,B scattered)
		//          slices 3-5 RGB = coeffs 4-6, alpha = coeff 7 (R,G,B scattered)
		//          slice 6 RGB = coeff 8, alpha = 1.0 (sentinel)
		//          slice 7 = all white (format sentinel)
		// Decode: coeff = (slice_val * 2.0 - 1.0) * l_range
		// Constants: constant_0.xyz = slots 0,1,2  constant_1.xyz = slots 3,4,5  constant_2.xyz = slots 6,7,8

		l2_available = true;

		sh_coefficients[0] = (sh_dxt_vector_0.rgb * 2.0f - 1.0f) * p_lightmap_compress_constant_0.x;
		sh_coefficients[1] = (sh_dxt_vector_1.rgb * 2.0f - 1.0f) * p_lightmap_compress_constant_0.y;
		sh_coefficients[2] = (sh_dxt_vector_2.rgb * 2.0f - 1.0f) * p_lightmap_compress_constant_0.z;

		sh_coefficients[3] = (float3(sh_dxt_vector_0.a, sh_dxt_vector_1.a, sh_dxt_vector_2.a) * 2.0f - 1.0f)
		                     * p_lightmap_compress_constant_1.x;

		sh_coefficients[4] = (sh_dxt_vector_3.rgb * 2.0f - 1.0f) * p_lightmap_compress_constant_1.z;
		sh_coefficients[5] = (sh_dxt_vector_4.rgb * 2.0f - 1.0f) * p_lightmap_compress_constant_2.x;
		sh_coefficients[6] = (sh_dxt_vector_5.rgb * 2.0f - 1.0f) * p_lightmap_compress_constant_2.z;

		sh_coefficients[7] = (float3(sh_dxt_vector_3.a, sh_dxt_vector_4.a, sh_dxt_vector_5.a) * 2.0f - 1.0f)
		                     * p_lightmap_compress_constant_2.y;

		sh_coefficients[8] = (sh_dxt_vector_6.rgb * 2.0f - 1.0f) * p_lightmap_compress_constant_2.z;
	}
	else
	{
		// ── Stock L1 Luvw decode: 4 pairs → 4 coefficients ──
		l2_available = false;

		sh_coefficients[0] = decode_bpp16_luvw(sh_dxt_vector_0, sh_dxt_vector_1, p_lightmap_compress_constant_0.x);
		sh_coefficients[1] = decode_bpp16_luvw(sh_dxt_vector_2, sh_dxt_vector_3, p_lightmap_compress_constant_0.y);
		sh_coefficients[2] = decode_bpp16_luvw(sh_dxt_vector_4, sh_dxt_vector_5, p_lightmap_compress_constant_0.z);
		sh_coefficients[3] = decode_bpp16_luvw(sh_dxt_vector_6, sh_dxt_vector_7, p_lightmap_compress_constant_1.x);
		sh_coefficients[4] = float3(0, 0, 0);
		sh_coefficients[5] = float3(0, 0, 0);
		sh_coefficients[6] = float3(0, 0, 0);
		sh_coefficients[7] = float3(0, 0, 0);
		sh_coefficients[8] = float3(0, 0, 0);
	}

	// Dominant light direction: luminance-weighted L1 direction (same for both paths)
	float3 dominant_light_dir_r = float3(-sh_coefficients[3].r, -sh_coefficients[1].r, sh_coefficients[2].r);
	float3 dominant_light_dir_g = float3(-sh_coefficients[3].g, -sh_coefficients[1].g, sh_coefficients[2].g);
	float3 dominant_light_dir_b = float3(-sh_coefficients[3].b, -sh_coefficients[1].b, sh_coefficients[2].b);
	dominant_light_direction = dominant_light_dir_r * 0.212656f + dominant_light_dir_g * 0.715158f + dominant_light_dir_b * 0.0721856f;
	dominant_light_direction = normalize(dominant_light_direction);

	// Dominant light intensity: evaluate L1 SH in dominant direction (matches stock Xbox approach)
	// This must be consistent with ravi_order_2_with_dominant_light's subtract/re-add cycle
	float4 dir_eval = float4(0.2820948f,
	                         -0.4886025f * dominant_light_direction.y,
	                          0.4886025f * dominant_light_direction.z,
	                         -0.4886025f * dominant_light_direction.x);
	dominant_light_intensity.r = dot(dir_eval, float4(sh_coefficients[0].r, sh_coefficients[1].r, sh_coefficients[2].r, sh_coefficients[3].r));
	dominant_light_intensity.g = dot(dir_eval, float4(sh_coefficients[0].g, sh_coefficients[1].g, sh_coefficients[2].g, sh_coefficients[3].g));
	dominant_light_intensity.b = dot(dir_eval, float4(sh_coefficients[0].b, sh_coefficients[1].b, sh_coefficients[2].b, sh_coefficients[3].b));
	dominant_light_intensity *= 0.7161972f;
}

#endif //__LIGHTMAP_SAMPLING_FX_H__
