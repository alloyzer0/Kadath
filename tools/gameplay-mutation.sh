#!/usr/bin/env bash
set -euo pipefail

usage() { printf '%s\n' 'Usage: gameplay-mutation.sh --candidate-sha SHA --evidence-root PATH'; }
candidate_sha= evidence_root=
while (($#)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done

block() {
    printf 'GAMEPLAY_MUTATION_STATUS=BLOCKED_ENV\n'
    printf 'GAMEPLAY_MUTATION_BLOCKER=%s\n' "$1"
    exit 2
}

[[ "$(uname -s 2>/dev/null || true)" == Linux ]] || block 'Linux mutation host unavailable'
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || block 'full candidate SHA required'
[[ -n "$evidence_root" && ! -e "$evidence_root" ]] || block 'unique absent evidence root required'
command -v cargo-mutants >/dev/null 2>&1 || block 'cargo-mutants unavailable'
command -v jq >/dev/null 2>&1 || block 'jq unavailable'
repository_root=$(git rev-parse --show-toplevel)
[[ "$(git -C "$repository_root" rev-parse HEAD)" == "$candidate_sha" ]] || block 'checkout does not match candidate SHA'
mkdir -p "$evidence_root"

mutation_root="$evidence_root/mutants"
(cd -- "$repository_root" && cargo mutants --package kadath_runtime_core \
    --file modules/runtime_core/src/gameplay.rs \
    --file modules/runtime_core/src/lib.rs \
    --timeout 120 --output "$mutation_root") >"$evidence_root/mutation-command.log" 2>&1 || true
outcomes=$(find "$mutation_root" -name outcomes.json -type f -print -quit)
[[ -n "$outcomes" && -f "$outcomes" ]] || block 'cargo-mutants outcomes missing'

total=$(jq '[.outcomes[] | select(.scenario != "Baseline")] | length' "$outcomes")
killed=$(jq '[.outcomes[] | select(.scenario != "Baseline" and .summary == "CaughtMutant")] | length' "$outcomes")
survived=$(jq '[.outcomes[] | select(.scenario != "Baseline" and .summary == "MissedMutant")] | length' "$outcomes")
unviable=$(jq '[.outcomes[] | select(.scenario != "Baseline" and .summary == "Unviable")] | length' "$outcomes")
unclassified=$((total - killed - survived - unviable))
critical_pattern='begin_step|observe_contacts|transition|active_contacts|contact_transitions|submit_contact_transitions|outcome_value|step_result|prepare_gameplay_state|begin_gameplay_fixed|commit_gameplay_fixed|publish_gameplay_snapshot|validate_outcome_buffer'
critical_survivors=$(jq --arg pattern "$critical_pattern" '[.outcomes[] | select(
    .scenario != "Baseline" and
    .summary == "MissedMutant" and
    ((.scenario.Mutant.function.function_name // "") | test($pattern))
)] | length' "$outcomes")
[[ "$total" -gt 0 ]] || block 'no mutants generated'
[[ "$unviable" -eq 0 ]] || block 'unviable mutants require audit'
[[ "$unclassified" -eq 0 ]] || block 'timeout or unclassified mutants require audit'
score=$(awk -v killed="$killed" -v total="$total" 'BEGIN { printf "%.2f", killed * 100 / total }')
awk -v score="$score" 'BEGIN { exit !(score+0 >= 80) }' || block 'mutation score below 80%'
[[ "$survived" -eq 0 ]] || block 'surviving Gameplay mutants present'
[[ "$critical_survivors" -eq 0 ]] || block 'critical invariant mutants survived'

manifest="$evidence_root/mutation-manifest.tsv"
jq -r '.outcomes[] | select(.scenario != "Baseline") |
    [.summary, (.scenario.Mutant.name // .scenario), (.log_path // "")] | @tsv' \
    "$outcomes" >"$manifest"
report="$evidence_root/mutation.report"
cat >"$report" <<EOF
GAMEPLAY_MUTATION_STATUS=PASS
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=cargo mutants --package kadath_runtime_core --file gameplay.rs --file lib.rs
GAMEPLAY_MUTATION_TOTAL=$total
GAMEPLAY_MUTATION_KILLED=$killed
GAMEPLAY_MUTATION_SURVIVED=$survived
GAMEPLAY_MUTATION_UNVIABLE=$unviable
GAMEPLAY_MUTATION_UNCLASSIFIED=$unclassified
GAMEPLAY_MUTATION_SCORE_PERCENT=$score
GAMEPLAY_CRITICAL_SURVIVORS=$critical_survivors
GAMEPLAY_MUTATION_CRITICAL_DOMAINS=timer_priority,contact_differencing,epoch_stale,capacity,snapshot_publication,outcome_sequence,abi_preflight
GAMEPLAY_MUTATION_MANIFEST=$manifest
GAMEPLAY_MUTATION_MANIFEST_SHA256=$(sha256sum "$manifest" | awk '{print $1}')
EOF
cat "$report"
