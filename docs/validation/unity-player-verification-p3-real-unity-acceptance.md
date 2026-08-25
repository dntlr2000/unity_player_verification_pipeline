# P3 real-Unity acceptance

## 0.3.1 patch — approved 2026-08-26

The nested-coroutine hardening patch passed the complete advertised P3 matrix: three Unity versions times Mono and IL2CPP, with success, top-level exception, nested exception, and nested `WaitUntil` timeout in every combination. The retained summary is `E:\CodexValidation\unity-player-verification-v031-full-matrix-20260825\acceptance-summary.json` (SHA-256 `f2a112a773b63d63eb589c9132f8fb566d7dbdb5902fbd2d0ce379d5a1319f44`).

| Unity | Test Framework | Backend | Success | Top-level exception | Nested exception | Nested wait timeout | Maximum Player time |
| --- | --- | --- | --- | --- | --- | --- | ---: |
| `2022.3.62f3` | `1.1.33` | Mono | `PLAYER_VERIFIED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | 4.448 s |
| `2022.3.62f3` | `1.1.33` | IL2CPP | `PLAYER_VERIFIED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | 4.488 s |
| `6000.0.69f1` | `1.6.0` | Mono | `PLAYER_VERIFIED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | 5.004 s |
| `6000.0.69f1` | `1.6.0` | IL2CPP | `PLAYER_VERIFIED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | 4.245 s |
| `6000.5.3f1` | `1.7.0` | Mono | `PLAYER_VERIFIED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | 5.317 s |
| `6000.5.3f1` | `1.7.0` | IL2CPP | `PLAYER_VERIFIED` | `VERIFICATION_BLOCKED` | `PLAYER_FAILED` | `VERIFICATION_BLOCKED` | 5.084 s |

All 24 results matched their expected final status and result schema. Every one of the 18 failure cases wrote a completed atomic `FAILED` scenario receipt, exited with code 1 before the external timeout, and completed within 5.317 seconds. Nested cases retained the assertion and capture recorded before the exception.

Every Player run proved Job Object creation, kill-on-close configuration, process assignment, root exit, process-tree exit, and zero active processes after the wait. Each source build reported `UNCHANGED` and identical before/after fingerprints; all 24 summary records link back to the corresponding unchanged source result. No Unity, Package Manager, instrumented Player, crash handler, or shader compiler process remained after the matrix.

Before the complete matrix, a focused `6000.0.69f1 + Test Framework 1.6.0 + StandaloneWindows64/IL2CPP` run passed the same four cases at `E:\CodexValidation\upvr-v031-p3-u6000-il2cpp\acceptance-summary.json`. The project-specific CodexGame follow-up also produced `PLAYER_VERIFIED` with 11/11 assertions and 5/5 capture identities at `E:\CodexValidation\CodexGame-player-verification-v031-20260825\s-6d3a199b303f48c2a07cc006f86c09dc\result.json`; its source fingerprint, Git metadata, PlayerPrefs, LocalLow, and CrashDump safeguards were unchanged.

## Gate state — approved 2026-08-24

Release candidate `0.3.0-rc.1` passed the complete Mono and IL2CPP matrix before promotion to `0.3.0`. The promotion changes only public version and release documentation; the approved runtime, schemas, compatibility tuples, infrastructure, and process contracts are unchanged.

## Retained summaries

| Phase | Backend | Cases | Result | Summary |
| --- | --- | ---: | --- | --- |
| P1 | Mono Test Player | 24/24 | Approved | `E:\CodexValidation\upvr-p1-v030-20260824\acceptance-summary.json` |
| P2 | Mono scenario Test Player | 15/15 | Approved | `E:\CodexValidation\upvr-p2-v030-20260824\acceptance-summary.json` |
| P3 | Mono Standalone | 18/18 | Approved | `E:\CodexValidation\upvr-p3m-v030-20260824\acceptance-summary.json` |
| P3 | IL2CPP Standalone | 18/18 | Approved | `E:\CodexValidation\unity-player-verification-p3-il2cpp-final-b-20260824\acceptance-summary.json` |
| P3 0.3.1 patch | Mono and IL2CPP Standalone | 24/24 | Approved | `E:\CodexValidation\unity-player-verification-v031-full-matrix-20260825\acceptance-summary.json` |

Each P3 Unity/backend combination covered a successful receipt-backed scenario, deliberate assertion failure, crash, timeout, opaque launch-only observation, and post-build receipt/tree mismatch. All 36 P3 results matched the expected final status and retained the required source, bundle, build, process, and receipt evidence.

## Approved exact identities

| Unity | Test Framework | Unity executable SHA-256 | Windows Support tree SHA-256 |
| --- | --- | --- | --- |
| `2022.3.62f3` | `1.1.33` | `02e80b2c1d7f983375c97b612655be9f8ed852121e3a4eedf1570701c48ea5cd` | `4cbc2ca32cfbcb07f03b57d0c978942f12f13e12576d3f9ec72daf3841e4affe` |
| `6000.0.69f1` | `1.6.0` | `3927c20e4c76f15951989fd4866546b03d3ebfcc72bb5d708cd6397fad50451d` | `ef7ce53571421990a31217c95a60a846393d3e061d5918ad9269522422e63e36` |
| `6000.5.3f1` | `1.7.0` | `5e54f3a9953179419ddf8af860c3ccdcbb6ada45276fa9df06fdaaaa1124a118` | `e7c1e6cdebfd2de95a0babae430c2e0da6ae4c02dab3d4291fa29dd1ccad7834` |

All three module trees contain exact Windows x64 non-development Mono and IL2CPP variations. IL2CPP approval additionally pins:

| Identity | Approved value |
| --- | --- |
| Visual Studio | `18.9.12112.369` |
| MSVC | `14.51.36231` |
| Windows SDK | `10.0.26100.0` |
| Aggregate toolchain SHA-256 | `04c1806062d4f109fc29858ce1f8387124808cf8a8a31423647668d4749bc48a` |
| `cl.exe` SHA-256 | `e6d57100c82ae0310c18b16abfe52bc0df8fbb272ca6c5fb287d485807cfce91` |
| `link.exe` SHA-256 | `3ef8fcf80d409fab22ddd89ee19249f31a26ad9914d3e3e48573c30998fa24de` |
| `rc.exe` SHA-256 | `65db0d7b4f10ba0f55973fd9356543a556da9ec1c777a0c05f05a0329c8a100a` |

## Approval issue discovered and closed

The first `2022.3.62f3` IL2CPP build itself succeeded, but post-build hashing encountered a generated source path at the legacy 260-character Windows boundary. That run correctly produced `PLAYER_FAILED` and stopped the matrix. Its retained result is `E:\CodexValidation\unity-player-verification-p3-il2cpp-final-20260824\runs\2022.3.62f3\IL2CPP\success\s-7519439920cc4c6eac300fd2704eee67\result.json`.

The verifier now reads build-tree files through extended-length Windows paths in both the Unity-side C# receipt writer and PowerShell-side independent snapshot. PS5.1 and PS7 fixtures exercise a generated path beyond 260 characters, and the complete real-Unity IL2CPP matrix subsequently passed under the same long artifact-root structure.
