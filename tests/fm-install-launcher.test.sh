#!/usr/bin/env bash
# Behavior tests for bin/fm-install-launcher.sh: config validation, refusal
# rather than a silent captain-specific default, standalone installed-copy
# home resolution independent of the destination, and destination/checkout
# paths containing spaces. No Herdr call is made; see
# tests/fm-launcher-lifecycle.test.sh for the Herdr lifecycle behavior of the
# installed launcher itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-launcher.sh"
TEMPLATE="$ROOT/bin/templates/fm-launcher.command"
PROTOCOL_FLOOR="$ROOT/bin/herdr-min-protocol"

assert_present "$INSTALLER" "bin/fm-install-launcher.sh is missing"
assert_present "$TEMPLATE" "bin/templates/fm-launcher.command is missing"
assert_present "$PROTOCOL_FLOOR" "bin/herdr-min-protocol is missing"
[ -x "$INSTALLER" ] || fail "fm-install-launcher.sh must be executable"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# fake_checkout <root-dir>: build a minimal fake Firstmate checkout at
# <root-dir> (AGENTS.md + bin/, with a symlinked templates dir and the real
# installer copied in so it resolves the fake checkout as its own ROOT).
fake_checkout() {
  local root=$1
  mkdir -p "$root/bin/templates" "$root/config"
  : > "$root/AGENTS.md"
  cp "$TEMPLATE" "$root/bin/templates/fm-launcher.command"
  cp "$INSTALLER" "$root/bin/fm-install-launcher.sh"
  cp "$PROTOCOL_FLOOR" "$root/bin/herdr-min-protocol"
  chmod +x "$root/bin/fm-install-launcher.sh"
}

valid_conf() {
  cat <<'EOF'
model=openai-codex/gpt-5.6-sol
thinking=low
pi_bin=PATH
quota_provider=codex
EOF
}

# --- refusal without config/launcher.conf -----------------------------------

TMP1=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP1/checkout"
OUT=$("$TMP1/checkout/bin/fm-install-launcher.sh" "$TMP1/dest" 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "installer must refuse without config/launcher.conf"
assert_contains "$OUT" "missing" "refusal must name the missing config file"
[ ! -e "$TMP1/dest/fm-launcher.command" ] || fail "installer must not write anything on refusal"
pass "fm-install-launcher: refuses to install without config/launcher.conf"

# --- refusal on missing required fields -------------------------------------

TMP2=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP2/checkout"
printf 'model=openai-codex/gpt-5.6-sol\n' > "$TMP2/checkout/config/launcher.conf"
OUT=$("$TMP2/checkout/bin/fm-install-launcher.sh" "$TMP2/dest" 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "installer must refuse with only 'model' set"
assert_contains "$OUT" "thinking" "refusal must name the missing 'thinking' field"
pass "fm-install-launcher: refuses on incomplete config"

# --- refusal on malformed fields ---------------------------------------------

TMP3=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP3/checkout"
printf 'model=badmodel\nthinking=low\npi_bin=PATH\nquota_provider=codex\n' > "$TMP3/checkout/config/launcher.conf"
OUT=$("$TMP3/checkout/bin/fm-install-launcher.sh" "$TMP3/dest" 2>&1) && fail "installer must refuse a model without a provider/model-id slash"
assert_contains "$OUT" "provider" "refusal must explain the required model shape"
pass "fm-install-launcher: refuses a malformed model value"

TMP3A=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP3A/checkout"
printf 'model=anthropic/claude-sonnet-4\nthinking=low\npi_bin=PATH\nquota_provider=claude\n' > "$TMP3A/checkout/config/launcher.conf"
OUT=$("$TMP3A/checkout/bin/fm-install-launcher.sh" "$TMP3A/dest" 2>&1) && fail "installer must refuse to route an Anthropic model through Pi"
assert_contains "$OUT" "anthropic" "refusal must name the forbidden Anthropic provider"
pass "fm-install-launcher: refuses Anthropic models routed through Pi"

TMP3b=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP3b/checkout"
printf 'model=openai-codex/gpt-5.6-sol\nthinking=extreme\npi_bin=PATH\nquota_provider=codex\n' > "$TMP3b/checkout/config/launcher.conf"
OUT=$("$TMP3b/checkout/bin/fm-install-launcher.sh" "$TMP3b/dest" 2>&1) && fail "installer must refuse an unsupported thinking level"
pass "fm-install-launcher: refuses an unsupported thinking level"

TMP3c=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP3c/checkout"
printf 'model=openai-codex/gpt-5.6-sol\nthinking=low\npi_bin=relative/path\nquota_provider=codex\n' > "$TMP3c/checkout/config/launcher.conf"
OUT=$("$TMP3c/checkout/bin/fm-install-launcher.sh" "$TMP3c/dest" 2>&1) && fail "installer must refuse a non-absolute, non-PATH pi_bin"
pass "fm-install-launcher: refuses a relative pi_bin"

TMP3d=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP3d/checkout"
printf 'model=openai-codex/gpt-5.6-sol\nthinking=low\npi_bin=PATH\nquota_provider=codex\nquota_reserve_percent=not-a-number\n' > "$TMP3d/checkout/config/launcher.conf"
OUT=$("$TMP3d/checkout/bin/fm-install-launcher.sh" "$TMP3d/dest" 2>&1) && fail "installer must refuse a non-integer quota_reserve_percent"
pass "fm-install-launcher: refuses a non-integer quota_reserve_percent"

for invalid_reserve in 08 101; do
  TMP3R=$(fm_test_tmproot fm-install-launcher)
  fake_checkout "$TMP3R/checkout"
  printf 'model=openai-codex/gpt-5.6-sol\nthinking=low\npi_bin=PATH\nquota_provider=codex\nquota_reserve_percent=%s\n' "$invalid_reserve" > "$TMP3R/checkout/config/launcher.conf"
  OUT=$("$TMP3R/checkout/bin/fm-install-launcher.sh" "$TMP3R/dest" 2>&1) && fail "installer must refuse invalid reserve $invalid_reserve"
done
pass "fm-install-launcher: reserve must be canonical and within 0 through 100"

TMP3e=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP3e/checkout"
printf 'model=openai-codex/gpt-5.6-sol\nthinking=low\npi_bin=PATH\nquota_provider=codex\nnonsense_field=1\n' > "$TMP3e/checkout/config/launcher.conf"
OUT=$("$TMP3e/checkout/bin/fm-install-launcher.sh" "$TMP3e/dest" 2>&1) && fail "installer must refuse an unrecognized config field rather than silently ignoring it"
pass "fm-install-launcher: refuses an unrecognized config field"

# --- successful install: standalone home resolution, not derived from dest -

TMP4=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP4/checkout"
valid_conf > "$TMP4/checkout/config/launcher.conf"
DEST4="$TMP4/dest with spaces/Desktop"
OUT=$("$TMP4/checkout/bin/fm-install-launcher.sh" "$DEST4" 2>&1) || fail "installer failed on a valid config: $OUT"
[ -f "$DEST4/fm-launcher.command" ] || fail "installer did not write fm-launcher.command"
[ -f "$DEST4/fm-launcher.conf" ] || fail "installer did not write fm-launcher.conf"
CHECKOUT_REAL=$(cd "$TMP4/checkout" && pwd)
assert_grep "home=$CHECKOUT_REAL" "$DEST4/fm-launcher.conf" \
  "installed conf must pin the checkout's own real path, not derived from the destination"
assert_no_grep "$DEST4" "$DEST4/fm-launcher.command" \
  "the tracked command template must stay byte-identical to the source and never embed the destination path"
diff -q "$TEMPLATE" "$DEST4/fm-launcher.command" >/dev/null 2>&1 \
  || fail "installed fm-launcher.command must be byte-identical to the tracked template"
pass "fm-install-launcher: standalone home resolution independent of the destination, spaces preserved"

# --- mode bits ----------------------------------------------------------------

CMD_MODE=$(file_mode "$DEST4/fm-launcher.command")
CONF_MODE=$(file_mode "$DEST4/fm-launcher.conf")
[ "$CMD_MODE" = 700 ] || fail "fm-launcher.command must be mode 0700, got $CMD_MODE"
[ "$CONF_MODE" = 600 ] || fail "fm-launcher.conf must be mode 0600, got $CONF_MODE"
pass "fm-install-launcher: installed files carry restrictive modes"

# --- checkout path itself contains spaces -------------------------------------

TMP5=$(fm_test_tmproot fm-install-launcher)
SPACED_CHECKOUT="$TMP5/my firstmate checkout"
fake_checkout "$SPACED_CHECKOUT"
valid_conf > "$SPACED_CHECKOUT/config/launcher.conf"
DEST5="$TMP5/dest5"
OUT=$("$SPACED_CHECKOUT/bin/fm-install-launcher.sh" "$DEST5" 2>&1) || fail "installer failed from a spaced checkout path: $OUT"
SPACED_REAL=$(cd "$SPACED_CHECKOUT" && pwd)
assert_grep "home=$SPACED_REAL" "$DEST5/fm-launcher.conf" \
  "installed conf must pin the exact spaced checkout path"
pass "fm-install-launcher: checkout path itself may contain spaces"

# --- optional fields: documented defaults applied ----------------------------

assert_grep 'quota_reserve_percent=25' "$DEST4/fm-launcher.conf" "quota_reserve_percent must default to 25 when unset"
assert_grep 'workspace_label=firstmate' "$DEST4/fm-launcher.conf" "workspace_label must default to firstmate when unset"
assert_grep 'tab_label=fm-primary' "$DEST4/fm-launcher.conf" "tab_label must default to fm-primary when unset"
pass "fm-install-launcher: documented safe defaults applied for optional fields"

# --- reinstall is idempotent and overwrites in place -------------------------

OUT2=$("$TMP4/checkout/bin/fm-install-launcher.sh" "$DEST4" 2>&1) || fail "reinstall failed: $OUT2"
diff -q "$TEMPLATE" "$DEST4/fm-launcher.command" >/dev/null 2>&1 || fail "reinstall must keep the command byte-identical"
pass "fm-install-launcher: reinstalling in place is idempotent"

# --- pinned absolute pi_bin must exist and be executable ---------------------

TMP6=$(fm_test_tmproot fm-install-launcher)
fake_checkout "$TMP6/checkout"
printf 'model=openai-codex/gpt-5.6-sol\nthinking=low\npi_bin=%s/nonexistent-pi\nquota_provider=codex\n' "$TMP6" > "$TMP6/checkout/config/launcher.conf"
OUT=$("$TMP6/checkout/bin/fm-install-launcher.sh" "$TMP6/dest" 2>&1) && fail "installer must refuse a pinned pi_bin that does not exist"
pass "fm-install-launcher: refuses a pinned pi_bin that is not an executable file"

echo "all fm-install-launcher tests passed"
