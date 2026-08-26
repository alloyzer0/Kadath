#!/usr/bin/env bash
set -euo pipefail

usage() { printf '%s\n' 'Usage: gameplay-performance.sh --candidate-sha SHA --evidence-root PATH'; }
candidate_sha= evidence_root=
while (($#)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

block() { printf 'GAMEPLAY_PERFORMANCE_STATUS=BLOCKED_ENV\nGAMEPLAY_PERFORMANCE_BLOCKER=%s\n' "$1"; exit 2; }
[[ "$(uname -s 2>/dev/null || true)" == Linux ]] || block 'Linux performance host unavailable'
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || block 'full candidate SHA required'
[[ -n "$evidence_root" && ! -e "$evidence_root" ]] || block 'unique absent evidence root required'
command -v zig >/dev/null 2>&1 || block 'zig unavailable'
command -v sha256sum >/dev/null 2>&1 || block 'sha256sum unavailable'
command -v /usr/bin/time >/dev/null 2>&1 || block 'GNU time unavailable'
repository_root=$(git rev-parse --show-toplevel)
[[ "$(git -C "$repository_root" rev-parse HEAD)" == "$candidate_sha" ]] || block 'checkout does not match candidate SHA'
mkdir -p "$evidence_root"
evidence_root=$(cd "$evidence_root" && pwd)

# Oracle 源文件自 Gameplay 首个实现提交后保持不变；脚本从 Git 对象读取，避免被候选工作树循环污染。
oracle_source="$evidence_root/runtime-gameplay-oracle-bench.zig"
git -C "$repository_root" show 8c98fe2:tools/runtime-gameplay-oracle-bench.zig >"$oracle_source" || block 'frozen oracle source missing'
grep -Fq 'frozen_oracle_sha = "f114d755a927acd202872bb3468a1d9e7b87decb"' "$oracle_source" || block 'oracle source identity marker missing'
oracle_source_sha=$(sha256sum "$oracle_source" | awk '{print $1}')

candidate_prefix="$evidence_root/candidate"
oracle_prefix="$evidence_root/oracle"
mkdir -p "$candidate_prefix" "$oracle_prefix"
(cd "$repository_root" && zig build emit-runtime-core-gameplay-bench --prefix "$candidate_prefix" \
    -Doptimize=ReleaseFast -Dgameplay-quality-evidence=true -Dgameplay-quality-emit-dir=gameplay-evidence \
    --summary all >"$evidence_root/candidate-build.log" 2>&1)
(cd "$repository_root" && zig build-exe -OReleaseFast -lc -I abi -femit-bin="$oracle_prefix/runtime-gameplay-oracle-bench" \
    "$oracle_source" >"$evidence_root/oracle-build.log" 2>&1)
candidate_benchmark="$candidate_prefix/gameplay-evidence/runtime-core-gameplay-bench"
oracle_benchmark="$oracle_prefix/runtime-gameplay-oracle-bench"
[[ -x "$candidate_benchmark" && -x "$oracle_benchmark" ]] || block 'benchmark binary missing'

metric() { sed -n "s/.*$2=\([0-9][0-9]*\).*/\1/p" "$1" | tail -n 1; }
rss() { sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$1" | tail -n 1; }
candidate_samples="$evidence_root/candidate-p95.samples"
oracle_samples="$evidence_root/oracle-p95.samples"
: >"$candidate_samples"; : >"$oracle_samples"
candidate_rss=0; oracle_rss=0; candidate_allocations=0
manifest="$evidence_root/performance-manifest.tsv"
printf 'run\tcandidate_log_sha256\toracle_log_sha256\tcandidate_time_sha256\toracle_time_sha256\n' >"$manifest"
for run in 1 2 3 4 5; do
    candidate_log="$evidence_root/candidate-run-$run.log"; oracle_log="$evidence_root/oracle-run-$run.log"
    candidate_time="$evidence_root/candidate-time-$run.txt"; oracle_time="$evidence_root/oracle-time-$run.txt"
    /usr/bin/time -v -o "$candidate_time" "$candidate_benchmark" >"$candidate_log" 2>&1
    /usr/bin/time -v -o "$oracle_time" "$oracle_benchmark" >"$oracle_log" 2>&1
    cp95=$(metric "$candidate_log" p95_ns); op95=$(metric "$oracle_log" p95_ns)
    [[ "$cp95" =~ ^[0-9]+$ && "$op95" =~ ^[0-9]+$ ]] || block "benchmark output missing on run $run"
    printf '%s\n' "$cp95" >>"$candidate_samples"; printf '%s\n' "$op95" >>"$oracle_samples"
    crss=$(rss "$candidate_time"); orss=$(rss "$oracle_time")
    ((crss > candidate_rss)) && candidate_rss=$crss; ((orss > oracle_rss)) && oracle_rss=$orss
    allocations=$(metric "$candidate_log" allocations); ((allocations > candidate_allocations)) && candidate_allocations=$allocations
    printf '%s\t%s\t%s\t%s\t%s\n' "$run" "$(sha256sum "$candidate_log" | awk '{print $1}')" "$(sha256sum "$oracle_log" | awk '{print $1}')" "$(sha256sum "$candidate_time" | awk '{print $1}')" "$(sha256sum "$oracle_time" | awk '{print $1}')" >>"$manifest"
done
candidate_p95=$(sort -n "$candidate_samples" | sed -n '3p'); oracle_p95=$(sort -n "$oracle_samples" | sed -n '3p')
p95_ratio=$(awk -v c="$candidate_p95" -v o="$oracle_p95" 'BEGIN { printf "%.6f", c/o }')
rss_ratio=$(awk -v c="$candidate_rss" -v o="$oracle_rss" 'BEGIN { printf "%.6f", c/o }')
status=PASS
(( candidate_p95 * 100 <= oracle_p95 * 125 )) || status=FAIL
(( candidate_rss * 100 <= oracle_rss * 125 )) || status=FAIL
[[ "$candidate_allocations" == 0 ]] || status=FAIL
cat >"$evidence_root/candidate.report" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=5 paired ReleaseFast runs under GNU time -v with raw stdout/stderr and manifest
GAMEPLAY_CANDIDATE_BENCHMARK=$candidate_benchmark
GAMEPLAY_CANDIDATE_BENCHMARK_SHA256=$(sha256sum "$candidate_benchmark" | awk '{print $1}')
GAMEPLAY_CANDIDATE_ITERATIONS=10000
GAMEPLAY_CANDIDATE_ACTIVE_OBJECTS=128
GAMEPLAY_CANDIDATE_DIRECTED_EVENTS=64
GAMEPLAY_CANDIDATE_RENDER_ITEMS=128
GAMEPLAY_CANDIDATE_P95_NS=$candidate_p95
GAMEPLAY_CANDIDATE_PEAK_RSS_KB=$candidate_rss
GAMEPLAY_CANDIDATE_ALLOCATIONS=$candidate_allocations
GAMEPLAY_CANDIDATE_P95_SAMPLES=$candidate_samples
GAMEPLAY_CANDIDATE_ORACLE_SOURCE=$oracle_source
GAMEPLAY_CANDIDATE_ORACLE_SOURCE_SHA256=$oracle_source_sha
GAMEPLAY_PERF_MANIFEST=$manifest
GAMEPLAY_PERF_MANIFEST_SHA256=$(sha256sum "$manifest" | awk '{print $1}')
GAMEPLAY_ORACLE_SHA=f114d755a927acd202872bb3468a1d9e7b87decb
GAMEPLAY_ORACLE_P95_NS=$oracle_p95
GAMEPLAY_ORACLE_PEAK_RSS_KB=$oracle_rss
GAMEPLAY_ORACLE_BENCHMARK=$oracle_benchmark
GAMEPLAY_ORACLE_BENCHMARK_SHA256=$(sha256sum "$oracle_benchmark" | awk '{print $1}')
GAMEPLAY_ORACLE_ITERATIONS=10000
GAMEPLAY_ORACLE_ACTIVE_OBJECTS=128
GAMEPLAY_ORACLE_DIRECTED_EVENTS=64
GAMEPLAY_ORACLE_RENDER_ITEMS=128
GAMEPLAY_PERF_P95_RATIO=$p95_ratio
GAMEPLAY_PERF_RSS_RATIO=$rss_ratio
GAMEPLAY_PERF_STATUS=$status
EOF
cat >"$evidence_root/oracle.report" <<EOF
GAMEPLAY_ORACLE_SHA=f114d755a927acd202872bb3468a1d9e7b87decb
GAMEPLAY_COMMAND=5 paired ReleaseFast runs under GNU time -v with raw stdout/stderr and manifest
GAMEPLAY_ORACLE_BENCHMARK=$oracle_benchmark
GAMEPLAY_ORACLE_BENCHMARK_SHA256=$(sha256sum "$oracle_benchmark" | awk '{print $1}')
GAMEPLAY_ORACLE_ITERATIONS=10000
GAMEPLAY_ORACLE_ACTIVE_OBJECTS=128
GAMEPLAY_ORACLE_DIRECTED_EVENTS=64
GAMEPLAY_ORACLE_RENDER_ITEMS=128
GAMEPLAY_ORACLE_P95_NS=$oracle_p95
GAMEPLAY_ORACLE_PEAK_RSS_KB=$oracle_rss
GAMEPLAY_ORACLE_P95_SAMPLES=$oracle_samples
GAMEPLAY_PERF_MANIFEST=$manifest
GAMEPLAY_PERF_MANIFEST_SHA256=$(sha256sum "$manifest" | awk '{print $1}')
EOF
cat "$evidence_root/candidate.report"
[[ "$status" == PASS ]]
