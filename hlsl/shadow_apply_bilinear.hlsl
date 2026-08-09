#line 2 "source\rasterizer\hlsl\shadow_apply_bilinear.hlsl"

//@generate tiny_position_only

#ifndef pc
#define BILINEAR_SHADOWS
#endif // pc

#define FASTER_SHADOWS


// halo3-ng: identity for the $shadow_debug == 1 variant probe (see shadow_apply.hlsl).
#define SHADOW_VARIANT_TINT float3(0.0f, 0.0f, 1.0f)    // BLUE   = _bilinear
#include "shadow_apply.hlsl"
