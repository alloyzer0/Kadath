#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: phase-quality-gate.sh [options]

Required evidence options:
  --candidate-benchmark PATH  executable for the current Rust Core candidate
  --oracle-worktree PATH      worktree checked out at bfc5504
  --oracle-benchmark PATH     executable for the bfc5504 Zig queue/flush oracle
  --coverage-report PATH      report containing PHASE3_COVERAGE_STATUS=PASS
  --mutation-report PATH      report containing PHASE3_MUTATION_STATUS=PASS
  --performance-report PATH   report containing PHASE3_PERF_STATUS=PASS
  --oracle-report PATH        report containing PHASE3_ORACLE_STATUS=PASS
  --help                      show this help

Exit status 0 means every required evidence source is present and marked PASS.
Exit status 2 means the gate is blocked. Exit status 1 means invalid usage.
USAGE
}

candidate_benchmark=""
oracle_worktree=""
oracle_benchmark=""
coverage_report=""
mutation_report=""
performance_report=""
oracle_report=""

while (($# > 0)); do
    case "$1" in
        --candidate-benchmark)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            candidate_benchmark=$2
            shift 2
            ;;
        --oracle-worktree)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            oracle_worktree=$2
            shift 2
            ;;
        --oracle-benchmark)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            oracle_benchmark=$2
            shift 2
            ;;
        --coverage-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            coverage_report=$2
            shift 2
            ;;
        --mutation-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            mutation_report=$2
            shift 2
            ;;
        --performance-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            performance_report=$2
            shift 2
            ;;
        --oracle-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            oracle_report=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf '%s\n' "unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

blocked=()
coverage_status=READY
coverage_reason=ok
mutation_status=READY
mutation_reason=ok
perf_status=READY
perf_reason=ok
oracle_status=READY
oracle_reason=ok
candidate_status=READY
candidate_reason=ok

if ! command -v llvm-cov >/dev/null 2>&1 || ! command -v llvm-profdata >/dev/null 2>&1; then
    coverage_status=BLOCKED
    coverage_reason="llvm-cov/llvm-profdata unavailable"
    blocked+=("coverage tools unavailable")
fi
if [[ -z "$coverage_report" ]]; then
    coverage_status=BLOCKED
    coverage_reason="coverage report not supplied"
    blocked+=("coverage report missing")
elif [[ ! -f "$coverage_report" ]] || ! grep -Fqx 'PHASE3_COVERAGE_STATUS=PASS' "$coverage_report"; then
    coverage_status=BLOCKED
    coverage_reason="coverage report missing PASS token"
    blocked+=("coverage report is not PASS")
fi

if ! command -v cargo-mutants >/dev/null 2>&1; then
    mutation_status=BLOCKED
    mutation_reason="cargo-mutants unavailable"
    blocked+=("mutation tool unavailable")
fi
if [[ -z "$mutation_report" ]]; then
    mutation_status=BLOCKED
    mutation_reason="mutation report not supplied"
    blocked+=("mutation report missing")
elif [[ ! -f "$mutation_report" ]] || ! grep -Fqx 'PHASE3_MUTATION_STATUS=PASS' "$mutation_report"; then
    mutation_status=BLOCKED
    mutation_reason="mutation report missing PASS token"
    blocked+=("mutation report is not PASS")
fi

if ! command -v perf >/dev/null 2>&1 || ! perf stat -e task-clock true >/dev/null 2>&1; then
    perf_status=BLOCKED
    perf_reason="perf stat unavailable or permission denied"
    blocked+=("performance counter unavailable")
fi
if [[ -z "$performance_report" ]]; then
    perf_status=BLOCKED
    perf_reason="performance report not supplied"
    blocked+=("performance report missing")
elif [[ ! -f "$performance_report" ]] || ! grep -Fqx 'PHASE3_PERF_STATUS=PASS' "$performance_report"; then
    perf_status=BLOCKED
    perf_reason="performance report missing PASS token"
    blocked+=("performance report is not PASS")
fi

if [[ -z "$candidate_benchmark" || ! -x "$candidate_benchmark" ]]; then
    candidate_status=BLOCKED
    candidate_reason="candidate benchmark executable missing"
    blocked+=("candidate benchmark missing")
fi

if [[ -z "$oracle_worktree" || ! -d "$oracle_worktree" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle worktree not supplied"
    blocked+=("oracle worktree missing")
elif ! oracle_sha=$(git -C "$oracle_worktree" rev-parse --verify bfc5504^{commit} 2>/dev/null) ||
    [[ "$(git -C "$oracle_worktree" rev-parse HEAD 2>/dev/null)" != "$oracle_sha" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle worktree is not checked out at bfc5504"
    blocked+=("oracle worktree is not bfc5504")
fi
if [[ -z "$oracle_benchmark" || ! -x "$oracle_benchmark" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle benchmark executable missing"
    blocked+=("oracle benchmark missing")
fi
if [[ -z "$oracle_report" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle report not supplied"
    blocked+=("oracle report missing")
elif [[ ! -f "$oracle_report" ]] || ! grep -Fqx 'PHASE3_ORACLE_STATUS=PASS' "$oracle_report"; then
    oracle_status=BLOCKED
    oracle_reason="oracle report missing PASS token"
    blocked+=("oracle report is not PASS")
fi

printf 'PHASE3_COVERAGE=%s\n' "$coverage_status"
printf 'PHASE3_COVERAGE_REASON=%s\n' "$coverage_reason"
printf 'PHASE3_MUTATION=%s\n' "$mutation_status"
printf 'PHASE3_MUTATION_REASON=%s\n' "$mutation_reason"
printf 'PHASE3_PERF=%s\n' "$perf_status"
printf 'PHASE3_PERF_REASON=%s\n' "$perf_reason"
printf 'PHASE3_CANDIDATE=%s\n' "$candidate_status"
printf 'PHASE3_CANDIDATE_REASON=%s\n' "$candidate_reason"
printf 'PHASE3_ORACLE=%s\n' "$oracle_status"
printf 'PHASE3_ORACLE_REASON=%s\n' "$oracle_reason"

if ((${#blocked[@]} != 0)); then
    printf 'PHASE3_QUALITY_GATE=BLOCKED\n'
    for reason in "${blocked[@]}"; do
        printf 'PHASE3_BLOCKER=%s\n' "$reason"
    done
    exit 2
fi

printf 'PHASE3_QUALITY_GATE=PASS\n'
printf 'QUALITY_GATE_STATUS=PASS\n'
