#ifndef _GLOBAL_FX_
#define _GLOBAL_FX_

// halo3-ng: enable motion vector output in forward pass shaders
#define ENABLE_MOTION_VECTORS 1
// halo3-ng: enable SSR injection + roughness MRT (SV_Target4) in forward pass shaders
#define ENABLE_SSR 1
#define USE_SSR ENABLE_SSR   // alias for environment_mapping.fx legacy guard

#include "global_systemvalue.fx"
#include "global_texture.fx"
#include "global_parameters.fx"
#include "global_cbuffer.fx"
#include "global_localsampler.fx"
#include "global_registers.fx"
#include "global_texture_sampling.fx"

#endif
