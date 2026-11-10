# Plotroom design system

Plotroom is drawn inside Tern, by Tern. The frame, the neutrals, the fonts, the keycaps, the picker, the side sheet and the overlays are Tern's kinds and Tern's variables; Plotroom adds meaning, not decoration. This page is the visual contract: read it before any UI change, and add a component here before you build it. Adapted from [tern-pr-guide's DESIGN.md](https://github.com/jubbydev/tern-pr-guide/blob/main/DESIGN.md).

Words on screen come from [PRODUCT.md › Glossary](PRODUCT.md#glossary). Behavior is in [docs/reference.md](docs/reference.md).

## Rules

**The Color Meaning Rule.** A coloured element means exactly one of five things. Anything else is neutral (`muted`, or no tone).

| Meaning | Tone (Tern) | Draws as | Where today |
| --- | --- | --- | --- |
| Your turn | `accent` | Tern's accent | **Needs you**, Needs input, Report: needs human, Not verified, Check failed, a stopped chain, **New** and **Changed**, Now's reasons that ask you (Review requested, Mention, Assigned, …), Now's `N need you` heading, a worktree tab's tint while its agent needs input (tab colours are named labels, not tones: `blue`) |
| Needs fixing | `error` | `--bad` | **Blocked** and its chips (Address changes, Reply, Fix checks, Re-run, Resolve conflicts), Conflicts, Changes requested, Checks failing, a failed check run, Report: stuck, a worktree that could not be made or is missing, a load or read that failed, a security alert |
| Done | `success` | `--ok` | **Ready to merge**, **Merged**, Approved, Verified, Checked, Passing, Done or Completed issues, a done Get started line |
| Agent working | `pending` | `--live` | **Agent working**, Working, the filled cells of a working agent's bar |
| Checks running | `warning` | `--warn` | a pending check run and Pending checks |

So: Open, Draft, Closed, PR open, Worktree, Not started, Idle, Exited, Clean, Uncommitted changes, Not at PR head, unpushed counts, In tab, Locked, New commits since you approved (the Changed badge already carries it), review required or requested of someone else, Jira workflow statuses other than Done, the integration tag (GitHub, Jira), numbers, a working agent's clock and the empty cells of its bar, diff sizes, stale or partial results and every button but a confirm's one primary (Buttons and links) are neutral. A meaning colour on something that does not carry that meaning breaks the rule, a red Remove button or a blue Next button included. Toasts use Tern's levels and are outside the rule; Tern's own focus ring, list selection and author avatars keep Tern's colours, which are Tern chrome, not a Plotroom meaning.

The Color Meaning Rule is enforced by tests: `hx.offPalette` (plugin/tests/harness.luau) fails on any other tone, a coloured span style (`num`, `ins`, `del`, `info`, `link`), a button with a meaning colour, a `primary` variant outside a confirm overlay or a second one inside it, or any `danger` variant (Buttons and links below); `scripts/check.py` fails `plotroom.css` on a hex or literal `rgb()`/`hsl()` colour, or on Tern's meaning variables (`--bad`, `--ok`, `--warn`, `--live`, …), which only a node's tone may use.

**Every visible string changes a decision.** A word on screen is there because it changes what you do next. A count the sidebar already shows, a label that repeats the badge beside it, a state nothing acts on: cut it. Reference text goes in a tooltip (`title`), not on the row.

**Controls appear only where they act.** A button or link is shown only when pressing it would do something now, on the thing it sits on. No disabled buttons; an action that does not apply is not offered (Commands filters to what applies). Every action is also a key or a Commands row.

**Borrowed neutrals.** No hex grey, no invented surface. Text, lines and surfaces are Tern variables; meaning colours come from a node's `tone`, never from CSS.

## Tokens

All Tern variables; the plugin declares none.

- **Ink:** `--t1` (titles, body), `--t2` (keycap labels), `--t3` (muted text: `muted` tone), `--t4` (dim).
- **Lines:** `--l1` to `--l4`; `--l3` rings Plotroom's buttons and underlines links.
- **Surfaces:** Tern's picker, card, prefs sheet and overlay draw their own (`--card`, `--panel`, `--chip-bg`); Plotroom paints none.
- **Accent:** `--accent` only through the `accent` tone (your turn), the one `primary` button a confirm overlay may hold (Buttons and links), and Tern's own focus ring.
- **Meaning colours:** through tones only: `accent`, `error` (`--bad`), `success` (`--ok`), `pending` (`--live`), `warning` (`--warn`).

## Typography

- **Prose:** Tern's sans face, set by `font = "sans"` on both blocks (Tern's Designing Views › Typography); no font stack is declared and no plugin CSS sets a block's face.
- **Identifiers** (author, branch, path, repository, `#N`, Jira keys, SHAs, counts, times): `mono` or `code` spans, 12px `var(--mono)` wherever they show, so a row's detail matches the preview's kv values. A number in a kv value or running text is `mono`, never `num` (it paints the code-number colour).
- **Weight:** the `title` token for the queue's view name (the page's name), `strong` for a linked item's title; nothing else is bold.
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

### Arrival ring

A queue row whose item a refresh just moved into Needs you, Blocked or Ready to merge takes that stage's tone as the picker row's `tone` (`accent`, `error`, `success`) for 1.4 s. `plotroom.css` rings it with a 2px inset `var(--tc)` box shadow, held, then faded, and only on the queue picker's rows; while Tern hides the pane (`.sf-paused`) the fade pauses where it was; under reduced motion (`prefers-reduced-motion`, Tern's `.sf-still`) the row is tinted instead. The colour is the stage's, so it means what the stage badge means. At most one toast per refresh goes with it, Tern's `error` level. A new animation in `plotroom.css` gets the same `.sf-still` and `.sf-paused` rules; `scripts/check.py test` fails without them.

### Preview card

The picker's preview, in one order for every item (docs/reference.md › Finer points › Preview): the Next button and links row; the head (`#N` or key, the integration tag, Copy link and Open icons, the state badge at the right); the title; the status `kv` (Stage first, then what needs you); the properties `kv`; then sections (checks, reviewers, unresolved threads, linked items, description, the worktree card). The description is a folded `card` with Tern's clamp and "N more lines".

### Buttons and links

What a click does shows on the node. A **button** does something: an `item` with `role = "plotroom.button"`, a 1px `--l3` ring, `--r-ctl` radius, sized to its label, its key as `hint` keycaps (render's `button()`). An icon button is an `icon` with the same role. A **link** opens something: `role = "plotroom.link"`, its label underlined in `--l3`, the underline darkening under the pointer. Every node with a click action or an `href` wears one of the two roles and no other node does (`hx.miscued`). Buttons are neutral: no tone, destructive ones included; their confirm is the guard.

**One primary button, only in a confirm.** Tern's guide makes one accent `primary` button per screen, the action on the selection. Plotroom departs from it: accent already means your turn, and an accent Next move on every preview would wear that cue down until Needs you no longer stands out. So the only `primary` button is the one choice a confirm overlay (`overlay` keyed `confirm`) offers on Enter, today the worktree removal's **Keep**, where nothing else on screen competes for it; a confirm has at most one. The preview's Next move, the worktree card, Settings, the Draft review's **Send to agent** (a decision row, not an overlay) and every other button stay `default` or `quiet`. `danger` is never used: a red Remove would say "needs fixing", and the confirm is the guard. The confirms the window asks through Tern's picker (Send to an agent, guided mutations) are Tern's own confirm rows, not Plotroom buttons. Until Plotroom builds against an SDK with `tern.ui.button` and its variants, no button sets one.

### Worktree card

A `card` in the preview while the item has a worktree: neutral badges (Up to date or Not at PR head; Clean, Uncommitted changes or Changes unchecked; N unpushed), the branch and path with copy icons, the update commands folded away when behind, then buttons (Open in new tab or Go to tab, Remove worktree, Open Git view). The card takes the `error` tone only when the worktree could not be made, and then shows why and no buttons. It is a cache of git, never the source.

### Loading, empty and error

Tern's four states, in the place of what they stand for and under its key, so the loaded part replaces them without a jump. **Loading:** a `skeleton` (default `shimmer` variant, no tone) shaped like the part: `rows` for a list (Checks 3, Reviewers, Unresolved threads and linked items 2), `text` lines for the Summary, the description and a worktree's linked items, and a `block` 8 lines tall where the Draft review's diff goes. **Empty:** an `empty` with `variant = "inline"`, no tone, its `title` saying what is missing ("No checks", a Board column's "None"). **Error:** the same inline `empty` with `tone = "error"` (needs fixing), `title` `Could not load <what>`, `text` the tool's message and when it is tried again, and one child: a Retry button (render's `button()`, `icon = "redo"`; its row height is Tern's `sm`). The queue picker's own `state = "loading" | "error"` stays.

### Commands

`.` opens Tern's picker as an overlay: grouped rows filtered to what applies now, **Next** first, each with its key as keycaps. Every queue action has a Commands row; there is no action bar or strip.

### Settings

Tern's `prefs` side sheet in the block's layer, four pages (Views, Actions, Repositories, General) with icon tabs. Each list item opens a form; its Delete or Remove sits beside Done and is neutral like every other button. A prompt is edited in an `editor` card over the sheet (`role = "omp.prefs.editor"`).

### Draft review

The review block is a focused workspace, not a feed of repeated diff cards. A compact header identifies the pull request and reviewed commit. A wrapping decision row holds the three neutral verdict choices (the selected one has a check), the kept/dropped count and **Send to agent**; sending and sent states replace the action, and a failed handoff offers **Copy** alongside its explanation.

A native `list` navigator selects Summary, each finding in file order, then Instructions. Its native selection stays in view; each finding names its filename, line and Kept/Dropped state without using colour as the only cue, with its kind, full path and feedback excerpt in the tooltip. The selected content occupies the remaining width: readable Markdown feedback, its native diff excerpt and local Keep/Drop and Edit controls. Off-diff findings explain why they cannot be kept. Summary and Instructions have explicit Edit controls, with Done while editing.

Use `row`/`col`, `list`/`item`, `md`, `editor`, `diff` and native keycaps. At compact pane widths the navigator becomes a short list above the detail, not a hidden pane. `j`/`k` or arrows move, Space keeps/drops, `e`/Enter edits, `1`/`2`/`3` choose the verdict and ⌘↵ sends. Buttons use the same neutral ring in both Plotroom block surfaces; selection uses the list's native highlight, not a semantic tone. No decorative colour, new font, animation or custom diff renderer.

## Adding a component

1. Add it here: which Tern kinds, which tones (by the Color Meaning Rule), which keys.
2. Add its LEDGER.md row.
3. Build it, with a regression case that runs `hx.miscued` and `hx.offPalette` over it.
