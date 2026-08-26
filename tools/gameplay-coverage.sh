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
    --branch --json --output-path "$rust_json") >"$evidence_root/rust-command.log" 2>&1 || block 'Rust coverage command failed'

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

meets() { awk -v n="$1" -v minimum="$2" 'BEGIN { exit !(n+0 >= minimum) }'; }
meets "$rust_line" 90 || block 'Rust Gameplay line coverage below 90%'
meets "$rust_branch" 85 || block 'Rust Gameplay branch coverage below 85%'
meets "$public_line" 90 || block 'public C line coverage below 90%'
meets "$zig_line" 90 || block 'Zig Adapter line coverage below 90%'

require_anchor() {
    local path=$1 anchor=$2 domain=$3
    grep -Fq "$anchor" "$repository_root/$path" || block "critical decision test missing: $domain"
}
require_test_log() {
    local log=$1 marker=$2 domain=$3
    [[ -s "$log" ]] || block "critical decision execution log missing: $domain"
    grep -Fq "$marker" "$log" || block "critical decision not executed: $domain"
}
decision_manifest="$evidence_root/critical-decisions.tsv"
printf 'domain\tfile\tline\tdecision\tcovered\ttotal\n' >"$decision_manifest"
require_anchor modules/runtime_core/src/gameplay.rs 'timer_then_hazard_then_goal_priority_is_terminal_and_exactly_once' timer_priority
require_test_log "$evidence_root/rust-command.log" 'timer_then_hazard_then_goal_priority_is_terminal_and_exactly_once ... ok' timer_priority
printf 'timer_priority\tmodules/runtime_core/src/gameplay.rs\tpriority\ttimer-before-contact\t1\t1\n' >>"$decision_manifest"
require_anchor modules/runtime_core/src/gameplay.rs 'stale_previous_contact_is_cleared_without_publishing_an_end_event' stale_contact
require_test_log "$evidence_root/rust-command.log" 'stale_previous_contact_is_cleared_without_publishing_an_end_event ... ok' stale_contact
printf 'stale_contact\tmodules/runtime_core/src/gameplay.rs\tcontact_transitions\tstale-source-drop\t1\t1\n' >>"$decision_manifest"
require_anchor modules/runtime_core/tests/runtime_core_contract.zig 'Scene publication requires ready Object Gameplay and Phase candidates' paired_candidate
require_test_log "$evidence_root/zig-adapter.log" 'Scene publication requires ready Object Gameplay and Phase candidates...OK' paired_candidate
printf 'paired_candidate\tmodules/runtime_core/tests/runtime_core_contract.zig\tpublication\tpaired-candidate-preflight\t1\t1\n' >>"$decision_manifest"
require_anchor modules/runtime_core/tests/runtime_core_contract.zig 'Restart is terminal-only and preserves Gameplay sequence high-water marks' restart_high_water
require_test_log "$evidence_root/zig-adapter.log" 'Restart is terminal-only and preserves Gameplay sequence high-water marks...OK' restart_high_water
printf 'restart_high_water\tmodules/runtime_core/tests/runtime_core_contract.zig\trestart\tsequence-high-water\t1\t1\n' >>"$decision_manifest"
require_anchor modules/runtime_core/tests/runtime_core_contract.zig 'Runtime Core Gameplay owns terminal priority contact events outcome and final tint' snapshot_outcome
require_test_log "$evidence_root/zig-adapter.log" 'Runtime Core Gameplay owns terminal priority contact events outcome and final tint...OK' snapshot_outcome
printf 'snapshot_outcome\tmodules/runtime_core/tests/runtime_core_contract.zig\tsnapshot\toutcome-tint-coherence\t1\t1\n' >>"$decision_manifest"
require_anchor modules/runtime_core/tests/public_contract.c 'PHASE3_PUBLIC_GAMEPLAY_PATH=PASS' public_preflight
require_test_log "$evidence_root/public-c.log" 'PHASE3_PUBLIC_GAMEPLAY_PATH=PASS' public_preflight
printf 'public_preflight\tmodules/runtime_core/tests/public_contract.c\tpreflight\tpublic-abi-preflight\t1\t1\n' >>"$decision_manifest"
require_anchor app/behavior_host_contract.zig 'contact events are directed and deliver end before begin' contact_order
require_test_log "$evidence_root/behavior.log" 'contact events are directed and deliver end before begin...OK' contact_order
printf 'contact_order\tapp/behavior_host_contract.zig\tcontact-events\tend-before-begin\t1\t1\n' >>"$decision_manifest"
require_anchor modules/runtime_core/tests/runtime_core_contract.zig 'Runtime Core Phase replay preserves FIFO, domain counters, and generation bounds' phase_capacity
require_test_log "$evidence_root/zig-adapter.log" 'Runtime Core Phase replay preserves FIFO, domain counters, and generation bounds...OK' phase_capacity
printf 'phase_capacity\tmodules/runtime_core/tests/runtime_core_contract.zig\tphase-replay\tfifo-generation-bounds\t1\t1\n' >>"$decision_manifest"
decision_total=$(awk 'NR > 1 { total++ } END { print total+0 }' "$decision_manifest")
decision_covered=$(awk 'NR > 1 && $5 == $6 { covered++ } END { print covered+0 }' "$decision_manifest")
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
GAMEPLAY_CRITICAL_DECISIONS_PERCENT=100
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
