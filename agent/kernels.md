# Kernel Design Context — KernelFlow

Reference for everything in `kernels/`, `benchmarks/`, `tests/`, `setup.py`, and `CMakeLists.txt`.
Read this before touching any kernel code.

---

## Current milestone status (as of 2026-04-26)

| Milestone | Kernel | Status | Gate |
|-----------|--------|--------|------|
| 1 | `fused_rmsnorm_rope` | **Scaffolded, not compiled on hardware yet** | ≥ 1.5× speedup, ≤ 1e-5 error |
| 2 | `fused_silu_mul` | Not started — wait for M1 to pass on real GPU | ≥ 1.3× speedup, ≤ 1e-5 error |
| 3 | `fused_attention` | Not started | ≥ 2.0× speedup, ≤ 1e-4 error |

**Rule:** Do not start Milestone 2 until `build/bench_all` clears the 1.5× gate on the actual GPU PC hardware.

---

## What exists in kernels/

| File | What it is |
|------|-----------|
| `kernels/common.cuh` | Shared primitives: `warp_reduce_sum()`, `block_reduce_sum()`. Used by all kernel implementations. |
| `kernels/baseline/rmsnorm.cu/.cuh` | Unfused RMSNorm. One block per token row. Shared-memory two-level warp+block reduction. |
| `kernels/baseline/rope.cu/.cuh` | Unfused RoPE. One thread per rotation pair `(2i, 2i+1)`. In-place. |
| `kernels/fused/fused_rmsnorm_rope.cu/.cuh` | Milestone 1 fused kernel. Two-phase: reduction → normalize+rotate in registers. |
| `kernels/extension.cu` | pybind11/PyTorch wrapper. Exposes `kernelflow.baseline_rmsnorm`, `kernelflow.baseline_rope`, `kernelflow.fused_rmsnorm_rope`. |

---

## Why the fused kernel saves memory bandwidth

The baseline runs two separate kernel launches:
1. `launch_rmsnorm` writes a full `[N, D]` float32 tensor to HBM
2. `launch_rope` reads that tensor back from HBM

The fused kernel eliminates step 1. After computing `rms_inv` in phase 1 (shared-memory reduction), phase 2 computes the normalised value in registers and immediately applies the RoPE rotation — never writing the intermediate normalised tensor to HBM. The first and only HBM write is the final rotated output.

**Concrete savings at N=2048, D=4096:**
- Eliminated write: 2048 × 4096 × 4 bytes = 32 MB
- Eliminated read: same = 32 MB
- Total per call: **~64 MB of HBM traffic eliminated**

This is the quantitative argument for the 1.5× speedup gate.

---

## Kernel design decisions — do not re-litigate

### Why kBlockSize = 256 (not 512 or 1024)
256 threads = 8 warps. Shared memory for the reduction scratch is `8 × sizeof(float)` = 32 bytes — essentially free. Larger block sizes increase register pressure and reduce occupancy (fewer blocks can reside on an SM simultaneously). For hidden dims up to D=8192, 256 threads with a stride loop is sufficient to saturate HBM bandwidth.

### Why block_reduce_sum returns the same value to ALL threads
The implementation writes the total into `smem[0]` then calls `__syncthreads()` before returning `smem[0]`. All threads therefore return the same float. This means the caller can compute `rsqrtf(ss / D + eps)` independently on every thread without another shared-memory write + sync cycle — one fewer synchronisation barrier per kernel invocation.

### Why cudaEvent_t for benchmarking (not wall-clock time)
CUDA kernel launches are asynchronous — the CPU returns from the launch call before the GPU finishes executing. `std::chrono` on the CPU therefore measures launch overhead plus CPU scheduling jitter, not actual GPU execution time. `cudaEventRecord` inserts timestamps directly into the GPU command queue; `cudaEventElapsedTime` measures the gap between two GPU-side timestamps, independent of the CPU. At sub-millisecond kernel times the difference is significant and wall-clock timing would give unreliable speedup numbers.

### Why block_reduce_sum uses smem[0] as the broadcast slot (not a separate __shared__ float)
After the warp-0 final reduction, `smem[0]` is already available as a known shared-memory location. Reusing it as the broadcast slot avoids declaring an additional `__shared__` variable and the associated extra barrier. The caller must not read `smem[0]` for anything else between the point block_reduce_sum returns and the next `__syncthreads()` — the code upholds this invariant.

---

## PyTorch extension interface

The three public functions (defined in `kernels/extension.cu`, exposed via pybind11):

```python
import kernelflow as kf

# Baseline (unfused) — for correctness reference and timing comparison
out  = kf.baseline_rmsnorm(x, w, eps=1e-6)       # x: [N,D], w: [D] → [N,D]
kf.baseline_rope(x, cos_cache, sin_cache)          # in-place, returns x

# Milestone 1 — the fused kernel
out = kf.fused_rmsnorm_rope(x, w, cos_cache, sin_cache, eps=1e-6)
# cos_cache, sin_cache: [N, D/2]
# All tensors: float32 CUDA contiguous
```

All inputs must be: `float32`, `is_cuda()`, `is_contiguous()`. The extension raises `torch.error` otherwise.

---

## Test strategy

Ground truth: PyTorch native ops (`torch.rsqrt`, manual RoPE rotation).
Tolerance: `1e-5` max absolute error (matches benchmark gate).
Test shapes: `(1,64)`, `(16,128)`, `(128,2048)`, `(512,4096)` — LLaMA-7B, `(1,8192)` — LLaMA-70B.
Behavioural tests: scale invariance of RMSNorm, norm preservation of RoPE (isometry), no input mutation, near-zero stability (no NaN/Inf).

---

## Build system split

`CMakeLists.txt` builds standalone C++ executables — specifically `build/bench_all` — linked against static kernel libs. `setup.py` builds the Python `.so` extension linked against libtorch. They are intentionally separate: different linker requirements, different consumers (C++ benchmark vs Python import). Merging them would require locating PyTorch's CMake package, which is fragile in offline environments.
