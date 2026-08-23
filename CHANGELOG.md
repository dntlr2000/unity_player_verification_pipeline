# Changelog

## 0.3.0-rc.1 - 2026-08-24

- Add isolated non-development `INSTRUMENTED_STANDALONE` builds with fixed source infrastructure, source-only scenarios, BuildReport and build receipts, Player-side assertions, and PNG identity evidence.
- Add explicit `PREBUILT_STANDALONE` verification. Receipt-backed builds can reach `PLAYER_VERIFIED`; receipt-free opaque executables are capped at `PLAYER_LAUNCH_VERIFIED` after a responsive 10-second window observation.
- Approve the complete P3 Mono matrix for all three supported Unity editors. Keep IL2CPP tuples absent until Windows x64 IL2CPP Build Support is installed and the full native-toolchain matrix passes.
- Require an exact Windows x64 non-development IL2CPP variation instead of treating the editor's shared `Data/il2cpp` directory as Player Build Support.
- Add full-tree prebuilt mutation detection, fixed Player arguments, separate Editor/Player Job Object evidence, and P3 real-Unity acceptance automation.

## 0.2.0 - 2026-08-23

- Add `SCENARIO_TEST_PLAYER` with strict source-only bundle, manifest, overlay, runtime receipt, and PNG identity contracts.
- Split the Player scenario runtime Harness from NUnit Test Runner infrastructure so capture and gameplay helpers compile as regular Player code.
- Approve success, assertion failure, capture omission, timeout, and overlay compilation failure on Unity `2022.3.62f3`, `6000.0.69f1`, and `6000.5.3f1`.

## 0.1.0 - 2026-08-23

- Add isolated Windows Test Player verification for approved Unity/Test Framework/Standalone Support combinations.
- Require matching PlayerConnection and Player-side NUnit evidence, a successful build report, complete process-tree termination, and source integrity.
- Add the explicit-only `$unity-player-verification` Codex Skill and idempotent link installer.
