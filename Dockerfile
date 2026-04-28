# KernelFlow build environment
# Base: CUDA 12.1 devel — matches PyTorch 2.3 cu121 wheel ABI requirements
# (PyTorch 2.3 cu121 needs libnvJitLink symbols only present in CUDA 12.1+)
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

# Prevent apt from prompting during build
ENV DEBIAN_FRONTEND=noninteractive
ENV CUDA_HOME=/usr/local/cuda
ENV PATH="${CUDA_HOME}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}"

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build tools
    build-essential \
    cmake \
    ninja-build \
    git \
    # Static analysis
    clang-tidy \
    # Coverage
    lcov \
    gcovr \
    # Python
    python3.11 \
    python3.11-dev \
    python3-pip \
    python3.11-venv \
    # Utilities
    curl \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Make python3.11 the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
 && update-alternatives --install /usr/bin/python  python  /usr/bin/python3.11 1

# ---------------------------------------------------------------------------
# Python dependencies
# ---------------------------------------------------------------------------
# Install PyTorch with CUDA 12.1 wheels (closest stable to CUDA 12.0 runtime)
RUN pip3 install --no-cache-dir --upgrade pip \
 && pip3 install --no-cache-dir \
    torch==2.3.0 \
    --index-url https://download.pytorch.org/whl/cu121

RUN pip3 install --no-cache-dir \
    pytest \
    pytest-cov \
    ruff \
    pylint \
    wandb \
    numpy

# ---------------------------------------------------------------------------
# compute-sanitizer is bundled with CUDA toolkit (available as compute-sanitizer)
# Verify it's accessible
# ---------------------------------------------------------------------------
RUN compute-sanitizer --version

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
WORKDIR /workspace

# Default: drop into bash (Jenkins will override with pipeline commands)
CMD ["/bin/bash"]
