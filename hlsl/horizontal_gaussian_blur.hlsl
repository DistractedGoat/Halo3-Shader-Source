#line 2 "source\rasterizer\hlsl\horizontal_gaussian_blur.hlsl"

#include "global.fx"
#include "hlsl_vertex_types.fx"
#include "utilities.fx"
#include "postprocess.fx"
//@generate screen

LOCAL_SAMPLER_2D_IN_VIEWPORT_MAYBE(target_sampler, 0);

float4 default_ps(screen_output IN) : SV_Target
{
	float2 sample= IN.texcoord;

//	sample.y += texture_size.y / 2;
//	sample.x= sample0.x - 4.5 * texture_size.x;	// 4.5

	// Scale step size to maintain consistent screen-space bloom radius at any resolution.
	// Reference: Xbox 360 bloom buffer (1152x640 / 2 = 576x320).
	float blur_scale_x = max(1.0, (1.0/576.0) / ps_postprocess_pixel_size.x);
	float scaled_step = ps_postprocess_pixel_size.x * blur_scale_x;

	sample.x -= 5.0 * scaled_step;	// -5
	float3 color= (1/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// -4
	color += (10/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// -3
	color += (45/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// -2
	color += (120/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// -1
	color += (210/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// 0
	color += (252/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// +1
	color += (210/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// +2
	color += (120/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// +3
	color += (45/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// +4
	color += (10/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	sample.x += scaled_step;			// +5
	color += (1/1024.0) *convert_from_bloom_buffer(sample2D(target_sampler, sample));

	return convert_to_bloom_buffer(color);
}
