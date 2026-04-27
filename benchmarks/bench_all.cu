// KernelFlow — Standalone CUDA benchmark
//
// Measures wall-clock GPU time for baseline (unfused) vs fused RMSNorm+RoPE,
// reports speedup, and exits non-zero if the speedup gate is not met.
//
// Build via CMake:
//   cmake -B build && make -C build -j$(nproc) && ./build/bench_all
//
// Arguments (all optional, positional):
//   ./bench_all [N] [D] [warmup_iters] [bench_iters]
//   Defaults: N=2048, D=4096, warmup=10, bench=100

#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <stdexcept>

#include "baseline/rmsnorm.cuh"
#include "baseline/rope.cuh"
#include "fused/fused_rmsnorm_rope.cuh"
#include "common.cuh"

// ---------------------------------------------------------------------------
// CUDA timing helpers
// ---------------------------------------------------------------------------
struct GpuTimer {
    cudaEvent_t start_, stop_;
    GpuTimer() {
        CUDA_CHECK(cudaEventCreate(&start_));
        CUDA_CHECK(cudaEventCreate(&stop_));
    }
    ~GpuTimer() {
        cudaEventDestroy(start_);
        cudaEventDestroy(stop_);
    }
    void start(cudaStream_t s = nullptr) { cudaEventRecord(start_, s); }
    float stop(cudaStream_t s = nullptr) {   // returns elapsed ms
        cudaEventRecord(stop_, s);
        cudaEventSynchronize(stop_);
        float ms = 0.f;
        cudaEventElapsedTime(&ms, start_, stop_);
        return ms;
    }
};

// ---------------------------------------------------------------------------
// Benchmark a callable over multiple iterations; returns avg GPU time (ms)
// ---------------------------------------------------------------------------
template <typename Fn>
static float benchmark(Fn fn, int warmup, int iters, cudaStream_t stream) {
    for (int i = 0; i < warmup; ++i) fn();
    CUDA_CHECK(cudaStreamSynchronize(stream));

    GpuTimer timer;
    timer.start(stream);
    for (int i = 0; i < iters; ++i) fn();
    float total_ms = timer.stop(stream);
    return total_ms / (float)iters;
}

// ---------------------------------------------------------------------------
// Fill device buffer with random floats in [-1, 1]
// ---------------------------------------------------------------------------
static void rand_fill(float* d_buf, int n) {
    auto* h = new float[n];
    for (int i = 0; i < n; ++i)
        h[i] = (float)rand() / RAND_MAX * 2.f - 1.f;
    CUDA_CHECK(cudaMemcpy(d_buf, h, n * sizeof(float), cudaMemcpyHostToDevice));
    delete[] h;
}

// ---------------------------------------------------------------------------
// Numerical correctness check: max absolute error between two device buffers
// ---------------------------------------------------------------------------
static float max_abs_error(const float* a, const float* b, int n) {
    auto* ha = new float[n];
    auto* hb = new float[n];
    CUDA_CHECK(cudaMemcpy(ha, a, n * sizeof(float), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(hb, b, n * sizeof(float), cudaMemcpyDeviceToHost));
    float err = 0.f;
    for (int i = 0; i < n; ++i)
        err = fmaxf(err, fabsf(ha[i] - hb[i]));
    delete[] ha;
    delete[] hb;
    return err;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    int N          = (argc > 1) ? atoi(argv[1]) : 2048;
    int D          = (argc > 2) ? atoi(argv[2]) : 4096;
    int warmup     = (argc > 3) ? atoi(argv[3]) : 10;
    int bench_iters = (argc > 4) ? atoi(argv[4]) : 100;

    // Benchmark gate (from CLAUDE.md)
    constexpr float kSpeedupGate   = 1.5f;
    constexpr float kMaxNumericErr = 1e-5f;

    printf("KernelFlow bench_all — RMSNorm + RoPE\n");
    printf("  N=%d  D=%d  warmup=%d  iters=%d\n\n", N, D, warmup, bench_iters);

    int half_D = D / 2;
    cudaStream_t stream;
    CUDA_CHECK(cudaStreamCreate(&stream));

    // Allocate device buffers
    float *d_x, *d_w, *d_cos, *d_sin, *d_out_baseline, *d_out_fused, *d_tmp;
    CUDA_CHECK(cudaMalloc(&d_x,            (long long)N * D * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_w,            D * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_cos,          (long long)N * half_D * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_sin,          (long long)N * half_D * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_out_baseline, (long long)N * D * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_out_fused,    (long long)N * D * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_tmp,          (long long)N * D * sizeof(float)));  // intermediate for baseline

    srand(42);
    rand_fill(d_x,   N * D);
    rand_fill(d_w,   D);
    rand_fill(d_cos, N * half_D);
    rand_fill(d_sin, N * half_D);

    // ------------------------------------------------------------------
    // Correctness check (single run before timing)
    // ------------------------------------------------------------------
    // Baseline: RMSNorm → copy x to tmp → RoPE in-place
    launch_rmsnorm(d_x, d_w, d_out_baseline, N, D, 1e-6f, stream);
    CUDA_CHECK(cudaMemcpyAsync(d_tmp, d_out_baseline,
                               (long long)N * D * sizeof(float),
                               cudaMemcpyDeviceToDevice, stream));
    launch_rope(d_tmp, d_cos, d_sin, N, D, stream);
    CUDA_CHECK(cudaMemcpyAsync(d_out_baseline, d_tmp,
                               (long long)N * D * sizeof(float),
                               cudaMemcpyDeviceToDevice, stream));

    // Fused
    launch_fused_rmsnorm_rope(d_x, d_w, d_cos, d_sin, d_out_fused, N, D, 1e-6f, stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));

    float err = max_abs_error(d_out_baseline, d_out_fused, N * D);
    printf("Correctness — max absolute error vs baseline: %.2e  ", err);
    if (err > kMaxNumericErr) {
        printf("[FAIL — threshold %.2e]\n", kMaxNumericErr);
        return 1;
    }
    printf("[PASS]\n\n");

    // ------------------------------------------------------------------
    // Timing — baseline (two kernel launches)
    // ------------------------------------------------------------------
    float ms_baseline = benchmark([&]() {
        launch_rmsnorm(d_x, d_w, d_tmp, N, D, 1e-6f, stream);
        launch_rope(d_tmp, d_cos, d_sin, N, D, stream);
    }, warmup, bench_iters, stream);

    // ------------------------------------------------------------------
    // Timing — fused (one kernel launch)
    // ------------------------------------------------------------------
    float ms_fused = benchmark([&]() {
        launch_fused_rmsnorm_rope(d_x, d_w, d_cos, d_sin, d_out_fused, N, D, 1e-6f, stream);
    }, warmup, bench_iters, stream);

    float speedup = ms_baseline / ms_fused;

    // Approximate HBM bandwidth savings
    long long bytes_saved = 2LL * N * D * sizeof(float);  // saved read + write of normed tensor
    int device; cudaGetDevice(&device);
    cudaDeviceProp prop; cudaGetDeviceProperties(&prop, device);

    printf("GPU: %s\n", prop.name);
    printf("Peak memory bandwidth: %.1f GB/s\n\n", prop.memoryBusWidth / 8.0 * prop.memoryClockRate * 2e-6);
    printf("Baseline (unfused): %7.3f ms/iter\n", ms_baseline);
    printf("Fused:              %7.3f ms/iter\n", ms_fused);
    printf("Speedup:            %7.2fx          ", speedup);
    if (speedup < kSpeedupGate) {
        printf("[FAIL — gate %.1fx]\n", kSpeedupGate);
    } else {
        printf("[PASS — gate %.1fx]\n", kSpeedupGate);
    }
    printf("HBM traffic saved:  %.1f MB\n", bytes_saved / 1e6f);

    // Write machine-readable result for report.py
    FILE* f = fopen("benchmark_result.txt", "w");
    if (f) {
        fprintf(f, "kernel=fused_rmsnorm_rope\n");
        fprintf(f, "N=%d\nD=%d\n", N, D);
        fprintf(f, "ms_baseline=%.6f\n", ms_baseline);
        fprintf(f, "ms_fused=%.6f\n", ms_fused);
        fprintf(f, "speedup=%.6f\n", speedup);
        fprintf(f, "max_err=%.2e\n", err);
        fprintf(f, "gpu=%s\n", prop.name);
        fclose(f);
    }

    CUDA_CHECK(cudaFree(d_x));
    CUDA_CHECK(cudaFree(d_w));
    CUDA_CHECK(cudaFree(d_cos));
    CUDA_CHECK(cudaFree(d_sin));
    CUDA_CHECK(cudaFree(d_out_baseline));
    CUDA_CHECK(cudaFree(d_out_fused));
    CUDA_CHECK(cudaFree(d_tmp));
    CUDA_CHECK(cudaStreamDestroy(stream));

    return (speedup >= kSpeedupGate) ? 0 : 1;
}
