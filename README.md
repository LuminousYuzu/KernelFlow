# KernelFlow

<p align="center">
  <b>Automated CUDA kernel optimization and CI/CD deployment platform for LLM inference.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/CUDA-12.0-76B900?logo=nvidia&logoColor=white" />
  <img src="https://img.shields.io/badge/PyTorch-Extension-EE4C2C?logo=pytorch&logoColor=white" />
  <img src="https://img.shields.io/badge/CMake-3.25+-064F8C?logo=cmake&logoColor=white" />
  <img src="https://img.shields.io/badge/Docker-nvidia%2Fcuda-2496ED?logo=docker&logoColor=white" />
  <img src="https://img.shields.io/badge/Jenkins-CI%2FCD-D24939?logo=jenkins&logoColor=white" />
  <img src="https://img.shields.io/badge/Kubernetes-minikube-326CE5?logo=kubernetes&logoColor=white" />
  <img src="https://img.shields.io/badge/License-Apache%202.0-blue" />
</p>

---

## Overview

KernelFlow is a production-style MLOps platform built around fused CUDA kernels for LLM inference. A researcher pushes a fused kernel to GitHub — the system automatically builds, validates numerical correctness, benchmarks against an unfused baseline, and deploys it as a PyTorch Extension. No manual steps.

The pipeline mirrors NVIDIA's internal kernel development infrastructure (cuDNN / FlashInfer style): every kernel must clear a defined speedup gate and numerical error budget before it can be promoted to `main` and packaged.

**Kernels implemented:**

| Milestone | Kernel | Speedup Gate |
|-----------|--------|-------------|
| 1 | Fused RMSNorm + RoPE | ≥ 1.5× vs baseline |
| 2 | Fused SiLU × Elementwise Multiply | ≥ 1.3× vs baseline |
| 3 | Fused Attention (Flash Attention simplified) | ≥ 2.0× vs baseline |

---

## Tech Stack

### Compute
<p>
  <img src="https://img.shields.io/badge/CUDA_C++-Kernels-76B900?logo=nvidia&logoColor=white" />
  <img src="https://img.shields.io/badge/cuBLAS-Baseline-76B900?logo=nvidia&logoColor=white" />
  <img src="https://img.shields.io/badge/cuDNN-Reference-76B900?logo=nvidia&logoColor=white" />
  <img src="https://img.shields.io/badge/Triton-Validation-000000?logo=openai&logoColor=white" />
  <img src="https://img.shields.io/badge/PyTorch-pybind11-EE4C2C?logo=pytorch&logoColor=white" />
</p>

### Build & CI/CD
<p>
  <img src="https://img.shields.io/badge/CMake-Build-064F8C?logo=cmake&logoColor=white" />
  <img src="https://img.shields.io/badge/Docker-nvidia%2Fcuda:12.0--devel-2496ED?logo=docker&logoColor=white" />
  <img src="https://img.shields.io/badge/Jenkins-Pipeline-D24939?logo=jenkins&logoColor=white" />
  <img src="https://img.shields.io/badge/Kubernetes-minikube-326CE5?logo=kubernetes&logoColor=white" />
</p>

### Quality & Observability
<p>
  <img src="https://img.shields.io/badge/clang--tidy-Static_Analysis-blue" />
  <img src="https://img.shields.io/badge/compute--sanitizer-GPU_Safety-76B900?logo=nvidia&logoColor=white" />
  <img src="https://img.shields.io/badge/pytest-Coverage-0A9EDC?logo=pytest&logoColor=white" />
  <img src="https://img.shields.io/badge/Nsight-Profiling-76B900?logo=nvidia&logoColor=white" />
  <img src="https://img.shields.io/badge/wandb-Benchmarks-FFBE00?logo=weightsandbiases&logoColor=black" />
  <img src="https://img.shields.io/badge/Grafana-Monitoring-F46800?logo=grafana&logoColor=white" />
</p>

---

## License

Apache 2.0 — consistent with NVIDIA open-source projects (CUTLASS, TensorRT-LLM, cuDF).
