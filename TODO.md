# TODO

## Backlog

## Todo

## In-Progress

- [ ] An Agents entry in the sidebar lists my live agents and what each is working on.
  - Branch: todo/an-agents-entry-in-the-sidebar-lists-my at /Users/andyhite/Code/tern-plotroom.todo/an-agents-entry-in-the-sidebar-lists-my
  - A special scope after Worktrees list, like it with no view record: rows for agents that are `working`, `waiting_input` or `idle`; `exited` ones are hidden. Each row shows the item title, the action name, the branch and the state badge, grouped by repository. The count shows in the sidebar; it is in the palette's Views group too.
  - Enter goes to the agent's tab (`flows.goAgent`). The `agentgo` link only parses `owner/repo/number` today, so extend it to Jira keys.
  - Persist action name, branch and title on `Link` (`agent-links`, `recordAgent` call in `window.luau`) and send them with the status map, so rows need no loaded view. Old links without them show key and state only.
  - Bump `RPC_PROTOCOL` and `PROTOCOL` together (the status map shape changes). Update `agentSig` and `engine.agentStatus` validation (size and key caps stay). Never write over a malformed `agent-links`.
  - No new polling: rows ride the 4 s status sync. Host state goes in `core`, glue in `engine`, rows in `render` (mirror `boardOn`/`scopeRows`/`boardProps`).
  - Cases: rows by state, exited hidden, old link, Jira go-to. README: Agents and sidebar sections.
  - Decided: the `agentgo` link needed no window change. For Jira, the host builds `plotroom://issue/agentgo/<PROJECT>/<KEY>` with the project upper-cased, which the window's issue branch already accepts.
  - Decided: the status map is now `key -> {state, action?, branch?, title?}`. Exited agents carry no texts, and texts stop at 30000 bytes so the report stays under the host's 40000-byte cap.
  - Decided: an `agent-links` row whose action, branch or title is not a string counts as malformed, so the store is never written over.
  - Fix: README.md, plugin/flows.luau, plugin/host/engine.luau, plugin/window.luau - rebase onto main conflicts (main gained the next-action chain work) - rebase onto main, resolve, rerun the gate
  - Fix: plugin/flows.luau (`statusMap`, `INFO_BYTES = 30000`) - unconfirmed: the budget counts raw bytes but the host's 40000-byte cap counts JSON-encoded bytes, so escaped titles or branches could push the report over and drop it - count the escaped size, or lower the budget to about 12000

## Review

## Done

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
