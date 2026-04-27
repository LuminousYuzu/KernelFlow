#pragma once

#include <cuda_runtime.h>
#include <stdexcept>
#include <string>

// ---------------------------------------------------------------------------
// Error checking
// ---------------------------------------------------------------------------
#define CUDA_CHECK(call)                                                       \
    do {                                                                       \
        cudaError_t _err = (call);                                             \
        if (_err != cudaSuccess) {                                             \
            throw std::runtime_error(                                          \
                std::string("CUDA error at ") + __FILE__ + ":"                \
                + std::to_string(__LINE__) + " — "                            \
                + cudaGetErrorString(_err));                                   \
        }                                                                      \
    } while (0)

// ---------------------------------------------------------------------------
// Tuning knobs
// ---------------------------------------------------------------------------
static constexpr int kWarpSize = 32;
static constexpr int kBlockSize = 256;   // threads per block for 1-D token kernels
static constexpr int kNumWarps  = kBlockSize / kWarpSize;  // 8

// ---------------------------------------------------------------------------
// Warp-level float reduce (all lanes participate via xor-shift butterfly)
// ---------------------------------------------------------------------------
__device__ __forceinline__ float warp_reduce_sum(float v) {
#pragma unroll
    for (int mask = kWarpSize >> 1; mask > 0; mask >>= 1)
        v += __shfl_xor_sync(0xffffffff, v, mask);
    return v;
}

// ---------------------------------------------------------------------------
// Block-level float reduce using shared memory scratch
// Returns the sum on ALL threads (broadcast).
// Caller must provide smem[kNumWarps] in shared memory.
// ---------------------------------------------------------------------------
__device__ __forceinline__ float block_reduce_sum(float v, float* smem) {
    int wid = threadIdx.x >> 5;   // warp index
    int lid = threadIdx.x & 31;   // lane index

    v = warp_reduce_sum(v);
    if (lid == 0) smem[wid] = v;
    __syncthreads();

    // First warp gathers and reduces the per-warp partials
    v = (lid < kNumWarps) ? smem[lid] : 0.f;
    if (wid == 0) {
        v = warp_reduce_sum(v);
        if (lid == 0) smem[0] = v;  // broadcast slot
    }
    __syncthreads();

    return smem[0];
}
