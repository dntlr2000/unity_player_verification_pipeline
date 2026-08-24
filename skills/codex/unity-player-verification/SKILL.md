---
name: unity-player-verification
description: "Run approved Unity Windows Test Player, source-only Player scenario, instrumented Standalone, or explicitly selected prebuilt EXE verification against external artifacts. Use only when the user explicitly invokes $unity-player-verification; never infer it from an ordinary Unity testing request."
---

# Unity Player Verification

Use the bundled PowerShell entrypoint as the sole source of dynamic Player verification truth. It preserves the source project, accepts only exact approved Unity/Test Framework/Windows Support identities, controls spawned processes, and requires mode-specific receipts before making a positive claim.

Component `0.3.0` enables all four modes. Test Player modes remain sealed to Mono; instrumented Standalone mode accepts only exact approved Mono or IL2CPP tuples.

## Invocation policy

- Require the literal name `$unity-player-verification` in the user's request.
- Never invoke this Skill implicitly or as an automatic continuation of Doctor, Baseline, or `$unity-play-verification`.
- Never install or update Unity, modules, packages, Visual Studio, toolchains, or SDKs.
- Never open or modify the source Unity project; Unity receives only the verifier-created external copy.
- Put Codex-operated validation artifacts under `E:\CodexValidation`, set `TEMP` and `TMP` to `E:\CodexTemp`, and reject C-drive source projects, project copies, builds, Player executables, and logs. A signed Unity editor may remain in its normal `C:\Program Files\Unity` installation.

## Entrypoint

```powershell
$runner = Join-Path $HOME ".agents\skills\unity-player-verification\scripts\invoke-unity-player-verification.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
    -Mode TEST_PLAYER `
    -ProjectRoot (Get-Location).Path `
    -ArtifactsRoot "E:\CodexValidation\unity-player-verification"
```

Use `-TestFilter`, `-TestCategory`, and `-AssemblyNames` only in `TEST_PLAYER`. Use `-ScenarioBundlePath` only in scenario modes. Use `-BuildRoot`, `-PlayerExecutable`, and optional `-BuildReceiptPath` only in `PREBUILT_STANDALONE`. Never append arbitrary Unity or Player arguments.

For `INSTRUMENTED_STANDALONE`, require a reviewed Standalone scenario bundle and choose `-ScriptingBackend Mono`, `IL2CPP`, or `Project`. Treat `Project` as a request to preserve the serialized Standalone backend; it still must resolve to an approved exact tuple. For `PREBUILT_STANDALONE`, execute only the exact user-supplied EXE. Never invent, edit, or substitute a build receipt.

## Source-only scenarios

- Accept only `manifest.json`, `.asmdef`, and `.cs` files from a reviewed local bundle outside the project.
- Implement `IPlayerVerificationScenario.Execute(PlayerVerificationContext)` and use only Player-internal Input System virtual devices/events or an existing public gameplay seam.
- Never use operating-system `SendInput`, window-coordinate clicks, or focus automation.
- Treat PNG captures as hashed evidence only; visual interpretation cannot promote or demote the JSON verdict.

## Result handling

- Parse exactly one stdout JSON document and preserve the identical external `result.json`.
- Do not promote `VERIFICATION_BLOCKED`, `PLAYER_FAILED`, or `ORIGINAL_PROJECT_CHANGED`.
- `PLAYER_VERIFIED` requires complete Player-side test or scenario receipts.
- `PLAYER_LAUNCH_VERIFIED` is the maximum claim for an opaque receipt-free prebuilt executable.
- Report the external artifact directory, mode, backend, test/assertion counts, and exact final status.

## Final statuses

| finalStatus | Meaning |
| --- | --- |
| `PLAYER_VERIFIED` | Complete positive Test Player or receipt-backed scenario evidence |
| `PLAYER_LAUNCH_VERIFIED` | A user-selected opaque EXE met only the bounded launch-observation contract |
| `PLAYER_FAILED` | Complete evidence identifies a compilation, build, test, scenario, or crash failure |
| `VERIFICATION_BLOCKED` | Safety, compatibility, completeness, timeout, skip, or evidence requirements were not met |
| `ORIGINAL_PROJECT_CHANGED` | Source content or disallowed Git metadata changed during verification |
