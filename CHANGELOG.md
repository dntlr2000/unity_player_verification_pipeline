# Changelog

## 0.4.0 - 2026-08-30

- Split IL2CPP identity into a build-affecting toolchain identity and a separately reported Visual Studio host-environment identity.
- Add compatibility schema `1.2.0` with reusable `CANDIDATE`, `APPROVED`, and `RETIRED` toolchain profiles and multiple approved profiles per Unity tuple.
- Discover all Visual Studio/MSVC/Windows SDK candidates and select exactly one approved match, with optional `ToolchainProfileId` and `VisualStudioPath` disambiguation.
- Pin compiler, linker, librarian, dependent native tools, MSVC headers/libraries, Windows SDK headers/libraries, Unity IL2CPP, and Bee identities; verify build/host identity again after the build.
- Parse isolated Bee DAG evidence to prove the selected `cl.exe`, `lib.exe`, and `link.exe` paths were used.
- Add result schema `1.1.0` and Standalone build receipt schema `1.1.0`; legacy receipt `1.0.0` is replay-only and cannot authorize a fresh v0.4 build.
- Add a candidate collector and approval-matrix staging flow that cannot mutate production profiles to `APPROVED`.

## 0.3.1 - 2026-08-26

- Traverse every nested Standalone scenario `IEnumerator` inside one runtime exception boundary, including nested `PlayerVerificationContext.WaitUntil` timeouts.
- Retain recorded assertions and captures in an atomic `FAILED` scenario receipt, then request immediate nonzero Player termination.
- Treat an exception-backed `FAILED` receipt as structurally consistent when its retained assertion/capture evidence is complete, without promoting it to positive evidence.
- Add real-Unity acceptance branches for top-level exceptions, nested exceptions, nested wait timeouts, retained failure evidence, prompt exit, and unchanged success behavior.

## 0.3.0 - 2026-08-24

- Add isolated non-development `INSTRUMENTED_STANDALONE` builds with fixed source infrastructure, source-only scenarios, BuildReport and build receipts, Player-side assertions, and PNG identity evidence.
- Add explicit `PREBUILT_STANDALONE` verification. Receipt-backed builds can reach `PLAYER_VERIFIED`; receipt-free opaque executables are capped at `PLAYER_LAUNCH_VERIFIED` after a responsive 10-second window observation.
- Approve complete P3 Mono and IL2CPP matrices for all three supported Unity editors, with exact Windows Support module and native toolchain identities.
- Require an exact Windows x64 non-development IL2CPP variation instead of treating the editor's shared `Data/il2cpp` directory as Player Build Support.
- Hash generated IL2CPP build files through extended-length Windows paths so the full build-tree contract remains valid beyond legacy `MAX_PATH`.
- Add full-tree prebuilt mutation detection, fixed Player arguments, separate Editor/Player Job Object evidence, and P3 real-Unity acceptance automation.

## 0.2.0 - 2026-08-23

- Add `SCENARIO_TEST_PLAYER` with strict source-only bundle, manifest, overlay, runtime receipt, and PNG identity contracts.
- Split the Player scenario runtime Harness from NUnit Test Runner infrastructure so capture and gameplay helpers compile as regular Player code.
- Approve success, assertion failure, capture omission, timeout, and overlay compilation failure on Unity `2022.3.62f3`, `6000.0.69f1`, and `6000.5.3f1`.

## 0.1.0 - 2026-08-23

- Add isolated Windows Test Player verification for approved Unity/Test Framework/Standalone Support combinations.
- Require matching PlayerConnection and Player-side NUnit evidence, a successful build report, complete process-tree termination, and source integrity.
- Add the explicit-only `$unity-player-verification` Codex Skill and idempotent link installer.
