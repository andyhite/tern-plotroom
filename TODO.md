# TODO

## Backlog
- [ ] For Jira, always order statuses (both items and the groups, when grouped) using the status categories, with in-progress at the top, followed by todo, followed by done (if done is included in the filter)
- [ ] Add the ability to create "workflows", which chain together actions in some way so that we know what the next action is to dispatch for an agent

## Todo
- [ ] An Agents entry in the sidebar lists my live agents and what each is working on.
  - A special scope after Worktrees list, like it with no view record: rows for agents that are `working`, `waiting_input` or `idle`; `exited` ones are hidden. Each row shows the item title, the action name, the branch and the state badge, grouped by repository. The count shows in the sidebar; it is in the palette's Views group too.
  - Enter goes to the agent's tab (`flows.goAgent`). The `agentgo` link only parses `owner/repo/number` today, so extend it to Jira keys.
  - Persist action name, branch and title on `Link` (`agent-links`, `recordAgent` call in `window.luau`) and send them with the status map, so rows need no loaded view. Old links without them show key and state only.
  - Bump `RPC_PROTOCOL` and `PROTOCOL` together (the status map shape changes). Update `agentSig` and `engine.agentStatus` validation (size and key caps stay). Never write over a malformed `agent-links`.
  - No new polling: rows ride the 4 s status sync. Host state goes in `core`, glue in `engine`, rows in `render` (mirror `boardOn`/`scopeRows`/`boardProps`).
  - Cases: rows by state, exited hidden, old link, Jira go-to. README: Agents and sidebar sections.

## In-Progress
- [ ] Show both the PR and the issue in the preview when an item's worktree has both.
  - Queue, issue selected: when its worktree's branch is the head of a GitHub PR in the code repo (`gh pr list --head <branch> --state all`), show a Pull request section (number, title, state, link). Skip it when GitHub's linked list already has that PR.
  - Queue, PR selected: when its head branch is a worktree branch noted with an issue (`branch.<b>.plotroomkey`), show an Issue section (key, title, status, link).
  - Worktrees board: a row with an issue `key` but no PR `number` and no tracker `related` looks the PR up by head branch the same way, so a PR the implement agent opened shows. Update `board.select`'s "branch text never does" comment: a head-ref match is GitHub's answer, not a guess.
  - Lookups ride the existing detail loads (debounce, `alive`/`gen` guards); no new polling.
  - Cases: `board_check` enrich by head, one host case per queue preview. README: preview section.

## Review

## Done

- [x] Actions can move a Jira issue to a set status when they run.
  - Add an optional `status` (target status name) to issue-side actions. Settings › Actions gets a "Move to status" text row on the issues side only. Carry it through `Prompt` (core), the `prompts-*` validator and save (storage), export/import (portable `checkPrompt`/`samePrompt`) and the action menu entries (requests).
  - When the agent starts (worktree ready), for a Jira issue only: list its transitions (`jira.transitions`), take the first whose target status matches `status` (case-insensitive), post it (`jira.transition`). No confirm; a toast reports the move.
  - Already in that status → nothing. No matching transition, a transition that needs fields, or no `PLOTROOM_JIRA_API_TOKEN` → error toast naming why, nothing posted. The agent runs either way.
  - GitHub issues and PR actions have no such field.
  - The window asks the host for the move (the token lives in the host env). Bump `RPC_PROTOCOL` and `PROTOCOL` together if the rpc shape changes.
  - Cases: match, no match, already there, no token, export/import round-trip. README: actions section.
