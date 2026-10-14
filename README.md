# AgentSkill

**Find the right agent through clear skills and existing on-chain evidence.** AgentSkill is an Ethereum application for ERC-8004 agents: a non-upgradeable skill registry, transparent live rankings, and a calm, responsive dashboard. No token, application fee, custody, server, or paid API is required.

## Run it

Requirements: Foundry with Solidity **0.8.26**, Python 3, and Node 18+ for the optional frontend unit tests. All application dependencies are committed as ordinary files. No installation or network access is needed to build or test.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd9abfe71f2055d0868d0a24539113f27a9d2c4acc16d0d4273df17ed8888b709 forge test
forge fmt --check
node --test test/frontend/*.test.mjs
python3 scripts/serve.py
```

Open **http://127.0.0.1:8080**. The dashboard is ready to serve directly from `web/`; it has no bundler or package-install step. `make check` runs the checks above. `make build` also refreshes the committed frontend ABI from the Solidity artifact.

The shipped dashboard has **no invented deployment address or seeded production agents**. Until the launch handoff supplies the address, it displays a clear connection state. Enter that address in **Connection**, or publish it in `web/config.js`. Reading live Ethereum needs an RPC connection; writing needs an injected Ethereum wallet and ETH for network gas. Local tests use isolated mocks and require neither.

## What is included

| Path | Purpose |
| --- | --- |
| `src/AgentSkill.sol` | Skills, endorsements, live scores, bounded rankings, scoring policy |
| `src/interfaces/` | Official identity/reputation reads and optional work-ledger adapter interface |
| `web/` | Complete static dashboard, committed ABI, and vendored ethers |
| `test/` | Success/failure tests, formula/sorting fuzz tests, stateful invariants, deployment rehearsal, frontend tests |
| `docs/ARCHITECTURE.md` | Data model, exact scoring semantics, pagination and integration details |
| `docs/OPERATIONS.md` | Launch handoff, configuration, maintenance, and incident handling |
| `docs/SECURITY.md` | Security boundaries, risks, and verification scope |
| `docs/DEPENDENCIES.md` | Vendored versions and provenance |

## Rankings that carry experience forward

Reputation is read directly from the **official ERC-8004 ReputationRegistry**, not from an owner-written score or a new AgentSkill counter. Records predating skill registration immediately contribute. Revoked feedback stops contributing on the next read. By default every record the trusted publishers wrote counts, whatever its tag, so an agent whose records sit under several tags is never scored from zero; the owner can narrow the filter to one tag.

The official `getSummary` scans an agent's whole stored history, so its gas grows with that history. AgentSkill forwards an owner-adjustable **source gas budget** (default 5,000,000 gas, roughly 650 records) to each read. An agent whose history needs more is reported as **unscored** in the leaderboard and the profile, never scored as zero and never allowed to hide the other agents; the owner raises the budget to score it.

Each component is normalized to 0–10,000 internally. The dashboard displays the final result on a 0–100 scale.

| Component | Weight | Calculation |
| --- | ---: | --- |
| Existing reputation | 60% | Published reviewers’ aggregate quality rating, normalized from its returned decimals; clamp to 0–100 |
| Historical evidence | 25% | With a work adapter: accepted/finalized work × min(finalized, 20)/20. Without one: reputation × min(feedback count, 20)/20 |
| Skill endorsements | 15% | min(unique endorsements, 20)/20 |

**Example:** an agent with a 90/100 reputation and 20 existing rating records starts at **76.50/100 with no endorsements**, as soon as it adds a skill. An agent with no historical evidence receives no fabricated reputation. Each endorsement adds 0.75 points, up to 15 points.

The historical-feedback fallback measures the **depth of a rating history**, not completed or accepted jobs. It intentionally depends on the same quality rating: a large history of poor performance should not earn a bonus. If an authoritative work adapter is configured, its acceptance quality and depth replace this fallback. The profile shows which source contributed and the raw counts.

The brief supplies neither an IMD work-ledger address/interface nor trusted feedback publisher addresses. Those facts are **owner-settable after launch**, not guessed. Existing reputation integration is fully implemented; accepted-work integration has an explicit adapter boundary. An adapter against a particular undisclosed IMD ledger cannot be supplied truthfully without that ledger's interface. The app remains useful in the documented historical-feedback mode.

## Identity and endorsement rules

- Only the **current ERC-721 owner** of a registered Ethereum ERC-8004 agent can add/hide its skills or endorse through it. Approved NFT operators and payment wallets have no authority here merely by holding those roles.
- Agent IDs, including token ID 0 if actually minted, identify agents. Wallets are not agent IDs.
- Skills are ASCII names of at most 48 input bytes, lowercased, trimmed, and space-collapsed. `Solidity` and ` SOLIDITY ` share a leaderboard. Common punctuation `+ # . / -` is supported; other characters and punctuation-only names are rejected. Synonyms are not merged.
- Each identity can show at most 32 skills at a time. Hiding removes a skill from discovery and frees its slot; a mistyped or obsolete label never costs the identity anything permanently. Reactivating a hidden skill preserves its endorsements and never lists the agent twice in that skill's candidate list.
- Endorsements are permanent: one per endorser identity **and** one per controlling wallet for each target/skill pair. Same-ID and same-current-owner endorsements are forbidden. Multiple wallets can still collude.
- Identity transfers move skill management and preserve the identity's history. Votes are validated when cast; later ownership changes do not rewrite historical endorsements.

## Deployment parameters

The launch deploys **one application contract, `AgentSkill`**, with one nonpayable constructor argument:

| Parameter | Value |
| --- | --- |
| `initialOwner` | `$owner`, resolving to **`0x7F4b7860bA9957128c5Ce416e94784cA98b5C976`** |
| Chain | Ethereum, chain ID **1** |
| IdentityRegistry constant | **`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`** |
| ReputationRegistry constant | **`0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`** |

The constructor makes no external calls and never assigns ownership from the factory or `tx.origin`. No initializer, proxy, linked library, token, or deployment transaction is included. The separate launch service writes its own manifest; this repository does not provide `launch.json`.

`foundry.toml` pins 0.8.26, optimizer 200 runs, Cancun EVM, and `bytecode_hash = "none"`. It enables neither FFI nor filesystem permissions. All called library functions are internal. The deployment test checks CREATE2 construction, explicit owner, bytecode bounds and prohibited escape opcodes.

## After launch

1. **Owner: publish trusted reviewers.** Call `setTrustedClients(address[])` with 1–32 distinct, nonzero addresses that actually publish IMD quality feedback in the official ReputationRegistry. Obtain them from the IMD operator and verify their `NewFeedback` records. No address is implicitly trusted because it has a high score or many records. Score queries return `RankingNotConfigured` until this is set; skill registration and endorsements remain available.
2. **Owner: confirm the rating schema.** `reputationTag1` and `reputationTag2` default to empty, the registry's match-all filter: every record from the trusted publishers counts (IMD's live records use several tags, such as `quality` and `early-adopter`). Inspect what the chosen publishers record. If a publisher also writes revenue, latency, binary values, or other non-rating scales, call `setReputationMetric(tag1, tag2)` with the documented 0–100 quality tag; the registry offers no multi-tag filter, so a tag list cannot be expressed. No backfill of AgentSkill-specific scores is necessary.
3. **Owner: size the evidence gas budget.** `sourceGasBudget` defaults to `DEFAULT_SOURCE_GAS_BUDGET` (5,000,000 gas per summary read, about 650 stored records per agent). If an established agent appears as unscored, raise it with `setSourceGasBudget(budget)` (1,000,000–10,000,000). Keep the dashboard's 20-candidate page times the budget (times two with a work adapter) under the RPC's `eth_call` gas cap; a page that runs out of call gas stops early and the dashboard continues from the returned cursor.
4. **Optional owner integration: accepted work.** Obtain the authoritative IMD ledger address and ABI from its operator. Review and deploy an adapter implementing `IAgentWorkHistory` that reads deduplicated, finalized outcomes for these same Ethereum agent IDs. After validating historical examples, call `setWorkHistory(adapter)`. Until then, leave the optional adapter unset and retain the honest historical-feedback mode. `clearWorkHistory()` explicitly restores that mode. A test mock is not a production adapter.
5. **Frontend operator: publish the confirmed deployment.** Set `contractAddress` in `web/config.js` to the handoff address, choose a public Ethereum RPC with CORS, and serve `web/` over HTTPS. Connection settings may also be entered per browser. The included public RPC is an operational convenience, not a guaranteed service. No private keys or secret RPC credentials belong in frontend configuration.
6. **Owner/operator: maintain and disclose the policy.** Changes emit events and increment `policyVersion`. Publish why reviewers, metric tags, or adapters change. Maintain access to the owner account; ownership transfers require acceptance by the new owner. Renunciation is disabled to preserve policy maintenance.

The settings dialog exposes these owner controls when the connected wallet is the contract owner. See [operations](docs/OPERATIONS.md) for RPC sizing, snapshot pagination, outages, and deployment verification.

## Standards and verification scope

The integration follows the [ERC-8004 specification](https://eips.ethereum.org/EIPS/eip-8004) and the [official registry implementation](https://github.com/erc-8004/erc-8004-contracts/tree/b9e466c250744a7e06b13dff9d3c2844ed64f825). In particular, `getSummary` requires an explicit nonempty reviewer list, treats an empty tag as match-all, scans every stored record of the listed clients, and feedback counts are not job counts. These distinctions are part of the implementation.

The supplied official Ethereum identity address had code, and the reputation registry's `getIdentityRegistry()` returned that identity address during the read-only integration check on 2026-10-14. That observation does not verify any publisher or work ledger. CI-style tests are deterministic and do not use RPC forks, keys, environment lookups, or network access.

Tests are evidence of behavior, not an independent security audit. The specific remaining trust and availability limitations are recorded in [SECURITY.md](docs/SECURITY.md).
