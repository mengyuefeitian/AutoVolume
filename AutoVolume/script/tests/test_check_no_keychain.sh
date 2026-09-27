#!/bin/bash
# Verifies script/check_no_keychain.sh actually catches Keychain usage.
# A gate that silently stops detecting is worse than no gate at all, so the
# gate has to be tested like any other piece of the build.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/script/check_no_keychain.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The gate scans $ROOT/Sources, so the fixtures have to live there. Put them in
# a throwaway directory inside Sources and remove it again on exit.
FIXTURE_DIR="$ROOT/Sources/__KeychainGateFixture__"
rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"
trap 'rm -rf "$TMP" "$FIXTURE_DIR"' EXIT

write_fixture() {
  cat > "$FIXTURE_DIR/Fixture.swift"
}

fail() { echo "FAIL: $1"; exit 1; }

# 1. A file that mentions Keychain only in prose must pass. This is the exact
#    false positive the comment-stripping exists to prevent — CredentialStore.swift
#    carries a note naming the banned APIs.
write_fixture <<'SWIFT'
import Foundation
// Never use SecItemAdd or SecItemCopyMatching here — credentials go in an
// encrypted local file instead.
struct Fixture { let x = 1 }
SWIFT
"$GATE" >/dev/null 2>&1 || fail "prose mentioning Keychain APIs was rejected"

# 2. The sanctioned use of Security (CSPRNG) must pass.
write_fixture <<'SWIFT'
import Security
func salt() -> Data {
    var b = [UInt8](repeating: 0, count: 16)
    SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
    return Data(b)
}
SWIFT
"$GATE" >/dev/null 2>&1 || fail "SecRandomCopyBytes was rejected"

# 3. Real Keychain code must fail.
write_fixture <<'SWIFT'
import Security
func readPassword() -> String? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
    var result: CFTypeRef?
    SecItemCopyMatching(q as CFDictionary, &result)
    return result as? String
}
SWIFT
"$GATE" >/dev/null 2>&1 && fail "SecItemCopyMatching was NOT detected"

# 4. Shelling out to the security(1) CLI must fail.
write_fixture <<'SWIFT'
import Foundation
func token() { _ = Process.run("/usr/bin/security", arguments: ["find-internet-password", "-s", "github.com"]) }
SWIFT
"$GATE" >/dev/null 2>&1 && fail "security(1) CLI usage was NOT detected"

# 5. With the fixture removed the real tree must pass again.
rm -rf "$FIXTURE_DIR"
"$GATE" >/dev/null 2>&1 || fail "gate fails on the real source tree"

echo "PASS: check_no_keychain"
