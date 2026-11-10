--!strict
-- The rpc protocol between a window and its blocks' hosts (window `ask` → host/requests), shared by both halves so they
-- cannot drift. A host announces PROTOCOL in its hidden `main.rpc` node; a window asks a host whose announcement lies
-- in [MIN, PROTOCOL]. A change is additive: a new op (or a new optional field) raises PROTOCOL by one and lists the op
-- in SINCE at that protocol, so a window refuses it at once to an older host in range. Removing or reshaping an op
-- raises MIN to the new PROTOCOL and drops the SINCE rows MIN now covers.
local M = {}

M.PROTOCOL = 48
M.MIN = 48
-- op → the protocol that added it; an op not listed is known to every host in range. 48 (MIN): `commit` is gone and a
-- plan (act's or draft's answer) is confirmed in the block's own Confirm overlay, not by the window.
M.SINCE = {} :: { [string]: number }

return M
