#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are literal filters and intentionally use $ variables.
# fm-task-quality.sh - owns the opt-in sequential task-quality contract and evidence record.
#
# The operator supplies a JSON contract, this script derives the pre-task route,
# runs bounded baseline/check commands, measures only the submitted patch, and
# refuses success when evidence is incomplete, stale, unexpected, or consequential.
# Worker text is advisory: it cannot change the contract or authorize acceptance.
# The caller remains responsible for launching workers through fm-spawn.sh and
# for handing accepted work to no-mistakes, whose validation and publication
# contract this script does not duplicate.
#
# Usage:
#   fm-task-quality.sh init <contract.json> <evidence.json>
#   fm-task-quality.sh run-check <evidence.json> <check-id>
#   fm-task-quality.sh assess-patch <evidence.json>
#   fm-task-quality.sh validate-decomposition <parent.json> <child.json>...
#   fm-task-quality.sh finalize <evidence.json>
#   fm-task-quality.sh --help
#
# Contract schema: fm-task-quality-contract.v1.
# Evidence schema: fm-task-quality-evidence.v1.
# Commands in a contract are operator-authored shell strings and execute in the
# contract worktree; they are not model-selected commands or hidden evaluators.
# A baseline command must pass on a clean worktree at the recorded base SHA.
# Every mandatory check must be run before a normal task can be accepted.
# Material consequence and unexpected submitted scope always produce needs-human.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck disable=SC1091
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-task-quality: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is not installed: $1"
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

absolute_file() {
  local path=$1 dir base
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *)
      dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || die "cannot resolve directory for $path"
      base=$(basename "$path")
      printf '%s/%s\n' "$dir" "$base"
      ;;
  esac
}

absolute_directory() {
  local path=$1
  if ! CDPATH='' cd -- "$path" 2>/dev/null; then
    die "cannot resolve directory: $path"
  fi
  pwd -P
}

atomic_jq() {
  local path=$1
  shift
  local tmp
  tmp=$(mktemp "${path}.tmp.XXXXXX") || die "cannot create temporary evidence file"
  if ! jq "$@" "$path" >"$tmp"; then
    rm -f "$tmp"
    die "cannot update evidence record: $path"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$path"
}

contract_has_forbidden_key() {
  jq -e '
    [paths | .[-1] | select(type == "string" and
      test("^(gold|reference|benchmark|hidden|evaluator)(_|$)|^worker_acceptance$"))]
    | length == 0
  ' "$1" >/dev/null 2>&1
}

validate_contract() {
  local contract=$1
  [ -f "$contract" ] || die "contract does not exist: $contract"
  jq -e '
    type == "object"
    and .schema == "fm-task-quality-contract.v1"
    and (.task_id | type == "string" and length > 0)
    and .delivery == "no-mistakes"
    and (.intent | type == "object")
    and (.intent.requested_behavior | type == "string" and length > 0)
    and (.intent.non_goals | type == "array")
    and (.intent.constraints | type == "array")
    and (.repository | type == "object")
    and (.repository.root | type == "string" and startswith("/") and length > 1)
    and (.repository.worktree | type == "string" and startswith("/") and length > 1)
    and (.repository.base_sha | type == "string" and test("^[0-9a-fA-F]{40}$"))
    and (.assessment | type == "object")
    and (.assessment.ambiguous | type == "boolean")
    and (.assessment.missing_information | type == "array")
    and (.assessment.decomposition_requested | type == "boolean")
    and (.assessment.consequence | IN("ordinary", "elevated", "material"))
    and (.limits | type == "object")
    and (.limits.wall_seconds | type == "number" and floor == . and . > 0)
    and (.limits.steps | type == "number" and floor == . and . > 0)
    and (.limits.spend | type == "number" and . >= 0)
    and (.allowed_paths | type == "array" and all(.[]; type == "string" and length > 0))
    and (.checks | type == "array" and length > 0)
    and ([.checks[] | select(type != "object"
      or (.id | type != "string" or length == 0)
      or (.phase | IN("baseline", "post-patch", "integration") | not)
      or (.command | type != "string" or length == 0)
      or (.mandatory | type != "boolean")
      or (.independent | type != "boolean"))] | length == 0)
    and ([.checks[].id] | length == (unique | length))
    and ([.checks[] | select(.phase == "baseline" and .mandatory == true)] | length == 1)
    and ([.checks[] | select(.phase == "post-patch" and .mandatory == true)] | length > 0)
    and ([.checks[] | select(.phase == "post-patch" and .mandatory == true and .independent == true)] | length > 0)
  ' "$contract" >/dev/null 2>&1 || die "contract is not valid fm-task-quality-contract.v1: $contract"
  contract_has_forbidden_key "$contract" || die "contract contains a forbidden gold, benchmark, hidden-evaluator, or worker-acceptance field"
}

resolve_git_path() {
  local worktree=$1 value=$2
  value=$(git -C "$worktree" rev-parse "$value") || return 1
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *) (cd "$worktree/$value" && pwd -P) ;;
  esac
}

verify_isolated_worktree() {
  local root=$1 worktree=$2 root_top worktree_top git_dir common_dir
  root=$(absolute_directory "$root")
  worktree=$(absolute_directory "$worktree")
  root_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) \
    || die "repository.root is not a Git checkout: $root"
  worktree_top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) \
    || die "repository.worktree is not a Git checkout: $worktree"
  root_top=$(absolute_directory "$root_top")
  worktree_top=$(absolute_directory "$worktree_top")
  [ "$root_top" = "$root" ] || die "repository.root is not the checkout root: $root"
  [ "$worktree_top" != "$root" ] || die "repository.worktree must be an isolated copy, not the primary checkout"
  git_dir=$(resolve_git_path "$worktree" --git-dir) || die "cannot resolve the worktree Git directory"
  common_dir=$(resolve_git_path "$worktree" --git-common-dir) || die "cannot resolve the worktree common Git directory"
  [ "$git_dir" != "$common_dir" ] || die "repository.worktree resolves to the repository primary checkout"
  printf '%s\n' "$worktree_top"
}

assert_clean() {
  local worktree=$1 changes
  changes=$(git -C "$worktree" status --porcelain --untracked-files=all) || die "cannot inspect worktree: $worktree"
  [ -z "$changes" ] || die "worktree must be clean before this operation: $worktree"
}

load_record() {
  RECORD=$1
  [ -f "$RECORD" ] || die "evidence record does not exist: $RECORD"
  jq -e 'type == "object" and .schema == "fm-task-quality-evidence.v1"' "$RECORD" >/dev/null 2>&1 \
    || die "invalid evidence record: $RECORD"
  CONTRACT_PATH=$(jq -er '.contract_path' "$RECORD") || die "evidence record has no contract path"
  CONTRACT_SHA=$(jq -er '.contract_sha256' "$RECORD") || die "evidence record has no contract digest"
  [ -f "$CONTRACT_PATH" ] || die "contract no longer exists: $CONTRACT_PATH"
  [ "$(hash_file "$CONTRACT_PATH")" = "$CONTRACT_SHA" ] \
    || die "contract changed after initialization; evidence is stale"
  validate_contract "$CONTRACT_PATH"
  ROOT=$(jq -er '.contract.repository.root' "$RECORD")
  WORKTREE=$(jq -er '.contract.repository.worktree' "$RECORD")
  BASE_SHA=$(jq -er '.contract.repository.base_sha' "$RECORD")
  verify_isolated_worktree "$ROOT" "$WORKTREE" >/dev/null
}

record_route() {
  local contract=$1
  jq -r '
    if .assessment.ambiguous or (.assessment.missing_information | length > 0)
    then "clarify"
    elif .assessment.decomposition_requested
    then "human-approved-decomposition"
    else "single-bounded-task"
    end
  ' "$contract"
}

init_record() {
  local contract=$1 record=$2 route contract_json root worktree base head
  validate_contract "$contract"
  contract=$(absolute_file "$contract")
  record=$(absolute_file "$record")
  [ "$contract" != "$record" ] || die "contract and evidence record must be different files"
  root=$(jq -er '.repository.root' "$contract")
  worktree=$(jq -er '.repository.worktree' "$contract")
  root=$(absolute_directory "$root")
  worktree=$(absolute_directory "$worktree")
  verify_isolated_worktree "$root" "$worktree" >/dev/null
  assert_clean "$worktree"
  base=$(jq -er '.repository.base_sha' "$contract")
  head=$(git -C "$worktree" rev-parse HEAD) || die "cannot read worktree HEAD"
  [ "$head" = "$base" ] || die "worktree HEAD $head is not the contract base SHA $base"
  [ ! -e "$record" ] || die "refusing to overwrite evidence record: $record"
  route=$(record_route "$contract")
  contract_json=$(jq -c . "$contract")
  umask 077
  jq -n \
    --arg task_id "$(jq -er '.task_id' "$contract")" \
    --arg contract_path "$contract" \
    --arg contract_sha256 "$(hash_file "$contract")" \
    --arg route "$route" \
    --arg root "$root" \
    --arg worktree "$worktree" \
    --arg base_sha "$base" \
    --argjson contract "$contract_json" \
    '{
      schema: "fm-task-quality-evidence.v1",
      task_id: $task_id,
      contract_path: $contract_path,
      contract_sha256: $contract_sha256,
      contract: $contract,
      route: $route,
      repository: {root: $root, worktree: $worktree, base_sha: $base_sha, head_sha: $base_sha},
      status: (if $route == "single-bounded-task" then "baseline-required" else "needs-human" end),
      disposition: null,
      reason: null,
      evidence: {
        initialized_at: (now | floor | tostring),
        steps: 0,
        checks: {},
        patch: null,
        decomposition: {validated: false, children: []},
        events: [{event: "initialized", route: $route}]
      }
    }' >"$record" || die "cannot write evidence record: $record"
  chmod 600 "$record"
  printf 'initialized %s route=%s\n' "$record" "$route"
}

check_json() {
  local id=$1
  jq -ce --arg id "$id" '.contract.checks[] | select(.id == $id)' "$RECORD" 2>/dev/null \
    || die "unknown check id: $id"
}

set_budget_stop() {
  local reason=$1
  atomic_jq "$RECORD" --arg reason "$reason" \
    '.status = "blocked" | .disposition = "needs-human" | .reason = $reason
     | .evidence.events += [{event: "budget-stop", reason: $reason}]'
}

run_check() {
  local id=$1 check phase command mandatory independent baseline_passed steps_limit wall_seconds
  check=$(check_json "$id")
  phase=$(printf '%s\n' "$check" | jq -er '.phase')
  command=$(printf '%s\n' "$check" | jq -er '.command')
  mandatory=$(printf '%s\n' "$check" | jq -r '.mandatory')
  independent=$(printf '%s\n' "$check" | jq -r '.independent')
  steps_limit=$(jq -er '.contract.limits.steps' "$RECORD")
  wall_seconds=$(jq -er '.contract.limits.wall_seconds' "$RECORD")
  jq -e --arg id "$id" '.evidence.checks[$id] == null' "$RECORD" >/dev/null \
    || die "check already has evidence: $id"
  case "$RECORD" in */*) ;; *) die "evidence path must include a directory" ;; esac
  if [ "$(jq -er '.route' "$RECORD")" = clarify ]; then
    die "route=clarify requires human input before checks can run"
  fi
  if [ "$(jq -er '.route' "$RECORD")" != single-bounded-task ] && [ "$phase" != integration ]; then
    die "route requires human-approved decomposition before non-integration checks"
  fi
  steps=$(jq -er '.evidence.steps' "$RECORD")
  if [ "$steps" -ge "$steps_limit" ]; then
    set_budget_stop "execution step limit exceeded before check $id"
    printf 'execution step limit exceeded before check %s\n' "$id" >&2
    return 2
  fi
  if [ "$phase" = baseline ]; then
    head=$(git -C "$WORKTREE" rev-parse HEAD) || die "cannot read worktree HEAD"
    [ "$head" = "$BASE_SHA" ] || die "baseline must run at the recorded base SHA"
    assert_clean "$WORKTREE"
  else
    baseline_passed=$(jq -e '
      any(.evidence.checks[]?; .phase == "baseline" and .exit_code == 0 and .status == "passed")
    ' "$RECORD" >/dev/null 2>&1 && printf true || printf false)
    [ "$baseline_passed" = true ] || die "a passing baseline is required before post-patch checks"
    head=$(git -C "$WORKTREE" rev-parse HEAD) || die "cannot read worktree HEAD"
    [ "$head" != "$BASE_SHA" ] || die "post-patch checks require a submitted commit beyond the base SHA"
    assert_clean "$WORKTREE"
  fi
  local output rc started finished tmp post_head post_changes
  tmp=$(mktemp "${RECORD}.check.XXXXXX") || die "cannot create check output file"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  set +e
  (cd "$WORKTREE" && fm_run_timed "$wall_seconds" bash -c "$command") >"$tmp" 2>&1
  rc=$?
  set -e
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  output=$(<"$tmp")
  rm -f "$tmp"
  if [ "$phase" = baseline ]; then
    post_head=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || printf '')
    post_changes=$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>/dev/null || printf '')
    if [ "$rc" -eq 0 ] && { [ "$post_head" != "$BASE_SHA" ] || [ -n "$post_changes" ]; }; then
      rc=1
      output="${output}${output:+$'\\n'}baseline command changed the worktree"
    fi
  fi
  [ "$rc" -eq 0 ] && status=passed || status=failed
  [ "$rc" -eq 124 ] && status=timed-out
  atomic_jq "$RECORD" \
    --arg id "$id" --arg phase "$phase" --arg command "$command" \
    --arg mandatory "$mandatory" --arg independent "$independent" \
    --arg started "$started" --arg finished "$finished" --arg status "$status" \
    --arg output "$output" --argjson rc "$rc" --arg head "$(git -C "$WORKTREE" rev-parse HEAD)" \
    '.evidence.checks[$id] = {
      phase: $phase, command: $command, mandatory: ($mandatory == "true"),
      independent: ($independent == "true"), started_at: $started, finished_at: $finished,
      head_sha: $head, exit_code: $rc, status: $status, output: $output
    }
    | .evidence.steps += 1
    | .status = (if $status == "passed" then "checks-in-progress" else "checks-failed" end)
    | .evidence.events += [{event: "check", id: $id, status: $status, exit_code: $rc}]'
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  printf 'check %s passed\n' "$id"
}

assess_patch() {
  local head paths paths_json added deleted files allowed unexpected
  jq -e '
    any(.evidence.checks[]?; .phase == "baseline" and .exit_code == 0 and .status == "passed")
  ' "$RECORD" >/dev/null 2>&1 || die "a passing baseline is required before patch assessment"
  assert_clean "$WORKTREE"
  head=$(git -C "$WORKTREE" rev-parse HEAD) || die "cannot read submitted HEAD"
  [ "$head" != "$BASE_SHA" ] || die "submitted patch must contain a commit beyond the base SHA"
  paths=$(git -C "$WORKTREE" diff --name-only "$BASE_SHA..$head") || die "cannot inspect submitted patch"
  [ -n "$paths" ] || die "submitted patch has no changed paths"
  paths_json=$(printf '%s\n' "$paths" | jq -R -s 'split("\n") | map(select(length > 0))')
  allowed=$(jq -c '.contract.allowed_paths' "$RECORD")
  unexpected=$(jq -cn --argjson paths "$paths_json" --argjson allowed "$allowed" '
    [$paths[] as $p
      | select((reduce $allowed[] as $a (false; . or ($p == $a or ($p | startswith($a + "/"))))) | not)
      | $p] | unique
  ')
  added=$(git -C "$WORKTREE" diff --numstat "$BASE_SHA..$head" | awk -F '\t' '{if ($1 ~ /^[0-9]+$/) a += $1; if ($2 ~ /^[0-9]+$/) d += $2} END {print a + 0}')
  deleted=$(git -C "$WORKTREE" diff --numstat "$BASE_SHA..$head" | awk -F '\t' '{if ($2 ~ /^[0-9]+$/) d += $2} END {print d + 0}')
  files=$(printf '%s\n' "$paths" | awk 'NF {n += 1} END {print n + 0}')
  atomic_jq "$RECORD" \
    --arg head "$head" --argjson paths "$paths_json" --argjson unexpected "$unexpected" \
    --argjson files "$files" --argjson added "$added" --argjson deleted "$deleted" \
    '.repository.head_sha = $head
     | .evidence.patch = {
         base_sha: .repository.base_sha, head_sha: $head, files_changed: $files,
         lines_added: $added, lines_deleted: $deleted, paths: $paths,
         unexpected_paths: $unexpected, unexpected_scope: ($unexpected | length > 0)
       }
     | .status = "patch-assessed"
     | .evidence.events += [{event: "patch-assessed", head_sha: $head}]'
  printf 'patch assessed files=%s added=%s deleted=%s\n' "$files" "$added" "$deleted"
}

validate_child_record() {
  local child=$1 parent_id=$2 child_parent child_status
  jq -e 'type == "object" and .schema == "fm-task-quality-evidence.v1"' "$child" >/dev/null 2>&1 \
    || die "invalid child evidence record: $child"
  child_parent=$(jq -er '.contract.decomposition.parent_task_id // empty' "$child") \
    || die "child has no parent_task_id: $child"
  [ "$child_parent" = "$parent_id" ] || die "child parent_task_id does not match: $child"
  child_status=$(jq -er '.disposition' "$child") || die "child has no disposition: $child"
  [ "$child_status" = accepted ] || die "child is not independently accepted: $child"
  jq -e '.evidence.patch != null and (.evidence.patch.unexpected_scope == false)' "$child" >/dev/null 2>&1 \
    || die "child has no clean submitted-patch assessment: $child"
  jq -e '
    . as $root
    | all($root.contract.checks[] | select(.mandatory == true) | .id;
        . as $id | $root.evidence.checks[$id].status == "passed")
  ' "$child" >/dev/null 2>&1 || die "child has incomplete mandatory evidence: $child"
}

validate_decomposition() {
  local parent_id route child children_json child_ids
  route=$(jq -er '.route' "$RECORD")
  [ "$route" = human-approved-decomposition ] || die "decomposition validation requires route=human-approved-decomposition"
  parent_id=$(jq -er '.task_id' "$RECORD")
  [ "$#" -gt 0 ] || die "at least one independently accepted child is required"
  child_ids='[]'
  for child in "$@"; do
    [ -f "$child" ] || die "child evidence record does not exist: $child"
    validate_child_record "$child" "$parent_id"
    child_ids=$(jq -cn --argjson ids "$child_ids" --arg id "$(jq -er '.task_id' "$child")" '$ids + [$id]')
  done
  children_json=$(jq -c '.contract.decomposition.children // []' "$RECORD")
  jq -e --argjson ids "$child_ids" --argjson listed "$children_json" 'all($ids[]; . as $id | ($listed | index($id)) != null)' \
    >/dev/null 2>&1 || die "parent contract does not list every child"
  jq -e '
    any(.contract.checks[]; .phase == "integration" and .mandatory == true)
    and any(.evidence.checks[]?; .phase == "integration" and .status == "passed" and .exit_code == 0)
  ' "$RECORD" >/dev/null 2>&1 || die "parent integration evidence is missing or has not passed"
  atomic_jq "$RECORD" --argjson children "$child_ids" \
    '.evidence.decomposition = {validated: true, children: $children}
     | .evidence.events += [{event: "decomposition-validated", children: $children}]'
  printf 'decomposition validated children=%s\n' "$(printf '%s' "$child_ids" | jq -c '.')"
}

finalize_record() {
  local route missing reason patch_head current_head consequence unexpected worker_acceptance
  jq -e '.evidence.patch != null' "$RECORD" >/dev/null 2>&1 || {
    atomic_jq "$RECORD" --arg reason "submitted patch assessment is missing" \
      '.status = "blocked" | .disposition = "needs-human" | .reason = $reason'
    die "submitted patch assessment is missing"
  }
  patch_head=$(jq -er '.evidence.patch.head_sha' "$RECORD")
  current_head=$(git -C "$WORKTREE" rev-parse HEAD) || die "cannot read current worktree HEAD"
  [ "$current_head" = "$patch_head" ] || {
    atomic_jq "$RECORD" --arg reason "evidence is stale: submitted HEAD changed after assessment" \
      '.status = "blocked" | .disposition = "needs-human" | .reason = $reason'
    die "evidence is stale: submitted HEAD changed after assessment"
  }
  worker_acceptance=$(jq -e 'has("worker_acceptance")' "$RECORD" >/dev/null 2>&1 && printf true || printf false)
  [ "$worker_acceptance" = false ] || {
    atomic_jq "$RECORD" --arg reason "worker-authored acceptance cannot authorize completion" \
      '.status = "blocked" | .disposition = "needs-human" | .reason = $reason'
    die "worker-authored acceptance cannot authorize completion"
  }
  missing=$(jq -r '
    . as $root
    | [$root.contract.checks[] | select(.mandatory == true) | .id as $id
      | select(($root.evidence.checks[$id].status // "missing") != "passed") | $id]
    | join(",")
  ' "$RECORD")
  if [ -n "$missing" ]; then
    reason="mandatory check evidence is incomplete or failed: $missing"
    atomic_jq "$RECORD" --arg reason "$reason" \
      '.status = "blocked" | .disposition = "needs-human" | .reason = $reason
       | .evidence.events += [{event: "finalize-blocked", reason: $reason}]'
    die "$reason"
  fi
  unexpected=$(jq -e '.evidence.patch.unexpected_scope == true' "$RECORD" >/dev/null 2>&1 && printf true || printf false)
  consequence=$(jq -er '.contract.assessment.consequence' "$RECORD")
  route=$(jq -er '.route' "$RECORD")
  if [ "$unexpected" = true ]; then
    reason="submitted patch crosses an unexpected scope boundary"
  elif [ "$consequence" = material ]; then
    reason="material-consequence work requires human approval after green checks"
  elif [ "$route" != single-bounded-task ]; then
    reason="route=$route requires human decision before acceptance"
  fi
  if [ -n "${reason:-}" ]; then
    atomic_jq "$RECORD" --arg reason "$reason" \
      '.status = "needs-human" | .disposition = "needs-human" | .reason = $reason
       | .evidence.events += [{event: "finalize-escalated", reason: $reason}]'
    die "$reason"
  fi
  atomic_jq "$RECORD" \
    '.status = "accepted" | .disposition = "accepted" | .reason = null
     | .evidence.events += [{event: "finalized", disposition: "accepted"}]'
  printf 'accepted %s\n' "$RECORD"
}

need_command jq
need_command git
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  die "required command is not installed: sha256sum or shasum"
fi

case "${1:-}" in
  -h|--help) usage ;;
  init)
    [ "$#" -eq 3 ] || die "usage: init <contract.json> <evidence.json>"
    init_record "$2" "$3"
    ;;
  run-check)
    [ "$#" -eq 3 ] || die "usage: run-check <evidence.json> <check-id>"
    load_record "$2"
    run_check "$3"
    ;;
  assess-patch)
    [ "$#" -eq 2 ] || die "usage: assess-patch <evidence.json>"
    load_record "$2"
    assess_patch
    ;;
  validate-decomposition)
    [ "$#" -ge 3 ] || die "usage: validate-decomposition <parent.json> <child.json>..."
    load_record "$2"
    shift 2
    validate_decomposition "$@"
    ;;
  finalize)
    [ "$#" -eq 2 ] || die "usage: finalize <evidence.json>"
    load_record "$2"
    finalize_record
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
