"""
pytest configuration for KernelFlow test suite.

Adds --gpu flag to restrict tests to GPU-only suites and registers
custom markers so pytest does not emit warnings about unknown marks.
"""

import pytest


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--gpu-only",
        action="store_true",
        default=False,
        help="Run only tests that require a CUDA GPU.",
    )


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line(
        "markers",
        "cuda: mark test as requiring a CUDA-capable GPU",
    )
