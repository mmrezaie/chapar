#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

bash "${ROOT}/ci/tests/software-specs-offline-gate.sh" --self-test-python-quality
