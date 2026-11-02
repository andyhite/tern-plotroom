# TODO

## Backlog

- [ ] Autopilot works through an opted-in view up to a pull request ready for review
  - Gate: promote only when the usage report shows checker agreement of at least 80% over 20 or more checked runs (PRODUCT.md › Metrics, row 6). Until then this item stays here.
  - Behavior per PRODUCT.md › Roadmap › Phase 5: one opted-in view is the work source; each item runs Implement → its checker → fix rounds (at most 3) → a pull request marked ready for review, then stops at Needs you.
  - Never pushes to a base branch, never merges, never confirms a write on the user's behalf; Merge stays the user's action.
  - Slots (default 2), a graceful stop that lets running agents finish and starts nothing new, recovery from the run log after a plugin reload, and a stop after 3 failed agent starts in a row.
  - Everything it needs from the user shows in Now; there is no separate dashboard (PRODUCT.md › Out of scope).

## Todo

- [ ] A usage report shows how often each command ran and how each agent run ended
  - Commands › Configuration gains **Copy usage report**: plain text since the first recorded day, listing every queue action, Commands row, Tern palette command and action (by name) with its count and last use, then runs grouped by action with a count per result (done, failed, exited, closed) and the median run time (PRODUCT.md › Metrics; LEDGER.md › Supervise › Run log and usage report).
  - Run log: one record per agent run (item key, action name, kind, model, runs in, started, ended, result), appended when the agent's turn ends, where `flows.recordResult` records the result today. It keeps the newest 1000 in kv `runs`. Usage counts live in kv `usage` (id → count, last use) on the machine that handles the action; the report shows both machines' counts, reading the host's as the palette reads `main.palette`.
  - Stores hold no item titles, prompt text or agent output. A `runs` or `usage` store that cannot be read or is malformed is never overwritten, and the report says which part is missing. Nothing is ever sent off the machine.
  - Out of scope: charts, a Settings page, resetting counts, outcomes (Phase 3 adds them to the run record).
  - Touch points: `flows.recordResult`, the `flows.COMMANDS` run path and the Commands palette in `plugin/window.luau`, the queue action dispatcher in `plugin/host.luau`, hidden `main.*` nodes in `host/render`, validators in `host/storage`.
  - Cases: a run is appended on finish and the cap holds (`tests/cases/flows.luau`); a key action increments its count (`tests/cases/queue.luau`); a malformed store is left untouched. Docs: README › Trust lists the two new kv stores.

- [ ] Plotroom has a changelog and its own version, and a window works with a host one protocol older
  - Add `CHANGELOG.md` (Keep a Changelog) with Unreleased and `0.33.0` entries; `0.33.0` summarizes the 2026-11-02 product direction. `plugin/plugin.toml`'s `version` stops tracking `RPC_PROTOCOL`, and `check_version` in `scripts/check.py` instead requires a `## [<version>]` heading in CHANGELOG.md (PRODUCT.md › Roadmap › Phase 0; LEDGER.md › Configuration and platform).
  - The window accepts a host whose announced protocol lies in `[MIN_PROTOCOL, PROTOCOL]`. The status-bar mismatch segment and the "another version" toast appear only outside that range, and their text names the host.
  - An rpc that an older host in range does not know is refused at once, with a toast saying to install the current Plotroom on that host; it never times out.
  - Rule, written into AGENTS.md's invariants in place of today's protocol/version rule: an rpc change is additive (a new op or a new optional field); removing or reshaping an op raises `MIN_PROTOCOL` to the new protocol. Every user-visible change adds a line under Unreleased. Tagging and pushing a release stay manual steps for the author.
  - Touch points: `PROTOCOL` and the host-version check in `plugin/window.luau`, `RPC_PROTOCOL` in `plugin/host/core.luau`, the `main.rpc` node in `host/render`, `check_version` in `scripts/check.py`.
  - Cases: a host at `PROTOCOL - 1` serves an old op and refuses a new one with the toast; a host below `MIN_PROTOCOL` shows the mismatch (`tests/cases/window.luau`). Docs: README › Install › Remote hosts explains the one-version tolerance.

- [ ] Features cut in LEDGER.md are gone, and Open is the only way to show an item's page
  - Remove, with their code, tests, smoke scenarios, README text and store fields (LEDGER.md rows with verdict Cut):
    - Tell Carly when it finishes, and the `plotroom_agents` Carly export
    - Send a Browser page element to an agent…
    - Re-run all jobs… and Cancel running workflow…
    - Add label… and Remove label…
    - The Jira transition… picker, with its REST client and `PLOTROOM_JIRA_API_TOKEN`
    - Export and import (`plugin/portable.luau`, `tests/portable_check.luau` and the export/import smoke steps)
  - Open floating preview merges into Open: the separate command and its `preview` follow mode go. Enter and Open keep docking Tern's Browser beside the queue. The floating-preview smoke scenario and the `layout` dump it needs go too, unless something else still uses them.
  - Saved actions that carry a `carly` field still load: the field is ignored and dropped at the next save of that store. No store is rewritten just to remove it, and malformed stores are still never overwritten.
  - Kept, on purpose: Re-run failed checks, an action's Move to status (acli), Message an agent with the selection…, Comment…, and Close issue… / Reopen issue….
  - AGENTS.md drops the Jira-token invariant. README › What it does, › Keys and the command palette, and › Trust stop mentioning the cut features. An rpc op that is removed follows the protocol rule on the base branch.
  - Verification: `python3 scripts/check.py` passes, with cases for the removed features deleted, not rewritten to pass.
  - After: Plotroom has a changelog and its own version, and a window works with a host one protocol older
  - After: A usage report shows how often each command ran and how each agent run ended

- [ ] Tern's palette lists only Plotroom's entry points and cross-pane commands
  - Tern's palette keeps Plotroom: Open, Open item by URL, Message an agent with the selection… and Go to the first agent that needs input. Every other Plotroom command stays in Commands (`.`) and keeps its one-key binding where it has one (LEDGER.md › Configuration and platform; PRODUCT.md › Metrics, row 2).
  - Prefer a registration that hides a command from Tern's palette but keeps it runnable by action name (`plugin.plotroom.<id>`: Tern key binds, `tern ctl plugins run`), for example `available` returning false. Prove it against real Tern in smoke. If Tern cannot run a hidden command, drop the registration and drive those smoke steps through Commands instead.
  - Commands keeps calling `flows.COMMANDS` runs directly, so nothing reachable today becomes unreachable from inside the block.
  - Touch points: the `flows.COMMANDS` registration loop and the `open-selected`, `worktree-selected`, `goto-selected` and `agent-selected` commands in `plugin/window.luau`; `plugins run` calls in `scripts/smoke.py`.
  - Cases: only the four commands are available in Tern's palette (`tests/cases/window.luau`); smoke passes. Docs: README › Keys and the command palette lists the four.
  - After: Features cut in LEDGER.md are gone, and Open is the only way to show an item's page

- [ ] Settings has four pages: Views, Actions, Repositories and General
  - **Views** and **Actions** stay as they are (LEDGER.md › Configuration and platform).
  - **Repositories** shows the default issue-branch and folder name formats first (formerly Settings › Worktrees), then each repository's checkout, setup commands and branch format, then Jira projects and their repositories while acli is on (formerly Settings › Jira projects).
  - **General** holds Keyboard shortcuts with the one-key set, then Refresh now with the pacing text and the GitHub quota meter (formerly Settings › Refresh). The GitHub and Jira setup pages stay, shown only while their CLI is missing.
  - Every setting keeps its kv key and behavior; only where it is shown changes. Restore defaults is renamed **Add missing defaults**, because it never overwrites edited defaults.
  - Touch points: `PAGE_DEFS` in `plugin/host/core.luau`, page renderers and handlers in `plugin/host/settings.luau`.
  - Cases: with both CLIs on, the page list is these four (`tests/cases/issues.luau`); existing settings cases keep passing. Docs: README's references to Settings pages.
  - After: Features cut in LEDGER.md are gone, and Open is the only way to show an item's page

- [ ] UI text uses only PRODUCT.md's glossary, and no internal names show
  - Apply PRODUCT.md › Glossary to every user-visible string: labels, titles, toasts, hints, empty states, picker placeholders, key labels and README. Examples:
    - Saved actions → Actions; Worktrees list → Worktrees; one name, **Commands**, for the `.` menu
    - **Needs attention only** as the filter's only name; **Snooze until tomorrow**
    - **Open Git view**; **Checkout** for local checkout / main checkout, so Runs in reads Worktree / Checkout
  - No internal names in the UI (PRODUCT.md › Glossary, last paragraph):
    - Commands rows show an action's detail with its variables filled for the selected item, or no detail, never `{placeholders}` (`plugin/window.luau` palette).
    - The duplicate-agent offer names the action and state, not a pane id.
    - The protocol mismatch reads as differing Plotroom versions on the named host.
  - Pickers whose Enter starts, sends or opens something say so in their key hint, instead of `choose` (the `action = "choose"` call sites in `plugin/flows.luau` and `plugin/window.luau`). In the narrow layout the view dropdown no longer repeats the title beside it. "Sort: Default (search order)" reads "Sort: GitHub's order" for GitHub views.
  - Out of scope: behavior, kv keys, action ids and code identifiers; only user-visible text changes.
  - Touch points: `keys.ACTIONS` labels, `flows.COMMANDS` labels and titles, `host/render`, `host/settings`, `plugin/window.luau`, `host/lens.luau`, `scripts/smoke.py` `wait_text` strings, README.
  - Cases: no Commands row detail contains `{` (`tests/cases/window.luau`); cases that match changed text are updated; smoke passes.
  - After: Tern's palette lists only Plotroom's entry points and cross-pane commands
  - After: Settings has four pages: Views, Actions, Repositories and General

- [ ] A new user gets from opening Plotroom to a running agent without opening Settings
  - Until it is done or dismissed, a first-run checklist shows in the preview area, also reachable from Commands as **Get started** (PRODUCT.md › Principles 4; Metrics, row 4). Each line has one action:
    - `gh` installed and signed in, with its setup guide when not
    - `omp` installed
    - A checkout for each repository among the listed items that has none
    - The one-key shortcuts: Use them / No thanks
  - Checkout detection offers **Use <path>** for a repository with no checkout when a folder is known to belong to it: the folder Plotroom opened in, or the directory of an open Tern pane on the same host inside a git checkout whose remote is that github.com repository. The folder is verified as Settings › Repositories verifies today. The disk is never scanned, and Clone stays the fallback.
  - Worktree, an action, or Type a prompt… on a repository with no checkout tries the same detection before asking for a path.
  - Panes on another host never count for this block. A dismissed checklist stays dismissed in kv. Without an integration's CLI, its line points to the setup guide.
  - Touch points: first-run and empty states in `host/render`, CLI probing and `checkouts` in `host/engine`, pane directories via `cx.session` in `plugin/window.luau`, `resolveRepository` in `plugin/worktree.luau`.
  - Cases: detected from the launch folder; from another pane; a wrong remote is refused; a pane on another host is ignored. A smoke scenario from a fresh config directory reaches a worktree without opening Settings. Docs: README › Install leads with this flow.
  - After: UI text uses only PRODUCT.md's glossary, and no internal names show

- [ ] README is a product page with screenshots, and the behavior spec lives in docs/reference.md
  - README.md becomes the product page (PRODUCT.md › Roadmap › Phase 1):
    - the pitch and who Plotroom is for
    - the loop as one table
    - 3–4 screenshots
    - install and first run
    - links to the reference, Trust and Development
  - `docs/reference.md` takes today's detailed behavior text, organized by loop step in the glossary's words. Nothing still true is dropped, and Trust keeps every guarantee.
  - Screenshots are PNGs under `docs/images/` from smoke's headless shots (`PLOTROOM_SMOKE_SHOTS=<dir> python3 scripts/check.py smoke`): the queue with its preview, Commands, Worktrees, and an agent. None over 400 KB, and none under `plugin/`, so the installed package stays small.
  - AGENTS.md says README.md is the product page and `docs/reference.md` the user-facing behavior spec that contributors update with every behavior change.
  - Verification: every README and reference link resolves; `python3 scripts/check.py` passes.
  - After: A new user gets from opening Plotroom to a running agent without opening Settings

- [ ] Every item shows its stage, derived from GitHub, Jira, git and its agent
  - Stages per PRODUCT.md › Glossary › Stage, highest precedence first:
    - **Merged** or **Closed**
    - **Needs you**: its agent needs input
    - **Agent working**
    - **Blocked**: a PR with failing required checks, changes requested, or conflicts
    - **Ready to merge**: approved, checks passing, mergeable
    - **PR open**, including an issue whose worktree branch has an open PR
    - **Worktree**: a Plotroom worktree, no PR
    - **Not started**
  - One stage badge on each row and as the preview's first fact. It replaces row badges that say the same thing, and keeps In tab, New and Changed.
  - Derived on every render from facts already fetched. A fact the list query lacks (review decision, merge state, check rollup) is added to the search's GraphQL selection within the bench gate (`PLOTROOM_BENCH_BUDGET_MS`; the `BENCH payload` row under 600000 bytes). A fact that is unknown never yields Ready to merge.
  - Touch points: rows and preview in `host/render`, details and worktree board glue in `host/engine`, search fields in `plugin/github.luau`, badges in `host/core`.
  - Cases: each stage and the precedence between them (`tests/cases/queue.luau`, `tests/cases/checks.luau`); bench passes. Docs: `docs/reference.md` documents stages.
  - After: README is a product page with screenshots, and the behavior spec lives in docs/reference.md

- [ ] The selected item suggests its next move for its stage
  - Mapping (PRODUCT.md › Roadmap › Phase 2):
    - Not started issue → Worktree; someone else's PR asking for your review → Review action
    - Needs you or Agent working → Go to agent
    - Blocked, changes requested on your PR → Address feedback; Blocked, failed checks → Re-run failed checks
    - Ready to merge → Merge…
    - Your draft PR → Ready for review…
    - Issue in a Worktree with no PR → Draft PR…
    - Merged or Closed with a worktree → Remove worktree…
  - It shows as the first Commands row, under the heading **Next**, and as a button in the preview header. A new queue action, **Next move**, has no default key and preset key `x` in the one-key set.
  - Every move runs exactly as its own command does, confirms included. When nothing applies, nothing is shown.
  - Touch points: `requests.paletteActions`, the preview header in `host/render`, `keys.ACTIONS`, the Commands palette in `plugin/window.luau`.
  - Cases: each stage maps to its move; no move for an unrelated closed item. Docs: `docs/reference.md`.
  - After: Every item shows its stage, derived from GitHub, Jira, git and its agent

- [ ] Now lists everything that needs me, ranked, first in the sidebar
  - **Now** is a built-in list, like the Inbox and Agents lists today: first in the sidebar, selected when Plotroom opens, and not editable or deletable (PRODUCT.md › Glossary › Now; LEDGER.md › Triage).
  - Ranked, top first; each row says why it is listed, and snoozed items follow Show or hide snoozed:
    - agents that need input
    - your PRs that are Blocked
    - reviews requested of you, oldest first
    - your PRs that are Ready to merge
    - unread notifications you take part in that are not already listed
    - New or Changed items assigned to you
  - It reads fixed searches per signed-in login (your open PRs, review requests, assigned issues), Jira's open work assigned to you while acli is on, and notifications as the Inbox does today. All of it stays within the polite-refresh pacing.
  - It replaces the Inbox list (Mark read… moves to Now), the Needs attention only filter, and the pane-title and status-bar attention counts. One count, `N need you`, covers both and focuses Now when clicked; the `N agents need input` toast stays. An empty Now says nothing needs you.
  - Touch points: refresh and identity in `host/engine`, lists and scopes in `host/render`, Inbox code, status segments in `plugin/window.luau`.
  - Cases: ranking order, snooze exclusion, Inbox and filter removal, the single count (`tests/cases/inbox.luau`, `tests/cases/queue.luau`); bench passes. Docs: `docs/reference.md`; mark the LEDGER.md Merge rows for Inbox and the attention filter as done in their Why cell.
  - After: Every item shows its stage, derived from GitHub, Jira, git and its agent

- [ ] An agent's question shows in Now and can be answered there
  - While an agent needs input, its Now row and preview show the agent's last message (read as the Agents list reads it today), with **Reply…** and **Go to agent** (PRODUCT.md › Decisions, the inbox of open questions).
  - Reply… asks for one line and sends it as Message agent… does. Once the agent leaves Needs input, the row leaves Now.
  - An agent that stopped waiting before the reply is sent gets the same toast Message agent… shows today, and nothing is sent.
  - Out of scope: answering an agent's structured choices natively; Go to agent covers those.
  - Touch points: the Message agent flow in `plugin/flows.luau`, Now rows and preview in `host/render`, agent status sync.
  - Cases: reply sent, stale reply refused, row leaves after the state change (`tests/cases/flows.luau`). Docs: `docs/reference.md`.
  - After: Now lists everything that needs me, ranked, first in the sidebar

- [ ] Every action's agent ends with a fixed report that Plotroom reads into the run log
  - Plotroom appends a fixed contract that users cannot edit to every action's prompt, typed prompts included (PRODUCT.md › Principles 7; Decisions, Kata conventions):
    - the agent ends with one fenced `plotroom-report` block of JSON
    - fields: `attention` (`ok`, `stuck` or `needs-human`), `reason`, `commit` (a full SHA or null), `pr` (a URL or null), `evidence` (a list of strings), `blocker` (a string or null)
  - When the turn ends, Plotroom reads the block from the agent's last message. A valid report is stored on the run record and shown on the Agents list row and preview: attention, reason, blocker. A missing or invalid one records "No report".
  - A report is a claim, not an outcome: it never marks work done. Fields are cut to the store cap, and no other agent output is stored.
  - Settings › Actions shows the contract read-only under the prompt editor. Default prompts in `plugin/prompts.luau` drop any wording that conflicts with it.
  - Touch points: job text assembly in `plugin/window.luau`, `plugin/prompts.luau`, `flows.recordResult` and agent status sync, the run log.
  - Cases: a valid, missing, malformed or oversized report (`tests/cases/flows.luau`). Docs: `docs/reference.md` › Actions documents the contract.
  - After: A usage report shows how often each command ran and how each agent run ended
  - After: An agent's question shows in Now and can be answered there

- [ ] Each action declares its outcome, and runs show Verified or Not verified from the facts
  - An action field, **Outcome**, with these choices (PRODUCT.md › Glossary › Outcome):
    - None
    - Review posted: a review or review comment by the action's GitHub login after the run started
    - PR opened: an open or draft PR whose head is the worktree's branch
    - Pushed: the branch on GitHub is at the reported commit
    - Replied to feedback: replies or resolved threads by that login after the run started, plus a push
    - Merged
  - Defaults: Review and Quick review → Review posted; Address feedback → Replied to feedback; Watch → Merged; Implement and Fix → PR opened; Plan → None.
  - When the turn ends (and, for Merged, at each refresh until the PR merges or the agent exits), Plotroom checks the facts as the run's login and records **Verified** or **Not verified** on the run. The result shows on the row, the Agents list, the preview and Now; a Not verified run ranks with Needs you. A report's `stuck` or `needs-human` means Needs you regardless.
  - A fact that cannot be read (rate limit, error) records **Unchecked** and is retried at the next refresh; missing data is never Verified. The usage report adds outcome counts per action (PRODUCT.md › Metrics, row 5).
  - Touch points: `Prompt` in `host/core`, the prompt validator in `host/storage`, Actions rows in `host/settings`, `plugin/github.luau`, the run log.
  - Cases: every outcome Verified, Not verified and Unchecked; defaults; a stored action without the field reads as None. Docs: `docs/reference.md`.
  - After: Every action's agent ends with a fixed report that Plotroom reads into the run log
  - After: Every item shows its stage, derived from GitHub, Jira, git and its agent

- [ ] An action can name a checker that a fresh agent runs against the issue's acceptance criteria
  - An action field, **Checked by**: another action, default none (PRODUCT.md › Glossary › Checker). A new default issue action, **Check**, verifies the work in the worktree against the criteria, posts nothing to GitHub or Jira, and reports pass or fail with findings in its report. It is the default checker of Implement and Fix.
  - When a run finishes with a commit, Plotroom starts the checker as a new agent, never in the builder's pane, on the same item where the checker action runs. A pass marks the run **Checked**; a fail shows the findings in the preview and Now, with the item at Needs you.
  - Acceptance criteria are saved on the run at dispatch: a GitHub issue's task-list lines, or a Jira description's Acceptance criteria section, else the whole description, capped. Builder and checker get the same snapshot as a fixed `{criteria}` block that no agent can change.
  - Settings refuses an action that checks itself. A checker without a checkout asks the way actions do today.
  - Touch points: the `Job`/chain start and `MAX_CHAIN` in `plugin/window.luau`, Actions rows in `host/settings`, prompt variables, `plugin/prompts.luau`, the run log.
  - Cases: checker started fresh; pass; fail; criteria snapshot from both trackers; self-check refused. Docs: `docs/reference.md`.
  - After: Each action declares its outcome, and runs show Verified or Not verified from the facts

- [ ] Chains advance only on Verified runs and stop after three strikes
  - Next action and fix rounds start only after a Verified run or a passing check (PRODUCT.md › Roadmap › Phase 3). A Not verified run stops the chain with a toast and lists the item in Now as Needs you.
  - A failed check starts the builder action again with the checker's findings as `{findings}`. After 3 failed checks on one item, the chain stops at Needs you with "3 failed checks".
  - It also stops after 3 runs in a row on the item with no new commit on its branch ("3 runs without progress"), and after 3 failed agent starts ("3 failed starts").
  - Counters live on the item's runs in the run log and reset when the user starts an action by hand. A plugin reload mid-chain resumes from the run log without starting a duplicate agent.
  - Touch points: chain and next-action logic in `plugin/window.luau`, the run log, Now.
  - Cases: each limit, reset by a manual start, resume after reload without a duplicate (`tests/cases/flows.luau`). Docs: `docs/reference.md`.
  - After: An action can name a checker that a fresh agent runs against the issue's acceptance criteria

- [ ] I can mark a check I disagree with, and the usage report shows checker agreement
  - Commands on an item whose run has a checker verdict offers **Disagree with check…**, with an optional one-line reason, recorded on that run (PRODUCT.md › Metrics, row 6).
  - A checked run counts as agreed once its PR merges, or 7 days after the verdict, unless a disagreement was recorded.
  - The usage report adds checker agreement: checked runs, disagreements, and agreement over the last 20 decided runs, beside the Autopilot gate of 80%.
  - Touch points: the run log, Commands rows in `requests.paletteActions`, the usage report.
  - Cases: agreed by merge, by time, and disagreed; agreement over the last 20 (`tests/cases/flows.luau`). Docs: `docs/reference.md`.
  - After: An action can name a checker that a fresh agent runs against the issue's acceptance criteria

## In-Progress

## Blocked

## Review

## Done
