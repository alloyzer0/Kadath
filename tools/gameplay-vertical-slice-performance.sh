#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' "Usage: gameplay-vertical-slice-performance.sh --candidate-sha SHA --evidence-root PATH [--max-p95-ns N] [--max-p99-ns N]"
}

candidate_sha=""
evidence_root=""
max_p95_ns=50000000
max_p99_ns=100000000
while (($#)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        --max-p95-ns) max_p95_ns=${2-}; shift 2 ;;
        --max-p99-ns) max_p99_ns=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
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
[[ -n "$evidence_root" && "$max_p95_ns" =~ ^[1-9][0-9]*$ && "$max_p99_ns" =~ ^[1-9][0-9]*$ ]] || {
    usage >&2
    exit 1
}
mkdir -p "$evidence_root"
evidence_root="$(cd -- "$evidence_root" && pwd)"

emit_prefix="$evidence_root/emit"
build_stdout="$evidence_root/build.stdout"
build_stderr="$evidence_root/build.stderr"
(
    cd -- "$repository_root"
    zig build emit-gameplay-vertical-slice-bench \
        --prefix "$emit_prefix" -Doptimize=ReleaseSafe -Dgameplay-quality-evidence=true \
        -Dgameplay-quality-emit-dir=gameplay-evidence --summary all
) >"$build_stdout" 2>"$build_stderr"

artifact_root="$emit_prefix/gameplay-evidence"
benchmark="$artifact_root/gameplay-vertical-slice-bench"
script_artifact="$artifact_root/vertical-slice.script"
initial_scene="$artifact_root/vertical-slice-initial.scene.json"
reload_scene="$artifact_root/vertical-slice-reload.scene.json"
[[ -x "$benchmark" && -f "$script_artifact" && -f "$initial_scene" && -f "$reload_scene" ]] || {
    printf '%s\n' "Vertical Slice benchmark or fixture was not emitted" >&2
    exit 1
}

raw_stdout="$evidence_root/vertical-slice.stdout"
raw_stderr="$evidence_root/vertical-slice.stderr"
time_file="$evidence_root/vertical-slice.time"
set +e
/usr/bin/time -v -o "$time_file" \
    "$benchmark" "$script_artifact" "$initial_scene" "$reload_scene" \
    >"$raw_stdout" 2>"$raw_stderr"
run_status=$?
set -e

metric_line=$(sed -n '/^vertical_slice_samples=/p' "$raw_stdout" "$raw_stderr" | tail -n 1)
contract_line=$(sed -n '/^vertical_slice_contract /p' "$raw_stdout" "$raw_stderr" | tail -n 1)
samples=$(sed -n 's/.*vertical_slice_samples=\([0-9][0-9]*\).*/\1/p' <<<"$metric_line")
p50_ns=$(sed -n 's/.*p50_ns=\([0-9][0-9]*\).*/\1/p' <<<"$metric_line")
p95_ns=$(sed -n 's/.*p95_ns=\([0-9][0-9]*\).*/\1/p' <<<"$metric_line")
p99_ns=$(sed -n 's/.*p99_ns=\([0-9][0-9]*\).*/\1/p' <<<"$metric_line")
allocations_total=$(sed -n 's/.*rust_allocations_total=\([0-9][0-9]*\).*/\1/p' <<<"$metric_line")
allocations_max=$(sed -n 's/.*rust_allocations_max=\([0-9][0-9]*\).*/\1/p' <<<"$metric_line")
digest=$(sed -n 's/.*digest=\([0-9a-f][0-9a-f]*\).*/\1/p' <<<"$metric_line")
peak_rss_kb=$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$time_file" | tail -n 1)

status=PASS
[[ "$run_status" == 0 && "$contract_line" == *"status=PASS"* ]] || status=BLOCKED
[[ "$samples" == 64 ]] || status=BLOCKED
for value in "$p50_ns" "$p95_ns" "$p99_ns" "$allocations_total" "$allocations_max" "$peak_rss_kb"; do
    [[ "$value" =~ ^[0-9]+$ ]] || status=BLOCKED
done
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || status=BLOCKED
if [[ "$p50_ns" =~ ^[0-9]+$ && "$p95_ns" =~ ^[0-9]+$ && "$p99_ns" =~ ^[0-9]+$ ]]; then
    (( p50_ns <= p95_ns && p95_ns <= p99_ns )) || status=BLOCKED
    (( p95_ns <= max_p95_ns && p99_ns <= max_p99_ns )) || status=BLOCKED
fi

hash() { sha256sum "$1" | awk '{print $1}'; }
payload="$evidence_root/vertical-slice.payload"
report="$evidence_root/vertical-slice.report"
cat >"$payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=gameplay-vertical-slice-performance.sh --candidate-sha $candidate_sha --evidence-root $evidence_root --max-p95-ns $max_p95_ns --max-p99-ns $max_p99_ns
GAMEPLAY_VERTICAL_SLICE_STATUS=$status
GAMEPLAY_VERTICAL_SLICE_SAMPLES=${samples:-0}
GAMEPLAY_VERTICAL_SLICE_OBJECTS=5
GAMEPLAY_VERTICAL_SLICE_FIXED_STEPS=7
GAMEPLAY_VERTICAL_SLICE_OUTCOMES=3
GAMEPLAY_VERTICAL_SLICE_P50_NS=${p50_ns:-0}
GAMEPLAY_VERTICAL_SLICE_P95_NS=${p95_ns:-0}
GAMEPLAY_VERTICAL_SLICE_P99_NS=${p99_ns:-0}
GAMEPLAY_VERTICAL_SLICE_MAX_P95_NS=$max_p95_ns
GAMEPLAY_VERTICAL_SLICE_MAX_P99_NS=$max_p99_ns
GAMEPLAY_VERTICAL_SLICE_RUST_ALLOCATIONS_TOTAL=${allocations_total:-0}
GAMEPLAY_VERTICAL_SLICE_RUST_ALLOCATIONS_MAX=${allocations_max:-0}
GAMEPLAY_VERTICAL_SLICE_REPLAY_DIGEST=${digest:-missing}
GAMEPLAY_VERTICAL_SLICE_PEAK_RSS_KB=${peak_rss_kb:-0}
GAMEPLAY_VERTICAL_SLICE_RSS_POLICY=diagnostic_only
GAMEPLAY_VERTICAL_SLICE_BENCHMARK=$benchmark
GAMEPLAY_VERTICAL_SLICE_BENCHMARK_SHA256=$(hash "$benchmark")
GAMEPLAY_VERTICAL_SLICE_SCRIPT_ARTIFACT=$script_artifact
GAMEPLAY_VERTICAL_SLICE_SCRIPT_ARTIFACT_SHA256=$(hash "$script_artifact")
GAMEPLAY_VERTICAL_SLICE_INITIAL_SCENE=$initial_scene
GAMEPLAY_VERTICAL_SLICE_INITIAL_SCENE_SHA256=$(hash "$initial_scene")
GAMEPLAY_VERTICAL_SLICE_RELOAD_SCENE=$reload_scene
GAMEPLAY_VERTICAL_SLICE_RELOAD_SCENE_SHA256=$(hash "$reload_scene")
GAMEPLAY_VERTICAL_SLICE_BUILD_STDOUT=$build_stdout
GAMEPLAY_VERTICAL_SLICE_BUILD_STDOUT_SHA256=$(hash "$build_stdout")
GAMEPLAY_VERTICAL_SLICE_BUILD_STDERR=$build_stderr
GAMEPLAY_VERTICAL_SLICE_BUILD_STDERR_SHA256=$(hash "$build_stderr")
GAMEPLAY_VERTICAL_SLICE_STDOUT=$raw_stdout
GAMEPLAY_VERTICAL_SLICE_STDOUT_SHA256=$(hash "$raw_stdout")
GAMEPLAY_VERTICAL_SLICE_STDERR=$raw_stderr
GAMEPLAY_VERTICAL_SLICE_STDERR_SHA256=$(hash "$raw_stderr")
GAMEPLAY_VERTICAL_SLICE_TIME=$time_file
GAMEPLAY_VERTICAL_SLICE_TIME_SHA256=$(hash "$time_file")
GAMEPLAY_TOOL_ZIG_VERSION=$(zig version)
GAMEPLAY_TOOL_GNU_TIME_VERSION=$(/usr/bin/time --version 2>&1 | head -n 1)
GAMEPLAY_TOOL_HOST=$(uname -a)
EOF
{
    cat "$payload"
    printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' "$payload" "$(hash "$payload")"
} >"$report"

printf 'GAMEPLAY_VERTICAL_SLICE_STATUS=%s\n' "$status"
printf 'GAMEPLAY_VERTICAL_SLICE_REPORT=%s\n' "$report"
printf 'GAMEPLAY_VERTICAL_SLICE_RSS_DIAGNOSTIC_KB=%s\n' "${peak_rss_kb:-0}"
if [[ "$status" == PASS ]]; then
    printf 'VERTICAL_SLICE_WORKLOAD_PASS\n'
else
    printf 'VERTICAL_SLICE_WORKLOAD_BLOCKED\n'
    exit 2
fi
