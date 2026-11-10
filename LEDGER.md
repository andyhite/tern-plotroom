# Plotroom feature ledger

Every feature, command, setting and surface, mapped to the loop step it serves ([PRODUCT.md › The loop](PRODUCT.md#the-loop)), with a verdict and the phase that acts on it. A new feature starts here as a row before any code is written.

**Verdicts**
- **Keep:** stays as it is, apart from glossary and copy fixes (Phase 1).
- **Merge:** folds into the named feature, which takes over its job.
- **Hide:** the behavior stays, but leaves the named surface.
- **Cut:** removed, together with its code, tests, docs, settings and export fields.
- **Review:** decided after two weeks of usage data from the Phase 0 report.
- **New:** planned.

**Status:** *Approved* rows are settled; the author approved every verdict on 2026-11-02. A *Proposed* row would wait for the author's decision and not be acted on.

## Intake

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Views: GitHub search or JQL, grouped by login | Sidebar, Settings › Views | Keep | — | Approved | The core of intake |
| Default views (My PRs, Review requested, Assigned to me, Created by me, My sprint, Up for grabs, My epics) | First run, Settings › Views | Keep | — | Approved | Trimmed from 14 to 7 on 2026-10-30 |
| Restore defaults | Settings › Views, Settings › Actions | Keep, renamed **Add missing defaults** | 1 | Approved | It never overwrites edited defaults, and the current label implies it does |
| Pins: Open item by URL, pasting a URL | Commands, Tern's palette, paste in the queue | Keep | — | Approved | Intake of one-off items |
| Refresh after your own commands: `git push`, `gh pr`, `gh issue` or `gh run` succeeding in any shell refreshes every queue at once, within the cooldown | Engine (shell hook) | New | — | Approved | tern-plotroom#bgvj: what you just did in a shell shows in the queue without waiting for the timer |
| Linked pull requests and issues | Preview | Keep | — | Approved | Navigation between the halves of one piece of work |
| Inbox (GitHub notifications) and Mark read | Sidebar | Merge into **Now** | 2 | Approved | One of the six partial answers to "what needs me". Done: Now lists the notifications and offers Mark all notifications read… |
| Shell lens after `gh pr create` | Shell pane | Keep | — | Approved | Cheap intake of a just-created PR |
| Alt-click a GitHub pull request or issue link in any pane to show it in Plotroom | Any pane's links | New | — | Approved | tern-plotroom#cfd8: intake of an item met anywhere in the window without copying its URL; a plain click still opens the browser |
| Open Plotroom button in the Files pane | Files pane | Keep | — | Approved | Entry point |
| Plotroom: Open | Tern's palette | Keep | — | Approved | Entry point |

## Triage

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| New and Changed badges; seen is automatic | Queue rows | Keep | — | Approved | |
| Mark seen | Commands | Keep | — | Approved | |
| Snooze until 08:00 tomorrow; Show or hide snoozed; Unsnooze | Commands, preview | Keep | — | Approved | |
| Needs attention only filter | Commands | Merge into **Now** | 2 | Approved | Three names today, and a partial answer to "what needs me". Done: removed; Now lists New and Changed assigned items |
| Pane-title count and the `N need attention` status segment | Pane title, status bar | Merge into one **Now** count | 2 | Approved | Done: `N need you` in the status bar is the one count and a button (shows Now); the pane title and Now's heading split it by reason (`2 agents need you · 1 Blocked · 3 reviews requested`); no header number repeats the sidebar |
| Sort orders (Next sort order, sort per view) | Commands, Settings › Views | Keep | — | Approved | The order is announced by a toast when it changes; no `Sort:` line |
| Search | Search field, Commands | Keep | — | Approved | |
| Group by (repository, status, label) | Settings › Views | Keep | — | Approved | |
| Preview: description, facts, checks, merge state, reviewers, closing issues; one shared order and one loading / error / empty state for every variant | Preview | Keep | 2 | Approved | Done: docs/reference.md › Finer points › Preview; one home per fact (the row's In tab is the card's Go to tab) |
| Preview: worktree card (Up to date, Changes, unpushed count) | Preview | Keep | — | Approved | |
| Stage on every item, and the suggested next move | Rows, preview, Commands | New | 2 | Approved | PRODUCT.md › Glossary › Stage |
| Picker rows: one field per Triage question. Keep: title (what is it?), author mark (mine to land or theirs to review?), number or Jira key (which one?), repository only when the view spans several (which codebase?), a Blocked PR's chips, one per reason, and the first one's who or what (what stops it, and whose move?), stage (where does it stand?), agent state when the stage does not say it (is an agent on it?), outcome and checker verdict (did the run do what it claims?), New/Changed/Snoozed (has it changed since I looked?), Worktree (already started?), Draft (ready for review?), Jira status or closed reason (where in the team's workflow / done or dropped?), Jira type (bug or feature?). Cut to the preview: `@author` in the detail (the mark says it), age, review text, check counts, labels, In tab | Queue rows | Cut | 2 | Approved | Every field earns its place; no fact twice in a row (tern-plotroom#yxak) |
| Status chips: a Blocked PR shows one chip per reason, most severe first, each naming its job (Address changes, Reply · N unresolved, Fix checks · N/T failing or Re-run · likely flaky, Resolve conflicts); the first one's who or what follows its number; the preview lists every reason and the unresolved review threads (author, file:line, first line, link) | Queue rows, Now, preview | New | 2 | Approved | tern-plotroom#5va5, adopted from tern-pr-guide: one reason hid the others, and a state ("Changes requested") does not say whose move it is. Unresolved threads block a PR not yet approved |
| Now | Sidebar (default view), status bar | New | 2 | Approved | Replaces Inbox, the attention filter and the two counts; its heading says what needs you by reason |
| Now: which reasons and logins it lists | Settings › Views › Now | New | 2 | Approved | Switches per reason (Blocked, Review requested, Ready to merge, Notifications, Assigned), team review requests, per `gh` login and Jira; never the queries. A switch that is off is not read |
| Ignored checks: a named check per repository that does not make a PR Blocked | Commands (Ignore this check…), Settings › Repositories, preview | New | 2 | Approved | Adopted from tern-pr-guide (tern-plotroom#fkqe): a check that fails until someone acts (an approval check) otherwise keeps a PR Blocked and in Now. The check still shows failing, marked Ignored, and still keeps the PR out of Ready to merge |
| Review recency: "New commits since you approved" on a row; a dismissed review counts as review requested | Queue rows, Now, Next move | New | 2 | Approved | From GitHub each time (your latest review's commit vs the head; your dismissed review); nothing stored. Adopted from tern-pr-guide |
| Next in Now: one key walks Now from the most urgent item to the next; Now's heading reads `N left`, or `n of N` while walking | Queue key, Commands › Now, Now's heading | New | 2 | Approved | Unbound by default; the one-key set binds `n`. A hand move or a change of the list stops the walk, which resumes from the selected item. Adopted from tern-pr-guide (Next up bar) |
| Arrival ring: a row a refresh moves into Needs you or Blocked (or Ready to merge) from another stage is ringed in that stage's colour for about 1.4 s; one toast per refresh names the item and why | Queue rows, toast | New | 2 | Approved | tern-plotroom#pvat, adopted from tern-pr-guide: a row changing stage under you otherwise goes unnoticed. Not for your own mutation in this block; conflicts alone don't toast (they arrive in bursts); New and Changed are unchanged |
| Board: a view laid out in columns by stage (Needs you, Agent working, Waiting, Ready to merge; Not started and Worktree folded), chosen per view as List or Board | Queue, Settings › Views | New | 6 | Approved | A spike on Now comes first: keyboard movement, narrow panes and the 1000-item bench budget decide whether views get the choice. From tern-pr-guide's board |
| Summary at the top of the preview | Preview, Settings › General | New | 6 | Approved | Made on select by omp's `@smol` role with no tools, cached by item and head SHA or updated time. From tern-pr-guide's feedback summary |

## Dispatch

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Worktree: one key; the PR's head branch; an issue's branch from its linked PR or a chosen base | Commands, key, preview | Keep | — | Approved | The core of dispatch |
| Checkouts and cloning | Settings › Repositories | Keep, plus automatic detection | 1 | Approved | Today a required manual step before any agent can start |
| Setup commands | Settings › Repositories | Keep | — | Approved | |
| Name formats (branch and folder) | Settings › Worktrees | Merge into Settings › **Repositories** | 1 | Approved | A whole page for three fields |
| Actions and Type a prompt… | Commands, Settings › Actions | Keep | — | Approved | |
| Default actions (Review, Quick review, Address feedback, Watch, Implement, Fix, Plan) | Settings › Actions | Keep; outcomes added | 3 | Approved | Done: each names its default outcome, and sets Model, Opens in and Next action (Implement and Fix → Watch) |
| Action fields: Model, Runs in, Opens in, Move to status (acli), key | Settings › Actions | Keep | — | Approved | Defaults set Model and Opens in; none sets a key or Move to status |
| Action fields: Model picked from omp's models (omp's default, role aliases, models by provider, with search) and Effort | Settings › Actions | New | — | Approved | tern-plotroom#6fwm, adopted from tern-pr-guide: a model is chosen from what omp lists instead of typed; Effort passes `--thinking`. Falls back to the text field when omp cannot list models |
| Agent placement: each agent Beside the queue, or joining a worktree's tab, splits the largest pane of that tab along its longer side, never the queue's (the queue keeps its half) | Dispatch (Opens in) | New | — | Approved | Spike tern-plotroom#ajat: today each agent beside the queue halves the queue's pane again, so at 5 agents the queue and the two newest are 94 px slivers at Tern's minimum; this rule keeps the queue at 1097 px and no agent below 274×480 px. The author approved it on 2026-11-03 (tern-plotroom#jd78): each split halves the pane, alternating by its shape |
| Action field: Next action (chains) | Settings › Actions | Keep; advances only on a Verified outcome | 3 | Approved | Default Implement and Fix lead into Watch |
| Action field: Tell Carly when it finishes, and the `plotroom_agents` Carly export | Settings › Actions, Carly | Cut | 1 | Approved | Serves no loop step that Tern's agent notifications and Now don't cover; adds jargon |
| "An agent already works on it" guard | Commands | Keep | — | Approved | |
| Conflict pre-merge: before an agent resolves conflicts, Plotroom merges the base and regenerates known lockfiles, so only real conflicts reach the agent | Dispatch (worktree) | New | — | Approved | tern-plotroom#zhm2, adopted from tern-pr-guide: lockfile conflicts are mechanical and an agent burns a run on them |
| Checker actions, fixed end-of-run report, outcomes, three-strike limits | Settings › Actions, run log | New | 3 | Approved | PRODUCT.md › Roadmap › Phase 3. Done: the fixed end-of-run report, read into the run log and shown in Agents; outcomes per action, checked on GitHub into Verified, Not verified or Unchecked on the run log, the row, Agents and Now; checker actions (Checked by, the default Check) run by a fresh agent against the acceptance criteria saved at dispatch, Checked or Check failed on the run log, the row, Agents and Now; chains that advance only on a Verified run or a passing check, fix rounds with `{findings}`, and the three-strike limits (3 failed checks, 3 runs without progress, 3 failed starts) counted on the run log and shown in Now; Disagree with check… (Commands) on the run log, and checker agreement (agreed by merge or after 7 days, over the last 20 decided runs) in the usage report (Metrics row 6) |
| Plotroom's omp extension: every agent starts as `omp -e <plugin>/omp/plotroom.ts` with a run id, and its tool `plotroom_propose_review` writes a Draft review file | Dispatch, Land | New | 6 | Approved | tern-plotroom#9gef: the first step of the Draft review (the block is #hf2x, the prompts #qyt3). Done: the extension, the tool and its file, the command line, the toast when the extension is missing |
| Failing checks' log excerpts: `{failures}` for actions, and each failing check's first error line with its excerpt in a fold in the preview | Prompt variables, preview (Checks) | New | 2 | Approved | Dispatch (and Land): an agent starts with the failure in hand. GitHub Actions only (`gh run view --log-failed`), read once per check and head commit; no log viewer, the check's page is one click away. Adopted from tern-pr-guide |
| Autopilot | One opted-in view | New | 5 | Approved | Gated by PRODUCT.md › Metrics row 6 |
| Plotroom's omp extension: tools Plotroom's agents load with `-e`, starting with Propose a Draft review | Agents Plotroom starts | New | 6 | Approved | Agents hand structured work back instead of text Plotroom parses |
| Review and Quick review end in a Draft review; the agent posts only what you send back | Settings › Actions (default prompts) | New | 6 | Approved | PRODUCT.md › Principles 3 and 5. tern-plotroom#qyt3: the prompts propose with `plotroom_propose_review`, post the sent choices as one review after re-reading the head, and fall back to the ask without the extension |

## Supervise

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Agent state badges | Rows, preview | Keep | — | Approved | |
| Agents list | Sidebar | Keep | — | Approved | |
| Go to agent; Interrupt agent; Stop agent…; Message agent… | Commands, Tern's palette | Keep | — | Approved | |
| `N agents need input` status segment and its toast | Status bar | Keep; its count joins the Now count | 2 | Approved | |
| Message an agent with the selection… | Tern's palette | Keep | — | Approved | Sends context to an agent from any pane |
| Send a Browser page element to an agent… | Commands, Tern's palette | Cut | 1 | Approved | Rarely in the loop; refused on remote hosts |
| Worktree tabs named after their item | Tab bar | Keep | — | Approved | |
| Worktree tab names survive a plugin reload: kept in kv `tab-labels` (newest 50), read at load, a closed tab's name dropped when a tab closes | Tab bar | New | — | Approved | Tern's Lifecycle and Reload: window state that must survive a reload belongs in kv; restored tabs kept losing their `#123 title`. tern-plotroom#vr4v |
| Paused-hook notice | Toast, status bar | Keep | — | Approved | |
| Run log and usage report | Commands › Configuration | New | 0 | Approved | Evidence for Review rows and for metrics 5 and 6 |
| Agent questions answered in Now | Now | New | 2 | Approved | Taken from CuLoRA's build loop. Done: a waiting agent's Now row shows its last message, with Reply… and Go to agent |
| A working agent's clock and estimated progress bar | Agents list, Now, previews | New | 2 | Approved | Elapsed m:ss; the bar eases toward the median of the action's finished runs in the run log (at least 5), never full before the run ends; redrawn once a second. Adopted from tern-pr-guide |
| End-of-run report as a `plotroom_report` tool call, read from the agent's transcript | Plotroom's omp extension, Agents, run log | New | 3 | Approved | PRODUCT.md › Principles 7. tern-plotroom#xzmc: the extension checks the report when the agent calls the tool, so a malformed one is refused and fixed by the agent instead of recorded as No report; the window reads the turn's last accepted call from `agents:transcript`, with no file and no rpc op. Replaces the fenced `plotroom-report` block |
| Worktree tab tinted while its agent needs input | Tab bar | New | 2 | Approved | tern-plotroom#dkwa: a tab Plotroom opened for a worktree takes your turn's colour (`cx.layout:color_tab`) while its agent waits for input, cleared when it works or finishes; a colour the user set is left alone |

## Land

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Merge… (including auto-merge); Approve…; Request changes…; Update branch… | Commands | Keep | — | Approved | The core of landing |
| Push empty commit… (a new head through GitHub's git database API, no checkout, so checks run again; open PR not behind and without conflicts, never a fork's branch) | Commands | New | — | Approved | tern-plotroom#bcd7, adopted from tern-pr-guide; Update branch… covers a branch behind its base |
| Review block: a Draft review on its diff beside the agent that proposed it; keep, edit or drop each comment, pick the verdict, Send to agent | Block beside the agent | New | 6 | Approved | From tern-pr-guide's review page; PRODUCT.md › Principles 5. tern-plotroom#hf2x: the second block (`review`, title Draft review), opened at a turn end on a newer Draft review file (rpc `review`), Copy when the agent is gone |
| Draft review layout: compact findings navigator and focused diff/feedback pane, with verdict and Send at the top; stacked layout in narrow panes | Draft review block | Keep | 6 | Approved | Refinement of the existing review block: make agent findings easy to inspect and edit without scrolling through repeated cards or losing the handoff controls |
| Ready for review…; Convert to draft… | Commands | Keep | — | Approved | |
| Draft PR… from an issue's worktree | Commands | Keep | — | Approved | |
| Comment…; Assign to me | Commands | Keep | — | Approved | |
| Close issue…; Reopen issue… | Commands | Keep | — | Approved | "Won't do" is a triage outcome |
| Re-run failed checks | Commands | Keep | — | Approved | |
| Likely flaky: a failing check that also fails on the base branch, or passed earlier on the same head commit, is marked so, and the Next move re-runs only when every failing check is | Preview checks, Blocked detail, Next move, Watch's prompt | New | — | Approved | tern-plotroom#zaq6, adopted from tern-pr-guide. Landing stalls on red checks the PR did not cause; the mark says which re-run is worth it, and your own PR's other failures go to Watch, which fixes them |
| Preview checks by state: Failing, Running, Queued, then Passed and Skipped folded, each headed with its count; each check with its CI and how long it ran or has been running; read again every 30 s while one is unfinished and the preview shows it | Preview (Checks) | New | 2 | Approved | tern-plotroom#de01, adopted from tern-pr-guide: what is red and what is still going reads at a glance, and the list moves without a refresh. Rows keep no check counts (row 44) |
| Re-run all jobs…; Cancel running workflow… | Commands | Cut | 1 | Approved | Managing CI belongs to GitHub; Re-run failed checks covers the loop |
| Add label…; Remove label… | Commands | Cut | 1 | Approved | Tracker housekeeping, not a loop step |
| Jira transition… (REST API; needs `PLOTROOM_JIRA_API_TOKEN`) | Commands | Cut | 1 | Approved | The only feature that needs a token; an action's Move to status (acli) stays |
| Open (the item's page in Tern's Browser beside the queue) | Enter, Commands, preview | Keep | — | Approved | |
| Open floating preview | Commands, Tern's palette | Merge into **Open** | 1 | Approved | Two ways to show the same page |
| Copy link; Copy number; Copy branch | Commands | Keep | — | Approved | Cheap |

## Clean up

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Worktrees list (badges, rotating scans) | Sidebar | Keep, renamed **Worktrees** | 1 | Approved | |
| Find finished worktrees; Remove finished worktrees…; Remove worktree… | Commands, preview | Keep | — | Approved | |
| Open in Git | Commands, preview | Keep, renamed **Open Git view** | 1 | Approved | Glossary: Open |

## Configuration and platform

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Seven Settings pages | Settings | Merge into four: **Views, Actions, Repositories, General** | 1 | Approved | Metric 3 |
| Jira projects page (project → repositories) | Settings | Merge into **Repositories** | 1 | Approved | |
| Refresh page (Refresh now, pacing, quota meter) | Settings | Merge into **General** | 1 | Approved | |
| Keyboard shortcuts page and the one-key set | Settings | Merge into **General**; the one-key set is offered at first run | 1 | Approved | |
| GitHub and Jira setup pages (when the CLI is missing) | Settings | Keep | — | Approved | |
| First-run checklist | Queue | New | 1 | Approved | PRODUCT.md › Principles 4 |
| Reset all settings | Settings › General | New | 1 | Approved | Starting over, and the way out of a corrupted store; keeps triage, usage, runs and agent links |
| Settings' on/off rows as native switches; each Settings page counts what differs from the defaults | Settings (Views › Now, General › Summaries; every page's nav entry) | New | — | Approved | Setup. tern-plotroom#y47f: Tern's prefs `switch` control and page `changed` count (spike `.evidence/y47f/`); an On/Off segment pair read as two choices, and nothing said where your changes are |
| Key footer: at most 5 bound keys for the selection (Commands, Shortcut list, Next move, then the most used); actions show their key where they appear | Queue, Commands, preview | New | — | Approved | Trust: a second user finds the keys. Adopted from tern-pr-guide (DESIGN.md › Keycaps); tern-plotroom#4ban |
| Export and import of views and actions | Commands › Configuration | Cut | 1 | Approved | About 700 lines for a rare move between machines; views and actions are re-created by hand |
| `Plotroom:` commands in Tern's palette, except Open, Open item by URL, Message an agent with the selection… and Go to the first agent that needs input (33 of 37 today) | Tern's palette | Hide: they stay in Commands; Tern's palette keeps only entry points and cross-pane commands. Tern-level key binds to hidden commands stop working. | 1 | Approved | Metric 2; Tern's palette is shared with every other plugin |
| Tern's palette rows under one **Plotroom** group, titles without the `Plotroom:` prefix; default keys ⌃⌥⇧Q Go to Plotroom (focus the block, else open one), ⌃⌥⇧I Show what needs you (Now), ⌃⌥⇧A Go to the first agent that needs input | Tern's palette, keys | New | — | Approved | tern-plotroom#1tyq (Trust: Commands and keys); rows read "Tern Plotroom › Plotroom: Open", and the cross-pane jumps had no key |
| Protocol mismatch notice | Status bar | Keep; shows only outside the supported protocol range | 0 | Approved | |
| CHANGELOG; version separate from the protocol; supported protocol range | Repository | New | 0 | Approved | Two-host installs without a reinstall for every change |
| Polite refresh and rate-limit backoff | Engine | Keep | — | Approved | |
| Developer commands (`PLOTROOM_SELFTEST=1`) | Tern's palette | Keep | — | Approved | Hidden unless the variable is set |
| DESIGN.md: one meaning per colour (your turn, needs fixing, done, agent working, checks running), everything else neutral | Every surface | New | 1 | Approved | Trust and coherence: a colour you can read at a glance; adopted from tern-pr-guide |
| Loading, empty and failed preview sections as Tern's `skeleton` and `empty` kinds; a failed read (or Summary) offers Retry in place; the Draft review's diff loads as a skeleton; an empty Board column is an `empty` | Preview, Board, Draft review | New | — | Approved | Trust: one look for the four states (Tern's Designing Views › The four states); tern-plotroom#eav9 |
| Arrival ring pauses with its pane: Tern's `.sf-paused` (a hidden pane) holds the ring where it was, and it resumes when the pane shows again | Queue rows | New | — | Approved | Trust (finer points): Tern's Styling views asks every plugin animation to pause under `.sf-paused`; a ring that ran out while the pane was hidden would leave a stage change unnoticed. tern-plotroom#4y4w |
| Both blocks in Tern's sans face (`font = "sans"`): people's text in the UI face, machine strings (ids, refs, branches, SHAs, paths, sizes, times) in `mono`/`code`/`path` spans, numbers in text `mono` not `num`, the queue's view name in the `title` token | Queue, Draft review | New | — | Approved | Trust (finer points): Tern's Designing Views › Typography ("Open apps in sans"); the Draft review's plugin-CSS font override is gone. tern-plotroom#7rrn |
