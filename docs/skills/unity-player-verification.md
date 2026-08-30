# `$unity-player-verification`

The Skill is intentionally explicit-only. It is not an automatic continuation of Unity Doctor, Baseline, or Editor Play verification.

Use `TEST_PLAYER` for existing PlayMode tests, `SCENARIO_TEST_PLAYER` for a reviewed source-only Player scenario, `INSTRUMENTED_STANDALONE` for a pipeline-built standalone scenario, and `PREBUILT_STANDALONE` only for a user-selected existing build root and executable.

Release `0.4.0` enables all four modes. In either scenario mode, do not pass `TestFilter`, `TestCategory`, or `AssemblyNames`. Keep the bundle outside the Unity project and include only `manifest.json`, `.asmdef`, and `.cs`. Scenario assemblies reference `UnityPlayerVerification.Harness` and implement `IPlayerVerificationScenario.Execute(PlayerVerificationContext): IEnumerator`.

The P3 Standalone runner directly traverses nested `IEnumerator` values. Exceptions from a nested scenario coroutine or `PlayerVerificationContext.WaitUntil` therefore produce an atomic `FAILED` receipt with all evidence recorded before the exception, followed by a nonzero Player exit. A failed receipt with missing manifest-owned evidence remains fail-closed and cannot become `PLAYER_VERIFIED`.

`INSTRUMENTED_STANDALONE` requires `ScenarioBundlePath`. Choose `ScriptingBackend Mono`, `IL2CPP`, or `Project`; `Project` is resolved from serialized project settings before Unity opens the copy. The resolved exact Unity/Test Framework/Windows Support/backend/toolchain tuple must already be approved. The resulting build contains verifier instrumentation and is not claimed to equal a distributable production build.

For IL2CPP, the verifier inventories every complete Visual Studio/MSVC/Windows SDK candidate and selects exactly one candidate matching an `APPROVED` toolchain profile referenced by the Unity compatibility entry. `ToolchainProfileId` and `VisualStudioPath` are optional selection constraints for ambiguous hosts; neither can create approval. A Visual Studio product-version or installation-path change is warning-only when build-affecting bytes still match the approved profile. Tool-byte changes, candidate-only or retired-only profiles, ambiguous selection, Bee path mismatch, or any within-run identity drift block verification.

Always inspect `warnings` even when the final status is `PLAYER_VERIFIED`. In a high-assurance workflow, do not accept a result containing `IL2CPP_HOST_ENVIRONMENT_DRIFT` until the changed Visual Studio host identity has been reviewed. This is an operator policy: v0.4 deliberately has no switch that converts approval-host drift into an automatic blocker.

Use `tests\acceptance\new-il2cpp-toolchain-candidate.ps1` to collect a read-only external candidate document. Approval requires the complete real-Unity matrix and explicit review of its summary SHA-256; production verification never promotes a candidate itself.

`PREBUILT_STANDALONE` requires the exact `BuildRoot` and `PlayerExecutable` and never searches for another EXE. A matching pipeline build receipt enables a fresh receipt-backed scenario run. Without a receipt, only a responsive 10-second launch observation is attempted, so the maximum status is `PLAYER_LAUNCH_VERIFIED`. Do not combine project, scenario, selector, or Unity executable inputs with prebuilt mode.

The machine-readable `result.json` is authoritative. Preserve its warnings, failures, blockers, verification scopes, and exact final status.

All v0.4 Player modes emit result schema `1.1.0`. Fresh instrumented Standalone builds emit build receipt schema `1.1.0`; a legacy `1.0.0` receipt is accepted only for an explicitly selected prebuilt replay and cannot authorize a fresh build. Mono invocation and verdict semantics are unchanged, but strict schema `1.0.0` consumers must be updated. Do not pass `ToolchainProfileId` or `VisualStudioPath` for Mono.

`$unity-play-verification` is independent. Installing or invoking this Skill does not update, route to, or change the Editor PlayMode verifier.
