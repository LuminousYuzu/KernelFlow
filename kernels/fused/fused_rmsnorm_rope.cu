#include "fused_rmsnorm_rope.cuh"
#include "../common.cuh"

// ---------------------------------------------------------------------------
// Fused RMSNorm + RoPE
// ---------------------------------------------------------------------------
// Kernel layout: one CTA per token row.
//
// Phase 1 — RMS reduction (identical to the baseline rmsnorm kernel):
//   Each thread accumulates x[i]^2 for its slice of D, then we do a
//   two-level warp + block reduction to get rms_inv.
//
// Phase 2 — Fused normalize + rotate (no intermediate HBM write):
//   Each thread loads a pair (x[2i], x[2i+1]), scales by rms_inv * w[2i/2i+1],
//   then immediately applies the RoPE rotation using the pre-fetched cos/sin
//   values.  The normalised values never leave the registers, eliminating the
//   full [N, D] HBM round-trip that the two-kernel baseline requires.
//
// Shared memory budget: kNumWarps floats (8 × 4 = 32 bytes), tiny.
// ---------------------------------------------------------------------------
__global__ void fused_rmsnorm_rope_kernel(
    const float* __restrict__ x,
    const float* __restrict__ w,
    const float* __restrict__ cos_cache,
    const float* __restrict__ sin_cache,
    float*       __restrict__ out,
    int D, float eps)
{
    int row    = blockIdx.x;
    int half_D = D >> 1;

    const float* xr    = x         + (long long)row * D;
    const float* cosr  = cos_cache  + (long long)row * half_D;
    const float* sinr  = sin_cache  + (long long)row * half_D;
    float*       yr    = out        + (long long)row * D;

    __shared__ float smem[kNumWarps];

    // -----------------------------------------------------------------------
    // Phase 1: compute sum-of-squares → rms_inv
    // -----------------------------------------------------------------------
    float ss = 0.f;
    for (int i = threadIdx.x; i < D; i += kBlockSize)
        ss += xr[i] * xr[i];

    // block_reduce_sum returns the same value on all threads (they all read smem[0])
    ss = block_reduce_sum(ss, smem);
    float rms_inv = rsqrtf(ss / (float)D + eps);  // every thread computes identically

    // -----------------------------------------------------------------------
    // Phase 2: normalise in register, apply RoPE, write once to HBM
    // -----------------------------------------------------------------------
    // Each thread processes one (cos, sin) pair per iteration.
    // Stride by kBlockSize pairs = kBlockSize * 2 elements.
    for (int i = threadIdx.x; i < half_D; i += kBlockSize) {
        // Normalise (stays in registers — never hits HBM)
        float n0 = xr[2 * i]     * rms_inv * w[2 * i];
        float n1 = xr[2 * i + 1] * rms_inv * w[2 * i + 1];

        // RoPE rotation
        float c = cosr[i];
        float s = sinr[i];
        yr[2 * i]     = n0 * c - n1 * s;
        yr[2 * i + 1] = n0 * s + n1 * c;
    }
}

void launch_fused_rmsnorm_rope(
    const float* x, const float* w,
    const float* cos_cache, const float* sin_cache,
    float* out,
    int N, int D, float eps, cudaStream_t stream)
{
    fused_rmsnorm_rope_kernel<<<N, kBlockSize, 0, stream>>>(
        x, w, cos_cache, sin_cache, out, D, eps);
    CUDA_CHECK(cudaGetLastError());
}
