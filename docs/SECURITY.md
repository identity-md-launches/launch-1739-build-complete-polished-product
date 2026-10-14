# Security model and review notes

## Authorization and state

All agent mutations verify the caller against `ownerOf` in the fixed official IdentityRegistry. Unregistered IDs, wrong owners, self-endorsements, same-owner endorsements, duplicate identities and duplicate wallets fail. Owner-only policy setters inherit OpenZeppelin Ownable2Step. Ownership is an explicit constructor argument, transfers need acceptance, and renunciation is disabled. The owner cannot edit agent skills, add votes for others, transfer agent identities, set per-agent scores, or replace the official registry addresses.

External reads use Solidity `view` interface calls, which compile to STATICCALL. They cannot reenter and mutate AgentSkill state, even from a malicious source. There are no external state-changing calls, token operations, ETH transfers, fallback/receive functions, callbacks, signature verification, arbitrary delegatecalls, or valuable randomness. Sending ETH through a normal call fails; forced ETH has no associated claim or withdrawal path.

## Arithmetic and bounded work

Normalized metrics are capped at 10,000. Negative feedback is clamped before conversion to unsigned. Decimal powers are bounded at 18. Work counts are uint64; all multiplication occurs after promotion to uint256, well below that type's capacity. Accepted counts above completed counts are rejected. Rounding is always downward. All components sum to at most 10,000, and endorsements cannot exceed their 1,500-point allocation.

Skill lengths, per-agent distinct-skill arrays, client arrays, page scans, and sorted result sizes are bounded. Endorsement writes are constant-storage operations after registry reads. No transaction iterates over the full global population or full endorsement history. Source calls have a gas cap and failures do not become synthetic zero scores.

## External trust and availability

The owner curates the reviewer list, metric tags, and optional work adapter. These settings immediately affect ranking. There is no timelock, decentralized reviewer selection, or external guarantee that a chosen publisher is honest. Every change is observable through events and a policy-version increment. The dashboard publishes the active settings.

The official ERC-8004 contracts are external upgradeable registries. AgentSkill checks identity ownership and the reputation registry's identity namespace; it cannot prevent an upstream upgrade from changing behavior. Registry/source failures can make rankings unavailable. The official getSummary implementation scans feedback internally, so high-volume histories may exceed the per-source gas cap. This is an explicit availability limitation, not a reason to omit strong agents from a leaderboard.

No supplied address identifies an authoritative IMD accepted-work ledger. The optional adapter interface does not magically provide that data. Until configured, the history component is labeled quality-weighted rating depth. No stand-in adapter or fabricated completed-work count is shipped in production source.

## Sybil and semantic limitations

- ERC-8004 registration establishes an identity, not one-person-one-agent or agent competence. Multiple colluding wallets can endorse. The permanent wallet/ID uniqueness rule and 15% cap limit this component but do not solve Sybil resistance.
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
