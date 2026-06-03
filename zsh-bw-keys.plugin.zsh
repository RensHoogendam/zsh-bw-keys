# zsh-bw-keys — lazy Bitwarden secret injection for shell env vars
# Usage:
#   bw-key-register VAR_NAME bw-item-name [trigger-commands...]
#   Example: bw-key-register GITHUB_TOKEN github-pat npm pnpm bun yarn

typeset -gA _BW_KEY_ITEMS    # VAR_NAME -> Bitwarden item name
typeset -gA _BW_KEY_TRIGGERS # VAR_NAME -> space-separated trigger commands

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

_bw_keys_ensure_session() {
  if [[ -z "${BW_SESSION:-}" ]]; then
    local _session_file="/tmp/.bw_session"
    if [[ -f "$_session_file" ]]; then
      BW_SESSION="$(cat "$_session_file")"
      export BW_SESSION
    fi
  fi

  if [[ -z "${BW_SESSION:-}" ]]; then
    command -v bw >/dev/null || {
      echo -e "\e[1;31m✗ Bitwarden CLI not installed (brew install bitwarden-cli)\e[0m" >&2
      return 1
    }
    echo -e "\e[1;33m🔒 Bitwarden vault locked — unlocking...\e[0m" >&2
    BW_SESSION="$(bw unlock --raw)" || return 1
    export BW_SESSION
    echo "$BW_SESSION" > /tmp/.bw_session
    chmod 600 /tmp/.bw_session
  fi
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
