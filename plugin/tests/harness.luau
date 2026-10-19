--!strict
-- The world every regression case runs in: a fake Tern SDK with a virtual clock (timers and os.time), process
-- runner, kv store, filesystem, JSON, UI builders and block host, plus semantic gh and git models, and the
-- assertions and scenes shared by the case files in tests/cases. The fakes keep state and fail the way the SDK
-- documents (fs and kv raise, spawns raise, timeouts kill), so a case checks outcomes: toasts, kv, files, argv,
-- rendered text. It never touches the network, a real repository or the user's files.

local M = {}

export type Require = (string) -> any
export type Loader = (any, any) -> Require

export type Github = typeof(require("../github"))
export type Jira = typeof(require("../jira"))

-- 2026-10-12T12:00:00Z: where every world's clock starts.
local EPOCH = 1791806400
M.EPOCH = EPOCH

-- ---------------------------------------------------------------- assertions

local NULL: any = setmetatable({}, {
	__tostring = function(): string
		return "null"
	end,
})
M.NULL = NULL
local arrayTags: { [any]: boolean } = (setmetatable({}, { __mode = "k" }) :: any)

-- The SDK tags an array with a protected metatable: table.clone refuses it ("table has a protected metatable").
local function tagArray(list: any): any
	arrayTags[list] = true
	if getmetatable(list) == nil then
		setmetatable(list, { __metatable = "protected" })
	end
	return list
end

local ESCAPES: { [string]: string } = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function quote(s: string): string
	local body = string.gsub(s, '[%c"\\]', function(c: string): string
		return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. body .. '"'
end

local function isArray(t: any): boolean
	if arrayTags[t] then
		return true
	end
	local n = 0
	for _ in t do
		n += 1
	end
	if n == 0 then
		return false
	end
	for i = 1, n do
		if t[i] == nil then
			return false
		end
	end
	return true
end

local function jsonInto(v: any, out: { string }, depth: number)
	local kind = type(v)
	if v == nil or v == NULL then
		table.insert(out, "null")
	elseif kind == "boolean" then
		table.insert(out, if v then "true" else "false")
	elseif kind == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			error("json: cannot encode a non-finite number", 0)
		end
		table.insert(out, if v == math.floor(v) and math.abs(v) < 1e15 then string.format("%d", v) else string.format("%.17g", v))
	elseif kind == "string" then
		table.insert(out, quote(v))
	elseif kind == "table" then
		if depth > 64 then
			error("json: nesting is too deep", 0)
		end
		if isArray(v) then
			table.insert(out, "[")
			for i = 1, #v do
				if i > 1 then
					table.insert(out, ",")
				end
				jsonInto(v[i], out, depth + 1)
			end
			table.insert(out, "]")
		else
			local keys: { string } = {}
			for k in v do
				if type(k) ~= "string" then
					error("json: object keys must be strings", 0)
				end
				table.insert(keys, k)
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, k in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, quote(k))
				table.insert(out, ":")
				jsonInto(v[k], out, depth + 1)
			end
			table.insert(out, "}")
		end
	else
		error("json: cannot encode a " .. kind, 0)
	end
end

-- Compact JSON with sorted keys: tables with keys 1..n (or tagged by json.array) are arrays.
local function jsonEncode(v: any): string
	local out: { string } = {}
	jsonInto(v, out, 0)
	return table.concat(out)
end
M.jsonEncode = jsonEncode

local function jsonDecode(text: string): any
	local pos = 1
	local function where(message: string): string
		return "json: " .. message .. " at byte " .. pos
	end
	local function skip()
		pos = string.find(text, "[^ \t\r\n]", pos) or (#text + 1)
	end
	local parseValue: () -> any
	local function parseString(): string
		local out: { string } = {}
		pos += 1
		while true do
			local stop = string.find(text, '["\\%c]', pos)
			if not stop then
				error(where("unterminated string"), 0)
			end
			table.insert(out, string.sub(text, pos, stop - 1))
			local c = string.sub(text, stop, stop)
			if c == '"' then
				pos = stop + 1
				return table.concat(out)
			elseif c ~= "\\" then
				error(where("control character in string"), 0)
			end
			local e = string.sub(text, stop + 1, stop + 1)
			pos = stop + 2
			if e == "u" then
				local cp = tonumber(string.sub(text, pos, pos + 3), 16)
				if not cp then
					error(where("bad \\u escape"), 0)
				end
				pos += 4
				if cp >= 0xD800 and cp <= 0xDBFF and string.sub(text, pos, pos + 1) == "\\u" then
					local lo = tonumber(string.sub(text, pos + 2, pos + 5), 16)
					if lo and lo >= 0xDC00 and lo <= 0xDFFF then
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
						pos += 6
					end
				end
				table.insert(out, utf8.char(cp))
			elseif e == "n" then
				table.insert(out, "\n")
			elseif e == "t" then
				table.insert(out, "\t")
			elseif e == "r" then
				table.insert(out, "\r")
			elseif e == "b" then
				table.insert(out, "\b")
			elseif e == "f" then
				table.insert(out, "\f")
			elseif e == '"' or e == "\\" or e == "/" then
				table.insert(out, e)
			else
				error(where("bad escape"), 0)
			end
		end
	end
	parseValue = function(): any
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			local obj: { [string]: any } = {}
			pos += 1
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then
					error(where("expected a key"), 0)
				end
				local key = parseString()
				skip()
				if string.sub(text, pos, pos) ~= ":" then
					error(where("expected ':'"), 0)
				end
				pos += 1
				local value = parseValue()
				if value ~= NULL then
					obj[key] = value -- null members are dropped, as the SDK does
				end
				skip()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "}" then
					return obj
				elseif sep ~= "," then
					error(where("expected ',' or '}'"), 0)
				end
			end
		elseif c == "[" then
			local list: { any } = {}
			tagArray(list)
			pos += 1
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return list
			end
			while true do
				table.insert(list, parseValue())
				skip()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "]" then
					return list
				elseif sep ~= "," then
					error(where("expected ',' or ']'"), 0)
				end
			end
		elseif c == '"' then
			return parseString()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4
			return NULL
		end
		local literal = string.match(text, "^-?[0-9][0-9.eE+-]*", pos)
		local n = if literal then tonumber(literal) else nil
		if not literal or not n then
			error(where("unexpected character"), 0)
		end
		pos += #literal
		return n
	end
	local result = parseValue()
	skip()
	if pos <= #text then
		error(where("trailing characters"), 0)
	end
	return if result == NULL then nil else result
end
M.jsonDecode = jsonDecode

local function show(v: any): string
	if type(v) == "string" then
		return '"' .. v .. '"'
	elseif type(v) == "table" then
		local ok, text = pcall(jsonEncode, v)
		return if ok then text else "<table>"
	end
	return tostring(v)
end
M.show = show

-- Assertions are plain functions over `any` (no assert refinement), blaming the calling line.
local function eq(actual: any, expected: any, what: string)
	if actual ~= expected then
		error(what .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
	end
end
M.eq = eq

local function same(actual: any, expected: any, what: string)
	local a, b = show(actual), show(expected)
	if a ~= b then
		error(what .. ": expected " .. b .. ", got " .. a, 2)
	end
end
M.same = same

local function yes(cond: any, what: string)
	if not cond then
		error(what, 2)
	end
end
M.yes = yes

local function has(text: any, needle: string, what: string)
	if type(text) ~= "string" or not string.find(text, needle, 1, true) then
		error(what .. ": expected text containing " .. show(needle) .. ", got " .. show(text), 2)
	end
end
M.has = has

local function lacks(text: any, needle: string, what: string)
	if type(text) == "string" and string.find(text, needle, 1, true) then
		error(what .. ": did not expect " .. show(needle) .. " in " .. show(text), 2)
	end
end
M.lacks = lacks

local function keyOf(name: string, mods: string?, text: string?): Key
	local m = mods or ""
	return {
		name = name,
		text = text,
		ctrl = string.find(m, "c", 1, true) ~= nil,
		alt = string.find(m, "a", 1, true) ~= nil,
		shift = string.find(m, "s", 1, true) ~= nil,
		meta = string.find(m, "m", 1, true) ~= nil,
	}
end
M.keyOf = keyOf

-- ---------------------------------------------------------------- the fake SDK

export type Toast = { level: string, text: string, sub: string? }
export type Call = { argv: { string }, cwd: string?, env: { [string]: string }, stdin: string?, timeoutMs: number?, at: number }
export type Reply = {
	status: number?,
	stdout: string?,
	stderr: string?,
	delay: number?,
	timedOut: boolean?,
	raise: string?,
	repeatCallback: boolean?, -- a misbehaving runtime that reports one process twice
}
export type Responder = (Call) -> Reply?
export type PaneRow = { pane: number, cwd: string? }
export type Event = { at: number, seq: number, run: () -> (), live: boolean }
export type WinPane = { block: string?, cwd: string, tab: number }

-- The window half of the world: sessions, tabs and panes that answer like cx.session/layout/hosts do. A nil from
-- new_tab is the SDK's "no pane" answer; "raise" is a failing call.
export type Win = {
	panes: { [number]: WinPane },
	tabs: { { id: number, session: number } },
	sessions: { number },
	focused: number?,
	surfaces: { [number]: any }, -- pane -> { main, dock, layer } regions of TSP nodes
	events: { { pane: number, ev: { [string]: any } } },
	switches: { number },
	launches: { { [string]: any } },
	tabNames: { [number]: string },
	browser: { any },
	remoteHost: boolean,
	newTab: string, -- "ok" | "nil" | "raise"
	picks: { any }, -- every cx:pick request
	choose: (string | { string })?, -- the label(s) cx:pick answers with: the first item a pick offers under one of them; nil, or no match, dismisses it
	decide: ((any) -> (string?, boolean?))?, -- answers a pick from its request instead of `choose`: the label to take (nil dismisses) and whether the answer arrives without a window cx
	typed: string?, -- what cx:prompt answers with; nil dismisses it
	agents: { any }, -- every cx.agents:start request
	agentStates: { [number]: string }, -- agent pane -> state cx.agents:list reports (a started agent is "working"; a closed pane is not listed)
	prompts: { any }, -- every cx:prompt request
	typedQueue: { string }, -- answers cx:prompt gives first, in order, before `typed`
	hostOf: { [number]: number }, -- pane -> host id (default 1)
	handlers: { [string]: any }, -- tern.on registrations by event name
	runs: { { pane: number, text: string } }, -- every cx:run (text typed into a pane)
	status: ((any) -> { any }?)?, -- the tern.chrome.status formatter
	refreshes: number, -- tern.chrome.refresh calls
	reads: { [number]: number }, -- pane -> cx.session:surface reads
}

export type Kv = {
	store: { [string]: string }, -- key -> JSON text, exactly what the SDK would keep on disk
	failGet: { [string]: string }, -- key (or "*") -> the error tern.kv.get raises
	failSet: { [string]: string },
	get: (string) -> any, -- decoded value, bypassing failures
	put: (string, any) -> (), -- seeds a value, bypassing failures
}

export type Fs = {
	files: { [string]: string },
	dirs: { [string]: boolean },
	denyMkdir: { [string]: string }, -- path -> the error tern.fs.mkdir raises
	mkdirs: { string }, -- every directory mkdir created, in order
}

export type Block = {
	pane: number,
	cx: any,
	state: () -> any,
	renders: () -> number,
	saved: () -> any,
	render: () -> any,
	view: () -> any, -- the last view rendered, without rendering again
	press: (string, string?, string?) -> boolean?,
	typeText: (string) -> (),
	event: ({ [string]: any }) -> (),
	text: () -> string,
	title: () -> string?,
	close: () -> (),
}

export type World = {
	context: string,
	sdk: any,
	load: Require,
	now: () -> number,
	seconds: () -> number,
	advance: (number) -> (),
	flush: () -> (),
	env: { [string]: string? },
	toasts: { Toast },
	opened: { string },
	copied: { string },
	frames: { { pane: number, ops: any } }, -- every cx:frame, oldest first: the ops a block sent its view (a focus move)
	calls: { Call },
	respond: (Responder) -> (),
	kv: Kv,
	fs: Fs,
	panes: { PaneRow },
	blocks: { [string]: any },
	open: (number, { string }?, any?) -> Block, -- pane, launch args, saved state: the Plotroom block, `prs`
	setEncodeViews: (boolean) -> (),
	window: Win,
	cx: any, -- the window's cx: what callbacks receive in a window world
	link: (Block) -> (), -- makes `block` the window's pane of the same id: events reach it, its opens are link clicks there, its main region is what the window reads
	click: (string, number?) -> any,
	command: (string) -> (),
	finish: () -> (),
}

local function collectTexts(v: any, out: { string })
	if type(v) == "string" then
		table.insert(out, v)
	elseif type(v) == "table" and v ~= NULL then
		for _, child in v do
			collectTexts(child, out)
		end
	end
end
M.collectTexts = collectTexts

local function parentOf(path: string): string
	local p = string.match(path, "^(.*)/[^/]*$")
	if p == nil or p == "" then
		return "/"
	end
	return p
end

local function cleanPath(path: string): string
	local c = string.gsub(path, "/+$", "")
	return if c == "" then "/" else c
end

-- A view node as the window reads it from a surface: ids are the dotted keys from the region down.
local function tspOf(node: any, id: string): any
	if type(node) ~= "table" then
		return nil
	end
	local out: { [string]: any } = { id = id, p = node.p }
	if type(node.c) == "table" then
		local kids: { any } = {}
		for _, child in node.c do
			local key = if type(child) == "table" and type(child.p) == "table" then child.p.key else nil
			table.insert(kids, tspOf(child, if type(key) == "string" then id .. "." .. key else id))
		end
		out.c = kids
	end
	return out
end

local function newWorld(instantiate: Loader, context: string): World
	local nowMs = 0
	local seq = 0
	local queue: { Event } = {}
	local env: { [string]: string? } = {}
	local toasts: { Toast } = {}
	local opened: { string } = {}
	local copied: { string } = {}
	local frames: { { pane: number, ops: any } } = {}
	local calls: { Call } = {}
	-- gh and acli start unless a model of them says otherwise (newGh, newAcli answer first): a block asks each for its
	-- --version before it lists any view, and once acli starts, whether the Jira site has sprints (it has).
	local responders: { Responder } = {
		function(call: Call): Reply?
			local argv = call.argv
			if (argv[1] == "gh" or argv[1] == "acli") and argv[2] == "--version" and #argv == 2 then
				return { stdout = argv[1] .. " version 1.0.0\n" }
			end
			if argv[1] == "acli" and argv[4] == "search" and argv[#argv] == "--count" then
				return { stdout = "✓ Number of work items in the search: 0\n" }
			end
			return nil
		end,
	}
	local unmatched: { string } = {}
	local panes: { PaneRow } = {}
	local blocks: { [string]: any } = {}
	local encodeViews = true
	local windowCx: any = nil
	local commands: { [string]: any } = {}
	local routes: { [string]: any } = {}
	local linked: { [number]: Block } = {}

	-- virtual time: events run in (time, creation) order
	local function schedule(delayMs: number, run: () -> ()): Event
		seq += 1
		local ev: Event = { at = nowMs + math.max(0, delayMs), seq = seq, run = run, live = true }
		table.insert(queue, ev)
		return ev
	end

	local function runUntil(limit: number)
		local guard = 0
		while true do
			local best: Event? = nil
			local live: { Event } = {}
			for _, ev in queue do
				if ev.live then
					table.insert(live, ev)
					if ev.at <= limit and (best == nil or ev.at < best.at or (ev.at == best.at and ev.seq < best.seq)) then
						best = ev
					end
				end
			end
			queue = live
			if best == nil then
				return
			end
			best.live = false
			nowMs = math.max(nowMs, best.at)
			best.run()
			guard += 1
			if guard > 100000 then
				error("virtual clock: more than 100000 events before " .. limit .. " ms", 0)
			end
		end
	end

	local function advance(ms: number)
		local limit = nowMs + ms
		runUntil(limit)
		nowMs = math.max(nowMs, limit)
	end

	local win: Win = {
		panes = { [1] = { block = "plugin.plotroom.prs", cwd = "/work/r", tab = 1 } },
		tabs = { { id = 1, session = 1 } },
		sessions = { 1 },
		focused = 1,
		surfaces = {},
		events = {},
		switches = {},
		launches = {},
		tabNames = {},
		browser = {},
		remoteHost = false,
		newTab = "ok",
		picks = {},
		agents = {},
		runs = {},
		agentStates = {},
		prompts = {},
		typedQueue = {},
		hostOf = {},
		handlers = {},
		refreshes = 0,
		reads = {},
	}
	local nextId = 10

	local function addPane(launch: any, tab: number?): number
		nextId += 1
		local tabId = tab or nextId
		win.panes[nextId] = { block = if launch then launch.block else nil, cwd = if launch and launch.cwd then launch.cwd else "", tab = tabId }
		if not tab then
			table.insert(win.tabs, { id = tabId, session = 1 })
		end
		table.insert(win.launches, launch or {})
		return nextId
	end

	windowCx = {
		toast = function(_self: any, level: string, text: string, sub: string?)
			table.insert(toasts, { level = level, text = text, sub = sub })
		end,
		run = function(_self: any, pane: number, text: string)
			table.insert(win.runs, { pane = pane, text = text })
		end,
		session = {
			pane = function(_self: any, id: number): any
				local p = win.panes[id]
				if p == nil then
					return nil
				end
				return { pane = id, block = p.block, cwd = p.cwd }
			end,
			surface = function(_self: any, id: number, _opts: any): any
				win.reads[id] = (win.reads[id] or 0) + 1
				local s = win.surfaces[id]
				local b = linked[id]
				if b == nil then
					return s
				end
				local v: any = b.view()
				return { main = tspOf(if v then v.main else nil, "main"), layer = if s then s.layer else nil }
			end,
			tab_of = function(_self: any, id: number): number?
				local p = win.panes[id]
				return if p then p.tab else nil
			end,
			tabs = function(_self: any): any
				local rows: { any } = {}
				for _, t in win.tabs do
					table.insert(rows, { id = t.id, session = t.session })
				end
				return rows
			end,
			sessions = function(_self: any): any
				local rows: { any } = {}
				for _, id in win.sessions do
					table.insert(rows, { id = id })
				end
				return rows
			end,
			focused = function(_self: any): number?
				return win.focused
			end,
			panes = function(_self: any): any
				local rows: { any } = {}
				for id, p in win.panes do
					table.insert(rows, { pane = id, cwd = p.cwd, tab = p.tab })
				end
				return rows
			end,
			event = function(_self: any, id: number, ev: { [string]: any })
				table.insert(win.events, { pane = id, ev = ev })
				if linked[id] then
					schedule(0, function()
						local b = linked[id]
						if b then
							b.event(ev)
						end
					end)
				end
			end,
		},
		sessions = {
			switch = function(_self: any, id: number)
				table.insert(win.switches, id)
			end,
		},
		layout = {
			new_tab = function(_self: any, launch: any, _reveal: any): number?
				if win.newTab == "raise" then
					error("layout: the window is closing", 0)
				elseif win.newTab == "nil" then
					return nil
				end
				return addPane(launch, nil)
			end,
			name_tab = function(_self: any, tab: number, name: string)
				win.tabNames[tab] = name
			end,
			focus = function(_self: any, pane: number)
				win.focused = pane
			end,
			split = function(_self: any, source: number, _dir: string, launch: any): number?
				local from = win.panes[source]
				if from == nil or win.newTab == "nil" then
					return nil
				end
				return addPane(launch, from.tab)
			end,
			dock = function(_self: any, _pane: number, _target: number, _dir: string, _opts: any): any
				return true
			end,
			move_to_tab = function(_self: any, pane: number, tab: number): (boolean, string?)
				local p = win.panes[pane]
				if p then
					p.tab = tab
				end
				return p ~= nil, nil
			end,
			move = function(_self: any, pane: number, target: number, _dir: string): boolean
				local p, to = win.panes[pane], win.panes[target]
				if p and to then
					p.tab = to.tab
				end
				return p ~= nil and to ~= nil
			end,
		},
		hosts = {
			list = function(_self: any): any
				local groups: { [number]: { number } } = {}
				for id in win.panes do
					local hostId = win.hostOf[id] or 1
					groups[hostId] = groups[hostId] or {}
					table.insert(groups[hostId], id)
				end
				local rows: { any } = {}
				for hostId, ids in groups do
					table.insert(rows, { id = hostId, kind = if win.remoteHost or hostId ~= 1 then "remote" else "local", address = if hostId ~= 1 then "host" .. hostId else nil, panes = ids })
				end
				return rows
			end,
		},
		open = function(_self: any, target: string, how: string?)
			table.insert(win.browser, { url = target, how = how, beside = win.focused })
		end,
		pick = function(_self: any, opts: any): any
			table.insert(win.picks, opts)
			return {
				next = function(_self2: any, fn: (any, any, any) -> ())
					schedule(0, function()
						local chosen: any = nil
						local want: any = win.choose
						local bare: boolean? = nil
						local decide = win.decide
						if decide then
							want, bare = decide(opts)
						end
						for _, item in opts.items do
							local label: any = item.label
							local hit = false
							if type(want) == "table" then
								hit = table.find(want, label) ~= nil
							else
								hit = label == want
							end
							if hit then
								chosen = item
								break
							end
						end
						fn(chosen, nil, if bare then nil else windowCx)
					end)
				end,
			}
		end,
		prompt = function(_self: any, opts: any): any
			table.insert(win.prompts, opts)
			local answer: string? = if #win.typedQueue > 0 then table.remove(win.typedQueue, 1) else win.typed
			return {
				next = function(_self2: any, fn: (any, any, any) -> ())
					schedule(0, function()
						fn(answer, nil, windowCx)
					end)
				end,
			}
		end,
		copy = function(_self: any, text: string)
			table.insert(copied, text)
		end,
		agents = {
			start = function(_self: any, opts: any): number
				table.insert(win.agents, opts)
				local pane = addPane({ cwd = opts.cwd }, nil)
				win.agentStates[pane] = "working"
				return pane
			end,
			list = function(_self: any): any
				local rows: { any } = {}
				for pane, state in win.agentStates do
					if win.panes[pane] then
						table.insert(rows, { pane = pane, state = state, cwd = win.panes[pane].cwd })
					end
				end
				return rows
			end,
		},
	}

	local fakeOs: any = {
		time = function(t: any?): number
			if t ~= nil then
				-- UTC, like the fake os.date: days from civil, with the overflow of a day or month carried (triage.tomorrow).
				local d: any = t
				local y: number, m: number = d.year, d.month
				y += (m - 1) // 12
				m = (m - 1) % 12 + 1
				local doy = (153 * (m + (if m > 2 then -3 else 9)) + 2) // 5 + d.day - 1
				if m <= 2 then
					y -= 1
				end
				local era = y // 400
				local yoe = y - era * 400
				local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
				return days * 86400 + (d.hour or 12) * 3600 + (d.min or 0) * 60 + (d.sec or 0)
			end
			return EPOCH + nowMs // 1000
		end,
		date = function(fmt: string, t: number?): any
			return os.date("!" .. fmt, t)
		end,
		clock = os.clock,
		difftime = os.difftime,
	}

	-- kv: values round-trip through JSON like the on-disk store; read/write failures raise
	local kvStore: { [string]: string } = {}
	local kvFailGet: { [string]: string } = {}
	local kvFailSet: { [string]: string } = {}
	local kv: Kv = {
		store = kvStore,
		failGet = kvFailGet,
		failSet = kvFailSet,
		get = function(key: string): any
			local text = kvStore[key]
			return if text == nil then nil else jsonDecode(text)
		end,
		put = function(key: string, value: any)
			kvStore[key] = jsonEncode(value)
		end,
	}
	-- Most cases drive the queue by the one-key shortcuts Plotroom bound by default before only the command palette had
	-- a key; a case about the defaults themselves drops them (`w.kv.store.keys = nil :: any`).
	kvStore.keys = jsonEncode({
		down = "j",
		up = "k",
		worktree = "w",
		goto = "g",
		agent = "a",
		agentgo = "G",
		seen = "m",
		snooze = "z",
		snoozed = "Z",
		attention = "n",
		sort = "o",
		search = "/",
		refresh = "r",
		settings = "s",
		help = "?",
		["wt-cleanup"] = "u",
		["wt-remove"] = "d",
	})

	-- fs: absolute paths only; failures raise
	local files: { [string]: string } = {}
	local dirs: { [string]: boolean } = { ["/"] = true }
	local denyMkdir: { [string]: string } = {}
	local mkdirs: { string } = {}
	local fs: Fs = { files = files, dirs = dirs, denyMkdir = denyMkdir, mkdirs = mkdirs }

	local function describe(call: Call): string
		return table.concat(call.argv, " ")
	end

	local sdk: any = {
		context = context,
		plugin = { id = "plotroom", name = "Tern Plotroom", version = "0.1.0" },
		runtime = { os = "macos", jit = false },
		log = {
			debug = function() end,
			info = function() end,
			warn = function() end,
			error = function() end,
		},
		json = {
			encode = function(value: any, _pretty: boolean?): string
				return jsonEncode(value)
			end,
			decode = function(text: string): any
				local value = jsonDecode(text)
				return value
			end,
			array = function(t: any?): any
				local list = t or {}
				return tagArray(list)
			end,
			null = NULL,
		},
		now = function(): number
			return nowMs
		end,
		getenv = function(name: string): string?
			return env[name]
		end,
		timer = function(ms: number, fn: (any) -> ()): any
			local ev = schedule(ms, function()
				fn(if context == "window" then windowCx else nil)
			end)
			return {
				cancel = function(_self: any)
					ev.live = false
				end,
			}
		end,
		kv = {
			get = function(key: string): any
				local why = kvFailGet[key] or kvFailGet["*"]
				if why then
					error(why, 0)
				end
				return kv.get(key)
			end,
			set = function(key: string, value: any)
				local why = kvFailSet[key] or kvFailSet["*"]
				if why then
					error(why, 0)
				end
				if value == nil then
					kvStore[key] = nil
				else
					kvStore[key] = jsonEncode(value)
				end
			end,
		},
		fs = {
			exists = function(path: string): boolean
				local p = cleanPath(path)
				return files[p] ~= nil or dirs[p] == true
			end,
			mkdir = function(path: string)
				local p = cleanPath(path)
				local why = denyMkdir[p]
				if why then
					error(why, 0)
				end
				if files[p] ~= nil then
					error("mkdir " .. p .. ": File exists", 0)
				end
				local chain: { string } = {}
				local cur = p
				while cur ~= "/" and not dirs[cur] do
					table.insert(chain, 1, cur)
					cur = parentOf(cur)
				end
				for _, d in chain do
					if files[d] ~= nil then
						error("mkdir " .. d .. ": Not a directory", 0)
					end
					dirs[d] = true
				end
				table.insert(mkdirs, p)
			end,
			read = function(path: string, maxBytes: number?): string
				local p = cleanPath(path)
				local text = files[p]
				if text == nil then
					error("read " .. p .. ": No such file or directory", 0)
				end
				if maxBytes and #text > maxBytes then
					error("read " .. p .. ": file is larger than " .. maxBytes .. " bytes", 0) -- the SDK rejects oversize input unread
				end
				return text
			end,
			write = function(path: string, text: string)
				local p = cleanPath(path)
				if not dirs[parentOf(p)] then
					error("write " .. p .. ": No such file or directory", 0)
				end
				files[p] = text
			end,
			list = function(path: string): { string }
				local p = cleanPath(path)
				local names: { string } = {}
				for name in files do
					if parentOf(name) == p then
						table.insert(names, string.match(name, "[^/]+$") or name)
					end
				end
				for name in dirs do
					if name ~= "/" and parentOf(name) == p then
						table.insert(names, string.match(name, "[^/]+$") or name)
					end
				end
				table.sort(names)
				return names
			end,
			remove = function(path: string)
				local p = cleanPath(path)
				files[p] = nil
				dirs[p] = nil
				local prefix = p .. "/"
				for name in files do
					if string.sub(name, 1, #prefix) == prefix then
						files[name] = nil
					end
				end
				for name in dirs do
					if string.sub(name, 1, #prefix) == prefix then
						dirs[name] = nil
					end
				end
			end,
		},
		process = {
			run = function(argv: any, a: any, b: any)
				local opts: any = a
				local cb: any = b
				if type(a) == "function" then
					opts, cb = nil, a
				end
				if type(argv) ~= "table" or #argv == 0 or type(cb) ~= "function" then
					error("the fake process.run takes (argv, opts?, callback)", 2)
				end
				local list: { string } = {}
				for _, arg in argv do
					table.insert(list, tostring(arg))
				end
				local copy: { [string]: string } = {}
				if opts and type(opts.env) == "table" then
					for k, v in opts.env do
						copy[k] = v
					end
				end
				local call: Call = {
					argv = list,
					cwd = if opts then opts.cwd else nil,
					env = copy,
					stdin = if opts then opts.stdin else nil,
					timeoutMs = if opts then opts.timeout_ms else nil,
					at = nowMs,
				}
				table.insert(calls, call)
				local reply: Reply? = nil
				for i = #responders, 1, -1 do
					reply = responders[i](call)
					if reply then
						break
					end
				end
				if not reply then
					table.insert(unmatched, describe(call))
					error("spawn " .. list[1] .. ": no such file or directory (the fake has no responder for this call)", 0)
				end
				if reply.raise then
					error(reply.raise, 0)
				end
				local delay = reply.delay or 0
				local result = {
					status = reply.status or 0,
					stdout = reply.stdout or "",
					stderr = reply.stderr or "",
					timed_out = reply.timedOut == true,
				}
				local limit = call.timeoutMs
				if limit and delay > limit then
					result = { status = -1, stdout = "", stderr = "", timed_out = true }
					delay = limit
				end
				local times = if reply.repeatCallback then 2 else 1
				for _ = 1, times do
					schedule(delay, function()
						cb(result, if context == "window" then windowCx else nil)
					end)
				end
			end,
		},
		ui = {
			span = function(t: string, s: string?): any
				return { t = t, s = s }
			end,
			link = function(t: string, href: string, s: string?): any
				return { t = t, s = s, href = href }
			end,
			text = function(spans: any): any
				return { k = "text", p = { spans = spans } }
			end,
			col = function(children: any): any
				return { k = "col", c = children }
			end,
			node = function(kind: string, props: any?, children: any?): any
				return { k = kind, p = props, c = children }
			end,
			el = function(tag: string, props: any?, children: any?): any
				local p: { [string]: any } = { tag = tag }
				for k, v in props or {} do
					p[k] = v
				end
				return { k = "el", p = p, c = children }
			end,
		},
		pane = {
			list = function(): { PaneRow }
				local rows: { PaneRow } = {}
				for _, row in panes do
					table.insert(rows, { pane = row.pane, cwd = row.cwd })
				end
				return rows
			end,
		},
		block = {
			define = function(id: string, def: any)
				if id ~= "prs" then
					error("tern.block.define block \"" .. id .. "\" is not declared in plugin.toml: the plugin declares one block, prs", 0)
				end
				blocks[id] = def
			end,
		},
		chrome = {
			status = function(fn: any)
				win.status = fn
			end,
			refresh = function()
				win.refreshes += 1
			end,
		},
		command = function(def: any)
			commands[def.id] = def
		end,
		on = function(name: string, fn: any)
			win.handlers[name] = fn -- lifecycle events fire only when a case calls win.handlers[name]
		end,
		route = {
			link = function(fn: any)
				routes.link = fn
			end,
			open = function(fn: any)
				routes.open = fn
			end,
		},
	}

	local load = instantiate(sdk, fakeOs)

	local function open(pane: number, args: { string }?, savedState: any?): Block
		local def: any = blocks.prs
		if def == nil then
			error("load \"host\" before opening the block", 2)
		end
		local state: any = nil
		local last: any = nil
		local renders = 0
		local persisted: any = savedState
		local cwd = if args then args[1] else nil
		local cx: any
		local function render()
			if state == nil then
				return
			end
			renders += 1
			last = def.view(state, cx)
			if encodeViews then
				jsonEncode(last) -- Tern serializes the view: it must be plain data
			end
		end
		cx = {
			pane = pane,
			cwd = cwd,
			cols = 140,
			rows = 40,
			toast = function(_self: any, level: string, text: string, sub: string?)
				table.insert(toasts, { level = level, text = text, sub = sub })
			end,
			open = function(_self: any, target: string)
				table.insert(opened, target)
				local route = routes.link
				if linked[pane] and route then
					schedule(0, function()
						route({ url = target, pane = pane, mods = { cmd = false, alt = false, shift = false, ctrl = false } }, windowCx)
					end)
				end
			end,
			copy = function(_self: any, text: string)
				table.insert(copied, text)
			end,
			render = function(_self: any)
				render()
			end,
			save = function(_self: any)
				if state ~= nil then
					persisted = jsonDecode(jsonEncode(def.save(state)))
				end
			end,
			exit = function(_self: any, _code: number) end,
			frame = function(_self: any, ops: any)
				table.insert(frames, { pane = pane, ops = ops })
			end,
			blob = function(_self: any, _bytes: string, _mime: string): string
				return "blob"
			end,
		}
		table.insert(panes, { pane = pane, cwd = cwd })
		state = def.init(cx, args or {}, savedState)
		render()
		cx:save()
		local function settle()
			render()
			cx:save()
		end
		local block: Block = {
			pane = pane,
			cx = cx,
			state = function(): any
				return state
			end,
			renders = function(): number
				return renders
			end,
			saved = function(): any
				return persisted
			end,
			render = function(): any
				render()
				return last
			end,
			view = function(): any
				return last
			end,
			press = function(name: string, mods: string?, text: string?): boolean?
				local handled = def.key(state, keyOf(name, mods, text), cx)
				if handled ~= false then
					settle()
				end
				return handled
			end,
			typeText = function(text: string)
				for _, cp in utf8.codes(text) do
					local ch = utf8.char(cp)
					local handled = def.key(state, keyOf(if ch == " " then "space" else ch, nil, ch), cx)
					if handled ~= false then
						settle()
					end
				end
			end,
			event = function(ev: { [string]: any })
				def.event(state, ev, cx)
				settle()
			end,
			text = function(): string
				local out: { string } = {}
				collectTexts(last, out)
				return table.concat(out, "\n")
			end,
			title = function(): string?
				return def.title(state)
			end,
			close = function()
				linked[pane] = nil
				for i, row in panes do
					if row.pane == pane then
						table.remove(panes, i)
						break
					end
				end
			end,
		}
		return block
	end

	local world: World = {
		context = context,
		sdk = sdk,
		load = load,
		now = function(): number
			return nowMs
		end,
		seconds = function(): number
			return EPOCH + nowMs // 1000
		end,
		advance = advance,
		flush = function()
			runUntil(nowMs)
		end,
		env = env,
		toasts = toasts,
		opened = opened,
		copied = copied,
		frames = frames,
		calls = calls,
		respond = function(responder: Responder)
			table.insert(responders, responder)
		end,
		kv = kv,
		fs = fs,
		panes = panes,
		blocks = blocks,
		open = open,
		setEncodeViews = function(on: boolean)
			encodeViews = on
		end,
		window = win,
		cx = windowCx,
		link = function(block: Block)
			linked[block.pane] = block
		end,
		click = function(url: string, pane: number?): any
			local handler = routes.link
			if handler == nil then
				error("load \"window\" before clicking a link", 2)
			end
			return handler({ url = url, pane = pane or 1, mods = { cmd = false, alt = false, shift = false, ctrl = false } }, windowCx)
		end,
		command = function(id: string)
			local def = commands[id]
			if def == nil then
				error("the window registered no command " .. id, 2)
			end
			def.run(windowCx)
		end,
		finish = function()
			if #unmatched > 0 then
				error("process calls no responder answered:\n  " .. table.concat(unmatched, "\n  "), 0)
			end
		end,
	}
	return world
end
M.newWorld = newWorld

-- ---------------------------------------------------------------- cases

export type Case = { name: string, context: string, run: (World) -> () }
local cases: { Case } = {}
M.cases = cases

local function case(name: string, run: (World) -> ())
	table.insert(cases, { name = name, context = "host", run = run })
end
M.case = case

local function windowCase(name: string, run: (World) -> ())
	table.insert(cases, { name = name, context = "window", run = run })
end
M.windowCase = windowCase

-- ---------------------------------------------------------------- semantic models of gh and git
-- They answer process.run calls from state: a PR list per login with paging and quota headers, a repository
-- with refs, remotes and worktrees. A case changes that state (or injects a failure) and reads it back.
local function sha(c: string): string
	return string.rep(c, 40)
end
M.sha = sha

local function array(t: { any }): { any }
	arrayTags[t] = true
	return t
end
M.array = array

local function iso(t: number): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", t) :: string
end

-- One PR as `gh api graphql --jq` prints it: the shape github.parsePage reads.
local function searchItem(n: number, repo: string, updated: number, extra: { [string]: any }?): { [string]: any }
	local item: { [string]: any } = {
		number = n,
		title = "PR " .. n,
		url = "https://github.com/" .. repo .. "/pull/" .. n,
		author = "octo",
		state = "OPEN",
		isDraft = false,
		updatedAt = iso(updated),
		createdAt = iso(updated),
		head = "branch-" .. n,
		base = "main",
		additions = 1,
		deletions = 2,
		changedFiles = 3,
		comments = 4,
		labels = array({}),
		runs = array({}),
		runTotal = 0,
	}
	if extra then
		for k, v in extra do
			item[k] = v
		end
	end
	return item
end
M.searchItem = searchItem

-- One issue as `gh api graphql --jq` prints it: the shape github.parseIssuePage reads.
local function issueItem(n: number, repo: string, updated: number, extra: { [string]: any }?): { [string]: any }
	local item: { [string]: any } = {
		number = n,
		title = "Issue " .. n,
		url = "https://github.com/" .. repo .. "/issues/" .. n,
		state = "OPEN",
		reason = NULL,
		updatedAt = iso(updated),
		createdAt = iso(updated),
		author = "octo",
		comments = 4,
		labels = array({}),
		assignees = array({}),
	}
	if extra then
		for k, v in extra do
			item[k] = v
		end
	end
	return item
end
M.issueItem = issueItem

-- PRs 1..count of `repo`, the newest update first.
local function manyItems(repo: string, count: number): { { [string]: any } }
	local items: { { [string]: any } } = {}
	for i = 1, count do
		table.insert(items, searchItem(i, repo, EPOCH - i * 60))
	end
	return items
end
M.manyItems = manyItems

export type GhLimit = { limit: number, remaining: number, reset: number }
export type GhReq = { kind: string, login: string?, fields: { [string]: string }, call: Call }
export type Gh = {
	active: string, -- the account gh uses without GH_TOKEN
	tokens: { [string]: string }, -- login -> what `gh auth token --user` prints
	items: { [string]: { { [string]: any } } }, -- login -> search results, newest first
	issueItems: { [string]: { { [string]: any } } }, -- login -> issue search results, newest first
	pulls: { [string]: { [string]: any } }, -- PR URL -> the item `resource(url:)` finds there; any other URL finds none
	issueDetail: { [string]: { [string]: any } }, -- "owner/repo#N" -> the detail ISSUE_DETAIL_JQ prints
	total: { [string]: number }, -- login -> issueCount when it differs from #items
	meta: { [string]: { base: string, sha: string, ref: string, headRepo: string?, headOwner: string?, state: string, baseRef: string?, title: string?, author: string? } }, -- "owner/repo#N" -> pulls/N as PR_JQ prints it; no headRepo: the head's repository was deleted
	checks: { [string]: { any } }, -- "owner/repo#N" -> check nodes of its latest commit
	checkTotal: { [string]: number },
	about: { [string]: { [string]: any } }, -- "owner/repo#N" -> the `about` part CHECKS_JQ prints
	linked: { [string]: { any } }, -- "owner/repo#ref" (an issue number or a Jira key) -> the pull requests PR_LINK_JQ prints for it: {number, title, head, branch, base}
	heads: { [string]: { any } }, -- "owner/repo@branch" -> the pull requests `pr list --head` prints for it: {number, title, state, isDraft, url}
	limits: { [string]: GhLimit }, -- login -> GraphQL quota, reported in the response headers
	repos: { [string]: { string } }, -- login -> the repositories `user/repos` lists, most recently pushed first
	pageSize: number,
	override: ((GhReq) -> Reply?)?, -- answers first: a failure, a malformed page
	requests: { GhReq },
}

local function newGh(w: World): Gh
	local gh: Gh = {
		active = "octocat",
		tokens = {},
		items = {},
		issueItems = {},
		issueDetail = {},
		pulls = {},
		total = {},
		meta = {},
		checks = {},
		checkTotal = {},
		about = {},
		linked = {},
		heads = {},
		limits = {},
		repos = {},
		pageSize = 100,
		override = nil,
		requests = {},
	}
	local function headers(lim: GhLimit?): string
		if not lim then
			return ""
		end
		return "HTTP/2.0 200 OK\r\nX-Ratelimit-Limit: " .. lim.limit .. "\r\nX-Ratelimit-Remaining: " .. lim.remaining .. "\r\nX-Ratelimit-Reset: " .. lim.reset .. "\r\nX-Ratelimit-Resource: graphql\r\n\r\n"
	end
	-- One page of `list` after the cursor `after` ("c<offset>"), and the cursor of the next page or JSON null.
	local function page(list: { any }, after: string?): ({ any }, any)
		local offset = tonumber(string.match(after or "", "^c(%d+)$")) or 0
		local slice: { any } = {}
		for i = offset + 1, math.min(offset + gh.pageSize, #list) do
			table.insert(slice, list[i])
		end
		return array(slice), if offset + gh.pageSize < #list then "c" .. (offset + gh.pageSize) else NULL
	end
	w.respond(function(call: Call): Reply?
		local argv = call.argv
		if argv[1] ~= "gh" then
			return nil
		end
		if argv[2] == "--version" then
			return { stdout = "gh version 2.98.0\n" }
		end
		local override = gh.override
		if argv[2] == "auth" and argv[3] == "status" then
			-- the active account and every one with a token, as `gh auth status --json hosts` lists them
			local req: GhReq = { kind = "accounts", login = nil, fields = {}, call = call }
			table.insert(gh.requests, req)
			local forced = if override then override(req) else nil
			if forced then
				return forced
			end
			local list: { any } = { { state = "success", active = true, host = "github.com", login = gh.active } }
			local logins: { string } = {}
			for login in gh.tokens do
				if login ~= gh.active then
					table.insert(logins, login)
				end
			end
			table.sort(logins)
			for _, login in logins do
				table.insert(list, { state = "success", active = false, host = "github.com", login = login })
			end
			return { stdout = jsonEncode({ hosts = { ["github.com"] = list } }) }
		end
		if argv[2] == "auth" and argv[3] == "token" then
			local user = ""
			for i = 4, #argv - 1 do
				if argv[i] == "--user" then
					user = argv[i + 1]
				end
			end
			local req: GhReq = { kind = "token", login = user, fields = {}, call = call }
			table.insert(gh.requests, req)
			local forced = if override then override(req) else nil
			if forced then
				return forced
			end
			local token = gh.tokens[user]
			if token then
				return { stdout = token .. "\n" }
			end
			return { status = 1, stderr = "no oauth token found for " .. user .. "\n" }
		end
		local fields: { [string]: string } = {}
		local path: string? = nil
		local i = 2
		while i <= #argv do
			local a = argv[i]
			if (a == "-f" or a == "-F") and argv[i + 1] ~= nil then
				local k, v = string.match(argv[i + 1], "^([^=]+)=(.*)$")
				if k and v then
					fields[k] = v
				end
				i += 2
			else
				if string.match(a, "^repos/") then
					path = a
				elseif string.match(a, "^user/repos") then
					path = "user/repos"
				end
				i += 1
			end
		end
		local kind = "other"
		if argv[2] == "pr" and argv[3] == "list" then
			kind = "head" -- the pull requests whose head is a branch
		elseif argv[2] == "repo" and argv[3] == "clone" then
			kind = "clone"
		elseif string.find(fields.query or "", "resource(url: $q)", 1, true) then
			kind = "pull"
		elseif string.find(fields.query or "", "baseRepository { nameWithOwner }", 1, true) then
			kind = "linked" -- an issue's linked pull requests: its closing references, or a search for a Jira key
		elseif fields.q then
			kind = if string.find(fields.q, " is:issue ", 1, true) then "issue-search" else "search"
		elseif fields.o and fields.r and fields.n then
			kind = if string.find(fields.query or "", "issue(number: $n)", 1, true) then "issue" else "checks"
		elseif path == "user/repos" then
			kind = "repos"
		elseif path then
			kind = "pr"
		end
		-- the account: the token's owner, or the active one
		local login: string? = gh.active
		local token = call.env.GH_TOKEN
		if token then
			login = nil
			for name, t in gh.tokens do
				if t == token then
					login = name
				end
			end
			if login == nil then
				return { status = 1, stderr = "gh: Bad credentials (HTTP 401)\n" }
			end
		end
		local req: GhReq = { kind = kind, login = login, fields = fields, call = call }
		table.insert(gh.requests, req)
		local forced = if override then override(req) else nil
		if forced then
			return forced
		end
		if kind == "clone" then
			return { status = 1, stderr = "gh: clone not modelled\n" }
		end
		local key = login or ""
		local lim = gh.limits[key]
		if kind == "search" or kind == "issue-search" or kind == "checks" or kind == "issue" or kind == "pull" then
			if lim and lim.remaining <= 0 then
				return { status = 1, stdout = headers(lim), stderr = "gh: API rate limit already exceeded for user ID 1. (HTTP 403)\n" }
			end
			if lim then
				lim.remaining -= 1
			end
		end
		if kind == "search" then
			local list = gh.items[key] or {}
			local slice, cursor = page(list, fields.after)
			local body = jsonEncode({ total = gh.total[key] or #list, next = cursor, cost = 1, items = slice })
			return { stdout = headers(lim) .. body }
		elseif kind == "pull" then
			local item = gh.pulls[fields.q]
			local body = jsonEncode({ total = if item then 1 else 0, next = NULL, cost = 1, items = array(if item then { item } else {}) })
			return { stdout = headers(lim) .. body }
		elseif kind == "checks" then
			local id = (fields.o or "") .. "/" .. (fields.r or "") .. "#" .. (fields.n or "")
			local nodes = gh.checks[id] or {}
			local slice, cursor = page(nodes, fields.after)
			local body = jsonEncode({ total = gh.checkTotal[id] or #nodes, next = cursor, nodes = slice, about = gh.about[id] })
			return { stdout = headers(lim) .. body }
		elseif kind == "issue-search" then
			local list = gh.issueItems[key] or {}
			local slice, cursor = page(list, fields.after)
			local body = jsonEncode({ total = #list, next = cursor, cost = 1, items = slice })
			return { stdout = headers(lim) .. body }
		elseif kind == "issue" then
			local id = (fields.o or "") .. "/" .. (fields.r or "") .. "#" .. (fields.n or "")
			local body = jsonEncode(gh.issueDetail[id] or { body = NULL, milestone = NULL, linked = array({}) })
			return { stdout = headers(lim) .. body }
		elseif kind == "pr" then
			local repo, n = string.match(path or "", "^repos/(.+)/pulls/(%d+)$")
			local meta = gh.meta[(repo or "") .. "#" .. (n or "")]
			if not meta then
				return { status = 1, stderr = "gh: Not Found (HTTP 404)\n" }
			end
			return { stdout = jsonEncode(meta) }
		elseif kind == "linked" then
			local repo, ref = string.match(fields.q or "", "^repo:(%S+) is:pr (.+)$")
			if not fields.q then
				repo, ref = (fields.o or "") .. "/" .. (fields.r or ""), fields.n
			end
			return { stdout = jsonEncode(array(gh.linked[(repo or "") .. "#" .. (ref or "")] or {})) }
		elseif kind == "head" then
			local repo, branch = "", ""
			for j = 4, #argv do
				if argv[j - 1] == "--repo" then
					repo = argv[j]
				end
				branch = string.match(argv[j], "^%-%-head=(.*)$") or branch
			end
			return { stdout = jsonEncode(array(gh.heads[repo .. "@" .. branch] or {})) }
		elseif kind == "repos" then
			local list = gh.repos[key] or {}
			return { stdout = if #list > 0 then table.concat(list, "\n") .. "\n" else "" }
		end
		return nil
	end)
	return gh
end
M.newGh = newGh

export type AcliReq = { kind: string, argv: { string } } -- kind: version | auth | search | sprints | view | projects | other
export type Acli = {
	site: string?, -- the Jira site `acli jira auth status` names; nil: signed out, every jira command fails as unauthorized
	searches: { [string]: { any } }, -- --jql value -> the work items it finds, in the order acli prints them; an unlisted query finds none
	views: { [string]: any }, -- key -> the REST issue `workitem view` prints
	projects: { any }, -- what `project list` prints
	override: ((AcliReq) -> Reply?)?, -- answers first: a failure, a malformed page
	sprints: boolean, -- whether JQL knows a Sprint field (the `sprint is EMPTY --count` probe)
	requests: { AcliReq },
}

-- Atlassian's acli as far as the Jira module reads it: `--version`, `jira auth status`, `jira workitem search|view` and
-- `jira project list`.
local function newAcli(w: World): Acli
	local acli: Acli = { site = "acme.atlassian.net", searches = {}, views = {}, projects = {}, override = nil, sprints = true, requests = {} }
	w.respond(function(call: Call): Reply?
		local argv = call.argv
		if argv[1] ~= "acli" then
			return nil
		end
		local kind = "other"
		if argv[2] == "--version" then
			kind = "version"
		elseif argv[2] == "jira" and argv[3] == "auth" and argv[4] == "status" then
			kind = "auth"
		elseif argv[2] == "jira" and argv[3] == "workitem" and (argv[4] == "search" or argv[4] == "view") then
			kind = if argv[#argv] == "--count" then "sprints" else argv[4]
		elseif argv[2] == "jira" and argv[3] == "project" and argv[4] == "list" then
			kind = "projects"
		end
		local req: AcliReq = { kind = kind, argv = argv }
		table.insert(acli.requests, req)
		local forced = if acli.override then acli.override(req) else nil
		if forced then
			return forced
		end
		if kind == "version" then
			return { stdout = "acli version 1.3.36-stable\n" }
		end
		local site = acli.site
		if not site then
			return { status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login' to authenticate\n" }
		end
		if kind == "auth" then
			return { stdout = "✓ Authenticated\n  Site: " .. site .. "\n  Email: ann@example.com\n  Authentication Type: oauth_global\n" }
		elseif kind == "sprints" then
			if acli.sprints then
				return { stdout = "✓ Number of work items in the search: 0\n" }
			end
			return { status = 1, stderr = "✗ Error: failed to parse JQL query: field 'sprint' does not exist or you do not have permission to view it.\n" }
		elseif kind == "search" then
			local jql = ""
			for i = 5, #argv - 1 do
				if argv[i] == "--jql" then
					jql = argv[i + 1]
				end
			end
			local items = acli.searches[jql] or {}
			return { stdout = if #items > 0 then jsonEncode(array(items)) .. "\n" else "[\n  null\n]\n" }
		elseif kind == "view" then
			local item = acli.views[argv[5] or ""]
			if item == nil then
				return { status = 1, stderr = "✗ Error: Issue does not exist or you do not have permission to see it.\n" }
			end
			return { stdout = jsonEncode(item) .. "\n" }
		elseif kind == "projects" then
			return { stdout = jsonEncode(array(acli.projects)) .. "\n" }
		end
		return nil
	end)
	return acli
end
M.newAcli = newAcli

-- A work item as `acli jira workitem search` prints it; `fields` replaces or adds members of its `fields`.
local function jiraItem(key: string, summary: string, fields: { [string]: any }?): { [string]: any }
	local f: { [string]: any } = {
		summary = summary,
		status = { name = "To Do", statusCategory = { key = "new" } },
		issuetype = { name = "Task" },
		priority = { name = "Medium" },
		reporter = { displayName = "Ann Lee" },
		assignee = NULL,
		labels = array({}),
	}
	if fields then
		for k, v in fields do
			f[k] = v
		end
	end
	return { key = key, fields = f }
end
M.jiraItem = jiraItem

-- git's refname rules, as far as generated names can break them (git check-ref-format).
local function validRef(name: string): boolean
	if name == "" or name == "@" or string.find(name, "..", 1, true) or string.find(name, "//", 1, true) or string.find(name, "@{", 1, true) then
		return false
	end
	local last = string.sub(name, -1)
	if last == "/" or last == "." or string.find(name, "%c") then
		return false
	end
	for _, ch in { " ", "~", "^", ":", "?", "*", "[", "\\" } do
		if string.find(name, ch, 1, true) then
			return false
		end
	end
	for part in string.gmatch(name, "[^/]+") do
		if string.sub(part, 1, 1) == "." or string.sub(part, -5) == ".lock" then
			return false
		end
	end
	return true
end
M.validRef = validRef

export type GitWorktree = { path: string, branch: string?, head: string, locked: boolean, prunable: boolean? }
export type Git = {
	root: string,
	remotes: { [string]: { string } }, -- name -> urls: `remote get-url --all` lists them, fetch uses the first
	served: { [string]: string }, -- what the remote serves (refs/pull/N/head, refs/heads/<branch>) -> sha
	defaultBranch: string?, -- the branch the remote's HEAD points at, as `ls-remote --symref` says; nil: it says none
	refs: { [string]: string }, -- local refs -> sha
	config: { [string]: string }, -- the repository's config as `git config <key> <value>` wrote it
	worktrees: { GitWorktree }, -- [1] is the main worktree
	dirty: { [string]: string }, -- worktree path -> `status --porcelain` output
	ahead: { [string]: boolean }, -- branch -> it holds commits its fetched ref lacks: `merge-base --is-ancestor` says no
	unmerged: { [string]: boolean }, -- branch -> `branch -d` refuses it: its commits are merged nowhere
	fail: { [string]: Reply }, -- "fetch", "status", "worktree add", "rev-parse HEAD"... -> the answer instead of the model's
	lockFetch: { winner: string? }?, -- another window holds the ref's lock; `winner` is the sha it leaves there
	onFetch: (() -> ())?, -- runs inside every fetch: the remote moves
	onAdd: (() -> ())?, -- runs before every worktree add: another window acts
	afterAdd: ((string) -> ())?, -- a post-checkout hook: runs after a worktree was added
	log: { string }, -- the arguments of every command, joined by spaces
	notes: { [string]: string }, -- `git config --local <key> <value>` writes (Plotroom's branch notes), kept apart from `config`
	counts: { [string]: number }, -- head sha -> commits it has over any base: `rev-list --count` says it
	pushes: { string }, -- the arguments of every `git push`
	pushFail: Reply?, -- the answer of every push instead of success: a non-fast-forward rejection
}

local gitFallback: { [any]: boolean } = (setmetatable({}, { __mode = "k" }) :: any)

-- `git worktree list --porcelain -z` of the model as it stands: one record per worktree, the main one first.
local function porcelain(g: Git): string
	local out: { string } = {}
	for _, t in g.worktrees do
		table.insert(out, "worktree " .. t.path .. "\0")
		table.insert(out, "HEAD " .. t.head .. "\0")
		table.insert(out, if t.branch then "branch " .. t.branch .. "\0" else "detached\0")
		if t.locked then
			table.insert(out, "locked\0")
		end
		if t.prunable then
			table.insert(out, "prunable gitdir file points to non-existent location\0")
		end
		table.insert(out, "\0")
	end
	return table.concat(out)
end
M.porcelain = porcelain

local function newGit(w: World, root: string): Git
	local g: Git = {
		root = root,
		remotes = {},
		served = {},
		defaultBranch = nil,
		refs = { ["refs/heads/main"] = sha("1") },
		config = {},
		worktrees = { { path = root, branch = "refs/heads/main", head = sha("1"), locked = false } },
		dirty = {},
		ahead = {},
		unmerged = {},
		fail = {},
		lockFetch = nil,
		onFetch = nil,
		onAdd = nil,
		afterAdd = nil,
		log = {},
		notes = {},
		counts = {},
		pushes = {},
		pushFail = nil,
	}
	w.fs.dirs[root] = true
	w.fs.dirs[root .. "/.git"] = true
	if not gitFallback[w] then
		-- the oldest responder: a directory no modelled repository owns
		gitFallback[w] = true
		w.respond(function(call: Call): Reply?
			if call.argv[1] ~= "git" or call.argv[2] ~= "-C" then
				return nil
			end
			local dir = cleanPath(call.argv[3] or "")
			if not w.fs.dirs[dir] then
				return { status = 128, stderr = "fatal: cannot change to '" .. dir .. "': No such file or directory\n" }
			end
			return { status = 128, stderr = "fatal: not a git repository (or any of the parent directories): .git\n" }
		end)
		-- omp's worktrees directory, as `omp config get worktree.base --json` reports a set value
		w.respond(function(call: Call): Reply?
			local a = call.argv
			if a[1] == "omp" and a[2] == "config" and a[3] == "get" and a[4] == "worktree.base" then
				return { stdout = '{"key":"worktree.base","value":"/wt","type":"string"}\n' }
			end
			return nil
		end)
	end
	local function worktreeOf(dir: string): GitWorktree?
		local best: GitWorktree? = nil
		for _, t in g.worktrees do
			if dir == t.path or string.sub(dir, 1, #t.path + 1) == t.path .. "/" then
				if best == nil or #t.path > #best.path then
					best = t
				end
			end
		end
		return best
	end
	w.respond(function(call: Call): Reply?
		local argv = call.argv
		-- `omp worktree add -q -C <root> <args…>` is modelled as the `git worktree add` it performs
		if argv[1] == "omp" and argv[2] == "worktree" and argv[3] == "add" and argv[4] == "-q" and argv[5] == "-C" then
			local as: { string } = { "git", "-C", argv[6], "worktree", "add" }
			for i = 7, #argv do
				table.insert(as, argv[i])
			end
			argv = as
		end
		if argv[1] ~= "git" or argv[2] ~= "-C" or not argv[3] then
			return nil
		end
		local dir = cleanPath(argv[3])
		local here = worktreeOf(dir)
		if not here then
			return nil
		end
		local args: { string } = {}
		for i = 4, #argv do
			table.insert(args, argv[i])
		end
		local sub = args[1] or ""
		local key = sub
		if sub == "worktree" then
			key = "worktree " .. (args[2] or "")
		elseif sub == "rev-parse" and args[2] == "HEAD" then
			key = "rev-parse HEAD"
		end
		table.insert(g.log, table.concat(args, " "))
		local forced = g.fail[key]
		if forced then
			return forced
		end
		if sub == "rev-parse" then
			local a = args[2]
			if a == "--show-toplevel" then
				return { stdout = here.path .. "\n" }
			elseif a == "--path-format=absolute" and args[3] == "--git-common-dir" then
				return { stdout = g.root .. "/.git\n" }
			elseif a == "HEAD" then
				return { stdout = here.head .. "\n" }
			elseif a == "--verify" and args[3] == "HEAD" then
				return { stdout = here.head .. "\n" }
			elseif a == "--abbrev-ref" then
				return { status = 128, stderr = "fatal: no upstream configured\n" }
			elseif a == "--verify" and args[3] == "--quiet" then
				local at = g.refs[args[4] or ""]
				if at then
					return { stdout = at .. "\n" }
				end
				return { status = 1 }
			end
		elseif sub == "remote" and args[2] == nil then
			local names: { string } = {}
			for name in g.remotes do
				table.insert(names, name)
			end
			table.sort(names)
			return { stdout = if #names > 0 then table.concat(names, "\n") .. "\n" else "" }
		elseif sub == "remote" and args[2] == "get-url" and args[3] == "--all" then
			local urls = g.remotes[args[4] or ""]
			if not urls then
				return { status = 2, stderr = "error: No such remote '" .. (args[4] or "") .. "'\n" }
			end
			return { stdout = table.concat(urls, "\n") .. "\n" }
		elseif sub == "status" then
			return { stdout = g.dirty[here.path] or "" }
		elseif sub == "config" and args[2] == "--local" and args[3] == "--get-regexp" then
			local out: { string } = {}
			for k, v in g.notes do
				if string.match(k, "^branch%..+%.plotroom%a+$") then
					table.insert(out, k .. " " .. v)
				end
			end
			table.sort(out)
			return if #out == 0 then { status = 1 } else { stdout = table.concat(out, "\n") .. "\n" }
		elseif sub == "config" and args[2] == "--local" and args[4] ~= nil and args[5] == nil then
			g.notes[args[3] or ""] = args[4]
			return {}
		elseif sub == "for-each-ref" then
			local prefix = args[3] or ""
			local out: { string } = {}
			for ref, at in g.refs do
				if string.sub(ref, 1, #prefix) == prefix then
					table.insert(out, at .. " " .. ref)
				end
			end
			table.sort(out)
			return { stdout = if #out > 0 then table.concat(out, "\n") .. "\n" else "" }
		elseif sub == "symbolic-ref" then
			return if here.branch then { stdout = here.branch .. "\n" } else { status = 1 }
		elseif sub == "rev-list" and args[2] == "--count" then
			local at = string.match(args[3] or "", "%.%.(%x+)$") or ""
			return { stdout = tostring(g.counts[at] or 0) .. "\n" }
		elseif sub == "log" then
			local at = string.match(args[5] or "", "%.%.(%x+)$") or ""
			local out: { string } = {}
			for i = 1, math.min(g.counts[at] or 0, 20) do
				table.insert(out, string.sub(at, 1, 7) .. " commit " .. i)
			end
			return { stdout = if #out > 0 then table.concat(out, "\n") .. "\n" else "" }
		elseif sub == "push" then
			table.insert(g.pushes, table.concat(args, " "))
			return g.pushFail or { stderr = "To remote\n" }
		elseif sub == "config" and args[2] ~= nil and args[3] ~= nil and args[4] == nil then
			g.config[args[2]] = args[3]
			return {}
		elseif sub == "ls-remote" and args[2] == "--symref" then
			-- `ls-remote --symref <remote> HEAD refs/heads/*`: where HEAD points, HEAD itself, then every branch the remote serves
			if not g.remotes[args[3] or ""] then
				return { status = 128, stderr = "fatal: '" .. tostring(args[3]) .. "' does not appear to be a git repository\n" }
			end
			local out: { string } = {}
			local default = g.defaultBranch
			local tip = if default then g.served["refs/heads/" .. default] else nil
			if default and tip then
				table.insert(out, "ref: refs/heads/" .. default .. "\tHEAD\n" .. tip .. "\tHEAD\n")
			end
			local heads: { string } = {}
			for ref in g.served do
				if string.sub(ref, 1, 11) == "refs/heads/" then
					table.insert(heads, ref)
				end
			end
			table.sort(heads)
			for _, ref in heads do
				table.insert(out, g.served[ref] .. "\t" .. ref .. "\n")
			end
			return { stdout = table.concat(out) }
		elseif sub == "check-ref-format" then
			-- `check-ref-format --branch <name>`: a valid name is echoed, anything else is refused
			local name = args[3] or ""
			if args[2] == "--branch" and validRef("refs/heads/" .. name) then
				return { stdout = name .. "\n" }
			end
			return { status = 128, stderr = "fatal: '" .. name .. "' is not a valid branch name\n" }
		elseif sub == "worktree" and args[2] == "list" then
			return { stdout = porcelain(g) }
		elseif sub == "fetch" then
			local onFetch = g.onFetch
			if onFetch then
				onFetch()
			end
			local remote, spec = args[4], args[5]
			if not remote or not g.remotes[remote] then
				return { status = 128, stderr = "fatal: '" .. tostring(remote) .. "' does not appear to be a git repository\n" }
			end
			local src, dst = string.match(spec or "", "^%+?([^:]+):(.+)$")
			if not src or not dst or not validRef(dst) then
				return { status = 128, stderr = "fatal: invalid refspec '" .. tostring(spec) .. "'\n" }
			end
			local lock = g.lockFetch
			if lock then
				if lock.winner then
					g.refs[dst] = lock.winner
				end
				return { status = 1, stderr = "error: cannot lock ref '" .. dst .. "': Unable to create '" .. g.root .. "/.git/" .. dst .. ".lock': File exists.\n" }
			end
			local served = g.served[src]
			if not served then
				return { status = 128, stderr = "fatal: couldn't find remote ref " .. src .. "\n" }
			end
			g.refs[dst] = served
			return { stderr = "From " .. remote .. "\n" }
		elseif sub == "worktree" and args[2] == "add" then
			local onAdd = g.onAdd
			if onAdd then
				onAdd()
			end
			local newBranch: string? = nil
			local target: string
			local commit: string
			if args[3] == "-b" then
				newBranch, target, commit = args[4], cleanPath(args[5] or ""), args[6] or ""
			else
				target, commit = cleanPath(args[3] or ""), args[4] or ""
			end
			if w.fs.dirs[target] or w.fs.files[target] then
				return { status = 128, stderr = "fatal: '" .. target .. "' already exists\n" }
			end
			local branchRef: string
			local head: string
			if newBranch then
				branchRef = "refs/heads/" .. newBranch
				if not validRef(branchRef) then
					return { status = 255, stderr = "fatal: '" .. newBranch .. "' is not a valid branch name\n" }
				end
				if g.refs[branchRef] then
					return { status = 255, stderr = "fatal: a branch named '" .. newBranch .. "' already exists\n" }
				end
				head = commit
				g.refs[branchRef] = head
			else
				branchRef = "refs/heads/" .. commit
				local tip = g.refs[branchRef]
				if not tip then
					return { status = 128, stderr = "fatal: invalid reference: " .. commit .. "\n" }
				end
				for _, t in g.worktrees do
					if t.branch == branchRef then
						return { status = 128, stderr = "fatal: '" .. commit .. "' is already checked out at '" .. t.path .. "'\n" }
					end
				end
				head = tip
			end
			table.insert(g.worktrees, { path = target, branch = branchRef, head = head, locked = false })
			local cur = target
			while cur ~= "/" and not w.fs.dirs[cur] do
				w.fs.dirs[cur] = true
				cur = parentOf(cur)
			end
			local hook = g.afterAdd
			if hook then
				hook(target)
			end
			return { stderr = "Preparing worktree\n" }
		elseif sub == "worktree" and args[2] == "remove" then
			-- never forced: git refuses a worktree with changes, a main one and an unknown one
			local target = cleanPath(args[3] or "")
			local at = 0
			for i, t in g.worktrees do
				if t.path == target then
					at = i
				end
			end
			if at == 0 then
				return { status = 128, stderr = "fatal: '" .. target .. "' is not a working tree\n" }
			elseif at == 1 then
				return { status = 128, stderr = "fatal: '" .. target .. "' is a main working tree\n" }
			elseif (g.dirty[target] or "") ~= "" then
				-- git speaks the user's language unless the caller pins the C locale
				local why = if call.env.LC_ALL == "C" then "contains modified or untracked files, use --force to delete it" else "enthält geänderte oder unversionierte Dateien, benutzen Sie --force zum Löschen"
				return { status = 128, stderr = "fatal: '" .. target .. "' " .. why .. "\n" }
			end
			table.remove(g.worktrees, at)
			for folder in w.fs.dirs do
				if folder == target or string.sub(folder, 1, #target + 1) == target .. "/" then
					w.fs.dirs[folder] = nil
				end
			end
			return {}
		elseif sub == "merge-base" and args[2] == "--is-ancestor" then
			-- exit 0: yes, 1: no, 128: a name that is no commit
			local branch, ref = args[3] or "", args[4] or ""
			-- git resolves a short name as a tag before a branch of the same name; a full name is exact
			local full = if g.refs[branch] then branch elseif g.refs["refs/tags/" .. branch] then "refs/tags/" .. branch elseif g.refs["refs/heads/" .. branch] then "refs/heads/" .. branch else nil
			if not full or not g.refs[ref] then
				return { status = 128, stderr = "fatal: Not a valid object name " .. (if g.refs[ref] then branch else ref) .. "\n" }
			end
			local head = string.match(full, "^refs/heads/(.+)$")
			return { status = if (if head then g.ahead[head] else g.refs[full] ~= g.refs[ref]) then 1 else 0 }
		elseif sub == "branch" and (args[2] == "-d" or args[2] == "-D") then
			local name = args[3] or ""
			if not g.refs["refs/heads/" .. name] then
				return { status = 1, stderr = "error: branch '" .. name .. "' not found\n" }
			end
			for _, t in g.worktrees do
				if t.branch == "refs/heads/" .. name then
					return { status = 1, stderr = "error: cannot delete branch '" .. name .. "' used by worktree at '" .. t.path .. "'\n" }
				end
			end
			if args[2] == "-d" and g.unmerged[name] then
				return { status = 1, stderr = "error: the branch '" .. name .. "' is not fully merged\nhint: If you are sure you want to delete it, run 'git branch -D " .. name .. "'\n" }
			end
			g.refs["refs/heads/" .. name] = nil
			return { stdout = "Deleted branch " .. name .. "\n" }
		elseif sub == "update-ref" and args[2] == "-d" then
			g.refs[args[3] or ""] = nil
			return {}
		end
		return nil
	end)
	return g
end
M.newGit = newGit

local function snapshot(g: Git): string
	return jsonEncode({ refs = g.refs, worktrees = g.worktrees, dirty = g.dirty, config = g.config })
end
M.snapshot = snapshot

-- How many logged commands from entry `from`+1 on start with `prefix`.
local function countLog(g: Git, prefix: string, from: number?): number
	local n = 0
	for i = (from or 0) + 1, #g.log do
		local line = g.log[i]
		-- Plotroom's own branch bookkeeping (config --local branch.<b>.plotroom…) is not what these counts are about.
		if string.sub(line, 1, #prefix) == prefix and not string.match(line, "^config %-%-local branch%..+%.plotroom%a+ ") then
			n += 1
		end
	end
	return n
end
M.countLog = countLog

-- The logged commands from entry `from`+1 on.
local function logFrom(g: Git, from: number): { string }
	local out: { string } = {}
	for i = from + 1, #g.log do
		table.insert(out, g.log[i])
	end
	return out
end
M.logFrom = logFrom

export type Worktree = typeof(require("../worktree"))

export type Scene = { git: Git, gh: Gh, repo: string, number: number, root: string, dir: string, target: string, branch: string, ref: string, launch: string }

-- A checkout of owner/name at /work/<name> whose origin is github.com/owner/name, with PR `n` at sha("b") on both the
-- remote and gh: from the same repository, on head branch `feature` (which the remote serves too). Its worktree is
-- the folder `dir` of omp's worktrees directory, /wt.
local function scene(w: World, worktree: Worktree, owner: string, name: string, n: number): Scene
	local root = "/work/" .. name
	local g = newGit(w, root)
	local repo = owner .. "/" .. name
	g.remotes.origin = { "https://github.com/" .. repo .. ".git" }
	g.served["refs/pull/" .. n .. "/head"] = sha("b")
	g.served["refs/heads/feature"] = sha("b")
	local gh = newGh(w)
	gh.meta[repo .. "#" .. n] = { base = repo, sha = sha("b"), ref = "feature", headRepo = repo, headOwner = owner, state = "open", baseRef = "main", title = "Add a feature", author = "ann" }
	w.fs.dirs[root .. "/src"] = true
	local dir = "plotroom-" .. string.lower(owner) .. "_" .. string.lower(name) .. "-pr-" .. n
	return {
		git = g,
		gh = gh,
		repo = repo,
		number = n,
		root = root,
		dir = dir,
		target = "/wt/" .. dir,
		branch = "feature",
		ref = worktree.prRef(owner, name, n),
		launch = root .. "/src",
	}
end
M.scene = scene

-- The commands spawned after entry `from` of the world's calls, every argument joined by spaces.
local function ranSince(w: World, from: number): { string }
	local out: { string } = {}
	for i = from + 1, #w.calls do
		table.insert(out, table.concat(w.calls[i].argv, " "))
	end
	return out
end
M.ranSince = ranSince

-- How many spawned commands read exactly `line`, every argument joined by spaces.
local function countCalls(w: World, line: string): number
	local n = 0
	for _, call in w.calls do
		if table.concat(call.argv, " ") == line then
			n += 1
		end
	end
	return n
end
M.countCalls = countCalls

-- The first node of a view (itself included) whose props carry `key`, and `kind` when given.
local function findKey(node: any, key: string, kind: string?): any
	if type(node) ~= "table" then
		return nil
	end
	local props: any = node.p
	if type(props) == "table" and props.key == key and (kind == nil or node.k == kind) then
		return node
	end
	local kids: any = node.c
	if type(kids) == "table" then
		for _, kid in kids do
			local hit = findKey(kid, key, kind)
			if hit ~= nil then
				return hit
			end
		end
	end
	return nil
end
M.findKey = findKey

-- The queue view's picker node, its props, and the PR ids the picker lists in order.
local function pickerNode(b: Block): any
	local view: any = b.view()
	return view.layer.c[1]
end
M.pickerNode = pickerNode

local function pickerOf(b: Block): any
	return pickerNode(b).p
end
M.pickerOf = pickerOf

-- Helpers shared by several case files, in one table.
local hx = {}
M.hx = hx

-- The settings view's page props: the side sheet in the layer, after the queue's picker.
local function prefsOf(b: Block): any
	local view: any = b.view()
	return findKey(view.layer, "settings", "prefs").p
end
M.prefsOf = prefsOf

local function prLink(kind: string, repo: string, n: number): string
	return "plotroom://github/" .. kind .. "/" .. repo .. "/" .. n
end
M.prLink = prLink

-- The link of the card's button that runs saved prompt `id` on PR `repo`#`n`.
local function runLink(repo: string, n: number, id: string): string
	return prLink("run", repo, n) .. "/" .. id
end
M.runLink = runLink

-- The queue surface of pane 1: the PR's buttons, as Tern shows host.luau's picker. (A linked block adds its own main
-- region: see `linkQueue`.)
local function listPr(w: World, repo: string, n: number)
	w.window.surfaces[1] = {
		layer = {
			id = "layer",
			c = {
				{
					id = "layer.queue",
					c = {
						{ id = "layer.queue.buttons.open", p = { href = prLink("open", repo, n) } },
						{ id = "layer.queue.buttons.worktree", p = { href = prLink("worktree", repo, n) } },
						{ id = "layer.queue.buttons.agent", p = { href = prLink("agent", repo, n) } },
					},
				},
			},
		},
	}
end
M.listPr = listPr

-- The views most cases run on, saved as a user keeps them: ungrouped and unsorted, so the list is the search's order.
-- A store the case saved already is kept. Cases about the default views (KINDS seeds) clear them first.
function hx.fixtureViews(w: World)
	if w.kv.get("views-prs") == nil then
		w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
			{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({}) },
			{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", group = "none", prompts = array({}) },
		}) })
	end
	if w.kv.get("views-issues") ~= nil then
		return
	end
	w.kv.put("views-issues", { version = 1, nextId = 5, items = array({
		{ id = "v1", name = "Assigned to me", integration = "github", query = "is:open assignee:@me", group = "none", prompts = array({}) },
		{ id = "v2", name = "Created by me", integration = "github", query = "is:open author:@me", group = "none", prompts = array({}) },
		{ id = "v3", name = "Assigned to me", integration = "jira", query = "assignee = currentUser() AND statusCategory != Done", group = "none", prompts = array({}) },
		{ id = "v4", name = "Created by me", integration = "jira", query = "reporter = currentUser() AND statusCategory != Done", group = "none", prompts = array({}) },
	}) })
end

-- The Plotroom block of pane 1, opened in the scene's checkout and listing its PR, linked to the window: the window's
-- requests reach its host half, which runs git, gh and omp, and the answers come back.
local function linkQueue(w: World, s: Scene): Block
	w.load("host")
	hx.fixtureViews(w)
	s.gh.items.octocat = { searchItem(s.number, s.repo, EPOCH - 60) }
	listPr(w, s.repo, s.number)
	local b = w.open(1, { s.launch })
	w.link(b)
	w.flush()
	return b
end
M.linkQueue = linkQueue

-- The worktree card the block shows for its selected PR, nil when none.
local function cardOf(b: Block): any
	return findKey(pickerNode(b), "worktree", "card")
end
M.cardOf = cardOf

-- The queue surface of pane 1 as the selected PR's own card shows it: the links of the block's real view, with the ids
-- Tern gives them. (`listPr` lists links for a PR the block need not be showing.)
local function cardSurface(w: World, b: Block)
	w.window.surfaces[1] = { layer = { id = "layer", c = { tspOf(pickerNode(b), "layer.queue") } } }
end
M.cardSurface = cardSurface

-- Every string the worktree card shows. (`Block.text` also holds the hidden answers to the window: JSON that can repeat
-- a reason the card no longer shows.)
local function cardText(b: Block): string
	local out: { string } = {}
	collectTexts(cardOf(b), out)
	return table.concat(out, "\n")
end
M.cardText = cardText

-- The shell commands the worktree card offers under `which` (its section's key: "update"), one per line; nil when none.
local function commandsOf(b: Block, which: string): string?
	local section = findKey(cardOf(b), which, "section")
	local md: any = if section then findKey(section, "commands", "md") else nil
	return if md then string.match(md.p.text, "^```sh\n(.-)\n```$") else nil
end
M.commandsOf = commandsOf

-- The text of the badges in the worktree card's status row, in order.
local function chipsOf(b: Block): { string }
	local out: { string } = {}
	local row: any = findKey(cardOf(b), "status", "row")
	local chips: { any } = if row then row.c else {}
	for _, chip in chips do
		table.insert(out, chip.p.text)
	end
	return out
end
M.chipsOf = chipsOf

-- A click on the card's button `key`, as Tern sends it: the button's own id, with the action it was given.
local function pressCard(b: Block, key: string)
	local item: any = findKey(cardOf(b), key, "item")
	b.event({ ev = "action", id = "layer.queue.worktree.actions." .. key, act = item.p.actions.click })
end
M.pressCard = pressCard

-- The confirm overlay the block shows over the queue; nil when it shows none.
local function confirmOf(b: Block): any
	return findKey(b.view().layer, "confirm", "overlay")
end
M.confirmOf = confirmOf

-- The Worktree badge of queue row `row` (the first by default); nil when it has none.
local function badgeOf(b: Block, row: number?): any
	local item: any = pickerOf(b).items[row or 1]
	local badges: any = if item then item.badges else nil
	for _, badge in badges or {} do
		if badge.text == "Worktree" then
			return badge
		end
	end
	return nil
end
M.badgeOf = badgeOf

-- Moves the queue's selection to PR `n`: its worktree's card and badge are what the block then shows.
local function showPr(b: Block, n: number)
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_23" .. n })
end
M.showPr = showPr

-- The requests the window has sent to blocks' hosts, decoded, oldest first.
local function requestsSent(w: World): { any }
	local out: { any } = {}
	for _, e in w.window.events do
		if e.ev.act == "rpc" then
			table.insert(out, jsonDecode(e.ev.value))
		end
	end
	return out
end
M.requestsSent = requestsSent

-- Sends the block a request the way a window does: act "rpc", a JSON value holding the request's id and op.
local function request(b: Block, id: string, body: { [string]: any })
	body.id = id
	b.event({ ev = "action", act = "rpc", value = jsonEncode(body) })
end
M.request = request

-- What the block answered request `id`: its hidden `r<id>` node, decoded; nil when it keeps none.
local function answerOf(b: Block, id: string): any
	local view: any = b.view()
	local node = findKey(view.main, "r" .. id)
	return if node then jsonDecode(node.p.text) else nil
end
M.answerOf = answerOf

-- Saved prompts as kv keeps them: `filters` are the ids of the filters a prompt is offered under, none: every filter;
-- `key` is its shortcut in the queue.
local function promptOf(id: string, name: string, text: string, key: string?): { [string]: any }
	return { id = id, name = name, text = text, key = key }
end
M.promptOf = promptOf

-- Makes `list` the saved prompts.
local function savePrompts(w: World, list: { { [string]: any } })
	w.kv.put("prompts-prs", { version = 1, nextId = #list + 1, items = array(list) })
end
M.savePrompts = savePrompts

-- The pickers of saved prompts the agent flow opened.
local function promptPicks(w: World): { any }
	local out: { any } = {}
	for _, p in w.window.picks do
		if string.find(p.placeholder or "", "^Run on ") then
			table.insert(out, p)
		end
	end
	return out
end
M.promptPicks = promptPicks

-- A window whose Plotroom pane (a linked block opened in the checkout's src directory) lists o/r#5.
local function agentScene(w: World): (Scene, Block)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	return s, linkQueue(w, s)
end
M.agentScene = agentScene

local function always(): boolean
	return true
end
M.always = always

local function checkRun(name: string, status: string, conclusion: string?, startedAt: string?, extra: { [string]: any }?): { [string]: any }
	local node: { [string]: any } = { name = name, status = status, conclusion = conclusion, startedAt = startedAt }
	if extra then
		for k, v in extra do
			node[k] = v
		end
	end
	return node
end
M.checkRun = checkRun

export type SearchOut = { result: any, problem: any, spent: number?, calls: number }

local function runSearch(w: World, github: Github, shouldContinue: (() -> boolean)?): SearchOut
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.search(nil, "is:open", shouldContinue or always, function(result, problem, spent)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.spent = spent
	end)
	w.flush()
	return out
end
M.runSearch = runSearch

export type ChecksOut = { runs: any, total: number?, problem: any, calls: number }

local function runChecks(github: Github, shouldContinue: (() -> boolean)?, account: string?): ChecksOut
	local out: ChecksOut = { runs = nil, total = nil, problem = nil, calls = 0 }
	github.checks("o/r", 5, account, function(runs, total, problem)
		out.calls += 1
		out.runs, out.total, out.problem = runs, total, problem
	end, shouldContinue)
	return out
end
M.runChecks = runChecks

local function nodes(count: number): { any }
	local list: { any } = {}
	for i = 1, count do
		table.insert(list, checkRun("job " .. i, "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "N" .. i }))
	end
	return list
end
M.nodes = nodes

-- How many acli calls of `kind` were made.
local function acliCount(acli: Acli, kind: string): number
	local n = 0
	for _, req in acli.requests do
		if req.kind == kind then
			n += 1
		end
	end
	return n
end
M.acliCount = acliCount

export type HostScene = { git: Git, gh: Gh }

-- A checkout of o/r at /work/r whose origin is github.com/o/r, and `count` PRs for the active gh account, on the
-- fixture views.
local function hostScene(w: World, count: number?): HostScene
	w.load("host")
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", count or 3)
	hx.fixtureViews(w)
	return { git = g, gh = gh }
end
M.hostScene = hostScene

-- The block of `pane` launched in /work/r, after its repository lookup and first search: its first row is selected.
local function openQueue(w: World, pane: number?): Block
	local b = w.open(pane or 1, { "/work/r" })
	w.flush()
	return b
end
M.openQueue = openQueue

-- Forgets every saved checkout: opening the queue in /work/r saves that one.
local function forgetCheckouts(w: World)
	local store: any = w.kv.store
	store.checkouts = nil
end
M.forgetCheckouts = forgetCheckouts

-- Leaves PR `n` of o/r a worktree in the checkout of `hostScene`, as an earlier version of Plotroom made it: in the folder
-- the default format names, on branch plotroom/o/r/pr-<n> (not the PR's head branch) at `at` (sha("b") unless given), and
-- the ref its head was fetched into. Its path. Only git lists it: nothing else remembers it.
local function leaveWt(w: World, s: HostScene, n: number, at: string?): string
	local path, branch = "/wt/plotroom-o_r-pr-" .. n, "plotroom/o/r/pr-" .. n
	table.insert(s.git.worktrees, { path = path, branch = "refs/heads/" .. branch, head = at or sha("b"), locked = false })
	s.git.refs["refs/heads/" .. branch] = at or sha("b")
	s.git.refs["refs/plotroom-pr/o/r/pr-" .. n] = at or sha("b")
	w.fs.dirs[path] = true
	return path
end
M.leaveWt = leaveWt

-- Refreshes `b` as its `r` key does and lets everything that starts finish.
local function refreshNow(w: World, b: Block)
	b.typeText("r")
	w.flush()
end
M.refreshNow = refreshNow

local function requestsOf(gh: Gh, kind: string): { GhReq }
	local out: { GhReq } = {}
	for _, req in gh.requests do
		if req.kind == kind then
			table.insert(out, req)
		end
	end
	return out
end
M.requestsOf = requestsOf

local function listed(b: Block): { string }
	local out: { string } = {}
	local order: any = pickerOf(b).order
	for _, id in order do
		table.insert(out, id)
	end
	return out
end
M.listed = listed

-- Clicks sidebar scope `id` of `b`.
local function pickScope(b: Block, id: string)
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = id })
end
M.pickScope = pickScope

local function actionOf(b: Block, id: string): any
	for _, action in pickerOf(b).actions do
		if action.id == id then
			return action
		end
	end
	return nil
end
M.actionOf = actionOf

-- One row of the settings page by id.
local function rowIn(b: Block, id: string): any
	for _, section in prefsOf(b).sections do
		for _, row in section.rows do
			if row.id == id then
				return row
			end
		end
	end
	return nil
end
M.rowIn = rowIn

-- The section of the settings page that holds row `id`.
local function sectionIn(b: Block, id: string): any
	for _, section in prefsOf(b).sections do
		for _, row in section.rows do
			if row.id == id then
				return section
			end
		end
	end
	return nil
end
M.sectionIn = sectionIn

-- Opens Settings on `page` with its first row focused, as the command palette's Settings does (no key needed): Tab
-- walks the pages the block offers.
local function goToSettings(b: Block, page: string)
	if findKey(b.view().layer, "settings", "prefs") == nil then
		b.event({ ev = "action", id = "layer.queue", act = "queue", value = "settings" })
	end
	for _ = 1, #prefsOf(b).pages do
		if prefsOf(b).page == page then
			break
		end
		b.press("tab")
	end
	eq(prefsOf(b).page, page, "Settings has a " .. page .. " page")
	b.press("down")
end
M.goToSettings = goToSettings

-- Expands the view or prompt whose summary row is `row` ("vopen:<kind>:<id>" / "popen:<kind>:<id>", the kind being prs or issues), as its Edit button does.
local function expand(b: Block, row: string)
	b.event({ ev = "action", id = "layer.settings", act = "expand", value = row })
end
M.expand = expand

-- Presses `key` on the Keys row of action `id` ("" is Backspace, which removes the shortcut): the warning under the row
-- afterwards. The row captures one key: Enter starts it, the next key that types text is the shortcut at once. A refused
-- key leaves the capture open (the row's warning shows), and the next call presses another key.
local function bindKey(b: Block, id: string, key: string): string?
	local row = "key:" .. id
	if prefsOf(b).editing == nil then
		b.event({ ev = "select", id = "layer.settings", item = row })
		b.press("enter")
	end
	if key == "" then
		b.press("backspace")
	else
		b.typeText(key)
	end
	return rowIn(b, row).warning
end
M.bindKey = bindKey

-- The shortcut list overlay's rows under `node`: each one's keycap labels and its description.
local function helpEntries(node: any): { { caps: { string }, text: string } }
	local out: { { caps: { string }, text: string } } = {}
	local list: any = findKey(node, "keys")
	if list == nil then
		return out
	end
	for _, row in list.c do
		local caps: { string } = {}
		for _, cap in findKey(row, "caps").p.spans do
			local label: any = if type(cap) == "table" then cap.t else cap
			if type(label) == "string" and label ~= " " then
				table.insert(caps, label)
			end
		end
		table.insert(out, { caps = caps, text = findKey(row, "text").p.spans[1].t })
	end
	return out
end
M.helpEntries = helpEntries

-- The rows of a shortcut list overlay found under `node`: each one's key labels, joined by a space, and what it does.
local function helpRows(node: any): { { keys: string, text: string } }
	local out: { { keys: string, text: string } } = {}
	for _, entry in helpEntries(node) do
		table.insert(out, { keys = table.concat(entry.caps, " "), text = entry.text })
	end
	return out
end
M.helpRows = helpRows

-- What the command palette's `menu` answer of block `b` says now: the queue actions' ids in order with their groups, keys,
-- labels and details by id, and the ids of the window commands that apply, with the group the host gave each (nil: its own).
hx.paletteAsks = 0
function hx.palette(w: World, b: Block): any
	hx.paletteAsks += 1
	local id = "pal" .. hx.paletteAsks
	request(b, id, { op = "menu", palette = true })
	w.flush()
	local a: any = answerOf(b, id)
	local out: any = { ids = {}, groups = {}, keys = {}, labels = {}, details = {}, commands = {}, commandGroups = {} }
	for _, q in a.queue do
		table.insert(out.ids, q.id)
		out.groups[q.id], out.keys[q.id], out.labels[q.id], out.details[q.id] = q.group, q.key, q.label, q.detail
	end
	for _, c in a.commands do
		table.insert(out.commands, c.id)
		out.commandGroups[c.id] = c.group
	end
	return out
end

-- The views saved under kv `key` as "<id> <name> · <integration> · <group>[ · <sort>]", in order.
function hx.viewRows(w: World, key: string): { string }
	local out: { string } = {}
	for _, v in w.kv.get(key).items do
		table.insert(out, v.id .. " " .. v.name .. " · " .. v.integration .. " · " .. v.group .. (if v.sort then " · " .. v.sort else ""))
	end
	return out
end

-- The prompt editor card of the Settings view; nil when no prompt's text is being edited.
local function editorCard(b: Block): any
	return findKey(b.view().layer, "prompt", "col")
end
M.editorCard = editorCard

-- Another live block `c`, its Settings open on the Views page with view prs:v1's form open, saves a rename of that view
-- after `logins` were written to the saved view: the other blocks reload the views and so learn the new logins.
local function loginsSavedBy(w: World, c: Block, logins: { string }, name: string)
	local store: any = w.kv.get("views-prs")
	store.items[1].logins = array(logins)
	w.kv.put("views-prs", store)
	c.press("enter")
	c.press("a", "c")
	c.typeText(name)
	c.press("enter")
end
M.loginsSavedBy = loginsSavedBy

-- A checkout of o/r at /work/r whose origin is github.com/o/r and whose remote serves its default branch at sha("b"),
-- with three issues for the active gh account, the newest first: #12 "Fix login" (labels bug and ui, assigned to ann and
-- bob), #13 closed as not planned and #14 closed as completed; on the fixture views.
local function issueHost(w: World): HostScene
	w.load("host")
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	g.served["refs/heads/main"] = sha("b")
	g.defaultBranch = "main"
	local gh = newGh(w)
	gh.issueItems.octocat = {
		issueItem(12, "o/r", EPOCH - 60, { title = "Fix login", labels = array({ "bug", "ui" }), assignees = array({ "ann", "bob" }), comments = 3 }),
		issueItem(13, "o/r", EPOCH - 120, { title = "Add dark mode", state = "CLOSED", reason = "NOT_PLANNED" }),
		issueItem(14, "o/r", EPOCH - 180, { title = "Docs typo", author = "ann", state = "CLOSED", reason = "COMPLETED" }),
	}
	hx.fixtureViews(w)
	return { git = g, gh = gh }
end
M.issueHost = issueHost

-- The Plotroom block of `pane` launched in /work/r and restored on the first issue filter (`v1` of views-issues), after
-- its repository lookup and first search: its first row is selected.
local function openIssues(w: World, pane: number?): Block
	local b = w.open(pane or 1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "issues", activeViewId = "v1" })
	w.flush()
	return b
end
M.openIssues = openIssues

-- Leaves issue `n` of o/r a worktree in the checkout of `issueHost`, as `omp worktree add` does: in the folder the default
-- issue format names, on branch <n>-fix-login. Its path. Only git lists it.
local function leaveIssueWt(w: World, s: HostScene, n: number): string
	local path = "/wt/plotroom-o_r-issue-" .. n
	table.insert(s.git.worktrees, { path = path, branch = "refs/heads/" .. n .. "-fix-login", head = sha("b"), locked = false })
	w.fs.dirs[path] = true
	return path
end
M.leaveIssueWt = leaveIssueWt

-- A window whose pane 1 is the Plotroom block of `issueHost` on its first issue filter, linked: the window's requests
-- reach its host half, which runs git and omp, and the answers come back. The window reads the links the block's own
-- view keeps unseen.
local function issueWindow(w: World): (HostScene, Block)
	local s = issueHost(w)
	w.load("window")
	local b = openIssues(w)
	w.link(b)
	cardSurface(w, b)
	return s, b
end
M.issueWindow = issueWindow

-- The Jira side of the issue filters: project ABC checked out at /work/r (its origin is on GitLab: a Jira project names
-- no repository) whose remote serves its default branch at sha("b"). acli is signed in to acme.atlassian.net and finds
-- under "Assigned to me" ABC-12 "Fix login" (In Progress, a High-priority Bug of Bob Ray, labelled ui) and ABC-13 "Old
-- bug" (Done), in that order, as the only issue filter. A Jira filter never searches through gh.
export type JiraScene = { git: Git, acli: Acli, gh: Gh }
local JIRA_ASSIGNED = "(assignee = currentUser() AND statusCategory != Done) ORDER BY priority DESC, updated DESC"
M.JIRA_ASSIGNED = JIRA_ASSIGNED

local function jiraHost(w: World): JiraScene
	w.load("host")
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	g.served["refs/heads/main"] = sha("b")
	g.defaultBranch = "main"
	local acli = newAcli(w)
	acli.searches[JIRA_ASSIGNED] = {
		jiraItem("ABC-12", "Fix login", {
			status = { name = "In Progress", statusCategory = { key = "indeterminate" } },
			issuetype = { name = "Bug" },
			priority = { name = "High" },
			assignee = { displayName = "Bob Ray" },
			labels = array({ "ui" }),
		}),
		jiraItem("ABC-13", "Old bug", { status = { name = "Done", statusCategory = { key = "done" } } }),
	}
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	w.kv.put("jira-repos", { ABC = array({ "o/r" }) })
	w.kv.put("views-issues", {
		version = 1,
		nextId = 2,
		items = array({ { id = "v1", name = "Assigned to me", integration = "jira", query = "assignee = currentUser() AND statusCategory != Done", group = "none", prompts = array({}) } }),
	})
	return { git = g, acli = acli, gh = newGh(w) }
end
M.jiraHost = jiraHost

local function issueLink(kind: string, repo: string, ref: string): string
	return "plotroom://issue/" .. kind .. "/" .. repo .. "/" .. ref
end
M.issueLink = issueLink

-- The link of the card's button that runs saved prompt `id` on issue `repo`#`ref`.
local function issueRunLink(repo: string, ref: string, id: string): string
	return issueLink("run", repo, ref) .. "/" .. id
end
M.issueRunLink = issueRunLink

-- The worktree request a window sends once its chooseBase picker was answered with `base` (main): a new branch from it.
local function freshAsk(repo: string, ref: string, base: string?): { [string]: any }
	return { op = "issue", repo = repo, ref = ref, worktree = true, fresh = true, base = base or "main" }
end
M.freshAsk = freshAsk

-- A saved issue prompt as kv keeps it: `inWorktree` false runs it in the main checkout, nil leaves the field out.
local function issuePrompt(id: string, name: string, text: string, inWorktree: boolean?, key: string?): { [string]: any }
	local p = promptOf(id, name, text, key)
	p.worktree = inWorktree
	return p
end
M.issuePrompt = issuePrompt

-- Makes `list` the saved issue prompts.
local function saveIssuePrompts(w: World, list: { { [string]: any } })
	w.kv.put("prompts-issues", { version = 1, nextId = #list + 1, items = array(list) })
end
M.saveIssuePrompts = saveIssuePrompts

-- The link the selected row's card keeps unseen for button `id`; nil when it keeps none.
local function buttonLink(b: Block, id: string): string?
	local node: any = findKey(findKey(pickerNode(b), "buttons"), id)
	return if node then node.p.href else nil
end
M.buttonLink = buttonLink

-- A picker row's detail line as plain text: its strings and the text of its spans.
local function detailText(row: any): string
	local out: { string } = {}
	for _, part in row.detail do
		table.insert(out, if type(part) == "table" then part.t else part)
	end
	return table.concat(out)
end
M.detailText = detailText

-- The text of the selected issue's property `key` ("Author", "Assignees", ...); nil when it shows none.
local function factOf(b: Block, key: string): string?
	local facts: any = findKey(findKey(pickerNode(b), "about"), "facts", "kv")
	for _, item in facts.p.items do
		if item.k == key then
			local out: { string } = {}
			if type(item.v) == "table" then
				for _, span in item.v do
					table.insert(out, if type(span) == "table" then span.t else span)
				end
			else
				table.insert(out, item.v)
			end
			return table.concat(out)
		end
	end
	return nil
end
M.factOf = factOf

-- Types `text` over what text row `row` of Settings holds and presses Enter: the warning under the row afterwards. A
-- refused value leaves the edit open, and the next call for the same row types over its draft.
function hx.save(b: Block, row: string, text: string): string?
	local editing = prefsOf(b).editing
	if editing ~= nil and editing.row ~= row then
		b.press("escape")
		editing = nil
	end
	if editing == nil then
		b.event({ ev = "select", id = "layer.settings", item = row })
		b.press("enter")
	end
	b.press("a", "c")
	b.press("backspace")
	b.typeText(text)
	b.press("enter")
	return rowIn(b, row).warning
end

-- Resets text row `row` of Settings, as its Reset button does: the warning under the row afterwards.
function hx.reset(b: Block, row: string): string?
	b.event({ ev = "change", id = "layer.settings", item = row })
	return rowIn(b, row).warning
end

-- The answer of block `b` to request `body` once everything it started has run.
function hx.ask(w: World, b: Block, id: string, body: { [string]: any }): any
	request(b, id, body)
	w.flush()
	return answerOf(b, id)
end

-- The picker rows of `b` that wear the "In tab" badge, as their ids in list order.
function hx.inTab(b: Block): { string }
	local out: { string } = {}
	for _, item in pickerOf(b).items do
		for _, badge in item.badges or {} do
			if badge.text == "In tab" then
				table.insert(out, item.id)
			end
		end
	end
	return out
end

-- The branch the selected issue's preview says a new worktree would make; nil when it shows none.
function hx.branchRow(b: Block): string?
	local node: any = findKey(pickerNode(b), "branch")
	return if node then findKey(node, "v").p.spans[1].t else nil
end

-- Serves pull request `n` of o/r (head branch `branch` at sha("c")) to gh and git, and returns the entry gh lists it
-- under for an issue it is linked to; `live` false is a pull request whose head branch was deleted.
function hx.linkedPr(s: HostScene, n: number, title: string, branch: string, live: boolean): { [string]: any }
	s.gh.meta["o/r#" .. n] = { base = "o/r", sha = sha("c"), ref = branch, headRepo = "o/r", headOwner = "o", state = "open", baseRef = "main", title = title, author = "ann" }
	s.git.served["refs/pull/" .. n .. "/head"] = sha("c")
	if live then
		s.git.served["refs/heads/" .. branch] = sha("c")
	end
	return { number = n, title = title, head = branch, branch = if live then branch else NULL, base = "o/r" }
end

-- `program` ("gh" | "acli") is not installed while the returned switch's `missing` holds: every spawn of it fails to
-- start, whatever a model of it would answer.
function hx.uninstalled(w: World, program: string): { missing: boolean }
	local switch = { missing = true }
	w.respond(function(call: Call): Reply?
		if switch.missing and call.argv[1] == program then
			return { raise = "spawn " .. program .. ": no such file or directory" }
		end
		return nil
	end)
	return switch
end

-- The ids of the pages Settings offers, in order.
function hx.pages(b: Block): { string }
	local out: { string } = {}
	for _, p in prefsOf(b).pages do
		table.insert(out, p.id)
	end
	return out
end

-- The ids of the rows of the Settings page shown, in order.
function hx.rows(b: Block): { string }
	local out: { string } = {}
	for _, section in prefsOf(b).sections do
		for _, r in section.rows do
			table.insert(out, r.id)
		end
	end
	return out
end

-- Helpers of the cases below, grouped in one table.
local asks = {}
M.asks = asks
asks.protocol = "22" -- mirrors host/core's RPC_PROTOCOL (what the `main.rpc` node says): the one place the window cases name it

-- The requests the window sent to blocks' hosts so far, decoded, without their ids.
function asks.sent(w: World): { any }
	local out: { any } = {}
	for _, q in requestsSent(w) do
		local copy: { [string]: any } = {}
		for k, v in q do
			if k ~= "id" then
				copy[k] = v
			end
		end
		table.insert(out, copy)
	end
	return out
end

-- The `issue` request of a window asking for a worktree of `ref` in `repo`, with what the user settled on top of it.
function asks.issue(repo: string, ref: string, settled: { [string]: any }?): { [string]: any }
	local q: { [string]: any } = { op = "issue", repo = repo, ref = ref, worktree = true, users = false }
	local extra: { [string]: any } = settled or {}
	for k, v in extra do
		q[k] = v
	end
	return q
end

-- A picker's rows as "label — detail @ group", in the order shown; a row without a detail or a group leaves that out.
function asks.rows(pick: any): { string }
	local out: { string } = {}
	for _, item in pick.items do
		table.insert(out, item.label .. (if item.detail then " — " .. item.detail else "") .. (if item.group then " @ " .. item.group else ""))
	end
	return out
end

-- How many toasts read exactly `text`.
function asks.toasted(w: World, text: string): number
	local n = 0
	for _, t in w.toasts do
		if t.text == text then
			n += 1
		end
	end
	return n
end

-- Pull request `n` of o/r titled `title` on its same-repository head branch `branch`, which gh and the remote both serve
-- at sha(`c`); the entry an issue's linked pull requests list holds for it.
function asks.pr(s: HostScene, n: number, title: string, branch: string, c: string): { [string]: any }
	s.gh.meta["o/r#" .. n] = { base = "o/r", sha = sha(c), ref = branch, headRepo = "o/r", headOwner = "o", state = "open", baseRef = "main", title = title, author = "ann" }
	s.git.served["refs/pull/" .. n .. "/head"] = sha(c)
	s.git.served["refs/heads/" .. branch] = sha(c)
	return { number = n, title = title, head = branch, branch = branch, base = "o/r" }
end

-- A window on the issue filter whose issue #12 is linked to pull requests #7 (branch fix-login), #9 (fix-login-mobile) and
-- #3, whose branch is gone.
function asks.several(w: World): (HostScene, Block)
	local s, b = issueWindow(w)
	s.gh.linked["o/r#12"] = array({
		asks.pr(s, 7, "Fix login", "fix-login", "c"),
		asks.pr(s, 9, "Fix login on mobile", "fix-login-mobile", "d"),
		{ number = 3, title = "First try", head = "old-try", branch = NULL, base = "o/r" },
	})
	return s, b
end

-- Helpers hang on `asks.bk`, grouping those of the backend cases.
asks.bk = {}

-- A gh whose every non-read command (kind "other": issue edit, pr create, run view/rerun) goes to `answer` by its argv
-- joined by spaces; a line it does not model fails. `seen` lists those lines in order.
function asks.bk.gh(w: World, answer: (string) -> Reply?): (Gh, { string })
	local gh = newGh(w)
	local seen: { string } = {}
	gh.override = function(req: GhReq): Reply?
		if req.kind ~= "other" then
			return nil
		end
		local line = table.concat(req.call.argv, " ")
		table.insert(seen, line)
		return answer(line) or { status = 1, stderr = "gh: not modelled\n" }
	end
	return gh, seen
end

-- Runs a write that answers done(problem) and returns the one problem (nil: success); never synchronous, answers once.
function asks.bk.once(w: World, start: ((any) -> ()) -> ()): any
	local calls: number, got: any = 0, nil
	start(function(p: any)
		calls += 1
		got = p
	end)
	eq(calls, 0, "never synchronous")
	w.flush()
	eq(calls, 1, "answers once")
	return got
end

-- "kind:repo:number" of a parsed item link; "nil" when refused.
function asks.bk.brief(p: any): string
	return if p then p.kind .. ":" .. p.repo .. ":" .. p.number else "nil"
end

-- tern.fetch and tern.base64 for the Jira REST routes: `route(req)` answers { status, body } by "METHOD /path".
function asks.bk.fetch(w: World, route: (any) -> { status: number, body: string }?): { any }
	local reqs: { any } = {}
	w.sdk.base64 = {
		encode = function(s: string): string
			return "b64:" .. s
		end,
	}
	w.sdk.fetch = function(url: string, opts: any, cb: (any) -> ())
		local req = { url = url, method = opts.method, headers = opts.headers, body = opts.body, line = opts.method .. " " .. string.sub(url, #"https://acme.atlassian.net" + 1) }
		table.insert(reqs, req)
		local reply = route(req) or { status = 500, body = "" }
		w.sdk.timer(0, function()
			cb({ status = reply.status, body = reply.body })
		end)
	end
	return reqs
end

-- Jira REST fixtures: /myself names `who`, the transitions of ABC-1 are `list`; the POST answers `post`.
function asks.bk.rest(w: World, who: string, list: { any }, post: { status: number, body: string }?): { any }
	return asks.bk.fetch(w, function(req: any): { status: number, body: string }?
		if req.line == "GET /rest/api/3/myself" then
			return { status = 200, body = jsonEncode({ emailAddress = who }) }
		elseif req.line == "GET /rest/api/3/issue/ABC-1/transitions" then
			return { status = 200, body = jsonEncode({ transitions = array(list) }) }
		elseif req.line == "POST /rest/api/3/issue/ABC-1/transitions" then
			return post or { status = 204, body = "" }
		end
		return nil
	end)
end

-- A checkout of o/r at /work/r (main at sha("1")) whose origin is github.com/o/r.
function asks.bk.repo(w: World): Git
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	return g
end

-- Adds a linked worktree at `path` on `branch` (nil: detached) at `head` (sha("b")); its folder exists unless `gone`.
function asks.bk.tree(w: World, g: Git, path: string, branch: string?, head: string?, extra: { locked: boolean?, prunable: boolean?, gone: boolean? }?)
	local at = head or sha("b")
	local x: { locked: boolean?, prunable: boolean?, gone: boolean? } = extra or {}
	table.insert(g.worktrees, { path = path, branch = if branch then "refs/heads/" .. branch else nil, head = at, locked = x.locked == true, prunable = x.prunable })
	if branch then
		g.refs["refs/heads/" .. branch] = at
	end
	if not x.gone then
		w.fs.dirs[path] = true
	end
end

-- Runs an async worktree call and returns its one answer packed ({ [1], [2], [3], n }).
function asks.bk.pack(w: World, start: ((...any) -> ()) -> ()): any
	local calls: number, got: any = 0, nil
	start(function(...: any)
		calls += 1
		got = table.pack(...)
	end)
	eq(calls, 0, "never synchronous")
	w.flush()
	eq(calls, 1, "answers once")
	return got
end

-- The inventory scene: a main checkout and one worktree of each kind.
function asks.bk.inventoryRepo(w: World): Git
	local g = asks.bk.repo(w)
	asks.bk.tree(w, g, "/wt/pr5", "feature")
	g.notes["branch.feature.plotroompr"] = "5"
	g.notes["branch.feature.plotroomrepo"] = "o/r"
	asks.bk.tree(w, g, "/wt/lk", "lk", nil, { locked = true })
	asks.bk.tree(w, g, "/wt/gone", "gn", nil, { gone = true })
	asks.bk.tree(w, g, "/wt/prune", "pr", nil, { prunable = true })
	asks.bk.tree(w, g, "/wt/det", nil, sha("d"))
	asks.bk.tree(w, g, "/wt/issue", "abc-1")
	g.notes["branch.abc-1.plotroomkey"] = "ABC-1"
	g.notes["branch.abc-1.plotroomrepo"] = "o/r"
	asks.bk.tree(w, g, "/wt/foreign", "fx")
	g.notes["branch.fx.plotroomkey"] = "Z-9"
	g.notes["branch.fx.plotroomrepo"] = "x/y"
	return g
end

-- A checkout with the worktree /wt/x on my-feat at sha("c"), two commits over main, which the remote serves at sha("1").
function asks.bk.drafted(w: World): Git
	local g = asks.bk.repo(w)
	asks.bk.tree(w, g, "/wt/x", "my-feat", sha("c"))
	g.served["refs/heads/main"] = sha("1")
	g.counts[sha("c")] = 2
	return g
end

-- Helpers hang on `asks.hx`, grouping those of the host workflow cases: triage, sorts, agent status, item mutations,
-- draft pull requests, the Worktrees list, export and import, open by URL.
asks.hx = {}
asks.hx.seq = 0

-- The text of the first badge of picker row `id` that is one of `names`; "-" when it wears none.
function asks.hx.badge(b: Block, id: string, names: { string }): string
	for _, row in pickerOf(b).items do
		if row.id == id then
			for _, badge in row.badges or {} do
				if table.find(names, badge.text) then
					return badge.text
				end
			end
		end
	end
	return "-"
end

-- The triage mark (New, Changed, Snoozed) of row `id`, "-" for none.
function asks.hx.mark(b: Block, id: string): string
	return asks.hx.badge(b, id, { "New", "Changed", "Snoozed" })
end

-- The agent badge of row `id`, "-" for none.
function asks.hx.agent(b: Block, id: string): string
	return asks.hx.badge(b, id, { "Working", "Needs input", "Idle", "Exited" })
end

-- The triage mark of every listed row, in the order listed.
function asks.hx.marks(b: Block): { string }
	local out: { string } = {}
	for _, id in listed(b) do
		table.insert(out, asks.hx.mark(b, id))
	end
	return out
end

-- The keys of a table, sorted.
function asks.hx.keys(t: any): { string }
	local out: { string } = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- The window's `agent-status` report: a state as a string, or the whole row ({ state, action?, branch?, title? }).
function asks.hx.agents(b: Block, map: { [string]: any })
	local sent: { [string]: any } = {}
	for k, v in map do
		sent[k] = if type(v) == "string" then { state = v } else v
	end
	b.event({ ev = "action", act = "agent-status", value = jsonEncode(sent) })
end

-- Sends the block a request as the window does and returns its answer once everything it started has finished.
function asks.hx.ask(w: World, b: Block, body: { [string]: any }): any
	asks.hx.seq += 1
	return hx.ask(w, b, "h" .. asks.hx.seq, body)
end

-- Makes gh answer every command no model reads (issue edit, pr create, run view and rerun) and returns the command
-- lines it was given, in order; `answer` may reply to a line, anything else gets an empty success.
function asks.hx.writes(gh: Gh, answer: ((string) -> Reply?)?): { string }
	local seen: { string } = {}
	if gh.tokens.octocat == nil then
		gh.tokens.octocat = "tok-octocat" -- the concrete account every plan names has a token, as a signed-in one does
	end
	gh.override = function(req: GhReq): Reply?
		if req.kind ~= "other" then
			return nil
		end
		local line = table.concat(req.call.argv, " ")
		table.insert(seen, line)
		return (if answer then answer(line) else nil) or { stdout = "" }
	end
	return seen
end

-- The option values of a choice row of the settings page.
function asks.hx.options(b: Block, row: string): { string }
	local out: { string } = {}
	for _, o in rowIn(b, row).control.options do
		table.insert(out, o.value)
	end
	return out
end

-- A checkout of o/r at /work/r whose issue 12 has a worktree on 12-fix-login two commits over a main the remote serves at
-- sha("1"); the issue filter is saved.
function asks.hx.draftScene(w: World): (HostScene, any)
	local s = issueHost(w)
	leaveIssueWt(w, s, 12)
	local tree: any = s.git.worktrees[#s.git.worktrees]
	tree.head = sha("c")
	s.git.refs["refs/heads/12-fix-login"] = sha("c")
	s.git.served["refs/heads/main"] = sha("1")
	s.git.counts[sha("c")] = 2
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	return s, tree
end

-- The name "repo/branch" of picker row `item` of the Worktrees board: its label is the folder's name now, so the row is
-- found in the block's board by the folder its detail line starts with.
function asks.hx.nameOf(b: Block, item: any): string
	local path: string = item.detail[1].t
	for _, row in b.state().board.rows do
		if row.path == path then
			return row.repo .. "/" .. (row.branch or "(detached)")
		end
	end
	error("no board row at " .. path, 2)
end

-- The picker items by id.
local function byId(b: Block): { [string]: any }
	local out: { [string]: any } = {}
	for _, item in pickerOf(b).items do
		out[item.id] = item
	end
	return out
end

-- The Worktrees board's rows as "repo/branch", in the order listed (group headings skipped).
function asks.hx.board(b: Block): { string }
	local items = byId(b)
	local out: { string } = {}
	for _, entry in pickerOf(b).order do
		if type(entry) ~= "table" then
			table.insert(out, asks.hx.nameOf(b, items[entry]))
		end
	end
	return out
end

-- The picker id of the board row `name` ("o/r/feature").
function asks.hx.rowId(b: Block, name: string): string
	local items = byId(b)
	for _, entry in pickerOf(b).order do
		if type(entry) ~= "table" and asks.hx.nameOf(b, items[entry]) == name then
			return entry
		end
	end
	error("no board row " .. name, 2)
end

-- The picker item of the board row `name`.
function asks.hx.rowItem(b: Block, name: string): any
	return byId(b)[asks.hx.rowId(b, name)]
end

-- The badges of the board row `name`, joined by commas.
function asks.hx.badges(b: Block, name: string): string
	local out: { string } = {}
	for _, badge in asks.hx.rowItem(b, name).badges or {} do
		table.insert(out, badge.text)
	end
	return table.concat(out, ",")
end

-- Two saved checkouts, o/r at /work/r (main, /wt/pr5 on feature for pull request 5, a locked /wt/lk) and x/y at /work/y
-- (main, /wt/yb on yb for pull request 7). The block is launched in o/r: the board must list x/y as well.
function asks.hx.boardScene(w: World): (HostScene, Git)
	local s = hostScene(w, 3)
	w.kv.put("checkouts", { ["o/r"] = "/work/r", ["x/y"] = "/work/y" })
	asks.bk.tree(w, s.git, "/wt/pr5", "feature")
	s.git.notes["branch.feature.plotroompr"] = "5"
	s.git.notes["branch.feature.plotroomrepo"] = "o/r"
	asks.bk.tree(w, s.git, "/wt/lk", "lk", nil, { locked = true })
	local y = newGit(w, "/work/y")
	y.remotes.origin = { "https://github.com/x/y.git" }
	asks.bk.tree(w, y, "/wt/yb", "yb")
	y.notes["branch.yb.plotroompr"] = "7"
	y.notes["branch.yb.plotroomrepo"] = "x/y"
	return s, y
end

-- The JSON of an export of views and actions, previewed then committed.
function asks.hx.exported(w: World, b: Block, views: { string }, prompts: { string }): string
	local pv = asks.hx.ask(w, b, { op = "export", views = views, prompts = prompts })
	return asks.hx.ask(w, b, { op = "export", phase = "commit", token = pv.token }).json
end

-- Two saved prs views (My PRs runs as octocat, who has a token) and actions (a keyed one and one that holds a secret),
-- and the checkout and setup commands an export must leave out.
function asks.hx.saved(w: World): HostScene
	local s = hostScene(w, 3)
	s.gh.tokens.octocat = "tok-octo"
	savePrompts(w, { promptOf("p1", "Review", "Review {url}", "e"), promptOf("p2", "Leaky", "Log in with gh" .. "p_" .. string.rep("a", 30)) })
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", logins = array({ "octocat" }), group = "none", prompts = array({ "p1" }) },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", logins = array({}), group = "none", prompts = array({}) },
	}) })
	w.kv.put("setup-commands", { ["o/r"] = array({ "npm install" }) })
	return s
end

-- A document of `views` views and `prompts` actions, as an export holds them.
function asks.hx.doc(views: number, prompts: number): string
	local vs: { any } = {}
	for i = 1, views do
		table.insert(vs, { kind = "prs", name = "View " .. i, integration = "github", query = "is:open", group = "none", accounts = array({}), prompts = array({}) })
	end
	local ps: { any } = {}
	for i = 1, prompts do
		table.insert(ps, { id = "prs:q" .. i, kind = "prs", name = "Action " .. i, text = "Do {url}" })
	end
	return jsonEncode({ format = "plotroom-export", version = 1, views = array(vs), prompts = array(ps) })
end


return M
