# zsh-bw-keys

Lazy Bitwarden secret injection for zsh — automatically loads secrets from your Bitwarden vault into environment variables the moment a specified command needs them.

## Requirements

- [Bitwarden CLI](https://bitwarden.com/help/cli/) (`brew install bitwarden-cli`)
- Logged in: `bw login`

## Installation

**Manual:**
```zsh
git clone https://github.com/RensHoogendam/zsh-bw-keys ~/.zsh/zsh-bw-keys
echo 'source ~/.zsh/zsh-bw-keys/zsh-bw-keys.plugin.zsh' >> ~/.zshrc
```

**Oh My Zsh:**
```zsh
git clone https://github.com/RensHoogendam/zsh-bw-keys ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-bw-keys
# Add zsh-bw-keys to plugins in ~/.zshrc
```

**zinit:**
```zsh
zinit light RensHoogendam/zsh-bw-keys
```

## Usage

Register keys in your `~/.zshrc` after sourcing the plugin:

```zsh
# bw-key-register VAR_NAME bitwarden-item-name [trigger-commands...]
bw-key-register GITHUB_TOKEN github-pat npm pnpm bun yarn
bw-key-register AWS_SECRET_ACCESS_KEY aws-dev-secret aws terraform
bw-key-register SOME_API_KEY my-api-key  # no triggers = loads on any command
```

The first time one of the trigger commands runs, it unlocks your Bitwarden vault (prompts once), loads the variable, and caches the session for the rest of the session. On reboot the cache clears and it prompts again.

### Clearing the session cache

```zsh
bw-keys-clear
```

Removes the cached session file, unsets `BW_SESSION`, and unsets all registered variables in the current shell — forcing a fresh unlock and reload on the next trigger.

## Biometric unlock (optional, off by default)

Instead of typing your master password, you can unlock with Touch ID / Windows Hello via [bitwarden-cli-bio](https://github.com/jeanregisser/bitwarden-cli-bio) (`bwbio`), which talks to the Bitwarden desktop app:

1. Install: `brew install jeanregisser/tap/bitwarden-cli-bio` (needs Node ≥ 22)
2. In the Bitwarden **desktop app**: enable *Unlock with biometrics* and *Allow browser integration* (Settings → Security). Optionally enable *Ask to verify browser integration* for extra safety.
3. Opt in, in your `~/.zshrc`:

```zsh
export BW_KEYS_BIOMETRIC=1
```

If `BW_KEYS_BIOMETRIC` is unset (or `bwbio` is missing), the plugin uses the regular `bw unlock` password prompt. When biometrics fail or are unavailable, `bwbio` itself falls back to a password prompt.

## How it works

- Session is cached in `/tmp/.bw_session` (cleared on reboot, `chmod 600`)
- Cached sessions are validated before use — after `bw lock` or logout the plugin re-prompts instead of failing
- Already-set variables are never overwritten
- If no trigger commands are specified, the key loads before any command
