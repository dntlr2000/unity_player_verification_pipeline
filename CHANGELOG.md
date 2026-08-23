# Changelog

## 0.2.0 - 2026-08-23

- Add `SCENARIO_TEST_PLAYER` with strict source-only bundle, manifest, overlay, runtime receipt, and PNG identity contracts.
- Split the Player scenario runtime Harness from NUnit Test Runner infrastructure so capture and gameplay helpers compile as regular Player code.
- Approve success, assertion failure, capture omission, timeout, and overlay compilation failure on Unity `2022.3.62f3`, `6000.0.69f1`, and `6000.5.3f1`.

## 0.1.0 - 2026-08-23

- Add isolated Windows Test Player verification for approved Unity/Test Framework/Standalone Support combinations.
- Require matching PlayerConnection and Player-side NUnit evidence, a successful build report, complete process-tree termination, and source integrity.
- Add the explicit-only `$unity-player-verification` Codex Skill and idempotent link installer.
