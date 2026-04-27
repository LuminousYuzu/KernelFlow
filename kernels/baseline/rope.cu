#include "rope.cuh"
#include "../common.cuh"

// Each thread handles one (cos, sin) pair — i.e. one pair of elements
// (x[2i], x[2i+1]) for a single token.
//
// Grid is 1-D; total threads = N * (D/2).
__global__ void rope_kernel(
    float*       __restrict__ x,
    const float* __restrict__ cos_cache,
    const float* __restrict__ sin_cache,
    int N, int half_D)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= N * half_D) return;

    int pair  = idx % half_D;
    int token = idx / half_D;

    long long base_x  = (long long)token * (half_D * 2) + pair * 2;
    long long base_cs = (long long)token * half_D + pair;

    float x0 = x[base_x];
    float x1 = x[base_x + 1];
    float c   = cos_cache[base_cs];
    float s   = sin_cache[base_cs];

    x[base_x]     = x0 * c - x1 * s;
    x[base_x + 1] = x0 * s + x1 * c;
}

void launch_rope(
    float* x, const float* cos_cache, const float* sin_cache,
    int N, int D, cudaStream_t stream)
{
    int half_D    = D / 2;
    int total     = N * half_D;
    int grid_size = (total + kBlockSize - 1) / kBlockSize;
    rope_kernel<<<grid_size, kBlockSize, 0, stream>>>(x, cos_cache, sin_cache, N, half_D);
    CUDA_CHECK(cudaGetLastError());
}
