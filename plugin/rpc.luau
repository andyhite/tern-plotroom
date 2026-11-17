--!strict
-- The rpc protocol between a window and its blocks' hosts (window `ask` → host/requests), shared by both halves so they
-- cannot drift. A host announces PROTOCOL in its hidden `main.rpc` node; a window asks a host whose announcement lies
-- in [MIN, PROTOCOL]. A change is additive: a new op (or a new optional field) raises PROTOCOL by one and lists the op
-- in SINCE at that protocol, so a window refuses it at once to an older host in range. Removing or reshaping an op
-- raises MIN to the new PROTOCOL and drops the SINCE rows MIN now covers.
local M = {}

M.PROTOCOL = 55
M.MIN = 48
-- op → the protocol that added it; an op not listed is known to every host in range. 48 (MIN): `commit` is gone and a
-- plan (act's or draft's answer) is confirmed in the block's own Confirm overlay, not by the window. 49: `message`, a
-- message for an agent reviewed in the block's Confirm overlay. 50: `fork`, the first agent on a fork's worktree asked
-- in the block's Confirm overlay; the `worktree` and `issue` answers say `fork`. 51: act's `issue-close` takes `reason` and
-- `text` (a closing comment); an older host ignores them and plans the close with GitHub's default reason, which its
-- confirm says. 52: `compose`, text written in the block's Compose overlay (Comment…, Approve…, Request changes…, Type a
-- prompt…, a Draft PR's description). 53: `menu` and `action` answers say an action's `premerge` (Merge the base first)
-- and the `worktree` answer `mergeProblem`; an older host says neither, so no action merges the base first through it.
-- 54: the `worktree` answer says `warning` when the worktree was made but Plotroom could not record it or set its
-- upstream; an older host says nothing, so the window shows no toast for it. 55: `jira-who`, the Jira account acli runs
-- as, read when an issue action with a Move to status starts; `move-status` takes it as `who` and moves nothing once
-- acli is another account or site (an older host moves as whoever acli is then).
M.SINCE = { message = 49, fork = 50, compose = 52, ["jira-who"] = 55 } :: { [string]: number }

return M
