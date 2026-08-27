#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
git_repo="$scratch/repo"
mkdir -p "$git_repo"
git -C "$git_repo" init -q
git -C "$git_repo" config user.name "Kadath Gate Test"
git -C "$git_repo" config user.email "gate-test@example.invalid"
printf '%s\n' fixture >"$git_repo/fixture"
git -C "$git_repo" add fixture
git -C "$git_repo" commit -qm fixture
candidate_sha=$(git -C "$git_repo" rev-parse HEAD)

hash() { sha256sum "$1" | awk '{print $1}'; }
for name in benchmark script initial reload build.stdout build.stderr run.stderr; do
    printf '%s\n' "$name" >"$scratch/$name"
done
chmod +x "$scratch/benchmark"
digest=fa77c837f249f9dfe9cdf85d597d7a06d34b3c45ceccfe9e5209e46c0947aaaf
cat >"$scratch/run.stdout" <<EOF
vertical_slice_samples=64 p50_ns=2000000 p95_ns=3000000 p99_ns=4000000 rust_allocations_total=58176 rust_allocations_max=909 rust_steady_fixed_samples=256 rust_steady_fixed_allocations_total=16896 rust_steady_fixed_allocations_max=66 digest=$digest
vertical_slice_contract objects=5 fixed_steps=7 outcomes=3 steady_fixed_samples=256 steady_fixed_max_allocations=96 initial_epoch=1 restart_epoch=1 reload_epoch=2 contact_order=212 status=PASS
EOF
printf '%s\n' 'Maximum resident set size (kbytes): 24576' >"$scratch/run.time"

payload="$scratch/report.payload"
report="$scratch/report"
cat >"$payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=test command
GAMEPLAY_VERTICAL_SLICE_STATUS=PASS
GAMEPLAY_VERTICAL_SLICE_SAMPLES=64
GAMEPLAY_VERTICAL_SLICE_OBJECTS=5
GAMEPLAY_VERTICAL_SLICE_FIXED_STEPS=7
GAMEPLAY_VERTICAL_SLICE_OUTCOMES=3
GAMEPLAY_VERTICAL_SLICE_P50_NS=2000000
GAMEPLAY_VERTICAL_SLICE_P95_NS=3000000
GAMEPLAY_VERTICAL_SLICE_P99_NS=4000000
GAMEPLAY_VERTICAL_SLICE_MAX_P95_NS=50000000
GAMEPLAY_VERTICAL_SLICE_MAX_P99_NS=100000000
GAMEPLAY_VERTICAL_SLICE_RUST_ALLOCATIONS_TOTAL=58176
GAMEPLAY_VERTICAL_SLICE_RUST_ALLOCATIONS_MAX=909
GAMEPLAY_VERTICAL_SLICE_RUST_STEADY_FIXED_SAMPLES=256
GAMEPLAY_VERTICAL_SLICE_RUST_STEADY_FIXED_ALLOCATIONS_TOTAL=16896
GAMEPLAY_VERTICAL_SLICE_RUST_STEADY_FIXED_ALLOCATIONS_MAX=66
GAMEPLAY_VERTICAL_SLICE_RUST_STEADY_FIXED_ALLOWED_MAX=96
GAMEPLAY_VERTICAL_SLICE_REPLAY_DIGEST=$digest
GAMEPLAY_VERTICAL_SLICE_PEAK_RSS_KB=24576
GAMEPLAY_VERTICAL_SLICE_RSS_POLICY=diagnostic_only
GAMEPLAY_VERTICAL_SLICE_BENCHMARK=$scratch/benchmark
GAMEPLAY_VERTICAL_SLICE_BENCHMARK_SHA256=$(hash "$scratch/benchmark")
GAMEPLAY_VERTICAL_SLICE_SCRIPT_ARTIFACT=$scratch/script
GAMEPLAY_VERTICAL_SLICE_SCRIPT_ARTIFACT_SHA256=$(hash "$scratch/script")
GAMEPLAY_VERTICAL_SLICE_INITIAL_SCENE=$scratch/initial
GAMEPLAY_VERTICAL_SLICE_INITIAL_SCENE_SHA256=$(hash "$scratch/initial")
GAMEPLAY_VERTICAL_SLICE_RELOAD_SCENE=$scratch/reload
GAMEPLAY_VERTICAL_SLICE_RELOAD_SCENE_SHA256=$(hash "$scratch/reload")
GAMEPLAY_VERTICAL_SLICE_BUILD_STDOUT=$scratch/build.stdout
GAMEPLAY_VERTICAL_SLICE_BUILD_STDOUT_SHA256=$(hash "$scratch/build.stdout")
GAMEPLAY_VERTICAL_SLICE_BUILD_STDERR=$scratch/build.stderr
GAMEPLAY_VERTICAL_SLICE_BUILD_STDERR_SHA256=$(hash "$scratch/build.stderr")
GAMEPLAY_VERTICAL_SLICE_STDOUT=$scratch/run.stdout
GAMEPLAY_VERTICAL_SLICE_STDOUT_SHA256=$(hash "$scratch/run.stdout")
GAMEPLAY_VERTICAL_SLICE_STDERR=$scratch/run.stderr
GAMEPLAY_VERTICAL_SLICE_STDERR_SHA256=$(hash "$scratch/run.stderr")
GAMEPLAY_VERTICAL_SLICE_TIME=$scratch/run.time
GAMEPLAY_VERTICAL_SLICE_TIME_SHA256=$(hash "$scratch/run.time")
GAMEPLAY_TOOL_ZIG_VERSION=0.16.0
GAMEPLAY_TOOL_GNU_TIME_VERSION=GNU time
GAMEPLAY_TOOL_HOST=Linux test
EOF
{
    cat "$payload"
    printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' "$payload" "$(hash "$payload")"
} >"$report"

(cd "$git_repo" && bash "$repository_root/tools/gameplay-vertical-slice-quality-gate.sh" --candidate-sha "$candidate_sha" --report "$report") | grep -q VERTICAL_SLICE_GATE_PASS

# 即使攻击者重新绑定 payload，稳态 fixed-step 出现分配也必须阻断。
steady_bad_payload="$scratch/steady-bad.payload"
steady_bad_report="$scratch/steady-bad.report"
sed 's/GAMEPLAY_VERTICAL_SLICE_RUST_STEADY_FIXED_ALLOCATIONS_MAX=66/GAMEPLAY_VERTICAL_SLICE_RUST_STEADY_FIXED_ALLOCATIONS_MAX=97/' \
    "$payload" >"$steady_bad_payload"
{
    cat "$steady_bad_payload"
    printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' \
        "$steady_bad_payload" "$(hash "$steady_bad_payload")"
} >"$steady_bad_report"
set +e
steady_bad_output=$(cd "$git_repo" && bash "$repository_root/tools/gameplay-vertical-slice-quality-gate.sh" \
    --candidate-sha "$candidate_sha" --report "$steady_bad_report" 2>&1)
steady_bad_status=$?
set -e
[[ "$steady_bad_status" == 2 ]]
grep -q 'steady fixed-step allocation gate failed' <<<"$steady_bad_output"

printf '%s\n' 'tampered' >>"$scratch/run.stdout"
set +e
tampered_output=$(cd "$git_repo" && bash "$repository_root/tools/gameplay-vertical-slice-quality-gate.sh" --candidate-sha "$candidate_sha" --report "$report" 2>&1)
tampered_status=$?
set -e
[[ "$tampered_status" == 2 ]]
grep -q 'Vertical Slice stdout hash mismatch' <<<"$tampered_output"
printf '%s\n' 'VERTICAL_SLICE_GATE_TEST_PASS'
