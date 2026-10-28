--!strict
-- The queue's one-key shortcuts, shared by the pull request and issue blocks: each action's default key, and kv "keys",
-- which holds the keys this machine changed (action id -> key; "" removes the shortcut, an absent id keeps its default).
-- Only the command palette has a default key: every other action is reached through it until someone binds one.

local M = {}

export type Action = { id: string, label: string, default: string }
export type Map = { [string]: string } -- action id -> its key, "" when removed

local KV = "keys"
local BAD = "Saved keys are malformed; not overwriting them."

-- In the order the Keys page lists them and `action` tries them.
M.ACTIONS = {
	{ id = "down", label = "Move down", default = "" },
	{ id = "up", label = "Move up", default = "" },
	{ id = "worktree", label = "Worktree", default = "" },
	{ id = "goto", label = "Go to tab", default = "" },
	{ id = "agent", label = "Agent picker", default = "" },
	{ id = "agentgo", label = "Go to agent", default = "" },
	{ id = "seen", label = "Mark seen", default = "" },
	{ id = "snooze", label = "Snooze until tomorrow", default = "" },
	{ id = "snoozed", label = "Show or hide snoozed", default = "" },
	{ id = "attention", label = "Needs attention only", default = "" },
	{ id = "sort", label = "Next sort order", default = "" },
	{ id = "wt-cleanup", label = "Find finished worktrees", default = "" },
	{ id = "wt-remove", label = "Remove worktree (Worktrees list)", default = "" },
	{ id = "more", label = "Command palette", default = "." },
	{ id = "search", label = "Search", default = "" },
	{ id = "refresh", label = "Refresh", default = "" },
	{ id = "settings", label = "Settings", default = "" },
	{ id = "help", label = "Shortcut list", default = "" },
} :: { Action }

local function actionOf(id: string): Action?
	for _, a in M.ACTIONS do
		if a.id == id then
			return a
		end
	end
	return nil
end

-- Why `text` cannot be a shortcut at all, or nil: one character that is not a gap ("" is no key, so it is fine).
function M.shape(text: string): string?
	if text ~= "" and (utf8.len(text) ~= 1 or string.find(text, "%s")) then
		return "One key: a single letter, digit or symbol."
	end
	return nil
end

-- The action key `k` triggers, if any.
function M.action(map: Map, k: string): string?
	if k ~= "" then
		for _, a in M.ACTIONS do
			if map[a.id] == k then
				return a.id
			end
		end
	end
	return nil
end

-- What kv holds, given pcall(tern.kv.get, ...)'s answer: the saved keys by action id, or nil and why when they cannot be
-- read or trusted (nothing may overwrite them then).
local function saved(ok: boolean, v: any): ({ [string]: string? }?, string?)
	if not ok then
		return nil, "Saved keys could not be read: " .. tostring(v)
	end
	local out: { [string]: string? } = {}
	if v == nil then
		return out, nil
	end
	if type(v) ~= "table" then
		return nil, BAD
	end
	for id, key in v do
		if type(id) ~= "string" or type(key) ~= "string" or M.shape(key) then
			return nil, BAD
		end
		out[id] = key
	end
	return out, nil
end

-- The key of every action as it works now, and why the saved ones are not in use: with a problem, every action has
-- its default. ponytail: read from kv on every use (a few small reads per key or render), so another block's change
-- needs no notice; cache it in the block's State if that ever shows up in a profile.
function M.load(): (Map, string?)
	local mine, why = saved(pcall(tern.kv.get, KV))
	-- Every key the user saved is theirs first: an action nobody customized keeps its default only when no saved key
	-- already holds it, so a newer built-in shortcut never takes over an older custom binding.
	local taken: { [string]: boolean } = {}
	local own: { [string]: string? } = mine or {}
	for _, key in own do
		if key ~= "" then
			taken[key :: string] = true
		end
	end
	local map: Map = {}
	for _, a in M.ACTIONS do
		local custom = own[a.id]
		map[a.id] = custom or (if taken[a.default] then "" else a.default)
	end
	return map, why
end

-- Saves action `id`'s key ("" removes the shortcut, nil restores the default); an error message or nil. Rereads what is
-- saved and fails closed: unreadable or malformed keys are never overwritten.
function M.save(id: string, key: string?): string?
	local a = actionOf(id)
	local mine, why = saved(pcall(tern.kv.get, KV))
	if not a or not mine then
		return why or "That is no shortcut of the queue."
	end
	mine[id] = if key == nil or (key == a.default and key ~= "") then nil else key
	-- tern.kv.set raises on failure and returns nothing.
	local ok, err = pcall(function(): string?
		tern.kv.set(KV, mine)
		return nil
	end)
	return if ok then nil else "Could not save: " .. tostring(err)
end

-- Why `text` cannot be action `id`'s key given the keys in `map` (load's), or nil; "" removes it.
function M.problem(map: Map, id: string, text: string): string?
	local why = M.shape(text)
	if why then
		return why
	end
	local other = M.action(map, text)
	local a = if other and other ~= id then actionOf(other) else nil
	return if a then "Already the shortcut of " .. a.label .. "." else nil
end

-- The classic one-key set, action id -> key; `preset` binds them in `ACTIONS` order.
local ONE_KEY = {
	down = "j", up = "k", worktree = "w", goto = "g", agent = "a", agentgo = "G", seen = "m", snooze = "z",
	snoozed = "Z", attention = "n", sort = "o", search = "/", refresh = "r", settings = "s", help = "?",
	["wt-cleanup"] = "u", ["wt-remove"] = "d",
} :: { [string]: string }

-- Binds the one-key set to the actions with no key and no saved choice. A preset key another action or `used` (the
-- keys of saved prompt actions) already holds is skipped. Returns the labels of the skipped actions, or nil and why.
function M.preset(used: { [string]: boolean }): ({ string }?, string?)
	local mine, why = saved(pcall(tern.kv.get, KV))
	if not mine then
		return nil, why
	end
	local map = M.load()
	local taken: { [string]: boolean } = {}
	for k in used do
		taken[k] = true
	end
	for _, key in map do
		taken[key] = true
	end
	local skipped: { string } = {}
	local changed = false
	for _, a in M.ACTIONS do
		local key = ONE_KEY[a.id]
		if key and map[a.id] == "" and mine[a.id] == nil then
			if taken[key] then
				table.insert(skipped, a.label .. " (" .. key .. ")")
			else
				mine[a.id] = key
				taken[key] = true
				changed = true
			end
		end
	end
	if changed then
		local ok, err = pcall(function(): string?
			tern.kv.set(KV, mine)
			return nil
		end)
		if not ok then
			return nil, "Could not save: " .. tostring(err)
		end
	end
	return skipped, nil
end

-- The keycaps of action `id`'s button: its key, none when removed.
function M.caps(map: Map, id: string): { string }?
	return if map[id] ~= "" then { map[id] } else nil
end

return M
