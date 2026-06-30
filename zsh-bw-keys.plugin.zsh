# zsh-bw-keys — lazy Bitwarden secret injection for shell env vars
# Usage:
#   bw-key-register VAR_NAME bw-item-name [trigger-commands...]
#   Example: bw-key-register GITHUB_TOKEN github-pat npm pnpm bun yarn
#   bw-keys-clear   # clear the cached session + loaded keys (forces re-unlock)
#
# Options (set anywhere in your zshrc, before or after sourcing):
#   export BW_KEYS_BIOMETRIC=1   # unlock via biometrics (bwbio) — default off

typeset -gA _BW_KEY_ITEMS    # VAR_NAME -> Bitwarden item name
typeset -gA _BW_KEY_TRIGGERS # VAR_NAME -> space-separated trigger commands
typeset -gA _BW_KEYS_ATTEMPTED # VAR_NAME -> 1 once a load was attempted (no retry storms)
# Cache the unlocked session in per-user, ephemeral storage — never the shared,
# world-traversable /tmp (symlink-race + snoop risk). Prefer $XDG_RUNTIME_DIR
# (Linux, 0700, cleared on logout), then $TMPDIR (macOS per-user /var/folders,
# 0700), falling back to /tmp only as a last resort. The file itself is written
# 0600 via umask 077 below.
typeset -g _BW_KEYS_SESSION_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/.bw_session"
typeset -g _BW_KEYS_SESSION_OK="" # set once the cached session validated in this shell
typeset -g _BW_KEYS_SESSION_TS="" # epoch seconds of the unlock backing this session (for TTL)
typeset -g _BW_KEYS_LAST_LINE=""
typeset -g _BW_KEYS_PLUGIN_FILE="${${(%):-%N}:A}"
typeset -g _BW_KEYS_SHIM_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-bw-keys/bin"
typeset -gA _BW_KEYS_COLORS=(green '1;32' red '1;31' yellow '1;33' dim '2')

# Optional knobs (set in your zshrc):
#   BW_KEYS_SESSION_TTL=900   # seconds an unlock stays valid before re-auth
#                             # (0/unset = until `bw lock`/reboot, the default)
#   BW_KEYS_NO_DISK_CACHE=1   # keep the session in this shell only, never on disk
#                             # (no cross-terminal sharing)
#   BW_KEYS_BIOMETRIC=1       # unlock via Touch ID (bwbio) — pairs well with a short TTL
#   BW_KEYS_BW="node /path/bw" # override the bw invocation — run the CLI under a
#                             # specific runtime/wrapper. Useful when a bw/Node
#                             # combo crashes decoding the server's gzip responses
#                             # (ERR_STREAM_PREMATURE_CLOSE). Defaults to `bw`.
#
# Core zsh modules backing the TTL: $EPOCHSECONDS and zstat (cached file's mtime).
# Loading is a no-op when BW_KEYS_SESSION_TTL is unset.
zmodload zsh/datetime 2>/dev/null
zmodload -F zsh/stat b:zstat 2>/dev/null

# Print a status line to stderr in the given color (green|red|yellow|dim).
_bw_keys_msg() {
  local color="$1"
  shift
  echo -e "\e[${_BW_KEYS_COLORS[$color]}m$*\e[0m" >&2
}

# Run the Bitwarden CLI. Honors BW_KEYS_BW so the CLI can be pinned to a specific
# runtime or wrapper (e.g. an older Node when the current one crashes decoding
# the server's gzip responses). The value is word-split, so a multi-word command
# like "node /opt/homebrew/bin/bw" works; unset falls back to plain `bw`.
_bw_keys_bw() { command ${=BW_KEYS_BW:-bw} "$@"; }
# The first word of the configured command — what to existence-check / report.
_bw_keys_bw_bin() { local -a c=(${=BW_KEYS_BW:-bw}); print -r -- "${c[1]}"; }

# True only when there is a terminal to prompt on. Everything else — editor
# tasks, background jobs, CI, and non-interactive snapshot shells (e.g. the one
# Claude Code replays) — must never prompt or spam; callers run the real
# command best-effort instead. (Negation of the old `! -t 0 && ! -t 1 && ! -t 2`.)
_bw_keys_can_prompt() {
  [[ -t 0 || -t 1 || -t 2 ]]
}

# Set $REPLY to a file's mtime in epoch seconds (empty if it can't be stat'd).
# Uses the zstat builtin — no fork, no GNU/BSD `stat` flag differences.
_bw_keys_file_mtime() {
  local -a st
  REPLY=""
  zstat -A st +mtime "$1" 2>/dev/null && REPLY="${st[1]}"
}

# True only when the cache file is one we actually own and is still 0600. A
# wrong owner or loosened perms — e.g. a misconfigured $XDG_RUNTIME_DIR that
# resolves to a shared path — means the session can't be trusted, so callers
# purge it and re-authenticate. (`8#NNN` is zsh's octal literal; a bare 0600
# is read as decimal here.)
_bw_keys_session_file_safe() {
  local -A st
  zstat -H st "$1" 2>/dev/null || return 1
  (( st[uid] == UID )) && (( (st[mode] & 8#777) == 8#600 ))
}

# True when an unlock stamped at epoch $1 is still within BW_KEYS_SESSION_TTL.
# TTL of 0/unset (or non-numeric) means "no expiry" — always fresh, and the
# common default path never touches $EPOCHSECONDS. An unknown/blank stamp with
# a TTL set is treated as expired so we re-auth rather than trust an opaque age.
_bw_keys_within_ttl() {
  local ttl="${BW_KEYS_SESSION_TTL:-0}"
  [[ "$ttl" == <-> ]] || return 0
  (( ttl <= 0 )) && return 0
  local ts="$1"
  [[ "$ts" == <-> ]] || return 1
  (( ${EPOCHSECONDS:-0} - ts < ttl ))
}

# Pure lookup: set $reply to the var names whose trigger list contains any
# of the given words.
_bw_keys_vars_for_cmds() {
  reply=()
  local var_name
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    local triggers=(${(z)_BW_KEY_TRIGGERS[$var_name]})
    local hits=("${(@)triggers:*argv}")
    (( ${#hits} )) && reply+=("$var_name")
  done
}

# Keep the shim dir first in PATH so shims win over the real binaries —
# even when something later in zshrc (volta, nvm, ...) prepends its own dirs.
_bw_keys_ensure_shim_path() {
  [[ "${path[1]:-}" == "$_BW_KEYS_SHIM_DIR" ]] && return 0
  path=("$_BW_KEYS_SHIM_DIR" "${(@)path:#$_BW_KEYS_SHIM_DIR}")
}

bw-key-register() {
  if [[ $# -lt 2 ]]; then
    echo "usage: bw-key-register VAR_NAME bw-item-name [trigger-commands...]" >&2
    return 1
  fi
  local var_name="$1"
  local bw_item="$2"
  shift 2
  _BW_KEY_ITEMS[$var_name]="$bw_item"
  _BW_KEY_TRIGGERS[$var_name]="${*}"

  # Wrap each trigger command in a function so the key is loaded (prompting
  # for unlock if needed) right before the command runs — even in compound
  # commands like `foo && npm i`. If loading fails the command is aborted
  # instead of crashing on the missing env var.
  local cmd
  for cmd in "$@"; do
    # Fall back to the real command when the plugin's helper isn't loaded in
    # this shell — a captured snapshot (Claude Code, etc.) keeps the wrapper
    # but drops the underscore-prefixed helpers, which otherwise crashes the
    # wrapper with "command not found: _bw_keys_run_trigger".
    eval "${cmd}() {
      if (( \$+functions[_bw_keys_run_trigger] )); then
        _bw_keys_run_trigger ${(q)cmd} \"\$@\"
      else
        command ${(q)cmd} \"\$@\"
      fi
    }"
    _bw_keys_write_shim "$cmd"
  done
  if (( $# )); then
    _bw_keys_ensure_shim_path
  fi
}

# Write a PATH shim for a trigger command. The function wrapper above is
# bypassed by `command npm`, scripts, and other shells — a real executable
# first in PATH catches all of those. The shim sources this plugin with the
# registry reduced to the relevant vars, then hands off to _bw_keys_shim_main.
_bw_keys_write_shim() {
  local cmd="$1"
  _bw_keys_vars_for_cmds "$cmd"
  local var_name pairs=""
  for var_name in $reply; do
    pairs+=" ${(qq)var_name} ${(qq)_BW_KEY_ITEMS[$var_name]}"
  done
  [[ -n "$pairs" ]] || return 0

  local shim="$_BW_KEYS_SHIM_DIR/$cmd"
  local content="#!/usr/bin/env zsh
# generated by zsh-bw-keys — do not edit
source ${(qq)_BW_KEYS_PLUGIN_FILE}
_BW_KEY_ITEMS=($pairs )
_bw_keys_shim_main ${(qq)cmd} \"\$@\""

  # This runs on every shell startup — skip the disk writes (and the forks
  # they cost) when the shim already has the right content.
  [[ -x "$shim" && "$(<$shim)" == "$content" ]] && return 0

  [[ -d "$_BW_KEYS_SHIM_DIR" ]] || mkdir -p -m 700 "$_BW_KEYS_SHIM_DIR"
  print -r -- "$content" > "$shim"
  chmod +x "$shim"
}

# Entry point for generated shims: drop the shim dir from PATH, load every
# missing key, then exec the real command.
_bw_keys_shim_main() {
  local cmd="$1"
  shift
  path=("${(@)path:#$_BW_KEYS_SHIM_DIR}")
  local var_name
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    [[ -n "${(P)var_name:-}" ]] && continue
    _bw_keys_load_var "$var_name"
    local rc=$?
    (( rc == 2 )) && continue   # no terminal to unlock on — run the command anyway
    (( rc != 0 )) && {
      _bw_keys_msg yellow "↻ ${var_name} not loaded — aborted '${cmd}'."
      exit 1
    }
  done
  exec "$cmd" "$@"
}

# Clear the cached session and all loaded keys — forces a fresh unlock and
# reload on the next trigger.
bw-keys-clear() {
  unset BW_SESSION
  _BW_KEYS_SESSION_OK=""
  _BW_KEYS_SESSION_TS=""
  _BW_KEYS_ATTEMPTED=()
  rm -f "$_BW_KEYS_SESSION_FILE"
  local var_name
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    if [[ -n "${(P)var_name:-}" ]]; then
      unset "$var_name"
      _bw_keys_msg green "✓ ${var_name} cleared"
    else
      _bw_keys_msg dim "- ${var_name} was not set"
    fi
  done
  _bw_keys_msg green "✓ Bitwarden session cache cleared"
}

_bw_keys_ensure_session() {
  # Already validated in this shell — skip the bw round-trip (~1s each), unless
  # the unlock has aged past BW_KEYS_SESSION_TTL, in which case drop it and
  # re-unlock below.
  if [[ -n "$_BW_KEYS_SESSION_OK" && -n "${BW_SESSION:-}" ]]; then
    _bw_keys_within_ttl "$_BW_KEYS_SESSION_TS" && return 0
    _BW_KEYS_SESSION_OK=""
    _BW_KEYS_SESSION_TS=""
    unset BW_SESSION
  fi

  command -v "$(_bw_keys_bw_bin)" >/dev/null || {
    # No terminal to prompt on → skip silently and let the command run anyway.
    _bw_keys_can_prompt || return 2
    _bw_keys_msg red "✗ Bitwarden CLI not installed (brew install bitwarden-cli)"
    return 1
  }

  # Adopt a session cached by another shell — unless the disk cache is disabled,
  # the file isn't one we safely own, or the cached unlock has aged past the TTL
  # (any of those → purge and re-auth).
  if [[ -z "${BW_SESSION:-}" && "${BW_KEYS_NO_DISK_CACHE:-0}" != "1" && -f "$_BW_KEYS_SESSION_FILE" ]]; then
    _bw_keys_file_mtime "$_BW_KEYS_SESSION_FILE"
    local cached_ts="$REPLY"
    if _bw_keys_session_file_safe "$_BW_KEYS_SESSION_FILE" && _bw_keys_within_ttl "$cached_ts"; then
      BW_SESSION="$(<"$_BW_KEYS_SESSION_FILE")"
      export BW_SESSION
      _BW_KEYS_SESSION_TS="$cached_ts"
    else
      rm -f "$_BW_KEYS_SESSION_FILE" 2>/dev/null
    fi
  fi

  # Validate the session — it goes stale after `bw lock`, logout, etc. The
  # session is passed via the exported BW_SESSION env var (which bw reads
  # natively), not `--session "$BW_SESSION"`, so the secret never lands in this
  # process's argv where any same-UID process could read it (`ps` / `/proc`).
  local was_stale=0
  if [[ -n "${BW_SESSION:-}" ]]; then
    if _bw_keys_bw unlock --check >/dev/null 2>&1; then
      _BW_KEYS_SESSION_OK=1
      # An inherited session (set in the env, not by us) has no known age —
      # stamp it now so the TTL clock starts from when this shell first saw it.
      [[ -n "$_BW_KEYS_SESSION_TS" ]] || _BW_KEYS_SESSION_TS="${EPOCHSECONDS:-}"
      return 0
    fi
    was_stale=1
    unset BW_SESSION
    rm -f "$_BW_KEYS_SESSION_FILE" 2>/dev/null   # best-effort; stay quiet if the fs blocks it
  fi

  # No terminal attached (editor task, background job, CI, snapshot shell):
  # never prompt — a surprise Touch ID popup or a hung password read is worse
  # than failing. Signal "skipped, can't prompt" (2) so callers run the real
  # command best-effort and stay silent, instead of aborting with noise.
  _bw_keys_can_prompt || return 2

  if (( was_stale )); then
    _bw_keys_msg yellow "⚠ Cached Bitwarden session is stale — re-unlocking..."
  else
    _bw_keys_msg yellow "🔒 Bitwarden vault locked — unlocking..."
  fi

  # Opt-in biometric unlock via bwbio (github.com/jeanregisser/bitwarden-cli-bio):
  # asks the Bitwarden desktop app for Touch ID / Windows Hello and falls back
  # to a password prompt by itself. Off by default — set BW_KEYS_BIOMETRIC=1.
  if [[ "${BW_KEYS_BIOMETRIC:-0}" == "1" ]] && command -v bwbio >/dev/null; then
    BW_SESSION="$(bwbio unlock --raw)" || return 1
  else
    BW_SESSION="$(_bw_keys_bw unlock --raw)" || return 1
  fi
  # A cancelled or no-op unlock can exit 0 with empty output — don't cache that.
  if [[ -z "$BW_SESSION" ]]; then
    _bw_keys_msg red "✗ Unlock returned an empty session"
    return 1
  fi
  export BW_SESSION
  _BW_KEYS_SESSION_OK=1
  _BW_KEYS_SESSION_TS="${EPOCHSECONDS:-}"
  # Persist for other shells unless the user opted out of the on-disk cache.
  # umask 077 → the file is created 0600 (owner-only) in per-user storage;
  # print -r -- is byte-safe for the token (echo would mangle a leading '-' etc).
  if [[ "${BW_KEYS_NO_DISK_CACHE:-0}" != "1" ]]; then
    (umask 077; print -r -- "$BW_SESSION" > "$_BW_KEYS_SESSION_FILE")
  fi
}

# True if the haystack ($1) contains any of the remaining substrings.
_bw_keys_err_has() {
  local hay="$1"; shift
  local needle
  for needle in "$@"; do
    [[ "$hay" == *"$needle"* ]] && return 0
  done
  return 1
}

# Print an accurate, actionable message for a failed `bw get`. bw's stderr
# ($err) is matched against known signatures so a runtime/network crash — most
# notably a newer Node + node-fetch closing the gzip stream early
# (ERR_STREAM_PREMATURE_CLOSE) — isn't misreported as a missing/renamed item,
# which is what the old blanket "Failed to load … from item" message did.
_bw_keys_report_load_failure() {
  local var_name="$1" item="$2" err="$3"
  if _bw_keys_err_has "$err" 'Premature close' ERR_STREAM_PREMATURE_CLOSE \
       FetchError 'Unable to fetch ServerConfig' ECONNRESET ETIMEDOUT \
       ECONNREFUSED ENOTFOUND EAI_AGAIN ENETUNREACH 'socket hang up' \
       'network timeout' 'self-signed certificate' 'unable to verify'; then
    _bw_keys_msg red "✗ ${var_name}: Bitwarden CLI couldn't reach the server — not an item problem."
    _bw_keys_msg dim "  'bw get ${item}' failed on a network/runtime error. Try 'bw sync', check the"
    _bw_keys_msg dim "  server, or pin bw to a working runtime via BW_KEYS_BW (see the README)."
  elif _bw_keys_err_has "$err" 'not logged in' 'You are not logged in' \
         'Vault is locked' 'mac failed' 'Invalid master password'; then
    _bw_keys_msg red "✗ ${var_name}: Bitwarden is locked or logged out — run 'bw-keys-clear', then retry to re-unlock."
  elif _bw_keys_err_has "$err" 'More than one result' 'Multiple results'; then
    _bw_keys_msg red "✗ ${var_name}: more than one Bitwarden item matches '${item}' — rename it or register its item ID."
  elif _bw_keys_err_has "$err" 'Not found' 'No item' "Couldn't find"; then
    _bw_keys_msg red "✗ ${var_name}: Bitwarden item '${item}' not found (renamed, deleted, or not synced?)."
  else
    _bw_keys_msg red "✗ Failed to load ${var_name} from Bitwarden item '${item}'"
  fi
  # Surface bw's own first error line for context — concise, and never the
  # secret (that's on stdout, captured separately into $val).
  if [[ -n "$err" ]]; then
    local first="${err%%$'\n'*}"
    [[ -n "$first" ]] && _bw_keys_msg dim "  ↳ ${first}"
  fi
}

# Load one registered key into its env var (no-op if already set).
_bw_keys_load_var() {
  local var_name="$1"
  [[ -n "${(P)var_name:-}" ]] && return 0

  _bw_keys_ensure_session
  local sess_rc=$?
  (( sess_rc == 2 )) && return 2   # no terminal to unlock on — propagate silently
  (( sess_rc != 0 )) && return 1

  # Capture bw's stderr (never the secret — that's on stdout, into $val) so a
  # server/runtime failure can be reported as such instead of as a bad item.
  local item="${_BW_KEY_ITEMS[$var_name]}"
  local err_file val rc err=""
  err_file="$(mktemp "${TMPDIR:-/tmp}/.bw_keys_err.XXXXXX" 2>/dev/null)"
  if [[ -n "$err_file" ]]; then
    val="$(_bw_keys_bw get password "$item" 2>"$err_file")"; rc=$?
    [[ -r "$err_file" ]] && err="$(<"$err_file")"
    rm -f "$err_file" 2>/dev/null
  else
    val="$(_bw_keys_bw get password "$item" 2>/dev/null)"; rc=$?
  fi

  (( rc != 0 )) && { _bw_keys_report_load_failure "$var_name" "$item" "$err"; return 1; }

  [[ -z "$val" ]] && {
    _bw_keys_msg red "✗ ${var_name}: Bitwarden item '${item}' returned empty"
    return 1
  }

  export "${var_name}=${val}"
  _bw_keys_msg green "✓ ${var_name} loaded"
}

# Load every key registered without trigger commands. One attempt per shell:
# a failed load (cancelled unlock) must not re-prompt before every command.
_bw_keys_load_untriggered() {
  local var_name
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    [[ -n "${_BW_KEY_TRIGGERS[$var_name]}" ]] && continue
    [[ -n "${_BW_KEYS_ATTEMPTED[$var_name]:-}" ]] && continue
    _BW_KEYS_ATTEMPTED[$var_name]=1
    _bw_keys_load_var "$var_name"
  done
}

# Wrapper entry point: load every key triggered by this command, then run
# the real command. Aborts if a key cannot be loaded.
_bw_keys_run_trigger() {
  local cmd="$1"
  shift
  _bw_keys_vars_for_cmds "$cmd"
  local var_name vars=($reply)
  for var_name in $vars; do
    _bw_keys_load_var "$var_name"
    local rc=$?
    (( rc == 2 )) && continue   # no terminal to unlock on — run the command anyway
    (( rc != 0 )) && {
      _bw_keys_msg yellow "↻ ${var_name} not loaded — aborted '${cmd}'. Run your command again."
      return 1
    }
  done
  # Keys are loaded — skip the PATH shim, it would only spawn another zsh
  # to re-source this plugin and exec the real command.
  local -a path=("${(@)path:#$_BW_KEYS_SHIM_DIR}")
  command "$cmd" "$@"
}

# Before each command: remember the line (for post-run recovery) and load
# keys registered without triggers.
_bw_keys_preexec() {
  _BW_KEYS_LAST_LINE="$1"
  _bw_keys_load_untriggered
}

# After each command: if a trigger word appeared anywhere in the line but its
# key is still missing (cancelled unlock, wrapper bypassed, stale session),
# prompt to unlock now and tell the user to re-run the command.
_bw_keys_precmd() {
  _bw_keys_ensure_shim_path

  local line="$_BW_KEYS_LAST_LINE"
  _BW_KEYS_LAST_LINE=""
  [[ -n "$line" ]] || return 0

  _bw_keys_vars_for_cmds ${(z)line}
  local var_name missing=()
  for var_name in $reply; do
    [[ -z "${(P)var_name:-}" ]] && missing+=("$var_name")
  done
  (( ${#missing} )) || return 0

  _bw_keys_msg yellow "⚠ Command needed ${(j:, :)missing} but it was not loaded — unlocking now..."
  local ok=1
  for var_name in $missing; do
    _bw_keys_load_var "$var_name" || ok=0
  done
  (( ok )) && _bw_keys_msg green "↻ Keys loaded — run your command again."
}

# Hooks are only useful in interactive shells — and in scripts (like the
# generated shims) the preexec hook would eagerly load every trigger-less key.
if [[ -o interactive ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook preexec _bw_keys_preexec
  add-zsh-hook precmd _bw_keys_precmd
fi
