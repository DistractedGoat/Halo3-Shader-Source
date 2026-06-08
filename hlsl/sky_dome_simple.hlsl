#line 2 "source\rasterizer\hlsl\write_depth.hlsl"

#include "global.fx"
#include "hlsl_constant_mapping.fx"
#include "deform.fx"
#include "utilities.fx"

#define LDR_ALPHA_ADJUST g_exposure.w
#define HDR_ALPHA_ADJUST g_exposure.b
#define DARK_COLOR_MULTIPLIER g_exposure.g
#include "render_target.fx"

//@generate sky

struct VS_INPUT
{
	float3 vPos : POSITION;
	float3 vColor : TEXCOORD0;
	float3 vNormal : NORMAL;
};

struct VS_OUTPUT
{
	float4 pos : SV_Position;
	float3 color : TEXCOORD0;
	float3 normal : TEXCOORD1;
};

VS_OUTPUT default_vs(VS_INPUT input)
{
	VS_OUTPUT output;

	float4 world_pos;
	world_pos.xyz= transform_point(float4(input.vPos, 1.0f), Nodes[0]);
	world_pos.w= 1.0f;
	output.pos= mul(world_pos, View_Projection);
	output.color= input.vColor;
	output.normal= normalize(input.vPos);

	// halo3-ng: anchor AtmosphereVS (v_atmosphere_constant_0) in this VS's RDEF so the
	// engine binds it to vs-cb2 (pinned slot) for the sky-dome draw. sky_dome_simple is
	// @generate sky — the engine uploads the scenario SKY ATMOSPHERE here (not a per-
	// BSP cluster atmosphere), and this draw runs exactly once per frame. 3DMigoto's
	// [ShaderOverrideSkyDomeSimpleVS] captures vs-cb2 post-draw into ResourceAtmosphereCB,
	// giving a deterministic scenario-global SUN_DIR for SSS contact-shadow tracing.
	// DCE-safe no-op: product with 1e-30 is denormalised to 0 in the position output.
	output.pos.x += v_atmosphere_constant_0.x * 1e-30f;

	return output;
}

accum_pixel default_ps(VS_OUTPUT input)
{

	float4 out_color= float4(input.color * g_exposure.rrr, 1.0f);

    float3 sun= pow(max(dot(p_lighting_constant_0.xyz, normalize(input.normal)), 0.0f), p_lighting_constant_0.w) * p_lighting_constant_1.rgb;
    out_color.rgb+= sun;

	return convert_to_render_target(out_color, true, false);
		
}
