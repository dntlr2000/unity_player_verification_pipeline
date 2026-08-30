# Unity Player Verification Pipeline

This standalone Windows pipeline verifies Unity behavior in a built Player without changing the source project. It copies the Doctor copy-set to an external artifact session, injects only pipeline-owned source infrastructure, resolves one exact signed Unity editor, and fails closed when compatibility, evidence, process control, or integrity is incomplete.

The public entrypoint is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\skills\codex\unity-player-verification\scripts\invoke-unity-player-verification.ps1 `
  -Mode TEST_PLAYER `
  -ProjectRoot E:\Unity\Project `
  -ArtifactsRoot E:\CodexValidation\unity-player-verification
```

## Release scopes

| Release | Modes | Positive claim |
| --- | --- | --- |
| 0.1.0 | `TEST_PLAYER` | Selected PlayMode tests passed in an approved Mono Windows Test Player |
| 0.2.0 | `SCENARIO_TEST_PLAYER` | A reviewed source-only scenario passed in an approved Mono Windows Test Player |
| 0.3.0 | `INSTRUMENTED_STANDALONE`, `PREBUILT_STANDALONE` | Receipt-backed standalone behavior passed, or an opaque EXE met the narrower launch-only contract |
| 0.3.1 | P3 runtime hardening | Nested scenario coroutine failures emit an atomic `FAILED` receipt and terminate the Player promptly |
| 0.4.0 | P3 IL2CPP toolchain profiles | Approved build-tool bytes are selected independently from maintenance-sensitive Visual Studio host metadata |

Current release: `0.4.0`. All four modes are enabled. P1/P2 remain sealed to `StandaloneWindows64 + Mono`; P3 instrumented builds accept only the exact approved Mono or IL2CPP tuples for Unity `2022.3.62f3`, `6000.0.69f1`, and `6000.5.3f1`. IL2CPP approval is now attached to a build-toolchain profile, while Visual Studio product version, instance, and installation path are retained as separate host evidence.

`PLAYER_VERIFIED` never means device input, production-binary equivalence, performance, subjective quality, or release readiness. An opaque executable can produce only `PLAYER_LAUNCH_VERIFIED`.

### v0.4 security and compatibility notes

- A Visual Studio product-version, instance, or installation-path difference from the approval host is warning-only when the approved build-toolchain identity still matches exactly. High-assurance operators should treat `IL2CPP_HOST_ENVIRONMENT_DRIFT` as requiring manual review; v0.4 has no built-in strict-host switch. Any build or host identity change during one run remains a blocker.
- Result schema `1.1.0` applies to every Player mode, including Mono. Fresh P3 builds emit Standalone receipt schema `1.1.0`; schema `1.0.0` is retained only for explicit legacy prebuilt replay. Existing commands remain valid, but strict result/receipt consumers must update their schema handling.
- Mono compatibility tuples and positive claims are unchanged. Mono does not select an IL2CPP toolchain profile, although malformed global compatibility-profile data still blocks the registry fail-closed.
- `$unity-play-verification` remains a separate Editor PlayMode pipeline with its own repository, result contract, and installation name. Player v0.4 does not import or execute it at runtime.

See [architecture.md](docs/architecture.md) for trust boundaries, [the Skill guide](docs/skills/unity-player-verification.md) for operator usage, [the P3 acceptance record](docs/validation/unity-player-verification-p3-real-unity-acceptance.md) for the sealed v0.3 evidence, and [the v0.4 toolchain-profile record](docs/validation/unity-player-verification-v040-toolchain-acceptance.md) for the split-identity approval gate.

For a source-only Standalone scenario:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\skills\codex\unity-player-verification\scripts\invoke-unity-player-verification.ps1 `
  -Mode INSTRUMENTED_STANDALONE `
  -ProjectRoot E:\Unity\Project `
  -ScenarioBundlePath E:\CodexValidation\reviewed-player-scenario `
  -ScriptingBackend Mono `
  -ArtifactsRoot E:\CodexValidation\unity-player-verification
```

If more than one installed candidate can satisfy an approved IL2CPP profile, disambiguate with the reviewed profile and Visual Studio root. These parameters constrain selection; they cannot approve a candidate.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\skills\codex\unity-player-verification\scripts\invoke-unity-player-verification.ps1 `
  -Mode INSTRUMENTED_STANDALONE `
  -ProjectRoot E:\Unity\Project `
  -ScenarioBundlePath E:\CodexValidation\reviewed-player-scenario `
  -ScriptingBackend IL2CPP `
  -ToolchainProfileId msvc-14-51-36231-sdk-10-0-26100-0-8fff423cab47 `
  -VisualStudioPath "C:\Program Files\Microsoft Visual Studio\18\Community" `
  -ArtifactsRoot E:\CodexValidation\unity-player-verification
```

For an existing build, specify both the root and exact executable. Include a matching verifier-produced `build-receipt.json` for behavioral verification; omit it for the narrower responsive-window launch observation.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\skills\codex\unity-player-verification\scripts\invoke-unity-player-verification.ps1 `
  -Mode PREBUILT_STANDALONE `
  -BuildRoot E:\Builds\Game `
  -PlayerExecutable E:\Builds\Game\Game.exe `
  -BuildReceiptPath E:\CodexValidation\prior-session\build-receipt.json `
  -ArtifactsRoot E:\CodexValidation\unity-player-verification
```
