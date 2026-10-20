--!strict
-- Triage memory for the queue: per item, the signature last marked seen and an optional snooze, in kv "triage".
-- Seen changes only through markSeen: the host calls it for the Mark seen action and when an item's preview is shown, never for an item that is merely listed or fetched.
-- An idle, exited or working agent never counts as handling an item; only waiting_input asks for attention.

local M = {}

export type Entry = { seen: string?, snoozeUntil: number?, at: number }
export type Store = { version: number, items: { [string]: Entry } }
export type Status = { fresh: "new" | "changed" | "seen", snoozed: boolean, snoozeUntil: number? }

M.CAP = 2000
local VERSION = 1
local KV = "triage"
local BAD = "Saved triage state is malformed; not overwriting it."

function M.empty(): Store
	return { version = VERSION, items = {} }
end

function M.sanitizeKey(key: any): string?
	if type(key) ~= "string" or #key == 0 or #key > 200 or key:find("[%c]") then
		return nil
	end
	return key
end

local function fnv(s: string, seed: number): number
	local h = seed
	for i = 1, #s do
		h = bit32.band(bit32.bxor(h, s:byte(i)) * 16777619, 0xFFFFFFFF)
	end
	return h
end

local function sortedJoin(list: any): string
	local out: { string } = {}
	if type(list) == "table" then
		for _, v in list do
			table.insert(out, tostring(v))
		end
	end
	table.sort(out)
	return table.concat(out, ",")
end

-- Runs that are not green, by name and status: a check flipping changes the signature even when `updated` does not.
local function runsPart(item: any): string
	local out: { string } = {}
	local runs = item.runs
	if type(runs) == "table" then
		for _, r in runs do
			if type(r) == "table" and r.status ~= "success" then
				table.insert(out, tostring(r.name) .. "=" .. tostring(r.status))
			end
		end
	end
	table.sort(out)
	return #out .. ":" .. table.concat(out, ",")
end

function M.signature(kind: string, item: any): string
	local f: { string }
	if kind == "prs" then
		f = {
			tostring(item.key), tostring(item.state), tostring(item.title), tostring(item.draft),
			tostring(item.review), tostring(item.checks), tostring(item.headSha), tostring(item.comments),
			tostring(item.additions), tostring(item.deletions), tostring(item.files),
			sortedJoin(item.labels), sortedJoin(item.assignees), runsPart(item), tostring(item.runTotal),
		}
	else
		local status = item.status
		f = {
			tostring(item.key), tostring(item.state), tostring(item.title),
			tostring(if type(status) == "table" then status.text else nil),
			tostring(item.category), tostring(item.priority), tostring(item.reason), tostring(item.comments),
			tostring(item.updated), sortedJoin(item.labels), sortedJoin(item.assignees),
		}
	end
	local s = table.concat(f, "\31")
	return string.format("%08x%08x", fnv(s, 2166136261), fnv(s, 0x9747b28c))
end

local function validate(v: any): string?
	if type(v) ~= "table" or v.version ~= VERSION or type(v.items) ~= "table" then
		return BAD
	end
	local n = 0
	for k, e in v.items do
		n += 1
		if n > M.CAP or not M.sanitizeKey(k) or type(e) ~= "table" or type(e.at) ~= "number" then
			return BAD
		end
		if (e.seen ~= nil and (type(e.seen) ~= "string" or #e.seen > 64))
			or (e.snoozeUntil ~= nil and type(e.snoozeUntil) ~= "number") then
			return BAD
		end
	end
	return nil
end
M.validate = validate

function M.load(): (Store?, string?)
	local ok, v = pcall(tern.kv.get, KV)
	if not ok then
		return nil, "Saved triage state could not be read: " .. tostring(v)
	end
	if v == nil then
		return M.empty(), nil
	end
	local bad = validate(v)
	if bad then
		return nil, bad
	end
	return v :: Store, nil
end

-- Drops the oldest entries beyond CAP, keeping still-snoozed ones until nothing else is left to drop.
function M.prune(store: Store, now: number)
	local list: { { key: string, e: Entry } } = {}
	for k, e in store.items do
		table.insert(list, { key = k, e = e })
	end
	local excess = #list - M.CAP
	if excess <= 0 then
		return
	end
	local function active(e: Entry): boolean
		return e.snoozeUntil ~= nil and now < e.snoozeUntil
	end
	table.sort(list, function(a, b)
		local x, y = active(a.e), active(b.e)
		if x ~= y then
			return y
		end
		if a.e.at ~= b.e.at then
			return a.e.at < b.e.at
		end
		return a.key < b.key
	end)
	for i = 1, excess do
		store.items[list[i].key] = nil
	end
end

function M.save(store: Store): string?
	M.prune(store, os.time())
	local bad = validate(store)
	if bad then
		return bad
	end
	local ok, err = pcall(function()
		tern.kv.set(KV, store)
	end)
	return if ok then nil else "Could not save triage state: " .. tostring(err)
end

function M.status(store: Store, kind: string, item: any, now: number): Status
	local key = M.sanitizeKey(item.key)
	local e = if key then store.items[key] else nil
	if not e or e.seen == nil then
		return { fresh = "new", snoozed = e ~= nil and e.snoozeUntil ~= nil and now < e.snoozeUntil, snoozeUntil = if e then e.snoozeUntil else nil }
	end
	local snoozed = e.snoozeUntil ~= nil and now < e.snoozeUntil
	return {
		fresh = if e.seen == M.signature(kind, item) then "seen" else "changed",
		snoozed = snoozed,
		snoozeUntil = if snoozed then e.snoozeUntil else nil,
	}
end

-- Whether `item` is snoozed now: status without hashing the item's signature.
function M.snoozed(store: Store, item: any, now: number): boolean
	local key = M.sanitizeKey(item.key)
	local e = if key then store.items[key] else nil
	return e ~= nil and e.snoozeUntil ~= nil and now < e.snoozeUntil
end

local function entry(store: Store, item: any, now: number): Entry?
	local key = M.sanitizeKey(item.key)
	if not key then
		return nil
	end
	local e = store.items[key]
	if not e then
		e = { at = now }
		store.items[key] = e
	end
	e.at = now
	return e
end

function M.markSeen(store: Store, kind: string, item: any, now: number)
	local e = entry(store, item, now)
	if e then
		e.seen = M.signature(kind, item)
	end
end

-- Snoozing alone does not mark the item seen.
function M.snooze(store: Store, kind: string, item: any, untilTs: number, now: number)
	local e = entry(store, item, now)
	if e then
		e.snoozeUntil = untilTs
	end
end

function M.unsnooze(store: Store, key: string)
	local e = store.items[key]
	if e then
		e.snoozeUntil = nil
	end
end

-- Local 08:00 of the next calendar day (os.time normalises day overflow).
function M.tomorrow(now: number): number
	local d = os.date("*t", now) :: any
	return os.time({ year = d.year, month = d.month, day = d.day + 1, hour = 8, min = 0, sec = 0 })
end

function M.attention(st: Status, agent: string?): boolean
	return agent == "waiting_input" or (st.fresh ~= "seen" and not st.snoozed)
end

return M
