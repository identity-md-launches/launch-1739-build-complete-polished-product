# AgentSkill Dashboard

A calm, responsive dashboard for finding Ethereum agents by skill and understanding their on-chain experience. The finished static site is in **`dist/`**; its React and TypeScript source, package manifest, and lockfile are in **`web/dashboard/`**.

## Preview the finished site

No install is needed to serve the production export:

```sh
python3 -m http.server 8080 --directory dist
```

Open `http://localhost:8080`. Use an HTTP server rather than opening `index.html` as a local file. Production hosting should use HTTPS for wallets and clipboard access. The export uses relative asset URLs and hash navigation, so it also works at a gateway subpath without server route rewrites.

## Install, develop, and rebuild

Use Node.js 22.12+ or Node.js 24 and npm. The existing root package and Solidity build configuration are retained; run frontend commands in the new dashboard directory:

```sh
cd web/dashboard
npm ci
npm run dev
```

For a production build and preview:

```sh
cd web/dashboard
npm run typecheck
npm test
npm run build
npm run preview -- --host 127.0.0.1
```

Vite writes the complete export to the repository-root `dist/` directory. Rebuild and include that directory whenever frontend source or assets change. The publisher serves the export; it does not rebuild it. Only local fonts, icons, and runtime bundles are required to render the interface. Ethereum reads require network access. No backend, private credentials, relay, or WalletConnect project ID is required.

Keep all dependency installations and package-manager caches out of submissions, including nested `node_modules/`. This delivery installed dependencies in an external temporary build workspace and synchronized only the source, lockfile, and finished export. No ignore file was changed.

## What the dashboard does

- **Discover:** search any supported skill name, use suggested skills, browse the on-chain catalog, and view the global top 20 scored agents. Search terms are included in the URL.
- **Agent profile:** look up a numeric ERC-8004 agent ID, see its current owner, active skills, endorsements, weighted scores, and evidence breakdown. Share the profile link.
- **My skills:** connect the identity-owner wallet, enter the agent ID, add skills, or hide skills while preserving their endorsement history.
- **Endorse:** use another registered agent you own to permanently endorse a target skill. The interface explains the effect, simulates the action, and tracks the transaction through confirmation.
- **How it works:** inspect score weights, publisher policy, history mode, contract address, and the snapshot block.

Browser wallets are discovered through EIP-6963. Phone browsers without an injected wallet offer MetaMask, Coinbase Wallet, Rabby, and Phantom browser links. Coinbase Smart Wallet is also available through the Coinbase SDK. The connection control supports network switching and disconnecting. Every write verifies the chain and deployed runtime code, checks current identity ownership, simulates the contract call, rechecks the wallet account/network, and waits for a successful receipt.

## Live deployment and ranking behavior

| Item | Pinned value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| AgentSkill | `0xabec9774d66c640b64238dbd69758d31d10d54b1` |
| Source commit | `cae6d4dcf66b14da9c8dadb25dac59f2697f3e92` |
| Canonical ABI keccak | `b496e524ca306f337d976085c9c9b4980ff142932f164ef0c2bcea58d0372ed0` |
| Compiled runtime keccak | `e271cd477eb394ac1c6709ed7cf49ea40a2b5514f0d50dd1f3ae8db1a2e7de9a` |

The deployment and public RPC parameters are preserved in `web/dashboard/src/deployment.json`. The identity registry address is read from the verified contract, not guessed. The ABI was generated from the unchanged pinned Solidity source and checked against the deployment hash. Recheck the generated ABI and runtime hash with:

```sh
forge build --skip test --skip script
node scripts/verify-dashboard.mjs
```

The live browser check on **2026-10-15**, at block **26,196,964**, verified the deployed runtime code. At that snapshot, the contract had no configured trusted feedback publishers, used rating-history mode, and the Solidity search had no registered candidates. The dashboard displays these actual states. It contains no sample production agents, invented scores, or seeded statistics.

The contract owner must configure real trusted publishers through the existing `setTrustedClients(address[])` function before rankings become available. This dashboard job does not change that policy or deploy anything. Skills and endorsements do not require scoring to be configured. The optional work-history adapter remains owner-settable; an unset adapter means historical rating evidence, not accepted jobs.

Scores combine **60% reputation, 25% historical evidence, and 15% endorsements**. Ranking pages, profile evidence, and scoring policy are pinned to one block. Every candidate page is merged before the global top 20 is shown; equal scores use the lower numeric agent ID first. Hidden registrations count as historical candidates, not active agents. Unavailable evidence is listed separately and is never converted to a zero score. A failed page does not produce a misleading partial leaderboard. Refresh retrieves a new snapshot.

## Validation

The worker ran the production build, TypeScript check, nine dashboard unit tests, eleven retained frontend tests, ABI/runtime verification, Chromium and WebKit interaction tests, the pinned taste@1 probe, and rendered accessibility/reflow checks. The detailed actual results, fixes, screenshots, and limitations are in **[docs/dashboard-review/validation.md](docs/dashboard-review/validation.md)**. The implemented design is documented in **[DESIGN.md](DESIGN.md)**.

To repeat the browser suite, first build the Solidity artifact and the dashboard, then install browser runtimes:

```sh
forge build --skip test --skip script
cd web/dashboard
npm ci
npm run build
npx playwright install --with-deps chromium webkit
npm run test:browser
TEST_ENGINE=webkit npm run test:browser
```

The suite starts and stops its own local server under `/preview/`. It intercepts RPC and wallet requests with isolated test fixtures and never broadcasts a transaction. It covers search, global ranking and pagination, profiles, forms, connection/network switching, add/hide/endorse calls, success/revert/rejection, offline recovery, keyboard focus, and the phone picker. Reports go to `test/scratch/` and are not application data.

Live authenticated signing, passkey creation, physical phones, native browser zoom, and screen-reader sessions were not performed. Browser fixtures validate UI behavior and encoded transactions; they are not evidence that a mainnet transaction was executed. Public RPCs and third-party wallet applications remain external availability dependencies.

## Repository layout

| Path | Purpose |
| --- | --- |
| `dist/` | Finished static export, including relative runtime assets and share image |
| `web/dashboard/src/` | Current dashboard, wallet connector, transaction flow, ABI and public deployment configuration |
| `web/dashboard/tests/` | Unit tests and isolated browser interaction suite |
| `web/dashboard/public/` | Local favicon, share image, wallet marks, runtime license notices |
| `web/dashboard/art/share.svg` | Editable source for the share image |
| `DESIGN.md` | Implemented visual system and responsive patterns |
| `docs/dashboard-review/` | Committed validation report, check results, and real export screenshots |
| `artifacts/` | Matching delivery-artifact copies of the review |
| `src/AgentSkill.sol`, `src/interfaces/` | Existing live contract and interfaces, unchanged |
| `test/`, `docs/` | Existing contract tests, architecture, security, and operations documentation |
| `web/app.js`, `web/core.js`, `web/index.html` | Retained original dashboard; its public config now points at the verified launch |

The legacy root `npm start` and `npm run build` commands remain unchanged and target the earlier frontend. Use the commands above for the new production dashboard. No token, contract, or pool was redeployed or replaced.

## Attribution

Design review used the pinned Better Interface guide by Jakub Krehel (MIT) and the adapted documentation method from Paul Bakaus’s Impeccable (Apache-2.0). Their notices and licenses are retained in `web/dashboard/licenses/Design-guidance.txt`. Inter is bundled under the SIL Open Font License. Wallet marks are from RainbowKit 2.2.11; runtime attribution is included in `dist/THIRD-PARTY-NOTICES.txt`.
