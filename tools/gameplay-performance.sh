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
candidate_build_stdout="$evidence_root/candidate-build.stdout"
candidate_build_stderr="$evidence_root/candidate-build.stderr"
oracle_build_stdout="$evidence_root/oracle-build.stdout"
oracle_build_stderr="$evidence_root/oracle-build.stderr"
(cd "$repository_root" && zig build emit-runtime-core-gameplay-bench --prefix "$candidate_prefix" \
    -Doptimize=ReleaseFast -Dgameplay-quality-evidence=true -Dgameplay-quality-emit-dir=gameplay-evidence \
    --summary all >"$candidate_build_stdout" 2>"$candidate_build_stderr")
(cd "$repository_root" && zig build-exe -OReleaseFast -lc -I abi -femit-bin="$oracle_prefix/runtime-gameplay-oracle-bench" \
    "$oracle_source" >"$oracle_build_stdout" 2>"$oracle_build_stderr")
candidate_benchmark="$candidate_prefix/gameplay-evidence/runtime-core-gameplay-bench"
oracle_benchmark="$oracle_prefix/runtime-gameplay-oracle-bench"
[[ -x "$candidate_benchmark" && -x "$oracle_benchmark" ]] || block 'benchmark binary missing'

metric() {
    local key=$1 stdout=$2 stderr=$3
    sed -n "s/.*${key}=\([0-9][0-9]*\).*/\1/p" "$stdout" "$stderr" | tail -n 1
}
rss() { sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$1" | tail -n 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
candidate_samples="$evidence_root/candidate-p95.samples"
oracle_samples="$evidence_root/oracle-p95.samples"
: >"$candidate_samples"; : >"$oracle_samples"
candidate_rss=0; oracle_rss=0; candidate_allocations=0
manifest="$evidence_root/performance-manifest.tsv"
command_manifest="$evidence_root/performance-commands.tsv"
printf 'run\tcandidate_stdout\tcandidate_stdout_sha256\tcandidate_stderr\tcandidate_stderr_sha256\tcandidate_time\tcandidate_time_sha256\toracle_stdout\toracle_stdout_sha256\toracle_stderr\toracle_stderr_sha256\toracle_time\toracle_time_sha256\n' >"$manifest"
printf 'kind\trun\tcommand\n' >"$command_manifest"
printf 'candidate_build\t0\tzig build emit-runtime-core-gameplay-bench --prefix %q -Doptimize=ReleaseFast -Dgameplay-quality-evidence=true -Dgameplay-quality-emit-dir=gameplay-evidence --summary all >%q 2>%q\n' \
    "$candidate_prefix" "$candidate_build_stdout" "$candidate_build_stderr" >>"$command_manifest"
printf 'oracle_build\t0\tzig build-exe -OReleaseFast -lc -I abi -femit-bin=%q %q >%q 2>%q\n' \
    "$oracle_benchmark" "$oracle_source" "$oracle_build_stdout" "$oracle_build_stderr" >>"$command_manifest"
for run in 1 2 3 4 5; do
    candidate_stdout="$evidence_root/candidate-run-$run.stdout"; candidate_stderr="$evidence_root/candidate-run-$run.stderr"
    oracle_stdout="$evidence_root/oracle-run-$run.stdout"; oracle_stderr="$evidence_root/oracle-run-$run.stderr"
    candidate_time="$evidence_root/candidate-time-$run.txt"; oracle_time="$evidence_root/oracle-time-$run.txt"
    printf 'candidate_run\t%s\t/usr/bin/time -v -o %q %q >%q 2>%q\n' "$run" \
        "$candidate_time" "$candidate_benchmark" "$candidate_stdout" "$candidate_stderr" >>"$command_manifest"
    printf 'oracle_run\t%s\t/usr/bin/time -v -o %q %q >%q 2>%q\n' "$run" \
        "$oracle_time" "$oracle_benchmark" "$oracle_stdout" "$oracle_stderr" >>"$command_manifest"
    /usr/bin/time -v -o "$candidate_time" "$candidate_benchmark" >"$candidate_stdout" 2>"$candidate_stderr"
    /usr/bin/time -v -o "$oracle_time" "$oracle_benchmark" >"$oracle_stdout" 2>"$oracle_stderr"
    cp95=$(metric p95_ns "$candidate_stdout" "$candidate_stderr"); op95=$(metric p95_ns "$oracle_stdout" "$oracle_stderr")
    [[ "$cp95" =~ ^[0-9]+$ && "$op95" =~ ^[0-9]+$ ]] || block "benchmark output missing on run $run"
    printf '%s\n' "$cp95" >>"$candidate_samples"; printf '%s\n' "$op95" >>"$oracle_samples"
    crss=$(rss "$candidate_time"); orss=$(rss "$oracle_time")
    ((crss > candidate_rss)) && candidate_rss=$crss; ((orss > oracle_rss)) && oracle_rss=$orss
    allocations=$(metric allocations "$candidate_stdout" "$candidate_stderr"); ((allocations > candidate_allocations)) && candidate_allocations=$allocations
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$run" "$candidate_stdout" "$(hash "$candidate_stdout")" "$candidate_stderr" "$(hash "$candidate_stderr")" \
        "$candidate_time" "$(hash "$candidate_time")" "$oracle_stdout" "$(hash "$oracle_stdout")" \
        "$oracle_stderr" "$(hash "$oracle_stderr")" "$oracle_time" "$(hash "$oracle_time")" >>"$manifest"
done
candidate_p95=$(sort -n "$candidate_samples" | sed -n '3p'); oracle_p95=$(sort -n "$oracle_samples" | sed -n '3p')
p95_ratio=$(awk -v c="$candidate_p95" -v o="$oracle_p95" 'BEGIN { printf "%.6f", c/o }')
rss_ratio=$(awk -v c="$candidate_rss" -v o="$oracle_rss" 'BEGIN { printf "%.6f", c/o }')
status=PASS
(( candidate_p95 * 100 <= oracle_p95 * 125 )) || status=FAIL
(( candidate_rss * 100 <= oracle_rss * 125 )) || status=FAIL
[[ "$candidate_allocations" == 0 ]] || status=FAIL
zig_version=$(zig version)
time_version=$(/usr/bin/time --version 2>&1 | sed -n '1p')
host_version=$(uname -srvmo)
candidate_payload="$evidence_root/candidate.payload"
candidate_report="$evidence_root/candidate.report"
cat >"$candidate_payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=5 paired ReleaseFast runs under GNU time -v; exact commands and raw files are SHA-bound below
GAMEPLAY_TOOL_ZIG_VERSION=$zig_version
GAMEPLAY_TOOL_GNU_TIME_VERSION=$time_version
GAMEPLAY_TOOL_HOST=$host_version
GAMEPLAY_CANDIDATE_BENCHMARK=$candidate_benchmark
GAMEPLAY_CANDIDATE_BENCHMARK_SHA256=$(hash "$candidate_benchmark")
GAMEPLAY_CANDIDATE_BUILD_STDOUT=$candidate_build_stdout
GAMEPLAY_CANDIDATE_BUILD_STDOUT_SHA256=$(hash "$candidate_build_stdout")
GAMEPLAY_CANDIDATE_BUILD_STDERR=$candidate_build_stderr
GAMEPLAY_CANDIDATE_BUILD_STDERR_SHA256=$(hash "$candidate_build_stderr")
GAMEPLAY_CANDIDATE_ITERATIONS=10000
GAMEPLAY_CANDIDATE_ACTIVE_OBJECTS=128
GAMEPLAY_CANDIDATE_DIRECTED_EVENTS=64
GAMEPLAY_CANDIDATE_RENDER_ITEMS=128
GAMEPLAY_CANDIDATE_P95_NS=$candidate_p95
GAMEPLAY_CANDIDATE_PEAK_RSS_KB=$candidate_rss
GAMEPLAY_CANDIDATE_ALLOCATIONS=$candidate_allocations
GAMEPLAY_CANDIDATE_P95_SAMPLES=$candidate_samples
GAMEPLAY_CANDIDATE_P95_SAMPLES_SHA256=$(hash "$candidate_samples")
GAMEPLAY_CANDIDATE_ORACLE_SOURCE=$oracle_source
GAMEPLAY_CANDIDATE_ORACLE_SOURCE_SHA256=$oracle_source_sha
GAMEPLAY_PERF_MANIFEST=$manifest
GAMEPLAY_PERF_MANIFEST_SHA256=$(hash "$manifest")
GAMEPLAY_PERF_COMMAND_MANIFEST=$command_manifest
GAMEPLAY_PERF_COMMAND_MANIFEST_SHA256=$(hash "$command_manifest")
GAMEPLAY_ORACLE_SHA=f114d755a927acd202872bb3468a1d9e7b87decb
GAMEPLAY_ORACLE_P95_NS=$oracle_p95
GAMEPLAY_ORACLE_PEAK_RSS_KB=$oracle_rss
GAMEPLAY_ORACLE_BENCHMARK=$oracle_benchmark
GAMEPLAY_ORACLE_BENCHMARK_SHA256=$(hash "$oracle_benchmark")
GAMEPLAY_ORACLE_ITERATIONS=10000
GAMEPLAY_ORACLE_ACTIVE_OBJECTS=128
GAMEPLAY_ORACLE_DIRECTED_EVENTS=64
GAMEPLAY_ORACLE_RENDER_ITEMS=128
GAMEPLAY_PERF_P95_RATIO=$p95_ratio
GAMEPLAY_PERF_RSS_RATIO=$rss_ratio
GAMEPLAY_PERF_STATUS=$status
EOF
cat "$candidate_payload" >"$candidate_report"
printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' \
    "$candidate_payload" "$(hash "$candidate_payload")" >>"$candidate_report"

oracle_payload="$evidence_root/oracle.payload"
oracle_report="$evidence_root/oracle.report"
cat >"$oracle_payload" <<EOF
GAMEPLAY_ORACLE_SHA=f114d755a927acd202872bb3468a1d9e7b87decb
GAMEPLAY_COMMAND=5 paired ReleaseFast runs under GNU time -v; exact commands and raw files are SHA-bound below
GAMEPLAY_TOOL_ZIG_VERSION=$zig_version
GAMEPLAY_TOOL_GNU_TIME_VERSION=$time_version
GAMEPLAY_TOOL_HOST=$host_version
GAMEPLAY_ORACLE_BENCHMARK=$oracle_benchmark
GAMEPLAY_ORACLE_BENCHMARK_SHA256=$(hash "$oracle_benchmark")
GAMEPLAY_ORACLE_BUILD_STDOUT=$oracle_build_stdout
GAMEPLAY_ORACLE_BUILD_STDOUT_SHA256=$(hash "$oracle_build_stdout")
GAMEPLAY_ORACLE_BUILD_STDERR=$oracle_build_stderr
GAMEPLAY_ORACLE_BUILD_STDERR_SHA256=$(hash "$oracle_build_stderr")
GAMEPLAY_ORACLE_ITERATIONS=10000
GAMEPLAY_ORACLE_ACTIVE_OBJECTS=128
GAMEPLAY_ORACLE_DIRECTED_EVENTS=64
GAMEPLAY_ORACLE_RENDER_ITEMS=128
GAMEPLAY_ORACLE_P95_NS=$oracle_p95
GAMEPLAY_ORACLE_PEAK_RSS_KB=$oracle_rss
GAMEPLAY_ORACLE_P95_SAMPLES=$oracle_samples
GAMEPLAY_ORACLE_P95_SAMPLES_SHA256=$(hash "$oracle_samples")
GAMEPLAY_PERF_MANIFEST=$manifest
GAMEPLAY_PERF_MANIFEST_SHA256=$(hash "$manifest")
GAMEPLAY_PERF_COMMAND_MANIFEST=$command_manifest
GAMEPLAY_PERF_COMMAND_MANIFEST_SHA256=$(hash "$command_manifest")
EOF
cat "$oracle_payload" >"$oracle_report"
printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' \
    "$oracle_payload" "$(hash "$oracle_payload")" >>"$oracle_report"

cat "$candidate_report"
[[ "$status" == PASS ]]
