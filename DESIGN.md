# AgentSkill Dashboard design system

## Overview

AgentSkill Dashboard helps people find agents by skill, compare evidence, and manage their own agent’s expertise. Its visual idea is a quiet workspace: warm neutral surfaces, forest-green actions, clear type, and generous spacing. The primary search is immediately available, including at 390px wide. There is no marketing hero or invented activity.

The current implementation lives in `web/dashboard/`. The earlier frontend in `web/` is retained for compatibility but does not define this design system. `src/styles.css` is the source of truth for the values below; `src/App.tsx` contains the page patterns.

## Colors

The application uses one light theme with sRGB hex colors. There is no automatic dark theme.

| CSS token | Value | Role |
| --- | --- | --- |
| `--canvas` | `#f7f8f5` | Workspace background |
| `--surface` | `#ffffff` | Navigation, inputs, result surfaces, dialogs |
| `--surface-subtle` | `#f0f3ec` | Hover, evidence details, quiet icons |
| `--text` | `#26362f` | Primary text |
| `--muted` | `#626c64` | Secondary text, descriptions, captions |
| `--border` | `#dfe4dc` | Structural separators and neutral controls |
| `--input-border` | `#a4afa1` | Input boundaries and hover outlines |
| `--accent` | `#244c3c` | Primary action fill and links |
| `--accent-hover` | `#193d2d` | Primary hover and pressed state |
| `--accent-soft` | `#e7eedf` | Selected desktop navigation and positive feedback |
| `--accent-text` | `#31553b` | Informational text and illustrations |
| `--focus` | `#416f53` | 2px keyboard focus outline |
| `--error` | `#9b3531` | Error text |
| `--error-bg` | `#fff0ed` | Error surfaces |
| `--info-bg` | `#eef2e8` | Informational notice surfaces |
| `--chart-reputation` | `#375940` | 60% score segment |
| `--chart-history` | `#8b9e77` | 25% score segment |
| `--chart-endorsement` | `#cfdbb9` | 15% score segment |

The score guide uses `#edf1e6`; the modal backdrop is `#14231c66`. Component illustrations use the same green/neutral family. The three chart segments are also labeled with names and percentages; color is never their only explanation. Wallet marks retain their vendor colors. Status dots are accompanied by text.

Rendered contrast checks and their limitations are recorded in `docs/dashboard-review/validation.md`. Use the semantic roles above instead of borrowing a border color for text.

## Typography

Inter Variable is self-hosted as one Latin WOFF2 file from `@fontsource-variable/inter` 5.2.8. `@font-face` declares the supported 100–900 range; the interface uses **400, 500, and 600**. The fallback stack is Inter, Apple system, BlinkMacSystemFont, Segoe UI, sans-serif. There is one family and five size tokens:

| Token | Default size | Use |
| --- | --- | --- |
| `--text-sm` | 14px / .875rem | Captions, labels, navigation, buttons, dense rows |
| `--text-base` | 16px / 1rem | Body text and all input text |
| `--text-lg` | 18px / 1.125rem | Section headings, scores, mobile brand |
| `--text-xl` | 22px / 1.375rem | Brand, profile identity, guide and dialog headings |
| `--text-title` | 32px / 2rem | Page heading |

Body line-height is 1.55. The page heading uses 1.2, weight 600, and −.035em tracking; section headings use 1.4 and −.015em. The score guide’s 22px heading uses 1.3 and −.025em. Headings balance their wrapping; prose uses pretty wrapping. Long-form text stays within 70ch, and compact empty-state descriptions stay within 43ch (32ch on small screens).

Inputs remain at least 16px at the default root size. Scores, IDs, changing counts, and addresses use tabular numbers. Critical addresses and agent IDs wrap without clipping. The header’s short wallet address expands to the complete checksummed address in the wallet dialog. No content-wide uppercase transformation, tracked kicker labels, or monospace prose is used.

## Layout

`app-shell` is a two-column desktop workspace: a 228px sidebar and a flexible content area. Main content is at most 1280px wide including padding, with 44px inline padding and 40px top padding. The topbar is at least 88px high. Desktop navigation, header, content, and footer follow consistent edges.

The discover page pairs a flexible search/results column with a 272px guide column, separated by 28px. The profile and explanation pages use a 288px secondary column with a 32px gap. Spacing generally follows 4px multiples, with 8–12px inside controls, 16–24px inside surfaces, and 28–32px between related sections.

| Breakpoint | Implemented behavior |
| --- | --- |
| At most 78rem / 1248px | Sidebar becomes 204px; main/header inline padding becomes 28px; guide columns become 248px |
| At most 66rem / 1056px | Main two-column layouts become one column; discover’s two supporting sections share a row |
| At most 48rem / 768px | Sidebar is replaced by the mobile brand/header and a three-item navigation row; main padding is 24px |
| At most 35rem / 560px | Main inline padding becomes 20px; forms stack; skill tiles become horizontal list rows; supporting sections stack; dialogs become bottom sheets |
| At most 22rem / 352px | Main/header padding becomes 16px; navigation and wallet icons simplify to preserve label space |

The header and mobile navigation wrap when text grows. Text containers use minimum heights rather than fixed heights. Important content remains in normal flow. Profile owner addresses and long numeric IDs wrap. Search retains its explicit label and adjacent submit button. Small-screen ranking rows preserve agent identity, endorsement count, and score while removing the redundant column heading.

The final export was checked at 320, 390, 768, 1024, and 1440px; doubled root text was separately checked at 390 and 1280px. The latter is text enlargement, not a native browser zoom claim. The 390px screenshots show the product, main search, connect control, and results heading on the first screen.

## Elevation & depth

The page is mostly flat. Borders define inputs, results, and skill tiles; subtle background changes group supporting information. Surfaces do not combine a shadow with a border. The modal alone uses elevation: `0 24px 80px #14231c2b`, with no border, over a translucent backdrop. Native dialog top-layer behavior keeps the background inert.

The selected mobile navigation item has an inset 2px bottom indicator. Desktop selection uses a soft green surface and a small dot. Neither selection depends on color alone: links also expose `aria-current`.

## Shapes

The shared radius is 12px; large result/guide surfaces use 18px. Buttons and inputs use 9px, wallet rows 10px, and desktop navigation 9px. Dialogs use 20px corners; the phone sheet has rounded top corners and square bottom corners, with safe-area padding. Avatars use rounded squares, while status dots and score markers are circular. The app’s local SVG mark and empty-state illustration repeat this restrained rounded geometry.

## Components

| Component / pattern | Source | Behavior |
| --- | --- | --- |
| `Modal` | `src/components.tsx` | Native modal dialog; unique accessible title, explicit Tab loop, Escape/backdrop/close dismissal, focus return, scroll containment; bottom sheet on phones |
| `Notice` | `src/components.tsx` | Informational and error variants with icon plus text; errors announce via alert |
| `Loading` | `src/components.tsx` | Text status and spinner; reduced motion stops rotation |
| `External` | `src/components.tsx` | Descriptive external link, arrow, new-tab announcement, `noopener noreferrer` |
| `Wallet` | `src/Wallet.tsx` | Named EIP-6963 rows, wallet marks, per-row pending state, inline rejection, mobile app links, Coinbase connector, full-address disclosure, switch/disconnect |
| Search | `Discover` in `src/App.tsx` | Labeled input, submit validation, suggested links, URL state, cancellation of obsolete ranking scans, live result announcement |
| Ranking | `Discover` | Ordered rows, global top results, snapshot block, unscored evidence, retry/loading/empty/unconfigured states |
| `AgentLookup` | `src/App.tsx` | Numeric ID entry preserving full uint256 precision; inline errors focus the input |
| `Profile`, `ScoreDetails` | `src/App.tsx` | Ownership, skills, share link, native evidence disclosures, exact score contributions and history meaning |
| `AddSkill`, `SkillAction` | `src/App.tsx` | Explicit action/fee descriptions; current ownership/network gates; transaction status also appears inside the modal |
| Transaction feedback | `src/transactions.ts`, `App` | Checking, wallet prompt, pending, success/revert/rejection and replacement/cancellation handling; persistent explorer link |
| `Icon`, `EmptyArt` | `src/icons.tsx` | Local, decorative SVGs; 1.7px current-color icon strokes; no icon font or remote image service |

`.button.primary` is the main action; `.button` is a secondary action; `.text-button` is a low-emphasis action. Rest, hover, pressed, disabled, and keyboard-focus states are explicit. Main targets are at least 44px high. Skill suggestions are 40px on phones and are separated from adjacent controls; inline evidence links use normal text-link spacing.

Transitions name only the changing properties and last 120ms. Pressed controls scale to .96 only when the visitor allows motion. There are no entrance animations, autoplay, parallax, or continuous decorative effects. Focus uses a 2px outline offset by 4px, with forced-color support.

## Do’s and don’ts

- Start a page with `.page-heading`, then reuse `.profile-layout`, `.discovery-grid`, or `.about-layout` as appropriate. Keep the main action above supporting explanations.
- Reuse the existing button, notice, loading, and dialog patterns. Keep labels visible when values are entered.
- Use the five size tokens and three weights. Preserve readable wrapping instead of hiding long values.
- Put actual block-stamped data first. Distinguish missing evidence, empty results, RPC errors, and unconfigured scoring.
- Keep suggested skills identifiable as suggestions; never add fabricated production profiles or live counters.
- Keep irreversible endorsement language and Ethereum fee context beside the action. Do not treat wallet connection as a transaction.
- Retain the calm light palette and flat surfaces. Avoid additional fonts, decorative gradients, stacked slogans, or nested bordered cards.

This document describes the implemented source after review. It adapts the documentation method from Paul Bakaus’s Impeccable; design guidance came from Jakub Krehel’s Better Interface. Their respective Apache-2.0 and MIT notices are retained in `web/dashboard/licenses/Design-guidance.txt`.
