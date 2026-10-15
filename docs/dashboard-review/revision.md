# Dashboard revision validation

Worker validation, 2026-10-15. Complete for the three reported findings. These are local observations, not independent certification. The existing design, dependencies, contract connection, and transaction implementation are retained.

## Reproduction and corrections

Each finding was reproduced against the original `dist/` before the production source was changed. `.imd-responses.json` contains the full finding IDs and verdicts.

| Finding | Reproduction | Correction and recheck |
| --- | --- | --- |
| `da1955d6…` — long-skill overflow | Searching 48 lowercase `s` characters produced a 557px page at 390px and a 553px page at 320px in the assigned browser. Refresh ended outside the card. The new Chromium regression also failed against the original export: 558px page at 320px. | `web/dashboard/src/styles.css:91`: permit the heading flex child to shrink and wrap the heading and empty-state paragraph anywhere. The full name remains visible. The assigned browser now measures page widths of 390 and 320; Refresh ends at 351 and 285 respectively, within card edges of 370 and 304. Chromium verifies empty and populated results at 320, 390, and 1440, full text bounds, and a working Refresh. |
| `9324509a…` — management slogans | At 390×844, the three reported headings appeared; the h1 occupied two lines and the steps heading began at y=771.58. The report is a real clarity issue on a task screen. | `web/dashboard/src/App.tsx:167`: use “Manage skills”, remove the connection-panel heading, and use “How to add skills”. Remove the paragraph’s now-unneeded top margin in `styles.css:193`. The h1 is one line at 390; Connect wallet moves from y=415.72 to y=346.14. Ownership, agent-ID, endorsement, and fee guidance are retained. Connect opens the wallet dialog; Escape restores focus. No overflow at 320, 390, or 1440. |
| `6471ebb4…` — joined mobile words | `#score-guide-title.innerText` was “A clearer pictureof expertise.” below 560px. | `web/dashboard/src/App.tsx:126`: retain a literal space before the responsive line break. Discover and Agent profile now read “A clearer picture of expertise.” at 320 and 390. The desktop line break remains visible at 1440. |

## Checks performed

Dependencies were installed from the unchanged dashboard lockfile in a temporary build copy. Source, tests, manifest, and lockfile were copied without modifications; only the complete rebuilt export was synchronized back. No repository dependency directory or cache was added. Commands below use the dashboard directory unless otherwise stated.

| Command / check | Actual result |
| --- | --- |
| `npm ci` | Exit 0; unchanged lockfile installation |
| `npm run typecheck` | Exit 0 |
| `npm test` | Exit 0; 9 tests passed |
| `npm run build` | Exit 0; Vite production export rebuilt after the final application source change |
| `npm run test:browser` | Exit 0; 30 Chromium checks passed, including two new long-skill checks. Export served under `/preview/`; RPC/wallet fixtures are isolated and send no real transactions. Existing ranking, profiles, wallet, registration, hiding, endorsement, errors, keyboard, and axe checks passed. |
| `TEST_ENGINE=webkit npm run test:browser` | Exit 1 before testing: WebKit could not launch. No revision WebKit behavior was verified. |
| `forge build --skip test --skip script` (root) | Exit 0; unchanged contract compiled for the existing browser fixtures; existing lint warnings remain |
| `node scripts/verify-dashboard.mjs` (root) | Exit 0; compiled ABI, canonical ABI hash, and runtime hash match the pinned record |
| Pinned `node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste` (root) | Exit 0; 16/16 checks passed on the rebuilt default export |
| Same probe with the preview URL ending in `#/discover?skill=` followed by 48 lowercase `s` characters, `--out test/scratch/taste-long-skill` | Exit 0; 16/16 passed, including layout at 320, 390, 1440 |

The probe used explicit `IMD_PLAYWRIGHT` and `PLAYWRIGHT_BROWSERS_PATH` paths to the temporary installation. The default and long-skill probes reported no script errors, missing local resources, horizontal scrolling, text overlap, or clipped text. Live empty results were observed separately from fixture rankings. No transaction was signed or broadcast.

## Better Interface coverage

The pinned workflow, all six domains’ core principles, and documentation guidance were read. Review was scoped to the changed results, score guide, and management page, with the existing interaction suite providing regression coverage.

| Domain | Coverage and limits |
| --- | --- |
| Accessibility | Checked native heading/button semantics and preserved labels; Refresh remains reachable; management wallet dialog and Escape/focus return exercised. Existing Chromium keyboard and axe checks passed. No screen-reader session. |
| Layout | Checked live empty and fixture populated results, mobile card boundaries, and management reflow at 320/390/1440. Inspected mobile and desktop screenshots. Product and Search remain on the first 390px screen. Native zoom, RTL, and physical devices were not retested. |
| Writing | Replaced the reproduced management slogans with task headings. Verified ownership, agent-ID, endorsement, and fee explanations remain. |
| Typography | Checked complete long names wrap without ellipsis; corrected score-guide word spacing on both affected pages. Existing five-size scale and three weights retained; probes passed typography checks. |
| Colors | Existing tokens retained. Both probes passed measured rendered text contrast thresholds (4.5:1 normal, 3:1 large); this is not a claim about every possible state or third-party wallet UI. |
| UI | Reviewed empty and populated states, Refresh, management connection, and reduced-motion probe results. Existing surfaces and transitions retained. No slow-motion animation-panel review. |

## Evidence and delivery

- `checks/revision-chromium.json`: 30 passing interaction results.
- `checks/revision-taste.json`: actual default and long-skill probe checks.
- `screenshots/revision-long-skill-390.png`: final live empty results with the complete skill wrapped and Refresh visible.
- `screenshots/revision-manage-390.png`: final task headings and connection panel.
- `export-sha256.json`: refreshed hashes of every final export file.

The final 390px entry screenshot and the 1440px long-skill screenshot from the probe were also viewed; temporary screenshots remain in `test/scratch/` and are not submitted. `DESIGN.md` now records wrapping and management-heading behavior.

Final integrity checks passed: every local HTML asset URL is relative and resolves, required metadata is present, and the delivered source/tests/export match the tested temporary build byte for byte. Protected files and ignore files are unchanged. No dependency directories, caches, packaging archives, source maps, or submodules are included. Eligible submission contents are approximately 3.5 MiB, with a conservative uncompressed tar estimate below 3.7 MiB, within the 8 MiB limit; this is a packaging estimate rather than a generated Git bundle. `git diff --check` passed.

The original report’s mainnet signing, passkey, native-app, physical-device, screen-reader, and native-zoom limitations remain. This revision did not repeat the full Solidity tests or the legacy frontend tests because their implementation is unchanged. WebKit remains the explicit additional validation limitation for this revision.
