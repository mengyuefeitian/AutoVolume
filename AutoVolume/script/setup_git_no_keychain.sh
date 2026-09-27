#!/bin/bash
# Wires this repository's git to a file-based credential helper so that no
# AutoVolume git operation ever touches macOS Keychain.
#
# Scope is deliberately local: the settings land in <repo>/.git/config, which
# is not committed and does not affect any other project on this machine.
#
# The empty-string helper matters. git collects credential.helper values in
# config-file order (system, then global, then local), so the osxkeychain
# helper inherited from the global/system config would otherwise run first and
# pop a Keychain dialog before ours got a turn. An empty value resets the
# collected list, clearing the inherited helper for this repository only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"

# This repo lives at <repo-root>/AutoVolume, so the git dir is one level up.
if [[ ! -d "$REPO_ROOT/.git" ]]; then
  echo "error: no .git directory at $REPO_ROOT — is this still nested one level below the repo root?" >&2
  exit 1
fi

HELPER="$ROOT/git_credential_file.sh"
if [[ ! -f "$HELPER" ]]; then
  echo "error: helper not found at $HELPER" >&2
  exit 1
fi

git -C "$REPO_ROOT" config --local credential.helper ''
git -C "$REPO_ROOT" config --local --add credential.helper "!bash $HELPER"

echo "Configured $REPO_ROOT to resolve GitHub credentials from a file, not Keychain."
echo ""
echo "  credential.helper (effective):"
git -C "$REPO_ROOT" config --local --get-all credential.helper | sed 's/^/    /'
echo ""
echo "If the token file is missing, git falls back to prompting on the terminal"
echo "instead of Keychain. Provision it once with:"
echo "  mkdir -p ~/.config/autovolume && gh auth token > ~/.config/autovolume/github_token && chmod 600 ~/.config/autovolume/github_token"
