"""
Numerical validation suite for fused_rmsnorm_rope — Milestone 1.

Correctness strategy:
  - Ground truth: PyTorch native ops (RMSNorm via manual computation, RoPE manual)
  - Tolerance: 1e-5 max absolute error (matches CLAUDE.md benchmark gate)
  - Shapes tested: small (smoke), typical LLaMA-7B dims, edge cases

Run on the GPU PC:
    pytest tests/test_fused_rmsnorm_rope.py -v --tb=short
"""

import pytest
import torch

CUDA_AVAILABLE = torch.cuda.is_available()
skip_no_cuda   = pytest.mark.skipif(not CUDA_AVAILABLE, reason="CUDA required")

# Import the compiled extension; skip entire module gracefully if not built yet
try:
    import kernelflow as kf          # type: ignore
    HAS_EXT = True
except ImportError:
    HAS_EXT = False

skip_no_ext = pytest.mark.skipif(
    not HAS_EXT,
    reason="kernelflow extension not built — run: pip install -e ."
)

DEVICE = "cuda" if CUDA_AVAILABLE else "cpu"
ATOL   = 1e-5   # Milestone 1 numerical budget


# ---------------------------------------------------------------------------
# Reference implementations (pure PyTorch, on CUDA)
# ---------------------------------------------------------------------------

def ref_rmsnorm(x: torch.Tensor, w: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    """RMSNorm reference: x / rms(x) * w  (last dim)."""
    rms_inv = torch.rsqrt(x.pow(2).mean(dim=-1, keepdim=True) + eps)
    return x * rms_inv * w


def build_rope_cache(N: int, D: int, base: float = 10000.0,
                     device: str = DEVICE) -> tuple[torch.Tensor, torch.Tensor]:
    """
    Build (cos_cache, sin_cache) of shape [N, D/2].
    Uses the standard LLaMA/GPT-NeoX frequency formula:
        theta_i = base^(-2i/D) for i in [0, D/2)
        angle_t_i = t * theta_i  for token position t in [0, N)
    """
    half_D = D // 2
    # [half_D]
    inv_freq = 1.0 / (base ** (torch.arange(0, half_D, device=device).float() / half_D))
    # [N]
    t = torch.arange(N, device=device).float()
    # [N, half_D]
    freqs   = torch.outer(t, inv_freq)
    cos_c   = freqs.cos().contiguous()
    sin_c   = freqs.sin().contiguous()
    return cos_c, sin_c


def ref_rope(x: torch.Tensor,
             cos_cache: torch.Tensor,
             sin_cache: torch.Tensor) -> torch.Tensor:
    """
    Apply RoPE to x [N, D] given cos/sin caches [N, D/2].
    Splits x into even/odd pairs, rotates in-place logic, returns new tensor.
    """
    x0 = x[..., 0::2]   # [N, D/2]  — even indices
    x1 = x[..., 1::2]   # [N, D/2]  — odd  indices
    c, s = cos_cache, sin_cache
    out = torch.empty_like(x)
    out[..., 0::2] = x0 * c - x1 * s
    out[..., 1::2] = x0 * s + x1 * c
    return out


def ref_rmsnorm_rope(x, w, cos_cache, sin_cache, eps=1e-6):
    return ref_rope(ref_rmsnorm(x, w, eps), cos_cache, sin_cache)


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

def make_inputs(N: int, D: int, seed: int = 0):
    """Return (x, w, cos_cache, sin_cache) on CUDA, float32, contiguous."""
    g = torch.Generator(device=DEVICE)
    g.manual_seed(seed)
    x   = torch.randn(N, D,     device=DEVICE, dtype=torch.float32, generator=g).contiguous()
    w   = torch.randn(D,        device=DEVICE, dtype=torch.float32, generator=g).contiguous()
    cos_c, sin_c = build_rope_cache(N, D, device=DEVICE)
    return x, w, cos_c, sin_c


def check_close(a: torch.Tensor, b: torch.Tensor, tag: str = "") -> None:
    err = (a - b).abs().max().item()
    assert err <= ATOL, (
        f"{tag} max absolute error {err:.2e} exceeds tolerance {ATOL:.2e}"
    )


# ---------------------------------------------------------------------------
# Tests: baseline_rmsnorm
# ---------------------------------------------------------------------------

@skip_no_cuda
@skip_no_ext
class TestBaselineRMSNorm:
    @pytest.mark.parametrize("N,D", [(1, 64), (16, 128), (512, 4096)])
    def test_matches_reference(self, N: int, D: int):
        x, w, _, _ = make_inputs(N, D)
        ref  = ref_rmsnorm(x, w)
        out  = kf.baseline_rmsnorm(x, w)
        check_close(ref, out, f"baseline_rmsnorm N={N} D={D}")

    def test_output_shape(self):
        x, w, _, _ = make_inputs(8, 256)
        out = kf.baseline_rmsnorm(x, w)
        assert out.shape == x.shape

    def test_output_dtype_device(self):
        x, w, _, _ = make_inputs(4, 64)
        out = kf.baseline_rmsnorm(x, w)
        assert out.dtype  == torch.float32
        assert out.device == x.device

    def test_scale_invariance(self):
        """x scaled by alpha should not affect RMSNorm output."""
        x, w, _, _ = make_inputs(8, 128)
        out1 = kf.baseline_rmsnorm(x,       w)
        out2 = kf.baseline_rmsnorm(x * 3.7, w)
        check_close(out1, out2, "scale_invariance")

    def test_eps_stability_near_zero(self):
        """Near-zero input must not produce NaN/Inf."""
        x = torch.zeros(4, 64, device=DEVICE)
        x[0, 0] = 1e-20
        w = torch.ones(64, device=DEVICE)
        out = kf.baseline_rmsnorm(x, w, eps=1e-6)
        assert torch.isfinite(out).all(), "NaN/Inf with near-zero input"


# ---------------------------------------------------------------------------
# Tests: baseline_rope
# ---------------------------------------------------------------------------

@skip_no_cuda
@skip_no_ext
class TestBaselineRoPE:
    @pytest.mark.parametrize("N,D", [(1, 64), (32, 128), (256, 512)])
    def test_matches_reference(self, N: int, D: int):
        x, _, cos_c, sin_c = make_inputs(N, D)
        ref = ref_rope(x.clone(), cos_c, sin_c)
        out = kf.baseline_rope(x.clone(), cos_c, sin_c)
        check_close(ref, out, f"baseline_rope N={N} D={D}")

    def test_norm_preservation(self):
        """RoPE is a rotation — it must preserve the L2 norm of each pair."""
        N, D = 64, 256
        x, _, cos_c, sin_c = make_inputs(N, D)
        x_in  = x.clone()
        kf.baseline_rope(x, cos_c, sin_c)
        # Per-pair norm: pairs (2i, 2i+1)
        norm_in  = (x_in[..., 0::2].pow(2) + x_in[..., 1::2].pow(2))
        norm_out = (x[...,   0::2].pow(2) + x[...,   1::2].pow(2))
        check_close(norm_in, norm_out, "rope_norm_preservation")


# ---------------------------------------------------------------------------
# Tests: fused_rmsnorm_rope  (the Milestone 1 kernel)
# ---------------------------------------------------------------------------

@skip_no_cuda
@skip_no_ext
class TestFusedRMSNormRoPE:
    @pytest.mark.parametrize("N,D", [
        (1,   64),    # single token, small dim
        (16,  128),   # small batch
        (128, 2048),  # medium — common for batched inference
        (512, 4096),  # LLaMA-7B hidden dim
        (1,   8192),  # LLaMA-70B hidden dim, single token
    ])
    def test_matches_reference(self, N: int, D: int):
        x, w, cos_c, sin_c = make_inputs(N, D)
        ref = ref_rmsnorm_rope(x, w, cos_c, sin_c)
        out = kf.fused_rmsnorm_rope(x, w, cos_c, sin_c)
        check_close(ref, out, f"fused_rmsnorm_rope N={N} D={D}")

    def test_matches_two_kernel_baseline(self):
        """Fused output must agree with sequential baseline kernels."""
        N, D = 128, 512
        x, w, cos_c, sin_c = make_inputs(N, D)

        # Two-kernel baseline path
        normed = kf.baseline_rmsnorm(x, w)
        baseline_out = kf.baseline_rope(normed, cos_c, sin_c)

        fused_out = kf.fused_rmsnorm_rope(x, w, cos_c, sin_c)
        check_close(baseline_out, fused_out, "fused_vs_two_kernel_baseline")

    def test_output_shape(self):
        N, D = 8, 256
        x, w, cos_c, sin_c = make_inputs(N, D)
        out = kf.fused_rmsnorm_rope(x, w, cos_c, sin_c)
        assert out.shape == (N, D)

    def test_does_not_modify_input(self):
        """Fused kernel must not write to x (x is read-only)."""
        N, D = 32, 128
        x, w, cos_c, sin_c = make_inputs(N, D)
        x_copy = x.clone()
        kf.fused_rmsnorm_rope(x, w, cos_c, sin_c)
        assert torch.equal(x, x_copy), "fused kernel modified input tensor x"

    def test_different_eps_values(self):
        x, w, cos_c, sin_c = make_inputs(16, 128)
        for eps in [1e-4, 1e-5, 1e-6, 1e-8]:
            ref = ref_rmsnorm_rope(x, w, cos_c, sin_c, eps=eps)
            out = kf.fused_rmsnorm_rope(x, w, cos_c, sin_c, eps=eps)
            check_close(ref, out, f"eps={eps}")

    def test_all_ones_weight(self):
        """With w=1, fused(x) should equal rope(rmsnorm(x, 1))."""
        N, D = 64, 256
        x, _, cos_c, sin_c = make_inputs(N, D)
        w = torch.ones(D, device=DEVICE)
        ref = ref_rmsnorm_rope(x, w, cos_c, sin_c)
        out = kf.fused_rmsnorm_rope(x, w, cos_c, sin_c)
        check_close(ref, out, "all_ones_weight")


# ---------------------------------------------------------------------------
# Smoke benchmark (not a gate — use bench_all for that)
# ---------------------------------------------------------------------------

@skip_no_cuda
@skip_no_ext
class TestSmokeBenchmark:
    def test_fused_is_faster_than_baseline(self):
        """Smoke check: fused kernel must be faster for a non-trivial shape."""
        import time

        N, D    = 2048, 4096
        warmup  = 5
        repeats = 20

        x, w, cos_c, sin_c = make_inputs(N, D)

        def time_fn(fn, reps):
            torch.cuda.synchronize()
            t0 = time.perf_counter()
            for _ in range(reps):
                fn()
            torch.cuda.synchronize()
            return (time.perf_counter() - t0) / reps * 1e3  # ms

        # Warmup
        for _ in range(warmup):
            normed = kf.baseline_rmsnorm(x, w)
            kf.baseline_rope(normed, cos_c, sin_c)
            kf.fused_rmsnorm_rope(x, w, cos_c, sin_c)

        ms_baseline = time_fn(
            lambda: kf.baseline_rope(kf.baseline_rmsnorm(x, w), cos_c, sin_c),
            repeats,
        )
        ms_fused = time_fn(
            lambda: kf.fused_rmsnorm_rope(x, w, cos_c, sin_c),
            repeats,
        )
        speedup = ms_baseline / ms_fused
        print(f"\n  Baseline: {ms_baseline:.3f} ms/iter")
        print(f"  Fused:    {ms_fused:.3f} ms/iter")
        print(f"  Speedup:  {speedup:.2f}x  (gate: 1.5x)")

        # Soft assertion — this is a smoke test; the hard gate is bench_all
        assert speedup > 1.0, (
            f"Fused kernel ({ms_fused:.3f} ms) slower than baseline ({ms_baseline:.3f} ms)"
        )
