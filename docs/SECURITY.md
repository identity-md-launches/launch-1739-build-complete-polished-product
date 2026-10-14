# Security model and review notes

## Authorization and state

All agent mutations verify the caller against `ownerOf` in the fixed official IdentityRegistry. Unregistered IDs, wrong owners, self-endorsements, same-owner endorsements, duplicate identities and duplicate wallets fail. Owner-only policy setters inherit OpenZeppelin Ownable2Step. Ownership is an explicit constructor argument, transfers need acceptance, and renunciation is disabled. The owner cannot edit agent skills, add votes for others, transfer agent identities, set per-agent scores, or replace the official registry addresses.

External reads use Solidity `view` interface calls, which compile to STATICCALL. They cannot reenter and mutate AgentSkill state, even from a malicious source. There are no external state-changing calls, token operations, ETH transfers, fallback/receive functions, callbacks, signature verification, arbitrary delegatecalls, or valuable randomness. Sending ETH through a normal call fails; forced ETH has no associated claim or withdrawal path.

## Arithmetic and bounded work

Normalized metrics are capped at 10,000. Negative feedback is clamped before conversion to unsigned. Decimal powers are bounded at 18. Work counts are uint64; all multiplication occurs after promotion to uint256, well below that type's capacity. Accepted counts above completed counts are rejected. Rounding is always downward. All components sum to at most 10,000, and endorsements cannot exceed their 1,500-point allocation.

Skill lengths, per-agent active-skill arrays, client arrays, page scans, and sorted result sizes are bounded. Endorsement writes are constant-storage operations after registry reads. No transaction iterates over the full global population or full endorsement history. Summary reads are budgeted STATICCALLs whose return data is validated word by word; a failure, budget overrun or malformed answer becomes an explicit `ScoreSourceUnavailable` error or an `unavailable` leaderboard entry, never a synthetic zero score. A call that cannot fund one budgeted read fails with `InsufficientCallGas` before the read, so an underfunded caller cannot make a healthy source look broken.

## External trust and availability

The owner curates the reviewer list, metric tags, source gas budget, and optional work adapter. These settings immediately affect ranking. The owner never writes a score, but the publishers the owner selects author the reputation component and, in fallback mode, the history component: 85% of every score. Feedback in the official registry is permissionless except for the rated agent's own owner, so a single trusted publisher can set any agent's reputation, and a work adapter is trusted for the remaining history component as well. There is no timelock, decentralized reviewer selection, or external guarantee that a chosen publisher is honest; selecting more than one publisher dilutes but does not remove this power. Every change is observable through events and a policy-version increment. The dashboard publishes the active settings.

The official ERC-8004 contracts are external upgradeable registries. AgentSkill checks identity ownership and the reputation registry's identity namespace; it cannot prevent an upstream upgrade from changing behavior. Registry/source failures make the affected agent explicitly unscored. The official getSummary implementation scans an agent's whole stored history, so a history beyond the owner-set source gas budget (default 5,000,000 gas, about 650 records) cannot be scored until the owner raises the budget, up to 10,000,000. Such an agent is reported in every leaderboard page that contains it and never hides the other candidates; this bounded availability limitation is disclosed rather than a reason to omit strong agents.

No supplied address identifies an authoritative IMD accepted-work ledger. The optional adapter interface does not magically provide that data. Until configured, the history component is labeled quality-weighted rating depth. No stand-in adapter or fabricated completed-work count is shipped in production source.

## Sybil and semantic limitations

- ERC-8004 registration is permissionless and free apart from gas, so an agent's controller can mint fresh identities to fresh wallets and endorse itself through them; the self-endorsement rule stops only the direct case. The permanent wallet/ID uniqueness rule and the 15% cap (20 votes) bound this component but do not solve Sybil resistance. Gating endorsers on trusted feedback would exclude legitimately new agents and couple writes to the reputation source, so it is not done; readers should weigh endorsements accordingly.
- Candidate lists grow with every first registration of a label and are never pruned, so free identity registration can inflate the number of pages a leaderboard needs. Results stay correct; cost grows linearly with spam. A large registry can move discovery to an event indexer with the same semantics.
- Trusted feedback publishers may submit many favorable records or collude. The 20-record depth cap limits volume rewards, while reviewer curation remains essential.
- Feedback is general quality evidence; it is not automatically evidence of a particular skill or a completed job. Skill claims themselves are self-declared.
- Ownership transfers preserve identity history and votes. A buyer can acquire a strong identity. Previously valid endorsements remain valid historical statements even when two identities later share an owner.
- No recency decay is applied: old non-revoked records retain influence. No timestamp or fresh-work claim is implied. New negative feedback, revocations, and work outcomes affect live reads immediately.
- Synonyms, spelling differences, and ASCII-only labels can fragment skill discovery. Normalization handles only case and whitespace; the UI provides common presets.
- Public immutable events retain historical claims even when skills are hidden. Endorsements are intentionally not revocable in this version.

## Frontend

The app contains no private keys, secrets, arbitrary HTML rendering, automatic remote metadata fetches, or external script dependencies. It uses a committed ethers bundle and semantic native dialogs. The contract address is never inferred from unrelated activity or invented. The connection flow checks chain ID, code presence, expected registry constants, and weights; it is not a cryptographic verification that an arbitrary address is the official deployment. The operator and user must use the confirmed handoff address.

Score reads are pinned to one block, global top results require every page, failures show errors, and old asynchronous searches cannot overwrite a newer search. Wallet writes simulate first, recheck the chain and signer, and surface rejection, confirmation and pending timeouts. Registration-document links are treated as external untrusted content; the app never interprets their HTML.

## Local verification and limits

The suite covers registration authorization and normalization, nonexistent and zero-token IDs, duplicate/hidden skills, transfer permissions, endorsement replay, identity and wallet deduplication, source filtering and revocation, existing reputation on day one, decimal extremes, accepted-work arithmetic, unavailable and inconsistent sources, policy authorization, two-step ownership, score bounds, stable sorting, page boundaries, and refusal of ETH.

Stateful invariant tests vary identity ownership, skill visibility and endorsement attempts, checking successful events against a separate vote model. Deployment rehearsal uses CREATE2 with an explicit owner on an empty dependency chain and scans runtime opcodes, excluding PUSH data, for DELEGATECALL, CALLCODE and SELFDESTRUCT. Frontend tests verify bigint IDs, global pagination, cancellation, no partial-result fallback, safe document URLs, error decoding, and ABI consistency.

This is a local implementation review with deterministic tests, not an independent audit. Slither and Mythril were not run. No funded-wallet operation, production deployment, real-wallet signing, or production IMD work-adapter verification is claimed. A separate review should evaluate the chosen reviewer policy and any future adapter against its actual ledger before enabling it.
