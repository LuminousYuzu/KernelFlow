cmake_minimum_required(VERSION 3.22)
project(KernelFlow CUDA CXX)

# ---------------------------------------------------------------------------
# Language standards
# ---------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD  17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ---------------------------------------------------------------------------
# CUDA architecture selection
# Defaults to the GPU detected on the build machine; override with
#   cmake -DCMAKE_CUDA_ARCHITECTURES="80;86;89" ..
# ---------------------------------------------------------------------------
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES native)
endif()

# ---------------------------------------------------------------------------
# Compiler flags
# ---------------------------------------------------------------------------
set(CUDA_NVCC_FLAGS_COMMON
    --expt-relaxed-constexpr
    --use_fast_math
    -Xcompiler=-Wall,-Wextra
    -lineinfo                    # keep line info for Nsight
)

# Coverage instrumentation (host-side only; GPU coverage not supported)
option(ENABLE_COVERAGE "Build with gcov coverage" OFF)
if(ENABLE_COVERAGE)
    add_compile_options(-fprofile-arcs -ftest-coverage)
    add_link_options(--coverage)
endif()

# ---------------------------------------------------------------------------
# Baseline kernels static library
# ---------------------------------------------------------------------------
add_library(kernelflow_baseline STATIC
    kernels/baseline/rmsnorm.cu
    kernels/baseline/rope.cu
)
target_include_directories(kernelflow_baseline PUBLIC kernels)
target_compile_options(kernelflow_baseline PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:${CUDA_NVCC_FLAGS_COMMON}>
)

# ---------------------------------------------------------------------------
# Fused kernels static library
# ---------------------------------------------------------------------------
add_library(kernelflow_fused STATIC
    kernels/fused/fused_rmsnorm_rope.cu
)
target_include_directories(kernelflow_fused PUBLIC kernels)
target_compile_options(kernelflow_fused PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:${CUDA_NVCC_FLAGS_COMMON}>
)

# ---------------------------------------------------------------------------
# Benchmark executable
# ---------------------------------------------------------------------------
add_executable(bench_all benchmarks/bench_all.cu)
target_include_directories(bench_all PRIVATE kernels)
target_link_libraries(bench_all PRIVATE kernelflow_baseline kernelflow_fused)
target_compile_options(bench_all PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:${CUDA_NVCC_FLAGS_COMMON}>
)

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
install(TARGETS bench_all DESTINATION bin)
