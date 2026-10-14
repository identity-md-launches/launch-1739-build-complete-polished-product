# AgentSkill contributor tests

These tests supplement the existing suite without changing application code, configuration, or dependencies. All registry data is local test data installed at the application's fixed registry addresses. No network, fork, private key, environment mutation through `vm.setEnv`, or production deployment is required.

| Suite | Additional checks |
| --- | --- |
| `AgentSkillBoundaries.t.sol` | Exact events, atomic rejection, per-target/per-skill vote isolation, hidden skill capacity, zero/maximum identity IDs, policy boundaries, ownership handovers, dependency recovery, and rejection of ETH attached to valid calldata. |
| `AgentSkillNormalizationProperties.t.sol` | Valid inputs generated directly, equivalent case/space variants, every possible byte, punctuation, and the input-length boundary. |
| `AgentSkillScoreProperties.t.sol` | Equivalent decimal representations, monotonic quality/evidence, accepted/rejected work incentives, confidence and endorsement caps, integer extremes, publisher changes, and preexisting work without reputation records. |
| `AgentSkillRankingProperties.t.sol` | Pairwise rank oracle, truncation and ties, random visibility and page windows, 101 candidates, entirely hidden pages, source failures, live reordering, and catalog pagination. |
| `AgentSkillStateful.t.sol` | Six identities, five wallets, and three skills under random registration, hiding, endorsements, transfers, unauthorized attempts, evidence updates, and work-policy changes. |

The stateful model records actions independently of application storage. Every attempted mutation must either succeed as predicted or return the exact expected error. Its invariants check:

- Catalog and candidate membership remain unique; active skills retain registration order.
- Each endorsement corresponds to one identity and one historical wallet record for its target/skill pair, including after transfers and reactivation.
- Every active agent appears exactly once in its ranking, with current evidence, current policy version, correct component bounds, descending scores, and ascending IDs for ties.

New fuzz properties use 1,000 runs. The new stateful campaign uses 256 sequences of 80 calls, with unexpected reverts treated as failures. These settings are inline in the Solidity files. A deterministic sequence also exercises successful and rejected handler actions and both work-history modes.

Run the build and suite from the repository root:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build --offline
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache FOUNDRY_FUZZ_SEED=0xd9abfe71f2055d0868d0a24539113f27a9d2c4acc16d0d4273df17ed8888b709 forge test --offline
```

The scratch output paths keep generated artifacts out of submitted test files. The repository's existing vendored dependencies and installed Solidity compiler suffice for offline verification.

One low-severity diagnostic defect is reported in the assignment's `.imd-findings.json`: a malformed successful reputation response bypasses the documented `ScoreSourceUnavailable` error and produces empty revert data. The report contains the self-contained test that was run and observed failing. The submitted passing suite does not assert that empty revert data is correct. Valid-source scoring, custody safety, and authorization are separate from this diagnostic limitation.

These tests verify the Solidity application's behavior against local dependencies. They do not certify live registry availability, publisher honesty, a production work-history adapter, or browser behavior.
