#line 2 "source\rasterizer\hlsl\decorators.hlsl"

#define IGNORE_SKINNING_NODES

#include "global.fx"
#include "wind.fx"

#include "hlsl_constant_mapping.fx"
//#include "deform.fx"
#include "utilities.fx"

//#define LDR_ONLY
#define LDR_ALPHA_ADJUST g_exposure.w
#define HDR_ALPHA_ADJUST g_exposure.b
#define DARK_COLOR_MULTIPLIER g_exposure.g
// Gap filler approach: fxc compacts SV_Target outputs when there are gaps, so SV_Target3 alone
// (without SV_Target2) would compile to o2, matching ShaderRegexBindMVRT instead of DepthCapture.
// _mv_gap at SV_Target2 holds the slot so rawDepth stays at SV_Target3 (o3).
// ShaderRegexBindMVRT (dcl_output o2) binds RT2=MV (receives zeros — correct, no motion), RT3=Depth.
// ShaderRegexDepthCapture (dcl_output o3) also matches and binds RT3=Depth (redundant, harmless).
#include "render_target.fx"
#include "albedo_pass.fx"

#include "atmosphere.fx"
#include "quaternions.fx"
#include "decorators_registers.fx"

#ifdef VERTEX_SHADER
#define SIMPLE_LIGHT_DATA v_simple_lights
#define SIMPLE_LIGHT_COUNT v_simple_light_count.x
#undef dynamic_lights_use_array_notation			// decorators dont use array notation, they use loop-friendly notation
#include "simple_lights.fx"
#endif // VERTEX_SHADER

#include "atmosphere.fx"
#include "decorators.h"
// halo3-ng (June 2026): decorators are a NORMAL ao_ssgi_inline consumer (foliage parity). The
// VS computes a real per-vertex camera MV (see static-decorator VS below), so the consumer
// reprojects the AO/GI/SSS it samples correctly.
// Reveal-gated disocclusion (June 2026): the consumer now distinguishes a genuine reveal from a
// stable foreground silhouette per-pixel (rv_reveal, FSR reconstructed-prev-depth). Decorator
// leaf edges are stable cliffs (rv_reveal==0) → strict two-sided accept + no ring inpaint = clean,
// exactly as the old DECORATOR_LEGACY_DEPTH_ACCEPT special-case did, but now via the unified path.
// The special-case #define is therefore removed — decorators are a normal consumer.
#include "ao_ssgi_inline.fx"

// decorator shader is defined as 'world' vertex type, even though it really doesn't have a vertex type - it does its own custom vertex fetches
//@generate decorator

/*
	POSITION	0:		vertex position
	TEXCOORD	0:		vertex texcoord
	POSITION	1:		instance position
	NORMAL		1:		instance quaternion
	COLOR		1:		instance color
	POSITION	2:		vertex index
*/

#define vertex_compression_scale Position_Compression_Scale
#define vertex_compression_offset Position_Compression_Offset
#define texture_compression UV_Compression_Scale_Offset


LOCAL_SAMPLER_2D(diffuse_texture, 0);			// pixel shader


#ifdef DECORATOR_EDIT


#define pc_ambient_light p_lighting_constant_0
#define selection_point p_lighting_constant_1
#define selection_curve p_lighting_constant_2
#define selection_color p_lighting_constant_3


struct interpolators
{
	float4	position			:	SV_Position;
	float2	texcoord			:	TEXCOORD0;
	float3	world_position		:	TEXCOORD1;
};

interpolators default_vs(
	float4 vertex_position : POSITION,
	float2 vertex_texcoord : TEXCOORD0)
{
	interpolators OUT;

	// decompress position
	vertex_position.xyz= vertex_position.xyz * vertex_compression_scale.xyz + vertex_compression_offset.xyz;

	OUT.world_position= quaternion_transform_point(instance_quaternion, vertex_position.xyz) * instance_position_and_scale.w + instance_position_and_scale.xyz;
	OUT.position= mul(float4(OUT.world_position.xyz, 1.0f), View_Projection);
	OUT.texcoord= vertex_texcoord.xy * texture_compression.xy + texture_compression.zw;
	return OUT;
}

accum_pixel default_ps(
	SCREEN_POSITION_INPUT(screen_position),
	in float2 texcoord : TEXCOORD0,
	in float3 world_position : TEXCOORD1)
{
//#define pc_ambient_light p_lighting_constant_0
//#define selection_point p_lighting_constant_1
//#define selection_curve p_lighting_constant_2
//#define selection_color p_lighting_constant_3

	float4 diffuse_albedo= sampleBiasGlobal2D(diffuse_texture, texcoord);
	clip(diffuse_albedo.a - k_decorator_alpha_test_threshold);				// alpha test
	
	float4 color= diffuse_albedo * pc_ambient_light * g_exposure.rrrr;

	// blend in selection cursor	
	float dist= distance(world_position, selection_point.xyz);
	float alpha= step(dist, selection_point.w);
	alpha *= selection_color.w;
	color.rgb= lerp(color.rgb, selection_color.rgb, alpha);
	
	return convert_to_render_target(color, true, false);
}
	


#else	// DECORATOR_EDIT


#ifdef VERTEX_SHADER

void default_vs(
#ifndef pc
	in int index						:	SV_VertexID,
#else
	float4 vertex_position : POSITION,
	float2 vertex_texcoord : TEXCOORD0,
	float3 vertex_normal   : NORMAL,

#if DX_VERSION == 11
	uint4 instance_position_int : TEXCOORD1,
#else	
	float4 instance_position   : TEXCOORD1,
#endif
	float4 instance_quaternion : TEXCOORD2,
	float4 instance_color      : TEXCOORD3,
#endif	
	out float4	out_position			:	SV_Position,
	out float4	out_texcoord			:	TEXCOORD0,
	out float4	out_ambient_light		:	TEXCOORD1,
	out float4	out_inscatter			:	TEXCOORD2
#ifdef pc
   ,out float3	out_normal  			:	TEXCOORD3
   ,out float3	out_world_position		:	TEXCOORD4	// halo3-ng: for decorator MV reconstruction
#endif
#if defined(pc) && defined(ACCUM_PIXEL_HAS_MV)
   ,out noperspective float2	out_motion_vector	:	TEXCOORD5	// halo3-ng: VS-computed MV (foliage parity)
#endif
   )
{
#ifdef pc
	out_world_position = 0.0f;	// halo3-ng: default (overwritten below for non-faded verts)
#endif
#if defined(pc) && defined(ACCUM_PIXEL_HAS_MV)
	out_motion_vector = float2(0.0f, 0.0f);	// halo3-ng: default for faded-vert early-out
#endif
	
	
#ifndef pc
    // what instance are we? - compute index to fetch from the instance stream
	int instance_index = floor(( index + 0.5 ) / instance_data.x);
#endif

#if defined(pc) && (DX_VERSION == 9)
	// convert fron signed short to unsigned
	// PC doesn't supoort USHORT format
	instance_position += 32767;
#elif DX_VERSION == 11
	float4 instance_position = instance_position_int;	// + 32767;
#else	
	// fetch instance data
	float4 instance_position;
	asm
	{
	    vfetch instance_position,	instance_index, position1;
	};
#endif	
	instance_position.xyz= instance_position.xyz * instance_compression_scale.xyz + instance_compression_offset.xyz;
	
	float3 camera_to_vertex= (instance_position.xyz - Camera_Position);
	float distance= sqrt(dot(camera_to_vertex, camera_to_vertex));
	out_ambient_light.a= saturate(distance * LOD_constants.x + LOD_constants.y);
	
	// if the decorator is not completely faded
#ifndef pc
	[ifAll]
#endif // pc
	if (out_ambient_light.a <= k_decorator_alpha_test_threshold)
	{
		out_position= 0.0f;
		out_texcoord= 0.0f;
		out_ambient_light.rgba= 0.0f;
		out_inscatter= 0.0f;
		return;
	}
	
#ifdef pc
   // convert fron unsigned to signed PC doesn't supoort BYTE4N format
   instance_quaternion = instance_quaternion * 2 - 1;
//   instance_color = 1;
   
#else	
	float4 instance_quaternion;
	float4 instance_color;
	asm
	{
	    vfetch instance_quaternion, instance_index, normal1;
       vfetch instance_color, instance_index.x, color1;
	};
#endif	

	float shifted_bits= instance_position.w / 256;				// integer part == type_index, fractional part == motion_scale
	float type_index= floor(shifted_bits);						// type_index = high 8 bits
	float motion_scale= shifted_bits - type_index;				// motion scale = low 8 bits	(aka sun intensity)

#ifndef pc
	// compute the index index to fetch from the index buffer stream
	float index_index = index + (type_index - instance_index) * instance_data.x;
	float vertex_index= index_index;							// unindexed:  vertex_index == index_index
#endif		

#ifndef pc
	// fetch the actual vertex
	float4 vertex_position;
	float2 vertex_texcoord;
	float3 vertex_normal = -1;
	asm
	{
		vfetch vertex_position,	vertex_index.x, position0;
		vfetch vertex_texcoord.xy, vertex_index.x, texcoord0;
		vfetch vertex_normal.xyz, vertex_index.x, normal0;
	};
#endif		
	vertex_position.xyz= vertex_position.xyz * vertex_compression_scale.xyz + vertex_compression_offset.xyz;
	vertex_texcoord= vertex_texcoord.xy * texture_compression.xy + texture_compression.zw;
	
	float height_scale= 1.0f;
	float2 wind_vector= 0.0f;

#ifdef DECORATOR_WIND
	// apply wind
	wind_vector= sample_wind(instance_position.xy);
	motion_scale *= saturate(vertex_position.z);										// apply model motion scale (increases linearly up to the top)
	wind_vector.xy *= motion_scale;														// modulate wind vector by motion scale
	
	// calculate height offset	(change in height because of bending from wind)
	float wind_squared= dot(wind_vector.xy, wind_vector.xy);							// how far did we move?
	float instance_scale= dot(instance_quaternion.xyzw, instance_quaternion.xyzw);		// scale value
	float height_squared= (instance_scale * vertex_position.z) + 0.01;
	height_scale= sqrt(height_squared / (height_squared + wind_squared));
#endif // DECORATOR_WIND

#ifdef DECORATOR_WAVY
	float phase= vertex_position.z * wave_flow.w + wind_data2.w * wave_flow.z + dot(instance_position.xy, wave_flow.xy);
	float wave= motion_scale * saturate(abs(vertex_position.z)) * sin(phase);
	vertex_position.x += wave;
#endif // DECORATOR_WAVY

	// combine the instance position with the mesh position
	float4 world_position= vertex_position;
	vertex_position.z *= height_scale;
	
	float3 rotated_position= quaternion_transform_point(instance_quaternion, vertex_position.xyz);
	world_position.xyz= rotated_position + instance_position.xyz;										// max scale of 2.0 is built into vertex compression	
	world_position.xy += wind_vector.xy * height_scale;													// apply wind vector after transformation

	out_position= mul(float4(world_position.xyz, 1.0f), View_Projection);

#ifdef pc
	out_world_position = world_position.xyz;	// halo3-ng: for prev-VP MV reconstruction in PS
#endif

#if defined(pc) && defined(ACCUM_PIXEL_HAS_MV)
	// halo3-ng (June 2026): per-vertex camera MV, computed IN THE VS like foliage
	// (compute_motion_vector, motion_vectors.fx) — inlined here because #include
	// "motion_vectors.fx" crashes the decorator tag compile. Decorators are static world
	// geometry, so camera motion IS the motion vector. Computing the prev-VP delta on the
	// VS's exact world_position + out_position (rather than reconstructing in the PS from an
	// interpolated world position) is what makes it correct: both sides use the same
	// world_position, so the large-absolute-coordinate magnitude cancels and a static camera
	// yields MV=0 (the prior PS reconstruction failed exactly this test — the dim-blue beacon).
	{
		float4 dec_pvp_r0 = sampler_prev_vp_matrix.t.Load(int3(0, 0, 0));
		if (dec_pvp_r0.x != 0.0f || dec_pvp_r0.y != 0.0f || dec_pvp_r0.z != 0.0f || dec_pvp_r0.w != 0.0f)
		{
			float4x4 dec_prev_vp = float4x4(
				dec_pvp_r0,
				sampler_prev_vp_matrix.t.Load(int3(1, 0, 0)),
				sampler_prev_vp_matrix.t.Load(int3(2, 0, 0)),
				sampler_prev_vp_matrix.t.Load(int3(3, 0, 0)));
			float4 dec_prev_clip = mul(float4(world_position.xyz, 1.0f), dec_prev_vp);
			if (abs(dec_prev_clip.w) > 1e-6f && abs(out_position.w) > 1e-6f)
			{
				float2 dec_curr_ndc = out_position.xy / out_position.w;
				float2 dec_prev_ndc = dec_prev_clip.xy / dec_prev_clip.w;
				// UV-space MV: X same sign as NDC, Y flipped (NDC Y-up -> UV Y-down).
				out_motion_vector = (dec_curr_ndc - dec_prev_ndc) * float2(0.5f, -0.5f);
				// Weapon/first-person kill band (matches motion_vectors.fx); harmless for
				// world-depth decorators (out_position.w >> 0.45 -> full MV).
				out_motion_vector *= smoothstep(0.30f, 0.45f, out_position.w);
			}
		}
	}
#endif

#ifdef DECORATOR_SHADED_LIGHT
	float3 world_normal= rotated_position;
#else
	float3 world_normal= quaternion_transform_point(instance_quaternion, vertex_normal.xyz);
#endif		
	world_normal= normalize(world_normal);					// get rid of scale

	// halo3-ng (April 23 2026) — reverted to VANILLA lighting normal behaviour:
	//   · DECORATOR_DYNAMIC_LIGHTS uses `two_sided_normal` (camera-facing flip on the
	//     geometric normal) so the simple-light integrator always sees a front-face.
	//   · DECORATOR_DOMINANT_LIGHT uses `world_normal` (raw geometric normal) so the
	//     sun lobe respects true orientation.
	// The previous origin-out "dome" normal produced a tuft-of-grass response but made
	// dynamic lights ignore decorator orientation entirely and biased the sun lobe away
	// from the actual per-sheet geometry. Reverting restores Bungie's intended per-sheet
	// shading at the cost of the dome softness — any follow-up softening should live in
	// the PS or a post-process, not by mutating the VS lighting normal.

	float3 fragment_to_camera_world= Camera_Position - world_position.xyz;
	float3 view_dir= normalize(fragment_to_camera_world);

	float3 diffuse_dynamic_light= 0.0f;
#ifdef DECORATOR_DYNAMIC_LIGHTS
	// point normal towards camera (two-sided only!)
	float3 two_sided_normal= world_normal * sign(dot(world_normal, fragment_to_camera_world));

	// accumulate dynamic lights
	calc_simple_lights_analytical_diffuse_translucent(
		world_position,
		two_sided_normal,
		translucency,
		diffuse_dynamic_light);
#endif // DECORATOR_DYNAMIC_LIGHTS

#ifdef DECORATOR_DOMINANT_LIGHT
	diffuse_dynamic_light +=
		motion_scale * sun_color * calc_diffuse_lobe(world_normal, sun_direction, translucency);
#endif // DECORATOR_DOMINANT_LIGHT

	out_texcoord.xy= vertex_texcoord;
	out_texcoord.zw= 0.0f;	
	out_ambient_light.rgb= (instance_color.rgb * exp2(instance_color.a * 63.75 - 31.75)) + diffuse_dynamic_light;

#ifdef DECORATOR_SHADED_LIGHT
	out_texcoord.z= dot(rotated_position, sun_direction);				// position relative to decorator center, projected onto sun direction
//	out_texcoord.w= dot(rotated_position, rotated_position);			// distance of position from decorator center (normalization term) - dividing z by w will give us a per-pixel cosine term
	out_texcoord.w= sqrt(dot(rotated_position, rotated_position));		// distance of position from decorator center (normalization term) - dividing z by w will give us a per-pixel cosine term
	out_texcoord.z= out_texcoord.z / out_texcoord.w;					// normalized projection == cosine lobe
#endif // DECORATOR_SHADED_LIGHT
	
	float3 extinction;
	compute_scattering(
		Camera_Position,
		world_position.xyz,
		extinction,
		out_inscatter.xyz);
	out_inscatter.w= 0.0f;
	
   out_ambient_light.rgb *= extinction;

#ifdef pc
	out_inscatter.w= out_position.w;
   out_normal = world_normal;
#endif // pc
}

#endif // VERTEX_SHADER


// ***************************************
// WARNING   WARNING   WARNING
// ***************************************
//    be careful changing this code.  it is optimized to use very few GPRs + interpolators
//			current optimized shader:	3 GPRs

// Extends albedo_pixel with SV_Target3 for depth capture.
// ShaderRegexDepthCapture (pattern: dcl_output o3) binds ResourceCurrentDepthCopy as RT3
// automatically when this compiled shader has dcl_output o3 — no d3dx.ini hash changes needed.
#ifdef pc
struct decorator_pixel
{
	float4 albedo_specmask : SV_Target0;
	float4 normal          : SV_Target1;
#ifdef ACCUM_PIXEL_HAS_DEPTH
	float4 _mv_gap         : SV_Target2;  // gap filler — prevents fxc from compacting SV_Target3→o2
	float  rawDepth        : SV_Target3;
#endif
#ifdef ACCUM_PIXEL_HAS_ROUGHNESS
	float  roughness       : SV_Target4;  // PBR roughness — halo3-ng SSR
	// Decorator stamp v2 (Aug 2026): dedicated RT (ResourceDecoratorStamp, R16G16_FLOAT via
	// [ShaderRegexBindMVRT] o5). The old _mv_gap.zw stamp was structurally broken: o2.w is an
	// ALPHA channel, and the global blend state's alpha equation zeroed every .w write, so the
	// stamp depth never arrived (this is why every depth-validated composite variant rejected
	// visible decorators). R16G16 has COLOR channels only — both blend with the color equation,
	// scaled by the SAME alpha factor -> homogeneous, stamp.y/stamp.x recovers exact rawDepth.
	// Exclusive by write mask: no other forward PS declares SV_Target5.
	// (Nested in ROUGHNESS so o4 is always declared beneath o5 — fxc compacts output gaps.)
	float2 stamp           : SV_Target5;
#endif
};
#endif

#ifdef pc
decorator_pixel
#else   
float4 
#endif 
default_ps(
	SCREEN_POSITION_INPUT(screen_position),
	in float4	texcoord			:	TEXCOORD0,								// z coordinate is unclamped cosine lobe for the 'sun'
	in float4	ambient_light		:	TEXCOORD1,
	in float4	inscatter			:	TEXCOORD2
#ifdef pc
   ,in float3	normal   			:	TEXCOORD3
   ,in float3	world_position		:	TEXCOORD4	// halo3-ng: for expectedPrevZ depth test
#endif
#if defined(pc) && defined(ACCUM_PIXEL_HAS_MV)
   ,in noperspective float2	motion_vector	:	TEXCOORD5	// halo3-ng: VS-computed camera MV
#endif
   ) : SV_Target0					// w unused
{
	float4 light= ambient_light;
#ifdef DECORATOR_SHADED_LIGHT
	{
		[isolate]				// this reduces GPRs by one	
		light.rgb *= saturate(texcoord.z) * contrast.y + contrast.x;
	}
#endif
   
#ifdef pc
   float position_w= inscatter.w;
   inscatter.w= 0;
#endif // pc

	texcoord= sampleBiasGlobal2D(diffuse_texture, texcoord.xy);								// ###HACK warning: I should use a new variable to hold the albedo sample, but re-using texcoord makes the stupid HLSL compiler generate one less GPR

	// halo3-ng (July 2026, zero-lag Stage 1.5): decorators NO LONGER consume AO/GI/SSS in-shader.
	// They draw inside the albedo PRE-PASS (frame analysis July 25: decorator draws at 101+ of
	// the frame, before the effect chain's boundary anchor), so any in-shader consumption is
	// structurally one frame stale — under the zero-lag hook that read back blade-level self-AO
	// noise from the decorator-inclusive boundary depth. Their AO is now applied at DISPLAY time
	// in final_composite_base.hlsl, masked to decorator pixels via the boundary-DSV vs
	// SV_Target3 depth difference, using the CURRENT frame's AO buffer (zero-lag by
	// construction). The VS-computed camera MV (TEXCOORD5) is retained — the o2 MV write below
	// still feeds the compute temporals.
#if defined(pc) && defined(ACCUM_PIXEL_HAS_MV)
	float2 decorator_mv = motion_vector;
#else
	float2 decorator_mv = float2(0.0f, 0.0f);
#endif
	float3 diffuse_lit = texcoord.rgb * light.rgb;
	float4 color = float4(diffuse_lit + inscatter.rgb, texcoord.a);

#if DX_VERSION == 11
	clip(color.a - k_decorator_alpha_test_threshold);								// alpha clip on D3D11
#endif

	color.rgb *= g_exposure.rrr;
#if DX_VERSION == 9
	color.a *= (0.5f / k_decorator_alpha_test_threshold);						// convert alpha for alpha-to-coverage (0.5f based)
#endif

#ifdef pc
	albedo_pixel base = convert_to_albedo_target(color, normal, position_w);
	decorator_pixel pix;
	pix.albedo_specmask = base.albedo_specmask;
	pix.normal          = base.normal;
#ifdef ACCUM_PIXEL_HAS_DEPTH
	// halo3-ng (June 2026): write the REAL VS-computed camera MV (decorator_mv) to SV_Target2 ->
	// ResourceMotionVectors (decorators match [ShaderRegexBindMVRT], dcl_output o2). Was 0, which
	// left the compute temporals + de-cross pre-fill with NO motion at decorator pixels -> decorator
	// AO/GI/SSS history couldn't track under camera motion (the "decorators lag worse" bug). The
	// consumer is unaffected (it reads the motion_vector PARAM, not this buffer) -> no double-reproj.
	// Name stays _mv_gap (the fxc-compaction gap-filler); non-zero keeps it o2, o3 depth unchanged.
	// .z = 1.0 (July 25 2026): DECORATOR STAMP for the display-time AO composite in
	// final_composite_base.hlsl. Every other forward PS declares SV_Target2 as float2, so their
	// write mask can never touch .z — the stamp is exclusive to decorators by construction, and
	// the per-frame MV clear zeroes it. (The depth-difference classifier it replaces was void:
	// decorator depth reaches BOTH the DSV path and SV_Target3 — rawDepth below — so the two
	// depth buffers are equal at decorator pixels.)
	// .w = the decorator's OWN raw depth: the composite validates the stamp against
	// the final SV_Target3 depth, so opaque occluders drawn over a stamped pixel (FP weapon,
	// characters) overwrite SV_Target3 with their depth, the values disagree, and the stamp is
	// rejected. Without this the stamp means "a decorator drew here at SOME point this frame" —
	// the write-mask exclusivity that protects .z from other draws also stops them clearing it.
	pix._mv_gap         = float4(decorator_mv, 1.0f, screen_position.z);
	pix.rawDepth        = screen_position.z;
#endif
#ifdef ACCUM_PIXEL_HAS_ROUGHNESS
	pix.roughness = 0.75f;  // vegetation/ground cover: diffuse-like (matches terrain non-specular default)
	// Stamp v2: .x = presence flag, .y = raw depth. Both arrive x blendFactor (color equation)
	// -> homogeneous; the resolve decodes depth as .y/.x. See struct comment. The _mv_gap.zw
	// stamp above is retained but DEAD (alpha-equation blending zeroes .w — see struct comment).
	pix.stamp = float2(1.0f, screen_position.z);
#endif
	return pix;
#else
	return color;
#endif // pc
}

#endif // DECORATOR_EDIT

