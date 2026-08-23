# P3 real-Unity acceptance

## Gate state — release blocked on IL2CPP

Candidate `0.3.0-rc.1` completed the full Mono matrix on 2026-08-24. The final `v0.3.0` release remains blocked because the three selected Unity installations do not contain a Windows x64 non-development IL2CPP variation. The pipeline does not install or update Unity modules, so no IL2CPP compatibility tuple is present in the production registry.

## Mono approval

The final candidate summary is `E:\CodexValidation\unity-player-verification-p3-mono-rc1-final-20260824\acceptance-summary.json`.

| Unity | Test Framework | Backend | Cases | Result |
| --- | --- | --- | ---: | --- |
| `2022.3.62f3` | `1.1.33` | Mono | 6/6 | Approved |
| `6000.0.69f1` | `1.6.0` | Mono | 6/6 | Approved |
| `6000.5.3f1` | `1.7.0` | Mono | 6/6 | Approved |

Each combination covered a successful receipt-backed scenario, deliberate assertion failure, crash, timeout, opaque launch-only observation, and post-build receipt/tree mismatch. All 18 results matched the expected final status and preserved the source project and scenario bundle.

The P3 candidate also passed the complete earlier-stage real-Unity regressions without modifying their contracts:

- P1: 24/24 cases approved at `E:\CodexValidation\unity-player-verification-p1-p3-regression-20260824\acceptance-summary.json`.
- P2: 15/15 cases approved at `E:\CodexValidation\unity-player-verification-p2-p3-regression-20260824\acceptance-summary.json`.

| Unity | Unity executable SHA-256 | Windows Support tree SHA-256 |
| --- | --- | --- |
| `2022.3.62f3` | `02e80b2c1d7f983375c97b612655be9f8ed852121e3a4eedf1570701c48ea5cd` | `985b3336582a618371a10727ffdb0a8f12fed4f617df5c9054a23d58f4c828e3` |
| `6000.0.69f1` | `3927c20e4c76f15951989fd4866546b03d3ebfcc72bb5d708cd6397fad50451d` | `287e51fd036a046e98082a64653bd7e1727463e3a41d022777d66e99a0098653` |
| `6000.5.3f1` | `5e54f3a9953179419ddf8af860c3ccdcbb6ada45276fa9df06fdaaaa1124a118` | `ba4c0ac41f2f6adf27f7df615905cd2b704f47e8d9582b65d5545bc9912a8afb` |

## IL2CPP blocker evidence

All three Windows Support trees contain `Variations/win64_player_nondevelopment_mono` and contain no matching IL2CPP variation. The editor-wide `Editor/Data/il2cpp` directory is not accepted as proof that Windows IL2CPP Build Support is installed.

An early signed-Unity probe on `2022.3.62f3` reached `BuildPipeline.BuildPlayer` and produced `Error building Player: Currently selected scripting backend (IL2CPP) is not installed.` Its retained result is `E:\CodexValidation\unity-player-verification-p3-final-approved-20260824\runs\2022.3.62f3\IL2CPP\success\s-e547cc37a4f5405daa30520254a265db\result.json`.

After correcting module detection and removing unapproved tuples, production preflight returned `VERIFICATION_BLOCKED` with `PLAYER_COMPATIBILITY_REJECTED`, did not start Unity, and preserved the source for every version:

| Unity | Production result |
| --- | --- |
| `2022.3.62f3` | `E:\CodexValidation\unity-player-verification-p3-il2cpp-unavailable-rc1-20260824\2022.3.62f3\s-cec711b5d08a4d26b687420ed9177be9\result.json` |
| `6000.0.69f1` | `E:\CodexValidation\unity-player-verification-p3-il2cpp-unavailable-rc1-20260824\6000.0.69f1\s-6e1a8677875d43868a51302353c21b5a\result.json` |
| `6000.5.3f1` | `E:\CodexValidation\unity-player-verification-p3-il2cpp-unavailable-rc1-20260824\6000.5.3f1\s-03dca3fab497485fbeb54b881c495eb2\result.json` |

## Remaining release gate

Install Windows Build Support (IL2CPP) for each exact Unity version outside this pipeline, then recalculate the Windows Support and native toolchain identities and run the six-case IL2CPP matrix for all three versions. Only successful exact combinations may be added to the compatibility registry. After the full 36-case Mono/IL2CPP matrix and repository regressions pass, replace the candidate version with `0.3.0` and create local tag `v0.3.0`.
