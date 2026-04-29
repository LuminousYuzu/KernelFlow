# Working Style — KernelFlow

Context for how to collaborate on this project effectively.
Read this at the start of any session, especially when picking up on a different machine.

---

## Project goal

KernelFlow is a **production-quality portfolio project** targeting NVIDIA's Deep Learning Libraries Group (cuDNN / FlashInfer infrastructure team). Every piece of the system — the kernels, the CI/CD, the K8s setup — is designed to mirror real NVIDIA internal infrastructure. The audience for this code is an NVIDIA hiring panel.

This means: no toy implementations, no tutorial-level shortcuts, no "good enough for a demo." If NVIDIA engineers wouldn't write it this way, don't write it that way.

---

## Development pattern

| Machine | Role |
|---------|------|
| MacBook | Code editing (VS Code), all writing and planning |
| Windows GPU PC | Compilation, test execution, Jenkins, minikube, actual GPU runs |

Work happens on the Mac. Output is verified on the GPU PC. The two machines share code via GitHub. Context must always be recoverable from repo files alone — never assume Mac-local state carries over to the PC.

---

## Code quality expectations

### CUDA C++
- Always use warp-level reductions (`__shfl_xor_sync`) before falling back to shared memory — minimize barrier count
- Use `__restrict__` on all pointer arguments
- Use `#pragma unroll` on fixed-iteration inner loops
- Time GPU kernels with `cudaEvent_t`, never `std::chrono`
- Use `rsqrtf` not `1.0f / sqrtf` for reciprocal square root
- Shared memory size must be a compile-time constant — no dynamic allocation unless explicitly needed
- Every kernel launch must be followed by `CUDA_CHECK(cudaGetLastError())`

### CI/CD / infrastructure
- Jenkins configuration lives in `jenkins/casc/jenkins.yaml` (JCasC) — never describe manual UI steps
- All secrets go in `jenkins/.env` (gitignored) — never hardcode credentials
- K8s RBAC: service accounts get only the permissions they need (pods, secrets, events — not cluster-admin)
- `bench_all` exits non-zero on gate failure — Jenkins reads exit codes, not stdout

### Python
- ruff-clean: E, F, W, I rules (E501 ignored)
- Type hints on all function signatures
- PyTorch extension inputs validated with `TORCH_CHECK` in C++, not try/except in Python

---

## Decisions already made — do not suggest alternatives without strong reason

| Decision | Rationale |
|----------|-----------|
| JCasC for Jenkins config | Reproducible, version-controlled, zero manual clicks |
| Two Docker images (build vs controller) | Keeps Jenkins controller lightweight; build image is ~8 GB |
| `imagePullPolicy: Never` | Build image pre-loaded into minikube; no registry needed |
| Host-mounted wheel registry | Simpler than Harbor/Artifactory for a single-machine lab |
| kBlockSize = 256 | 8 warps, 32-byte smem scratch, sufficient for D up to 8192 |
| Separate setup.py from CMakeLists.txt | Different linker requirements; offline build robustness |
| Multibranch pipeline | PRs get isolated runs; Deploy gated to main only |
| Hybrid pipeline (pod + host agent) | Forced by WSL2 nested-container GPU limit; on native Linux this would all be in pods. See `docs/development-log.md` Issues 8-10 |
| Cloudflare Tunnel for webhook | GitHub can't reach private LAN IPs; outbound tunnel avoids router config |
| Pipeline job created via UI (not JCasC) | `job-dsl` plugin's GitHub source API kept breaking; one-time UI click is acceptable |

---

## What to do at the start of a new session on the GPU PC

1. Read `agent/cicd.md` for current CI/CD state and architecture
2. Read `agent/kernels.md` for kernel status and what milestone is active
3. Read `docs/development-log.md` for the full history of issues + decisions
4. Read `docs/local-sop.md` (gitignored, GPU-PC-local) for cold-start procedure
5. Check `git log --oneline -10` to see what was last committed
6. If the GPU PC has not been bootstrapped yet: run `bash scripts/setup.sh` first
7. After every reboot: follow `docs/local-sop.md` to reload images, refresh
   minikube credentials, and re-register the webhook (tunnel URL changes)
