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
7. Authorization resolution now uses semantic precedence, so exact compatibility evidence survives newer inconclusive reads while every newer conclusive native or denied state remains authoritative.
8. Delivery routing carries a state revision, retries stale selections with a fixed bound, synchronously revalidates compatibility immediately before launch, and performs exact suffix accounting on cancellation.
9. Live compatibility commands are tracked, canceled, force-killed if needed, and reaped by an injected production drain that `AppModel.stop()` awaits with a one-second bound.
10. Provisioning records whether it installed the exact restricted key line and removes only that new line on any post-install security-verification failure, with absence verification and sanitized manual remediation if rollback fails.
11. Installation now stages and validates the candidate before moving the prior app to an explicit backup, atomically replaces the final path, and restores/verifies the backup after replacement or final-validation failure.
12. Notification delivery results derive delivered count from validated attempted/failure data; the NVIDIA marker must be exactly one trimmed standalone line; failed polls preserve candidates; and multi-server candidate/offline/recovery state remains isolated.

## TDD evidence

- The new Swift tests first failed on missing `ProbeFailure`, missing warning/security health, unconfirmed snapshot leakage, duplicate-UUID trap risk, and missing parser validation.
- The strengthened candidate test separately failed because the first candidate changed `capturedAt`; the fix now leaves the entire stable snapshot unchanged.
- The offline recovery regression separately failed because a warning between connectivity streaks allowed a duplicate offline event; the fix suppresses another offline notification until a successful recovery.
- The offline forced-command harness first failed both GPU-query and compute-query nonzero cases against the production command, while the successful empty-compute case passed.
- Final-review race tests first failed because exact-error evidence was overwritten by inconclusive reads, stale compatibility routes defaulted to native, and cancellation did not account for the exact remaining suffix.
- Shutdown tests first failed at compile time because no production compatibility-drain API or injected AppModel drain existed.
- Transaction harnesses first demonstrated four missing SSH-key rollback paths and the installer's direct copy to the final path instead of a verified staging transaction.
- Delivery-invariant tests first failed at compile time because contradictory public count construction remained available.

## Final-review touched files

```text
README.md
Sources/GPUMonitorApp/AppModel.swift
Sources/GPUMonitorCore/NVIDIAOutputParser.swift
Sources/GPUMonitorCore/NotificationContracts.swift
Sources/GPUMonitorNotifications/MacOSNotificationSink.swift
Tests/GPUMonitorAppTests/AppModelTests.swift
Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift
Tests/GPUMonitorCoreTests/NVIDIAOutputParserTests.swift
Tests/GPUMonitorCoreTests/NotificationContractsTests.swift
Tests/GPUMonitorCoreTests/StateTrackerTests.swift
Tests/PackagingTests/fixtures/fake_ssh.sh
Tests/PackagingTests/install_app_behavior_test.sh
Tests/PackagingTests/package_scripts_test.sh
Tests/PackagingTests/provisioning_behavior_test.sh
docs/superpowers/plans/2026-08-24-gpu-monitor-implementation.md
docs/superpowers/plans/2026-08-24-notification-compatibility-fallback-implementation.md
docs/superpowers/specs/2026-08-24-gpu-monitor-design.md
docs/superpowers/specs/2026-08-24-notification-compatibility-fallback-design.md
scripts/install_app.sh
scripts/provision_ssh.sh
```

## Final verification

The final-review verification matrix completed with exit status 0 for every command:

```sh
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorAppTestsRunner
zsh Tests/PackagingTests/provisioning_behavior_test.sh
zsh Tests/PackagingTests/install_app_behavior_test.sh
zsh Tests/PackagingTests/package_scripts_test.sh
swift build --product GPUMonitor -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./scripts/package_app.sh
/usr/bin/codesign --verify --deep --strict --verbose=2 "dist/GPU Monitor.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "dist/GPU Monitor.app/Contents/Info.plist"
git diff --check
```

Results:

- Core: 67 tests passed.
- App: 55 tests passed.
- Provisioning behavior harness: 31 checks passed, including key rollback and pre-existing-key preservation.
- Installer behavior harness: 9 scenario groups passed, including staged validation, replacement rollback, and no-prior-install cleanup.
- Packaging policy harness: 137 checks passed.
- Complete strict-concurrency product build with warnings-as-errors: passed.
- Release package: built and ad-hoc signed.
- `codesign --verify --deep --strict`: passed.
- Bundle identifier: `com.yxy.gpumonitor`.
- `git diff --check`: clean.
