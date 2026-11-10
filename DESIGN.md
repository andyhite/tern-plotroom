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

So: Open, Draft, Closed, PR open, Worktree, Not started, Idle, Exited, Clean, Uncommitted changes, Not at PR head, unpushed counts, In tab, Locked, New commits since you approved (the Changed badge already carries it), review required or requested of someone else, Jira workflow statuses other than Done, the integration tag (GitHub, Jira), numbers, a working agent's clock and the empty cells of its bar, diff sizes, stale or partial results and every button but a confirm's one action (Confirm overlay) are neutral. A meaning colour on something that does not carry that meaning breaks the rule, a red Remove button on a card or a blue Next button included. Toasts use Tern's levels and are outside the rule; Tern's own focus ring, list selection and author avatars keep Tern's colours, which are Tern chrome, not a Plotroom meaning.

The Color Meaning Rule is enforced by tests: `hx.offPalette` (plugin/tests/harness.luau) fails on any other tone, a coloured span style (`num`, `ins`, `del`, `info`, `link`), a button with a meaning colour, any `primary` variant, or a `danger` variant outside a confirm overlay or a second one inside it (Buttons and links below); `scripts/check.py` fails `plotroom.css` on a hex or literal `rgb()`/`hsl()` colour, or on Tern's meaning variables (`--bad`, `--ok`, `--warn`, `--live`, …), which only a node's tone may use.

**Every visible string changes a decision.** A word on screen is there because it changes what you do next. A count the sidebar already shows, a label that repeats the badge beside it, a state nothing acts on: cut it. Reference text goes in a tooltip (`title`), not on the row.

**Controls appear only where they act.** A button or link is shown only when pressing it would do something now, on the thing it sits on. No disabled buttons; an action that does not apply is not offered (Commands filters to what applies). Every action is also a key or a Commands row.

**Borrowed neutrals.** No hex grey, no invented surface. Text, lines and surfaces are Tern variables; meaning colours come from a node's `tone`, never from CSS.

## Tokens

All Tern variables; the plugin declares none.

- **Ink:** `--t1` (titles, body), `--t2` (keycap labels), `--t3` (muted text: `muted` tone), `--t4` (dim).
- **Lines:** `--l1` to `--l4`; `--l3` underlines links (Tern's `button` kind draws its own ring).
- **Surfaces:** Tern's picker, card, prefs sheet and overlay draw their own (`--card`, `--panel`, `--chip-bg`); Plotroom paints none.
- **Accent:** `--accent` only through the `accent` tone (your turn) and Tern's own focus ring.
- **Meaning colours:** through tones only: `accent`, `error` (`--bad`), `success` (`--ok`), `pending` (`--live`), `warning` (`--warn`).

## Typography

- **Prose:** Tern's sans face, set by `font = "sans"` on both blocks (Tern's Designing Views › Typography); no font stack is declared and no plugin CSS sets a block's face.
- **Identifiers** (author, branch, path, repository, `#N`, Jira keys, SHAs, counts, times): `mono` or `code` spans, 12px `var(--mono)` wherever they show, so a row's detail matches the preview's kv values. A number in a kv value or running text is `mono`, never `num` (it paints the code-number colour).
- **Weight:** the `title` token for the queue's view name (the page's name), `strong` for a linked item's title; nothing else is bold.
- Text is never coloured for emphasis; only a meaning colours it.

## Spacing and radii

- Lengths are `px`, `em`, `vw`, `vh` or `%` only (Tern rejects `ch` and `rem`); no logical properties, no `:has()`.
- Steps in use: 8px (the gap between Add buttons), 10px (above an Add row), 12px (a row's gap to its control). Node `gap` props use Tern's `xs` and `sm`.
- Radii: `--r-ctl` for the arrival ring on a row; everything else takes the radius its Tern kind draws (`--r-chip` badges, `--r-card` cards, a `button`'s own).

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

What a click does shows on the node. A **button** does something: Tern's `button` kind (`tern.ui.button`, render's `button()`), sized to its label, its key as `keys` keycaps (key names: `cmd`, `enter`, `esc`, `space`, a letter; an upper-case key is `shift` and its letter, since a keycap upper-cases every letter). Size `sm` in rows, the preview and cards (the worktree card, Get started, Retry, the lenses after `gh pr create` and `git push`); `md` in bars, overlays and the Draft review's head row (the Board's fold bar, the shortcut list's Close, the confirm, verdicts and Send). An icon button is the same kind with an empty label, `quiet`, named by its `title` (the head's and the branch's Copy). A button whose work is under way is `busy` (a spinner in its icon's place; it sends nothing more), as the Draft review's Send while the window carries it. A key footer seg (a `seg` in the dock's `status` strip, requests' `keyBar`) is neither: Tern's own seg, with its own hover fill and no Plotroom cue; the strip is Tern's status bar look, a keycap then what the key does. A **link** opens something: `role = "plotroom.link"`, its label underlined in `--l3`, the underline darkening under the pointer. Every node with a click action or an `href` is a button, a key footer seg or wears the link role, and no other node does (`hx.miscued`). Buttons are neutral: no tone, destructive ones included; their confirm is the guard.

**No primary button; danger only in a confirm.** Tern's guide makes one accent `primary` button per screen, the action on the selection. Plotroom departs from it: accent already means your turn, and an accent Next move on every preview would wear that cue down until Needs you no longer stands out. So no button is `primary`. The only `danger` button is a destroying confirm overlay's action (Confirm overlay), where Tern's guide puts it: the confirm is about to destroy something, nothing else on screen competes, and a confirm has at most one. A plan's confirm (a write to GitHub or Jira) destroys nothing Plotroom holds, so its action is `default`. The preview's Next move, the worktree card's Remove worktree, Settings' Delete and Remove rows, the Draft review's **Send to agent** (a decision row, not an overlay) and every other button stay `default` or `quiet` (`quiet`: icon buttons, Show less, Get started's Dismiss, a confirm's Cancel): the button that only opens a confirm acts on nothing yet. The one confirm the window asks through Tern's picker, Message an agent with the selection… (about no Plotroom block), is Tern's own confirm rows, not Plotroom buttons.

### Confirm overlay

Every confirm Plotroom asks: the worktree card's Remove worktree, the Worktrees list's Remove worktree and Remove finished worktrees, Settings' Delete view, Delete action, Remove repository, Remove project and Reset all settings, Stop agent…, and every plan of a write to GitHub or Jira. One Tern `overlay` keyed `confirm` in the block's layer (over the picker, or over the Settings sheet for Settings' own), `modal`, `size = "sm"`, its icon (`trash` for a removal or a delete, `x` for Stop agent, `merge` for a plan), the question as `head`, muted `meta` for a count that qualifies it (how many were not checked). Its body: the consequence in one muted sentence, then a `kv` of facts (a worktree's Path and Branch, the Branch line saying what becomes of it) or a plan's lines as they will be sent, and a plain warning line while a tab works in a folder about to go. Its `foot` is a row, right-aligned: **Cancel** first (`quiet`, `md`, keycap `esc`), then the action named as what it does (`md`, the overlay's icon, its key's keycap; `danger` for a removal, a delete or Stop agent, `default` for a plan). A refused removal says why in the sentence and offers Cancel alone. Settings' confirms, Stop agent and a plan take Enter for the action; the worktree removals keep `d` for it, and Enter keeps the worktree too. While a confirm asks, no other key reaches what is under it.

### Checks table

The preview's checks, one Tern `table` per group (Failing, Running, Queued; Passed and Skipped in their fold), each under its muted `Group N` heading. Columns: **Check** (the one `grow` column, a status `dot` in the run's tone: `error` failed, `warning` running or queued, `success` passed, `muted` skipped; Required, Likely flaky and Ignored as muted text after the name), **Workflow** and **Took** (`align = "end"`, `mono`). Rows are `selectable`: a click opens the check's page. Each row's right-click menu offers Open (when the check has a page) and, on a failing check not yet ignored, Ignore in this repo…; Tern adds Copy row. A failing check's excerpt is a `code` node (`lang = "text"`) in a plain section headed by its first error line, that line marked `error`, clamped by `preview` with Tern's "K more lines". Never put it in a collapsible section: Tern applies a code `preview` only while that disclosure is folded, and folded draws no body.

### Worktree card

A `card` in the preview while the item has a worktree: neutral badges (Up to date or Not at PR head; Clean, Uncommitted changes or Changes unchecked; N unpushed), the branch and path with copy icons, the update commands folded away when behind, then buttons (Open in new tab or Go to tab, Remove worktree, Open Git view). The card takes the `error` tone only when the worktree could not be made, and then shows why and no buttons. It is a cache of git, never the source.

### Loading, empty and error

Tern's four states, in the place of what they stand for and under its key, so the loaded part replaces them without a jump. **Loading:** a `skeleton` (default `shimmer` variant, no tone) shaped like the part: `rows` for a list (Checks 3, Reviewers, Unresolved threads and linked items 2), `text` lines for the Summary, the description and a worktree's linked items, and a `block` 8 lines tall where the Draft review's diff goes. **Empty:** an `empty` with `variant = "inline"`, no tone, its `title` saying what is missing ("No checks", a Board column's "None"). **Error:** the same inline `empty` with `tone = "error"` (needs fixing), `title` `Could not load <what>`, `text` the tool's message and when it is tried again, and one child: a Retry button (render's `button()`, `icon = "redo"`, size `sm`). The queue picker's own `state = "loading" | "error"` stays.

### Commands

`.` opens Tern's picker as an overlay: grouped rows filtered to what applies now, **Next** first, each with its key as keycaps. Every queue action has a Commands row; there is no action bar or strip.

### Settings

Tern's `prefs` side sheet in the block's layer, four pages (Views, Actions, Repositories, General) with icon tabs. Each list item opens a form; its Delete or Remove sits beside Done and is neutral like every other button, and asks in a Confirm overlay over the sheet. A prompt is edited in an `editor` card over the sheet (`role = "omp.prefs.editor"`).

### Draft review

The review block is a focused workspace, not a feed of repeated diff cards. A compact header identifies the pull request and reviewed commit. A wrapping decision row holds the three neutral verdict choices (the selected one has a check), the kept/dropped count and **Send to agent**, all `md` buttons; while sending, Send is `busy` and reads Sending…; once sent a muted Sent badge replaces it, and a failed handoff offers **Copy** alongside its explanation.

A native `list` navigator selects Summary, each finding in file order, then Instructions. Its native selection stays in view; each finding names its filename, line and Kept/Dropped state without using colour as the only cue, with its kind, full path and feedback excerpt in the tooltip. The selected content occupies the remaining width: readable Markdown feedback, its native diff excerpt and local Keep/Drop and Edit controls. Off-diff findings explain why they cannot be kept. Summary and Instructions have explicit Edit controls, with Done while editing.

Use `row`/`col`, `list`/`item`, `button`, `md`, `editor`, `diff` and native keycaps. At compact pane widths the navigator becomes a short list above the detail, not a hidden pane. `j`/`k` or arrows move, Space keeps/drops, `e`/Enter edits, `1`/`2`/`3` choose the verdict and ⌘↵ sends. Buttons are Tern's `button` kind in both Plotroom block surfaces; selection uses the list's native highlight, not a semantic tone. No decorative colour, new font, animation or custom diff renderer.

## Adding a component

1. Add it here: which Tern kinds, which tones (by the Color Meaning Rule), which keys.
2. Add its LEDGER.md row.
3. Build it, with a regression case that runs `hx.miscued` and `hx.offPalette` over it.
