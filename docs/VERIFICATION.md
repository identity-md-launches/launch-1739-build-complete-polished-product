# Local verification record

The implementation was checked locally on 2026-10-14. These are reproducible development checks, not an independent audit or a production deployment attestation.

## Foundry

- Compiler: Solidity 0.8.26, pinned in `foundry.toml`.
- Seed: `0xd9abfe71f2055d0868d0a24539113f27a9d2c4acc16d0d4273df17ed8888b709`.
- 33 tests across application, stateful invariant, adversarial source and deployment-policy suites.
- Four fuzz tests, 512 runs each: formula bounds/exactness, work arithmetic, sorting, and skill normalization.
- Stateful invariant: 128 runs × 64 calls, 8,192 actions covering endorsement, identity transfer and visibility changes.
- Source-failure tests include a gas-exhausting reputation source, failed candidate aggregation, and an identity source attempting a state mutation through a static read even while holding application-owner authority.
- Runtime is below EIP-170, constructor input is below the init-code bound, and the local deployment rehearsal finds no forbidden escape opcodes outside PUSH data.

Run `make check` for build, tests, formatting and frontend logic tests. No fork or network is required. Test mocks live only under `test/` and are not launch applications.

## Frontend logic

Nine Node tests verify skill canonicalization, full uint256 IDs, page merging and stable ties, same-block global reads, empty/hidden candidates, cancellation, broken cursors, failure of complete rankings rather than partial fallback, safe external links, custom error decoding, and parity of the committed ABI with the compiled contract.

## Browser behavior

A temporary headless Chromium session and an isolated Anvil chain exercised the actual dashboard against the compiled application contract and test registries. The local chain used chain ID 1 solely to exercise the fixed Ethereum UI path; this is not evidence of a mainnet deployment. Browser tooling and seed scaffolding were kept in `test/scratch/`, which is not part of the deliverable.

Checked scenarios:

- Unconfigured first visit and connection setup without a wallet.
- Live ranking order and the exact weighted score of an established agent.
- Profile skill list, feedback count, score contributions and explicit historical-feedback label.
- Wallet connection, skill-registration transaction, confirmation and updated profile.
- Endorsement transaction, changed live score, and rejection of a duplicate.
- Rejected wallet authorization; no transaction sent.
- Wallet on another chain; switch to Ethereum before attempting a write.
- Wrong agent owner; simulation rejects before transaction submission.
- Account-change notification clears cached wallet identity.
- Owner-only scoring-policy controls become visible only for the current owner.
- Transaction feedback stays visible inside the active native dialog.
- Desktop at 1440px and mobile at 390px; no horizontal overflow and no uncaught browser exceptions.
- Automated WCAG A/AA checks with axe-core on the discovery page, settings dialog, score explanation and agent profile: no violations reported in those tested states.

This does not cover every browser, real wallet extension, smart-account wallet, RPC endpoint, screen reader, registry upgrade, or a production accepted-work adapter. The browser test data were local fixtures; none are used by the shipped dashboard.
