#!/usr/bin/env zsh
# Dependency-free test suite for zsh-bw-keys. No framework — just zsh + asserts.
#   zsh test/run.zsh        # exits non-zero if any check fails
#
# Each behavioural check runs in its own `zsh -f` subshell so state (registered
# vars, generated shims, PATH) can't leak between tests.
emulate -L zsh

HERE="${0:A:h}"
PLUGIN="$HERE/../zsh-bw-keys.plugin.zsh"

typeset -i PASS=0 FAIL=0
pass() { print "  ok   - $1"; (( PASS++ )); }
fail() { print "  FAIL - $1"; (( FAIL++ )); }
expect() { # expect "desc" "got" "want"
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got: '$2'  want: '$3')"; fi
}

# Keep generated shims / runtime files off the real machine.
export XDG_CACHE_HOME="$(mktemp -d)"

print "zsh-bw-keys test suite"

# 1. Parses cleanly (this is the lint gate too).
if zsh -n "$PLUGIN" 2>/dev/null; then pass "zsh -n: plugin parses"; else fail "zsh -n: parse error"; fi

# 2. Public API + helpers are defined after sourcing.
api=$(zsh -fc "source '$PLUGIN'
  for f in bw-key-register bw-keys-clear _bw_keys_run_trigger _bw_keys_load_var; do
    (( \$+functions[\$f] )) || { print \"missing:\$f\"; exit 1; }
  done
  print ok")
expect "defines public API + helpers" "$api" "ok"

# 3. Session cache resolves to per-user storage, never bare /tmp.
p=$(XDG_RUNTIME_DIR=/run/user/9 TMPDIR=/tmp/x zsh -fc "source '$PLUGIN'; print \$_BW_KEYS_SESSION_FILE")
expect "session path prefers \$XDG_RUNTIME_DIR" "$p" "/run/user/9/.bw_session"
p=$(unset XDG_RUNTIME_DIR; TMPDIR=/var/t zsh -fc "source '$PLUGIN'; print \$_BW_KEYS_SESSION_FILE")
expect "session path falls back to \$TMPDIR" "$p" "/var/t/.bw_session"
case "$(XDG_RUNTIME_DIR=/run/user/9 zsh -fc "source '$PLUGIN'; print \$_BW_KEYS_SESSION_FILE")" in
  /tmp/*) fail "must not use world-readable /tmp when a per-user dir exists" ;;
  *)      pass "avoids world-readable /tmp" ;;
esac

# 4. A trigger command maps back to its registered var.
m=$(zsh -fc "source '$PLUGIN'; bw-key-register TOKEN_A item-a npm pnpm; _bw_keys_vars_for_cmds pnpm; print \${reply[*]}")
expect "maps trigger command -> var" "$m" "TOKEN_A"

# 5. The command wrapper guards against a missing helper (snapshot-shell safety):
#    it must fall back to `command npm` instead of crashing on a stripped helper.
g=$(zsh -fc "source '$PLUGIN'; bw-key-register TOKEN_B item-b npm; functions npm")
if [[ "$g" == *'_bw_keys_run_trigger'* && "$g" == *'command npm'* ]]; then
  pass "wrapper falls back to 'command npm' when helper absent"
else
  fail "wrapper missing fallback guard"
fi

# 6. End-to-end key load against a mocked bw (pre-seeded session, no TTY needed).
mock="$(mktemp -d)"
cat > "$mock/bw" <<'MOCK'
#!/usr/bin/env zsh
[[ "$1" == "unlock" && "$2" == "--check" ]] && exit 0
[[ "$1" == "get" && "$2" == "password" && "$3" == "item-secret" ]] && { print "s3cr3t"; exit 0; }
exit 1
MOCK
chmod +x "$mock/bw"
loaded=$(PATH="$mock:$PATH" BW_SESSION=SEED zsh -fc \
  "source '$PLUGIN'; bw-key-register SECRET_VAR item-secret; _bw_keys_load_var SECRET_VAR; print \$SECRET_VAR")
expect "loads a registered key via bw (mocked)" "$loaded" "s3cr3t"

# 7. bw-keys-clear unsets a loaded var.
cleared=$(PATH="$mock:$PATH" BW_SESSION=SEED zsh -fc \
  "source '$PLUGIN'; bw-key-register SECRET_VAR item-secret; _bw_keys_load_var SECRET_VAR; \
   bw-keys-clear >/dev/null 2>&1; print \"[\${SECRET_VAR:-EMPTY}]\"")
expect "bw-keys-clear unsets loaded vars" "$cleared" "[EMPTY]"

print ""
print "Result: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
