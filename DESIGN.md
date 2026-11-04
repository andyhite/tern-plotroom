# Plotroom design system

Plotroom is drawn inside Tern, by Tern. The frame, the neutrals, the fonts, the keycaps, the picker, the side sheet and the overlays are Tern's kinds and Tern's variables; Plotroom adds meaning, not decoration. This page is the visual contract: read it before any UI change, and add a component here before you build it. Adapted from [tern-pr-guide's DESIGN.md](https://github.com/jubbydev/tern-pr-guide/blob/main/DESIGN.md).

Words on screen come from [PRODUCT.md › Glossary](PRODUCT.md#glossary). Behavior is in [docs/reference.md](docs/reference.md).

## Rules

**The Color Meaning Rule.** A coloured element means exactly one of five things. Anything else is neutral (`muted`, or no tone).

| Meaning | Tone (Tern) | Draws as | Where today |
| --- | --- | --- | --- |
| Your turn | `accent` | Tern's accent | **Needs you**, Needs input, Report: needs human, Not verified, Check failed, a stopped chain, **New** and **Changed**, Now's reasons that ask you (Review requested, Mention, Assigned, …), Now's `N need you` heading |
| Needs fixing | `error` | `--bad` | **Blocked** and its chips (Address changes, Reply, Fix checks, Re-run, Resolve conflicts), Conflicts, Changes requested, Checks failing, a failed check run, Report: stuck, a worktree that could not be made or is missing, a load or read that failed, a security alert |
| Done | `success` | `--ok` | **Ready to merge**, **Merged**, Approved, Verified, Checked, Passing, Done or Completed issues, a done Get started line |
| Agent working | `pending` | `--live` | **Agent working**, Working, the filled cells of a working agent's bar |
| Checks running | `warning` | `--warn` | a pending check run and Pending checks |

So: Open, Draft, Closed, PR open, Worktree, Not started, Idle, Exited, Clean, Uncommitted changes, Not at PR head, unpushed counts, In tab, Locked, New commits since you approved (the Changed badge already carries it), review required or requested of someone else, Jira workflow statuses other than Done, the integration tag (GitHub, Jira), numbers, a working agent's clock and the empty cells of its bar, diff sizes, stale or partial results and every button are neutral. A meaning colour on something that does not carry that meaning breaks the rule, a red Remove button or a blue Next button included. Toasts use Tern's levels and are outside the rule; Tern's own focus ring, list selection and author avatars keep Tern's colours, which are Tern chrome, not a Plotroom meaning.

The Color Meaning Rule is enforced by tests: `hx.offPalette` (plugin/tests/harness.luau) fails on any other tone, a coloured span style (`num`, `ins`, `del`, `info`, `link`), or a button with a meaning colour; `scripts/check.py` fails `plotroom.css` on a hex or literal `rgb()`/`hsl()` colour, or on Tern's meaning variables (`--bad`, `--ok`, `--warn`, `--live`, …), which only a node's tone may use.

**Every visible string changes a decision.** A word on screen is there because it changes what you do next. A count the sidebar already shows, a label that repeats the badge beside it, a state nothing acts on: cut it. Reference text goes in a tooltip (`title`), not on the row.

**Controls appear only where they act.** A button or link is shown only when pressing it would do something now, on the thing it sits on. No disabled buttons; an action that does not apply is not offered (Commands filters to what applies). Every action is also a key or a Commands row.

**Borrowed neutrals.** No hex grey, no invented surface. Text, lines and surfaces are Tern variables; meaning colours come from a node's `tone`, never from CSS.

## Tokens

All Tern variables; the plugin declares none.

- **Ink:** `--t1` (titles, body), `--t2` (keycap labels), `--t3` (muted text: `muted` tone), `--t4` (dim).
- **Lines:** `--l1` to `--l4`; `--l3` rings Plotroom's buttons and underlines links.
- **Surfaces:** Tern's picker, card, prefs sheet and overlay draw their own (`--card`, `--panel`, `--chip-bg`); Plotroom paints none.
- **Accent:** `--accent` only through the `accent` tone (your turn) and Tern's own focus ring.
- **Meaning colours:** through tones only: `accent`, `error` (`--bad`), `success` (`--ok`), `pending` (`--live`), `warning` (`--warn`).

## Typography

- **Prose:** `var(--sans)`, Tern's default for every kind; no font stack is declared.
- **Identifiers** (author, branch, path, repository, `#N`, Jira keys, counts): `mono` or `code` spans, 12px `var(--mono)` wherever they show, so a row's detail matches the preview's kv values.
- **Weight:** `strong` spans for a heading's view name and a linked item's title; nothing else is bold.
- Text is never coloured for emphasis; only a meaning colours it.

## Spacing and radii

- Lengths are `px`, `em`, `vw`, `vh` or `%` only (Tern rejects `ch` and `rem`); no logical properties, no `:has()`.
- Steps in use: 2px (an icon button's padding), 6px (gap inside a button), 8px (button padding, the gap between Add buttons), 10px (above an Add row), 12px (a row's gap to its control). Node `gap` props use Tern's `xs`.
- Radii: `--r-ctl` for buttons; everything else takes the radius its Tern kind draws (`--r-chip` badges, `--r-card` cards).

## Components

Each is built from Tern kinds; `plotroom.css` touches only what no kind or prop covers.

### Rows

A picker `item` per pull request, issue, Now entry, agent or worktree. Left: the author's mark (Now: the reason). Title, then a detail line of identifiers (`#N` or key in `mono`, the repository only when the view spans several, for a Blocked PR its first chip's who or what, in plain text). Right: badges, stage first. A row shows only what decides at the list level; the rest is the preview's.

### Badges

Tern's `badge` (picker rows: the item's `badges`). One word or a short phrase, title case, the reason in its tooltip. The stage badge leads, a Blocked PR's chips next; agent state, checked outcome, checker verdict, New / Changed / Snoozed, Worktree and Draft follow. Tone by the Color Meaning Rule; a badge that is no meaning is `muted`.

### Status chips

A Blocked pull request's reasons, one Tern `badge` each, right after the Blocked badge, most severe first: **Address changes**, **Reply · N unresolved**, **Fix checks · N/T failing** (or **Re-run · likely flaky**), **Resolve conflicts**. Each names the job that clears it, not the state; tone `error` (needs fixing); the tooltip says who or what. The Blocked badge says no reason, and the row's detail line says the first chip's who or what in plain text, so no fact shows twice. The preview's status `kv` lists each as **Blocked by** (the chip in `error`, then its detail). A Board card has room for one: the first chip. No keys, no click: a chip names a job, the Next move does it.

### Preview card

The picker's preview, in one order for every item (docs/reference.md › Finer points › Preview): the Next button and links row; the head (`#N` or key, the integration tag, Copy link and Open icons, the state badge at the right); the title; the status `kv` (Stage first, then what needs you); the properties `kv`; then sections (checks, reviewers, unresolved threads, linked items, description, the worktree card). The description is a folded `card` with Tern's clamp and "N more lines".

### Buttons and links

What a click does shows on the node. A **button** does something: an `item` with `role = "plotroom.button"`, a 1px `--l3` ring, `--r-ctl` radius, sized to its label, its key as `hint` keycaps (render's `button()`). An icon button is an `icon` with the same role. A **link** opens something: `role = "plotroom.link"`, its label underlined in `--l3`, the underline darkening under the pointer. Every node with a click action or an `href` wears one of the two roles and no other node does (`hx.miscued`). Buttons are neutral: no tone, destructive ones included; their confirm is the guard.

### Worktree card

A `card` in the preview while the item has a worktree: neutral badges (Up to date or Not at PR head; Clean, Uncommitted changes or Changes unchecked; N unpushed), the branch and path with copy icons, the update commands folded away when behind, then buttons (Open in new tab or Go to tab, Remove worktree, Open Git view). The card takes the `error` tone only when the worktree could not be made, and then shows why and no buttons. It is a cache of git, never the source.

### Commands

`.` opens Tern's picker as an overlay: grouped rows filtered to what applies now, **Next** first, each with its key as keycaps. Every queue action has a Commands row; there is no action bar or strip.

### Settings

Tern's `prefs` side sheet in the block's layer, four pages (Views, Actions, Repositories, General) with icon tabs. Each list item opens a form; its Delete or Remove sits beside Done and is neutral like every other button. A prompt is edited in an `editor` card over the sheet (`role = "omp.prefs.editor"`).

## Adding a component

1. Add it here: which Tern kinds, which tones (by the Color Meaning Rule), which keys.
2. Add its LEDGER.md row.
3. Build it, with a regression case that runs `hx.miscued` and `hx.offPalette` over it.
