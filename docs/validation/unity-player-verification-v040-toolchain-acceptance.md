# v0.4.0 IL2CPP toolchain-profile acceptance

## Gate state — approved 2026-08-30

The schema `1.2.0` toolchain profile `msvc-14-51-36231-sdk-10-0-26100-0-8fff423cab47` is approved for the production registry. The verifier and acceptance harness cannot promote a profile automatically; this promotion records an explicit user decision made after reviewing the retained evidence.

The retained complete-matrix summary is `E:\CodexValidation\unity-player-verification-v040-full-matrix-pass2-20260830\acceptance-summary.json`, with SHA-256 `8f427cd52baca82950f461ad924dcb25b8f45b75f79eb485a5fc2e215725d77f`. Its machine status is `APPROVAL_ELIGIBLE`. The user explicitly approved that exact path, digest, and status at `2026-08-30T07:52:02.471901500Z`.

## Approved profile identities

| Evidence | Value |
| --- | --- |
| Candidate document | `E:\CodexValidation\unity-player-verification-v040-toolchain-candidate\toolchain-candidate.json` |
| Candidate document SHA-256 | `6ade7ec84891c9f24924072d7e08ef0816a631a8f739ee3fea6a0d550b010caf` |
| Build identity algorithm | `upvr-il2cpp-build-toolchain-v2` |
| Build identity SHA-256 | `8fff423cab4707e314325938903ac7bd545b2f46e06883549f7b7a6ad823e09d` |
| Host identity algorithm | `upvr-il2cpp-host-environment-v1` |
| Approval-run host identity SHA-256 | `9eecfba859bc788246c5d7eab228e45e91cd44c5059b64d1e92b4c1829848408` |
| Visual Studio | `18.9.12120.119` at `C:\Program Files\Microsoft Visual Studio\18\Community` |
| MSVC | `14.51.36231` |
| Windows SDK | `10.0.26100.0` |

The build identity excludes Visual Studio product version and absolute installation path. It includes the fixed compiler/linker/librarian and dependent-tool manifest plus deterministic MSVC and Windows SDK header/library trees. The host identity retains Visual Studio instance, version, product, channel, path, state, required components, and `vswhere` identity.

## Complete real-Unity matrix

Six fresh source builds were produced: three supported Unity versions times Mono and IL2CPP. Each build then supplied nine independent records: success, assertion failure, top-level exception, nested exception, nested `WaitUntil` timeout, crash, run timeout, opaque launch, and receipt/tree mismatch.

| Unity | Test Framework | Backend | Cases | Exact expected statuses | Source/Git safe | IL2CPP identity/Bee |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `2022.3.62f3` | `1.1.33` | Mono | 9 | 9 | 9 | N/A |
| `2022.3.62f3` | `1.1.33` | IL2CPP | 9 | 9 | 9 | 9/9 |
| `6000.0.69f1` | `1.6.0` | Mono | 9 | 9 | 9 | N/A |
| `6000.0.69f1` | `1.6.0` | IL2CPP | 9 | 9 | 9 | 9/9 |
| `6000.5.3f1` | `1.7.0` | Mono | 9 | 9 | 9 | N/A |
| `6000.5.3f1` | `1.7.0` | IL2CPP | 9 | 9 | 9 | 9/9 |

All 54 records use result schema `1.1.0`, have unique result paths, and match their expected final status. The final-status distribution is six `PLAYER_VERIFIED`, six `PLAYER_LAUNCH_VERIFIED`, eighteen `PLAYER_FAILED`, and twenty-four `VERIFICATION_BLOCKED`.

All 48 cases that started a Player proved Job Object creation, process assignment, root exit, process-tree exit, and zero active processes. The six receipt-mismatch cases were rejected before Player start. Every result links to an unchanged source fingerprint and safe Git state. Every IL2CPP record reports unchanged pre/post build and host identities plus accepted isolated Bee evidence for the selected `cl.exe`, `lib.exe`, and `link.exe` paths.

## Harness correction retained during approval

The first full-matrix attempt at `E:\CodexValidation\unity-player-verification-v040-full-matrix-20260830` stopped after the first IL2CPP prebuilt case because the summary recorder read build-only toolchain fields from the prebuilt result rather than its source build result. The underlying source build and case result were not rejected. The recorder was corrected, PowerShell 5.1/7 fixtures were rerun, and the complete matrix was restarted in the `pass2` root. The interrupted evidence remains retained and is not part of the approval-eligible summary.

## Promotion record

The production profile records the external summary path, exact digest, and approval timestamp above. This human approval is distinct from the machine-generated `APPROVAL_ELIGIBLE` status, and the production verifier remains unable to create or promote an `APPROVED` profile. Schema, PowerShell 5.1/7, installer, Skill, diff, and repository-integrity gates must pass after promotion before the local `v0.4.0` commit and tag are created. Push and GitHub Release remain out of scope.
