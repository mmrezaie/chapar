#!/usr/bin/env bash
# DESCRIPTION: CPU ISA, vendor, feature, NUMA, PCI, release metadata, and ELF compatibility evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:03:00
#SBATCH --job-name=cpu-platform

set -euo pipefail

usage() {
    printf '%s\n' 'Usage: cpu-platform.sbatch [--fixture validation/fixtures/cpu/<case>]'
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
fixture=""

if [ "${1:-}" = --fixture ]; then
    [ "$#" = 2 ] || { usage; exit 2; }
    fixture="$2"
    [ -f "${fixture}/manifest.json" ] || { printf 'CPU fixture manifest is missing: %s\n' "${fixture}" >&2; exit 2; }
elif [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

source "${validation_dir}/lib/verdict.sh"
source "${validation_dir}/lib/result-manifest.sh"
validation_result_init cpu-platform "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export CPU_PLATFORM_FIXTURE="${fixture}"
export CPU_PLATFORM_RESULT="${results_dir}/cpu_platform.json"
export CPU_PLATFORM_EXPECTED_PLATFORM="${VALIDATION_CPU_PLATFORM:-}"
export CPU_PLATFORM_EXPECTED_VENDOR="${VALIDATION_CPU_VENDOR:-}"
export CPU_PLATFORM_REQUIRED_FEATURES="${VALIDATION_CPU_REQUIRED_FEATURES:-}"
export CPU_PLATFORM_EXPECTED_NUMA_NODES="${VALIDATION_CPU_NUMA_NODES:-}"
export CPU_PLATFORM_EXPECTED_PCI_DEVICES="${VALIDATION_CPU_PCI_DEVICES:-}"
export CPU_PLATFORM_RELEASE_DIR="${CHAPAR_RELEASE_DIR:-}"
export CPU_PLATFORM_ELF_PATHS="${CHAPAR_ELF_PATHS:-}"

python3 <<'PY'
import json
import os
import pathlib
import platform
import subprocess


def output(*command):
    try:
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return ""
    return completed.stdout if completed.returncode == 0 else ""


def normalized_architecture(value):
    value = value.lower()
    if value in {"x86_64", "amd64"}:
        return "x86_64"
    if value in {"aarch64", "arm64"}:
        return "aarch64"
    return value


def machine_for_architecture(architecture):
    return "AArch64" if architecture == "aarch64" else "X86-64"


def vendor_for_cpuinfo(cpuinfo, architecture):
    lower = cpuinfo.lower()
    if "genuineintel" in lower or "intel" in lower:
        return "intel"
    if "authenticamd" in lower or "amd" in lower:
        return "amd"
    if "nvidia" in lower and architecture == "aarch64":
        return "nvidia"
    return "generic"


def features_for_cpuinfo(cpuinfo):
    names = ("flags", "features")
    values = set()
    for line in cpuinfo.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip().lower() in names:
            values.update(value.strip().lower().split())
    return sorted(values)


def release_architecture(release_dir):
    if not release_dir:
        return "", ""
    path = pathlib.Path(release_dir) / ".chapar-arch"
    if not path.is_file():
        return "", f"release metadata is missing: {path}"
    return path.read_text(encoding="utf-8").strip(), ""


def elf_machines(paths):
    values = []
    for path in paths:
        if not pathlib.Path(path).is_file():
            values.append({"path": path, "machine": "", "error": "not a regular file"})
            continue
        header = output("readelf", "-h", path)
        machine = next((line.split(":", 1)[1].strip() for line in header.splitlines() if line.strip().startswith("Machine:")), "")
        values.append({"path": path, "machine": machine, "error": "" if machine else "readelf did not report ELF machine"})
    return values


def fixture_payload(path):
    return json.loads((pathlib.Path(path) / "manifest.json").read_text(encoding="utf-8"))


fixture = os.environ["CPU_PLATFORM_FIXTURE"]
if fixture:
    payload = fixture_payload(fixture)
    observed = payload["cpu_platform"]
    expected = payload["expected"]
    declared = payload["verdicts"]["cpu-platform"]
else:
    cpuinfo = pathlib.Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace") if pathlib.Path("/proc/cpuinfo").is_file() else ""
    architecture = normalized_architecture(platform.machine())
    release_arch, release_error = release_architecture(os.environ["CPU_PLATFORM_RELEASE_DIR"])
    configured_paths = [path for path in os.environ["CPU_PLATFORM_ELF_PATHS"].split(":") if path]
    observed = {
        "architecture": architecture,
        "vendor": vendor_for_cpuinfo(cpuinfo, architecture),
        "features": features_for_cpuinfo(cpuinfo),
        "numa_nodes": len(list(pathlib.Path("/sys/devices/system/node").glob("node[0-9]*"))),
        "pci_devices": len(list(pathlib.Path("/sys/bus/pci/devices").glob("*"))),
        "chapar_arch": release_arch,
        "release_error": release_error,
        "elf": elf_machines(configured_paths),
    }
    expected = {
        "platform": os.environ["CPU_PLATFORM_EXPECTED_PLATFORM"],
        "vendor": os.environ["CPU_PLATFORM_EXPECTED_VENDOR"],
        "features": [value for value in os.environ["CPU_PLATFORM_REQUIRED_FEATURES"].lower().split(",") if value],
        "numa_nodes": os.environ["CPU_PLATFORM_EXPECTED_NUMA_NODES"],
        "pci_devices": os.environ["CPU_PLATFORM_EXPECTED_PCI_DEVICES"],
    }
    declared = ""

failures = []
warnings = []
architecture = normalized_architecture(observed["architecture"])
vendor = observed["vendor"].lower()
platform_name = expected.get("platform", "")
if architecture not in {"x86_64", "aarch64"}:
    failures.append(f"unsupported host ISA: {architecture}")
if platform_name:
    expected_platform = {
        "intel-x86": ("x86_64", "intel"),
        "amd-x86": ("x86_64", "amd"),
        "nvidia-grace": ("aarch64", "nvidia"),
        "generic": (architecture, "generic"),
    }.get(platform_name)
    if expected_platform is None:
        failures.append(f"unsupported expected CPU platform: {platform_name}")
    elif architecture != expected_platform[0] or (expected_platform[1] != "generic" and vendor != expected_platform[1]):
        failures.append(f"CPU platform mismatch: expected={platform_name}, architecture={architecture}, vendor={vendor}")
expected_vendor = expected.get("vendor", "")
if expected_vendor and expected_vendor != "generic" and vendor != expected_vendor:
    failures.append(f"CPU vendor mismatch: expected={expected_vendor}, got={vendor}")
missing_features = sorted(set(expected.get("features", [])) - set(observed.get("features", [])))
if missing_features:
    failures.append(f"missing required CPU features: {','.join(missing_features)}")
for key in ("numa_nodes", "pci_devices"):
    value = expected.get(key, "")
    if value not in (None, "") and int(observed[key]) != int(value):
        failures.append(f"{key} mismatch: expected={value}, got={observed[key]}")
release_arch = observed.get("chapar_arch", "")
if observed.get("release_error"):
    failures.append(observed["release_error"])
elif release_arch:
    release_is_arm = "aarch64" in release_arch
    release_is_x86 = any(token in release_arch for token in ("x86_64", "zen", "skylake", "icelake", "sapphirerapids"))
    if not release_is_arm and not release_is_x86:
        failures.append(f".chapar-arch has no supported CPU ISA target: {release_arch}")
    elif release_is_arm != (architecture == "aarch64"):
        failures.append(f".chapar-arch is incompatible with host ISA: {release_arch} vs {architecture}")
    elif "zen" in release_arch and vendor != "amd":
        failures.append(f".chapar-arch requires an AMD Zen target but host vendor is {vendor}")
elif not fixture:
    warnings.append("CHAPAR_RELEASE_DIR was not supplied; .chapar-arch compatibility was not evaluated")
expected_machine = machine_for_architecture(architecture)
for elf in observed.get("elf", []):
    if elf["error"]:
        failures.append(f"ELF inspection failed for {elf['path']}: {elf['error']}")
    elif expected_machine not in elf["machine"]:
        failures.append(f"ELF machine is incompatible with host ISA: {elf['path']} reports {elf['machine']}")
if not observed.get("elf") and not fixture:
    warnings.append("CHAPAR_ELF_PATHS was not supplied; ELF compatibility was not evaluated")

verdict = "FAIL" if failures else "WARN" if warnings else "PASS"
if declared and verdict != declared:
    failures.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture), "expected": expected, "observed": observed,
    "verdict": verdict, "failures": failures, "warnings": warnings,
    "elf_scope": "ELF machine compatibility only; CPU microarchitecture is never inferred from ELF",
}
pathlib.Path(os.environ["CPU_PLATFORM_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

verdict="$(python3 -c "import json; print(json.load(open('${results_dir}/cpu_platform.json'))['verdict'])")"
reason="$(python3 -c "import json; value=json.load(open('${results_dir}/cpu_platform.json')); print('; '.join(value['failures'] or value['warnings']))")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
esac

printf 'CPU platform evidence written to %s\n' "${results_dir}" >&2
