#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' "Usage: phase-mutation.sh --candidate-sha SHA --evidence-root PATH"
}

candidate_sha=""
evidence_root=""
while (($# > 0)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --evidence-root) evidence_root=${2-}; shift 2 ;;
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
[[ -n "$evidence_root" ]] || { usage >&2; exit 1; }
mkdir -p "$evidence_root"
evidence_root="$(cd -- "$evidence_root" && pwd)"

mutation_worktree="$evidence_root/candidate-mutants"
git -C "$repository_root" worktree add --detach "$mutation_worktree" "$candidate_sha" >/dev/null
cleanup() {
    git -C "$repository_root" worktree remove --force "$mutation_worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

source_path="modules/runtime_core/src/phase_commit.rs"
source_file="$mutation_worktree/$source_path"
pristine_source="$evidence_root/phase_commit.pristine.rs"
cp -- "$source_file" "$pristine_source"
test_command='zig build test-runtime-core test-runtime-core-public-c test-behavior-script -Doptimize=Debug --summary all'

baseline_log="$evidence_root/baseline.log"
(cd -- "$mutation_worktree" && eval "$test_command") >"$baseline_log" 2>&1

ids=(
    domain_frame_alias
    phase_token_inversion
    generation_upper_bound
    generation_zero_normalization
    generation_expected_inversion
    admission_exact_capacity
    event_exact_capacity
    structural_exact_capacity
    activation_binding_exact_capacity
    completion_count_inversion
    reserve_completion_status_inversion
    destroy_completion_status_inversion
)
olds=(
    '            abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME => Ok(1),'
    '        if self.domain(domain)?.phase_sequence == Some(phase_sequence) {'
    '        if expected > MAX_GENERATION {'
    '        if input == 0 {'
    '        if input != expected {'
    '        if next > MAX_BINDINGS {'
    '    if domain_state.event_queue.len() + item_count > EVENT_CAPACITY {'
    '    if domain_state.structural_queue.len() + item_count > STRUCTURAL_CAPACITY'
    '    if staged_used as usize > batch.active_binding_capacity {'
    '    if completion_count != remaining_count {'
    '            if indexed.value.status != abi::KADATH_RUNTIME_PHASE_COMPLETION_CANCELLED {'
    '            && indexed.value.status == abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED'
)
news=(
    '            abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME => Ok(0),'
    '        if self.domain(domain)?.phase_sequence != Some(phase_sequence) {'
    '        if expected >= MAX_GENERATION {'
    '        if input != 0 {'
    '        if input == expected {'
    '        if next >= MAX_BINDINGS {'
    '    if domain_state.event_queue.len() + item_count >= EVENT_CAPACITY {'
    '    if domain_state.structural_queue.len() + item_count >= STRUCTURAL_CAPACITY'
    '    if staged_used as usize >= batch.active_binding_capacity {'
    '    if completion_count == remaining_count {'
    '            if indexed.value.status == abi::KADATH_RUNTIME_PHASE_COMPLETION_CANCELLED {'
    '            && indexed.value.status != abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED'
)

manifest="$evidence_root/mutation-manifest.tsv"
printf 'id\tstatus\tdiff_sha256\tcommand\tkill_test\n' >"$manifest"
killed=0
survived=0
unviable=0
for index in "${!ids[@]}"; do
    cp -- "$pristine_source" "$source_file"
    old=${olds[$index]}
    new=${news[$index]}
    matches="$(grep -Fc -- "$old" "$source_file")"
    if [[ "$matches" -ne 1 ]]; then
        printf '%s\tUNVIABLE\tmissing-source-anchor\t%s\n' "${ids[$index]}" "$test_command" >>"$manifest"
        unviable=$((unviable + 1))
        continue
    fi
    OLD="$old" NEW="$new" perl -0pi -e '
        BEGIN { $old = $ENV{"OLD"}; $new = $ENV{"NEW"}; }
        $count += s/\Q$old\E/$new/g;
        END { die "mutation anchor count=$count\n" unless $count == 1; }
    ' "$source_file"
    diff_file="$evidence_root/${ids[$index]}.diff"
    git -C "$mutation_worktree" diff -- "$source_path" >"$diff_file"
    diff_sha="$(sha256sum "$diff_file" | awk '{print $1}')"
    log="$evidence_root/${ids[$index]}.log"
    set +e
    (cd -- "$mutation_worktree" && eval "$test_command") >"$log" 2>&1
    exit_code=$?
    set -e
    kill_test=""
    if [[ "$exit_code" -eq 0 ]]; then
        status=SURVIVED
        survived=$((survived + 1))
    elif grep -Eq 'error: the following command failed with [0-9]+ compilation errors|error: failed to compile|error\[E[0-9]+\]' "$log"; then
        status=UNVIABLE
        unviable=$((unviable + 1))
    else
        kill_test="$(grep -Em1 '(^[0-9]+/[0-9]+ .*\.(test\.)?.*\.(FAIL|ERROR)|^test .* \.\.\. FAILED$|^error: test command failed|^failed command:)' "$log" || true)"
        if [[ -n "$kill_test" ]]; then
            status=KILLED
            killed=$((killed + 1))
        else
            status=UNVIABLE
            unviable=$((unviable + 1))
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${ids[$index]}" "$status" "$diff_sha" "$test_command" "$kill_test" >>"$manifest"
done
cp -- "$pristine_source" "$source_file"

total=${#ids[@]}
score="$(awk -v killed="$killed" -v total="$total" 'BEGIN { printf "%.2f", 100 * killed / total }')"
manifest_sha="$(sha256sum "$manifest" | awk '{print $1}')"
status=PASS
awk -v value="$score" 'BEGIN { exit !(value >= 80.0) }' || status=FAIL
[[ "$survived" -eq 0 && "$unviable" -eq 0 ]] || status=FAIL

report="$evidence_root/mutation.report"
cat >"$report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_COMMAND=tools/phase-mutation.sh --candidate-sha $candidate_sha --evidence-root $evidence_root
PHASE3_MUTATION_STATUS=$status
PHASE3_MUTATION_SCORE_PERCENT=$score
PHASE3_MUTATION_TOTAL=$total
PHASE3_MUTATION_KILLED=$killed
PHASE3_MUTATION_SURVIVED=$survived
PHASE3_MUTATION_UNVIABLE=$unviable
PHASE3_CRITICAL_SURVIVORS=$survived
PHASE3_MUTATION_MANIFEST_SHA256=$manifest_sha
PHASE3_MUTATION_MANIFEST=$manifest
EOF

printf 'PHASE3_MUTATION_REPORT=%s\n' "$report"
printf 'PHASE3_MUTATION_MANIFEST=%s\n' "$manifest"
printf 'PHASE3_MUTATION_STATUS=%s\n' "$status"
[[ "$status" == PASS ]]
