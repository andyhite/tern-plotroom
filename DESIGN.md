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
| Agent working | `pending` | `--live` | **Agent working**, Working, the fill of a working agent's bar in a preview |
| Checks running | `warning` | `--warn` | a pending check run and Pending checks |

So: Open, Draft, Closed, PR open, Worktree, Not started, Idle, Exited, Clean, Uncommitted changes, Not at PR head, unpushed counts, In tab, Locked, New commits since you approved (the Changed badge already carries it), review required or requested of someone else, Jira workflow statuses other than Done, the integration tag (GitHub, Jira), numbers, a working agent's clock and the empty track of its bar, diff sizes, stale or partial results and every button but a confirm's one action (Confirm overlay) are neutral. A meaning colour on something that does not carry that meaning breaks the rule, a red Remove button on a card or a blue Next button included. Toasts use Tern's levels and are outside the rule; Tern's own focus ring, list selection, author avatars and the fill of a picker's bar column (a working agent's bar on its Agents or Now row, which takes no tone) keep Tern's colours, which are Tern chrome, not a Plotroom meaning.

The Color Meaning Rule is enforced by tests: `hx.offPalette` (plugin/tests/harness.luau) fails on any other tone, a coloured span style (`num`, `ins`, `del`, `info`, `link`), a button with a meaning colour, any `primary` variant, or a `danger` variant outside a confirm overlay or a second one inside it (Buttons and links below); `scripts/check.py` fails `plotroom.css` on a hex or literal `rgb()`/`hsl()` colour, or on Tern's meaning variables (`--bad`, `--ok`, `--warn`, `--live`, …), which only a node's tone may use.

**Every visible string changes a decision.** A word on screen is there because it changes what you do next. A count the sidebar already shows, a label that repeats the badge beside it, a state nothing acts on: cut it. Reference text goes in a tooltip (`title`), not on the row.

**Controls appear only where they act.** A button or link is shown only when pressing it would do something now, on the thing it sits on. No disabled buttons; an action that does not apply is not offered (Commands filters to what applies). Every action is also a key or a Commands row.

**Borrowed neutrals.** No hex grey, no invented surface. Text, lines and surfaces are Tern variables; meaning colours come from a node's `tone`, never from CSS.

## Tokens

Tern variables the plugin uses, and nothing else. `plotroom.css` declares none and names only these; every other ink, line, surface and radius is drawn by the Tern kind that owns it, so it is not listed.

- **`--l3`:** the hairline under a link's label (Tern's `button` kind draws its own ring).
- **`--mono`:** the monospace face of identifiers, 12px (Typography).
- **`--accent`:** the focus ring (1.5px, plus a 3px halo) on the Delete, Remove and Add buttons of a focused Settings row, drawn as Tern's own ring is. It never colours anything else: your turn's colour comes through the `accent` tone.
- **`--tc`:** the colour Tern sets on a picker row that carries a `tone`; the arrival ring and its reduced-motion tint read it.
- **`--r-ctl`:** the arrival ring's radius.
- **`--tv-aside`, `--sf-zoom`:** the Settings sheet's width and the block's zoom; the queue's right margin while the sheet is open is the first over the second.
- **Meaning colours:** through tones only: `accent`, `error` (`--bad`), `success` (`--ok`), `pending` (`--live`), `warning` (`--warn`). The CSS never names them.

## Typography

- **Prose:** Tern's sans face, set by `font = "sans"` on both blocks (Tern's Designing Views › Typography); no font stack is declared and no plugin CSS sets a block's face.
- **Identifiers** (author, branch, path, repository, `#N`, Jira keys, SHAs, counts, times): `mono` or `code` spans, 12px `var(--mono)` wherever they show, so a row's detail matches the preview's kv values. A number in a kv value or running text is `mono`, never `num` (it paints the code-number colour).
- **Weight:** the `title` token for the queue's view name (the page's name), `strong` for a linked item's title; nothing else is bold.
- Text is never coloured for emphasis; only a meaning colours it.

## Spacing and radii

- Lengths are `px`, `em`, `vw`, `vh` or `%` only (Tern rejects `ch` and `rem`); no logical properties, no `:has()`.
- Steps in use: 8px (the gap between Add buttons), 10px (above an Add row), 12px (a row's gap to its control). Node `gap` props use Tern's `xs` and `sm`.
- Radii: `--r-ctl` for the arrival ring on a row; everything else takes the radius its Tern kind draws (badges, cards, a `button`'s own).

## Components

Each is built from Tern kinds; `plotroom.css` touches only what no kind or prop covers.

### Rows

A picker `item` per pull request, issue, Now entry or agent (a worktree is a Worktrees table row). Left: the author's mark (Now: the reason). Title, then a detail line of identifiers (`#N` or key in `mono`, the repository only when the view spans several, for a Blocked PR its first chip's who or what, in plain text). Right: badges, stage first. A row shows only what decides at the list level; the rest is the preview's.

### Sidebar

Tern's `scopes` rail on the queue `picker` (`scopes` the entries, `scope` the one shown). Each entry is an icon, a label and a count Tern draws muted: **Now** first (`inbox`; its count is what needs you), the Pins, the views (the kind's icon; a view's own name, cut to one line), then **Worktrees** (`folder`) and **Agents** (`sparkle`). The entries get a group heading (Now, Pins, the integration and login, Worktrees, Agents) only when there is more than one integration, a view of several logins or a pin; with one group they stay a flat rail. The queue's heading is the shown entry's name, so the rail repeats no state. No tone: a count is a number, not a meaning.

**Narrow sidebar.** At 127 terminal columns or fewer, measured from the block's own `cx.cols` (Tern's CSS sees the window's width, and container queries do not apply), the host adds `.narrow` to the picker's role; two `plotroom.css` rules then hide the rail and show Tern's scope dropdown beside the heading. Its entries read `GitHub - octocat: My PRs` (integration, login, then view; no group headings, no counts) and its button names the entry shown, so the heading keeps only its markers (stale, partial).

### Now's heading

Now is the queue picker with its own head: `icon` `inbox`, `title` **Now** (`strong`) followed by a muted ` · N left` (how many it lists) at rest and ` · n of N` while Next in Now walks it. Under it, the `subtitle`, joined by ` · `: a shimmering muted `Reading…` while it loads, the need summary in `accent` (`2 agents need you · 1 Blocked · …`, your turn), each problem in `error`, and a muted `Snoozed shown`. An empty Now says `Nothing needs you right now.` (muted), or, with every reason off, `Only agents are listed: Settings › Views › Now`. Next in Now has no bar of its own: it is a queue key, a Commands row and the key footer's **Now** seg, and the heading's `n of N` is its only trace.

### Agents row, clock and Working line

A picker `item` per live agent in the Agents list, grouped by repository (a group head with its count). Its label is the item's title; its detail line the action's name (then the last result and its age), the branch in `mono`, then what it asks of you: why the last prompt was not delivered and its blocker in `error`, its reason in plain text, its last message `muted`. Badges: the agent's state first (Working `pending`, Needs input `accent`, Idle and Exited `muted`), then the end-of-run report, the checked outcome and the checker's verdict, each toned by the Color Meaning Rule.

While an agent works, the Agents row and its item's row in Now carry two picker columns, **bar** (Tern's `bar` format) then **clock** (`elapsed`, Tern ticks it: `2m12s`). The bar is an estimate, shown only once the action has 5 finished runs; the clock and the empty track are neutral. A preview shows the same as a **Working** line under the stage, a `row` keyed `working`: a muted `Working` label, an `elapsed` node (`format = "clock"`, `m:ss`) and, with an estimate, a `meter` in `pending`, the one place the bar is coloured (your agent is working). It is a row, not a kv fact, because a kv value holds spans only. A working row's bar moves by redraw only, so the block redraws when the soonest shown bar reaches its next step.

### Board

Now or a view laid out in columns by stage, in the queue picker's preview pane (the Board's two rules in `plotroom.css` hide `.pk-main` and widen `.pk-pv`, Tern's inner picker classes; the header of `plotroom.css` lists every inner class the sheet touches). Each column is a `card` (`role = "plotroom.lane"`), its name as `head` and its count as `meta`, holding a `scroll` bounded to the block's height; an empty column holds the inline `empty` "None" instead. Each item is a compact selectable `card` (it carries `selected`; a click selects it, and Tern draws its hover and selection ring, so it wears no Plotroom cue): its number or Jira key (`mono`, then muted " · Snoozed") as `head`, one `badge` in a row under the head (Now's reason, or a view's first chip in `error`, else New / Changed in `accent`; its tooltip on the card; not the head's `end`, which Tern draws over the number in a narrow column), the title under it as a `text` with `lines = 2` (clamped, ending in `…`). The selected card is `selected` (Tern's accent ring). Double click is Enter; right-click is `actions.menu`: Open, Worktree, Agent, Snooze on a view, Open alone on Now. No CSS beyond those two rules: the look is Tern's card.

### Badges

Tern's `badge` (picker rows: the item's `badges`). One word or a short phrase, title case, the reason in its tooltip. The stage badge leads, a Blocked PR's chips next; agent state, checked outcome, checker verdict, New / Changed / Snoozed, Worktree and Draft follow. Tone by the Color Meaning Rule; a badge that is no meaning is `muted`.

### Status chips

A Blocked pull request's reasons, one Tern `badge` each, right after the Blocked badge, most severe first: **Address changes**, **Reply · N unresolved**, **Fix checks · N/T failing** (or **Re-run · likely flaky**), **Resolve conflicts**. Each names the job that clears it, not the state; tone `error` (needs fixing); the tooltip says who or what. The Blocked badge says no reason, and the row's detail line says the first chip's who or what in plain text, so no fact shows twice. The preview's status `kv` lists each as **Blocked by** (the chip in `error`, then its detail). A Board card has room for one: the first chip. No keys, no click: a chip names a job, the Next move does it.

### Arrival ring

A queue row whose item a refresh just moved into Needs you, Blocked or Ready to merge takes that stage's tone as the picker row's `tone` (`accent`, `error`, `success`) for 1.4 s. `plotroom.css` rings it with a 2px inset `var(--tc)` box shadow, held, then faded, and only on the queue picker's rows; while Tern hides the pane (`.sf-paused`) the fade pauses where it was; under reduced motion (`prefers-reduced-motion`, Tern's `.sf-still`) the row is tinted instead. The colour is the stage's, so it means what the stage badge means. At most one toast per refresh goes with it, Tern's `error` level. A new animation in `plotroom.css` gets the same `.sf-still` and `.sf-paused` rules; `scripts/check.py test` fails without them.

### Preview card

The picker's preview of a pull request or issue is a page (Tern's Designing Views › Page structure). **Head:** one `card` keyed `head`: `icon` the kind's (`merge`, the issue icon), its head a column of the title (strong) and the meta line under it (the ref and repository in `mono`, then the integration, muted; not Tern's `meta` prop, which shares the title's line and is cut to nothing in a narrow preview), and its `end` a wrapping row of the state `badge`, the Next move `button` (`sm`, its keycaps), the quiet Copy link button and the Open link icon. **Stats:** Tern's `stats`, at most four tiles, never in a card: a pull request's Checks (`error` while any fails, `warning` while any runs, else its rollup's tone), Changes, Comments and Age; an issue's Comments, Age and Linked; the rest untoned. **Tabs** (pull requests only): a `tabs` strip, the default underline, under the stats: Overview, Checks N, Threads N, Reviewers N, each count a muted span once known; only the active panel is drawn, under it, full width; Tab and Shift+Tab switch them and the key footer lists both. Overview holds the shared order (docs/reference.md › Finer points › Preview): the status `kv` (Stage first, then what needs you, then Unpin and Unsnooze), the worktree card, the description (a folded `card` with Tern's clamp and "N more lines"), the properties `kv` and the linked items. The worktree, agent and Now previews keep the plain head row (ref, kind tag, state badge) and title.

**Narrow preview.** The head card (role `plotroom.head`) keeps its title column at least 12em wide: when the title and the `end` row do not fit on one line, the `end` wraps onto its own line under the title, right-aligned, never squeezing the title. The underline `tabs` (role `plotroom.tabs`) wrap onto a second line rather than clip the last tab. Both are plotroom.css rules, since no card or tabs prop does it.

### Summary

The part at the top of a pull request's or issue's preview, an omp-written gist of the selected item (Settings › General; off, nothing shows). A `text` headed `Summary` (`strong`), then the answer as one plain `text`: never Markdown and never a link, since a model wrote it from untrusted text. Loading is a `skeleton` of 3 `text` lines; a failure is the inline error `Summary not made` with one **Make the Summary again** button (Loading, empty and error). Nothing shows until the cursor has rested on the item. No tone, no key.

### Buttons and links

What a click does shows on the node. A **button** does something: Tern's `button` kind (`tern.ui.button`, render's `button()`), sized to its label, its key as `keys` keycaps (key names: `cmd`, `enter`, `esc`, `space`, a letter; an upper-case key is `shift` and its letter, since a keycap upper-cases every letter). Size `sm` in rows, the preview and cards (the worktree card, Get started, Retry, the lenses after `gh pr create` and `git push`); `md` in bars, overlays and the Draft review's head row (the Board's fold bar, the shortcut list's Close, the confirm, verdicts and Send). An icon button is the same kind with an empty label, `quiet`, named by its `title` (the head's and the branch's Copy). A button whose work is under way is `busy` (a spinner in its icon's place; it sends nothing more), as the Draft review's Send while the window carries it. A key footer seg (a `seg` in the dock's `status` strip, requests' `keyBar`) is neither: Tern's own seg, with its own hover fill and no Plotroom cue; the strip is Tern's status bar look, a keycap then what the key does. A Board card is neither too: a selectable `card` (it carries `selected`), whose click selects it, with Tern's own hover and selection ring. A **link** opens something: `role = "plotroom.link"`, its label underlined in `--l3`, the underline darkening under the pointer. Every node with a click action or an `href` is a button, a key footer seg, a selectable card or wears the link role, and no other node does (`hx.miscued`). Buttons are neutral: no tone, destructive ones included; their confirm is the guard.

**No primary button; danger only in a confirm.** Tern's guide makes one accent `primary` button per screen, the action on the selection. Plotroom departs from it: accent already means your turn, and an accent Next move on every preview would wear that cue down until Needs you no longer stands out. So no button is `primary`. The only `danger` button is a destroying confirm overlay's action (Confirm overlay), where Tern's guide puts it: the confirm is about to destroy something, nothing else on screen competes, and a confirm has at most one. A plan's confirm (a write to GitHub or Jira) destroys nothing Plotroom holds, so its action is `default`. The preview's Next move, the worktree card's Remove worktree, Settings' Delete and Remove rows, the Draft review's **Send to agent** (a decision row, not an overlay) and every other button stay `default` or `quiet` (`quiet`: icon buttons, Show less, Get started's Dismiss, a confirm's Cancel): the button that only opens a confirm acts on nothing yet. The one confirm the window asks through Tern's picker, Message an agent with the selection… (about no Plotroom block), is Tern's own confirm rows, not Plotroom buttons.

### Confirm overlay

Every confirm Plotroom asks: the worktree card's Remove worktree, the Worktrees list's Remove worktree and Remove finished worktrees, Settings' Delete view, Delete action, Remove repository, Remove project and Reset all settings, Stop agent…, every plan of a write to GitHub or Jira, Message an agent with the selection…'s review, and the first agent on a fork's worktree. One Tern `overlay` keyed `confirm` in the block's layer (over the picker, or over the Settings sheet for Settings' own), `modal`, `size = "sm"`, its icon (`trash` for a removal or a delete, `x` for Stop agent, `merge` for a plan, a message or a fork's agent), the question as `head`, muted `meta` for a count that qualifies it (how many were not checked). Its body: the consequence in one muted sentence, then a `kv` of facts (a worktree's Path and Branch, the Branch line saying what becomes of it) or a plan's, message's or fork agent's lines as they will be sent or started; a message's review adds, above the foot, **Add a note…** (or **Edit note…**; `quiet`, `md`, icon `pen`, keycap `n`). Its `foot` is a row, right-aligned: **Cancel** first (`quiet`, `md`, keycap `esc`), then the action named as what it does (`md`, the overlay's icon, its key's keycap; `danger` for a removal, a delete or Stop agent, `default` for a plan, Send or Start agent). A refused removal (git refuses it, or a tab or an agent works in the folder) says why in the sentence and offers Cancel alone. Settings' confirms, Stop agent, a plan, Send and Start agent take Enter for the action; the worktree removals keep `d` for it, and Enter keeps the worktree too. While a confirm asks, no other key reaches what is under it.

### Compose overlay

Text Plotroom asks for that may run over several lines: Comment…, Approve…'s and Request changes…'s comment, Type a prompt… and a draft pull request's description. One Tern `overlay` keyed `compose` in the queue block's layer (over the picker; Settings closes first), `modal`, `size = "md"`, icon `pen`, what the text is for as `head` (Comment, Approve, Request changes, Prompt for an agent on #N, Draft PR description), the selected item's ref as muted `meta` when the text is about it. Its body: an `editor` keyed `draft` (the placeholder says what to write, `maxLines = 16`, at least 6 lines tall), then, when its action was refused (too long), one `error` line saying so. Its `foot` is a row, right-aligned: **Cancel** first (`quiet`, `md`, keycap `esc`), then the action named as what comes next (`default`, `md`, keycaps `cmd` `enter`): **Continue** when a confirm follows, **Start agent**, **Save** for a description. Enter adds a line, ⌘↵ (or Ctrl-Enter) is the action, Esc cancels; while it asks, no other key reaches the queue. It is not a confirm: nothing leaves Plotroom from it, so it has no consequence sentence and its action is never `danger`.

### Shortcut list overlay

The keys that work now, one Tern `overlay` keyed `help`, `modal`, `size = "md"`, headed `Keyboard shortcuts`. Its body is a `col` of rows (`gap = "md"`, `align = "start"`): the keys as native keycaps in a `text` of their own that never shrinks below 13 characters (`wrap = "none"`; a kv's key column is measured as text and ran four keycaps into the description), then what they do in the body font, growing. The rows are the list's built-in keys, each with the key you bound it to, then one **Run the action “X” on the selected pull request** (or issue) row per action with a key; with Settings open it lists Settings' keys instead. Its foot is one **Close** button (`md`, icon `x`, keycap `esc`). No tone: a key is not a meaning.

### Checks table

The preview's checks, one Tern `table` per group (Failing, Running, Queued; Passed and Skipped in their fold), each under its muted `Group N` heading. Columns: **Check** (the one `grow` column, a status `dot` in the run's tone: `error` failed, `warning` running or queued, `success` passed, `muted` skipped; Required, Likely flaky and Ignored as muted text after the name), **Workflow** and **Took** (`align = "end"`, `mono`). Rows are `selectable`: a click opens the check's page. Each row's right-click menu offers Open (when the check has a page) and, on a failing check not yet ignored, Ignore in this repo…; Tern adds Copy row. A failing check's excerpt is a `code` node (`lang = "text"`) in a plain section headed by its first error line, that line marked `error`, clamped by `preview` with Tern's "K more lines". Never put it in a collapsible section: Tern applies a code `preview` only while that disclosure is folded, and folded draws no body.

### Worktrees table

The Worktrees scope, laid out like the Board in the queue picker's preview pane (its `.board` role, no new CSS): one Tern `table`, `selectable`, its `selected` the selected worktree (a click selects, a double click opens it in a tab), beside that worktree's card. Columns: **Name** (the worktree's folder name, `grow`, the highest `priority`), **Repository** (`mono`), **Status** (a `dot` and its words: Changes, Clean, Unknown or Reading…, then Merged or Closed, Locked, Missing, In tab, Unnoted; the dot `error` for a missing folder, `success` for Merged, else `muted`), **Linked** (`#N` or the Jira key, `mono`) and **Path** (`mono`, `truncate = "middle"`, the full path as the cell's tooltip, the lowest `priority`, so it hides first; it grows too, since Tern cuts only a column that takes spare width and hides one that does not fit whole). The card beside it: `head` its name, `meta` its branch (`mono`), `end` its **Remove** button (`sm`, default variant, the bound key as keycaps), then the worktree preview's parts.

### Worktree card

A `card` in the preview while the item has a worktree: neutral badges (Up to date or Not at PR head; Clean, Uncommitted changes or Changes unchecked; N unpushed), the branch and path with copy icons, the update commands folded away when behind, then buttons (Open in new tab or Go to tab, Remove worktree, Open Git view). The card takes the `error` tone only when the worktree could not be made, and then shows why and no buttons. It is a cache of git, never the source.

### Loading, empty and error

Tern's four states, in the place of what they stand for and under its key, so the loaded part replaces them without a jump. **Loading:** a `skeleton` (default `shimmer` variant, no tone) shaped like the part: `rows` for a list (Checks 3, Reviewers, Unresolved threads and linked items 2), `text` lines for the Summary, the description and a worktree's linked items, and a `block` 8 lines tall where the Draft review's diff goes. **Empty:** an `empty` with `variant = "inline"`, no tone, its `title` saying what is missing ("No checks", a Board column's "None"). **Error:** the same inline `empty` with `tone = "error"` (needs fixing), `title` `Could not load <what>`, `text` the tool's message and when it is tried again, and one child: a Retry button (render's `button()`, `icon = "redo"`, size `sm`). The queue picker's own `state = "loading" | "error"` stays.

### Commands

`.` opens Tern's picker as an overlay: grouped rows filtered to what applies now, **Next** first, each with its key as keycaps. Every queue action has a Commands row; there is no action bar (the key footer lists keys, not actions).

### Key footer

Tern's `status` strip (keyed `keybar`, `aria = "Keys"`) in the block's dock, 24px tall, under the queue and its Board. One `seg` per key that works now: the key as a keycap span, then its name muted, in the order docs/reference.md gives (Commands, Shortcut list, the Next move, then the most used). Each seg's `priority` falls from first to last, so a narrow pane drops keys from the end and Commands goes last. A click on a seg runs what its key runs: the strip is Tern's own control, so a seg is a clickable node that is neither a `button` nor a link. No tone. With no key bound, or while Settings is open, there is no strip. The picker's role takes `.keys` while it shows, and `plotroom.css` ends the picker's sheet 24px above the dock so the strip takes clicks and covers no row; a Board's columns are 2 lines shorter for it.

### Get started

The checklist `card` keyed `get-started`, first in the preview above a pull request's or issue's page and in Now's; not beside the Worktrees table or the Agents list. It shows until every line is done or it is dismissed (kv `get-started`), and again when Commands › Get started opens it. Its head is a `text`: `Get started` (`strong`) and a muted `N to do` or `All set`. Under it, a `col` (`gap = "xs"`) of one line per step: gh (installed, signed in), omp, git (a line only while it is older than 2.36) and a checkout for each repository that has none, then the one-key shortcuts line. A step you can do is a `row` of a `button` (`sm`, icon `arrow-right`) and its muted detail; a setup guide is a link `item` that opens the guide; a step being asked is a muted `item` (`Checking gh…`) with no control; a done step is an `item` with the `check` icon in `success` and no control. The shortcuts line asks **Use them** or **No thanks** (icons `check`, `x`), then reads done. Its foot is **Dismiss**, or **Close** once all is set (`quiet`, icon `x`). While any line is being asked the card stays hidden unless Get started opened it. `success` is the only tone: the rest is neutral.

### Settings

Tern's `prefs` side sheet in the block's layer, four pages (Views, Actions, Repositories, General) with icon tabs. Each list item opens a form; its Delete or Remove sits beside Done and is neutral like every other button, and asks in a Confirm overlay over the sheet. A prompt is edited in an `editor` card over the sheet (`role = "omp.prefs.editor"`).

### Draft review

The review block is a focused workspace, not a feed of repeated diff cards. A compact header identifies the pull request and reviewed commit. A wrapping decision row holds the verdict choices as one `buttons` group (joined, neutral, the chosen one `on`), the kept/dropped count and **Send to agent**, all `md`; while sending, Send is `busy` and reads Sending…; once sent a muted Sent badge replaces it, and a failed handoff offers **Copy** alongside its explanation.

A native `list` navigator selects Summary, each finding in file order, then Instructions. Its native selection stays in view; each finding names its filename, line and Kept/Dropped state without using colour as the only cue, with its kind, full path and feedback excerpt in the tooltip. The selected item is one `card` (no tone, no icon): a finding's `head` is its path in mono, its `meta` where it is (line or lines), its `end` a `row` of `sm` buttons, Keep/Drop then Edit (Done while editing); the body holds its native diff excerpt, its Markdown feedback and, in a folded section, its suggestion as a `diff` of the lines it replaces (else `code`). Summary and Instructions are cards the same way, with Edit summary and Edit instructions at their `end`. Off-diff findings explain why they cannot be kept.

The navigator and the card sit in a `split` (keyed `body`, the default hairline look, growing into the pane's height): side by side with minimums of 24ch and 40ch, or stacked (`dir = "col"`) below 100 columns. The shares the user drags (`change`) are kept for the block per direction and fed back as `sizes`. Use `split`, `card`, `list`/`item`, `button`/`buttons`, `md`, `editor`, `diff`, `code` and native keycaps. `j`/`k` or arrows move, Space keeps/drops, `e`/Enter edits, `1`/`2`/`3` choose the verdict and ⌘↵ sends. Buttons are Tern's `button` kind in both Plotroom block surfaces; selection uses the list's native highlight, not a semantic tone. No decorative colour, new font, animation or custom diff renderer.

## Adding a component

1. Add it here: which Tern kinds, which tones (by the Color Meaning Rule), which keys.
2. Add its LEDGER.md row.
3. Build it, with a regression case that runs `hx.miscued` and `hx.offPalette` over it.
