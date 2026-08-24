# Unity Player Verification real-Unity acceptance

This document is populated from retained, external acceptance artifacts. A compatibility entry is approved only when its exact signed Unity editor, Test Framework content, Windows Standalone Support module, backend, and (for IL2CPP) toolchain pass the release matrix.

## P1 — reapproved 2026-08-24

The retained summary is `E:\CodexValidation\upvr-p1-v030-20260824\acceptance-summary.json`. P1 was rerun after Windows IL2CPP Build Support changed each pinned Windows Support module tree.

| Unity | Test Framework | Source | Windows Support tree SHA-256 | Cases |
| --- | --- | --- | --- | ---: |
| 2022.3.62f3 | 1.1.33 | official registry | `4cbc2ca32cfbcb07f03b57d0c978942f12f13e12576d3f9ec72daf3841e4affe` | 8/8 |
| 6000.0.69f1 | 1.6.0 | Editor builtin | `ef7ce53571421990a31217c95a60a846393d3e061d5918ad9269522422e63e36` | 8/8 |
| 6000.5.3f1 | 1.7.0 | Editor builtin | `e7c1e6cdebfd2de95a0babae430c2e0da6ae4c02dab3d4291fa29dd1ccad7834` | 8/8 |

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

## P2 — reapproved 2026-08-24

P2 passed five cases on each approved Unity version: a complete scenario with PNG capture, deliberate assertion failure, requested capture omission, manifest timeout, and overlay compilation failure. All 15 cases preserved the source project and matched their expected final state.

| Unity | Test Framework | success | assertion | missing capture | timeout | compile failure |
| --- | --- | --- | --- | --- | --- | --- |
| `2022.3.62f3` | `1.1.33` registry | `PLAYER_VERIFIED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` |
| `6000.0.69f1` | `1.6.0` builtin | `PLAYER_VERIFIED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` |
| `6000.5.3f1` | `1.7.0` builtin | `PLAYER_VERIFIED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` |

The combined machine-readable summary is retained at `E:\CodexValidation\upvr-p2-v030-20260824\acceptance-summary.json`.

The PNG verdict checks only the manifest ID, expected path, nonzero size, and SHA-256. It does not judge image content.
