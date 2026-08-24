# Architecture

## Trust and isolation

The verifier operates on an external byte-verified copy of the Unity project. It does not open the source project in Unity. The bundled Doctor scanner, fingerprint implementation, Git metadata integrity check, path budget, Job Object controller, JSON Schema validator, and Test Framework identity implementation are pinned internal copies; no sibling repository is a runtime dependency.

The source project and source-only scenario execute with the current user's permissions. Isolation protects the source project from ordinary Unity writes, but it is not a security sandbox for malicious C#.

## Evidence flow

```text
source project
  -> static Doctor + stable source/Git snapshots
  -> verified external copy
  -> pipeline-owned source overlay
  -> exact signed Unity + approved package/module/toolchain
  -> Test Player or Standalone build
  -> independent Editor/Player receipts, logs, hashes, process evidence
  -> source/Git integrity recheck
  -> fail-closed final status
```

For Test Players, the command-line NUnit document returned through PlayerConnection and the runtime callback NUnit document must both exist and agree semantically. For instrumented Standalone builds, the build receipt, runtime scenario receipt, executable identity, and current build-tree fingerprint must agree. Opaque prebuilt executables are never promoted beyond launch-only verification.

P2 adds a second source boundary. The external bundle permits only one root `manifest.json`, `.asmdef`, and `.cs`; blocks reparse points, binaries, unsafe/precompiled references, and OS input automation tokens; then copies the reviewed hashes into `Assets/__UnityPlayerVerification/Scenario` in the isolated project. A regular runtime Harness owns scenes, bounded waits, assertions, and pure-C# PNG encoding, while a separate Test Runner assembly owns the single fixed NUnit filter.

P3 reuses the regular runtime Harness but replaces the Test Runner entry with a pre-Scene bootstrap and a fixed Editor builder. `BuildPipeline.BuildPlayer` creates a non-development `StandaloneWindows64` tree under the artifact session. The verifier cross-checks the BuildReport, build receipt, PE32+ AMD64 executable, matching Data directory, backend, Scene list, executable hash, and deterministic full-tree hash before execution. Mono entries require no external native toolchain; IL2CPP entries additionally pin the exact Visual Studio, MSVC, Windows SDK, `cl.exe`, `link.exe`, and `rc.exe` identity through an aggregate SHA-256.

Backend availability is derived from the selected editor's Windows Support `Variations` tree. A shared editor `Data/il2cpp` directory is not sufficient evidence of Windows IL2CPP Build Support. Release `0.3.0` contains exact approved Mono and IL2CPP tuples for all three supported Unity editors. Generated IL2CPP files are hashed through extended-length Windows paths so full-tree identity remains deterministic beyond legacy `MAX_PATH`.

Receipt-backed prebuilt execution binds the retained scenario identity to a fresh session token and requires a new runtime receipt. Receipt-free prebuilt execution does not trust or infer gameplay state. It records the explicit EXE and build-tree identity, applies only the fixed windowed/log arguments, requires a continuously responsive window for at least 10 seconds, requests `CloseMainWindow`, and uses the Job Object to guarantee a zero-process end state. Runtime changes to the supplied build tree block either verdict.

Instrumented source and scenarios run with the caller's Windows permissions. The pipeline is an integrity and evidence boundary, not a hostile-code sandbox, CI attestation, code-signing system, or proof that an instrumented binary equals a production release binary.
