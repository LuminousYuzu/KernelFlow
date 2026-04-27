#include <torch/extension.h>
#include "baseline/rmsnorm.cuh"
#include "baseline/rope.cuh"
#include "fused/fused_rmsnorm_rope.cuh"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static void check_cuda_float(const torch::Tensor& t, const char* name) {
    TORCH_CHECK(t.is_cuda(),              name, " must be a CUDA tensor");
    TORCH_CHECK(t.is_contiguous(),        name, " must be contiguous");
    TORCH_CHECK(t.scalar_type() == torch::kFloat, name, " must be float32");
}

// ---------------------------------------------------------------------------
// Python-visible ops
// ---------------------------------------------------------------------------

// baseline_rmsnorm(x [N,D], w [D], eps) → out [N,D]
torch::Tensor baseline_rmsnorm(
    torch::Tensor x,
    torch::Tensor w,
    float         eps)
{
    check_cuda_float(x, "x");
    check_cuda_float(w, "w");
    TORCH_CHECK(x.dim() == 2,           "x must be 2-D [N, D]");
    TORCH_CHECK(w.dim() == 1,           "w must be 1-D [D]");
    TORCH_CHECK(w.size(0) == x.size(1), "w.size(0) must equal x.size(1)");

    int N = x.size(0);
    int D = x.size(1);
    auto out = torch::empty_like(x);

    launch_rmsnorm(
        x.data_ptr<float>(), w.data_ptr<float>(), out.data_ptr<float>(),
        N, D, eps,
        at::cuda::getCurrentCUDAStream());
    return out;
}

// baseline_rope(x [N,D], cos_cache [N,D/2], sin_cache [N,D/2]) → x in-place
torch::Tensor baseline_rope(
    torch::Tensor x,
    torch::Tensor cos_cache,
    torch::Tensor sin_cache)
{
    check_cuda_float(x,         "x");
    check_cuda_float(cos_cache, "cos_cache");
    check_cuda_float(sin_cache, "sin_cache");
    TORCH_CHECK(x.dim() == 2,                    "x must be 2-D [N, D]");
    TORCH_CHECK(x.size(1) % 2 == 0,              "D must be even");
    TORCH_CHECK(cos_cache.sizes() == sin_cache.sizes(), "cos/sin cache shape mismatch");

    int N = x.size(0);
    int D = x.size(1);

    launch_rope(
        x.data_ptr<float>(),
        cos_cache.data_ptr<float>(), sin_cache.data_ptr<float>(),
        N, D,
        at::cuda::getCurrentCUDAStream());
    return x;  // in-place; return for chaining
}

// fused_rmsnorm_rope(x [N,D], w [D], cos_cache [N,D/2], sin_cache [N,D/2], eps) → out [N,D]
torch::Tensor fused_rmsnorm_rope(
    torch::Tensor x,
    torch::Tensor w,
    torch::Tensor cos_cache,
    torch::Tensor sin_cache,
    float         eps)
{
    check_cuda_float(x,         "x");
    check_cuda_float(w,         "w");
    check_cuda_float(cos_cache, "cos_cache");
    check_cuda_float(sin_cache, "sin_cache");
    TORCH_CHECK(x.dim() == 2,                       "x must be 2-D [N, D]");
    TORCH_CHECK(w.dim() == 1,                       "w must be 1-D [D]");
    TORCH_CHECK(x.size(1) % 2 == 0,                 "D must be even");
    TORCH_CHECK(w.size(0) == x.size(1),             "w.size(0) must equal D");
    TORCH_CHECK(cos_cache.sizes() == sin_cache.sizes(), "cos/sin cache shape mismatch");

    int N = x.size(0);
    int D = x.size(1);
    auto out = torch::empty_like(x);

    launch_fused_rmsnorm_rope(
        x.data_ptr<float>(), w.data_ptr<float>(),
        cos_cache.data_ptr<float>(), sin_cache.data_ptr<float>(),
        out.data_ptr<float>(),
        N, D, eps,
        at::cuda::getCurrentCUDAStream());
    return out;
}

// ---------------------------------------------------------------------------
// Module registration
// ---------------------------------------------------------------------------
PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
    m.doc() = "KernelFlow — fused CUDA kernels for LLM inference";

    m.def("baseline_rmsnorm",   &baseline_rmsnorm,
          "Unfused RMSNorm (baseline)",
          py::arg("x"), py::arg("w"), py::arg("eps") = 1e-6f);

    m.def("baseline_rope",      &baseline_rope,
          "Unfused RoPE in-place (baseline)",
          py::arg("x"), py::arg("cos_cache"), py::arg("sin_cache"));

    m.def("fused_rmsnorm_rope", &fused_rmsnorm_rope,
          "Fused RMSNorm + RoPE — Milestone 1",
          py::arg("x"), py::arg("w"),
          py::arg("cos_cache"), py::arg("sin_cache"),
          py::arg("eps") = 1e-6f);
}
