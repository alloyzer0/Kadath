#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' "Usage: phase-coverage.sh --candidate-sha SHA --evidence-root PATH --kcov PATH"
}

candidate_sha=""
evidence_root=""
kcov=""
while (($# > 0)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        --kcov) kcov=${2-}; shift 2 ;;
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
[[ -n "$evidence_root" && -x "$kcov" ]] || { usage >&2; exit 1; }
mkdir -p "$evidence_root"
evidence_root="$(cd -- "$evidence_root" && pwd)"
kcov="$(cd -- "$(dirname -- "$kcov")" && pwd)/$(basename -- "$kcov")"

emit_name="phase-coverage-${candidate_sha:0:12}"
(
cd -- "$repository_root"
cargo test --locked --manifest-path modules/runtime_core/Cargo.toml \
    >"$evidence_root/rust-unit.log" 2>&1
zig build emit-phase-runtime-core-contract emit-phase-public-c-contract emit-phase-behavior-contract \
    -Dphase-quality-evidence=true -Dphase-quality-emit-dir="$emit_name" --summary all \
    >"$evidence_root/emit.log" 2>&1
)

runtime_binary="$repository_root/zig-out/$emit_name/runtime-core-contract"
public_binary="$repository_root/zig-out/$emit_name/runtime-core-public-contract"
behavior_binary="$repository_root/zig-out/$emit_name/behavior-host-contract"
rust_unit_binary="$(find "$repository_root/target/debug/deps" -maxdepth 1 -type f \
    -name 'kadath_runtime_core-*' -printf '%T@ %m %p\n' |
    awk '$2 == 700 { print }' | sort -nr | head -n 1 | cut -d' ' -f3-)"
[[ -x "$runtime_binary" && -x "$public_binary" && -x "$behavior_binary" && -x "$rust_unit_binary" ]] || exit 1

kcov_library_dir="${KCOV_LIBRARY_DIR:-}"
if [[ -n "$kcov_library_dir" ]]; then
    export LD_LIBRARY_PATH="$kcov_library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
phase_source="$repository_root/modules/runtime_core/src/phase_commit.rs"
public_source="$repository_root/modules/runtime_core/tests/public_contract.c"
adapter_source="$repository_root/modules/runtime_core/src/main.zig"
behavior_source="$repository_root/app/behavior_host.zig"

"$kcov" --clean --include-pattern="$phase_source,$adapter_source" \
    "$evidence_root/runtime" "$runtime_binary" >"$evidence_root/runtime.log" 2>&1
"$kcov" --clean --include-pattern="$phase_source,$public_source" \
    "$evidence_root/public" "$public_binary" >"$evidence_root/public.log" 2>&1
(
ulimit -s 65536
"$kcov" --clean --include-pattern="$phase_source,$behavior_source" \
    "$evidence_root/behavior" "$behavior_binary" >"$evidence_root/behavior.log" 2>&1
)
"$kcov" --clean --include-pattern="$phase_source" \
    "$evidence_root/rust-unit" "$rust_unit_binary" >"$evidence_root/rust-unit-kcov.log" 2>&1
"$kcov" --merge "$evidence_root/merged" \
    "$evidence_root/runtime" "$evidence_root/public" "$evidence_root/behavior" "$evidence_root/rust-unit" \
    >"$evidence_root/merge.log" 2>&1

coverage_json="$(find "$evidence_root/merged" -name coverage.json -type f -print -quit)"
[[ -f "$coverage_json" ]] || exit 1
metric() {
    local path=$1
    sed -n "s|.*\"file\": \"${path//|/\\|}\", \"percent_covered\": \"\([^\"]*\)\", \"covered_lines\": \"\([^\"]*\)\", \"total_lines\": \"\([^\"]*\)\".*|\1 \2 \3|p" "$coverage_json"
}
read -r phase_percent phase_covered phase_total <<<"$(metric "$phase_source")"
read -r public_percent public_covered public_total <<<"$(metric "$public_source")"
read -r adapter_percent adapter_covered adapter_total <<<"$(metric "$adapter_source")"
read -r behavior_percent behavior_covered behavior_total <<<"$(metric "$behavior_source")"

matrix_manifest="$evidence_root/decision-matrix.tsv"
: >"$matrix_manifest"
matrix_total=0
matrix_present=0
require_decision() {
    local decision=$1
    local source=$2
    local log=$3
    local pattern=$4
    matrix_total=$((matrix_total + 1))
    local line
    line="$(grep -nEm1 "$pattern" "$log" || true)"
    if [[ -n "$line" ]]; then
        matrix_present=$((matrix_present + 1))
        printf '%s\tPASS\t%s\t%s\t%s\n' "$decision" "$source" "$log" "$line" >>"$matrix_manifest"
    else
        printf '%s\tMISSING\t%s\t%s\t%s\n' "$decision" "$source" "$log" "$pattern" >>"$matrix_manifest"
    fi
}

# Every row is bound to output from a binary executed under kcov in this run,
# rather than to a source grep that can only prove a test exists.
require_decision fixed_frame_isolation modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'Phase replay preserves FIFO, domain counters, and generation bounds.*OK'
require_decision event_queue_overflow modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'Phase replay preserves FIFO, domain counters, and generation bounds.*OK'
require_decision generation_zero_to_eight modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'Phase replay preserves FIFO, domain counters, and generation bounds.*OK'
require_decision generation_exhaustion modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'Phase replay preserves FIFO, domain counters, and generation bounds.*OK'
require_decision independent_event_structural_sequence modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'structural replay preserves bounded FIFO and successor generation.*OK'
require_decision admission_256 modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'admission overflow preserves structural state.*OK'
require_decision event_budget_64 modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'Phase replay preserves FIFO, domain counters, and generation bounds.*OK'
require_decision structural_budget_64 modules/runtime_core/tests/runtime_core_contract.zig "$evidence_root/runtime.log" 'structural replay preserves bounded FIFO and successor generation.*OK'
require_decision stale_delivery app/behavior_host_contract.zig "$evidence_root/behavior.log" 'stale queued target is dropped without disabling its producer.*OK'
require_decision wrong_domain_token modules/runtime_core/tests/public_contract.c "$evidence_root/public.log" 'PHASE3_PUBLIC_PHASE_COMMIT_PATH=PASS'
require_decision same_flush_cancellation app/behavior_host_contract.zig "$evidence_root/behavior.log" 'spawn then destroy cancels child before activation.*OK'
require_decision activation_commit_abort modules/runtime_core/tests/public_contract.c "$evidence_root/public.log" 'PHASE3_PUBLIC_ACTIVATION_DISCARD=PASS'
require_decision serial_high_water modules/runtime_core/tests/public_contract.c "$evidence_root/public.log" 'PHASE3_PUBLIC_SERIAL_HIGH_WATER=PASS'
require_decision restart_reload_cleanup app/behavior_host_contract.zig "$evidence_root/behavior.log" 'follows restart replacement and rejects a new world epoch.*OK'
require_decision wrong_thread modules/runtime_core/tests/public_contract.c "$evidence_root/public.log" 'PHASE3_PUBLIC_MISUSE=PASS'
require_decision reentrant modules/runtime_core/src/lib.rs "$evidence_root/rust-unit-kcov.log" 'reentrant_entry_is_rejected_without_clearing_outer_call_state.*ok'
require_decision panic_no_publication modules/runtime_core/tests/public_contract.c "$evidence_root/public.log" 'PHASE3_PUBLIC_FAULT_CONTAINMENT=PASS'
require_decision oom_no_side_effect modules/runtime_core/tests/public_contract.c "$evidence_root/public.log" 'PHASE3_PUBLIC_FAULT_CONTAINMENT=PASS'
require_decision callback_failure_isolation app/behavior_host_contract.zig "$evidence_root/behavior.log" 'failed event handler keeps prior writes and later handlers continue.*OK'

matrix_percent="$(awk -v present="$matrix_present" -v total="$matrix_total" 'BEGIN { printf "%.0f", 100 * present / total }')"
matrix_sha="$(sha256sum "$matrix_manifest" | awk '{print $1}')"

status=PASS
for percent in "$phase_percent" "$public_percent" "$adapter_percent" "$behavior_percent"; do
    [[ -n "$percent" ]] || { status=FAIL; continue; }
    awk -v value="$percent" 'BEGIN { exit !(value >= 90.0) }' || status=FAIL
done
[[ "$matrix_present" -eq "$matrix_total" ]] || status=FAIL

report="$evidence_root/coverage.report"
cat >"$report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_COMMAND=tools/phase-coverage.sh --candidate-sha $candidate_sha --evidence-root $evidence_root --kcov $kcov
PHASE3_COVERAGE_STATUS=$status
PHASE3_COVERAGE_PHASE_COMMIT_PERCENT=$phase_percent
PHASE3_COVERAGE_PHASE_COMMIT_LINES=$phase_covered/$phase_total
PHASE3_COVERAGE_PUBLIC_C_PERCENT=$public_percent
PHASE3_COVERAGE_PUBLIC_C_LINES=$public_covered/$public_total
PHASE3_COVERAGE_ZIG_ADAPTER_PERCENT=$adapter_percent
PHASE3_COVERAGE_ZIG_ADAPTER_LINES=$adapter_covered/$adapter_total
PHASE3_COVERAGE_BEHAVIOR_HOST_PERCENT=$behavior_percent
PHASE3_COVERAGE_BEHAVIOR_HOST_LINES=$behavior_covered/$behavior_total
PHASE3_DECISION_MATRIX_PERCENT=$matrix_percent
PHASE3_DECISION_MATRIX_COUNT=$matrix_present/$matrix_total
PHASE3_DECISION_MATRIX_MANIFEST_SHA256=$matrix_sha
PHASE3_DECISION_MATRIX_EVIDENCE=$matrix_manifest
EOF

printf 'PHASE3_COVERAGE_REPORT=%s\n' "$report"
printf 'PHASE3_COVERAGE_JSON=%s\n' "$coverage_json"
printf 'PHASE3_COVERAGE_STATUS=%s\n' "$status"
[[ "$status" == PASS ]]
