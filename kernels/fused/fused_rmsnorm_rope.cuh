#pragma once

#include <cuda_runtime.h>

// Fused RMSNorm + RoPE kernel — Milestone 1.
//
// Equivalent to launch_rmsnorm(x, w, tmp, ...) followed by
// launch_rope(tmp, cos_cache, sin_cache, ...), but without materialising
// the intermediate normalised tensor to HBM.  Saves one full read+write
// of [N, D] float32, which at D=4096 and N=2048 is ~64 MB of bandwidth.
//
// x           : float32 device pointer [N, D]  (read-only)
// w           : float32 device pointer [D]      (RMSNorm scale weights)
// cos_cache   : float32 device pointer [N, D/2]
// sin_cache   : float32 device pointer [N, D/2]
// out         : float32 device pointer [N, D]  (write-only)
// N           : number of tokens
// D           : hidden dimension; must be even and <= 8192
// eps         : RMSNorm epsilon (default 1e-6)
// stream      : CUDA stream (default 0)
void launch_fused_rmsnorm_rope(
    const float* x,
    const float* w,
    const float* cos_cache,
    const float* sin_cache,
    float*       out,
    int          N,
    int          D,
    float        eps    = 1e-6f,
    cudaStream_t stream = nullptr
);
