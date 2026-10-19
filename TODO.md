# TODO

## Backlog
- [ ] Let users specify the order statuses are listed in, for both sort order and grouping.
- [ ] Let an action prompt be inserted into a running agent managed by Plotroom (e.g. run the watch action after implement finishes and the PR is open).
- [ ] Add a special view that shows all of my in-progress agents and what they're working on

## Todo
- [ ] Actions can move a Jira issue to a set status when they run.
  - Add an optional `status` (target status name) to issue-side actions. Settings › Actions gets a "Move to status" text row on the issues side only. Carry it through `Prompt` (core), the `prompts-*` validator and save (storage), export/import (portable `checkPrompt`/`samePrompt`) and the action menu entries (requests).
  - When the agent starts (worktree ready), for a Jira issue only: list its transitions (`jira.transitions`), take the first whose target status matches `status` (case-insensitive), post it (`jira.transition`). No confirm; a toast reports the move.
  - Already in that status → nothing. No matching transition, a transition that needs fields, or no `PLOTROOM_JIRA_API_TOKEN` → error toast naming why, nothing posted. The agent runs either way.
  - GitHub issues and PR actions have no such field.
  - The window asks the host for the move (the token lives in the host env). Bump `RPC_PROTOCOL` and `PROTOCOL` together if the rpc shape changes.
  - Cases: match, no match, already there, no token, export/import round-trip. README: actions section.
- [ ] Show both the PR and the issue in the preview when an item's worktree has both.
  - Queue, issue selected: when its worktree's branch is the head of a GitHub PR in the code repo (`gh pr list --head <branch> --state all`), show a Pull request section (number, title, state, link). Skip it when GitHub's linked list already has that PR.
  - Queue, PR selected: when its head branch is a worktree branch noted with an issue (`branch.<b>.plotroomkey`), show an Issue section (key, title, status, link).
  - Worktrees board: a row with an issue `key` but no PR `number` and no tracker `related` looks the PR up by head branch the same way, so a PR the implement agent opened shows. Update `board.select`'s "branch text never does" comment: a head-ref match is GitHub's answer, not a guess.
  - Lookups ride the existing detail loads (debounce, `alive`/`gen` guards); no new polling.
  - Cases: `board_check` enrich by head, one host case per queue preview. README: preview section.

## In-Progress

## Done
