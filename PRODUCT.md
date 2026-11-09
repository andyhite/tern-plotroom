# Plotroom: product

**Plotroom is where a developer running coding agents decides what to work on, hands it off, and lands it, without keeping the state in their head.**

This file decides what Plotroom should be: who it is for, the loop every feature serves, the principles, what is out of scope, the vocabulary and the roadmap. [LEDGER.md](LEDGER.md) gives every feature a verdict. [README.md](README.md) is the product page and [docs/reference.md](docs/reference.md) tells users how Plotroom behaves; [AGENTS.md](AGENTS.md) tells contributors how to build it. Where they disagree about what Plotroom *should* do, this file wins; about what it *does* now, the code wins.

## Who it is for

- **Primary user:** a developer who works in Tern with omp and runs two to six coding agents at once against GitHub pull requests and issues, sometimes Jira issues. Keyboard first, often on a remote host, often with a work and a personal GitHub login.
- **Today:** one user, Plotroom's author, who is also the first design partner. Every decision must still make sense to the second user, who has none of the author's history.
- **Not for:** teams coordinating through Plotroom, people who do not run agents, or anyone looking for a full GitHub or Jira client.

## The loop

Every feature serves one step. A feature that serves none is cut (LEDGER.md), however cheap it is.

| Step | The user's question | What Plotroom answers with |
| --- | --- | --- |
| **Intake** | What work exists? | Views, Pins, Inbox (Now from Phase 2) |
| **Triage** | What needs me now? | New and Changed, Snooze, Needs attention (Now and stages from Phase 2) |
| **Dispatch** | Who does it, and where? | One-key Worktree, Actions that start agents |
| **Supervise** | Which agent needs me, which finished, and did it work? | Agent states, the Agents list, messages (outcomes from Phase 3) |
| **Land** | Is it ready? Ship it. | Checks, reviews, Merge, Approve, Request changes, Draft PR |
| **Clean up** | What is finished? | Find and remove finished worktrees |

## Principles

1. **One loop.** Every feature serves a step above. A feature that serves none is cut, however cheap it is.
2. **Facts, not memory.** Stage, outcome and check state are derived from GitHub, Jira, git and Tern each time. Plotroom stores only what a person edits (views, actions, snoozes, keys) and the run history. Text derived from those facts (a Summary) may be cached, keyed by the facts it came from, and is never a source.
3. **Nothing leaves unconfirmed.** Every write to GitHub or Jira is planned, shown, and committed only after a confirm that lists Cancel first; a saved account that cannot be used fails closed. (These are existing invariants in AGENTS.md.)
4. **Works before it is configured.** With `gh` and `omp` installed and the repository's checkout open in a Tern tab, a new user reaches a running agent without opening Settings. Settings change defaults; they are not a setup step.
5. **Tern-native, not a second app.** Use Tern's Browser, tabs, agent blocks, Git view and status bar. Never rebuild what Tern, omp or GitHub already do well: CI, merge queues, notification delivery, GitHub's code review UI. The exception is agent work you must approve before it leaves: a Draft review is shown on its diff in Plotroom, because no other surface lets you edit an agent's findings before they post.
6. **One word per thing.** The glossary below is the only vocabulary in the UI, README and reference.
7. **Editable guidance, fixed contract.** (Phase 3) Users edit an action's text. The end-of-run report Plotroom appends to it is fixed, because Plotroom parses it.

## Out of scope

- Team features, shared state, a hosted service, accounts.
- Trackers beyond GitHub and Jira until a design partner needs one. Kata is served by tern-kata (board, agent card, attention page, worker); Linear and GitLab wait for demand.
- Owning CI, merge queues, or pushing to a base branch. Work lands through pull requests.
- A second agent harness, local-model triage, or reading agents' screens.
- A separate dashboard for agents or loops. Plotroom is the dashboard.
- Housekeeping that GitHub or Jira does better: labels, workflow-run management, issue fields.

## Glossary

The UI, README and reference use these words and no others for these things.

| Term | Means | Instead of |
| --- | --- | --- |
| **Item** | One pull request, GitHub issue or Jira issue. | row, entry |
| **View** | A saved GitHub search or JQL query in the sidebar. | filter, scope, list |
| **Pin** | An item opened by URL or paste, kept in the sidebar's Pins group. | — |
| **Now** (Phase 2) | The default view: everything that needs you, ranked. | Inbox, Needs attention only |
| **Stage** (Phase 2) | Where an item stands, derived from facts: Not started, Worktree, Agent working, Needs you, PR open, Blocked, Ready to merge, Merged, Closed. | status (except Jira's own status) |
| **Chip** | One reason a Blocked pull request is Blocked, named by the job that clears it: **Address changes**, **Reply** (unresolved threads), **Fix checks**, **Re-run** (every failing check Likely flaky), **Resolve conflicts**. | reason badge, blocker, status |
| **Likely flaky** | A failing check that no failure annotation blames on a file the PR changed, and that failed at least 3 of the base branch's last 20 runs of its workflow or passed earlier on the same head commit. | flaky (unqualified), intermittent |
| **Checkout** | A repository's main local clone, set in Settings › Repositories. | local checkout, main checkout, repository path |
| **Worktree** | A linked git worktree Plotroom made for one item. The sidebar list is **Worktrees**. | Worktrees list, board |
| **Action** | A saved instruction that starts an agent on an item (Settings › Actions). Its text field is its **prompt**. | saved action, prompt (for the whole thing), command |
| **Agent** | An omp agent block started by an action. | session, worker |
| **Run** | One agent started by an action on an item, from start to end of turn, as recorded in the run log. | job |
| **Outcome** (Phase 3) | What a run must leave behind (review posted, PR opened, …), checked against facts: **Verified** or **Not verified**. | result, done |
| **Checker** (Phase 3) | An action run by a fresh agent that verifies another run's work. | evaluator, reviewer |
| **Commands** | Plotroom's own menu, opened with `.`. Tern's own palette is **Tern's palette**. | command palette, menu |
| **Open** | Show the item's web page in Tern's Browser beside the queue. Other destinations are named: **Go to tab**, **Go to agent**, **Open Git view**, **Show in Plotroom**. | Open in GitHub, preview, floating preview |
| **Needs attention** | New or Changed and not snoozed, or its agent needs input. | attention filter |
| **Snooze** | Hide an item until 08:00 tomorrow. | — |
| **Refresh** | Read the view again now. | reload, sync |
| **Draft review** | Findings an agent proposes for a pull request (comments on lines, a summary, a verdict), opened in Plotroom's review block beside that agent. You keep, edit or drop each one and send them back; the agent posts only what you sent. | proposal, suggested review |
| **Board** | A view laid out in columns by stage instead of as a list. | kanban, columns |
| **Summary** | A few sentences a small model writes about an item, at the top of its preview. | explanation, TL;DR |

User-facing text never shows internal names: protocol numbers, pane or run ids, kv keys, unfilled `{placeholders}`, or code identifiers.

## How features get added

- **Feature freeze:** until Phase 0 is done, bug fixes only.
- After Phase 0, a feature starts as a LEDGER.md row naming its loop step and phase, before any code.
- A new command or setting either replaces or merges an existing one, or names the metric it moves.
- kata issues cite the PRODUCT.md or LEDGER.md section they implement.

## Roadmap

| Phase | Goal | Contents | Exit criterion |
| --- | --- | --- | --- |
| **0: Groundwork** | Make product decisions on evidence, and ship changes safely | Run log and usage report; CHANGELOG, a version separate from the protocol, and a supported protocol range | A usage report can be copied; one window works with a host one protocol older |
| **1: Coherence** | One product, not an accumulation | Apply LEDGER.md verdicts; the glossary everywhere; four Settings pages; first-run checklist; README as a product page with screenshots, the spec moved to a reference doc | Metrics rows 2–4 hit their targets |
| **2: The loop** | Answer "what needs me" in one place | Stage on every item; the suggested next move; Now; agent questions answered in Now | One surface answers "what needs me" |
| **3: Checked outcomes** | Know whether agent work actually worked | Fixed end-of-run report; outcomes per action; checker actions with acceptance criteria saved at dispatch; three-strike limits; chains advance only on Verified; recording disagreement with a checker | Default-action runs reach a Verified outcome at least 80% of the time |
| **4: Beyond the author** | A second, third and fourth user | 3–5 design partners from the Tern and omp community, a listing in the awesome-tern catalog, repository description and topics, a demo recording (`tern shot` `record`). These are the author's tasks, not loop tasks. | 3 partners using it weekly |
| **5: Autopilot** | Hand off a whole view, not one item | Opt-in view as the work source; Implement → Check → Fix (at most 3 rounds) → PR ready for review; slots, graceful stop, recovery from the run log; everything surfaces in Now. It never pushes to a base branch and never merges. | Gate to start: the checker agrees with you on at least 80% of 20 or more checked runs |
| **6: Review and layout** | Approve agent work where it happens, and see the queue at a glance | Plotroom's omp extension (tools agents use to hand work back); the review block and Draft reviews; a Board layout per view (after a spike); Summaries | A Review run ends in a Draft review you edit and send without leaving Tern |

Phases 0–3 and 6 are queued as kata issues. Each is blocked by its prerequisites until they close, because roundhouse otherwise starts ready issues oldest first, as many at once as it has slots. Phase 5 waits as a someday issue behind its gate.

## Metrics

All local; nothing is sent anywhere.

| # | Metric | Measured by | Today | Target |
| --- | --- | --- | --- | --- |
| 1 | Places to look to answer "what needs me" | Counting surfaces | 6 (badges, the attention filter, Inbox, the Agents list, two status segments) | 1 (Now) |
| 2 | Tern palette `Plotroom:` commands | Counting `tern.command` registrations | 37 | ≤ 10 |
| 3 | Settings pages, with both CLIs installed | Counting | 7 | 4 |
| 4 | New user: from install to a running agent | Timed on a clean profile | Requires Settings › Repositories | Under 5 minutes, Settings never opened |
| 5 | Default-action runs with a Verified outcome | Run log | No outcomes yet | ≥ 80% |
| 6 | Checker agreement | Run log plus disagreements you record | None yet | ≥ 80% over 20 checked runs (the Autopilot gate) |
| 7 | Weekly users besides the author | Design partners | 0 | 3–5 |

## Decisions

- **2026-11-02.** Plotroom is built for Tern and omp developers beyond its author, and the author is its first design partner.
- **2026-11-02.** GitHub comes first. Jira stays at its current depth until Phase 3 is done.
- **2026-11-02.** No rewrite. Fetching, worktrees, the trust model and the check gate stay as they are; the surface is reorganized around the loop.
- **2026-11-02.** Feature freeze until Phase 0 is done.
- **2026-11-02.** Cut: Tell Carly and the `plotroom_agents` export, Send a page element to an agent, Re-run all jobs, Cancel running workflow, Add and Remove label, the token-based Jira transition picker, and Export and import. Merged: the floating preview into Open. Hidden from Tern's palette: every command but the entry points and cross-pane commands. See LEDGER.md.
- **2026-11-02.** Kata is not a dependency. Plotroom adopts its agent conventions (attention `ok` / `stuck` / `needs-human` with a one-line reason; the handoff fields commit, evidence and blocker) for its own end-of-run report.
- **2026-11-02.** From CuLoRA's build loop, Plotroom ports: a checker that never built the work, a fixed end-of-run report, three-strike limits, an inbox of open questions, and a run log. It skips: merging to `main` itself, the app lock, local-model triage and a separate dashboard. Autopilot comes last, behind the agreement gate. In CuLoRA, the checker passed 18 of 34 rounds, and a rubric that excluded styling let through a UI that missed its designs.
- **2026-11-04.** From tern-pr-guide: an agent's review is a Draft review shown on its diff beside the agent, and the agent posts only what you send back (principle 5 now allows this). Plotroom ships an omp extension that its agents load, starting with the tool that proposes a Draft review. A Board layout is spiked on Now before any view offers it. Summaries are made on select by omp's `@smol` role and cached. Phase 6 is not gated and may run beside Phase 4.

## Heritage

Plotroom began as Plotroom Fleet (`~/Code/plotroom`), a Tauri desktop cockpit for supervising agents. Its PRD's thesis carries over: *durable, typed state turns agent chat into agent workflow*, and the operator should "reliably know which one is stuck, finished, waiting on approval". Tern now owns terminals, tabs and agent hosting, so Plotroom keeps the work queue, dispatch and supervision.
