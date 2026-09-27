#!/bin/bash
# Fails the build if anything in the project reaches for macOS Keychain.
#
# AutoVolume stores credentials in an encrypted local file
# (EncryptedFileCredentialStore) on purpose. macOS Keychain is banned outright:
# it prompts for authorization at unpredictable moments, behaves differently
# between a GUI session and the launchd contexts this app actually runs in
# (menu bar app, LaunchAgent, privileged LaunchDaemon), and it puts the user's
# NAS passwords somewhere the app cannot reason about or migrate.
#
# The Security framework itself is still allowed — CredentialStore.swift uses it
# for SecRandomCopyBytes (a CSPRNG). This gate flags Keychain APIs, not the
# framework import.
#
# Comments are stripped before scanning: prose that *mentions* a banned symbol
# (like this header, or the note in CredentialStore.swift) is not a violation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Keychain entry points. SecRandomCopyBytes / kSecRandomDefault are deliberately
# absent: using Security as a random source is the one sanctioned use.
PATTERN='SecItemAdd|SecItemCopyMatching|SecItemUpdate|SecItemDelete|SecKeychain|SecAccessControl|kSecClass|kSecAttrService|kSecAttrAccount|kSecUseDataProtection'

# Swift/ObjC/C: drop // line comments and /* */ block comments (which may span
# lines) while keeping original line numbers, then report any match left.
scan_sources() {
  find "$ROOT/Sources" "$ROOT/ManualTests" -type f \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.c' \) \
    -print0 2>/dev/null |
  while IFS= read -r -d '' file; do
    awk -v pat="$PATTERN" -v file="$file" '
      BEGIN { inb = 0 }
      {
        l = $0; o = ""
        while (length(l) > 0) {
          if (inb) {
            p = index(l, "*/")
            if (p) { l = substr(l, p + 2); inb = 0 } else { l = "" }
          } else {
            p1 = index(l, "/*"); p2 = index(l, "//")
            if (p1 && (!p2 || p1 < p2)) { o = o substr(l, 1, p1 - 1); l = substr(l, p1 + 2); inb = 1 }
            else if (p2) { o = o substr(l, 1, p2 - 1); l = "" }
            else { o = o l; l = "" }
          }
        }
        if (o ~ pat) print file ":" NR ": " o
      }
    ' "$file"
  done
}

# Shelling out to the `security` CLI is a Keychain dependency too. '#' comments
# are stripped for the same reason as above.
scan_cli() {
  find "$ROOT/Sources" "$ROOT/ManualTests" -type f \( -name '*.swift' -o -name '*.sh' \) \
    -print0 2>/dev/null |
  while IFS= read -r -d '' file; do
    awk -v file="$file" '
      { l = $0; sub(/#.*/, "", l)
        # Matches three invocation shapes: an explicit path (/usr/bin/security),
        # a shell command ("security find-internet-password"), and the binary
        # passed as its own argv element to Process/Command ("security" or
        # 'security'), which is how Swift code shells out.
        if (l ~ /\/usr\/bin\/security|\/bin\/security/) print file ":" NR ": " l
        else if (l ~ /(^|[^A-Za-z0-9_])security[[:space:]]+(add|find|delete|list|import|export|set|get)-/) print file ":" NR ": " l
        else if (l ~ /["\x27]security["\x27]/) print file ":" NR ": " l }
    ' "$file"
  done
}

hits="$(scan_sources)"
cli_hits="$(scan_cli)"

if [[ -n "$hits" || -n "$cli_hits" ]]; then
  echo "error: macOS Keychain usage detected — this project must never depend on it." >&2
  echo >&2
  if [[ -n "$hits" ]]; then
    echo "  Keychain APIs:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$cli_hits" ]]; then
    echo "  security(1) CLI:" >&2
    printf '%s\n' "$cli_hits" | sed 's/^/    /' >&2
  fi
  echo >&2
  echo "  Credentials belong in EncryptedFileCredentialStore, which writes a" >&2
  echo "  salted, AES-GCM encrypted file owned by the user. See CLAUDE.md." >&2
  exit 1
fi

# Guard the guard: if CredentialStore stops importing Security entirely, the
# CSPRNG note deserves a re-read rather than silent drift.
if ! grep -q 'import Security' "$ROOT/Sources/AutoVolumeShared/CredentialStore.swift"; then
  echo "note: CredentialStore.swift no longer imports Security — confirm that is" >&2
  echo "      intentional (SecRandomCopyBytes is the only sanctioned use)." >&2
fi

echo "PASS: no Keychain usage"
