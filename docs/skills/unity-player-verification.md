# `$unity-player-verification`

The Skill is intentionally explicit-only. It is not an automatic continuation of Unity Doctor, Baseline, or Editor Play verification.

Use `TEST_PLAYER` for existing PlayMode tests, `SCENARIO_TEST_PLAYER` for a reviewed source-only Player scenario, `INSTRUMENTED_STANDALONE` for a pipeline-built standalone scenario, and `PREBUILT_STANDALONE` only for a user-selected existing build root and executable.

Release `0.2.0` enables the first two modes. In `SCENARIO_TEST_PLAYER`, do not pass `TestFilter`, `TestCategory`, or `AssemblyNames`; the manifest owns the fixed Harness filter. Keep the bundle outside the Unity project and include only `manifest.json`, `.asmdef`, and `.cs`. Scenario assemblies reference `UnityPlayerVerification.Harness` and implement `IPlayerVerificationScenario.Execute(PlayerVerificationContext): IEnumerator`.

The machine-readable `result.json` is authoritative. Preserve its warnings, failures, blockers, verification scopes, and exact final status.
