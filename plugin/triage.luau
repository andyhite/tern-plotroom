--!strict
-- Triage memory for the queue: per item, the signature last marked seen and an optional snooze, in kv "triage".
-- A snooze ends at `snoozeUntil` or, sooner, when the item's signature is no longer the one recorded as `snoozeSig`.
-- Seen changes only through markSeen: the host calls it for the Mark seen action and when an item's preview is shown, never for an item that is merely listed or fetched.

local M = {}

-- `seenAt` is when markSeen last ran; `at` is when the entry was last written (seen or snoozed), for pruning.
-- `snoozeSig` is the item's signature when it was snoozed (absent on a snooze saved before it was recorded: that one runs to its time).
export type Entry = { seen: string?, seenAt: number?, snoozeUntil: number?, snoozeSig: string?, at: number }
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

-- FNV-1a, 32 bits. The prime is 2^24 + 0x193, so the multiply is done in two parts that stay below 2^53:
-- (h * 2^24) mod 2^32 is the low byte of h shifted up, and h * 0x193 is under 2^41. A direct `h * 16777619` reaches 2^56 and loses low bits.
function M.fnv(s: string, seed: number): number
	local h = seed
	for i = 1, #s do
		h = bit32.bxor(h, s:byte(i))
		h = ((h % 256) * 16777216 + h * 0x193) % 4294967296
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

-- Items are never mutated after normalize, so a signature is hashed once per item table.
local memo: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

function M.signature(kind: string, item: any): string
	local hit = memo[item]
	if hit then
		return hit
	end
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
	local sig = string.format("%08x%08x", M.fnv(s, 2166136261), M.fnv(s, 0x9747b28c))
	memo[item] = sig
	return sig
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
			or (e.snoozeSig ~= nil and (type(e.snoozeSig) ~= "string" or #e.snoozeSig > 64))
			or (e.snoozeUntil ~= nil and type(e.snoozeUntil) ~= "number")
			or (e.seenAt ~= nil and type(e.seenAt) ~= "number") then
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

-- Whether `e`'s snooze still holds for `item`: its time has not come and the item is as it was when snoozed. The
-- signature is hashed only for an entry that has a snooze running. A nil `kind` (an item known by its key alone) has
-- no signature to compare, so its snooze runs to its time.
local function holds(e: Entry?, kind: string?, item: any, now: number): boolean
	if not e or e.snoozeUntil == nil or now >= e.snoozeUntil then
		return false
	end
	return e.snoozeSig == nil or kind == nil or e.snoozeSig == M.signature(kind, item)
end

function M.status(store: Store, kind: string, item: any, now: number): Status
	local key = M.sanitizeKey(item.key)
	local e = if key then store.items[key] else nil
	local snoozed = holds(e, kind, item, now)
	local until_ = if snoozed and e then e.snoozeUntil else nil
	if not e or e.seen == nil then
		return { fresh = "new", snoozed = snoozed, snoozeUntil = until_ }
	end
	return { fresh = if e.seen == M.signature(kind, item) then "seen" else "changed", snoozed = snoozed, snoozeUntil = until_ }
end

-- When `item`'s snooze ends by the clock, while one runs (nil otherwise): no signature is hashed.
function M.snoozeEnd(store: Store, item: any, now: number): number?
	local key = M.sanitizeKey(item.key)
	local e = if key then store.items[key] else nil
	return if e and e.snoozeUntil and now < e.snoozeUntil then e.snoozeUntil else nil
end

-- Whether `item` is snoozed now: it has a snooze running and has not changed since.
function M.snoozed(store: Store, kind: string?, item: any, now: number): boolean
	local key = M.sanitizeKey(item.key)
	return holds(if key then store.items[key] else nil, kind, item, now)
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
		e.seenAt = now
	end
end

-- Snoozing alone does not mark the item seen.
function M.snooze(store: Store, kind: string, item: any, untilTs: number, now: number)
	local e = entry(store, item, now)
	if e then
		e.snoozeUntil = untilTs
		e.snoozeSig = M.signature(kind, item)
	end
end

function M.unsnooze(store: Store, key: string)
	local e = store.items[key]
	if e then
		e.snoozeUntil = nil
		e.snoozeSig = nil
	end
end

-- Local 08:00 of the next calendar day (os.time normalises day overflow).
function M.tomorrow(now: number): number
	local d = os.date("*t", now) :: any
	return os.time({ year = d.year, month = d.month, day = d.day + 1, hour = 8, min = 0, sec = 0 })
end

return M
