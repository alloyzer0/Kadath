#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' "Usage: phase-performance.sh --candidate-sha SHA --evidence-root PATH"
}

candidate_sha=""
evidence_root=""
while (($# > 0)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
candidate_sha="$(git -C "$repository_root" rev-parse --verify "${candidate_sha}^{commit}")"
[[ "$candidate_sha" == "$(git -C "$repository_root" rev-parse HEAD)" ]] || {
    printf '%s\n' "candidate SHA is not current HEAD" >&2
    exit 1
}
[[ -n "$evidence_root" ]] || { usage >&2; exit 1; }
mkdir -p "$evidence_root"
evidence_root="$(cd -- "$evidence_root" && pwd)"

oracle_sha="$(git -C "$repository_root" rev-parse bfc5504^{commit})"
oracle_worktree="$evidence_root/oracle"
git -C "$repository_root" worktree add --detach "$oracle_worktree" "$oracle_sha" >/dev/null
cleanup() {
    git -C "$repository_root" worktree remove --force "$oracle_worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT
[[ -z "$(git -C "$oracle_worktree" status --short)" ]] || exit 1

oracle_source="$oracle_worktree/tools/runtime-phase-zig-oracle-bench.zig"
cp -- "$repository_root/tools/runtime-phase-zig-oracle-bench.zig" "$oracle_source"
oracle_source_sha="$(sha256sum "$oracle_source" | awk '{print $1}')"
oracle_authority_sha="$(git -C "$oracle_worktree" show "$oracle_sha:app/behavior_host.zig" | sha256sum | awk '{print $1}')"
oracle_source_match=false
extract_block() {
    local source=$1
    local begin=$2
    local end=$3
    awk -v begin="$begin" -v end="$end" '
        index($0, begin) { inside = 1; next }
        index($0, end) { inside = 0; exit }
        inside { print }
    ' "$source"
}
authority_source="$evidence_root/oracle-authority.zig"
git -C "$oracle_worktree" show "$oracle_sha:app/behavior_host.zig" >"$authority_source"
authority_event="$evidence_root/authority-event.zig"
benchmark_event="$evidence_root/benchmark-event.zig"
authority_structural="$evidence_root/authority-structural.zig"
benchmark_structural="$evidence_root/benchmark-structural.zig"
sed -n '18,90p' "$authority_source" >"$authority_event"
extract_block "$oracle_source" \
    'BEGIN FROZEN bfc5504 app/behavior_host.zig EVENT AUTHORITY' \
    'END FROZEN bfc5504 app/behavior_host.zig EVENT AUTHORITY' >"$benchmark_event"
sed -n '92,153p' "$authority_source" >"$authority_structural"
extract_block "$oracle_source" \
    'BEGIN FROZEN bfc5504 app/behavior_host.zig STRUCTURAL AUTHORITY' \
    'END FROZEN bfc5504 app/behavior_host.zig STRUCTURAL AUTHORITY' >"$benchmark_structural"
if cmp -s "$authority_event" "$benchmark_event" &&
    cmp -s "$authority_structural" "$benchmark_structural"; then
    oracle_source_match=true
fi
[[ "$oracle_source_match" == true ]] || {
    printf '%s\n' 'oracle benchmark authority blocks do not match bfc5504' >&2
    exit 1
}
oracle_benchmark="$evidence_root/runtime-phase-zig-oracle-bench"
zig build-exe -OReleaseSafe \
    -lc \
    --dep behavior_runtime --dep scene.zig --dep runtime_object_registry.zig \
    -Mroot="$oracle_source" \
    --dep behavior_artifact --dep behavior_common \
    -Mbehavior_runtime="$oracle_worktree/modules/behavior_script/src/runtime.zig" \
    --dep behavior_common \
    -Mbehavior_artifact="$oracle_worktree/modules/behavior_script/src/artifact.zig" \
    -Mbehavior_common="$oracle_worktree/modules/behavior_script/src/common.zig" \
    --dep content_identity.zig \
    -Mscene.zig="$oracle_worktree/app/scene.zig" \
    -Mcontent_identity.zig="$oracle_worktree/app/content_identity.zig" \
    --dep scene.zig \
    -Mruntime_object_registry.zig="$oracle_worktree/app/runtime_object_registry.zig" \
    -I "$oracle_worktree/abi" \
    -I "$oracle_worktree/modules/behavior_script/native" \
    -femit-bin="$oracle_benchmark"

candidate_build_log="$evidence_root/candidate-build.log"
(
cd -- "$repository_root"
zig build bench-runtime-core-phase \
    -Doptimize=ReleaseSafe -Dphase-quality-evidence=true --summary all \
    >"$candidate_build_log" 2>&1
)
candidate_benchmark="$(find "$repository_root/.zig-cache/o" -maxdepth 2 -type f -name runtime-core-phase-bench -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
[[ -x "$candidate_benchmark" ]] || exit 1
candidate_benchmark_sha="$(sha256sum "$candidate_benchmark" | awk '{print $1}')"
oracle_benchmark_sha="$(sha256sum "$oracle_benchmark" | awk '{print $1}')"

metric() {
    local path=$1
    local key=$2
    sed -n "s/.*${key}=\([0-9][0-9]*\).*/\1/p" "$path"
}
rss() {
    sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$1"
}
candidate_worst_samples="$evidence_root/candidate-worst-p95.samples"
oracle_worst_samples="$evidence_root/oracle-worst-p95.samples"
: >"$candidate_worst_samples"
: >"$oracle_worst_samples"
candidate_rss=0
oracle_rss=0
candidate_allocations=0
performance_manifest="$evidence_root/performance-manifest.tsv"
printf 'run\tcandidate_log_sha256\toracle_log_sha256\tcandidate_time_sha256\toracle_time_sha256\n' >"$performance_manifest"
for run in 1 2 3 4 5; do
    candidate_run_log="$evidence_root/candidate-run-$run.log"
    oracle_run_log="$evidence_root/oracle-run-$run.log"
    candidate_time="$evidence_root/candidate-time-$run.txt"
    oracle_time="$evidence_root/oracle-time-$run.txt"
    /usr/bin/time -v -o "$candidate_time" "$candidate_benchmark" 2>"$candidate_run_log"
    /usr/bin/time -v -o "$oracle_time" "$oracle_benchmark" 2>"$oracle_run_log"
    candidate_fixed_p95="$(metric "$candidate_run_log" fixed_p95_ns)"
    candidate_frame_p95="$(metric "$candidate_run_log" frame_p95_ns)"
    oracle_fixed_p95="$(metric "$oracle_run_log" fixed_p95_ns)"
    oracle_frame_p95="$(metric "$oracle_run_log" frame_p95_ns)"
    printf '%s\n' "$(( candidate_fixed_p95 > candidate_frame_p95 ? candidate_fixed_p95 : candidate_frame_p95 ))" >>"$candidate_worst_samples"
    printf '%s\n' "$(( oracle_fixed_p95 > oracle_frame_p95 ? oracle_fixed_p95 : oracle_frame_p95 ))" >>"$oracle_worst_samples"
    run_candidate_rss="$(rss "$candidate_time")"
    run_oracle_rss="$(rss "$oracle_time")"
    ((run_candidate_rss > candidate_rss)) && candidate_rss=$run_candidate_rss
    ((run_oracle_rss > oracle_rss)) && oracle_rss=$run_oracle_rss
    run_allocations="$(( $(metric "$candidate_run_log" fixed_allocations) + $(metric "$candidate_run_log" frame_allocations) ))"
    ((run_allocations > candidate_allocations)) && candidate_allocations=$run_allocations
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$run" \
        "$(sha256sum "$candidate_run_log" | awk '{print $1}')" \
        "$(sha256sum "$oracle_run_log" | awk '{print $1}')" \
        "$(sha256sum "$candidate_time" | awk '{print $1}')" \
        "$(sha256sum "$oracle_time" | awk '{print $1}')" >>"$performance_manifest"
done

candidate_worst_p95="$(sort -n "$candidate_worst_samples" | sed -n '3p')"
oracle_worst_p95="$(sort -n "$oracle_worst_samples" | sed -n '3p')"
p95_ratio="$(awk -v candidate="$candidate_worst_p95" -v oracle="$oracle_worst_p95" 'BEGIN { printf "%.6f", candidate / oracle }')"
overhead_per_item="$(awk -v candidate="$candidate_worst_p95" -v oracle="$oracle_worst_p95" 'BEGIN { overhead = candidate > oracle ? candidate - oracle : 0; printf "%.6f", overhead / 64 }')"
rss_ratio="$(awk -v candidate="$candidate_rss" -v oracle="$oracle_rss" 'BEGIN { printf "%.6f", candidate / oracle }')"
performance_manifest_sha="$(sha256sum "$performance_manifest" | awk '{print $1}')"

oracle_clean=false
git -C "$oracle_worktree" diff --quiet -- . ':(exclude)tools/runtime-phase-zig-oracle-bench.zig' && \
    [[ -z "$(git -C "$oracle_worktree" status --short --untracked-files=no)" ]] && oracle_clean=true

status=PASS
awk -v value="$candidate_worst_p95" 'BEGIN { exit !(value <= 100000) }' || status=FAIL
awk -v value="$overhead_per_item" 'BEGIN { exit !(value <= 512) }' || status=FAIL
awk -v value="$rss_ratio" 'BEGIN { exit !(value <= 1.25) }' || status=FAIL
[[ "$candidate_allocations" -eq 0 && "$oracle_clean" == true ]] || status=FAIL

oracle_report="$evidence_root/oracle.report"
performance_report="$evidence_root/performance.report"
cat >"$oracle_report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_ORACLE_SHA=$oracle_sha
PHASE3_COMMAND=zig build-exe -OReleaseSafe tools/runtime-phase-zig-oracle-bench.zig
PHASE3_ORACLE_STATUS=$status
PHASE3_ORACLE_WORKTREE_CLEAN=$oracle_clean
PHASE3_ORACLE_SOURCE_MATCH=$oracle_source_match
PHASE3_ORACLE_SOURCE_SHA256=$oracle_source_sha
PHASE3_ORACLE_AUTHORITY_SHA256=$oracle_authority_sha
PHASE3_ORACLE_BENCHMARK=$oracle_benchmark
PHASE3_ORACLE_BENCHMARK_SHA256=$oracle_benchmark_sha
PHASE3_ORACLE_FIXED_P95_NS=$oracle_fixed_p95
PHASE3_ORACLE_FRAME_P95_NS=$oracle_frame_p95
PHASE3_ORACLE_WORST_P95_MEDIAN_NS=$oracle_worst_p95
PHASE3_ORACLE_P95_SAMPLES=$oracle_worst_samples
EOF
cat >"$performance_report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_COMMAND=zig build bench-runtime-core-phase -Doptimize=ReleaseSafe -Dphase-quality-evidence=true
PHASE3_PERF_STATUS=$status
PHASE3_CANDIDATE_BENCHMARK=$candidate_benchmark
PHASE3_CANDIDATE_BENCHMARK_SHA256=$candidate_benchmark_sha
PHASE3_CANDIDATE_FIXED_P95_NS=$candidate_fixed_p95
PHASE3_CANDIDATE_FRAME_P95_NS=$candidate_frame_p95
PHASE3_CANDIDATE_WORST_P95_MEDIAN_NS=$candidate_worst_p95
PHASE3_CANDIDATE_P95_SAMPLES=$candidate_worst_samples
PHASE3_PERF_P95_RATIO=$p95_ratio
PHASE3_PERF_OVERHEAD_NS_PER_ITEM=$overhead_per_item
PHASE3_PERF_PAIRED_RUNS=5
PHASE3_PERF_MANIFEST=$performance_manifest
PHASE3_PERF_MANIFEST_SHA256=$performance_manifest_sha
PHASE3_CANDIDATE_RSS_KB=$candidate_rss
PHASE3_ORACLE_RSS_KB=$oracle_rss
PHASE3_PERF_RSS_RATIO=$rss_ratio
PHASE3_STEADY_STATE_ALLOCATION_DELTA=$candidate_allocations
EOF

printf 'PHASE3_PERFORMANCE_REPORT=%s\n' "$performance_report"
printf 'PHASE3_ORACLE_REPORT=%s\n' "$oracle_report"
printf 'PHASE3_CANDIDATE_BENCHMARK=%s\n' "$candidate_benchmark"
printf 'PHASE3_ORACLE_WORKTREE=%s\n' "$oracle_worktree"
printf 'PHASE3_ORACLE_BENCHMARK=%s\n' "$oracle_benchmark"
printf 'PHASE3_PERFORMANCE_STATUS=%s\n' "$status"
[[ "$status" == PASS ]]
trap - EXIT
