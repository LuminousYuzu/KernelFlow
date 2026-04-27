#pragma once

#include <cuda_runtime.h>

// Applies Rotary Position Embedding (RoPE) in-place.
//
// For each token n and each pair (2i, 2i+1):
//   out[n, 2i]   = x[n, 2i] * cos[n, i] - x[n, 2i+1] * sin[n, i]
//   out[n, 2i+1] = x[n, 2i] * sin[n, i] + x[n, 2i+1] * cos[n, i]
//
// x           : float32 device pointer [N, D], modified in-place
// cos_cache   : float32 device pointer [N, D/2]
// sin_cache   : float32 device pointer [N, D/2]
// N           : number of tokens
// D           : hidden dimension; must be even
// stream      : CUDA stream (default 0)
void launch_rope(
    float*       x,
    const float* cos_cache,
    const float* sin_cache,
    int          N,
    int          D,
    cudaStream_t stream = nullptr
);
