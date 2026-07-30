#!/usr/bin/env bash

rdma_selected_hcas() {
    local profile="${VALIDATION_SITE_PROFILE:-}"

    if [ -n "${VALIDATION_RDMA_HCAS:-}" ]; then
        tr ',' '\n' <<<"${VALIDATION_RDMA_HCAS}" | while IFS= read -r hca; do
            [ -n "${hca}" ] && [ -d "/sys/class/infiniband/${hca}" ] && printf '%s\n' "${hca}"
        done
        return
    fi

    python3 - "${profile}" <<'PY'
import pathlib
import re
import sys

profile_path = sys.argv[1]
hcas = sorted(path.name for path in pathlib.Path("/sys/class/infiniband").glob("*"))
patterns = []
if profile_path:
    import yaml
    with open(profile_path, encoding="utf-8") as stream:
        profile = yaml.safe_load(stream) or {}
    patterns = [entry.get("name_pattern", "") for entry in profile.get("topology", {}).get("rdma", {}).get("hcas", [])]

for hca in hcas:
    if not patterns or any(pattern and re.fullmatch(pattern, hca) for pattern in patterns):
        print(hca)
PY
}

rdma_selected_hca() {
    local hca
    hca="$(rdma_selected_hcas | sort | head -n 1)"
    [ -n "${hca}" ] || return 1
    printf '%s\n' "${hca}"
}

rdma_benchmark_edge_limit() {
    local fallback="${RDMA_BENCHMARK_MAX_EDGES:-1}"
    local profile="${VALIDATION_SITE_PROFILE:-}"

    if [ -z "${profile}" ]; then
        printf '%s\n' "${fallback}"
        return
    fi

    python3 - "${profile}" "${fallback}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    profile = yaml.safe_load(stream) or {}
print(profile.get("topology", {}).get("rdma", {}).get("max_benchmark_edges", sys.argv[2]))
PY
}
