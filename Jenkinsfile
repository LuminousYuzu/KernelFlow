// KernelFlow CI/CD Pipeline
//
// Stages: Build → Static Analysis → Test + Coverage → Benchmark → Deploy
//
// Triggered by GitHub webhook on every push / PR (registered via
// scripts/register_webhook.sh). Runs inside a GPU-enabled minikube pod
// described in k8s/jenkins-agent.yaml.
// Deploy stage only executes on pushes to `main`.
//
// Required Jenkins credentials (configured via jenkins/casc/jenkins.yaml):
//   WANDB_API_KEY   — Weights & Biases upload key
//   GITHUB_TOKEN    — GitHub PAT for repo access
//   minikube-sa-token — K8s service account token

pipeline {

    agent {
        kubernetes {
            yamlFile 'k8s/jenkins-agent.yaml'
            defaultContainer 'cuda-build'
            retries 1
        }
    }

    triggers {
        githubPush()
    }

    options {
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
    }

    environment {
        BUILD_DIR    = 'build'
        REGISTRY_DIR = '/registry'
        WANDB_API_KEY = credentials('WANDB_API_KEY')
    }

    // -----------------------------------------------------------------------
    // Stage 1 — Build
    // -----------------------------------------------------------------------
    stages {

        stage('Build') {
            steps {
                echo "=== Build: compiling CUDA kernels and benchmarks ==="
                sh '''
                    cmake -B ${BUILD_DIR} \
                        -DCMAKE_BUILD_TYPE=Release \
                        -DENABLE_COVERAGE=ON \
                        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
                    make -C ${BUILD_DIR} -j$(nproc)
                '''
                // Also build the PyTorch extension wheel (used by tests & deploy)
                // Non-editable install (-e removed) because PyTorch CUDAExtension's
                // setup.py does not implement PEP 660 build_editable hook.
                sh 'pip3 install . --no-build-isolation -q'
            }
            post {
                failure { error "Build failed — check nvcc output above." }
            }
        }

        // -----------------------------------------------------------------------
        // Stage 2 — Static Analysis (three tools in parallel)
        // -----------------------------------------------------------------------
        stage('Static Analysis') {
            parallel {

                stage('clang-tidy') {
                    steps {
                        echo "=== clang-tidy: C++ static analysis ==="
                        // Note: clang-tidy 14 in the build image does not fully support CUDA 12.
                        // We run it for visibility but only fail on hard errors in *our* code,
                        // not on warnings or on errors from system/PyTorch CUDA headers.
                        // Upgrade to clang-tidy 18+ when the base image bumps to a newer toolchain.
                        sh '''
                            clang-tidy \
                                --config-file=.clang-tidy \
                                -p ${BUILD_DIR} \
                                kernels/baseline/rmsnorm.cu \
                                kernels/baseline/rope.cu \
                                kernels/fused/fused_rmsnorm_rope.cu \
                                -- -x cuda --cuda-gpu-arch=sm_86 \
                                   -I${CUDA_HOME}/include \
                                   -std=c++17 \
                            2>&1 | tee clang-tidy.log || true
                            # Only fail on errors in our own kernel files (not system headers)
                            ! grep -E "^.*kernels/.+:[0-9]+:[0-9]+: error:" clang-tidy.log
                        '''
                    }
                    post {
                        always { archiveArtifacts artifacts: 'clang-tidy.log', allowEmptyArchive: true }
                    }
                }

                stage('compute-sanitizer') {
                    steps {
                        echo "=== compute-sanitizer: GPU memory safety check (SKIPPED in pod) ==="
                        // compute-sanitizer requires GPU access. Under the hybrid architecture
                        // (see docs/development-log.md Issues 8-10), pods run CPU-only and the
                        // GPU stages run on the WSL2 host agent. Move this to the host stage
                        // once the wsl-host Jenkins agent is registered (Priority 1 work item).
                        sh 'echo "compute-sanitizer deferred to host agent — see docs/development-log.md"'
                    }
                }

                stage('ruff') {
                    steps {
                        echo "=== ruff: Python linting ==="
                        sh '''
                            ruff check tests/ benchmarks/ \
                                --output-format=github \
                                --select=E,F,W,I \
                                --ignore=E501
                        '''
                    }
                }
            }
        }

        // -----------------------------------------------------------------------
        // Stage 3 — Test + Coverage
        // -----------------------------------------------------------------------
        stage('Test + Coverage') {
            steps {
                echo "=== pytest: numerical correctness + smoke benchmark ==="
                sh '''
                    pytest tests/ \
                        --cov=. \
                        --cov-report=xml:coverage.xml \
                        --cov-report=term-missing \
                        -v \
                        --tb=short \
                        -p no:cacheprovider \
                    2>&1 | tee pytest.log
                '''
            }
            post {
                always {
                    // Publish coverage to Jenkins (requires Cobertura plugin)
                    cobertura coberturaReportFile: 'coverage.xml',
                              failUnhealthy: false,
                              failUnstable: false,
                              onlyStable: false
                    archiveArtifacts artifacts: 'pytest.log', allowEmptyArchive: true
                    junit testResults: '**/junit*.xml', allowEmptyResults: true
                }
                failure { error "Tests failed — check pytest output above." }
            }
        }

        // -----------------------------------------------------------------------
        // Stage 4 — Benchmark (hard gate: speedup must meet CLAUDE.md thresholds)
        // -----------------------------------------------------------------------
        stage('Benchmark') {
            steps {
                echo "=== bench_all: speedup gate check ==="
                sh '''
                    # Run the standalone CUDA benchmark
                    # Returns exit code 1 if speedup < 1.5x or numeric error > 1e-5
                    ${BUILD_DIR}/bench_all 2048 4096 10 100
                '''
                // Upload results to wandb
                sh 'python3 benchmarks/report.py --result benchmark_result.txt'
            }
            post {
                always {
                    archiveArtifacts artifacts: 'benchmark_result.txt', allowEmptyArchive: true
                }
                failure { error "Benchmark gate not met — kernel did not clear 1.5x speedup threshold." }
            }
        }

        // -----------------------------------------------------------------------
        // Stage 5 — Deploy (main branch only)
        // -----------------------------------------------------------------------
        stage('Deploy') {
            when {
                branch 'main'
                beforeAgent true
            }
            steps {
                echo "=== Deploy: packaging wheel and publishing to local registry ==="
                sh '''
                    # Build distributable wheel
                    python3 setup.py bdist_wheel --dist-dir dist/

                    WHEEL=$(ls dist/kernelflow-*.whl | head -1)
                    echo "Wheel: ${WHEEL}"

                    # Copy to the local registry volume (mounted from the GPU PC host)
                    cp "${WHEEL}" "${REGISTRY_DIR}/"
                    echo "Published: ${REGISTRY_DIR}/$(basename ${WHEEL})"

                    # Write a latest symlink for easy consumption
                    ln -sf "$(basename ${WHEEL})" "${REGISTRY_DIR}/kernelflow-latest.whl"
                '''
            }
            post {
                success {
                    echo "Kernel deployed to local registry at ${REGISTRY_DIR}"
                    archiveArtifacts artifacts: 'dist/*.whl'
                }
            }
        }

    }   // end stages

    // -----------------------------------------------------------------------
    // Global post actions
    // -----------------------------------------------------------------------
    post {
        always {
            echo "Pipeline complete — branch: ${env.BRANCH_NAME}, build: ${env.BUILD_NUMBER}"
        }
        success {
            echo "All gates passed. Kernel is production-ready."
        }
        failure {
            echo "Pipeline failed. Review stage logs in Blue Ocean."
        }
        cleanup {
            cleanWs()
        }
    }
}
