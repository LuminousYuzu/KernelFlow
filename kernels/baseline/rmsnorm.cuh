#pragma once

#include <cuda_runtime.h>

// Applies RMSNorm in-place along the last dimension.
//
// out[n, d] = (x[n, d] / rms(x[n, :])) * w[d]
// where rms(x) = sqrt(mean(x^2) + eps)
//
// x, w, out : float32 device pointers
// N         : number of tokens (rows)
// D         : hidden dimension (columns); must be > 0
// eps       : numerical stability term (default 1e-6)
// stream    : CUDA stream (default 0)
void launch_rmsnorm(
    const float* x,
    const float* w,
    float*       out,
    int          N,
    int          D,
    float        eps    = 1e-6f,
    cudaStream_t stream = nullptr
);
