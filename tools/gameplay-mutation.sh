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

# 只对冻结清单中的 Gameplay/Phase critical 函数做变异；lib.rs 其它通用 FFI 包装器不属于本门禁。
critical_pattern='strict_overlap|active_contacts|contact_events|contact_transitions|submit_contact_transitions|submit_trusted_gameplay_events_with|mask_contains|source_key_is_live|append_contact_transition|step_plan|step_result|outcome_value|prepare_gameplay_state|begin_gameplay_fixed|plan_gameplay_positions|commit_gameplay_fixed|publish_gameplay_snapshot|validate_outcome_buffer|apply_positions|valid_output_array|query_gameplay_interface|begin_phase_impl|begin_phase_v1|begin_phase_v2|submit_events|validate_event'
mutation_root="$evidence_root/mutants"
(cd -- "$repository_root" && cargo mutants --package kadath_runtime_core \
    --file modules/runtime_core/src/gameplay.rs \
    --file modules/runtime_core/src/lib.rs \
    --file modules/runtime_core/src/phase_commit.rs \
    --re "$critical_pattern" \
    --timeout 120 --output "$mutation_root") >"$evidence_root/mutation-command.log" 2>&1 || true
outcomes=$(find "$mutation_root" -name outcomes.json -type f -print -quit)
[[ -n "$outcomes" && -f "$outcomes" ]] || block 'cargo-mutants outcomes missing'

total=$(jq '[.outcomes[] | select(.scenario != "Baseline")] | length' "$outcomes")
killed=$(jq '[.outcomes[] | select(.scenario != "Baseline" and .summary == "CaughtMutant")] | length' "$outcomes")
survived=$(jq '[.outcomes[] | select(.scenario != "Baseline" and .summary == "MissedMutant")] | length' "$outcomes")
unviable=$(jq '[.outcomes[] | select(.scenario != "Baseline" and .summary == "Unviable")] | length' "$outcomes")
unclassified=$((total - killed - survived - unviable))
critical_survivors=$(jq --arg pattern "$critical_pattern" '[.outcomes[] | select(
    .scenario != "Baseline" and
    .summary == "MissedMutant" and
    ((.scenario.Mutant.function.function_name // "") | test($pattern))
)] | length' "$outcomes")
[[ "$total" -gt 0 ]] || block 'no mutants generated'
score=$(awk -v killed="$killed" -v total="$total" 'BEGIN { printf "%.2f", killed * 100 / total }')

status=PASS
blockers=()
[[ "$unviable" -eq 0 ]] || { status=FAIL; blockers+=("unviable mutants require audit"); }
[[ "$unclassified" -eq 0 ]] || { status=FAIL; blockers+=("timeout or unclassified mutants require audit"); }
awk -v score="$score" 'BEGIN { exit !(score+0 >= 80) }' || { status=FAIL; blockers+=("mutation score below 80%"); }
[[ "$survived" -eq 0 ]] || { status=FAIL; blockers+=("surviving Gameplay mutants present"); }
[[ "$critical_survivors" -eq 0 ]] || { status=FAIL; blockers+=("critical invariant mutants survived"); }

manifest="$evidence_root/mutation-manifest.tsv"
printf 'domain\tfile\tfunction\tstatus\tmutant\tlog\n' >"$manifest"
jq -r '.outcomes[] | select(.scenario != "Baseline") |
    (.scenario.Mutant // {}) as $m |
    ($m.function.function_name // "unknown") as $fn |
    (if ($fn | test("strict_overlap|active_contacts|contact_events|contact_transitions|submit_contact_transitions|submit_trusted_gameplay_events_with|mask_contains")) then "contact_differencing"
     elif ($fn | test("prepare_gameplay_state|begin_gameplay_fixed|plan_gameplay_positions|commit_gameplay_fixed|step_plan|step_result")) then "timer_priority"
     elif ($fn | test("source_key_is_live|validate_outcome_buffer|read_object_key|object_view")) then "epoch_stale"
     elif ($fn | test("append_contact_transition|valid_output_array|apply_positions|validate_outcome_buffer")) then "capacity"
     elif ($fn | test("publish_gameplay_snapshot|gameplay_snapshot|snapshot")) then "snapshot_publication"
     elif ($fn | test("outcome_value|step_result|commit_gameplay_fixed")) then "outcome_sequence"
     elif ($fn | test("query_interface|query_gameplay_interface|begin_phase|submit_events|validate_")) then "abi_preflight"
     else "uncategorized" end) as $domain |
    [$domain, ($m.file // ""), $fn, (.summary // ""), ($m.name // ""), (.log_path // "")] | @tsv' \
    "$outcomes" >"$manifest"
critical_manifest="$evidence_root/mutation-critical-domains.tsv"
cat >"$critical_manifest" <<'EOF'
domain	files	functions
timer_priority	modules/runtime_core/src/gameplay.rs;modules/runtime_core/src/lib.rs	step_plan;step_result;prepare_gameplay_state;begin_gameplay_fixed;plan_gameplay_positions;commit_gameplay_fixed
contact_differencing	modules/runtime_core/src/gameplay.rs;modules/runtime_core/src/phase_commit.rs	strict_overlap;active_contacts;contact_events;contact_transitions;submit_contact_transitions;submit_trusted_gameplay_events_with;mask_contains
epoch_stale	modules/runtime_core/src/gameplay.rs;modules/runtime_core/src/lib.rs	source_key_is_live;validate_outcome_buffer;read_object_key;object_view
capacity	modules/runtime_core/src/gameplay.rs;modules/runtime_core/src/lib.rs	append_contact_transition;valid_output_array;apply_positions
snapshot_publication	modules/runtime_core/src/lib.rs	publish_gameplay_snapshot;gameplay_snapshot
outcome_sequence	modules/runtime_core/src/gameplay.rs;modules/runtime_core/src/lib.rs	outcome_value;step_result;commit_gameplay_fixed
abi_preflight	modules/runtime_core/src/phase_commit.rs;modules/runtime_core/src/lib.rs	query_interface;query_gameplay_interface;begin_phase_v1;begin_phase_v2;submit_events;validate_event
EOF

# 将 survivor/unviable 独立落盘，避免只凭总分判断而丢失逐项追踪证据。
# survivor 一律保守标记为待跟进；unviable 只确认 cargo-mutants 的编译不可行结论，
# 具体 rustc 诊断通过绑定的 log 路径复核，不能把它们误算成已杀死。
survivor_audit="$evidence_root/mutation-survivor-audit.tsv"
jq -r --arg pattern "$critical_pattern" '.outcomes[]
    | select(.scenario != "Baseline" and .summary == "MissedMutant")
    | (.scenario.Mutant // {}) as $m
    | ($m.function.function_name // "unknown") as $fn
    | (if ($fn | test("strict_overlap|active_contacts|contact_events|contact_transitions|submit_contact_transitions|submit_trusted_gameplay_events_with|mask_contains")) then "contact_differencing"
       elif ($fn | test("prepare_gameplay_state|begin_gameplay_fixed|plan_gameplay_positions|commit_gameplay_fixed|step_plan|step_result")) then "timer_priority"
       elif ($fn | test("source_key_is_live|validate_outcome_buffer|read_object_key|object_view")) then "epoch_stale"
       elif ($fn | test("append_contact_transition|valid_output_array|apply_positions|validate_outcome_buffer")) then "capacity"
       elif ($fn | test("publish_gameplay_snapshot|gameplay_snapshot|snapshot")) then "snapshot_publication"
       elif ($fn | test("outcome_value|step_result|commit_gameplay_fixed")) then "outcome_sequence"
       elif ($fn | test("query_interface|query_gameplay_interface|begin_phase|submit_events|validate_")) then "abi_preflight"
       else "uncategorized" end) as $domain
    | [$domain, ($m.file // ""), $fn, "SURVIVED", "requires_followup",
       "完整 cargo test 未杀死；需补充针对性回归或单独记录等价性依据",
       ($m.name // ""), (.log_path // "")] | @tsv' "$outcomes" \
    | { printf 'domain\tfile\tfunction\tstatus\taudit\trationale\tmutant\tlog\n'; cat; } >"$survivor_audit"

unviable_audit="$evidence_root/mutation-unviable-audit.tsv"
jq -r '.outcomes[]
    | select(.scenario != "Baseline" and .summary == "Unviable")
    | (.scenario.Mutant // {}) as $m
    | ($m.function.function_name // "unknown") as $fn
    | (if ($fn | test("strict_overlap|active_contacts|contact_events|contact_transitions|submit_contact_transitions|submit_trusted_gameplay_events_with|mask_contains")) then "contact_differencing"
       elif ($fn | test("prepare_gameplay_state|begin_gameplay_fixed|plan_gameplay_positions|commit_gameplay_fixed|step_plan|step_result")) then "timer_priority"
       elif ($fn | test("source_key_is_live|validate_outcome_buffer|read_object_key|object_view")) then "epoch_stale"
       elif ($fn | test("append_contact_transition|valid_output_array|apply_positions|validate_outcome_buffer")) then "capacity"
       elif ($fn | test("publish_gameplay_snapshot|gameplay_snapshot|snapshot")) then "snapshot_publication"
       elif ($fn | test("outcome_value|step_result|commit_gameplay_fixed")) then "outcome_sequence"
       elif ($fn | test("query_interface|query_gameplay_interface|begin_phase|submit_events|validate_")) then "abi_preflight"
       else "uncategorized" end) as $domain
    | [$domain, ($m.file // ""), $fn, "UNVIABLE", "compile_invalid",
       "cargo-mutants 标记为 Unviable；rustc 编译诊断保存在绑定日志中",
       ($m.name // ""), (.log_path // "")] | @tsv' "$outcomes" \
    | { printf 'domain\tfile\tfunction\tstatus\taudit\trationale\tmutant\tlog\n'; cat; } >"$unviable_audit"

report="$evidence_root/mutation.report"
cat >"$report" <<EOF
GAMEPLAY_MUTATION_STATUS=$status
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=cargo mutants --package kadath_runtime_core --file gameplay.rs --file lib.rs --file phase_commit.rs --re critical-domain-function-regex
GAMEPLAY_MUTATION_SCOPE=gameplay.rs,lib.rs,phase_commit.rs
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
GAMEPLAY_MUTATION_CRITICAL_MANIFEST=$critical_manifest
GAMEPLAY_MUTATION_CRITICAL_MANIFEST_SHA256=$(sha256sum "$critical_manifest" | awk '{print $1}')
GAMEPLAY_MUTATION_SURVIVOR_AUDIT=$survivor_audit
GAMEPLAY_MUTATION_SURVIVOR_AUDIT_SHA256=$(sha256sum "$survivor_audit" | awk '{print $1}')
GAMEPLAY_MUTATION_UNVIABLE_AUDIT=$unviable_audit
GAMEPLAY_MUTATION_UNVIABLE_AUDIT_SHA256=$(sha256sum "$unviable_audit" | awk '{print $1}')
GAMEPLAY_MUTATION_BLOCKER=$(IFS=';'; printf '%s' "${blockers[*]-}")
EOF
cat "$report"

# 报告必须先完整落盘并输出；只要门禁判定为 FAIL，脚本最终状态也必须非零。
[[ "$status" == PASS ]]
