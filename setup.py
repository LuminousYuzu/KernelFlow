"""
PyTorch Extension build script for KernelFlow.

Usage:
    pip install -e .          # editable install (dev)
    python setup.py bdist_wheel   # build distributable wheel
"""

import os
import torch
from setuptools import setup
from torch.utils.cpp_extension import CUDAExtension, BuildExtension

# Detect CUDA architectures from the current GPU, or fall back to a safe set
# that covers Volta (sm_70), Turing (sm_75), Ampere (sm_80/86), Ada (sm_89).
def get_cuda_arch_flags() -> list[str]:
    archs = os.environ.get("TORCH_CUDA_ARCH_LIST", "")
    if archs:
        return []   # torch will pick up TORCH_CUDA_ARCH_LIST automatically
    if torch.cuda.is_available():
        major, minor = torch.cuda.get_device_capability()
        return [f"-gencode=arch=compute_{major}{minor},code=sm_{major}{minor}"]
    # Offline build: cover common production GPUs
    return [
        "-gencode=arch=compute_70,code=sm_70",
        "-gencode=arch=compute_75,code=sm_75",
        "-gencode=arch=compute_80,code=sm_80",
        "-gencode=arch=compute_86,code=sm_86",
        "-gencode=arch=compute_89,code=sm_89",
    ]


nvcc_flags = [
    "--expt-relaxed-constexpr",
    "--use_fast_math",
    "-lineinfo",
    "-O3",
    *get_cuda_arch_flags(),
]

ext = CUDAExtension(
    name="kernelflow",
    sources=[
        "kernels/extension.cu",
        "kernels/baseline/rmsnorm.cu",
        "kernels/baseline/rope.cu",
        "kernels/fused/fused_rmsnorm_rope.cu",
    ],
    include_dirs=["kernels"],
    extra_compile_args={"nvcc": nvcc_flags, "cxx": ["-O3"]},
)

setup(
    name="kernelflow",
    version="0.1.0",
    description="Fused CUDA kernels for LLM inference (KernelFlow Milestone 1)",
    author="KernelFlow",
    license="Apache-2.0",
    ext_modules=[ext],
    cmdclass={"build_ext": BuildExtension},
    python_requires=">=3.10",
    install_requires=["torch"],
)
