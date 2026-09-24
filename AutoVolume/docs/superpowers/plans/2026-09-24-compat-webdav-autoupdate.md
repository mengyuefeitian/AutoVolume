# macOS 14+ Compatibility, WebDAV Mount Stall, and Sparkle Auto-Update — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AutoVolume actually launch on every macOS it claims to support (14.0+), remove the UI/Finder stall when mounting WebDAV, and ship Sparkle-based "check daily + one-click install and relaunch" updates like InceptLaunch.

**Architecture:** A post-build binary-compatibility gate stops any Mach-O with a higher `minos` than `LSMinimumSystemVersion` from reaching a DMG again. The NTFS driver is rebuilt for 14.0, and the privileged helper learns to reinstall itself when the bundled copy changes. Sparkle 2 is fetched via SPM (`swift package resolve` only), then linked and embedded by the existing raw-`swiftc` build script. Releases are signed with a separate AutoVolume EdDSA key, and the appcast is served from GitHub Pages (`main:/docs/appcast.xml`).

**Tech Stack:** Swift 5 language mode via raw `swiftc` (no Xcode project), AppKit + SwiftUI menu-bar app, LaunchAgent + LaunchDaemon helper, Sparkle 2.x, bash build scripts.

**Spec:** This document. Research evidence is in the "Root-cause findings" section below.

## Root-cause findings (research done 2026-09-24, before this plan)

### Issue 1: menu-bar icon "missing" on macOS 15.8

- The reporter installed **public GitHub release v0.1.47** on Apple Silicon. That asset (`AutoVolume-0.1.47.dmg`, 2,595,171 bytes) is byte-for-byte the local `dist/AutoVolume-0.1.47.dmg`.
- Every binary inside it has `LC_BUILD_VERSION minos 26.0`. dyld refuses to load it on macOS 15.x, so the app never runs. It is `LSUIElement`, so the only visible symptom is a missing menu-bar icon.
- Measured minos by build:

  | Build | App, agent, shared lib | ntfs-3g / libntfs-3g |
  |---|---|---|
  | 0.1.38, 0.1.45, 0.1.47 | 26.0 | — |
  | 0.1.48 | 28.0 | 27.0 |
  | 0.1.49 | 14.0 (fixed by ab0f2d3) | **27.0 (still broken)** |

- `Info.plist` claimed `LSMinimumSystemVersion 14.0` the whole time. Nothing checks the real binaries, so this can happen again. Task 1 adds that check.
- The build is arm64-only. The reporter is on Apple Silicon, so a universal build is out of scope.

### Issue 2: WebDAV mount stall (UI beachball + Finder beachball + long silent wait)

**It only reproduces on the reporter's macOS 15.8 machine, not on this dev Mac (macOS 27).** Live sampling here is useless, so Task 7 ships diagnostics that pinpoint the stall from the 15.8 user's log. Task 8 fixes the defects that are wrong regardless of OS. Candidates from static reading of `AppViewModel.swift`:

- `mount()` runs up to about 9 sequential `ls` probes with 3–5 s timeouts, several `/sbin/mount` runs, a fixed 0.6 s sleep, a Finder AppleScript that iterates every Finder window, and `open`. A healthy mount takes several seconds with no UI feedback, and `hideListWindow()` closes the popover immediately.
- `refreshAlerts()` / `refreshVolumeStatuses()` mutate `@Observable` state from the `Task.detached` background thread. That is a data race, and SwiftUI invalidation happens off-main.
- The ContentView catch path and `delete()` call `refreshAlerts()` on the main thread. That runs `mount` plus an `ls` probe with a 3 s timeout for **every** volume, synchronously on main.
- The `cleanupFinderWindows` AppleScript is sent to Finder while webdavfs is still warming up, which can beachball Finder.

### Issue 3: auto-update

- Reference implementation: `/Users/xiaoan/Documents/code/InceptLaunch` (`Sources/iLaunch/Services/UpdateService.swift`, `script/publish_release.sh`, `docs/appcast.xml`, `script/build_and_run.sh` lines 58–72).
- **Difference that silently breaks updates if copied verbatim:** iLaunch uses a dotted `CFBundleVersion` (`1.9.6`). AutoVolume uses an integer (`49`). Sparkle compares `sparkle:version` against `CFBundleVersion`, so the appcast must carry the integer build number.
- Repo `mengyuefeitian/AutoVolume` is public, and GitHub Pages is on with source `main:/docs`. That folder is `/Users/xiaoan/Documents/Playground/docs/` in this checkout, **not** `AutoVolume/docs/`. The feed URL is `https://mengyuefeitian.github.io/AutoVolume/appcast.xml`.

## Global Constraints

- Every `swift`/`swiftc` invocation needs the prefix `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0` (see `AutoVolume/CLAUDE.md`). This includes `script/build_and_run.sh`, `script/package_dmg.sh`, and `swift package resolve`.
- Every `swiftc` call keeps `-target arm64-apple-macosx14.0`.
- Minimum supported OS: **macOS 14.0**. No shipped Mach-O may have `minos` > 14.0.
- Tests live in `AutoVolume/ManualTests/AutoVolumeManualTests.swift`: a function per test, registered in the `tests` array at the bottom, run by `script/build_and_run.sh`. Shell-script tests go in `AutoVolume/script/tests/*.sh` and are run by `script/build_and_run.sh` before compiling.
- UI strings are bilingual, with Chinese first, via `localized("中文", "English")` in `StatusBarController` or `AppStrings` in `AppViewModel.swift`.
- Code style: match the surrounding code. No new third-party dependencies other than Sparkle.
- **Never:** `git commit`, `git push`, `gh release`, edit GitHub settings, run Sparkle `generate_keys`, or read or print the Sparkle private key. The human does these.
- Version bump happens **once**, in Task 9 (0.1.49 → 0.1.50 / build 50), not per task.

## Review Focus

1. User on macOS 14.x/15.x installs the new DMG. The app launches, the menu-bar icon shows, and enabling NTFS read-write installs a driver that loads (not minos 27). Tests: Task 1 gate plus Task 2 manual check.
2. User on 0.1.50 (build 50) is offered 0.1.51 (build 51) and **not** offered 0.1.9 or an equal build. Test: Task 6 appcast test asserts `sparkle:version` equals the integer `CFBundleVersion`.
3. The update relaunches the app. The old agent must be gone, the new agent must run from the new bundle, and the NTFS helper must be reinstalled if its bundled copy changed. Tests: Task 3 version-stamp test plus Task 9 manual checklist.
4. Clicking Mount on a WebDAV volume never freezes the AutoVolume UI, gives visible progress, and doesn't beachball Finder. Tests: Task 8 fixes, verified with the Task 7 phase-timing and stall-watchdog logs from the 15.8 machine.
5. A Sparkle update check on a menu-bar (accessory) app surfaces its window in front, not behind other apps. Test: Task 5 manual check.

---

### Task 1: Binary compatibility gate

**Files:**
- Create: `AutoVolume/script/check_binary_compat.sh`
- Create: `AutoVolume/script/tests/test_check_binary_compat.sh`
- Modify: `AutoVolume/script/build_and_run.sh`: run the shell tests at the top (after `cd "$ROOT"`), and run the gate after the last `codesign` and before `--verify`

**Interfaces:**
- Produces: `script/check_binary_compat.sh <App.app> [--print-max-minos]`. Exits 0 when every Mach-O under the bundle has `minos <= LSMinimumSystemVersion` and contains an `arm64` slice. Otherwise exits 1 and prints each offending `path minos=X arch=Y`. With `--print-max-minos`, it prints the highest minos found (for example `14.0`) to stdout and exits 0/1 the same way. Task 6 uses this.

- [ ] **Step 1: Write the failing test.** Create `script/tests/test_check_binary_compat.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/script/check_binary_compat.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_app() { # $1=app dir, $2=Info.plist min, $3=binary minos
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Frameworks"
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $2" "$1/Contents/Info.plist" >/dev/null
  printf 'int main(void){return 0;}\n' > "$TMP/m.c"
  clang -arch arm64 -mmacosx-version-min="$3" -o "$1/Contents/MacOS/Main" "$TMP/m.c"
  printf 'int f(void){return 1;}\n' > "$TMP/f.c"
  clang -arch arm64 -mmacosx-version-min=14.0 -dynamiclib -o "$1/Contents/Frameworks/libF.dylib" "$TMP/f.c"
}

make_app "$TMP/Good.app" 14.0 14.0
"$GATE" "$TMP/Good.app" >/dev/null || { echo "FAIL: good bundle rejected"; exit 1; }
[[ "$("$GATE" "$TMP/Good.app" --print-max-minos)" == "14.0" ]] || { echo "FAIL: max minos not 14.0"; exit 1; }

make_app "$TMP/Bad.app" 14.0 26.0
if "$GATE" "$TMP/Bad.app" > "$TMP/out.txt" 2>&1; then echo "FAIL: minos 26 bundle accepted"; exit 1; fi
grep -q "Contents/MacOS/Main minos=26.0" "$TMP/out.txt" || { echo "FAIL: offender not reported"; cat "$TMP/out.txt"; exit 1; }

mkdir -p "$TMP/X86.app/Contents/MacOS"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$TMP/X86.app/Contents/Info.plist" >/dev/null
clang -arch x86_64 -mmacosx-version-min=14.0 -o "$TMP/X86.app/Contents/MacOS/Main" "$TMP/m.c"
if "$GATE" "$TMP/X86.app" >/dev/null 2>&1; then echo "FAIL: x86_64-only bundle accepted"; exit 1; fi

echo "PASS: check_binary_compat"
```

- [ ] **Step 2: Run it and confirm it fails.** `bash AutoVolume/script/tests/test_check_binary_compat.sh` should fail with `No such file` for the gate.

- [ ] **Step 3: Implement the gate.** Create `script/check_binary_compat.sh`:

```bash
#!/bin/bash
# Fails if any Mach-O in the bundle needs a newer macOS than Info.plist promises,
# or lacks an arm64 slice. Guards against the 0.1.38–0.1.48 regression where
# binaries shipped with minos 26/28 while LSMinimumSystemVersion said 14.0.
set -euo pipefail
APP="${1:?Usage: check_binary_compat.sh <App.app> [--print-max-minos]}"
MODE="${2:-}"
PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

version_gt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$1" && "$1" != "$2" ]]; }

max="0.0"; failed=0
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  archs="$(lipo -archs "$file" 2>/dev/null || true)"
  if [[ " $archs " != *" arm64 "* ]]; then
    echo "${file#$APP/} missing arm64 (archs=$archs)" >&2; failed=1
  fi
  for arch in $archs; do
    minos="$(otool -arch "$arch" -l "$file" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
    [[ -z "$minos" ]] && minos="$(otool -arch "$arch" -l "$file" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
    [[ -z "$minos" ]] && continue
    version_gt "$minos" "$max" && max="$minos"
    if version_gt "$minos" "$PLIST_MIN"; then
      echo "${file#$APP/} minos=$minos arch=$arch (> LSMinimumSystemVersion $PLIST_MIN)" >&2; failed=1
    fi
  done
done < <(find "$APP" -type f -print0)

[[ "$MODE" == "--print-max-minos" ]] && echo "$max"
exit "$failed"
```

The offender lines go to stderr. The test redirects `2>&1`, so the grep still sees them.

- [ ] **Step 4: Run the test and confirm it passes.** `bash AutoVolume/script/tests/test_check_binary_compat.sh` should print `PASS: check_binary_compat`.

- [ ] **Step 5: Wire it into the build.** In `script/build_and_run.sh`, right after `cd "$ROOT"`, add:

```bash
for shell_test in "$ROOT"/script/tests/test_*.sh; do
  bash "$shell_test"
done
```

After the final `codesign --force --sign - "$APP"`, add:

```bash
"$ROOT/script/check_binary_compat.sh" "$APP"
```

- [ ] **Step 6: Confirm the gate catches today's real regression.** Run `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 AutoVolume/script/build_and_run.sh --no-launch`. It **must fail**, listing `Contents/Resources/NTFSDriver/ntfs-3g minos=27.0` and `libntfs-3g.89.dylib minos=27.0`. That failure is correct; Task 2 fixes it. Report the output.

---

### Task 2: Rebuild the NTFS driver for macOS 14.0

**Files:**
- Create: `AutoVolume/script/build_ntfs3g.sh` (a reproducible rebuild; the original build was done by hand)
- Replace: `AutoVolume/Resources/NTFSDriver/ntfs-3g`, `AutoVolume/Resources/NTFSDriver/libntfs-3g.89.dylib`
- Modify: `AutoVolume/docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md`: add a "Rebuild for 14.0" note pointing to the script

**Interfaces:**
- Consumes: the Task 1 gate.
- Produces: two binaries with `minos 14.0`, arm64, and the same install names as today: `ntfs-3g` → `@loader_path/libntfs-3g.89.dylib`, plus `@rpath/libfuse-t.dylib` with `LC_RPATH /usr/local/lib`.

Background: `2026-09-20-ntfs-driver-findings.md` item 2 has the original build recipe (the `macos-fuse-t/ntfs-3g` fork, linked against FUSE-T). `/usr/local/lib/libfuse-t.dylib` itself has minos 13.0, so FUSE-T is fine. The FUSE-T headers were at `/usr/local/include/fuse` at the time. If they are missing now, get them from the FUSE-T pkg with `pkgutil --expand-full AutoVolume/Resources/NTFSDriver/fuse-t-installer.pkg <tmp>`, then find the `include/fuse` directory inside the payload and point `CPPFLAGS` at it.

- [ ] **Step 1: Write `script/build_ntfs3g.sh`.**

```bash
#!/bin/bash
# Rebuilds the bundled ntfs-3g for the app's minimum macOS (14.0). Reproducible
# replacement for the manual build in docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${NTFS3G_WORK:-$ROOT/.ntfs3g-build}"
FUSE_INCLUDE="${FUSE_INCLUDE:-/usr/local/include/fuse}"
FUSE_LIB="${FUSE_LIB:-/usr/local/lib}"
[[ -f "$FUSE_INCLUDE/fuse.h" ]] || { echo "error: fuse.h not found in $FUSE_INCLUDE (set FUSE_INCLUDE)" >&2; exit 1; }

rm -rf "$WORK"; git clone --depth 1 https://github.com/macos-fuse-t/ntfs-3g "$WORK"
cd "$WORK"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export CPPFLAGS="-I$FUSE_INCLUDE"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0 -L$FUSE_LIB -lfuse-t -Wl,-rpath,$FUSE_LIB"
./autogen.sh
./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external \
  --sbindir=/usr/local/bin --bindir=/usr/local/bin --disable-static
make -j"$(sysctl -n hw.ncpu)"

OUT="$ROOT/Resources/NTFSDriver"
cp src/.libs/ntfs-3g "$OUT/ntfs-3g"
cp libntfs-3g/.libs/libntfs-3g.89.dylib "$OUT/libntfs-3g.89.dylib"
install_name_tool -id @loader_path/libntfs-3g.89.dylib "$OUT/libntfs-3g.89.dylib"
old_lib="$(otool -L "$OUT/ntfs-3g" | awk '/libntfs-3g\.89\.dylib/{print $1}')"
install_name_tool -change "$old_lib" @loader_path/libntfs-3g.89.dylib "$OUT/ntfs-3g"
for bin in "$OUT/ntfs-3g" "$OUT/libntfs-3g.89.dylib"; do
  old_fuse="$(otool -L "$bin" | awk '/libfuse-t/{print $1}')"
  [[ "$old_fuse" == "@rpath/libfuse-t.dylib" ]] || install_name_tool -change "$old_fuse" @rpath/libfuse-t.dylib "$bin"
done
otool -l "$OUT/ntfs-3g" | grep -q "path $FUSE_LIB" || install_name_tool -add_rpath "$FUSE_LIB" "$OUT/ntfs-3g"
chmod +x "$OUT/ntfs-3g"
echo "Built:"; for b in "$OUT/ntfs-3g" "$OUT/libntfs-3g.89.dylib"; do
  echo "$(basename "$b") $(lipo -archs "$b") minos=$(otool -l "$b" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"; done
```

Add `.ntfs3g-build/` to the repo `.gitignore`. Brew build deps (automake, autoconf, libtool, pkg-config) are already installed under `/opt/homebrew`. If `configure` pulls in `libgcrypt`/`gnutls` from Homebrew, **stop and report**: that would add non-system dylib dependencies and needs a decision. The shipped binary today links only `libSystem`, `CoreFoundation`, `libfuse-t`, and `libntfs-3g`.

- [ ] **Step 2: Run it and check the output.** Run `bash AutoVolume/script/build_ntfs3g.sh`. Expected: both files show `arm64 minos=14.0`. Then run `otool -L` on both. Expected: exactly the same four dependencies as before, and no `/opt/homebrew` paths.

- [ ] **Step 3: Smoke-test the binary.** Run `AutoVolume/Resources/NTFSDriver/ntfs-3g --version 2>&1 | head -2`. Expected: the ntfs-3g version banner and no dyld error.

- [ ] **Step 4: Run the full build.** Run it with the SDKROOT prefix. Expected: the gate passes, and so do all manual tests.

---

### Task 3: Reinstall the NTFS helper when the bundled copy changes

Sparkle replaces `/Applications/AutoVolume.app`, but the root-owned copies in `/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver` (helper, `libAutoVolumeShared.dylib`, ntfs-3g) stay stale. Today `isHelperInstalled()` only checks that the daemon plist exists, so an updated app would keep driving an old helper against an ABI-changed shared dylib.

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeShared/NTFSDriverInstaller.swift`
- Modify: `AutoVolume/Sources/AutoVolumeShared/NTFSAutoMountService.swift` (the place that calls `installPlan`, around line 94)
- Test: `AutoVolume/ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces:
  - `NTFSDriverPaths.versionStampPath: String`, equal to `NTFSDriverPaths.installDirectory + "/installed-build"`.
  - `NTFSDriverInstaller.init(fileManager:fuseTMarkerPath:versionStampPath:daemonPlistPath:)`. The new parameters default to `NTFSDriverPaths.versionStampPath` and `NTFSHelperSocket.daemonPlistInstallPath`, and `isHelperInstalled()` uses the injected `daemonPlistPath`.
  - `func isHelperInstalled(expectedBuild: String) -> Bool`: true only if the daemon plist exists **and** the stamp file's trimmed contents equal `expectedBuild`.
  - `installPlan(..., bundleBuild: String)`: new last parameter. The shell script writes `printf '%s' '<build>' > <stamp>` after copying and sets it to `chmod 644`.
  - Keep the zero-argument `isHelperInstalled()` and `isFullyInstalled()` working for existing callers (plist presence only).

- [ ] **Step 1: Write the failing tests** (and register them in `tests`):

```swift
func testNTFSDriverInstallerTreatsMismatchedBuildStampAsNotInstalled() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stamp = directory.appendingPathComponent("installed-build")
    let plist = directory.appendingPathComponent("daemon.plist")
    let installer = NTFSDriverInstaller(fuseTMarkerPath: "/nonexistent", versionStampPath: stamp.path, daemonPlistPath: plist.path)

    try "49".write(to: stamp, atomically: true, encoding: .utf8)
    try expect(!installer.isHelperInstalled(expectedBuild: "49"), "Matching stamp without daemon plist must not count as installed")

    try "x".write(to: plist, atomically: true, encoding: .utf8)
    try expect(!installer.isHelperInstalled(expectedBuild: "50"), "Stamp 49 must not satisfy expected build 50")
    try expect(installer.isHelperInstalled(expectedBuild: "49"), "Matching stamp plus daemon plist counts as installed")
    try expect(installer.isHelperInstalled(), "Legacy isHelperInstalled() still checks plist presence only")

    try FileManager.default.removeItem(at: stamp)
    try expect(!installer.isHelperInstalled(expectedBuild: "49"), "Missing stamp (pre-0.1.50 install) must trigger reinstall")
}

func testNTFSDriverInstallerInstallPlanWritesBuildStamp() throws {
    let plan = NTFSDriverInstaller().installPlan(
        bundledInstallerPkgPath: "/b/fuse-t.pkg", bundledHelperExecutablePath: "/b/helper",
        bundledDaemonPlistPath: "/b/daemon.plist", bundledNTFS3GPath: "/b/ntfs-3g",
        bundledNTFS3GDylibPath: "/b/libntfs-3g.89.dylib", bundledSharedDylibPath: "/b/libAutoVolumeShared.dylib",
        bundleBuild: "50"
    )
    let script = plan.arguments.joined(separator: " ")
    try expect(script.contains("printf '%s' '50' > '\(NTFSDriverPaths.versionStampPath)'"), "Install plan must write build stamp 50")
}
```

- [ ] **Step 2: Run the build and confirm it fails.** Expected: a compile error, because `versionStampPath:` / `bundleBuild:` don't exist yet.

- [ ] **Step 3: Implement.** Add the stamp path constant next to the other `NTFSDriverPaths` members, the new init parameter, `isHelperInstalled(expectedBuild:)`, and the stamp write at the end of the install script (before the `launchctl bootout`). In `NTFSAutoMountService`, derive `bundleBuild` from `Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"`, then decide whether to install with `isFUSETInstalled() && isHelperInstalled(expectedBuild: bundleBuild)` instead of `isFullyInstalled()`. Keep the existing "install at most once per instance" guard (the comment at line 38).

- [ ] **Step 4: Run the build.** Expected: all manual tests pass.

---

### Task 4: Fetch, link, embed, and sign Sparkle in the raw-swiftc build

**Prerequisite (human, not the agent):** the AutoVolume EdDSA public key must exist at `AutoVolume/Resources/SparklePublicEDKey.txt` (one line, base64). If the file is missing, **stop and report**. Do not run `generate_keys`.

**Files:**
- Modify: `AutoVolume/Package.swift`
- Modify: `AutoVolume/script/build_and_run.sh`
- Modify: `AutoVolume/Resources/Info.plist`
- Modify: repo `.gitignore` (ignore `AutoVolume/.build/`)

**Interfaces:**
- Produces: a built app with `Contents/Frameworks/Sparkle.framework`, where `import Sparkle` compiles in the app target. `Info.plist` gains `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` (true), and `SUScheduledCheckInterval` (86400).

- [ ] **Step 1: Add the dependency.** In `Package.swift`, add `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")` to `dependencies`. On the `AutoVolumeApp` executable target, add `.product(name: "Sparkle", package: "Sparkle")`. SPM is used **only** to fetch artifacts; the real build stays raw `swiftc`.

- [ ] **Step 2: Resolve.** Run `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 swift package resolve`. Expected: `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework` and `.build/artifacts/sparkle/Sparkle/bin/sign_update` exist. If resolve hits the SDK 27 `-target-arch-variant` bug, report it. Don't work around it by editing the toolchain.

- [ ] **Step 3: Update the build script.** In `script/build_and_run.sh`:
  - Near the top:

    ```bash
    SPARKLE_XCFW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    if [[ ! -d "$SPARKLE_XCFW/Sparkle.framework" ]]; then
      swift package resolve
    fi
    [[ -d "$SPARKLE_XCFW/Sparkle.framework" ]] || { echo "error: Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
    SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$ROOT/Resources/SparklePublicEDKey.txt")"
    ```

  - Add these flags to the **AutoVolumeApp** `swiftc` call only: `-F "$SPARKLE_XCFW" -framework Sparkle`. The existing `-rpath @executable_path/../Frameworks` already covers loading.
  - After bundle assembly: `ditto "$SPARKLE_XCFW/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"`. Use `ditto`, which preserves the framework's symlinks.
  - After copying Info.plist, add the keys:

    ```bash
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://mengyuefeitian.github.io/AutoVolume/appcast.xml" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$APP/Contents/Info.plist"
    ```

  - Signing order (inside out, before the existing outer `codesign "$APP"`):

    ```bash
    codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
    ```

    First check these paths with `ls` against the resolved framework version, and adjust if Sparkle's layout differs.

- [ ] **Step 4: Verify.** Run the build with `--verify` and the SDKROOT prefix. Expected: manual tests pass, the Task 1 gate passes (Sparkle's minos is ≤ 14.0; if not, report it), and `codesign --verify --deep --strict` passes. `spctl` rejection is expected for ad-hoc signing and is fine. Then run `plutil -p dist/AutoVolume.app/Contents/Info.plist | grep SU`, which should show the 4 keys.

---

### Task 5: UpdateService, "检查更新…" menu item, and accessory-app UI surfacing

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeApp/UpdateService.swift`
- Create: `AutoVolume/Sources/AutoVolumeShared/UpdateSchedule.swift`
- Modify: `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift` (`AppDelegate` owns `UpdateService`)
- Modify: `AutoVolume/Sources/AutoVolumeApp/StatusBarController.swift` (menu item)
- Modify: `AutoVolume/script/build_and_run.sh` (add `UpdateService.swift` to the app `swiftc` file list and `UpdateSchedule.swift` to the shared list)
- Test: `AutoVolume/ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes: Sparkle linked by Task 4.
- Produces:
  - `public enum UpdateSchedule { public static let automaticallyChecks = true; public static let checkInterval: TimeInterval = 86400 }` in the shared lib.
  - `@MainActor final class UpdateService: NSObject, SPUStandardUserDriverDelegate` with `init()` and `func checkForUpdates()`.
  - `StatusBarController.init(viewModel:updateService:)`.

- [ ] **Step 1: Write the failing test.** Register it as `("UpdateSchedule checks daily", testUpdateScheduleChecksDaily)`.

```swift
func testUpdateScheduleChecksDaily() throws {
    try expect(UpdateSchedule.automaticallyChecks, "Automatic update checks must be on")
    try expect(UpdateSchedule.checkInterval == 86400, "Update check interval must be one day")
}
```

- [ ] **Step 2: Run the build and confirm it fails** because `UpdateSchedule` isn't found.

- [ ] **Step 3: Implement `UpdateSchedule.swift`** (the enum above), then `UpdateService.swift`:

```swift
import AppKit
import Sparkle
import AutoVolumeShared

/// Wraps Sparkle's standard updater: daily background checks plus the
/// "检查更新… / Check for Updates…" menu item. Download, EdDSA verification,
/// install and relaunch are Sparkle's own standard UI.
@MainActor
final class UpdateService: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.automaticallyChecksForUpdates = UpdateSchedule.automaticallyChecks
        controller.updater.updateCheckInterval = UpdateSchedule.checkInterval
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // Menu-bar (LSUIElement) app: opt into gentle reminders so scheduled
    // checks surface the update window in front instead of behind other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
```

If the Sparkle version you resolved names these delegate methods differently, go by its `SPUStandardUserDriverDelegate.h`.

In `AppDelegate`, add `private var updateService: UpdateService?`. Create it in `applicationDidFinishLaunching` **before** `StatusBarController`, and pass it in. In `StatusBarController.showContextMenu()`, insert `NSMenuItem(title: localized("检查更新…", "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")` right after "关于 / About", plus `@objc private func checkForUpdates() { AutoVolumeLogger.shared.info("Check for updates requested"); updateService.checkForUpdates() }`.

- [ ] **Step 4: Run the build.** Expected: the new test passes along with all existing ones.

- [ ] **Step 5: Do a manual smoke check.** Launch `dist/AutoVolume.app`, right-click the menu-bar icon, and click "检查更新…". Before the first appcast is published, Sparkle's window should come to the front with a feed error or "up to date", not appear behind other apps. Report what appeared.

---

### Task 6: Release script that generates a correct appcast entry

**Files:**
- Create: `AutoVolume/script/publish_release.sh`
- Create: `AutoVolume/script/tests/test_publish_release.sh`
- Create: `docs/appcast.xml` at the **repo root** (`/Users/xiaoan/Documents/Playground/docs/appcast.xml`; Pages serves `main:/docs`)

**Interfaces:**
- Consumes: `script/check_binary_compat.sh --print-max-minos` (Task 1).
- Produces: `publish_release.sh <path-to-dmg>`. It reads `CFBundleShortVersionString` and `CFBundleVersion` from `dist/AutoVolume.app/Contents/Info.plist`, signs the DMG with `sign_update`, and **inserts** a new `<item>` at the top of `docs/appcast.xml`. Env overrides for tests: `APP_BUNDLE`, `APPCAST_PATH`, `SIGN_UPDATE`, `SPARKLE_PRIVATE_KEY_FILE` (default `$HOME/.config/autovolume/sparkle_signing_key`).

- [ ] **Step 1: Write the failing test.** Create `script/tests/test_publish_release.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
APPB="$TMP/AutoVolume.app"; mkdir -p "$APPB/Contents/MacOS"
for kv in "CFBundleShortVersionString string 0.1.50" "CFBundleVersion string 50" "LSMinimumSystemVersion string 14.0"; do
  /usr/libexec/PlistBuddy -c "Add :$kv" "$APPB/Contents/Info.plist" >/dev/null; done
printf 'int main(void){return 0;}\n' > "$TMP/m.c"
clang -arch arm64 -mmacosx-version-min=14.0 -o "$APPB/Contents/MacOS/AutoVolume" "$TMP/m.c"
printf '#!/bin/bash\necho '"'"'sparkle:edSignature="SIG==" length="123"'"'"'\n' > "$TMP/sign_update"; chmod +x "$TMP/sign_update"
touch "$TMP/key" "$TMP/AutoVolume-0.1.50-local.dmg"
cat > "$TMP/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AutoVolume Updates</title>
  </channel>
</rss>
XML
APP_BUNDLE="$APPB" APPCAST_PATH="$TMP/appcast.xml" SIGN_UPDATE="$TMP/sign_update" SPARKLE_PRIVATE_KEY_FILE="$TMP/key" \
  bash "$ROOT/script/publish_release.sh" "$TMP/AutoVolume-0.1.50-local.dmg" >/dev/null
X="$TMP/appcast.xml"
xmllint --noout "$X" || { echo "FAIL: appcast not well-formed"; exit 1; }
grep -q "<sparkle:version>50</sparkle:version>" "$X" || { echo "FAIL: sparkle:version must be integer CFBundleVersion"; exit 1; }
grep -q "<sparkle:shortVersionString>0.1.50</sparkle:shortVersionString>" "$X" || { echo "FAIL: short version"; exit 1; }
grep -q "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>" "$X" || { echo "FAIL: min system version"; exit 1; }
grep -q 'releases/download/v0.1.50/AutoVolume-0.1.50-local.dmg' "$X" || { echo "FAIL: download url"; exit 1; }
[[ "$(grep -c 'length=' "$X")" == "1" ]] || { echo "FAIL: duplicate length attribute"; exit 1; }
echo "PASS: publish_release"
```

- [ ] **Step 2: Run it and confirm it fails** (the script is missing).

- [ ] **Step 3: Implement `script/publish_release.sh`.** Base it on InceptLaunch's `script/publish_release.sh` with these **required differences**:
  - `sparkle:version` is `CFBundleVersion` (integer) and `shortVersionString` is `CFBundleShortVersionString`, both read with PlistBuddy from `$APP_BUNDLE`.
  - `minimumSystemVersion` is `"$ROOT/script/check_binary_compat.sh" "$APP_BUNDLE" --print-max-minos`. If the gate exits non-zero, abort.
  - Download URL: `https://github.com/mengyuefeitian/AutoVolume/releases/download/v${SHORT}/$(basename "$DMG")`.
  - Insert the `<item>` right after the `<title>` line in `<channel>` using a python3 or awk text insertion, instead of printing it for manual pasting. Refuse with an error if an item with the same `<sparkle:version>` already exists.
  - Don't add a `length=` attribute; `sign_update` output already contains it.

- [ ] **Step 4: Run the test and confirm it passes.**

- [ ] **Step 5: Create the initial feed.** Create the repo-root `docs/appcast.xml` with the empty channel skeleton from the test fixture, plus `<link>https://mengyuefeitian.github.io/AutoVolume/appcast.xml</link>`.

---

### Task 7: Diagnostics: environment, WebDAV phase timing, main-thread stall watchdog, NTFS logging, diagnostics export

Background: the WebDAV stall only reproduces on macOS 15.8, and NTFS has **no logging at all** on the agent side.
- `NTFSAutoMountService` and the DiskArbitration callbacks in `AutoVolumeAgent/main.swift` never call `AutoVolumeLogger`.
- The helper writes one line per mount to root-owned `/var/log/com.autovolume.ntfshelper.log`, which "查看日志" (View Logs) doesn't open.
- After mounting, ntfs-3g daemonizes. Its runtime I/O errors (for example, a failed copy) go only to the macOS unified log.

The goal: one "导出诊断信息… / Export Diagnostics…" click on the user's machine gives us everything needed.

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeShared/DiagnosticsContext.swift` (current-operation tag, phase timer)
- Create: `AutoVolume/Sources/AutoVolumeApp/MainThreadStallWatchdog.swift`
- Create: `AutoVolume/Sources/AutoVolumeShared/DiagnosticsExporter.swift`
- Modify: `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift`, `AutoVolume/Sources/AutoVolumeApp/StatusBarController.swift`, `AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift`
- Modify: `AutoVolume/Sources/AutoVolumeShared/AutoVolumeLogger.swift` (Logs/ directory, per-file loggers, migration, 7-day retention)
- Modify: `AutoVolume/Sources/AutoVolumeShared/NTFSAutoMountService.swift`, `AutoVolume/Sources/AutoVolumeAgent/main.swift`, `AutoVolume/Sources/AutoVolumeNTFSHelper/main.swift`
- Modify: `AutoVolume/script/build_and_run.sh` (add the new files to the shared and app file lists)
- Test: `AutoVolume/ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces:
  - `public final class PhaseTimer { public init(operation: String, logger: AutoVolumeLogger = .shared); public func mark(_ phase: String); public func finish(result: String) }`. `mark` logs `"<operation> phase=<phase> ms=<since previous mark> total_ms=<since init>"` at INFO. `finish` logs `"<operation> finished result=<result> total_ms=<n>"`.
  - `public final class DiagnosticsContext { public static let shared; public func begin(_ operation: String); public func end(); public var current: String? }` (thread-safe via `NSLock`).
  - `@MainActor final class MainThreadStallWatchdog { init(thresholdMs: Int = 400); func start() }`.
  - `public struct DiagnosticsExporter { public init(...injectable paths and a CommandRunner...); public func export(to directory: URL) throws -> URL }`, which returns the path of `AutoVolume-diagnostics-<yyyyMMdd-HHmmss>.zip`.

- [ ] **Step 0: Move logs into their own directory and split NTFS into its own file** (user requirement, 2026-09-24).

  Today `AutoVolume.log` sits in the root of `~/Library/Application Support/AutoVolume/`, next to `volumes.json`, `credentials.*`, `settings.json`, and so on. NTFS and network-mount events end up interleaved in one file. Retention is only **24 hours** (`retentionInterval` default), which is why earlier manual mounts were gone from the log.

  New layout:
  - Log directory: `~/Library/Application Support/AutoVolume/Logs/`
  - `AutoVolume.log`: app lifecycle, environment line, UI actions, main-thread stall watchdog, network mounts (SMB/WebDAV/AFP/NFS, both app and agent checks), and updates. These stay in one file on purpose: the stall watchdog, the WebDAV phase timings, and agent checks must be read on one timeline to explain a stall.
  - `NTFS.log`: everything NTFS from both the app and the agent (DiskArbitration events, eligibility and skip reasons, driver install, helper request/response). NTFS is a separate subsystem (disks, root helper, driver) and would otherwise be buried under the agent's periodic network checks.
  - The root helper keeps writing to `/var/log/com.autovolume.ntfshelper.log` (root-owned, rotated by newsyslog). "查看日志" (View Logs) doesn't show it; the diagnostics export includes it.
  - Retention: 7 days per file (`7 * 24 * 60 * 60`), still capped at 10 MB each.

  Required API (keep the existing init source-compatible):
  - Add `fileName: String = "AutoVolume.log"` and `settingsDirectory: URL? = nil` parameters to `AutoVolumeLogger.init`.
  - `settingsStore` must keep defaulting to `JSONAppSettingsStore(directory: <App Support/AutoVolume>)`. **Not** the Logs directory, or the log-level setting is lost.
  - The lock file becomes `.<fileName>.lock`.
  - `public static let shared` points at `Logs/AutoVolume.log`, and a new `public static let ntfs` points at `Logs/NTFS.log`, both with the 7-day retention.
  - `public static func migrateLegacyLogIfNeeded(appSupportDirectory:)`: if `<appSupport>/AutoVolume.log` exists and `Logs/AutoVolume.log` does not, create `Logs/` and move it (and delete `<appSupport>/.AutoVolume.log.lock`). Call it at app launch and at agent start, before the first log line.
  - All NTFS logging in this task goes through `AutoVolumeLogger.ntfs`. "查看日志" opens the `Logs/` directory.

  Tests to add (register them):

```swift
func testLoggerWritesToNamedFileInGivenDirectoryAndKeepsSettingsElsewhere() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("Logs")
    let logger = AutoVolumeLogger(directory: logs, fileName: "NTFS.log", settingsDirectory: root)
    logger.info("NTFS disk appeared bsd=disk4s1")
    try expect(logger.logFileURL.path == logs.appendingPathComponent("NTFS.log").path, "logger must write Logs/NTFS.log")
    let text = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(text.contains("NTFS disk appeared bsd=disk4s1"), "NTFS line missing")
    try expect(!FileManager.default.fileExists(atPath: logs.appendingPathComponent("settings.json").path), "settings must not move into Logs/")
}

func testLegacyLogMigratesIntoLogsDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "old line\n".write(to: root.appendingPathComponent("AutoVolume.log"), atomically: true, encoding: .utf8)
    AutoVolumeLogger.migrateLegacyLogIfNeeded(appSupportDirectory: root)
    try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("AutoVolume.log").path), "legacy log must be moved")
    let moved = try String(contentsOf: root.appendingPathComponent("Logs/AutoVolume.log"), encoding: .utf8)
    try expect(moved.contains("old line"), "legacy content must survive migration")
}
```

  Update any existing test that assumes the 24 h default retention (only if one exists; tests that pass `retentionInterval:` explicitly are unaffected).

- [ ] **Step 1: Write the failing tests** (register them all):

```swift
func testPhaseTimerLogsEachPhaseWithOperationName() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory)
    let timer = PhaseTimer(operation: "webdav-mount home", logger: logger)
    timer.mark("connectivity")
    timer.mark("mount-command")
    timer.finish(result: "success")
    let log = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(log.contains("webdav-mount home phase=connectivity ms="), "connectivity phase missing")
    try expect(log.contains("webdav-mount home phase=mount-command ms="), "mount-command phase missing")
    try expect(log.contains("webdav-mount home finished result=success total_ms="), "finish line missing")
}

func testDiagnosticsContextTracksCurrentOperation() throws {
    let context = DiagnosticsContext()
    try expect(context.current == nil, "No operation initially")
    context.begin("webdav-mount home")
    try expect(context.current == "webdav-mount home", "begin sets current")
    context.end()
    try expect(context.current == nil, "end clears current")
}

func testDiagnosticsExporterBundlesLogsAndRedactsSecrets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let appLog = root.appendingPathComponent("AutoVolume.log")
    try "2026-09-24T10:00:00.000+08:00 [INFO] mount https://user:hunter2@nas/x\n".write(to: appLog, atomically: true, encoding: .utf8)
    let exporter = DiagnosticsExporter(appLogURL: appLog,
                                       helperLogURL: root.appendingPathComponent("missing-helper.log"),
                                       volumesConfigURL: root.appendingPathComponent("missing-volumes.json"),
                                       unifiedLogWindow: nil)
    let zip = try exporter.export(to: root)
    try expect(FileManager.default.fileExists(atPath: zip.path), "zip not created")
    let unzipped = root.appendingPathComponent("out")
    let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzip.arguments = ["-x", "-k", zip.path, unzipped.path]; try unzip.run(); unzip.waitUntilExit()
    let files = try FileManager.default.subpathsOfDirectory(atPath: unzipped.path)
    try expect(files.contains { $0.hasSuffix("AutoVolume.log") }, "app log missing from bundle")
    try expect(files.contains { $0.hasSuffix("environment.txt") }, "environment.txt missing")
    let bundledLog = try String(contentsOf: unzipped.appendingPathComponent(files.first { $0.hasSuffix("AutoVolume.log") }!), encoding: .utf8)
    try expect(!bundledLog.contains("hunter2"), "password leaked into diagnostics")
}
```

`AutoVolumeLogger.init(directory:retentionInterval:maxBytes:settingsStore:)` already exists. Don't break its existing callers in ManualTests (lines ~236, 362, 421).

- [ ] **Step 2: Run the build and confirm it fails** (missing types).

- [ ] **Step 3: Implement.**
  - `PhaseTimer` / `DiagnosticsContext`: small classes as specified, with timing from `DispatchTime.now().uptimeNanoseconds`.
  - **Environment line at launch** (app and agent): in `applicationDidFinishLaunching` and at agent start, log `"Environment app=<CFBundleShortVersionString>(<CFBundleVersion>) macOS=<ProcessInfo.processInfo.operatingSystemVersionString> arch=<uname machine>"`.
  - **Main-thread stall watchdog** (app only, started in `applicationDidFinishLaunching`):
    - A background `DispatchSourceTimer` fires every 200 ms and posts `DispatchQueue.main.async { lastPong = now }`.
    - If `now - lastPong > thresholdMs`, log once per stall at WARN: `"Main thread stalled ≥<n>ms during <DiagnosticsContext.shared.current ?? "idle">"`.
    - When main recovers, log `"Main thread recovered after <n>ms"`.
  - **WebDAV/mount phases:** in `AppViewModel.mount(_:password:)`, create `PhaseTimer(operation: "\(config.protocolType.rawValue)-mount \(config.name)")` and pass it down.
    - Mark phases in `runMountCommand`, `runMountWithRecovery`, and `openMountedVolume`: `connectivity`, `prepare`, `mount-command`, `stale-check`, `response-wait`, `expose`, `response-wait-2`, `refresh`, `finder-cleanup`, `finder-open`.
    - On error, call `finish(result: "failed: <message>")`.
    - Also log the osascript exit code and redacted stderr for every mount command, including successful ones.
  - **NTFS agent side:**
    - In the DiskArbitration appeared, description-changed, and disappeared callbacks, log bsdName, volume kind, name, and path.
    - In `NTFSAutoMountService`, log every branch with its reason:
      - setting disabled → onboarding alert
      - already owned by our driver → skip
      - debounced → skip
      - install started, then finished with exit code, redacted stderr, and duration
      - helper request sent: device → mountPoint
      - helper response: success/message and duration
      - volume recorded
      - disappeared → cleanup
    - Use `NTFS` as a prefix, for example `"NTFS disk appeared bsd=disk4s1 kind=ntfs name=MyDisk path=/Volumes/MyDisk"`.
  - **NTFS helper side:**
    - Log the full ntfs-3g argument list, exit code, stdout+stderr, and duration.
    - After a successful mount, start `/usr/bin/log stream --style compact --predicate 'process == "ntfs-3g" OR process BEGINS WITH "go-nfsv4"'`. Send its stdout to the helper's stderr (already `/var/log/com.autovolume.ntfshelper.log`, rotated by newsyslog), so copy-time errors from ntfs-3g and FUSE-T's NFS server are recorded.
    - Keep one stream process while at least one NTFS volume is mounted, and terminate it after the last unmount.
    - Before writing this, check the FUSE-T server's actual process name with `ps aux | grep -i fuse` while an NTFS volume is mounted, and use it in the predicate.
  - **`DiagnosticsExporter.export(to:)`** creates a temp folder containing:
    - `Logs/AutoVolume.log` and `Logs/NTFS.log` (redacted via `CommandResult.redacted`).
    - `ntfshelper.log`, copied from `/var/log/com.autovolume.ntfshelper.log` if readable.
    - `environment.txt` with `sw_vers`, `uname -m`, app version, `mount` output, and `ls -la /Library/PrivilegedHelperTools/com.autovolume.ntfsdriver`.
    - `volumes.json` with `username` fields replaced by `<redacted>`. Never include `credentials.*`.
    - `unified.log`, from `/usr/bin/log show --last <window> --style compact --predicate 'process == "ntfs-3g" OR process BEGINS WITH "go-nfsv4" OR process == "webdavfs_agent" OR process == "NetAuthAgent" OR process == "AutoVolume" OR process == "AutoVolumeAgent"'`, when `unifiedLogWindow` is non-nil. The default is `"2h"`. Run it with a 30 s timeout.
    - It then zips with `/usr/bin/ditto -c -k --keepParent` into `directory`.
  - **Menu item:** in `StatusBarController.showContextMenu()`, add `localized("导出诊断信息…", "Export Diagnostics…")` after "查看日志" (View Logs). It runs the export on a background queue into `~/Desktop`, then reveals the zip with `NSWorkspace.shared.activateFileViewerSelecting([zip])`. On failure, it shows an `NSAlert` with the error.

- [ ] **Step 4: Run the build.** Expected: all tests pass.

- [ ] **Step 5: Manual check.**
  - Launch the app and mount `home`. `AutoVolume.log` should show the `Environment` line and the `webdav-mount home phase=...` lines.
  - Click "导出诊断信息…". A zip appears on the Desktop, and it contains no passwords (`grep -r` for the saved WebDAV password must find nothing).
  - Paste the phase lines into the report.

---

### Task 8: WebDAV mount stall

**Preamble:** the stall reproduces only on macOS 15.8. This task fixes the defects that are wrong on every OS. The 15.8-specific cause will be decided from Task 7's logs after the user runs 0.1.50 there. Do not change the mount mechanism (osascript `mount volume`) in this task.

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift`
- Modify: `AutoVolume/Sources/AutoVolumeApp/ContentView.swift`
- Test: `AutoVolume/ManualTests/AutoVolumeManualTests.swift` (only if logic moves into `AutoVolumeShared`)

**Interfaces:**
- Produces: `AppViewModel.refreshVolumeStatusesAsync() async`, which computes statuses off-main and assigns `volumeStatuses` / `alerts` on the `MainActor`. `mount`/`unmount` no longer mutate observable state from a background thread. Per-phase timing logs are written at `info` level: `WebDAV mount phase=<name> ms=<n>`.

- [ ] **Step 1: Mark the in-flight operation.** Wrap the mount and unmount flows in `DiagnosticsContext.shared.begin("webdav-mount <name>")` / `end()` (Task 7), so the stall watchdog names the operation.
- [ ] **Step 2: Keep observable mutations on main.** Split `refreshVolumeStatuses()` into `computeVolumeStatuses(volumes:alerts:) -> [ID: VolumeStatus]` (a pure function over `mountStateProvider`, safe off-main) and a `@MainActor` assignment. `refreshAlerts()` called from a background context must hop to main for the assignment. The ContentView catch paths and `delete()` must call the async variant instead of the synchronous one.
- [ ] **Step 3: Remove redundant probes.** `runMountCommand` calls `waitForMountedVolumeResponse` after `runMountWithRecovery` already did. Drop the second call unless `expose` changed the health-check path (SMB subpath only).
- [ ] **Step 4: Show progress while mounting.** `hideListWindow()` closes the popover as soon as Mount is clicked, so the user sees nothing for several seconds. While any volume is in `workingVolumeIDs`, set the status-item button image to `arrow.triangle.2.circlepath` (SF Symbol, macOS 11+), and restore `externaldrive.connected.to.line.below` when the set becomes empty. StatusBarController observes this via a callback that `ContentView` invokes.
- [ ] **Step 5: Guard the Finder window-cleanup AppleScript.** Run it with a 3 s timeout (`with timeout of 3 seconds` inside the script), and skip it entirely when no Finder window targets any of the cleanup paths. Check that with a single fast `tell application "Finder" to get POSIX path of (target of every Finder window as alias list)` call, wrapped in `try`.
- [ ] **Step 6:** Build and run the manual tests. Mount `home` from the UI, and paste the `phase=` log lines into the report.

---

### Task 9: Version bump, package, and hand off to the human

- [ ] **Step 1:** In `AutoVolume/Resources/Info.plist`, set `CFBundleShortVersionString` to `0.1.50` and `CFBundleVersion` to `50`.
- [ ] **Step 2:** Run `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 AutoVolume/script/build_and_run.sh --verify`. The shell tests, manual tests, gate, and codesign verify must all pass.
- [ ] **Step 3:** Run `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 AutoVolume/script/package_dmg.sh 0.1.50`, then run the gate again on the app inside the mounted DMG.
- [ ] **Step 4:** Report `dist/AutoVolume-0.1.50-local.dmg` to the human. **Do not** run `publish_release.sh` for real, create a GitHub release, commit, or push.

Human release checklist (not the agent's job):

1. Generate the key pair once, and keep the private key outside git:
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account autovolume`
   `... -x ~/.config/autovolume/sparkle_signing_key`
   `... -p > AutoVolume/Resources/SparklePublicEDKey.txt`
2. Self-test the 0.1.50 DMG on this Mac. Ideally, also test on a macOS 14/15 machine or VM: the icon appears, WebDAV mounts smoothly, and NTFS works.
3. Run `publish_release.sh`, commit, merge to `main` (Pages serves `main:/docs`), and create the GitHub release `v0.1.50` with the DMG. That fixes the stuck 15.8 user, who has to reinstall manually once.
4. Upgrade test: publish 0.1.51, then confirm that 0.1.50 offers it, installs with one click, relaunches, the agent restarts, and the NTFS helper reinstalls (one admin prompt).
