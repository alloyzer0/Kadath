#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' 'Usage: gameplay-coverage.sh --candidate-sha SHA --evidence-root PATH --kcov PATH'
}

candidate_sha= evidence_root= kcov=
while (($#)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        --kcov) kcov=${2-}; shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done

block() {
    printf 'GAMEPLAY_COVERAGE_STATUS=BLOCKED_ENV\n'
    printf 'GAMEPLAY_COVERAGE_BLOCKER=%s\n' "$1"
    exit 2
}

[[ "$(uname -s 2>/dev/null || true)" == Linux ]] || block 'Linux coverage host unavailable'
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || block 'full candidate SHA required'
[[ -n "$evidence_root" ]] || block 'evidence root required'
[[ -x "$kcov" ]] || block 'kcov unavailable'
command -v cargo >/dev/null 2>&1 || block 'cargo unavailable'
command -v cargo-llvm-cov >/dev/null 2>&1 || block 'cargo-llvm-cov unavailable'
command -v llvm-profdata >/dev/null 2>&1 || block 'llvm-profdata unavailable'
command -v jq >/dev/null 2>&1 || block 'jq unavailable'
command -v zig >/dev/null 2>&1 || block 'zig unavailable'
command -v rustup >/dev/null 2>&1 || block 'rustup unavailable for nightly coverage'
rustup toolchain list | grep -q '^nightly-' || block 'nightly Rust toolchain unavailable'

repository_root=$(git rev-parse --show-toplevel)
[[ "$(git -C "$repository_root" rev-parse HEAD)" == "$candidate_sha" ]] || block 'checkout does not match candidate SHA'
[[ ! -e "$evidence_root" ]] || block 'evidence root must be unique and absent'
mkdir -p "$evidence_root"

rust_json="$evidence_root/rust-coverage.json"
(cd -- "$repository_root" && cargo +nightly llvm-cov --package kadath_runtime_core --all-targets \
    --branch --json --output-path "$rust_json" -- --nocapture) >"$evidence_root/rust-command.log" 2>&1 || block 'Rust coverage command failed'

emit_prefix="$evidence_root/emit"
(cd -- "$repository_root" && zig build \
    emit-phase-runtime-core-contract emit-phase-public-c-contract emit-phase-behavior-contract \
    --prefix "$emit_prefix" -Doptimize=Debug -Dgameplay-quality-evidence=true \
    -Dgameplay-quality-emit-dir=gameplay-evidence --summary all) \
    >"$evidence_root/zig-emit.log" 2>&1 || block 'Zig evidence build failed'

binary_root="$emit_prefix/gameplay-evidence"
runtime_binary="$binary_root/runtime-core-contract"
public_binary="$binary_root/runtime-core-public-contract"
behavior_binary="$binary_root/behavior-host-contract"
for binary in "$runtime_binary" "$public_binary" "$behavior_binary"; do
    [[ -x "$binary" ]] || block "evidence binary missing: $binary"
done

run_kcov() {
    local name=$1 binary=$2 include=$3
    "$kcov" --include-path="$repository_root/$include" "$evidence_root/$name" "$binary" \
        >"$evidence_root/$name.log" 2>&1 || block "kcov run failed: $name"
}
run_kcov zig-adapter "$runtime_binary" modules/runtime_core/src/main.zig
run_kcov public-c "$public_binary" modules/runtime_core/tests/public_contract.c
run_kcov behavior "$behavior_binary" app/behavior_host.zig

rust_metric() {
    local field=$1
    jq -er --arg path "$repository_root/modules/runtime_core/src/gameplay.rs" \
        ".data[0].files[] | select(.filename == \$path) | .summary.${field}.percent" "$rust_json"
}
kcov_metric() {
    local directory=$1 field=$2
    local json
    json=$(find "$evidence_root/$directory" -name coverage.json -type f -print -quit)
    [[ -f "$json" ]] || block "kcov summary missing: $directory"
    jq -er ".$field | tonumber" "$json"
}

rust_line=$(rust_metric lines) || block 'Rust Gameplay line denominator missing'
rust_branch=$(rust_metric branches) || block 'Rust Gameplay branch denominator missing'
public_line=$(kcov_metric public-c percent_covered) || block 'public C line denominator missing'
zig_line=$(kcov_metric zig-adapter percent_covered) || block 'Zig Adapter line denominator missing'
behavior_line=$(kcov_metric behavior percent_covered) || block 'Behavior line denominator missing'

meets() { awk -v n="$1" -v minimum="$2" 'BEGIN { exit !(n+0 >= minimum) }'; }
meets "$rust_line" 90 || block 'Rust Gameplay line coverage below 90%'
meets "$rust_branch" 85 || block 'Rust Gameplay branch coverage below 85%'
meets "$public_line" 90 || block 'public C line coverage below 90%'
meets "$zig_line" 90 || block 'Zig Adapter line coverage below 90%'
meets "$behavior_line" 90 || block 'Behavior line coverage below 90%'

decision_manifest="$evidence_root/critical-decisions.tsv"
printf 'domain\tfile\tline\tdecision\tcovered\ttotal\n' >"$decision_manifest"
record_decision() {
    local domain=$1 path=$2 decision=$3 log=$4
    local marker="GAMEPLAY_DECISION $decision" source_line execution covered total
    source_line=$(grep -Fn "$marker" "$repository_root/$path" | cut -d: -f1 | tail -n 1)
    [[ "$source_line" =~ ^[0-9]+$ ]] || block "critical decision source marker missing: $decision"
    execution=$(grep -F "$marker " "$log" | tail -n 1)
    [[ -n "$execution" ]] || block "critical decision not executed: $decision"
    covered=$(sed -n 's/.* covered=\([0-9][0-9]*\) total=.*/\1/p' <<<"$execution")
    total=$(sed -n 's/.* total=\([0-9][0-9]*\).*/\1/p' <<<"$execution")
    [[ "$covered" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$total" -gt 0 && "$covered" -le "$total" ]] || \
        block "critical decision counter invalid: $decision"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$domain" "$path" "$source_line" "$decision" "$covered" "$total" >>"$decision_manifest"
}

# 每一行都来自本次 Debug 二进制的运行时 marker；源码 grep 只用于绑定 marker 所在行号。
record_decision timer_priority modules/runtime_core/src/gameplay.rs timer_priority "$evidence_root/rust-command.log"
record_decision contact_differencing modules/runtime_core/src/gameplay.rs contact_diff_edges "$evidence_root/rust-command.log"
record_decision paired_publication modules/runtime_core/tests/runtime_core_contract.zig paired_publication "$evidence_root/zig-adapter.log"
record_decision restart_reset modules/runtime_core/tests/runtime_core_contract.zig restart_reset "$evidence_root/zig-adapter.log"
record_decision phase_capacity modules/runtime_core/tests/runtime_core_contract.zig phase_capacity "$evidence_root/zig-adapter.log"
record_decision snapshot_outcome modules/runtime_core/tests/runtime_core_contract.zig snapshot_outcome_no_replay "$evidence_root/zig-adapter.log"
record_decision public_preflight modules/runtime_core/tests/public_contract.c public_abi_preflight "$evidence_root/public-c.log"
record_decision failure_atomicity modules/runtime_core/tests/public_contract.c failure_no_side_effect "$evidence_root/public-c.log"
record_decision contact_order app/behavior_host_contract.zig directed_contact_order "$evidence_root/behavior.log"
record_decision overflow app/behavior_host_contract.zig behavior_overflow_isolation "$evidence_root/behavior.log"
decision_total=$(awk -F '\t' 'NR > 1 { total += $6 } END { print total+0 }' "$decision_manifest")
decision_covered=$(awk -F '\t' 'NR > 1 { covered += $5 } END { print covered+0 }' "$decision_manifest")
decision_percent=$(awk -v covered="$decision_covered" -v total="$decision_total" 'BEGIN { printf "%.2f", 100 * covered / total }')
[[ "$decision_total" -gt 0 && "$decision_total" -eq "$decision_covered" ]] || block 'critical decision matrix incomplete'

report="$evidence_root/coverage.report"
cat >"$report" <<EOF
GAMEPLAY_COVERAGE_STATUS=PASS
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=cargo llvm-cov + zig emit + kcov runtime/public/behavior
GAMEPLAY_COVERAGE_RUST_LINE_PERCENT=$rust_line
GAMEPLAY_COVERAGE_RUST_BRANCH_PERCENT=$rust_branch
GAMEPLAY_COVERAGE_PUBLIC_C_LINE_PERCENT=$public_line
GAMEPLAY_COVERAGE_ZIG_ADAPTER_LINE_PERCENT=$zig_line
GAMEPLAY_COVERAGE_BEHAVIOR_LINE_PERCENT=$behavior_line
GAMEPLAY_CRITICAL_DECISIONS_COVERED=$decision_covered
GAMEPLAY_CRITICAL_DECISIONS_TOTAL=$decision_total
GAMEPLAY_CRITICAL_DECISIONS_PERCENT=$decision_percent
GAMEPLAY_CRITICAL_DECISIONS_MANIFEST=$decision_manifest
GAMEPLAY_CRITICAL_DECISIONS_MANIFEST_SHA256=$(sha256sum "$decision_manifest" | awk '{print $1}')
GAMEPLAY_COVERAGE_RUST_JSON=$rust_json
GAMEPLAY_COVERAGE_RUST_JSON_SHA256=$(sha256sum "$rust_json" | awk '{print $1}')
GAMEPLAY_COVERAGE_RUNTIME_BINARY=$runtime_binary
GAMEPLAY_COVERAGE_RUNTIME_BINARY_SHA256=$(sha256sum "$runtime_binary" | awk '{print $1}')
GAMEPLAY_COVERAGE_PUBLIC_BINARY=$public_binary
GAMEPLAY_COVERAGE_PUBLIC_BINARY_SHA256=$(sha256sum "$public_binary" | awk '{print $1}')
GAMEPLAY_COVERAGE_BEHAVIOR_BINARY=$behavior_binary
GAMEPLAY_COVERAGE_BEHAVIOR_BINARY_SHA256=$(sha256sum "$behavior_binary" | awk '{print $1}')
EOF
cat "$report"
