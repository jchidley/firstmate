#!/usr/bin/env bash
# Behavior tests for the opt-in sequential task-quality contract.
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUALITY="$ROOT/bin/fm-task-quality.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-quality)

make_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  fm_git_worktree "$dir/repo" "$dir/worktree" "task-$name"
  printf '%s\n' "$dir|$dir/repo|$dir/worktree|$(git -C "$dir/worktree" rev-parse HEAD)"
}

write_contract() {
  local dir=$1 contract=$2 consequence=${3:-ordinary} baseline=${4:-'test -f README.md'} task_id
  local feature=${5:-'test -f feature.txt'} steps=${6:-10} ambiguous=${7:-false}
  local missing=${8:-false} decomposition=${9:-false} allowed=${10:-'feature.txt'}
  task_id=$(basename "$contract" .json)
  jq -n \
    --arg task_id "$task_id" \
    --arg root "$dir/repo" --arg worktree "$dir/worktree" \
    --arg base_sha "$(git -C "$dir/worktree" rev-parse HEAD)" \
    --arg consequence "$consequence" --arg baseline "$baseline" --arg feature "$feature" \
    --argjson steps "$steps" --argjson ambiguous "$ambiguous" \
    --argjson missing "$missing" --argjson decomposition "$decomposition" \
    --arg allowed "$allowed" \
    '{
      schema: "fm-task-quality-contract.v1",
      task_id: $task_id,
      delivery: "no-mistakes",
      intent: {
        requested_behavior: "Add the requested behavior without changing unrelated behavior.",
        non_goals: ["No unrelated cleanup."],
        constraints: ["Keep the public interface stable."]
      },
      repository: {root: $root, worktree: $worktree, base_sha: $base_sha},
      assessment: {
        ambiguous: $ambiguous,
        missing_information: (if $missing then ["a required product choice"] else [] end),
        decomposition_requested: $decomposition,
        consequence: $consequence
      },
      limits: {wall_seconds: 2, steps: $steps, spend: 0},
      allowed_paths: [$allowed],
      checks: [
        {id: "baseline", phase: "baseline", command: $baseline, mandatory: true, independent: false},
        {id: "feature", phase: "post-patch", command: $feature, mandatory: true, independent: true}
      ]
    }' > "$contract"
}

commit_feature() {
  local worktree=$1 path=$2 contents=$3
  printf '%s\n' "$contents" > "$worktree/$path"
  git -C "$worktree" add -- "$path"
  git -C "$worktree" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "add $path"
}

run_quality() {
  "$QUALITY" "$@"
}

assert_json() {
  local expression=$1 file=$2 message=$3
  jq -e "$expression" "$file" >/dev/null 2>&1 || fail "$message"
}

test_sequential_task_is_accepted_from_submitted_patch() {
  local dir repo worktree contract evidence out rc
  IFS='|' read -r dir repo worktree _ <<EOF
$(make_case accepted)
EOF
  contract="$dir/accepted.json"
  evidence="$dir/accepted-evidence.json"
  write_contract "$dir" "$contract"
  out=$(run_quality init "$contract" "$evidence")
  assert_contains "$out" "route=single-bounded-task" "init did not derive the bounded route"
  run_quality run-check "$evidence" baseline >/dev/null
  commit_feature "$worktree" feature.txt feature
  run_quality run-check "$evidence" feature >/dev/null
  run_quality assess-patch "$evidence" >/dev/null
  run_quality finalize "$evidence" >/dev/null
  assert_json '.disposition == "accepted" and .evidence.patch.files_changed == 1 and .evidence.patch.lines_added == 1 and (.evidence.patch.unexpected_scope == false)' "$evidence" \
    "green submitted patch did not produce an accepted evidence record"
  assert_json '.evidence.checks.baseline.status == "passed" and .evidence.checks.feature.independent == true' "$evidence" \
    "mandatory baseline or independent feature evidence was not retained"
  pass "task-quality: sequential contract, checks, patch assessment, and finalization"
}

test_primary_checkout_is_refused() {
  local dir repo worktree contract evidence out rc
  IFS='|' read -r dir repo worktree _ <<EOF
$(make_case primary)
EOF
  contract="$dir/primary.json"
  evidence="$dir/primary-evidence.json"
  write_contract "$dir" "$contract"
  jq --arg root "$repo" '.repository.root = $root | .repository.worktree = $root' "$contract" > "$contract.tmp"
  mv "$contract.tmp" "$contract"
  out=$(run_quality init "$contract" "$evidence" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "primary checkout was accepted"
  assert_contains "$out" "isolated copy" "primary checkout refusal did not explain the isolation boundary"
  assert_absent "$evidence" "refused primary checkout still wrote evidence"
  pass "task-quality: primary checkout cannot initialize a task"
}

test_missing_baseline_is_rejected_before_dispatch() {
  local dir contract evidence out rc
  IFS='|' read -r dir _ _ _ <<EOF
$(make_case no-baseline)
EOF
  contract="$dir/no-baseline.json"
  evidence="$dir/no-baseline-evidence.json"
  write_contract "$dir" "$contract"
  jq '.checks |= map(select(.phase != "baseline"))' "$contract" > "$contract.tmp"
  mv "$contract.tmp" "$contract"
  out=$(run_quality init "$contract" "$evidence" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "contract without a baseline was accepted"
  assert_contains "$out" "not valid" "missing baseline refusal did not identify the invalid contract"
  assert_absent "$evidence" "invalid contract without a baseline wrote evidence"
  pass "task-quality: baseline absence blocks initialization"
}

test_baseline_failure_blocks_follow_on_checks() {
  local dir contract evidence out rc
  IFS='|' read -r dir _ _ _ <<EOF
$(make_case baseline-fails)
EOF
  contract="$dir/baseline-fails.json"
  evidence="$dir/baseline-fails-evidence.json"
  write_contract "$dir" "$contract" ordinary 'false'
  run_quality init "$contract" "$evidence" >/dev/null
  out=$(run_quality run-check "$evidence" baseline 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "failing baseline returned success"
  assert_json '.evidence.checks.baseline.status == "failed" and .evidence.checks.baseline.exit_code != 0' "$evidence" \
    "baseline failure was not retained"
  out=$(run_quality run-check "$evidence" feature 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "post-patch check ran after a failed baseline"
  assert_contains "$out" "passing baseline" "post-patch refusal did not name the prerequisite"
  pass "task-quality: baseline failure blocks implementation checks"
}

test_easy_route_cannot_skip_mandatory_check() {
  local dir contract evidence out rc
  IFS='|' read -r dir _ worktree _ <<EOF
$(make_case mandatory)
EOF
  contract="$dir/mandatory.json"
  evidence="$dir/mandatory-evidence.json"
  write_contract "$dir" "$contract"
  run_quality init "$contract" "$evidence" >/dev/null
  run_quality run-check "$evidence" baseline >/dev/null
  commit_feature "$worktree" feature.txt feature
  run_quality assess-patch "$evidence" >/dev/null
  out=$(run_quality finalize "$evidence" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "finalize accepted a patch with a skipped mandatory check"
  assert_contains "$out" "mandatory check evidence" "missing mandatory check was not reported"
  assert_json '.disposition == "needs-human" and .status == "blocked"' "$evidence" \
    "missing mandatory evidence did not produce a blocked disposition"
  pass "task-quality: easy-looking tasks cannot skip mandatory checks"
}

test_worker_acceptance_cannot_authorize_success() {
  local dir contract evidence worktree out rc
  IFS='|' read -r dir _ worktree _ <<EOF
$(make_case worker-acceptance)
EOF
  contract="$dir/worker-acceptance.json"
  evidence="$dir/worker-acceptance-evidence.json"
  write_contract "$dir" "$contract"
  run_quality init "$contract" "$evidence" >/dev/null
  run_quality run-check "$evidence" baseline >/dev/null
  commit_feature "$worktree" feature.txt feature
  run_quality run-check "$evidence" feature >/dev/null
  run_quality assess-patch "$evidence" >/dev/null
  jq '.worker_acceptance = "accepted"' "$evidence" > "$evidence.tmp"
  mv "$evidence.tmp" "$evidence"
  out=$(run_quality finalize "$evidence" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "worker-authored acceptance authorized completion"
  assert_contains "$out" "worker-authored acceptance" "self-authored acceptance was not refused"
  pass "task-quality: worker acceptance is advisory and cannot authorize itself"
}

test_unexpected_scope_escalates_after_green_checks() {
  local dir contract evidence worktree out rc
  IFS='|' read -r dir _ worktree _ <<EOF
$(make_case unexpected)
EOF
  contract="$dir/unexpected.json"
  evidence="$dir/unexpected-evidence.json"
  write_contract "$dir" "$contract"
  run_quality init "$contract" "$evidence" >/dev/null
  run_quality run-check "$evidence" baseline >/dev/null
  commit_feature "$worktree" feature.txt feature
  commit_feature "$worktree" unrelated.txt unrelated
  run_quality run-check "$evidence" feature >/dev/null
  run_quality assess-patch "$evidence" >/dev/null
  out=$(run_quality finalize "$evidence" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unexpected patch scope was accepted"
  assert_contains "$out" "unexpected scope" "unexpected scope escalation was not explained"
  assert_json '.disposition == "needs-human" and .evidence.patch.unexpected_scope == true' "$evidence" \
    "unexpected scope did not remain visible after green checks"
  pass "task-quality: unexpected submitted scope escalates after green checks"
}

test_material_consequence_escalates_after_green_checks() {
  local dir contract evidence worktree out rc
  IFS='|' read -r dir _ worktree _ <<EOF
$(make_case material)
EOF
  contract="$dir/material.json"
  evidence="$dir/material-evidence.json"
  write_contract "$dir" "$contract" material
  run_quality init "$contract" "$evidence" >/dev/null
  run_quality run-check "$evidence" baseline >/dev/null
  commit_feature "$worktree" feature.txt feature
  run_quality run-check "$evidence" feature >/dev/null
  run_quality assess-patch "$evidence" >/dev/null
  out=$(run_quality finalize "$evidence" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "material consequence was accepted without human approval"
  assert_contains "$out" "material-consequence" "material consequence escalation was not explained"
  pass "task-quality: material consequence overrides green automation"
}

test_post_patch_evidence_must_be_fresh() {
  local dir contract evidence worktree out rc
  IFS='|' read -r dir _ worktree _ <<EOF
$(make_case stale)
EOF
  contract="$dir/stale.json"
  evidence="$dir/stale-evidence.json"
  write_contract "$dir" "$contract"
  run_quality init "$contract" "$evidence" >/dev/null
  run_quality run-check "$evidence" baseline >/dev/null
  commit_feature "$worktree" feature.txt feature
  run_quality run-check "$evidence" feature >/dev/null
  run_quality assess-patch "$evidence" >/dev/null
  commit_feature "$worktree" later.txt later
  out=$(run_quality finalize "$evidence" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "stale patch evidence was accepted"
  assert_contains "$out" "evidence is stale" "stale evidence refusal was not explained"
  pass "task-quality: changing the submitted head invalidates old evidence"
}

test_budget_stop_preserves_evidence() {
  local dir contract evidence out rc
  IFS='|' read -r dir _ _ _ <<EOF
$(make_case budget)
EOF
  contract="$dir/budget.json"
  evidence="$dir/budget-evidence.json"
  write_contract "$dir" "$contract" ordinary 'test -f README.md' 'test -f feature.txt' 1
  run_quality init "$contract" "$evidence" >/dev/null
  run_quality run-check "$evidence" baseline >/dev/null
  out=$(run_quality run-check "$evidence" feature 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "budget stop returned $rc instead of its bounded-stop code"
  assert_contains "$out" "execution step limit" "budget stop did not explain the bound"
  assert_json '.status == "blocked" and .disposition == "needs-human" and (.evidence.events | map(select(.event == "budget-stop")) | length == 1)' "$evidence" \
    "budget stop did not preserve a durable evidence event"
  pass "task-quality: step budget stops execution while preserving evidence"
}

test_timeout_preserves_check_result() {
  local dir contract evidence out rc
  IFS='|' read -r dir _ _ _ <<EOF
$(make_case timeout)
EOF
  contract="$dir/timeout.json"
  evidence="$dir/timeout-evidence.json"
  write_contract "$dir" "$contract" ordinary 'sleep 5' 'test -f feature.txt'
  run_quality init "$contract" "$evidence" >/dev/null
  out=$(run_quality run-check "$evidence" baseline 2>&1); rc=$?
  [ "$rc" -eq 124 ] || fail "timeout returned $rc instead of 124"
  assert_json '.evidence.checks.baseline.status == "timed-out" and .evidence.checks.baseline.exit_code == 124' "$evidence" \
    "timeout did not preserve the bounded check result"
  pass "task-quality: wall bound records a timed-out check"
}

test_routes_and_rejects_leakage_fields() {
  local dir contract evidence out rc
  IFS='|' read -r dir _ _ _ <<EOF
$(make_case routing)
EOF
  contract="$dir/routing.json"
  evidence="$dir/routing-evidence.json"
  write_contract "$dir" "$contract" ordinary 'test -f README.md' 'test -f feature.txt' 10 true
  run_quality init "$contract" "$evidence" >/dev/null
  assert_json '.route == "clarify" and .status == "needs-human"' "$evidence" \
    "ambiguous input did not route to clarification"
  out=$(run_quality run-check "$evidence" baseline 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "clarification route ran a check"
  assert_contains "$out" "route=clarify" "clarification route refusal was not explained"

  local leaked="$dir/leaked.json"
  write_contract "$dir" "$leaked"
  jq '.gold_patch = "never operational"' "$leaked" > "$leaked.tmp"
  mv "$leaked.tmp" "$leaked"
  out=$(run_quality init "$leaked" "$dir/leaked-evidence.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "gold-patch field was accepted as operational input"
  assert_contains "$out" "forbidden" "gold-patch refusal did not name the leakage boundary"
  pass "task-quality: ambiguity routes to humans and gold-patch inputs are refused"
}

test_decomposition_requires_independent_children_and_integration() {
  local dir contract evidence out rc
  IFS='|' read -r dir _ _ _ <<EOF
$(make_case decomposition)
EOF
  contract="$dir/decomposition.json"
  evidence="$dir/decomposition-evidence.json"
  write_contract "$dir" "$contract" ordinary 'test -f README.md' 'test -f feature.txt' 10 false false true
  jq '.decomposition = {children: ["missing-child"]}' "$contract" > "$contract.tmp"
  mv "$contract.tmp" "$contract"
  run_quality init "$contract" "$evidence" >/dev/null
  assert_json '.route == "human-approved-decomposition" and .status == "needs-human"' "$evidence" \
    "decomposition request did not route to human approval"
  out=$(run_quality run-check "$evidence" feature 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "decomposition route ran a non-integration check"
  assert_contains "$out" "human-approved decomposition" "decomposition refusal was not explained"
  pass "task-quality: decomposition cannot proceed without human-approved child and integration evidence"
}

test_sequential_task_is_accepted_from_submitted_patch
test_primary_checkout_is_refused
test_missing_baseline_is_rejected_before_dispatch
test_baseline_failure_blocks_follow_on_checks
test_easy_route_cannot_skip_mandatory_check
test_worker_acceptance_cannot_authorize_success
test_unexpected_scope_escalates_after_green_checks
test_material_consequence_escalates_after_green_checks
test_post_patch_evidence_must_be_fresh
test_budget_stop_preserves_evidence
test_timeout_preserves_check_result
test_routes_and_rejects_leakage_fields
test_decomposition_requires_independent_children_and_integration

echo "# all fm-task-quality tests passed"
