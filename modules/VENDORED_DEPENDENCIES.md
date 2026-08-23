# Vendored dependencies

The following files are immutable internal copies from `unity_play_verification_pipeline` tag `v0.3.0` (`cde10c0`). They keep this repository standalone while preserving the already-reviewed Doctor, isolation, process, schema, and package-identity contracts.

| Internal path | SHA-256 |
| --- | --- |
| `scripts/vendor/doctor/inspect-unity-project.ps1` | `aec20fbf43b00a0438158110088bf9ef656264b94e956a0901dfd7c80fb2d197` |
| `scripts/vendor/doctor/lib/unity-project-fingerprint.ps1` | `757a2bf5ef5a45e68bb6b71b766f0b31d7b5a77174b6985809f22fe8f0f69b0a` |
| `scripts/vendor/shared/git-metadata-integrity.ps1` | `2feadfb3d199ffc4556e90b1a35036d11f1a70c7b5bbf1207ec3b4eaaa2bcb7d` |
| `scripts/vendor/shared/json-schema-validator.ps1` | `e93ec93f8c2ce6e1db1065dc12ede3a4a503ffc5060262fca63acc9211ed97c7` |
| `scripts/vendor/shared/unity-baseline-orchestration.ps1` | `395af0d5341da7c3b6405338b6842449c5c91e9ddf8261c4c52512af627e4c37` |
| `scripts/vendor/shared/unity-isolation-path-budget.ps1` | `24f9b9b10fa70ab66ed5a5a5ad19516d1ec4ccc5152a9f89a453e7d0ae246974` |
| `scripts/vendor/shared/unity-process-job.ps1` | `f1e6caa35391777c30a0372f0aabbfe5b144d5aebcea87cf4ed3239201e0a128` |
| `scripts/lib/unity-play-verification-core.ps1` | `1c40fa02c5a2d44bc2c7af6f162949bc57dbc41c8bf7fe988bee36026e7e400c` |
| `scripts/lib/unity-test-framework-identity.ps1` | `ecd29468afe9986b3e4ec3c839ce1174bf2b1dbca2eab2f01f13280ef2eb852b` |

The copied `Upv` function prefix is retained intentionally. These functions execute only inside the new verifier process and are wrapped by Player-specific `Upvr` functions. The Job Object copy is the sole derived module: it preserves the reviewed native process setup and adds build-receipt phase transition, independent build/run deadlines, and an explicit retained failure-signal stop. Its derived hash is pinned above and covered by Player-specific tests.
