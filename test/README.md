# AgentSkill contributor tests

These tests supplement the existing suite without changing application code, configuration, or dependencies. All registry data is local test data installed at the application's fixed registry addresses. No network, fork, private key, environment mutation through `vm.setEnv`, or production deployment is required.

| Suite | Additional checks |
| --- | --- |
| `AgentSkillBoundaries.t.sol` | Exact events, atomic rejection, per-target/per-skill vote isolation, the active-skill cap with slots released by hiding, swap-and-pop list order with position bookkeeping across chained hides (unit and fuzz), zero/maximum identity IDs, policy boundaries, ownership handovers, dependency recovery, and rejection of ETH attached to valid calldata. |
| `AgentSkillNormalizationProperties.t.sol` | Valid inputs generated directly, equivalent case/space variants, every possible byte, punctuation, and the input-length boundary. |
| `AgentSkillScoreProperties.t.sol` | Equivalent decimal representations, monotonic quality/evidence, accepted/rejected work incentives, confidence and endorsement caps, integer extremes, publisher changes, and preexisting work without reputation records. |
| `AgentSkillRankingProperties.t.sol` | Pairwise rank oracle, truncation and ties, random visibility and page windows, 101 candidates, entirely hidden pages, live reordering, catalog pagination, and a fuzz property over random reputation and work-adapter outages: the scored prefix ranks only readable candidates and every unreadable active candidate trails it once, in scan order, naming the first failed source and carrying no partial figures. |
| `AgentSkillStateful.t.sol` | Six identities, five wallets, and three skills under random registration, hiding, endorsements, transfers, unauthorized attempts, evidence updates, per-agent reputation outages, and work-policy changes. |

The stateful model records actions independently of application storage. Every attempted mutation must either succeed as predicted or return the exact expected error. Its invariants check:

- Catalog and candidate membership remain unique; the active-skill list equals the model's swap-and-pop list exactly.
- Each endorsement corresponds to one identity and one historical wallet record for its target/skill pair, including after transfers and reactivation.
- Every active agent appears exactly once in its ranking. Readable agents form a descending scored prefix (ascending IDs for ties) with current evidence, current policy version, and correct component bounds; agents whose reputation summary is unreadable form the trailing tail in candidate order, flagged unavailable with the reputation registry as source and an all-zero breakdown, and their single-agent read reverts with `ScoreSourceUnavailable`.

New fuzz properties use 1,000 runs. The new stateful campaign uses 256 sequences of 80 calls, with unexpected reverts treated as failures. These settings are inline in the Solidity files. A deterministic sequence also exercises successful and rejected handler actions and both work-history modes.

Run the build and suite from the repository root:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build --offline
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache FOUNDRY_FUZZ_SEED=0xd9abfe71f2055d0868d0a24539113f27a9d2c4acc16d0d4273df17ed8888b709 forge test --offline
```

The scratch output paths keep generated artifacts out of submitted test files. The repository's existing vendored dependencies and installed Solidity compiler suffice for offline verification.

The previously reported diagnostic defect (a malformed successful reputation response producing empty revert data) is fixed by the budgeted, length-validated source reads; the suite now asserts the documented `ScoreSourceUnavailable` error and the `unavailable` leaderboard entry for malformed, reverting, and over-budget sources.

One low-severity finding remains in the assignment's `.imd-findings.json`: a candidate whose identity read fails (`ownerOf` reverting or returning zero for that one ID) still reverts the whole `getTopAgents` page with `UnregisteredAgent`, while a failed reputation or work read for the same candidate is reported in the unavailable tail without hiding the others. The report contains the self-contained test that was run and observed failing. The submitted passing suite does not assert that the page-wide revert is correct.

These tests verify the Solidity application's behavior against local dependencies. They do not certify live registry availability, publisher honesty, a production work-history adapter, or browser behavior.
