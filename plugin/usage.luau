--!strict
-- How often each command ran and how each agent run ended, on this machine only: kv `usage` (id -> count and last use,
-- and the day counting began) and kv `runs` (one record per agent run, newest first, at most RUNS_CAP). Ids are
-- "<where>:<what>": "queue:<action id>" (the host's queue actions), "row:<command id>" (Commands rows the window runs),
-- "palette:<command id>" (Tern palette commands) and "action:<name>" (saved actions started). Neither store holds item
-- titles, prompt text or agent output, and a store that cannot be read or is malformed is never written over.

local M = {}

M.USAGE_KEY = "usage"
M.RUNS_KEY = "runs"
M.RUNS_CAP = 1000
local IDS_CAP = 500 -- ids kept; the least recently used goes first
local ID_CAP = 200
local TEXT_CAP = 200

export type Count = { n: number, at: number }
export type Usage = { since: number, counts: { [string]: Count } }
-- `runsIn`: "worktree" or "main checkout"; `started`/`ended`: seconds since the epoch (an old link has no start).
export type Run = { key: string, action: string, kind: string?, model: string?, runsIn: string?, started: number?, ended: number, result: string }

-- `s` as one line of at most `cap` bytes, cut at a character boundary; nil when it is no string or empty.
function M.line(s: any, cap: number): string?
	if type(s) ~= "string" then
		return nil
	end
	local text = string.sub((string.gsub(s, "%c", " ")), 1, cap)
	while #text > 0 and not utf8.len(text) do
		text = string.sub(text, 1, -2)
	end
	return if string.find(text, "%S") then text else nil
end

local function whole(v: any): boolean
	return type(v) == "number" and v >= 0 and v % 1 == 0
end

local function textOk(v: any, cap: number): boolean
	return type(v) == "string" and #v <= cap
end

-- A usage store decoded from kv or JSON, or nil when it is malformed.
function M.parseUsage(v: any): Usage?
	if type(v) ~= "table" or not whole(v.since) or type(v.counts) ~= "table" then
		return nil
	end
	local counts: { [string]: Count } = {}
	for id, c in v.counts do
		if not textOk(id, ID_CAP) or type(c) ~= "table" or not whole(c.n) or not whole(c.at) then
			return nil
		end
		counts[id] = { n = c.n, at = c.at }
	end
	return { since = v.since, counts = counts }
end

-- The saved usage, or nil and why when it cannot be read or is malformed; nothing saved yet is an empty store.
function M.readUsage(): (Usage?, string?)
	local ok, v = pcall(tern.kv.get, M.USAGE_KEY)
	if not ok then
		return nil, "could not be read"
	elseif v == nil then
		return { since = 0, counts = {} }, nil
	end
	local u = M.parseUsage(v)
	return u, if u then nil else "is malformed"
end

-- The text of the host's hidden `main.usage` node: its usage store, or why it cannot be read, as JSON.
-- ponytail: one kv read per render; cache in the block's State if it shows up in a profile.
function M.published(): string
	local u, why = M.readUsage()
	return tern.json.encode(if u then { usage = { since = u.since, counts = u.counts } } else { problem = why })
end

-- Counts one use of `id` now. Nothing is written when the store cannot be read or is malformed.
function M.bump(id: string)
	local key = M.line(id, ID_CAP)
	local u = M.readUsage()
	if not key or not u then
		return
	end
	local now = os.time()
	local c = u.counts[key]
	u.counts[key] = { n = (if c then c.n else 0) + 1, at = now }
	if u.since == 0 then
		u.since = now
	end
	local ids: { string } = {}
	for k in u.counts do
		table.insert(ids, k)
	end
	if #ids > IDS_CAP then
		table.sort(ids, function(a, b)
			return u.counts[a].at > u.counts[b].at
		end)
		for i = IDS_CAP + 1, #ids do
			u.counts[ids[i]] = nil
		end
	end
	pcall(tern.kv.set, M.USAGE_KEY, { since = u.since, counts = u.counts })
end

local function runOf(r: any): Run?
	if
		type(r) ~= "table"
		or not textOk(r.key, ID_CAP)
		or not textOk(r.action, TEXT_CAP)
		or not textOk(r.result, TEXT_CAP)
		or not whole(r.ended)
		or (r.kind ~= nil and not textOk(r.kind, TEXT_CAP))
		or (r.model ~= nil and not textOk(r.model, TEXT_CAP))
		or (r.runsIn ~= nil and not textOk(r.runsIn, TEXT_CAP))
		or (r.started ~= nil and not whole(r.started))
	then
		return nil
	end
	return { key = r.key, action = r.action, kind = r.kind, model = r.model, runsIn = r.runsIn, started = r.started, ended = r.ended, result = r.result }
end

-- The run log, newest first, or nil and why when it cannot be read or is malformed.
function M.readRuns(): ({ Run }?, string?)
	local ok, v = pcall(tern.kv.get, M.RUNS_KEY)
	if not ok then
		return nil, "could not be read"
	elseif v == nil then
		return {}, nil
	elseif type(v) ~= "table" then
		return nil, "is malformed"
	end
	local out: { Run } = {}
	for _, r in v do
		local run = runOf(r)
		if not run then
			return nil, "is malformed"
		end
		table.insert(out, run)
	end
	return out, nil
end

-- Puts `run` first in the log, keeping the newest RUNS_CAP. Nothing is written when the log cannot be read or is malformed.
function M.appendRun(run: Run)
	local runs = M.readRuns()
	local clean = runOf({
		key = M.line(run.key, ID_CAP),
		action = M.line(run.action, TEXT_CAP) or "",
		kind = M.line(run.kind, TEXT_CAP),
		model = M.line(run.model, TEXT_CAP),
		runsIn = M.line(run.runsIn, TEXT_CAP),
		started = run.started,
		ended = run.ended,
		result = M.line(run.result, TEXT_CAP),
	})
	if not runs or not clean then
		return
	end
	local rows: { any } = { clean }
	for i = 1, math.min(#runs, M.RUNS_CAP - 1) do
		table.insert(rows, runs[i])
	end
	pcall(tern.kv.set, M.RUNS_KEY, tern.json.array(rows))
end

local function day(t: number): string
	return os.date("%Y-%m-%d", t) :: string
end

local function duration(s: number): string
	s = math.floor(s + 0.5)
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return (s // 60) .. "m " .. (s % 60) .. "s"
	end
	return (s // 3600) .. "h " .. ((s % 3600) // 60) .. "m"
end

local RESULTS = { "done", "failed", "exited", "closed" }
local WHERE = { queue = "Queue action", row = "Commands row", palette = "Palette command", action = "Action" }
local ORDER = { queue = 1, row = 2, palette = 3, action = 4 }

export type Part<T> = { value: T?, problem: string? }
export type Inputs = {
	host: Part<Usage>, -- the block's host: its "queue:" counts are taken
	here: Part<Usage>, -- this machine: every other count
	runs: Part<{ Run }>,
	name: (id: string) -> string, -- what a count's id is called
}

-- The plain-text report: the counts since the first recorded day, then the runs by action. A part that could not be
-- read is named, and the rest is reported all the same.
function M.report(i: Inputs): string
	local rows: { { where: string, what: string, id: string, c: Count } } = {}
	local since: number? = nil
	local function earliest(t: number?)
		if t and t > 0 and (not since or t < since) then
			since = t
		end
	end
	local function take(u: Usage?, host: boolean)
		if not u then
			return
		end
		earliest(u.since)
		for id, c in u.counts do
			local where, what = string.match(id, "^(%a+):(.+)$")
			if where and WHERE[where] and (where == "queue") == host then
				table.insert(rows, { where = where, what = what :: string, id = id, c = c })
			end
		end
	end
	take(i.host.value, true)
	take(i.here.value, false)
	local runs: { Run } = i.runs.value or {}
	for _, r in runs do
		earliest(r.started or r.ended)
	end
	table.sort(rows, function(a, b)
		if a.where ~= b.where then
			return ORDER[a.where] < ORDER[b.where]
		elseif a.c.n ~= b.c.n then
			return a.c.n > b.c.n
		end
		return a.id < b.id
	end)

	local out = { "Plotroom usage report", if since then "Since " .. day(since :: number) else "Nothing recorded yet" }
	local missing: { string } = {}
	if i.host.problem then
		table.insert(missing, "Usage counts on the block's host " .. i.host.problem .. "; its queue actions are left out.")
	end
	if i.here.problem then
		table.insert(missing, "Usage counts on this machine " .. i.here.problem .. "; its commands and actions are left out.")
	end
	if i.runs.problem then
		table.insert(missing, "The run log " .. i.runs.problem .. "; runs are left out.")
	end
	if #missing > 0 then
		table.insert(out, "")
		table.insert(out, "Missing")
		for _, m in missing do
			table.insert(out, m)
		end
	end

	table.insert(out, "")
	table.insert(out, "Commands")
	for _, r in rows do
		table.insert(out, WHERE[r.where] .. " · " .. i.name(r.id) .. " · " .. r.c.n .. " · last " .. os.date("%Y-%m-%d %H:%M", r.c.at))
	end
	if #rows == 0 then
		table.insert(out, "None")
	end

	table.insert(out, "")
	table.insert(out, "Runs")
	local groups: { [string]: { results: { [string]: number }, times: { number }, n: number } } = {}
	local names: { string } = {}
	for _, r in runs do
		local name = if r.action ~= "" then r.action else "Unnamed"
		local g = groups[name]
		if not g then
			g = { results = {}, times = {}, n = 0 }
			groups[name] = g
			table.insert(names, name)
		end
		g.n += 1
		g.results[r.result] = (g.results[r.result] or 0) + 1
		if r.started and r.ended >= r.started then
			table.insert(g.times, r.ended - r.started)
		end
	end
	table.sort(names, function(a, b)
		return if groups[a].n ~= groups[b].n then groups[a].n > groups[b].n else a < b
	end)
	for _, name in names do
		local g = groups[name]
		local parts: { string } = {}
		for _, res in RESULTS do
			table.insert(parts, res .. " " .. (g.results[res] or 0))
		end
		local others: { string } = {}
		for res, n in g.results do
			if not table.find(RESULTS, res) then
				table.insert(others, res .. " " .. n)
			end
		end
		table.sort(others)
		for _, o in others do
			table.insert(parts, o)
		end
		local median = "unknown"
		local t = g.times
		if #t > 0 then
			table.sort(t)
			local mid = (#t + 1) // 2
			median = duration(if #t % 2 == 1 then t[mid] else (t[mid] + t[mid + 1]) / 2)
		end
		table.insert(out, name .. " · " .. g.n .. (if g.n == 1 then " run" else " runs") .. " · " .. table.concat(parts, ", ") .. " · median " .. median)
	end
	if #names == 0 then
		table.insert(out, "None")
	end
	return table.concat(out, "\n") .. "\n"
end

return M
