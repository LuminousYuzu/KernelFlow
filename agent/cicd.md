# CI/CD Context — KernelFlow

Authoritative reference for everything in `jenkins/`, `scripts/`, `Jenkinsfile`, and `k8s/`.
Read this before touching any of those files.

---

## Current status (as of 2026-04-26)

Everything is **scaffolded but not yet run on hardware**.
The GPU PC has not been bootstrapped. The very next action is running `scripts/setup.sh` on the GPU PC for the first time.

---

## File map — what each file does

### Pipeline
| File | Purpose |
|------|---------|
| `Jenkinsfile` | 5-stage declarative pipeline: Build → Static Analysis → Test+Coverage → Benchmark → Deploy. Runs inside a minikube pod. Deploy gated to `main` branch only. |
| `k8s/jenkins-agent.yaml` | Pod spec for the build worker. Requests `nvidia.com/gpu: "1"`. Uses `kernelflow-build:latest` with `imagePullPolicy: Never`. |

### Jenkins controller
| File | Purpose |
|------|---------|
| `jenkins/Dockerfile.jenkins` | Builds the Jenkins controller image from `jenkins/jenkins:lts-jdk17`. Pre-bakes all plugins at image build time — startup is offline-capable and fast. |
| `jenkins/docker-compose.yml` | Runs the Jenkins controller on the GPU PC. Ports 8080 (UI) and 50000 (JNLP). Reads secrets from `jenkins/.env`. Mounts `jenkins/kube/` and `jenkins/minikube-certs/` so Jenkins can reach minikube. |
| `jenkins/casc/jenkins.yaml` | Jenkins Configuration as Code. On first boot: configures security realm, Kubernetes cloud pointed at minikube, all credentials, and creates the `kernelflow` multibranch pipeline job. Zero manual clicks. |
| `jenkins/plugins.txt` | Plugin list consumed by `jenkins-plugin-cli`. Includes: kubernetes, blueocean, github-branch-source, configuration-as-code, cobertura, credentials-binding, ws-cleanup. |

### Build environment
| File | Purpose |
|------|---------|
| `Dockerfile` | CUDA build environment (`nvidia/cuda:12.0.0-devel-ubuntu22.04`). Runs inside K8s pods. Contains: nvcc, PyTorch 2.3, clang-tidy, compute-sanitizer, ruff, pytest, wandb, lcov. |

### Setup scripts
| File | Purpose |
|------|---------|
| `scripts/setup.sh` | **Run once on GPU PC.** Full bootstrap: minikube start with `--gpus=all`, NVIDIA device plugin install, Jenkins K8s service account + RBAC, builds both Docker images, loads `kernelflow-build` into minikube, copies kube certs into `jenkins/kube/`, prompts for 3 secrets, writes `jenkins/.env`, creates `/opt/kernelflow/registry`, starts Jenkins via docker compose. |
| `scripts/register_webhook.sh` | **Run after Jenkins is up.** Posts webhook to GitHub repo pointing at `http://<PC_LAN_IP>:8080/github-webhook/`. Generates HMAC secret via `openssl rand -hex 20`, appends to `jenkins/.env`. Triggers initial branch scan. |

---

## First-time setup sequence (GPU PC, run in this exact order)

```bash
# 1. Clone
git clone https://github.com/LuminousYuzu/KernelFlow && cd KernelFlow

# 2. Bootstrap — ~10-15 min (building Docker images dominates)
bash scripts/setup.sh
# Prompts for:
#   Jenkins admin password
#   GitHub PAT  (needs scopes: repo, admin:repo_hook)
#   wandb API key  (Enter to skip for now)

# 3. Wait ~90 s for Jenkins to boot, then verify:
#    http://<PC_LAN_IP>:8080  →  Jenkins login page

# 4. Register the GitHub webhook
bash scripts/register_webhook.sh

# 5. Trigger the first pipeline run
git commit --allow-empty -m "ci: trigger first pipeline run"
git push origin main
```

---

## Secrets — `jenkins/.env`

Gitignored, never committed, written by `setup.sh`. All `${VAR}` references in `jenkins/casc/jenkins.yaml` and `jenkins/docker-compose.yml` are injected from here.

| Variable | What it is | Where used |
|----------|-----------|-----------|
| `JENKINS_ADMIN_PASSWORD` | Jenkins login | JCasC security realm |
| `GITHUB_TOKEN` | GitHub PAT | JCasC credential → SCM checkout + PR status |
| `WANDB_API_KEY` | Weights & Biases | JCasC credential → `benchmarks/report.py` |
| `MINIKUBE_SA_TOKEN` | K8s service account token | JCasC credential → Kubernetes cloud plugin |
| `MINIKUBE_API_URL` | minikube API server URL (e.g. `https://127.0.0.1:PORT`) | JCasC `serverUrl` |
| `PC_LAN_IP` | LAN IP of GPU PC | JCasC `jenkinsUrl` + `jenkinsTunnel` |
| `GITHUB_WEBHOOK_SECRET` | HMAC secret for webhook payload verification | appended by `register_webhook.sh` |

If `.env` is lost: delete it and re-run `setup.sh` — it detects the existing file and skips prompts unless you delete it first.

---

## Port map

| Port | Service | From Mac |
|------|---------|----------|
| 8080 | Jenkins Web UI (Blue Ocean) | `http://<PC_LAN_IP>:8080` |
| 50000 | Jenkins JNLP agent tunnel | used internally by minikube pods |

---

## Docker images

| Image | Built from | In minikube? | Purpose |
|-------|-----------|-------------|---------|
| `kernelflow-build:latest` | `Dockerfile` | Yes (`minikube image load`) | CUDA worker; runs as the pipeline pod container |
| `kernelflow-jenkins:latest` | `jenkins/Dockerfile.jenkins` | No | Jenkins controller; runs on host via docker compose |

---

## Full pipeline flow — step by step

### Trigger
`git push` → GitHub POSTs to `http://<PC_LAN_IP>:8080/github-webhook/` → Jenkins GitHub plugin → triggers scan of `kernelflow` multibranch job → reads `Jenkinsfile` from the pushed commit.

Fallback if webhook is missed: JCasC configures a 5-minute periodic scan.

### Pod creation
Jenkins Kubernetes plugin sends `k8s/jenkins-agent.yaml` to the minikube API. The pod starts with two containers:
- **`cuda-build`** (`kernelflow-build:latest`) — where all pipeline `sh` steps execute. Has real GPU via NVIDIA device plugin.
- **`jnlp`** (`jenkins/inbound-agent:latest`) — the control sidecar. It dials *out* to Jenkins on port 50000 and establishes the command channel. Jenkins sends shell commands in over this connection; the sidecar forwards them into `cuda-build`.

This two-container pattern is required by the Jenkins Kubernetes plugin — `jnlp` handles the protocol, `cuda-build` handles the work.

### Stage 1 — Build
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_COVERAGE=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
make -C build -j$(nproc)
pip3 install -e . --no-build-isolation
```
Outputs: `libkernelflow_baseline.a`, `libkernelflow_fused.a`, `build/bench_all`, `kernelflow.cpython-*.so`
Failure modes: nvcc compile error, missing CUDA headers, CMake config error, PyTorch not found.

### Stage 2 — Static Analysis (three tools in parallel)
- **clang-tidy**: reads `.clang-tidy` + `build/compile_commands.json`. Shell script greps output for `warning:/error:` lines and fails the stage if any are found.
- **compute-sanitizer**: runs `build/bench_all 16 64 1 1` under `--tool memcheck`. Small shape (N=16, D=64) keeps it fast while still exercising all memory paths. Catches: OOB global memory, uninitialised reads, race conditions.
- **ruff**: lints `tests/` and `benchmarks/`. Rules E, F, W, I — E501 (line length) ignored.

### Stage 3 — Test + Coverage
```bash
pytest tests/ --cov=. --cov-report=xml:coverage.xml -v --tb=short
```
PyTorch native ops serve as ground truth. Tolerance: 1e-5 max absolute error.
Key test shapes: single token, LLaMA-7B (`N=512, D=4096`), LLaMA-70B (`D=8192`), near-zero stability, no input mutation.
Coverage published as Cobertura XML — Jenkins Cobertura plugin renders trend charts.

### Stage 4 — Benchmark (hard gate)
```bash
build/bench_all 2048 4096 10 100   # N=2048, D=4096, 10 warmup, 100 timed iters
python3 benchmarks/report.py --result benchmark_result.txt
```
`bench_all` uses `cudaEvent_t` for GPU-side timing (not wall-clock — see WHY section below).
Exits 1 if speedup < 1.5× OR max_err > 1e-5 → stage fails → Deploy never runs.
On pass: writes `benchmark_result.txt`, `report.py` uploads to wandb project `kernelflow`.

### Stage 5 — Deploy (main branch only)
```bash
python3 setup.py bdist_wheel --dist-dir dist/
cp dist/kernelflow-*.whl /registry/
ln -sf <wheel> /registry/kernelflow-latest.whl
```
`/registry` in the pod is volume-mounted from `/opt/kernelflow/registry` on the GPU PC host.
Output: `kernelflow-0.1.0-cp311-cp311-linux_x86_64.whl` + `kernelflow-latest.whl` symlink.

### Failure outcomes by stage
| Stage fails | Deploy runs? | Build colour |
|------------|-------------|-------------|
| Build | No | Red |
| Any static analysis tool | No | Red |
| Any test | No | Red |
| Benchmark gate (speedup or error) | No | Red |
| Deploy | N/A | Red |

### Typical total time
**8–15 minutes.** Dominated by nvcc compilation (~5 min). Subsequent runs are faster if unchanged files are not recompiled (incremental make).

---

## Monitoring from Mac

| What | Where |
|------|-------|
| Pipeline runs + logs | `http://<PC_LAN_IP>:8080/blue/pipelines` |
| Benchmark history | wandb.ai → project `kernelflow` |
| Deployed wheels | SSH GPU PC → `ls /opt/kernelflow/registry/` |

---

## WHY — decisions made, do not re-litigate

### Why JCasC instead of manual Jenkins setup
Manual configuration is not reproducible — if the Docker volume is lost, everything is gone and setup must be redone by hand. JCasC bakes all configuration (security, K8s cloud, credentials, the pipeline job itself) into `jenkins/casc/jenkins.yaml`, which is version-controlled. A fresh `docker compose up` gives a fully configured Jenkins with zero clicks.

### Why Kubernetes plugin instead of a Jenkins agent running directly on the GPU PC
K8s pods isolate each build in a fresh container — no state leaks between runs (e.g. a previous build's compiled artifacts affecting the next). Each job starts from a clean `kernelflow-build` image. This also mirrors real NVIDIA infrastructure where every CI job runs in a disposable pod.

### Why two Docker images (kernelflow-build vs kernelflow-jenkins)
`kernelflow-build` needs nvcc, cuBLAS, PyTorch, clang-tidy — it's ~8 GB. `kernelflow-jenkins` is the controller: just JRE + plugins, no CUDA. Coupling the controller to a CUDA base would make it 8 GB and make every Jenkins restart slow. Keep them separate: the controller is lightweight and fast to restart; the build image is large but only spins up during pipeline runs.

### Why `imagePullPolicy: Never` in k8s/jenkins-agent.yaml
`kernelflow-build` is loaded directly into minikube via `minikube image load`, not pushed to DockerHub or any registry. `Never` tells the kubelet not to contact a registry — it uses the locally cached image. Keeps the setup offline-capable and avoids registry auth complexity. To update the image: rebuild locally, re-run `minikube image load`.

### Why the Deploy stage uses a host-mounted volume instead of a container registry
A real registry (Harbor, Artifactory) requires TLS, auth, and network setup. The host-mounted `/opt/kernelflow/registry` is simple and sufficient for a single-machine lab. Upgradeable later: change the `cp` line to `twine upload` or `oras push` without touching anything else in the pipeline.

### Why bench_all exits non-zero on gate failure
Jenkins reads exit codes, not stdout. A non-zero exit from any `sh` step fails the stage. Printing a warning to stdout while exiting 0 would let the pipeline continue and deploy a kernel that didn't clear the gate. The exit code is the only reliable gate.

### Why multibranch pipeline (not a Freestyle or single Pipeline job)
Multibranch auto-discovers branches and PRs. Every PR gets its own pipeline run so quality gates run before merge. The `when { branch 'main' }` guard in the Deploy stage means PR builds run all gates but never deploy — only merged commits to `main` deploy. This matches real team workflows.

### Why GITHUB_WEBHOOK_SECRET is generated at runtime and stored in .env
The secret is created by `openssl rand -hex 20` during `register_webhook.sh` — it can't be known at authoring time and must never be hardcoded. Jenkins uses it to verify the HMAC signature on every incoming webhook payload, blocking spoofed builds from unauthorized senders.

### Why setup.py (CUDAExtension) is separate from CMakeLists.txt
CMake builds standalone C++ executables (the benchmark binary). `setup.py` builds the Python `.so` extension linked against libtorch. They have different linker requirements and different consumers. Merging them would require finding PyTorch's CMake package, which breaks offline builds and adds fragility for a marginal gain.

### Why cudaEvent_t for GPU timing (not std::chrono wall-clock)
CUDA kernel launches are asynchronous — the CPU returns from `cudaLaunchKernel` before the GPU finishes. `std::chrono` on the CPU therefore measures launch overhead + scheduling jitter, not actual kernel execution time. `cudaEventRecord` timestamps are inserted directly into the GPU command queue; `cudaEventElapsedTime` measures the gap between two GPU-side timestamps. At sub-millisecond kernel times the difference between these two approaches is significant.

---

## Known gaps

| Item | Status |
|------|--------|
| `k8s/grafana-dashboard.json` | Stub file only — Grafana + Prometheus not yet wired (Week 7) |
| Codecov upload | lcov installed in `Dockerfile` but upload step not in `Jenkinsfile` yet |
| Milestone 2 kernel (`fused_silu_mul`) | Not started — wait for Milestone 1 to pass 1.5× gate on real hardware |
| Milestone 3 kernel (`fused_attention`) | Not started |
