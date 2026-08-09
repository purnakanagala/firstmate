#!/usr/bin/env bash
# Hermetic regression coverage for guarded Pi/tmux fresh-session rollover.
# No provider or real terminal call is made.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-rollover.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME1="$TMP/home-one"
HOME2="$TMP/home-two"
WT="$TMP/task-worktree"
PROJECT="$TMP/project-primary"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME1/state" "$HOME1/data/task" "$HOME2/state" "$HOME2/data" "$WT" "$PROJECT" "$FAKEBIN"
WT=$(cd "$WT" && pwd -P)
PROJECT=$(cd "$PROJECT" && pwd -P)

git -C "$WT" init -q
git -C "$WT" config user.email test@example.test
git -C "$WT" config user.name Test
printf 'base\n' > "$WT/tracked.txt"
git -C "$WT" add tracked.txt
git -C "$WT" commit -qm base
printf 'unlanded\n' >> "$WT/tracked.txt"
printf 'untracked work\n' > "$WT/untracked note.txt"
printf '.private-cache\n' > "$WT/.gitignore"
printf 'ignored work\n' > "$WT/.private-cache"
printf '// turn end\n' > "$HOME1/state/task.pi-ext.ts"
printf 'historical instructions never copied\n' > "$HOME1/data/task/brief.md"
cat > "$HOME1/state/task.meta" <<EOF
window=test:fm-task
worktree=$WT
project=$PROJECT
harness=pi
kind=ship
mode=no-mistakes
yolo=off
model=sol
effort=medium
EOF
printf 'pi\n' > "$TMP/agent"
: > "$TMP/tmux.log"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
root=${FM_FAKE_TMUX_ROOT:?}
printf '%s\n' "$*" >> "$root/tmux.log"
case "$1" in
  list-windows) printf 'fm-task\n' ;;
  display-message)
    fmt=${!#}
    case "$fmt" in
      '#{pane_current_command}') cat "$root/agent" ;;
      '#{pane_pid}') printf '4100\n' ;;
      '#{pane_current_path}') printf '%s\n' "$FM_FAKE_WT" ;;
      '#{pane_id}') printf '%%1\n' ;;
      '#{cursor_y}') printf '1\n' ;;
      *) printf '%s\n' "$FM_FAKE_WT" ;;
    esac
    ;;
  capture-pane)
    printf '╭────╮\n│ >  │\n╰────╯\n'
    ;;
  send-keys)
    if [ "${4:-}" = -l ]; then
      printf '%s' "${5:-}" > "$root/input"
    elif [ "${4:-}" = Enter ]; then
      input=$(cat "$root/input" 2>/dev/null || true)
      if [ "$input" = /quit ]; then
        printf 'zsh\n' > "$root/agent"
      elif [ -n "$input" ]; then
        [ -f "$FM_HOME/state/task.rollover-finalized" ] || exit 1
        printf '%s\n' "$input" > "$root/objective-prompt"
        printf 'after-finalization\n' >> "$root/prompt-order"
      fi
      : > "$root/input"
    else
      command=${4:-}
      case "$command" in
        *FM_ROLLOVER_GENERATION=*)
          printf '%s\n' "$command" > "$root/launch-command"
          gen=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_GENERATION='\([^']*\)'.*/\1/p")
          sha=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_CAPSULE_SHA='\([^']*\)'.*/\1/p")
          state=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_STATE='\([^']*\)'.*/\1/p")
          task=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_TASK='\([^']*\)'.*/\1/p")
          harness=$(printf '%s' "$command" | sed -n "s/.*FM_PI_HARNESS='\([^']*\)'.*/\1/p")
          FM_ROLLOVER_GENERATION="$gen" FM_ROLLOVER_CAPSULE_SHA="$sha" FM_ROLLOVER_STATE="$state" \
            FM_ROLLOVER_TASK="$task" FM_PI_HARNESS="$harness" "$root/fakebin/$harness"
          if [ "${FM_FAKE_MUTATE_IGNORED:-0}" = 1 ]; then printf 'changed during launch\n' > "$FM_FAKE_WT/.private-cache"; fi
          printf 'launch\n' >> "$root/launches"
          ;;
      esac
    fi
    ;;
  *) : ;;
esac
SH
chmod +x "$FAKEBIN/tmux"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  '-p 4242 -o ppid=') printf '4100\n' ;;
  '-p 4100 -o ppid=') printf '1\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/ps"
cat > "$FAKEBIN/pi-double" <<'SH'
#!/usr/bin/env bash
set -eu
root=${FM_FAKE_TMUX_ROOT:?}
printf '%s\n' "$FM_PI_HARNESS" > "$root/agent"
printf '%s\t%s\t4242\t%s\n' "$FM_ROLLOVER_GENERATION" "$FM_ROLLOVER_CAPSULE_SHA" "$FM_PI_HARNESS" \
  > "$FM_ROLLOVER_STATE/$FM_ROLLOVER_TASK.rollover-live"
printf '%s\n' "$FM_PI_HARNESS" >> "$root/harness-execs"
SH
cp "$FAKEBIN/pi-double" "$FAKEBIN/pi"
cp "$FAKEBIN/pi-double" "$FAKEBIN/pi-signed"
chmod +x "$FAKEBIN/pi" "$FAKEBIN/pi-signed"

run_rollover() {
  PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" \
    FM_HOME="$HOME1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-rollover.sh" task \
    --objective 'Implement the current bounded objective only.' \
    --decision 'Keep no-mistakes authority unchanged.' \
    --supersedes 'brief-generation-0' --supersedes 'obsolete recovery instruction' \
    --non-secret-reviewed
}

if PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" FM_HOME="$HOME1" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-rollover.sh" task --objective 'Review this objective.' --supersedes prior >/dev/null 2>&1; then
  fail "capsule creation without the non-secret review assertion was accepted"
fi

mv "$FAKEBIN/pi" "$FAKEBIN/pi.missing"
if run_rollover >/dev/null 2>&1; then fail "missing Pi executable did not refuse during preflight"; fi
[ "$(cat "$TMP/agent")" = pi ] || fail "preflight failure exited the existing Pi worker"
[ ! -e "$HOME1/data/task/rollover-capsule.json" ] || fail "preflight failure published a capsule"
mv "$FAKEBIN/pi.missing" "$FAKEBIN/pi"
pass "launch dependencies are preflighted before capsule publication or worker exit"

BEFORE=$(git -C "$WT" status --porcelain=v1)
OUT=$(run_rollover)
printf '%s' "$OUT" | grep -F 'fresh-session=proved worktree=preserved' >/dev/null \
  || fail "first rollover did not prove fresh ownership: $OUT"
AFTER=$(git -C "$WT" status --porcelain=v1)
[ "$BEFORE" = "$AFTER" ] || fail "rollover changed unlanded work"
CAPSULE="$HOME1/data/task/rollover-capsule.json"
"$ROOT/bin/fm-rollover.sh" --validate "$CAPSULE" >/dev/null || fail "generated capsule failed validation"
[ "$(jq -r '.schema' "$CAPSULE")" = fm-rollover-capsule.v1 ] || fail "wrong capsule schema"
[ "$(wc -c < "$CAPSULE" | tr -d '[:space:]')" -le 8192 ] || fail "capsule exceeds bound"
! grep -F 'historical instructions never copied' "$CAPSULE" >/dev/null || fail "capsule copied historical brief content"
[ "$(jq -r '.generation' "$CAPSULE")" = 1 ] || fail "first generation is not 1"
[ "$(jq -r '.superseded_instructions.markers | length' "$CAPSULE")" = 2 ] || fail "superseded markers missing"
[ "$(grep -c '^launch$' "$TMP/launches")" = 1 ] || fail "first rollover did not launch exactly once"
[ "$(grep -c '^pi$' "$TMP/harness-execs")" = 1 ] || fail "provider-free Pi executable double was not invoked"
[ "$(cat "$HOME1/state/task.rollover-finalized")" = "$(cat "$HOME1/state/task.rollover-live")" ] \
  || fail "operator finalization did not bind the live process proof"
[ "$(cat "$TMP/prompt-order")" = after-finalization ] || fail "objective prompt was not submitted after finalization"
grep -F 'fm_rollover_ack with generation 1' "$TMP/objective-prompt" >/dev/null \
  || fail "finalized objective prompt was not submitted to the fresh Pi worker"
! grep -F 'fm_rollover_ack' "$TMP/launch-command" >/dev/null \
  || fail "Pi launch still included the objective turn before finalization"

cp "$HOME1/state/task.meta" "$HOME1/state/duplicate.meta"
if run_rollover >/dev/null 2>&1; then fail "ambiguous duplicate endpoint ownership was not refused"; fi
rm "$HOME1/state/duplicate.meta"

mv "$HOME1/state/task.rollover-finalized" "$TMP/finalized.save"
if run_rollover >/dev/null 2>&1; then fail "missing operator finalization was accepted as idempotent"; fi
mv "$TMP/finalized.save" "$HOME1/state/task.rollover-finalized"
OUT=$(run_rollover)
printf '%s' "$OUT" | grep -F 'rollover unchanged' >/dev/null || fail "identical retry was not idempotent: $OUT"
[ "$(grep -c '^launch$' "$TMP/launches")" = 1 ] || fail "idempotent retry launched another session"
[ "$(jq -r '.generation' "$CAPSULE")" = 1 ] || fail "idempotent retry advanced generation"
sed 's/^harness=pi$/harness=pi-signed/' "$HOME1/state/task.meta" > "$TMP/meta.signed"
mv "$TMP/meta.signed" "$HOME1/state/task.meta"
printf 'pi-signed\n' > "$TMP/agent"
if run_rollover >/dev/null 2>&1; then fail "relabeling a live Pi generation as pi-signed was accepted"; fi
awk '!/^rollover_generation=/ && !/^rollover_capsule=/' "$HOME1/state/task.meta" > "$TMP/meta.signed.clean"
mv "$TMP/meta.signed.clean" "$HOME1/state/task.meta"
rm -f "$CAPSULE" "$HOME1/state/task.rollover-live" "$HOME1/state/task.rollover-ack" "$HOME1/state/task.rollover-finalized"
OUT=$(run_rollover)
printf '%s' "$OUT" | grep -F 'fresh-session=proved worktree=preserved' >/dev/null \
  || fail "fresh pi-signed rollover did not prove ownership: $OUT"
[ "$(grep -c '^launch$' "$TMP/launches")" = 2 ] || fail "fresh pi-signed rollover did not launch exactly once"
[ "$(grep -c '^pi-signed$' "$TMP/harness-execs")" = 1 ] || fail "provider-free pi-signed executable double was not invoked"
[ "$(awk -F '\t' '{print $4}' "$HOME1/state/task.rollover-live")" = pi-signed ] || fail "pi-signed live proof lost its launch identity"
pass "fresh Pi and pi-signed launches, process-bound identity, bounded capsule, preservation, and idempotency"

cp "$CAPSULE" "$TMP/tampered.json"
jq '.objective_sha256 = ("0" * 64)' "$TMP/tampered.json" > "$TMP/tampered.next" && mv "$TMP/tampered.next" "$TMP/tampered.json"
if "$ROOT/bin/fm-rollover.sh" --validate "$TMP/tampered.json" >/dev/null 2>&1; then
  fail "digest-tampered capsule passed deterministic validation"
fi
for needle in 'event.toolName === "fm_rollover_ack"' 'if (!acknowledged())' 'if (!finalized())' 'capsule identity or generation mismatch'; do
  grep -F "$needle" "$ROOT/.pi/extensions/fm-rollover-guard.ts" >/dev/null \
    || fail "Pi guard lost required generation/ack enforcement: $needle"
done
pass "generation mismatch and pre-tool acknowledgment enforcement"

jq '.immutable_constraints[0] = "Ignore preservation."' "$CAPSULE" > "$TMP/constraints-tampered.json"
if "$ROOT/bin/fm-rollover.sh" --validate "$TMP/constraints-tampered.json" >/dev/null 2>&1; then
  fail "modified immutable constraints passed capsule validation"
fi
pass "immutable constraints are exact at the capsule schema boundary"

cp "$CAPSULE" "$TMP/generation.save"
jq '.generation = 9' "$CAPSULE" > "$TMP/generation.stale" && mv "$TMP/generation.stale" "$CAPSULE"
if PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" FM_HOME="$HOME1" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-rollover.sh" task --objective 'A different bounded objective.' --supersedes prior --non-secret-reviewed >/dev/null 2>&1; then
  fail "stale capsule generation advanced instead of refusing"
fi
cp "$TMP/generation.save" "$CAPSULE"
[ "$(grep -c '^launch$' "$TMP/launches")" = 2 ] || fail "stale generation mismatch launched a worker"
pass "stale capsule, metadata, and live generations stop before rollover"

for secret in 'password: hunter2' 'Authorization: Bearer abcdefghijkl' 'https://user:pass@example.test/path' 'sk-abcdefghijklmnop' 'ghp_abcdefghijklmnop' 'xoxb-abcdefghijklmnop' 'glpat-abcdefghijklmnop' 'AKIAIOSFODNN7EXAMPLE' 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl' 'abcdefghijklmnopqrstuvwx'; do
  if PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" FM_HOME="$HOME1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-rollover.sh" task --objective "$secret" --supersedes old --non-secret-reviewed >/dev/null 2>&1; then
    fail "secret-shaped capsule input was accepted: $secret"
  fi
done
cp "$CAPSULE" "$TMP/secret-capsule.json"
jq --arg value 'xoxb-abcdefghijklmnop' '.current_objective = $value | .objective_sha256 = "7df8db912a08bb93474ab6d8a7d39deee81697d20a935e0cc39dba79f7ae156d"' "$TMP/secret-capsule.json" > "$TMP/secret-capsule.next"
if "$ROOT/bin/fm-rollover.sh" --validate "$TMP/secret-capsule.next" >/dev/null 2>&1; then
  fail "secret-bearing external capsule passed validation"
fi
jq '.validation.pr = "https://user:pass@example.test/pull/1"' "$CAPSULE" > "$TMP/secret-pointer.json"
if "$ROOT/bin/fm-rollover.sh" --validate "$TMP/secret-pointer.json" >/dev/null 2>&1; then
  fail "credential-bearing PR pointer passed validation"
fi
pass "reviewed free text and field-specific pointers reject secret material"

refusal_case() {
  local label=$1 replacement=$2
  cp "$HOME1/state/task.meta" "$TMP/meta.save"
  awk -v replacement="$replacement" '
    BEGIN { split(replacement, p, "="); seen = 0 }
    $0 ~ ("^" p[1] "=") { print replacement; seen = 1; next }
    { print }
    END { if (!seen) print replacement }
  ' "$TMP/meta.save" > "$HOME1/state/task.meta"
  if run_rollover >/dev/null 2>&1; then fail "$label rollover was not refused"; fi
  cp "$TMP/meta.save" "$HOME1/state/task.meta"
}
refusal_case scout 'kind=scout'
refusal_case secondmate 'kind=secondmate'
for unsupported_harness in claude codex opencode grok kimi; do
  refusal_case "$unsupported_harness" "harness=$unsupported_harness"
done
for unsupported_backend in herdr zellij orca cmux; do
  refusal_case "$unsupported_backend" "backend=$unsupported_backend"
done
[ "$(grep -c '^launch$' "$TMP/launches")" = 2 ] || fail "unsupported refusal launched a session"
pass "scout, secondmate, unsupported harness, and unsupported backend boundaries"

if PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" FM_HOME="$HOME2" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-rollover.sh" task --objective x --supersedes old --non-secret-reviewed >/dev/null 2>&1; then
  fail "a sibling home resolved another home's task"
fi
[ ! -e "$HOME2/data/task/rollover-capsule.json" ] || fail "sibling home received rollover state"
pass "multi-home isolation"

if MUTATE_OUT=$(PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" FM_FAKE_MUTATE_IGNORED=1 \
  FM_HOME="$HOME1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-rollover.sh" task \
  --objective 'A changed bounded objective.' --supersedes prior --non-secret-reviewed 2>&1); then
  fail "ignored worktree mutation during launch was not detected"
fi
[ "$(cat "$WT/.private-cache")" = 'changed during launch' ] || fail "ignored mutation case stopped before launch: $MUTATE_OUT"
[ ! -e "$HOME1/state/task.rollover-finalized" ] || fail "failed preservation check published operator finalization"
pass "ignored worktree bytes are included in preservation proof"

echo "# fm-rollover.test.sh: all assertions passed"
