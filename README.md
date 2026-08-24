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

Current release: `0.3.0`. All four modes are enabled. P1/P2 remain sealed to `StandaloneWindows64 + Mono`; P3 instrumented builds accept only the exact approved Mono or IL2CPP tuples for Unity `2022.3.62f3`, `6000.0.69f1`, and `6000.5.3f1`.

`PLAYER_VERIFIED` never means device input, production-binary equivalence, performance, subjective quality, or release readiness. An opaque executable can produce only `PLAYER_LAUNCH_VERIFIED`.

See [architecture.md](docs/architecture.md) for trust boundaries, [the Skill guide](docs/skills/unity-player-verification.md) for operator usage, and [the P3 acceptance record](docs/validation/unity-player-verification-p3-real-unity-acceptance.md) for the retained Mono and IL2CPP approval evidence.

For a source-only Standalone scenario:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\skills\codex\unity-player-verification\scripts\invoke-unity-player-verification.ps1 `
  -Mode INSTRUMENTED_STANDALONE `
  -ProjectRoot E:\Unity\Project `
  -ScenarioBundlePath E:\CodexValidation\reviewed-player-scenario `
  -ScriptingBackend Mono `
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
