# Local code-signing identity

`script/build_and_run.sh` signs every binary in the bundle with a stable local
identity, `"AutoVolume Local Signing"`, instead of ad-hoc (`--sign -`).

## Why this exists

Ad-hoc signing gives every rebuild a fresh cdhash. macOS TCC grants (e.g. Full
Disk Access for `NTFSPrivilegedHelper`, required for read-write NTFS mounts)
are tied to the binary's code requirement. Under ad-hoc signing that
requirement is `anchor=<cdhash>` — it changes on every rebuild, so a TCC grant
silently stops working the moment the binary is rebuilt, even without any
source change. A stable certificate-based identity produces a code requirement
anchored to the certificate instead (`certificate leaf = H"<hash>"`), which
survives rebuilds as long as the same certificate signs the binary.

Verify a build actually got the stable identity (not a silent ad-hoc
fallback):

```bash
codesign -d -r- dist/AutoVolume.app/Contents/Resources/NTFSPrivilegedHelper
# want:  designated => identifier "NTFSPrivilegedHelper" and certificate leaf = H"..."
# NOT:   designated => identifier "NTFSPrivilegedHelper" and cdhash H"..."
```

## Recreating the identity on a new machine

If `security find-identity -v -p codesigning` shows no `"AutoVolume Local
Signing"` identity, `build_and_run.sh` falls back to ad-hoc signing (with a
warning) rather than failing the build — but any existing TCC grants won't
survive that build. Recreate the identity:

```bash
# 1. Generate a self-signed cert with a Code Signing EKU.
openssl req -x509 -newkey rsa:2048 -keyout /tmp/av_key.pem -out /tmp/av_cert.pem \
  -days 3650 -nodes -subj "/CN=AutoVolume Local Signing" \
  -addext "extendedKeyUsage=critical,codeSigning"

# 2. Bundle into a PKCS12 file. macOS's `security` tool can't parse OpenSSL
#    3.x's default AES-256 PKCS12 encryption — the -legacy flag is required.
openssl pkcs12 -export -legacy -inkey /tmp/av_key.pem -in /tmp/av_cert.pem \
  -out /tmp/av_cert.p12 -passout pass:temp123

# 3. Import into the login keychain, trusted for codesign and security.
security import /tmp/av_cert.p12 -k ~/Library/Keychains/login.keychain-db \
  -P temp123 -T /usr/bin/codesign -T /usr/bin/security

# 4. Trust it for code signing specifically (plain import isn't enough —
#    `-r trustAsRoot` is NOT a valid parameter; it must be `trustRoot`).
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/av_cert.pem

# 5. Clean up the temp key material.
rm -f /tmp/av_key.pem /tmp/av_cert.pem /tmp/av_cert.p12

# 6. Confirm it's usable.
security find-identity -v -p codesigning
# should list: 1) <SHA-1> "AutoVolume Local Signing"
```

This certificate lives only in this machine's login keychain — it is not
committed to git and has no cloud backup. If it's lost (new machine, keychain
reset), every user's Full Disk Access grant for the helper breaks again and
must be re-granted once, after which it will stay stable under the newly
recreated identity's own certificate hash.

## Re-granting Full Disk Access after a signing-identity change

The first release built under a new identity (or the first release after
recreating a lost identity) invalidates any existing Full Disk Access grant
for `com.autovolume.ntfshelper`, because the grant is bound to the old
requirement. After installing that release:

1. System Settings → Privacy & Security → Full Disk Access.
2. Remove (−) the existing `com.autovolume.ntfshelper` entry — toggling it
   off/on does not refresh the stored requirement, it must be removed and
   re-added.
3. Add (+) `/Library/PrivilegedHelperTools/com.autovolume.ntfshelper`.
4. `sudo launchctl kickstart -k system/com.autovolume.ntfshelper`

From that point on, rebuilds under the same identity keep the grant valid.
