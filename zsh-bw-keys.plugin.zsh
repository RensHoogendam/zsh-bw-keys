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
typeset -g _BW_KEYS_SESSION_FILE="/tmp/.bw_session"
typeset -g _BW_KEYS_LAST_LINE=""

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
    eval "${cmd}() { _bw_keys_run_trigger ${(q)cmd} \"\$@\" }"
  done
}

# Clear the cached session and all loaded keys — forces a fresh unlock and
# reload on the next trigger.
bw-keys-clear() {
  unset BW_SESSION
  rm -f "$_BW_KEYS_SESSION_FILE"
  local var_name
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    [[ -n "${(P)var_name:-}" ]] || continue
    unset "$var_name"
    echo -e "\e[1;32m✓ ${var_name} cleared\e[0m" >&2
  done
  echo -e "\e[1;32m✓ Bitwarden session cache cleared\e[0m" >&2
}

_bw_keys_ensure_session() {
  local _session_file="$_BW_KEYS_SESSION_FILE"

  command -v bw >/dev/null || {
    echo -e "\e[1;31m✗ Bitwarden CLI not installed (brew install bitwarden-cli)\e[0m" >&2
    return 1
  }

  if [[ -z "${BW_SESSION:-}" && -f "$_session_file" ]]; then
    BW_SESSION="$(cat "$_session_file")"
    export BW_SESSION
  fi

  # Validate the session — it goes stale after `bw lock`, logout, etc.
  if [[ -n "${BW_SESSION:-}" ]]; then
    bw unlock --check --session "$BW_SESSION" >/dev/null 2>&1 && return 0
    echo -e "\e[1;33m⚠ Cached Bitwarden session is stale — re-unlocking...\e[0m" >&2
    unset BW_SESSION
    rm -f "$_session_file"
  else
    echo -e "\e[1;33m🔒 Bitwarden vault locked — unlocking...\e[0m" >&2
  fi

  # Opt-in biometric unlock via bwbio (github.com/jeanregisser/bitwarden-cli-bio):
  # asks the Bitwarden desktop app for Touch ID / Windows Hello and falls back
  # to a password prompt by itself. Off by default — set BW_KEYS_BIOMETRIC=1.
  if [[ "${BW_KEYS_BIOMETRIC:-0}" == "1" ]] && command -v bwbio >/dev/null; then
    BW_SESSION="$(bwbio unlock --raw)" || return 1
  else
    BW_SESSION="$(bw unlock --raw)" || return 1
  fi
  export BW_SESSION
  (umask 077; echo "$BW_SESSION" > "$_session_file")
}

# Load one registered key into its env var (no-op if already set).
_bw_keys_load_var() {
  local var_name="$1"
  [[ -n "${(P)var_name:-}" ]] && return 0

  _bw_keys_ensure_session || return 1

  local val
  val="$(bw get password "${_BW_KEY_ITEMS[$var_name]}" --session "$BW_SESSION" 2>/dev/null)" || {
    echo -e "\e[1;31m✗ Failed to load ${var_name} from Bitwarden item '${_BW_KEY_ITEMS[$var_name]}'\e[0m" >&2
    return 1
  }

  [[ -z "$val" ]] && {
    echo -e "\e[1;31m✗ ${var_name}: Bitwarden item '${_BW_KEY_ITEMS[$var_name]}' returned empty\e[0m" >&2
    return 1
  }

  export "${var_name}=${val}"
  echo -e "\e[1;32m✓ ${var_name} loaded\e[0m" >&2
}

# Wrapper entry point: load every key triggered by this command, then run
# the real command. Aborts if a key cannot be loaded.
_bw_keys_run_trigger() {
  local cmd="$1"
  shift
  local var_name
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    local triggers=(${(z)_BW_KEY_TRIGGERS[$var_name]})
    (( ${triggers[(Ie)$cmd]} )) || continue
    _bw_keys_load_var "$var_name" || {
      echo -e "\e[1;33m↻ ${var_name} not loaded — aborted '${cmd}'. Run your command again.\e[0m" >&2
      return 1
    }
  done
  command "$cmd" "$@"
}

# Before each command: remember the line (for post-run recovery) and load
# keys registered without triggers.
_bw_keys_preexec() {
  _BW_KEYS_LAST_LINE="$1"

  local var_name
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    [[ -n "${_BW_KEY_TRIGGERS[$var_name]}" ]] && continue
    _bw_keys_load_var "$var_name"
  done
}

# After each command: if a trigger word appeared anywhere in the line but its
# key is still missing (cancelled unlock, wrapper bypassed, stale session),
# prompt to unlock now and tell the user to re-run the command.
_bw_keys_precmd() {
  local line="$_BW_KEYS_LAST_LINE"
  _BW_KEYS_LAST_LINE=""
  [[ -n "$line" ]] || return 0

  local words=(${(z)line})
  local var_name t missing=()
  for var_name in ${(k)_BW_KEY_ITEMS}; do
    [[ -z "${(P)var_name:-}" ]] || continue
    local triggers=(${(z)_BW_KEY_TRIGGERS[$var_name]})
    (( ${#triggers} )) || continue
    for t in $triggers; do
      (( ${words[(Ie)$t]} )) && { missing+=("$var_name"); break }
    done
  done
  (( ${#missing} )) || return 0

  echo -e "\e[1;33m⚠ Command needed ${(j:, :)missing} but it was not loaded — unlocking now...\e[0m" >&2
  local ok=1
  for var_name in $missing; do
    _bw_keys_load_var "$var_name" || ok=0
  done
  (( ok )) && echo -e "\e[1;32m↻ Keys loaded — run your command again.\e[0m" >&2
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _bw_keys_preexec
add-zsh-hook precmd _bw_keys_precmd
