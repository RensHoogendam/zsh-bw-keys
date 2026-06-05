# zsh-bw-keys — lazy Bitwarden secret injection for shell env vars
# Usage:
#   bw-key-register VAR_NAME bw-item-name [trigger-commands...]
#   Example: bw-key-register GITHUB_TOKEN github-pat npm pnpm bun yarn
#   bw-keys-clear   # clear the cached session (forces re-unlock)
#
# Options (set anywhere in your zshrc, before or after sourcing):
#   export BW_KEYS_BIOMETRIC=1   # unlock via biometrics (bwbio) — default off

typeset -gA _BW_KEY_ITEMS    # VAR_NAME -> Bitwarden item name
typeset -gA _BW_KEY_TRIGGERS # VAR_NAME -> space-separated trigger commands
typeset -g _BW_KEYS_SESSION_FILE="/tmp/.bw_session"

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
}

# Clear the cached session — forces a fresh unlock on the next trigger.
bw-keys-clear() {
  unset BW_SESSION
  rm -f "$_BW_KEYS_SESSION_FILE"
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

_bw_keys_preexec() {
  local cmd="${1%% *}"

  for var_name in ${(k)_BW_KEY_ITEMS}; do
    [[ -n "${(P)var_name:-}" ]] && continue

    local triggers=(${(z)_BW_KEY_TRIGGERS[$var_name]})
    (( ${#triggers} > 0 )) && (( ! ${triggers[(Ie)$cmd]} )) && continue

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
  done
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _bw_keys_preexec
