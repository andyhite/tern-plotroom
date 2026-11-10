--!strict
-- The rpc protocol between a window and its blocks' hosts (window `ask` → host/requests), shared by both halves so they
-- cannot drift. A host announces PROTOCOL in its hidden `main.rpc` node; a window asks a host whose announcement lies
-- in [MIN, PROTOCOL]. A change is additive: a new op (or a new optional field) raises PROTOCOL by one and lists the op
-- in SINCE at that protocol, so a window refuses it at once to an older host in range. Removing or reshaping an op
-- raises MIN to the new PROTOCOL and drops the SINCE rows MIN now covers.
local M = {}

M.PROTOCOL = 47
M.MIN = 35
-- op → the protocol that added it; an op not listed is known to every host in range. 36: `outcome`, and the actions'
-- optional `outcome` field. 37: `criteria`, and the actions' optional `checker` field. 38: agent-status's optional
-- `stop` field (why an item's chain stopped). 39: agent-status's optional `since` and `expected` fields (a working
-- agent's clock and bar). 40: worktree's optional `failures` field (the `{failures}` block). 41: worktree's optional
-- `premerge` field and its answer's `merge` (an older host ignores it and answers no merge). 42: `models` (Settings ›
-- Actions › Model's picker), and the actions' optional `effort` field. 43: a pull request worktree answer's optional
-- `flaky` field. 44: act's optional `check` field (Ignore this check…). 45: `models` also for `summary:model`
-- (Settings › General › Summary model's picker). Not a SINCE row: only a host at 45 draws that row's button, so only
-- one asks. 46: `review` (when a run's Draft review file was written). 47: review's answer's optional `glimpse` (Settings ›
-- General › Draft review opens Over the agent's tab; an older host never sends it, so its reviews open beside the agent)
-- and agent-status's optional `review` field (Show Draft review).
M.SINCE = { outcome = 36, criteria = 37, models = 42, review = 46 } :: { [string]: number }

return M
