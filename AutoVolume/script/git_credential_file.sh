#!/bin/bash
# A git credential helper that answers from a plain, owner-only file instead of
# macOS Keychain.
#
# AutoVolume's release flow is git push + gh, and both default to the Keychain.
# Every git operation that needs a credential — and every gh invocation — asks
# Keychain for the GitHub token, and Keychain answers with an authorization
# dialog at unpredictable moments (once per push, again for the release, again
# for the asset upload). This helper removes git from that loop entirely.
#
# It is wired up per-repository by setup_git_no_keychain.sh, so no other
# project on this machine changes behaviour.
#
# git invokes a helper as: <helper> <operation>
# with the credential description on stdin and the answer on stdout.
set -uo pipefail

TOKEN_FILE="${AUTOVOLUME_GITHUB_TOKEN_FILE:-$HOME/.config/autovolume/github_token}"
GITHUB_USER="${AUTOVOLUME_GITHUB_USER:-mengyuefeitian}"

# Only "get" needs an answer. store/erase are accepted and ignored: the token
# is provisioned out of band (see CLAUDE.md), and silently dropping them beats
# letting git re-hide the credential somewhere we cannot audit.
if [[ "${1:-}" != "get" ]]; then
  exit 0
fi

# Drain stdin so git does not see a broken pipe when it writes the description.
cat >/dev/null 2>&1 || true

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "git-credential-file: no token file at $TOKEN_FILE" >&2
  echo "git-credential-file: export it with (last Keychain prompt you should ever need):" >&2
  echo "git-credential-file:   mkdir -p ~/.config/autovolume && gh auth token > ~/.config/autovolume/github_token && chmod 600 ~/.config/autovolume/github_token" >&2
  # Exit 0 keeps git's helper chain going rather than failing the operation.
  exit 0
fi

perms="$(stat -f '%OLp' "$TOKEN_FILE" 2>/dev/null || echo '?')"
if [[ "$perms" != "600" ]]; then
  echo "git-credential-file: refusing to use $TOKEN_FILE — mode $perms, expected 600" >&2
  exit 0
fi

# Strip any trailing newline; tokens never contain whitespace.
token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
if [[ -z "$token" ]]; then
  echo "git-credential-file: token file is empty" >&2
  exit 0
fi

echo "username=$GITHUB_USER"
echo "password=$token"
