#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' "Usage: gameplay-representative-performance.sh --candidate-sha SHA --evidence-root PATH"
}

candidate_sha=""
evidence_root=""
while (($# > 0)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
candidate_sha="$(git -C "$repository_root" rev-parse --verify "${candidate_sha}^{commit}")"
[[ "$candidate_sha" == "$(git -C "$repository_root" rev-parse HEAD)" ]] || {
    printf '%s\n' "candidate SHA is not current HEAD" >&2
    exit 1
}
git -C "$repository_root" diff --quiet --ignore-submodules -- &&
    git -C "$repository_root" diff --cached --quiet --ignore-submodules -- || {
    printf '%s\n' "candidate worktree or index has tracked changes" >&2
    exit 1
}
[[ -n "$evidence_root" ]] || { usage >&2; exit 1; }
mkdir -p "$evidence_root"
evidence_root="$(cd -- "$evidence_root" && pwd)"

emit_prefix="$evidence_root/emit"
build_stdout="$evidence_root/build.stdout"
build_stderr="$evidence_root/build.stderr"
(
    cd -- "$repository_root"
    zig build emit-runtime-core-representative-bench \
        --prefix "$emit_prefix" -Doptimize=ReleaseSafe -Dgameplay-quality-evidence=true \
        -Dgameplay-quality-emit-dir=gameplay-evidence --summary all
) >"$build_stdout" 2>"$build_stderr"
benchmark="$emit_prefix/gameplay-evidence/runtime-core-representative-bench"
[[ -x "$benchmark" ]] || { printf '%s\n' 'representative benchmark was not emitted' >&2; exit 1; }

raw_stdout="$evidence_root/representative.stdout"
raw_stderr="$evidence_root/representative.stderr"
time_file="$evidence_root/representative.time"
set +e
/usr/bin/time -v -o "$time_file" "$benchmark" >"$raw_stdout" 2>"$raw_stderr"
run_status=$?
set -e

metric() {
    local name=$1
    sed -n "s/.*representative_${name}_samples=\([0-9][0-9]*\) p95_ns=\([0-9][0-9]*\) p99_ns=\([0-9][0-9]*\) allocations=\([0-9][0-9]*\).*/\1 \2 \3 \4/p" \
        "$raw_stdout" "$raw_stderr" | tail -n 1
}
fixed=($(metric fixed_step))
phase=($(metric phase_drain))
snapshot=($(metric snapshot))
restart=($(metric restart))
reload=($(metric scene_reload))

status=PASS
[[ "$run_status" == 0 ]] || status=BLOCKED
for values in "${fixed[*]-}" "${phase[*]-}" "${snapshot[*]-}" "${restart[*]-}" "${reload[*]-}"; do
    [[ "$values" =~ ^[0-9]+[[:space:]][0-9]+[[:space:]][0-9]+[[:space:]][0-9]+$ ]] || status=BLOCKED
done
for values in "${fixed[*]-}" "${phase[*]-}" "${snapshot[*]-}"; do
    [[ "${values##* }" == 0 ]] || status=BLOCKED
done

payload="$evidence_root/representative.payload"
report="$evidence_root/representative.report"
benchmark_sha="$(sha256sum "$benchmark" | awk '{print $1}')"
cat >"$payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=gameplay-representative-performance.sh --candidate-sha $candidate_sha --evidence-root $evidence_root
GAMEPLAY_REPRESENTATIVE_STATUS=$status
GAMEPLAY_REPRESENTATIVE_SAMPLES=${fixed[0]-0}
GAMEPLAY_REPRESENTATIVE_ACTIVE_OBJECTS=128
GAMEPLAY_REPRESENTATIVE_PHASE_EVENTS=64
GAMEPLAY_REPRESENTATIVE_FIXED_STEP_P95_NS=${fixed[1]-0}
GAMEPLAY_REPRESENTATIVE_FIXED_STEP_P99_NS=${fixed[2]-0}
GAMEPLAY_REPRESENTATIVE_FIXED_STEP_ALLOCATIONS=${fixed[3]-0}
GAMEPLAY_REPRESENTATIVE_PHASE_DRAIN_P95_NS=${phase[1]-0}
GAMEPLAY_REPRESENTATIVE_PHASE_DRAIN_P99_NS=${phase[2]-0}
GAMEPLAY_REPRESENTATIVE_PHASE_DRAIN_ALLOCATIONS=${phase[3]-0}
GAMEPLAY_REPRESENTATIVE_SNAPSHOT_P95_NS=${snapshot[1]-0}
GAMEPLAY_REPRESENTATIVE_SNAPSHOT_P99_NS=${snapshot[2]-0}
GAMEPLAY_REPRESENTATIVE_SNAPSHOT_ALLOCATIONS=${snapshot[3]-0}
GAMEPLAY_REPRESENTATIVE_RESTART_P95_NS=${restart[1]-0}
GAMEPLAY_REPRESENTATIVE_RESTART_P99_NS=${restart[2]-0}
GAMEPLAY_REPRESENTATIVE_RESTART_ALLOCATIONS=${restart[3]-0}
GAMEPLAY_REPRESENTATIVE_SCENE_RELOAD_P95_NS=${reload[1]-0}
GAMEPLAY_REPRESENTATIVE_SCENE_RELOAD_P99_NS=${reload[2]-0}
GAMEPLAY_REPRESENTATIVE_SCENE_RELOAD_ALLOCATIONS=${reload[3]-0}
GAMEPLAY_REPRESENTATIVE_BENCHMARK=$benchmark
GAMEPLAY_REPRESENTATIVE_BENCHMARK_SHA256=$benchmark_sha
GAMEPLAY_REPRESENTATIVE_BUILD_STDOUT=$build_stdout
GAMEPLAY_REPRESENTATIVE_BUILD_STDOUT_SHA256=$(sha256sum "$build_stdout" | awk '{print $1}')
GAMEPLAY_REPRESENTATIVE_BUILD_STDERR=$build_stderr
GAMEPLAY_REPRESENTATIVE_BUILD_STDERR_SHA256=$(sha256sum "$build_stderr" | awk '{print $1}')
GAMEPLAY_REPRESENTATIVE_STDOUT=$raw_stdout
GAMEPLAY_REPRESENTATIVE_STDOUT_SHA256=$(sha256sum "$raw_stdout" | awk '{print $1}')
GAMEPLAY_REPRESENTATIVE_STDERR=$raw_stderr
GAMEPLAY_REPRESENTATIVE_STDERR_SHA256=$(sha256sum "$raw_stderr" | awk '{print $1}')
GAMEPLAY_REPRESENTATIVE_TIME=$time_file
GAMEPLAY_REPRESENTATIVE_TIME_SHA256=$(sha256sum "$time_file" | awk '{print $1}')
GAMEPLAY_TOOL_ZIG_VERSION=$(zig version)
GAMEPLAY_TOOL_GNU_TIME_VERSION=$(/usr/bin/time --version 2>&1 | head -n 1)
GAMEPLAY_TOOL_HOST=$(uname -a)
EOF
{
    cat "$payload"
    printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' "$payload" "$(sha256sum "$payload" | awk '{print $1}')"
} >"$report"

printf 'GAMEPLAY_REPRESENTATIVE_STATUS=%s\n' "$status"
printf 'GAMEPLAY_REPRESENTATIVE_REPORT=%s\n' "$report"
if [[ "$status" == PASS ]]; then
    printf 'REPRESENTATIVE_WORKLOAD_PASS\n'
else
    printf 'REPRESENTATIVE_WORKLOAD_BLOCKED\n'
    exit 2
fi
