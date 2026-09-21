# AutoVolume Project Rules

## Build environment note (Swift toolchain / SDK)

On this machine, the default `swiftc` (installed via `swiftly`, Swift 6.3.3) fails to compile any multi-file target that imports Foundation when paired with the default `MacOSX.sdk` (`MacOSX27.0.sdk`) — it hits a reproducible `error: unknown argument: '-target-arch-variant'` inside the ClangImporter's Foundation module build. This reproduces identically on Swift 6.2.4 and 6.3.3, and is specific to SDK 27.0 (confirmed via minimal repro: 2+ Swift files each importing Foundation, `-emit-module`, any SDK-27.0-based invocation). The older `MacOSX26.5.sdk` (also shipped under `/Library/Developer/CommandLineTools/SDKs/`) does not have this bug.

**Always build/test with these env vars set** until this is fixed upstream or a newer Xcode/CLT resolves it:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch
```

(`MACOSX_DEPLOYMENT_TARGET=14.0` matches `Package.swift`'s `platforms: [.macOS(.v14)]`.) Every command below that invokes `script/build_and_run.sh` implicitly needs this prefix.

## Release workflow after code changes

After finishing any code change in this project (including small/intermediate iterations, not just final "done" states), automatically:

1. **Bump the version** in `Resources/Info.plist`:
   - `CFBundleShortVersionString`: increment the patch number (e.g. `0.1.45` → `0.1.46`)
   - `CFBundleVersion`: match the new patch number as a plain integer (e.g. `46`)
2. **Build and verify**: run `script/build_and_run.sh --no-launch` (compiles shared/agent/app, runs the manual test suite, code-signs the app bundle). All manual tests must pass before continuing.
3. **Package a DMG**: run `script/package_dmg.sh <version>` (e.g. `script/package_dmg.sh 0.1.46`), matching the version bumped in step 1.
4. **Hand back to the user for self-testing**: tell the user the new DMG path (`dist/AutoVolume-<version>-local.dmg`) and ask them to test it themselves before it's considered done. Do not mark the task complete on your own say-so — this step exists because compile/tests passing does not prove the feature behaves correctly in the running app.

This applies automatically without the user needing to ask each time — it mirrors the workflow this project used with Codex previously. Skip this only if the user explicitly says not to (e.g. "don't package this, just show me the diff").

**Not covered by this rule:** git commits/pushes. Bumping the version and building a local DMG are local, reversible actions; committing to git still follows the global git-safety rules (only commit when explicitly asked). When the user does ask to commit a release, follow the existing convention: a single `release: prepare AutoVolume X.Y.Z` commit (see `git log` for examples) that includes the version bump alongside the code changes.
