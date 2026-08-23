# Unity Player Verification real-Unity acceptance

This document is populated from retained, external acceptance artifacts. A compatibility entry is approved only when its exact signed Unity editor, Test Framework content, Windows Standalone Support module, backend, and (for IL2CPP) toolchain pass the release matrix.

## P1 — approved 2026-08-23

The retained summary is `E:\CodexValidation\unity-player-verification-p1-final-20260823\acceptance-summary.json`.

| Unity | Test Framework | Source | Windows Support tree SHA-256 | Cases |
| --- | --- | --- | --- | ---: |
| 2022.3.62f3 | 1.1.33 | official registry | `985b3336582a618371a10727ffdb0a8f12fed4f617df5c9054a23d58f4c828e3` | 8/8 |
| 6000.0.69f1 | 1.6.0 | Editor builtin | `287e51fd036a046e98082a64653bd7e1727463e3a41d022777d66e99a0098653` | 8/8 |
| 6000.5.3f1 | 1.7.0 | Editor builtin | `ba4c0ac41f2f6adf27f7df615905cd2b704f47e8d9582b65d5545bc9912a8afb` | 8/8 |

Each combination passed these signed-Unity cases:

1. multi-frame Player pass → `PLAYER_VERIFIED`
2. deliberate NUnit failure → `PLAYER_FAILED`
3. Skip → `VERIFICATION_BLOCKED`
4. Inconclusive → `VERIFICATION_BLOCKED`
5. zero selected tests → `VERIFICATION_BLOCKED`
6. compiler error → `PLAYER_FAILED`
7. retained Player crash signal → `PLAYER_FAILED`
8. missing PlayerConnection completion → `VERIFICATION_BLOCKED`

Every case recorded zero remaining Job Object processes and `UNCHANGED` source-copy integrity. The pass cases also retained matching PlayerConnection and Player-side NUnit summaries, runtime receipt/log evidence, a pipeline build callback receipt, Test Player executable/Data identity, and full build-tree hashes.

Unity 6 reports `BuildReport.summary.result = Unknown` from the `IPostprocessBuildWithReport` callback before the summary is finalized. P1 accepts that callback-time value only when total errors are zero and independent positive output-tree, Player execution, NUnit, process-exit, and Editor-log evidence all agree. It cannot produce a positive verdict by itself.
