# AutoVolume Project Rules

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
