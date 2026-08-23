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
