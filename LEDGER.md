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
| Linked pull requests and issues | Preview | Keep | — | Approved | Navigation between the halves of one piece of work |
| Inbox (GitHub notifications) and Mark read | Sidebar | Merge into **Now** | 2 | Approved | One of the six partial answers to "what needs me". Done: Now lists the notifications and offers Mark read… |
| Shell lens after `gh pr create` | Shell pane | Keep | — | Approved | Cheap intake of a just-created PR |
| Open Plotroom button in the Files pane | Files pane | Keep | — | Approved | Entry point |
| Plotroom: Open | Tern's palette | Keep | — | Approved | Entry point |

## Triage

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| New and Changed badges; seen is automatic | Queue rows | Keep | — | Approved | |
| Mark seen | Commands | Keep | — | Approved | |
| Snooze until 08:00 tomorrow; Show or hide snoozed; Unsnooze | Commands, preview | Keep | — | Approved | |
| Needs attention only filter | Commands | Merge into **Now** | 2 | Approved | Three names today, and a partial answer to "what needs me". Done: removed; Now lists New and Changed assigned items |
| Pane-title count and the `N need attention` status segment | Pane title, status bar | Merge into one **Now** count | 2 | Approved | Done: one `N need you` count in the pane title and the status bar |
| Sort orders (Next sort order, sort per view) | Commands, Settings › Views | Keep | — | Approved | |
| Search | Bottom bar, Commands | Keep | — | Approved | |
| Group by (repository, status, label) | Settings › Views | Keep | — | Approved | |
| Preview: description, facts, checks, merge state, reviewers | Preview | Keep | — | Approved | |
| Preview: worktree card (Up to date, Changes, unpushed count) | Preview | Keep | — | Approved | |
| Stage on every item, and the suggested next move | Rows, preview, Commands | New | 2 | Approved | PRODUCT.md › Glossary › Stage |
| Now | Sidebar (default view), status bar | New | 2 | Approved | Replaces Inbox, the attention filter and the two counts |

## Dispatch

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Worktree: one key; the PR's head branch; an issue's branch from its linked PR or a chosen base | Commands, key, preview | Keep | — | Approved | The core of dispatch |
| Checkouts and cloning | Settings › Repositories | Keep, plus automatic detection | 1 | Approved | Today a required manual step before any agent can start |
| Setup commands | Settings › Repositories | Keep | — | Approved | |
| Name formats (branch and folder) | Settings › Worktrees | Merge into Settings › **Repositories** | 1 | Approved | A whole page for three fields |
| Actions and Type a prompt… | Commands, Settings › Actions | Keep | — | Approved | |
| Default actions (Review, Quick review, Address feedback, Watch, Implement, Fix, Plan) | Settings › Actions | Keep; outcomes added | 3 | Approved | Done: each names its default outcome |
| Action fields: Model, Runs in, Opens in, Move to status (acli), key | Settings › Actions | Keep | — | Approved | |
| Action field: Next action (chains) | Settings › Actions | Keep; advances only on a Verified outcome | 3 | Approved | |
| Action field: Tell Carly when it finishes, and the `plotroom_agents` Carly export | Settings › Actions, Carly | Cut | 1 | Approved | Serves no loop step that Tern's agent notifications and Now don't cover; adds jargon |
| "An agent already works on it" guard | Commands | Keep | — | Approved | |
| Checker actions, fixed end-of-run report, outcomes, three-strike limits | Settings › Actions, run log | New | 3 | Approved | PRODUCT.md › Roadmap › Phase 3. Done: the fixed end-of-run report, read into the run log and shown in Agents; outcomes per action, checked on GitHub into Verified, Not verified or Unchecked on the run log, the row, Agents and Now; checker actions (Checked by, the default Check) run by a fresh agent against the acceptance criteria saved at dispatch, Checked or Check failed on the run log, the row, Agents and Now; chains that advance only on a Verified run or a passing check, fix rounds with `{findings}`, and the three-strike limits (3 failed checks, 3 runs without progress, 3 failed starts) counted on the run log and shown in Now; Disagree with check… (Commands) on the run log, and checker agreement (agreed by merge or after 7 days, over the last 20 decided runs) in the usage report (Metrics row 6) |
| Autopilot | One opted-in view | New | 5 | Approved | Gated by PRODUCT.md › Metrics row 6 |

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
| Paused-hook notice | Toast, status bar | Keep | — | Approved | |
| Run log and usage report | Commands › Configuration | New | 0 | Approved | Evidence for Review rows and for metrics 5 and 6 |
| Agent questions answered in Now | Now | New | 2 | Approved | Taken from CuLoRA's build loop. Done: a waiting agent's Now row shows its last message, with Reply… and Go to agent |

## Land

| Feature | Where | Verdict | Phase | Status | Why |
| --- | --- | --- | --- | --- | --- |
| Merge… (including auto-merge); Approve…; Request changes…; Update branch… | Commands | Keep | — | Approved | The core of landing |
| Ready for review…; Convert to draft… | Commands | Keep | — | Approved | |
| Draft PR… from an issue's worktree | Commands | Keep | — | Approved | |
| Comment…; Assign to me | Commands | Keep | — | Approved | |
| Close issue…; Reopen issue… | Commands | Keep | — | Approved | "Won't do" is a triage outcome |
| Re-run failed checks | Commands | Keep | — | Approved | |
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
| Export and import of views and actions | Commands › Configuration | Cut | 1 | Approved | About 700 lines for a rare move between machines; views and actions are re-created by hand |
| `Plotroom:` commands in Tern's palette, except Open, Open item by URL, Message an agent with the selection… and Go to the first agent that needs input (33 of 37 today) | Tern's palette | Hide: they stay in Commands; Tern's palette keeps only entry points and cross-pane commands. Tern-level key binds to hidden commands stop working. | 1 | Approved | Metric 2; Tern's palette is shared with every other plugin |
| Protocol mismatch notice | Status bar | Keep; shows only outside the supported protocol range | 0 | Approved | |
| CHANGELOG; version separate from the protocol; supported protocol range | Repository | New | 0 | Approved | Two-host installs without a reinstall for every change |
| Polite refresh and rate-limit backoff | Engine | Keep | — | Approved | |
| Developer commands (`PLOTROOM_SELFTEST=1`) | Tern's palette | Keep | — | Approved | Hidden unless the variable is set |
