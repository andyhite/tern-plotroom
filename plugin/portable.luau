--!strict
-- Portable export/import of saved views and actions (prompts). Pure: no kv, no process, no paths. An export holds
-- views and prompts only; accounts leave as anonymous slots, and secret-looking prompts, checkouts, paths and setup
-- commands never do. An import is parsed strictly (unknown keys are dropped, never copied), planned against what is
-- saved, then applied to copies of the stores: the host writes the returned shapes.

local M = {}

export type ExView = { id: string, kind: string, name: string, integration: string, query: string, group: string, sort: string?, logins: { string }, prompts: { string } }
export type ExPrompt = { id: string, kind: string, name: string, text: string, key: string?, worktree: boolean?, split: boolean?, model: string?, status: string?, next: string? }
export type DView = { kind: string, name: string, integration: string, query: string, group: string, sort: string?, slots: { string }, prompts: { string } }
export type DPrompt = { ref: string, kind: string, name: string, text: string, key: string?, worktree: boolean?, split: boolean?, model: string?, status: string?, next: string? }
export type Doc = { views: { DView }, prompts: { DPrompt } }
export type Existing = { [string]: { views: { items: { any }, nextId: number }, prompts: { items: { any }, nextId: number } } }
export type Entry = { id: number, type: "view" | "prompt", kind: string, name: string, conflict: ("same-name" | "identical")?, remap: { string }, slots: { string } }
export type Plan = { entries: { Entry }, slots: { string }, problems: { string } }
export type Ok = {
	sortValid: (kind: string, integration: string, sort: string) -> boolean,
	integrationOn: (id: string) -> boolean,
	reserved: { [string]: boolean },
}

M.LIMIT = 60000 -- bytes of one export
-- Keys the queue itself uses; the host fills this before `plan` (apply takes the same set as `ok.reserved`).
M.reservedKeys = {} :: { [string]: boolean }

local FORMAT = "plotroom-export"
local MAX_ITEMS = 100
local NAME_CAP = 120
M.STATUS_CAP = 100 -- bytes of an action's target status name
local QUERY_CAP = 1000
local TEXT_CAP = 8000
local KINDS: { [string]: boolean } = { prs = true, issues = true }
local INTEGRATIONS: { [string]: boolean } = { github = true, jira = true }
local FORBIDDEN = { "setup", "checkout", "path", "token", "secret" }

local function val(x: any): any
	if x == tern.json.null then
		return nil
	end
	return x
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out: { [any]: any } = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function findById(items: { any }, id: string): any
	for _, it in items do
		if it.id == id then
			return it
		end
	end
	return nil
end

local function findByName(items: { any }, name: string): any
	local want = string.lower(name)
	for _, it in items do
		if type(it.name) == "string" and string.lower(it.name) == want then
			return it
		end
	end
	return nil
end

-- A string of at most `cap` bytes without control characters (`multiline`: tabs and line breaks are allowed).
local function clean(s: any, cap: number, multiline: boolean): boolean
	return type(s) == "string" and #s <= cap and not string.find(s, if multiline then "[\0-\8\11\12\14-\31\127]" else "[%c]")
end

local function checkView(v: any): string?
	if type(v) ~= "table" then
		return "not a view"
	elseif not KINDS[v.kind] then
		return "unknown kind"
	elseif not clean(v.name, NAME_CAP, false) or v.name == "" then
		return "a name must be 1 to " .. NAME_CAP .. " characters on one line"
	elseif not INTEGRATIONS[v.integration] then
		return "unknown integration"
	elseif v.kind == "prs" and v.integration ~= "github" then
		return "pull request views are GitHub views"
	elseif not clean(v.query, QUERY_CAP, false) then
		return "a query must be one line of at most " .. QUERY_CAP .. " characters"
	elseif not clean(v.group, NAME_CAP, false) then
		return "a group must be one line of at most " .. NAME_CAP .. " characters"
	elseif v.sort ~= nil and (not clean(v.sort, 40, false) or v.sort == "") then
		return "invalid sort"
	end
	return nil
end

-- Whether an action of kind `from` may name one of kind `to` as its next: its own kind, or an issue action's pull request action.
local function mayChain(from: string, to: string): boolean
	return from == to or (from == "issues" and to == "prs")
end

local function checkPrompt(p: any): string?
	if type(p) ~= "table" then
		return "not an action"
	elseif not KINDS[p.kind] then
		return "unknown kind"
	elseif not clean(p.name, NAME_CAP, false) or p.name == "" then
		return "a name must be 1 to " .. NAME_CAP .. " characters on one line"
	elseif not clean(p.text, TEXT_CAP, true) or p.text == "" then
		return "the text must be 1 to " .. TEXT_CAP .. " bytes"
	elseif p.key ~= nil and (type(p.key) ~= "string" or not string.match(p.key, "^%g$")) then
		return "a shortcut is one visible character"
	elseif p.worktree ~= nil and type(p.worktree) ~= "boolean" then
		return "worktree must be true or false"
	elseif p.split ~= nil and type(p.split) ~= "boolean" then
		return "split must be true or false"
	elseif p.model ~= nil and (not clean(p.model, NAME_CAP, false) or p.model == "") then
		return "invalid model"
	elseif p.status ~= nil and (p.kind ~= "issues" or not clean(p.status, M.STATUS_CAP, false) or p.status == "") then
		return "a status is a name of at most " .. M.STATUS_CAP .. " characters on one line, on an issue action"
	elseif p.next ~= nil and (type(p.next) ~= "string" or not (string.match(p.next, "^%w+$") or (p.kind == "issues" and string.match(p.next, "^prs:%w+$")))) then
		return "next must be the id of another action"
	end
	return nil
end

-- Whether `text` holds something that looks like a credential.
local function secretIn(text: string): boolean
	for tok in string.gmatch(text, "gh[pousr]_%w+") do
		if #tok >= 20 then
			return true
		end
	end
	for tok in string.gmatch(text, "github_pat_[%w_]+") do
		if #tok >= 30 then
			return true
		end
	end
	for tok in string.gmatch(text, "A[KS]IA%w+") do
		if #tok >= 20 then
			return true
		end
	end
	for tok in string.gmatch(text, "[Bb][Ee][Aa][Rr][Ee][Rr]%s+([%w%-%._~%+/]+)") do
		if #tok >= 20 then
			return true
		end
	end
	-- ponytail: literal after `password=`/`passwd=` only; a placeholder ({x}, <x>, $x, [x]) passes. Add entropy checks if it leaks.
	local lower = string.lower(text)
	return string.find(text, "%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY") ~= nil or string.find(lower, "passw[o]?r?d%s*=%s*[^%s{<%$%[]") ~= nil
end

local function array(items: { any }): any
	return tern.json.array(items)
end

function M.build(views: { ExView }, prompts: { ExPrompt }, secretFree: boolean?, pool: { ExPrompt }?): (string?, { string })
	local notes: { string } = {}
	local byRef: { [string]: ExPrompt } = {}
	local none: { ExPrompt } = {}
	for _, p in (pool or none) do
		byRef[p.kind .. ":" .. p.id] = p
	end
	for _, p in prompts do
		byRef[p.kind .. ":" .. p.id] = p
	end

	local outPrompts: { any } = {}
	local included: { [string]: boolean } = {}
	local failed = false
	local function include(ref: string, p: ExPrompt): boolean
		if included[ref] ~= nil then
			return included[ref]
		end
		local why = checkPrompt(p)
		if why then
			table.insert(notes, "Action '" .. tostring(p.name) .. "' left out: " .. why .. ".")
		elseif secretIn(p.text) then
			table.insert(notes, "Action '" .. p.name .. "' left out: its text looks like it holds a secret.")
			failed = secretFree == true
		else
			local item = { id = ref, kind = p.kind, name = p.name, text = p.text, key = p.key, worktree = p.worktree, split = p.split, model = p.model, status = p.status, next = nil :: string? }
			table.insert(outPrompts, item)
			included[ref] = true
			-- The next action travels with it; one that cannot be exported (or no longer exists) is dropped.
			local nref = if p.next then (if p.kind == "issues" and string.match(p.next, "^prs:") then p.next else p.kind .. ":" .. p.next) else nil
			local nextP = if nref then byRef[nref] else nil
			if nref and nextP and mayChain(p.kind, nextP.kind) and include(nref, nextP) then
				item.next = nref
			end
			return true
		end
		included[ref] = false
		return false
	end

	local slotOf: { [string]: string } = {}
	local slotCount = 0
	local outViews: { any } = {}
	for _, v in views do
		local why = checkView(v)
		if why then
			table.insert(notes, "View '" .. tostring(v.name) .. "' left out: " .. why .. ".")
			continue
		end
		local refs: { string } = {}
		for _, id in v.prompts do
			local ref = if string.find(id, ":", 1, true) then id else v.kind .. ":" .. id
			local p = byRef[ref]
			if p and p.kind == v.kind and include(ref, p) then
				table.insert(refs, ref)
			else
				table.insert(notes, "View '" .. v.name .. "' no longer lists an action that could not be exported.")
			end
		end
		local accounts: { string } = {}
		local lowerQuery = string.lower(v.query)
		local mentioned = false
		for _, login in v.logins do
			if not slotOf[login] then
				slotCount += 1
				slotOf[login] = "account-" .. slotCount
			end
			if not table.find(accounts, slotOf[login]) then
				table.insert(accounts, slotOf[login])
			end
			mentioned = mentioned or string.find(lowerQuery, string.lower(login), 1, true) ~= nil
		end
		if mentioned then
			table.insert(notes, "The query of view '" .. v.name .. "' names one of its accounts; edit it before sharing.")
		end
		table.insert(outViews, { kind = v.kind, name = v.name, integration = v.integration, query = v.query, group = v.group, sort = v.sort, accounts = array(accounts), prompts = array(refs) })
	end
	for _, p in prompts do
		include(p.kind .. ":" .. p.id, p)
	end

	if failed then
		return nil, notes
	end
	if #outViews == 0 and #outPrompts == 0 then
		table.insert(notes, "Nothing to export.")
		return nil, notes
	end
	local text = tern.json.encode({ format = FORMAT, version = 1, prompts = array(outPrompts), views = array(outViews) })
	if #text > M.LIMIT then
		table.insert(notes, "The export is " .. #text .. " bytes; the limit is " .. M.LIMIT .. ".")
		return nil, notes
	end
	return text, notes
end

-- The first field name in `v` (at any depth) that could carry a checkout, path, command or credential.
local function forbidden(v: any, depth: number): string?
	if type(v) ~= "table" then
		return nil
	end
	if depth > 6 then
		return "(nesting)"
	end
	for k, x in v do
		if type(k) == "string" then
			local lower = string.lower(k)
			for _, bad in FORBIDDEN do
				if string.find(lower, bad, 1, true) then
					return k
				end
			end
		end
		local found = forbidden(x, depth + 1)
		if found then
			return found
		end
	end
	return nil
end

local function list(v: any, max: number, what: string): ({ any }?, string?)
	v = val(v)
	if v == nil then
		return {}, nil
	elseif type(v) ~= "table" then
		return nil, "The export's " .. what .. " must be a list."
	end
	local n = 0
	for _ in v do
		n += 1
	end
	if n ~= #v then
		return nil, "The export's " .. what .. " must be a list."
	elseif n > max then
		return nil, "The export has more than " .. max .. " " .. what .. "."
	end
	return v, nil
end

function M.parse(text: string): (Doc?, string?)
	if type(text) ~= "string" or #text > M.LIMIT then
		return nil, "The export is larger than " .. M.LIMIT .. " bytes."
	end
	local decoded, data = pcall(tern.json.decode, text)
	if not decoded or type(data) ~= "table" then
		return nil, "That is not an export: it is not JSON."
	elseif data.format ~= FORMAT or data.version ~= 1 then
		return nil, "That is not a version 1 Plotroom export."
	end
	local bad = forbidden(data, 0)
	if bad then
		return nil, "The export has a field named '" .. bad .. "', which an import never accepts."
	end
	local rawPrompts, perr = list(data.prompts, MAX_ITEMS, "actions")
	if not rawPrompts then
		return nil, perr
	end
	local rawViews, verr = list(data.views, MAX_ITEMS, "views")
	if not rawViews then
		return nil, verr
	end

	local doc: Doc = { views = {}, prompts = {} }
	local byRef: { [string]: DPrompt } = {}
	local names: { [string]: boolean } = {}
	for i, raw in rawPrompts do
		if type(raw) ~= "table" then
			return nil, "Action " .. i .. " is invalid: not an action."
		end
		local p = { kind = val(raw.kind), name = val(raw.name), text = val(raw.text), key = val(raw.key), worktree = val(raw.worktree), split = val(raw.split), model = val(raw.model), status = val(raw.status) }
		local nextRef = val(raw.next)
		if nextRef ~= nil and (type(nextRef) ~= "string" or not string.match(nextRef, "^%a+:%w+$")) then
			return nil, "Action " .. i .. " is invalid: next must be the id of another action."
		end
		local ref = val(raw.id)
		local why = if type(raw) ~= "table" then "not an action" else checkPrompt(p)
		if not why and (type(ref) ~= "string" or ref ~= p.kind .. ":" .. (string.match(ref, "^%a+:(%w+)$") or "") or byRef[ref]) then
			why = "an action's id is its kind and a unique name like prs:p1"
		end
		local nameKey = if why then "" else p.kind .. "\n" .. string.lower(p.name)
		if not why and names[nameKey] then
			why = "two actions share a name"
		end
		if why then
			return nil, "Action " .. i .. " is invalid: " .. why .. "."
		end
		names[nameKey] = true
		local item: DPrompt = { ref = ref, kind = p.kind, name = p.name, text = p.text, key = p.key, worktree = p.worktree, split = p.split, model = p.model, status = p.status, next = nextRef }
		byRef[ref] = item
		table.insert(doc.prompts, item)
	end
	-- A next action the document does not hold, of another kind, or that closes a loop is dropped.
	for _, item in doc.prompts do
		local nx = item.next
		if nx then
			local target = byRef[nx]
			local at: DPrompt? = target
			local seen: { [string]: boolean } = {}
			local loops = false
			while at and not seen[at.ref] do
				if at.ref == item.ref then
					loops = true
					break
				end
				seen[at.ref] = true
				at = if at.next then byRef[at.next] else nil
			end
			if not target or not mayChain(item.kind, target.kind) or loops then
				item.next = nil
			end
		end
	end

	names = {}
	for i, raw in rawViews do
		if type(raw) ~= "table" then
			return nil, "View " .. i .. " is invalid: not a view."
		end
		local v = { kind = val(raw.kind), name = val(raw.name), integration = val(raw.integration), query = val(raw.query), group = val(raw.group), sort = val(raw.sort) }
		local why = if type(raw) ~= "table" then "not a view" else checkView(v)
		if why then
			return nil, "View " .. i .. " is invalid: " .. why .. "."
		end
		local nameKey = v.kind .. "\n" .. string.lower(v.name)
		if names[nameKey] then
			return nil, "View " .. i .. " is invalid: two views share a name."
		end
		names[nameKey] = true
		local accounts, aerr = list(raw.accounts, 20, "accounts")
		local refs, rerr = list(raw.prompts, MAX_ITEMS, "view actions")
		if not accounts or not refs then
			return nil, "View " .. i .. " is invalid: " .. (aerr or rerr or "bad list") .. ""
		end
		local slots: { string } = {}
		for _, s in accounts do
			if type(s) ~= "string" or not string.match(s, "^account%-%d+$") then
				return nil, "View " .. i .. " is invalid: an account is a slot like account-1."
			end
			if not table.find(slots, s) then
				table.insert(slots, s)
			end
		end
		local outRefs: { string } = {}
		for _, r in refs do
			local target = if type(r) == "string" then byRef[r] else nil
			if not target or target.kind ~= v.kind then
				return nil, "View " .. i .. " is invalid: it lists an action the export does not hold."
			end
			table.insert(outRefs, r)
		end
		table.insert(doc.views, { kind = v.kind, name = v.name, integration = v.integration, query = v.query, group = v.group, sort = v.sort, slots = slots, prompts = outRefs })
	end
	if #doc.views == 0 and #doc.prompts == 0 then
		return nil, "The export holds no views or actions."
	end
	return doc, nil
end

-- Names (lowercase, in order) of the actions `ids` pick from `items`, as one comparable string.
local function namesOf(ids: { any }, items: { any }): string
	local out: { string } = {}
	for _, id in ids do
		for _, p in items do
			if p.id == id then
				table.insert(out, string.lower(p.name))
			end
		end
	end
	return table.concat(out, "\n")
end

local function samePrompt(p: DPrompt, e: any, nextName: string, savedNextName: string): boolean
	return p.text == e.text and p.key == e.key and (p.worktree ~= false) == (e.worktree ~= false) and (p.split == true) == (e.split == true) and (p.model or "") == (e.model or "") and (p.status or "") == (e.status or "") and nextName == savedNextName
end

-- Who holds `key` among `items` (not the item `skipId`) or the reserved keys; nil when it is free.
local function keyHolder(items: { any }, key: string, reserved: { [string]: boolean }, skipId: string?): string?
	if reserved[key] then
		return "a Plotroom shortcut"
	end
	for _, it in items do
		if it.key == key and it.id ~= skipId then
			return tostring(it.name)
		end
	end
	return nil
end

function M.plan(doc: Doc, existing: Existing): Plan
	local plan: Plan = { entries = {}, slots = {}, problems = {} }
	local refName: { [string]: string } = {}
	local refQual: { [string]: string } = {}
	for _, p in doc.prompts do
		refName[p.ref] = string.lower(p.name)
		refQual[p.ref] = p.kind .. ":" .. string.lower(p.name)
	end
	local unknown: { [string]: boolean } = {}
	local function known(kind: string): boolean
		if existing[kind] then
			return true
		end
		if not unknown[kind] then
			unknown[kind] = true
			table.insert(plan.problems, "Saved " .. kind .. " cannot be imported into right now.")
		end
		return false
	end

	local n = 0
	for _, v in doc.views do
		n += 1
		local remap: { string } = {}
		local found: any = if known(v.kind) then findByName(existing[v.kind].views.items, v.name) else nil
		local conflict: ("same-name" | "identical")? = nil
		if found then
			local mine: { string } = {}
			for _, r in v.prompts do
				table.insert(mine, refName[r] or "")
			end
			conflict = "same-name"
			if #v.slots == 0 and #found.logins == 0 and found.integration == v.integration and found.query == v.query and found.group == v.group and found.sort == v.sort and namesOf(found.prompts, existing[v.kind].prompts.items) == table.concat(mine, "\n") then
				conflict = "identical"
			end
		end
		for _, s in v.slots do
			table.insert(remap, "runs as account slot " .. s)
			if not table.find(plan.slots, s) then
				table.insert(plan.slots, s)
			end
		end
		table.insert(plan.entries, { id = n, type = "view", kind = v.kind, name = v.name, conflict = conflict, remap = remap, slots = table.clone(v.slots) })
	end

	local claimed: { [string]: { any } } = {} -- kind -> keys this document's earlier actions keep
	for _, p in doc.prompts do
		n += 1
		local remap: { string } = {}
		local conflict: ("same-name" | "identical")? = nil
		local found: any = nil
		if known(p.kind) then
			found = findByName(existing[p.kind].prompts.items, p.name)
			if found then
				local pn = if p.next then refQual[p.next] or "" else ""
				local savedNext: any = nil
				local savedKind = p.kind
				if found.next then
					local qualified = if p.kind == "issues" then string.match(found.next, "^prs:(.+)$") else nil
					savedKind = if qualified then "prs" else p.kind
					local from = existing[savedKind]
					savedNext = if from then findById(from.prompts.items, qualified or found.next) else nil
				end
				conflict = if samePrompt(p, found, pn, if savedNext then savedKind .. ":" .. string.lower(savedNext.name) else "") then "identical" else "same-name"
			end
		end
		if p.key and existing[p.kind] then
			claimed[p.kind] = claimed[p.kind] or {}
			local pool: { any } = table.clone(existing[p.kind].prompts.items)
			for _, c in claimed[p.kind] do
				table.insert(pool, c)
			end
			local holder = keyHolder(pool, p.key, M.reservedKeys, if found then found.id else nil)
			if holder then
				table.insert(remap, "shortcut " .. p.key .. " removed: already used by " .. holder)
			else
				table.insert(claimed[p.kind], { id = "\0claimed", name = p.name, key = p.key })
			end
		end
		table.insert(plan.entries, { id = n, type = "prompt", kind = p.kind, name = p.name, conflict = conflict, remap = remap, slots = {} })
	end
	return plan
end

-- `name` made unique among `items` as "X (imported)", "X (imported 2)", ... within the name cap.
local function uniqueName(items: { any }, name: string): string
	local stem = string.sub(name, 1, NAME_CAP - 16)
	while #stem > 0 and not utf8.len(stem) do
		stem = string.sub(stem, 1, #stem - 1)
	end
	local try = stem .. " (imported)"
	local n = 1
	while findByName(items, try) do
		n += 1
		try = stem .. " (imported " .. n .. ")"
	end
	return try
end

function M.apply(doc: Doc, plan: Plan, choices: { [number]: string }, mapping: { [string]: string }, existing: Existing, ok: Ok): ({ [string]: { views: any, prompts: any } }?, { string })
	if #plan.entries ~= #doc.views + #doc.prompts then
		return nil, { "The import plan does not match the export." }
	end
	local out: { [string]: { views: any, prompts: any } } = {}
	local notes: { string } = {}
	local function work(kind: string): { views: any, prompts: any }
		local w = out[kind]
		if not w then
			w = { views = deepCopy(existing[kind].views), prompts = deepCopy(existing[kind].prompts) }
			out[kind] = w
		end
		return w
	end
	-- Conflicts default to skip, the rest to add; an unknown choice is the default.
	local function choiceOf(id: number, conflict: boolean): string
		local c = choices[id]
		if conflict then
			return if c == "replace" or c == "duplicate" then c else "skip"
		end
		return if c == "skip" then "skip" else "add"
	end

	local promptId: { [string]: string } = {} -- export ref -> the saved id it ended as
	local applied: { [string]: any } = {} -- export ref -> the saved prompt this import wrote
	for i, p in doc.prompts do
		local ex = existing[p.kind]
		if not ex then
			table.insert(notes, "Action '" .. p.name .. "' skipped: " .. p.kind .. " cannot be imported into right now.")
			continue
		end
		local current = if out[p.kind] then out[p.kind].prompts else ex.prompts
		local found = findByName(current.items, p.name)
		local choice = choiceOf(#doc.views + i, found ~= nil)
		if choice == "skip" then
			if found then
				promptId[p.ref] = found.id
			end
			table.insert(notes, "Action '" .. p.name .. "' skipped.")
			continue
		end
		local store = work(p.kind).prompts
		local target = if choice == "replace" then findByName(store.items, p.name) else nil
		local name = if choice == "duplicate" then uniqueName(store.items, p.name) else p.name
		local key = p.key
		if key then
			local holder = keyHolder(store.items, key, ok.reserved, if target then target.id else nil)
			if holder then
				table.insert(notes, "Action '" .. name .. "': shortcut " .. key .. " removed, already used by " .. holder .. ".")
				key = nil
			end
		end
		if not target then
			target = { id = "p" .. store.nextId }
			store.nextId += 1
			table.insert(store.items, target)
		end
		target.name, target.text, target.key, target.worktree, target.split, target.model, target.status = name, p.text, key, p.worktree, p.split, p.model, p.status
		applied[p.ref] = target
		promptId[p.ref] = target.id
	end
	-- Each written action's next action, remapped to saved ids; one that was skipped away, or would close a loop among the
	-- saved actions, is dropped.
	for _, p in doc.prompts do
		local target = applied[p.ref]
		if target then
			target.next = nil
			local nk = if p.next then string.match(p.next, "^(%a+):") else nil
			local nid = if p.next then promptId[p.next] else nil
			if nid and nk and nk ~= p.kind then
				target.next = nk .. ":" .. nid -- an issue action's pull request action; mayChain let nothing else through
			elseif nid and nid ~= target.id then
				local items = out[p.kind].prompts.items
				local at: any = findById(items, nid)
				local seen: { [string]: boolean } = {}
				local loops = false
				while at and not seen[at.id] do
					if at.id == target.id then
						loops = true
						break
					end
					seen[at.id] = true
					at = if at.next then findById(items, at.next) else nil
				end
				if not loops then
					target.next = nid
				end
			end
		end
	end

	for i, v in doc.views do
		local ex = existing[v.kind]
		local function skip(why: string)
			table.insert(notes, "View '" .. v.name .. "' skipped: " .. why)
		end
		if not ex then
			skip(v.kind .. " cannot be imported into right now.")
			continue
		end
		local current = if out[v.kind] then out[v.kind].views else ex.views
		local found = findByName(current.items, v.name)
		local choice = choiceOf(i, found ~= nil)
		if choice == "skip" then
			skip("kept as it is.")
		elseif not ok.integrationOn(v.integration) then
			skip(v.integration .. " is not turned on.")
		elseif v.sort and not ok.sortValid(v.kind, v.integration, v.sort) then
			skip("its sort order is not available.")
		else
			local logins: { string } = {}
			local blocked: string? = nil
			for _, slot in v.slots do
				local login = mapping[slot]
				if login == nil then
					blocked = "no account was chosen for " .. slot .. "."
					break
				elseif login ~= "" and not string.match(login, "^[%w%-_]+$") then
					blocked = "the account chosen for " .. slot .. " is not a login."
					break
				elseif login ~= "" and not table.find(logins, login) then
					table.insert(logins, login)
				end
			end
			if blocked then
				skip(blocked)
			else
				local store = work(v.kind).views
				local target = if choice == "replace" then findByName(store.items, v.name) else nil
				local name = if choice == "duplicate" then uniqueName(store.items, v.name) else v.name
				local refs: { string } = {}
				for _, r in v.prompts do
					local id = promptId[r]
					if id and not table.find(refs, id) then
						table.insert(refs, id)
					end
				end
				if not target then
					target = { id = v.kind .. ":v" .. store.nextId, kind = v.kind }
					store.nextId += 1
					table.insert(store.items, target)
				end
				target.name, target.integration, target.query, target.group, target.sort, target.logins, target.prompts = name, v.integration, v.query, v.group, v.sort, logins, refs
			end
		end
	end
	return out, notes
end

return M
