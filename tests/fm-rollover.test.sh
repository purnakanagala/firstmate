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
      if [ "$(cat "$root/input" 2>/dev/null || true)" = /quit ]; then printf 'zsh\n' > "$root/agent"; fi
    else
      command=${4:-}
      case "$command" in
        *FM_ROLLOVER_GENERATION=*)
          gen=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_GENERATION='\([^']*\)'.*/\1/p")
          sha=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_CAPSULE_SHA='\([^']*\)'.*/\1/p")
          state=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_STATE='\([^']*\)'.*/\1/p")
          task=$(printf '%s' "$command" | sed -n "s/.*FM_ROLLOVER_TASK='\([^']*\)'.*/\1/p")
          printf 'pi\n' > "$root/agent"
          printf '%s\t%s\t4242\n' "$gen" "$sha" > "$state/$task.rollover-live"
          printf 'launch\n' >> "$root/launches"
          ;;
      esac
    fi
    ;;
  *) : ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

run_rollover() {
  PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" \
    FM_HOME="$HOME1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-rollover.sh" task \
    --objective 'Implement the current bounded objective only.' \
    --decision 'Keep no-mistakes authority unchanged.' \
    --supersedes 'brief-generation-0' --supersedes 'obsolete recovery instruction'
}

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

OUT=$(run_rollover)
printf '%s' "$OUT" | grep -F 'rollover unchanged' >/dev/null || fail "identical retry was not idempotent: $OUT"
[ "$(grep -c '^launch$' "$TMP/launches")" = 1 ] || fail "idempotent retry launched another session"
[ "$(jq -r '.generation' "$CAPSULE")" = 1 ] || fail "idempotent retry advanced generation"
sed 's/^harness=pi$/harness=pi-signed/' "$HOME1/state/task.meta" > "$TMP/meta.signed"
mv "$TMP/meta.signed" "$HOME1/state/task.meta"
OUT=$(run_rollover)
printf '%s' "$OUT" | grep -F 'rollover unchanged' >/dev/null || fail "pi-signed did not share the verified guarded path"
sed 's/^harness=pi-signed$/harness=pi/' "$HOME1/state/task.meta" > "$TMP/meta.pi"
mv "$TMP/meta.pi" "$HOME1/state/task.meta"
pass "fresh Pi session proof, Pi-signed parity, bounded capsule, unlanded-work preservation, and idempotent retry"

cp "$CAPSULE" "$TMP/tampered.json"
jq '.objective_sha256 = ("0" * 64)' "$TMP/tampered.json" > "$TMP/tampered.next" && mv "$TMP/tampered.next" "$TMP/tampered.json"
if "$ROOT/bin/fm-rollover.sh" --validate "$TMP/tampered.json" >/dev/null 2>&1; then
  fail "digest-tampered capsule passed deterministic validation"
fi
for needle in 'event.toolName === "fm_rollover_ack"' 'if (!acknowledged())' 'capsule identity or generation mismatch'; do
  grep -F "$needle" "$ROOT/.pi/extensions/fm-rollover-guard.ts" >/dev/null \
    || fail "Pi guard lost required generation/ack enforcement: $needle"
done
pass "generation mismatch and pre-tool acknowledgment enforcement"

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
[ "$(grep -c '^launch$' "$TMP/launches")" = 1 ] || fail "unsupported refusal launched a session"
pass "scout, secondmate, unsupported harness, and unsupported backend boundaries"

if PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_ROOT="$TMP" FM_FAKE_WT="$WT" FM_HOME="$HOME2" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-rollover.sh" task --objective x --supersedes old >/dev/null 2>&1; then
  fail "a sibling home resolved another home's task"
fi
[ ! -e "$HOME2/data/task/rollover-capsule.json" ] || fail "sibling home received rollover state"
pass "multi-home isolation"

echo "# fm-rollover.test.sh: all assertions passed"
