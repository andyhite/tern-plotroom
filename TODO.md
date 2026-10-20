# TODO

## Backlog

## Todo

- [ ] Settings offers the one-key shortcut set in one click, and a Ready to merge view joins the defaults.
  - Settings › Keyboard shortcuts gets a "Use one-key shortcuts" row that binds the classic set (`j`/`k` move, `w` worktree, `g` go to tab, `a` agent picker, `G` go to agent, `m` mark seen, `z`/`Z` snooze, `n` attention, `o` sort, `/` search, `r` refresh, `s` settings, `?` help, `u` find finished, `d` remove) to actions that have no key.
  - A key you already saved keeps its action, a preset key already used by another action or a saved action is skipped, a toast lists what was skipped, and an unreadable `keys` store is refused with the existing message.
  - A new default pull request view "Ready to merge" (`is:open author:@me review:approved status:success archived:false`, grouped by repository) is seeded on first run and reaches existing users through Restore defaults in Settings › Views.
  - Touch points: `ACTIONS`, `save` and `problem` in `keys.luau`; the Keys page rows in `host/settings.luau` (row pattern of `restore-views`); PR seeds in `KINDS` in `host/core.luau`; `storage.missingViews`.
  - Cases (`tests/cases/queue.luau` keys page, clearing `keys` first): the preset fills unbound actions, keeps a saved key, and skips a clash; the default views include Ready to merge and Restore defaults offers it. README: Keys and the command palette, Default views.

- [ ] An action's Move to status works without PLOTROOM_JIRA_API_TOKEN.
  - When an issue action with Move to status starts its agent on a Jira issue, Plotroom moves it with `acli jira workitem transition` (key, status, `--yes`) instead of the REST API, so no token is needed.
  - An issue already in that status is left alone as today; an acli failure (no such status, a transition that needs fields) is an error toast with acli's message, and the agent still runs.
  - The palette's Jira transition… picker keeps the REST API and the token, since it needs the transition list.
  - Touch points: a transition-by-status call beside `jira.transition` in `jira.luau` (acli argv style), the Move to status path in `host/requests.luau`.
  - Docs: README's "Jira transitions need an API token" and Move to status bullets say the token is only for the palette picker; README Trust notes Move to status runs without a confirm, as decided when it shipped; AGENTS.md's Jira transition invariant names the palette picker only.
  - Cases (`tests/cases/issues.luau`, `tests/cases/flows.luau`): the move runs acli with no token set; already there runs nothing; an acli failure toasts and the agent starts.
  - Decided: Move to status uses `acli jira workitem transition --status`; the REST API and token stay only for the palette's Jira transition… picker.

- [ ] Jira views list up to 1000 items instead of stopping at 100.
  - A Jira view fetches its JQL results past 100, up to 1000 items like GitHub's cap; more than 1000 marks the view partial, as a cut list does today.
  - The view takes its total from acli's count, so exactly 100 results no longer shows as partial.
  - A failed count keeps today's single-page behavior; each acli call keeps its 60 s timeout.
  - Touch points: the search call, `LIMIT` (with its `ponytail:` comment) and the completeness rule in `jira.luau`; the completeness rule in `tracker.luau`.
  - Cases (`tests/cases/tracker.luau`): more than 100 paginates, exactly 100 is complete, a failed count falls back; update the `--limit 100` and "full page not complete" cases. README Finer points: Jira's limit.

- [ ] An action can have Carly summarize its run when it finishes, and Carly can see my live agents.
  - Settings › Actions gets an off-by-default "Tell Carly when it finishes" toggle; when on, the started agent schedules one Carly message for the end of its turn (`Agent:tocarly`).
  - The message is a fixed template naming the action, item key and result; no PR or issue text and no agent output goes into it.
  - A read-only Carly export named `plotroom_agents` lists the window's linked agents with item key, action name and state; it changes nothing.
  - Where Carly isn't available, the toggle does nothing and the export isn't registered; a failed schedule is a toast, and the agent runs regardless.
  - Touch points: the new `Prompt` field through core, the storage validator and save, `portable` export/import and the Settings › Actions row; the start path in `window.luau` (`cx.agents:get`, then `tocarly`); `tern.carly.export` registered from `window.luau`.
  - Cases: the toggle round-trips through save and export/import; a start with it on schedules one message with no item text (the harness gains carly and `agents:get` fakes); the export lists linked agents. README: the actions section and Trust (what Carly receives).

- [ ] After `gh pr create` in a shell, a lens offers to show the new PR in Plotroom.
  - A command lens claims `gh pr create`; when the output holds a PR URL, the lens view shows it with Show in Plotroom, Copy and Open in browser.
  - Show in Plotroom opens the PR in the same host's Plotroom block as Open item by URL does (fetched, pinned), launching Plotroom first when none is open; the lens runs nothing else.
  - Output without a PR URL (a failed or cancelled create) shows the raw output; pipelines and redirects are never lensed, by Tern's rule.
  - The window accepts this one read-only show link from a non-Plotroom pane; worktree, agent and run links still refuse anything not from a Plotroom block.
  - Touch points: `[[lenses]]` in `plugin/plugin.toml`; `tern.lens.define` registered in `host.luau` with the lens in a host module that respects the layer rules; `route.link`/`handle` and `openByUrl` in `window.luau`/`flows.luau`.
  - Cases: a `gh pr create` transcript yields the lens view; the show link from a non-Plotroom pane opens and pins the PR; a worktree link from that pane is still refused (the harness gains a lens fake). README: What it does.

- [ ] A GitHub notifications inbox lists what needs me, and marks threads read in one confirm.
  - A new Inbox list in the sidebar, after Agents (a list like Worktrees and Agents, not a view kind), shows gh's active login's unread, participating notifications, grouped by repository, each with its reason (review requested, mention, CI…) and the PR or issue it's about.
  - Enter shows that PR or issue in the block, as a linked PR does; the list refreshes with the queue and obeys GitHub's `X-Poll-Interval` and `Last-Modified`, so an unchanged inbox (304) costs nothing.
  - Mark read… marks the listed threads read after one confirm, Cancel first, that shows their count and the account; the gh login is captured at plan time.
  - Without gh, or when the login can't read notifications, the list shows the problem and the `gh auth refresh` command that fixes it; nothing falls back to another login.
  - Touch points: a notifications read and a mark-read write in `github.luau`; host state in `host/core.luau`, glue in `host/engine.luau`, rows in `host/render.luau` (mirroring the Agents list); plan/commit in `host/requests.luau` and the confirm in `flows.luau`; bump `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` together.
  - Cases: rows from a fake notifications reply, a 304 spends nothing, mark-read plan and commit with the captured login, the scope problem message. README: What it does, the sidebar, and the Trust list of confirmed writes.
  - Decided: the inbox marks threads read, never done, through one batched confirm.

- [ ] Jira writes always go to the site acli is signed in to now, and a "429" inside other text is not a rate limit.
  - Before any REST write (the palette's Jira transition…), Plotroom re-reads acli's site and email, so after `acli jira auth switch` the write goes to the current site or is refused; nothing is posted to a cached site.
  - A failed `acli jira auth status` during that read is an `auth` problem, and nothing is sent.
  - acli output counts as rate-limited only when it says rate limit or shows 429 as a standalone status, never inside a key such as `ABC-429` or an id.
  - Touch points: `verified()` and `withSite` in `jira.luau` (reset the cached site the way `noted()` does), the acli classifier.
  - Cases: `tests/cases/mutation.luau` transition with a site switch between list and post; `tests/cases/tracker.luau` an acli failure naming `ABC-429` is not `rate-limit`, "429 Too Many Requests" still is.
  - Base: main
  - Branch: todo/jira-writes-current-site at /Users/andyhite/Code/tern-plotroom.todo/jira-writes-current-site
  - Decision: `verified()` clears the cached site first, so every listed or transition write re-runs `acli jira auth status` and uses that site and email; `noted()` is unchanged.
  - Decision: acli output is rate-limited when it says rate limit or has 429 as a standalone token (`%f[%w_%-]429%f[^%w_%-]`), so `ABC-429` and `12429` are not.
  - Decision: The harness `asks.bk.fetch` fixture strips any `https://host` prefix so a case can answer another site.
  - Fix: plugin/jira.luau:854-858 (`verified`) - a failed `acli jira auth status` re-read before a write reaches the caller as `failed` (or `missing`), not `auth`, because `M.classify` only says `auth` for "unauthorized"/"auth login"; acceptance bullet 2 is unmet and `tests/cases/mutation.luau:490` only checks a problem exists - in `verified()`, call `withSite` first and turn any failure into `kind = "auth"` (keeping acli's line in the message) before `/myself`; leave `withSite` itself unchanged (`tracker.luau` expects a search to pass `missing` through); assert `problem.kind == "auth"` in the case.
  - Review attempts: 1

- [ ] Links inside PR or issue text can't run Plotroom actions, and unsafe head branch names never reach agent prompts.
  - Every action link the block renders for the window (button, saved-action run, worktree, agent, goto, agentgo) carries a random token made when the host starts; the window's exact-href check then refuses a `plotroom://` link written into a description, which lacks it.
  - A tokenless or stale link gets the existing "no longer listed" toast and starts nothing; the token never appears in rendered markdown, toasts or kv.
  - `github.pr` refuses a head branch with characters outside letters, digits and `_ . / + @ -`, or one not starting with a letter, digit or `_`, naming the branch; Worktree and agents refuse that PR while the queue still lists it.
  - Touch points: `buttonLinks` and the other hidden hrefs in `host/render.luau`, `parseLink`/`handle` in `window.luau`, the head ref check in `github.pr`, the link builders `prLink`/`issueLink` in `tests/harness.luau`.
  - The link format changes: bump `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` together.
  - Cases: hidden hrefs carry the token; a tokenless run or worktree link is refused; a PR whose head branch contains `$` or `;` is refused for Worktree and agents. README Trust: one line for each guard.
  - Base: main
  - Branch: todo/action-link-token-head-ref-check at /Users/andyhite/Code/tern-plotroom.todo/action-link-token-head-ref-check
  - Decision: The link token is four `math.random` 24-bit draws made when the host module loads (`ponytail:` comment); the window strips `?k=<token>` before parsing and compares the full href with the hidden node's.
  - Decision: Tokened: button, saved-action run, worktree, agent, goto, agentgo and the Worktrees list's open link; `show`, `check`, `more`, `repos`, `confirm` and `rpc` links stay untokened.
  - Decision: An unsafe head branch is a `failed` problem from `github.pr`, naming the branch cleaned and cut to 80 bytes.
  - Decision: `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` are now "23".
  - Fix: plugin/host/core.luau:611, plugin/window.luau:33, plugin/tests/harness.luau:3031 - main (7cbca60, fork PRs) already took protocol "23", so after landing this new `?k=` link format shares main's number and a mixed host/window pair sees no mismatch and fails every link as malformed - rebase onto main and bump `RPC_PROTOCOL`, `PROTOCOL` and `asks.protocol` to the next unused number ("24" unless main has moved past it); update the Decision bullet to match.
  - Fix: plugin/github.luau:1094 - `string.sub(input.clean(data.ref), 1, 80)` cuts after cleaning, so a long multibyte branch can end in a broken UTF-8 sequence in the reply and toast - clean after cutting: `input.clean(string.sub(data.ref, 1, 80))`, as `flows.clip` does.
  - Review attempts: 1

- [ ] Switching views shows each view's cached list at once, and one view's error never stalls the others.
  - Switching between pull request, GitHub issue and Jira views keeps every cached list: a view shows its last result immediately while it refreshes, and other groups' sidebar counts stay.
  - A `not-found` (an unknown Jira project, a pin no longer visible) belongs to its view: switching to another view clears it and that view searches; `auth` and `missing` still hold every view until Refresh.
  - Sidebar counts and Needs attention only read snooze state without hashing each seen item, so render cost does not grow with seen items in cached views.
  - Cached lists stay keyed by `snapKey` (kind, integration, login, query), so no identity sees another's list; they are not pruned, and a `ponytail:` comment names that ceiling.
  - Touch points: `forget`, `identify`, `changed`, `keep` and `listedCount` in `host/engine.luau`; a snooze-only lookup beside `status` in `triage.luau`.
  - Cases (`tests/cases/queue.luau`): a cross-kind switch shows the cached list and its count; `not-found` on one view does not block another; a bench row with 1000 seen items in `tests/regression.luau`. README Finer points › Refresh: terminal errors include `not-found`, cleared by a view switch.
  - Base: main
  - Branch: todo/view-cache-per-view-errors at /Users/andyhite/Code/tern-plotroom.todo/view-cache-per-view-errors
  - Decision: A login change within one integration still clears the problem; a switch that changes integration or kind keeps `auth` and `missing`.
  - Decision: `changed` clears `not-found` only when the view moved (`snapKey` differs from `applied`); re-clicking the same view keeps it.
  - Decision: The `issues.luau` case "a request is about what it names…" now expects no problem, since the cached Jira list stays.
  - Decision: Snooze-only lookup is `triage.snoozed`, used by `keep` and `listedCount`; bench row `seen-render`.
  - Fix: plugin/tests/regression.luau:86-94 (`seen-render`) - the row never loads 1000 seen items: keys are `no/r#i` (the picker-id prefix, not the triage key `o/r#i`), entries lack `at` so `triage.validate` rejects the store, and the block keeps the `state.triage` it already read - seed `o/r#i` with `{ seen = "x", at = EPOCH }` and make the block reread the store (e.g. `b.state().triage = nil`) before timing, so the row fails if `listedCount` hashes each item again.
  - Fix: plugin/host/engine.luau:666-669, 719-729 - `identify` now keeps an `auth`/`missing` problem across an integration change, but `headOf`/`helpOf` (and Settings' pause line) label it by the view now shown, so an acli sign-out shown on a GitHub view reads "GitHub CLI not signed in" / "Run gh auth login" (and the reverse), and `save` persists that - record the integration that raised the problem when it is set and label by it in `headOf`, `helpOf` and `paceLine`.
  - Fix: plugin/tests/cases/queue.luau:2286-2306 - the not-found case switches Jira → PR, which base already cleared through `forget`, so it passes without the change and never asserts the title's "the view itself stays paused" - add a same-integration switch (two Jira views, or two GitHub views of one login) that fails on base, and assert re-clicking the failed view sends no search.
  - Review attempts: 1

- [ ] Agent chains never stop silently, and agent status syncing runs only while an agent is alive.
  - A finished agent whose host has no open Plotroom block keeps its next action and gets a toast to open Plotroom on that host; its next `done` finish then advances the chain.
  - A chained issue step reuses the code repository the chain recorded, so a Jira project mapped to several repositories is not asked about again mid-chain.
  - A finished pane maps only to its newest link, so a pane id reused after a restart never starts an old chain; recording an agent drops older links for that pane.
  - The 4 s status timer re-arms only while a linked, non-exited agent exists and starts again after a plugin reload; the two `pane_closed` handlers merge into one; `agent-recent` is never written after a failed read.
  - Touch points: `takeChain`, `recordAgent`, `agentSync`, `tick` and `ensureSync` in `flows.luau`; `advanceChain`, the `pane_closed`/`window_start` handlers and `readRecent` in `window.luau`.
  - Cases (`tests/cases/flows.luau`, `tests/cases/window.luau`): a chain stops after 8 with its toast; an `exited` result toasts; no block → toast and the next action kept; a stale pane link is ignored; the timer stops with no live agent; one `pane_closed` runs agent sync, redraw and the protocol check; an unreadable `agent-recent` is not written. README: the Next action bullet.
  - Base: main
  - Branch: todo/agent-chains-never-stop-silently at /Users/andyhite/Code/tern-plotroom.todo/agent-chains-never-stop-silently
  - Decision: With no Plotroom block on the agent's host, the toast "Next action waits for Plotroom" shows for any result and the next action is kept.
  - Decision: `active()` counts an unreadable agent list as live, so the 4 s timer keeps running then.
  - Decision: An issue chain step passes `{target = chain.code}` to `prepareTarget`.
  - Fix: plugin/window.luau:252, 1262-1267 / acceptance "starts again after a plugin reload" - the timer still starts only from `window_start`/`pane_created`, but this file documents that a plugin reload fires no lifecycle event (hence the load-time `arm(0)`), so after a reload a live agent's status stays stale until a pane is created - start it at module load too (a `tern.timer(0, …)` calling `flows.ensureSync(cx)`, like `arm(0)`), with a case that a reload with a live linked agent restarts the timer.
  - Fix: plugin/flows.luau:286-294 (`active`) - returns true when `cx.agents:list()` is unreadable before looking at links, so with zero links the 4 s timer keeps re-arming although no linked agent exists - return false when `readLinks()` is empty, then treat an unreadable list as live.
  - Fix: plugin/tests/cases/flows.luau:2991-3000 - `flowHost` announces the matching protocol, so `protocolWarning(w, 1)` is nil whether or not the merged `pane_closed` handler calls `checkProtocol`; the named "one `pane_closed` runs … the protocol check" case proves nothing - make the block announce another protocol before the event and assert the mismatch warning appears.
  - Review attempts: 1

- [ ] The command palette sends only what it shows, and in the Agents list it offers agent commands instead of queue ones.
  - The palette's `menu` answer omits each saved action's prompt text (the palette runs actions through their hidden links), so pressing `.` no longer adds every prompt to the block's frame and long prompts no longer push actions out of the palette.
  - The agent picker and saved-action runs keep getting the prompt text from their own `menu` request.
  - Opened from the Agents list, the palette offers Go to agent for the selected row, the views, Settings and help, and none of the queue's snooze, attention, sort, search or refresh rows.
  - Dead paths go: the ignored `agent-link` event, the `seen` event branch that repeats `queueAction`, and the never-produced "GitHub" and "Jira" palette groups; a draft PR preview is cleared only while it is still the one that plan made.
  - Touch points: `menu` and `paletteActions` in `host/requests.luau`, the draft clear in the draft PR commit, `GROUPS` in `window.luau`, event dispatch in `host.luau`; the `menu` answer changes, so bump `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` together.
  - Cases: `tests/cases/checks.luau` palette answer has no prompt text (update its pin); the palette on the Agents list; a draft replaced during a push survives. README: Keys and the command palette.
  - Base: main
  - Branch: todo/palette-sends-what-it-shows at /Users/andyhite/Code/tern-plotroom.todo/palette-sends-what-it-shows
  - Decision: `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` are now "23".
  - Decision: The Agents-list Go to agent row is in a new "Agents" palette group, after "Saved actions" in `GROUPS`.
  - Decision: `flows.luau` no longer sends the ignored `agent-link` event.
  - Decision: The draft-replaced case only checks the commit finishes and pins the new PR; it cannot tell the fix from the old clear, because the pin bumps `state.gen`.
  - Fix: plugin/host/core.luau:601, plugin/window.luau:33, plugin/tests/harness.luau:3022 - main (7cbca60, fork PRs) already took protocol "23", so the new `menu` shape ships under main's number and a mixed host/window pair sees no mismatch - rebase onto main and bump `RPC_PROTOCOL`, `PROTOCOL` and `asks.protocol` to the next number main has not used (check main at rebase time; another queued item also targets "24"); update the Decision bullet to match.
  - Review attempts: 1

## In-Progress

- [ ] The worktree card opens Tern's Git view, shows unpushed commits, and refreshes after git commands.
  - The worktree card and a Worktrees list row offer Open in Git, which opens Tern's git block on that worktree; it shows only for a local block whose worktree folder exists.
  - The card's changes read uses `git status --porcelain=v2 --branch`, so the same spawn gives ahead/behind: a worktree with unpushed commits shows "N unpushed", and nothing shows when the branch has no upstream (fork PR worktrees).
  - A command whose line starts with `git ` finishing in a pane inside a known worktree marks that card for a fresh read, so badges update right after `git commit` or `git pull`.
  - Touch points: `dirty` in `worktree.luau` (porcelain v2 header lines never count as changes); the card in `host/render.luau`; `inspectSelected` in `host.luau`; host `command_finished` beside the existing hooks in `host/engine.luau`; an `openWorktree`-style link in `flows.luau`/`window.luau` calling `cx.git:open`.
  - Read-only, so no plan-then-commit; the new link and path request bump `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` together.
  - Cases: porcelain v2 parsing (clean with an ahead count, dirty, no upstream) in `tests/cases/mutation.luau`/`checks.luau`; a `git commit` finish refreshes the card; Open in Git is refused for a remote block. README Worktrees: the card's badges and buttons.
  - Base: main
  - Branch: todo/worktree-card-opens-tern-git-view-shows at /Users/andyhite/Code/tern-plotroom.todo/worktree-card-opens-tern-git-view-shows

- [ ] Interrupt, stop or message the selected item's agent from the command palette.
  - The palette's Saved actions group offers Interrupt agent, Stop agent… and Message agent… while the selected item, or the selected Agents row, has a live agent.
  - Interrupt sends Ctrl-C to the agent's current turn without closing it; Message asks for one line and sends it to the agent.
  - Stop asks first in a pick listing Cancel first, then closes the agent block and ends its program.
  - An exited agent, a blank message, or a message the agent can't take now gives a toast and changes nothing.
  - Touch points: pane resolution through `liveAgent`/`goAgent` in `flows.luau`; link kinds, `parseLink` and the hidden-node check in `window.luau`; palette rows in `host/requests.luau`; `cx.agents:interrupt`, `stop` and `ask`.
  - Cases (`tests/cases/flows.luau`): each command reaches the right pane, Stop's Cancel stops nothing, an exited agent toasts, the rows show only with a live agent. README: Keys and the command palette; Triage, agents and commands.
  - Base: main
  - Branch: todo/interrupt-stop-message-selected-item-age at /Users/andyhite/Code/tern-plotroom.todo/interrupt-stop-message-selected-item-age

- [ ] Remove every finished worktree in one confirm.
  - After Find finished worktrees, a Remove finished row (palette and Worktrees list) lists every row it marked Merged or Closed and asks once: `d` removes them all, Enter or Esc keeps them, as single removal does.
  - Each goes through `removeEntry` one at a time, never forced: a worktree with changes is refused and kept, a branch whose commits aren't all in the fetched ref is kept, and the toast counts removed and kept rows.
  - Only rows Find finished worktrees already checked are included; unchecked, main, locked and missing rows are skipped, and the confirm says how many weren't checked.
  - It is refused while another board operation runs; the Find action has one name, "Find finished worktrees", in the bar, the palette and README.
  - Touch points: `findCandidates` and removal in `board.luau`; `wt-cleanup` and removal in `host/engine.luau`; the remove overlay in `host/render.luau`; palette rows in `host/requests.luau`.
  - Cases (`tests/cases/flows.luau` cleanup cases): the confirm lists only marked rows, Esc keeps all, `d` removes clean ones and keeps a dirty one. README: the Worktrees list bullet.
  - Base: main
  - Branch: todo/remove-every-finished-worktree-one-confi at /Users/andyhite/Code/tern-plotroom.todo/remove-every-finished-worktree-one-confi

## Blocked

- [ ] Queue rows show the badges that matter, and the bench gate fails on real regressions.
  - Rows drop the GitHub/Jira integration badge (the same on every row of a view; the preview head keeps it), freeing a badge slot for status, Draft or Merged, and drop the redundant `seed` on the author mark.
  - Any number of `cwd`/`pane_exited` events within `redrawQueues`' 250 ms window render each block once.
  - The primary-button CSS restyle gives way to the `end` prop, with Commands still last in the corner in a real Tern window, and the CSS rule for linked picker titles, which matches nothing, goes.
  - The bench budget default drops to 25 ms, and the `BENCH payload` row must stay under 600000 bytes, so either regression fails `check.py`.
  - Touch points: row builders and the action list in `host/render.luau`, `redrawQueues` in `host/engine.luau`, `plugin/plotroom.css`, `check_bench` in `scripts/check.py`, AGENTS.md's `PLOTROOM_BENCH_BUDGET_MS` default.
  - Cases (`tests/cases/queue.luau`): rows carry no integration badge while the preview head does; five redraw events render once.
  - Base: main
  - Branch: todo/queue-rows-show-badges-that-matter-bench at /Users/andyhite/Code/tern-plotroom.todo/queue-rows-show-badges-that-matter-bench
  - Blocked: Commands-last-in-the-corner needs a real Tern window check; the display was asleep and locked (`computer.capabilities()`: capture false, screenLocked true). All other bullets are done and gated at 5e1ee9f. To check: `tern plugin link <worktree>/plugin`, open Plotroom, confirm Commands is last in the action-bar corner, then `tern plugin link /Users/andyhite/Code/tern-plotroom/plugin`.

## Review

- [ ] A GitHub rate-limit pause stops every automatic GitHub read, and Settings always shows the refresh pace.
  - While GitHub's pause holds (quota 0 or Retry-After), the first page of every search and the head-branch lookup answer rate-limited without spawning `gh`, and so does everything built on them (board preview, noted-issue reads).
  - Confirmed writes (assign, comment, labels, re-runs, draft PR) stay ungated: they are user-initiated, and GitHub reports its own limit.
  - Settings › Refresh keeps showing the interval and the last "next at" while a refresh runs instead of going blank.
  - Touch points: `searchAll` (a guard before the first page, shaped like the one in `M.checks`) and `pullByHead` in `github.luau`; `paceLine` in `host/render.luau` and its Settings caller.
  - Cases: `tests/cases/tracker.luau` first search page and `pullByHead` during a pause spawn nothing and answer `rate-limit`; `tests/cases/queue.luau` the pace hint is non-empty during a refresh. README Finer points: the pause covers every automatic read, not confirmed writes.
  - Base: main
  - Branch: todo/rate-limit-pause-gates-reads at /Users/andyhite/Code/tern-plotroom.todo/rate-limit-pause-gates-reads
  - Decision: Pause guards answer `rate-limit` ("GitHub's rate limit is reached; reads resume at HH:MM:SS.") through `tern.timer(0)`, shaped like `M.checks`; a cancelled search under a pause now reports `rate-limit`, not `superseded`.
  - Decision: `paceLine` no longer requires `state.timer`, so Settings shows the previous "next at" during a refresh.

- [ ] A PR's preview finds its fork worktree and noted issue without listing every worktree, and reads that issue as the view's account.
  - The PR preview takes the noted issue from the last worktree scan (`state.notes`), matching the PR's local branch including a fork's `<owner>/<branch>`, instead of running `git worktree list` on every PR selection (replacing the per-PR `inventory` read added with the both-halves preview).
  - Before a checkout's first scan the preview shows no Issue section; the next refresh's scan fills it.
  - The noted issue is read as the view's gh login (`M.login(state)`), not gh's active one; the Worktrees board keeps its own account.
  - Two issues noted on one branch: the first wins, as today.
  - Touch points: the PR branch of the detail load and `readNoted` (gains a login parameter) in `host/engine.luau`.
  - Cases (`tests/cases/checks.luau`): a fork PR's preview shows its noted issue; the issue read passes the view's login; selecting a PR runs no `worktree list` (update the two list-count cases that expect one).
  - Base: main
  - Branch: todo/pr-preview-finds-fork-worktree-noted-iss at /Users/andyhite/Code/tern-plotroom.todo/pr-preview-finds-fork-worktree-noted-iss
  - Decision: The preview matches an ok `issues` note in the PR repo's checkout whose branch equals `worktree.prBranch(pr.head, pr.fork)`; of two notes on one branch the lowest `seq` (first noted) wins.
  - Decision: `readNoted(key, rowRepo, account, live, done)`: the PR preview passes `M.login(state)`, the Worktrees board passes `nil`.
  - Decision: An issue's worktree is noted only after an issue list was scanned, so a PR preview before that shows no Issue section (README).

- [ ] The queue's error and empty states say what to do next.
  - A view with an error and no list shows Refresh and Settings buttons on its card even when those actions have no key (only `.` is bound by default); with a list on screen the bar is unchanged.
  - An empty list emptied by Needs attention only or snoozing says how many items are hidden and by which filter, naming its key or palette row; a view with no matches keeps today's text.
  - The README hero's footer shows only keys bound by default.
  - Touch points: the action list, `keyed` filter, error card and empty text in `host/render.luau`; `keep`/`listedCount` in `host/engine.luau` for the hidden count.
  - Cases (`tests/cases/queue.luau`): the error card with default keys has Refresh and Settings; Needs attention hiding every item shows the hidden count. README: the hero block.
  - Base: main
  - Branch: todo/queue-error-empty-states-say-what-do-nex at /Users/andyhite/Code/tern-plotroom.todo/queue-error-empty-states-say-what-do-nex
  - Decision: The hidden-count text shows only when the filter hides every item in the snapshot: "N pull requests hidden by Needs attention only; press <key> to show them.", or the palette row name when no key is bound; snoozing reads the same way.
  - Decision: The README hero footer reads `.  commands`; Settings and Refresh are already in the header.
  - Decision: The named Needs attention case is covered by the snooze case instead: the open selection stays listed under Needs attention, so that list never empties.

- [ ] Default prompts don't contradict themselves, agent toasts show the action's name, and ⌘⇧Z no longer undoes.
  - Review's "NEVER edit tracked files" exempts its step-1 `git pull --ff-only` sync, Quick review's read-only rule exempts its `git fetch`, and Plan lists an epic's children with `--paginate`.
  - The agent-start toast's second line is the action's name, or nothing for a typed prompt, instead of the whole filled prompt.
  - ⌘⇧Z (Ctrl⇧Z) in a text field does nothing instead of undoing; there is still no redo.
  - Touch points: Review, Quick review and Plan in `prompts.luau`; the start toasts in `window.luau`; the undo key in `input.luau`.
  - Cases: `tests/cases/window.luau` toast detail; `tests/check.luau` undo ignores shift; the cases pinning default prompt names and text (`tests/cases/issues.luau` ~1320-1354, `tests/cases/window.luau` ~158, ~176) assert behavior instead of wording.
  - Base: main
  - Branch: todo/default-prompts-don-contradict-themselve at /Users/andyhite/Code/tern-plotroom.todo/default-prompts-don-contradict-themselve
  - Decision: A typed prompt is told apart by `job.id == nil`, since the typed path sets `name = "Typed prompt"`.
  - Decision: The prompt cases read names and text from `prompts.luau`'s exported defaults; the window case loops over them and checks cwd, filled branch/repo and no leftover `{`.

- [ ] Every action I can save also exports, imports and runs.
  - Export keeps an action whose shortcut is any single visible character, non-ASCII such as `é` included, by the same rule Settings applies; import accepts it unless the queue already uses that key.
  - Settings refuses an action name over 120 characters with a message, matching the export limit and the palette's clip.
  - Import checks an action's model by the same rule as Settings and the window; an invalid model leaves that action out with a note instead of saving an action that can never start.
  - `portable` takes the reserved keys as a parameter instead of a module global.
  - Touch points: key, name and model checks and `reservedKeys` in `portable.luau` (shared rules passed in through its `Ok` table, since it requires nothing); key shape in `keys.luau`; `worktree.validModel`; the name row in `host/settings.luau`; `reserve` in `host/requests.luau`.
  - Cases: `tests/portable_check.luau` round-trips an `é` key and leaves out a 121-character name and the model `a b`; a Settings name-cap case. README: export and import.
  - Base: main
  - Branch: todo/every-action-can-save-also-exports-impor at /Users/andyhite/Code/tern-plotroom.todo/every-action-can-save-also-exports-impor
  - Decision: The key shape rule (one UTF-8 character, no whitespace) is duplicated in `portable.checkPrompt` rather than passed through `Ok`, because `build`/`parse` take no `Ok`; the model rule is passed as `Ok.modelValid` (= `worktree.validModel`) and checked in `apply`.
  - Decision: `portable.NAME_CAP` is public and Settings uses it: "A name is at most 120 characters."
  - Decision: `plan(doc, existing, reserved)` and `ok.reserved` replace the `portable.reservedKeys` global; `requests.reserve()` returns a fresh table.

- [ ] The Worktrees list shows every repository's worktrees when two repositories share a checkout, and two PRs never share one local branch.
  - A checkout saved for two repositories (a fork and its upstream) is listed once per path; each row takes the repository its note names, so the second repository's worktrees no longer show as Unnoted.
  - Checking out a PR whose local branch is already noted for another PR (a same-repository head `alice/x` vs alice's fork branch `x`) is refused with a message naming both PRs; nothing is reused or moved.
  - README gives the push command for fork PR worktrees (`git push <fork remote> HEAD:<branch>`), whose local branch name differs from the fork's.
  - Board dead code goes: `M.detail`, `Row.checking`, `select`'s `refresh` parameter, the never-hit `rel.key` branch, the always-true `showMain`, and the dropped problem argument of `Api.dirty`.
  - Touch points: `load`, `rows` and `select` in `board.luau`; `prBranch`, `reconcile` and `checkoutPr` in `worktree.luau`; board row ids (`repo\0path`) and `engine.boardId`.
  - Cases: `tests/cases/worktree.luau` a shared checkout lists both repositories' notes and a branch collision is refused; `tests/board_check.luau` updated. README: the fork PR line under Worktrees.
  - Base: main
  - Branch: todo/worktrees-list-shows-every-repository-wo at /Users/andyhite/Code/tern-plotroom.todo/worktrees-list-shows-every-repository-wo
  - Decision: A shared checkout is read once per saved repository with that repository's notes; each row goes to the repository its note names, else to the path's first repository in sorted order. `Entry.repo` carries the note's repository.
  - Decision: The branch-collision check is in `checkoutPr`, reading `plotroompr`/`plotroomrepo` with one `git config --local --get-regexp`; a note with no repository counts as the current one.
  - Decision: With `rel.key` gone, a PR's related Jira key no longer fills the issue (`Info.related` is `{ number: number? }`); without `select`'s `refresh`, a finished preview is not re-read on a plain re-select.

- [ ] Removing a worktree takes one safe path, and its confirm says exactly what happens to the branch.
  - The worktree card's Remove goes through `removeEntry`, as the Worktrees list does: it re-reads the claim first and keeps a branch Plotroom never noted.
  - The `inventoryDirty` pre-check goes: `git worktree remove` without `--force` already refuses a worktree with changes, and that refusal is reported as today.
  - The confirm text comes from the row's facts: a noted PR or issue branch goes only if git confirms nothing is lost, an unnoted or inferred branch is kept, a detached worktree has no branch.
  - The three "worktree remove, then parse modified or untracked" copies in `worktree.luau` become one.
  - Touch points: `removeEntry`, `remove`, `claim` and `inventoryDirty` in `worktree.luau`; removal in `board.luau`; the card removal in `host.luau` (its note gains `repo`, from `jiraReposOf` for Jira); the remove overlays in `host/render.luau`; the runtime op in `tests/runtime.luau`.
  - Cases: `tests/cases/mutation.luau` removeEntry (the inventoryDirty cases go), `tests/cases/checks.luau` card removal order, the `tests/board_check.luau` fake, the `scripts/smoke.py` removal scenario. README: Remove worktree.
  - Base: main
  - Branch: todo/removing-worktree-takes-one-safe-path-co at /Users/andyhite/Code/tern-plotroom.todo/removing-worktree-takes-one-safe-path-co
  - Decision: The card confirm reads git's worktree list when Remove is pressed and takes its text from `board.fate` (via `State.removeFate`), showing "Reading its branch from git…" meanwhile.
  - Decision: A card whose worktree went detached since the card was made says "Git no longer lists this worktree."; "It has no branch." shows in the Worktrees list.
  - Decision: `Note` and `Report` gain `repo`: PR `repo` or issue `code`, and for scan-created Jira notes the `jiraReposOf` code whose checkout is the root; a Jira note with no match has none.

- [ ] Close/reopen, ready/draft and an account switch between plan and commit are covered by tests, and tests stop pinning incidental copy.
  - Host cases for issue close and reopen and PR ready and draft check the committed argv per action (`--undo` only for draft) and the refusal when the item is already in that state.
  - A case plans a mutation, switches gh's active account, commits within 5 minutes, and asserts the planned login and its token are used.
  - Cases pinning incidental copy assert behavior instead: Settings section and row ids and hints (`tests/cases/issues.luau` ~1404-1427), sort labels already asserted as toasts (`tests/check.luau` ~371), the acli startup request count (`issues.luau` ~798; count `view` calls), and the full fact order (`issues.luau` ~803; check the one missing fact).
  - Duplicated fixtures collapse: `issueHost`/`jiraHost` reuse `asks.bk.repo`, `jiraWindow` reuses `issueWindow` with a host parameter, and `queue.luau`'s four clone setups use `cloneScene`.
  - Test-only: no plugin source changes.
  - Touch points: `tests/cases/issues.luau`, `tests/cases/queue.luau`, `tests/harness.luau`, `tests/check.luau`; the code under test is close/reopen/ready/draft in `host/requests.luau` and `github.setIssueState`/`setPrReady`.
  - Base: main
  - Branch: todo/close-reopen-ready-draft-account-switch at /Users/andyhite/Code/tern-plotroom.todo/close-reopen-ready-draft-account-switch
  - Decision: Close/reopen, ready/draft and account-switch cases live in `tests/cases/flows.luau`.
  - Decision: `issueWindow` takes an optional host (`jiraWindow` = `issueWindow(w, jiraHost)`); `asks`/`asks.bk.repo` moved above `hostScene` in the harness; `cloneScene`/`slowClone` return the scene.

- [ ] GitHub calls spawn fewer processes, and `github.luau` keeps one search parser, one account rule and one guarded write path.
  - `M.gh` reuses a login's token for up to 60 s in memory and drops it on any `auth` problem; tokens are still never written to disk, and a failed token read still sends nothing.
  - An empty or missing account is normalized once inside `M.gh`; the eleven per-function copies and the never-produced `account` problem kind go.
  - Refresh keeps the login-shell PATH found earlier and clears only failed lookups; a spawn that fails under that PATH probes the login shell once more, so a newly installed CLI is still found.
  - One search-page parser with the normalizer passed in replaces `parsePage` and `parseIssuePage`, `tracker.reconcile` replaces `github.reconcile`, `rerunFailed` goes through `guarded`, and the unread `rateLimit { cost }` fields leave the checks and issue-detail queries.
  - Touch points: `M.gh`, the parsers and `rerunFailed` in `github.luau`; `tracker.reconcile`; `reset`/`run` in `process.luau`.
  - Cases: `tests/cases/tracker.luau` a second call within 60 s spawns no `gh auth token` and an `auth` reply clears it; a `process` reset keeps the recovered PATH; `tests/check.luau` parser names; `tests/cases/mutation.luau` rerun unchanged. README Trust and Finer points › Accounts: tokens are kept in memory up to 60 s.
  - Decided: gh tokens are cached in memory for 60 s per login.
  - Base: main
  - Branch: todo/github-calls-spawn-fewer-processes-githu at /Users/andyhite/Code/tern-plotroom.todo/github-calls-spawn-fewer-processes-githu
  - Decision: The token cache is keyed by lowercased login, in memory only, 60 s TTL.
  - Decision: `tracker.reconcile` is generic (keyed on `.key`/`.updated`); `parsePage(stdout, normalize)` takes `github.normalize` or `github.normalizeIssue`, and `searchAll` takes the normalizer.
  - Decision: A spawn failing under the kept PATH clears it and re-probes the login shell; same PATH or a failed probe restores the old PATH and reports the spawn error, otherwise it retries once.
  - Decision: `rerunFailed` goes through `guarded`, which checks the run URL against the repo more strictly.

- [ ] The Worktrees and Agents lists take Home and End like the queue, and Settings edits go through shared helpers.
  - Home and End jump to the first and last row of the Worktrees list and the Agents list, as in the queue, and are ignored while searching.
  - The two list key handlers in `host.luau` become one helper taking the move, Enter and extra-action functions.
  - The eight edit-one-action copies (`kindAndId` → `editPrompts` → `promptById` → deleted elsewhere) and the four Edit/Done summary rows in `host/settings.luau` become one local helper each.
  - The checkout-claim flow of `host/requests.luau` and `host/settings.luau` becomes one engine helper, and `itemId`/`boardId`/`agentId` become one id builder with byte-identical output.
  - Nothing else changes for the user: picker ids, Settings rows and messages stay the same.
  - Cases: Home/End on the Worktrees list (`tests/cases/flows.luau` board cases) and the Agents list (`tests/cases/checks.luau`); existing Settings and claim cases pass unchanged.
  - Base: main
  - Branch: todo/worktrees-agents-lists-take-home-end-lik at /Users/andyhite/Code/tern-plotroom.todo/worktrees-agents-lists-take-home-end-lik
  - Decision: Neither the Worktrees nor the Agents list has a search box, so there is no search guard for Home/End.
  - Decision: Helpers: `listKeys(move, enter, extra)` (host), `editPrompt(qid, fn, quiet?)` and `summary(prefix, id, label, hint)` (settings), `engine.claimCheckout(state, repo, path, busy, moved, done)`, `engine.pickerId(prefix, key)`; the claim messages that differ are passed in so they stay byte-identical.
  - Decision: `pnext` and `pwhere`/`psplit` with a malformed prompt id now say "That action was deleted elsewhere."; sheet rows never produce such an id.

- [ ] CI and tooling: a credential-free checkout, a plugin version that tracks the protocol, an SDK drift warning, and Luau 0.743.
  - The CI checkout step sets `persist-credentials: false`.
  - `plugin.toml`'s version minor equals `RPC_PROTOCOL` (`0.22.0` while the protocol is 22), and `check.py` fails when they differ, so `tern plugin list` tells two hosts' builds apart.
  - Smoke generates the installed Tern's SDK types and shows a WARN row in the summary when their sha256 differs from the pinned snapshot; the gate does not fail on it.
  - Luau is pinned to 0.743 with GitHub's published asset digests (luau-lsp 1.70.1 is already the latest), and the workflow step name stops repeating tool versions.
  - `smoke.py` reuses `Smoke.cd` and `wait_until` instead of its copies, and `check.py` appends the NOT RUN row after the stage loop instead of re-sorting.
  - Touch points: `.github/workflows/check.yml`, `scripts/check.py` (tool pins, summary, version gate), `scripts/smoke.py`, `plugin/plugin.toml`, AGENTS.md (pins and the version rule), README's remote-host paragraph.
  - Base: main
  - Branch: todo/ci-tooling-credential-free-checkout-plug at /Users/andyhite/Code/tern-plotroom.todo/ci-tooling-credential-free-checkout-plug
  - Decision: `plugin.toml` is `0.23.0`, since `RPC_PROTOCOL` is "23" on this base; the gate reads the protocol from `core.luau`.
  - Decision: The version gate is its own `version` row in the `all` and `test` commands, needing neither Tern nor the lock.
  - Decision: `smoke.py` exposes `WARNINGS`; `check.py` turns each into a `smoke … WARN` row after the stage loop and never fails on it. The WARN path itself was not exercised (installed Tern 0.9.5's types matched the pin).

- [ ] A status-bar segment shows how many of my agents need input and jumps to the first one.
  - While any linked agent is in `waiting_input`, every pane's status line shows "N agents need input"; clicking it focuses the first waiting agent's pane, as Go to agent does.
  - Each agent that enters `waiting_input` gets one toast naming its item and action; staying there toasts nothing more.
  - The count covers the agents the Agents list covers, rides the existing 4 s status sync, and clears as soon as none waits.
  - The protocol-mismatch warning and the new segment come from one `tern.chrome.status` formatter, refreshed only when either changes; tab colors are never touched.
  - Touch points: the status formatter and `checkProtocol` in `window.luau`; `agentStates`/`agentSync` in `flows.luau`; a new `tern.command` for the jump.
  - Cases (`tests/cases/flows.luau`): the count appears and clears, a click focuses the first waiting pane, one toast per entry, the mismatch warning still shows. README: Triage, agents and commands.
  - Base: main
  - Branch: todo/status-bar-segment-shows-how-many-agents at /Users/andyhite/Code/tern-plotroom.todo/status-bar-segment-shows-how-many-agents
  - Decision: Segment reads "1 agent needs input" / "N agents need input"; the first waiting agent is the lowest pane number; the click runs the new `agents-waiting` command.
  - Decision: Count and toasts are computed in `agentSync`; an agent already waiting at load toasts once at its first sync, and again only after leaving and re-entering `waiting_input`. The toast reads "o/r#5 needs input" with the action as subtitle.
  - Decision: `trackWaiting` calls `tern.chrome.refresh()` only when the waiting set changes; with no Plotroom pane `agentSync` clears the count.

- [ ] Merge, approve, request changes and update a PR's branch from Plotroom.
  - The palette's GitHub - PR group gains Merge…, Approve…, Request changes… and Update branch…; each is plan-then-commit with Cancel first, names the PR and account, and captures the gh login at plan time.
  - Merge offers the methods the repository allows (squash, merge, rebase), plus "Auto-merge when checks pass" while checks are pending; the commit is bound to the planned head commit, so a push after planning refuses it.
  - Merge never deletes the branch (a worktree may sit on it) and never uses admin override.
  - Request changes requires a comment and Approve takes an optional one, each shown in full in the confirm and refused when it can't fit, as comments are; Update branch is offered only while the preview shows the branch behind its base, using GitHub's default merge update.
  - Touch points: `COMMANDS` and `planAct` in `flows.luau`; act dispatch and the plan/commit guards in `host/requests.luau`; new writes on `guarded` beside `setPrReady` in `github.luau`; new act names, so bump `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` together.
  - Cases: `tests/cases/issues.luau` argv per command, methods from repository settings, auto-merge only with pending checks, no branch deletion, a moved head refused; `tests/cases/flows.luau` Cancel-first plans and palette groups. README: What it does and the Trust list of confirmed writes.
  - Decided: Merge offers the repository's allowed methods plus auto-merge while checks are pending; it never passes `--delete-branch` or `--admin`.
  - Base: main
  - Branch: todo/merge-approve-request-changes-update-pr at /Users/andyhite/Code/tern-plotroom.todo/merge-approve-request-changes-update-pr
  - Decision: Auto-merge is a per-method picker row ("Auto-merge when checks pass", method as detail), since `gh pr merge --auto` needs a method.
  - Decision: Merge runs `gh pr merge <n> --repo … <--squash|--merge|--rebase> [--auto] --match-head-commit <planned sha>`, and the host re-reads `headRefOid` at commit; allowed methods come from `gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`, read at the list and plan steps.
  - Decision: Merge is offered for open non-draft PRs with a known head sha; Approve/Request changes for any open PR; Update branch only while the preview's `about.merge` is `behind`, re-checked live as `BEHIND` at commit.
  - Decision: Comment, Approve and Request changes share `requests.previewRows`.
  - Decision: `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` are now "24".

- [ ] The Agents list shows what each agent last said, why a prompt wasn't delivered, and how its last run ended.
  - Each Agents row and its preview show the agent's last message, cut to 200 bytes, and its delivery error when there is one, both read from the `agents:list` call the status sync already makes.
  - When an agent's turn ends, its result (done, failed, exited, closed) and time are saved on its `agent-links` entry and shown on its row ("Review: done 14:02"); exited agents stay hidden as today.
  - An `agent-links` row whose new fields aren't strings counts as malformed, so the store is never written over; older links without them still show.
  - The status map carries the new texts within its 30000-byte cap and the host's 40000-byte limit; bump `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` together.
  - Touch points: `agentStates`, `statusMap`, the link record and `writeLinks` in `flows.luau`; `agent_finished` in `window.luau`; `agentStatus`, `INFO_CAPS` and `agentRows` in `host/engine.luau`; Agents rows, preview and `agentSig` in `host/render.luau`.
  - Cases (`tests/cases/flows.luau`): the last message is cut, a delivery error shows, a result survives a reload, a malformed link is not written over. README: the Agents list and the Trust list of kv contents.
  - Base: main
  - Branch: todo/agents-list-shows-what-each-agent-last-s at /Users/andyhite/Code/tern-plotroom.todo/agents-list-shows-what-each-agent-last-s
  - Decision: New link fields `result` (done/failed/exited/closed) and `ended` (`HH:MM`), both strings; a link keeps its last result until the next turn ends.
  - Decision: `agentStates` returns per-pane notes (last message, delivery error, cut to 200 bytes) from `cx.agents:list`, never saved on the link.
  - Decision: A row reads "Action: result time · branch · error · last message"; the preview adds Last run, Last message and Not delivered facts.
  - Decision: `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` are now "24".

- [ ] Paste a GitHub or Jira URL into the queue to open it, copy an item's link, number or branch, and see new counts in the pane title.
  - Pasting into the queue outside search opens the first GitHub PR/issue or Jira issue URL in the text as Open item by URL does (fetched, then pinned); text without one gets a toast; a paste during search still edits the search.
  - The palette offers Copy link, Copy number (`#N` or the Jira key) and, when the item has a head or worktree branch, Copy branch for the selected item.
  - The pane title adds the attention count when it isn't zero: "Plotroom · My PRs (12) · 3 new".
  - Touch points: paste handling and the `title` handler in `host.luau`; `openUrl` in `host/requests.luau`, split so a paste answers with a toast instead of an rpc reply; palette rows in `host/requests.luau`; `cx:copy`.
  - Cases (`tests/cases/queue.luau`): a paste opens and pins, a paste without a URL toasts, a paste during search edits the query, each copy row copies its text, the title shows "· 3 new". README: Keys and the command palette, Open item by URL.
  - Base: main
  - Branch: todo/paste-github-jira-url-into-queue-open-co at /Users/andyhite/Code/tern-plotroom.todo/paste-github-jira-url-into-queue-open-co
  - Decision: `openUrl` takes `done(problem?, message?)`: the rpc op replies through it and a paste toasts through it; rpc replies and the protocol are unchanged.
  - Decision: Copy number gives `#N` for GitHub and the key for Jira; Copy branch uses the PR's `head`, else the worktree note's branch.
  - Decision: "N new" counts `engine.needs` items (new or changed and not snoozed, or an agent waiting); the selected item is marked seen so it drops out.
  - Decision: Pasted URLs are found by regex, trailing `.,;:!?)]}` stripped, and the first one `engine.pinView` accepts is used.

## Done

- [x] Plotroom never checks out a fork's pull request for an issue unless I pick it.
  - Worktree, and any action that runs in an issue's worktree, auto-pick a linked pull request only when it is the single live same-repository one; a fork's (cross-repository) PR is never picked automatically.
  - Fork PRs still appear in the "Which branch" choice, marked as forks with their owner, beside same-repository PRs and New branch…; an issue whose only live linked PR is a fork shows that choice and fetches nothing.
  - A PR from a deleted fork counts as a fork, owned by its author, as `github.pr` already treats it.
  - Touch points: `github.linkedPrs` (`PR_LINK`/`PR_LINK_JQ` gain `isCrossRepository` and the head owner; `LinkedPr` gains `fork`), `undecided()` in `host/requests.luau`, the `choosePr` rows in `window.luau`.
  - The `choosePr` reply gains a field: bump `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` together.
  - Cases: `tests/cases/tracker.luau` linkedPrs keeps the fork flag; `tests/cases/issues.luau` fork + same-repo auto-picks the same-repo PR, fork only shows the choice. README: the issue-worktree bullet under Worktrees.
  - Decision: The fork owner is clipped to 100 characters in the `choosePr` rows, like titles are clipped to 160.
  - Decision: A fork row in the picker shows the detail "Fork of <owner> · <branch>"; same-repository rows still show the branch.
  - Decision: `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` are now "23".

- [x] An issue action's Next action can be a PR action, so Implement can chain into Watch.
  - Settings › Actions › Next action on an issue action also offers the PR actions, labelled by kind; PR actions still offer only PR actions.
  - Issue agent finishes `done` with a PR next action → look up the PR whose head is the issue worktree's branch in the issue's code repository (`github.pullByHead`, open or draft only), then run the PR action on it as a manual run would: same worktree (reused by branch), the tab the agent ran in, PR variables from the fresh PR read.
  - No open/draft PR on the branch, a failed lookup, or an issue action that ran in the main checkout (no branch) → the chain stops with a toast naming why; nothing starts.
  - Storage: a cross-kind `next` is stored qualified (`prs:<id>`); a bare id stays same-kind, so existing `prompts-*` stores stay valid. `storage.chainReaches`, deleting an action (clears it as anyone's next, in both stores) and export/import (`portable` drops another kind's next today) handle the qualified form.
  - Touch points: `advanceChain`/`prepareTarget` (window), `flows` `Chain` (needs the code repo and branch: a Jira chain's `repo` is the project key), the host `action` rpc or a head-lookup op (requests), settings `pnext` options. Bump `RPC_PROTOCOL` and `PROTOCOL` together; never write over a malformed `agent-links`.
  - Cases: issue → PR chain starts on the found PR in the same worktree; no PR / merged only → toast, nothing starts; Settings offers PR actions on the issue side only; qualified next survives export/import and delete. README: Next action bullet in the actions section.
  - Decided: issue → PR only; PR actions cannot chain into issue actions.
  - Decided: the PR is the open or draft one on the worktree branch; merged/closed only → the chain stops.
  - Decided: the next action gets only its own kind's variables; issue variables are not carried over.
  - Decided: `agent-links` chain records also keep optional `code` (code repo) and `branch`; issue rpc replies carry `code`, so a Jira chain no longer leans on its project key. Old links stay valid.
  - Decided: the `action` rpc takes optional `repo`/`branch` and runs `github.pullByHead` itself, replying with `pr` or a `problem` (lookup failed, no PR, merged/closed only); no separate head-lookup op. The hop reuses `prepareTarget`'s PR path.
  - Decided: `storage.nextOf(kind, next)` resolves a next; `chainReaches` is unchanged (a qualified next ends the walk). Deleting a PR action clears `prs:<id>` in the issues store, leaving an unreadable store untouched. PR options on issue actions are labelled `<name> (pull request)`.
  - Decided: `RPC_PROTOCOL`, `PROTOCOL` and harness `asks.protocol` are now "22".
  - Decided: `github.pullByHead` skips cross-repository (fork) PRs for every caller, so the Worktrees board/preview head lookup ignores fork PRs too.

- [x] Actions can move a Jira issue to a set status when they run.
  - Add an optional `status` (target status name) to issue-side actions. Settings › Actions gets a "Move to status" text row on the issues side only. Carry it through `Prompt` (core), the `prompts-*` validator and save (storage), export/import (portable `checkPrompt`/`samePrompt`) and the action menu entries (requests).
  - When the agent starts (worktree ready), for a Jira issue only: list its transitions (`jira.transitions`), take the first whose target status matches `status` (case-insensitive), post it (`jira.transition`). No confirm; a toast reports the move.
  - Already in that status → nothing. No matching transition, a transition that needs fields, or no `PLOTROOM_JIRA_API_TOKEN` → error toast naming why, nothing posted. The agent runs either way.
  - GitHub issues and PR actions have no such field.
  - The window asks the host for the move (the token lives in the host env). Bump `RPC_PROTOCOL` and `PROTOCOL` together if the rpc shape changes.
  - Cases: match, no match, already there, no token, export/import round-trip. README: actions section.

- [x] Show both the PR and the issue in the preview when an item's worktree has both.
  - Queue, issue selected: when its worktree's branch is the head of a GitHub PR in the code repo (`gh pr list --head <branch> --state all`), show a Pull request section (number, title, state, link). Skip it when GitHub's linked list already has that PR.
  - Queue, PR selected: when its head branch is a worktree branch noted with an issue (`branch.<b>.plotroomkey`), show an Issue section (key, title, status, link).
  - Worktrees board: a row with an issue `key` but no PR `number` and no tracker `related` looks the PR up by head branch the same way, so a PR the implement agent opened shows. Update `board.select`'s "branch text never does" comment: a head-ref match is GitHub's answer, not a guess.
  - Lookups ride the existing detail loads (debounce, `alive`/`gen` guards); no new polling.
  - Cases: `board_check` enrich by head, one host case per queue preview. README: preview section.
  - Decided: several PRs on one head branch show the open one (else the newest); the lookup matches the branch name only, so a fork's PR of the same name can show.
  - Decided: the issue side uses the worktree note the scan had when the detail loaded; a refresh loads it again. The PR side lists the saved checkout with `inventory` (adds a `git worktree list` per PR detail load; two existing list-count cases now expect it).
  - Decided: a failed lookup shows nothing (no error row); the Worktrees board shows the PR section only when one is found, never "not found".

- [x] Clicking a view in the sidebar always refreshes it.
  - Clicking a view refreshes it even when its cached snapshot is younger than the refresh interval, and clicking the already-active view refreshes it too (also from the Worktrees board back to the queue). The periodic timer is unchanged.
  - Gaps: `switchView` skips the refresh when `age < fresh`; `goScope` does nothing for the active scope with the board off.
  - Unchanged: `refresh` still dedupes in-flight requests for the same `gen`, honors the server rate-limit cooldown and does not retry terminal problems (`auth`, `missing`, `not-found`). A click while another view loads refreshes the new view; the old reply is dropped by the `gen` guard.
  - Touch points: `engine.switchView` (~`:997`), `engine.goScope` (~`:1311`); mirror the `engine.retry` path.
  - Cases: switch to a fresh cached view issues a search, click on the active view issues a search, click inside the cooldown does not. README: refresh section.
  - Decided: `switchView` now always calls `changed` (so other callers like pin, settings and reload refresh too). `goScope` on the active view calls `refresh` and keeps the selection.

- [x] Jira items and status groups always order by status category: in progress, then to do, then done.
  - Items and `status` groups sort by category first, whatever the sort. A saved `priority` sort now means priority within each category, so existing views reorder. Done shows only when the filter includes it.
  - Status groups: category, then status name within a category (not first appearance), so groups do not jump between refreshes.
  - Gap today: only the default order and grouping are category-ordered, through `tracker.byStatus` running before `sorting.apply`; `sorting.apply` (`priority`) ignores category, and group labels depend on that pre-sort.
  - Touch points: `sorting.apply`/`rank` (take the category), the `sorting.apply` call and group labels in `engine` (~`:414-469`), the Jira `status` group in `core`. GitHub issues and PRs unchanged.
  - Cases: `check.luau` priority sort with categories, `issues.luau` grouped Jira view with a `priority` sort (Done never above In Progress; two To Do statuses ordered by name). README: sorting and grouping; update the `sorting.luau` header comment.
  - Decided: `sorting.apply` takes an optional category-rank function, which the engine passes only for Jira issue views, so GitHub is unchanged.
  - Decided: the Jira `status` group gets a `rank` field (`tracker.categoryRank`) in place of `keep`. Groups sort by category, then by lowercase status name. GitHub's `state` group keeps `keep`.

- [x] Actions can name a next action that starts automatically when the agent finishes.
  - Add an optional `next` (another action of the same kind) to `Prompt`: a "Next action" row in Settings › Actions, carried through the `prompts-*` validator and save (storage) and export/import (portable `ref` remap; a `next` pointing at a deleted action is dropped).
  - On `agent_finished` with result `done` (handler in `window.luau`, today only `agentSync`), start the next action for the same item in a new pane in the same tab, same worktree. `failed`, `exited` and `closed` stop the chain, with a toast naming why.
  - Every agent pane is named after the action it ran, so panes in a tab can be told apart.
  - Needs the finished pane mapped back to item and action: `recordAgent` keeps only one link per key and host today, so it must keep the chained agents (record action id on `Link`, without writing over a malformed `agent-links`).
  - Cycles (A → B → A) are rejected in Settings; chain depth is capped. A pane finishing while a prompt waits does not fire `agent_finished`, so it does not advance.
  - Bump `RPC_PROTOCOL` and `PROTOCOL` together if the status map or an rpc shape changes. No confirm step, like the first action.
  - Cases: chain advances on done, stops on failed, cycle rejected, deleted next dropped, export/import round-trip, pane name. README: actions section.
  - Decided: Tern 0.8.3 has no API to name a pane (only tabs), so Go to agent lists each agent as "<action name> · pane N", read from the link's recorded action name.
  - Decided: `recordAgent` keeps every earlier link that carries a chain, so each pane maps back to its action. `takeChain` clears the link's `next` before advancing, so a later turn of the same agent starts nothing.
  - Decided: chain cap is 8 actions. A next action deleted at runtime gives an error toast and nothing starts. Deleting an action in Settings clears it as anyone's next.

- [x] An Agents entry in the sidebar lists my live agents and what each is working on.
  - A special scope after Worktrees list, like it with no view record: rows for agents that are `working`, `waiting_input` or `idle`; `exited` ones are hidden. Each row shows the item title, the action name, the branch and the state badge, grouped by repository. The count shows in the sidebar; it is in the palette's Views group too.
  - Enter goes to the agent's tab (`flows.goAgent`). The `agentgo` link only parses `owner/repo/number` today, so extend it to Jira keys.
  - Persist action name, branch and title on `Link` (`agent-links`, `recordAgent` call in `window.luau`) and send them with the status map, so rows need no loaded view. Old links without them show key and state only.
  - Bump `RPC_PROTOCOL` and `PROTOCOL` together (the status map shape changes). Update `agentSig` and `engine.agentStatus` validation (size and key caps stay). Never write over a malformed `agent-links`.
  - No new polling: rows ride the 4 s status sync. Host state goes in `core`, glue in `engine`, rows in `render` (mirror `boardOn`/`scopeRows`/`boardProps`).
  - Cases: rows by state, exited hidden, old link, Jira go-to. README: Agents and sidebar sections.
  - Decided: the `agentgo` link needed no window change. For Jira, the host builds `plotroom://issue/agentgo/<PROJECT>/<KEY>` with the project upper-cased, which the window's issue branch already accepts.
  - Decided: the status map is now `key -> {state, action?, branch?, title?}`. Exited agents carry no texts, and texts stop at 30000 JSON-encoded bytes (`statusMap` counts the escaped size) so the report stays under the host's 40000-byte cap.
  - Decided: an `agent-links` row whose action, branch or title is not a string counts as malformed, so the store is never written over.
  - Decided: rebased onto main with the next-action chain work; `recordAgent` takes `(…, chain, info)` and `finishAgent` takes `info` last. A click on the active view clears both `boardOn` and `agentsOn` and refreshes.
  - Decided: `RPC_PROTOCOL`, `PROTOCOL` and the harness's `asks.protocol` are now "21" (main is "20").
