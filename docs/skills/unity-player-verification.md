# `$unity-player-verification`

The Skill is intentionally explicit-only. It is not an automatic continuation of Unity Doctor, Baseline, or Editor Play verification.

Use `TEST_PLAYER` for existing PlayMode tests, `SCENARIO_TEST_PLAYER` for a reviewed source-only Player scenario, `INSTRUMENTED_STANDALONE` for a pipeline-built standalone scenario, and `PREBUILT_STANDALONE` only for a user-selected existing build root and executable.

Release `0.3.0` enables all four modes. In either scenario mode, do not pass `TestFilter`, `TestCategory`, or `AssemblyNames`. Keep the bundle outside the Unity project and include only `manifest.json`, `.asmdef`, and `.cs`. Scenario assemblies reference `UnityPlayerVerification.Harness` and implement `IPlayerVerificationScenario.Execute(PlayerVerificationContext): IEnumerator`.

`INSTRUMENTED_STANDALONE` requires `ScenarioBundlePath`. Choose `ScriptingBackend Mono`, `IL2CPP`, or `Project`; `Project` is resolved from serialized project settings before Unity opens the copy. The resolved exact Unity/Test Framework/Windows Support/backend/toolchain tuple must already be approved. The resulting build contains verifier instrumentation and is not claimed to equal a distributable production build.

`PREBUILT_STANDALONE` requires the exact `BuildRoot` and `PlayerExecutable` and never searches for another EXE. A matching pipeline build receipt enables a fresh receipt-backed scenario run. Without a receipt, only a responsive 10-second launch observation is attempted, so the maximum status is `PLAYER_LAUNCH_VERIFIED`. Do not combine project, scenario, selector, or Unity executable inputs with prebuilt mode.

The machine-readable `result.json` is authoritative. Preserve its warnings, failures, blockers, verification scopes, and exact final status.
