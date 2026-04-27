#include "rmsnorm.cuh"
#include "../common.cuh"

// One block per token row.  Each thread strides across the hidden dim.
// Shared memory layout: smem[0..kNumWarps-1] holds per-warp partial sums;
// after reduction smem[0] holds rms_inv and is broadcast to all threads.
__global__ void rmsnorm_kernel(
    const float* __restrict__ x,
    const float* __restrict__ w,
    float*       __restrict__ out,
    int D, float eps)
{
    int row = blockIdx.x;
    const float* xr = x   + (long long)row * D;
    float*       yr = out  + (long long)row * D;

    __shared__ float smem[kNumWarps];

    // Accumulate sum-of-squares across this thread's slice of D
    float ss = 0.f;
    for (int i = threadIdx.x; i < D; i += kBlockSize)
        ss += xr[i] * xr[i];

    // block_reduce_sum returns the same value on all threads (they all read smem[0])
    ss = block_reduce_sum(ss, smem);
    float rms_inv = rsqrtf(ss / (float)D + eps);  // every thread computes identically
    for (int i = threadIdx.x; i < D; i += kBlockSize)
        yr[i] = xr[i] * rms_inv * w[i];
}

void launch_rmsnorm(
    const float* x, const float* w, float* out,
    int N, int D, float eps, cudaStream_t stream)
{
    rmsnorm_kernel<<<N, kBlockSize, 0, stream>>>(x, w, out, D, eps);
    CUDA_CHECK(cudaGetLastError());
}
