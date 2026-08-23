# `$unity-player-verification`

The Skill is intentionally explicit-only. It is not an automatic continuation of Unity Doctor, Baseline, or Editor Play verification.

Use `TEST_PLAYER` for existing PlayMode tests, `SCENARIO_TEST_PLAYER` for a reviewed source-only Player scenario, `INSTRUMENTED_STANDALONE` for a pipeline-built standalone scenario, and `PREBUILT_STANDALONE` only for a user-selected existing build root and executable.

The machine-readable `result.json` is authoritative. Preserve its warnings, failures, blockers, verification scopes, and exact final status.
