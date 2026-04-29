# CI/CD Context — KernelFlow

Authoritative reference for everything in `jenkins/`, `scripts/`, `Jenkinsfile`,
and `k8s/`. Read this before touching any of those files.

---

## Current status (as of 2026-04-29)

**Pipeline is GREEN end-to-end on real RTX 4070 hardware.**

| Metric              | Latest run     | Gate        | Status |
|---------------------|----------------|-------------|--------|
| Speedup vs baseline | **1.66×**      | ≥ 1.5×      | ✅     |
| Numerical error     | 0.00e+00       | ≤ 1e-5      | ✅     |
| HBM traffic saved   | 67.1 MB / call | —           | —      |

The architecture in production is a **hybrid pipeline**: most stages run inside
K8s pods, but the GPU-dependent **Benchmark stage runs on a Jenkins host agent
on the WSL2 host**, where Docker Desktop's GPU passthrough actually works.
This compromise was forced by WSL2's nested-container GPU limitation; on
native Linux the Benchmark stage moves back into a pod with one config change.
Full rationale and three abandoned alternative architectures are recorded in
`docs/development-log.md` Issues 8–10.

---

## File map — what each file does

### Pipeline definition

| File | Purpose |
|------|---------|
| `Jenkinsfile` | 5-stage declarative pipeline. Top-level `agent { kubernetes }` for Build/Test/Static Analysis/Deploy; Benchmark stage uses `agent { label 'gpu-host' }` to run on the WSL2 host. Deploy gated to `main` only. |
| `k8s/jenkins-agent.yaml` | Pod spec for build-stage worker. **CPU-only** (no `nvidia.com/gpu` request — pod can't get GPU on WSL2 anyway). Uses `docker.io/library/kernelflow-build:latest` with `imagePullPolicy: Never`. |

### Jenkins controller (Docker Compose)

| File | Purpose |
|------|---------|
| `jenkins/Dockerfile.jenkins` | Builds Jenkins controller image from `jenkins/jenkins:lts-jdk17`. Pre-bakes plugins at image build time so startup is offline-capable and fast. |
| `jenkins/docker-compose.yml` | Two services: **`jenkins`** (controller, ports 8080/50000) and **`cloudflared`** (sidecar Quick Tunnel that exposes Jenkins to the public internet for GitHub webhooks). Joins both `jenkins_default` and `minikube` external networks so Jenkins can reach minikube's API at `192.168.49.2:8443`. |
| `jenkins/casc/jenkins.yaml` | Jenkins Configuration as Code. Configures security realm, Kubernetes cloud, credentials. Note: **`jobs:` section was removed** because the `job-dsl` plugin's GitHub source API is incompatible with the current `github-branch-source` plugin. The `kernelflow` multibranch pipeline is created via the UI once on first boot — see `docs/development-log.md` Issue 4. |
| `jenkins/plugins.txt` | Plugin list pre-installed by `jenkins-plugin-cli`. Includes `pipeline-graph-view` (replaces deprecated Blue Ocean), `kubernetes`, `github-branch-source`, `configuration-as-code`, `credentials-binding`, `ws-cleanup`. **`blueocean`, `cobertura`, and `job-dsl` were removed** — see `docs/development-log.md` Issues 2-4. |

### Build environment

| File | Purpose |
|------|---------|
| `Dockerfile` | CUDA 12.1 build environment (`nvidia/cuda:12.1.1-devel-ubuntu22.04`). Used in two execution contexts: minikube pods (CPU stages) and `docker run --gpus all` on the WSL2 host (Benchmark stage). Contains: nvcc, PyTorch 2.3 cu121, clang-tidy, compute-sanitizer, ruff, pytest, wandb, lcov. |

### Setup & operations

| File | Purpose |
|------|---------|
| `scripts/setup.sh` | First-time bootstrap on a fresh GPU PC. Installs minikube, NVIDIA device plugin, builds Docker images, writes `jenkins/.env`. **Note: out of sync with hybrid architecture** — does not yet provision the WSL2 host agent or cloudflared sidecar. Cold-start procedure post-setup is documented in the gitignored `docs/local-sop.md`. |
| `scripts/register_webhook.sh` | Registers a webhook pointing at `http://${PC_LAN_IP}:8080/github-webhook/`. **Largely obsolete** — LAN IPs aren't reachable from GitHub. The current webhook flow uses Cloudflare Tunnel; see `docs/local-sop.md` Step 8 for the manual `gh api` invocation. |

---

## Hybrid pipeline architecture

```
git push
    ↓
GitHub webhook → https://<random>.trycloudflare.com/github-webhook/
    ↓ (Cloudflare edge → outbound tunnel → cloudflared sidecar)
    ↓
Jenkins controller (Docker container)
    ↓ branch indexing reads Jenkinsfile from the pushed commit
    ↓
┌─────────────────────────────────────────────────────────────┐
│ STAGES 1-3, 5 — Run in K8s pod (minikube)                   │
│                                                             │
│ Jenkins K8s plugin → minikube API → schedules pod from      │
│ k8s/jenkins-agent.yaml. Pod has two containers:             │
│   - cuda-build: runs Build / Static Analysis / Test / Deploy│
│   - jnlp: bidirectional control channel back to Jenkins     │
│ Pod is CPU-only. No GPU access.                             │
└─────────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────────┐
│ STAGE 4 — Benchmark — runs on WSL2 host Jenkins agent       │
│                                                             │
│ Jenkins controller routes this stage to `wsl-host` agent    │
│ (java -jar agent.jar systemd service on the WSL2 host).     │
│ The host agent invokes:                                     │
│                                                             │
│   docker run --rm --gpus all                                │
│     -v ${WORKSPACE}:/workspace -w /workspace                │
│     -e WANDB_API_KEY="$WANDB_API_KEY"                       │
│     kernelflow-build:latest                                 │
│     bash -c 'cmake && make && ./build/bench_all 2048 4096   │
│              10 100 && python3 benchmarks/report.py ...'    │
│                                                             │
│ Docker Desktop's WSL2 NVIDIA integration injects RTX 4070   │
│ access into this top-level container. Inside the container, │
│ bench_all uses cudaEvent_t timing, exits non-zero if        │
│ speedup < 1.5x or max_err > 1e-5. report.py uploads run     │
│ to wandb project "kernelflow".                              │
└─────────────────────────────────────────────────────────────┘
    ↓
Stage 5 (Deploy) gated by `when { branch 'main' }`.
```

### Why this layout — not all stages on the host?

The host agent COULD run everything. We deliberately keep Build/Test/Static
Analysis in K8s pods because:

1. **Demonstrates K8s pod isolation skills** — every PR gets a fresh pod, no
   state leaks. Production-correct pattern.
2. **Forces clean dependency declaration** — if it doesn't work in the pod's
   `kernelflow-build` image, it doesn't work. No accidental host-only deps.
3. **Migration path stays trivial** — on native Linux with NVIDIA GPU
   Operator, just delete the `agent { label 'gpu-host' }` block from the
   Benchmark stage and everything runs in pods again. Zero kernel changes.

The host agent exists ONLY to bridge the WSL2 nested-container GPU gap. On
any other Linux host, it would be deleted.

---

## Secrets — `jenkins/.env`

Gitignored, never committed, written initially by `setup.sh`. All `${VAR}`
references in `jenkins/casc/jenkins.yaml` and `jenkins/docker-compose.yml`
are injected from here.

| Variable | What it is | Where used |
|----------|-----------|-----------|
| `JENKINS_ADMIN_PASSWORD` | Jenkins login | JCasC security realm |
| `GITHUB_TOKEN` | GitHub PAT | Stored as Jenkins credential `kernelflowPAT` (Username with password type, used by github-branch-source) AND as `github-pat-secret` (Secret text, used by GitHub API rate limiter). Same value, two credentials due to plugin API differences. |
| `WANDB_API_KEY` | Weights & Biases | Passed into Benchmark container via `docker run -e WANDB_API_KEY=...`; `report.py` uploads run metrics |
| `MINIKUBE_SA_TOKEN` | K8s ServiceAccount token | JCasC credential `minikube-sa-token` → Jenkins K8s plugin → authenticates to minikube API |
| `MINIKUBE_API_URL` | minikube API URL | JCasC `serverUrl: ${MINIKUBE_API_URL}` — set to `https://192.168.49.2:8443` (Docker network IP, NOT the host port) |
| `PC_LAN_IP` | LAN IP of GPU PC | JCasC `jenkinsUrl` + `jenkinsTunnel` — used by K8s pods to dial **back** to Jenkins on port 50000 (JNLP). NOT used for inbound webhooks anymore — Cloudflare Tunnel handles that. |
| `GITHUB_WEBHOOK_SECRET` | HMAC secret for webhook payload verification | Generated each time a new tunnel URL is registered (see `docs/local-sop.md` Step 8) |

The Jenkins SA token, kubeconfig, and TLS certs all need to be **regenerated
on every minikube restart** because minikube tears down its CA when stopped.
This is automated in `docs/local-sop.md` Step 5.

---

## Port map and network topology

| Port (host) | Service | Reachability |
|-------------|---------|--------------|
| 8080 | Jenkins UI | `http://localhost:8080` (local), `https://<random>.trycloudflare.com` (public via tunnel) |
| 50000 | Jenkins JNLP | minikube pods + WSL2 host agent dial in here |
| (no host port) | minikube API | Reached from Jenkins controller as `https://192.168.49.2:8443` via the `minikube` Docker network |

Three Docker networks involved:
- **`jenkins_default`** — Jenkins controller and cloudflared sidecar
- **`minikube`** (external, created by `minikube start`) — Jenkins controller is also joined here so it can reach the K8s API
- **default WSL2 networking** — WSL2 host agent connects to `localhost:8080` via Docker port mapping

---

## Docker images

| Image | Built from | Where it runs | Purpose |
|-------|-----------|---------------|---------|
| `kernelflow-build:latest` | `Dockerfile` | minikube pods (CPU stages) AND host Docker (Benchmark stage) | CUDA build environment + test toolchain |
| `kernelflow-jenkins:latest` | `jenkins/Dockerfile.jenkins` | Host Docker (`docker compose`) | Jenkins controller |
| `cloudflare/cloudflared:latest` | (upstream) | Host Docker (`docker compose`) | Quick Tunnel sidecar; `tunnel --url http://jenkins:8080` |

The **build image is loaded into minikube** via `minikube image load
kernelflow-build:latest` and referenced as `docker.io/library/kernelflow-build:latest`
(fully qualified — bare name fails due to containerd's strict resolution).
This must be re-done on every minikube restart; see `docs/local-sop.md` Step 4.

---

## Full pipeline flow — step by step

### Trigger
`git push` → GitHub HTTP POST to the cloudflared public URL → Cloudflare edge
→ outbound tunnel → cloudflared sidecar → `http://jenkins:8080/github-webhook/`
→ Jenkins GitHub plugin → triggers scan of `kernelflow` multibranch job →
reads `Jenkinsfile` from the pushed commit.

Fallback if webhook misses: JCasC configures a 5-minute periodic scan.

### Stage 1 — Build (in pod)
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_COVERAGE=ON \
              -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
make -C build -j$(nproc)
pip3 install . --no-build-isolation -q
```
Outputs: `libkernelflow_baseline.a`, `libkernelflow_fused.a`, `build/bench_all`,
`kernelflow.cpython-*.so` (PyTorch extension wheel installed system-wide in
the pod's Python).

Note: `pip install -e .` was tried and abandoned — PyTorch's CUDAExtension
setup.py predates PEP 660 and lacks the `build_editable` hook
(`docs/development-log.md`).

### Stage 2 — Static Analysis (in pod, three jobs in parallel)

- **clang-tidy** — runs against our kernel files. Only fails the stage if an
  error is reported in `kernels/**/*.{cu,cuh}` (errors from system headers
  are noise — clang-tidy 14 in our base image doesn't fully support CUDA
  12.1 syntax, so PyTorch CUDA texture intrinsic warnings are unavoidable
  until clang-tidy 18+ is in the build image).
- **compute-sanitizer** — **deferred** (logs a message and exits 0). This
  needs GPU access, which the pod doesn't have. Should be moved to the host
  agent stage as a P-future polish item.
- **ruff** — lints `tests/` and `benchmarks/`. Rules E, F, W, I — E501 ignored.

### Stage 3 — Test + Coverage (in pod)
```bash
pytest tests/ --cov=. --cov-report=xml:coverage.xml -v --tb=short
```
22 tests collected. **All currently SKIPPED** because the pod has no GPU
(`@skip_no_cuda` marks fire). Pytest exits 0 — skipped is not failure.
Coverage XML is archived as a build artifact (legacy Cobertura plugin was
removed; see `docs/development-log.md`).

The actual numerical correctness validation happens implicitly during the
Benchmark stage on the host: `bench_all`'s correctness check compares fused
output to two-kernel-baseline output and exits non-zero on `max_err > 1e-5`.

### Stage 4 — Benchmark (on WSL2 host, hard gate)

Routed to the `gpu-host` Jenkins agent. Inside the agent:

```bash
docker run --rm --gpus all \
    -v "${WORKSPACE}:/workspace" -w /workspace \
    -e WANDB_API_KEY="${WANDB_API_KEY}" \
    kernelflow-build:latest \
    bash -c '
        cmake -B build -DCMAKE_BUILD_TYPE=Release \
                      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
        make -C build -j$(nproc)
        ./build/bench_all 2048 4096 10 100
        python3 benchmarks/report.py --result benchmark_result.txt
    '
```

`bench_all` uses `cudaEvent_t` for GPU-side timing. Exits 1 if
`speedup < 1.5×` OR `max_err > 1e-5` → stage fails → Deploy never runs.
On pass: `report.py` uploads run to wandb project `kernelflow` under entity
`yuzheliu007-na`.

### Stage 5 — Deploy (in pod, main branch only)
```bash
python3 setup.py bdist_wheel --dist-dir dist/
cp dist/kernelflow-*.whl /registry/
ln -sf <wheel> /registry/kernelflow-latest.whl
```
`/registry` is the `/opt/kernelflow/registry` host directory volume-mounted
into the pod. Output: `kernelflow-0.1.0-cp311-cp311-linux_x86_64.whl` plus
a stable `kernelflow-latest.whl` symlink.

### Failure outcomes by stage

| Stage fails | Subsequent stages run? | Build colour |
|------------|------------------------|--------------|
| Build | No | Red |
| Any of clang-tidy / ruff / compute-sanitizer | No | Red |
| Test | No | Red |
| Benchmark gate (speedup < 1.5x or max_err > 1e-5) | No | Red |
| Deploy | N/A | Red |

### Typical total time

**~3 minutes warm, ~4-5 minutes cold.** Build dominates (nvcc + PyTorch
extension compile ~2 min; pip install ~2 min on cold cache). Benchmark
itself is sub-second per iteration; the stage time is mostly the in-container
rebuild on the host (which gets its own workspace).

---

## Monitoring from Mac

| What | Where |
|------|-------|
| Pipeline runs + console logs | `http://localhost:8080/job/kernelflow/` (or via tunnel URL from the Mac) |
| Per-build pipeline graph | `http://localhost:8080/blue/...` (pipeline-graph-view plugin) |
| Benchmark history | `https://wandb.ai/yuzheliu007-na/kernelflow` |
| Deployed wheels | SSH GPU PC → `ls /opt/kernelflow/registry/` |

---

## Key architectural decisions — do not re-litigate

(WHY entries from older revisions of this file are preserved unless superseded.)

### Why JCasC for Jenkins config
Manual configuration is not reproducible. JCasC bakes security realm, K8s
cloud, credentials into version-controlled YAML. A fresh `docker compose up`
gives a fully configured Jenkins. The exception is the `kernelflow` multibranch
pipeline job itself — created via UI because the `job-dsl` plugin's API for
`github-branch-source` kept breaking across plugin updates (development-log
Issue 4). One manual click on first boot is acceptable.

### Why a Jenkins K8s plugin AND a separate host agent (hybrid)
K8s pods give per-build isolation and mirror production NVIDIA-style infra.
But on WSL2, the GPU isn't reachable inside nested containers (development-log
Issue 8). The host agent exists ONLY to bridge that gap. On native Linux it
disappears.

### Why two Docker images (kernelflow-build vs kernelflow-jenkins)
The build image is ~8 GB (CUDA + PyTorch + tools); the controller is small
(JRE + plugins). Coupling them would make every Jenkins restart slow.

### Why `imagePullPolicy: Never`
`kernelflow-build` is loaded into minikube via `minikube image load`, not
pushed to a registry. `Never` tells kubelet to use the local image. Keeps
the lab offline-capable.

### Why a host-mounted wheel registry instead of Harbor/Artifactory
A real registry needs TLS, auth, network setup. The host-mounted
`/opt/kernelflow/registry` is sufficient for a single-machine lab. Upgrade
later by changing the `cp` line to `oras push` or `twine upload`.

### Why Cloudflare Quick Tunnel for the webhook
GitHub can't reach private LAN IPs. Cloudflare Tunnel uses outbound-only
connections, no router config, free, no account needed for Quick mode. The
URL changes on each restart (logged in `docs/local-sop.md` Step 7); upgrading
to a Named Tunnel for a stable URL is a P-future polish item.

### Why `bench_all` exits non-zero on gate failure
Jenkins reads exit codes, not stdout. Non-zero = stage fails = Deploy never
runs. Printing a warning while exiting 0 would let bad kernels merge.

### Why multibranch pipeline (not Freestyle or single Pipeline)
Multibranch auto-discovers branches and PRs; every PR gets its own run.
`when { branch 'main' }` on Deploy means PR builds run all gates but never
deploy.

### Why CUDA 12.1 base instead of 12.0
PyTorch 2.3's `cu121` wheel needs `libnvJitLink` symbols only present in
CUDA 12.1+. Bumped from `nvidia/cuda:12.0.0-devel` to
`nvidia/cuda:12.1.1-devel`. See development-log Issue ABI mismatch.

### Why `cudaEvent_t` for benchmarking (not wall-clock)
CUDA launches are async; CPU `std::chrono` measures launch overhead, not
GPU time. `cudaEventRecord` timestamps inside the GPU command queue;
`cudaEventElapsedTime` measures the GPU-side gap. At sub-millisecond kernel
times, the difference is significant.

### Why setup.py separated from CMakeLists.txt
CMake builds standalone C++ executables (bench_all). setup.py builds the
Python `.so` extension linked against libtorch. Different linker requirements,
different consumers. Merging would require finding PyTorch's CMake package,
which breaks offline builds.

---

## Known gaps (P-future polish items)

| Item | Status | Priority |
|------|--------|----------|
| Prometheus + Grafana monitoring stack | Not started; `k8s/grafana-dashboard.json` doesn't exist | High for SDE-targeted polish |
| `compute-sanitizer` GPU memcheck | Currently no-op (deferred to host agent stage) | Medium |
| `time.perf_counter()` in `TestSmokeBenchmark` | Should use `torch.cuda.Event` per project standards | Low |
| Stride-2 memory access in fused kernel Phase 2 | Could vectorize with `float2` for ~1.9× speedup | Medium — worth doing before any further milestone |
| Cloudflare Named Tunnel (stable URL) | Currently Quick Tunnel, URL changes on restart | High — every reboot requires re-registering webhook |
| `scripts/setup.sh` not in sync with hybrid arch | Doesn't provision host agent or cloudflared | Medium — affects new-machine bootstrap |
| Jenkins plugin versions | All `:latest` — reproducibility risk | Medium |
| Codecov / Cobertura coverage rendering | Coverage XML archived; nothing renders it in UI | Low |
| Milestone 2 kernel (`fused_silu_mul`) | Not started | Triggered by user choice — kernel work vs SDE polish |
| Milestone 3 kernel (`fused_attention`) | Not started | Same |

These are tracked in `docs/development-log.md` and `docs/handoff-prompt.md`.
