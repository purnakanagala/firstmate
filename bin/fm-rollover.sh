#!/usr/bin/env bash
# Roll one ordinary Pi ship task onto a fresh coding-agent session in its existing
# tmux endpoint and isolated worktree, preserving every worktree byte.
# Usage: FM_HOME=<home> fm-rollover.sh <task-id> --objective <one-line-objective>
#          [--decision <one-line-accepted-decision>]... --supersedes <marker>...
#          --non-secret-reviewed
#        fm-rollover.sh --validate <capsule.json>
#
# This script is the authoritative owner of fm-rollover-capsule.v1 and rollover
# mechanics. It supports only kind=ship, harness=pi|pi-signed, backend=tmux.
# Every other task kind, harness, or backend is explicitly refused until its
# adapter can prove fresh-session identity while retaining the exact endpoint and
# worktree. Repeating an already-live identical rollover is an idempotent no-op.
# The capsule is bounded to 8 KiB and contains no brief/report/chat/log/source
# content: only a concise operator-supplied objective and decisions, fixed safety
# constraints, git identity, artifact pointers, validation/PR pointers, and
# superseded-generation markers.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-harness-launch-lib.sh
. "$SCRIPT_DIR/fm-harness-launch-lib.sh"
fm_refuse_if_gate_agent

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
sha256_text() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; else printf '%s' "$1" | sha256sum | awk '{print $1}'; fi
}
sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}
meta_get() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
refuse() { echo "error: $*" >&2; exit 1; }
IMMUTABLE_CONSTRAINTS_JSON='["Preserve the existing isolated worktree and every unlanded change; never reset, stash, discard, or change ownership.","Keep Firstmate approval, merge, destructive-action, security, secondmate, scout, X-mode, and multi-home boundaries unchanged.","Keep no-mistakes authority unchanged; one worker owns an active run and its synchronous responses.","Do not execute any superseded instruction; stop on capsule or generation mismatch.","Do not expose secrets, private prompts, chats, logs, reports, or source through rollover state."]'
worktree_state_digest() {  # <worktree>
  local wt=$1 file
  {
    git -C "$wt" status --porcelain=v1 -z
    git -C "$wt" diff --binary --no-ext-diff
    git -C "$wt" diff --cached --binary --no-ext-diff
    while IFS= read -r -d '' file; do
      printf 'payload:%s\0' "$file"
      if [ -L "$wt/$file" ]; then
        printf 'symlink:%s\0' "$(readlink "$wt/$file")"
      elif [ -f "$wt/$file" ]; then
        sha256_file "$wt/$file"
      elif [ -d "$wt/$file" ]; then
        printf 'directory\0'
      else
        printf 'other\0'
      fi
    done < <({ git -C "$wt" ls-files --cached --others --exclude-standard -z; git -C "$wt" ls-files --others --ignored --exclude-standard -z; })
  } | sha256_stdin
}

endpoint_owner_count() {  # <state> <backend> <target>
  local state=$1 backend=$2 target=$3 meta count=0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_backend_of_meta "$meta")" = "$backend" ] || continue
    [ "$(fm_backend_target_of_meta "$meta")" = "$target" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

pid_descends_from() {  # <pid> <ancestor-pid>
  local pid=$1 ancestor=$2 parent steps=0
  case "$pid:$ancestor" in *[!0-9:]*|:*) return 1 ;; esac
  while [ "$pid" -gt 1 ] && [ "$steps" -lt 32 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    case "$parent" in ''|*[!0-9]*) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
    steps=$((steps + 1))
  done
  return 1
}

harness_command_matches() {  # <target> <harness>
  local target=$1 harness=$2 command
  command=$(fm_backend_tmux_current_command "$target") || return 1
  command=${command#-}
  case "$harness:$command" in
    pi:pi|pi:pi-launcher|pi:Pi|pi-signed:pi-signed|pi-signed:pi-launcher|pi-signed:Pi) return 0 ;;
    *) return 1 ;;
  esac
}

live_process_matches() {  # <live-line> <target> <harness>
  local live=$1 target=$2 harness=$3 generation capsule_sha pid live_harness extra pane_pid
  IFS=$'\t' read -r generation capsule_sha pid live_harness extra <<< "$live"
  [ -n "$generation" ] && [ -n "$capsule_sha" ] && [ -n "$pid" ] && [ "$live_harness" = "$harness" ] && [ -z "${extra:-}" ] || return 1
  pane_pid=$(fm_backend_tmux_pane_pid "$target") || return 1
  pid_descends_from "$pid" "$pane_pid" || return 1
  harness_command_matches "$target" "$harness"
}

capsule_text_is_safe() {  # <text>
  local value=$1
  printf '%s' "$value" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9 .,;:!?()/_#+-]*$' || return 1
  printf '%s' "$value" | LC_ALL=C grep -qiE '(BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|(^|[^[:alnum:]_])(password|passwd|pwd|token|secret|api[ _-]?key|authorization|credential)([^[:alnum:]_]|$)|bearer[[:space:]]|://|(^|[^[:alnum:]_])(sk-|gh[pousr]_|glpat-|xox[baprs]-|A(KIA|SIA)[A-Z0-9]{16})|[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|[A-Za-z0-9._/-]{24,})' \
    && return 1
  return 0
}

validate_capsule() {
  local file=$1 bytes
  [ -f "$file" ] && [ ! -L "$file" ] || refuse "capsule must be a regular file"
  bytes=$(wc -c < "$file" | tr -d '[:space:]')
  [ "$bytes" -le 8192 ] || refuse "capsule exceeds 8192 bytes"
  jq -e --argjson immutable "$IMMUTABLE_CONSTRAINTS_JSON" '
    type == "object" and
    (keys | sort) == (["accepted_decisions","artifacts","current_objective","generation","immutable_constraints","objective_sha256","schema","superseded_instructions","task","validation"] | sort) and
    .schema == "fm-rollover-capsule.v1" and
    (.task | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.generation | type == "number" and . >= 1 and floor == .) and
    (.current_objective | type == "string" and length >= 1 and length <= 2048 and (contains("\\n") | not)) and
    (.objective_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.accepted_decisions | type == "array" and length <= 20 and all(type == "string" and length >= 1 and length <= 512 and (contains("\\n") | not))) and
    .immutable_constraints == $immutable and
    (.artifacts | type == "object" and (keys | sort) == (["brief","report","worktree"] | sort) and
      (.worktree | type == "string" and length >= 1 and length <= 2048 and test("^/[A-Za-z0-9 ._/+()-]+$") and (contains("://") | not)) and
      (.brief | type == "string" and test("^$|^data/[A-Za-z0-9._-]+/brief[.]md$")) and
      (.report | type == "string" and test("^$|^data/[A-Za-z0-9._-]+/report[.]md$"))) and
    (.validation | type == "object" and (keys | sort) == (["branch","mode","pr","pr_head","revision"] | sort) and
      (.branch | type == "string" and test("^detached$|^[A-Za-z0-9._/-]{1,256}$")) and
      (.mode | type == "string" and test("^[A-Za-z0-9._-]{0,64}$")) and
      (.pr | type == "string" and test("^$|^[0-9]+$|^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/%+-]+$")) and
      (.pr_head | type == "string" and test("^$|^[A-Fa-f0-9]{7,64}$|^[A-Za-z0-9._/-]{1,256}$")) and
      (.revision | type == "string" and test("^[A-Fa-f0-9]{40,64}$"))) and
    (.superseded_instructions | type == "object" and (keys | sort) == (["generation_marker","markers"] | sort) and
      (.generation_marker | type == "string" and test("^generation-[0-9]+$")) and
      (.markers | type == "array" and length >= 1 and length <= 20 and all(type == "string" and length >= 1 and length <= 256 and (contains("\\n") | not))))
  ' "$file" >/dev/null || refuse "capsule does not match fm-rollover-capsule.v1"
  [ "$(jq -r '.objective_sha256' "$file")" = "$(sha256_text "$(jq -r '.current_objective' "$file")")" ] \
    || refuse "capsule objective digest mismatch"
  while IFS= read -r value; do
    capsule_text_is_safe "$value" || refuse "capsule text violates the non-secret input contract"
  done <<< "$(jq -r '[.current_objective] + .accepted_decisions + .superseded_instructions.markers | .[]' "$file")"
}

if [ "${1:-}" = --validate ]; then
  [ "$#" -eq 2 ] || refuse "--validate requires exactly one capsule path"
  validate_capsule "$2"
  echo "valid fm-rollover-capsule.v1"
  exit 0
fi

[ -n "${FM_HOME:-}" ] || refuse "FM_HOME must be explicit"
[ "$#" -ge 1 ] || refuse "task id is required"
ID=$1; shift
case "$ID" in ''|*[!A-Za-z0-9._-]*) refuse "invalid task id" ;; esac
OBJECTIVE=
DECISIONS=()
SUPERSEDES=()
NON_SECRET_REVIEWED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --objective) [ "$#" -ge 2 ] || refuse "--objective requires a value"; OBJECTIVE=$2; shift 2 ;;
    --decision) [ "$#" -ge 2 ] || refuse "--decision requires a value"; DECISIONS+=("$2"); shift 2 ;;
    --supersedes) [ "$#" -ge 2 ] || refuse "--supersedes requires a value"; SUPERSEDES+=("$2"); shift 2 ;;
    --non-secret-reviewed) NON_SECRET_REVIEWED=1; shift ;;
    *) refuse "unknown argument: $1" ;;
  esac
done
[ -n "$OBJECTIVE" ] || refuse "--objective is required"
[ "${#OBJECTIVE}" -le 2048 ] && [[ "$OBJECTIVE" != *$'\n'* ]] || refuse "objective must be one line and at most 2048 bytes"
[ "${#SUPERSEDES[@]}" -ge 1 ] && [ "${#SUPERSEDES[@]}" -le 20 ] || refuse "provide 1-20 --supersedes markers"
[ "${#DECISIONS[@]}" -le 20 ] || refuse "at most 20 accepted decisions are allowed"
[ "$NON_SECRET_REVIEWED" -eq 1 ] || refuse "--non-secret-reviewed is required after reviewing all free-text capsule inputs"
for value in "$OBJECTIVE" "${DECISIONS[@]+"${DECISIONS[@]}"}" "${SUPERSEDES[@]+"${SUPERSEDES[@]}"}"; do
  [ "${#value}" -le 512 ] || [ "$value" = "$OBJECTIVE" ] || refuse "decision/marker exceeds 512 bytes"
  [[ "$value" != *$'\n'* ]] || refuse "capsule inputs must be one line"
  capsule_text_is_safe "$value" || refuse "capsule input violates the non-secret text contract"
done

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
META="$STATE/$ID.meta"
[ -d "$FM_HOME" ] && [ -d "$STATE" ] || refuse "home/state directory is missing"
[ -f "$META" ] && [ ! -L "$META" ] || refuse "task ownership metadata is missing or unsafe"
[ "$(meta_get "$META" kind)" = ship ] || refuse "rollover supports ordinary ship tasks only; scouts and secondmates are refused"
HARNESS=$(meta_get "$META" harness)
case "$HARNESS" in pi|pi-signed) ;; *) refuse "rollover is unsupported for harness '$HARNESS'; only pi and pi-signed are verified" ;; esac
BACKEND=$(fm_backend_of_meta "$META")
[ "$BACKEND" = tmux ] || refuse "rollover is unsupported for backend '$BACKEND'; only tmux has fresh-session proof"
fm_backend_source "$BACKEND" || refuse "tmux backend adapter could not be loaded"
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || refuse "task endpoint is not recorded"
[ "$(endpoint_owner_count "$STATE" "$BACKEND" "$TARGET")" = 1 ] || refuse "task endpoint ownership is ambiguous"
[ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = alive ] || refuse "current Pi agent ownership is not provably alive"
harness_command_matches "$TARGET" "$HARNESS" || refuse "live endpoint does not run the recorded Pi harness"
WT=$(meta_get "$META" worktree); PROJECT=$(meta_get "$META" project)
[ -n "$WT" ] && [ -d "$WT" ] && [ ! -L "$WT" ] || refuse "recorded worktree is missing or unsafe"
WT_REAL=$(cd "$WT" && pwd -P)
TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || refuse "recorded worktree is not a git worktree"
TOP_REAL=$(cd "$TOP" && pwd -P)
[ "$TOP_REAL" = "$WT_REAL" ] || refuse "recorded worktree is not its git root"
PROJECT_REAL=$(cd "$PROJECT" 2>/dev/null && pwd -P) || refuse "recorded project is unavailable"
[ "$PROJECT_REAL" != "$WT_REAL" ] || refuse "recorded task is in the primary project copy"
[ "$(fm_backend_tmux_current_path "$TARGET")" = "$WT_REAL" ] || refuse "live endpoint is not in the recorded isolated worktree"

LOCK="$STATE/.spawn-$ID.lock"
fm_lock_try_acquire "$LOCK" || refuse "another spawn or rollover owns this task"
cleanup() { fm_lock_release "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

MODEL=$(meta_get "$META" model); EFFORT=$(meta_get "$META" effort)
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
PIEXT="$STATE/$ID.pi-ext.ts"
[ -f "$PIEXT" ] && [ ! -L "$PIEXT" ] || refuse "task Pi turn-end extension is missing or unsafe"
GUARD="$FM_ROOT/.pi/extensions/fm-rollover-guard.ts"
[ -f "$GUARD" ] && [ ! -L "$GUARD" ] || refuse "rollover guard extension is missing or unsafe"
OPINPUT="$FM_ROOT/bin/fm-operational-input.sh"
[ -f "$OPINPUT" ] && [ -x "$OPINPUT" ] && [ ! -L "$OPINPUT" ] || refuse "operational input encoder is missing or unsafe"
command -v "$HARNESS" >/dev/null 2>&1 || refuse "$HARNESS executable not found on PATH"

CAPSULE="$DATA/$ID/rollover-capsule.json"
mkdir -p "$DATA/$ID"
PREV=0
CURRENT_SHA=
META_GEN=$(meta_get "$META" rollover_generation)
META_CAPSULE=$(meta_get "$META" rollover_capsule)
LIVE=$(cat "$STATE/$ID.rollover-live" 2>/dev/null || true)
FINALIZED=$(cat "$STATE/$ID.rollover-finalized" 2>/dev/null || true)
if [ -e "$CAPSULE" ] || [ -L "$CAPSULE" ]; then
  [ -f "$CAPSULE" ] && [ ! -L "$CAPSULE" ] || refuse "existing rollover capsule is unsafe"
  validate_capsule "$CAPSULE"
  PREV=$(jq -r '.generation' "$CAPSULE")
  CURRENT_SHA=$(sha256_file "$CAPSULE")
  [ "$META_GEN" = "$PREV" ] && [ "$META_CAPSULE" = "$CAPSULE" ] \
    || refuse "existing rollover capsule and metadata generation do not match"
  [[ "$LIVE" = "$PREV"$'\t'"$CURRENT_SHA"$'\t'* ]] && live_process_matches "$LIVE" "$TARGET" "$HARNESS" \
    || refuse "existing rollover generation has no matching live process proof"
  [ "$FINALIZED" = "$LIVE" ] || refuse "existing rollover generation is not operator-finalized"
else
  [ -z "$META_GEN" ] && [ -z "$META_CAPSULE" ] && [ -z "$LIVE" ] && [ -z "$FINALIZED" ] && [ ! -e "$STATE/$ID.rollover-ack" ] \
    || refuse "rollover generation state exists without its capsule"
fi
GEN=$((PREV + 1))
BRANCH=$(git -C "$WT_REAL" symbolic-ref --quiet --short HEAD 2>/dev/null || printf detached)
REV=$(git -C "$WT_REAL" rev-parse HEAD)
DIRTY_BEFORE=$(worktree_state_digest "$WT_REAL")
OBJECTIVE_SHA=$(sha256_text "$OBJECTIVE")
DECISIONS_JSON=$(printf '%s\n' "${DECISIONS[@]+"${DECISIONS[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')
SUPERSEDES_JSON=$(printf '%s\n' "${SUPERSEDES[@]+"${SUPERSEDES[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')
BRIEF_PTR=""; REPORT_PTR=""
[ -f "$DATA/$ID/brief.md" ] && BRIEF_PTR="data/$ID/brief.md"
[ -f "$DATA/$ID/report.md" ] && REPORT_PTR="data/$ID/report.md"
MODE=$(meta_get "$META" mode); PR=$(meta_get "$META" pr); PR_HEAD=$(meta_get "$META" pr_head)
TMP="$CAPSULE.tmp.$$"
umask 077
jq -n --arg task "$ID" --argjson generation "$GEN" --arg objective "$OBJECTIVE" --arg objective_sha "$OBJECTIVE_SHA" \
  --argjson decisions "$DECISIONS_JSON" --arg worktree "$WT_REAL" --arg brief "$BRIEF_PTR" --arg report "$REPORT_PTR" \
  --arg branch "$BRANCH" --arg mode "$MODE" --arg pr "$PR" --arg pr_head "$PR_HEAD" --arg revision "$REV" --arg marker "generation-$PREV" \
  --argjson supersedes "$SUPERSEDES_JSON" --argjson immutable "$IMMUTABLE_CONSTRAINTS_JSON" '{
    schema:"fm-rollover-capsule.v1", task:$task, generation:$generation,
    current_objective:$objective, objective_sha256:$objective_sha, accepted_decisions:$decisions,
    immutable_constraints:$immutable,
    artifacts:{worktree:$worktree,brief:$brief,report:$report},
    validation:{branch:$branch,mode:$mode,pr:$pr,pr_head:$pr_head,revision:$revision},
    superseded_instructions:{generation_marker:$marker,markers:$supersedes}
  }' > "$TMP"
validate_capsule "$TMP"
chmod 600 "$TMP"
CAPSULE_SHA=$(sha256_file "$TMP")
CAPSULE_INPUT=$("$OPINPUT" encode launch-brief < "$TMP") || refuse "capsule operational-input encoding failed"
PROMPT="$CAPSULE_INPUT

This capsule generation is launch-authoritative. State its current_objective, then call fm_rollover_ack with generation $GEN and objective_sha256 $OBJECTIVE_SHA before any other tool. Every instruction named by superseded_instructions is inactive."
LAUNCH="FM_PI_HARNESS=$(fm_shell_quote "$HARNESS") FM_ROLLOVER_TASK=$(fm_shell_quote "$ID") FM_ROLLOVER_GENERATION=$(fm_shell_quote "$GEN") FM_ROLLOVER_CAPSULE=$(fm_shell_quote "$CAPSULE") FM_ROLLOVER_CAPSULE_SHA=$(fm_shell_quote "$CAPSULE_SHA") FM_ROLLOVER_STATE=$(fm_shell_quote "$STATE") $(fm_shell_quote "$HARNESS") ${MODELFLAG}${EFFORTFLAG}-e $(fm_shell_quote "$PIEXT") -e $(fm_shell_quote "$GUARD")"

# Identical, already-live generation: discard the speculative next capsule and return.
if [ -f "$CAPSULE" ]; then
  OLD_SEM=$(jq -S 'del(.generation,.superseded_instructions.generation_marker)' "$CAPSULE")
  NEW_SEM=$(jq -S 'del(.generation,.superseded_instructions.generation_marker)' "$TMP")
  if [ "$OLD_SEM" = "$NEW_SEM" ]; then
    rm -f "$TMP"
    echo "rollover unchanged: $ID generation=$PREV capsule=$CAPSULE"
    exit 0
  fi
fi
mv "$TMP" "$CAPSULE"
rm -f "$STATE/$ID.rollover-live" "$STATE/$ID.rollover-ack" "$STATE/$ID.rollover-finalized"

VERDICT=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" /quit 3 0.4 1) || refuse "Pi quit submission failed"
[ "$VERDICT" = empty ] || refuse "Pi quit was not confirmed"
i=0
while [ "$i" -lt 40 ] && [ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" != dead ]; do sleep 0.25; i=$((i + 1)); done
[ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = dead ] || refuse "old Pi session did not exit cleanly; fresh ownership cannot be proven"
[ "$(fm_backend_tmux_current_path "$TARGET")" = "$WT_REAL" ] || refuse "endpoint left the preserved worktree after Pi exit"

fm_backend_tmux_send_text_line "$TARGET" "$LAUNCH"

i=0
while [ "$i" -lt 80 ]; do
  LIVE=$(cat "$STATE/$ID.rollover-live" 2>/dev/null || true)
  [[ "$LIVE" = "$GEN"$'\t'"$CAPSULE_SHA"$'\t'* ]] && break
  sleep 0.25; i=$((i + 1))
done
[[ "${LIVE:-}" = "$GEN"$'\t'"$CAPSULE_SHA"$'\t'* ]] || refuse "fresh Pi session did not publish generation-bound ownership proof"
live_process_matches "$LIVE" "$TARGET" "$HARNESS" || refuse "fresh Pi process is not bound to the recorded endpoint and harness"
[ "$(fm_backend_tmux_current_path "$TARGET")" = "$WT_REAL" ] || refuse "fresh Pi session is not in the preserved worktree"
DIRTY_AFTER=$(worktree_state_digest "$WT_REAL")
[ "$DIRTY_AFTER" = "$DIRTY_BEFORE" ] || refuse "worktree changed during rollover; stop and inspect preserved work"

META_TMP="$META.tmp.$$"
awk '!/^rollover_generation=/ && !/^rollover_capsule=/' "$META" > "$META_TMP"
printf 'rollover_generation=%s\nrollover_capsule=%s\n' "$GEN" "$CAPSULE" >> "$META_TMP"
mv "$META_TMP" "$META"
FINALIZED_TMP="$STATE/$ID.rollover-finalized.tmp.$$"
printf '%s\n' "$LIVE" > "$FINALIZED_TMP"
chmod 600 "$FINALIZED_TMP"
mv "$FINALIZED_TMP" "$STATE/$ID.rollover-finalized"

i=0
while [ "$i" -lt 40 ] && [ "$(fm_backend_composer_state "$BACKEND" "$TARGET")" != empty ]; do
  sleep 0.25
  i=$((i + 1))
done
[ "$(fm_backend_composer_state "$BACKEND" "$TARGET")" = empty ] || {
  rm -f "$STATE/$ID.rollover-finalized"
  refuse "fresh Pi composer was not ready for the finalized objective"
}
if ! VERDICT=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$PROMPT" 3 0.4 1); then
  rm -f "$STATE/$ID.rollover-finalized"
  refuse "finalized objective submission failed"
fi
if [ "$VERDICT" != empty ]; then
  rm -f "$STATE/$ID.rollover-finalized"
  refuse "finalized objective delivery was not confirmed"
fi
echo "rolled over $ID generation=$GEN capsule=$CAPSULE fresh-session=proved worktree=preserved"
