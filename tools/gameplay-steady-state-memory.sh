#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' "Usage: gameplay-steady-state-memory.sh --candidate-sha SHA --candidate-benchmark PATH --evidence-root PATH"
}

candidate_sha=""
candidate_benchmark=""
evidence_root=""
while (($# > 0)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --candidate-benchmark) candidate_benchmark=${2-}; shift 2 ;;
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
[[ -x "$candidate_benchmark" && -n "$evidence_root" ]] || { usage >&2; exit 1; }
mkdir -p "$evidence_root"
evidence_root="$(cd -- "$evidence_root" && pwd)"

# 120 个 10,000-step 批次约覆盖 120 万次固定步，足以暴露线性泄漏，同时不把总 RSS 当绝对门槛。
steady_batches=120
raw_stdout="$evidence_root/steady-state.stdout"
raw_stderr="$evidence_root/steady-state.stderr"
time_file="$evidence_root/steady-state.time"
set +e
/usr/bin/time -v -o "$time_file" "$candidate_benchmark" --steady-batches "$steady_batches" >"$raw_stdout" 2>"$raw_stderr"
run_status=$?
set -e

metric() {
    local key=$1
    sed -n "s/.*${key}=\([0-9][0-9]*\).*/\1/p" "$raw_stdout" "$raw_stderr" | tail -n 1
}

sample_count="$(grep -c '^steady_sample=' "$raw_stderr" || true)"
warmup_iterations="$(sed -n 's/.*runtime_core_gameplay_steady_warmup iterations=\([0-9][0-9]*\).*/\1/p' "$raw_stdout" "$raw_stderr" | tail -n 1)"
warmup_allocations="$(sed -n 's/.*runtime_core_gameplay_steady_warmup.*allocations=\([0-9][0-9]*\).*/\1/p' "$raw_stdout" "$raw_stderr" | tail -n 1)"
first_rss="$(metric first_rss_kb)"
last_rss="$(metric last_rss_kb)"
peak_rss="$(metric peak_rss_kb)"
growth="$(metric growth_kb)"
peak_growth="$(metric peak_growth_kb)"
allocations="$(metric 'runtime_core_gameplay_steady_state.*allocations' || true)"
if [[ -z "$allocations" ]]; then allocations="$(sed -n 's/.*runtime_core_gameplay_steady_state.*allocations=\([0-9][0-9]*\).*/\1/p' "$raw_stderr" | tail -n 1)"; fi

status=PASS
[[ "$run_status" == 0 ]] || status=BLOCKED
[[ "$sample_count" == "$steady_batches" ]] || status=BLOCKED
[[ "$warmup_iterations" == 10000 && "$warmup_allocations" == 0 ]] || status=BLOCKED
[[ "$first_rss" =~ ^[0-9]+$ && "$last_rss" =~ ^[0-9]+$ && "$peak_rss" =~ ^[0-9]+$ && "$growth" =~ ^[0-9]+$ && "$peak_growth" =~ ^[0-9]+$ && "$allocations" =~ ^[0-9]+$ ]] || status=BLOCKED
[[ "$allocations" == 0 ]] || status=BLOCKED
[[ "$peak_growth" =~ ^[0-9]+$ && "$peak_growth" -le 64 ]] || status=BLOCKED

payload="$evidence_root/steady-state.payload"
report="$evidence_root/steady-state.report"
candidate_benchmark_sha="$(sha256sum "$candidate_benchmark" | awk '{print $1}')"
cat >"$payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=gameplay-steady-state-memory.sh --candidate-sha $candidate_sha --candidate-benchmark $candidate_benchmark --evidence-root $evidence_root
GAMEPLAY_STEADY_STATE_STATUS=$status
GAMEPLAY_STEADY_STATE_BATCHES=$steady_batches
GAMEPLAY_STEADY_STATE_SAMPLE_COUNT=$sample_count
GAMEPLAY_STEADY_STATE_WARMUP_ITERATIONS=$warmup_iterations
GAMEPLAY_STEADY_STATE_WARMUP_ALLOCATIONS=$warmup_allocations
GAMEPLAY_STEADY_STATE_ITERATIONS=$(metric iterations)
GAMEPLAY_STEADY_STATE_FIRST_RSS_KB=$first_rss
GAMEPLAY_STEADY_STATE_LAST_RSS_KB=$last_rss
GAMEPLAY_STEADY_STATE_PEAK_RSS_KB=$peak_rss
GAMEPLAY_STEADY_STATE_GROWTH_KB=$growth
GAMEPLAY_STEADY_STATE_PEAK_GROWTH_KB=$peak_growth
GAMEPLAY_STEADY_STATE_ALLOWED_GROWTH_KB=64
GAMEPLAY_STEADY_STATE_ALLOCATIONS=$allocations
GAMEPLAY_STEADY_STATE_BENCHMARK=$candidate_benchmark
GAMEPLAY_STEADY_STATE_BENCHMARK_SHA256=$candidate_benchmark_sha
GAMEPLAY_STEADY_STATE_STDOUT=$raw_stdout
GAMEPLAY_STEADY_STATE_STDOUT_SHA256=$(sha256sum "$raw_stdout" | awk '{print $1}')
GAMEPLAY_STEADY_STATE_STDERR=$raw_stderr
GAMEPLAY_STEADY_STATE_STDERR_SHA256=$(sha256sum "$raw_stderr" | awk '{print $1}')
GAMEPLAY_STEADY_STATE_TIME=$time_file
GAMEPLAY_STEADY_STATE_TIME_SHA256=$(sha256sum "$time_file" | awk '{print $1}')
GAMEPLAY_TOOL_ZIG_VERSION=$(zig version)
GAMEPLAY_TOOL_GNU_TIME_VERSION=$(/usr/bin/time --version 2>&1 | head -n 1)
GAMEPLAY_TOOL_HOST=$(uname -a)
EOF
{
    cat "$payload"
    printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' "$payload" "$(sha256sum "$payload" | awk '{print $1}')"
} >"$report"

printf 'GAMEPLAY_STEADY_STATE_STATUS=%s\n' "$status"
printf 'GAMEPLAY_STEADY_STATE_REPORT=%s\n' "$report"
if [[ "$status" == PASS ]]; then
    printf 'STEADY_STATE_MEMORY_PASS\n'
else
    printf 'STEADY_STATE_MEMORY_BLOCKED\n'
    exit 2
fi
