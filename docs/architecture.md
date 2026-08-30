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

P3 reuses the regular runtime Harness but replaces the Test Runner entry with a pre-Scene bootstrap and a fixed Editor builder. `BuildPipeline.BuildPlayer` creates a non-development `StandaloneWindows64` tree under the artifact session. The verifier cross-checks the BuildReport, build receipt, PE32+ AMD64 executable, matching Data directory, backend, Scene list, executable hash, and deterministic full-tree hash before execution. Mono entries require no external native toolchain.

Release `0.4.0` separates IL2CPP evidence into two identities:

- `buildToolchainIdentity` contains the x64 MSVC and Windows SDK versions; hashes and versions for `cl`, compiler DLLs, `link`, `lib`, `cvtres`, PDB support files, `rc`, and `mt`; and deterministic trees for MSVC headers/x64 libraries plus Windows SDK headers/UCRT/x64 UM libraries. Visual Studio product version and absolute installation root are deliberately excluded.
- `hostEnvironmentIdentity` records the Visual Studio instance, product/channel/version/path/state, required components, and `vswhere` identity. A host-only difference from approval is reported as a warning when the build identity still matches, but any host or build identity drift during one verification run blocks the result.

The Unity Windows Support tree, `il2cpp.exe`, and `bee_backend.exe` remain compatibility-entry evidence because they are selected by the Unity editor rather than the Visual Studio profile. After each IL2CPP build, the verifier recomputes both identities and parses the isolated `Library/Bee` DAG to prove that the selected `cl.exe`, `lib.exe`, and `link.exe` paths were present. Missing, conflicting, or unparsable evidence blocks verification.

Compatibility schema `1.2.0` stores reusable toolchain profiles with `CANDIDATE`, `APPROVED`, or `RETIRED` state. The verifier inventories all complete Visual Studio/MSVC/SDK candidates, matches only profiles referenced by the exact Unity compatibility entry, and requires one deterministic approved match. Zero matches, candidate-only or retired-only matches, and unresolved multiple matches fail closed. Optional profile/path parameters may disambiguate installed candidates but can never change approval state.

### Security trade-off and residual evidence boundary

Separating host metadata from build-affecting bytes intentionally broadens the accepted host set relative to v0.3.1. A Visual Studio product-version, instance, or absolute-path difference between approval and a later run emits `IL2CPP_HOST_ENVIRONMENT_DRIFT` but does not by itself prevent `PLAYER_VERIFIED` when the approved build identity is exact. This avoids reapproval for servicing-only changes. Environments that treat the Visual Studio instance itself as a supply-chain identity must apply a manual policy that rejects this warning; v0.4 does not expose a strict-host option.

The build identity covers the fixed native tools and dependency/header/library trees listed above, not the entire Visual Studio installation, operating system, environment variables, or workload manifest. Bee evidence proves that the isolated DAG contained the selected `cl.exe`, `lib.exe`, and `link.exe` paths; it is stronger than v0.3.1's preflight-only identity but is not OS-level process attestation. The verifier remains a same-user integrity boundary rather than a hostile-build sandbox.

Profile and compatibility approval paths and SHA-256 values are audit metadata inside the trusted production registry. Runtime validation checks their presence and digest shape but does not dereference the retained external acceptance summary on every verification. Repository integrity and reviewed release promotion therefore remain the approval root of trust.

Compatibility schema `1.2.0` is validated as one fail-closed registry. Consequently, malformed or tampered IL2CPP profile data can block a Mono request even though Mono does not select a native profile. This is an availability coupling, not a relaxation of Mono evidence. The three approved Mono tuples, Test Player command contract, NUnit agreement, process control, and positive-claim semantics remain unchanged.

Backend availability is derived from the selected editor's Windows Support `Variations` tree. A shared editor `Data/il2cpp` directory is not sufficient evidence of Windows IL2CPP Build Support. Release `0.3.0` contains exact approved Mono and IL2CPP tuples for all three supported Unity editors. Generated IL2CPP files are hashed through extended-length Windows paths so full-tree identity remains deterministic beyond legacy `MAX_PATH`.

Release `0.3.1` hardens only the instrumented Standalone runtime. Its runner expands nested `IEnumerator` frames itself, calls every nested `MoveNext()` and `Current` inside one exception boundary, writes the partial assertion/capture snapshot into an atomic failure receipt, and exits nonzero without waiting for the external process timeout.

Fresh v0.4 Standalone builds write receipt schema `1.1.0`, including profile ID, build-identity algorithm/hash, and host-identity algorithm/hash. Receipt schema `1.0.0` remains readable only for explicit prebuilt replay and produces a legacy warning; it cannot authorize a fresh build. A receipt whose identity algorithm is unknown or whose current tree/tool evidence differs is blocked.

Result schema `1.1.0` is emitted by all four modes, including Mono Test Player modes. This is a versioned machine-interface change even where verification behavior is unchanged; consumers that require result schema `1.0.0` must migrate before processing v0.4 output. New Mono Standalone receipts keep every split IL2CPP identity field null or empty as required by receipt schema `1.1.0`.

Receipt-backed prebuilt execution binds the retained scenario identity to a fresh session token and requires a new runtime receipt. Receipt-free prebuilt execution does not trust or infer gameplay state. It records the explicit EXE and build-tree identity, applies only the fixed windowed/log arguments, requires a continuously responsive window for at least 10 seconds, requests `CloseMainWindow`, and uses the Job Object to guarantee a zero-process end state. Runtime changes to the supplied build tree block either verdict.

Instrumented source and scenarios run with the caller's Windows permissions. The pipeline is an integrity and evidence boundary, not a hostile-code sandbox, CI attestation, code-signing system, or proof that an instrumented binary equals a production release binary.
