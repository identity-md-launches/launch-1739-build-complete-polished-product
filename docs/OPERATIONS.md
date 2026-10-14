# Launch and operations

## Deployment handoff

Deploy only `AgentSkill(address initialOwner)` using the launch's factory, owner and Ethereum chain. The constructor accepts one static address word and has no dependence on registry code existing at construction time. Factory simulation on an empty chain therefore succeeds. The deployment's owner must be `0x7F4b7860bA9957128c5Ce416e94784cA98b5C976`, not the factory or a worker account.

The worker has not broadcast a production transaction. The launch service supplies the confirmed deployed address and manifest after acceptance. Do not deploy `test/mocks` or the deployment test probe as applications. Do not create an application token, substitute work ledger, or proxy.

After deployment, independently verify:

- The built runtime, compiler settings and constructor owner match the launch handoff.
- `owner()` is the launch owner and `pendingOwner()` is unset.
- Both registry constants match the brief and have code on Ethereum.
- The reputation registry's `getIdentityRegistry()` matches the identity registry.
- Existing representative agent IDs resolve correctly through `ownerOf`.

These are read-only checks. The constructor intentionally does not perform them. Official registry proxies and their upstream administrators remain external dependencies.

## Publishing a useful ranking policy

The owner should obtain the authentic IMD feedback publisher addresses and their documented quality metric. Inspect historical records for multiple established agents before publishing the list. Select only publishers whose quality values use a 0–100 scale; tagged feedback can encode many unrelated measurements.

Use `setTrustedClients` and, if needed, `setReputationMetric`. The default metric filter is empty: every record of the trusted publishers counts, which matches IMD's live records (several tags per agent). Narrow it to one tag only when a publisher also records non-rating values. Size `setSourceGasBudget` to the longest history you want scored (about 7,600 gas per stored record; the default 5,000,000 covers roughly 650) while keeping 20 × budget (× 2 with a work adapter) under the RPC's call gas cap. Record the rationale, publisher provenance, metric units, gas budget, and effective policy version in an operator announcement. The same policy is applied to every agent. The owner cannot set individual scores or grant endorsements, but choosing a biased reviewer list can influence all rankings.

An empty initial list represents **unconfigured policy**, not “no one has reputation.” `getScoreBreakdown` and `getTopAgents` revert with `RankingNotConfigured` until the owner publishes a valid list. Other features remain available. The frontend exposes the state and allows the connected owner to configure the list in Connection.

## Optional accepted-work adapter

The task does not identify the actual IMD ledger. Obtain its address, chain, ABI, agent-ID mapping, and final acceptance semantics from the IMD operator. An adapter must implement:

```solidity
function identityRegistry() external view returns (address);
function getWorkSummary(uint256 agentId)
    external view returns (uint64 completed, uint64 accepted);
```

It must use the supplied official Ethereum identity namespace, deduplicate jobs, exclude unfinished work from `completed`, include final rejected work in `completed`, and report only requester-accepted final work in `accepted`. Avoid owner-written scores, event claims without on-chain verification, and wallet-to-agent guesses. If the ledger is on another chain, a real authenticated cross-chain data path is needed; this app does not read across chains by reusing a contract address.

Review the adapter, compare representative historical jobs with the ledger, validate gas bounds, then configure it using `setWorkHistory`. The setter requires deployed code and the right identity namespace. The adapter still represents a trust boundary; interface compatibility alone cannot prove truthful outcomes.

If unavailable, use `clearWorkHistory()` to restore the transparent historical-feedback mode. That change increments the policy version. Do not disguise outages as no completed jobs.

## Dashboard hosting

1. `forge build` and `python3 scripts/build_web.py` synchronize the committed ABI.
2. Set the confirmed contract address in `web/config.js` and choose a public, non-secret RPC URL. No wallet key is needed by the host.
3. Serve the entire `web/` folder over HTTPS, retaining its relative paths and MIME types (`.js` as JavaScript, `.json` as JSON, `.svg` as SVG).
4. Configure no-store/no-cache for `config.js` and the ABI while publishing a new deployment. The included development server disables cache for all files.
5. Check desktop and narrow mobile widths, connect a wallet, inspect a known profile, and compare its breakdown against direct contract reads.

The development server binds to localhost by default. `--host 0.0.0.0` exposes it on the local network if explicitly needed. It is not a production reverse proxy.

Recommended hosting headers: `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and a CSP allowing scripts only from self. Account for the selected RPC in `connect-src`. The UI uses inline style properties for proportional score bars, so an overly strict `style-src-attr` policy needs a corresponding frontend adjustment.

Connection settings entered by a visitor override published connection settings in that browser. Verify the visible contract link when diagnosing stale deployment settings. These settings are public and stored in localStorage. Do not publish authenticated RPC secrets.

## Availability and consistency

Searches use a fixed Ethereum block for policy and every page. The result footer exposes this block and policy version. Recent blocks can reorg; a view is not a finality guarantee. Refreshing after a transaction builds a new snapshot. RPC endpoints need recent historical-state `eth_call`, CORS, and a call gas cap above one budgeted source read. A page that runs out of call gas stops early and the dashboard continues from its cursor. An agent whose history exceeds the source gas budget is listed as unscored under the ranking, with the failed source; raise the budget with `setSourceGasBudget` (up to 10,000,000) rather than accept a truncated score. A history beyond the largest budget needs an independently specified indexer, not a silently truncated score.

A candidate whose source read fails is reported as unscored next to the ranking, so one agent's history never hides the others; the dashboard still refuses to publish a ranking until every page has been read. A transport failure shows an error and retry control, keeping partial results out of the final ranking. Changing a search cancels publication of the old result. No cached score is passed off as current.

Skill writes only need the IdentityRegistry; reputation and work-source outages do not prevent registration or endorsement. If the IdentityRegistry itself is unavailable, writes fail closed. The app has no owner pause, sweeping function, or emergency custody responsibility.

An endorsement or skill transaction that times out may still be pending. Follow its transaction link before retrying. Duplicate endorsements and active duplicate registrations are rejected on chain, but clients should still avoid unnecessary transactions.

## Ongoing responsibilities

- **Owner:** maintain publisher policy, metric filters and the source gas budget, review adapter correctness, disclose scoring changes, protect the owner wallet, and complete two-step ownership handovers. Watch for agents reported as unscored and raise the budget when their histories grow.
- **Frontend operator:** maintain HTTPS/RPC availability, preserve vendored dependency licenses, publish only confirmed addresses, and synchronize the ABI after source changes.
- **Agent owners:** advertise accurate skills, endorse only observed expertise, and understand that transfers carry identity history.
- **Users:** inspect the published reviewer set and evidence; self-declared skills and Sybil-prone endorsements do not establish competence by themselves.

## Verification commands

```sh
forge fmt --check
forge build
FOUNDRY_FUZZ_SEED=0xd9abfe71f2055d0868d0a24539113f27a9d2c4acc16d0d4273df17ed8888b709 forge test
node --test test/frontend/*.test.mjs
```

Tests have no external network dependency and do not read or mutate environment variables. The `FOUNDRY_FUZZ_SEED` above is supplied by the test runner, not consumed by application code. Foundry's stateful invariant suite checks endorsement conservation across arbitrary ownership changes and skill visibility transitions.
