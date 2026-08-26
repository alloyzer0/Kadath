#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' 'Usage: gameplay-seed-matrix.sh --candidate-sha SHA --evidence-root PATH'
}

candidate_sha= evidence_root=
while (($#)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done

block() {
    printf 'GAMEPLAY_SEED_MATRIX_STATUS=BLOCKED_ENV\n'
    printf 'GAMEPLAY_SEED_MATRIX_BLOCKER=%s\n' "$1"
    exit 2
}

[[ "$(uname -s 2>/dev/null || true)" == Linux ]] || block 'Linux seed-matrix host unavailable'
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || block 'full candidate SHA required'
[[ -n "$evidence_root" && ! -e "$evidence_root" ]] || block 'unique absent evidence root required'
command -v cargo >/dev/null 2>&1 || block 'cargo unavailable'
command -v sha256sum >/dev/null 2>&1 || block 'sha256sum unavailable'
command -v awk >/dev/null 2>&1 || block 'awk unavailable'

repository_root=$(git rev-parse --show-toplevel)
[[ "$(git -C "$repository_root" rev-parse HEAD)" == "$candidate_sha" ]] || block 'checkout does not match candidate SHA'
mkdir -p "$evidence_root"

manifest="$evidence_root/seed-matrix.tsv"
command_log="$evidence_root/seed-matrix-command.log"
(cd -- "$repository_root" && \
    GAMEPLAY_SEED_MATRIX_MANIFEST="$manifest" \
    cargo test -p kadath_runtime_core deterministic_seed_matrix_covers_revision2_dimensions -- --nocapture) \
    >"$command_log" 2>&1 || block 'seed matrix test failed'

[[ -s "$manifest" ]] || block 'seed matrix manifest missing'
total=$(awk -F '\t' '$1 == "meta" && $2 == "total_seeds" { print $3; exit }' "$manifest")
unique=$(awk -F '\t' '$1 == "meta" && $2 == "unique_combinations" { print $3; exit }' "$manifest")
[[ "$total" == 10000 ]] || block 'seed total is not 10000'
[[ "$unique" == 5760 ]] || block 'seed combination coverage is not 5760'

# 每个维度取值和每个正交组合都必须至少出现一次；缺失行或零计数直接阻断。
bad_rows=$(awk -F '\t' 'NR > 1 && ($1 == "dimension" || $1 == "combination") && (($3 + 0) < ($4 + 0)) { count++ } END { print count + 0 }' "$manifest")
[[ "$bad_rows" == 0 ]] || block 'seed matrix contains uncovered dimension or combination'
dimension_rows=$(awk -F '\t' '$1 == "dimension" { count++ } END { print count + 0 }' "$manifest")
combination_rows=$(awk -F '\t' '$1 == "combination" { count++ } END { print count + 0 }' "$manifest")
[[ "$dimension_rows" == 26 ]] || block 'seed dimension manifest is incomplete'
[[ "$combination_rows" == 5760 ]] || block 'seed combination manifest is incomplete'

report="$evidence_root/seed-matrix.report"
cat >"$report" <<EOF
GAMEPLAY_SEED_MATRIX_STATUS=PASS
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_SEED_MATRIX_COMMAND=cargo test -p kadath_runtime_core deterministic_seed_matrix_covers_revision2_dimensions -- --nocapture
GAMEPLAY_SEED_MATRIX_TOTAL=$total
GAMEPLAY_SEED_MATRIX_UNIQUE_COMBINATIONS=$unique
GAMEPLAY_SEED_MATRIX_DIMENSION_ROWS=$dimension_rows
GAMEPLAY_SEED_MATRIX_COMBINATION_ROWS=$combination_rows
GAMEPLAY_SEED_MATRIX_MANIFEST=$manifest
GAMEPLAY_SEED_MATRIX_MANIFEST_SHA256=$(sha256sum "$manifest" | awk '{print $1}')
GAMEPLAY_SEED_MATRIX_COMMAND_LOG=$command_log
GAMEPLAY_SEED_MATRIX_COMMAND_LOG_SHA256=$(sha256sum "$command_log" | awk '{print $1}')
EOF
cat "$report"
