# Review Fix A Report

## Scope and safety

- Work was limited to `/Users/yxy/Documents/workspace/gpu-monitor/.worktrees/gpu-monitor-v1`.
- No real SSH server was contacted.
- `/Applications`, user SSH keys, user `known_hosts`, and user configuration were not modified.
- Packaging produced only the worktree-local ignored `dist/GPU Monitor.app` artifact.

## Implemented fixes

1. The restricted remote command now chains GPU query, marker, and compute query with `&&`. Either query's nonzero status fails the SSH sample; a successful empty compute result remains a valid free-GPU sample. The exact command is synchronized across provisioning, packaging assertions, README, design, and implementation plan.
2. `SSHGPUProbe` now uses `-F /dev/null`, the dedicated identity/known-hosts files, `IdentitiesOnly=yes`, public-key-only authentication, disabled password/keyboard-interactive authentication, `GlobalKnownHostsFile=/dev/null`, `ClearAllForwardings=yes`, and the existing 8-second timeout.
3. Sanitized `ProbeFailure` cases distinguish connectivity, host-key/security, authentication, remote-command, invalid-response, and local-launch failures. Only consecutive connectivity failures advance the offline threshold. Other failures reset that sequence and become independent warning/security health. OpenSSH `Network is unreachable` and `Connection refused` are connectivity; displayed errors never include stderr, host, user, identity path, or secrets.
4. `StateTracker.GPURecord` retains the complete confirmed GPU. A first opposite candidate leaves the full stable snapshot unchanged; the second confirms it. Matching confirmed observations may refresh metrics/processes. Failures retain the confirmed snapshot, and direct duplicate UUID input is defensively first-wins instead of trapping.
5. `NVIDIAOutputParser` rejects empty GPU UUID/name, duplicate GPU UUID/index, empty process GPU UUID/name, and process rows referring to an absent GPU UUID.
6. `ServerHealthDisplay`, `MenuStatus`, error summaries, and UI colors/icons now distinguish connectivity degradation, ordinary warning, security error, and confirmed offline state. Existing cancellation and active-poll sharing paths were left intact and covered by the full suites.

## TDD evidence

- The new Swift tests first failed on missing `ProbeFailure`, missing warning/security health, unconfirmed snapshot leakage, duplicate-UUID trap risk, and missing parser validation.
- The strengthened candidate test separately failed because the first candidate changed `capturedAt`; the fix now leaves the entire stable snapshot unchanged.
- The offline recovery regression separately failed because a warning between connectivity streaks allowed a duplicate offline event; the fix suppresses another offline notification until a successful recovery.
- The offline forced-command harness first failed both GPU-query and compute-query nonzero cases against the production command, while the successful empty-compute case passed.

## Final verification

One fresh serial verification command completed with exit status 0:

```sh
zsh -n scripts/package_app.sh scripts/install_app.sh scripts/provision_ssh.sh Tests/PackagingTests/package_scripts_test.sh Tests/PackagingTests/provisioning_behavior_test.sh Tests/PackagingTests/fixtures/fake_ssh.sh Tests/PackagingTests/fixtures/fake_nvidia_smi.sh
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorAppTestsRunner
zsh Tests/PackagingTests/provisioning_behavior_test.sh
zsh Tests/PackagingTests/package_scripts_test.sh
swift build -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./scripts/package_app.sh
codesign --verify --deep --strict --verbose=2 "dist/GPU Monitor.app"
plutil -lint "dist/GPU Monitor.app/Contents/Info.plist"
git diff --check
```

Results:

- Core: 58 tests passed.
- App: 18 tests passed.
- Provisioning behavior harness: all checks passed, including both query failures and successful empty compute output.
- Packaging policy harness: all checks passed.
- Swift 6 complete strict-concurrency build with warnings-as-errors: passed for all targets.
- Release package: built and ad-hoc signed.
- `codesign --verify --deep --strict`: passed.
- `plutil -lint`: `OK`.
- `git diff --check`: clean.
