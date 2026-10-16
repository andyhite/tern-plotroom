--!strict
-- Behavioral regression suite. scripts/check.py wraps every plugin module as
-- function(tern, require, os) and calls `run` (or `bench`). Each case builds a
-- world -- a fake Tern SDK with a virtual clock (timers and os.time), process
-- runner, kv store, filesystem, JSON, UI builders and block host -- plus
-- semantic gh and git models, and loads the real modules into it. The fakes keep
-- state and fail the way the SDK documents (fs and kv raise, spawns raise,
-- timeouts kill), so a case checks outcomes: toasts, kv, files, argv, rendered
-- text. It never touches the network, a real repository or the user's files.

local M = {}

type Require = (string) -> any
export type Loader = (any, any) -> Require

type Github = typeof(require("../github"))
type Input = typeof(require("../input"))
type Process = typeof(require("../process"))
type Jira = typeof(require("../jira"))

-- 2026-10-12T12:00:00Z: where every world's clock starts.
local EPOCH = 1791806400

-- ---------------------------------------------------------------- assertions

local NULL: any = setmetatable({}, {
	__tostring = function(): string
		return "null"
	end,
})
local arrayTags: { [any]: boolean } = {}

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

local function show(v: any): string
	if type(v) == "string" then
		return '"' .. v .. '"'
	elseif type(v) == "table" then
		local ok, text = pcall(jsonEncode, v)
		return if ok then text else "<table>"
	end
	return tostring(v)
end

-- Assertions are plain functions over `any` (no assert refinement), blaming the calling line.
local function eq(actual: any, expected: any, what: string)
	if actual ~= expected then
		error(what .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
	end
end

local function same(actual: any, expected: any, what: string)
	local a, b = show(actual), show(expected)
	if a ~= b then
		error(what .. ": expected " .. b .. ", got " .. a, 2)
	end
end

local function yes(cond: any, what: string)
	if not cond then
		error(what, 2)
	end
end

local function has(text: any, needle: string, what: string)
	if type(text) ~= "string" or not string.find(text, needle, 1, true) then
		error(what .. ": expected text containing " .. show(needle) .. ", got " .. show(text), 2)
	end
end

local function lacks(text: any, needle: string, what: string)
	if type(text) == "string" and string.find(text, needle, 1, true) then
		error(what .. ": did not expect " .. show(needle) .. " in " .. show(text), 2)
	end
end

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

-- ---------------------------------------------------------------- the fake SDK

type Toast = { level: string, text: string, sub: string? }
type Call = { argv: { string }, cwd: string?, env: { [string]: string }, stdin: string?, timeoutMs: number?, at: number }
type Reply = {
	status: number?,
	stdout: string?,
	stderr: string?,
	delay: number?,
	timedOut: boolean?,
	raise: string?,
	repeatCallback: boolean?, -- a misbehaving runtime that reports one process twice
}
type Responder = (Call) -> Reply?
type PaneRow = { pane: number, cwd: string? }
type Event = { at: number, seq: number, run: () -> (), live: boolean }
type WinPane = { block: string?, cwd: string, tab: number }

-- The window half of the world: sessions, tabs and panes that answer like cx.session/layout/hosts do. A nil from
-- new_tab is the SDK's "no pane" answer; "raise" is a failing call.
type Win = {
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

type Kv = {
	store: { [string]: string }, -- key -> JSON text, exactly what the SDK would keep on disk
	failGet: { [string]: string }, -- key (or "*") -> the error tern.kv.get raises
	failSet: { [string]: string },
	get: (string) -> any, -- decoded value, bypassing failures
	put: (string, any) -> (), -- seeds a value, bypassing failures
}

type Fs = {
	files: { [string]: string },
	dirs: { [string]: boolean },
	denyMkdir: { [string]: string }, -- path -> the error tern.fs.mkdir raises
	mkdirs: { string }, -- every directory mkdir created, in order
}

type Block = {
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

type World = {
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
	-- --version before it lists any view.
	local responders: { Responder } = {
		function(call: Call): Reply?
			local argv = call.argv
			if (argv[1] == "gh" or argv[1] == "acli") and argv[2] == "--version" and #argv == 2 then
				return { stdout = argv[1] .. " version 1.0.0\n" }
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

-- ---------------------------------------------------------------- cases

type Case = { name: string, context: string, run: (World) -> () }
local cases: { Case } = {}

local function case(name: string, run: (World) -> ())
	table.insert(cases, { name = name, context = "host", run = run })
end

local function windowCase(name: string, run: (World) -> ())
	table.insert(cases, { name = name, context = "window", run = run })
end

-- pure selftest (plugin/tests/check.luau), here against the fake SDK
case("selftest: the pure helper assertions of check.luau pass", function(w: World)
	local check = w.load("tests/check") :: { run: () -> () }
	check.run()
end)

-- ---- process.luau: discovery of gh/git when the SDK cannot find them

local PROBE = "\0PLOTROOM_PATH\0/opt/tools/bin:/usr/bin\n\0PLOTROOM_END\0"

local function isProbe(call: Call): boolean
	return call.argv[2] == "-l" and call.argv[3] == "-i"
end

local function probeCount(w: World): number
	local n = 0
	for _, call in w.calls do
		if isProbe(call) then
			n += 1
		end
	end
	return n
end

case("process: a raising spawn with no usable SHELL reports 'could not be started' exactly once", function(w: World)
	local process = w.load("process") :: Process
	w.respond(function(_call: Call): Reply?
		return { raise = "no such file or directory" }
	end)
	local outcomes: { string } = {}
	process.run({ "gh", "api" }, {}, function(result, problem, _cx)
		table.insert(outcomes, if result then "result" else (problem or "?"))
	end)
	w.flush()
	eq(#outcomes, 1, "done calls")
	has(outcomes[1], "gh", "problem names the program")
	eq(#w.calls, 1, "no probe is spawned without a shell")
end)

case("process: a probe that raises fails every waiter once and is not retried until reset", function(w: World)
	local process = w.load("process") :: Process
	w.env.SHELL = "/bin/zsh"
	w.fs.files["/bin/zsh"] = ""
	w.respond(function(_call: Call): Reply?
		return { raise = "spawn failed" }
	end)
	local outcomes: { string } = {}
	local function done(result: ProcessResult?, problem: string?, _cx: WindowCx?)
		table.insert(outcomes, if result then "result" else (problem or "?"))
	end
	process.run({ "git", "status" }, {}, done)
	process.run({ "git", "remote" }, {}, done)
	w.flush()
	eq(#outcomes, 2, "each caller is answered once")
	has(outcomes[1], "git", "first problem names the program")
	has(outcomes[2], "git", "second problem names the program")
	eq(probeCount(w), 1, "two concurrent runs share one probe")
	process.run({ "git", "fetch" }, {}, done)
	w.flush()
	eq(#outcomes, 3, "later runs are answered from the cached failure")
	eq(probeCount(w), 1, "the failed probe is cached")
	process.reset()
	process.run({ "git", "fetch" }, {}, done)
	w.flush()
	eq(probeCount(w), 2, "reset allows a new probe")
end)

case("process: a probe that exits nonzero, times out or prints no markers is cached as a failure", function(w: World)
	local process = w.load("process") :: Process
	w.env.SHELL = "/bin/zsh"
	w.fs.files["/bin/zsh"] = ""
	local probeReply: Reply = { status = 1 }
	w.respond(function(call: Call): Reply?
		if isProbe(call) then
			return probeReply
		end
		return { raise = "spawn failed" }
	end)
	local function attempt(): string
		local text = ""
		process.run({ "gh" }, {}, function(result, problem, _cx)
			text = if result then "result" else (problem or "?")
		end)
		w.flush()
		w.advance(10000)
		return text
	end
	has(attempt(), "exit 1", "nonzero exit")
	eq(probeCount(w), 1, "one probe")
	has(attempt(), "exit 1", "the cached failure is reused")
	eq(probeCount(w), 1, "no second probe while cached")
	process.reset()
	probeReply = { status = -1, timedOut = true, delay = 60000 }
	has(attempt(), "5 seconds", "timeout")
	process.reset()
	probeReply = { status = 0, stdout = "banner only\n" }
	has(attempt(), "exit 0", "no markers")
end)

case("process: the recovered PATH retries the same argv once and later runs start with it", function(w: World)
	local process = w.load("process") :: Process
	w.env.SHELL = "/bin/zsh"
	w.fs.files["/bin/zsh"] = ""
	w.respond(function(call: Call): Reply?
		if isProbe(call) then
			return { stdout = "login banner\n" .. PROBE }
		end
		-- gh exists only under /opt/tools/bin, as a PATH lookup would find it
		local path = call.env.PATH
		if path and string.find(path, "/opt/tools/bin", 1, true) then
			return { stdout = "gh version 2.98.0\n" }
		end
		return { raise = "no such file or directory" }
	end)
	local env: { [string]: string } = { GH_PROMPT_DISABLED = "1" }
	local outcomes: { string } = {}
	local function done(result: ProcessResult?, problem: string?, _cx: WindowCx?)
		table.insert(outcomes, if result then result.stdout else ("problem: " .. (problem or "?")))
	end
	process.run({ "gh", "--version" }, { env = env, timeout_ms = 30000 }, done)
	w.flush()
	same(outcomes, { "gh version 2.98.0\n" }, "the retry reaches the program")
	eq(#w.calls, 3, "spawn, probe, retry")
	eq(w.calls[3].env.PATH, "/opt/tools/bin:/usr/bin", "the retry carries the recovered PATH")
	eq(w.calls[3].env.GH_PROMPT_DISABLED, "1", "the caller's environment is kept")
	eq(w.calls[3].timeoutMs, 30000, "options are kept")
	eq(env.PATH, nil, "the caller's env table is never mutated")
	process.run({ "gh", "--version" }, { env = env }, done)
	w.flush()
	eq(#w.calls, 4, "later runs spawn once, already with the PATH")
	eq(w.calls[4].env.PATH, "/opt/tools/bin:/usr/bin", "cached PATH")
	eq(probeCount(w), 1, "the PATH is probed once")
end)

case("process: a started program that exits nonzero is a result, never a discovery retry", function(w: World)
	local process = w.load("process") :: Process
	w.env.SHELL = "/bin/zsh"
	w.fs.files["/bin/zsh"] = ""
	w.respond(function(_call: Call): Reply?
		return { status = 4, stderr = "gh: not logged in" }
	end)
	local got: ProcessResult? = nil
	process.run({ "gh", "auth", "status" }, {}, function(result, _problem, _cx)
		got = result
	end)
	w.flush()
	yes(got ~= nil, "a result is delivered")
	eq((got :: ProcessResult).status, 4, "the exit status is the program's")
	eq(#w.calls, 1, "no probe after a started process")
	eq(probeCount(w), 0, "no probe")
end)

-- ---- input.luau: UTF-8 cleanup and word editing

type TextModel = { text: string, cur: number, anchor: number?, undo: { { text: string, cur: number, anchor: number? } }, multi: boolean? }

local function model(text: string, cur: number?): TextModel
	return { text = text, cur = cur or #text, anchor = nil, undo = {} }
end

-- A caret is on a boundary when the byte after it does not continue a character.
local function onBoundary(text: string, cur: number): boolean
	local b = string.byte(text, cur + 1)
	return b == nil or b < 0x80 or b >= 0xC0
end

case("input: clean drops only malformed bytes and control characters", function(w: World)
	local input = w.load("input") :: Input
	eq(input.clean("é\x80b"), "éb", "stray continuation byte after a valid character")
	eq(input.clean("a\xC3b"), "ab", "truncated lead byte")
	eq(input.clean("\xFF\xFEx"), "x", "invalid bytes")
	eq(input.clean("a\x01b\r\nc"), "ab c", "control characters and line breaks")
	eq(input.clean("😀\x80"), "😀", "four-byte character kept")
	eq(input.clean("ok"), "ok", "plain ASCII is returned as is")
end)

case("input: ctrl/alt word movement lands on word boundaries and never mid-codepoint", function(w: World)
	local input = w.load("input") :: Input
	local noop = function(_text: string) end
	local m = model("foo bar_baz")
	input.key(m, keyOf("left", "c"), noop)
	eq(m.cur, 4, "ctrl+left to the start of the last word")
	input.key(m, keyOf("left", "c"), noop)
	eq(m.cur, 0, "ctrl+left to the start of the first word")
	input.key(m, keyOf("left", "c"), noop)
	eq(m.cur, 0, "ctrl+left at the start stays")
	input.key(m, keyOf("right", "a"), noop)
	eq(m.cur, 3, "alt+right to the end of the word")
	input.key(m, keyOf("right", "a"), noop)
	eq(m.cur, 11, "alt+right to the end of the next word")
	local u = model("a😀 é")
	for _ = 1, 4 do
		input.key(u, keyOf("left", "c"), noop)
		yes(onBoundary(u.text, u.cur), "ctrl+left lands on a codepoint boundary")
	end
	u.cur = 0
	for _ = 1, 4 do
		input.key(u, keyOf("right", "c"), noop)
		yes(onBoundary(u.text, u.cur), "ctrl+right lands on a codepoint boundary")
	end
end)

case("input: ctrl/alt+backspace and delete remove one word; a selection wins", function(w: World)
	local input = w.load("input") :: Input
	local noop = function(_text: string) end
	local m = model("foo  bar")
	input.key(m, keyOf("backspace", "c"), noop)
	eq(m.text, "foo  ", "ctrl+backspace removes the word before the caret")
	eq(m.cur, 5, "caret after the removal")
	local d = model("foo  bar", 0)
	input.key(d, keyOf("delete", "c"), noop)
	eq(d.text, "  bar", "ctrl+delete removes the word after the caret")
	eq(d.cur, 0, "caret stays")
	local a = model("foo  bar")
	input.key(a, keyOf("backspace", "a"), noop)
	eq(a.text, "foo  ", "alt+backspace works like ctrl")
	local s = model("abcdef")
	s.anchor, s.cur = 1, 3
	input.key(s, keyOf("backspace", "c"), noop)
	eq(s.text, "adef", "with a selection ctrl+backspace deletes only the selection")
	local t = model("abcdef")
	t.anchor, t.cur = 1, 3
	input.key(t, keyOf("delete", "c"), noop)
	eq(t.text, "adef", "with a selection ctrl+delete deletes only the selection")
end)

case("input: selection collapses, extends by word, and meta word keys are not handled", function(w: World)
	local input = w.load("input") :: Input
	local noop = function(_text: string) end
	local m = model("foo bar baz")
	m.anchor, m.cur = 4, 7
	input.key(m, keyOf("left", "c"), noop)
	eq(m.cur, 4, "ctrl+left collapses to the start of the selection")
	eq(m.anchor, nil, "no anchor after collapsing")
	m.anchor, m.cur = 4, 7
	input.key(m, keyOf("right", "c"), noop)
	eq(m.cur, 7, "ctrl+right collapses to the end of the selection")
	local x = model("foo bar baz", 4)
	input.key(x, keyOf("left", "cs"), noop)
	eq(x.anchor, 4, "ctrl+shift+left anchors at the caret")
	eq(x.cur, 0, "and extends by a word")
	local n = model("foo bar")
	for _, name in { "left", "right", "backspace", "delete" } do
		eq(input.key(n, keyOf(name, "m"), noop), false, "meta+" .. name .. " is not handled")
	end
	eq(input.key(n, keyOf("left", "cm"), noop), false, "ctrl+meta+left is not handled")
	eq(n.text, "foo bar", "unhandled keys change nothing")
	input.key(n, keyOf("a", "c"), noop)
	eq(input.selected(n), "foo bar", "ctrl+a still selects everything")
end)

-- ---------------------------------------------------------------- semantic models of gh and git
-- They answer process.run calls from state: a PR list per login with paging and quota headers, a repository
-- with refs, remotes and worktrees. A case changes that state (or injects a failure) and reads it back.

local function sha(c: string): string
	return string.rep(c, 40)
end

local function array(t: { any }): { any }
	arrayTags[t] = true
	return t
end

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

-- PRs 1..count of `repo`, the newest update first.
local function manyItems(repo: string, count: number): { { [string]: any } }
	local items: { { [string]: any } } = {}
	for i = 1, count do
		table.insert(items, searchItem(i, repo, EPOCH - i * 60))
	end
	return items
end

type GhLimit = { limit: number, remaining: number, reset: number }
type GhReq = { kind: string, login: string?, fields: { [string]: string }, call: Call }
type Gh = {
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
		if argv[2] == "repo" and argv[3] == "clone" then
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
		elseif kind == "repos" then
			local list = gh.repos[key] or {}
			return { stdout = if #list > 0 then table.concat(list, "\n") .. "\n" else "" }
		end
		return nil
	end)
	return gh
end

type AcliReq = { kind: string, argv: { string } } -- kind: version | auth | search | view | projects | other
type Acli = {
	site: string?, -- the Jira site `acli jira auth status` names; nil: signed out, every jira command fails as unauthorized
	searches: { [string]: { any } }, -- --jql value -> the work items it finds, in the order acli prints them; an unlisted query finds none
	views: { [string]: any }, -- key -> the REST issue `workitem view` prints
	projects: { any }, -- what `project list` prints
	override: ((AcliReq) -> Reply?)?, -- answers first: a failure, a malformed page
	requests: { AcliReq },
}

-- Atlassian's acli as far as the Jira module reads it: `--version`, `jira auth status`, `jira workitem search|view` and
-- `jira project list`.
local function newAcli(w: World): Acli
	local acli: Acli = { site = "acme.atlassian.net", searches = {}, views = {}, projects = {}, override = nil, requests = {} }
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
			kind = argv[4]
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

type GitWorktree = { path: string, branch: string?, head: string, locked: boolean, prunable: boolean? }
type Git = {
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

local gitFallback: { [any]: boolean } = {}

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

local function snapshot(g: Git): string
	return jsonEncode({ refs = g.refs, worktrees = g.worktrees, dirty = g.dirty, config = g.config })
end

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

-- The logged commands from entry `from`+1 on.
local function logFrom(g: Git, from: number): { string }
	local out: { string } = {}
	for i = from + 1, #g.log do
		table.insert(out, g.log[i])
	end
	return out
end

-- ---- worktree.luau: names, remotes, wording

type Worktree = typeof(require("../worktree"))

case("worktree: git-illegal names that GitHub allows are encoded in the fetched ref, never rejected", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local expect: { { string } } = {
		{ "github", ".github", "refs/plotroom-pr/github/%2Egithub/pr-1" },
		{ "o", "a..b", "refs/plotroom-pr/o/a.%2Eb/pr-1" },
		{ "o", "x.lock", "refs/plotroom-pr/o/x%2Elock/pr-1" },
		{ "o", ".lock", "refs/plotroom-pr/o/%2Elock/pr-1" },
		{ "o", "...", "refs/plotroom-pr/o/%2E.%2E/pr-1" },
		{ "o", "foo.js", "refs/plotroom-pr/o/foo.js/pr-1" },
		{ "O", "R", "refs/plotroom-pr/o/r/pr-1" },
		{ "-x", "a.", "refs/plotroom-pr/-x/a./pr-1" },
	}
	for _, row in expect do
		local ref = worktree.prRef(row[1], row[2], 1)
		eq(ref, row[3], "ref of " .. row[1] .. "/" .. row[2])
		yes(validRef(ref), "git accepts the ref of " .. row[2])
	end
end)

case("worktree: fetched ref names are injective and git-acceptable for every legal name over a small alphabet", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local alphabet = { ".", "a", "l", "o", "c", "k" }
	local seen: { [string]: string } = {}
	local count = 0
	local function visit(prefix: string, depth: number)
		if prefix ~= "" and worktree.validSegment(prefix) then
			local ref = worktree.prRef("o", prefix, 1)
			yes(validRef(ref), "ref for " .. prefix)
			local clash = seen[ref]
			if clash ~= nil then
				error("the names " .. clash .. " and " .. prefix .. " share the ref " .. ref, 0)
			end
			seen[ref] = prefix
			count += 1
			local needsEscape = string.sub(prefix, 1, 1) == "." or string.find(prefix, "..", 1, true) ~= nil or string.sub(prefix, -5) == ".lock"
			if not needsEscape and ref ~= "refs/plotroom-pr/o/" .. prefix .. "/pr-1" then
				error("the name " .. prefix .. " needs no escaping but became " .. ref, 0)
			end
		end
		if depth < 6 then
			for _, ch in alphabet do
				visit(prefix .. ch, depth + 1)
			end
		end
	end
	visit("", 0)
	yes(count > 20000, "only " .. count .. " names were generated")
end)

case("worktree: a branch checked out in the main checkout is never reused as an item's worktree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local main = { path = "/r", branch = "refs/heads/feature", bare = false, detached = false, locked = false, prunable = false }
	local verdict, why = worktree.reconcile({ main } :: any, "feature", "/wt/plotroom-o_r-pr-5")
	eq(verdict, "error", "the main checkout is not taken")
	has(why, "main checkout at /r", "and the message says where the branch is")
end)

case("worktree: validSegment accepts GitHub names and refuses path tricks", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	for _, name in { ".github", "a..b", "x.lock", "foo.js", "a-b_c", "A1" } do
		yes(worktree.validSegment(name), name .. " is a legal name")
	end
	for _, name in { "", ".", "..", "a/b", "a b", "a\n", "é", "a%2E" } do
		yes(not worktree.validSegment(name), show(name) .. " is refused")
	end
end)

case("worktree: remote URLs with a trailing slash still identify the repository", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	for _, url in { "https://github.com/o/r", "https://github.com/o/r/", "https://github.com/o/r.git/", "git@github.com:o/r/", "ssh://git@github.com/o/r.git/" } do
		eq(worktree.normalizeRemote(url), "o/r", url)
	end
	eq(worktree.normalizeRemote("https://github.com/o/"), nil, "an owner alone is not a repository")
end)

local function resultOf(created: boolean, head: string, prHead: string, dirty: boolean?): { [string]: any }
	return {
		path = "/wt/plotroom-o_r-pr-5",
		root = "/work/r",
		remote = "origin",
		branch = "feature",
		ref = "refs/plotroom-pr/o/r/pr-5",
		number = 5,
		created = created,
		head = head,
		prHead = prHead,
		prRef = "feature",
		prBase = "main",
		title = "Add a feature",
		author = "ann",
		dirty = dirty,
	}
end

case("worktree: describe says whether the worktree is current, different, modified or unchecked", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local fresh = worktree.describe(resultOf(true, sha("b"), sha("b"), false) :: any)
	has(fresh, "Created", "fresh")
	has(fresh, "Current", "fresh is current")
	has(fresh, "Clean", "fresh is clean")
	local advanced = worktree.describe(resultOf(false, sha("b"), sha("c"), true) :: any)
	has(advanced, "Reused", "advanced and modified")
	has(advanced, "Different", "advanced")
	has(advanced, "bbbbbbb", "names the local head")
	has(advanced, "ccccccc", "names the PR head")
	has(advanced, "Modified", "modified")
	has(worktree.describe(resultOf(false, sha("b"), sha("b"), nil) :: any), "unchecked", "status unknown is never Clean")
end)

case("worktree: update commands are single-line shell words, quoted for spaces, quotes and control characters", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local current = resultOf(false, sha("b"), sha("b"), false)
	same(worktree.update(current :: any), {}, "nothing to update when current")
	local behind = resultOf(false, sha("b"), sha("c"), false)
	same(worktree.update(behind :: any), { "git -C /wt/plotroom-o_r-pr-5 pull --ff-only" }, "update: one pull, for the branch tracks the PR's head branch, and only a fast-forward")
	local odd = resultOf(false, sha("b"), sha("c"), false)
	odd.path = "/tmp/a b/it's"
	eq(worktree.update(odd :: any)[1], "git -C '/tmp/a b/it'\\''s' pull --ff-only", "spaces and quotes")
	odd.path = "/tmp/a\nb"
	local entries = worktree.update(odd :: any)
	eq(entries[1], "git -C $'/tmp/a\\x0ab' pull --ff-only", "a newline")
	lacks(entries[1], "\n", "a command stays on one line")
end)

case("worktree: tilde writes the home folder as ~ and leaves every other path as it is", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	eq(worktree.tilde("/home/u/.omp/wt/plotroom-o_r-pr-5", "/home/u"), "~/.omp/wt/plotroom-o_r-pr-5", "under home")
	eq(worktree.tilde("/home/u", "/home/u"), "~", "home itself")
	eq(worktree.tilde("/home/user/wt", "/home/u"), "/home/user/wt", "a folder whose name only starts like home's")
	eq(worktree.tilde("/wt/x", "/home/u"), "/wt/x", "elsewhere")
	eq(worktree.tilde("/home/u/x", nil), "/home/u/x", "without a home")
	eq(worktree.tilde("/home/u/x", ""), "/home/u/x", "or with an empty one")
end)

-- ---- worktree.open against the git and gh models

type Scene = { git: Git, gh: Gh, repo: string, number: number, root: string, dir: string, target: string, branch: string, ref: string, launch: string }

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

-- worktree.open's naming callback for `s`: the scene's folder.
local function naming(s: Scene): (any) -> (string?, string?)
	return function(_meta: any): (string?, string?)
		return s.dir, nil
	end
end

type Opened = { calls: number, result: any, problem: string?, cx: any }

-- Opens the scene's PR from `checkout` (the scene's launch directory by default).
local function openWt(w: World, worktree: Worktree, s: Scene, checkout: string?, waitMs: number?): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.open(checkout or s.launch, s.repo, s.number, naming(s), nil, function(result, problem, cx)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.cx = cx
	end)
	w.flush()
	if waitMs then
		w.advance(waitMs)
	end
	return out
end

windowCase("worktree: a first open fetches the PR head into its own ref and reports Created, Current and Clean", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	yes(out.cx ~= nil, "the window cx reaches the callback")
	local r = out.result
	eq(r.path, "/wt/plotroom-o_r-pr-5", "path: a direct child of omp's worktrees directory")
	eq(r.root, "/work/r", "root")
	eq(r.remote, "origin", "remote")
	eq(r.branch, "feature", "branch: the pull request's own head branch")
	eq(r.ref, "refs/plotroom-pr/o/r/pr-5", "ref")
	eq(r.created, true, "created")
	eq(r.head, sha("b"), "head")
	eq(r.prHead, sha("b"), "prHead")
	eq(r.prRef, "feature", "prRef")
	eq(r.dirty, false, "dirty")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], sha("b"), "the PR head is fetched into refs/plotroom-pr/")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch starts at the PR head")
	eq(s.git.worktrees[2].path, s.target, "the worktree is registered")
	eq(w.fs.mkdirs[1], "/wt", "omp's worktrees directory was created")
	eq(countLog(s.git, "worktree add -b feature /wt/plotroom-o_r-pr-5 " .. sha("b")), 1, "added through omp worktree add")
	local created = worktree.describe(r)
	has(created, "Created", "summary: new")
	has(created, "Current", "summary: at the PR head")
	has(created, "Clean", "summary: no local changes")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5"), 1, "one fetch")
	eq(countLog(s.git, "worktree add -b feature " .. s.target .. " " .. sha("b")), 1, "one worktree add")
	lacks(table.concat(s.git.log, "\n"), "refs/plotroom/", "the old, ambiguous namespace is not used")
end)

windowCase("worktree: opening again reuses the worktree: no fetch, nothing changed, status read once", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	eq(openWt(w, worktree, s, nil, nil).result.created, true, "first open creates")
	local before, mark = snapshot(s.git), #s.git.log
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.calls, 1, "done calls")
	eq(again.result.created, false, "created")
	eq(again.result.path, s.target, "path")
	eq(again.result.head, sha("b"), "head")
	eq(again.result.dirty, false, "dirty")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(countLog(s.git, "fetch", mark), 0, "no fetch")
	eq(countLog(s.git, "worktree add", mark), 0, "no add")
	eq(countLog(s.git, "status --porcelain --untracked-files=normal", mark), 1, "status is read once")
end)

windowCase("worktree: after the PR advanced a reused worktree stays where it is and says so", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	openWt(w, worktree, s, nil, nil)
	s.gh.meta["o/r#5"].sha = sha("c")
	s.git.served["refs/pull/5/head"] = sha("c")
	local before, mark = snapshot(s.git), #s.git.log
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.result.created, false, "created")
	eq(again.result.head, sha("b"), "the worktree keeps its commit")
	eq(again.result.prHead, sha("c"), "the PR head is the new one")
	eq(snapshot(s.git), before, "no ref, branch or worktree moved")
	eq(countLog(s.git, "fetch", mark), 0, "no fetch on reuse")
	same(worktree.update(again.result), { "git -C " .. s.target .. " pull --ff-only" }, "the update command is offered, not run")
	local advanced = worktree.describe(again.result)
	has(advanced, "Different", "summary")
	has(advanced, "bbbbbbb", "names the local head")
	has(advanced, "ccccccc", "names the PR head")
end)

windowCase("worktree: a modified worktree is reported modified and kept exactly as it is", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	openWt(w, worktree, s, nil, nil)
	s.git.dirty[s.target] = " M src/a.lua\n?? notes.txt\n"
	s.gh.meta["o/r#5"].sha = sha("c")
	local before = snapshot(s.git)
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.result.dirty, true, "dirty")
	eq(snapshot(s.git), before, "the changes and every ref are untouched")
	has(worktree.describe(again.result), "Modified", "summary")
end)

windowCase("worktree: a post-checkout hook's changes in a fresh worktree are reported, never a false Clean", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.afterAdd = function(path: string)
		s.git.dirty[path] = "?? generated.txt\n"
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.result.created, true, "created")
	eq(out.result.dirty, true, "the hook's change is reported")
	local hooked = worktree.describe(out.result)
	has(hooked, "Created", "summary: new")
	has(hooked, "Current", "summary: at the PR head")
	has(hooked, "Modified", "summary: the hook's change")
	lacks(hooked, "Clean", "never a false Clean")
	local failing = scene(w, worktree, "o", "q", 7)
	failing.git.fail["status"] = { status = 128, stderr = "fatal: unable to read the index\n" }
	local unknown = openWt(w, worktree, failing, nil, nil)
	eq(unknown.result.created, true, "created")
	eq(unknown.result.dirty, nil, "a status that failed is unknown, not clean")
	has(worktree.describe(unknown.result), "unchecked", "summary")
end)

windowCase("worktree: a status that times out leaves dirty unknown instead of failing the open", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	openWt(w, worktree, s, nil, nil)
	s.git.fail["status"] = { delay = 60000 }
	local again = openWt(w, worktree, s, nil, 10000)
	eq(again.calls, 1, "done calls")
	eq(again.result.created, false, "created")
	eq(again.result.dirty, nil, "dirty")
end)

windowCase("worktree: a branch already at the PR head is attached, not recreated", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/feature"] = sha("b")
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.created, true, "created")
	eq(countLog(s.git, "worktree add " .. s.target .. " feature"), 1, "attached with the two-argument form")
	eq(countLog(s.git, "worktree add -b"), 0, "no new branch")
end)

windowCase("worktree: another window winning the add is accepted as a reuse, never an error", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.onAdd = function()
		s.git.onAdd = nil
		table.insert(s.git.worktrees, { path = s.target, branch = "refs/heads/" .. s.branch, head = sha("b"), locked = false })
		s.git.refs["refs/heads/" .. s.branch] = sha("b")
		w.fs.dirs[s.target] = true
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.result.created, false, "created: the other window made it")
	eq(out.result.path, s.target, "path")
	eq(out.result.dirty, false, "dirty")
end)

windowCase("worktree: a fetch that lost the ref lock continues only when the ref holds the PR head", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.lockFetch = { winner = sha("b") }
	local won = openWt(w, worktree, s, nil, nil)
	eq(won.problem, nil, "the other window fetched the same commit")
	eq(won.result.created, true, "created")
	local lost = scene(w, worktree, "o", "q", 6)
	lost.git.lockFetch = { winner = sha("e") }
	local other = openWt(w, worktree, lost, nil, nil)
	eq(other.result, nil, "a different commit in the ref fails")
	has(other.problem, "cannot lock ref", "git's message")
	local empty = scene(w, worktree, "o", "p", 8)
	empty.git.lockFetch = {}
	local none = openWt(w, worktree, empty, nil, nil)
	eq(none.result, nil, "an absent ref fails")
	has(none.problem, "cannot lock ref", "git's message")
end)

windowCase("worktree: a PR that moves during the fetch is accepted only on an exact second read", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.served["refs/pull/5/head"] = sha("c")
	local moved = openWt(w, worktree, s, nil, nil)
	eq(moved.result, nil, "gh still reports the old head")
	has(moved.problem, "changed", "the pull request moved")
	eq(#s.git.worktrees, 1, "nothing was created")
	local t = scene(w, worktree, "o", "q", 6)
	t.git.served["refs/pull/6/head"] = sha("c")
	t.git.onFetch = function()
		t.gh.meta["o/q#6"].sha = sha("c")
	end
	local settled = openWt(w, worktree, t, nil, nil)
	eq(settled.problem, nil, "the second read agrees with the fetched commit")
	eq(settled.result.head, sha("c"), "the worktree is at the commit that was fetched")
	eq(settled.result.prHead, sha("c"), "prHead")
end)

windowCase("worktree: a mkdir that raises ends the open once with its reason and creates nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	w.fs.denyMkdir["/wt"] = "permission denied"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	has(out.problem, "/wt", "names the directory")
	has(out.problem, "permission denied", "and the reason")
	eq(countLog(s.git, "worktree add"), 0, "git was never asked to add it")
	w.fs.denyMkdir["/wt"] = nil
	eq(openWt(w, worktree, s, nil, nil).result.created, true, "after the cause is fixed the next open works")
end)

windowCase("worktree: a filesystem call that raises mid-flow fails the request once", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	w.sdk.fs.exists = function(_path: string): boolean
		error("input/output error", 0)
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	has(out.problem, "input/output error", "the reason")
end)

windowCase("worktree: a runtime that reports one process twice still ends the open once", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "pr" then
			return { stdout = jsonEncode(meta), repeatCallback = true }
		end
		return nil
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	yes(out.result ~= nil or out.problem ~= nil, "an outcome")
end)

windowCase("worktree: a checkout of another repository is NO_REPO; the checkout given is the one used", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.remotes.origin = { "https://github.com/x/y.git" }
	local none = openWt(w, worktree, s, nil, nil)
	eq(none.calls, 1, "done calls")
	eq(none.problem, worktree.NO_REPO, "problem")
	eq(none.result, nil, "result")
	local other = newGit(w, "/work/other")
	other.remotes.origin = { "https://github.com/o/r.git" }
	other.served["refs/pull/5/head"] = sha("b")
	local given = openWt(w, worktree, s, "/work/other", nil)
	eq(given.problem, nil, "the given checkout resolves")
	eq(given.result.root, "/work/other", "root")
	eq(given.result.path, "/wt/plotroom-o_r-pr-5", "path")
end)

windowCase("worktree: omp's worktrees directory is OMP_WORKTREE_DIR, then worktree.base, then ~/.omp/wt; relative values are ignored", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.env.HOME = "/home/u"
	local base: string? = nil
	w.respond(function(call: Call): Reply?
		local a = call.argv
		return if a[1] == "omp" and a[2] == "config" then { stdout = jsonEncode({ key = "worktree.base", value = base }) .. "\n" } else nil
	end)
	local function dir(): string?
		local got: string? = nil
		worktree.worktreesDir(function(d: string?)
			got = d
		end)
		w.flush()
		return got
	end
	eq(dir(), "/home/u/.omp/wt", "unset: omp's default")
	base = "~/wts"
	eq(dir(), "/home/u/wts", "the setting, ~ expanded")
	base = "rel/wts"
	eq(dir(), "/home/u/.omp/wt", "a relative setting is ignored")
	base = "/cfg"
	w.env.OMP_WORKTREE_DIR = "/env/wt"
	eq(dir(), "/env/wt", "the environment variable wins")
	w.env.OMP_WORKTREE_DIR = "relative"
	eq(dir(), "/cfg", "a relative environment variable is ignored")
end)

windowCase("worktree: the worktrees directory is a clean path, so git's own listing of it matches", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.env.HOME = "/home/u"
	w.respond(function(call: Call): Reply?
		local a = call.argv
		return if a[1] == "omp" and a[2] == "config" then { stdout = jsonEncode({ key = "worktree.base", value = "/cfg/wts//" }) .. "\n" } else nil
	end)
	local function dir(): string?
		local got: string? = nil
		worktree.worktreesDir(function(d: string?)
			got = d
		end)
		w.flush()
		return got
	end
	eq(dir(), "/cfg/wts", "the setting's trailing slashes are dropped")
	w.env.OMP_WORKTREE_DIR = "/env//wt/"
	eq(dir(), "/env/wt", "so are the environment variable's, and doubled slashes inside")
	w.env.OMP_WORKTREE_DIR = "/"
	eq(dir(), "/", "the root stays the root")
	w.env.OMP_WORKTREE_DIR = "~/wt/"
	eq(dir(), "/home/u/wt", "after ~ expansion too")
end)

-- The commands spawned after entry `from` of the world's calls that can change a repository or add a worktree, in order,
-- every argument joined by spaces: everything but git's read-only commands (`omp worktree add` included).
local function worktreeWrites(w: World, from: number?): { string }
	local reads: { [string]: boolean } = { ["rev-parse"] = true, remote = true, status = true, ["ls-remote"] = true, ["check-ref-format"] = true, ["merge-base"] = true }
	local out: { string } = {}
	for i = (from or 0) + 1, #w.calls do
		local a = w.calls[i].argv
		local readOnly = reads[a[4] or ""] or (a[4] == "worktree" and a[5] == "list")
		local note = a[4] == "config" and a[5] == "--local" and string.match(a[6] or "", "^branch%..+%.plotroom%a+$") ~= nil
		if not note and ((a[1] == "omp" and a[2] == "worktree") or (a[1] == "git" and a[2] == "-C" and not readOnly)) then
			table.insert(out, table.concat(a, " "))
		end
	end
	return out
end

windowCase("worktree.open: a same-repo PR gets a worktree on its own head branch, tracking it, with the head fetched into its own ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.path, s.target, "path")
	eq(r.branch, "feature", "branch: the PR's head branch, not a plotroom/... name")
	eq(r.ref, s.ref, "ref: where the PR head was fetched")
	eq(r.prRef, "feature", "prRef")
	eq(r.number, 5, "number")
	eq(r.created, true, "created")
	eq(r.head, sha("b"), "head")
	eq(r.prHead, sha("b"), "prHead")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature",
		"omp worktree add -q -C /work/r -b feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.feature.remote origin",
		"git -C /work/r config branch.feature.merge refs/heads/feature",
	}, "the PR head, its branch's remote-tracking ref, the worktree on a new branch at the PR head, then the upstream")
	eq(s.git.config["branch.feature.remote"], "origin", "the upstream's remote")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "and branch, so pull, push and gh pr view work there")
end)

windowCase("worktree.open: the new head branch starts at the PR's commit, wherever the remote's branch is now", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.served["refs/heads/feature"] = sha("c") -- pushed to since GitHub reported the PR head
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.head, sha("b"), "the worktree is at the PR's head")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch starts there")
	eq(s.git.refs["refs/remotes/origin/feature"], sha("c"), "the remote-tracking ref says where the remote's branch is")
	eq(countLog(s.git, "worktree add -b feature " .. s.target .. " " .. sha("b")), 1, "created at the PR's commit")
end)

windowCase("worktree.open: the tracking fetch and the upstream write are best effort: a gone head branch or a failing git does not fail the open", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.served["refs/heads/feature"] = nil -- merged, and its branch deleted
	local gone = openWt(w, worktree, s, nil, nil)
	eq(gone.calls, 1, "done calls")
	eq(gone.problem, nil, "problem")
	eq(gone.result.created, true, "created")
	eq(gone.result.branch, "feature", "branch")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature"), 1, "the head branch was asked for once")
	eq(s.git.refs["refs/remotes/origin/feature"], nil, "and not found")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch still starts at the PR head")
	eq(s.git.config["branch.feature.remote"], "origin", "and still tracks the remote")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "and the branch")
	-- the second fetch (and no other) fails for a reason of its own
	local t = scene(w, worktree, "o", "q", 6)
	t.git.onFetch = function()
		t.git.onFetch = nil
		t.git.fail["fetch"] = { status = 128, stderr = "fatal: unable to access 'https://github.com/o/q.git/': Could not resolve host: github.com\n" }
	end
	local offline = openWt(w, worktree, t, nil, nil)
	eq(offline.problem, nil, "problem when only the tracking fetch fails")
	eq(offline.result.created, true, "created")
	eq(countLog(t.git, "fetch"), 2, "both fetches were tried")
	eq(t.git.refs["refs/heads/feature"], sha("b"), "the branch exists")
	eq(t.git.config["branch.feature.remote"], "origin", "with its upstream")
	-- a config write that fails leaves the worktree made, without its upstream
	local u = scene(w, worktree, "o", "p", 7)
	u.git.fail["config"] = { status = 255, stderr = "error: could not lock config file .git/config: File exists\n" }
	local untracked = openWt(w, worktree, u, nil, nil)
	eq(untracked.problem, nil, "problem when the upstream cannot be written")
	eq(untracked.result.created, true, "created")
	eq(untracked.result.branch, "feature", "branch")
	eq(untracked.result.head, sha("b"), "head")
	eq(countLog(u.git, "config"), 2, "both settings were tried")
	same(u.git.config, {}, "and none was written")
end)

windowCase("worktree.open: the repository's own remote, whatever its name, is fetched from and tracked", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.remotes = { origin = { "https://github.com/me/r.git" }, upstream = { "https://github.com/o/r.git" } }
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.remote, "upstream", "remote")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head upstream +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head upstream +refs/heads/feature:refs/remotes/upstream/feature",
		"omp worktree add -q -C /work/r -b feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.feature.remote upstream",
		"git -C /work/r config branch.feature.merge refs/heads/feature",
	}, "every command names upstream, the remote that points at o/r")
end)

windowCase("worktree.open: a fork PR is on <fork owner>/<branch>, never fetched from origin, tracking the fork's branch by its URL", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	meta.headRepo, meta.headOwner = "fork/r", "fork"
	s.git.served["refs/heads/feature"] = sha("c") -- origin has an unrelated branch of that name
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.branch, "fork/feature", "branch: the fork's owner and the head branch")
	eq(r.prRef, "feature", "prRef: the head branch as GitHub names it")
	eq(r.ref, s.ref, "ref")
	eq(r.head, sha("b"), "head")
	eq(r.title, "Add a feature", "title")
	eq(r.author, "ann", "author")
	eq(r.prBase, "main", "prBase")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"omp worktree add -q -C /work/r -b fork/feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.fork/feature.remote https://github.com/fork/r.git",
		"git -C /work/r config branch.fork/feature.merge refs/heads/feature",
	}, "one fetch, from origin: the fork's branch is not fetched, and the upstream is the fork's URL")
	same(s.git.config, {
		["branch.fork/feature.remote"] = "https://github.com/fork/r.git",
		["branch.fork/feature.merge"] = "refs/heads/feature",
	}, "the upstream is the fork's branch and nothing else is configured")
	-- a fork's main is its own branch, so the repository's main never meets it
	local t = scene(w, worktree, "o", "q", 6)
	local tm = t.gh.meta["o/q#6"]
	tm.headRepo, tm.headOwner, tm.ref = "other/q", "other", "main"
	local forked = openWt(w, worktree, t, nil, nil)
	eq(forked.problem, nil, "problem for a fork's main")
	eq(forked.result.branch, "other/main", "branch")
	eq(t.git.refs["refs/heads/other/main"], sha("b"), "the fork's main starts at the PR head")
	eq(t.git.refs["refs/heads/main"], sha("1"), "the repository's own main did not move")
	eq(t.git.worktrees[1].branch, "refs/heads/main", "and its checkout is still on it")
	eq(t.git.config["branch.other/main.merge"], "refs/heads/main", "the fork's branch is tracked as main")
	eq(t.git.config["branch.main.merge"], nil, "the repository's main was not configured")
end)

windowCase("worktree.open: a PR whose fork was deleted is on <head owner or author>/<branch> and tracks the PR's own ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	meta.headRepo, meta.headOwner = nil, "gone"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.branch, "gone/feature", "branch: the head's user, who is still named")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"omp worktree add -q -C /work/r -b gone/feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.gone/feature.remote origin",
		"git -C /work/r config branch.gone/feature.merge refs/pull/5/head",
	}, "only the PR's ref is fetched; the branch tracks it on origin, the head branch having gone with the fork")
	-- no head user either: the author's name
	local t = scene(w, worktree, "o", "q", 6)
	local tm = t.gh.meta["o/q#6"]
	tm.headRepo, tm.headOwner = nil, nil
	local nameless = openWt(w, worktree, t, nil, nil)
	eq(nameless.problem, nil, "problem without a head user")
	eq(nameless.result.branch, "ann/feature", "branch: the author's name")
	eq(t.git.config["branch.ann/feature.merge"], "refs/pull/6/head", "tracking the PR's ref")
	eq(countLog(t.git, "fetch"), 1, "one fetch")
end)

windowCase("worktree.open: a head repository that is the base repository in other letter case is not a fork", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.gh.meta["o/r#5"].headRepo = "O/R"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.branch, "feature", "branch: no fork prefix")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature"), 1, "its head branch is fetched from the repository's remote")
	eq(s.git.config["branch.feature.remote"], "origin", "and tracked there")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "as its own branch")
end)

windowCase("worktree.open: an existing local branch is attached at its own commit, never moved, and its upstream settings stay the user's", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/feature"] = sha("d")
	s.git.config["branch.feature.remote"] = "mine"
	s.git.config["branch.feature.merge"] = "refs/heads/elsewhere"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.created, true, "created")
	eq(r.branch, "feature", "branch")
	eq(r.head, sha("d"), "head: the branch's own commit")
	eq(r.prHead, sha("b"), "prHead: the PR's")
	has(worktree.describe(r), "Different", "the summary says the worktree is not at the PR head")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature",
		"omp worktree add -q -C /work/r /wt/plotroom-o_r-pr-5 feature",
	}, "attached with the two-argument form: no new branch and no upstream written")
	same({ tip = s.git.refs["refs/heads/feature"], config = s.git.config }, {
		tip = sha("d"),
		config = { ["branch.feature.remote"] = "mine", ["branch.feature.merge"] = "refs/heads/elsewhere" },
	}, "the branch did not move and its upstream settings are untouched")
end)

windowCase("worktree.open: a local branch already at the PR head is attached, not recreated, a fork's branch included", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/feature"] = sha("b")
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.created, true, "created")
	eq(out.result.head, sha("b"), "head")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature",
		"omp worktree add -q -C /work/r /wt/plotroom-o_r-pr-5 feature",
	}, "attached by name, no -b")
	same(s.git.config, {}, "no upstream is written for a branch that was already there")
	local t = scene(w, worktree, "o", "q", 6)
	local tm = t.gh.meta["o/q#6"]
	tm.headRepo, tm.headOwner = "fork/q", "fork"
	t.git.refs["refs/heads/fork/feature"] = sha("b")
	local mark = #w.calls
	local forked = openWt(w, worktree, t, nil, nil)
	eq(forked.problem, nil, "problem for a fork's branch")
	eq(forked.result.branch, "fork/feature", "branch")
	same(worktreeWrites(w, mark), {
		"git -C /work/q fetch --no-tags --no-write-fetch-head origin +refs/pull/6/head:refs/plotroom-pr/o/q/pr-6",
		"omp worktree add -q -C /work/q /wt/plotroom-o_q-pr-6 fork/feature",
	}, "attached by name, nothing configured")
	same(t.git.config, {}, "no upstream for the fork's branch either")
end)

windowCase("worktree.open: the worktree that already holds the PR's branch is reused wherever it is, with nothing fetched, added or configured", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	table.insert(s.git.worktrees, { path = "/wt/elsewhere", branch = "refs/heads/feature", head = sha("d"), locked = false })
	s.git.refs["refs/heads/feature"] = sha("d")
	s.git.dirty["/wt/elsewhere"] = " M src/a.lua\n"
	w.fs.dirs["/wt/elsewhere"] = true
	local before = snapshot(s.git)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.created, false, "created")
	eq(r.path, "/wt/elsewhere", "path: the worktree that has the branch, not the folder the naming gave")
	eq(r.branch, "feature", "branch")
	eq(r.head, sha("d"), "head: its own commit")
	eq(r.prHead, sha("b"), "prHead")
	eq(r.dirty, true, "dirty: its changes are reported")
	same(worktreeWrites(w), {}, "nothing was fetched, added or configured")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
end)

windowCase("worktree.open: a plain folder at the PR's folder, or a locked or missing worktree there or of its branch, ends the open, touching nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local function refused(what: string): string?
		local before = snapshot(s.git)
		local out = openWt(w, worktree, s, nil, nil)
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		eq(snapshot(s.git), before, what .. ": git state is untouched")
		same(worktreeWrites(w), {}, what .. ": nothing fetched or added")
		eq(#w.fs.mkdirs, 0, what .. ": no directory made")
		return out.problem
	end
	w.fs.dirs[s.target] = true
	eq(refused("a plain folder"), s.target .. " already exists and is not the worktree of feature; move it away or remove it.", "a folder that is no worktree")
	table.insert(s.git.worktrees, { path = s.target, branch = "refs/heads/other", head = sha("d"), locked = true })
	eq(refused("a locked worktree of another branch at the folder"), "The worktree record at " .. s.target .. " belongs to something other than feature.", "one that cannot be used is neither reused nor replaced")
	w.fs.dirs[s.target] = nil
	eq(refused("a worktree of another branch at the folder whose folder is gone"), "The worktree record at " .. s.target .. " belongs to something other than feature.", "nor is one with no folder")
	table.remove(s.git.worktrees, 2)
	table.insert(s.git.worktrees, { path = "/wt/locked", branch = "refs/heads/feature", head = sha("d"), locked = true })
	w.fs.dirs["/wt/locked"] = true
	local locked = refused("a locked worktree")
	has(locked, "The worktree of feature at /wt/locked is locked, prunable or missing", "the branch's worktree is locked")
	table.remove(s.git.worktrees, 2)
	table.insert(s.git.worktrees, { path = "/wt/gone", branch = "refs/heads/feature", head = sha("d"), locked = false })
	has(refused("a worktree whose folder is gone"), "The worktree of feature at /wt/gone is locked, prunable or missing", "the branch's worktree has no folder")
end)

windowCase("worktree.open: a worktree already in the PR's folder is its worktree whatever its branch (an earlier version's), reused with nothing fetched, added or configured", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	table.insert(s.git.worktrees, { path = s.target, branch = "refs/heads/plotroom/o/r/pr-5", head = sha("d"), locked = false })
	s.git.refs["refs/heads/plotroom/o/r/pr-5"] = sha("d")
	s.git.dirty[s.target] = " M src/a.lua\n"
	w.fs.dirs[s.target] = true
	local before = snapshot(s.git)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.created, false, "created")
	eq(r.path, s.target, "path: the folder the naming gave")
	eq(r.branch, "plotroom/o/r/pr-5", "branch: the one the worktree is on, not the PR's head branch")
	eq(r.ref, s.ref, "ref: the PR's own, as always")
	eq(r.head, sha("d"), "head: its own commit")
	eq(r.prHead, sha("b"), "prHead")
	eq(r.dirty, true, "dirty: its changes are reported")
	same(worktreeWrites(w), {}, "nothing was fetched, added or configured")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.result.branch, "plotroom/o/r/pr-5", "opened again, it is the same worktree")
	eq(again.result.created, false, "created")
end)

windowCase("worktree.open: the folder comes from the naming callback, which is given the PR; a later name still finds the PR's worktree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	meta.headRepo, meta.headOwner = "fork/r", "fork"
	local seen: { any } = {}
	local dir = "my-pr-5"
	local function open(): Opened
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.open(s.launch, s.repo, s.number, function(m: any): (string?, string?)
			table.insert(seen, m)
			return dir, nil
		end, nil, function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		w.flush()
		return out
	end
	local out = open()
	eq(out.problem, nil, "problem")
	eq(out.result.path, "/wt/my-pr-5", "path: the name the callback gave")
	eq(out.result.branch, "fork/feature", "branch: it does not depend on the folder")
	eq(#seen, 1, "the callback ran once")
	local given: any = seen[1]
	eq(given.title, "Add a feature", "the callback was given the PR's title")
	eq(given.ref, "feature", "head branch")
	eq(given.fork, "fork", "fork owner")
	eq(given.forkRepo, "fork/r", "fork repository")
	eq(given.author, "ann", "author")
	eq(given.baseRef, "main", "base branch")
	eq(given.sha, sha("b"), "head commit")
	dir = "renamed-5" -- the user edits the format
	local mark = #w.calls
	local again = open()
	eq(again.problem, nil, "problem on the second open")
	eq(again.result.created, false, "created")
	eq(again.result.path, "/wt/my-pr-5", "the worktree that has the branch is still the PR's")
	same(worktreeWrites(w, mark), {}, "no second worktree, nothing fetched")
	eq(#seen, 2, "the callback is asked every time")
end)

windowCase("worktree.open: a naming callback that gives no name ends the open with its reason, creating nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.open(s.launch, s.repo, s.number, function(_m: any): (string?, string?)
		return nil, "The folder format names {github.user}, which could not be read."
	end, nil, function(result, problem, cx)
		out.calls += 1
		out.result, out.problem, out.cx = result, problem, cx
	end)
	w.flush()
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, "The folder format names {github.user}, which could not be read.", "problem: the callback's reason, as it gave it")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	same(worktreeWrites(w), {}, "nothing fetched or added")
end)

windowCase("worktree.open: a folder name that is not one plain path segment is refused, creating nothing; a name with a space works", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	local bad: { { string } } = {
		{ "a slash", "pr/5" },
		{ "a path out of the folder", "../pr-5" },
		{ "an absolute path", "/tmp/pr-5" },
		{ "an empty name", "" },
		{ "a dot", "." },
		{ "two dots", ".." },
		{ "a newline", "pr\n5" },
		{ "an escape sequence", "pr-5\27[31m" },
		{ "201 bytes", string.rep("a", 201) },
	}
	for _, row in bad do
		s.dir = row[2]
		local out = openWt(w, worktree, s, nil, nil)
		eq(out.calls, 1, row[1] .. ": done calls")
		eq(out.result, nil, row[1] .. ": no result")
		has(out.problem, "Worktree folder name " .. row[2] .. " is not usable", row[1] .. ": names the folder name")
		has(out.problem, "Settings", row[1] .. ": says where to change it")
	end
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	s.dir = "my pr 5"
	local ok = openWt(w, worktree, s, nil, nil)
	eq(ok.problem, nil, "problem for a name with spaces")
	eq(ok.result.path, "/wt/my pr 5", "path")
	local added: any = nil
	for _, call in w.calls do
		if call.argv[1] == "omp" and call.argv[3] == "add" then
			added = call.argv
		end
	end
	same(added, { "omp", "worktree", "add", "-q", "-C", "/work/r", "-b", "feature", "/wt/my pr 5", sha("b") }, "the folder is one argument, never a shell word")
end)

windowCase("worktree.open: a PR whose base is another repository is refused, creating nothing; one in other letter case is accepted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	s.gh.meta["o/r#5"].base = "x/y"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, "The pull request's base is x/y, not o/r.", "problem")
	eq(snapshot(s.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	s.gh.meta["o/r#5"].base = "O/R"
	local cased = openWt(w, worktree, s, nil, nil)
	eq(cased.problem, nil, "problem when the base differs only in letter case")
	eq(cased.result.created, true, "created")
end)

windowCase("worktree.open: a PR that cannot be read ends the open with gh's problem, creating nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	local function refused(what: string, reply: Reply, want: string)
		s.gh.override = function(req: GhReq): Reply?
			return if req.kind == "pr" then reply else nil
		end
		local out = openWt(w, worktree, s, nil, nil)
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		has(out.problem, want, what .. ": gh's problem")
	end
	refused("a PR GitHub does not show", { status = 1, stderr = "gh: Not Found (HTTP 404)\n" }, "gh: Not Found (HTTP 404)")
	refused("a sign-in gh rejects", { status = 1, stderr = "gh: Bad credentials (HTTP 401)\n" }, "gh: Bad credentials (HTTP 401)")
	refused("an answer that is no PR", { stdout = "not json" }, "unexpected pull request metadata")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	same(worktreeWrites(w), {}, "nothing fetched or added")
end)

-- ---- worktree.remove against the git model

type Removed = { removal: any, problem: string?, dirty: boolean?, calls: number }

-- Removes the worktree `t` names (a worktree.Target) and returns the one answer remove gave.
local function removeWt(w: World, worktree: Worktree, t: { [string]: any }): Removed
	local out: Removed = { removal = nil, problem = nil, dirty = nil, calls = 0 }
	worktree.remove(t :: any, function(removal, problem, dirty)
		out.calls += 1
		out.removal = removal
		out.problem = problem
		out.dirty = dirty
	end)
	w.flush()
	return out
end

-- The commands spawned after entry `from` of the world's calls, every argument joined by spaces.
local function ranSince(w: World, from: number): { string }
	local out: { string } = {}
	for i = from + 1, #w.calls do
		table.insert(out, table.concat(w.calls[i].argv, " "))
	end
	return out
end

-- PR 5 of o/r with its worktree made, and what remove takes of it.
local function madeWt(w: World, worktree: Worktree): (Scene, { [string]: any })
	local s = scene(w, worktree, "o", "r", 5)
	local r = openWt(w, worktree, s).result
	return s, { root = r.root, path = r.path, branch = r.branch, ref = r.ref }
end

case("worktree: remove takes a clean pull request worktree, its branch once the fetched ref holds all of it, and that ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.calls, 1, "answered once")
	eq(out.problem, nil, "no problem")
	eq(out.removal.branch, "Branch feature was deleted too.", "the branch went with it")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-pr-5",
		"git -C /work/r merge-base --is-ancestor refs/heads/feature refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r branch -D feature",
		"git -C /work/r update-ref -d refs/plotroom-pr/o/r/pr-5",
	}, "the worktree without --force, then -D only after the ancestry check, then the ref")
	eq(#s.git.worktrees, 1, "only the main worktree is left")
	eq(s.git.refs["refs/heads/feature"], nil, "the branch is gone")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], nil, "and the ref it was fetched into")
	eq(w.fs.dirs["/wt/plotroom-o_r-pr-5"], nil, "and the folder")
end)

case("worktree: remove keeps a pull request branch that holds commits of its own, with its ref, and says why", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.ahead["feature"] = true
	s.git.unmerged["feature"] = true
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.problem, nil, "the worktree itself was removed")
	eq(out.removal.branch, "Branch feature was kept. The branch 'feature' is not fully merged.", "the branch stays, with git's reason")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-pr-5",
		"git -C /work/r merge-base --is-ancestor refs/heads/feature refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r branch -d feature",
	}, "-d, never -D, and the ref is not dropped")
	eq(#s.git.worktrees, 1, "the worktree is gone")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch keeps its commits")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], sha("b"), "beside the ref")
end)

case("worktree: remove deletes a pull request branch that is ahead of its ref when git finds it merged, and the ref with it", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.ahead["feature"] = true -- merged into the checkout's HEAD: `unmerged` stays unset
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.removal.branch, "Branch feature was deleted too.", "the branch goes")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-pr-5",
		"git -C /work/r merge-base --is-ancestor refs/heads/feature refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r branch -d feature",
		"git -C /work/r update-ref -d refs/plotroom-pr/o/r/pr-5",
	}, "through -d, which git allows, and then the ref")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], nil, "the ref is gone")
end)

case("worktree: remove keeps unpushed commits of a pull request branch even when a tag has the branch's name", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.refs["refs/tags/feature"] = s.git.refs["refs/plotroom-pr/o/r/pr-5"] -- the tag sits at the fetched head
	s.git.ahead["feature"] = true -- the branch has moved on
	s.git.unmerged["feature"] = true
	local out = removeWt(w, worktree, t)
	eq(out.problem, nil, "the worktree itself was removed")
	eq(out.removal.branch, "Branch feature was kept. The branch 'feature' is not fully merged.", "the branch stays")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "its commits are not lost")
end)

case("worktree: remove reads uncommitted changes from git whatever language git speaks", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.dirty["/wt/plotroom-o_r-pr-5"] = " M src/a.lua\n"
	local out = removeWt(w, worktree, t)
	eq(out.dirty, true, "dirty")
	has(out.problem, "uncommitted changes", "said plainly")
	eq(#s.git.worktrees, 2, "nothing was removed")
end)

case("worktree: remove stops at uncommitted changes, which git refuses to discard, and does nothing else", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.dirty["/wt/plotroom-o_r-pr-5"] = " M src/a.lua\n"
	local before = snapshot(s.git)
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.calls, 1, "answered once")
	eq(out.removal, nil, "nothing was removed")
	eq(out.problem, "It has uncommitted changes; commit, stash or remove it yourself.", "the user is told what to do")
	eq(out.dirty, true, "and that the changes were why")
	same(ranSince(w, mark), { "git -C /work/r worktree remove /wt/plotroom-o_r-pr-5" }, "git was asked once, without --force")
	eq(snapshot(s.git), before, "no worktree, branch or ref changed")
end)

case("worktree: remove relays any other refusal of git, and says when a ref could not be dropped", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.fail["worktree remove"] = { status = 128, stderr = "fatal: cannot remove a locked working tree, lock reason: moving\nuse 'remove -f -f' to override or unlock first\n" }
	local before = snapshot(s.git)
	local locked = removeWt(w, worktree, t)
	eq(locked.removal, nil, "nothing was removed")
	eq(locked.problem, "Cannot remove a locked working tree, lock reason: moving.", "git's first line, as a sentence")
	eq(locked.dirty, false, "which is not about changes")
	eq(snapshot(s.git), before, "nothing changed")
	s.git.fail["worktree remove"] = nil
	s.git.fail["update-ref"] = { status = 1, stderr = "error: cannot lock ref 'refs/plotroom-pr/o/r/pr-5'\n" }
	local out = removeWt(w, worktree, t)
	eq(out.removal.branch, "Branch feature was deleted too. Its fetched ref refs/plotroom-pr/o/r/pr-5 was kept. Cannot lock ref 'refs/plotroom-pr/o/r/pr-5'.", "a ref that stays is reported")
end)

-- ---- worktree.openIssue against the git model

type IssueRepo = { git: Git, target: string, launch: string }

-- A checkout of o/r at /work/r (launched from its src directory) whose origin is github.com/o/r and whose remote serves
-- its default branch main at sha("b"); `target` is where issue `ref`'s worktree goes (folder plotroom-o_r-issue-<ref>).
local function issueRepo(w: World, ref: string): IssueRepo
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	g.served["refs/heads/main"] = sha("b")
	g.defaultBranch = "main"
	w.fs.dirs["/work/r/src"] = true
	return { git = g, target = "/wt/plotroom-o_r-issue-" .. ref, launch = "/work/r/src" }
end

-- What an issue worktree is asked for (worktree.IssuePlan); the folder defaults to plotroom-o_r-issue-<key>.
type PlanAsk = { dir: string?, branch: string, pr: number?, fresh: boolean, base: string? }

-- Opens issue `key` of o/r as `plan` says, from `checkout` (the repository's src directory by default).
local function openIssuePlan(w: World, worktree: Worktree, r: IssueRepo, key: string, plan: PlanAsk, checkout: string?): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	local asked = { dir = plan.dir or "plotroom-o_r-issue-" .. key, branch = plan.branch, pr = plan.pr, fresh = plan.fresh, base = plan.base }
	worktree.openIssue(checkout or r.launch, "o/r", key, asked, nil, function(result, problem, cx)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.cx = cx
	end)
	w.flush()
	return out
end

-- Opens issue `key` of o/r on the new branch `branch`, made from the remote's main.
local function openIssueWt(w: World, worktree: Worktree, r: IssueRepo, key: string, branch: string, checkout: string?): Opened
	return openIssuePlan(w, worktree, r, key, { branch = branch, fresh = true, base = "main" }, checkout)
end

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

windowCase("worktree.openIssue: creates the issue's branch at the chosen base and reports Created and Clean", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	yes(out.cx ~= nil, "the window cx reaches the callback")
	local res = out.result
	eq(res.path, r.target, "path: a direct child of omp's worktrees directory")
	eq(res.root, "/work/r", "root")
	eq(res.remote, "origin", "remote")
	eq(res.branch, "12-fix-login", "branch")
	eq(res.key, "12", "key")
	eq(res.created, true, "created")
	eq(res.head, sha("b"), "head: the remote's default branch")
	eq(res.dirty, false, "dirty")
	eq(w.fs.mkdirs[1], "/wt", "omp's worktrees directory was created")
	eq(countLog(r.git, "check-ref-format --branch 12-fix-login"), 1, "git checks the branch name first")
	eq(countLog(r.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base is fetched into its remote-tracking ref")
	eq(r.git.refs["refs/remotes/origin/main"], sha("b"), "which holds the remote's commit")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("b"), "the new branch starts there")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b 12-fix-login " .. r.target .. " " .. sha("b")), 1, "added through omp worktree add")
	eq(r.git.worktrees[2].path, r.target, "the worktree is registered")
	eq(countLog(r.git, "config"), 0, "no upstream is configured: the user's first push -u sets it")
end)

windowCase("worktree.openIssue: a worktree at the issue's directory is reused whatever its branch, so is one that holds the branch elsewhere; a locked or missing one is an error", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	-- the issue's directory holds another branch
	table.insert(r.git.worktrees, { path = r.target, branch = "refs/heads/work-in-progress", head = sha("d"), locked = false })
	w.fs.dirs[r.target] = true
	local before = snapshot(r.git)
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.result.created, false, "created")
	eq(out.result.path, r.target, "path")
	eq(out.result.branch, "work-in-progress", "the branch is the worktree's own, not the one asked for")
	eq(out.result.head, sha("d"), "head")
	eq(out.result.dirty, false, "dirty")
	eq(snapshot(r.git), before, "git state is untouched")
	eq(countLog(r.git, "fetch"), 0, "no fetch")
	eq(countLog(r.git, "worktree add"), 0, "no add")
	-- the directory holds a detached HEAD
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-13", head = sha("e"), locked = false })
	w.fs.dirs["/wt/plotroom-o_r-issue-13"] = true
	local detached = openIssueWt(w, worktree, r, "13", "13-docs", nil)
	eq(detached.result.created, false, "a detached worktree is reused too")
	eq(detached.result.branch, "13-docs", "and reported on the branch asked for")
	eq(detached.result.head, sha("e"), "at its own commit")
	-- another worktree holds the branch
	table.insert(r.git.worktrees, { path = "/wt/elsewhere", branch = "refs/heads/14-typo", head = sha("f"), locked = false })
	w.fs.dirs["/wt/elsewhere"] = true
	local elsewhere = openIssueWt(w, worktree, r, "14", "14-typo", nil)
	eq(elsewhere.result.created, false, "the worktree that has the branch is reused")
	eq(elsewhere.result.path, "/wt/elsewhere", "wherever it is")
	eq(elsewhere.result.branch, "14-typo", "branch")
	eq(countLog(r.git, "worktree add"), 0, "still no add")
	-- a locked worktree, and one whose directory is gone
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-15", branch = "refs/heads/15-x", head = sha("a"), locked = true })
	w.fs.dirs["/wt/plotroom-o_r-issue-15"] = true
	local locked = openIssueWt(w, worktree, r, "15", "15-x", nil)
	eq(locked.result, nil, "a locked worktree is left alone")
	has(locked.problem, "locked, prunable or missing", "and the problem says what to look at")
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-16", branch = "refs/heads/16-y", head = sha("c"), locked = false })
	local gone = openIssueWt(w, worktree, r, "16", "16-y", nil)
	eq(gone.result, nil, "so is one whose directory is gone")
	has(gone.problem, "locked, prunable or missing", "with the same problem")
	eq(countLog(r.git, "worktree add"), 0, "nothing was added")
end)

windowCase("worktree.openIssue: attaches an existing local branch without moving it", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.refs["refs/heads/12-fix-login"] = sha("d")
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.problem, nil, "problem")
	eq(out.result.created, true, "created")
	eq(out.result.head, sha("d"), "the worktree is at the branch's own commit")
	eq(out.result.branch, "12-fix-login", "branch")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("d"), "the branch did not move")
	eq(countCalls(w, "omp worktree add -q -C /work/r " .. r.target .. " 12-fix-login"), 1, "attached with the two-argument form")
	eq(countLog(r.git, "worktree add -b"), 0, "no new branch")
	eq(countLog(r.git, "fetch"), 0, "and nothing fetched: the default branch is not needed")
end)

windowCase("worktree.openIssue: a branch name git rejects ends the request with the way to fix the format, and creates nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.fail["check-ref-format"] = { status = 1 }
	local before = snapshot(r.git)
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, "Branch name 12-fix-login is not valid; change the branch format in Settings › Repositories.", "problem")
	eq(snapshot(r.git), before, "git state is untouched")
	eq(countLog(r.git, "fetch"), 0, "nothing was fetched")
	eq(countLog(r.git, "worktree add"), 0, "and nothing added")
end)

windowCase("worktree.openIssue: a repository, key or branch it cannot use ends the request without touching git; another repository's checkout is NO_REPO", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local function refused(what: string, repo: string, key: string, branch: string, want: string)
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.openIssue(r.launch, repo, key, { dir = "plotroom-o_r-issue-" .. key, branch = branch, fresh = true, base = "main" }, nil, function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		eq(out.calls, 0, what .. ": never synchronous")
		w.flush()
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		has(out.problem, want, what .. ": the reason")
	end
	refused("a repository that is no owner/name", "o", "12", "12-x", "Invalid repository")
	refused("a dot-dot owner", "../r", "12", "12-x", "Invalid repository")
	refused("a key with a slash", "o/r", "1/2", "12-x", "Invalid issue")
	refused("a key over 64 bytes", "o/r", string.rep("1", 65), "12-x", "Invalid issue")
	refused("an empty key", "o/r", "", "12-x", "Invalid issue")
	refused("no branch", "o/r", "12", "", "Invalid issue")
	local folder = openIssuePlan(w, worktree, r, "12", { dir = "a/b", branch = "12-x", fresh = true, base = "main" }, nil)
	eq(folder.result, nil, "a folder name with a slash: no result")
	has(folder.problem, "Worktree folder name a/b is not usable", "a folder name with a slash: the reason")
	eq(#w.calls, 0, "no process was started")
	r.git.remotes.origin = { "https://github.com/x/y.git" }
	local none = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(none.calls, 1, "done calls")
	eq(none.problem, worktree.NO_REPO, "a checkout of another repository is NO_REPO")
	eq(none.result, nil, "result")
	local other = newGit(w, "/work/other")
	other.remotes.origin = { "https://github.com/o/r.git" }
	other.served["refs/heads/main"] = sha("c")
	local given = openIssueWt(w, worktree, r, "12", "12-fix-login", "/work/other")
	eq(given.problem, nil, "the checkout given resolves")
	eq(given.result.root, "/work/other", "and is the one used")
	eq(given.result.head, sha("c"), "with its own remote's base")
end)

windowCase("worktree.openIssue: a base that cannot be fetched creates neither branch nor worktree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.served["refs/heads/main"] = nil
	local missing = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(missing.calls, 1, "done calls")
	eq(missing.result, nil, "no result")
	has(missing.problem, "couldn't find remote ref refs/heads/main", "git's own message")
	r.git.fail["fetch"] = {}
	local silent = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(silent.problem, "Could not read main of o/r.", "a fetch that left no ref says so")
	eq(r.git.refs["refs/heads/12-fix-login"], nil, "no branch was made")
	eq(#r.git.worktrees, 1, "and no worktree")
	eq(countLog(r.git, "worktree add"), 0, "git was never asked to add one")
end)

windowCase("worktree.openIssue: a Jira issue is made in the GitHub repository's checkout, in the repository's own directory", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "ABC-7")
	local function open(key: string): Opened
		return openIssuePlan(w, worktree, r, key, { branch = key .. "-fix", fresh = true, base = "main" }, nil)
	end
	local out = open("ABC-7")
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.result.path, "/wt/plotroom-o_r-issue-ABC-7", "the repository's slot, the key in its own case")
	eq(out.result.remote, "origin", "origin")
	eq(out.result.key, "ABC-7", "key")
	eq(out.result.branch, "ABC-7-fix", "branch")
	eq(out.result.created, true, "created")
	eq(countLog(r.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base is fetched into its remote-tracking ref")
	eq(r.git.refs["refs/heads/ABC-7-fix"], sha("b"), "the branch starts at the base")
	local again = open("ABC-7")
	eq(again.result.created, false, "the same issue again reuses its worktree")
	eq(again.result.path, out.result.path, "at the same path")
	-- the remote of the repository is the one used, whatever its name
	r.git.remotes = { zeta = { "https://github.com/x/z.git" }, upstream = { "https://github.com/o/r.git" } }
	eq(open("ABC-8").result.remote, "upstream", "the remote that points at o/r")
	-- a repository or key it cannot use
	local before = #w.calls
	for _, bad in { { "ABC", "ABC-1" }, { "o", "ABC-1" }, { "o/r", "ABC/1" }, { "o/r", "" } } do
		local refused: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.openIssue(r.launch, bad[1], bad[2], { dir = "plotroom-x", branch = "x", fresh = true, base = "main" }, nil, function(result, problem, cx)
			refused.calls += 1
			refused.result, refused.problem, refused.cx = result, problem, cx
		end)
		w.flush()
		eq(refused.calls, 1, "done calls: " .. bad[1] .. " " .. bad[2])
		eq(refused.result, nil, "no result: " .. bad[1] .. " " .. bad[2])
		has(refused.problem, "Invalid", "the reason: " .. bad[1] .. " " .. bad[2])
	end
	eq(#w.calls, before, "no process was started")
end)

windowCase("worktree: a project is a Jira key or a GitHub repository, and a checkout is claimed by cloning when it is no work tree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "ABC-7")
	yes(worktree.validProject("ABC") and worktree.validProject("A1_B") and worktree.validProject("o/r"), "a Jira key and a GitHub repository are projects")
	for _, bad in { "abc", "A", "o", "o/r/s", "" } do
		yes(not worktree.validProject(bad), "not a project: " .. bad)
	end
	local function claim(path: string): Opened
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.claimCheckout(path, "o/r", nil, function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		w.flush()
		return out
	end
	local ok = claim("/work/r/src")
	eq(ok.calls, 1, "done calls")
	eq(ok.problem, nil, "problem")
	eq(ok.result.root, "/work/r", "the checkout's root, found from a folder inside it")
	eq(ok.result.cloned, false, "used as it is")
	r.git.remotes = {}
	local bare = claim("/work/r")
	eq(bare.result, nil, "a checkout with no remote")
	eq(bare.problem, "No remote of /work/r points at github.com/o/r.", "has no remote of the repository")
	-- a folder that is no checkout, or is missing, is cloned into with gh
	local cloned = newGit(w, "/work/new")
	cloned.remotes.origin = { "https://github.com/o/r.git" }
	w.fs.dirs["/work/new"] = nil
	w.fs.dirs["/work/new/.git"] = nil
	w.respond(function(call: Call): Reply?
		if table.concat(call.argv, " ") == "gh repo clone o/r /work/new" then
			w.fs.dirs["/work/new"] = true
			w.fs.dirs["/work/new/.git"] = true
			return { stdout = "" }
		end
		return nil
	end)
	local made = claim("/work/new")
	eq(made.problem, nil, "a missing folder is cloned into: problem")
	eq(made.result.root, "/work/new", "and is the checkout")
	eq(made.result.cloned, true, "cloned")
	eq(countCalls(w, "gh repo clone o/r /work/new"), 1, "gh cloned once")
	w.fs.dirs["/work/plain"] = true
	w.respond(function(call: Call): Reply?
		if table.concat(call.argv, " ") == "gh repo clone o/r /work/plain" then
			return { status = 1, stderr = "fatal: destination path '/work/plain' already exists and is not an empty directory.\n" }
		end
		return nil
	end)
	local plain = claim("/work/plain")
	eq(plain.result, nil, "a folder that is no checkout and cannot be cloned into")
	has(plain.problem, "not an empty directory", "gh's reason is the problem")
end)

windowCase("worktree: claimCheckout answers a folder the runtime cannot look at with a problem, and never clones", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	issueRepo(w, "ABC-7")
	w.sdk.fs.exists = function(_path: string): boolean
		error("fs gone", 0)
	end
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.claimCheckout("/work/new", "o/r", nil, function(result, problem, cx)
		out.calls += 1
		out.result, out.problem, out.cx = result, problem, cx
	end)
	w.flush()
	eq(out.calls, 1, "answered once")
	eq(out.result, nil, "no checkout")
	has(out.problem, "fs gone", "the reason")
	eq(countCalls(w, "gh repo clone o/r /work/new"), 0, "nothing was cloned")
end)

case("worktree: describeIssue says how the issue's worktree stands", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local function result(created: boolean, dirty: boolean?): any
		return {
			path = "/wt/plotroom-o_r-issue-12",
			root = "/work/r",
			remote = "origin",
			branch = "12-fix-login",
			key = "12",
			created = created,
			head = sha("b"),
			dirty = dirty,
		}
	end
	eq(worktree.describeIssue(result(true, false)), "Created · 12-fix-login at bbbbbbb · Clean", "a new, clean one")
	eq(worktree.describeIssue(result(false, true)), "Reused · 12-fix-login at bbbbbbb · Modified (uncommitted changes kept)", "a reused one with local changes")
	eq(worktree.describeIssue(result(false, nil)), "Reused · 12-fix-login at bbbbbbb · Changes unchecked", "a status that could not be read is never Clean")
end)

case("worktree: remove takes an issue's worktree, and its branch only when git agrees it is merged", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local repo = issueRepo(w, "12")
	local r = openIssueWt(w, worktree, repo, "12", "12-fix-login", nil).result
	repo.git.unmerged["12-fix-login"] = true
	local mark = #w.calls
	local kept = removeWt(w, worktree, { root = r.root, path = r.path, branch = r.branch })
	eq(kept.problem, nil, "the worktree is removed")
	eq(kept.removal.branch, "Branch 12-fix-login was kept. The branch '12-fix-login' is not fully merged.", "a branch with commits merged nowhere stays, and the user is told")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-issue-12",
		"git -C /work/r branch -d 12-fix-login",
	}, "-d only: no ancestry check, no -D, and no ref to drop")
	eq(repo.git.refs["refs/heads/12-fix-login"], sha("b"), "the branch keeps its commits")
	repo.git.unmerged["12-fix-login"] = nil
	local again = openIssueWt(w, worktree, repo, "12", "12-fix-login", nil).result
	mark = #w.calls
	local gone = removeWt(w, worktree, { root = again.root, path = again.path, branch = again.branch })
	eq(gone.removal.branch, "Branch 12-fix-login was deleted too.", "a merged one goes with the next removal")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-issue-12",
		"git -C /work/r branch -d 12-fix-login",
	}, "by -d")
	eq(repo.git.refs["refs/heads/12-fix-login"], nil, "the branch is gone")
end)

-- Reads the checkout `checkout` with worktree.scan for `wants` (item key -> how its worktree is known), lets everything that
-- starts finish, and answers the Scan and the problem; scan must answer once.
local function scanOf(w: World, worktree: Worktree, checkout: string, wants: { [string]: any }): (any, string?)
	local got: any = nil
	local why: string? = nil
	local calls = 0
	worktree.scan(checkout, wants, function(result, problem)
		calls += 1
		got, why = result, problem
	end)
	w.flush()
	eq(calls, 1, "scan reports once")
	return got, why
end

-- The item keys of a Scan's `found`, sorted.
local function foundKeys(scan: any): { string }
	local keys: { string } = {}
	for key in scan.found do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

case("worktree: scan finds the worktrees of the items it is given, by their branches or folder names, as git lists them, and leaves out what Plotroom cannot use or remove", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	local function add(path: string, branch: string?, head: string, locked: boolean?, folder: boolean?)
		table.insert(g.worktrees, { path = path, branch = if branch then "refs/heads/" .. branch else nil, head = head, locked = locked == true })
		if folder ~= false then
			w.fs.dirs[path] = true
		end
	end
	add("/wt/plotroom-o_r-pr-5", "feature", sha("b"))
	add("/wt/plotroom-o_r-pr-6", "feature-6", sha("b"), true)
	add("/wt/plotroom-o_r-pr-7", nil, sha("b"))
	add("/wt/plotroom-o_r-pr-8", "feature-8", sha("b"), false, false)
	add("/wt/anything", "bob/patch", sha("d"))
	add("/wt/plotroom-o_r-pr-3", "plotroom/o/r/pr-3", sha("f"))
	add("/home/u/plotroom-notes/wt/plotroom-o_r-pr-4", "plotroom/o/r/pr-4", sha("a"))
	add("/wt/plotroom-o_r-issue-12", "octocat/12-fix-login", sha("c"))
	add("/wt/plotroom-o_r-issue-13", nil, sha("c"))
	add("/wt/elsewhere", "other", sha("e"))
	local function pr(n: number, branch: string): any
		return { branches = { branch }, dirs = { "plotroom-o_r-pr-" .. n }, ref = "refs/plotroom-pr/o/r/pr-" .. n }
	end
	local wants = {
		["o/r#3"] = pr(3, "feature-3"),
		["o/r#4"] = pr(4, "feature-4"),
		["o/r#5"] = pr(5, "feature"),
		["o/r#6"] = pr(6, "feature-6"),
		["o/r#7"] = pr(7, "feature-7"),
		["o/r#8"] = pr(8, "feature-8"),
		["o/r#9"] = pr(9, "bob/patch"),
		["o/r#12"] = { branches = { "octocat/12-fix-login" }, dirs = { "plotroom-o_r-issue-12" } },
		["o/r#13"] = { branches = { "octocat/13-x" }, dirs = { "plotroom-o_r-issue-13" } },
		["o/r#14"] = pr(14, "feature-14"),
	}
	local scan, why = scanOf(w, worktree, "/work/r/src", wants)
	eq(why, nil, "problem")
	eq(scan.root, "/work/r", "the main worktree, whichever folder of the checkout was asked")
	same(foundKeys(scan), { "o/r#12", "o/r#3", "o/r#4", "o/r#5", "o/r#9" }, "found: a locked one, a detached one, one whose folder is gone, one no item names and an item with no worktree are left out")
	same(scan.found["o/r#5"], { root = "/work/r", path = "/wt/plotroom-o_r-pr-5", branch = "feature", head = sha("b"), ref = "refs/plotroom-pr/o/r/pr-5" }, "a pull request's: where it is, its branch and head, and the ref it is fetched into")
	same(scan.found["o/r#9"], { root = "/work/r", path = "/wt/anything", branch = "bob/patch", head = sha("d"), ref = "refs/plotroom-pr/o/r/pr-9" }, "a fork's is on its owner's branch, whatever its folder is called")
	eq(scan.found["o/r#3"].path, "/wt/plotroom-o_r-pr-3", "one on a branch an earlier version named is found by its folder")
	eq(scan.found["o/r#3"].branch, "plotroom/o/r/pr-3", "and says which branch it is on")
	eq(scan.found["o/r#4"].path, "/home/u/plotroom-notes/wt/plotroom-o_r-pr-4", "the folder's own name decides, not the folders above it")
	same(scan.found["o/r#12"], { root = "/work/r", path = "/wt/plotroom-o_r-issue-12", branch = "octocat/12-fix-login", head = sha("c") }, "an issue's has no fetched ref")
	eq(countLog(g, "worktree list"), 1, "one read of the checkout")
	for _, never in { "worktree add", "worktree remove", "status", "fetch", "branch", "merge", "config", "remote", "rev-parse" } do
		eq(countLog(g, never), 0, "git " .. never .. " was not run: scanning only lists")
	end
	eq(scanOf(w, worktree, "/wt/plotroom-o_r-pr-5", wants).root, "/work/r", "asked from a linked worktree, it still names the main one")
	same(foundKeys((scanOf(w, worktree, "/work/r", {}))), {}, "no item wanted, none found")
	g.fail["worktree list"] = { status = 128, stderr = "fatal: unable to read the worktrees\n" }
	local none, problem = scanOf(w, worktree, "/work/r", wants)
	eq(none, nil, "a checkout git cannot list gives no scan")
	has(problem, "unable to read the worktrees", "and git's reason")
	g.fail["worktree list"] = nil
	w.sdk.fs.exists = function(_path: string): boolean
		error("fs gone", 0)
	end
	same(foundKeys((scanOf(w, worktree, "/work/r", wants))), {}, "a runtime that cannot look at folders finds none, and still answers")
end)

case("worktree: scan knows a worktree by its branch before its folder, and takes the first git lists when an item has two", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	local function add(path: string, branch: string)
		table.insert(g.worktrees, { path = path, branch = "refs/heads/" .. branch, head = sha("b"), locked = false })
		w.fs.dirs[path] = true
	end
	add("/wt/shared", "feature-a")
	add("/wt/own", "feature-b")
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#1"] = { branches = { "feature-a" }, dirs = { "elsewhere" } },
		["o/r#2"] = { branches = { "feature-b" }, dirs = { "shared" } },
	})
	eq(scan.found["o/r#1"].path, "/wt/shared", "a worktree whose branch an item wants is that item's...")
	eq(scan.found["o/r#2"].path, "/wt/own", "...though another item names its folder, and that one has its own")
	-- an item with two worktrees: one on its branch, one in its folder
	add("/wt/by-branch", "feature-c")
	add("/wt/by-folder", "unrelated")
	local two = { ["o/r#3"] = { branches = { "feature-c" }, dirs = { "by-folder" } } }
	eq(scanOf(w, worktree, "/work/r", two).found["o/r#3"].path, "/wt/by-branch", "the first git lists is the item's")
	table.insert(g.worktrees, 2, table.remove(g.worktrees) :: any)
	eq(scanOf(w, worktree, "/work/r", two).found["o/r#3"].path, "/wt/by-folder", "whichever that is")
end)

case("worktree: scan gives a worktree to every item that names its branch or folder", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	table.insert(g.worktrees, { path = "/wt/a", branch = "refs/heads/fix-login", head = sha("b"), locked = false })
	table.insert(g.worktrees, { path = "/wt/plotroom-o_r-issue-9", branch = "refs/heads/other", head = sha("c"), locked = false })
	w.fs.dirs["/wt/a"] = true
	w.fs.dirs["/wt/plotroom-o_r-issue-9"] = true
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#12"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-issue-12" } },
		["o/r#45"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-pr-45" }, ref = "refs/plotroom-pr/o/r/pr-45" },
		["o/r#46"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-pr-46" }, ref = "refs/plotroom-pr/o/r/pr-46" },
		["o/r#9"] = { branches = { "x" }, dirs = { "plotroom-o_r-issue-9" } },
		["o/r#10"] = { branches = { "y" }, dirs = { "plotroom-o_r-issue-9" } },
	})
	same(foundKeys(scan), { "o/r#10", "o/r#12", "o/r#45", "o/r#46", "o/r#9" }, "an issue and pull requests on one branch, or in one folder, all have it")
	eq(scan.found["o/r#45"].ref, "refs/plotroom-pr/o/r/pr-45", "each keeps its own fetched ref")
	eq(scan.found["o/r#46"].ref, "refs/plotroom-pr/o/r/pr-46", "each keeps its own fetched ref")
	eq(scan.found["o/r#12"].path, "/wt/a", "the same worktree")
end)

case("worktree: scan gives a folder-only item the worktree a PR branch also matches, unless the item has a worktree of its own branch", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	local function add(path: string, branch: string)
		table.insert(g.worktrees, { path = path, branch = "refs/heads/" .. branch, head = sha("b"), locked = false })
		w.fs.dirs[path] = true
	end
	add("/wt/plotroom-o_r-issue-12", "fix-login")
	add("/wt/own", "feature-b")
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#45"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-pr-45" }, ref = "refs/plotroom-pr/o/r/pr-45" },
		["o/r#12"] = { branches = { "octocat/12-x" }, dirs = { "plotroom-o_r-issue-12" } },
		["o/r#13"] = { branches = { "feature-b" }, dirs = { "plotroom-o_r-issue-12" } },
	})
	eq(scan.found["o/r#45"].path, "/wt/plotroom-o_r-issue-12", "the PR by its branch")
	eq(scan.found["o/r#12"].path, "/wt/plotroom-o_r-issue-12", "the issue by its folder, though the branch is the PR's")
	eq(scan.found["o/r#13"].path, "/wt/own", "an item with a worktree on its own branch keeps that one")
end)

case("worktree: scan never reports the main worktree, whatever branch or folder name an item wants", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	table.insert(g.worktrees, { path = "/wt/plotroom-o_r-pr-5", branch = "refs/heads/feature", head = sha("b"), locked = false })
	w.fs.dirs["/wt/plotroom-o_r-pr-5"] = true
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#1"] = { branches = { "main" }, dirs = {} },
		["o/r#2"] = { branches = {}, dirs = { "r" } },
		["o/r#5"] = { branches = { "feature" }, dirs = {} },
	})
	same(foundKeys(scan), { "o/r#5" }, "the checkout is no item's worktree: not by its branch, not by its folder")
	eq(scan.root, "/work/r", "though it is the root")
end)

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

-- The queue view's picker node, its props, and the PR ids the picker lists in order.
local function pickerNode(b: Block): any
	local view: any = b.view()
	return view.layer.c[1]
end

local function pickerOf(b: Block): any
	return pickerNode(b).p
end

-- Helpers of the cases, in one table: this file is at Luau's 200-top-level-local limit.
local hx = {}

-- Picks the first listed row as a click on it does, unless something is selected: nothing is selected for the user, so a
-- case that acts on "the" item picks one first. Its preview opens, and with it the item is marked seen.
function hx.selectFirst(b: Block)
	if pickerOf(b).selected == nil then
		for _, id in pickerOf(b).order do
			if type(id) == "string" then
				b.event({ ev = "select", id = "layer.queue", item = id })
				return
			end
		end
	end
end

-- The settings view's page props: the side sheet in the layer, after the queue's picker.
local function prefsOf(b: Block): any
	local view: any = b.view()
	return findKey(view.layer, "settings", "prefs").p
end

-- The branches of o/r that worktree.remoteBranches lists from `checkout`: its one answer (result: the names).
local function remoteBranchesOf(w: World, worktree: Worktree, checkout: string): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.remoteBranches(checkout, "o/r", function(names, problem, cx)
		out.calls += 1
		out.result, out.problem, out.cx = names, problem, cx
	end)
	w.flush()
	return out
end

windowCase("worktree.openIssue: a plan with neither a PR nor a new branch is UNDECIDED when no worktree is at the folder", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = false }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, worktree.UNDECIDED, "problem: the caller has to choose between a linked PR's branch and a new one")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
end)

windowCase("worktree.openIssue: a worktree already at the plan's folder is reused whatever the plan, on its own branch", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	table.insert(r.git.worktrees, { path = r.target, branch = "refs/heads/work-in-progress", head = sha("d"), locked = false })
	w.fs.dirs[r.target] = true
	local before = snapshot(r.git)
	local plans: { { any } } = {
		{ "an undecided plan", { branch = "12-fix-login", fresh = false } },
		{ "a new branch without a base", { branch = "12-fix-login", fresh = true } },
		{ "a new branch from a base", { branch = "12-fix-login", fresh = true, base = "main" } },
		{ "a PR", { branch = "12-fix-login", pr = 7, fresh = false } },
	}
	for _, row in plans do
		local out = openIssuePlan(w, worktree, r, "12", row[2], nil)
		eq(out.calls, 1, row[1] .. ": done calls")
		eq(out.problem, nil, row[1] .. ": problem")
		eq(out.result.created, false, row[1] .. ": created")
		eq(out.result.path, r.target, row[1] .. ": path")
		eq(out.result.branch, "work-in-progress", row[1] .. ": the worktree's own branch, not the one asked for")
		eq(out.result.head, sha("d"), row[1] .. ": head")
		eq(out.result.dirty, false, row[1] .. ": dirty")
	end
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched, added or configured")
	eq(#gh.requests, 0, "the PR was not even read")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	-- a detached HEAD has no branch of its own: the plan's is reported
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-13", head = sha("e"), locked = false })
	w.fs.dirs["/wt/plotroom-o_r-issue-13"] = true
	local detached = openIssuePlan(w, worktree, r, "13", { branch = "13-docs", fresh = false }, nil)
	eq(detached.problem, nil, "problem for a detached worktree")
	eq(detached.result.created, false, "created")
	eq(detached.result.branch, "13-docs", "branch")
	eq(detached.result.head, sha("e"), "head")
end)

windowCase("worktree.openIssue: a plan with a PR puts the worktree on that PR's head branch as worktree.open does, in the plan's folder", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	gh.meta["o/r#7"] = { base = "o/r", sha = sha("b"), ref = "fix-login", headRepo = "o/r", headOwner = "o", state = "open", baseRef = "main", title = "Fix login", author = "ann" }
	r.git.served["refs/pull/7/head"] = sha("b")
	r.git.served["refs/heads/fix-login"] = sha("b")
	local out = openIssuePlan(w, worktree, r, "12", { dir = "issue-12", branch = "", pr = 7, fresh = false }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local res = out.result
	eq(res.path, "/wt/issue-12", "path: the plan's folder")
	eq(res.root, "/work/r", "root")
	eq(res.remote, "origin", "remote")
	eq(res.branch, "fix-login", "branch: the PR's head branch, whatever the plan's own")
	eq(res.key, "12", "key")
	eq(res.ref, worktree.prRef("o", "r", 7), "ref: where the PR head was fetched")
	eq(res.number, 7, "number")
	eq(res.created, true, "created")
	eq(res.head, sha("b"), "head")
	eq(res.dirty, false, "dirty")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/7/head:refs/plotroom-pr/o/r/pr-7",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/fix-login:refs/remotes/origin/fix-login",
		"omp worktree add -q -C /work/r -b fix-login /wt/issue-12 " .. sha("b"),
		"git -C /work/r config branch.fix-login.remote origin",
		"git -C /work/r config branch.fix-login.merge refs/heads/fix-login",
	}, "the PR's head, its branch's tracking ref, the worktree on a new branch there, then the upstream")
	same(r.git.config, { ["branch.fix-login.remote"] = "origin", ["branch.fix-login.merge"] = "refs/heads/fix-login" }, "the upstream")
	-- another issue linked to the same PR shares the PR's worktree, wherever it is
	local mark = #w.calls
	local shared = openIssuePlan(w, worktree, r, "14", { branch = "", pr = 7, fresh = false }, nil)
	eq(shared.problem, nil, "problem for a second issue")
	eq(shared.result.created, false, "created")
	eq(shared.result.path, "/wt/issue-12", "the worktree that has the PR's branch")
	eq(shared.result.key, "14", "key")
	eq(shared.result.ref, worktree.prRef("o", "r", 7), "ref")
	eq(shared.result.number, 7, "number")
	same(worktreeWrites(w, mark), {}, "nothing fetched, added or configured")
	-- a fork's PR is on the fork's branch
	gh.meta["o/r#8"] = { base = "o/r", sha = sha("b"), ref = "patch", headRepo = "fork/r", headOwner = "fork", state = "open", baseRef = "main", title = "Patch", author = "bo" }
	r.git.served["refs/pull/8/head"] = sha("b")
	local forked = openIssuePlan(w, worktree, r, "15", { branch = "", pr = 8, fresh = false }, nil)
	eq(forked.problem, nil, "problem for a fork's PR")
	eq(forked.result.branch, "fork/patch", "branch")
	eq(forked.result.number, 8, "number")
	eq(r.git.config["branch.fork/patch.remote"], "https://github.com/fork/r.git", "tracking the fork's URL")
	eq(r.git.config["branch.fork/patch.merge"], "refs/heads/patch", "and its branch")
end)

windowCase("worktree.openIssue: a plan's PR must merge into the repository (any letter case) and be readable, or nothing is created", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	gh.meta["o/r#9"] = { base = "x/y", sha = sha("b"), ref = "feature", headRepo = "x/y", headOwner = "x", state = "open", baseRef = "main", title = "Elsewhere", author = "ann" }
	r.git.served["refs/pull/9/head"] = sha("b")
	local before = snapshot(r.git)
	local other = openIssuePlan(w, worktree, r, "12", { branch = "12-x", pr = 9, fresh = false }, nil)
	eq(other.calls, 1, "done calls")
	eq(other.result, nil, "no result")
	eq(other.problem, "Pull request #9 merges into x/y, not o/r.", "problem: another repository's PR")
	local missing = openIssuePlan(w, worktree, r, "12", { branch = "12-x", pr = 10, fresh = false }, nil)
	eq(missing.calls, 1, "done calls for an unreadable PR")
	eq(missing.result, nil, "no result for an unreadable PR")
	has(missing.problem, "gh: Not Found (HTTP 404)", "problem: gh's own")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	gh.meta["o/r#9"].base = "O/R"
	local cased = openIssuePlan(w, worktree, r, "12", { branch = "12-x", pr = 9, fresh = false }, nil)
	eq(cased.problem, nil, "problem when the base differs only in letter case")
	eq(cased.result.number, 9, "number")
end)

windowCase("worktree.openIssue: a new branch without a base is NEED_BASE once its name is checked and no worktree has the branch", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, worktree.NEED_BASE, "problem: the caller has to ask which branch to start from")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	eq(countLog(r.git, "check-ref-format --branch 12-fix-login"), 1, "the branch name was checked")
	-- a name git refuses is refused first, whether or not a base was chosen
	local invalid = openIssuePlan(w, worktree, r, "13", { branch = "13 fix login", fresh = true }, nil)
	eq(invalid.result, nil, "no result for an invalid branch")
	eq(invalid.problem, "Branch name 13 fix login is not valid; change the branch format in Settings › Repositories.", "problem: the branch name, not NEED_BASE")
	local withBase = openIssuePlan(w, worktree, r, "13", { branch = "13 fix login", fresh = true, base = "main" }, nil)
	eq(withBase.problem, "Branch name 13 fix login is not valid; change the branch format in Settings › Repositories.", "problem with a base")
	same(worktreeWrites(w), {}, "still nothing fetched or added")
	-- a worktree that has the branch is reused: no base is needed
	table.insert(r.git.worktrees, { path = "/wt/elsewhere", branch = "refs/heads/14-typo", head = sha("f"), locked = false })
	w.fs.dirs["/wt/elsewhere"] = true
	local reused = openIssuePlan(w, worktree, r, "14", { branch = "14-typo", fresh = true }, nil)
	eq(reused.problem, nil, "problem when a worktree has the branch")
	eq(reused.result.created, false, "created")
	eq(reused.result.path, "/wt/elsewhere", "path: the worktree that has it")
	eq(reused.result.branch, "14-typo", "branch")
	eq(reused.result.head, sha("f"), "head")
	same(worktreeWrites(w), {}, "nothing was added")
end)

windowCase("worktree.openIssue: a new branch starts at the commit of its base as fetched from the remote, with no upstream", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true, base = "main" }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local res = out.result
	eq(res.created, true, "created")
	eq(res.path, r.target, "path")
	eq(res.branch, "12-fix-login", "branch")
	eq(res.key, "12", "key")
	eq(res.head, sha("b"), "head: the remote's main, not the checkout's own main at " .. sha("1"))
	eq(res.dirty, false, "dirty")
	eq(res.ref, nil, "no PR ref")
	eq(res.number, nil, "no PR number")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main",
		"omp worktree add -q -C /work/r -b 12-fix-login /wt/plotroom-o_r-issue-12 " .. sha("b"),
	}, "the base is fetched once, then the worktree is added on a new branch at that commit, and no upstream is written")
	eq(r.git.refs["refs/remotes/origin/main"], sha("b"), "the remote-tracking ref holds the remote's commit")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("b"), "the new branch starts there")
	eq(r.git.refs["refs/heads/main"], sha("1"), "the checkout's own main did not move")
	same(r.git.config, {}, "no upstream: the first push -u sets it")
	-- a base that is not the default branch and has a slash, while the checkout's own branch of that name is somewhere else
	r.git.served["refs/heads/release/1.2"] = sha("c")
	r.git.refs["refs/heads/release/1.2"] = sha("d")
	local mark = #w.calls
	local release = openIssuePlan(w, worktree, r, "13", { branch = "13-docs", fresh = true, base = "release/1.2" }, nil)
	eq(release.problem, nil, "problem for a release base")
	eq(release.result.head, sha("c"), "head: the remote's release/1.2, not the local branch of that name")
	same(worktreeWrites(w, mark), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/release/1.2:refs/remotes/origin/release/1.2",
		"omp worktree add -q -C /work/r -b 13-docs /wt/plotroom-o_r-issue-13 " .. sha("c"),
	}, "the base is fetched under its own name")
	eq(r.git.refs["refs/heads/release/1.2"], sha("d"), "the local branch of that name did not move")
end)

windowCase("worktree.openIssue: a base that cannot be fetched or read creates nothing, and the problem is git's own", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local function refused(what: string, base: string): string?
		local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true, base = base }, nil)
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		eq(snapshot(r.git), before, what .. ": no branch, ref or worktree was made")
		eq(#w.fs.mkdirs, 0, what .. ": no directory was made")
		return out.problem
	end
	has(refused("a branch the remote does not have", "gone"), "couldn't find remote ref refs/heads/gone", "git's message for a missing branch")
	r.git.fail["fetch"] = { status = 128, stderr = "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com\n" }
	has(refused("a failing fetch", "main"), "Could not resolve host: github.com", "git's message for a failing fetch")
	r.git.fail["fetch"] = {} -- git says nothing and the ref is not there
	eq(refused("a fetch that leaves no ref", "main"), "Could not read main of o/r.", "a fetch that left nothing to start from")
	r.git.fail["fetch"] = nil
	local mark = #w.calls
	eq(refused("a base git rejects as a branch name", "bad name"), "Base branch bad name is not a valid branch name.", "the invalid base")
	same(worktreeWrites(w, mark), {}, "which is not fetched")
end)

windowCase("worktree.openIssue: a new branch that exists locally is attached at its own commit, without a base, and never moved", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.refs["refs/heads/12-fix-login"] = sha("d")
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem: no base was needed")
	eq(out.result.created, true, "created")
	eq(out.result.branch, "12-fix-login", "branch")
	eq(out.result.head, sha("d"), "head: the branch's own commit")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("d"), "the branch did not move")
	same(worktreeWrites(w), { "omp worktree add -q -C /work/r /wt/plotroom-o_r-issue-12 12-fix-login" }, "attached with the two-argument form: nothing fetched, no -b, no upstream")
	-- a base chosen anyway is not fetched either
	r.git.refs["refs/heads/13-docs"] = sha("e")
	local mark = #w.calls
	local based = openIssuePlan(w, worktree, r, "13", { branch = "13-docs", fresh = true, base = "main" }, nil)
	eq(based.problem, nil, "problem with a base")
	eq(based.result.head, sha("e"), "head")
	same(worktreeWrites(w, mark), { "omp worktree add -q -C /work/r /wt/plotroom-o_r-issue-13 13-docs" }, "the base is not needed, so not fetched")
end)

windowCase("worktree.openIssue: a folder name or branch that cannot be used ends the request, creating nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local bad: { { string } } = {
		{ "a slash", "issue/12" },
		{ "a path out of the folder", "../issue-12" },
		{ "an empty name", "" },
		{ "two dots", ".." },
		{ "a newline", "issue\n12" },
		{ "201 bytes", string.rep("a", 201) },
	}
	for _, row in bad do
		local out = openIssuePlan(w, worktree, r, "12", { dir = row[2], branch = "12-fix-login", fresh = true, base = "main" }, nil)
		eq(out.calls, 1, row[1] .. ": done calls")
		eq(out.result, nil, row[1] .. ": no result")
		has(out.problem, "Worktree folder name " .. row[2] .. " is not usable", row[1] .. ": names the folder name")
		has(out.problem, "Settings", row[1] .. ": says where to change it")
	end
	local nameless = openIssuePlan(w, worktree, r, "12", { branch = "", fresh = true, base = "main" }, nil)
	eq(nameless.result, nil, "no result for a new branch without a name")
	has(nameless.problem, "Invalid issue 12 of o/r", "problem: a new branch needs a name")
	eq(snapshot(r.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	local spaced = openIssuePlan(w, worktree, r, "12", { dir = "issue 12", branch = "12-fix-login", fresh = true, base = "main" }, nil)
	eq(spaced.problem, nil, "problem for a folder name with spaces")
	eq(spaced.result.path, "/wt/issue 12", "path")
	local added: any = nil
	for _, call in w.calls do
		if call.argv[1] == "omp" and call.argv[3] == "add" then
			added = call.argv
		end
	end
	same(added, { "omp", "worktree", "add", "-q", "-C", "/work/r", "-b", "12-fix-login", "/wt/issue 12", sha("b") }, "the folder is one argument, never a shell word")
end)

windowCase("worktree.openIssue: a folder that is no worktree ends a PR or a new-branch plan, touching nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	gh.meta["o/r#7"] = { base = "o/r", sha = sha("b"), ref = "fix-login", headRepo = "o/r", headOwner = "o", state = "open", baseRef = "main", title = "Fix login", author = "ann" }
	r.git.served["refs/pull/7/head"] = sha("b")
	w.fs.dirs[r.target] = true
	local before = snapshot(r.git)
	local fresh = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true, base = "main" }, nil)
	eq(fresh.result, nil, "no result for a new branch")
	eq(fresh.problem, r.target .. " already exists and is not the worktree of 12-fix-login; move it away or remove it.", "problem for a new branch")
	local pr = openIssuePlan(w, worktree, r, "12", { branch = "", pr = 7, fresh = false }, nil)
	eq(pr.result, nil, "no result for a PR")
	eq(pr.problem, r.target .. " already exists and is not the worktree of fix-login; move it away or remove it.", "problem for a PR")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
end)

windowCase("worktree.remoteBranches: lists the branches of the repository's own remote, its default branch first and the rest sorted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.remotes = { origin = { "https://github.com/me/r.git" }, upstream = { "https://github.com/o/r.git" } }
	r.git.defaultBranch = "trunk"
	for _, name in { "zeta", "trunk", "release/2.0", "alpha", "release/10.0", "feat/x" } do
		r.git.served["refs/heads/" .. name] = sha("c")
	end
	local out = remoteBranchesOf(w, worktree, r.launch)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	same(out.result, { "trunk", "alpha", "feat/x", "main", "release/10.0", "release/2.0", "zeta" }, "the default branch, then the others in name order")
	eq(countCalls(w, "git -C /work/r ls-remote --symref upstream HEAD refs/heads/*"), 1, "asked the remote that points at o/r, for HEAD and the branches")
	-- a remote that names no default branch: just the names, sorted
	r.git.defaultBranch = nil
	local plain = remoteBranchesOf(w, worktree, r.launch)
	eq(plain.problem, nil, "problem without a default branch")
	same(plain.result, { "alpha", "feat/x", "main", "release/10.0", "release/2.0", "trunk", "zeta" }, "sorted, none first")
	-- a remote with no branch at all
	r.git.served = {}
	local empty = remoteBranchesOf(w, worktree, r.launch)
	eq(empty.problem, nil, "problem for an empty remote")
	same(empty.result, {}, "no branches")
	-- git's own order is not relied on: whatever order the remote lists its refs in, the names come out sorted
	local listing = "ref: refs/heads/main\tHEAD\n" .. sha("c") .. "\tHEAD\n"
	for _, name in { "zeta", "main", "alpha", "release/10.0", "feat/x" } do
		listing ..= sha("c") .. "\trefs/heads/" .. name .. "\n"
	end
	w.respond(function(call: Call): Reply?
		return if table.concat(call.argv, " ") == "git -C /work/r ls-remote --symref upstream HEAD refs/heads/*" then { stdout = listing } else nil
	end)
	local shuffled = remoteBranchesOf(w, worktree, r.launch)
	eq(shuffled.problem, nil, "problem for an unsorted listing")
	same(shuffled.result, { "main", "alpha", "feat/x", "release/10.0", "zeta" }, "the default branch, then the rest sorted")
end)

windowCase("worktree.remoteBranches: a remote that cannot be listed is the problem, and a checkout of another repository is NO_REPO", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.fail["ls-remote"] = { status = 128, stderr = "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com\n" }
	local failed = remoteBranchesOf(w, worktree, r.launch)
	eq(failed.calls, 1, "done calls")
	eq(failed.result, nil, "no names")
	has(failed.problem, "Could not resolve host: github.com", "problem: git's own message")
	r.git.fail["ls-remote"] = nil
	r.git.remotes.origin = { "https://github.com/x/y.git" }
	local none = remoteBranchesOf(w, worktree, r.launch)
	eq(none.calls, 1, "done calls for another repository")
	eq(none.result, nil, "no names for another repository")
	eq(none.problem, worktree.NO_REPO, "problem: a checkout of another repository")
	eq(countLog(r.git, "ls-remote"), 1, "only the first checkout was listed")
end)

-- ---- window.luau: the Worktree link

local function prLink(kind: string, repo: string, n: number): string
	return "plotroom://github/" .. kind .. "/" .. repo .. "/" .. n
end

-- The link of the card's button that runs saved prompt `id` on PR `repo`#`n`.
local function runLink(repo: string, n: number, id: string): string
	return prLink("run", repo, n) .. "/" .. id
end

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

-- The Plotroom block of pane 1, opened in the scene's checkout and listing its PR, linked to the window: the window's
-- requests reach its host half, which runs git, gh and omp, and the answers come back.
local function linkQueue(w: World, s: Scene): Block
	w.load("host")
	s.gh.items.octocat = { searchItem(s.number, s.repo, EPOCH - 60) }
	listPr(w, s.repo, s.number)
	local b = w.open(1, { s.launch })
	w.link(b)
	w.flush()
	hx.selectFirst(b)
	return b
end

-- The worktree card the block shows for its selected PR, nil when none.
local function cardOf(b: Block): any
	return findKey(pickerNode(b), "worktree", "card")
end

-- The queue surface of pane 1 as the selected PR's own card shows it: the links of the block's real view, with the ids
-- Tern gives them. (`listPr` lists links for a PR the block need not be showing.)
local function cardSurface(w: World, b: Block)
	w.window.surfaces[1] = { layer = { id = "layer", c = { tspOf(pickerNode(b), "layer.queue") } } }
end

-- Every string the worktree card shows. (`Block.text` also holds the hidden answers to the window: JSON that can repeat
-- a reason the card no longer shows.)
local function cardText(b: Block): string
	local out: { string } = {}
	collectTexts(cardOf(b), out)
	return table.concat(out, "\n")
end

-- The shell commands the worktree card offers under `which` (its section's key: "update"), one per line; nil when none.
local function commandsOf(b: Block, which: string): string?
	local section = findKey(cardOf(b), which, "section")
	local md: any = if section then findKey(section, "commands", "md") else nil
	return if md then string.match(md.p.text, "^```sh\n(.-)\n```$") else nil
end

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

-- The worktree card's buttons as "key:label", in order; none for a failed attempt.
local function buttonsOf(b: Block): { string }
	local out: { string } = {}
	local list: any = findKey(cardOf(b), "actions", "row")
	local rows: { any } = if list then list.c else {}
	for _, row in rows do
		table.insert(out, row.p.key .. ":" .. row.p.label)
	end
	return out
end

-- A click on the card's button `key`, as Tern sends it: the button's own id, with the action it was given.
local function pressCard(b: Block, key: string)
	local item: any = findKey(cardOf(b), key, "item")
	b.event({ ev = "action", id = "layer.queue.worktree.actions." .. key, act = item.p.actions.click })
end

-- The confirm overlay the block shows over the queue; nil when it shows none.
local function confirmOf(b: Block): any
	return findKey(b.view().layer, "confirm", "overlay")
end

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

-- Moves the queue's selection to PR `n`: its worktree's card and badge are what the block then shows.
local function showPr(b: Block, n: number)
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_23" .. n })
end

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

-- Sends the block a request the way a window does: act "rpc", a JSON value holding the request's id and op.
local function request(b: Block, id: string, body: { [string]: any })
	body.id = id
	b.event({ ev = "action", act = "rpc", value = jsonEncode(body) })
end

-- What the block answered request `id`: its hidden `r<id>` node, decoded; nil when it keeps none.
local function answerOf(b: Block, id: string): any
	local view: any = b.view()
	local node = findKey(view.main, "r" .. id)
	return if node then jsonDecode(node.p.text) else nil
end

-- The delete the block asks the window to confirm: its hidden `confirm` node, decoded ({row, head, label, detail}); nil when none is pending.
local function pendingOf(b: Block): any
	local view: any = b.view()
	local node = findKey(view.main, "confirm")
	return if node then jsonDecode(node.p.text) else nil
end

-- Saved prompts as kv keeps them: `filters` are the ids of the filters a prompt is offered under, none: every filter;
-- `key` is its shortcut in the queue.
local function promptOf(id: string, name: string, text: string, key: string?): { [string]: any }
	return { id = id, name = name, text = text, key = key }
end

-- Makes `list` the saved prompts.
local function savePrompts(w: World, list: { { [string]: any } })
	w.kv.put("prompts-prs", { version = 1, nextId = #list + 1, items = array(list) })
end

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

-- A window whose Plotroom pane (a linked block opened in the checkout's src directory) lists o/r#5.
local function agentScene(w: World): (Scene, Block)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	return s, linkQueue(w, s)
end

windowCase("window: the Add repository picker offers the saved repositories and each gh login, whose repositories it lists next; a pick or a typed one is saved and its checkout row opens", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.repos.work = { "z/z", "o/r" }
	local b = linkQueue(w, s)
	w.window.choose = { "@work", "z/z" }
	w.click("plotroom://repos")
	w.flush()
	local function labels(i: number): { string }
		local out: { string } = {}
		for _, item in w.window.picks[i].items do
			table.insert(out, item.label)
		end
		return out
	end
	same(labels(1), { "o/r", "@octocat", "@work", "Other repository…" }, "saved, then the gh logins (active first), then a typed one")
	eq(w.window.picks[1].items[1].detail, "/work/r", "a saved repository shows its checkout")
	same(labels(2), { "z/z", "o/r" }, "picking a login lists its repositories")
	eq(w.kv.get("checkouts")["z/z"], "", "the pick is saved without a checkout")
	eq(prefsOf(b).editing.row, "checkout:z/z", "and Settings opens on its checkout row")
	w.window.choose = "Other repository…"
	w.window.typed = " p/q "
	w.click("plotroom://repos")
	w.flush()
	eq(w.kv.get("checkouts")["p/q"], "", "so is a typed one")
	eq(prefsOf(b).editing.row, "checkout:p/q", "with its row open")
end)

windowCase("window: clicking Worktree coalesces repeats, notes the worktree on the block first, then opens its tab", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	local cardAtTab: any = nil
	local newTab = w.cx.layout.new_tab
	w.cx.layout.new_tab = function(self: any, launch: any, reveal: any): number?
		cardAtTab = cardOf(b)
		return newTab(self, launch, reveal)
	end
	w.click(prLink("worktree", "o/r", 5))
	eq(w.toasts[1].level, "info", "start")
	has(w.toasts[1].text, "o/r#5", "names the pull request")
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(countLog(s.git, "worktree add"), 1, "created once")
	eq(answerOf(b, requestsSent(w)[2].id).busy, true, "the host answered the repeat that the PR is already being prepared")
	eq(w.toasts[3].level, "info", "a second click while it runs is told so")
	has(w.toasts[3].text, "o/r#5", "names the pull request")
	eq(w.toasts[4].level, "success", "level")
	has(w.toasts[4].text, "o/r#5", "names the pull request")
	has(w.toasts[4].sub, "Created", "a new worktree")
	has(w.toasts[4].sub, "Current", "at the PR head")
	has(w.toasts[4].sub, "bbbbbbb", "names the head")
	has(w.toasts[4].sub, "Clean", "without local changes")
	eq(#w.window.picks, 0, "the Worktree key asks nothing")
	yes(cardAtTab ~= nil, "the block showed its worktree card when the tab was opened")
	eq(cardAtTab.p.tone, "success", "a ready one")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	has(cardText(b), s.target, "and the card says where the worktree is")
	same(w.window.switches, { 1 }, "the source session is switched to")
	eq(#w.window.launches, 1, "one tab: the repeated click opened none")
	eq(w.window.launches[1].cwd, s.target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "PR #5 · r", "tab name")
	w.click(prLink("worktree", "o/r", 5))
	has(w.toasts[5].text, "o/r#5", "after it finished a click starts again")
	w.flush()
	has(w.toasts[6].sub, "Reused", "the second run reuses")
	has(w.toasts[6].sub, "Current", "and is current")
	has(w.toasts[6].sub, "Clean", "and clean")
	eq(commandsOf(b, "update"), nil, "no update commands: the worktree is current")
	yes(findKey(cardOf(b), "remove", "item") ~= nil, "the card offers to remove it")
	-- the card's Open in new tab is the Worktree button: its click reaches the window's flow, which opens another tab
	local tabs = #w.window.launches
	pressCard(b, "open")
	w.flush()
	eq(#w.window.launches, tabs + 1, "a tab opens in the worktree")
	eq(w.window.launches[tabs + 1].cwd, s.target, "at the worktree's path")
end)

windowCase("window: Agent lists the saved prompts of the active filter first, runs the pick with {url} replaced in the PR's worktree without asking, recent first next time", function(w: World)
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({ "p1", "p2" }) },
	}) })
	local s = agentScene(w)
	savePrompts(w, {
		promptOf("p1", "Review", "Review {url}\nthen summarise"),
		promptOf("p2", "Triage", "Triage {url}, then triage {url} again"),
		promptOf("p3", "Others", "Check the tests"),
		promptOf("p4", "Blank", ""),
		promptOf("p5", "Orphan", "Look into {url}"),
	})
	w.window.choose = "Review"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local items = promptPicks(w)[1].items
	local labels: { string } = {}
	for _, item in items do
		table.insert(labels, item.label)
	end
	same(labels, { "Type a prompt…", "Review", "Triage" }, "typing, then only the prompts the view lists; one it leaves out and one with no text are not offered")
	eq(items[1].detail, "Send your own text", "typing says what it does")
	eq(items[2].group, "For My PRs", "a prompt of a restricted view has that view's group")
	eq(items[2].detail, "Review {url}", "and its first line as its detail")
	eq(items[3].group, "For My PRs", "so does the next")
	eq(#w.window.picks, 1, "nothing but the picker is asked")
	eq(#w.window.agents, 1, "one agent")
	eq(w.window.agents[1].command, nil, "a prompt without a model runs the agent setting's command")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5\nthen summarise", "the pick runs with {url} replaced by the PR's link")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "its branch tracks the PR's head branch, so git pull and gh there find the PR")
	same(w.kv.get("agent-recent"), { "Review" }, "the pick is kept in kv, which outlives a plugin VM reboot")
	w.window.choose = "Start another agent" -- a live agent is offered first; the menu itself is dismissed
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local again = promptPicks(w)[2].items
	eq(again[1].label, "Review", "the last pick comes first")
	eq(again[1].group, "Recent", "under Recent")
	eq(#w.window.agents, 1, "a dismissed picker runs nothing")
	w.window.choose = { "Start another agent", "Triage" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[2].prompt, "Triage https://github.com/o/r/pull/5, then triage https://github.com/o/r/pull/5 again", "every {url} is replaced")
	same(w.kv.get("agent-recent"), { "Triage", "Review" }, "the newest pick leads")
	w.window.choose, w.window.typed = { "Start another agent", "Type a prompt…" }, "Fix the flaky test in {url}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[3].prompt, "Fix the flaky test in https://github.com/o/r/pull/5", "typed text gets {url} replaced too")
	w.window.choose, w.window.typed = { "Start another agent", "Type a prompt…" }, "{owner}/{repo}#{number} {title} by {author}: {branch} into {base} of {remote}, {nope}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[4].prompt, "o/r#5 Add a feature by ann: feature into main of origin, {nope}", "every variable is filled from a fresh read of the PR and its worktree's remote; an unknown one stays")
end)

windowCase("window: with no prompts saved, a pull request offers Review, Address feedback and Watch, each run in its worktree with every variable it names filled in", function(w: World)
	local s = agentScene(w)
	for i, name in { "Review", "Address feedback", "Watch" } do
		w.window.choose = { "Start another agent", name }
		w.click(prLink("agent", "o/r", 5))
		w.flush()
		local agent = w.window.agents[i]
		eq(agent.cwd, s.target, name .. " runs in the PR's worktree")
		has(agent.prompt, "Branches: head `feature` → base `main` (base remote `origin`)", name .. " names the branches and the checkout's remote")
		lacks(agent.prompt, "{", name .. " has every variable it names filled in")
	end
	local labels: { string } = {}
	for _, item in promptPicks(w)[1].items do
		table.insert(labels, item.label)
	end
	same(labels, { "Type a prompt…", "Review", "Address feedback", "Watch" }, "typing, then the defaults")
	eq(w.kv.get("prompts-prs"), nil, "running them saves nothing")
end)

windowCase("window: Recent lists only prompts that are still saved, and with none saved the picker says where to write them", function(w: World)
	agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	w.window.choose = "Review"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	w.window.choose = { "Start another agent", "Triage" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	same(w.kv.get("agent-recent"), { "Triage", "Review" }, "two picks are remembered")
	savePrompts(w, { promptOf("p2", "Triage", "Triage {url}") })
	w.window.choose = "Start another agent"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local rows = promptPicks(w)[3].items
	local labels: { string } = {}
	local groups: { string } = {}
	for _, item in rows do
		table.insert(labels, item.label)
		table.insert(groups, item.group or "")
	end
	same(labels, { "Triage", "Type a prompt…", "Triage" }, "a prompt deleted since is no longer a recent row")
	same(groups, { "Recent", "", "All actions" }, "the recent one leads, then typing, then the saved prompts")
	savePrompts(w, {})
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local none = promptPicks(w)[4].items
	eq(#none, 1, "with nothing saved only typing is offered")
	eq(none[1].label, "Type a prompt…", "typing")
	eq(none[1].detail, "Save actions in Settings › Actions", "which says where to write prompts")
end)

windowCase("window: saved prompts the host cannot read are reported, and a prompt can still be typed", function(w: World)
	agentScene(w)
	w.kv.put("prompts-prs", "garbage")
	w.window.choose, w.window.typed = "Type a prompt…", "Look at {url}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[1].level, "error", "the user is told")
	eq(w.toasts[1].text, "Saved actions are not listed", "what is missing")
	has(w.toasts[1].sub, "malformed", "and why")
	eq(#promptPicks(w)[1].items, 1, "the picker still opens")
	eq(w.window.agents[1].prompt, "Look at https://github.com/o/r/pull/5", "to type a prompt")
	eq(w.kv.get("prompts-prs"), "garbage", "and the saved prompts are untouched")
end)

windowCase("window: a card button's run link runs its prompt with every {url} replaced in the PR's worktree, with its model, as the prompt is saved now", function(w: World)
	local s, b = agentScene(w)
	local review = promptOf("p1", "Review", "Review {url}\nthen summarise {url}")
	review.model = "@slow"
	savePrompts(w, { review, promptOf("p2", "Triage", "Triage {url}") })
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "menu", "worktree" }, "the host is asked what the prompt is, then for the worktree")
	eq(requestsSent(w)[1].only, "p1", "and the request for the prompt names it")
	eq(#w.window.picks, 0, "nothing is asked: the button names its prompt")
	eq(#w.window.agents, 1, "the agent starts")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5\nthen summarise https://github.com/o/r/pull/5", "with every {url} replaced by the PR's link")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	eq(w.window.agents[1].command, "omp --model @slow", "as omp with the prompt's model, a role alias here")
	savePrompts(w, { promptOf("p1", "Review", "Review quickly: {url}") })
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(w.window.agents[2].prompt, "Review quickly: https://github.com/o/r/pull/5", "a prompt edited since the card was drawn runs as it is saved now")
	eq(w.window.agents[2].command, nil, "its model removed, the agent setting's command runs it")
	local bad = promptOf("p1", "Review", "Review {url}")
	bad.model = "opus; rm -rf ~"
	savePrompts(w, { bad })
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(#w.window.agents, 2, "a model that is no model name starts nothing, as it would go on a command line")
	eq(w.toasts[#w.toasts].level, "error", "the user is told")
end)

windowCase("window: a PR prompt set to the main checkout starts its agent in a new tab at the checkout, with the PR's details and no worktree", function(w: World)
	local s, b = agentScene(w)
	local review = promptOf("p1", "Review", "Review {url}: {title} by {author}, {branch} into {base}")
	review.worktree = false
	savePrompts(w, { review })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(requestsSent(w)[2].worktree, false, "the request says no worktree")
	eq(#w.window.agents, 1, "the agent starts")
	eq(w.window.agents[1].cwd, s.root, "in the main checkout")
	has(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5: ", "with the PR's variables filled in")
	lacks(w.window.agents[1].prompt, "{", "every one of them")
	eq(#w.window.runs, 0, "no setup commands ran")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made")
	eq(cardOf(b), nil, "nor noted on the block")
end)

windowCase("window: a prompt set to open in this tab starts its agent beside the queue, a new worktree's setup in a tab of its own", function(w: World)
	local s, b = agentScene(w)
	local review = promptOf("p1", "Review", "Review {url}")
	review.split = true
	savePrompts(w, { review })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	b.render()
	cardSurface(w, b)
	local agent: number? = nil
	local start = w.cx.agents.start
	w.cx.agents.start = function(self: any, opts: any): number
		agent = start(self, opts)
		return agent :: number
	end
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(w.window.agents[1].cwd, s.target, "the agent runs in the worktree")
	local queueTab = w.window.panes[1].tab
	eq(w.window.panes[agent :: number].tab, queueTab, "as a block in the queue's tab")
	eq(#w.window.runs, 1, "the setup commands ran")
	yes(w.window.panes[w.window.runs[1].pane].tab ~= queueTab, "in a tab of their own")
	eq(w.toasts[#w.toasts].text, "Agent started beside the queue for o/r#5", "the toast says where")
end)

windowCase("window: a card button of a prompt the picker's size budget would cut still runs it, the request naming the prompt", function(w: World)
	local s, b = agentScene(w)
	local text = string.rep("x", 7900) .. " {url}"
	local list: { { [string]: any } } = {}
	for i = 1, 8 do
		table.insert(list, promptOf("p" .. i, "Big " .. i, text))
	end
	savePrompts(w, list)
	b.render()
	cardSurface(w, b)
	request(b, "all", { op = "menu" })
	yes(#answerOf(b, "all").items < 8, "the whole list does not fit one answer")
	w.click(runLink("o/r", 5, "p8"))
	w.flush()
	local sent = requestsSent(w)[1]
	eq(sent.op, "menu", "the host is asked about the prompt")
	eq(sent.only, "p8", "by its id alone")
	eq(#w.window.agents, 1, "the eighth button runs its prompt")
	eq(w.window.agents[1].prompt, string.rep("x", 7900) .. " https://github.com/o/r/pull/5", "with its whole text")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
end)

windowCase("window: a run link the card does not show is refused before anything is asked", function(w: World)
	local _, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	b.render()
	cardSurface(w, b)
	local sent, ran = #w.window.events, #w.calls
	local function refused(url: string, text: string, what: string)
		local said = #w.toasts
		w.click(url)
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		eq(w.toasts[#w.toasts].text, text, what .. ": what is wrong")
	end
	local unlisted = "Plotroom: that pull request is no longer listed"
	refused(runLink("o/r", 5, "p9"), unlisted, "a prompt with no button")
	refused(runLink("o/r", 6, "p1"), unlisted, "another pull request")
	refused(runLink("x/r", 5, "p1"), unlisted, "another repository")
	refused("plotroom://github/run/o/r/5", "Plotroom: malformed link", "a link with no prompt")
	refused(runLink("o/r", 5, "p-1"), "Plotroom: malformed link", "an id that is no word")
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.window.picks, 0, "and nothing was offered")
end)

windowCase("window: a prompt no longer offered once the card was drawn gives a toast and runs nothing", function(w: World)
	local _, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	b.render()
	cardSurface(w, b)
	-- Saves `list` instead, then clicks the first prompt's button on the card as it was drawn.
	local function gone(what: string, list: { { [string]: any } })
		savePrompts(w, list)
		local said = #w.toasts
		w.click(runLink("o/r", 5, "p1"))
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		eq(w.toasts[#w.toasts].text, "That action is no longer offered here", what .. ": what is wrong")
		eq(#w.window.agents, 0, what .. ": no agent")
		eq(cardOf(b), nil, what .. ": and no worktree was prepared")
	end
	gone("deleted", { promptOf("p2", "Triage", "Triage {url}") })
	gone("emptied", { promptOf("p1", "Review", "") })
end)

windowCase("window: the palette command Run an agent follows the card's unseen Agent link to the picker", function(w: World)
	local _, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	b.render()
	cardSurface(w, b)
	w.window.choose = "Review"
	w.command("agent-selected")
	w.flush()
	eq(#promptPicks(w), 1, "the picker opens")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5", "and the pick runs")
end)

windowCase("window: a new worktree runs its repository's setup commands in its tab; a reused one does not", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install", "  ", "make" }), ["x/y"] = array({ "nope" }) })
	linkQueue(w, s)
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(#w.window.runs, 1, "setup runs once")
	eq(w.window.runs[1].text, "pnpm install && make\r", "this repository's commands, blanks dropped, stopping at the first failure")
	eq(w.window.panes[w.window.runs[1].pane].cwd, s.target, "typed into the worktree's new tab")
	has(w.toasts[#w.toasts].sub, "running setup", "the toast says so")
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(#w.window.runs, 1, "a reused worktree is not set up again")
end)

windowCase("window: an agent on a new worktree joins the tab where its setup runs", function(w: World)
	local s = agentScene(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	w.window.choose, w.window.typed = "Type a prompt…", "go"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(#w.window.runs, 1, "setup runs")
	local shell = w.window.panes[w.window.runs[1].pane]
	eq(shell.cwd, s.target, "in a shell in the worktree")
	eq(w.window.agents[1].prompt, "go", "the agent starts")
	local inTab = 0
	for _, p in w.window.panes do
		if p.tab == shell.tab then
			inTab += 1
		end
	end
	eq(inTab, 2, "and joins the setup shell's tab")
end)

windowCase("window: an answer that arrives without a window context starts nothing", function(w: World)
	agentScene(w)
	local ran = #w.calls
	w.window.typed = "go"
	w.window.decide = function(_opts: any): (string?, boolean?)
		return "Type a prompt…", true
	end
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(#w.calls, ran, "the picker, answered without a context, ran nothing")
	eq(#requestsSent(w), 1, "and asked the host for nothing beyond the prompts")
	eq(#w.toasts, 0, "or said anything")
end)

windowCase("window: a failing mkdir reports the failure, releases the PR, and the next click works", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.fs.denyMkdir["/wt"] = "permission denied"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, "/wt", "names the path")
	has(w.toasts[2].sub, "permission denied", "and the reason")
	eq(cardOf(b).p.tone, "error", "the failure is noted on the block for the queue preview")
	has(cardText(b), "permission denied", "with its reason")
	eq(badgeOf(b), nil, "and no badge")
	w.fs.denyMkdir["/wt"] = nil
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[4].level, "success", "the retry succeeds: the PR was released, not 'already being prepared'")
	has(w.toasts[4].text, "o/r#5", "names the pull request")
	eq(cardOf(b).p.tone, "success", "and the card follows")
end)

windowCase("window: a tab that cannot open keeps the worktree path visible, the block noting it first", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.window.newTab = "nil"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, s.target, "the path is shown")
	has(cardText(b), s.target, "and the block noted the worktree whatever its tab did")
	local raised = scene(w, worktree, "o", "q", 6)
	linkQueue(w, raised)
	w.window.newTab = "raise"
	w.click(prLink("worktree", "o/q", 6))
	w.flush()
	local last = w.toasts[#w.toasts]
	eq(last.level, "error", "a raising tab call ends the same way")
	has(last.sub, raised.target, "the path is shown")
end)

windowCase("window: a source pane that closed meanwhile gets a toast but no tab", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.click(prLink("worktree", "o/r", 5))
	w.window.panes[1] = nil
	w.flush()
	eq(w.toasts[2].level, "success", "the worktree is ready")
	has(w.toasts[2].sub, s.target, "the path is shown")
	eq(#w.window.launches, 0, "no tab")
	has(cardText(b), s.target, "and the block noted the worktree")
end)

windowCase("window: PR worktree without a checkout asks for one, then continues", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	linkQueue(w, s)
	w.kv.put("checkouts", {})
	w.window.typed = "/work/r"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	local sent = requestsSent(w)
	eq(#sent, 3, "the worktree request, the checkout it led to, then the worktree request again")
	eq(sent[1].op, "worktree", "first the worktree")
	eq(sent[2].op, "checkout", "then the folder the user gave")
	eq(sent[2].repo, "o/r", "for the repository")
	eq(sent[2].path, "/work/r", "and that path")
	eq(sent[3].op, "worktree", "and the worktree once more")
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the checkout is saved under the lowercase repository")
	eq(w.toasts[#w.toasts].level, "success", "the worktree is made")
	has(w.toasts[#w.toasts].text, "o/r#5", "for the pull request")
	eq(countLog(s.git, "worktree add"), 1, "once")
	w.window.typed = nil
	w.kv.put("checkouts", {})
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(#requestsSent(w), 4, "a dismissed question sends nothing more")
	eq(countLog(s.git, "worktree add"), 1, "and creates nothing")
end)

windowCase("window: any worktree failure is noted and toasted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	s.gh.meta["o/r#5"] = nil
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, "not visible to this GitHub account", "gh's classified reason")
	eq(cardOf(b).p.tone, "error", "noted as a failure")
	has(cardText(b), "not visible to this GitHub account", "with that reason")
end)

windowCase("window: a remote host's pane gets its worktree from its own host; stale links and foreign panes reach nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.window.remoteHost = true
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "success", "a remote host's pane is served: its block's host makes the worktree")
	has(cardText(b), s.target, "and its block shows it")
	local sent, ran, said = #w.window.events, #w.calls, #w.toasts
	w.click(prLink("worktree", "o/r", 6))
	eq(w.toasts[said + 1].level, "error", "a link the surface does not list")
	w.click("plotroom://github/worktree/o/../5")
	eq(w.toasts[said + 2].level, "error", "malformed")
	w.window.panes[1] = { block = "plugin.terminal", cwd = "/", tab = 1 }
	w.click(prLink("worktree", "o/r", 5))
	eq(w.toasts[said + 3].level, "error", "a pane that is not Plotroom")
	w.flush()
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "no process was started")
end)

windowCase("window: a worktree.open that raises releases the PR and says so", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	linkQueue(w, s)
	local patched: any = worktree
	local real = patched.open
	patched.open = function()
		error("boom", 0)
	end
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, "boom", "reason")
	patched.open = real
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[4].level, "success", "released: the retry works, it is not 'already being prepared'")
	has(w.toasts[4].text, "o/r#5", "names the pull request")
end)

windowCase("window: a legitimate .github repository gets a worktree through the whole link flow", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "github", ".github", 1)
	local b = linkQueue(w, s)
	w.click(prLink("worktree", "github/.github", 1))
	w.flush()
	eq(w.toasts[2].level, "success", "level")
	has(w.toasts[2].text, "github/.github#1", "names the pull request")
	has(cardText(b), "/wt/plotroom-github_.github-pr-1", "the directory keeps the real name")
	has(cardText(b), "feature", "the card shows the pull request's own head branch")
	eq(s.git.refs["refs/plotroom-pr/github/%2Egithub/pr-1"], sha("b"), "so is the fetched ref")
end)

windowCase("window: a block whose host does not announce this protocol is never asked, and the user is told", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local function refused(what: string)
		local said = #w.toasts
		w.click(prLink("worktree", "o/r", 5))
		w.click(prLink("agent", "o/r", 5))
		eq(#w.toasts, said + 2, what .. ": each click is answered")
		for i = said + 1, said + 2 do
			eq(w.toasts[i].level, "error", what .. ": level")
			has(w.toasts[i].text, "another version", what .. ": the user is told")
		end
		eq(#w.window.events + #w.window.picks + #w.calls, 0, what .. ": nothing was sent, asked or run")
	end
	refused("a view without the marker")
	local surface: any = w.window.surfaces[1]
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = "2", hidden = true } } } }
	refused("another protocol's marker")
end)

windowCase("window: a request its block's host never answers gives up with a toast, and an answer that comes late is ignored", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local surface: any = w.window.surfaces[1]
	local nodes: { any } = { { id = "main.rpc", p = { text = "17", hidden = true } } }
	surface.main = { id = "main", c = nodes }
	w.click(prLink("agent", "o/r", 5))
	w.click(prLink("worktree", "o/r", 5))
	local sent = requestsSent(w)
	eq(#sent, 2, "two requests are out")
	eq(sent[1].op, "menu", "the list")
	eq(sent[2].op, "worktree", "and the worktree")
	local function gaveUp(): number
		local n = 0
		for _, t in w.toasts do
			if string.find(t.text, "did not answer", 1, true) then
				n += 1
			end
		end
		return n
	end
	w.click("plotroom://rpc/" .. sent[1].id)
	w.advance(20 * 1000)
	eq(gaveUp(), 0, "a link announcing an answer that is not on screen leaves the list waited for")
	w.advance(20 * 1000)
	eq(gaveUp(), 1, "the list is given up after a while")
	eq(w.toasts[#w.toasts].level, "error", "with an error")
	w.advance(60 * 1000)
	eq(gaveUp(), 1, "a worktree takes longer: it is still waited for")
	w.advance(5 * 60 * 1000)
	eq(gaveUp(), 2, "and given up too in the end")
	local picks, tabs, said = #w.window.picks, #w.window.launches, #w.toasts
	table.insert(nodes, { id = "main.r" .. sent[1].id, p = { text = jsonEncode({ items = { { label = "/late", send = "/late" } } }), hidden = true } })
	table.insert(nodes, { id = "main.r" .. sent[2].id, p = { text = jsonEncode({ path = "/wt/late", summary = "Created", created = true, current = true }), hidden = true } })
	w.click("plotroom://rpc/" .. sent[1].id)
	w.click("plotroom://rpc/" .. sent[2].id)
	w.flush()
	eq(#w.window.picks, picks, "a late list opens no picker")
	eq(#w.window.launches, tabs, "a late worktree opens no tab")
	eq(#w.toasts, said, "and says nothing")
end)

windowCase("window: an answer already on screen is found by polling even when its link never arrives", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local surface: any = w.window.surfaces[1]
	local nodes: { any } = { { id = "main.rpc", p = { text = "17", hidden = true } } }
	surface.main = { id = "main", c = nodes }
	w.click(prLink("agent", "o/r", 5))
	local sent = requestsSent(w)
	eq(#sent, 1, "the list is requested")
	local picks = #w.window.picks
	table.insert(nodes, { id = "main.r" .. sent[1].id, p = { text = jsonEncode({ items = { { label = "/go", send = "/go" } } }), hidden = true } })
	w.advance(1000)
	eq(#w.window.picks, picks + 1, "the list opens without any rpc link")
	w.advance(60 * 1000)
	for _, t in w.toasts do
		lacks(t.text, "did not answer", "and the request is not given up")
	end
end)

-- ---- github.luau

local function always(): boolean
	return true
end

local function checkRun(name: string, status: string, conclusion: string?, startedAt: string?, extra: { [string]: any }?): { [string]: any }
	local node: { [string]: any } = { name = name, status = status, conclusion = conclusion, startedAt = startedAt }
	if extra then
		for k, v in extra do
			node[k] = v
		end
	end
	return node
end

case("github.gh: a token that times out is 'failed' after one spawn, a refusal is 'auth', a token travels only in GH_TOKEN", function(w: World)
	local github = w.load("github") :: Github
	local script: Responder = function(_call: Call): Reply?
		return { delay = 40000 }
	end
	w.respond(function(call: Call): Reply?
		return script(call)
	end)
	local outcome: { out: string?, problem: any } = { out = nil, problem = nil }
	local function ask()
		outcome.out, outcome.problem = nil, nil
		github.gh({ "api", "user" }, function(out, problem, _cx, _raw)
			outcome.out, outcome.problem = out, problem
		end, "victim")
		w.flush()
		w.advance(30000)
	end
	ask()
	eq(outcome.problem.kind, "failed", "a timeout is retryable, not 'not signed in'")
	has(outcome.problem.message, "30 seconds", "message gives the timeout")
	eq(#w.calls, 1, "no gh call after a timed-out token")
	script = function(_call: Call): Reply?
		return { status = 1, stderr = "no such user\n" }
	end
	ask()
	eq(outcome.problem.kind, "auth", "a definite refusal")
	has(outcome.problem.message, "victim", "message names the account")
	script = function(call: Call): Reply?
		if call.argv[2] == "auth" then
			return { stdout = "tok\n" }
		end
		return { stdout = "ok" }
	end
	local before = #w.calls
	ask()
	eq(outcome.out, "ok", "output")
	eq(#w.calls - before, 2, "token, then the command")
	same(w.calls[before + 1].argv, { "gh", "auth", "token", "--hostname", "github.com", "--user", "victim" }, "token argv")
	eq(w.calls[before + 1].env.GH_TOKEN, nil, "the token call has no token")
	same(w.calls[before + 2].argv, { "gh", "api", "user" }, "command argv")
	eq(w.calls[before + 2].env.GH_TOKEN, "tok", "the token is in the environment only")
end)

case("github.runs: same-named checks of different suites are independent rows, the failing one stays visible", function(w: World)
	local github = w.load("github") :: Github
	local runs = github.runs({
		checkRun("test", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { id = "CR1", checkSuite = { id = "S1" } }),
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T01:00:00Z", { id = "CR2", checkSuite = { id = "S2" } }),
	})
	eq(#runs, 2, "rows")
	eq(runs[1].status, "failure", "failure first")
	eq(runs[2].status, "success", "then the pass")
end)

case("github.runs: attempts of one check in one suite collapse to the newest, a queued re-run counts as newest", function(w: World)
	local github = w.load("github") :: Github
	local failing = checkRun("build", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" } })
	local queued = checkRun("build", "QUEUED", nil, nil, { checkSuite = { id = "S1" } })
	for _, order in { { failing, queued }, { queued, failing } } do
		local runs = github.runs(order)
		eq(#runs, 1, "one row")
		eq(runs[1].status, "pending", "the queued re-run wins")
		eq(runs[1].detail, "Queued", "detail")
	end
	local passed = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T01:00:00Z", { checkSuite = { id = "S1" } })
	for _, order in { { failing, passed }, { passed, failing } } do
		local runs = github.runs(order)
		eq(#runs, 1, "one row")
		eq(runs[1].status, "success", "the later attempt wins in either order")
	end
	local stale = checkRun("build", "IN_PROGRESS", nil, "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" } })
	eq(github.runs({ stale, passed })[1].status, "success", "a newer completed attempt beats an older running one")
	local required = checkRun("build", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" }, isRequired = true })
	local optional = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T01:00:00Z", { checkSuite = { id = "S1" }, isRequired = false })
	local merged = github.runs({ required, optional })
	eq(#merged, 1, "one row")
	eq(merged[1].required, true, "required when any attempt was")
end)

case("github.about: merge state, reviewers (asked again wins) and a capped description from untrusted JSON", function(w: World)
	local github = w.load("github") :: Github
	local a = github.about({
		mergeable = "MERGEABLE",
		merge = "BEHIND",
		body = "Fixes #1",
		reviews = array({ { login = "ann", state = "APPROVED" }, { login = "bob", state = "CHANGES_REQUESTED" }, { login = "x y", state = "APPROVED" }, { login = "pat", state = "PENDING" } }),
		requested = array({ "bob", "core-team", NULL, 5 }),
	})
	eq(a.merge, "behind", "mergeStateStatus reads as its word")
	same(a.reviews, {
		{ login = "ann", state = "approved" },
		{ login = "bob", state = "requested" },
		{ login = "core-team", state = "requested" },
	}, "verdicts by login; a reviewer asked again is requested; a malformed login, a pending review and non-logins are dropped")
	eq(a.body, "Fixes #1", "the description")
	eq(github.about({ mergeable = "CONFLICTING", merge = "BLOCKED" }).merge, "conflicts", "a conflict wins over the merge state")
	eq(github.about({ merge = "SOMETHING_NEW" }).merge, "unknown", "an unknown state is unknown")
	eq(github.about(nil).merge, "unknown", "and so is nothing at all")
	local long = github.about({ body = string.rep("é", 20005) }).body
	eq(utf8.len(long), 20003, "a long description is cut at 20000 characters, on a character boundary, and marked")
end)

case("github.runs: entries without a suite are independent unless they are the same node", function(w: World)
	local github = w.load("github") :: Github
	local plain = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z")
	eq(#github.runs({ plain, plain, plain }), 3, "no identity at all: every entry is a row")
	local node = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "N1" })
	eq(#github.runs({ node, node }), 1, "the same node id twice is one entry")
	local mixed = github.runs({
		{ context = "build", state = "SUCCESS" },
		checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" } }),
	})
	eq(#mixed, 2, "a status context and a check run are separate even with one name")
end)

case("github.runs: a name two checks share is prefixed with its workflow or app", function(w: World)
	local github = w.load("github") :: Github
	local runs = github.runs({
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "1", checkSuite = { id = "S1", workflowRun = { workflow = { name = "CI" } } } }),
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "2", checkSuite = { id = "S2", workflowRun = { workflow = { name = "Lint" } } } }),
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "3", checkSuite = { id = "S3", app = { name = "Vercel" } } }),
		checkRun("unique", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "4", checkSuite = { id = "S4", workflowRun = { workflow = { name = "CI" } } } }),
	})
	local names: { string } = {}
	for _, run in runs do
		table.insert(names, run.name)
	end
	same(names, { "CI / test", "Lint / test", "Vercel / test", "unique" }, "names")
end)

case("github.parseResponse: only plain bounded integers and IMF dates are believed", function(w: World)
	local github = w.load("github") :: Github
	local function retry(value: string): number?
		local q: any = github.parseResponse("HTTP/2.0 429 Too Many Requests\r\nRetry-After: " .. value .. "\r\n\r\n{}", 1000)
		return if q then q.retryUntil else nil
	end
	for _, bad in { "inf", "nan", "0x10", "1e3", "-5", "2.5", "", "99999999999" } do
		eq(retry(bad), nil, "Retry-After '" .. bad .. "' is ignored")
	end
	eq(retry("120"), 1120, "seconds")
	eq(retry("99999999"), 1000 + 86400, "capped at a day")
	eq(retry("Thu, 01 Jan 1970 00:17:40 GMT"), 1060, "IMF-fixdate")
	local q: any = github.parseResponse("HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 5\r\nX-Ratelimit-Reset: inf\r\n\r\n{}", 1000)
	eq(q.remaining, 5, "a plain integer is read")
	eq(q.reset, nil, "inf is not a reset time")
end)

case("github.classify: statuses map to the pause kinds the host acts on", function(w: World)
	local github = w.load("github") :: Github
	local function kind(status: number, stderr: string, timedOut: boolean?): string
		return github.classify({ status = status, stdout = "", stderr = stderr, timed_out = timedOut == true }).kind
	end
	eq(kind(1, "gh: Bad credentials (HTTP 401)\n"), "auth", "401")
	eq(kind(4, ""), "auth", "gh exit 4")
	eq(kind(1, "gh: Resource not accessible by integration (HTTP 403)\n"), "auth", "403")
	eq(kind(1, "gh: Not Found (HTTP 404)\n"), "not-found", "404")
	eq(kind(1, "gh: Validation Failed (HTTP 422)\n"), "invalid", "422")
	eq(kind(1, "gh: API rate limit exceeded for user ID 1.\n"), "rate-limit", "primary limit")
	eq(kind(1, "gh: You have exceeded a secondary rate limit (HTTP 403)\n"), "rate-limit", "secondary limit")
	eq(kind(1, "gh: HTTP 429\n"), "rate-limit", "429")
	eq(kind(-1, "", true), "failed", "timeout")
	eq(kind(1, "gh: something broke\n"), "failed", "anything else")
end)

type SearchOut = { result: any, problem: any, spent: number?, calls: number }

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

case("github.search: a count GitHub caps loads ten pages of 100 and is partial", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 1000)
	gh.total.octocat = 5000
	local out = runSearch(w, github, nil)
	eq(#gh.requests, 10, "gh calls")
	eq(#out.result.prs, 1000, "PRs")
	eq(out.result.total, 5000, "total")
	eq(out.result.complete, false, "complete")
	eq(out.spent, 10, "spent")
end)

case("github.search: complete means every counted PR arrived", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 250)
	local full = runSearch(w, github, nil)
	eq(#gh.requests, 3, "three pages")
	eq(#full.result.prs, 250, "PRs")
	eq(full.result.complete, true, "complete")
	gh.requests = {}
	gh.items.octocat = manyItems("o/r", 2)
	gh.total.octocat = 5
	local short = runSearch(w, github, nil)
	eq(#short.result.prs, 2, "the PRs that arrived are kept")
	eq(short.result.complete, false, "fewer PRs than counted is partial")
	gh.items.octocat = {}
	gh.total.octocat = 0
	local empty = runSearch(w, github, nil)
	eq(#empty.result.prs, 0, "no PRs")
	eq(empty.result.complete, true, "an empty search is complete")
end)

case("github.search: a pull request carries the commit its head branch is at: asked of GitHub, kept lowercase, and only when it is 40 hex digits", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function item(n: number, head: any): { [string]: any }
		return searchItem(n, "o/r", EPOCH - n * 60, { headSha = head })
	end
	gh.items.octocat = {
		item(1, sha("a")),
		item(2, string.rep("AB", 20)),
		item(3, string.rep("a", 39)),
		item(4, string.rep("g", 40)),
		item(5, 12345),
		item(6, NULL),
		searchItem(7, "o/r", EPOCH - 7 * 60),
	}
	local out = runSearch(w, github, nil)
	local argv = gh.requests[1].call.argv
	has(gh.requests[1].fields.query, "headRefOid", "the search selects the head commit")
	has(argv[(table.find(argv, "--jq") :: number) + 1], "headSha:.headRefOid", "and the filter hands it over as headSha")
	local got: { string? } = {}
	for i, pr in out.result.prs do
		got[i] = pr.headSha
	end
	eq(got[1], sha("a"), "a full commit id")
	eq(got[2], string.rep("ab", 20), "is lowercased")
	eq(got[3], nil, "too short")
	eq(got[4], nil, "not hexadecimal")
	eq(got[5], nil, "not text")
	eq(got[6], nil, "null")
	eq(got[7], nil, "absent")
	eq(#out.result.prs, 7, "none of them is lost for it")
end)

case("github.search: a pull request carries the owner of the fork its head branch lives in: asked of GitHub, and kept only as a login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function item(n: number, fork: any): { [string]: any }
		return searchItem(n, "o/r", EPOCH - n * 60, { fork = fork })
	end
	gh.items.octocat = {
		item(1, "bob"),
		item(2, "bob-2"),
		item(3, "not a login"),
		item(4, "a/b"),
		item(5, ""),
		item(6, 12345),
		item(7, NULL),
		searchItem(8, "o/r", EPOCH - 8 * 60),
	}
	local out = runSearch(w, github, nil)
	local argv = gh.requests[1].call.argv
	has(gh.requests[1].fields.query, "isCrossRepository", "the search asks whether the head is in another repository")
	has(gh.requests[1].fields.query, "headRepositoryOwner { login }", "and who owns it")
	has(argv[(table.find(argv, "--jq") :: number) + 1], "fork:(if .isCrossRepository then (.headRepositoryOwner.login // .author.login) else null end)", "the filter hands that owner over as fork (the author when the fork is gone), and nothing for a branch of the repository itself")
	local got: { string? } = {}
	for i, pr in out.result.prs do
		got[i] = pr.fork
	end
	eq(got[1], "bob", "a login")
	eq(got[2], "bob-2", "with a dash")
	eq(got[3], nil, "a name with spaces is no login")
	eq(got[4], nil, "nor one with a slash")
	eq(got[5], nil, "an empty one")
	eq(got[6], nil, "a number")
	eq(got[7], nil, "null: the head is in the repository itself")
	eq(got[8], nil, "absent")
	eq(#out.result.prs, 8, "none of them is lost for it")
end)

case("github.search: an empty page with a cursor, or a cursor that did not advance, stops the scan as partial", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 1000)
	gh.total.octocat = 5000
	local seen = 0
	gh.override = function(req: GhReq): Reply?
		if req.kind ~= "search" then
			return nil
		end
		seen += 1
		if seen == 2 then
			return { stdout = jsonEncode({ total = 5000, next = "c200", cost = 1, items = array({}) }) }
		end
		return nil
	end
	local empty = runSearch(w, github, nil)
	eq(#gh.requests, 2, "gh calls")
	eq(#empty.result.prs, 100, "the first page is kept")
	eq(empty.result.complete, false, "partial")
	seen = 0
	gh.requests = {}
	local second: { any } = {}
	for i = 101, 200 do
		table.insert(second, searchItem(i, "o/r", EPOCH - i * 60))
	end
	gh.override = function(req: GhReq): Reply?
		if req.kind == "search" then
			seen += 1
			if seen == 2 then
				return { stdout = jsonEncode({ total = 5000, next = "c100", cost = 1, items = array(second) }) }
			end
		end
		return nil
	end
	local stuck = runSearch(w, github, nil)
	eq(#gh.requests, 2, "gh calls")
	eq(#stuck.result.prs, 200, "both pages are kept")
	eq(stuck.result.complete, false, "the repeated cursor ends the scan")
end)

case("github.search: a failing request returns its problem and no partial result", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 300)
	local seen = 0
	gh.override = function(req: GhReq): Reply?
		if req.kind ~= "search" then
			return nil
		end
		seen += 1
		if seen == 2 then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local out = runSearch(w, github, nil)
	eq(out.result, nil, "no result")
	eq(out.problem.kind, "failed", "problem kind")
	eq(out.spent, 2, "both requests were counted")
end)

case("github.search: an exhausted quota mid-scan keeps the pages that arrived as partial", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 1000)
	gh.limits.octocat = { limit = 30, remaining = 1, reset = EPOCH + 600 }
	local out = runSearch(w, github, nil)
	eq(#gh.requests, 1, "no request after the quota ran out")
	eq(#out.result.prs, 100, "the first page is kept")
	eq(out.result.complete, false, "partial")
	eq(github.wait(w.seconds(), nil), 601, "every pane waits for the reset")
end)

case("github.search: a rate limit without headers backs the account off for five minutes", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.override = function(_req: GhReq): Reply?
		return { status = 1, stderr = "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)\n" }
	end
	local out = runSearch(w, github, nil)
	eq(out.problem.kind, "rate-limit", "problem kind")
	eq(github.wait(w.seconds(), nil), 300, "backoff")
end)

case("github.search: cancellation is checked before every page and after every response", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 300)
	local before = runSearch(w, github, function(): boolean
		return false
	end)
	eq(#gh.requests, 0, "a cancelled search sends nothing")
	eq(before.problem.kind, "superseded", "problem kind")
	eq(before.spent, 0, "spent")
	gh.items.octocat = manyItems("o/r", 50) -- a single page: only the check after the response can cancel it
	local go = true
	gh.override = function(req: GhReq): Reply?
		if req.kind == "search" then
			go = false
		end
		return nil
	end
	local during = runSearch(w, github, function(): boolean
		return go
	end)
	eq(#gh.requests, 1, "no second page after the answer arrived cancelled")
	eq(during.problem.kind, "superseded", "problem kind")
	eq(during.spent, 1, "spent")
end)

case("github.search: no repo qualifier, runs as the view's login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.tokens.work = "tok-work"
	gh.items.work = manyItems("o/r", 3)
	gh.items.octocat = manyItems("o/r", 7)
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.search("work", "is:open author:@me", always, function(result, problem, spent)
		out.calls += 1
		out.result, out.problem, out.spent = result, problem, spent
	end)
	w.flush()
	eq(#out.result.prs, 3, "the work account's PRs, not the active one's")
	eq(gh.requests[1].kind, "token", "the token is read first")
	eq(gh.requests[2].kind, "search", "then the search")
	eq(gh.requests[2].fields.q, "is:open author:@me is:pr sort:updated-desc", "the view's query, no repo: qualifier")
	for _, req in gh.requests do
		eq(req.login, "work", "every request ran as the view's login")
	end
end)

case("github.search: an empty query fails asynchronously without a request", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.search(nil, "   ", always, function(result, problem, spent)
		out.calls += 1
		out.result, out.problem, out.spent = result, problem, spent
	end)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	eq(out.problem.kind, "failed", "problem kind")
	eq(out.spent, 0, "spent")
	eq(#gh.requests, 0, "nothing was sent")
end)

type ChecksOut = { runs: any, total: number?, problem: any, calls: number }

local function runChecks(github: Github, shouldContinue: (() -> boolean)?, account: string?): ChecksOut
	local out: ChecksOut = { runs = nil, total = nil, problem = nil, calls = 0 }
	github.checks("o/r", 5, account, function(runs, total, problem)
		out.calls += 1
		out.runs, out.total, out.problem = runs, total, problem
	end, shouldContinue)
	return out
end

local function nodes(count: number): { any }
	local list: { any } = {}
	for i = 1, count do
		table.insert(list, checkRun("job " .. i, "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "N" .. i }))
	end
	return list
end

case("github.checks: pages of 100 up to three, the total counts what the pages did not show", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.checks["o/r#5"] = nodes(250)
	gh.checkTotal["o/r#5"] = 400
	local out = runChecks(github, nil)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	eq(out.calls, 1, "done calls")
	eq(#gh.requests, 3, "three pages")
	eq(#out.runs, 250, "runs")
	eq(out.total, 400, "the 150 checks beyond the pages are counted")
	gh.requests = {}
	gh.checks["o/r#5"] = nodes(350)
	gh.checkTotal["o/r#5"] = nil
	local capped = runChecks(github, nil)
	w.flush()
	eq(#gh.requests, 3, "never more than three pages")
	eq(#capped.runs, 300, "runs")
	eq(capped.total, 350, "total")
end)

case("github.checks: a repeated cursor stops silently with what arrived", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.checks["o/r#5"] = nodes(300)
	local seen = 0
	gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" then
			seen += 1
			if seen == 2 then
				return { stdout = jsonEncode({ total = 300, next = "c100", nodes = array(nodes(5)) }) }
			end
		end
		return nil
	end
	local out = runChecks(github, nil)
	w.flush()
	eq(#gh.requests, 2, "gh calls")
	eq(out.problem, nil, "no problem")
	yes(#out.runs > 0, "runs")
end)

case("github.checks: a paused quota or an unusable account sends nothing, and cancellation wins everywhere", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.checks["o/r#5"] = nodes(250)
	github.record({ remaining = 0, reset = w.seconds() + 60, limit = 30 }, w.seconds(), "limited")
	local paused = runChecks(github, nil, "limited")
	eq(paused.calls, 0, "never synchronous")
	w.flush()
	eq(paused.problem.kind, "rate-limit", "problem kind")
	has(paused.problem.message, "checks resume at", "message")
	eq(#gh.requests, 0, "nothing was sent while paused")
	gh.tokens.fine = "tok-fine"
	gh.checks["o/r#5"] = nodes(250)
	local cancelled = runChecks(github, function(): boolean
		return false
	end, "fine")
	w.flush()
	eq(cancelled.problem.kind, "superseded", "cancelled before the call")
	eq(#gh.requests, 0, "nothing was sent")
	gh.checks["o/r#5"] = nodes(50) -- a single page: only the check after the response can cancel it
	local go = true
	gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" then
			go = false
		end
		return nil
	end
	local during = runChecks(github, function(): boolean
		return go
	end, "fine")
	w.flush()
	eq(during.problem.kind, "superseded", "cancelled while the first page was in flight")
	local checkCalls = 0
	for _, req in gh.requests do
		if req.kind == "checks" then
			checkCalls += 1
		end
	end
	eq(checkCalls, 1, "no second page")
	local bad: ChecksOut = { runs = nil, total = nil, problem = nil, calls = 0 }
	github.checks("not-a-repo", 5, nil, function(runs, total, problem)
		bad.runs, bad.total, bad.problem = runs, total, problem
	end)
	w.flush()
	eq(bad.problem.kind, "failed", "an unexpected repository name")
end)

case("github.pr: the head sha must be 40 hex digits and is lowercased", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local got: any = nil
	local why: any = nil
	local function ask()
		got, why = nil, nil
		github.pr("o/r", 5, nil, function(meta, problem, _cx)
			got, why = meta, problem
		end)
		w.flush()
	end
	gh.meta["o/r#5"] = { base = "o/r", sha = string.rep("A", 40), ref = "feature", state = "open" }
	ask()
	eq(got.sha, sha("a"), "lowercased")
	eq(got.base, "o/r", "base")
	eq(got.baseRef, "", "a base branch gh left out is empty, not a failed read")
	gh.meta["o/r#5"] = { base = "o/r", sha = "abc123", ref = "feature", state = "open" }
	ask()
	eq(got, nil, "a short sha is refused")
	has(why.message, "unexpected pull request metadata", "message")
end)

-- Shared by the github cases (one top-level local: regression.luau is near Luau's limit).
local ghx = {
	-- "<number>:<branch>" of every linked PR, "-" for a deleted branch: one string per PR, in order.
	brief = function(prs: any): { string }
		local out: { string } = {}
		for _, p in prs do
			table.insert(out, p.number .. ":" .. (p.branch or "-"))
		end
		return out
	end,
	-- The fake gh's requests of one kind (requestsOf is defined further down the suite).
	of = function(gh: Gh, kind: string): { GhReq }
		local out: { GhReq } = {}
		for _, req in gh.requests do
			if req.kind == kind then
				table.insert(out, req)
			end
		end
		return out
	end,
	-- github.linkedPrs once, flushed: the list, the problem and how often done ran (and whether before the call returned).
	linked = function(w: World, github: Github, ref: string, account: string?): { list: any, problem: any, calls: number, early: number }
		local out = { list = nil :: any, problem = nil :: any, calls = 0, early = 0 }
		github.linkedPrs("o/r", ref, account, function(list, problem)
			out.calls += 1
			out.list, out.problem = list, problem
		end)
		out.early = out.calls
		w.flush()
		return out
	end,
}

case("github.pr: the head's repository decides fork and forkRepo", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function ask(base: string, headRepo: string?, headOwner: string?, author: string?): any
		gh.meta["o/r#5"] = { base = base, sha = sha("a"), ref = "feature", state = "open", headRepo = headRepo, headOwner = headOwner, author = author }
		local calls, got, why = 0, nil :: any, nil :: any
		github.pr("o/r", 5, nil, function(meta, problem, _cx)
			calls += 1
			got, why = meta, problem
		end)
		w.flush()
		eq(calls, 1, "done runs once")
		eq(why, nil, "no problem")
		return got
	end
	local same1 = ask("o/r", "o/r", "o", "ann")
	eq(same1.fork, nil, "a head in the base repository is no fork")
	eq(same1.forkRepo, nil, "and names no fork repository")
	eq(same1.ref, "feature", "the head branch is still read")
	local cased = ask("o/r", "O/R", "O", "ann")
	eq(cased.fork, nil, "a head repository in another letter case is the same repository")
	eq(cased.forkRepo, nil, "so no fork repository")
	local cased2 = ask("O/r", "o/R", "o", "ann")
	eq(cased2.fork, nil, "the base's letter case does not matter either")
	eq(cased2.forkRepo, nil, "so no fork repository")
	local live = ask("o/r", "bob/r", "bob", "ann")
	eq(live.fork, "bob", "a live fork: the fork's owner")
	eq(live.forkRepo, "bob/r", "and its repository")
	local owned = ask("o/r", "bob/r", nil, "ann")
	eq(owned.fork, "bob", "the owner comes from the fork repository, not from headOwner")
	eq(owned.forkRepo, "bob/r", "so a missing headOwner does not hide the fork")
	local renamed = ask("o/r", "bob/other-name", "bob", "ann")
	eq(renamed.forkRepo, "bob/other-name", "a fork may be named differently")
	local gone = ask("o/r", nil, "carol", "ann")
	eq(gone.fork, "carol", "a deleted fork: the head's user")
	eq(gone.forkRepo, nil, "and no repository to fetch from")
	local blank = ask("o/r", "", "carol", "ann")
	eq(blank.fork, "carol", "an empty head repository is a deleted fork too")
	eq(blank.forkRepo, nil, "no repository either")
	local author = ask("o/r", nil, nil, "dave")
	eq(author.fork, "dave", "a deleted fork whose head user is unknown: the PR's author")
	eq(author.forkRepo, nil, "no repository")
	local badOwner = ask("o/r", nil, "not an owner", "dave")
	eq(badOwner.fork, "dave", "a head user that is no login falls back to the author")
	local nobody = ask("o/r", nil, nil, nil)
	eq(nobody.fork, nil, "no head user and no author: nobody to name")
	eq(nobody.forkRepo, nil, "no repository")
	local spaced = ask("o/r", "bob/my repo", "bob", "ann")
	eq(spaced.forkRepo, nil, "a head repository with a space is not a fork repository")
	eq(spaced.fork, nil, "and is not taken for a deleted fork")
	local deep = ask("o/r", "a/b/c", "bob", "ann")
	eq(deep.forkRepo, nil, "a head repository of three segments is not a fork repository")
	eq(deep.fork, nil, "and is not taken for a deleted fork")
end)

case("github.linkedPrs: an issue number reads its closing references, keeps this repository's PRs and marks deleted branches", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.linked["o/r#12"] = array({
		{ number = 9, title = "Late fix", head = "late", branch = "late", base = "o/r" },
		{ number = 4, title = "Fork PR", head = "x", branch = "x", base = "other/r" },
		{ number = 3, title = "Gone", head = "old", branch = NULL, base = "O/R" },
		{ number = 7, title = "Fix login", head = "fix-login", branch = "fix-login", base = "o/r" },
	})
	local out = ghx.linked(w, github, "12", nil)
	eq(out.early, 0, "done never runs before the call returns")
	eq(out.calls, 1, "done runs once")
	eq(out.problem, nil, "no problem")
	same(ghx.brief(out.list), { "9:late", "3:-", "7:fix-login" }, "the other repository's PR is dropped, the deleted branch is nil, the order is kept")
	eq(out.list[2].title, "Gone", "a PR whose branch is gone keeps its title")
	eq(out.list[1].base, nil, "only number, title and branch are kept")
	local sent = ghx.of(gh, "linked")
	eq(#sent, 1, "one GraphQL request")
	same({ sent[1].fields.o, sent[1].fields.r, sent[1].fields.n }, { "o", "r", "12" }, "owner, name and number are the variables")
	eq(sent[1].fields.q, nil, "and there is no search query")
	local argv = sent[1].call.argv
	same({ argv[1], argv[2], argv[3], argv[4], argv[5], argv[6] }, { "gh", "api", "graphql", "--hostname", "github.com", "-f" }, "gh api graphql on github.com")
	has(argv[7], "query=query($o: String!, $r: String!, $n: Int!)", "the issue query")
	has(argv[7], "closedByPullRequestsReferences", "reads the closing references")
	same({ argv[8], argv[9], argv[10], argv[11], argv[12], argv[13], argv[14] }, { "-f", "o=o", "-f", "r=r", "-F", "n=12", "--jq" }, "owner and name as strings, the number as an integer")
	has(argv[15], "baseRepository.nameWithOwner", "the jq keeps the base repository")
	eq(#argv, 15, "nothing else is passed")
end)

case("github.linkedPrs: a merged pull request is not offered as the issue's branch, a closed unmerged one still is", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.linked["o/r#12"] = array({
		{ number = 1, title = "Merged", head = "m", branch = "m", base = "o/r", state = "MERGED" },
		{ number = 2, title = "Closed", head = "c", branch = "c", base = "o/r", state = "CLOSED" },
		{ number = 3, title = "Open", head = "o", branch = "o", base = "o/r", state = "OPEN" },
	})
	same(ghx.brief(ghx.linked(w, github, "12", nil).list), { "2:c", "3:o" }, "only the merged one is dropped")
end)

case("github.linkedPrs: an issue number with no PRs is an empty list, and a failed or odd answer is a problem", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local none = ghx.linked(w, github, "12", nil)
	same(none.list, {}, "no closing references: an empty list")
	eq(none.problem, nil, "that is no problem")
	eq(none.calls, 1, "done runs once")
	gh.linked["o/r#12"] = array({ { number = 4, title = "Fork PR", head = "x", branch = "x", base = "other/r" } })
	local foreign = ghx.linked(w, github, "12", nil)
	same(foreign.list, {}, "only another repository's PR: an empty list")
	eq(foreign.problem, nil, "no problem")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { status = 1, stderr = "gh: Not Found (HTTP 404)\n" }
		end
		return nil
	end
	local missing = ghx.linked(w, github, "12", nil)
	eq(missing.list, nil, "a failed read has no list")
	eq(missing.problem.kind, "not-found", "gh's classification is passed through")
	eq(missing.calls, 1, "done runs once")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { status = 1, stderr = "gh: Bad credentials (HTTP 401)\n" }
		end
		return nil
	end
	local refused = ghx.linked(w, github, "12", nil)
	eq(refused.list, nil, "no list")
	eq(refused.problem.kind, "auth", "a refused sign-in is an auth problem")
	for _, odd in { "not json at all", "42", "" } do
		gh.override = function(req: GhReq): Reply?
			if req.kind == "linked" then
				return { stdout = odd }
			end
			return nil
		end
		local bad = ghx.linked(w, github, "12", nil)
		eq(bad.list, nil, "output that is no JSON array has no list: " .. odd)
		eq(bad.problem.kind, "failed", "and is a failed read: " .. odd)
		has(bad.problem.message, "unexpected pull request data", "with its message: " .. odd)
		eq(bad.calls, 1, "done runs once: " .. odd)
	end
end)

case("github.linkedPrs: a Jira key searches the repository and keeps PRs naming the key as a whole word", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function pr(n: number, title: string, head: any, base: string?, branch: any): any
		return { number = n, title = title, head = head, branch = branch, base = base or "o/r" }
	end
	gh.linked["o/r#ABC-12"] = array({
		pr(1, "Fix ABC-12: login", "x", nil, "x"),
		pr(2, "abc-12 login", "y", nil, "y"),
		pr(3, "Login", "fix/ABC-12-login", nil, "fix/ABC-12-login"),
		pr(4, "Bump ABC-123", "bump", nil, "bump"),
		pr(5, "NABC-12 thing", "n", nil, "n"),
		pr(6, "ABC-12x", "z", nil, "z"),
		pr(7, "Other", "feat/abc-12_login", nil, "feat/abc-12_login"),
		pr(8, "ABC-12 elsewhere", "e", "other/r", "e"),
		pr(9, "Mentions ABC-12.", "gone", "O/R", NULL),
		pr(10, "Unrelated", NULL, nil, "u"),
		pr(11, "Nothing", "XABC-12", nil, "XABC-12"),
		pr(12, "Nothing", "fix-ABC-1234", nil, "fix-ABC-1234"),
		pr(13, "(ABC-12)", "q", nil, "q"),
	})
	local out = ghx.linked(w, github, "ABC-12", nil)
	eq(out.early, 0, "done never runs before the call returns")
	eq(out.calls, 1, "done runs once")
	eq(out.problem, nil, "no problem")
	same(ghx.brief(out.list), { "1:x", "2:y", "3:fix/ABC-12-login", "7:feat/abc-12_login", "9:-", "13:q" }, "the key as a whole word in the title or the head branch, any letter case; ABC-123, NABC-12, ABC-12x and other repositories' PRs are dropped; a deleted branch is nil")
	eq(out.list[5].title, "Mentions ABC-12.", "a PR whose branch is gone keeps its title")
	local sent = ghx.of(gh, "linked")
	eq(#sent, 1, "one GraphQL request")
	eq(sent[1].fields.q, "repo:o/r is:pr ABC-12", "the search names the repository, pull requests and the key")
	same({ sent[1].fields.o, sent[1].fields.r, sent[1].fields.n }, { nil, nil, nil }, "no issue variables")
	local argv = sent[1].call.argv
	same({ argv[1], argv[2], argv[3], argv[4], argv[5], argv[6] }, { "gh", "api", "graphql", "--hostname", "github.com", "-f" }, "gh api graphql on github.com")
	has(argv[7], "query=query($q: String!) { search(query: $q, type: ISSUE", "the search query")
	same({ argv[8], argv[9], argv[10] }, { "-f", "q=repo:o/r is:pr ABC-12", "--jq" }, "the search text as a string")
	has(argv[11], "baseRepository.nameWithOwner", "the jq keeps the base repository")
	eq(#argv, 11, "nothing else is passed")
	gh.linked["o/r#ABC-1"] = array({ pr(1, "Fix ABC-12", "x", nil, "x"), pr(2, "Fix ABC-1", "y", nil, "y") })
	same(ghx.brief(ghx.linked(w, github, "ABC-1", nil).list), { "2:y" }, "ABC-1 is not ABC-12")
	gh.linked["o/r#abc-12"] = array({ pr(1, "ABC-12 login", "x", nil, "x") })
	same(ghx.brief(ghx.linked(w, github, "abc-12", nil).list), { "1:x" }, "a lowercase key matches the same way")
end)

case("github.linkedPrs: a Jira key search failure is passed through and no PR is listed", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.linked["o/r#ABC-12"] = array({ { number = 1, title = "ABC-12", head = "x", branch = "x", base = "o/r" } })
	same(ghx.brief(ghx.linked(w, github, "ABC-12", nil).list), { "1:x" }, "found")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { status = 1, stderr = "gh: Validation Failed (HTTP 422)\n" }
		end
		return nil
	end
	local invalid = ghx.linked(w, github, "ABC-12", nil)
	eq(invalid.list, nil, "no list")
	eq(invalid.problem.kind, "invalid", "gh's classification is passed through")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { stdout = "{oops" }
		end
		return nil
	end
	local bad = ghx.linked(w, github, "ABC-12", nil)
	eq(bad.list, nil, "no list")
	eq(bad.problem.kind, "failed", "unexpected output is a failed read")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { stdout = jsonEncode(array({})) }
		end
		return nil
	end
	local empty = ghx.linked(w, github, "ABC-12", nil)
	same(empty.list, {}, "no match is an empty list")
	eq(empty.problem, nil, "not a problem")
end)

case("github.linkedPrs: runs as the given account, else as gh's active one", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.tokens.work = "tok-work"
	gh.linked["o/r#12"] = array({ { number = 3, title = "Fix", head = "fix", branch = "fix", base = "o/r" } })
	gh.linked["o/r#ABC-12"] = array({ { number = 5, title = "ABC-12", head = "abc", branch = "abc", base = "o/r" } })
	for _, ref in { "12", "ABC-12" } do
		local as = ghx.linked(w, github, ref, "work")
		eq(#as.list, 1, "the PR is listed for " .. ref)
		eq(gh.requests[1].kind, "token", "the account's token is read first for " .. ref)
		eq(gh.requests[1].login, "work", "its owner for " .. ref)
		eq(gh.requests[2].kind, "linked", "then the PR read for " .. ref)
		eq(gh.requests[2].login, "work", "runs as that account for " .. ref)
		eq(gh.requests[2].call.env.GH_TOKEN, "tok-work", "with its token for " .. ref)
		eq(#gh.requests, 2, "nothing else for " .. ref)
		gh.requests = {}
		for _, blank in { false, true } do
			local active = ghx.linked(w, github, ref, if blank then "" else nil)
			eq(#active.list, 1, "the PR is listed as the active login for " .. ref)
			eq(#gh.requests, 1, "no token is read for " .. ref)
			eq(gh.requests[1].kind, "linked", "just the PR read for " .. ref)
			eq(gh.requests[1].login, "octocat", "as the active account for " .. ref)
			eq(gh.requests[1].call.env.GH_TOKEN, nil, "without a GH_TOKEN for " .. ref)
			gh.requests = {}
		end
		local ghost = ghx.linked(w, github, ref, "ghost")
		eq(ghost.list, nil, "an account that is not signed in lists nothing for " .. ref)
		eq(ghost.problem.kind, "auth", "an auth problem for " .. ref)
		eq(#ghx.of(gh, "linked"), 0, "and sends no PR read for " .. ref)
		gh.requests = {}
	end
end)

case("github.login: the given account answers asynchronously without calling gh", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local got: { string } = {}
	local problems = 0
	github.login("work", function(login, problem)
		table.insert(got, login or "nil")
		if problem then
			problems += 1
		end
	end)
	eq(#got, 0, "done never runs before the call returns")
	w.flush()
	same(got, { "work" }, "the account, once")
	eq(problems, 0, "no problem")
	eq(#gh.requests, 0, "gh was not asked")
	eq(#w.calls, 0, "no command ran")
end)

case("github.login: gh's active login is read once and kept", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.active = "zed"
	gh.tokens.alpha = "tok-alpha"
	local got: { string } = {}
	local function ask(account: string?)
		github.login(account, function(login, problem)
			table.insert(got, (login or "nil") .. if problem then "!" else "")
		end)
	end
	ask(nil)
	eq(#got, 0, "done never runs before the call returns")
	w.flush()
	same(got, { "zed" }, "the active account, not the first alphabetically")
	eq(#ghx.of(gh, "accounts"), 1, "one accounts request")
	ask(nil)
	ask("")
	eq(#got, 1, "a known answer is still asynchronous")
	w.flush()
	same(got, { "zed", "zed", "zed" }, "an empty account is no account")
	eq(#ghx.of(gh, "accounts"), 1, "the second and third read nothing")
	eq(#gh.requests, 1, "and nothing else was asked")
end)

case("github.login: an Enterprise Managed User login with an underscore is an account", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.active = "mona-cat_octo"
	gh.tokens["mona-cat_octo"] = "tok-emu"
	local got: { string } = {}
	github.login(nil, function(login, problem)
		table.insert(got, (login or "nil") .. if problem then "!" else "")
	end)
	w.flush()
	same(got, { "mona-cat_octo" }, "the login is kept whole")
end)

case("github.login: callers during the read share one accounts request", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local got: { string } = {}
	for _ = 1, 2 do
		github.login(nil, function(login, _problem)
			table.insert(got, login or "nil")
		end)
	end
	w.flush()
	same(got, { "octocat", "octocat" }, "both callers are answered")
	eq(#ghx.of(gh, "accounts"), 1, "from one request")
end)

case("github.login: a gh that fails or lists no hosts is a problem with no login, and is read again next time", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local calls, login, problem = 0, "unset" :: any, nil :: any
	local function ask()
		calls, login, problem = 0, "unset", nil
		github.login(nil, function(l, p)
			calls += 1
			login, problem = l, p
		end)
		w.flush()
		eq(calls, 1, "done runs once")
	end
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { status = 1, stderr = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n" }
		end
		return nil
	end
	ask()
	eq(login, nil, "no login")
	eq(problem.kind, "auth", "a signed-out gh is an auth problem")
	yes(#problem.message > 0, "with a message")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { stdout = "{}" }
		end
		return nil
	end
	ask()
	eq(login, nil, "an answer without hosts is no login")
	eq(problem.kind, "failed", "a failed read")
	has(problem.message, "2.66", "telling gh may be too old")
	gh.override = nil
	ask()
	eq(login, "octocat", "a failed read is not remembered: once gh is signed in the login is found")
	eq(problem, nil, "with no problem")
	eq(#ghx.of(gh, "accounts"), 3, "every failed attempt asked gh again")
end)

case("github.login: signed-in accounts without an active one are an auth problem with no login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { stdout = jsonEncode({ hosts = { ["github.com"] = array({ { state = "success", active = false, host = "github.com", login = "work" } }) } }) }
		end
		return nil
	end
	local calls, login, problem = 0, "unset" :: any, nil :: any
	github.login(nil, function(l, p)
		calls += 1
		login, problem = l, p
	end)
	w.flush()
	eq(calls, 1, "done runs once")
	eq(login, nil, "an account that is not the active one is no login")
	eq(problem.kind, "auth", "an auth problem")
	has(problem.message, "gh auth login", "naming how to sign in")
end)

case("github.login: a host with no accounts is an auth problem with no login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { stdout = jsonEncode({ hosts = { ["github.com"] = array({}) } }) }
		end
		return nil
	end
	local calls, login, problem = 0, "unset" :: any, nil :: any
	github.login(nil, function(l, p)
		calls += 1
		login, problem = l, p
	end)
	w.flush()
	eq(calls, 1, "done runs once")
	eq(login, nil, "no account at all is no login")
	eq(problem.kind, "auth", "an auth problem")
	has(problem.message, "gh auth login", "naming how to sign in")
end)

case("jira.user: the email's local part before the @", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local got: { string } = {}
	local function ask()
		jira.user(function(user, problem)
			table.insert(got, (user or "nil") .. if problem then "!" else "")
		end)
		w.flush()
	end
	ask()
	same(got, { "ann" }, "ann@example.com is ann")
	ask()
	same(got, { "ann", "ann" }, "the second read answers the same")
	local function authCount(): number
		local n = 0
		for _, req in acli.requests do
			if req.kind == "auth" then
				n += 1
			end
		end
		return n
	end
	eq(authCount(), 1, "acli was asked once for the sign-in")
	local function signIn(status: string)
		acli.override = function(req: AcliReq): Reply?
			if req.kind == "auth" then
				return { stdout = status }
			end
			return nil
		end
		jira.reset()
	end
	signIn("✓ Authenticated\n  Site: acme.atlassian.net\n  Email: first.last+x@corp.com\n")
	ask()
	eq(got[3], "first.last+x", "dots and plus signs stay")
	signIn("✓ Authenticated\n  Site: acme.atlassian.net\n  Email: a_b-c@corp.com\n")
	ask()
	eq(got[4], "a_b-c", "underscores and hyphens stay")
end)

case("jira.user: an unnamed sign-in is empty and read once", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	jira.user(function() end)
	w.flush()
	acli.requests = {}
	acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = "✓ Authenticated\n  Site: acme.atlassian.net\n  Authentication Type: oauth_global\n" }
		end
		return nil
	end
	jira.reset()
	local got: { string } = {}
	for _ = 1, 2 do
		jira.user(function(user, problem)
			table.insert(got, (user or "nil") .. if problem then "!" else "")
		end)
		w.flush()
	end
	same(got, { "", "" }, "no Email line: an empty user, not the previous sign-in's and no problem")
	eq(#acli.requests, 1, "the sign-in was read once for both")
	eq(acli.requests[1].kind, "auth", "by acli jira auth status")
	same(acli.requests[1].argv, { "acli", "jira", "auth", "status" }, "exactly")
end)

case("jira.user: a signed-out acli is a problem with no user, and is read again once signed in", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	acli.site = nil
	local calls, user, problem = 0, "unset" :: any, nil :: any
	local function ask()
		calls, user, problem = 0, "unset", nil
		jira.user(function(u, p)
			calls += 1
			user, problem = u, p
		end)
		w.flush()
		eq(calls, 1, "done runs once")
	end
	ask()
	eq(user, nil, "no user")
	eq(problem.kind, "auth", "an auth problem")
	has(problem.message, "not signed in", "with a message")
	acli.site = "acme.atlassian.net"
	ask()
	eq(user, "ann", "signed in: the user")
	eq(problem, nil, "no problem")
end)

-- ---- github.issues and github.issue

local function runIssues(w: World, github: Github, query: string): SearchOut
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.issues(nil, query, always, function(result, problem, spent)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.spent = spent
	end)
	w.flush()
	return out
end

case("github.issues: searches is:issue in the repository and normalizes issues", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.issueItems.octocat = {
		issueItem(12, "O/R", EPOCH - 60, { title = "Fix login", state = "CLOSED", reason = "NOT_PLANNED", labels = array({ "bug", "ui" }), assignees = array({ "ann", "bob" }), comments = 7 }),
		issueItem(11, "o/r", EPOCH - 120),
	}
	local out = runIssues(w, github, "is:open assignee:@me")
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(#gh.requests, 1, "one request covers two issues")
	eq(gh.requests[1].kind, "issue-search", "an issue search")
	eq(gh.requests[1].fields.q, "is:open assignee:@me is:issue sort:updated-desc", "the view's own query, issues only, no repo: qualifier")
	eq(out.result.total, 2, "total")
	eq(out.result.complete, true, "complete")
	eq(out.spent, 1, "spent")
	local issues = out.result.issues
	eq(#issues, 2, "issues")
	local first = issues[1]
	eq(first.key, "o/r#12", "identity is lowercase")
	eq(first.tracker, "github", "tracker")
	eq(first.repo, "O/R", "the repository as GitHub spells it")
	eq(first.ref, "12", "ref")
	eq(first.title, "Fix login", "title")
	eq(first.url, "https://github.com/O/R/issues/12", "url")
	eq(first.author, "octo", "author")
	eq(first.state, "closed", "state")
	eq(first.reason, "not-planned", "NOT_PLANNED reads as not-planned")
	same(first.labels, { "bug", "ui" }, "labels")
	same(first.assignees, { "ann", "bob" }, "assignees")
	eq(first.comments, 7, "comments")
	eq(first.updated, EPOCH - 60, "updated")
	eq(first.created, EPOCH - 60, "created")
	eq(issues[2].state, "open", "an open issue")
	eq(issues[2].reason, nil, "has no reason")
	-- every closing reason, a closed issue without one, and a deleted author
	gh.issueItems.octocat = {
		issueItem(1, "o/r", EPOCH - 10, { state = "CLOSED", reason = "COMPLETED" }),
		issueItem(2, "o/r", EPOCH - 20, { state = "CLOSED", reason = "DUPLICATE" }),
		issueItem(3, "o/r", EPOCH - 30, { state = "CLOSED", reason = "NOT_PLANNED" }),
		issueItem(4, "o/r", EPOCH - 40, { state = "CLOSED" }),
		issueItem(5, "o/r", EPOCH - 50, { author = NULL }),
	}
	local closed = runIssues(w, github, "is:closed")
	local seen: { string } = {}
	for _, issue in closed.result.issues do
		table.insert(seen, issue.state .. ":" .. (issue.reason or "-") .. ":" .. issue.author)
	end
	same(seen, { "closed:completed:octo", "closed:duplicate:octo", "closed:not-planned:octo", "closed:-:octo", "open:-:ghost" }, "the closing reasons, and ghost for a deleted author")
	-- a pull request, or a URL that is not the issue's, fails the whole read
	gh.issueItems.octocat = { issueItem(5, "o/r", EPOCH - 60, { url = "https://github.com/o/r/pull/5" }) }
	local pull = runIssues(w, github, "is:open")
	eq(pull.result, nil, "a pull request in an issue search fails the read")
	eq(pull.problem.kind, "failed", "problem kind")
	eq(pull.problem.message, "the search returned an item that is not an issue", "message")
	gh.issueItems.octocat = { issueItem(5, "o/r", EPOCH - 60, { url = "https://evil.example/o/r/issues/5" }) }
	eq(runIssues(w, github, "is:open").problem.message, "the search returned an issue with an unexpected URL", "a foreign URL")
	gh.issueItems.octocat = { issueItem(5, "o/r", EPOCH - 60, { number = 6 }) }
	eq(runIssues(w, github, "is:open").problem.message, "the search returned an issue with an unexpected URL", "a URL of another number")
	-- the pages are the same
	gh.requests = {}
	local many: { { [string]: any } } = {}
	for i = 1, 250 do
		table.insert(many, issueItem(i, "o/r", EPOCH - i * 60))
	end
	gh.issueItems.octocat = many
	local paged = runIssues(w, github, "is:open")
	eq(#gh.requests, 3, "250 issues are three pages of 100")
	eq(#paged.result.issues, 250, "all of them")
	eq(paged.result.complete, true, "complete")
end)

type IssueOut = { detail: any, problem: any, calls: number }

local function runIssue(w: World, github: Github, shouldContinue: (() -> boolean)?, account: string?): IssueOut
	local out: IssueOut = { detail = nil, problem = nil, calls = 0 }
	github.issue("o/r", 12, account, function(detail, problem)
		out.calls += 1
		out.detail, out.problem = detail, problem
	end, shouldContinue)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	return out
end

case("github.issue: reads body, milestone and linked pull requests", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.issueDetail["o/r#12"] = {
		body = "Login fails.<!-- CURSOR_SUMMARY -->\nrecap\n<!-- /CURSOR_SUMMARY -->",
		milestone = "v2",
		linked = array({
			{ number = 45, title = "Fix login redirect", url = "https://github.com/o/r/pull/45", state = "OPEN", isDraft = true },
			{ number = 44, title = "Earlier attempt", url = "https://github.com/o/r/pull/44", state = "MERGED", isDraft = false },
			{ number = 43, title = "Abandoned", url = "https://github.com/o/r/pull/43", state = "CLOSED", isDraft = false },
			{ number = 42, title = "Ready", url = "https://github.com/o/r/pull/42", state = "OPEN", isDraft = false },
			{ number = 41, title = "Elsewhere", url = "javascript:alert(1)", state = "OPEN", isDraft = false },
			{ title = "No number", url = "https://github.com/o/r/pull/40", state = "OPEN", isDraft = false },
		}),
	}
	local out = runIssue(w, github, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(#gh.requests, 1, "one call")
	eq(gh.requests[1].kind, "issue", "an issue read")
	eq(gh.requests[1].fields.o, "o", "owner")
	eq(gh.requests[1].fields.r, "r", "repository")
	eq(gh.requests[1].fields.n, "12", "number")
	eq(out.detail.body, "Login fails.", "the body, without Cursor's generated summary")
	same(out.detail.fields, { { label = "Milestone", value = "v2" } }, "the milestone is the one detail row GitHub fills")
	same(out.detail.linked, {
		{ ref = "45", title = "Fix login redirect", url = "https://github.com/o/r/pull/45", state = "draft" },
		{ ref = "44", title = "Earlier attempt", url = "https://github.com/o/r/pull/44", state = "merged" },
		{ ref = "43", title = "Abandoned", url = "https://github.com/o/r/pull/43", state = "closed" },
		{ ref = "42", title = "Ready", url = "https://github.com/o/r/pull/42", state = "open" },
	}, "draft, merged, closed and open; an entry with a foreign URL or no number is dropped")
	-- an issue gh prints nothing of reads as empty, an empty milestone as none, a long body is cut
	gh.issueDetail["o/r#12"] = nil
	local none = runIssue(w, github, nil)
	eq(none.problem, nil, "an issue the account cannot see is not a failed read")
	eq(none.detail.body, "", "no body")
	same(none.detail.fields, { { label = "Milestone" } }, "no milestone")
	same(none.detail.linked, {}, "no linked pull requests")
	gh.issueDetail["o/r#12"] = { body = string.rep("é", 20005), milestone = "", linked = array({}) }
	local long = runIssue(w, github, nil)
	same(long.detail.fields, { { label = "Milestone" } }, "an empty milestone is none")
	eq(utf8.len(long.detail.body), 20003, "a long body is cut at 20000 characters, on a character boundary, and marked")
	-- what gh printed must be a JSON object, and a failing call returns its problem
	gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" then
			return { stdout = "not json" }
		end
		return nil
	end
	local bad = runIssue(w, github, nil)
	eq(bad.detail, nil, "no detail")
	eq(bad.problem.kind, "failed", "problem kind")
	eq(bad.problem.message, "gh printed unexpected issue data.", "message")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local failed = runIssue(w, github, nil)
	eq(failed.detail, nil, "no detail")
	eq(failed.problem.kind, "failed", "the call's problem")
end)

case("github.issue: a paused quota or an unusable account sends nothing, and cancellation wins everywhere", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.issueDetail["o/r#12"] = { body = "x", linked = array({}) }
	github.record({ remaining = 0, reset = w.seconds() + 60, limit = 30 }, w.seconds(), "limited")
	local paused = runIssue(w, github, nil, "limited")
	eq(paused.problem.kind, "rate-limit", "problem kind")
	has(paused.problem.message, "resume at", "message")
	eq(#gh.requests, 0, "nothing was sent while paused")
	gh.tokens.fine = "tok-fine"
	local cancelled = runIssue(w, github, function(): boolean
		return false
	end, "fine")
	eq(cancelled.problem.kind, "superseded", "cancelled before the call")
	eq(#gh.requests, 0, "nothing was sent")
	local go = true
	gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" then
			go = false
		end
		return nil
	end
	local during = runIssue(w, github, function(): boolean
		return go
	end, "fine")
	eq(during.problem.kind, "superseded", "cancelled while the call was in flight")
	local bad: IssueOut = { detail = nil, problem = nil, calls = 0 }
	github.issue("not-a-repo", 5, nil, function(detail, problem)
		bad.detail, bad.problem = detail, problem
	end)
	w.flush()
	eq(bad.problem.kind, "failed", "an unexpected repository name")
end)

-- ---- jira.luau: acli's search, one work item's details and the project list

local function runJira(w: World, jira: Jira, query: string, shouldContinue: (() -> boolean)?): SearchOut
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	jira.issues(query, shouldContinue or always, function(result, problem, spent)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.spent = spent
	end)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	return out
end

local function runJiraIssue(w: World, jira: Jira, key: string, shouldContinue: (() -> boolean)?): IssueOut
	local out: IssueOut = { detail = nil, problem = nil, calls = 0 }
	jira.issue(key, function(detail, problem)
		out.calls += 1
		out.detail, out.problem = detail, problem
	end, shouldContinue)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	return out
end

-- The value after option `name` of an acli call.
local function acliOption(argv: { string }, name: string): string?
	for i = 2, #argv - 1 do
		if argv[i] == name then
			return argv[i + 1]
		end
	end
	return nil
end

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

case("jira.issues: one search of the view's query, highest priority then newest update first, normalized", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local query = "assignee = currentUser() AND statusCategory != Done"
	local jql = "(" .. query .. ") ORDER BY priority DESC, updated DESC"
	acli.searches[jql] = {
		jiraItem("ABC-12", "Fix login", {
			status = { name = "In Progress", statusCategory = { key = "indeterminate" } },
			issuetype = { name = "Bug" },
			priority = { name = "High" },
			assignee = { displayName = "Bob Ray" },
			labels = array({ "ui", "bug" }),
		}),
		jiraItem("ABC-13", "Old bug", { status = { name = "Done", statusCategory = { key = "done" } } }),
	}
	local out = runJira(w, jira, query, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.spent, 0, "Jira has no quota to spend")
	eq(#acli.requests, 2, "the site, then one search")
	eq(acli.requests[1].kind, "auth", "the site comes first")
	eq(acli.requests[2].kind, "search", "then the search")
	local argv = acli.requests[2].argv
	eq(acliOption(argv, "--jql"), jql, "the view's query in parentheses, highest priority then newest update first, no project clause")
	eq(acliOption(argv, "--limit"), "100", "the newest 100")
	eq(acliOption(argv, "--fields"), "key,summary,status,issuetype,priority,assignee,reporter,labels", "only the fields acli's search allows")
	yes(table.find(argv, "--json"), "as JSON")
	eq(out.result.total, 2, "total")
	eq(out.result.complete, true, "fewer than a page is complete")
	local issues = out.result.issues
	eq(#issues, 2, "issues, in acli's order")
	local first = issues[1]
	eq(first.key, "abc#ABC-12", "identity: the lowercase project, then the key")
	eq(first.ref, "ABC-12", "ref")
	eq(first.repo, "ABC", "the project")
	eq(first.tracker, "jira", "tracker")
	eq(first.url, "https://acme.atlassian.net/browse/ABC-12", "browse URL from the site acli is signed in to")
	eq(first.title, "Fix login", "title")
	eq(first.author, "Ann Lee", "the reporter")
	eq(first.state, "open", "an unfinished status is open")
	eq(first.reason, nil, "no close reason")
	same(first.status, { text = "In Progress", tone = "warning" }, "the workflow status, toned by its category")
	eq(first.type, "Bug", "type")
	eq(first.priority, "High", "priority")
	same(first.labels, { "ui", "bug" }, "labels")
	same(first.assignees, { "Bob Ray" }, "the assignee")
	eq(first.comments, 0, "the list has no comment count")
	eq(first.created, 0, "and no creation date")
	eq(first.updated, 0, "nor update date")
	local second = issues[2]
	eq(second.key, "abc#ABC-13", "key")
	eq(second.state, "closed", "a done category is closed")
	same(second.status, { text = "Done", tone = "success" }, "status")
	same(second.assignees, {}, "a null assignee is none")
	-- an empty search prints [null], [] or null
	for i, text in { "[\n  null\n]\n", "[]\n", "null\n" } do
		acli.override = function(req: AcliReq): Reply?
			return if req.kind == "search" then { stdout = text } else nil
		end
		local none = runJira(w, jira, query, nil)
		eq(none.problem, nil, "empty form " .. i .. ": problem")
		eq(#none.result.issues, 0, "empty form " .. i .. ": issues")
		eq(none.result.total, 0, "empty form " .. i .. ": total")
		eq(none.result.complete, true, "empty form " .. i .. ": complete")
	end
	-- an update notice before the JSON and a null element inside it are skipped
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "search" then { stdout = "You're using an outdated version 1.3.36-stable. Update to the latest version 1.3.39-stable.\n[null," .. jsonEncode(jiraItem("ABC-5", "Five")) .. "]" } else nil
	end
	local noticed = runJira(w, jira, query, nil)
	eq(noticed.problem, nil, "problem")
	eq(#noticed.result.issues, 1, "the notice and the null are skipped")
	eq(noticed.result.issues[1].ref, "ABC-5", "the work item")
	-- a full page may have more behind it
	acli.override = nil
	local many: { any } = {}
	for i = 1, 100 do
		table.insert(many, jiraItem("ABC-" .. i, "Issue " .. i))
	end
	acli.searches[jql] = many
	local full = runJira(w, jira, query, nil)
	eq(#full.result.issues, 100, "a full page")
	eq(full.result.complete, false, "a full page is not known to be complete")
	eq(full.result.issues[1].ref, "ABC-1", "acli's order is kept")
	eq(full.result.issues[100].ref, "ABC-100", "to the last item")
	-- the site is read once per sign-in
	eq(acliCount(acli, "auth"), 1, "the site is asked for once")
	jira.reset()
	runJira(w, jira, query, nil)
	eq(acliCount(acli, "auth"), 2, "reset forgets it")
end)

case("jira.issues: acli's failures become problems, and a query that cannot be wrapped never reaches acli", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local query = "assignee = currentUser()"
	-- acli is not installed: the spawn raises and there is no shell to look in
	acli.override = function(_req: AcliReq): Reply?
		return { raise = "no such file or directory" }
	end
	local missing = runJira(w, jira, query, nil)
	eq(missing.result, nil, "no result")
	eq(missing.problem.kind, "missing", "acli cannot be started")
	has(missing.problem.message, "acli could not be started", "and the message names the program")
	-- signed out: the site lookup is refused
	acli.override = nil
	acli.site = nil
	local signedOut = runJira(w, jira, query, nil)
	eq(signedOut.problem.kind, "auth", "signed out")
	eq(signedOut.problem.message, "acli is not signed in to Jira: unauthorized: use 'acli jira auth login' to authenticate", "in acli's words")
	eq(acliCount(acli, "search"), 0, "no search was sent")
	-- a sign-in that names no site
	acli.site = "acme.atlassian.net"
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "auth" then { stdout = "✓ Authenticated\n" } else nil
	end
	local nameless = runJira(w, jira, query, nil)
	eq(nameless.problem.kind, "auth", "no site named")
	has(nameless.problem.message, "did not name a Jira site", "message")
	eq(acliCount(acli, "search"), 0, "still no search")
	-- the site is known now; what a search fails with
	acli.override = nil
	eq(runJira(w, jira, query, nil).problem, nil, "a working search")
	local lookups = acliCount(acli, "auth")
	local function searchReplies(reply: Reply): SearchOut
		acli.override = function(req: AcliReq): Reply?
			return if req.kind == "search" then reply else nil
		end
		local out = runJira(w, jira, query, nil)
		eq(out.result, nil, "no result")
		return out
	end
	local bogus = searchReplies({ status = 1, stderr = "✗ Error: failed to parse JQL query: field 'bogus' does not exist or you do not have permission to view it.\n" })
	eq(bogus.problem.kind, "invalid", "a JQL error is terminal")
	eq(bogus.problem.message, "failed to parse JQL query: field 'bogus' does not exist or you do not have permission to view it.", "in acli's words")
	local gone = searchReplies({ status = 1, stderr = "✗ Error: failed to parse JQL query: the value 'nopexyz' does not exist for the field 'project'.\n" })
	eq(gone.problem.kind, "not-found", "an unknown project is not found")
	eq(searchReplies({ status = 1, stderr = "✗ Error: request failed: 429 Too Many Requests\n" }).problem.kind, "rate-limit", "a 429 is a rate limit")
	local boom = searchReplies({ status = 1, stderr = "✗ Error: boom\n" })
	eq(boom.problem.kind, "failed", "anything else")
	eq(boom.problem.message, "boom", "with acli's message")
	local slow = searchReplies({ timedOut = true })
	eq(slow.problem.kind, "failed", "no answer in time")
	eq(slow.problem.message, "acli did not answer within 60 seconds.", "message")
	eq(searchReplies({ stdout = "not json" }).problem.message, "acli printed something other than a search result", "no JSON")
	eq(searchReplies({ stdout = '{"issues":[]}' }).problem.message, "acli printed something other than a search result", "an object is no search result")
	eq(searchReplies({ stdout = '[{"key":"ABC-1"}]' }).problem.message, "acli returned a work item without a key or summary", "an item with no summary")
	eq(acliCount(acli, "auth"), lookups, "none of those forgot the site")
	-- a search that ends signed out forgets the site: the next one asks again
	eq(searchReplies({ status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login' to authenticate\n" }).problem.kind, "auth", "signed out mid-way")
	acli.override = nil
	eq(runJira(w, jira, query, nil).problem, nil, "signed in again")
	eq(acliCount(acli, "auth"), lookups + 1, "the site was looked up again")
	-- a query that cannot be wrapped in parentheses is refused without asking acli
	local sent = #acli.requests
	for _, bad in { "a = 1) OR (b = 2", "a = 1 ORDER BY created", "a = 1 order  by x", "x = 'open", "(a = 1" } do
		local refused = runJira(w, jira, bad, nil)
		eq(refused.result, nil, "no result: " .. bad)
		eq(refused.problem.kind, "invalid", "refused: " .. bad)
	end
	eq(#acli.requests, sent, "none of them reached acli")
	eq(jira.scopeProblem("a = 1) OR (b = 2"), "Unbalanced parentheses.", "an extra closing parenthesis")
	eq(jira.scopeProblem("(a = 1"), "Unbalanced quotes or parentheses.", "an open parenthesis")
	eq(jira.scopeProblem("a = 1 ORDER BY x"), "Leave out ORDER BY: issues are listed by status, then priority.", "ordering is the search's")
	local blank = runJira(w, jira, "  ", nil)
	eq(blank.problem.kind, "failed", "a blank filter")
	eq(blank.problem.message, "The view's query is empty.", "message")
	eq(runJira(w, jira, 'summary ~ "a) ORDER BY (b"', nil).problem, nil, "quoted text may hold parentheses and ORDER BY")
	-- cancellation wins everywhere
	local searches = acliCount(acli, "search")
	local cancelled = runJira(w, jira, query, function(): boolean
		return false
	end)
	eq(cancelled.problem.kind, "superseded", "cancelled before the search")
	eq(acliCount(acli, "search"), searches, "nothing was sent")
	local go = true
	acli.override = function(req: AcliReq): Reply?
		if req.kind == "search" then
			go = false
		end
		return nil
	end
	local during = runJira(w, jira, query, function(): boolean
		return go
	end)
	eq(during.problem.kind, "superseded", "cancelled while the search was in flight")
end)

case("jira.issue: body as markdown, fields, links and dates", function(w: World)
	local jira = w.load("jira") :: Jira
	local github = w.load("github") :: Github
	local acli = newAcli(w)
	local function ref(key: string, summary: string, category: string): any
		return { key = key, fields = { summary = summary, status = { statusCategory = { key = category } } } }
	end
	local blocks: { any } = {
		{ type = "heading", attrs = { level = 2 }, content = { { type = "text", text = "Steps" } } },
		{
			type = "paragraph",
			content = {
				{ type = "text", text = "See " },
				{ type = "text", text = "the guide", marks = { { type = "strong" }, { type = "link", attrs = { href = "https://example.com/guide" } } } },
				{ type = "text", text = "." },
			},
		},
		{
			type = "bulletList",
			content = {
				{ type = "listItem", content = { { type = "paragraph", content = { { type = "text", text = "Open /login" } } } } },
				{ type = "listItem", content = { { type = "paragraph", content = { { type = "text", text = "Press " }, { type = "text", text = "Enter", marks = { { type = "code" } } } } } } },
			},
		},
	}
	local links: { any } = {
		{ type = { inward = "is blocked by", outward = "blocks" }, outwardIssue = ref("ABC-3", "Login API", "done") },
		{ type = { inward = "is blocked by", outward = "blocks" }, inwardIssue = ref("ABC-4", "Design", "new") },
		{ type = { inward = "relates to", outward = "relates to" }, outwardIssue = { fields = { summary = "No key" } } },
	}
	acli.views["ABC-12"] = {
		key = "ABC-12",
		fields = {
			summary = "Fix login",
			description = { type = "doc", version = 1, content = blocks },
			parent = { key = "ABC-1", fields = { summary = "Auth rework" } },
			customfield_10020 = array({
				{ boardId = 1, state = "closed", name = "Sprint 1" },
				{ boardId = 1, state = "active", name = "Sprint 2" },
				{ boardId = 1, state = "future", name = "Sprint 3" },
			}),
			customfield_10036 = array({ { id = "1", value = "not a sprint" } }),
			components = array({ { name = "Web" }, { name = "API" } }),
			fixVersions = array({ { name = "v2" } }),
			issuelinks = array(links),
			subtasks = array({ ref("ABC-13", "Add a test", "indeterminate") }),
			comment = { total = 2 },
			created = "2026-05-27T09:38:49.512-0500",
			updated = "2026-05-28T10:00:00.000+0000",
		},
	}
	local out = runJiraIssue(w, jira, "ABC-12", nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(#acli.requests, 2, "the site, then the work item")
	eq(acli.requests[2].kind, "view", "a view")
	eq(acli.requests[2].argv[5], "ABC-12", "of the key")
	eq(acliOption(acli.requests[2].argv, "--fields"), "*all", "with every field")
	eq(out.detail.body, "## Steps\n\nSee [**the guide**](https://example.com/guide).\n\n- Open /login\n- Press `Enter`", "the description as markdown")
	same(out.detail.fields, {
		{ label = "Parent", value = "ABC-1 Auth rework" },
		{ label = "Sprint", value = "Sprint 2" },
		{ label = "Components", value = "Web, API" },
		{ label = "Fix versions", value = "v2" },
	}, "parent, the active sprint (the sprint field found by its shape), components and fix versions, in order")
	same(out.detail.linked, {
		{ ref = "ABC-3", title = "Login API", url = "https://acme.atlassian.net/browse/ABC-3", state = "done", relation = "blocks", status = { text = "Done", tone = "success" } },
		{ ref = "ABC-4", title = "Design", url = "https://acme.atlassian.net/browse/ABC-4", state = "open", relation = "is blocked by", status = { text = "To Do", tone = "muted" } },
		{ ref = "ABC-13", title = "Add a test", url = "https://acme.atlassian.net/browse/ABC-13", state = "open", relation = "subtask", status = { text = "In Progress", tone = "warning" } },
	}, "an outward link, an inward one, a subtask, each with its status (here its category's name: no status name); a link with no key is dropped")
	eq(out.detail.comments, 2, "comments")
	eq(out.detail.created, github.epoch("2026-05-27T14:38:49Z"), "a -0500 offset is converted to UTC")
	eq(out.detail.updated, github.epoch("2026-05-28T10:00:00Z"), "updated")
	-- a work item with nothing set reads as empty
	acli.views["ABC-14"] = { key = "ABC-14", fields = { summary = "Bare" } }
	local bare = runJiraIssue(w, jira, "ABC-14", nil)
	eq(bare.problem, nil, "problem")
	eq(bare.detail.body, "", "no description")
	same(bare.detail.fields, { { label = "Parent" }, { label = "Sprint" }, { label = "Components" }, { label = "Fix versions" } }, "every row, with no value")
	same(bare.detail.linked, {}, "no links")
	eq(bare.detail.comments, nil, "no comment count")
	eq(bare.detail.created, nil, "no creation date")
	-- a plain-text description, cut long
	acli.views["ABC-15"] = { key = "ABC-15", fields = { summary = "Long", description = string.rep("é", 20005) } }
	local long = runJiraIssue(w, jira, "ABC-15", nil)
	eq(utf8.len(long.detail.body), 20001, "a long description is cut at 20000 characters, on a character boundary, and marked")
	eq(string.sub(long.detail.body, -3), "…", "with an ellipsis")
	-- what acli answers that is no work item
	local requests = #acli.requests
	local badKey = runJiraIssue(w, jira, "abc-1", nil)
	eq(badKey.detail, nil, "no detail")
	eq(badKey.problem.kind, "failed", "a key that is none")
	eq(#acli.requests, requests, "and nothing was asked")
	local gone = runJiraIssue(w, jira, "ABC-99", nil)
	eq(gone.detail, nil, "an issue acli cannot see")
	eq(gone.problem.kind, "failed", "is a failed read")
	eq(gone.problem.message, "Issue does not exist or you do not have permission to see it.", "in acli's words")
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "view" then { stdout = "not json" } else nil
	end
	local junk = runJiraIssue(w, jira, "ABC-12", nil)
	eq(junk.problem.kind, "failed", "no JSON")
	eq(junk.problem.message, "acli printed unexpected issue data.", "message")
	-- signed out mid-way forgets the site; cancellation wins
	local lookups = acliCount(acli, "auth")
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "view" then { status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login' to authenticate\n" } else nil
	end
	eq(runJiraIssue(w, jira, "ABC-12", nil).problem.kind, "auth", "signed out")
	acli.override = nil
	eq(runJiraIssue(w, jira, "ABC-12", nil).problem, nil, "signed in again")
	eq(acliCount(acli, "auth"), lookups + 1, "the site was looked up again")
	local views = acliCount(acli, "view")
	local cancelled = runJiraIssue(w, jira, "ABC-12", function(): boolean
		return false
	end)
	eq(cancelled.problem.kind, "superseded", "cancelled before the call")
	eq(acliCount(acli, "view"), views, "nothing was sent")
	local go = true
	acli.override = function(req: AcliReq): Reply?
		if req.kind == "view" then
			go = false
		end
		return nil
	end
	local during = runJiraIssue(w, jira, "ABC-12", function(): boolean
		return go
	end)
	eq(during.problem.kind, "superseded", "cancelled while the call was in flight")
end)

case("jira.adf: blocks, marks and inline nodes become markdown", function(w: World)
	local jira = w.load("jira") :: Jira
	local function t(s: string, marks: { any }?): any
		return { type = "text", text = s, marks = marks }
	end
	local function p(...: any): any
		return { type = "paragraph", content = { ... } }
	end
	local function doc(...: any): any
		return { type = "doc", version = 1, content = { ... } }
	end
	local function item(...: any): any
		return { type = "listItem", content = { ... } }
	end
	local function row(kind: string, ...: string): any
		local cells: { any } = {}
		for _, s in { ... } do
			table.insert(cells, { type = kind, content = { p(t(s)) } })
		end
		return { type = "tableRow", content = cells }
	end
	eq(jira.adf(doc(p(t("one")), p(t("two")))), "one\n\ntwo", "blocks are separated by a blank line")
	eq(jira.adf(doc(p(t("a"), { type = "hardBreak" }, t("b")))), "a\nb", "a hard break is a line break")
	eq(jira.adf(doc({ type = "heading", attrs = { level = 3 }, content = { t("Title") } })), "### Title", "a heading")
	eq(jira.adf(doc({ type = "heading", attrs = { level = 9 }, content = { t("Deep") } })), "###### Deep", "at most six hashes")
	eq(
		jira.adf(doc(p(
			t("a", { { type = "code" } }),
			t(" "),
			t("b ", { { type = "strong" } }),
			t("c", { { type = "em" } }),
			t(" "),
			t("d", { { type = "strike" } }),
			t(" "),
			t("e", { { type = "link", attrs = { href = "https://x.test/e" } } })
		))),
		"`a` **b** *c* ~~d~~ [e](https://x.test/e)",
		"marks; the space inside strong stays outside the asterisks"
	)
	eq(
		jira.adf(doc({ type = "bulletList", content = { item(p(t("a"))), item(p(t("b")), { type = "bulletList", content = { item(p(t("c"))) } }) } })),
		"- a\n- b\n  - c",
		"a bullet list, a nested one under its item"
	)
	eq(
		jira.adf(doc({ type = "orderedList", content = { item(p(t("one")), { type = "bulletList", content = { item(p(t("inner"))) } }), item(p(t("two"))) } })),
		"1. one\n   - inner\n2. two",
		"an ordered list counts, and a nested list sits under the marker's width"
	)
	eq(jira.adf(doc({ type = "orderedList", attrs = { order = 3 }, content = { item(p(t("x"))) } })), "3. x", "an ordered list starts at its order")
	eq(jira.adf(doc({ type = "codeBlock", attrs = { language = "lua" }, content = { t("print(1)\nprint(2)") } })), "```lua\nprint(1)\nprint(2)\n```", "a fenced code block with its language")
	eq(jira.adf(doc({ type = "codeBlock", content = { t("a ``` b") } })), "````\na ``` b\n````", "a fence longer than any run of backticks inside")
	eq(jira.adf(doc({ type = "blockquote", content = { p(t("a")), p(t("b")) } })), "> a\n> \n> b", "a quote marks every line")
	eq(jira.adf(doc(p(t("a")), { type = "rule" }, p(t("b")))), "a\n\n---\n\nb", "a rule")
	eq(
		jira.adf(doc({ type = "table", content = { row("tableHeader", "A", "B"), row("tableCell", "1", "x|y") } })),
		"| A | B |\n| --- | --- |\n| 1 | x\\|y |",
		"a table: the first row is the header, a pipe in a cell is escaped"
	)
	eq(jira.adf(doc({ type = "panel", attrs = { panelType = "info" }, content = { p(t("note")) } })), "note", "a panel shows its content")
	eq(
		jira.adf(doc(p(
			t("hi "),
			{ type = "mention", attrs = { text = "@Ann" } },
			t(" "),
			{ type = "emoji", attrs = { shortName = ":smile:" } },
			t(" "),
			{ type = "inlineCard", attrs = { url = "https://x.test/c" } },
			t(" "),
			{ type = "status", attrs = { text = "DONE" } },
			{ type = "date", attrs = { timestamp = "1" } }
		))),
		"hi @Ann :smile: https://x.test/c DONE",
		"mentions, emoji, smart links and statuses are text; a date draws nothing"
	)
	eq(jira.adf(doc(p(t("a")), { type = "mediaSingle", content = { { type = "media", attrs = { id = "1" } } } })), "a", "media draws nothing")
	eq(jira.adf(doc({ type = "taskList", content = { { type = "taskItem", content = { t("do it") } } } })), "do it", "an unknown block shows what it holds")
	eq(jira.adf(nil), "", "nothing is empty")
end)

case("jira.projects: lists the visible projects by key and leaves out what is no project key", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	acli.projects = { { key = "OXYGEN", name = "Oxygen" }, { key = "CAR", name = "CARBON" }, { key = "lower", name = "Not a Jira key" }, { key = "NONAME" } }
	local got: any, why: any = nil, nil
	local calls = 0
	local function list()
		calls, got, why = 0, nil, nil
		jira.projects(function(projects, problem)
			calls += 1
			got, why = projects, problem
		end)
		w.flush()
	end
	list()
	eq(calls, 1, "done calls")
	eq(why, nil, "problem")
	eq(#acli.requests, 1, "one call, no site needed")
	eq(table.concat(acli.requests[1].argv, " "), "acli jira project list --paginate --json", "the project list")
	same(got, { { key = "CAR", name = "CARBON" }, { key = "NONAME", name = "" }, { key = "OXYGEN", name = "Oxygen" } }, "sorted by key; a missing name is empty; a key that is no project key is left out")
	acli.site = nil
	list()
	eq(got, nil, "no projects")
	eq(why.kind, "auth", "signed out")
	acli.site = "acme.atlassian.net"
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "projects" then { stdout = "not json" } else nil
	end
	list()
	eq(why.kind, "failed", "output that is no project list")
end)

-- ---- host.luau: the Plotroom block (`prs`), driven through the def it registers with tern.block.define

type HostScene = { git: Git, gh: Gh }

-- A checkout of o/r at /work/r whose origin is github.com/o/r, and `count` PRs for the active gh account.
local function hostScene(w: World, count: number?): HostScene
	w.load("host")
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", count or 3)
	return { git = g, gh = gh }
end

-- The block of `pane` launched in /work/r, after its repository lookup and first search, nothing selected.
function hx.openBare(w: World, pane: number?): Block
	local b = w.open(pane or 1, { "/work/r" })
	w.flush()
	return b
end

-- The block of `pane` launched in /work/r, after its repository lookup and first search, its first row selected.
local function openQueue(w: World, pane: number?): Block
	local b = hx.openBare(w, pane)
	hx.selectFirst(b)
	return b
end

-- Forgets every saved checkout: opening the queue in /work/r saves that one.
local function forgetCheckouts(w: World)
	local store: any = w.kv.store
	store.checkouts = nil
end

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

-- Refreshes `b` as its `r` key does and lets everything that starts finish.
local function refreshNow(w: World, b: Block)
	b.typeText("r")
	w.flush()
end

local function requestsOf(gh: Gh, kind: string): { GhReq }
	local out: { GhReq } = {}
	for _, req in gh.requests do
		if req.kind == kind then
			table.insert(out, req)
		end
	end
	return out
end

local function listed(b: Block): { string }
	local out: { string } = {}
	local order: any = pickerOf(b).order
	for _, id in order do
		table.insert(out, id)
	end
	return out
end

-- Clicks sidebar scope `id` of `b`.
local function pickScope(b: Block, id: string)
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = id })
end

local function actionOf(b: Block, id: string): any
	for _, action in pickerOf(b).actions do
		if action.id == id then
			return action
		end
	end
	return nil
end

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

-- Expands the view or prompt whose summary row is `row` ("vopen:<kind>:<id>" / "popen:<kind>:<id>", the kind being prs or issues), as its Edit button does.
local function expand(b: Block, row: string)
	b.event({ ev = "action", id = "layer.settings", act = "expand", value = row })
end

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

-- The lowercased key labels of a shortcut list overlay found under `node`.
local function helpKeys(node: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, entry in helpEntries(node) do
		for _, label in entry.caps do
			out[string.lower(label)] = true
		end
	end
	return out
end

-- The rows of a shortcut list overlay found under `node`: each one's key labels, joined by a space, and what it does.
local function helpRows(node: any): { { keys: string, text: string } }
	local out: { { keys: string, text: string } } = {}
	for _, entry in helpEntries(node) do
		table.insert(out, { keys = table.concat(entry.caps, " "), text = entry.text })
	end
	return out
end

case("host: the queue resolves the repository, searches inside it, lists the PRs and polls until its pane closes", function(w: World)
	local s = hostScene(w, 3)
	local items = s.gh.items.octocat
	s.gh.items.octocat = { items[3], items[1], items[2] }
	local b = w.open(1, { "/work/r" })
	eq(pickerOf(b).state, "loading", "the first card is the spinner")
	w.flush()
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 1, "one request covers three PRs")
	has(searches[1].fields.q, "is:pr", "the search asks for pull requests")
	eq(searches[1].fields.q, "is:open author:@me is:pr sort:updated-desc", "the view's own query, with no repository qualifier")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "newest update first")
	eq(pickerOf(b).selected, nil, "nothing is selected until a row is picked")
	hx.selectFirst(b)
	eq(pickerOf(b).selected, "no_2fr_231", "the first PR is selected once picked")
	eq(pickerOf(b).state, "ready", "the list is ready")
	has(b.title(), "My PRs", "the title names the filter")
	has(b.title(), "(3)", "and counts the PRs")
	local prRow: any = findKey(pickerNode(b), "titlerow")
	eq(prRow.c[1].p.key, "title", "the preview's title row starts with the title")
	eq(prRow.c[2].p.text, "GitHub", "and ends with the integration badge")
	w.advance(59999)
	eq(#requestsOf(s.gh, "search"), 1, "no refresh before the minute is up")
	w.advance(1)
	eq(#requestsOf(s.gh, "search"), 2, "a refresh a minute later")
	b.close()
	w.advance(10 * 60 * 1000)
	eq(#requestsOf(s.gh, "search"), 2, "a closed pane stops polling")
end)

case("host: running init again for a live pane keeps its list and does not search twice", function(w: World)
	local s = hostScene(w, 3)
	openQueue(w)
	local again = w.open(1, { "/work/r" })
	w.flush()
	same(listed(again), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the loaded list is still there")
	eq(#requestsOf(s.gh, "search"), 1, "and nothing was searched again")
end)

case("host: launching in a directory that is gone maps no checkout and still shows the views", function(w: World)
	w.load("host")
	newGh(w)
	local b = w.open(1, { "/nowhere" })
	w.flush()
	eq(w.kv.get("checkouts"), nil, "no checkout is saved for a directory that does not exist")
	eq(pickerOf(b).state ~= "loading", true, "the card is not left on the spinner")
end)

case("host: launch dir maps its checkout once", function(w: World)
	hostScene(w, 3)
	forgetCheckouts(w)
	openQueue(w)
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "an unmapped repository gets the launch checkout")
	w.kv.put("checkouts", { ["o/r"] = "/elsewhere" })
	openQueue(w, 2)
	eq(w.kv.get("checkouts")["o/r"], "/elsewhere", "an existing mapping is kept")
end)

case("host: Escape clears the search, then closes it, and is left to the pane when there is nothing to cancel", function(w: World)
	hostScene(w, 3)
	local b = hx.openBare(w)
	b.typeText("/")
	eq(pickerOf(b).query, "", "the search opens empty")
	b.typeText("2")
	same(listed(b), { "no_2fr_232" }, "the search narrows the list")
	eq(pickerOf(b).selected, nil, "and selects nothing for the user")
	eq(b.press("escape"), true, "the first Escape is handled")
	eq(pickerOf(b).query, "", "it cleared the text but kept the search open")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the whole list is back")
	eq(b.press("escape"), true, "the second Escape is handled")
	eq(pickerOf(b).query, nil, "it closed the search")
	eq(b.press("escape"), false, "with nothing to cancel Escape is not consumed")
	b.press("tab")
	eq(pickerOf(b).focus, "scopes", "Tab moves to the filter list")
	eq(b.press("escape"), true, "Escape leaves the filter list")
	eq(pickerOf(b).focus, "list", "back to the pull requests")
end)

case("host: nothing is selected at first; a row click, Down or an activation selects it, and a refresh, a search or a view switch never selects another", function(w: World)
	local s = hostScene(w, 3)
	local b = hx.openBare(w)
	eq(pickerOf(b).selected, nil, "nothing is selected after the first search")
	same(pickerNode(b).c or {}, {}, "so the preview is empty")
	eq(w.kv.store["triage"], nil, "and nothing was marked seen")
	refreshNow(w, b)
	eq(pickerOf(b).selected, nil, "a refresh selects nothing")
	b.typeText("/")
	b.typeText("2")
	eq(pickerOf(b).selected, nil, "nor does a search")
	b.press("escape")
	b.press("escape")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_231", "Down from nothing takes the first row")
	b.press("escape")
	eq(pickerOf(b).selected, nil, "Escape closes the preview")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	eq(pickerOf(b).selected, "no_2fr_232", "a row event selects it")
	refreshNow(w, b)
	eq(pickerOf(b).selected, "no_2fr_232", "a refresh keeps it")
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60), searchItem(3, "o/r", EPOCH - 180) }
	refreshNow(w, b)
	eq(pickerOf(b).selected, nil, "a refresh that drops its item leaves nothing selected, not a neighbour")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	pickScope(b, "prs:v2")
	w.flush()
	eq(pickerOf(b).selected, nil, "another view opens with nothing selected")
end)

case("host: ? lists the shortcuts of the current mode, and a ? is plain text while searching", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("?")
	local queueKeys = helpKeys(b.view().layer)
	for _, key in { "↑", "↓", "enter", "w", "/", "tab", "r", "s", "?" } do
		yes(queueKeys[key], "the queue list shows " .. key)
	end
	local entries = helpEntries(b.view().layer)
	same(entries[1].caps, { "↑", "↓", "j", "k" }, "the first row puts its four keycaps in its caps text")
	has(entries[1].text, "Move through the pull requests", "and what it does in its text")
	lacks(entries[1].text, "↑", "apart from them")
	local row: any = findKey(findKey(b.view().layer, "keys"), "r1")
	same({ row.c[1].p.key, row.c[2].p.key }, { "caps", "text" }, "a row is its caps and its description")
	for i, cap in row.c[1].p.spans do
		if i % 2 == 1 then
			eq(cap.s, "key", "each keycap wears the key token")
		else
			eq(cap, " ", "a gap between them")
		end
	end
	eq(b.press("j", nil, "j"), false, "other keys are not consumed while the list is open")
	eq(b.press("escape"), true, "Escape closes the list")
	eq(findKey(b.view().layer, "help"), nil, "it is gone")
	b.typeText("/")
	b.typeText("?jk")
	eq(pickerOf(b).query, "?jk", "while searching ? j and k are text")
	eq(findKey(b.view().layer, "help"), nil, "no list opened")
	b.press("escape")
	b.press("escape")
	b.typeText("s")
	b.typeText("?")
	local settingsKeys = helpKeys(b.view().layer)
	for _, key in { "↑", "↓", "enter", "esc", "tab", "?" } do
		yes(settingsKeys[key], "the settings list shows " .. key)
	end
	b.press("escape")
	b.press("escape")
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "Escape closes the list, then Settings")
end)

case("host: the documented queue keys move, open, refresh and switch filters", function(w: World)
	local s = hostScene(w, 12)
	local b = openQueue(w)
	b.typeText("j")
	eq(pickerOf(b).selected, "no_2fr_232", "j moves down")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_233", "Down moves down")
	b.typeText("k")
	eq(pickerOf(b).selected, "no_2fr_232", "k moves up")
	b.press("home")
	eq(pickerOf(b).selected, "no_2fr_231", "Home jumps to the first PR")
	b.press("page_down")
	eq(pickerOf(b).selected, "no_2fr_2311", "Page Down jumps ten")
	b.press("page_up")
	eq(pickerOf(b).selected, "no_2fr_231", "Page Up jumps back ten")
	b.press("end")
	eq(pickerOf(b).selected, "no_2fr_2312", "End jumps to the last PR")
	b.press("enter")
	eq(w.opened[#w.opened], prLink("open", "o/r", 12), "Enter opens the selected PR in a Browser block")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 12), "w checks it out in a worktree")
	b.typeText("r")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "r refreshes")
	b.press("tab")
	eq(pickerOf(b).focus, "scopes", "Tab moves to the filters")
	b.press("down")
	eq(pickerOf(b).scope, "prs:v2", "Down in the filter list switches view")
	b.typeText("s")
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "s opens Settings")
	eq(pickerNode(b).k, "picker", "as a sheet over the queue")
end)

case("host: Settings › Keys binds an action to a key: the key works, ? and the action bar show it, and Reset goes back to no key", function(w: World)
	hostScene(w, 3)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	goToSettings(b, "keys")
	local page: any = nil
	for _, p in prefsOf(b).pages do
		if p.id == "keys" then
			page = p
		end
	end
	same(page, { id = "keys", label = "Keyboard shortcuts", group = "Queue", icon = "keyboard" }, "Keyboard shortcuts is a page of the Queue group")
	local ids: { string } = {}
	for _, r in prefsOf(b).sections[1].rows do
		table.insert(ids, r.id)
	end
	same(ids, { "key:down", "key:up", "key:worktree", "key:goto", "key:agent", "key:agentgo", "key:seen", "key:snooze", "key:snoozed", "key:attention", "key:sort", "key:wt-cleanup", "key:wt-remove", "key:more", "key:search", "key:refresh", "key:settings", "key:help" }, "one row for each action of the queue")
	eq(prefsOf(b).sections[1].title, "Queue", "under the queue's title")
	local row = rowIn(b, "key:worktree")
	eq(row.label, "Worktree", "named for its action")
	eq(row.control.value, "", "with no key: only the command palette has one by default")
	eq(row.control.placeholder, "None", "which it says")
	eq(row.changed, false, "the default is no change")
	eq(row.defaultLabel, "None", "and is what Reset goes back to")
	eq(rowIn(b, "key:more").control.value, ".", "the command palette's key is .")
	for _, a in pickerOf(b).actions do
		eq(a.id, "more", "the action bar shows only the command palette's button, the one with a key")
	end
	eq(bindKey(b, "worktree", "w"), nil, "a free key is accepted")
	eq(prefsOf(b).editing, nil, "and closes the edit")
	same(w.kv.get("keys"), { worktree = "w" }, "it is saved as the one difference from the defaults")
	row = rowIn(b, "key:worktree")
	eq(row.control.value, "w", "the row shows it")
	eq(row.changed, true, "as a change")
	eq(bindKey(b, "down", "j"), nil, "a move key binds too")
	eq(bindKey(b, "help", "h"), nil, "and so does the list's own")
	same(w.kv.get("keys"), { down = "j", help = "h", worktree = "w" }, "each is saved beside the others")
	b.press("escape")
	local opened = #w.opened
	eq(b.press("w", "s", "W"), false, "a key no action has is left to the pane")
	eq(#w.opened, opened, "and opens nothing")
	eq(b.press("w", nil, "w"), true, "the bound one is handled")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and makes the selected pull request's worktree")
	b.typeText("j")
	eq(pickerOf(b).selected, "no_2fr_232", "j moves down")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_233", "and the arrow still does")
	b.typeText("k")
	eq(pickerOf(b).selected, "no_2fr_233", "an action nobody bound has no key")
	same(actionOf(b, "worktree").keys, { "w" }, "the action bar shows the button once it has a key")
	eq(actionOf(b, "agent"), nil, "and none for an action without one")
	b.typeText("?")
	eq(findKey(b.view().layer, "help"), nil, "? opens nothing")
	b.typeText("h")
	local shown: { string } = {}
	for _, r in helpRows(b.view().layer) do
		table.insert(shown, r.keys)
	end
	same(shown, { "↑ ↓ j", "Enter", "w", ".", "Tab", "h" }, "the list shows every key there is")
	eq(b.press("h", nil, "h"), true, "its key closes it")
	eq(findKey(b.view().layer, "help"), nil, "and it is gone")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	b.typeText("h")
	local inSettings = helpRows(b.view().layer)
	eq(inSettings[#inSettings].keys, "h", "Settings' own list shows it")
	b.press("escape")
	eq(prefsOf(b).page, "keys", "Settings reopened on the Keys page it last showed")
	b.event({ ev = "change", id = "layer.settings", item = "key:worktree" })
	same(w.kv.get("keys"), { down = "j", help = "h" }, "Reset drops that one change")
	row = rowIn(b, "key:worktree")
	eq(row.control.value, "", "the row has no key again")
	eq(row.changed, false, "as no change")
	b.event({ ev = "change", id = "layer.settings", item = "key:down" })
	b.event({ ev = "change", id = "layer.settings", item = "key:help" })
	same(w.kv.get("keys"), {}, "Reset on the others leaves nothing changed")
	eq(bindKey(b, "refresh", "R"), nil, "a key can be bound again")
	same(w.kv.get("keys"), { refresh = "R" }, "and is saved")
	eq(bindKey(b, "refresh", ""), nil, "and removed")
	same(w.kv.get("keys"), {}, "which is no change: nothing stays saved")
	b.press("escape")
	eq(b.press("w", nil, "w"), false, "the reset key is the pane's again")
end)

case("host: an empty Keys row removes a shortcut: no key does it, ? and the action bar leave it out, and the command palette's Reset brings its . back", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "keys")
	for _, id in { "worktree", "agent", "search", "down", "up", "more" } do
		eq(bindKey(b, id, ""), nil, "an empty row is accepted: " .. id)
	end
	local saved = w.kv.get("keys")
	for _, id in { "worktree", "agent", "search", "down", "up" } do
		eq(saved[id], nil, "no key is the default, so nothing is saved for it: " .. id)
	end
	eq(saved.more, "", "the command palette's removal is saved")
	local row = rowIn(b, "key:worktree")
	eq(row.control.value, "", "the row is empty")
	eq(row.changed, false, "as it is by default")
	row = rowIn(b, "key:more")
	eq(row.control.value, "", "the palette's row is empty too")
	eq(row.changed, true, "and changed")
	eq(row.defaultLabel, ".", "so Reset can bring its key back")
	b.press("tab", "s")
	eq(prefsOf(b).page, "prompts", "the Prompts page is before Keys")
	b.press("escape")
	local opened = #w.opened
	for _, k in { "w", "a", "." } do
		eq(b.press(k, nil, k), false, k .. " is left to the pane")
	end
	eq(#w.opened, opened, "nothing was opened")
	b.typeText("/")
	eq(pickerOf(b).query, nil, "/ opens no search")
	b.typeText("j")
	eq(pickerOf(b).selected, "no_2fr_231", "j moves nowhere")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_232", "the arrow does")
	b.typeText("k")
	eq(pickerOf(b).selected, "no_2fr_232", "k does not move up")
	b.press("up")
	eq(pickerOf(b).selected, "no_2fr_231", "the arrow does")
	eq(actionOf(b, "worktree"), nil, "the action bar leaves the button out")
	eq(actionOf(b, "more"), nil, "the palette's too")
	b.typeText("?")
	local shown: { string } = {}
	for _, r in helpRows(b.view().layer) do
		table.insert(shown, r.keys)
	end
	same(shown, { "↑ ↓", "Enter", "g", "G", "m", "z", "Z", "n", "o", "Tab", "r", "s", "?" }, "the list leaves out what has no key")
	b.press("escape")
	goToSettings(b, "keys")
	eq(bindKey(b, "help", ""), nil, "the list's own key can go")
	eq(bindKey(b, "settings", ""), nil, "and Settings'")
	b.press("escape")
	b.typeText("?")
	eq(findKey(b.view().layer, "help"), nil, "no key opens the list")
	b.typeText("s")
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "no key opens Settings")
	eq(actionOf(b, "settings"), nil, "and its button is gone")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "the event still opens it")
	b.typeText("?")
	eq(findKey(b.view().layer, "help"), nil, "Settings has no key for its list either")
	b.press("tab")
	b.press("tab")
	b.event({ ev = "change", id = "layer.settings", item = "key:more" })
	eq(w.kv.get("keys").more, nil, "Reset brings the palette's key back")
	b.press("escape")
	eq(b.press(".", nil, "."), true, "and it works again")
	eq(w.opened[#w.opened], "plotroom://more", "opening the command palette")
end)

case("host: the empty queue's hint names the Settings key, or just Settings when it has none", function(w: World)
	hostScene(w, 3)
	w.kv.put("views-prs", { version = 1, nextId = 1, items = array({}) })
	w.kv.put("views-issues", { version = 1, nextId = 1, items = array({}) })
	local b = openQueue(w)
	eq(pickerOf(b).empty[1].t, "No saved views yet. Press s to add one.", "the hint names the key")
	w.kv.put("keys", { settings = "S" })
	b.render()
	eq(pickerOf(b).empty[1].t, "No saved views yet. Press S to add one.", "as it is now")
	w.kv.put("keys", { settings = "" })
	b.render()
	eq(pickerOf(b).empty[1].t, "No saved views yet. Press . and pick Settings to add one.", "or the command palette's once it is removed")
	w.kv.put("keys", { settings = "", more = "" })
	b.render()
	eq(pickerOf(b).empty[1].t, "No saved views yet. Open Settings to add one.", "or just Settings with neither")
end)

case("host: the In tab tooltip names the key that goes to the tab, or none once it is removed", function(w: World)
	local s = hostScene(w, 3)
	leaveWt(w, s, 1)
	local b = openQueue(w)
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-pr-1/src" })
	b.render()
	local function tip(): string?
		for _, badge in pickerOf(b).items[1].badges do
			if badge.text == "In tab" then
				return badge.title
			end
		end
		return nil
	end
	eq(tip(), "A tab works in this pull request's worktree (g goes there)", "the tooltip names the key")
	w.kv.put("keys", { ["goto"] = "G" })
	b.render()
	eq(tip(), "A tab works in this pull request's worktree (G goes there)", "as it is now, the rows rebuilt")
	same(actionOf(b, "goto").keys, { "G" }, "like the button's keycap")
	w.kv.put("keys", { ["goto"] = "" })
	b.render()
	eq(tip(), "A tab works in this pull request's worktree", "and not at all once it is removed")
	eq(actionOf(b, "goto"), nil, "nor is the button shown")
end)

case("host: the preview lists the branch and the base apart, each with a copy icon that copies its name", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local refs: { [string]: string } = { branch = "branch-1", base = "main" }
	for key, name in refs do
		local icon: any = findKey(findKey(pickerNode(b), key), "copy", "icon")
		eq(icon.p.href, name, key .. ": Tern's copy action copies the href")
		eq(icon.p.actions.click, "copy", key .. ": on click")
	end
end)

case("host: the bar's Settings and Refresh events do what their keys do", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	local function act(id: string)
		b.event({ ev = "action", id = "layer.queue", act = id })
	end
	act("retry")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "Refresh searches again")
	act("settings")
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "Settings opens the settings page")
end)

-- What the command palette's `menu` answer of block `b` says now: the queue actions' ids in order with their groups, keys
-- and labels by id, and the ids of the window commands that apply.
hx.paletteAsks = 0
function hx.palette(w: World, b: Block): any
	hx.paletteAsks += 1
	local id = "pal" .. hx.paletteAsks
	request(b, id, { op = "menu", palette = true })
	w.flush()
	local a: any = answerOf(b, id)
	local out: any = { ids = {}, groups = {}, keys = {}, labels = {}, commands = {} }
	for _, q in a.queue do
		table.insert(out.ids, q.id)
		out.groups[q.id], out.keys[q.id], out.labels[q.id] = q.group, q.key, q.label
	end
	for _, c in a.commands do
		table.insert(out.commands, c)
	end
	return out
end

case("host: the command palette's menu lists the queue actions and the commands the block offers now, in groups, and a queue event runs only one of those", function(w: World)
	local s = hostScene(w, 3)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	eq(findKey(b.view().main, "more").p.href, "plotroom://more", "the palette's link is always on screen, for the window to check")
	eq(pickerOf(b).strip.label, "Sort: Default (search order)", "the current order is in the strip, which narrow windows keep")
	local p = hx.palette(w, b)
	same(p.ids, { "open", "worktree", "seen", "snooze", "close-preview", "agent", "snoozed", "attention", "sort", "search", "refresh", "settings", "help" }, "the selected item's, then the view's and the configuration's: no Go to tab or Go to agent without a tab or an agent, no Unpin without a pin")
	eq(p.labels.open, "Open in GitHub", "Open names the integration")
	eq(p.keys.worktree, "", "an action without a key says none")
	eq(p.groups.open, "Item", "the selected item's actions are the Item group")
	eq(p.groups["close-preview"], "Item", "Close preview among them")
	eq(p.groups.agent, "Agents", "the agent picker is the Agents group")
	eq(p.groups.sort, "View", "the view's actions are the View group")
	eq(p.groups.settings, "Configuration", "Settings and the shortcut list are Configuration")
	same(p.commands, { "open-url", "export", "import", "worktrees-open", "pr-draft", "comment" }, "the commands: the ones that need no item, then what an open pull request takes")
	request(b, "c2", { op = "menu" })
	w.flush()
	eq(answerOf(b, "c2").queue, nil, "the agent picker's menu carries no queue actions")
	eq(answerOf(b, "c2").commands, nil, "nor commands")
	local opened = #w.opened
	b.event({ ev = "action", act = "queue", value = "goto" })
	b.event({ ev = "action", act = "queue", value = "unpin" })
	b.event({ ev = "action", act = "queue", value = "rm" })
	eq(#w.opened, opened, "an action not offered now does nothing")
	b.event({ ev = "action", act = "queue", value = "worktree" })
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "an offered one runs as its key would")
	b.event({ ev = "action", act = "queue", value = "refresh" })
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "Refresh searches again")
	b.event({ ev = "action", act = "queue", value = "close-preview" })
	eq(pickerOf(b).selected, nil, "Close preview clears the selection")
	eq(pickerOf(b).preview, "none", "no preview pane is left open")
	eq(#(pickerNode(b).c or {}), 0, "and nothing is drawn in it")
	p = hx.palette(w, b)
	same(p.ids, { "snoozed", "attention", "sort", "search", "refresh", "settings", "help" }, "with nothing selected only the view's and the configuration's remain")
	same(p.commands, { "open-url", "export", "import", "worktrees-open" }, "and the commands that need no item")
	opened = #w.opened
	b.event({ ev = "action", act = "queue", value = "worktree" })
	eq(#w.opened, opened, "an item action does nothing with nothing selected")
	b.event({ ev = "action", act = "queue", value = "search" })
	eq(pickerOf(b).query, "", "Search opens the search")
end)

case("host: with no pull request selected Enter and w open nothing", function(w: World)
	hostScene(w, 0)
	local b = openQueue(w)
	eq(#listed(b), 0, "an empty result lists nothing")
	eq(pickerOf(b).state, "ready", "and is not an error")
	b.press("enter")
	b.typeText("w")
	eq(#w.opened, 0, "the keys open nothing")
end)

case("host: Escape cancels a settings edit, Enter saves it, and a rejected value keeps its warning and its draft", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "views")
	eq(prefsOf(b).focus, "vopen:prs:v1", "the first view is a one-row summary")
	expand(b, "vopen:prs:v1")
	eq(prefsOf(b).focus, "name:prs:v1", "the first row is focused")
	b.press("enter")
	eq(prefsOf(b).editing.row, "name:prs:v1", "Enter starts the edit")
	b.typeText(" j?")
	eq(prefsOf(b).editing.draft, "My PRs j?", "keys are text while editing")
	eq(b.press("escape"), true, "Escape is handled")
	eq(prefsOf(b).editing, nil, "Escape ends the edit")
	eq(w.kv.get("views-prs").items[1].name, "My PRs", "nothing was saved")
	b.press("enter")
	b.typeText("!")
	eq(b.press("enter"), true, "Enter is handled")
	eq(prefsOf(b).editing, nil, "Enter ends the edit")
	eq(w.kv.get("views-prs").items[1].name, "My PRs!", "and saves it")
	has(b.title(), "My PRs!", "the title follows the new name")
	b.event({ ev = "select", id = "layer.settings", item = "query:prs:v1" })
	b.press("enter")
	for _ = 1, 18 do
		b.press("backspace")
	end
	b.press("enter")
	eq(rowIn(b, "query:prs:v1").warning, "A query is required.", "the rejected query is explained under its row")
	eq(prefsOf(b).editing.row, "query:prs:v1", "the edit stays open for a correction")
	eq(prefsOf(b).editing.draft, "", "with the draft")
	eq(w.kv.get("views-prs").items[1].query, "is:open author:@me", "nothing was saved")
	eq(#requestsOf(s.gh, "search"), 1, "and nothing was searched")
	b.typeText("is:open label:bug")
	b.press("enter")
	eq(rowIn(b, "query:prs:v1").warning, nil, "a saved value clears the warning")
	eq(prefsOf(b).editing, nil, "and closes the edit")
	eq(w.kv.get("views-prs").items[1].query, "is:open label:bug", "the correction is saved")
	w.flush()
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 2, "the active view searches again")
	has(searches[2].fields.q, "label:bug", "with its new query")
end)

case("host: a view that cannot be written keeps its draft and says why; an unchanged Enter writes nothing", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	w.kv.failSet["views-prs"] = "read-only file system"
	b.press("enter")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "Enter on unchanged text only closes the edit")
	eq(rowIn(b, "name:prs:v1").warning, nil, "without a write, so without a warning")
	b.press("enter")
	b.typeText("2")
	b.press("enter")
	has(rowIn(b, "name:prs:v1").warning, "read-only file system", "a failed write is explained under its row")
	eq(prefsOf(b).editing.draft, "My PRs2", "the draft is kept for another try")
	eq(w.kv.get("views-prs").items[1].name, "My PRs", "nothing was written")
	w.kv.failSet["views-prs"] = nil
	b.press("enter")
	eq(rowIn(b, "name:prs:v1").warning, nil, "the retry saved it and cleared the warning")
	eq(w.kv.get("views-prs").items[1].name, "My PRs2", "the draft was saved")
end)

case("host: a opens the selected PR's agent link", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local n = string.match(pickerOf(b).selected, "_23(%d+)$") :: string
	local link: any = findKey(pickerNode(b), "agent")
	eq(link.p.href, "plotroom://github/agent/o/r/" .. n, "the card keeps the selected PR's Agent link")
	eq(findKey(pickerNode(b), "buttons").p.hidden, true, "unseen: the action bar has no Agent button")
	b.typeText("a")
	eq(w.opened[#w.opened], "plotroom://github/agent/o/r/" .. n, "a opens it")
end)

case("host: setup commands are added, edited and removed per repository; unreadable ones are never overwritten", function(w: World)
	hostScene(w, 3)
	w.kv.put("setup-commands", { ["x/y"] = array({ "make" }) })
	local b = openQueue(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	local function save(row: string, text: string)
		b.event({ ev = "select", id = "layer.settings", item = row })
		b.press("enter")
		for _ = 1, 40 do
			b.press("backspace")
		end
		b.typeText(text)
		b.press("enter")
	end
	save("setup:o/r:new", "pnpm install")
	save("setup:o/r:new", "cp ../r/.env .")
	same(w.kv.get("setup-commands")["o/r"], { "pnpm install", "cp ../r/.env ." }, "added in order under the launch repo")
	same(w.kv.get("setup-commands")["x/y"], { "make" }, "another repository's commands are kept")
	eq(rowIn(b, "setup:o/r:2").control.value, "cp ../r/.env .", "each command is a row")
	save("setup:o/r:1", "pnpm i")
	same(w.kv.get("setup-commands")["o/r"], { "pnpm i", "cp ../r/.env ." }, "edited in place")
	save("setup:o/r:1", "")
	same(w.kv.get("setup-commands")["o/r"], { "cp ../r/.env ." }, "emptying a command removes it")
	eq(prefsOf(b).focus, "setup:o/r:new", "focus moves to the add row")
	save("setup:o/r:1", "")
	eq(w.kv.get("setup-commands")["o/r"], nil, "the last one removed drops the repository's entry")
	w.kv.put("setup-commands", "garbage")
	b.render()
	yes(type(rowIn(b, "setup:o/r:new").disabled) == "string", "an unreadable map disables the rows")
	eq(w.kv.get("setup-commands"), "garbage", "and is never overwritten")
end)

case("host: unreadable or malformed saved views are shown as defaults and never overwritten", function(w: World)
	hostScene(w, 3)
	local saved = { version = 1, nextId = 9, items = array({ { id = "v7", name = "Mine", integration = "github", query = "is:open label:x", group = "none", prompts = array({}) } }) }
	w.kv.put("views-prs", saved)
	w.kv.failGet["views-prs"] = "disk offline"
	local b = openQueue(w)
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the queue still works with the default views")
	has(b.text(), "disk offline", "the cause is on screen")
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	has(rowIn(b, "name:prs:v1").disabled, "disk offline", "the rows are locked, with the cause")
	has(rowIn(b, "query:prs:v1").disabled, "disk offline", "and so is every other row of the form")
	same(w.kv.get("views-prs"), saved, "the saved views were not overwritten")
	w.kv.failGet["views-prs"] = nil
	w.kv.put("views-prs", { version = 2 })
	local other = openQueue(w, 2)
	same(listed(other), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "malformed views show the defaults too")
	same(w.kv.get("views-prs"), { version = 2 }, "and are not overwritten either")
end)

case("host: a first run saves the default views of both kinds, Add creates one, and Delete asks the window to confirm", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat" -- a view with its own login runs as it, by token
	local b = openQueue(w)
	eq(#w.kv.get("views-prs").items, 2, "the default pull request views were saved")
	same({ w.kv.get("views-prs").items[1].name, w.kv.get("views-prs").items[2].name }, { "My PRs", "Review requested" }, "the pull request seeds")
	eq(#w.kv.get("views-issues").items, 4, "and the default issue views beside them, in a store of their own")
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "the signed-in account's Add saved a new view")
	same(w.kv.get("views-prs").items[3].logins, { "octocat" }, "for that account")
	eq(prefsOf(b).editing.row, "name:prs:v3", "and starts naming it")
	b.press("escape")
	eq(w.kv.get("views-prs").items[3].name, "New view", "cancelling the naming keeps the placeholder name")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "the new view became the active one and was searched")
	has(b.title(), "New view", "the title shows it")
	expand(b, "vopen:prs:v2")
	b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v2" })
	b.press("enter")
	local ask = pendingOf(b)
	same({ ask.row, ask.label }, { "delete:prs:v2", "Delete view" }, "Delete asks the window to confirm: this row, this action")
	has(ask.head, "Review requested", "naming the view")
	eq(w.opened[#w.opened], "plotroom://confirm", "through the window's link")
	eq(findKey(b.view().layer, "confirm"), nil, "Settings draws no overlay of its own")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "delete:prs:v3" })
	eq(#w.kv.get("views-prs").items, 3, "a confirmation of another row deletes nothing")
	b.typeText("d")
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "d and Enter do not confirm it")
	b.event({ ev = "action", id = "layer.settings", act = "cancel-delete", value = ask.row })
	eq(pendingOf(b), nil, "cancelling clears the question")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = ask.row })
	eq(#w.kv.get("views-prs").items, 3, "and a late confirmation deletes nothing")
	b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v2" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = ask.row })
	eq(pendingOf(b), nil, "confirming closes the question")
	local items = w.kv.get("views-prs").items
	eq(#items, 2, "and deletes the view")
	eq(items[2].id, "v3", "the other views stay")
	expand(b, "vopen:prs:v3")
	b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v3" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "delete:prs:v3" })
	w.flush()
	eq(#w.kv.get("views-prs").items, 1, "the active view can be deleted too")
	eq(pickerOf(b).scope, "issues:v1", "the filter now at its place in the list is shown: the pull request filters are followed by the issue filters")
end)

windowCase("window: a Settings delete is confirmed in the palette with Cancel first; only the destructive item deletes, Cancel and dismissing delete nothing", function(w: World)
	local _, b = agentScene(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v2")
	-- Presses Delete on the second view and follows the link the block opened; returns the question and the picker the window showed.
	local function ask(): (any, any)
		b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v2" })
		b.press("enter")
		local question = pendingOf(b)
		w.click(w.opened[#w.opened])
		w.flush()
		return question, w.window.picks[#w.window.picks]
	end
	local function views(): number
		return #w.kv.get("views-prs").items
	end
	local function lastEvent(): any
		return w.window.events[#w.window.events]
	end
	w.window.choose = "Cancel"
	local question, pick = ask()
	eq(#pick.items, 2, "two items")
	same({ pick.items[1].label, pick.items[1].icon }, { "Cancel", "x" }, "Cancel comes first")
	same({ pick.items[2].label, pick.items[2].detail, pick.items[2].icon, pick.items[2].confirm }, { question.label, question.detail, "trash", true }, "the destructive item second, as the block worded it")
	same({ pick.placeholder, pick.icon }, { question.head, "trash" }, "under the block's question")
	same(lastEvent(), { pane = 1, ev = { ev = "action", act = "cancel-delete", value = "delete:prs:v2" } }, "Cancel tells the pane to drop the question")
	eq(pendingOf(b), nil, "which does")
	eq(views(), 2, "and nothing is deleted")
	w.window.choose = nil
	ask()
	same(lastEvent(), { pane = 1, ev = { ev = "action", act = "cancel-delete", value = "delete:prs:v2" } }, "dismissing the picker cancels too")
	eq(views(), 2, "and nothing is deleted")
	w.window.choose = "Delete view"
	ask()
	same(lastEvent(), { pane = 1, ev = { ev = "action", act = "confirm-delete", value = "delete:prs:v2" } }, "the destructive item tells the pane to delete that row")
	eq(views(), 1, "the view is deleted")
	eq(pendingOf(b), nil, "and the question is closed")
end)

windowCase("window: the confirm link is refused from a pane of another version or another block, and with nothing pending", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local surface: any = w.window.surfaces[1]
	local question = jsonEncode({ row = "delete:prs:v2", head = "Delete view “B”?", label = "Delete view", detail = "Gone from every Plotroom pane" })
	local function refused(text: string, what: string, pane: number?)
		local said = #w.toasts
		w.click("plotroom://confirm", pane)
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		has(w.toasts[#w.toasts].text, text, what .. ": what is wrong")
		eq(#w.window.picks + #w.window.events, 0, what .. ": nothing was picked or sent")
	end
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = "2", hidden = true } }, { id = "main.confirm", p = { text = question, hidden = true } } } }
	refused("another version", "another protocol")
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = "17", hidden = true } } } }
	refused("nothing to delete", "no question")
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = "17", hidden = true } }, { id = "main.confirm", p = { text = "{not json", hidden = true } } } }
	refused("nothing to delete", "a malformed question")
	refused("did not come from a Plotroom block", "a pane that is not Plotroom", 2)
end)

case("host: Tab cycles the Settings pages in order, Views, Prompts, Keys, Worktrees, Repositories, Jira, Refresh, and Shift+Tab goes back; they are the same whichever kind of filter is shown", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	local b = openQueue(w)
	b.typeText("s")
	local pages: { string } = { prefsOf(b).page }
	for _ = 1, 7 do
		b.press("tab")
		table.insert(pages, prefsOf(b).page)
	end
	same(pages, { "views", "prompts", "keys", "worktrees", "repos", "jira", "connection", "views" }, "Tab walks the pages and wraps around")
	b.press("tab", "s")
	eq(prefsOf(b).page, "connection", "Shift+Tab goes back, wrapping the other way")
	b.press("escape")
	b.typeText("s")
	eq(prefsOf(b).page, "connection", "Settings reopens on the page it last showed")
	b.press("escape")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	eq(prefsOf(b).page, "connection", "and so does its button")
	local function ids(): { string }
		local out: { string } = {}
		for _, p in prefsOf(b).pages do
			table.insert(out, p.id)
		end
		return out
	end
	local expected = { "views", "prompts", "keys", "worktrees", "repos", "jira", "connection" }
	same(ids(), expected, "a pull request filter's pages")
	local byId: { [string]: any } = {}
	for _, p in prefsOf(b).pages do
		byId[p.id] = p
	end
	same(byId.worktrees, { id = "worktrees", label = "Worktrees", group = "Code", icon = "tree" }, "Worktrees is a page of the Code group")
	same(byId.connection, { id = "connection", label = "Refresh", group = "Connection", icon = "gauge" }, "and Refresh the Connection group's")
	b.press("escape")
	pickScope(b, "issues:v1")
	b.typeText("s")
	same(ids(), expected, "are an issue filter's")
end)

case("host: a view's Group by is a menu: Enter opens it, the arrows and the pointer move the highlight, Esc closes it, Enter saves; the integration cannot be changed", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", query = "is:open label:x", logins = array({ "work" }), group = "none", prompts = array({}) } }) })
	local b = w.open(1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "issues", activeViewId = "v1" })
	w.flush()
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	eq(rowIn(b, "vint:issues:v1"), nil, "the form has no Integration row")
	b.event({ ev = "change", id = "layer.settings", item = "vint:issues:v1", value = "jira" })
	eq(w.kv.get("views-issues").items[1].integration, "github", "an event for it changes nothing")
	b.event({ ev = "change", id = "layer.settings", item = "vint:issues:v1" })
	eq(w.kv.get("views-issues").items[1].query, "is:open label:x", "and so does Reset on it")
	-- Group by is a menu: Enter opens it on the current option, the arrows move the highlight, Enter picks and closes it.
	local vgroup = "vgroup:issues:v1"
	local menu: any = rowIn(b, vgroup).control
	eq(menu.k, "choice", "Group by is a choice")
	eq(menu.style, "menu", "shown as a menu")
	eq(menu.value, "none", "on None after the integration switched")
	local second: string = menu.options[2].value
	b.event({ ev = "select", id = "layer.settings", item = vgroup })
	b.press("enter")
	same(prefsOf(b).editing, { row = vgroup, option = "none" }, "Enter opens the menu on the current option")
	b.press("down")
	eq(prefsOf(b).editing.option, second, "Down moves the highlight")
	b.press("up")
	eq(prefsOf(b).editing.option, "none", "Up moves it back")
	b.press("right")
	eq(prefsOf(b).editing.option, second, "and so do the other arrows")
	b.event({ ev = "select", id = "layer.settings", item = vgroup .. "=none" })
	eq(prefsOf(b).editing.option, "none", "the pointer on an option moves the highlight there")
	eq(prefsOf(b).focus, vgroup, "without moving the focus")
	eq(w.kv.get("views-issues").items[1].group, "none", "or saving anything")
	b.event({ ev = "action", id = "layer.settings", act = "close", value = vgroup })
	eq(prefsOf(b).editing, nil, "a click outside closes the menu")
	b.press("enter")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc closes it too")
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "leaving Settings open")
	b.press("enter")
	b.press("down")
	b.press("enter")
	eq(w.kv.get("views-issues").items[1].group, second, "Enter on the highlighted option saves it")
	eq(prefsOf(b).editing, nil, "and closes the menu")
	eq(rowIn(b, vgroup).control.value, second, "the row shows it")
end)

-- The prompt editor card of the Settings view; nil when no prompt's text is being edited.
local function editorCard(b: Block): any
	return findKey(b.view().layer, "prompt", "col")
end

-- The text in the card's draft; nil without a card.
local function draftOf(b: Block): string?
	local card: any = editorCard(b)
	local draft: any = if card then findKey(card, "draft", "editor") else nil
	return if draft then draft.p.text else nil
end

-- The warning the card shows under its draft; nil when it shows none.
local function cardWarning(b: Block): string?
	local card: any = editorCard(b)
	local warning: any = if card then findKey(card, "error", "text") else nil
	return if warning then warning.p.spans[1].t else nil
end

-- The text kv keeps for the prompt at `index`.
local function savedText(w: World, index: number): string
	return w.kv.get("prompts-prs").items[index].text
end

-- Where the block last put the caret: the id of the field, "released" for none; nil when it never moved it.
local function caretOf(w: World): string?
	local last = w.frames[#w.frames]
	local op: any = if last then last.ops[1] else nil
	if op == nil or op[1] ~= "focus" then
		return nil
	end
	return if op[2] == NULL then "released" else op[2]
end

case("host: Add prompt asks for a name, then opens the text in a multi-line editor where Enter breaks lines and ⌘Enter saves it trimmed", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {})
	local b = openQueue(w)
	goToSettings(b, "prompts")
	eq(prefsOf(b).focus, "padd:prs", "with nothing saved the Add row is the first")
	b.press("enter")
	same(w.kv.get("prompts-prs"), { version = 1, nextId = 2, items = array({ promptOf("p1", "New action", "") }) }, "Add saves a prompt with no text at once, offered under every view")
	eq(prefsOf(b).editing.row, "pname:prs:p1", "and starts naming it")
	eq(prefsOf(b).editing.draft, "", "from an empty draft")
	eq(editorCard(b), nil, "the text editor waits for the name")
	eq(caretOf(w), nil, "and the caret has not been moved")
	b.press("enter")
	eq(rowIn(b, "pname:prs:p1").warning, "A name is required.", "an empty name is refused under its row")
	eq(prefsOf(b).editing.row, "pname:prs:p1", "and the name edit stays open")
	eq(w.kv.get("prompts-prs").items[1].name, "New action", "with nothing saved")
	b.typeText("Review")
	b.press("enter")
	eq(w.kv.get("prompts-prs").items[1].name, "Review", "Enter saves the name")
	eq(prefsOf(b).editing, nil, "the name edit is over")
	yes(editorCard(b) ~= nil, "and a prompt with no text opens its text editor next")
	eq(editorCard(b).p.role, "omp.prefs.editor", "in the editor card")
	eq(findKey(editorCard(b), "head", "text").p.spans[1].t, "Prompt · Review", "which names the prompt")
	eq(draftOf(b), "", "with nothing in it")
	eq(caretOf(w), "layer.settings.prompt.draft", "and the caret in its field")
	eq(prefsOf(b).focus, "ptext:prs:p1", "the prompt's text row is the focused one")
	eq(rowIn(b, "ptext:prs:p1").hint, "Empty", "and says it is empty")
	b.press("enter")
	b.typeText("  Review {url}")
	b.press("enter")
	b.typeText("Then summarise.")
	b.press("enter")
	b.press("enter")
	eq(draftOf(b), "\n  Review {url}\nThen summarise.\n\n", "Enter inserts a line break")
	eq(savedText(w, 1), "", "and saves nothing")
	b.press("enter", "m")
	eq(savedText(w, 1), "Review {url}\nThen summarise.", "⌘Enter saves the text without the blanks around it")
	eq(editorCard(b), nil, "and closes the editor")
	eq(caretOf(w), "released", "giving the caret back")
	eq(rowIn(b, "ptext:prs:p1").hint, "Review {url}", "the row shows the text's first line")
	b.press("enter")
	eq(draftOf(b), "Review {url}\nThen summarise.", "Edit… opens the saved text")
	eq(caretOf(w), "layer.settings.prompt.draft", "with the caret in the field")
	b.press("up")
	b.typeText("!")
	eq(draftOf(b), "Review {url}!\nThen summarise.", "Up moves a line inside the editor")
	b.press("escape")
	eq(editorCard(b), nil, "Esc closes the editor")
	eq(savedText(w, 1), "Review {url}\nThen summarise.", "and drops what was typed")
	eq(caretOf(w), "released", "giving the caret back")
	b.press("enter")
	b.typeText(" Be brief.")
	b.press("enter", "c")
	eq(savedText(w, 1), "Review {url}\nThen summarise. Be brief.", "Ctrl+Enter saves as well")
end)

case("host: naming a new prompt with the placeholder name itself still opens its text editor", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {})
	local b = openQueue(w)
	goToSettings(b, "prompts")
	b.press("enter")
	b.typeText("New action")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "the name edit is over")
	eq(w.kv.get("prompts-prs").items[1].name, "New action", "the name stays what it was")
	yes(editorCard(b) ~= nil, "and the prompt, still with no text, opens its text editor")
	eq(caretOf(w), "layer.settings.prompt.draft", "with the caret in its field")
end)

case("host: a prompt's text that is empty or over 8000 bytes stays in the editor with the card's warning; Save and Cancel act like ⌘Enter and Esc", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	b.press("down")
	eq(prefsOf(b).focus, "ptext:prs:p1", "the prompt's text row")
	b.press("enter")
	b.press("a", "c")
	b.press("backspace")
	b.press("enter", "m")
	eq(cardWarning(b), "A prompt is required.", "an empty text is refused in the card")
	eq(draftOf(b), "", "the edit stays open")
	eq(savedText(w, 1), "Review {url}", "and nothing is saved")
	b.typeText("  ")
	b.press("enter")
	b.press("enter", "m")
	eq(cardWarning(b), "A prompt is required.", "so is a text of blanks")
	b.press("a", "c")
	b.press("paste", nil, string.rep("x", 8001))
	b.press("enter", "m")
	eq(cardWarning(b), "Over 8000 bytes; shorten it.", "a text over 8000 bytes is refused")
	eq(savedText(w, 1), "Review {url}", "with nothing saved")
	eq(caretOf(w), "layer.settings.prompt.draft", "and the caret stays in the field")
	b.press("backspace")
	b.press("enter", "m")
	eq(#savedText(w, 1), 8000, "8000 bytes are accepted")
	eq(editorCard(b), nil, "and close the editor")
	local cancel: { [string]: any } = { ev = "action", id = "layer.settings.prompt.buttons.cancel", act = "cancel-prompt" }
	local save: { [string]: any } = { ev = "action", id = "layer.settings.prompt.buttons.save", act = "save-prompt" }
	b.press("enter")
	b.press("a", "c")
	b.typeText("Short.")
	b.event(cancel)
	eq(editorCard(b), nil, "Cancel closes the editor like Esc")
	eq(#savedText(w, 1), 8000, "and drops the change")
	eq(caretOf(w), "released", "giving the caret back")
	b.press("enter")
	b.press("a", "c")
	b.typeText("Short.")
	b.event(save)
	eq(savedText(w, 1), "Short.", "Save saves like ⌘Enter")
	eq(editorCard(b), nil, "and closes the editor")
	b.event(save)
	eq(savedText(w, 1), "Short.", "a second click finds nothing to save")
	b.press("enter")
	b.press("a", "c")
	b.press("backspace")
	b.event(save)
	eq(cardWarning(b), "A prompt is required.", "Save refuses an empty text the same way")
	eq(savedText(w, 1), "Short.", "and keeps the saved one")
end)

case("host: a view's Prompts chips keep only prompts that exist, and Enter, Right and Space toggle them from the keyboard", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	b.event({ ev = "select", id = "layer.settings", item = "vprompts:prs:v1" })
	eq(prefsOf(b).focus, "vprompts:prs:v1", "the view's Prompts row")
	local chips: any = rowIn(b, "vprompts:prs:v1").control
	same(chips.values, array({}), "a view that lists none offers every prompt")
	eq(#chips.options, 2, "among all the prompts")
	eq(chips.options[2].value, "p2", "by id")
	eq(chips.options[2].label, "Triage", "and name")
	local function saved(): any
		return w.kv.get("views-prs").items[1].prompts
	end
	local function changed(values: { any })
		b.event({ ev = "change", id = "layer.settings", item = "vprompts:prs:v1", value = array(values) })
	end
	changed({ "p2", "gone" })
	same(saved(), { "p2" }, "a change saves only the prompts that still exist")
	same(rowIn(b, "vprompts:prs:v1").control.values, { "p2" }, "and the row shows them")
	changed({ "p2", "p1" })
	same(saved(), { "p1", "p2" }, "in the prompts' order")
	changed({ "gone" })
	same(saved(), array({}), "none left means every prompt")
	b.press("enter")
	eq(prefsOf(b).editing.row, "vprompts:prs:v1", "Enter starts picking: the chips take the keys")
	eq(prefsOf(b).editing.option, "p1", "at the first prompt")
	b.press("right")
	eq(prefsOf(b).editing.option, "p2", "Right moves to the next prompt")
	b.press("space")
	same(saved(), { "p2" }, "Space turns it on, saved at once")
	b.press("enter")
	same(saved(), array({}), "Enter turns it off again")
	b.press("right")
	eq(prefsOf(b).editing.option, "p2", "Right stops at the last prompt")
	b.press("left")
	b.press("left")
	eq(prefsOf(b).editing.option, "p1", "Left stops at the first")
	b.press("space")
	same(saved(), { "p1" }, "and toggles that one")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc leaves the chips")
	eq(prefsOf(b).page, "views", "with Settings still open")
	b.press("space")
	eq(prefsOf(b).editing.option, "p1", "Space starts picking too")
	b.press("down")
	eq(prefsOf(b).editing, nil, "any other key leaves the chips")
	eq(prefsOf(b).focus, "vopen:prs:v2", "and does what it does")
	same(saved(), { "p1" }, "without changing the prompts")
end)

case("host: Delete on a prompt asks the window to confirm, naming it: confirming deletes it, cancelling keeps it", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	b.event({ ev = "select", id = "layer.settings", item = "pdelete:prs:p1" })
	b.press("enter")
	local ask = pendingOf(b)
	same({ ask.row, ask.head, ask.label }, { "pdelete:prs:p1", "Delete action “Review”?", "Delete action" }, "Delete asks the window to confirm, naming the prompt")
	eq(w.opened[#w.opened], "plotroom://confirm", "through the window's link")
	b.event({ ev = "action", id = "layer.settings", act = "cancel-delete", value = "pdelete:prs:p1" })
	eq(#w.kv.get("prompts-prs").items, 2, "cancelling keeps it")
	eq(pendingOf(b), nil, "and closes the question")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p1" })
	eq(#w.kv.get("prompts-prs").items, 2, "a confirmation of a question that is gone deletes nothing")
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p1" })
	local items = w.kv.get("prompts-prs").items
	eq(#items, 1, "confirming deletes it")
	eq(items[1].id, "p2", "the other prompt stays")
	eq(prefsOf(b).focus, "padd:prs", "and the Add row takes the focus")
	b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:p2" })
	eq(pendingOf(b).head, "Delete action “Triage”?", "the Delete button asks the same question")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p2" })
	eq(#w.kv.get("prompts-prs").items, 0, "and confirming it deletes that prompt")
end)

case("host: changing page or closing Settings drops an open text edit and gives the caret back", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	-- Opens Settings on the Prompts page with the prompt's text being edited.
	local function editing()
		goToSettings(b, "prompts")
		expand(b, "popen:prs:p1")
		b.press("down")
		b.press("enter")
		eq(caretOf(w), "layer.settings.prompt.draft", "the text is being edited")
	end
	editing()
	b.event({ ev = "action", id = "layer.settings", act = "page", value = "views" })
	eq(prefsOf(b).page, "views", "a click on another page leaves the Prompts page")
	eq(editorCard(b), nil, "the editor is gone")
	eq(caretOf(w), "released", "and the caret is given back")
	b.press("tab")
	eq(prefsOf(b).page, "prompts", "back on the Prompts page")
	eq(editorCard(b), nil, "the edit did not come back")
	b.press("escape")
	editing()
	b.event({ ev = "action", id = "layer.settings", act = "close" })
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "closing Settings leaves the queue")
	eq(caretOf(w), "released", "and gives the caret back")
	b.typeText("s")
	eq(editorCard(b), nil, "reopened Settings has no edit")
end)

case("host: deleting a prompt drops an edit of its own name or text and leaves the edit of another prompt alone", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	-- Deletes prompt `id` with the mouse: the keys cannot while an edit is open.
	local function click(id: string)
		b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:" .. id })
		b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:" .. id })
	end
	expand(b, "popen:prs:p2")
	b.event({ ev = "select", id = "layer.settings", item = "ptext:prs:p2" })
	b.press("enter")
	eq(draftOf(b), "Triage {url}", "the text of the second prompt is being edited")
	click("p1")
	eq(#w.kv.get("prompts-prs").items, 1, "the first prompt is deleted")
	eq(draftOf(b), "Triage {url}", "the edit of the other prompt goes on")
	eq(caretOf(w), "layer.settings.prompt.draft", "with the caret where it was")
	click("p2")
	eq(#w.kv.get("prompts-prs").items, 0, "the prompt being edited is deleted")
	eq(editorCard(b), nil, "its editor goes with it")
	eq(caretOf(w), "released", "and the caret is given back")
	savePrompts(w, { promptOf("p3", "Plan", "Plan {url}") })
	expand(b, "popen:prs:p3")
	b.event({ ev = "select", id = "layer.settings", item = "pname:prs:p3" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "pname:prs:p3", "the name of another prompt is being edited")
	click("p3")
	eq(#w.kv.get("prompts-prs").items, 0, "it is deleted")
	eq(prefsOf(b).editing, nil, "and its name edit ends")
end)

case("host: unreadable or malformed saved prompts lock Add with the reason, are never overwritten, and the menu answers with the problem and no prompts", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "prompts")
	local asked = 0
	-- Tries every way to write the prompts while they cannot be loaded: `why` is what the reason must say.
	local function locked(what: string, why: string)
		b.render()
		local stored = w.kv.store["prompts-prs"]
		has(rowIn(b, "padd:prs").disabled, why, what .. ": Add is locked, with the reason")
		b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:prs" })
		b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:p1" })
		b.press("d")
		eq(w.kv.store["prompts-prs"], stored, what .. ": nothing was written over it")
		asked += 1
		request(b, "m" .. asked, { op = "menu" })
		local answer = answerOf(b, "m" .. asked)
		eq(#answer.items, 0, what .. ": the menu lists no prompts")
		has(answer.problem, why, what .. ": and says why")
	end
	local malformed: { any } = {
		"garbage",
		{ version = 2, nextId = 1, items = array({}) },
		{ version = 1, nextId = 2, items = array({ { id = "p1", name = "Review" } }) },
		{ version = 1, nextId = 2, items = array({ { id = "p1", name = "Review", text = "Review {url}", key = 5 } }) },
	}
	for i, value in malformed do
		w.kv.put("prompts-prs", value)
		locked("malformed value " .. i, "malformed")
	end
	w.kv.put("prompts-prs", { version = 1, nextId = 2, items = array({ promptOf("p1", "Review", "Review {url}") }) })
	w.kv.failGet["prompts-prs"] = "disk offline"
	locked("an unreadable store", "disk offline")
	w.kv.failGet["prompts-prs"] = nil
	b.render()
	eq(rowIn(b, "padd:prs").disabled, nil, "a readable store unlocks Add")
	request(b, "m9", { op = "menu" })
	local answer = answerOf(b, "m9")
	eq(answer.problem, nil, "and the menu has no problem")
	eq(#answer.items, 1, "but the prompt")
end)

case("host: view prompts limit the menu", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}"),
		promptOf("p2", "Anywhere", "Look at {url}\nTwice"),
		promptOf("p3", "Blank", ""),
	})
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({ "p2" }) },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	local asked = 0
	-- What the block answers a window asking for the menu: the rows, in order.
	local function menu(): any
		asked += 1
		request(b, "m" .. asked, { op = "menu" })
		w.flush()
		return answerOf(b, "m" .. asked)
	end
	local first = menu()
	eq(first.problem, nil, "nothing is wrong")
	same(first.items, {
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "For My PRs", send = "Look at {url}\nTwice", worktree = true },
	}, "a view that lists a prompt offers only it, in the group For the view")
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "prs:v2", "the second view is active")
	same(menu().items, {
		{ id = "p1", label = "Mine", detail = "Review {url}", group = "All actions", send = "Review {url}", worktree = true },
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "All actions", send = "Look at {url}\nTwice", worktree = true },
	}, "a view that lists none offers every prompt with text, as All actions")
end)

case("host: the menu asked for one prompt answers just that one, if it is offered, however many are saved", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}"),
		promptOf("p2", "Anywhere", "Look at {url}"),
		promptOf("p3", "Theirs", "Only for review requests"),
		promptOf("p4", "Blank", ""),
	})
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({ "p1", "p4" }) },
	}) })
	local b = openQueue(w)
	local asked = 0
	-- The rows the block answers a menu request that names prompt `id`.
	local function only(id: string): { any }
		asked += 1
		request(b, "o" .. asked, { op = "menu", only = id })
		return answerOf(b, "o" .. asked).items
	end
	same(only("p1"), { { id = "p1", label = "Mine", detail = "Review {url}", group = "For My PRs", send = "Review {url}", worktree = true } }, "just the prompt asked for, in the group it has under the view")
	eq(#only("p2"), 0, "none that the view does not list")
	eq(#only("p4"), 0, "none with no text")
	eq(#only("p9"), 0, "none that is not saved")
end)

case("host: the picker's action bar has Settings and Refresh on the left, then the PR's Worktree, Go to tab and Agent by the command palette, with no button per prompt and Open in the preview's head; each opens the link the card keeps unseen, beside each offered prompt's", function(w: World)
	local s = hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", "e"),
		promptOf("p2", "Anywhere", "Look at {url}\nTwice"),
		promptOf("p3", "Theirs", "Only for review requests", "x"),
		promptOf("p4", "Blank", "", "b"),
		promptOf("p-5", "Dashed", "Its id cannot be part of a link", "d"),
	})
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({ "p1", "p2", "p4", "p-5" }) },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", group = "none", prompts = array({ "p3" }) },
	}) })
	local b = openQueue(w)
	-- The ids of the action bar's buttons, in order.
	local function bar(): { string }
		local out: { string } = {}
		for _, a in pickerOf(b).actions do
			table.insert(out, a.id)
		end
		return out
	end
	local function action(id: string): any
		for _, a in pickerOf(b).actions do
			if a.id == id then
				return a
			end
		end
		return nil
	end
	local function link(id: string): string?
		local node: any = findKey(findKey(pickerNode(b), "buttons"), id)
		return if node then node.p.href else nil
	end
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "one Agent button, none per saved prompt; Seen before the command palette, which is last")
	eq(action("more").primary, true, "the command palette is the primary button")
	eq(action("more").label, "Commands", "named Commands")
	same(action("more").keys, { "." }, "with its key")
	eq(action("open"), nil, "Open is no button of the bar")
	local globe: any = findKey(findKey(pickerNode(b), "head"), "open", "icon")
	eq(globe.p.href, link("open"), "but an icon in the preview's head, opening the hidden Open link")
	eq(globe.p.actions.click, "open", "on click")
	eq(globe.p.title, "Open in GitHub", "named for the integration")
	eq(action("settings")["end"], nil, "Settings and Refresh sit on the left")
	eq(action("retry")["end"], nil, "both of them")
	eq(action("worktree")["end"], true, "the PR's buttons sit on the right, by Open")
	eq(action("agent")["end"], true, "Agent too")
	eq(action("agent").label, "Agent", "named Agent")
	same(action("agent").keys, { "a" }, "with the Agent picker's key")
	eq(findKey(pickerNode(b), "buttons").p.hidden, true, "the links sit in an unseen node")
	eq(link("agent"), "plotroom://github/agent/o/r/1", "Agent's link opens the picker on the selected pull request")
	eq(link("prompt-p1"), "plotroom://github/run/o/r/1/p1", "each offered prompt's link runs it, for its shortcut")
	eq(link("prompt-p2"), "plotroom://github/run/o/r/1/p2", "one with no shortcut too")
	eq(link("prompt-p3"), nil, "none for a prompt the view does not list")
	eq(link("prompt-p4"), nil, "or a blank one")
	eq(link("prompt-p-5"), nil, "or one whose id is no link")
	b.event({ ev = "action", id = "layer.queue", act = "agent" })
	eq(w.opened[#w.opened], "plotroom://github/agent/o/r/1", "a click opens the button's link")
	b.event({ ev = "action", id = "layer.queue", act = "worktree" })
	eq(w.opened[#w.opened], "plotroom://github/worktree/o/r/1", "Worktree's too")
	leaveWt(w, s, 1)
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-pr-1" })
	refreshNow(w, b)
	same(bar(), { "settings", "retry", "worktree", "goto", "agent", "seen", "more" }, "a tab in the pull request's worktree adds Go to tab before Agent")
	eq(link("goto"), "plotroom://github/goto/o/r/1", "with its link")
	table.remove(w.panes)
	b.press("tab")
	b.press("down")
	w.flush()
	hx.selectFirst(b)
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "under Review requested the bar stays the same")
	eq(link("prompt-p3"), "plotroom://github/run/o/r/1/p3", "and the prompt links swap")
	eq(link("prompt-p1"), nil, "for the ones it lists")
	b.press("e")
	eq(w.opened[#w.opened] == "plotroom://github/run/o/r/1/p1", false, "a prompt the view does not list has no key")
	b.press("x")
	eq(w.opened[#w.opened], "plotroom://github/run/o/r/1/p3", "one it lists runs on its key, through its link")
end)

case("host: opening in a linked worktree saves its main checkout, not the worktree", function(w: World)
	local s = hostScene(w, 3)
	table.insert(s.git.worktrees, { path = "/wt/feature", branch = "refs/heads/feature", head = sha("1"), locked = false })
	w.fs.dirs["/wt/feature"] = true
	w.kv.put("checkouts", {})
	w.open(1, { "/wt/feature" })
	w.flush()
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the main checkout is saved, not the worktree")
end)

case("host: Add repository saves a picked repository without a checkout and opens its checkout row; the picker gets the saved ones, the gh logins, then a login's repositories", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.override = function(req: GhReq): Reply?
		return if req.kind == "repos" then { delay = 5000, stdout = "z/z\nO/R\na/b\n" } else nil
	end
	local b = openQueue(w)
	b.event({ ev = "action", act = "add-repo", value = "X/Y" })
	w.flush()
	eq(w.kv.get("checkouts")["x/y"], "", "the picked repository is saved without a checkout, by its lowercase name")
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the launch checkout stays")
	eq(prefsOf(b).page, "repos", "Settings opens on the Repositories page")
	eq(prefsOf(b).editing.row, "checkout:x/y", "to enter its checkout")
	b.press("escape")
	b.event({ ev = "action", act = "add-repo", value = "x/y/z" })
	eq(w.toasts[#w.toasts].level, "error", "a malformed pick is refused")
	eq(w.kv.get("checkouts")["x/y/z"], nil, "and saves nothing")
	local function subtitle(): string
		local out = ""
		for _, span in pickerOf(b).subtitle or {} do
			out ..= span.t
		end
		return out
	end
	request(b, "q1", { op = "repos" })
	w.flush()
	local answer = answerOf(b, "q1")
	local want: { any } = {
		{ repo = "o/r", path = "/work/r" },
		{ repo = "x/y" },
	}
	same(answer.items, want, "saved repositories by name, with their checkouts")
	local accounts: { any } = { { login = "octocat", active = true } }
	same(answer.accounts, accounts, "and the gh logins")
	eq(#requestsOf(s.gh, "accounts"), 1, "read once, when the first search warmed them")
	request(b, "q2", { op = "profile", login = "octocat" })
	w.flush()
	eq(answerOf(b, "q2"), nil, "no answer while GitHub lists the login's repositories")
	has(subtitle(), "Loading repositories…", "the heading shows they are loading")
	w.advance(5000)
	lacks(subtitle(), "Loading repositories…", "until they are in")
	same(answerOf(b, "q2").repos, { "z/z", "O/R", "a/b" }, "most recently pushed first")
	eq(requestsOf(s.gh, "repos")[1].login, "octocat", "listed as that login")
end)

case("host: a prompt's key opens its run link for the selected pull request, but not while searching, under a view that does not offer it, or with ctrl, alt or meta", function(w: World)
	local s = hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", "e"),
		promptOf("p2", "Anywhere", "Look at {url}", "T"),
		promptOf("p3", "Theirs", "Only for review requests", "x"),
		promptOf("p4", "Hand edited", "The queue's own key wins", "w"),
	})
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({ "p1", "p2", "p4" }) },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", group = "none", prompts = array({ "p3" }) },
	}) })
	local b = openQueue(w)
	local opened = #w.opened
	-- A key the pane may use: not handled, and nothing opened.
	local function ignored(what: string, name: string, mods: string?)
		eq(b.press(name, mods, name), false, what .. ": not handled")
		eq(#w.opened, opened, what .. ": nothing opened")
	end
	eq(b.press("e", nil, "e"), true, "the key is handled")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p1"), "and opens its prompt's run link for the selected pull request")
	eq(b.press("t", "s", "T"), true, "shift is allowed")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p2"), "a capital is a key of its own")
	b.press("down")
	b.typeText("e")
	eq(w.opened[#w.opened], runLink("o/r", 2, "p1"), "the link follows the selection")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 2), "a key the queue uses itself stays the queue's, whatever a prompt says")
	opened = #w.opened
	ignored("a key no prompt has", "q")
	ignored("a prompt of another view", "x")
	ignored("ctrl", "e", "c")
	ignored("alt", "e", "a")
	ignored("meta", "e", "m")
	b.typeText("/")
	b.typeText("e")
	eq(pickerOf(b).query, "e", "while searching the key is text")
	eq(#w.opened, opened, "and opens nothing")
	b.press("escape")
	b.press("escape")
	b.press("tab")
	b.press("down")
	w.flush()
	hx.selectFirst(b)
	eq(pickerOf(b).scope, "prs:v2", "under the second view")
	ignored("a prompt of the first view", "e")
	local n = tonumber(string.match(pickerOf(b).selected, "^no_2fr_23(%d+)$")) :: number
	b.typeText("x")
	eq(w.opened[#w.opened], runLink("o/r", n, "p3"), "its own prompt's key works there")
	s.gh.items.octocat = {}
	b.typeText("r")
	w.flush()
	eq(pickerOf(b).selected, nil, "with no pull request selected")
	opened = #w.opened
	ignored("no pull request", "x")
end)

case("host: a prompt's shortcut is one free key on the Keys page: the row refuses what the queue uses or another prompt has, and clearing it removes the key", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}", "t") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	local ids: { string } = {}
	for _, row in prefsOf(b).sections[1].rows do
		table.insert(ids, row.id)
	end
	same(ids, { "popen:prs:p1", "pdelete:prs:p1", "pname:prs:p1", "ptext:prs:p1", "pmodel:prs:p1", "pwhere:prs:p1", "psplit:prs:p1" }, "an open prompt has Done and Delete, then its name, text, model, where it runs and opens: no shortcut")
	goToSettings(b, "keys")
	local row = rowIn(b, "pkey:prs:p1")
	eq(row.label, "Review", "the Keys page has a row for the saved action, named for it")
	eq(sectionIn(b, "pkey:prs:p1").title, "Pull request actions", "under its kind's title")
	eq(row.control.value, "", "empty while the prompt has none")
	eq(row.control.placeholder, "None", "which it says")
	eq(rowIn(b, "pkey:prs:p2").control.value, "t", "and one for each other saved action, showing its key")
	b.event({ ev = "select", id = "layer.settings", item = "pkey:prs:p1" })
	-- Presses `key` ("" is Backspace) on the first prompt's shortcut row: what the row warns afterwards. Enter starts the
	-- capture; a refused key leaves it open, and the next call presses another key.
	local function try(key: string): string?
		if prefsOf(b).editing == nil then
			b.press("enter")
			eq(prefsOf(b).editing.draft, "", "the capture starts empty")
		end
		if key == "" then
			b.press("backspace")
		else
			b.typeText(key)
		end
		return rowIn(b, "pkey:prs:p1").warning
	end
	eq(try(" "), "One key: a single letter, digit or symbol.", "a space is no key")
	eq(prefsOf(b).editing.row, "pkey:prs:p1", "the capture stays open")
	for _, k in { "j", "k", "w", "g", "a", "G", "m", "z", "Z", "n", "o", ".", "/", "?", "r", "s" } do
		eq(try(k), "The queue already uses " .. k .. ".", "the queue's own " .. k .. " is refused")
		eq(prefsOf(b).editing.row, "pkey:prs:p1", "with the capture still open for another key")
	end
	eq(try("t"), "Already the shortcut of Triage.", "another prompt's key is refused")
	eq(w.kv.get("prompts-prs").items[1].key, nil, "nothing was saved")
	eq(try("e"), nil, "a free key is accepted at once, with no Enter")
	eq(prefsOf(b).editing, nil, "and closes the capture")
	same(w.kv.get("prompts-prs").items[1], { id = "p1", name = "Review", text = "Review {url}", key = "e" }, "it is saved as the prompt's key, the rest as it was")
	eq(w.kv.get("prompts-prs").items[2].key, "t", "another prompt keeps its key")
	eq(rowIn(b, "pkey:prs:p1").control.value, "e", "the row shows it")
	eq(try("A"), nil, "a capital is not the queue's a")
	eq(w.kv.get("prompts-prs").items[1].key, "A", "and is saved as typed")
	eq(try("é"), nil, "one character is one key, whatever its bytes")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and is saved")
	b.press("enter")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc cancels the capture")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and keeps the key")
	b.press("enter")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "Enter cancels it too")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and keeps the key")
	b.press("enter")
	b.press("x", "c", "x")
	eq(prefsOf(b).editing.row, "pkey:prs:p1", "a key with ctrl is swallowed: the capture stays open")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and nothing is saved")
	b.press("escape")
	eq(try(""), nil, "Backspace is accepted")
	eq(w.kv.get("prompts-prs").items[1].key, nil, "and removes the key")
	eq(rowIn(b, "pkey:prs:p1").control.value, "", "which the row shows")
end)

case("host: a Keys row refuses a key another action or a saved prompt of either kind has, and a prompt's shortcut refuses the keys the queue uses now", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}", "e") })
	w.kv.put("prompts-issues", { version = 1, nextId = 2, items = array({ promptOf("p1", "Triage", "Triage {url}", "i") }) })
	w.kv.put("keys", { ["goto"] = "g" })
	local b = openQueue(w)
	goToSettings(b, "keys")
	eq(bindKey(b, "worktree", "g"), "Already the shortcut of Go to tab.", "another action's key is refused, naming the action")
	eq(prefsOf(b).editing.row, "key:worktree", "and the capture stays open for another key")
	eq(bindKey(b, "worktree", " "), "One key: a single letter, digit or symbol.", "a space is no key")
	eq(prefsOf(b).editing.row, "key:worktree", "and the capture is still open")
	eq(bindKey(b, "worktree", "e"), "Already the shortcut of the pull request action “Review”.", "a pull request prompt's key is refused, naming the prompt")
	eq(bindKey(b, "worktree", "i"), "Already the shortcut of the issue action “Triage”.", "and an issue prompt's")
	same(w.kv.get("keys"), { ["goto"] = "g" }, "nothing was saved")
	eq(bindKey(b, "worktree", "x"), nil, "a free key is saved at once, with no Enter")
	eq(prefsOf(b).editing, nil, "and closes the capture")
	same(w.kv.get("keys"), { ["goto"] = "g", worktree = "x" }, "beside the other key")
	b.press("enter")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc cancels a capture")
	same(w.kv.get("keys"), { ["goto"] = "g", worktree = "x" }, "and keeps the old key")
	eq(bindKey(b, "worktree", ""), nil, "Backspace is accepted")
	same(w.kv.get("keys"), { ["goto"] = "g" }, "and removes the shortcut, no key being the default")
	eq(bindKey(b, "goto", "Q"), nil, "an action's key is free once it has moved")
	eq(bindKey(b, "worktree", "g"), nil, "and another action can have it")
	same(w.kv.get("keys"), { ["goto"] = "Q", worktree = "g" }, "both are saved")
	b.event({ ev = "select", id = "layer.settings", item = "pkey:prs:p1" })
	-- Presses `key` on the prompt's shortcut row: the warning under its row afterwards.
	local function try(key: string): string?
		if prefsOf(b).editing == nil then
			b.press("enter")
		end
		b.typeText(key)
		return rowIn(b, "pkey:prs:p1").warning
	end
	eq(try("Q"), "The queue already uses Q.", "a prompt cannot take the key an action moved to")
	eq(try("w"), nil, "but takes the one the action gave up")
	eq(w.kv.get("prompts-prs").items[1].key, "w", "and it is saved")
	b.press("escape")
	b.typeText("w")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p1"), "the prompt's key runs it")
	b.typeText("g")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and the action's new key makes the worktree")
end)

case("host: unreadable or malformed saved keys lock the Keys rows with the reason, the default keys keep working, and nothing is written over them", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "keys")
	-- Tries every way to write the keys while they cannot be loaded: `why` is what the rows must say.
	local function locked(what: string, why: string)
		b.render()
		local stored = w.kv.store["keys"]
		for _, r in prefsOf(b).sections[1].rows do
			has(r.disabled, why, what .. ": " .. r.id .. " is locked, with the reason")
		end
		b.event({ ev = "activate", id = "layer.settings", item = "key:worktree" })
		eq(prefsOf(b).editing, nil, what .. ": no edit opens")
		b.event({ ev = "change", id = "layer.settings", item = "key:worktree" })
		has(rowIn(b, "key:worktree").warning, why, what .. ": Reset says why")
		eq(w.kv.store["keys"], stored, what .. ": nothing was written over it")
	end
	local malformed: { any } = { "garbage", { worktree = 5 }, { worktree = "ww" }, { worktree = "a b" }, array({ "w" }) }
	for i, value in malformed do
		w.kv.put("keys", value)
		locked("malformed value " .. i, "malformed")
	end
	w.kv.put("keys", { more = "," })
	w.kv.failGet["keys"] = "disk offline"
	locked("an unreadable store", "disk offline")
	b.press("escape")
	eq(b.press(",", nil, ","), false, "the saved key is not in use while the keys cannot be read")
	eq(b.press(".", nil, "."), true, "the default one is")
	w.kv.failGet["keys"] = nil
	eq(b.press(",", nil, ","), true, "readable again, the saved key works")
	goToSettings(b, "keys")
	b.event({ ev = "select", id = "layer.settings", item = "key:goto" })
	b.press("enter")
	w.kv.put("keys", "garbage")
	local stored = w.kv.store["keys"]
	b.typeText("Q")
	has(rowIn(b, "key:goto").warning, "malformed", "a key pressed after the keys went bad is refused")
	eq(w.kv.store["keys"], stored, "and nothing is written over them")
	eq(prefsOf(b).editing.draft, "Q", "the capture stays open")
	w.kv.put("keys", { worktree = "W" })
	w.kv.failSet["keys"] = "read-only file system"
	b.typeText("Q")
	eq(rowIn(b, "key:goto").warning, "Could not save: read-only file system", "a failed write is reported under the row")
	eq(prefsOf(b).editing.draft, "Q", "with the capture still open")
	same(w.kv.get("keys"), { worktree = "W" }, "and the saved keys as they were")
	w.kv.failSet["keys"] = nil
	b.typeText("Q")
	eq(rowIn(b, "key:goto").warning, nil, "the retry clears the warning")
	same(w.kv.get("keys"), { ["goto"] = "Q", worktree = "W" }, "and saves the key beside the other")
end)

case("host: a key changed in one block reaches the other live blocks, and a closed pane is skipped", function(w: World)
	hostScene(w, 3)
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	local gone = w.open(3, { "/work/r" })
	w.flush()
	gone.close()
	hx.selectFirst(c)
	goToSettings(a, "keys")
	local drawn, closed = c.renders(), gone.renders()
	eq(bindKey(a, "worktree", "W"), nil, "the key is saved")
	yes(c.renders() > drawn, "the other block is drawn again")
	same(actionOf(c, "worktree").keys, { "W" }, "and shows the new key")
	eq(gone.renders(), closed, "a closed pane is not drawn")
	eq(c.press("w", nil, "w"), false, "the other block's old key is its pane's again")
	eq(c.press("w", "s", "W"), true, "and the new one works there")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "on its selected pull request")
	a.event({ ev = "change", id = "layer.settings", item = "key:worktree" })
	eq(actionOf(c, "worktree"), nil, "Reset reaches it too: back to no key, the button goes")
end)

case("host: a prompt's model is a model pattern or omp role: the row refuses anything else, the menu sends it, reset clears it", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "pmodel:prs:p1").control.value, "", "empty while the prompt has none")
	b.event({ ev = "select", id = "layer.settings", item = "pmodel:prs:p1" })
	local function try(text: string): string?
		if prefsOf(b).editing == nil then
			b.press("enter")
		end
		b.press("a", "c")
		b.press("backspace")
		b.typeText(text)
		b.press("enter")
		return rowIn(b, "pmodel:prs:p1").warning
	end
	local bad = "A model such as opus or provider/model-id, or a role such as @slow."
	eq(try("opus; rm -rf ~"), bad, "shell syntax is refused: the window puts it on a command line")
	eq(try("@"), bad, "a bare @ is no role")
	eq(try("a b"), bad, "so is a gap")
	eq(w.kv.get("prompts-prs").items[1].model, nil, "nothing was saved")
	for _, ok in { "@slow", "opus", "anthropic/claude-opus-4-5", "gpt-5.2:high", "openrouter/x-ai/grok-4" } do
		eq(try(ok), nil, ok .. " is accepted")
		eq(w.kv.get("prompts-prs").items[1].model, ok, ok .. " is saved")
	end
	eq(rowIn(b, "pmodel:prs:p1").changed, true, "the row offers a reset")
	request(b, "m1", { op = "menu" })
	local item = answerOf(b, "m1").items[1]
	eq(item.model, "openrouter/x-ai/grok-4", "the menu sends the model")
	eq(item.detail, "openrouter/x-ai/grok-4 · Review {url}", "and names it before the first line")
	b.event({ ev = "change", id = "layer.settings", item = "pmodel:prs:p1", value = nil })
	eq(w.kv.get("prompts-prs").items[1].model, nil, "reset clears it")
	eq(try(""), nil, "an empty model is accepted")
end)

case("host: ? adds a row for each prompt offered under the view that has a key, in the queue only", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", "m"),
		promptOf("p2", "Quiet", "Has no key {url}"),
		promptOf("p3", "Theirs", "Only for review requests", "x"),
		promptOf("p4", "Blank", "", "b"),
		promptOf("p5", "Anywhere", "Look at {url}", "T"),
	})
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({ "p1", "p2", "p4", "p5" }) },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", group = "none", prompts = array({ "p3", "p5" }) },
	}) })
	local b = openQueue(w)
	-- The rows of the open shortcut list that say what a prompt's key does.
	local function promptRows(): { { keys: string, text: string } }
		local out: { { keys: string, text: string } } = {}
		for _, row in helpRows(b.view().layer) do
			if string.find(row.text, "Run the action", 1, true) then
				table.insert(out, row)
			end
		end
		return out
	end
	b.typeText("?")
	same(promptRows(), {
		{ keys = "m", text = "Run the action “Mine” on the selected pull request" },
		{ keys = "T", text = "Run the action “Anywhere” on the selected pull request" },
	}, "each prompt offered under My PRs that has a key, in the menu's order; none without a key, with no text or for another view")
	b.press("escape")
	b.press("tab")
	b.press("down")
	w.flush()
	b.typeText("?")
	same(promptRows(), {
		{ keys = "x", text = "Run the action “Theirs” on the selected pull request" },
		{ keys = "T", text = "Run the action “Anywhere” on the selected pull request" },
	}, "under Review requested the rows follow")
	b.press("escape")
	b.typeText("s")
	b.typeText("?")
	same(promptRows(), {}, "the list of Settings has none")
end)

case("host: a checkout of another repository is refused with its draft kept; a real one is saved only after git confirms it", function(w: World)
	local s = hostScene(w, 3)
	local other = newGit(w, "/work/other")
	other.remotes.origin = { "https://github.com/x/y.git" }
	local b = openQueue(w)
	w.kv.put("checkouts", { ["o/r"] = "" })
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	eq(prefsOf(b).focus, "checkout:o/r", "the checkout row is focused")
	b.press("enter")
	b.typeText("/work/other")
	b.press("enter")
	w.flush()
	has(rowIn(b, "checkout:o/r").warning, "No remote of /work/other points at github.com/o/r", "git's refusal is shown under the row")
	eq(prefsOf(b).editing.draft, "/work/other", "the draft stays for a correction")
	eq(w.kv.get("checkouts")["o/r"], "", "nothing was saved")
	eq(#requestsOf(s.gh, "clone"), 0, "a repository that is there is never cloned over")
	w.kv.failGet["checkouts"] = "disk offline"
	request(b, "c1", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	has(answerOf(b, "c1").problem, "could not be read", "an unreadable checkout map is refused")
	eq(w.kv.get("checkouts")["o/r"], "", "and nothing written over it")
	w.kv.failGet["checkouts"] = nil
	b.press("a", "c")
	b.typeText("/work/r")
	b.press("enter")
	w.flush()
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the confirmed checkout is saved")
	eq(w.toasts[#w.toasts].level, "success", "and reported")
	eq(w.toasts[#w.toasts].text, "Checkout saved", "as saved, not cloned")
	eq(#requestsOf(s.gh, "clone"), 0, "nothing was cloned")
	eq(prefsOf(b).editing, nil, "the edit is closed")
	eq(rowIn(b, "checkout:o/r").warning, nil, "without a warning")
end)

case("host: a folder that does not exist is cloned into with gh, saved once git confirms the clone", function(w: World)
	local s = hostScene(w, 3)
	-- the clone's git state exists in the model, but the folder only appears once gh has run
	local fresh = newGit(w, "/code/r")
	fresh.remotes.origin = { "https://github.com/o/r.git" }
	w.fs.dirs["/code/r"] = nil
	w.fs.dirs["/code/r/.git"] = nil
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "clone" then
			w.fs.dirs["/code/r"] = true
			w.fs.dirs["/code/r/.git"] = true
			return { stdout = "", delay = 2000 }
		end
		return nil
	end
	local b = openQueue(w)
	w.kv.put("checkouts", { ["o/r"] = "" })
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "checkout:o/r", "the checkout row is ready for a path")
	b.typeText("/code/r")
	b.press("enter")
	has(rowIn(b, "checkout:o/r").disabled, "cloning into it", "while gh clones the row says so and cannot be edited")
	same(requestsOf(s.gh, "clone")[1].call.argv, { "gh", "repo", "clone", "o/r", "/code/r" }, "gh clones the repository into the folder")
	eq(w.kv.get("checkouts")["o/r"], "", "nothing is saved before the clone ends")
	w.advance(2000)
	eq(w.kv.get("checkouts")["o/r"], "/code/r", "the clone is saved as the checkout")
	eq(w.toasts[#w.toasts].text, "Cloned o/r", "and reported as a clone")
	eq(w.toasts[#w.toasts].sub, "/code/r", "naming where")
	eq(rowIn(b, "checkout:o/r").disabled, nil, "and the row is free again")
	eq(rowIn(b, "checkout:o/r").control.value, "/code/r", "showing it")
end)

case("host: a checkout clone that fails late stays inline on the Repositories page and is a toast anywhere else", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	w.kv.put("checkouts", { ["o/r"] = "" })
	-- gh answers about the clone only after five seconds
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "clone" then
			return { status = 1, stderr = "fatal: destination path '/elsewhere' already exists and is not an empty directory.\n", delay = 5000 }
		end
		return nil
	end
	local function submit()
		expand(b, "ropen:o/r")
		b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
		b.press("enter")
		b.typeText("/elsewhere")
		b.press("enter")
		eq(prefsOf(b).editing, nil, "the edit closes while gh clones")
	end
	goToSettings(b, "repos")
	submit()
	w.advance(5000)
	has(rowIn(b, "checkout:o/r").warning, "not an empty directory", "on the Repositories page the refusal is shown under the row")
	eq(prefsOf(b).editing.draft, "/elsewhere", "with the draft kept for a correction")
	eq(#w.toasts, 0, "and no toast")
	b.press("escape")
	submit()
	b.press("tab", "s")
	eq(prefsOf(b).page, "worktrees", "the user moved on while gh was cloning")
	w.advance(5000)
	eq(#w.toasts, 1, "the refusal is reported once")
	eq(w.toasts[1].level, "error", "as an error")
	eq(w.toasts[1].text, "Checkout not saved", "that says what happened")
	has(w.toasts[1].sub, "not an empty directory", "with gh's reason")
	eq(prefsOf(b).page, "worktrees", "the page the user is on is left alone")
	b.press("tab")
	eq(prefsOf(b).page, "repos", "back on the Repositories page")
	submit()
	b.press("escape")
	w.advance(5000)
	eq(#w.toasts, 2, "closing Settings meanwhile reports it as well")
	eq(w.toasts[2].text, "Checkout not saved", "with the same toast")
	goToSettings(b, "repos")
	submit()
	b.press("tab", "s")
	b.press("tab")
	eq(prefsOf(b).page, "repos", "a user who is back on the page before gh answers")
	w.advance(5000)
	has(rowIn(b, "checkout:o/r").warning, "not an empty directory", "sees the refusal under its row")
	eq(prefsOf(b).editing.draft, "/elsewhere", "with the draft")
	eq(#w.toasts, 2, "and no extra toast")
	eq(w.kv.get("checkouts")["o/r"], "", "nothing was ever saved")
end)

-- gh's clone of o/r answers after 5s with a refusal (fail) or after 2s with a clone at /code/r
local function slowClone(w: World, s: any, fail: boolean)
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "clone" then
			if fail then
				return { status = 1, stderr = "fatal: destination path '/elsewhere' already exists and is not an empty directory.\n", delay = 5000 }
			end
			w.fs.dirs["/code/r"] = true
			w.fs.dirs["/code/r/.git"] = true
			return { stdout = "", delay = 2000 }
		end
		return nil
	end
end

case("host: a clone that fails late leaves a draft being typed in another row alone", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	w.kv.put("checkouts", { ["o/r"] = "", ["x/y"] = "" })
	slowClone(w, s, true)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/elsewhere")
	b.press("enter")
	expand(b, "ropen:x/y")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:x/y" })
	b.press("enter")
	b.typeText("/mine")
	w.advance(5000)
	eq(prefsOf(b).editing.row, "checkout:x/y", "the form being typed in stays")
	eq(prefsOf(b).editing.draft, "/mine", "with its draft")
	eq(w.toasts[#w.toasts].text, "Checkout not saved", "the refusal is a toast instead")
end)

case("host: a checkout asked in the palette waits out a clone of the same repository", function(w: World)
	local s = hostScene(w, 3)
	local fresh = newGit(w, "/code/r")
	fresh.remotes.origin = { "https://github.com/o/r.git" }
	w.fs.dirs["/code/r"] = nil
	w.fs.dirs["/code/r/.git"] = nil
	slowClone(w, s, false)
	local b = openQueue(w)
	w.kv.put("checkouts", { ["o/r"] = "" })
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/code/r")
	b.press("enter")
	request(b, "c1", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	has(answerOf(b, "c1").problem, "being", "the second claim is answered busy")
	eq(w.kv.get("checkouts")["o/r"], "", "and saved nothing")
	w.advance(2000)
	eq(w.kv.get("checkouts")["o/r"], "/code/r", "the clone is the checkout")
end)

case("host: removing a repository while it clones does not bring it back", function(w: World)
	local s = hostScene(w, 3)
	local fresh = newGit(w, "/code/r")
	fresh.remotes.origin = { "https://github.com/o/r.git" }
	w.fs.dirs["/code/r"] = nil
	w.fs.dirs["/code/r/.git"] = nil
	slowClone(w, s, false)
	local b = openQueue(w)
	w.kv.put("checkouts", { ["o/r"] = "" })
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/code/r")
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "delete", value = "rremove:o/r" })
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "rremove:o/r" })
	w.advance(2000)
	eq(w.kv.get("checkouts")["o/r"], nil, "the removed repository stays removed")
	eq(w.toasts[#w.toasts].level, "error", "and the clone's end says why")
end)

-- o/r is listed without a checkout, and gh's clone of it into /code/r takes 2s; panes 1 and 2 hold blocks
local function cloneScene(w: World): (Block, Block)
	local s = hostScene(w, 3)
	local fresh = newGit(w, "/code/r")
	fresh.remotes.origin = { "https://github.com/o/r.git" }
	w.fs.dirs["/code/r"] = nil
	w.fs.dirs["/code/r/.git"] = nil
	slowClone(w, s, false)
	local a = openQueue(w)
	local b = openQueue(w, 2)
	w.kv.put("checkouts", { ["o/r"] = "" })
	return a, b
end

case("host: a Settings checkout refused as busy keeps the typed path", function(w: World)
	local a, b = cloneScene(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/work/r")
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" }) -- another pane starts its claim while the field is open
	w.flush()
	b.press("enter")
	has(rowIn(b, "checkout:o/r").warning, "already being set up", "the refusal is shown under the row")
	eq(prefsOf(b).editing.draft, "/work/r", "the typed path stays for another try")
end)

case("host: a claim in one pane makes another pane's claim of the same repository wait", function(w: World)
	local a, b = cloneScene(w)
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	request(b, "c2", { op = "checkout", repo = "O/R", path = "/work/r" })
	w.flush()
	has(answerOf(b, "c2").problem, "being", "the other pane is told it is busy")
	eq(w.kv.get("checkouts")["o/r"], "", "and saved nothing")
	w.advance(2000)
	eq(answerOf(a, "c1").ok, true, "the first claim finishes")
	eq(w.kv.get("checkouts")["o/r"], "/code/r", "and is the checkout")
	request(b, "c3", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	eq(answerOf(b, "c3").ok, true, "the repository can be claimed again once it is done")
end)

case("host: a repository removed while a palette claim clones it is not listed again", function(w: World)
	local a = cloneScene(w)
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	w.kv.put("checkouts", {}) -- removed meanwhile, from Settings in any pane
	w.advance(2000)
	has(answerOf(a, "c1").problem, "changed or removed", "the claim is refused")
	eq(w.kv.get("checkouts")["o/r"], nil, "the repository stays removed")
end)

case("host: a claim of a repository that was not listed is still saved", function(w: World)
	local a = cloneScene(w)
	w.kv.put("checkouts", {})
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	w.advance(2000)
	eq(answerOf(a, "c1").ok, true, "claimed")
	eq(w.kv.get("checkouts")["o/r"], "/code/r", "and listed")
end)

case("host: a claim whose block closed saves nothing and frees the repository", function(w: World)
	local a, b = cloneScene(w)
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	table.remove(w.panes, 1) -- pane 1 closes while gh clones
	w.advance(2000)
	eq(w.kv.get("checkouts")["o/r"], "", "the retired block saved nothing")
	request(b, "c2", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	eq(answerOf(b, "c2").ok, true, "the repository is not left claimed")
end)

case("host: switching views searches the new query, reuses a fresh cached list, and never waits for a superseded request", function(w: World)
	local s = hostScene(w, 3)
	local second = { searchItem(21, "o/r", EPOCH - 10), searchItem(22, "o/r", EPOCH - 20) }
	local slow = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind ~= "search" then
			return nil
		end
		if string.find(req.fields.q, "review-requested", 1, true) then
			return { stdout = jsonEncode({ total = 2, next = NULL, cost = 1, items = second }) }
		elseif slow then
			return { delay = 5000, stdout = jsonEncode({ total = 3, next = NULL, cost = 1, items = s.gh.items.octocat }) }
		end
		return nil
	end
	local b = openQueue(w)
	local function scope(id: string)
		b.event({ ev = "action", id = "layer.queue", act = "scope", value = id })
	end
	scope("prs:v2")
	w.flush()
	same(listed(b), { "no_2fr_2321", "no_2fr_2322" }, "the second view shows its own results")
	eq(#requestsOf(s.gh, "search"), 2, "it was searched")
	scope("prs:v1")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "going back shows the cached list at once")
	scope("prs:v1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "a fresh cached list and re-selecting the active view cost nothing")
	slow = true
	second = { searchItem(23, "o/r", EPOCH - 5) }
	b.typeText("r")
	scope("prs:v2")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 4, "the switch sent its own search while the slow one is still pending")
	same(listed(b), { "no_2fr_2323" }, "the switch showed the new answer without waiting for the slow search")
	w.advance(5000)
	same(listed(b), { "no_2fr_2323" }, "and the superseded answer never replaces it")
	eq(pickerOf(b).scope, "prs:v2", "the second view is still the one shown")
end)

case("host: a rejected query pauses only itself: no automatic retry, and another view still loads", function(w: World)
	local s = hostScene(w, 3)
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and string.find(req.fields.q, "author:@me", 1, true) then
			return { status = 1, stderr = "gh: Validation Failed (HTTP 422)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	eq(pickerOf(b).state, "error", "the rejected query shows its card")
	local sent = #requestsOf(s.gh, "search")
	w.advance(30 * 60 * 1000)
	eq(#requestsOf(s.gh, "search"), sent, "the timer does not retry a rejected query")
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "prs:v2" })
	w.flush()
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "another view loads")
	eq(pickerOf(b).state, "ready", "without the first view's card")
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "prs:v1" })
	w.flush()
	eq(#requestsOf(s.gh, "search"), sent + 2, "going back asks again instead of trusting the old rejection")
	eq(pickerOf(b).state, "error", "and it is rejected again")
end)

case("host: view group-by emits headers", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { searchItem(1, "o/b", EPOCH - 10), searchItem(2, "o/a", EPOCH - 20), searchItem(3, "o/b", EPOCH - 30) }
	-- Makes `group` the group-by of the only view.
	local function groupBy(group: string)
		w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
			{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = group, prompts = array({}) },
		}) })
	end
	groupBy("repo")
	local b = openQueue(w)
	local expectedOrder: { any } = {
		{ group = "o/a", label = "o/a", count = 1 },
		"no_2fa_232",
		{ group = "o/b", label = "o/b", count = 2 },
		"no_2fb_231",
		"no_2fb_233",
	}
	same(pickerOf(b).order, expectedOrder, "a header per repository in label order, each followed by its PRs in list order")
	eq(pickerOf(b).selected, "no_2fa_232", "the first PR of the first group is selected")
	b.typeText("j")
	eq(pickerOf(b).selected, "no_2fb_231", "and navigation steps over the header to the next PR")
	groupBy("none")
	local plain = openQueue(w, 2)
	same(pickerOf(plain).order, { "no_2fb_231", "no_2fa_232", "no_2fb_233" }, "without a group-by the order is the PRs alone, with no header")
end)

case("host: a rate limit holds every refresh, the manual one included, until it resets", function(w: World)
	local s = hostScene(w, 3)
	local limited = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and limited then
			return { status = 1, stderr = "gh: API rate limit exceeded (HTTP 403)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	eq(#requestsOf(s.gh, "search"), 1, "the first search was refused")
	eq(pickerOf(b).state, "error", "the card says so")
	eq(type(actionOf(b, "retry").disabled), "string", "and Refresh is shown as paused")
	b.typeText("r")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 1, "Refresh does not hammer a limited account")
	limited = false
	w.advance(299 * 1000)
	eq(#requestsOf(s.gh, "search"), 1, "nothing is sent before the reset")
	w.advance(1000)
	eq(#requestsOf(s.gh, "search"), 2, "the search resumes by itself once the limit has passed")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and loads")
	eq(actionOf(b, "retry").disabled, nil, "Refresh is available again")
end)

case("host: a sign-in failure survives a restart and only an explicit Refresh tries again", function(w: World)
	local s = hostScene(w, 3)
	local signedIn = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and not signedIn then
			return { status = 4, stderr = "gh: To get started with GitHub CLI, please run:  gh auth login\n" }
		end
		return nil
	end
	local b = openQueue(w)
	eq(pickerOf(b).state, "error", "no results without a sign-in")
	w.advance(30 * 60 * 1000)
	eq(#requestsOf(s.gh, "search"), 1, "a sign-in failure is not retried by the timer")
	b.cx:save()
	local function sentToGithub(): number
		return #s.gh.requests - #requestsOf(s.gh, "accounts") -- learning the active login is no search
	end
	local sent = sentToGithub()
	local again = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(sentToGithub(), sent, "a restored block sends nothing to GitHub while the pause stands")
	eq(pickerOf(again).state, "error", "and shows the same card")
	signedIn = true
	again.typeText("r")
	w.flush()
	same(listed(again), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "Refresh tries again and loads")
end)

case("host: Refresh while a search is running says so and sends nothing more", function(w: World)
	local s = hostScene(w, 3)
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" then
			return { delay = 5000, stdout = jsonEncode({ total = 3, next = NULL, cost = 1, items = s.gh.items.octocat }) }
		end
		return nil
	end
	local b = openQueue(w)
	eq(pickerOf(b).state, "loading", "the first search is still running")
	b.typeText("r")
	eq(w.toasts[1].level, "info", "Refresh says it is already refreshing")
	eq(#requestsOf(s.gh, "search"), 1, "and does not start another")
	w.advance(5000)
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the one search lands")
	eq(#requestsOf(s.gh, "search"), 1, "once")
end)

case("host: a view change in one block reaches the other live blocks, and a closed pane is skipped", function(w: World)
	local s = hostScene(w, 3)
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "each block searches for itself")
	goToSettings(a, "views")
	expand(a, "vopen:prs:v1")
	a.press("enter")
	a.press("a", "c")
	a.typeText("Mine")
	a.press("enter")
	has(c.title(), "Mine", "the other block shows the new name")
	eq(#requestsOf(s.gh, "search"), 2, "a rename needs no new search")
	a.event({ ev = "select", id = "layer.settings", item = "query:prs:v1" })
	a.press("enter")
	a.typeText(" label:bug")
	a.press("enter")
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 4, "both blocks searched the new query")
	has(searches[3].fields.q, "label:bug", "this block")
	has(searches[4].fields.q, "label:bug", "and the other one")
	w.flush()
	same(listed(c), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the other block still lists the PRs")
	c.close()
	local drawn = c.renders()
	a.press("enter")
	a.typeText(" -label:wip")
	a.press("enter")
	eq(#requestsOf(s.gh, "search"), 5, "a closed pane is not searched for")
	eq(c.renders(), drawn, "and not drawn")
end)

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

case("host: gh's active account changing reaches every block: the old account's data goes and nothing runs as it", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30), searchItem(8, "o/r", EPOCH - 90) }
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	w.flush()
	same(listed(a), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the active gh account's PRs")
	local before = #s.gh.requests
	s.gh.active = "work"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	a.typeText("r")
	w.flush()
	same(listed(a), { "no_2fr_237", "no_2fr_238" }, "this block shows the new account's PRs")
	same(listed(c), { "no_2fr_237", "no_2fr_238" }, "and so does the other one")
	local ranAsOld = false
	for i = before + 1, #s.gh.requests do
		if s.gh.requests[i].kind == "search" and s.gh.requests[i].login == "octocat" then
			ranAsOld = true
		end
	end
	eq(ranAsOld, false, "nothing searched as the old account after it changed")
end)

case("host: a search still running for the old account never shows after the account changed", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and req.login == "octocat" then
			return { delay = 5000, stdout = jsonEncode({ total = 3, next = NULL, cost = 1, items = s.gh.items.octocat }) }
		end
		return nil
	end
	local b = openQueue(w)
	eq(pickerOf(b).state, "loading", "the first search is still running")
	-- another block saves the shown view with a login of its own: this one reloads the views
	local c = w.open(2, { "/work/r" })
	goToSettings(c, "views")
	expand(c, "vopen:prs:v1")
	loginsSavedBy(w, c, { "work" }, "Mine")
	w.advance(1)
	same(listed(b), { "no_2fr_237" }, "the new account's list is shown")
	w.advance(5000)
	same(listed(b), { "no_2fr_237" }, "the old account's late answer is dropped")
end)

-- Two PRs whose checks the search only summarises, and the full checks each one loads.
local function checksScene(w: World): HostScene
	local s = hostScene(w, 0)
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { checks = "SUCCESS" }),
		searchItem(2, "o/r", EPOCH - 120, { checks = "FAILURE" }),
	}
	s.gh.checks["o/r#1"] = nodes(2)
	s.gh.checks["o/r#2"] = nodes(3)
	return s
end

-- One check as GraphQL lists it; `state` is "queued", "running", "passed" or "failed".
local function job(name: string, state: string): { [string]: any }
	if state == "queued" then
		return checkRun(name, "QUEUED", nil, nil, { id = name })
	elseif state == "running" then
		return checkRun(name, "IN_PROGRESS", nil, "2026-01-01T00:00:00Z", { id = name })
	end
	return checkRun(name, "COMPLETED", if state == "passed" then "SUCCESS" else "FAILURE", "2026-01-01T00:00:00Z", { id = name })
end

-- Pull request o/r#1 as the server shows it from now on: the search summarises its first two checks, the checks
-- query lists all of them. Its updatedAt never moves, because a check finishing does not touch the pull request.
local function serveChecks(s: HostScene, rollup: string, list: { any })
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60, { checks = rollup, runs = array({ list[1], list[2] }), runTotal = #list }) }
	s.gh.checks["o/r#1"] = list
end

-- The preview's check rows as "name — detail", in the order shown: required, then the others.
local function runRows(b: Block): { string }
	local out: { string } = {}
	for _, key in { "required", "runs" } do
		local list: any = findKey(pickerNode(b), key)
		if list then
			for _, row in list.c do
				table.insert(out, row.p.title)
			end
		end
	end
	return out
end

case("host: the full checks load once the cursor rests, never while it moves or a render repeats it, and a PR with current checks asks for nothing", function(w: World)
	local s = checksScene(w)
	local b = openQueue(w)
	eq(#requestsOf(s.gh, "checks"), 0, "nothing loads the moment a PR is selected")
	w.advance(100)
	b.press("down")
	for _ = 1, 3 do
		b.render()
	end
	w.advance(299)
	eq(#requestsOf(s.gh, "checks"), 0, "the wait restarted when the cursor moved, and renders do not restart it")
	w.advance(1)
	local sent = requestsOf(s.gh, "checks")
	eq(#sent, 1, "one load, for the PR the cursor rests on")
	eq(sent[1].fields.n, "2", "the second PR, not the one passed over")
	has(b.text(), "job 3", "the loaded checks are shown")
	for _ = 1, 20 do
		b.render()
	end
	eq(#requestsOf(s.gh, "checks"), 1, "renders never repeat a load")
	b.press("up")
	w.advance(300)
	eq(#requestsOf(s.gh, "checks"), 2, "the other PR loads once its cursor has rested")
	b.press("down")
	w.advance(1000)
	eq(#requestsOf(s.gh, "checks"), 2, "going back to a PR whose checks are current asks for nothing")
	local before, searched = #requestsOf(s.gh, "checks"), #requestsOf(s.gh, "search")
	w.advance(10 * 60 * 1000)
	local later = requestsOf(s.gh, "checks")
	yes(#later - before <= #requestsOf(s.gh, "search") - searched, "an idle pane reloads at most once per refresh")
	for i = before + 1, #later do
		eq(later[i].fields.n, "2", "and only for the PR the cursor rests on")
	end
	b.close()
	w.advance(10 * 60 * 1000)
	eq(#requestsOf(s.gh, "checks"), #later, "a closed pane asks for nothing")
end)

case("host: checks that finish while the PR's updatedAt does not move replace the list the preview showed on the next refresh", function(w: World)
	local s = hostScene(w, 0)
	serveChecks(s, "PENDING", { job("build", "queued"), job("test", "queued"), job("lint", "queued") })
	local b = openQueue(w)
	w.advance(300)
	same(runRows(b), { "build — Queued", "test — Queued", "lint — Queued" }, "the full list loads queued")
	serveChecks(s, "SUCCESS", { job("build", "passed"), job("test", "passed"), job("lint", "passed") })
	w.advance(62000)
	has(b.text(), "Passing", "the refreshed search says the checks passed")
	same(runRows(b), { "build — Passed", "test — Passed", "lint — Passed" }, "and so does the list, though the PR was not updated")
	lacks(b.text(), "Queued", "nothing of the old list is left")
end)

case("host: jobs that move on while the rollup stays pending replace the list the preview showed on the next refresh", function(w: World)
	local s = hostScene(w, 0)
	serveChecks(s, "PENDING", { job("build", "passed"), job("test", "running"), job("lint", "queued") })
	local b = openQueue(w)
	w.advance(300)
	same(runRows(b), { "test — In progress", "lint — Queued", "build — Passed" }, "the full list loads, pending first")
	serveChecks(s, "PENDING", { job("build", "passed"), job("test", "passed"), job("lint", "running") })
	w.advance(62000)
	has(b.text(), "Pending", "the rollup did not change")
	same(runRows(b), { "lint — In progress", "build — Passed", "test — Passed" }, "the third job's progress is only in the full list, and it is shown")
end)

case("host: a check row is its job, its workflow dim, the time it took and a toned icon; required ones apart, every check listed", function(w: World)
	local s = hostScene(w, 0)
	local build = job("ci / build", "failed")
	build.completedAt = "2026-01-01T00:00:03Z"
	build.isRequired = true
	local gate = job("gate", "passed")
	gate.isRequired = true
	serveChecks(s, "FAILURE", { build, gate, job("test", "running"), job("lint", "passed"), job("docs", "passed") })
	local b = openQueue(w)
	w.advance(300)
	local function rows(list: any): { string }
		local out: { string } = {}
		for _, row in list.c do
			eq(row.k, "item", "only rows in a list: other kinds get no row behaviour")
			table.insert(out, table.concat({ row.p.label, row.p.detail or "-", row.p.value or "-", row.p.icon, row.p.tone }, " "))
		end
		return out
	end
	local preview = pickerNode(b)
	eq(findKey(preview, "required-head").p.spans[1].t, "Required · 2", "required checks under their own heading")
	same(rows(findKey(preview, "required", "list")), { "build ci 3s x error", "gate - - check success" }, "the job, its workflow, its time and its status as an icon, worst first")
	eq(findKey(preview, "optional-head").p.spans[1].t, "Optional · 3", "the rest under theirs")
	same(rows(findKey(preview, "runs", "list")), { "test - - clock warning", "lint - - check success", "docs - - check success" }, "passed ones are listed too; a running check has no time and no status word")
	local many: { any } = {}
	for i = 1, 30 do
		table.insert(many, job("job" .. i, "passed"))
	end
	serveChecks(s, "SUCCESS", many)
	w.advance(62000)
	preview = pickerNode(b)
	local all: any = findKey(preview, "runs", "list")
	eq(#all.c, 30, "thirty: every one is a row")
	eq(all.p.max, nil, "in the preview's own scroll, not a list of its own")
	eq(findKey(preview, "optional-head"), nil, "with no required checks there are no headings")
end)

case("host: the preview shimmers while the detail loads, then shows the merge state, each reviewer's verdict and the description, folded and foldable again", function(w: World)
	local s = hostScene(w, 0)
	serveChecks(s, "SUCCESS", { job("build", "passed") })
	s.gh.about["o/r#1"] = {
		mergeable = "CONFLICTING",
		merge = "DIRTY",
		body = "## Why\nBecause.<!-- CURSOR_SUMMARY -->\nGenerated recap.\n<!-- /CURSOR_SUMMARY -->",
		reviews = array({ { login = "ann", state = "APPROVED" } }),
		requested = array({ "bob" }),
	}
	local b = openQueue(w)
	local function merge(): any
		for _, item in findKey(pickerNode(b), "facts", "kv").p.items do
			if item.k == "Merge" then
				return item.v[1]
			end
		end
		return nil
	end
	eq(merge(), nil, "no merge state before the detail loads")
	eq(findKey(pickerNode(b), "reviewers"), nil, "nor reviewers")
	eq(findKey(pickerNode(b), "reviewers-loading", "shimmer").p.text, "Loading reviewers…", "but Tern's shimmer under the heading")
	eq(findKey(pickerNode(b), "runs-loading", "shimmer").p.text, "Loading checks…", "and under the checks'")
	w.advance(300)
	eq(merge().t, "Conflicts", "a conflicting PR says so")
	eq(merge().s, "error", "in red")
	local rows: { string } = {}
	for _, item in findKey(pickerNode(b), "reviewers", "list").c do
		eq(item.p.value, nil, "no status word: the icon is the verdict")
		table.insert(rows, item.p.title .. " " .. item.p.icon .. " " .. item.p.tone)
	end
	same(rows, { "@ann — Approved check success", "@bob — Requested clock warning" }, "each reviewer with a verdict, then those still asked; the tooltip spells it out")
	eq(findKey(pickerNode(b), "reviewers-loading"), nil, "the shimmer is gone")
	eq(findKey(pickerNode(b), "runs-loading"), nil, "from the checks too")
	local function card(): any
		return findKey(pickerNode(b), "description", "card")
	end
	eq(card().p.head, nil, "no heading: just the text")
	eq(card().p.collapsed, true, "the description starts folded")
	same(card().p.preview, { lines = 6 }, "to its first lines, with Tern's button for the rest")
	eq(findKey(card(), "body", "md").p.text, "## Why\nBecause.", "as Markdown, without Cursor's generated summary")
	eq(findKey(pickerNode(b), "less"), nil, "nothing to fold back yet")
	b.event({ ev = "toggle", id = "layer.queue.description", key = "description", collapsed = false })
	eq(card().p.collapsed, false, "the more-lines button's unfolding is kept")
	local less: any = findKey(pickerNode(b), "less", "item")
	b.event({ ev = "action", id = "layer.queue.less", act = less.p.actions.click })
	eq(card().p.collapsed, true, "Show less folds it again")
	eq(findKey(pickerNode(b), "less"), nil, "and goes")
end)

case("host: Refresh reloads the checks the preview already showed, without waiting for the timer", function(w: World)
	local s = hostScene(w, 0)
	serveChecks(s, "PENDING", { job("build", "passed"), job("test", "running"), job("lint", "queued") })
	local b = openQueue(w)
	w.advance(300)
	same(runRows(b), { "test — In progress", "lint — Queued", "build — Passed" }, "the full list loads")
	serveChecks(s, "PENDING", { job("build", "passed"), job("test", "passed"), job("lint", "running") })
	b.typeText("r")
	w.flush()
	w.advance(1000)
	same(runRows(b), { "lint — In progress", "build — Passed", "test — Passed" }, "r shows where the jobs are now")
	eq(#requestsOf(s.gh, "checks"), 2, "with one reload")
end)

case("host: a checks load that a refresh outdated never shows its answer, and the preview ends on the fresh list", function(w: World)
	local s = hostScene(w, 0)
	local stale = { job("build", "queued"), job("test", "queued"), job("lint", "queued") }
	serveChecks(s, "PENDING", stale)
	local slow = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" and slow then
			slow = false
			return { delay = 5000, stdout = jsonEncode({ total = 3, next = NULL, nodes = array(stale) }) }
		end
		return nil
	end
	local b = openQueue(w)
	w.advance(300)
	eq(#requestsOf(s.gh, "checks"), 1, "the slow load is out and answers at 5.3 s")
	serveChecks(s, "PENDING", { job("build", "passed"), job("test", "passed"), job("lint", "running") })
	w.advance(700)
	b.typeText("r")
	w.flush()
	lacks(b.text(), "Queued", "the refreshed search is shown while the old load is still out")
	w.advance(4400)
	lacks(b.text(), "Queued", "the old answer arrived and is not shown")
	w.advance(5000)
	same(runRows(b), { "lint — In progress", "build — Passed", "test — Passed" }, "the fresh load is what stays")
	lacks(b.text(), "Queued", "of the old list nothing is left")
	yes(#requestsOf(s.gh, "checks") <= 2, "one fresh load for the one refresh")
end)

case("host: a reload that fails keeps the last list with its error and Retry, and backs off like a first load", function(w: World)
	local s = hostScene(w, 0)
	serveChecks(s, "PENDING", { job("build", "passed"), job("test", "running"), job("lint", "queued") })
	local failing = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" and failing then
			return { status = 1, stderr = "gh: Bad Gateway (HTTP 502)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	w.advance(300)
	local loaded = { "test — In progress", "lint — Queued", "build — Passed" }
	same(runRows(b), loaded, "the full list loads")
	failing = true
	w.advance(60000)
	same(runRows(b), loaded, "the list stays when its reload fails")
	yes(findKey(pickerNode(b), "runs-retry") ~= nil, "with the failure explained and Retry on offer")
	w.advance(45000)
	local sent = requestsOf(s.gh, "checks")
	eq(#sent, 4, "the first load, the failed reload and two retries")
	eq(sent[3].call.at - sent[2].call.at, 15000, "the first wait is 15 s")
	eq(sent[4].call.at - sent[3].call.at, 30000, "and it doubles")
	failing = false
	b.event({ ev = "action", id = "layer.queue", act = "retry-checks" })
	w.advance(300)
	eq(findKey(pickerNode(b), "runs-retry"), nil, "Retry reloads the list and the button goes")
	same(runRows(b), loaded, "the list is still there")
end)

case("host: a failed checks load offers Retry, backs off 15 s doubling to 5 minutes, and loads once the failure clears", function(w: World)
	local s = checksScene(w)
	local failing = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" and failing then
			return { status = 1, stderr = "gh: Bad Gateway (HTTP 502)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	w.advance(300)
	yes(findKey(pickerNode(b), "runs-retry") ~= nil, "a failed load offers Retry")
	local gaps = { 15000, 30000, 60000, 120000, 240000, 300000, 300000 }
	for _, gap in gaps do
		w.advance(gap)
	end
	local sent = requestsOf(s.gh, "checks")
	eq(#sent, #gaps + 1, "one attempt after every wait")
	for i, gap in gaps do
		eq(sent[i + 1].call.at - sent[i].call.at, gap, "the wait before attempt " .. i + 1)
	end
	failing = false
	w.advance(300000)
	has(b.text(), "job 2", "the load succeeds once the failure clears")
	eq(findKey(pickerNode(b), "runs-retry"), nil, "and the Retry button goes")
	local before, searched = #requestsOf(s.gh, "checks"), #requestsOf(s.gh, "search")
	w.advance(30 * 60 * 1000)
	yes(#requestsOf(s.gh, "checks") - before <= #requestsOf(s.gh, "search") - searched, "afterwards at most one reload per refresh")
end)

case("host: a sign-in failure on the checks waits for Retry, and Retry loads them again", function(w: World)
	local s = checksScene(w)
	local failing = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" and failing then
			return { status = 1, stderr = "gh: Bad credentials (HTTP 401)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	w.advance(300)
	eq(#requestsOf(s.gh, "checks"), 1, "one attempt")
	w.advance(2 * 60 * 60 * 1000)
	eq(#requestsOf(s.gh, "checks"), 1, "no automatic retry of a sign-in failure")
	yes(findKey(pickerNode(b), "runs-retry") ~= nil, "Retry is on offer")
	failing = false
	b.event({ ev = "action", id = "layer.queue", act = "retry-checks" })
	w.advance(300)
	eq(#requestsOf(s.gh, "checks"), 2, "Retry loads them again")
	has(b.text(), "job 2", "and shows them")
	eq(findKey(pickerNode(b), "runs-retry"), nil, "the button goes")
end)

case("host: a rate-limited checks load waits for the limit's end instead of the backoff", function(w: World)
	local s = checksScene(w)
	local limited = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" and limited then
			limited = false
			return { status = 1, stdout = "HTTP/2.0 429 Too Many Requests\r\nRetry-After: 90\r\n\r\n", stderr = "gh: HTTP 429\n" }
		end
		return nil
	end
	local b = openQueue(w)
	w.advance(300 + 90 * 1000)
	local sent = requestsOf(s.gh, "checks")
	eq(#sent, 2, "the second attempt came after the limit")
	eq(sent[2].call.at - sent[1].call.at, 90000, "exactly when GitHub said")
	has(b.text(), "job 2", "and it loaded")
end)

case("host: checks loading or loaded under one account never show under another", function(w: World)
	local s = checksScene(w)
	newAcli(w)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(1, "o/r", EPOCH - 60, { checks = "SUCCESS" }) }
	s.gh.override = function(req: GhReq): Reply?
		if req.kind ~= "checks" then
			return nil
		end
		local mine = if req.login == "work" then "work-job" else "old-job"
		local body = jsonEncode({ total = 1, next = NULL, nodes = array({ checkRun(mine, "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = mine }) }) })
		return { stdout = body, delay = if req.login == "work" then 0 else 5000 }
	end
	local b = openQueue(w)
	w.advance(300)
	eq(#requestsOf(s.gh, "checks"), 1, "the old account's checks are on their way")
	-- another block saves the shown view with a login of its own: this one reloads the views
	local c = w.open(2, { "/work/r" })
	goToSettings(c, "views")
	expand(c, "vopen:prs:v1")
	loginsSavedBy(w, c, { "work" }, "Mine")
	w.flush()
	w.advance(300)
	local sent = requestsOf(s.gh, "checks")
	eq(sent[#sent].login, "work", "the new account asked for its own, as itself")
	has(b.text(), "work-job", "and shows what it got")
	w.advance(5000)
	has(b.text(), "work-job", "the old account's late answer changes nothing")
	lacks(b.text(), "old-job", "and is not shown")
end)

case("host: items from two repositories with the same number get distinct ids", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { searchItem(12, "o/a", EPOCH - 60), searchItem(12, "o/b", EPOCH - 120) }
	local b = openQueue(w)
	same(listed(b), { "no_2fa_2312", "no_2fb_2312" }, "one id per repository, though both are #12")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fb_2312" })
	eq(pickerOf(b).selected, "no_2fb_2312", "selecting the second puts the cursor on it")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/b", 12), "and the Worktree link names o/b, not o/a")
end)

case("host: selecting and activating rows follows the picker, and a row that is gone is ignored", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	eq(pickerOf(b).selected, "no_2fr_232", "selecting a row moves the selection")
	b.event({ ev = "activate", id = "layer.queue", item = "no_2fr_233" })
	eq(pickerOf(b).selected, "no_2fr_233", "activating a row selects it")
	eq(w.opened[#w.opened], prLink("open", "o/r", 3), "and opens it in a Browser block")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2399" })
	eq(pickerOf(b).selected, "no_2fr_233", "a row that a refresh removed is ignored")
	b.event({ ev = "select", id = "somewhere.else", item = "no_2fr_231" })
	eq(pickerOf(b).selected, "no_2fr_233", "and so is an event for another surface")
end)

case("host: with Settings open the queue beside it takes clicks, a field being typed is saved first, and keys stay Settings'", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	b.event({ ev = "select", id = "layer.settings", item = "name:prs:v1" })
	b.press("enter")
	for _ = 1, 40 do
		b.press("backspace")
	end
	b.typeText("Mine")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	eq(pickerOf(b).selected, "no_2fr_232", "a row click moves the selection")
	eq(w.kv.get("views-prs").items[1].name, "Mine", "after saving the name being typed")
	eq(prefsOf(b).editing, nil, "which closes its edit")
	eq(prefsOf(b).page, "views", "Settings stays open")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_232", "keys still go to Settings")
	pickScope(b, "prs:v2")
	eq(pickerOf(b).scope, "prs:v2", "a sidebar view click switches the view")
	yes(prefsOf(b) ~= nil, "beside Settings")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "the Settings button closes the sheet")
end)

case("host: a worktree request becomes a badge and a card with its status, place and update commands, and removes nothing", function(w: World)
	local s = hostScene(w, 2)
	for n = 1, 2 do
		s.git.served["refs/pull/" .. n .. "/head"] = sha("b")
		s.gh.meta["o/r#" .. n] = { base = "o/r", sha = sha("b"), ref = if n == 1 then "feature" else "feature-2", headRepo = "o/r", headOwner = "o", state = "open" }
	end
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	local sent = 0
	-- Asks the block for PR `n`'s worktree as a window would, and returns its answer.
	local function ask(n: number, extra: { [string]: any }?): any
		sent += 1
		local body: { [string]: any } = { op = "worktree", repo = "o/r", number = n }
		if extra then
			for k, v in extra do
				body[k] = v
			end
		end
		request(b, "a" .. sent, body)
		w.flush()
		return answerOf(b, "a" .. sent)
	end
	eq(badgeOf(b), nil, "no badge before there is a worktree")
	eq(cardOf(b), nil, "and no card")
	eq(ask(1).path, target, "the answer says where the worktree is")
	eq(w.opened[#w.opened], "plotroom://rpc/a1", "and the window is told to read it")
	local named = ask(1, { tpl = "/home/u/.omp/agent/prompts/other.md" })
	eq(named.path, target, "a template named in the request is ignored: the worktree is served")
	eq(named.refused, nil, "with no refusal")
	eq(named.why, nil, "and no reason")
	yes(badgeOf(b) ~= nil, "a worktree puts a badge on the row")
	eq(badgeOf(b).tone, "success", "a current, clean worktree is a success")
	eq(cardOf(b).p.tone, "success", "and a card in the preview")
	has(cardText(b), target, "that says where it is")
	s.git.dirty[target] = " M src/a.lua\n"
	ask(1)
	eq(badgeOf(b).tone, "warning", "local changes deserve a look")
	s.git.dirty[target] = nil
	s.gh.meta["o/r#1"].sha = sha("c")
	ask(1)
	eq(badgeOf(b).tone, "warning", "so does a worktree behind its PR")
	local ran = #w.calls
	eq(commandsOf(b, "update"), "git -C " .. target .. " pull --ff-only", "the update command too")
	eq(#w.calls, ran, "showing them ran nothing")
	s.gh.meta["o/r#1"].sha = sha("b")
	ask(1)
	eq(badgeOf(b).tone, "success", "caught up with its PR, the worktree is a success again")
	eq(commandsOf(b, "update"), nil, "no update commands to show")
	s.gh.meta["o/r#1"] = nil
	yes(type(ask(1).problem) == "string", "a PR that cannot be read is answered with the reason")
	eq(badgeOf(b), nil, "a failed attempt shows no badge")
	eq(cardOf(b).p.tone, "error", "but an error card")
	eq(findKey(cardOf(b), "actions"), nil, "with no buttons: there is no worktree to go to or remove")
	w.fs.denyMkdir["/wt"] = "mkdir denied"
	showPr(b, 2)
	ask(2)
	eq(badgeOf(b, 2), nil, "a worktree that cannot be made shows no badge either")
	eq(cardOf(b).p.tone, "error", "but an error card")
	has(cardText(b), "mkdir denied", "with the reason")
	for _, never in { "worktree remove", "branch", "update-ref", "merge" } do
		eq(countLog(s.git, never), 0, "git " .. never .. " was never run")
	end
end)

case("host: the worktree card is two badges, the branch and the path, then the buttons that go to its tab, open one or remove it", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	w.env.HOME = "/wt"
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	local function ask()
		request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
		w.flush()
	end
	ask()
	same(chipsOf(b), { "Up to date", "Clean" }, "at the PR head and clean: two badges")
	eq(findKey(cardOf(b), "sync", "badge").p.tone, "success", "a good state")
	has(findKey(cardOf(b), "sync", "badge").p.title, "Created", "with the one-line summary of the attempt as the tooltip")
	for _, gone in { "summary", "never", "facts" } do
		eq(findKey(cardOf(b), gone), nil, "no " .. gone .. " line: the summary sentence, the footer and the kv are gone")
	end
	eq(findKey(cardOf(b), "cleanup", "section"), nil, "nor cleanup commands")
	eq(findKey(cardOf(b), "update", "section"), nil, "and no update commands: it is at the PR head")
	local branch = findKey(cardOf(b), "wbranch")
	eq(findKey(branch, "v").p.spans[1].t, "feature", "the branch")
	eq(findKey(branch, "copy", "icon").p.href, "feature", "copied as it is")
	local path = findKey(cardOf(b), "wpath")
	eq(findKey(path, "v").p.spans[1].t, "~/plotroom-o_r-pr-1", "the path, home written ~")
	eq(findKey(path, "v").p.truncate, "middle", "cut in the middle when it is long")
	eq(findKey(path, "v").p.title, target, "the tooltip has all of it")
	eq(findKey(path, "copy", "icon").p.href, target, "and so does the copy icon")
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree" }, "no tab works in it: open one, or remove it")
	local open: any = findKey(cardOf(b), "open", "item")
	same(open.p.hint, { "w" }, "Open in new tab wears the Worktree key")
	eq(open.p.actions.click, "worktree", "and is the Worktree button")
	local remove: any = findKey(cardOf(b), "remove", "item")
	eq(remove.p.tone, "error", "Remove is red")
	eq(remove.p.icon, "trash", "with a trash can")
	eq(remove.p.hint, nil, "and no key")
	pressCard(b, "open")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "a click opens the Worktree link, as the key does")
	table.insert(w.panes, { pane = 9, cwd = target .. "/src" })
	b.render()
	same(buttonsOf(b), { "go:Go to tab", "remove:Remove worktree" }, "while a tab works in it, the button goes there instead")
	same(findKey(cardOf(b), "go", "item").p.hint, { "g" }, "wearing the Go to tab key")
	pressCard(b, "go")
	eq(w.opened[#w.opened], prLink("goto", "o/r", 1), "and its click opens the Go to tab link")
	table.remove(w.panes)
	s.gh.meta["o/r#1"].sha = sha("c")
	s.git.dirty[target] = " M src/a.lua\n"
	ask()
	same(chipsOf(b), { "Not at PR head", "Uncommitted changes" }, "behind its PR and modified")
	eq(findKey(cardOf(b), "sync", "badge").p.tone, "warning", "both are warnings")
	eq(findKey(cardOf(b), "changes", "badge").p.tone, "warning", "")
	eq(cardOf(b).p.tone, "warning", "and so is the card")
	eq(findKey(cardOf(b), "update", "section").p.collapsed, true, "the update commands are folded away")
	eq(commandsOf(b, "update"), "git -C " .. target .. " pull --ff-only", "and complete")
	s.gh.meta["o/r#1"].sha = sha("b")
	s.git.dirty[target] = nil
	s.git.fail["status"] = { status = 128, stderr = "fatal: unable to read the index\n" }
	ask()
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "a status git could not read is never Clean")
	eq(findKey(cardOf(b), "changes", "badge").p.tone, "muted", "and is no warning either")
	s.git.fail["status"] = nil
	s.gh.meta["o/r#1"] = nil
	ask()
	eq(cardOf(b).p.tone, "error", "a failed attempt is a red card")
	eq(findKey(cardOf(b), "status"), nil, "with no badges")
	same(buttonsOf(b), {}, "and no buttons: there is no worktree to go to or remove")
end)

case("host: Remove worktree asks first: Esc or Enter keeps it, d or the Remove button takes it away, on the host, with its card and badge", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target, branch, ref = "/wt/plotroom-o_r-pr-1", "feature", "refs/plotroom-pr/o/r/pr-1"
	local function ask()
		request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
		w.flush()
	end
	ask()
	eq(confirmOf(b), nil, "nothing is asked yet")
	pressCard(b, "remove")
	local box = confirmOf(b)
	yes(box ~= nil, "Remove worktree asks")
	eq(box.p.head, "Remove worktree?", "with its question")
	eq(box.p.modal, true, "over everything")
	same(findKey(box, "facts", "kv").p.items, {
		{ k = "Path", v = { { t = target, s = "code" } } },
		{ k = "Branch", v = { { t = branch, s = "code" } } },
	}, "naming the worktree's path and branch")
	eq(findKey(box, "tab"), nil, "no tab works in it: no warning")
	eq(b.press("j"), false, "other keys are not taken while it asks")
	eq(b.press("escape"), true, "Esc keeps it")
	eq(confirmOf(b), nil, "the question closes")
	pressCard(b, "remove")
	eq(b.press("enter"), true, "Enter keeps it too")
	eq(confirmOf(b), nil, "and closes it")
	table.insert(w.panes, { pane = 9, cwd = target })
	pressCard(b, "remove")
	has(findKey(confirmOf(b), "tab", "text").p.spans[1].t, "A tab works in it", "while a tab works in it, the question warns that it is left in a folder that is gone")
	b.press("escape")
	table.remove(w.panes)
	pressCard(b, "remove")
	local keep: any = findKey(confirmOf(b), "keep", "item")
	b.event({ ev = "action", id = "layer.confirm.buttons.keep", act = keep.p.actions.click })
	eq(confirmOf(b), nil, "the Keep button keeps it")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed so far")
	local mark = #s.git.log
	local told = #w.toasts
	pressCard(b, "remove")
	b.typeText("d")
	eq(confirmOf(b), nil, "d closes the question")
	eq(w.toasts[told + 1].level, "info", "and starts the removal")
	has(w.toasts[told + 1].text, "o/r#1", "naming the pull request")
	request(b, "a2", { op = "worktree", repo = "o/r", number = 1 })
	eq(answerOf(b, "a2").busy, true, "no request for the worktree is served while it is removed")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree remove " .. target,
		"merge-base --is-ancestor refs/heads/" .. branch .. " " .. ref,
		"branch -D " .. branch,
		"update-ref -d " .. ref,
		"worktree list --porcelain -z",
	}, "the worktree without --force, then -D only after the ancestry check, then the ref, then a read of the checkout")
	eq(cardOf(b), nil, "its card is gone")
	eq(badgeOf(b), nil, "and the row's badge")
	eq(w.toasts[#w.toasts].level, "success", "the removal is reported")
	eq(w.toasts[#w.toasts].text, "Worktree removed", "")
	eq(w.toasts[#w.toasts].sub, "Branch feature was deleted too.", "with what became of the branch")
	eq(#s.git.worktrees, 1, "only the main worktree is left")
	ask()
	eq(answerOf(b, "a1").created, true, "asking again makes a new worktree: the old one is really gone")
	pressCard(b, "remove")
	local remove: any = findKey(confirmOf(b), "delete", "item")
	eq(remove.p.label, "Remove", "the question's button says what it does")
	b.event({ ev = "action", id = "layer.confirm.buttons.delete", act = remove.p.actions.click })
	w.flush()
	eq(cardOf(b), nil, "its Remove button removes it as d does")
	ask()
	b.typeText("s")
	b.event({ ev = "action", id = "layer.queue.worktree.actions.remove", act = "remove-worktree" })
	b.press("escape")
	eq(confirmOf(b), nil, "with Settings open the queue's buttons do nothing, here as on the action bar")
end)

case("host: a worktree git refuses to remove stays: its card says why, its badge follows, and nothing else was done", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(badgeOf(b).tone, "success", "a clean worktree starts as a success")
	s.git.dirty[target] = " M src/a.lua\n"
	local before = snapshot(s.git)
	local mark = #s.git.log
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree remove " .. target,
		"worktree list --porcelain -z",
	}, "git was asked once, without --force, and only read the checkout afterwards")
	eq(snapshot(s.git), before, "no worktree, branch or ref changed")
	yes(cardOf(b) ~= nil, "the card stays")
	has(cardText(b), "Not removed. It has uncommitted changes; commit, stash or remove it yourself.", "and says why")
	same(chipsOf(b), { "Up to date", "Uncommitted changes" }, "with what git found")
	eq(cardOf(b).p.tone, "warning", "so it is a warning now")
	eq(badgeOf(b).tone, "warning", "and so is the row's badge")
	eq(w.toasts[#w.toasts].level, "error", "the refusal is toasted too")
	eq(w.toasts[#w.toasts].text, "Worktree not removed", "")
	eq(w.toasts[#w.toasts].sub, "It has uncommitted changes; commit, stash or remove it yourself.", "with the same reason")
	s.git.dirty[target] = nil
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	eq(cardOf(b), nil, "once the changes are dealt with, it goes")
end)

case("host: removing a worktree whose branch holds commits of its own keeps the branch, and says so", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target, branch, ref = "/wt/plotroom-o_r-pr-1", "feature", "refs/plotroom-pr/o/r/pr-1"
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	s.git.ahead[branch] = true
	s.git.unmerged[branch] = true
	local mark = #s.git.log
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree remove " .. target,
		"merge-base --is-ancestor refs/heads/" .. branch .. " " .. ref,
		"branch -d " .. branch,
		"worktree list --porcelain -z",
	}, "-d, never -D, and the ref stays with its branch; then a read of the checkout")
	eq(cardOf(b), nil, "the worktree is gone, and so is its card")
	eq(w.toasts[#w.toasts].level, "success", "removing it worked")
	eq(w.toasts[#w.toasts].sub, "Branch feature was kept. The branch 'feature' is not fully merged.", "and the branch that stayed is named")
	eq(s.git.refs["refs/heads/" .. branch], sha("b"), "it holds its commits")
end)

case("host: Remove worktree is refused while the worktree is being prepared, at the button and at the question", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	local told = #w.toasts
	request(b, "a2", { op = "worktree", repo = "o/r", number = 1 }) -- in flight: its git commands are not answered yet
	pressCard(b, "remove")
	eq(confirmOf(b), nil, "no question while it is being prepared")
	eq(w.toasts[told + 1].text, "Worktree is busy", "the button says why")
	w.flush()
	pressCard(b, "remove")
	yes(confirmOf(b) ~= nil, "idle again, it asks")
	request(b, "a3", { op = "worktree", repo = "o/r", number = 1 })
	b.typeText("d")
	eq(confirmOf(b), nil, "the question closes")
	eq(w.toasts[#w.toasts].text, "Worktree is busy", "and d is refused the same")
	w.flush()
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	yes(cardOf(b) ~= nil, "and the card is still there")
end)

-- ---- the worktree card, read from git
-- Nothing about a worktree is remembered between runs: after each refresh, Worktree attempt and removal the block lists
-- its checkouts' worktrees with git, so a block that never made one shows the ones that exist, and one removed outside
-- Plotroom goes.

case("host: a fresh block shows the card and the row badge of a worktree its checkout already has, read from git with no Worktree press", function(w: World)
	local s = hostScene(w, 2)
	local path = leaveWt(w, s, 1)
	s.gh.items.octocat[1].headSha = sha("b")
	local b = openQueue(w)
	yes(badgeOf(b) ~= nil, "the PR's row wears the Worktree badge")
	eq(badgeOf(b).tone, nil, "with no tone while its changes are unread")
	eq(badgeOf(b, 2), nil, "the PR with no worktree wears none")
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "the card: at the PR's head, its changes unread")
	eq(cardOf(b).p.tone, nil, "no tone either")
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree" }, "with the buttons that open a tab in it or remove it")
	has(cardText(b), "plotroom/o/r/pr-1", "its branch")
	has(cardText(b), path, "and where it is")
	eq(countLog(s.git, "worktree list"), 1, "git listed the checkout once")
	eq(countLog(s.git, "config"), 0, "and read no git config: a worktree is known by its branch or folder name")
	eq(countLog(s.git, "status"), 0, "no worktree's changes were read yet")
	eq(countLog(s.git, "worktree add"), 0, "nothing was made")
	w.advance(300)
	same(chipsOf(b), { "Up to date", "Clean" }, "the selected PR's changes are read once the cursor has rested on it")
	eq(badgeOf(b).tone, "success", "and the row follows")
	eq(cardOf(b).p.tone, "success", "and the card")
	eq(countLog(s.git, "status"), 1, "by one status")
	eq(countLog(s.git, "worktree list"), 1, "the checkout was not listed again for it")
	eq(#w.toasts, 0, "nothing was said")
end)

case("host: a block opened after another made a worktree shows its card at once, though it made nothing", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", state = "open" }
	s.gh.items.octocat[1].headSha = sha("b")
	local first = openQueue(w)
	request(first, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(answerOf(first, "a1").created, true, "the first block made the worktree")
	w.advance(300)
	eq(countLog(s.git, "status"), 1, "the attempt read the worktree's changes: its card does not read them again")
	first.close()
	local fresh = openQueue(w, 2)
	yes(badgeOf(fresh) ~= nil, "a block that never made one wears its row badge")
	same(chipsOf(fresh), { "Up to date", "Changes unchecked" }, "and shows its card, read from git: at the PR's head, its changes unread")
	has(cardText(fresh), "/wt/plotroom-o_r-pr-1", "where it is")
	eq(countLog(s.git, "worktree add"), 1, "the worktree was made once, by the first block")
	request(fresh, "b1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(answerOf(fresh, "b1").created, false, "and the second block reuses it")
end)

case("host: a worktree removed outside Plotroom leaves its card and badge at the next refresh, and a scan that fails changes nothing", function(w: World)
	local s = hostScene(w, 2)
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	local one = leaveWt(w, s, 1)
	leaveWt(w, s, 2)
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil and badgeOf(b, 2) ~= nil, "both rows wear the badge")
	-- git removes the first behind Plotroom's back
	table.remove(s.git.worktrees, 2)
	w.fs.dirs[one] = nil
	b.render()
	yes(cardOf(b) ~= nil, "a render asks git nothing: the card stays")
	local mark = #s.git.log
	s.git.fail["worktree list"] = { status = 128, stderr = "fatal: unable to read the worktrees\n" }
	refreshNow(w, b)
	yes(cardOf(b) ~= nil, "a scan that fails changes nothing")
	yes(badgeOf(b, 1) ~= nil and badgeOf(b, 2) ~= nil, "not the badges either")
	eq(#w.toasts, 0, "and says nothing")
	s.git.fail["worktree list"] = nil
	refreshNow(w, b)
	eq(cardOf(b), nil, "the next scan that works finds it gone, and the card goes")
	eq(badgeOf(b, 1), nil, "and the row's badge")
	yes(badgeOf(b, 2) ~= nil, "the other worktree stays")
	same(logFrom(s.git, mark), {
		"worktree list --porcelain -z",
		"worktree list --porcelain -z",
	}, "one list per refresh")
	showPr(b, 2)
	yes(cardOf(b) ~= nil, "the other PR's card is there")
	-- git moves it: the card follows
	s.git.worktrees[2].path = "/moved/plotroom-o_r-pr-2"
	w.fs.dirs["/moved/plotroom-o_r-pr-2"] = true
	refreshNow(w, b)
	has(cardText(b), "/moved/plotroom-o_r-pr-2", "git moves the worktree: the card names where it is now")
	lacks(cardText(b), "/wt/plotroom-o_r-pr-2", "and no longer where it was")
end)

case("host: the card says Up to date or Not at PR head by the head the last refresh saw, with the commands to catch up", function(w: World)
	local s = hostScene(w, 1)
	local path = leaveWt(w, s, 1)
	local function head(at: string?)
		s.gh.items.octocat[1].headSha = at
	end
	head(sha("b"))
	local b = openQueue(w)
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "the worktree is at the PR's head")
	eq(commandsOf(b, "update"), nil, "nothing to catch up on")
	head(sha("c"))
	refreshNow(w, b)
	same(chipsOf(b), { "Not at PR head", "Changes unchecked" }, "the PR moved on: the worktree is behind it")
	eq(findKey(cardOf(b), "sync", "badge").p.tone, "warning", "a warning")
	eq(badgeOf(b).tone, "warning", "as is the row's badge")
	eq(findKey(cardOf(b), "sync", "badge").p.title, "Reused · Different (local bbbbbbb, PR head ccccccc on branch-1; not updated) · Changes unchecked", "the tooltip says how")
	eq(commandsOf(b, "update"), "git -C " .. path .. " pull --ff-only", "and the command to catch up is one pull: the branch tracks the PR's head branch")
	local ran = #w.calls
	b.render()
	eq(#w.calls, ran, "showing them ran nothing")
	s.git.worktrees[2].head = sha("c") -- the user caught up
	refreshNow(w, b)
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "its head is the PR's again")
	eq(commandsOf(b, "update"), nil, "and there is nothing to run")
	eq(badgeOf(b).tone, nil, "the row's badge is calm again")
	s.git.worktrees[2].head = sha("d") -- a commit of its own
	refreshNow(w, b)
	same(chipsOf(b), { "Not at PR head", "Changes unchecked" }, "a worktree on commits of its own is not at the PR's head either")
	head(nil)
	refreshNow(w, b)
	same(chipsOf(b), { "Not at PR head", "Changes unchecked" }, "a refresh that does not say where the PR's head is leaves the last verdict")
	local fresh = openQueue(w, 2)
	same(chipsOf(fresh), { "Up to date", "Changes unchecked" }, "and a block that has no verdict yet takes the worktree as current")
	eq(badgeOf(fresh).title, "Worktree ready · " .. path, "with nothing to say of its head")
end)

case("host: a worktree's changes are read for the selected item only, once the cursor has rested, and again after each refresh", function(w: World)
	local s = hostScene(w, 4)
	leaveWt(w, s, 1)
	local two = leaveWt(w, s, 2)
	leaveWt(w, s, 3)
	s.git.dirty[two] = " M src/a.lua\n"
	local b = openQueue(w)
	eq(countLog(s.git, "status"), 0, "no status is read as the list is shown")
	w.advance(299)
	eq(countLog(s.git, "status"), 0, "nor before the cursor has rested")
	w.advance(1)
	eq(countLog(s.git, "status"), 1, "then the selected PR's worktree is read")
	same(chipsOf(b), { "Up to date", "Clean" }, "and its card says what git found")
	eq(badgeOf(b, 1).tone, "success", "its row too")
	eq(badgeOf(b, 2).tone, nil, "the others are not read: their badges have no tone yet")
	eq(badgeOf(b, 3).tone, nil, "")
	showPr(b, 2)
	w.advance(100)
	showPr(b, 3)
	w.advance(100)
	showPr(b, 4)
	w.advance(1000)
	eq(countLog(s.git, "status"), 1, "a cursor that moves on before it has rested reads nothing")
	showPr(b, 2)
	w.advance(299)
	eq(countLog(s.git, "status"), 1, "one that rests...")
	w.advance(1)
	eq(countLog(s.git, "status"), 2, "...on a worktree reads it")
	same(chipsOf(b), { "Up to date", "Uncommitted changes" }, "its card shows the changes")
	eq(badgeOf(b, 2).tone, "warning", "and its row")
	showPr(b, 4)
	w.advance(1000)
	eq(countLog(s.git, "status"), 2, "an item with no worktree has nothing to read")
	showPr(b, 1)
	w.advance(1000)
	showPr(b, 2)
	w.advance(1000)
	eq(countLog(s.git, "status"), 2, "and a worktree read since the last refresh is not read again")
	s.git.dirty[two] = nil
	local mark = #s.git.log
	refreshNow(w, b)
	eq(countLog(s.git, "worktree list", mark), 1, "a refresh lists the checkout once...")
	eq(countLog(s.git, "status", mark), 0, "...and reads no status by itself")
	same(chipsOf(b), { "Up to date", "Uncommitted changes" }, "the card keeps what it knew")
	w.advance(300)
	eq(countLog(s.git, "status", mark), 1, "it reads the selected worktree again once the cursor rests")
	same(chipsOf(b), { "Up to date", "Clean" }, "and shows what changed")
	eq(badgeOf(b, 2).tone, "success", "in its row too")
end)

case("host: a scan that began before a worktree attempt or a removal ended cannot undo it", function(w: World)
	local s = hostScene(w, 2)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", state = "open" }
	leaveWt(w, s, 2)
	local b = openQueue(w)
	eq(cardOf(b), nil, "the selected PR has no worktree")
	-- The next listing git gives is `porcelain(s.git)` as it stands now, and comes `ms` late.
	local function slowly(ms: number)
		s.git.fail["worktree list"] = { stdout = porcelain(s.git), delay = ms }
	end
	-- A refresh starts a scan; its answer was read before the worktree existed and comes late.
	slowly(5000)
	refreshNow(w, b)
	s.git.fail["worktree list"] = nil
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(answerOf(b, "a1").created, true, "the worktree is made while the scan is out")
	yes(cardOf(b) ~= nil, "and its card shown")
	slowly(1000) -- the listing made again once the late answer is dropped is slow as well
	w.advance(5000)
	yes(cardOf(b) ~= nil, "the late answer does not list the worktree, and does not take its card away")
	w.advance(1000)
	yes(cardOf(b) ~= nil and badgeOf(b, 1) ~= nil and badgeOf(b, 2) ~= nil, "the listing made again confirms it")
	eq(countLog(s.git, "worktree list"), 4, "the first scan, the refresh's, the attempt's own and the one made again")
	-- The same for a removal: a scan that listed the worktree before it went cannot bring it back.
	slowly(5000)
	refreshNow(w, b)
	s.git.fail["worktree list"] = nil
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	eq(cardOf(b), nil, "the worktree is removed")
	slowly(1000)
	w.advance(5000)
	eq(cardOf(b), nil, "the late answer still lists it, and cannot bring its card back")
	eq(badgeOf(b, 1), nil, "nor its badge")
	w.advance(1000)
	eq(cardOf(b), nil, "the listing made again agrees")
	yes(badgeOf(b, 2) ~= nil, "the other worktree stays")
end)

case("host: every worktree git lists keeps its card, however many there are; only remembered attempts git has not confirmed are capped", function(w: World)
	local s = hostScene(w, 50)
	for n = 1, 25 do
		leaveWt(w, s, n)
	end
	local b = openQueue(w)
	for n = 1, 25 do
		yes(badgeOf(b, n) ~= nil, "PR " .. n .. " wears its badge: there are more worktrees than the cap")
	end
	-- 22 attempts that fail, none of those PRs being known to GitHub: two more than the cap
	for n = 26, 47 do
		request(b, "f" .. n, { op = "worktree", repo = "o/r", number = n })
		w.flush()
	end
	for n = 1, 25 do
		yes(badgeOf(b, n) ~= nil, "PR " .. n .. " still wears it")
	end
	showPr(b, 26)
	eq(cardOf(b), nil, "the oldest failed attempt was forgotten")
	showPr(b, 27)
	eq(cardOf(b), nil, "and the next")
	showPr(b, 28)
	eq(cardOf(b).p.tone, "error", "the rest are kept")
	showPr(b, 47)
	eq(cardOf(b).p.tone, "error", "the newest too")
	showPr(b, 25)
	yes(cardOf(b) ~= nil, "and a worktree git lists keeps its card")
end)

case("host: each saved checkout of the listed repositories is listed once per refresh, however many rows there are, and one with no checkout is left alone", function(w: World)
	local s = hostScene(w, 0)
	local other = newGit(w, "/work/y")
	other.remotes.origin = { "https://github.com/x/y.git" }
	w.kv.put("checkouts", { ["o/r"] = "/work/r", ["x/y"] = "/work/y", ["z/w"] = "" })
	local items: { { [string]: any } } = {}
	for i = 1, 6 do
		table.insert(items, searchItem(i, if i <= 2 then "o/r" elseif i <= 4 then "x/y" else "z/w", EPOCH - i * 60))
	end
	s.gh.items.octocat = items
	leaveWt(w, s, 1)
	table.insert(other.worktrees, { path = "/wt/plotroom-x_y-pr-3", branch = "refs/heads/plotroom/x/y/pr-3", head = sha("b"), locked = false })
	w.fs.dirs["/wt/plotroom-x_y-pr-3"] = true
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil and badgeOf(b, 3) ~= nil, "the worktrees of both repositories show")
	yes(badgeOf(b, 2) == nil and badgeOf(b, 4) == nil and badgeOf(b, 5) == nil and badgeOf(b, 6) == nil, "and no other row wears a badge")
	eq(countLog(s.git, "worktree list"), 1, "o/r's checkout was listed once")
	eq(countLog(other, "worktree list"), 1, "x/y's once")
	refreshNow(w, b)
	eq(countLog(s.git, "worktree list"), 2, "each again at the next refresh, and not once more for the six rows")
	eq(countLog(other, "worktree list"), 2, "")
end)

case("host: a checkout the window gives after the list is shown is read at once: the worktrees it holds show with no refresh", function(w: World)
	local s = hostScene(w, 2)
	leaveWt(w, s, 1)
	local b = w.open(1, { "/nowhere" }) -- a launch folder that is gone maps no checkout
	w.flush()
	eq(#listed(b), 2, "the list is shown")
	eq(cardOf(b), nil, "with no checkout there is no worktree to show")
	hx.selectFirst(b)
	eq(countLog(s.git, "worktree list"), 0, "and none was looked for")
	request(b, "c1", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	eq(answerOf(b, "c1").ok, true, "the window gives the checkout")
	yes(cardOf(b) ~= nil, "its worktree shows")
	eq(countLog(s.git, "worktree list"), 1, "after one listing")
end)

case("host: a checkout typed in Settings is read once git confirms it: the worktrees it holds show with no refresh", function(w: World)
	local s = hostScene(w, 2)
	leaveWt(w, s, 1)
	local b = w.open(1, { "/nowhere" })
	w.flush()
	eq(cardOf(b), nil, "with no checkout there is no worktree to show")
	hx.selectFirst(b)
	w.kv.put("checkouts", { ["o/r"] = "" })
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/work/r")
	b.press("enter")
	w.flush()
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the checkout is saved once git confirms it")
	yes(cardOf(b) ~= nil, "and its worktree shows")
	eq(countLog(s.git, "worktree list"), 1, "after one listing")
end)

case("host: a pull request listed as from a fork is found on <owner>/<branch>, whatever its folder is called, and not on the repository's own branch of that name", function(w: World)
	local s = hostScene(w, 2)
	s.gh.items.octocat[1].fork = "bob"
	local function add(path: string, branch: string)
		table.insert(s.git.worktrees, { path = path, branch = "refs/heads/" .. branch, head = sha("b"), locked = false })
		w.fs.dirs[path] = true
	end
	add("/wt/bobs", "bob/branch-1")
	add("/wt/mine", "branch-1")
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil, "the fork's pull request wears the badge of the worktree on its owner's branch")
	has(cardText(b), "/wt/bobs", "and its card names that one")
	lacks(cardText(b), "/wt/mine", "not the repository's own branch of the same name")
	eq(badgeOf(b, 2), nil, "which is no other pull request's either")
end)

case("host: a malformed request from a window gets no answer and starts nothing", function(w: World)
	hostScene(w, 2)
	local b = openQueue(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, value: any)
		b.event({ ev = "action", act = "rpc", value = value })
		w.flush()
		for _, probe in { "a1", "m1" } do
			eq(answerOf(b, probe), nil, what .. ": no answer is kept for " .. probe)
		end
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.toasts, 0, what .. ": or said")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	ignored("a value that is not text", 42)
	ignored("text that is not JSON", "{not json")
	ignored("JSON that is not an object", "[1,2]")
	ignored("a request too big", jsonEncode({ id = "a1", op = "menu", pad = string.rep("x", 130000) }))
	ignored("no id", jsonEncode({ op = "menu" }))
	ignored("an id that is not text", jsonEncode({ id = 5, op = "menu" }))
	ignored("an id of other characters than letters and digits", jsonEncode({ id = "a-1", op = "menu" }))
	ignored("an id that is too long", jsonEncode({ id = string.rep("a", 41), op = "menu" }))
	ignored("an op that does not exist", jsonEncode({ id = "a1", op = "format" }))
	ignored("an op that no longer exists", jsonEncode({ id = "a1", op = "verify", tpl = "/home/u/.omp/agent/prompts/review.md", root = "/work/r" }))
	local repos: { any } = { 5, "o", "o/r/x", "o/..", "../r", "o/r r" }
	for _, repo in repos do
		ignored("the repository " .. show(repo), jsonEncode({ id = "a1", op = "worktree", repo = repo, number = 1 }))
	end
	local numbers: { any } = { 0, -1, 1.5, 2147483648, "5" }
	for _, number in numbers do
		ignored("the number " .. show(number), jsonEncode({ id = "a1", op = "worktree", repo = "o/r", number = number }))
	end
	savePrompts(w, { promptOf("p1", "Review", "Review {url}\nthen report") })
	request(b, "m1", { op = "menu" })
	w.flush()
	same(answerOf(b, "m1").items, { { id = "p1", label = "Review", detail = "Review {url}", group = "All actions", send = "Review {url}\nthen report", worktree = true } }, "a well-formed request is answered with the saved prompts")
	eq(w.opened[#w.opened], "plotroom://rpc/m1", "and announced")
end)

windowCase("window: an agent run notes its worktree on the block as the Worktree key does, and the card replaces the failure before it", function(w: World)
	local s, b = agentScene(w)
	w.window.choose, w.window.typed = "Type a prompt…", "go"
	w.fs.denyMkdir["/wt"] = "permission denied"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(cardOf(b).p.tone, "error", "a worktree that cannot be made is a red card")
	has(cardText(b), "permission denied", "with its reason")
	eq(badgeOf(b), nil, "and no badge")
	w.fs.denyMkdir["/wt"] = nil
	local toneAtStart: any = nil
	local start = w.cx.agents.start
	w.cx.agents.start = function(self: any, opts: any): number
		toneAtStart = cardOf(b).p.tone
		return start(self, opts)
	end
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(#w.window.agents, 1, "the agent starts")
	eq(toneAtStart, "success", "after the block showed its worktree")
	eq(cardOf(b).p.tone, "success", "the card now says the worktree is ready")
	lacks(cardText(b), "permission denied", "the failure is gone")
	has(cardText(b), s.target, "and the card shows where the worktree is")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	eq(findKey(findKey(cardOf(b), "wbranch"), "v").p.spans[1].t, "feature", "and the worktree's branch")
	s.gh.meta["o/r#5"].sha = sha("c")
	s.git.served["refs/pull/5/head"] = sha("c")
	w.window.choose = { "Start another agent", "Type a prompt…" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(badgeOf(b).tone, "warning", "a reused worktree behind its pull request is flagged")
	eq(commandsOf(b, "update"), "git -C /wt/plotroom-o_r-pr-5 pull --ff-only", "with the command that brings it up to date")
	w.cx.agents.start = function(_self: any, _opts: any): number
		error("no agent program", 0)
	end
	w.window.choose = { "Start another agent", "Type a prompt…" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[#w.toasts].text, "Could not start an agent for o/r#5", "an agent that cannot start is toasted")
	has(cardText(b), s.target, "and the worktree's card is still on screen")
end)

-- ---------------------------------------------------------------- issue filters of the Plotroom block
-- The Plotroom block lists GitHub pull requests, GitHub issues and Jira issues (tracker.luau) from one sidebar. Issue
-- filters and prompts keep their own kv stores (views-issues, prompts-issues) beside the PR ones, and a worktree of an
-- issue is on a branch named after it.

-- A checkout of o/r at /work/r whose origin is github.com/o/r and whose remote serves its default branch at sha("b"),
-- with three issues for the active gh account, the newest first: #12 "Fix login" (labels bug and ui, assigned to ann and
-- bob), #13 closed as not planned and #14 closed as completed.
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
	return { git = g, gh = gh }
end

-- The Plotroom block of `pane` launched in /work/r and restored on the first issue filter (`v1` of views-issues), after
-- its repository lookup and first search, nothing selected.
function hx.openIssuesBare(w: World, pane: number?): Block
	local b = w.open(pane or 1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "issues", activeViewId = "v1" })
	w.flush()
	return b
end

-- The same with its first row selected.
local function openIssues(w: World, pane: number?): Block
	local b = hx.openIssuesBare(w, pane)
	hx.selectFirst(b)
	return b
end

-- Leaves issue `n` of o/r a worktree in the checkout of `issueHost`, as `omp worktree add` does: in the folder the default
-- issue format names, on branch <n>-fix-login. Its path. Only git lists it.
local function leaveIssueWt(w: World, s: HostScene, n: number): string
	local path = "/wt/plotroom-o_r-issue-" .. n
	table.insert(s.git.worktrees, { path = path, branch = "refs/heads/" .. n .. "-fix-login", head = sha("b"), locked = false })
	w.fs.dirs[path] = true
	return path
end

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

-- The Jira side of the issue filters: project ABC checked out at /work/r (its origin is on GitLab: a Jira project names
-- no repository) whose remote serves its default branch at sha("b"). acli is signed in to acme.atlassian.net and finds
-- under "Assigned to me" ABC-12 "Fix login" (In Progress, a High-priority Bug of Bob Ray, labelled ui) and ABC-13 "Old
-- bug" (Done), in that order, as the only issue filter. A Jira filter never searches through gh.
type JiraScene = { git: Git, acli: Acli, gh: Gh }
local JIRA_ASSIGNED = "(assignee = currentUser() AND statusCategory != Done) ORDER BY priority DESC, updated DESC"

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

local function issueLink(kind: string, repo: string, ref: string): string
	return "plotroom://issue/" .. kind .. "/" .. repo .. "/" .. ref
end

-- The link of the card's button that runs saved prompt `id` on issue `repo`#`ref`.
local function issueRunLink(repo: string, ref: string, id: string): string
	return issueLink("run", repo, ref) .. "/" .. id
end

-- The worktree request a window sends once its chooseBase picker was answered with `base` (main): a new branch from it.
local function freshAsk(repo: string, ref: string, base: string?): { [string]: any }
	return { op = "issue", repo = repo, ref = ref, worktree = true, fresh = true, base = base or "main" }
end

-- A saved issue prompt as kv keeps it: `inWorktree` false runs it in the main checkout, nil leaves the field out.
local function issuePrompt(id: string, name: string, text: string, inWorktree: boolean?, key: string?): { [string]: any }
	local p = promptOf(id, name, text, key)
	p.worktree = inWorktree
	return p
end

-- Makes `list` the saved issue prompts.
local function saveIssuePrompts(w: World, list: { { [string]: any } })
	w.kv.put("prompts-issues", { version = 1, nextId = #list + 1, items = array(list) })
end

-- The link the selected row's card keeps unseen for button `id`; nil when it keeps none.
local function buttonLink(b: Block, id: string): string?
	local node: any = findKey(findKey(pickerNode(b), "buttons"), id)
	return if node then node.p.href else nil
end

-- A picker row's detail line as plain text: its strings and the text of its spans.
local function detailText(row: any): string
	local out: { string } = {}
	for _, part in row.detail do
		table.insert(out, if type(part) == "table" then part.t else part)
	end
	return table.concat(out)
end

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

case("host: a first run seeds the filters of both kinds, and an issue filter lists issues under its own search, noun, icon, group and shortcuts", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	same(w.kv.get("views-issues"), {
		version = 1,
		nextId = 5,
		items = {
			{ id = "v1", name = "Assigned to me", integration = "github", query = "is:open assignee:@me", logins = array({}), group = "none", prompts = array({}) },
			{ id = "v2", name = "Created by me", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}) },
			{ id = "v3", name = "Assigned to me", integration = "jira", query = "assignee = currentUser() AND statusCategory != Done", logins = array({}), group = "none", prompts = array({}) },
			{ id = "v4", name = "Created by me", integration = "jira", query = "reporter = currentUser() AND statusCategory != Done", logins = array({}), group = "none", prompts = array({}) },
		},
	}, "the first run seeds the same two issue views for GitHub and Jira")
	same(w.kv.get("views-prs"), {
		version = 1,
		nextId = 3,
		items = {
			{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}) },
			{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", logins = array({}), group = "none", prompts = array({}) },
		},
	}, "and the two pull request views beside them, in a store of its own with ids of its own")
	local searches = requestsOf(s.gh, "issue-search")
	eq(#searches, 1, "one request covers three issues")
	eq(searches[1].fields.q, "is:open assignee:@me is:issue sort:updated-desc", "the active view's query across every repository, issues only")
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "newest update first")
	eq(pickerOf(b).selected, "no_2fr_2312", "the first issue is selected")
	eq(pickerOf(b).state, "ready", "the list is ready")
	eq(b.title(), "Plotroom · Assigned to me (3)", "the title names the filter and counts the issues")
	eq(pickerOf(b).noun, "issues", "the picker counts issues")
	eq(pickerOf(b).placeholder, "Filter the loaded issues", "and filters them")
	eq(pickerOf(b).icon, "list-checks", "with an icon of its own")
	local sidebar: { string } = {}
	local loaded: any = nil
	for _, scope in pickerOf(b).scopes do
		if scope.id ~= "worktrees" then
			table.insert(sidebar, scope.group .. ": " .. scope.label)
		end
		if scope.id == "issues:v1" then
			loaded = scope
		end
	end
	same(sidebar, {
		"GitHub - octocat: My PRs",
		"GitHub - octocat: Review requested",
		"GitHub - octocat: Assigned to me",
		"GitHub - octocat: Created by me",
		"Jira: Assigned to me",
		"Jira: Created by me",
	}, "the sidebar lists every filter under its integration's group, pull request filters and issue filters together")
	eq(loaded.count, 3, "the loaded one with its count")
	-- the local search reads titles, labels, assignees, authors and numbers
	local function found(text: string): { string }
		b.typeText("/")
		b.typeText(text)
		local ids = listed(b)
		b.press("escape")
		b.press("escape")
		return ids
	end
	same(found("dark"), { "no_2fr_2313" }, "the search matches titles")
	same(found("ui"), { "no_2fr_2312" }, "labels")
	same(found("ann"), { "no_2fr_2312", "no_2fr_2314" }, "assignees and authors")
	same(found("#14"), { "no_2fr_2314" }, "and numbers")
	-- the shortcut list speaks of issues
	b.typeText("?")
	local byKeys: { [string]: string } = {}
	for _, row in helpRows(b.view().layer) do
		byKeys[row.keys] = row.text
		if row.keys ~= "w" then
			lacks(row.text, "pull request", "no other shortcut speaks of pull requests: " .. row.keys)
		end
	end
	eq(byKeys.w, "Create or reuse the selected issue's worktree and open it in a new tab: on its linked pull request's branch (Plotroom asks which when several have one), else on a new branch from the base you pick (Plotroom asks for the repository, and its checkout, the first time)", "w makes the issue's worktree, on a linked pull request's branch or a new one")
	eq(byKeys.a, "Pick a saved action, or type a prompt, and run it on the selected issue (typed prompts run in its worktree)", "a runs a prompt on the issue")
	b.press("escape")
	-- the second filter searches its own query
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "issues:v2", "the second issue filter is active")
	eq(requestsOf(s.gh, "issue-search")[2].fields.q, "is:open author:@me is:issue sort:updated-desc", "and searched")
	has(b.title(), "Created by me", "the title follows")
end)

case("host: narrowing the block folds the scope rail into a dropdown that names integration and profile, drops counts, and keeps the same scopes", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	b.cx.cols = 140
	b.cx:render()
	local function snap(): ({ string }, { [string]: any })
		local ids: { string } = {}
		local labels: { [string]: any } = {}
		for _, scope in pickerOf(b).scopes do
			table.insert(ids, scope.id)
			labels[scope.id] = scope
		end
		return ids, labels
	end
	local wideIds, wide = snap()
	eq(wide["issues:v1"].count, 3, "wide: the loaded filter has a count")
	b.cx.cols = 100
	b.cx:render()
	local narrowIds, narrow = snap()
	same(narrowIds, wideIds, "narrow: the same scopes in the same order")
	for id, scope in narrow do
		eq(scope.count, nil, "narrow: no count on " .. id)
	end
	has(narrow["issues:v1"].label, "GitHub - octocat", "narrow: the label carries integration and profile")
	has(narrow["issues:v1"].label, "Assigned to me", "narrow: and the filter name")
	eq(narrow["issues:v3"].label:sub(1, 6), "Jira: ", "narrow: an integration without a profile gets no dash")
	b.cx.cols = 140
	b.cx:render()
	local backIds, back = snap()
	same(backIds, wideIds, "wide again: the same scopes")
	eq(back["issues:v1"].count, 3, "wide again: the count returns")
	eq(back["issues:v1"].label, wide["issues:v1"].label, "and the plain label")
end)

case("host: the Keys page refuses a pull request prompt's shortcut while an issue filter is shown, and one set of keys serves both kinds of filter", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	w.kv.put("prompts-prs", { version = 1, nextId = 2, items = array({ promptOf("p1", "Review", "Review {url}", "e") }) })
	local b = openIssues(w)
	goToSettings(b, "keys")
	eq(bindKey(b, "agent", "e"), "Already the shortcut of the pull request action “Review”.", "a pull request prompt's key is refused on an issue filter too")
	b.press("escape")
	eq(bindKey(b, "worktree", "W"), nil, "a free key is accepted")
	b.press("escape")
	eq(b.press("w", nil, "w"), false, "the old key is left to the pane")
	eq(b.press("w", "s", "W"), true, "the new one works")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "on the selected issue")
	pickScope(b, "prs:v1")
	w.flush()
	hx.selectFirst(b)
	eq(b.press("w", nil, "w"), false, "a pull request filter follows")
	eq(b.press("w", "s", "W"), true, "with the same key")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "on its selected pull request")
end)

case("host: pull request and issue filters share one sidebar with an icon each, and the active filter decides what is searched, listed, loaded and offered", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local b = openQueue(w)
	local entries: { string } = {}
	for _, scope in pickerOf(b).scopes do
		if scope.id ~= "worktrees" then
			table.insert(entries, scope.id .. " " .. scope.icon .. " " .. scope.label)
		end
	end
	same(entries, {
		"prs:v1 merge My PRs",
		"prs:v2 merge Review requested",
		"issues:v1 list-checks Assigned to me",
		"issues:v2 list-checks Created by me",
		"issues:v3 list-checks Assigned to me",
		"issues:v4 list-checks Created by me",
	}, "one entry per filter of both stores, an icon for its kind: both stores have a v1, the entries do not")
	eq(pickerOf(b).scope, "prs:v1", "a new block starts on the first pull request filter")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "listing its pull requests")
	eq(pickerOf(b).noun, "pull requests", "counted as pull requests")
	eq(pickerOf(b).icon, "merge", "under the pull request icon")
	eq(buttonLink(b, "worktree"), prLink("worktree", "o/r", 1), "with the pull request's buttons")
	w.advance(300)
	eq(#requestsOf(s.gh, "checks"), 1, "its checks load")
	eq(#requestsOf(s.gh, "issue"), 0, "and no issue's details")
	pickScope(b, "issues:v1")
	w.flush()
	hx.selectFirst(b)
	eq(#requestsOf(s.gh, "search"), 1, "no pull request was searched for the issue filter")
	eq(requestsOf(s.gh, "issue-search")[1].fields.q, "is:open assignee:@me is:issue sort:updated-desc", "the issue search is the filter's own")
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the list is its issues")
	eq(b.title(), "Plotroom · Assigned to me (3)", "the title names it")
	eq(pickerOf(b).noun, "issues", "counted as issues")
	eq(pickerOf(b).icon, "list-checks", "under the issue icon")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "with the issue's buttons")
	b.typeText("w")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "and the Worktree key opens the issue's link")
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 1, "the issue's details load")
	eq(#requestsOf(s.gh, "checks"), 1, "and no pull request's checks")
	pickScope(b, "prs:v1")
	w.flush()
	hx.selectFirst(b)
	eq(#requestsOf(s.gh, "search"), 2, "back on the pull request filter, a list of issues is no list of its pull requests: it searches again")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and lists them")
	eq(buttonLink(b, "worktree"), prLink("worktree", "o/r", 1), "with the pull request's buttons")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and its Worktree key")
	eq(#requestsOf(s.gh, "issue-search"), 1, "the issues were searched once")
end)

case("host: a block saves the kind of its filter and restores it: both stores have a v1, and a pane saved before issue filters joined the block is on a pull request filter", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local b = openQueue(w)
	eq(b.saved().activeKind, nil, "a pull request filter saves no kind, as before")
	pickScope(b, "issues:v1")
	w.flush()
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the store's own id is saved")
	eq(saved.activeKind, "issues", "with the kind of its store")
	local again = w.open(2, { "/work/r" }, saved)
	w.flush()
	eq(pickerOf(again).scope, "issues:v1", "a restored block is on the issue filter, not the pull request filter of the same id")
	same(listed(again), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "listing its issues")
	pickScope(again, "prs:v2")
	w.flush()
	eq(again.saved().activeKind, nil, "back on a pull request filter it saves none again")
	local back = w.open(3, { "/work/r" }, again.saved())
	w.flush()
	eq(pickerOf(back).scope, "prs:v2", "one saved on a pull request filter is restored on it")
	local before = w.open(4, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeViewId = "v2" })
	w.flush()
	eq(pickerOf(before).scope, "prs:v2", "a pane saved with no kind, as every pane was before issue filters, is on a pull request filter")
	local odd = w.open(5, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "bugs", activeViewId = "v2" })
	w.flush()
	eq(pickerOf(odd).scope, "prs:v2", "so is one saved with a kind the block does not know")
end)

case("host: a search that lands after the filter switched to the other kind is dropped, whichever kind it was for", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	-- gh answers the searches of the kinds in `late` five seconds late, with the list its model holds
	local late: { [string]: boolean } = { search = true }
	s.gh.override = function(req: GhReq): Reply?
		if not late[req.kind] then
			return nil
		end
		local list = if req.kind == "search" then s.gh.items.octocat else s.gh.issueItems.octocat
		return { delay = 5000, stdout = jsonEncode({ total = #list, next = NULL, cost = 1, items = list }) }
	end
	local b = openQueue(w)
	eq(pickerOf(b).state, "loading", "the pull request search is on its way")
	late.search = false
	pickScope(b, "issues:v1")
	w.flush()
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the issue filter shows its own list at once")
	w.advance(5000)
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the pull request answer that came late does not replace it")
	eq(pickerOf(b).noun, "issues", "the block still counts issues")
	eq(b.title(), "Plotroom · Assigned to me (3)", "under the issue filter's title")
	pickScope(b, "prs:v1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "the late answer was dropped, not kept: the pull request filter searches again")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and lists its own pull requests")
	late["issue-search"] = true
	pickScope(b, "issues:v2")
	late["issue-search"] = false
	pickScope(b, "prs:v2")
	w.flush()
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "a second pull request filter lists its pull requests while the issue search is out")
	w.advance(5000)
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the issue answer that came late does not replace them")
	eq(pickerOf(b).noun, "pull requests", "the block still counts pull requests")
	eq(pickerOf(b).scope, "prs:v2", "on the filter that was shown")
end)

case("host: a pull request's worktree and an issue's stay each their own kind's across filter switches: neither wears the other's badge or card", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 2)
	local prPath = leaveWt(w, s, 1)
	local issuePath = leaveIssueWt(w, s, 12)
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil, "the pull request with a worktree wears its badge")
	eq(badgeOf(b, 2), nil, "the other wears none")
	has(cardText(b), prPath, "its card says where the worktree is")
	pickScope(b, "issues:v1")
	w.flush()
	hx.selectFirst(b)
	yes(badgeOf(b, 1) ~= nil, "issue 12 wears its own badge")
	eq(badgeOf(b, 2), nil, "issue 13 wears none")
	eq(badgeOf(b, 3), nil, "nor does issue 14")
	has(cardText(b), issuePath, "the selected issue's card is its worktree")
	lacks(cardText(b), prPath, "not the pull request's")
	pickScope(b, "prs:v1")
	w.flush()
	hx.selectFirst(b)
	yes(badgeOf(b, 1) ~= nil, "back on the pull requests the first still wears its badge")
	eq(badgeOf(b, 2), nil, "and the second none")
	has(cardText(b), prPath, "its card is the pull request's again")
	eq(countLog(s.git, "worktree add"), 0, "nothing was made")
end)

case("host: an issue row names its number, repository, author and age, wears its labels, shows no assignee, and says why a closed issue closed", function(w: World)
	local s = issueHost(w)
	s.gh.issueItems.octocat = {
		issueItem(12, "o/r", EPOCH - 60, { title = "Fix login", labels = array({ "bug", "ui" }), assignees = array({ "ann", "bob" }), comments = 3 }),
		issueItem(13, "o/r", EPOCH - 120, { state = "CLOSED", reason = "COMPLETED", comments = 0 }),
		issueItem(14, "o/r", EPOCH - 180, { state = "CLOSED", reason = "NOT_PLANNED", assignees = array({ "cy" }) }),
		issueItem(15, "o/r", EPOCH - 240, { state = "CLOSED", reason = "DUPLICATE" }),
		issueItem(16, "o/r", EPOCH - 300, { state = "CLOSED" }),
	}
	local b = openIssues(w)
	local function row(i: number): any
		return pickerOf(b).items[i]
	end
	-- A row's badges as "text/tone", in order.
	local function badges(i: number): string
		local out: { string } = {}
		for _, badge in row(i).badges or {} do
			if badge.text ~= "New" then
				table.insert(out, badge.text .. "/" .. (badge.tone or "-"))
			end
		end
		return table.concat(out, " ")
	end
	eq(row(1).id, "no_2fr_2312", "the id is n and the issue's reference")
	eq(row(1).label, "Fix login", "the title is the label")
	eq(detailText(row(1)), "#12 · o/r · @octo opened 1m ago", "the number, the repository, the author and the age")
	eq(detailText(row(3)), "#14 · o/r · @octo opened 3m ago", "a lone assignee is not in the detail")
	eq(detailText(row(2)), "#13 · o/r · @octo opened 2m ago", "nor is the lack of one")
	eq(row(1).mark.text, "octo", "the author's mark")
	eq(row(1).facts, nil, "the rows carry no facts column: no comment count, no assignee")
	eq(pickerOf(b).columns, nil, "and the picker has no columns")
	local titlerow: any = findKey(pickerNode(b), "titlerow")
	eq(titlerow.c[1].p.key, "title", "the preview's title row starts with the title")
	eq(titlerow.c[2].p.key, "integration", "and ends with the integration badge")
	eq(titlerow.c[2].p.text, "GitHub", "naming GitHub")
	eq(titlerow.c[2].p.tone, "muted", "muted for GitHub")
	eq(badges(1), "GitHub/muted bug/- ui/-", "the integration is the first badge, then the labels")
	eq(badges(2), "GitHub/muted Completed/accent", "a completed issue")
	eq(badges(3), "GitHub/muted Not planned/muted", "one closed as not planned")
	eq(badges(4), "GitHub/muted Duplicate/muted", "a duplicate")
	eq(badges(5), "GitHub/muted Closed/error", "and a closed one with no reason")
	leaveIssueWt(w, s, 14)
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-14/src" })
	refreshNow(w, b)
	eq(badges(3), "GitHub/muted In tab/accent Worktree/- Not planned/muted", "a tab working in the issue's worktree marks its row, after the integration and before its worktree and state")
	eq(badges(1), "GitHub/muted bug/- ui/-", "and no other row")
end)

case("host: the issue preview shows its body, assignees, milestone, linked pull requests and the branch it would create", function(w: World)
	local s = issueHost(w)
	leaveIssueWt(w, s, 12)
	s.gh.issueDetail["o/r#12"] = {
		body = "Steps to reproduce:\n\n1. Open /login",
		milestone = "v2",
		linked = array({
			{ number = 45, title = "Fix the login redirect", url = "https://github.com/o/r/pull/45", state = "OPEN", isDraft = false },
			{ number = 44, title = "A first try", url = "https://github.com/o/r/pull/44", state = "OPEN", isDraft = true },
			{ number = 43, title = "An older fix", url = "https://github.com/o/r/pull/43", state = "MERGED", isDraft = false },
		}),
	}
	local b = openIssues(w)
	has(b.text(), "Loading details…", "the linked pull requests shimmer while the details load")
	eq(#requestsOf(s.gh, "issue"), 0, "nothing loads the moment an issue is selected")
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 1, "the details load once the cursor rests")
	lacks(b.text(), "Loading details…", "the shimmer is gone")
	local preview = pickerNode(b)
	local branch = findKey(preview, "branch")
	eq(findKey(branch, "v").p.spans[1].t, "octocat/12-fix-login", "the branch Worktree would make: the default format over gh's active login, the issue's key and its title's slug")
	eq(findKey(branch, "copy", "icon").p.href, "octocat/12-fix-login", "with a copy icon")
	w.kv.put("branch-format", "{key}-{slug}")
	b.render()
	eq(findKey(findKey(pickerNode(b), "branch"), "v").p.spans[1].t, "12-fix-login", "a format saved in Settings shows through")
	local head = findKey(preview, "head")
	eq(findKey(head, "copy", "icon").p.href, "https://github.com/o/r/issues/12", "the head's copy icon takes the issue's link")
	eq(findKey(head, "state", "badge").p.text, "Open", "the state")
	eq(findKey(preview, "title").p.spans[1].t, "Fix login", "the title")
	eq(findKey(preview, "buttons").p.hidden, true, "the buttons' links sit in an unseen node")
	eq(factOf(b, "Author"), "@octo", "author")
	eq(factOf(b, "Assignees"), "@ann, @bob", "assignees")
	eq(factOf(b, "Milestone"), "v2", "milestone, from the details")
	eq(factOf(b, "Comments"), "3", "comments")
	local function card(): any
		return findKey(pickerNode(b), "description", "card")
	end
	eq(card().p.role, "plotroom.description", "the description is the PR's own card")
	eq(findKey(card(), "body", "md").p.text, "Steps to reproduce:\n\n1. Open /login", "the body as Markdown")
	local linked: { string } = {}
	for i = 1, 3 do
		local item: any = findKey(preview, "pr" .. i, "item")
		table.insert(linked, item.p.label .. " | " .. item.p.value .. " | " .. item.p.icon .. " | " .. item.p.tone .. " | " .. item.p.title)
	end
	same(linked, {
		"Fix the login redirect | #45 | merge | success | #45 · Open",
		"A first try | #44 | merge | muted | #44 · Draft",
		"An older fix | #43 | merge | accent | #43 · Merged",
	}, "each linked pull request: its title, its number at the right, the icon toned by its state, which the tooltip names")
	eq(findKey(preview, "linked-head1"), nil, "pull requests have no relation heading")
	has(b.text(), "12-fix-login", "the branch is on screen")
	has(b.text(), "#45", "and so is a linked pull request")
	eq(card().p.collapsed, true, "the description starts folded")
	b.event({ ev = "toggle", id = "layer.queue.description", key = "description", collapsed = false })
	eq(card().p.collapsed, false, "the more-lines button's unfolding is kept")
	local less: any = findKey(pickerNode(b), "less", "item")
	b.event({ ev = "action", id = "layer.queue.less", act = less.p.actions.click })
	eq(card().p.collapsed, true, "Show less folds it again")
	-- the chips: labels, and In tab while a tab works in the issue's worktree
	local function chips(): { string }
		local out: { string } = {}
		for _, chip in findKey(pickerNode(b), "chips").c do
			table.insert(out, chip.p.text)
		end
		return out
	end
	same(chips(), { "bug", "ui" }, "the labels are chips")
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-12" })
	b.render()
	same(chips(), { "In tab", "bug", "ui" }, "a tab in the issue's worktree adds In tab first")
	-- an issue with no milestone, assignee or pull request, and no description
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2313" })
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 2, "the next issue loads its own details")
	eq(factOf(b, "Milestone"), nil, "no milestone row")
	eq(factOf(b, "Assignees"), nil, "no assignee row")
	eq(findKey(pickerNode(b), "pr1"), nil, "no linked pull request")
	lacks(b.text(), "Linked pull requests", "and no heading for them")
	eq(findKey(pickerNode(b), "description"), nil, "an empty body shows no card")
	eq(findKey(findKey(pickerNode(b), "head"), "state", "badge").p.text, "Not planned", "a closed issue says why in the head's badge")
end)

case("host: a block told to show a pull request selects it where its pull request filter lists it, else looks it up alone in a pinned scope, and from an issue filter always pins", function(w: World)
	local s = hostScene(w, 3)
	local url = "https://github.com/o/r/pull/45"
	s.gh.pulls[url] = searchItem(45, "o/r", EPOCH - 600, { title = "Fix the login redirect" })
	local b = openQueue(w)
	b.typeText("s")
	b.event({ ev = "action", act = "show-pr", value = "https://github.com/o/r/pull/2" })
	eq(pickerOf(b).selected, "no_2fr_232", "a PR the view lists is selected in it")
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "Settings closes to show it")
	eq(#requestsOf(s.gh, "pull"), 0, "nothing is looked up")
	eq(pickerOf(b).scopes[1].label, "My PRs", "and nothing is pinned")
	b.event({ ev = "action", act = "show-pr", value = url })
	w.flush()
	eq(requestsOf(s.gh, "pull")[1].fields.q, url, "one the view does not list is looked up by its URL")
	same(listed(b), { "no_2fr_2345" }, "and listed alone")
	eq(pickerOf(b).selected, "no_2fr_2345", "selected")
	eq(pickerOf(b).scopes[1].label, "o/r#45", "under a scope named after it, first in the sidebar")
	eq(pickerOf(b).scope, pickerOf(b).scopes[1].id, "which is the active one")
	eq(b.title(), "Plotroom · o/r#45 (1)", "the block's title names it")
	b.event({ ev = "action", act = "show-pr", value = "https://example.com/o/r/pull/1" })
	eq(#requestsOf(s.gh, "pull"), 1, "anything but a pull request URL is ignored")
	eq(pickerOf(b).scopes[1].label, "o/r#45", "and keeps the pin")
	eq(b.saved().activeViewId, "pin:o/r#45", "the pinned scope is saved by its id")
	same(b.saved().pins, { url }, "and its URL is in the saved pins")
	local restored = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(pickerOf(restored).scopes[1].label, "o/r#45", "a restored block has its pin in the sidebar")
	eq(pickerOf(restored).selected, nil, "with nothing selected")
	local launched = w.open(3, { "/work/r", url })
	w.flush()
	eq(pickerOf(launched).selected, "no_2fr_2345", "a block launched on a pull request starts on it")
	eq(pickerOf(launched).scope, "pin:o/r#45", "in its pinned scope")
	s.gh.pulls["https://github.com/o/r/pull/2"] = searchItem(2, "o/r", EPOCH - 120)
	local issues = w.open(4, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "issues", activeViewId = "v1" })
	w.flush()
	eq(pickerOf(issues).noun, "issues", "a block on an issue filter lists issues")
	local looked = #requestsOf(s.gh, "pull")
	issues.event({ ev = "action", act = "show-pr", value = "https://github.com/o/r/pull/2" })
	w.flush()
	eq(requestsOf(s.gh, "pull")[looked + 1].fields.q, "https://github.com/o/r/pull/2", "told to show a pull request, it looks it up alone: an issue filter lists no pull requests")
	same(listed(issues), { "no_2fr_232" }, "and lists that one")
	eq(pickerOf(issues).scope, "pin:o/r#2", "in the pinned scope")
	eq(pickerOf(issues).noun, "pull requests", "as pull requests")
	pickScope(issues, "issues:v1")
	w.flush()
	eq(pickerOf(issues).noun, "issues", "the issue filter is one click away")
	eq(issues.saved().activeKind, "issues", "and what the block saves again")
end)

case("host: an issue's details that fail to load show the error and a Retry that asks again", function(w: World)
	local s = issueHost(w)
	local failing = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" and failing then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	s.gh.issueDetail["o/r#12"] = { body = "Back again.", linked = array({}) }
	local b = openIssues(w)
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 1, "one load")
	has(b.text(), "Server Error", "the error is on screen")
	has(b.text(), "Retry", "with a Retry button")
	lacks(b.text(), "Loading details…", "and no shimmer")
	failing = false
	b.event({ ev = "action", id = "layer.queue", act = "retry-checks" })
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 2, "Retry asks again")
	has(b.text(), "Back again.", "the details arrived")
	lacks(b.text(), "Server Error", "and the error is gone")
end)

case("host: a prompt set to the main checkout answers with the checkout and spawns nothing", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local ran = #w.calls
	request(b, "i1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	w.flush()
	local a = answerOf(b, "i1")
	eq(a.path, "/work/r", "the answer is the saved checkout")
	eq(a.summary, "Main checkout", "which says what it is")
	eq(a.created, false, "nothing was created")
	eq(a.current, true, "nothing is out of date")
	eq(a.busy, nil, "it is never busy")
	same(a.vars, {
		url = "https://github.com/o/r/issues/12",
		owner = "o",
		repo = "r",
		key = "12",
		number = "12",
		title = "Fix login",
		author = "octo",
		labels = "bug, ui",
	}, "the issue's variables, with no branch: there is no worktree")
	eq(#w.calls, ran, "nothing was spawned")
	eq(w.opened[#w.opened], "plotroom://rpc/i1", "the window is told to read the answer")
	eq(badgeOf(b), nil, "no worktree is noted on the row")
	eq(cardOf(b), nil, "or in the preview")
end)

case("host: an issue request makes its worktree once, notes it on the block, and refuses a repeat while it runs", function(w: World)
	local s = issueHost(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	local b = openIssues(w)
	local target = "/wt/plotroom-o_r-issue-12"
	eq(badgeOf(b), nil, "no badge before there is a worktree")
	eq(cardOf(b), nil, "and no card")
	request(b, "a1", freshAsk("o/r", "12"))
	request(b, "a2", freshAsk("o/r", "12"))
	eq(answerOf(b, "a2").busy, true, "a repeat while it runs is told so")
	w.flush()
	local a = answerOf(b, "a1")
	eq(a.path, target, "the answer says where the worktree is")
	eq(a.created, true, "created")
	eq(a.current, true, "a new branch starts at the default branch: current")
	eq(a.dirty, false, "clean")
	eq(a.summary, "Created · octocat/12-fix-login at bbbbbbb · Clean", "and sums it up")
	eq(a.setup, "pnpm install", "a new worktree is set up")
	eq(a.vars.branch, "octocat/12-fix-login", "its branch joins the variables: the default format, over the gh login")
	eq(a.vars.title, "Fix login", "with the rest")
	eq(countLog(s.git, "worktree add -b octocat/12-fix-login " .. target .. " " .. sha("b")), 1, "made once")
	eq(w.opened[#w.opened], "plotroom://rpc/a1", "the window is told to read it")
	yes(badgeOf(b) ~= nil, "a worktree puts a badge on the row")
	eq(badgeOf(b).tone, "success", "a current, clean worktree is a success")
	eq(cardOf(b).p.tone, "success", "and a card in the preview")
	has(cardText(b), target, "that says where it is")
	eq(findKey(findKey(cardOf(b), "wbranch"), "v").p.spans[1].t, "octocat/12-fix-login", "the card shows its branch")
	same(chipsOf(b), { "Clean" }, "and one badge: an issue has no pull request head to be at")
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree" }, "with the buttons to open its tab or remove it")
	eq(commandsOf(b, "update"), nil, "and none to update it: the issue has no head to follow")
	request(b, "a3", freshAsk("o/r", "12"))
	w.flush()
	local again = answerOf(b, "a3")
	eq(again.created, false, "the second request reuses it")
	eq(again.setup, nil, "which is not set up again")
	eq(again.summary, "Reused · octocat/12-fix-login at bbbbbbb · Clean", "and says so")
	eq(countLog(s.git, "worktree add"), 1, "still made once")
	s.git.dirty[target] = " M src/a.lua\n"
	request(b, "a4", freshAsk("o/r", "12"))
	w.flush()
	eq(answerOf(b, "a4").summary, "Reused · octocat/12-fix-login at bbbbbbb · Modified (uncommitted changes kept)", "local changes are reported")
	eq(badgeOf(b).tone, "warning", "and deserve a look")
	s.git.dirty[target] = nil
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2313" })
	w.fs.denyMkdir["/wt"] = "mkdir denied"
	request(b, "a5", freshAsk("o/r", "13"))
	w.flush()
	has(answerOf(b, "a5").problem, "mkdir denied", "a worktree that cannot be made is answered with the reason")
	eq(badgeOf(b, 2), nil, "it shows no badge")
	eq(cardOf(b).p.tone, "error", "but an error card")
	has(cardText(b), "mkdir denied", "with the reason")
	for _, never in { "worktree remove", "branch", "update-ref", "merge", "config" } do
		eq(countLog(s.git, never), 0, "git " .. never .. " was never run")
	end
end)

case("host: an issue's worktree is removed with its branch only when git agrees, and a branch git keeps is named", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	local target = "/wt/plotroom-o_r-issue-12"
	local function ask()
		request(b, "a1", freshAsk("o/r", "12"))
		w.flush()
	end
	ask()
	s.git.unmerged["octocat/12-fix-login"] = true
	local mark = #s.git.log
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), { "worktree remove " .. target, "branch -d octocat/12-fix-login", "worktree list --porcelain -z" }, "-d only: no ancestry check, no -D, no ref; then a read of the checkout")
	eq(cardOf(b), nil, "the card goes")
	eq(badgeOf(b), nil, "and the row's badge")
	eq(w.toasts[#w.toasts].sub, "Branch octocat/12-fix-login was kept. The branch 'octocat/12-fix-login' is not fully merged.", "the branch git kept is named")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("b"), "with its commits")
	s.git.unmerged["octocat/12-fix-login"] = nil
	ask()
	eq(answerOf(b, "a1").created, true, "a new worktree attaches the branch that stayed")
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	eq(w.toasts[#w.toasts].sub, "Branch octocat/12-fix-login was deleted too.", "merged now, it goes with the next removal")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], nil, "and is gone")
	ask()
	s.git.dirty[target] = " M src/a.lua\n"
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	has(cardText(b), "Not removed. It has uncommitted changes; commit, stash or remove it yourself.", "changes git refuses to lose keep the card, with the reason")
	same(chipsOf(b), { "Uncommitted changes" }, "and the badge learns of them")
end)

case("host: an issue request is dropped unless it is well formed", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, value: any)
		b.event({ ev = "action", act = "rpc", value = value })
		w.flush()
		for _, probe in { "a1", "m1" } do
			eq(answerOf(b, probe), nil, what .. ": no answer is kept for " .. probe)
		end
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.toasts, 0, what .. ": or said")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	local repos: { any } = { 5, "o", "o/r/x", "o/..", "../r", "o/r r" }
	for _, repo in repos do
		ignored("the repository " .. show(repo), jsonEncode({ id = "a1", op = "issue", repo = repo, ref = "12", worktree = false }))
	end
	local refs: { any } = { "", "a/b", "a b", "1.5", string.rep("1", 65), true }
	for _, ref in refs do
		ignored("the reference " .. show(ref), jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = ref, worktree = false }))
	end
	local wheres: { any } = { "yes", 1 }
	for _, where in wheres do
		ignored("worktree " .. show(where), jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = "12", worktree = where }))
	end
	ignored("no worktree field", jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = "12" }))
	request(b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	w.flush()
	eq(answerOf(b, "a2").path, "/work/r", "a well-formed request is answered")
end)

case("host: an issue request reports an issue the block no longer lists, a missing checkout and a branch format that no longer holds", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	local ran = #w.calls
	-- the issue is looked up in every list the block has loaded, not only the one on screen
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "issue-search" and string.find(req.fields.q, "author:@me", 1, true) then
			return { stdout = jsonEncode({ total = 1, next = NULL, cost = 1, items = array({ issueItem(20, "o/r", EPOCH - 30, { title = "Mine" }) }) }) }
		end
		return nil
	end
	b.press("tab")
	b.press("down")
	w.flush()
	same(listed(b), { "no_2fr_2320" }, "the second filter lists another issue")
	request(b, "k1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(answerOf(b, "k1").vars.title, "Fix login", "an issue of the first filter's list is still known")
	request(b, "k2", { op = "issue", repo = "o/r", ref = "20", worktree = false })
	eq(answerOf(b, "k2").vars.title, "Mine", "and so is one of the list on screen")
	request(b, "k3", { op = "issue", repo = "o/r", ref = "99", worktree = false })
	eq(answerOf(b, "k3").problem, "That issue is not loaded here any more; Refresh and try again.", "an issue no list has is refused")
	request(b, "k4", { op = "issue", repo = "O/R", ref = "12", worktree = false })
	eq(answerOf(b, "k4").vars.title, "Fix login", "the repository's case does not matter")
	ran = #w.calls
	-- a branch format that no longer holds
	w.kv.put("branch-formats", { ["o/r"] = "{foo}" })
	request(b, "f1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	w.flush()
	eq(answerOf(b, "f1").problem, "Unknown variable {foo}.", "a worktree is refused with the format's problem")
	eq(#w.calls, ran, "and git was never asked anything")
	request(b, "f2", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(answerOf(b, "f2").path, "/work/r", "the main checkout needs no branch")
	-- no saved checkout
	forgetCheckouts(w)
	request(b, "c1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(answerOf(b, "c1").needCheckout, "o/r", "no checkout, no main checkout: the window is asked for one")
	request(b, "c2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(answerOf(b, "c2").needCheckout, "o/r", "nor a worktree")
	eq(#w.calls, ran, "and nothing ran")
end)

case("host: the branch format rejects unknown variables and saves per repository", function(w: World)
	issueHost(w)
	w.kv.put("checkouts", { ["x/y"] = "/work/y" })
	w.kv.put("branch-formats", { ["x/y"] = "keep/{key}" })
	local b = openIssues(w)
	goToSettings(b, "repos")
	local function rows(): { string }
		local out: { string } = {}
		for _, section in prefsOf(b).sections do
			for _, r in section.rows do
				table.insert(out, r.id)
			end
		end
		return out
	end
	same(rows(), { "ropen:o/r", "ropen:x/y", "radd" }, "each repository is a summary row, then the Add button: the launch one was added")
	eq(rowIn(b, "ropen:x/y").hint, "/work/y · keep/{key}", "a summary shows the checkout and the repository's own branch format")
	eq(rowIn(b, "ropen:x/y").control.label, "Edit", "and opens with Edit")
	eq(rowIn(b, "branch:o/r"), nil, "the fields stay folded")
	expand(b, "ropen:o/r")
	eq(prefsOf(b).focus, "checkout:o/r", "Edit opens the form on its checkout")
	same(rows(), { "ropen:o/r", "rremove:o/r", "checkout:o/r", "branch:o/r", "setup:o/r:new", "ropen:x/y", "radd" }, "one form is open, its Remove right after its Done")
	eq(rowIn(b, "ropen:o/r").control.label, "Done", "Edit turned Done")
	local row = rowIn(b, "branch:o/r")
	eq(row.label, "Issue branch name", "label")
	eq(row.hint, nil, "no description")
	eq(row.control.k, "text", "a text field")
	eq(row.control.placeholder, "{github.user}/{key}-{slug}", "the Worktrees format is its placeholder")
	eq(row.control.value, "", "nothing is saved for o/r")
	eq(row.changed, false, "so the row is not marked changed")
	has(row.defaultLabel, "Worktrees", "and a reset says where the default comes from")
	has(b.text(), "octocat/12-fix-login", "the preview shows the branch the Worktrees format makes")
	local function save(text: string)
		b.event({ ev = "select", id = "layer.settings", item = "branch:o/r" })
		b.press("enter")
		for _ = 1, 40 do
			b.press("backspace")
		end
		b.typeText(text)
		b.press("enter")
	end
	save("{foo}")
	eq(rowIn(b, "branch:o/r").warning, "Unknown variable {foo}.", "an unknown variable is refused by name")
	eq(prefsOf(b).editing.row, "branch:o/r", "the draft stays for a correction")
	b.press("escape")
	save("x-{slug}")
	eq(rowIn(b, "branch:o/r").warning, "Include {key}, so each issue gets its own branch.", "a format without {key} would give every issue one branch")
	b.press("escape")
	same(w.kv.get("branch-formats"), { ["x/y"] = "keep/{key}" }, "nothing was saved")
	save("feat/{key}")
	eq(prefsOf(b).editing, nil, "a good format closes the edit")
	eq(w.kv.get("branch-formats")["o/r"], "feat/{key}", "and is saved under the repository")
	eq(w.kv.get("branch-formats")["x/y"], "keep/{key}", "another repository's format is kept")
	eq(rowIn(b, "branch:o/r").control.value, "feat/{key}", "the row shows it")
	eq(rowIn(b, "branch:o/r").changed, true, "as changed")
	has(b.text(), "feat/12", "and the preview's branch follows")
	save("")
	eq(w.kv.get("branch-formats")["o/r"], nil, "an empty format goes back to the default")
	eq(w.kv.get("branch-formats")["x/y"], "keep/{key}", "without touching the other repository")
	save("{owner}/{key}")
	eq(w.kv.get("branch-formats")["o/r"], "{owner}/{key}", "saved again")
	b.event({ ev = "change", id = "layer.settings", item = "branch:o/r" })
	eq(w.kv.get("branch-formats")["o/r"], nil, "Reset clears it")
	eq(rowIn(b, "branch:o/r").control.value, "", "the row is empty again")
	eq(rowIn(b, "branch:o/r").changed, false, "and unchanged")
	-- a saved format that no longer holds, by hand, shows no branch; an unreadable map is never overwritten
	w.kv.put("branch-formats", { ["o/r"] = "{foo}" })
	b.render()
	eq(findKey(pickerNode(b), "branch"), nil, "the preview shows no branch the format cannot name")
	w.kv.put("branch-formats", "garbage")
	b.render()
	save("feat/{key}")
	eq(w.kv.get("branch-formats"), "garbage", "an unreadable map is never overwritten")
	eq(findKey(findKey(pickerNode(b), "branch"), "v").p.spans[1].t, "octocat/12-fix-login", "and the Worktrees format applies meanwhile")
end)

case("host: issue prompts are separate from PR prompts, each kind's on the Prompts page and offered under its own filters, and they carry where they run", function(w: World)
	issueHost(w)
	savePrompts(w, { promptOf("p1", "PR only", "Review {url}") })
	saveIssuePrompts(w, {
		issuePrompt("p1", "Triage", "Triage {url}", true, "t"),
		issuePrompt("p2", "Notes", "Summarise {title}", false),
		issuePrompt("p3", "Old", "Old {url}"),
	})
	local b = openIssues(w)
	local asked = 0
	-- The rows the block answers a menu request with.
	local function menu(): { any }
		asked += 1
		request(b, "m" .. asked, { op = "menu" })
		w.flush()
		return answerOf(b, "m" .. asked).items
	end
	same(menu(), {
		{ id = "p1", label = "Triage", detail = "Triage {url}", group = "All actions", send = "Triage {url}", worktree = true, key = "t" } :: any,
		{ id = "p2", label = "Notes", detail = "Summarise {title}", group = "All actions", send = "Summarise {title}", worktree = false },
		{ id = "p3", label = "Old", detail = "Old {url}", group = "All actions", send = "Old {url}", worktree = true },
	}, "an issue filter offers the issue prompts, each saying where it runs and its key; one saved without the field runs in a worktree")
	pickScope(b, "prs:v1")
	w.flush()
	same(menu(), {
		{ id = "p1", label = "PR only", detail = "Review {url}", group = "All actions", send = "Review {url}", worktree = true },
	}, "a pull request filter offers the pull request prompts, saying where each runs too: both stores have a p1")
	pickScope(b, "issues:v1")
	w.flush()
	goToSettings(b, "prompts")
	local order: { string } = {}
	for _, section in prefsOf(b).sections do
		table.insert(order, section.id)
	end
	same(order, { "prompts:prs", "add:prs", "prompts:issues", "add:issues" }, "the page lists both kinds' prompts in a section each, the pull request prompts first, each followed by its Add button")
	local listed: { string } = {}
	for _, section in prefsOf(b).sections do
		for _, r in section.rows do
			table.insert(listed, r.id)
		end
	end
	same(listed, { "popen:prs:p1", "padd:prs", "prestore:prs", "popen:issues:p1", "popen:issues:p2", "popen:issues:p3", "padd:issues", "prestore:issues" }, "each kind's prompts are summary rows with the kind's Add row, then Restore defaults (none of these is named like a default), last")
	expand(b, "popen:issues:p1")
	local ids: { string } = {}
	for _, section in prefsOf(b).sections do
		if section.id == "form:issues:p1" then
			for _, r in section.rows do
				table.insert(ids, r.id)
			end
		end
	end
	same(ids, { "popen:issues:p1", "pdelete:issues:p1", "pname:issues:p1", "ptext:issues:p1", "pmodel:issues:p1", "pwhere:issues:p1", "psplit:issues:p1" }, "an open prompt first in its kind takes over the kind's card: Done and Delete, then Runs in and Opens in after the model")
	eq(sectionIn(b, "popen:issues:p1").title, "Issue actions", "keeping the kind's title")
	local where = rowIn(b, "pwhere:issues:p1")
	eq(where.label, "Runs in", "label")
	eq(where.control.k, "choice", "a choice")
	eq(where.control.style, "segmented", "of segments")
	eq(where.control.value, "worktree", "on the worktree for a prompt that runs in one")
	same(where.control.options, { { value = "worktree", label = "Worktree" }, { value = "checkout", label = "Main checkout" } }, "the two places")
	expand(b, "popen:issues:p2")
	eq(rowIn(b, "pwhere:issues:p2").control.value, "checkout", "the main checkout for one that runs there")
	expand(b, "popen:issues:p3")
	eq(rowIn(b, "pwhere:issues:p3").control.value, "worktree", "and the worktree for one saved without the field")
	expand(b, "popen:issues:p1")
	local function choose(id: string, value: string)
		b.event({ ev = "change", id = "layer.settings", item = "pwhere:issues:" .. id, value = value })
	end
	choose("p1", "checkout")
	eq(w.kv.get("prompts-issues").items[1].worktree, false, "choosing the main checkout saves worktree = false")
	eq(rowIn(b, "pwhere:issues:p1").control.value, "checkout", "the row shows it")
	eq(menu()[1].worktree, false, "and the menu says so")
	b.event({ ev = "select", id = "layer.settings", item = "pwhere:issues:p1" })
	b.press("enter")
	eq(w.kv.get("prompts-issues").items[1].worktree, true, "Enter on the segments switches to the next one at once and saves it")
	eq(prefsOf(b).editing, nil, "without opening a menu")
	b.press("enter")
	eq(w.kv.get("prompts-issues").items[1].worktree, false, "and on again wraps round to the first")
	eq(menu()[1].worktree, false, "and the menu says so")
	choose("p2", "worktree")
	eq(w.kv.get("prompts-issues").items[2].worktree, true, "the worktree again")
	eq(w.kv.get("prompts-issues").items[1].name, "Triage", "the rest of the prompt is kept")
	eq(w.kv.get("prompts-prs").items[1].worktree, nil, "the PR prompts are untouched")
	b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:issues" })
	local saved = w.kv.get("prompts-issues")
	eq(#saved.items, 4, "Add prompt on the issue side saves a new one with the issue prompts")
	eq(saved.items[4].worktree, true, "that runs in a worktree")
	eq(#w.kv.get("prompts-prs").items, 1, "and none with the PR prompts")
	b.press("escape")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "psplit:prs:p1").control.value, "tab", "a PR prompt on the same page opens in a tab of its own until told otherwise")
	b.event({ ev = "change", id = "layer.settings", item = "psplit:prs:p1", value = "split" })
	eq(w.kv.get("prompts-prs").items[1].split, true, "the Beside the queue segment saves split")
	eq(rowIn(b, "psplit:prs:p1").control.value, "split", "the row shows it")
	b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:prs" })
	eq(#w.kv.get("prompts-prs").items, 2, "Add prompt on the pull request side saves one with the PR prompts")
	eq(#w.kv.get("prompts-issues").items, 4, "and none with the issue prompts")
	b.press("escape")
	b.press("escape")
	b.typeText("?")
	local keyed = false
	for _, row in helpRows(b.view().layer) do
		keyed = keyed or row.text == "Run the action “Triage” on the selected issue"
	end
	yes(keyed, "a prompt's shortcut is listed for the selected issue")
	b.press("escape")
	pickScope(b, "prs:v1")
	w.flush()
	eq(menu()[1].split, true, "the pull request filter's menu says the prompt opens beside the queue")
end)

case("host: the issue's buttons, keys and links: Worktree, Go to tab and Agent, each opening the link the card keeps unseen beside each prompt's", function(w: World)
	leaveIssueWt(w, issueHost(w), 12)
	saveIssuePrompts(w, {
		issuePrompt("p1", "Triage", "Triage {url}", true, "t"),
		issuePrompt("p2", "Notes", "Notes on {title}", false),
		issuePrompt("p3", "Blank", "", true, "b"),
	})
	local b = openIssues(w)
	local function bar(): { string }
		local out: { string } = {}
		for _, a in pickerOf(b).actions do
			table.insert(out, a.id)
		end
		return out
	end
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "Worktree, Agent, no button per prompt, Seen, and the command palette last")
	eq(buttonLink(b, "open"), "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12", "Open's link carries the issue's page, percent-encoded")
	local globe: any = findKey(findKey(pickerNode(b), "head"), "open", "icon")
	eq(globe.p.href, buttonLink(b, "open"), "the preview head's Open icon opens it")
	eq(globe.p.title, "Open in GitHub", "named for the issue's tracker")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "Worktree's")
	eq(buttonLink(b, "agent"), issueLink("agent", "o/r", "12"), "the Agent link for the a key and the palette command")
	eq(buttonLink(b, "prompt-p1"), issueRunLink("o/r", "12", "p1"), "each prompt's unseen link runs it on the selected issue")
	eq(buttonLink(b, "prompt-p3"), nil, "none for a prompt with no text")
	eq(buttonLink(b, "goto"), nil, "no tab works in its worktree: no Go to tab")
	eq(b.press("g", nil, "g"), false, "and g does nothing")
	b.event({ ev = "action", id = "layer.queue", act = "worktree" })
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "a click opens the button's link")
	b.event({ ev = "action", id = "layer.queue", act = "agent" })
	eq(w.opened[#w.opened], issueLink("agent", "o/r", "12"), "Agent's too")
	b.typeText("w")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "w opens the Worktree link")
	b.typeText("a")
	eq(w.opened[#w.opened], issueLink("agent", "o/r", "12"), "a the Agent link")
	b.typeText("t")
	eq(w.opened[#w.opened], issueRunLink("o/r", "12", "p1"), "a prompt's key its run link")
	b.press("enter")
	eq(w.opened[#w.opened], "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12", "Enter the Open link")
	b.typeText("j")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "13"), "the links follow the selection")
	b.typeText("k")
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-12/src" })
	b.render()
	same(bar(), { "settings", "retry", "worktree", "goto", "agent", "seen", "more" }, "a tab in the issue's worktree adds Go to tab before Agent")
	eq(buttonLink(b, "goto"), issueLink("goto", "o/r", "12"), "with its link")
	b.typeText("g")
	eq(w.opened[#w.opened], issueLink("goto", "o/r", "12"), "g opens it")
	table.remove(w.panes)
	forgetCheckouts(w)
	b.render()
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "without a saved checkout the buttons stay: the window asks for one when it runs")
	lacks(b.text(), "No local checkout", "and the heading says nothing of it")
	local opened = #w.opened
	b.typeText("w")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "w opens the Worktree link")
	eq(#w.opened, opened + 1, "and only that one")
end)

case("host: an account's Add makes a view of the kind on screen, saved with that kind's views; Jira's Add always makes an issue view", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat" -- a view with its own login runs as it, by token
	local b = openIssues(w)
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(#w.kv.get("views-issues").items, 5, "Add saved an issue view with the issue views")
	eq(#w.kv.get("views-prs").items, 2, "and none with the pull request views")
	eq(prefsOf(b).editing.row, "name:issues:v5", "and starts naming it")
	b.press("escape")
	b.press("escape")
	w.flush()
	eq(pickerOf(b).scope, "issues:v5", "the new view is the one shown")
	pickScope(b, "prs:v1")
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "on a pull request view the same Add saved a pull request view with the pull request views")
	eq(#w.kv.get("views-issues").items, 5, "and the issue views are as they were")
	eq(prefsOf(b).editing.row, "name:prs:v3", "naming it")
	b.press("escape")
	b.press("escape")
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:jira:" })
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "Jira has no pull requests")
	eq(w.kv.get("views-issues").items[6].integration, "jira", "so its Add made an issue view")
	b.press("escape")
	b.press("escape")
	goToSettings(b, "views")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:nowhere:" })
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:github:bad name" })
	same({ #w.kv.get("views-prs").items, #w.kv.get("views-issues").items }, { 3, 6 }, "a malformed Add value (an unknown integration, a login that is none) saves nothing")
end)

case("host: an Enterprise Managed User account (a login with an underscore) can have a view added, saved and shown", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "mona-cat_octo"
	s.gh.tokens["mona-cat_octo"] = "tok-emu"
	local b = openIssues(w)
	goToSettings(b, "views")
	yes(rowIn(b, "vadd:github:mona-cat_octo") ~= nil, "the account has its group and Add")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:github:mona-cat_octo" })
	local made = w.kv.get("views-issues").items[#w.kv.get("views-issues").items]
	same(made.logins, { "mona-cat_octo" }, "the view is saved as that account")
	b.press("escape")
	b.press("escape")
	w.flush()
	eq(pickerOf(b).scope, "issues:v" .. (#w.kv.get("views-issues").items), "and is the one shown")
end)

case("host: deleting a view takes only its own kind's view of that id, and the block moves on to the view now at its place in the list", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	b.event({ ev = "select", id = "layer.settings", item = "delete:issues:v1" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "delete:issues:v1" })
	w.flush()
	local gone: { string } = {}
	for _, v in w.kv.get("views-issues").items do
		table.insert(gone, v.id)
	end
	same(gone, { "v2", "v3", "v4" }, "the issue view is gone")
	eq(#w.kv.get("views-prs").items, 2, "the pull request view of the same id is not")
	eq(pickerOf(b).scope, "issues:v2", "the view now at its place in the list is shown")
	eq(b.saved().activeViewId, "v2", "and saved")
	eq(prefsOf(b).focus, "vopen:issues:v2", "and Settings focuses its summary row")
end)

case("host: a view's Type row moves it to the other kind's store under a new id with no prompts, and the shown view follows it", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open label:x", logins = array({ "work" }), group = "repo", prompts = array({ "p1" }) },
		{ id = "v2", name = "Other", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	eq(rowIn(b, "vint:prs:v1"), nil, "a view has no integration to pick")
	eq(rowIn(b, "vkind:prs:v1").control.value, "prs", "its Type row shows its kind")
	eq(rowIn(b, "vkind:prs:v1").label, "Type", "labelled Type")
	same(rowIn(b, "vkind:prs:v1").control.options, { { value = "prs", label = "Pull requests" }, { value = "issues", label = "Issues" } }, "and offers both kinds by name")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:prs:v1", value = "issues" })
	local prs = w.kv.get("views-prs")
	eq(#prs.items, 1, "the pull request store lost it")
	eq(prs.nextId, 3, "and keeps its next id")
	eq(prs.items[1].id, "v2", "and the other view stays")
	local issues = w.kv.get("views-issues")
	same({ #issues.items, issues.nextId }, { 5, 6 }, "the issue store took it as its next view")
	same(issues.items[5], { id = "v5", name = "Mine", integration = "github", query = "is:open label:x", logins = { "work" }, group = "repo", prompts = array({}) }, "keeping its query, login and the grouping both kinds have, with none of the pull request prompts")
	eq(pickerOf(b).scope, "issues:v5", "the view that was shown is still the one shown, under its new id")
	eq(prefsOf(b).focus, "vkind:issues:v5", "its Type row keeps the focus")
	yes(rowIn(b, "name:issues:v5") ~= nil, "and its form stays open")
	eq(b.saved().activeKind, "issues", "the block saves the new kind")
	eq(b.saved().activeViewId, "v5", "and the new id")
	b.event({ ev = "change", id = "layer.settings", item = "vgroup:issues:v5", value = "assignee" })
	b.event({ ev = "change", id = "layer.settings", item = "vkind:issues:v5", value = "prs" })
	same(w.kv.get("views-prs").items[2], { id = "v3", name = "Mine", integration = "github", query = "is:open label:x", logins = { "work" }, group = "none", prompts = array({}) }, "moved back, a grouping only issues have starts over")
	eq(#w.kv.get("views-issues").items, 4, "the issue store lost it")
	eq(pickerOf(b).scope, "prs:v3", "and the block shows it as a pull request view")
	-- a Jira view has no pull request kind to move to
	expand(b, "vopen:issues:v3")
	eq(rowIn(b, "vkind:issues:v3"), nil, "a Jira view's form has no Type row")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:issues:v3", value = "prs" })
	eq(#w.kv.get("views-issues").items, 4, "an event for it moves nothing")
	eq(#w.kv.get("views-prs").items, 2, "and adds nothing to the pull request views")
end)

case("host: a views store that cannot be read locks its own kind's views, says which kind it is, and leaves the other kind editable", function(w: World)
	issueHost(w)
	newAcli(w)
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", query = "is:open", group = "none", prompts = array({}) } }) })
	local before = w.kv.store["views-prs"]
	w.kv.failGet["views-prs"] = "disk offline"
	local b = openIssues(w)
	has(b.text(), "Saved pull request views could not be read: disk offline", "the block says which kind of views could not be read")
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	eq(rowIn(b, "name:issues:v1").disabled, nil, "the issue views stay editable")
	eq(rowIn(b, "vadd:github:octocat").disabled, nil, "and Add makes an issue view")
	b.press("enter")
	b.typeText("!")
	b.press("enter")
	eq(w.kv.get("views-issues").items[1].name, "Assigned to me!", "a rename of an issue view is saved")
	expand(b, "vopen:prs:v1")
	has(rowIn(b, "name:prs:v1").disabled, "disk offline", "the pull request views' rows are locked, with the cause")
	eq(w.kv.store["views-prs"], before, "and the unreadable store was not overwritten")
	b.press("escape")
	pickScope(b, "prs:v1")
	w.flush()
	goToSettings(b, "views")
	has(rowIn(b, "vadd:github:octocat").disabled, "disk offline", "on a pull request filter Add is locked, as its kind's views are")
end)

case("host: a click on another row first ends the line being typed, so a new view's Group by menu opens at once", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat"
	local b = openQueue(w)
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "name:prs:v3", "a new view starts with its name being typed")
	b.event({ ev = "activate", id = "layer.settings", item = "vgroup:prs:v3" })
	eq(prefsOf(b).editing.row, "vgroup:prs:v3", "a click on Group by opens its menu over the untouched name")
	eq(w.kv.get("views-prs").items[3].name, "New view", "which is dropped, not saved empty")
	b.press("escape")
	b.event({ ev = "activate", id = "layer.settings", item = "name:prs:v3" })
	b.typeText("2")
	b.event({ ev = "activate", id = "layer.settings", item = "name:prs:v3" })
	eq(prefsOf(b).editing.draft, "New view2", "a click inside the field being typed keeps the draft")
	b.event({ ev = "activate", id = "layer.settings", item = "vgroup:prs:v3" })
	eq(w.kv.get("views-prs").items[3].name, "New view2", "a click on another row saves the typed name")
	eq(prefsOf(b).editing.row, "vgroup:prs:v3", "and does what it does")
	b.press("escape")
	b.event({ ev = "activate", id = "layer.settings", item = "name:prs:v3" })
	b.typeText("3")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "vopen:prs:v3" })
	eq(w.kv.get("views-prs").items[3].name, "New view23", "Done saves it too")
	eq(rowIn(b, "name:prs:v3"), nil, "and closes the form")
end)

case("host: a collapsed view is one summary row; Edit expands its form, another's Edit collapses the first, and Done collapses", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	local b = openQueue(w)
	goToSettings(b, "views")
	local function sectionOf(id: string): any
		return sectionIn(b, id)
	end
	local summary = rowIn(b, "vopen:prs:v1")
	eq(summary.label, "My PRs · active", "the summary names the view and marks the active one")
	has(summary.hint, "is:open author:@me", "its hint shows the query")
	lacks(summary.hint, "GitHub", "and no longer names the integration")
	eq(summary.control.act, "expand", "its button expands the form")
	eq(summary.control.label, "Edit", "labelled Edit")
	eq(sectionOf("vopen:prs:v1").id, "group:github - octocat", "the first view of a group opens the group's section, named by the lowercased label")
	eq(sectionOf("vopen:prs:v1").title, "GitHub - octocat", "titled with the group")
	eq(rowIn(b, "name:prs:v1"), nil, "a collapsed view shows no form row")
	eq(rowIn(b, "query:prs:v1"), nil, "not the query")
	eq(rowIn(b, "delete:prs:v1"), nil, "nor Delete")
	expand(b, "vopen:prs:v1")
	local open = rowIn(b, "vopen:prs:v1")
	eq(open.control.act, "collapse", "an expanded view keeps its row, now collapsing")
	eq(open.control.label, "Done", "labelled Done")
	eq(open.hint, nil, "with no hint")
	local form: { string } = {}
	for _, r in sectionOf("vopen:prs:v1").rows do
		table.insert(form, r.id)
	end
	same(form, { "vopen:prs:v1", "delete:prs:v1", "name:prs:v1", "vkind:prs:v1", "query:prs:v1", "vgroup:prs:v1", "vsort:prs:v1", "vprompts:prs:v1" }, "Done on top, then Delete, which the sheet draws beside Done")
	eq(sectionOf("vopen:prs:v1").id, "form:prs:v1", "the group's first view, open, takes over the group's card")
	eq(sectionOf("vopen:prs:v1").title, "GitHub - octocat", "title and all")
	eq(sectionOf("vopen:prs:v2").id, "after:prs:v1", "the group's later views go on in a section after the form")
	eq(prefsOf(b).focus, "name:prs:v1", "with the name focused")
	expand(b, "vopen:prs:v2")
	eq(rowIn(b, "vopen:prs:v1").control.act, "expand", "expanding another view collapses the first")
	eq(rowIn(b, "name:prs:v1"), nil, "its form is gone")
	yes(rowIn(b, "name:prs:v2") ~= nil, "and the other's form shows")
	eq(sectionOf("vopen:prs:v2").id, "form:prs:v2", "in a section of its own when it is not the group's first")
	eq(sectionOf("vopen:prs:v2").rows[1].id, "vopen:prs:v2", "Done first")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "vopen:prs:v2" })
	yes(rowIn(b, "vopen:prs:v2").control.act == "expand" and rowIn(b, "name:prs:v2") == nil, "Done collapses it")
	eq(prefsOf(b).focus, "vopen:prs:v2", "and focuses its summary")
	w.kv.put("prompts-prs", { version = 1, nextId = 3, items = array({ promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") }) })
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", logins = array({ "work" }), query = "is:open", group = "repo", prompts = array({ "p2" }) } }) })
	local other = openQueue(w, 2)
	goToSettings(other, "views")
	local hint = rowIn(other, "vopen:prs:v1").hint
	lacks(hint, "work", "a login is not in the summary")
	for _, section in prefsOf(other).sections do
		if section.id == "group:github - work" then
			has(section.title, "work", "it is in the group's title")
		end
	end
	eq(hint, "Pull requests · is:open", "the summary is the kind and the query: no grouping, no prompt count")
end)

case("host: a collapsed prompt is one summary row; Edit expands it, another's Edit or Done collapses, and Add opens the new prompt expanded", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}", "r"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	local function sectionOf(id: string): any
		return sectionIn(b, id)
	end
	local summary = rowIn(b, "popen:prs:p1")
	eq(summary.label, "Review", "the summary names the prompt")
	eq(summary.hint, "Review {url}", "its hint shows the text, not the key: shortcuts are the Keys page's")
	eq(summary.control.act, "expand", "its button expands the form")
	eq(summary.control.label, "Edit", "labelled Edit")
	eq(sectionOf("popen:prs:p1").id, "prompts:prs", "the prompts of a kind share its section")
	eq(rowIn(b, "pname:prs:p1"), nil, "a collapsed prompt shows no form row")
	eq(rowIn(b, "pdelete:prs:p1"), nil, "nor Delete")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "popen:prs:p1").control.act, "collapse", "an expanded prompt keeps its row, now collapsing")
	eq(rowIn(b, "popen:prs:p1").control.label, "Done", "labelled Done")
	eq(sectionOf("popen:prs:p1").rows[1].id, "popen:prs:p1", "first in its form")
	yes(rowIn(b, "pname:prs:p1") ~= nil and rowIn(b, "ptext:prs:p1") ~= nil and rowIn(b, "pmodel:prs:p1") ~= nil, "its form shows")
	eq(rowIn(b, "pkey:prs:p1"), nil, "with no shortcut row")
	expand(b, "popen:prs:p2")
	yes(rowIn(b, "popen:prs:p1").control.act == "expand" and rowIn(b, "pname:prs:p1") == nil, "expanding another prompt collapses the first")
	yes(rowIn(b, "pname:prs:p2") ~= nil, "and shows the other's form")
	eq(sectionOf("popen:prs:p2").id, "form:prs:p2", "in a section of its own when it is not the kind's first")
	eq(sectionOf("padd:prs").id, "add:prs", "and the Add button follows the list in its own")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "popen:prs:p2" })
	yes(rowIn(b, "popen:prs:p2").control.act == "expand" and rowIn(b, "pname:prs:p2") == nil, "Done collapses it")
	eq(prefsOf(b).focus, "popen:prs:p2", "and focuses its summary")
	expand(b, "popen:prs:p1")
	b.event({ ev = "select", id = "layer.settings", item = "padd:prs" })
	b.press("enter")
	eq(#w.kv.get("prompts-prs").items, 3, "Add saved a prompt")
	yes(rowIn(b, "pname:prs:p3") ~= nil, "the new prompt opens expanded")
	yes(rowIn(b, "popen:prs:p1").control.act == "expand" and rowIn(b, "pname:prs:p1") == nil, "and the one that was open collapses")
	eq(prefsOf(b).editing.row, "pname:prs:p3", "with its name being edited")
end)

case("host: pull request and issue filters sit together in the group of the login they run as, and one without a login follows gh's active login", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "user-a"
	s.gh.tokens["user-a"] = "tok-a"
	s.gh.tokens["user-b"] = "tok-b"
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "PR of A", integration = "github", query = "is:open", logins = array({ "user-a" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "PR plain", integration = "github", query = "is:open", group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 5, items = array({
		{ id = "v1", name = "A's", integration = "github", query = "is:open", logins = array({ "user-a" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "B's", integration = "github", query = "is:open", logins = array({ "user-b" }), group = "none", prompts = array({}) },
		{ id = "v3", name = "Plain", integration = "github", query = "is:open", group = "none", prompts = array({}) },
		{ id = "v4", name = "Jira view", integration = "jira", query = "assignee = currentUser()", group = "none", prompts = array({}) },
	}) })
	local b = openIssues(w)
	-- The sidebar as "name @ group", in the order shown.
	local function sidebar(): { string }
		local out: { string } = {}
		for _, scope in pickerOf(b).scopes do
			if scope.id ~= "worktrees" then
				table.insert(out, scope.label .. " @ " .. scope.group)
			end
		end
		return out
	end
	same(sidebar(), {
		"PR of A @ GitHub - user-a",
		"PR plain @ GitHub - user-a",
		"A's @ GitHub - user-a",
		"Plain @ GitHub - user-a",
		"B's @ GitHub - user-b",
		"Jira view @ Jira",
	}, "a group is an integration's and a login's, whatever the kind: pull request filters first, then issue filters; one with no login sits with the active login's own; user-b has its own group, and Jira follows")
	s.gh.active = "user-b"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	b.typeText("r")
	w.flush()
	same(sidebar(), {
		"PR of A @ GitHub - user-a",
		"A's @ GitHub - user-a",
		"PR plain @ GitHub - user-b",
		"B's @ GitHub - user-b",
		"Plain @ GitHub - user-b",
		"Jira view @ Jira",
	}, "after the active account switched, the filters with no login moved to user-b's group, after user-b's own")
end)

-- A PR view that runs as the logins `who`, saved as the only filter of the block: the issue store is left empty.
local function loginsView(w: World, who: { string })
	w.kv.put("views-issues", { version = 1, nextId = 1, items = array({}) })
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open author:@me", logins = array(who), group = "none", prompts = array({}) },
	}) })
end

-- The sidebar as "name @ group = id", in the order shown.
local function sidebarOf(b: Block): { string }
	local out: { string } = {}
	for _, scope in pickerOf(b).scopes do
		if scope.id ~= "worktrees" then
			table.insert(out, scope.label .. " @ " .. (scope.group or "-") .. " = " .. scope.id)
		end
	end
	return out
end

case("host: a view of two logins is one scope in each login's group; each runs only as its login, and nothing is merged", function(w: World)
	local s = hostScene(w, 0)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60, { checks = "SUCCESS" }), searchItem(2, "o/r", EPOCH - 120) }
	s.gh.items.work = { searchItem(3, "o/r", EPOCH - 30, { checks = "SUCCESS" }) }
	s.gh.checks["o/r#1"] = nodes(1)
	s.gh.checks["o/r#3"] = nodes(1)
	s.git.served["refs/pull/3/head"] = sha("b")
	s.gh.meta["o/r#3"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	same(sidebarOf(b), { "Both @ GitHub - octocat = prs:v1@octocat", "Both @ GitHub - work = prs:v1@work" }, "the view is listed once in each login's group")
	eq(pickerOf(b).scope, "prs:v1@octocat", "the first login's scope is the one shown")
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 1, "one search")
	eq(searches[1].login, "octocat", "as that login")
	has(searches[1].fields.q, "is:open author:@me", "with the view's query")
	same(listed(b), { "no_2fr_231", "no_2fr_232" }, "its PRs only")
	w.advance(300)
	eq(requestsOf(s.gh, "checks")[1].login, "octocat", "its checks load as it")
	pickScope(b, "prs:v1@work")
	w.flush()
	hx.selectFirst(b)
	searches = requestsOf(s.gh, "search")
	eq(#searches, 2, "the other scope searches on its own")
	eq(searches[2].login, "work", "as its login")
	same(listed(b), { "no_2fr_233" }, "and lists only what that login found, never a merge")
	eq(pickerOf(b).scope, "prs:v1@work", "the scope is the one clicked")
	w.advance(300)
	eq(requestsOf(s.gh, "checks")[2].login, "work", "its checks load as it")
	request(b, "a1", { op = "worktree", repo = "o/r", number = 3 })
	w.flush()
	eq(requestsOf(s.gh, "pr")[1].login, "work", "and its worktree reads the PR as it")
	-- the keys walk the scopes in the order shown
	b.press("tab")
	b.press("up")
	eq(pickerOf(b).scope, "prs:v1@octocat", "Up moves to the scope above")
	w.flush()
	eq(requestsOf(s.gh, "search")[3].login, "octocat", "and runs as its login again")
	same(listed(b), { "no_2fr_231", "no_2fr_232" }, "with its own list")
	b.press("down")
	eq(pickerOf(b).scope, "prs:v1@work", "Down moves to the scope below")
end)

case("host: a login failing in one scope leaves the view's other scope alone", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and req.login == "work" then
			return { status = 1, stderr = "gh: Resource not accessible by integration (HTTP 403)\n" }
		end
		return nil
	end
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the working login's scope lists its PRs")
	pickScope(b, "prs:v1@work")
	w.flush()
	eq(pickerOf(b).state, "error", "the failing login's scope shows the problem")
	eq(#listed(b), 0, "and no list")
	pickScope(b, "prs:v1@octocat")
	w.flush()
	eq(pickerOf(b).state, "ready", "the other scope is not an error card")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and lists its PRs again")
	local who: { string } = {}
	for _, req in requestsOf(s.gh, "search") do
		table.insert(who, req.login or "")
	end
	same(who, { "octocat", "work", "octocat" }, "each scope searched as its own login, and the failure stopped nothing else")
end)

case("host: a view sits in the group of each login it lists, and one with none follows gh's active login", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "user-a"
	s.gh.tokens["user-a"] = "tok-a"
	s.gh.tokens["user-b"] = "tok-b"
	w.kv.put("views-issues", { version = 1, nextId = 4, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open", logins = array({ "user-a", "user-b" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "Just b", integration = "github", query = "is:open", logins = array({ "user-b" }), group = "none", prompts = array({}) },
		{ id = "v3", name = "Active", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-prs", { version = 1, nextId = 1, items = array({}) })
	local b = openIssues(w)
	same(sidebarOf(b), {
		"Both @ GitHub - user-a = issues:v1@user-a",
		"Active @ GitHub - user-a = issues:v3",
		"Both @ GitHub - user-b = issues:v1@user-b",
		"Just b @ GitHub - user-b = issues:v2",
	}, "Both is under each of its logins; the view with none is under the active account's group")
	goToSettings(b, "views")
	has(sectionIn(b, "vopen:issues:v1").title, "GitHub - user-a, user-b", "the section in Settings lists the logins together in its title")
	has(sectionIn(b, "vopen:issues:v3").title, "GitHub - user-a", "and a view with none names the active account")
	s.gh.active = "user-b"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	b.typeText("r")
	w.flush()
	same(sidebarOf(b), {
		"Both @ GitHub - user-a = issues:v1@user-a",
		"Both @ GitHub - user-b = issues:v1@user-b",
		"Just b @ GitHub - user-b = issues:v2",
		"Active @ GitHub - user-b = issues:v3",
	}, "when the active account switches, the view with none follows it")
end)

case("host: each Views group of an available account or Jira ends in an Add button for a view of its own; a group that is not available has none", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "user-a"
	s.gh.tokens["user-a"] = "tok-a"
	s.gh.tokens["user-b"] = "tok-b"
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open", logins = array({ "user-a", "user-b" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "Sprint", integration = "jira", query = "sprint in openSprints()", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	local function ids(): { string }
		local out: { string } = {}
		for _, section in prefsOf(b).sections do
			for _, r in section.rows do
				table.insert(out, r.id)
			end
		end
		return out
	end
	same(ids(), { "vopen:prs:v1", "vadd:github:user-a", "vopen:issues:v1", "vadd:github:user-b", "vopen:issues:v2", "vadd:jira:" }, "user-a's group with the view that follows it and its Add, the view of both logins in a group of its own with none, user-b's group with only its Add, Jira's group with its view and Add; no status order row")
	eq(sectionIn(b, "vadd:github:user-a").id, "add:github:user-a", "the Add of a group with views closes it in a section of its own")
	eq(sectionIn(b, "vadd:github:user-a").title, nil, "with no title")
	eq(sectionIn(b, "vopen:issues:v1").id, "group:github - user-a, user-b", "the view of two logins sits in the group of both, named by its lowercased label")
	eq(sectionIn(b, "vadd:github:user-b").id, "add-to:github:user-b", "an account with no view is only its Add")
	eq(sectionIn(b, "vadd:github:user-b").title, "GitHub - user-b", "titled with the account's group")
	eq(sectionIn(b, "vadd:jira:").id, "add:jira:", "Jira's Add closes its group")
	eq(rowIn(b, "vadd:github:user-b").disabled, nil, "an Add is available while its views can be saved")
	eq(rowIn(b, "vadd:github:user-b").control.act, "add", "pressing it adds")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:github:user-b" })
	local made = w.kv.get("views-prs").items[2]
	eq(made.integration, "github", "user-b's Add makes a GitHub view")
	same(made.logins, { "user-b" }, "as user-b, though user-a is gh's active account")
	eq(made.query, "is:open involves:@me", "starting from the integration's query")
	eq(prefsOf(b).editing.row, "name:prs:v2", "a pull request view, the kind on screen, its form open on the name")
	yes(table.find(sidebarOf(b), "New view @ GitHub - user-b = prs:v2") ~= nil, "it sits in user-b's group in the sidebar")
	b.press("escape")
	b.press("escape")
	goToSettings(b, "views")
	eq(sectionIn(b, "vopen:prs:v2").id, "group:github - user-b", "user-b's group now lists it")
	eq(sectionIn(b, "vadd:github:user-b").id, "add:github:user-b", "and ends in its Add")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:jira:" })
	made = w.kv.get("views-issues").items[3]
	eq(made.integration, "jira", "Jira's Add makes a Jira view")
	eq(#made.logins, 0, "with no login")
	eq(made.query, "assignee = currentUser() AND statusCategory != Done", "and Jira's query")
	eq(#w.kv.get("views-prs").items, 2, "an issue view though a pull request view is shown: Jira has no pull requests")
end)

case("host: the Jira group of the Views page follows acli: with no Jira view it shows once acli answers, and not while acli cannot be started", function(w: World)
	hostScene(w, 3)
	local acli = newAcli(w)
	acli.override = function(_req: AcliReq): Reply?
		return { raise = "no such file or directory" }
	end
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	w.flush()
	eq(rowIn(b, "vadd:jira:"), nil, "acli cannot be started: no Jira group")
	yes(rowIn(b, "vadd:github:octocat") ~= nil, "while the signed-in account's group is there")
	acli.override = nil
	b.press("escape")
	refreshNow(w, b) -- Refresh asks again which CLIs start
	goToSettings(b, "views")
	w.flush()
	eq(sectionIn(b, "vadd:jira:").id, "add-to:jira:", "acli answers: Jira is a group with only its Add")
	eq(sectionIn(b, "vadd:jira:").title, "Jira", "titled Jira")
end)

case("host: a view's logins saved by another block: removing the shown scope's login moves to its first remaining login", function(w: World)
	local s = hostScene(w, 0)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60) }
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	pickScope(b, "prs:v1@work")
	w.flush()
	same(listed(b), { "no_2fr_237" }, "the work scope is shown")
	local c = openQueue(w, 2)
	goToSettings(c, "views")
	expand(c, "vopen:prs:v1")
	loginsSavedBy(w, c, { "octocat" }, "Mine")
	w.flush()
	same(sidebarOf(b), { "Mine @ - = prs:v1" }, "the view is one scope again, and the block's sidebar needs no groups")
	same(listed(b), { "no_2fr_231" }, "and shows the login that is left")
	local searches = requestsOf(s.gh, "search")
	eq(searches[#searches].login, "octocat", "searched as it")
	-- adding a login keeps the scope shown; emptying the list is gh's active account
	loginsSavedBy(w, c, { "octocat", "zed" }, "Mine again")
	eq(pickerOf(b).scope, "prs:v1@octocat", "a login added keeps the scope that was shown")
	eq(#requestsOf(s.gh, "search"), #searches, "and searches nothing more")
	loginsSavedBy(w, c, {}, "Mine once more")
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "with no login the view is one scope")
	eq(requestsOf(s.gh, "search")[#requestsOf(s.gh, "search")].login, "octocat", "run as gh's active account")
end)

case("host: the active login is saved with the block and restored; one the view no longer lists falls back to its first", function(w: World)
	local s = hostScene(w, 0)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60) }
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	pickScope(b, "prs:v1@work")
	w.flush()
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the view is saved")
	eq(saved.activeLogin, "work", "and the login of its scope")
	local again = w.open(2, { "/work/r" }, saved)
	w.flush()
	eq(pickerOf(again).scope, "prs:v1@work", "a restored block shows the same scope")
	same(listed(again), { "no_2fr_237" }, "with that login's list")
	local searches = requestsOf(s.gh, "search")
	eq(searches[#searches].login, "work", "searched as it")
	local stale = { version = 2, launchCwd = "/work/r", activeViewId = "v1", activeLogin = "gone" }
	local third = w.open(3, { "/work/r" }, stale)
	w.flush()
	eq(pickerOf(third).scope, "prs:v1@octocat", "a saved login the view does not list falls back to its first")
	same(listed(third), { "no_2fr_231" }, "and shows that one's PRs")
	eq(third.saved().activeLogin, "octocat", "which is what is saved from then on")
end)

case("host: a view saved with one login loads as a list of one; a malformed list is not overwritten; repeats collapse on the next save", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Old", integration = "github", query = "is:open", login = "work", group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_237" }, "the old login still decides who searches")
	eq(requestsOf(s.gh, "search")[1].login, "work", "as that login")
	goToSettings(b, "views")
	same(rowIn(b, "vopen:prs:v1").label, "Old · active", "the view")
	expand(b, "vopen:prs:v1")
	b.press("enter")
	b.typeText("!")
	b.press("enter")
	local saved = w.kv.get("views-prs").items[1]
	same(saved.logins, { "work" }, "the next save writes a list")
	eq(saved.login, nil, "and no longer the old field")
	-- repeats of another case collapse
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Dups", integration = "github", query = "is:open", logins = array({ "work", "Work" }), group = "none", prompts = array({}) },
	}) })
	local again = openQueue(w, 2)
	goToSettings(again, "views")
	expand(again, "vopen:prs:v1")
	again.press("enter")
	again.typeText("!")
	again.press("enter")
	same(w.kv.get("views-prs").items[1].logins, { "work" }, "the same login in another case is one once saved")
	-- a malformed list is refused whole
	local bad = { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Bad", integration = "github", query = "is:open", logins = array({ "no good" }), group = "none", prompts = array({}) },
	}) }
	w.kv.put("views-prs", bad)
	local third = openQueue(w, 3)
	has(third.text(), "malformed", "a login with a space makes the saved views malformed")
	same(w.kv.get("views-prs"), bad, "and they are not overwritten")
end)

case("host: a Jira filter lists its issues and saves its active view and kind", function(w: World)
	local s = jiraHost(w)
	local before = w.kv.get("views-issues")
	local b = openIssues(w)
	same(w.kv.get("views-issues"), before, "the saved Jira filters are read, never seeded over or rewritten")
	eq(#w.kv.get("views-prs").items, 2, "the PR filters, absent until now, are seeded beside them")
	-- How many searches acli was asked for.
	local function searched(): number
		local n = 0
		for _, req in s.acli.requests do
			if req.kind == "search" then
				n += 1
			end
		end
		return n
	end
	eq(searched(), 1, "one search covers the project's issues")
	for _, call in w.calls do
		-- whether gh starts, and the sidebar's group labels learn gh's active login; nothing else may ask gh
		if call.argv[2] ~= "--version" then
			eq(call.argv[1] == "gh" and call.argv[2] ~= "auth", false, "a Jira filter never searches through gh: " .. table.concat(call.argv, " "))
			eq(call.argv[1] == "gh" and call.argv[3] ~= "status", false, "nor reads a token: " .. table.concat(call.argv, " "))
		end
	end
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "listed in acli's order")
	eq(pickerOf(b).selected, "nabc_23ABC-12", "the first issue is selected")
	eq(pickerOf(b).state, "ready", "the list is ready")
	eq(b.title(), "Plotroom · Assigned to me (2)", "the title names the filter and counts the issues")
	local jira: any = nil
	for _, scope in pickerOf(b).scopes do
		if scope.id == "issues:v1" then
			jira = scope
		end
	end
	eq(jira.label, "Assigned to me", "the sidebar lists the Jira view")
	eq(jira.group, "Jira", "under Jira's group")
	eq(actionOf(b, "repos"), nil, "the action bar has no repository button")
	b.typeText("q")
	eq(#w.opened, 0, "and q opens nothing")
	local function row(i: number): any
		return pickerOf(b).items[i]
	end
	-- A row's badges as "text/tone", in order.
	local function badges(i: number): string
		local out: { string } = {}
		for _, badge in row(i).badges or {} do
			if badge.text ~= "New" then
				table.insert(out, badge.text .. "/" .. (badge.tone or "-"))
			end
		end
		return table.concat(out, " ")
	end
	eq(row(1).id, "nabc_23ABC-12", "the id is n and the issue's key, escaped")
	eq(row(1).label, "Fix login", "the summary is the label")
	eq(detailText(row(1)), "ABC-12 · Ann Lee · Bug", "the key, the reporter and the type: no repository, no age (the search carries no dates), no assignee")
	eq(detailText(row(2)), "ABC-13 · Ann Lee · Task", "the same for an unassigned issue")
	eq(row(1).facts, nil, "the rows carry no facts column: no assignee, no comment count")
	eq(pickerOf(b).columns, nil, "and the picker has no columns")
	eq(badges(1), "Jira/accent In Progress/warning ui/-", "the integration comes first, accent for Jira, then the workflow status toned by its category, then the labels")
	eq(badges(2), "Jira/accent Done/success", "a done issue says Done")
	eq(findKey(findKey(pickerNode(b), "head"), "open", "icon").p.title, "Open in Jira", "the preview head's Open icon names the tracker")
	b.typeText("?")
	for _, r in helpRows(b.view().layer) do
		eq(r.keys == "p", false, "no shortcut for another project")
	end
	b.press("escape")
	local rerun = w.open(1, { "/work/r" })
	w.flush()
	same(listed(rerun), { "nabc_23ABC-12", "nabc_23ABC-13" }, "running init again for the live pane keeps its Jira list")
	eq(searched(), 1, "and does not search twice")
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the block saves its active view")
	eq(saved.activeKind, "issues", "and its kind: a PR filter may have the same id")
	local again = w.open(2, { "/work/r" }, saved)
	w.flush()
	eq(again.title(), "Plotroom · Assigned to me (2)", "a restored block shows the same view")
end)

case("host: issues always list In Progress, then To Do, then Done, in acli's priority order within each; a saved status order and Settings change nothing", function(w: World)
	local s = jiraHost(w)
	local function status(name: string, category: string): any
		return { status = { name = name, statusCategory = { key = category } } }
	end
	s.acli.searches[JIRA_ASSIGNED] = {
		jiraItem("ABC-1", "Shipped", status("Done", "done")),
		jiraItem("ABC-2", "Next", status("Proposed", "new")),
		jiraItem("ABC-3", "Review", status("In Review", "indeterminate")),
		jiraItem("ABC-4", "Later", status("Proposed", "new")),
		jiraItem("ABC-5", "Coding", status("In Development", "indeterminate")),
	}
	local b = openIssues(w)
	same(listed(b), { "nabc_23ABC-3", "nabc_23ABC-5", "nabc_23ABC-2", "nabc_23ABC-4", "nabc_23ABC-1" }, "by status category, acli's order within one")
	local views: any = w.kv.get("views-issues")
	views.items[1].group = "status"
	w.kv.put("views-issues", views)
	local grouped = openIssues(w, 2)
	-- group headers by label, items by id
	local function shown(blk: Block): { string }
		local out: { string } = {}
		for _, id in pickerOf(blk).order do
			table.insert(out, if type(id) == "table" then id.label else id)
		end
		return out
	end
	same(shown(grouped), { "In Review", "nabc_23ABC-3", "In Development", "nabc_23ABC-5", "Proposed", "nabc_23ABC-2", "nabc_23ABC-4", "Done", "nabc_23ABC-1" }, "status groups follow the list, not the alphabet")
	goToSettings(b, "views")
	eq(rowIn(b, "sorder"), nil, "Settings has no status order row")
	local saved = array({ "done", "new", "indeterminate" })
	w.kv.put("status-order", saved)
	local later = openIssues(w, 3)
	same(shown(later), { "In Review", "nabc_23ABC-3", "In Development", "nabc_23ABC-5", "Proposed", "nabc_23ABC-2", "nabc_23ABC-4", "Done", "nabc_23ABC-1" }, "a saved status order is not read: a block opened after it sorts as before")
	same(listed(b), { "nabc_23ABC-3", "nabc_23ABC-5", "nabc_23ABC-2", "nabc_23ABC-4", "nabc_23ABC-1" }, "and the list of the block that was open stays the same")
	same(w.kv.get("status-order"), saved, "and it is left as it was")
end)

case("host: a Jira view's Settings speak of JQL, the shared prompts, the repositories its issues are worked in and its branch format", function(w: World)
	local s = jiraHost(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Triage", "Triage {key} in {project}: {title}", true) })
	local b = openIssues(w)
	local function page(name: string)
		b.event({ ev = "action", id = "layer.settings", act = "page", value = name })
	end
	-- Types `text` over what text row `row` holds and saves it.
	local function save(row: string, text: string)
		b.event({ ev = "select", id = "layer.settings", item = row })
		b.press("enter")
		for _ = 1, 80 do
			b.press("backspace")
		end
		b.typeText(text)
		b.press("enter")
	end
	-- The JQL of acli's latest search.
	local function lastJql(): string
		local jql = ""
		for _, req in s.acli.requests do
			if req.kind == "search" then
				jql = req.argv[6]
			end
		end
		return jql
	end
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	eq(rowIn(b, "query:issues:v1").label, "JQL", "the query field is the JQL")
	eq(rowIn(b, "query:issues:v1").control.placeholder, "assignee = currentUser() AND statusCategory != Done", "and shows an example")
	save("query:issues:v1", "a = 1) OR (b = 2")
	eq(rowIn(b, "query:issues:v1").warning, "Unbalanced parentheses.", "a query that closes its own parenthesis is refused")
	eq(prefsOf(b).editing.row, "query:issues:v1", "the draft stays for a correction")
	b.press("escape")
	s.acli.searches['(summary ~ "login") ORDER BY priority DESC, updated DESC'] = { jiraItem("ABC-12", "Fix login") }
	save("query:issues:v1", 'summary ~ "login"')
	w.flush()
	eq(lastJql(), '(summary ~ "login") ORDER BY priority DESC, updated DESC', "a good query searches again, in parentheses, highest priority first")
	same(listed(b), { "nabc_23ABC-12" }, "and lists what it finds")
	page("prompts")
	expand(b, "popen:issues:p1")
	eq(rowIn(b, "pname:issues:p1").control.value, "Triage", "the prompts saved for issues are shared with GitHub's")
	b.event({ ev = "action", id = "layer.settings", act = "edit-prompt", value = "ptext:issues:p1" })
	local legend: { string } = {}
	for _, item in findKey(editorCard(b), "list", "kv").p.items do
		table.insert(legend, item.k[1].t)
	end
	same(legend, { "{url}", "{key}", "{title}", "{author}", "{labels}", "{branch}", "{base}", "{remote}", "{owner}", "{repo}", "{number}", "{project}", "{status}", "{type}", "{github.user}", "{jira.user}" }, "the variables of both trackers are listed, with the worktree's and the two users")
	b.press("escape")
	page("jira")
	eq(rowIn(b, "jopen:ABC").hint, "o/r", "the project's summary names its repositories")
	expand(b, "jopen:ABC")
	eq(prefsOf(b).focus, "jrepos:ABC", "and Edit opens them")
	eq(rowIn(b, "jrepos:ABC").control.values[1], "o/r", "the project's repository")
	same(rowIn(b, "jrepos:ABC").control.options, { { value = "o/r", label = "o/r" } }, "chosen among the saved repositories")
	page("repos")
	expand(b, "ropen:o/r")
	save("branch:o/r", "{project}/{key}")
	eq(w.kv.get("branch-formats")["o/r"], "{project}/{key}", "a good format is saved under the repository")
	has(b.text(), "ABC/ABC-12", "and the preview's branch follows")
	page("views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(w.kv.get("views-issues").items[2].query, "is:open involves:@me", "a new view starts as the GitHub one")
end)

case("host: removing a repository drops it from jira-repos, branch-formats and setup-commands", function(w: World)
	issueHost(w)
	w.kv.put("checkouts", { ["x/y"] = "/work/y" })
	w.kv.put("branch-formats", { ["x/y"] = "keep/{key}", ["o/r"] = "{key}" })
	w.kv.put("setup-commands", { ["x/y"] = array({ "make" }), ["o/r"] = array({ "pnpm install" }) })
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }), DEF = array({ "x/y" }) })
	local b = openIssues(w)
	goToSettings(b, "repos")
	expand(b, "ropen:x/y")
	b.event({ ev = "select", id = "layer.settings", item = "rremove:x/y" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "rremove:x/y" })
	eq(w.kv.get("checkouts")["x/y"], nil, "its checkout is forgotten")
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the other repository's stays")
	same(w.kv.get("branch-formats"), { ["o/r"] = "{key}" }, "so is its branch format")
	same(w.kv.get("setup-commands"), { ["o/r"] = { "pnpm install" } }, "and its setup commands")
	same(w.kv.get("jira-repos"), { ABC = { "o/r" }, DEF = array({}) }, "every Jira project drops it; one left with none stays listed")
	eq(rowIn(b, "ropen:x/y"), nil, "it is gone from the page")
	eq(prefsOf(b).focus, "radd", "and the Add button takes the focus")
end)

case("host: a Jira issue request makes its worktree in the project's mapped GitHub repository", function(w: World)
	local s = jiraHost(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	local b = openIssues(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	eq(badgeOf(b), nil, "no badge before there is a worktree")
	request(b, "j1", freshAsk("ABC", "ABC-12"))
	w.flush()
	local a = answerOf(b, "j1")
	eq(a.path, target, "the worktree is named after the repository and the issue's key")
	eq(a.created, true, "created")
	eq(a.summary, "Created · octocat/ABC-12-fix-login at bbbbbbb · Clean", "on a branch of the gh login, the key and the summary's slug, at the base chosen")
	eq(a.setup, "pnpm install", "the repository's saved setup commands run in a new worktree")
	same(a.vars, {
		url = "https://acme.atlassian.net/browse/ABC-12",
		key = "ABC-12",
		title = "Fix login",
		author = "Ann Lee",
		labels = "ui",
		owner = "o",
		repo = "r",
		project = "ABC",
		status = "In Progress",
		type = "Bug",
		["github.user"] = "octocat",
		["jira.user"] = "ann",
		branch = "octocat/ABC-12-fix-login",
		base = "main",
		remote = "origin",
	}, "the issue's Jira variables, with both users and the worktree's branch, base and remote")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base was fetched into its remote-tracking ref")
	eq(countLog(s.git, "worktree add -b octocat/ABC-12-fix-login " .. target .. " " .. sha("b")), 1, "and the worktree made once")
	eq(w.opened[#w.opened], "plotroom://rpc/j1", "the window is told to read the answer")
	eq(badgeOf(b).text, "Worktree", "a worktree puts a badge on the row")
	table.insert(w.panes, { pane = 9, cwd = target .. "/src" })
	b.render()
	local texts: { string } = {}
	for _, badge in pickerOf(b).items[1].badges do
		table.insert(texts, badge.text)
	end
	yes(table.find(texts, "In tab") ~= nil, "a tab in the worktree marks the issue: the directory keeps the key's case")
	local titlerow: any = findKey(pickerNode(b), "titlerow")
	yes(titlerow ~= nil, "the preview has a title row")
	eq(titlerow.c[1].p.key, "title", "its first node is the title")
	eq(titlerow.c[2].p.key, "integration", "followed by the integration badge")
	eq(titlerow.c[2].p.text, "Jira", "naming the tracker")
	eq(titlerow.c[2].p.tone, "accent", "accent for Jira")
	eq(findKey(findKey(pickerNode(b), "head"), "integration"), nil, "and the head row no longer carries it")
	-- a format saved for the repository applies, with its {project}
	w.kv.put("branch-formats", { ["o/r"] = "{project}/{key}" })
	request(b, "j2", freshAsk("ABC", "ABC-13"))
	w.flush()
	eq(answerOf(b, "j2").vars.branch, "ABC/ABC-13", "the project's branch format names the branch")
	-- the main checkout
	request(b, "j3", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false })
	local main = answerOf(b, "j3")
	eq(main.path, "/work/r", "a prompt set to the main checkout runs in the repository's checkout")
	eq(main.vars.branch, nil, "with no branch: there is no worktree")
	eq(main.vars.project, "ABC", "but the project")
	-- what is not for this block is dropped
	local ran, told = #w.calls, #w.opened
	request(b, "g1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	request(b, "g2", { op = "issue", repo = "abc", ref = "ABC-12", worktree = false })
	request(b, "g3", { op = "issue", repo = "ABC", ref = "ABC 12", worktree = false })
	w.flush()
	eq(answerOf(b, "g1").problem, "That issue is not loaded here any more; Refresh and try again.", "a GitHub issue the Jira list never had is refused")
	eq(answerOf(b, "g2"), nil, "so is a project key that is not one")
	eq(answerOf(b, "g3"), nil, "and a reference that cannot name a directory")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.opened, told + 1, "and the window was told of that refusal only")
end)

case("host: an issue filter shows the card of an issue's worktree that git lists, with no pull request head to be at", function(w: World)
	local s = issueHost(w)
	local path = "/wt/plotroom-o_r-issue-12"
	table.insert(s.git.worktrees, { path = path, branch = "refs/heads/12-fix-login", head = sha("b"), locked = false })
	table.insert(s.git.worktrees, { path = "/wt/plotroom-o_r-pr-13", branch = "refs/heads/plotroom/o/r/pr-13", head = sha("b"), locked = false })
	w.fs.dirs[path] = true
	w.fs.dirs["/wt/plotroom-o_r-pr-13"] = true
	s.git.dirty[path] = " M src/a.lua\n"
	local b = openIssues(w)
	yes(badgeOf(b, 1) ~= nil, "the issue's row wears the badge")
	eq(badgeOf(b, 2), nil, "an issue with no worktree wears none, though a pull request of that number has one")
	same(chipsOf(b), { "Changes unchecked" }, "its card: only its changes, an issue has no head to be at")
	has(cardText(b), "12-fix-login", "its branch")
	has(cardText(b), path, "and where it is")
	eq(countLog(s.git, "config"), 0, "no remote is read: only a pull request's branch needs one")
	w.advance(300)
	same(chipsOf(b), { "Uncommitted changes" }, "its changes are read once the cursor has rested")
	eq(badgeOf(b).tone, "warning", "and the row follows")
	table.remove(s.git.worktrees, 2)
	w.fs.dirs[path] = nil
	table.remove(s.git.worktrees, 2)
	refreshNow(w, b)
	eq(cardOf(b), nil, "removed outside Plotroom, it leaves the next refresh")
end)

case("host: a Jira issue's worktree in a repository mapped to its project shows on its card, and a project with none mapped reads nothing", function(w: World)
	local s = jiraHost(w)
	local path = "/wt/plotroom-o_r-issue-ABC-12"
	table.insert(s.git.worktrees, { path = path, branch = "refs/heads/ABC-12-fix-login", head = sha("b"), locked = false })
	w.fs.dirs[path] = true
	local b = openIssues(w)
	yes(badgeOf(b, 1) ~= nil, "ABC-12's row wears the badge")
	eq(badgeOf(b, 2), nil, "ABC-13's does not")
	same(chipsOf(b), { "Changes unchecked" }, "its card")
	has(cardText(b), "ABC-12-fix-login", "names the branch")
	eq(countLog(s.git, "worktree list"), 1, "from one list of the repository the project is mapped to")
	w.kv.put("jira-repos", {})
	local unmapped = openIssues(w, 2)
	eq(cardOf(unmapped), nil, "a project mapped to no repository shows none")
	eq(countLog(s.git, "worktree list"), 1, "and looked in none")
end)

case("host: the Jira preview shows the union rows and Jira's own", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = {
		key = "ABC-12",
		fields = {
			description = { type = "doc", version = 1, content = { { type = "paragraph", content = { { type = "text", text = "Login fails." } } } } },
			parent = { key = "ABC-1", fields = { summary = "Auth epic" } },
			customfield_10020 = array({ { boardId = 3, state = "closed", name = "Sprint 1" }, { boardId = 3, state = "active", name = "Sprint 2" } }),
			fixVersions = array({ { name = "v2" } }),
			issuelinks = array({
				{ type = { inward = "is blocked by", outward = "blocks" }, outwardIssue = { key = "ABC-3", fields = { summary = "Login API", status = { statusCategory = { key = "new" } } } } },
				{ type = { inward = "relates to", outward = "relates to" }, inwardIssue = { key = "ABC-6", fields = { summary = "Old notes", status = { name = "Backlog", statusCategory = { key = "new" } } } } },
				{ type = { inward = "is blocked by", outward = "blocks" }, outwardIssue = { key = "ABC-5", fields = { summary = "Review copy", status = { name = "In Review", statusCategory = { key = "indeterminate" } } } } },
			}),
			subtasks = array({ { key = "ABC-14", fields = { summary = "Add test", status = { statusCategory = { key = "done" } } } } }),
			comment = { total = 2, comments = array({}) },
			created = "2026-10-12T08:00:00.000+0000",
			updated = "2026-10-12T11:30:00.000+0000",
		},
	}
	local b = openIssues(w)
	local function factKeys(): { string }
		local out: { string } = {}
		local facts: any = findKey(findKey(pickerNode(b), "about"), "facts", "kv")
		for _, item in facts.p.items do
			table.insert(out, item.k)
		end
		return out
	end
	same(factKeys(), { "Project", "Reporter", "Assignees", "Type", "Priority" }, "only the rows with a value; the details' rows wait for them")
	eq(factOf(b, "Reporter"), "Ann Lee", "the reporter is a name, not a login")
	eq(factOf(b, "Assignees"), "Bob Ray", "assignees")
	eq(factOf(b, "Type"), "Bug", "the type")
	eq(factOf(b, "Priority"), "High", "and the priority, which the search carries")
	has(b.text(), "Linked issues", "the linked items' heading shimmers meanwhile")
	has(b.text(), "Loading details…", "with the details loading")
	eq(#s.acli.requests, 3, "only whether acli starts, the sign-in and the search were asked: the details wait for the cursor to rest")
	w.advance(300)
	eq(s.acli.requests[4].kind, "view", "the details load once the cursor rests")
	eq(factOf(b, "Parent"), "ABC-1 Auth epic", "the parent")
	eq(factOf(b, "Sprint"), "Sprint 2", "the active sprint")
	same(factKeys(), { "Project", "Reporter", "Assignees", "Type", "Priority", "Parent", "Sprint", "Fix versions", "Comments", "Opened", "Updated" }, "no components row without components")
	eq(factOf(b, "Fix versions"), "v2", "the fix version")
	eq(factOf(b, "Comments"), "2", "the comment count")
	eq(factOf(b, "Opened"), "4h ago", "when it was opened")
	eq(factOf(b, "Updated"), "30m ago", "and last updated")
	local preview = pickerNode(b)
	local head = findKey(preview, "head")
	eq(findKey(head, "copy", "icon").p.href, "https://acme.atlassian.net/browse/ABC-12", "the head's copy icon takes the browse link")
	eq(findKey(head, "copy", "icon").p.aria, "Copy link to issue ABC-12", "which names the key")
	eq(findKey(head, "state", "badge").p.text, "In Progress", "the head's badge is the workflow status")
	eq(findKey(head, "state", "badge").p.tone, "warning", "toned by its category")
	eq(findKey(findKey(preview, "branch"), "v").p.spans[1].t, "octocat/ABC-12-fix-login", "the branch Worktree would make: the default format over gh's active login")
	eq(findKey(findKey(preview, "description", "card"), "body", "md").p.text, "Login fails.", "the description from Jira's document format, as Markdown")
	-- The linked section as lines: each relation's heading, then its rows.
	local function linked(): { string }
		local out: { string } = {}
		local g = 1
		while findKey(preview, "linked" .. g) do
			local h: any = findKey(preview, "linked-head" .. g)
			if h then
				table.insert(out, h.p.spans[1].t)
			end
			for _, item in (findKey(preview, "linked" .. g) :: any).c do
				table.insert(out, "  " .. item.p.label .. " | " .. item.p.value .. " | " .. item.p.icon .. " | " .. item.p.tone .. " | " .. item.p.title)
			end
			g += 1
		end
		return out
	end
	same(linked(), {
		"Blocks · 2",
		"  Login API | ABC-3 | list-checks | muted | ABC-3 · To Do",
		"  Review copy | ABC-5 | list-checks | warning | ABC-5 · In Review",
		"Relates to · 1",
		"  Old notes | ABC-6 | list-checks | muted | ABC-6 · Backlog",
		"Subtasks · 1",
		"  Add test | ABC-14 | check | success | ABC-14 · Done",
	}, "linked issues under one heading per relation, in the order Jira first names it; the icon and tone are the status category, the key at the right, the status in the tooltip")
	-- an issue whose details cannot be read says why
	b.event({ ev = "select", id = "layer.queue", item = "nabc_23ABC-13" })
	w.advance(300)
	has(b.text(), "Could not load the details: Issue does not exist or you do not have permission to see it.", "the reason is on screen")
	has(b.text(), "Retry", "with a Retry button")
	eq(factOf(b, "Comments"), nil, "and what only the details know stays hidden")
end)

case("host: the project pickers: Jira's list puts saved projects first with their repositories, and the repository lists are GitHub's", function(w: World)
	local s = jiraHost(w)
	local gh = s.gh
	gh.tokens.octocat = "tok-octo"
	s.acli.projects = {
		{ key = "ABC", name = "Alpha" },
		{ key = "LOW", name = "Lower" },
		{ key = "XYZ", name = "Xylo" },
		{ key = "lower", name = "Not a key" },
	}
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }), DEF = array({}), nope = array({ "o/r" }) })
	w.kv.put("checkouts", { ["o/r"] = "/work/o", ["x/y"] = "" })
	local b = openIssues(w)
	request(b, "p1", { op = "jira-projects" })
	w.flush()
	local answer = answerOf(b, "p1")
	local want: { any } = {
		{ key = "ABC", name = "Alpha", repos = "o/r, x/y", saved = true },
		{ key = "DEF", repos = "", saved = true },
		{ key = "LOW", name = "Lower", saved = false },
		{ key = "XYZ", name = "Xylo", saved = false },
	}
	same(answer.items, want, "saved projects by key with their repositories, then the rest of acli's list; a key that is none is left out")
	eq(answer.problem, nil, "nothing is wrong")
	eq(w.opened[#w.opened], "plotroom://rpc/p1", "and the window is told to read the answer")
	-- signed out: the saved projects, and why there are no more
	s.acli.site = nil
	request(b, "p2", { op = "jira-projects" })
	w.flush()
	local out = answerOf(b, "p2")
	local saved: { any } = {
		{ key = "ABC", repos = "o/r, x/y", saved = true },
		{ key = "DEF", repos = "", saved = true },
	}
	same(out.items, saved, "signed out, only the saved projects are listed")
	has(out.problem, "acli is not signed in to Jira", "and the problem says why")
	-- the repository picker lists the saved repositories with their checkouts, then the gh logins
	request(b, "r1", { op = "repos" })
	w.flush()
	local expectedRepos: { any } = { { repo = "o/r", path = "/work/o" }, { repo = "x/y" } }
	same(answerOf(b, "r1").items, expectedRepos, "the repository picker lists the saved repositories, a folder only where one is set")
	same(answerOf(b, "r1").accounts, { { login = "octocat", active = true } }, "and the gh logins")
	request(b, "r2", { op = "profile", login = "octocat" })
	w.flush()
	same(answerOf(b, "r2").repos, array({}), "a login's list holds the repositories it can open")
end)

windowCase("window: Worktree on an issue opens a tab named \"#12 · r\" in plotroom-o_r-issue-12", function(w: World)
	local s, b = issueWindow(w)
	local target = "/wt/plotroom-o_r-issue-12"
	w.window.choose = "main"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(w.toasts[1].level, "info", "start")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "names the issue")
	eq(w.toasts[2].level, "success", "level")
	eq(w.toasts[2].text, "Worktree ready for o/r#12", "names the issue")
	eq(w.toasts[2].sub, "Created · octocat/12-fix-login at bbbbbbb · Clean", "a new worktree on the issue's branch, at the base picked")
	local sent = requestsSent(w)
	eq(#sent, 2, "the first request, which the host answers with the base branches to pick from, and the one that carries the pick")
	eq(sent[1].op, "issue", "the issue op")
	eq(sent[1].repo, "o/r", "of the repository")
	eq(sent[1].ref, "12", "and the issue")
	eq(sent[1].worktree, true, "in a worktree")
	eq(sent[1].fresh, nil, "with no decision yet")
	eq(sent[2].fresh, true, "the second asks for a new branch")
	eq(sent[2].base, "main", "from the base picked")
	eq(#w.window.picks, 1, "the base was asked once")
	eq(#w.window.launches, 1, "one tab")
	eq(w.window.launches[1].cwd, target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "#12 · r", "tab name")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("b"), "the branch starts at the base picked, named after the gh login")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "which was fetched once")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b octocat/12-fix-login " .. target .. " " .. sha("b")), 1, "and the worktree added through omp")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	has(cardText(b), target, "and the card says where the worktree is")
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(w.toasts[#w.toasts].level, "success", "the second click")
	has(w.toasts[#w.toasts].sub, "Reused", "reuses it")
	eq(countLog(s.git, "worktree add"), 1, "made once")
	eq(#w.window.launches, 2, "and opens its tab again")
end)

-- A window whose pane 1 is the Plotroom block of `jiraHost` on its Jira filter (project ABC), linked.
local function jiraWindow(w: World): (JiraScene, Block)
	local s = jiraHost(w)
	w.load("window")
	local b = openIssues(w)
	w.link(b)
	cardSurface(w, b)
	return s, b
end

windowCase("window: the Jira project picker lists the saved projects and acli's; a typed key is added in Settings", function(w: World)
	local s, b = jiraWindow(w)
	s.acli.projects = { { key = "ABC", name = "Alpha" }, { key = "XYZ", name = "Xyz Project" } }
	w.window.choose = "Other project…"
	w.window.typed = "xyz"
	w.click("plotroom://jira-projects")
	w.flush()
	local items = w.window.picks[1].items
	eq(items[1].label, "ABC", "the saved project first")
	eq(items[1].group, "Saved", "in its group")
	eq(items[1].detail, "o/r", "with its repositories")
	eq(items[2].label, "XYZ", "then the one acli lists")
	eq(items[2].group, "Jira projects", "in its group")
	eq(items[2].detail, "Xyz Project", "with its name")
	eq(items[3].label, "Other project…", "then a typed one")
	same(w.kv.get("jira-repos").XYZ, array({}), "a typed key is saved upper-cased, with no repository yet")
	eq(prefsOf(b).page, "jira", "and Settings opens on the Jira page")
	eq(prefsOf(b).focus, "jrepos:XYZ", "at its repositories")
end)

windowCase("window: Worktree on a Jira issue opens a tab named \"ABC-12\"", function(w: World)
	local s, b = jiraWindow(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	w.window.choose = "main"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(w.toasts[1].text, "Preparing worktree for ABC-12", "names the issue by its key")
	eq(w.toasts[2].level, "success", "level")
	eq(w.toasts[2].sub, "Created · octocat/ABC-12-fix-login at bbbbbbb · Clean", "a new worktree on the issue's branch")
	eq(requestsSent(w)[1].repo, "ABC", "the request names the project")
	eq(w.window.launches[1].cwd, target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "ABC-12", "tab name")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base is fetched into its remote-tracking ref")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
end)

windowCase("window: Jira issue picks its repository: asked when none is mapped, among several, never with one", function(w: World)
	local _, b = jiraWindow(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	-- none mapped: the pick maps the project, then the worktree is made there
	w.kv.put("jira-repos", {})
	w.window.choose = { "o/r", "main" }
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	local picks = w.window.picks
	eq(#picks, 2, "two questions: the repository, then the base branch")
	eq(picks[1].placeholder, "Repository for Jira project ABC…", "it names the project")
	eq(picks[1].items[1].label, "o/r", "offering the saved repositories")
	eq(picks[1].items[#picks[1].items].label, "Other repository…", "and a typed one")
	same(w.kv.get("jira-repos").ABC, { "o/r" }, "the pick is saved for the project")
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "issue", "map-jira", "issue", "issue" }, "the request is repeated once the project is mapped, and again once the base is picked")
	eq(requestsSent(w)[3].target, "o/r", "naming the repository picked")
	eq(requestsSent(w)[4].target, "o/r", "which the base's answer keeps")
	eq(requestsSent(w)[4].base, "main", "with the base")
	eq(w.window.launches[1].cwd, target, "the tab opens in the worktree of the picked repository")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	-- one mapped: no question at all
	local asked, sent = #w.window.picks, #requestsSent(w)
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(#w.window.picks, asked, "a mapped project asks nothing")
	eq(#requestsSent(w), sent + 1, "and sends one request")
	-- several mapped: asked each time, nothing saved
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }) })
	w.window.choose = "x/y"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(w.window.picks[asked + 1].placeholder, "Which repository for ABC-12?", "several repositories are asked each time")
	same(w.kv.get("jira-repos").ABC, { "o/r", "x/y" }, "and the map is left as it was")
	local last = requestsSent(w)
	eq(last[#last - 1].op, "issue", "the first request found several")
	eq(last[#last].target, "x/y", "the second names the pick")
end)

windowCase("window: Go to tab on an issue focuses the pane working in its worktree", function(w: World)
	local s, b = issueWindow(w)
	leaveIssueWt(w, s, 12)
	w.window.panes[9] = { block = nil, cwd = "/wt/plotroom-o_r-issue-12/src", tab = 2 }
	table.insert(w.window.tabs, { id = 2, session = 1 })
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-12/src" })
	refreshNow(w, b)
	cardSurface(w, b)
	w.click(issueLink("goto", "o/r", "12"))
	w.flush()
	eq(requestsSent(w)[1].op, "where", "the host is asked where the issue's worktree is")
	eq(requestsSent(w)[1].key, "o/r#12", "naming the issue")
	same(w.window.switches, { 1 }, "its session is switched to")
	eq(w.window.focused, 9, "and the pane focused")
	eq(#w.toasts, 0, "with nothing said")
end)

windowCase("window: a prompt set to the main checkout starts its agent in a new tab at the checkout, with no worktree made", function(w: World)
	local s, b = issueWindow(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Review", "Review {title} ({url}) in {owner}/{repo}#{number}, branch {branch}", false) })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	b.render()
	cardSurface(w, b)
	w.click(issueRunLink("o/r", "12", "p1"))
	w.flush()
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "menu", "issue" }, "the host is asked what the prompt is, then for the checkout")
	eq(requestsSent(w)[2].worktree, false, "and the request says no worktree")
	eq(#w.window.picks, 0, "nothing is asked")
	eq(#w.window.agents, 1, "the agent starts")
	eq(w.window.agents[1].cwd, "/work/r", "in the main checkout")
	eq(w.window.agents[1].how, "tab", "in a new tab")
	eq(w.window.agents[1].prompt, "Review Fix login (https://github.com/o/r/issues/12) in o/r#12, branch {branch}", "with the issue's variables filled in; {branch} stays as written: there is no worktree")
	eq(w.toasts[#w.toasts].text, "Agent started for o/r#12", "the agent got its own tab, not the worktree's")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "#12 · r", "named for the issue")
	eq(#w.window.launches, 1, "the agent's tab is the only one: no setup shell")
	eq(#w.window.runs, 0, "no setup commands ran")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made")
	eq(cardOf(b), nil, "nor noted on the block")
end)

windowCase("window: the Agent picker on an issue runs typed text in its worktree and a saved prompt where it says, every {variable} filled in", function(w: World)
	local s, b = issueWindow(w)
	saveIssuePrompts(w, {
		issuePrompt("p1", "Here", "In {branch} ({base}): {title}", true),
		issuePrompt("p2", "There", "In the checkout, branch {branch}, labels {labels}", false),
	})
	b.render()
	cardSurface(w, b)
	w.window.choose, w.window.typed = { "Type a prompt…", "main" }, "Fix {title} ({key}) on {branch} from {base} of {remote}; {nope}"
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	local rows = promptPicks(w)[1].items
	same({ rows[1].label, rows[2].label, rows[3].label }, { "Type a prompt…", "Here", "There" }, "typing, then the saved prompts")
	eq(rows[2].worktree, true, "a prompt that runs in a worktree says so")
	eq(rows[3].worktree, false, "and one that runs in the checkout")
	eq(#w.window.agents, 1, "the typed prompt started an agent")
	eq(w.window.agents[1].cwd, "/wt/plotroom-o_r-issue-12", "in the issue's worktree")
	eq(w.window.agents[1].prompt, "Fix Fix login (12) on octocat/12-fix-login from main of origin; {nope}", "with the issue's variables and the new worktree's branch, base and remote filled in; an unknown one stays")
	eq(countLog(s.git, "worktree add -b octocat/12-fix-login /wt/plotroom-o_r-issue-12 " .. sha("b")), 1, "the worktree was made for it")
	w.window.choose = { "Start another agent", "There" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	eq(#w.window.agents, 2, "a saved prompt starts one too")
	eq(w.window.agents[2].cwd, "/work/r", "in the main checkout, as the prompt says")
	eq(w.window.agents[2].prompt, "In the checkout, branch {branch}, labels bug, ui", "with no branch to fill in")
	w.window.choose = { "Start another agent", "Here" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	eq(#w.window.agents, 3, "and another")
	eq(w.window.agents[3].cwd, "/wt/plotroom-o_r-issue-12", "in the worktree, as that prompt says")
	eq(w.window.agents[3].prompt, "In octocat/12-fix-login (): Fix login", "with its branch, and no base: the branch was reused")
	eq(countLog(s.git, "worktree add"), 1, "the worktree is made once")
end)

windowCase("window: with no prompts saved, an issue offers Implement and Fix in its worktree and Plan in the main checkout, every variable they name filled in", function(w: World)
	local _, b = issueWindow(w)
	b.render()
	cardSurface(w, b)
	w.window.choose = { "Implement", "main" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	local rows = promptPicks(w)[1].items
	same({ rows[2].label, rows[3].label, rows[4].label }, { "Implement", "Fix", "Plan" }, "after typing, the defaults")
	same({ rows[2].worktree, rows[3].worktree, rows[4].worktree }, { true, true, false }, "Plan alone runs in the main checkout")
	for i, name in { "Implement", "Fix", "Plan" } do
		if i > 1 then
			w.window.choose = { "Start another agent", name }
			w.click(issueLink("agent", "o/r", "12"))
			w.flush()
		end
		local agent = w.window.agents[i]
		eq(agent.cwd, if name == "Plan" then "/work/r" else "/wt/plotroom-o_r-issue-12", name .. " runs where it says")
		lacks(agent.prompt, "{", name .. " has every variable it names filled in")
	end
	has(w.window.agents[1].prompt, "Branch: `octocat/12-fix-login` from base `main` (remote `origin`)", "a new worktree's branch, base and remote")
	has(w.window.agents[2].prompt, "from base `` (remote `origin`)", "a reused one has no base to tell")
	eq(w.kv.get("prompts-issues"), nil, "running them saves nothing")
end)

windowCase("window: Open on an issue opens its URL beside the block it came from, whatever pane has focus", function(w: World)
	local _, b = issueWindow(w)
	local open = "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12"
	eq(buttonLink(b, "open"), open, "the block's Open link carries the issue's URL")
	w.window.focused = 7
	w.click(open)
	w.flush()
	same(w.window.browser, { { url = "https://github.com/o/r/issues/12", how = "beside", beside = 1 } }, "the issue's page, opened beside the block")
	eq(#w.toasts, 0, "nothing is said")
	w.command("open-selected")
	w.flush()
	eq(#w.window.browser, 2, "the palette command follows the same link")
end)

windowCase("window: a linked pull request in an issue's sidebar is shown by the Plotroom block it is in, which the window focuses: no other block, tab or session, and the issue filter is still there to go back to", function(w: World)
	local s, b = issueWindow(w)
	local url = "https://github.com/o/r/pull/45"
	s.gh.pulls[url] = searchItem(45, "o/r", EPOCH - 600, { title = "Fix the login redirect" })
	s.gh.issueDetail["o/r#12"] = { body = "x", linked = array({ { number = 45, title = "Fix the login redirect", url = url, state = "OPEN", isDraft = false } }) }
	w.advance(300)
	cardSurface(w, b)
	local show = "plotroom://github/show/o/r/45"
	eq(findKey(pickerNode(b), "pr1", "item").p.href, show, "the linked row links to showing it")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "the block's buttons are the issue's")
	w.window.focused = nil
	w.click(show)
	same(w.window.events[#w.window.events], { pane = 1, ev = { ev = "action", act = "show-pr", value = url } }, "it tells the block the link is in, not another one, to show the pull request")
	eq(w.window.focused, 1, "and focuses it")
	eq(#w.window.launches, 0, "no block is launched")
	eq(#w.window.switches, 0, "no session is switched to")
	w.flush()
	same(listed(b), { "no_2fr_2345" }, "the same block lists the pull request alone")
	eq(pickerOf(b).noun, "pull requests", "as pull requests")
	eq(pickerOf(b).scope, pickerOf(b).scopes[1].id, "in a scope of its own, the first of the sidebar")
	eq(buttonLink(b, "worktree"), prLink("worktree", "o/r", 45), "its buttons are the pull request's")
	pickScope(b, "issues:v1")
	w.flush()
	hx.selectFirst(b)
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the issue filter is one click away: its issues are back")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "with the issue's buttons")
	local said, sent = #w.toasts, #w.window.events
	w.click("plotroom://github/show/o/r/46")
	eq(w.toasts[said + 1].text, "Plotroom: that pull request is no longer listed", "a pull request the sidebar does not link is refused")
	eq(#w.window.events, sent, "and no block is told anything")
end)

windowCase("window: Plotroom has one launcher, which opens the one block beside the focused pane, and no command opens an Issues block of its own", function(w: World)
	w.load("window")
	w.command("open")
	same(w.window.launches, { { block = "plotroom.prs", cwd = "/work/r", args = { "/work/r" } } }, "the palette command launches the Plotroom block in the focused pane's folder")
	local ok = pcall(w.command, "open-issues")
	eq(ok, false, "there is no command for an Issues block")
end)

windowCase("window: a forged issue link not shown by the block is refused before anything is asked", function(w: World)
	local _, b = issueWindow(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Triage", "Triage {url}", true) })
	b.render()
	cardSurface(w, b)
	local sent, ran, picked = #w.window.events, #w.calls, #w.window.picks
	local function refused(url: string, text: string, what: string, pane: number?)
		local said = #w.toasts
		w.click(url, pane)
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		eq(w.toasts[#w.toasts].text, text, what .. ": what is wrong")
	end
	local unlisted = "Plotroom: that issue is no longer listed"
	local malformed = "Plotroom: malformed link"
	refused(issueLink("worktree", "o/r", "13"), unlisted, "another issue")
	refused(issueLink("worktree", "x/r", "12"), unlisted, "another repository")
	refused(issueLink("agent", "o/r", "13"), unlisted, "the Agent link of another issue")
	refused(issueLink("goto", "o/r", "12"), unlisted, "a tab link the block shows none of")
	refused(issueRunLink("o/r", "12", "p9"), unlisted, "a prompt with no button")
	refused(issueRunLink("o/r", "13", "p1"), unlisted, "a prompt button of another issue")
	refused("plotroom://issue/open/https%3A%2F%2Fevil.example%2Fx", unlisted, "a page that is not the issue's")
	refused("plotroom://issue/open/javascript%3Aalert(1)", malformed, "a page that is not https")
	refused("plotroom://issue/open/https%3A%2F%2Fa.example%2F%0Ax", malformed, "a page with a control character")
	refused("plotroom://issue/open/https%3A%2F%2Fa.example%2Fx%20y", malformed, "a page with a space")
	refused("plotroom://issue/worktree/o/r", malformed, "a link with no issue")
	refused("plotroom://issue/bogus/o/r/12", malformed, "an action there is none of")
	refused("plotroom://issue/worktree/o/../12", malformed, "a dot-dot repository")
	refused(issueLink("worktree", "o/r", string.rep("1", 65)), malformed, "a reference over 64 bytes")
	refused(issueRunLink("o/r", "12", "p-1"), malformed, "an id that is no word")
	refused(issueLink("worktree", "o/r", "12"), "Plotroom: link did not come from a Plotroom block", "a pane that is not Plotroom", 2)
	w.window.panes[2] = { block = "plugin.plotroom.issues", cwd = "/work/r", tab = 1 }
	refused(issueLink("worktree", "o/r", "12"), "Plotroom: link did not come from a Plotroom block", "a pane of the retired Issues block", 2)
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.window.picks, picked, "nothing was offered")
	eq(#w.window.browser, 0, "no Browser opened")
	eq(#w.window.agents + #w.window.launches, 0, "and nothing started")
end)

-- (hx, the helpers of the cases, is declared before openQueue.)

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

case("host: a request is about what it names, not about the filter on screen: a pull request's worktree and Jira's projects are answered under either kind", function(w: World)
	local s = jiraHost(w)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	s.acli.projects = { { key = "ABC", name = "Alpha" } }
	local b = openIssues(w)
	eq(hx.ask(w, b, "p1", { op = "worktree", repo = "o/r", number = 1 }).path, "/wt/plotroom-o_r-pr-1", "a pull request's worktree is made while an issue filter is shown")
	eq(hx.ask(w, b, "w1", { op = "where", kind = "pr", key = "o/r#1" }).path, "/wt/plotroom-o_r-pr-1", "its block says where it is")
	eq(hx.ask(w, b, "w2", { op = "where", kind = "issue", key = "o/r#1" }).path, nil, "asked about an issue of that key, it knows none")
	pickScope(b, "prs:v1")
	w.flush()
	eq(hx.ask(w, b, "j1", { op = "jira-projects" }).items[1].key, "ABC", "Jira's projects are listed while a pull request filter is shown")
	goToSettings(b, "jira")
	expand(b, "jopen:ABC")
	eq(rowIn(b, "jrepos:ABC").control.values[1], "o/r", "Settings has the Jira page under a pull request filter too, with the project's repository")
	b.press("escape")
	hx.ask(w, b, "j2", { op = "map-jira", project = "ABC", repo = "x/y" })
	same(w.kv.get("jira-repos").ABC, { "o/r", "x/y" }, "and a repository is mapped to a project")
	eq(hx.ask(w, b, "i1", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false }).problem, "That issue is not loaded here any more; Refresh and try again.", "an issue is answered only while its list is loaded: the pull request filter replaced it")
end)

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

case("host: without gh, GitHub is off everywhere: no GitHub view, group, prompt or request, and Settings shows its setup guide until gh starts", function(w: World)
	local s = jiraHost(w)
	local gh = hx.uninstalled(w, "gh")
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	-- restored on a GitHub pull request view
	local b = w.open(1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeViewId = "v1" })
	w.flush()
	same(sidebarOf(b), { "Assigned to me @ - = issues:v1" }, "only the Jira view is listed")
	eq(b.title(), "Plotroom · Assigned to me (2)", "and shown in place of the GitHub view restored")
	eq(#w.kv.get("views-prs").items, 2, "the GitHub views stay saved")
	goToSettings(b, "views")
	same(hx.rows(b), { "vopen:issues:v1", "vadd:jira:" }, "Views has Jira's group alone")
	b.press("escape")
	goToSettings(b, "prompts")
	same(hx.rows(b), { "popen:issues:p1", "popen:issues:p2", "popen:issues:p3", "padd:issues" }, "Prompts has the issue prompts alone, the defaults here: the pull request one stays saved, unlisted")
	b.press("escape")
	goToSettings(b, "worktrees")
	same(hx.rows(b), { "fmt:branch", "fmt:issuedir" }, "no pull request folder name")
	b.press("escape")
	goToSettings(b, "setup-github")
	same(hx.pages(b), { "views", "prompts", "keys", "worktrees", "repos", "jira", "connection", "setup-github" }, "GitHub's setup page is offered")
	eq(prefsOf(b).focus, "guide:github", "its one row")
	b.press("enter")
	eq(w.opened[#w.opened], "https://github.com/cli/cli#installation", "opens gh's install guide")
	b.press("escape")
	w.kv.put("branch-format", "{key}-{slug}")
	same(hx.ask(w, b, "j1", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true }), { chooseBase = true, branch = "ABC-12-fix-login", branches = { "main" } }, "a Jira issue's worktree looks for no linked pull request: a new branch")
	w.kv.put("branch-format", "")
	has(hx.ask(w, b, "j2", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true }).problem, "{github.user}, which could not be read: install gh (Settings › GitHub)", "the default format's gh login says gh is missing")
	for _, call in w.calls do
		if call.argv[1] == "gh" then
			eq(table.concat(call.argv, " "), "gh --version", "gh is only asked whether it starts")
		end
	end
	-- gh is installed meanwhile: showing its setup page again finds it
	gh.missing = false
	goToSettings(b, "setup-github")
	w.flush()
	eq(prefsOf(b).page, "views", "the setup page gives way to Views")
	yes(rowIn(b, "vadd:github:octocat") ~= nil, "which has the signed-in account's group")
	b.press("escape")
	same(sidebarOf(b), {
		"My PRs @ GitHub - octocat = prs:v1",
		"Review requested @ GitHub - octocat = prs:v2",
		"Assigned to me @ Jira = issues:v1",
	}, "the GitHub views are listed again")
	eq(pickerOf(b).scope, "issues:v1", "the view on screen stays")
	eq(#requestsOf(s.gh, "search"), 0, "and nothing searches GitHub until one is picked")
end)

case("host: with no prompts saved, Settings lists each kind's default prompts, and the first change saves them with it", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "prompts")
	same(hx.rows(b), { "popen:prs:p1", "popen:prs:p2", "popen:prs:p3", "padd:prs", "popen:issues:p1", "popen:issues:p2", "popen:issues:p3", "padd:issues" }, "both kinds list their defaults")
	eq(w.kv.get("prompts-prs"), nil, "showing them saves nothing")
	b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:prs" })
	local saved = w.kv.get("prompts-prs")
	local names: { string } = {}
	for _, p in saved.items do
		table.insert(names, p.name)
	end
	same(names, { "Review", "Address feedback", "Watch", "New action" }, "Add saves the defaults, then the new prompt")
	eq(saved.nextId, 5, "whose id follows theirs")
	has(saved.items[1].text, "Review PR #{number} of {owner}/{repo}", "a default is saved with its text")
	eq(w.kv.get("prompts-issues"), nil, "the issue prompts stay the defaults")
end)

case("host: Restore defaults saves back the default actions no saved one is named like, and a kind with none keeps its title on its buttons", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "My own review"), promptOf("p2", "Mine", "Look at {url}") })
	saveIssuePrompts(w, {})
	local b = openQueue(w)
	goToSettings(b, "prompts")
	same(hx.rows(b), { "popen:prs:p1", "popen:prs:p2", "padd:prs", "prestore:prs", "padd:issues", "prestore:issues" }, "each kind can restore what it lacks")
	eq(sectionIn(b, "padd:issues").title, "Issue actions", "a kind with none saved titles its buttons, so they say whose they are")
	eq(sectionIn(b, "padd:prs").title, nil, "a kind with a list has them under it")
	b.event({ ev = "action", id = "layer.settings", act = "restore-prompts", value = "prestore:prs" })
	local saved = w.kv.get("prompts-prs")
	local names: { string } = {}
	for _, p in saved.items do
		table.insert(names, p.name)
	end
	same(names, { "Review", "Mine", "Address feedback", "Watch" }, "the missing defaults are added after the saved ones")
	eq(saved.items[1].text, "My own review", "an edited default keeps its text")
	same({ saved.items[3].id, saved.items[4].id }, { "p3", "p4" }, "the restored ones take the next ids")
	eq(saved.nextId, 5, "and the next free one follows them")
	same(hx.rows(b), { "popen:prs:p1", "popen:prs:p2", "popen:prs:p3", "popen:prs:p4", "padd:prs", "padd:issues", "prestore:issues" }, "with every default saved, Restore defaults goes")
	eq(prefsOf(b).focus, "padd:prs", "and Add takes the focus")
	eq(#w.kv.get("prompts-issues").items, 0, "the other kind is untouched")
end)

case("host: with neither gh nor acli installed, nothing is listed or asked, and Settings offers both setup guides", function(w: World)
	hostScene(w, 3)
	hx.uninstalled(w, "gh")
	hx.uninstalled(w, "acli")
	local b = openQueue(w)
	eq(#pickerOf(b).scopes, 1, "only the Worktrees board is listed: no view is")
	eq(pickerOf(b).state, "ready", "nothing is loading")
	has(b.text(), "Neither gh nor acli is installed on this host. Press s to set one up.", "the queue says what to do")
	for _, call in w.calls do
		if call.argv[1] == "gh" or call.argv[1] == "acli" then
			eq(call.argv[2], "--version", call.argv[1] .. " is only asked whether it starts")
		end
	end
	goToSettings(b, "setup-jira")
	same(hx.pages(b), { "views", "prompts", "keys", "worktrees", "repos", "connection", "setup-github", "setup-jira" }, "no Jira projects page, and a setup page each")
	b.press("enter")
	eq(w.opened[#w.opened], "https://developer.atlassian.com/cloud/acli/guides/install-acli/", "Jira's opens acli's install guide")
end)

case("host: until the CLIs answer no view is listed or searched, and the restored view is the active one once they do", function(w: World)
	local s = issueHost(w)
	w.respond(function(call: Call): Reply?
		if call.argv[1] == "gh" and call.argv[2] == "--version" then
			return { delay = 1000, stdout = "gh version 2.98.0\n" }
		end
		return nil
	end)
	local b = openIssues(w) -- acli has answered, gh not yet
	eq(#pickerOf(b).scopes, 1, "only the Worktrees board is listed while gh has not answered: no view is")
	eq(pickerOf(b).state, "loading", "the queue is loading")
	eq(#requestsOf(s.gh, "issue-search"), 0, "nothing is searched")
	eq(b.saved().activeViewId, "v1", "the block still saves the view it was restored on")
	eq(b.saved().activeKind, "issues", "with its kind")
	w.advance(1000)
	eq(pickerOf(b).scope, "issues:v1", "once gh answers, the restored view is the active one")
	eq(#requestsOf(s.gh, "issue-search"), 1, "and is searched")
	eq(#listed(b), 3, "its issues are listed")
end)

case("host: Settings › Worktrees lists the three name formats with their defaults, and saves only a format that can name a branch or a folder", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	goToSettings(prs, "worktrees")
	local section = prefsOf(prs).sections[1]
	eq(section.id, "sec-names", "the page's section")
	eq(section.title, "Names", "is the Names one")
	eq(#prefsOf(prs).sections, 1, "and the only one: the worktrees folder is omp's")
	local ids: { string } = {}
	for _, row in section.rows do
		table.insert(ids, row.id)
	end
	same(ids, { "fmt:branch", "fmt:prdir", "fmt:issuedir" }, "its rows: the three formats")
	local expected: { { string } } = {
		{ "fmt:branch", "Issue branch name", "{github.user}/{key}-{slug}", "{key} {slug} {owner} {repo} {project} {github.user} {jira.user}" },
		{ "fmt:prdir", "Pull request folder name", "plotroom-{owner}_{repo}-pr-{key}", "{key} {slug} {owner} {repo}" },
		{ "fmt:issuedir", "Issue folder name", "plotroom-{owner}_{repo}-issue-{key}", "{key} {slug} {owner} {repo}" },
	}
	for _, e in expected do
		local row = rowIn(prs, e[1])
		eq(row.label, e[2], e[1] .. ": label")
		eq(row.control.k, "text", e[1] .. ": a text field")
		eq(row.control.placeholder, e[3], e[1] .. ": the default is its placeholder")
		eq(row.control.value, "", e[1] .. ": nothing is saved")
		eq(row.changed, false, e[1] .. ": so the row is not marked changed")
		eq(row.defaultLabel, e[3], e[1] .. ": and a reset says the default")
		eq(row.hint, e[4], e[1] .. ": the hint lists only the variables the format may name")
	end
	-- a format that cannot name what it is for is refused by name, with the draft kept and nothing saved
	eq(hx.save(prs, "fmt:branch", "{foo}"), "Unknown variable {foo}.", "an unknown variable is refused by name")
	eq(prefsOf(prs).editing.row, "fmt:branch", "the draft stays for a correction")
	eq(hx.save(prs, "fmt:branch", "{foo.bar}/{key}"), "Unknown variable {foo.bar}.", "a dotted one is named whole")
	eq(hx.save(prs, "fmt:branch", "x-{slug}"), "Include {key}, so each issue gets its own branch.", "a branch format without {key} would give every issue one branch")
	eq(w.kv.get("branch-format"), nil, "nothing was saved")
	eq(hx.save(prs, "fmt:branch", "feat/{github.user}-{key}"), nil, "a slash and a user are fine in a branch")
	eq(prefsOf(prs).editing, nil, "a good format closes the edit")
	eq(w.kv.get("branch-format"), "feat/{github.user}-{key}", "and is saved")
	eq(rowIn(prs, "fmt:branch").control.value, "feat/{github.user}-{key}", "the row shows it")
	eq(rowIn(prs, "fmt:branch").changed, true, "as changed")
	eq(rowIn(prs, "fmt:branch").control.placeholder, "{github.user}/{key}-{slug}", "its placeholder is still the default")
	-- a folder name holds neither the branch's users and project nor a slash, and needs {key} in its own words
	eq(hx.save(prs, "fmt:prdir", "{github.user}-{key}"), "Unknown variable {github.user}.", "a folder name has no user")
	eq(hx.save(prs, "fmt:prdir", "{project}-{key}"), "Unknown variable {project}.", "nor a project")
	eq(hx.save(prs, "fmt:prdir", "wt/{key}"), "A folder name holds no /.", "a slash would nest the folder")
	eq(hx.save(prs, "fmt:prdir", "pr-{slug}"), "Include {key}, so each worktree gets its own folder.", "a folder format without {key} would give every pull request one folder")
	eq(hx.save(prs, "fmt:issuedir", "issue-{owner}"), "Include {key}, so each worktree gets its own folder.", "and so would an issue's")
	eq(w.kv.get("pr-dir-format"), nil, "no folder format was saved")
	eq(w.kv.get("issue-dir-format"), nil, "by any of them")
	eq(hx.save(prs, "fmt:prdir", "pr-{key}-{slug}"), nil, "a good folder format is accepted")
	eq(w.kv.get("pr-dir-format"), "pr-{key}-{slug}", "saved for pull requests")
	eq(rowIn(prs, "fmt:prdir").control.value, "pr-{key}-{slug}", "the row shows it")
	eq(rowIn(prs, "fmt:prdir").changed, true, "as changed")
	eq(rowIn(prs, "fmt:prdir").control.placeholder, "plotroom-{owner}_{repo}-pr-{key}", "its placeholder is still the default")
	eq(w.kv.get("issue-dir-format"), nil, "and only for them")
	eq(hx.save(prs, "fmt:issuedir", "{owner}-{repo}-i{key}"), nil, "an issue's folder has its own format")
	eq(w.kv.get("issue-dir-format"), "{owner}-{repo}-i{key}", "saved apart")
	eq(w.kv.get("branch-format"), "feat/{github.user}-{key}", "the branch format is as it was")
	-- an issue filter's pane reads the same formats
	goToSettings(issues, "worktrees")
	eq(rowIn(issues, "fmt:branch").control.value, "feat/{github.user}-{key}", "its page shows the branch format")
	eq(rowIn(issues, "fmt:prdir").control.value, "pr-{key}-{slug}", "the pull request folder format")
	eq(rowIn(issues, "fmt:issuedir").control.value, "{owner}-{repo}-i{key}", "and the issue folder format")
	eq(rowIn(issues, "fmt:issuedir").changed, true, "as changed")
	-- empty text, blank text and Reset go back to the default
	eq(hx.save(prs, "fmt:prdir", ""), nil, "an empty format is accepted")
	eq(w.kv.get("pr-dir-format"), "", "and saves the default")
	eq(rowIn(prs, "fmt:prdir").control.value, "", "the row is empty again")
	eq(rowIn(prs, "fmt:prdir").changed, false, "and unchanged")
	eq(hx.save(prs, "fmt:branch", "   "), nil, "blank text is an empty format too, not a format of blanks")
	eq(w.kv.get("branch-format"), "", "the default again")
	eq(rowIn(prs, "fmt:branch").changed, false, "unchanged")
	eq(hx.reset(prs, "fmt:issuedir"), nil, "Reset takes no warning")
	eq(w.kv.get("issue-dir-format"), "", "it saves the default")
	eq(rowIn(prs, "fmt:issuedir").control.value, "", "the row is empty again")
	eq(rowIn(prs, "fmt:issuedir").changed, false, "and unchanged")
	-- a format that cannot be written says so and keeps its draft; nothing is swallowed
	w.kv.failSet["issue-dir-format"] = "read-only file system"
	eq(hx.save(prs, "fmt:issuedir", "i{key}"), "Could not save: read-only file system", "a failed write is reported under the row")
	eq(prefsOf(prs).editing.draft, "i{key}", "with the draft kept")
	eq(w.kv.get("issue-dir-format"), "", "and the saved format as it was")
	w.kv.failSet["issue-dir-format"] = nil
	prs.press("enter")
	eq(rowIn(prs, "fmt:issuedir").warning, nil, "the retry clears the warning")
	eq(w.kv.get("issue-dir-format"), "i{key}", "and saves the draft")
	w.kv.failSet["issue-dir-format"] = "read-only file system"
	eq(hx.reset(prs, "fmt:issuedir"), "Could not save: read-only file system", "a Reset that cannot be written says so")
	eq(w.kv.get("issue-dir-format"), "i{key}", "and keeps the format")
	eq(rowIn(prs, "fmt:issuedir").changed, true, "which the row still shows")
end)

case("host: the repository's own branch format wins over the Worktrees one for an issue's new branch, and its Reset brings the Worktrees one back", function(w: World)
	local s = issueHost(w)
	table.insert(s.gh.issueItems.octocat, issueItem(15, "o/r", EPOCH - 240, { title = "Ship it" }))
	-- GitHub spells a repository as its owner did: the formats are found whatever the case
	table.insert(s.gh.issueItems.octocat, issueItem(16, "O/R", EPOCH - 300, { title = "Shout" }))
	local b = openIssues(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	eq(rowIn(b, "branch:o/r").control.placeholder, "{github.user}/{key}-{slug}", "the repository's row shows the Worktrees format, the default while none is saved")
	b.event({ ev = "action", id = "layer.settings", act = "page", value = "worktrees" })
	eq(hx.save(b, "fmt:branch", "{key}-{slug}"), nil, "a Worktrees format is saved")
	b.event({ ev = "action", id = "layer.settings", act = "page", value = "repos" })
	local row = rowIn(b, "branch:o/r")
	eq(row.control.placeholder, "{key}-{slug}", "it is now the placeholder of the repository's row")
	eq(row.control.value, "", "which holds none of its own")
	eq(row.changed, false, "so it is not marked changed")
	eq(hx.ask(w, b, "g1", freshAsk("o/r", "12")).vars.branch, "12-fix-login", "an issue's branch follows the Worktrees format")
	eq(hx.save(b, "branch:o/r", "feat/{github.user}-{key}"), nil, "the repository's own format is saved: it may name the gh login, which the Worktrees format does not")
	same(w.kv.get("branch-formats"), { ["o/r"] = "feat/{github.user}-{key}" }, "under the repository, lowercase")
	row = rowIn(b, "branch:o/r")
	eq(row.control.value, "feat/{github.user}-{key}", "the row shows it")
	eq(row.changed, true, "as changed")
	eq(row.control.placeholder, "{key}-{slug}", "its placeholder is still the Worktrees format")
	local a = hx.ask(w, b, "r1", freshAsk("o/r", "13"))
	eq(a.vars.branch, "feat/octocat-13", "the repository's format names the branch, over the Worktrees one")
	eq(a.path, "/wt/plotroom-o_r-issue-13", "in the folder the folder format names")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b feat/octocat-13 /wt/plotroom-o_r-issue-13 " .. sha("b")), 1, "git made that branch")
	a = hx.ask(w, b, "r4", freshAsk("o/r", "16"))
	eq(a.vars.branch, "feat/octocat-16", "an issue whose repository GitHub spells in capitals has the same format")
	eq(a.path, "/wt/plotroom-o_r-issue-16", "and its folder is lowercase")
	eq(w.kv.get("branch-format"), "{key}-{slug}", "the Worktrees format is as it was")
	eq(hx.reset(b, "branch:o/r"), nil, "Reset takes the repository's format away")
	eq(w.kv.get("branch-formats")["o/r"], nil, "from the saved ones")
	row = rowIn(b, "branch:o/r")
	eq(row.control.value, "", "the row is empty again")
	eq(row.changed, false, "and unchanged")
	eq(hx.ask(w, b, "r2", freshAsk("o/r", "14")).vars.branch, "14-docs-typo", "the Worktrees format names the branch again")
	-- formats that cannot be read leave the Worktrees one, and their row locked
	w.kv.put("branch-formats", "garbage")
	b.render()
	has(rowIn(b, "branch:o/r").disabled, "could not be read", "an unreadable map locks the row, saying why")
	eq(hx.ask(w, b, "r3", freshAsk("o/r", "15")).vars.branch, "15-ship-it", "and the Worktrees format applies meanwhile")
	eq(w.kv.get("branch-formats"), "garbage", "the map is never overwritten")
end)

case("host: an issue's new branch is named from the gh login by default, and the login is read only when the format or the prompt needs it", function(w: World)
	local s = issueHost(w)
	-- gh cannot say who is signed in until `healed`: every request that needs the login asks again
	local healed = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" and not healed then
			return { status = 1, stderr = "gh: not logged in\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local function asked(): number
		return #requestsOf(s.gh, "accounts")
	end
	local opened = asked()
	-- a prompt that runs in the main checkout needs no login unless it names one
	local a = hx.ask(w, b, "m1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(a.path, "/work/r", "the main checkout is answered")
	eq(a.vars["github.user"], nil, "with no login among the variables")
	eq(asked(), opened, "gh was not asked who is signed in")
	-- the default format names the login: unreadable, the request is refused and nothing is made
	local before = snapshot(s.git)
	local mark = #w.calls
	a = hx.ask(w, b, "d1", freshAsk("o/r", "12"))
	eq(a.problem, "The branch format names {github.user}, which could not be read: sign in with gh auth login, or change the format in Settings › Repositories.", "the answer says what to do")
	eq(asked(), opened + 1, "gh was asked who is signed in")
	same(ranSince(w, mark), { "gh auth status --hostname github.com --json hosts" }, "and that was the only command: git was never asked anything")
	eq(snapshot(s.git), before, "no branch, worktree or setting was written")
	eq(badgeOf(b), nil, "the row has no Worktree badge")
	eq(hx.ask(w, b, "d2", freshAsk("o/r", "12")).busy, nil, "the refused request left the issue free for the next one")
	-- a format that cannot name a branch is refused for that, and frees the issue the same
	w.kv.put("branch-format", "{github.user}/{foo}")
	eq(hx.ask(w, b, "f1", freshAsk("o/r", "12")).problem, "Unknown variable {foo}.", "a variable there is none of is refused by name")
	eq(hx.ask(w, b, "f2", freshAsk("o/r", "12")).busy, nil, "and the next request finds the issue free")
	-- a format that names no user never asks
	w.kv.put("branch-format", "{key}-{slug}")
	local count = asked()
	a = hx.ask(w, b, "c1", freshAsk("o/r", "12"))
	eq(a.vars.branch, "12-fix-login", "the format names the branch")
	eq(a.path, "/wt/plotroom-o_r-issue-12", "in the issue's folder")
	eq(a.vars["github.user"], nil, "with no login among the variables")
	eq(asked(), count, "gh was not asked who is signed in")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b 12-fix-login /wt/plotroom-o_r-issue-12 " .. sha("b")), 1, "the worktree was made")
	-- the login is the branch's first part once gh can say it
	healed = true
	w.kv.put("branch-format", "")
	a = hx.ask(w, b, "g1", freshAsk("o/r", "13"))
	eq(a.vars.branch, "octocat/13-add-dark-mode", "the default format names the gh login, the key and the title's slug")
	eq(a.path, "/wt/plotroom-o_r-issue-13", "in the issue's folder")
	eq(a.vars["github.user"], "octocat", "the login joins the variables")
	eq(s.git.refs["refs/heads/octocat/13-add-dark-mode"], sha("b"), "git made the branch")
	-- a prompt that names the users gets them whatever the format says
	w.kv.put("branch-format", "{key}-{slug}")
	a = hx.ask(w, b, "u1", { op = "issue", repo = "o/r", ref = "14", worktree = true, fresh = true, base = "main", users = true })
	eq(a.vars.branch, "14-docs-typo", "the format still names the branch")
	eq(a.vars["github.user"], "octocat", "and the login is among the variables the prompt asked for")
	a = hx.ask(w, b, "u2", { op = "issue", repo = "o/r", ref = "12", worktree = false, users = true })
	eq(a.path, "/work/r", "so it is for a prompt that runs in the main checkout")
	eq(a.vars["github.user"], "octocat", "which gets the login too")
end)

case("host: {github.user} is the login the view runs as, and gh's active one for a view with none", function(w: World)
	local s = issueHost(w)
	s.gh.tokens.work = "tok-work"
	s.gh.issueItems.work = { issueItem(12, "o/r", EPOCH - 60, { title = "Fix login" }) }
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Work", integration = "github", query = "is:open", logins = array({ "work" }), group = "none", prompts = array({}) },
	}) })
	local work = openIssues(w, 1)
	eq(hx.ask(w, work, "w1", freshAsk("o/r", "12")).vars.branch, "work/12-fix-login", "a view that runs as work names work, not gh's active login")
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local mine = openIssues(w, 2)
	eq(hx.ask(w, mine, "m1", freshAsk("o/r", "13")).vars.branch, "octocat/13-add-dark-mode", "a view with no login runs as gh's active one")
end)

case("host: a Jira issue's branch can name {jira.user}, the sign-in's email before the @", function(w: World)
	local s = jiraHost(w)
	w.kv.put("branch-format", "{jira.user}/{key}-{slug}")
	local b = openIssues(w)
	local a = hx.ask(w, b, "j1", freshAsk("ABC", "ABC-12"))
	eq(a.vars.branch, "ann/ABC-12-fix-login", "the format names the email's local part, the key and the title's slug")
	eq(a.path, "/wt/plotroom-o_r-issue-ABC-12", "in the issue's folder")
	eq(a.vars["jira.user"], "ann", "the Jira user joins the variables")
	eq(s.git.refs["refs/heads/ann/ABC-12-fix-login"], sha("b"), "git made the branch")
	-- a format that names no user reads none unless the prompt asks for them
	w.kv.put("branch-format", "{key}-{slug}")
	a = hx.ask(w, b, "j2", freshAsk("ABC", "ABC-13"))
	eq(a.vars.branch, "ABC-13-old-bug", "the format names the branch")
	eq(a.vars["jira.user"], nil, "with no Jira user among the variables")
	eq(a.vars["github.user"], nil, "nor a gh login")
	a = hx.ask(w, b, "j3", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = true })
	eq(a.path, "/work/r", "a prompt that runs in the main checkout")
	eq(a.vars["jira.user"], "ann", "gets the Jira user when it asks")
	eq(a.vars["github.user"], "octocat", "and the gh login")
end)

case("host: a branch format naming {jira.user} is refused while the sign-in names no email, and nothing is made", function(w: World)
	local s = jiraHost(w)
	-- an API token's sign-in has no email to take the user from
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = "✓ Authenticated\n  Site: acme.atlassian.net\n  Authentication Type: api_token\n" }
		end
		return nil
	end
	w.kv.put("branch-format", "{jira.user}/{key}-{slug}")
	local b = openIssues(w)
	local before = snapshot(s.git)
	local mark = #w.calls
	local a = hx.ask(w, b, "t1", freshAsk("ABC", "ABC-12"))
	eq(a.problem, "The branch format names {jira.user}, which could not be read: sign in with acli jira auth login, or change the format in Settings › Repositories.", "the answer says what to do")
	eq(snapshot(s.git), before, "no branch or worktree was made")
	for _, line in ranSince(w, mark) do
		lacks(line, "worktree add", "no worktree was added: " .. line)
	end
	eq(cardOf(b), nil, "no worktree is noted: the issue has no card")
	eq(hx.ask(w, b, "t2", freshAsk("ABC", "ABC-12")).busy, nil, "the refused request left the issue free for the next one")
	w.kv.put("branch-format", "")
	eq(hx.ask(w, b, "t3", freshAsk("ABC", "ABC-12")).vars.branch, "octocat/ABC-12-fix-login", "a format that names no Jira user does not need one")
end)

case("host: a map-jira request naming something other than owner/name is answered with a problem, not left to time out", function(w: World)
	hostScene(w, 1)
	local b = openQueue(w)
	eq(hx.ask(w, b, "j1", { op = "map-jira", project = "ABC", repo = "github.com/o/r" }).problem, "Type it as owner/name.", "the typed text is refused with what to type")
	eq(w.kv.get("jira-repos"), nil, "and nothing is saved")
end)

case("host: a pull request worktree request answers the gh login only when it asks for it, and still makes the worktree when gh cannot say it", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local healed = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" and not healed then
			return { status = 1, stderr = "gh: not logged in\n" }
		end
		return nil
	end
	local b = openQueue(w)
	local count = #requestsOf(s.gh, "accounts")
	local a = hx.ask(w, b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	eq(a.path, "/wt/plotroom-o_r-pr-1", "the worktree is made")
	eq(a["github.user"], nil, "with no login in the answer")
	eq(#requestsOf(s.gh, "accounts"), count, "gh was not asked who is signed in")
	a = hx.ask(w, b, "a2", { op = "worktree", repo = "o/r", number = 1, users = true })
	eq(a.path, "/wt/plotroom-o_r-pr-1", "a login that cannot be read does not stop the worktree")
	eq(a["github.user"], "", "the answer says it is unknown")
	eq(#requestsOf(s.gh, "accounts"), count + 1, "gh was asked who is signed in")
	healed = true
	a = hx.ask(w, b, "a3", { op = "worktree", repo = "o/r", number = 1, users = true })
	eq(a["github.user"], "octocat", "the answer carries the login once gh says it")
	a = hx.ask(w, b, "a4", { op = "worktree", repo = "o/r", number = 1, users = "yes" })
	eq(a["github.user"], nil, "only true asks for it")
	request(b, "a5", { op = "worktree", repo = "o/r", number = 1, users = true })
	request(b, "a6", { op = "worktree", repo = "o/r", number = 1 })
	eq(answerOf(b, "a6").busy, true, "a repeat while the login is read is told the worktree is busy")
	w.flush()
	eq(answerOf(b, "a5")["github.user"], "octocat", "the first request is answered with it")
end)

case("host: an issue worktree request with nothing decided asks gh for the linked pull requests and, with none still on a branch, offers the remote's branches for a new one", function(w: World)
	local s = issueHost(w)
	s.git.served["refs/heads/zeta"] = sha("c")
	s.git.served["refs/heads/alpha"] = sha("d")
	s.git.served["refs/heads/dev/x"] = sha("e")
	-- #13's only linked pull request lost its branch
	s.gh.linked["o/r#13"] = array({ hx.linkedPr(s, 40, "Old try", "old-try", false) })
	local b = openIssues(w)
	local before = snapshot(s.git)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	same(a, { chooseBase = true, branch = "octocat/12-fix-login", branches = { "main", "alpha", "dev/x", "zeta" } }, "the new branch's name, and the remote's branches to start it from: the default one first, then by name")
	local linked = requestsOf(s.gh, "linked")
	eq(#linked, 1, "gh was asked once for the linked pull requests")
	same({ linked[1].fields.o, linked[1].fields.r, linked[1].fields.n }, { "o", "r", "12" }, "of o/r#12")
	eq(countLog(s.git, "ls-remote --symref origin HEAD refs/heads/*"), 1, "and git once for the remote's branches")
	eq(snapshot(s.git), before, "nothing was made")
	eq(badgeOf(b), nil, "the row has no Worktree badge")
	-- a pull request that lost its branch is no pull request to work on
	a = hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "13", worktree = true })
	same(a, { chooseBase = true, branch = "octocat/13-add-dark-mode", branches = { "main", "alpha", "dev/x", "zeta" } }, "an issue whose only pull request lost its branch gets the same question")
	linked = requestsOf(s.gh, "linked")
	eq(#linked, 2, "gh was asked for its pull requests too")
	eq(linked[2].fields.n, "13", "by its number")
	-- the list is cut to fit the window's read
	for i = 1, 3000 do
		s.git.served["refs/heads/release/candidate-" .. string.format("%04d", i)] = sha("e")
	end
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "14", worktree = true })
	eq(a.chooseBase, true, "an issue with many branches around is asked the same")
	eq(a.branches[1], "main", "the default branch is still first")
	yes(#a.branches > 100 and #a.branches < 3000, "the list is cut, not dropped: " .. #a.branches)
	yes(#jsonEncode(a) < 64000, "to fit the window's 64000-character read")
end)

case("host: an issue with exactly one linked pull request still on its branch is worked on that branch, asking nothing", function(w: World)
	local s = issueHost(w)
	s.gh.linked["o/r#12"] = array({ hx.linkedPr(s, 45, "Fix the login redirect", "fix-login", true), hx.linkedPr(s, 40, "Old try", "old-try", false) })
	local b = openIssues(w)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.path, "/wt/plotroom-o_r-issue-12", "the worktree is in the issue's folder")
	eq(a.created, true, "created")
	eq(a.vars.branch, "fix-login", "on the pull request's own branch, not a new one")
	eq(a.summary, "Created · fix-login at ccccccc · Clean", "at the pull request's head")
	eq(#requestsOf(s.gh, "linked"), 1, "gh was asked for the linked pull requests once")
	eq(countLog(s.git, "ls-remote"), 0, "no branch was offered")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b fix-login /wt/plotroom-o_r-issue-12 " .. sha("c")), 1, "git made the worktree on that branch")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], nil, "the issue's own branch was not made")
	eq(s.git.config["branch.fix-login.remote"], "origin", "the new branch tracks the remote")
	eq(s.git.config["branch.fix-login.merge"], "refs/heads/fix-login", "and the pull request's branch there")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-45"], sha("c"), "the pull request's head was fetched into Plotroom's own ref")
	has(cardText(b), "/wt/plotroom-o_r-issue-12", "the worktree is noted: its card says where it is")
	eq(findKey(findKey(cardOf(b), "wbranch"), "v").p.spans[1].t, "fix-login", "the card shows the pull request's branch")
	-- removing it takes the pull request's fetched ref with it
	local mark = #s.git.log
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree remove /wt/plotroom-o_r-issue-12",
		"merge-base --is-ancestor refs/heads/fix-login refs/plotroom-pr/o/r/pr-45",
		"branch -D fix-login",
		"update-ref -d refs/plotroom-pr/o/r/pr-45",
		"worktree list --porcelain -z",
	}, "the worktree, then the branch the fetched ref holds in full, then the ref, then a read of the checkout")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-45"], nil, "the ref is gone")
end)

case("host: an issue with several linked pull requests asks which one, and the window's answers decide the rounds that follow", function(w: World)
	local s = issueHost(w)
	s.git.served["refs/heads/dev"] = sha("e")
	local prs = {
		hx.linkedPr(s, 45, "Fix the login redirect", "fix-login", true),
		hx.linkedPr(s, 40, "Old try", "old-try", false),
		hx.linkedPr(s, 46, "Second\ntry " .. string.rep("x", 200), "second", true),
	}
	s.gh.linked["o/r#12"] = array(prs)
	s.gh.linked["o/r#13"] = array(prs)
	local b = openIssues(w)
	local before = snapshot(s.git)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.choosePr, true, "the window is asked which pull request")
	same(a.prs, {
		{ number = 45, title = "Fix the login redirect", branch = "fix-login" },
		{ number = 46, title = "Second try " .. string.rep("x", 149) .. "…", branch = "second" },
	}, "in gh's order, without the one whose branch is gone, each title on one line and cut at 160 characters")
	eq(snapshot(s.git), before, "nothing was made")
	eq(countLog(s.git, "ls-remote"), 0, "and no branch was offered yet")
	eq(cardOf(b), nil, "nor noted: the issue has no card")
	eq(hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true }).choosePr, true, "an open question is not busy: asked again, it is the same question")
	-- the pull request picked: its branch, with no second look at the linked ones
	local looked = #requestsOf(s.gh, "linked")
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true, pr = 46 })
	eq(a.vars.branch, "second", "the worktree is on the picked pull request's branch")
	eq(a.path, "/wt/plotroom-o_r-issue-12", "in the issue's folder")
	eq(#requestsOf(s.gh, "linked"), looked, "gh was not asked about the linked pull requests again")
	-- New branch… is the picker's other answer: fresh, then the base the remote's branches offer
	a = hx.ask(w, b, "b1", { op = "issue", repo = "o/r", ref = "13", worktree = true })
	eq(a.choosePr, true, "another issue with the same pull requests is asked too")
	a = hx.ask(w, b, "b2", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true })
	same(a, { chooseBase = true, branch = "octocat/13-add-dark-mode", branches = { "main", "dev", "fix-login", "second" } }, "a new branch asks which branch to start from: the remote's, the default one first")
	eq(#requestsOf(s.gh, "linked"), looked + 1, "without asking gh about the linked pull requests again")
	eq(hx.ask(w, b, "b3", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true }).chooseBase, true, "an open question is not busy either")
	request(b, "b4", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true, base = "dev" })
	request(b, "b5", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true, base = "dev" })
	eq(answerOf(b, "b5").busy, true, "while the worktree is being made a repeat is told so")
	w.flush()
	a = answerOf(b, "b4")
	eq(a.vars.branch, "octocat/13-add-dark-mode", "the branch is the issue's own")
	eq(a.summary, "Created · octocat/13-add-dark-mode at eeeeeee · Clean", "started at the base picked")
	eq(hx.ask(w, b, "b6", { op = "issue", repo = "o/r", ref = "13", worktree = true }).created, false, "and once it exists the issue asks nothing: its worktree is reused")
end)

case("host: an issue stays busy while gh reads its linked pull requests and git the remote's branches, and is free once the question is asked", function(w: World)
	local s = issueHost(w)
	local slow = 0 -- how long gh takes to list the linked pull requests, and git the remote's branches
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" and slow > 0 then
			return { stdout = "[]", delay = slow }
		end
		return nil
	end
	local branches = "ref: refs/heads/main\tHEAD\n" .. sha("b") .. "\tHEAD\n" .. sha("b") .. "\trefs/heads/main\n"
	w.respond(function(call: Call): Reply?
		if slow > 0 and call.argv[4] == "ls-remote" then
			return { stdout = branches, delay = slow }
		end
		return nil
	end)
	local b = openIssues(w)
	slow = 4000
	request(b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	w.advance(1000)
	eq(answerOf(b, "a1"), nil, "gh is still listing the linked pull requests: nothing is answered yet")
	request(b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(answerOf(b, "a2").busy, true, "a repeat meanwhile is told the issue is busy")
	w.advance(4000)
	eq(answerOf(b, "a1"), nil, "git is now listing the remote's branches: still nothing is answered")
	request(b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(answerOf(b, "a3").busy, true, "a repeat meanwhile is busy too")
	w.advance(4000)
	same(answerOf(b, "a1"), { chooseBase = true, branch = "octocat/12-fix-login", branches = { "main" } }, "the question is asked once both reads are over")
	slow = 0
	local a = hx.ask(w, b, "a4", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.busy, nil, "with the question on screen the issue is free: a new request asks it again")
	eq(a.chooseBase, true, "and gets it")
end)

case("host: an issue worktree request that names its pull request, or a new branch's base, asks neither gh nor the remote anything", function(w: World)
	local s = issueHost(w)
	s.git.served["refs/heads/dev"] = sha("e")
	hx.linkedPr(s, 46, "Second", "second", true)
	local b = openIssues(w)
	local a = hx.ask(w, b, "p1", { op = "issue", repo = "o/r", ref = "12", worktree = true, pr = 46 })
	eq(a.vars.branch, "second", "pr: the worktree is on that pull request's branch")
	eq(a.path, "/wt/plotroom-o_r-issue-12", "in the issue's folder")
	eq(#requestsOf(s.gh, "pr"), 1, "gh was asked for that pull request")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b second /wt/plotroom-o_r-issue-12 " .. sha("c")), 1, "git made the worktree on its branch, at its head")
	eq(#requestsOf(s.gh, "linked"), 0, "it was not asked for the linked pull requests")
	eq(countLog(s.git, "ls-remote"), 0, "nor for the remote's branches")
	a = hx.ask(w, b, "f1", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true, base = "dev" })
	eq(a.vars.branch, "octocat/13-add-dark-mode", "fresh: the worktree is on a new branch of the issue's own")
	eq(a.summary, "Created · octocat/13-add-dark-mode at eeeeeee · Clean", "started at the base's tip, not the default branch's")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/dev:refs/remotes/origin/dev"), 1, "the base was fetched into its remote-tracking ref")
	eq(s.git.refs["refs/heads/octocat/13-add-dark-mode"], sha("e"), "the branch starts there")
	eq(#requestsOf(s.gh, "linked"), 0, "gh was still not asked for the linked pull requests")
	eq(countLog(s.git, "ls-remote"), 0, "nor git for the remote's branches")
	-- a base the remote does not have makes nothing
	local before = snapshot(s.git)
	a = hx.ask(w, b, "f2", { op = "issue", repo = "o/r", ref = "14", worktree = true, fresh = true, base = "nope" })
	has(a.problem, "nope", "the answer names the base")
	eq(snapshot(s.git), before, "no branch or worktree was made")
	eq(hx.ask(w, b, "w14", { op = "where", kind = "issue", key = "o/r#14" }).path, nil, "and none is noted")
end)

case("host: an issue whose worktree exists is reused whatever else the request says: no question, no pull request read", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	eq(hx.ask(w, b, "a1", freshAsk("o/r", "12")).created, true, "the worktree is made")
	-- pull requests that would ask a question if there were no worktree
	s.gh.linked["o/r#12"] = array({ hx.linkedPr(s, 45, "Fix the login redirect", "fix-login", true), hx.linkedPr(s, 46, "Second", "second", true) })
	local mark = #w.calls
	local a = hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.created, false, "the worktree is reused")
	eq(a.summary, "Reused · octocat/12-fix-login at bbbbbbb · Clean", "and the answer says so")
	eq(a.vars.branch, "octocat/12-fix-login", "on the branch it has")
	eq(a.choosePr, nil, "no pull request is asked for")
	eq(#requestsOf(s.gh, "linked"), 0, "gh was not asked for the linked pull requests")
	eq(countLog(s.git, "ls-remote"), 0, "nor git for the remote's branches")
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true, pr = 46 })
	eq(a.created, false, "a pull request named in the request does not move it")
	eq(a.vars.branch, "octocat/12-fix-login", "it stays on its branch")
	eq(#requestsOf(s.gh, "pr"), 0, "and the pull request was not read")
	a = hx.ask(w, b, "a4", { op = "issue", repo = "o/r", ref = "12", worktree = true, fresh = true, base = "dev" })
	eq(a.created, false, "nor does a base")
	eq(countLog(s.git, "worktree add"), 1, "the worktree was made once")
	for _, line in ranSince(w, mark) do
		lacks(line, "gh api", "gh was not asked anything: " .. line)
		lacks(line, "fetch", "nothing was fetched: " .. line)
	end
end)

case("host: an issue worktree request whose linked pull requests cannot be read says so, makes nothing and leaves the issue free for a retry", function(w: World)
	local s = issueHost(w)
	local failing = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" and failing then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local before = snapshot(s.git)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	has(a.problem, "The pull requests linked to #12 could not be read: ", "the answer says what failed")
	has(a.problem, "Server Error (HTTP 502)", "with gh's reason")
	eq(snapshot(s.git), before, "no branch or worktree was made")
	eq(cardOf(b), nil, "none is noted: the issue has no card")
	eq(countLog(s.git, "ls-remote"), 0, "and no branch was offered")
	a = hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.busy, nil, "the failed request left the issue free for the next one")
	has(a.problem, "could not be read", "which is refused for the same reason")
	eq(#requestsOf(s.gh, "linked"), 2, "after asking gh again")
	failing = false
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.chooseBase, true, "once gh answers, the question is asked")
end)

case("host: a Jira issue's linked pull requests are those a search for its key finds, and the choices work as for a GitHub issue", function(w: World)
	local s = jiraHost(w)
	local acliItems = s.acli.searches[JIRA_ASSIGNED]
	table.insert(acliItems, jiraItem("ABC-14", "Third thing"))
	-- ABC-12 is only named by ABC-123's pull request; ABC-13 has its own and ABC-130's; ABC-14 has two
	s.gh.linked["o/r#ABC-12"] = array({ hx.linkedPr(s, 50, "ABC-123 another thing", "abc-123-other", true) })
	s.gh.linked["o/r#ABC-13"] = array({
		hx.linkedPr(s, 51, "ABC-13 fix the bug", "abc-13-fix", true),
		hx.linkedPr(s, 52, "ABC-130 something else", "abc-130-else", true),
	})
	s.gh.linked["o/r#ABC-14"] = array({
		hx.linkedPr(s, 53, "ABC-14 first try", "abc-14-first", true),
		hx.linkedPr(s, 54, "[ABC-14] second try", "abc-14-second", true),
	})
	local b = openIssues(w)
	local a = hx.ask(w, b, "j1", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true })
	eq(a.chooseBase, true, "a key that only a longer key's pull request names has none: a new branch is asked for")
	eq(a.branch, "octocat/ABC-12-fix-login", "named from the gh login, the key and the title's slug")
	local linked = requestsOf(s.gh, "linked")
	eq(#linked, 1, "gh was asked once")
	eq(linked[1].fields.q, "repo:o/r is:pr ABC-12", "to search the repository's pull requests for the key")
	eq(linked[1].fields.o, nil, "not for an issue's closing references")
	a = hx.ask(w, b, "j2", { op = "issue", repo = "ABC", ref = "ABC-13", worktree = true })
	eq(a.vars.branch, "abc-13-fix", "the one pull request that names the key is worked on, asking nothing")
	eq(a.path, "/wt/plotroom-o_r-issue-ABC-13", "in the issue's folder")
	eq(s.git.refs["refs/heads/abc-13-fix"], sha("c"), "on its branch")
	request(b, "w1", { op = "where", kind = "issue", key = "abc#ABC-13" })
	eq(answerOf(b, "w1").path, "/wt/plotroom-o_r-issue-ABC-13", "the worktree is noted under the project's lowercase key")
	a = hx.ask(w, b, "j3", { op = "issue", repo = "ABC", ref = "ABC-14", worktree = true })
	same(a.prs, {
		{ number = 53, title = "ABC-14 first try", branch = "abc-14-first" },
		{ number = 54, title = "[ABC-14] second try", branch = "abc-14-second" },
	}, "two pull requests are asked about")
	eq(hx.ask(w, b, "j4", { op = "issue", repo = "ABC", ref = "ABC-14", worktree = true, pr = 54 }).vars.branch, "abc-14-second", "the one picked decides")
	eq(#requestsOf(s.gh, "linked"), 3, "a request that names its pull request searches no more")
	a = hx.ask(w, b, "j5", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true, fresh = true, base = "main" })
	eq(a.vars.branch, "octocat/ABC-12-fix-login", "a request that names its base makes the issue's own branch")
	eq(#requestsOf(s.gh, "linked"), 3, "without a search either")
end)

case("host: an issue request with a pull request or base it cannot use is dropped, and one with a fresh or users that is no boolean has them ignored", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, extra: { [string]: any })
		local body: { [string]: any } = { id = "m1", op = "issue", repo = "o/r", ref = "12", worktree = true }
		for k, v in extra do
			body[k] = v
		end
		b.event({ ev = "action", act = "rpc", value = jsonEncode(body) })
		w.flush()
		eq(answerOf(b, "m1"), nil, what .. ": no answer is kept")
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	local prs: { any } = { 0, -1, 1.5, "7", 2147483648, true }
	for _, pr in prs do
		ignored("the pull request " .. show(pr), { pr = pr })
	end
	local bases: { any } = { "-x", "a b", "a\nb", "a\tb", string.rep("a", 256), 5, true }
	for _, base in bases do
		ignored("the base " .. show(base), { fresh = true, base = base })
	end
	-- the largest ones that are fine
	local a = hx.ask(w, b, "k1", { op = "issue", repo = "o/r", ref = "12", worktree = false, pr = 2147483647, base = string.rep("a", 255) })
	eq(a.path, "/work/r", "a pull request number of 2147483647 and a base of 255 bytes are answered")
	-- a fresh that is not true is no fresh, a users that is not true asks for no users
	a = hx.ask(w, b, "k2", { op = "issue", repo = "o/r", ref = "12", worktree = true, fresh = "yes", base = "main" })
	eq(a.chooseBase, true, "fresh = \"yes\" is no fresh: the linked pull requests decide, and with none a base is asked for")
	eq(#requestsOf(s.gh, "linked"), 1, "gh was asked for them")
	a = hx.ask(w, b, "k3", { op = "issue", repo = "o/r", ref = "12", worktree = false, users = "yes" })
	eq(a.path, "/work/r", "the main checkout is answered")
	eq(a.vars["github.user"], nil, "users = \"yes\" asks for no login")
end)

case("host: where answers the worktree a block knows for a pull request or an issue, from its own attempt or from git, until the worktree is removed", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	local other = openQueue(w, 3)
	local asked = 0
	-- The folder block `b` says the worktree of item `key` of `kind` is in; nil when it knows none.
	local function where(b: Block, kind: string, key: string): string?
		asked += 1
		request(b, "w" .. asked, { op = "where", kind = kind, key = key })
		local a = answerOf(b, "w" .. asked)
		yes(a ~= nil, "where was answered")
		return a.path
	end
	eq(where(prs, "pr", "o/r#1"), nil, "a pull request with no worktree has no path")
	eq(where(issues, "issue", "o/r#12"), nil, "nor does an issue")
	eq(hx.ask(w, prs, "p1", { op = "worktree", repo = "o/r", number = 1 }).path, "/wt/plotroom-o_r-pr-1", "a pull request's worktree is made")
	eq(where(prs, "pr", "o/r#1"), "/wt/plotroom-o_r-pr-1", "its block says where it is")
	eq(where(other, "pr", "o/r#1"), nil, "another block of the host has not heard of it")
	refreshNow(w, other)
	eq(where(other, "pr", "o/r#1"), "/wt/plotroom-o_r-pr-1", "until its next refresh reads the checkout from git")
	eq(hx.ask(w, issues, "i1", freshAsk("o/r", "12")).path, "/wt/plotroom-o_r-issue-12", "an issue's worktree is made")
	eq(where(issues, "issue", "o/r#12"), "/wt/plotroom-o_r-issue-12", "its block says where it is")
	eq(where(prs, "pr", "o/r#7"), nil, "an item with none has no path, whoever asks")
	-- removing a worktree forgets it, for every block
	showPr(prs, 1)
	pressCard(prs, "remove")
	prs.typeText("d")
	w.flush()
	eq(where(prs, "pr", "o/r#1"), nil, "a removed pull request worktree has no path")
	eq(where(other, "pr", "o/r#1"), nil, "for another block too")
	eq(where(issues, "issue", "o/r#12"), "/wt/plotroom-o_r-issue-12", "the issue's is still there")
	pressCard(issues, "remove")
	issues.typeText("d")
	w.flush()
	eq(where(issues, "issue", "o/r#12"), nil, "until it is removed too")
end)

case("host: a where request with a kind or key it cannot use is dropped", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, body: { [string]: any })
		body.id, body.op = "m1", "where"
		b.event({ ev = "action", act = "rpc", value = jsonEncode(body) })
		w.flush()
		eq(answerOf(b, "m1"), nil, what .. ": no answer is kept")
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	ignored("a kind that is neither", { kind = "commit", key = "o/r#12" })
	ignored("no kind", { key = "o/r#12" })
	ignored("a key that is no text", { kind = "pr", key = 5 })
	ignored("a key over 200 bytes", { kind = "pr", key = string.rep("k", 201) })
	request(b, "k1", { op = "where", kind = "pr", key = string.rep("k", 200) })
	eq(answerOf(b, "k1").path, nil, "a key of 200 bytes is answered")
end)

case("host: the In tab badge follows the panes working in a worktree the block knows, whatever its folder is called, and marks no other row", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60), searchItem(2, "o/r", EPOCH - 120), searchItem(12, "o/r", EPOCH - 180) }
	s.gh.issueItems.octocat = { issueItem(2, "o/r", EPOCH - 60, { title = "Second" }), issueItem(12, "o/r", EPOCH - 120, { title = "Fix login" }) }
	s.git.served["refs/pull/2/head"] = sha("b")
	s.gh.meta["o/r#2"] = { base = "o/r", sha = sha("b"), ref = "second", headRepo = "o/r", headOwner = "o", state = "open", title = "Second" }
	-- Worktrees git lists: PRs 1 and 12 in their folders, and issue 2 in a folder of its own, on the branch the format names
	-- (it names no user, so the block needs no sign-in to know it).
	w.kv.put("branch-format", "{key}-{slug}")
	leaveWt(w, s, 1)
	leaveWt(w, s, 12)
	table.insert(s.git.worktrees, { path = "/wt/custom-name", branch = "refs/heads/2-second", head = sha("b"), locked = false })
	w.fs.dirs["/wt/custom-name"] = true
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	-- Puts a pane working in `cwd` on the host, draws both panes and says which rows wear In tab: the PRs', then the issues'.
	local nextPane = 8
	local function working(cwd: string): { { string } }
		nextPane += 1
		table.insert(w.panes, { pane = nextPane, cwd = cwd })
		prs.render()
		issues.render()
		return { hx.inTab(prs), hx.inTab(issues) }
	end
	prs.render()
	issues.render()
	same({ hx.inTab(prs), hx.inTab(issues) }, { {}, {} }, "no pane in a worktree, no badge")
	same(working("/wt/plotroom-o_r-pr-12/src"), { { "no_2fr_2312" }, {} }, "a pane in a folder of pull request 12's worktree marks it; not 1, whose folder's name starts the same, nor issue 12")
	same(working("/wt/custom-name"), { { "no_2fr_2312" }, { "no_2fr_232" } }, "a pane in issue 2's worktree marks the issue whatever the folder is called; not pull request 2")
	same(working("/wt/plotroom-o_r-pr-1"), { { "no_2fr_231", "no_2fr_2312" }, { "no_2fr_232" } }, "a pane in the worktree itself marks it")
	same(working("/work/r"), { { "no_2fr_231", "no_2fr_2312" }, { "no_2fr_232" } }, "a pane elsewhere marks nothing")
	for _ = 1, 4 do
		table.remove(w.panes)
	end
	prs.render()
	issues.render()
	same({ hx.inTab(prs), hx.inTab(issues) }, { {}, {} }, "with the panes gone, so are the badges")
	-- a worktree made now is found by its noted folder, however the formats named it
	w.kv.put("pr-dir-format", "p{key}")
	w.kv.put("issue-dir-format", "i{key}-{slug}")
	eq(hx.ask(w, prs, "p2", { op = "worktree", repo = "o/r", number = 2 }).path, "/wt/p2", "a pull request's folder is named by its format")
	eq(hx.ask(w, issues, "i12", freshAsk("o/r", "12")).path, "/wt/i12-fix-login", "an issue's too")
	same(working("/wt/p2/src"), { { "no_2fr_232" }, {} }, "a pane in the pull request's folder marks it")
	same(working("/wt/i12-fix-login"), { { "no_2fr_232" }, { "no_2fr_2312" } }, "and one in the issue's marks the issue")
end)

case("host: a worktree noted for a pull request that left the list is still known, by its own branch and folder, until git no longer lists it", function(w: World)
	local s = hostScene(w, 2)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local asked = 0
	local function where(): string?
		asked += 1
		return hx.ask(w, b, "w" .. asked, { op = "where", kind = "pr", key = "o/r#1" }).path
	end
	eq(hx.ask(w, b, "p1", { op = "worktree", repo = "o/r", number = 1 }).path, "/wt/plotroom-o_r-pr-1", "a pull request's worktree is made")
	-- pull request 1 is merged: the next refresh lists pull request 2 only
	s.gh.items.octocat = { s.gh.items.octocat[2] }
	refreshNow(w, b)
	eq(#listed(b), 1, "the list holds one pull request now")
	eq(where(), "/wt/plotroom-o_r-pr-1", "the one that left is still known: git lists its worktree on the branch and in the folder the note says")
	table.remove(s.git.worktrees, 2)
	w.fs.dirs["/wt/plotroom-o_r-pr-1"] = nil
	refreshNow(w, b)
	eq(where(), nil, "until git no longer lists it")
end)

case("host: after a format changes, the block that made an issue's worktree still knows it by the branch and folder it noted, and a block that did not cannot", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	eq(hx.ask(w, b, "i1", freshAsk("o/r", "12")).path, "/wt/plotroom-o_r-issue-12", "an issue's worktree is made under the default formats")
	yes(cardOf(b) ~= nil, "its card shows")
	w.kv.put("branch-format", "{key}")
	w.kv.put("issue-dir-format", "i{key}")
	refreshNow(w, b)
	has(cardText(b), "/wt/plotroom-o_r-issue-12", "neither format names it now, and it is still known: by what its note says it was made on")
	local fresh = openIssues(w, 2)
	eq(cardOf(fresh), nil, "a block with no note of it cannot tell it from any other worktree")
end)

case("host: the issue preview's Branch row shows the real branch as soon as gh names its login, and the format's variable as written until then", function(w: World)
	local s = issueHost(w)
	local signedIn = false
	s.gh.override = function(req: GhReq): Reply?
		return if req.kind == "accounts" and not signedIn then { status = 1, stderr = "gh: not logged in\n" } else nil
	end
	local b = openIssues(w)
	eq(hx.branchRow(b), "{github.user}/12-fix-login", "gh named no login: the format's variable shows as written")
	signedIn = true
	hx.ask(w, b, "m1", { op = "issue", repo = "o/r", ref = "12", worktree = false, users = true })
	eq(hx.branchRow(b), "octocat/12-fix-login", "once gh named it the row shows the branch a worktree would make")
	w.kv.put("branch-formats", { ["o/r"] = "feat/{github.user}-{key}" })
	b.render()
	eq(hx.branchRow(b), "feat/octocat-12", "the repository's own format shows through, and wins")
	w.kv.put("branch-formats", { ["o/r"] = "{key}-{slug}" })
	b.render()
	eq(hx.branchRow(b), "12-fix-login", "whatever it names")
	w.kv.put("branch-formats", {})
	w.kv.put("branch-format", "{owner}/{repo}/{key}")
	b.render()
	eq(hx.branchRow(b), "o/r/12", "without one the Worktrees format shows")
	w.kv.put("branch-format", "{foo}")
	b.render()
	eq(hx.branchRow(b), nil, "a format that cannot name a branch shows none")
end)

case("host: a Jira issue's preview fills {jira.user} from the sign-in its search read and {github.user} from gh's active login", function(w: World)
	jiraHost(w)
	w.kv.put("branch-format", "{jira.user}/{github.user}/{key}")
	local b = openIssues(w)
	eq(hx.branchRow(b), "ann/octocat/ABC-12", "both users are known once the list loaded")
end)

case("host: the saved folder formats name the folders of pull request and issue worktrees, and a format that renders no usable folder says so", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 2)
	table.insert(s.gh.issueItems.octocat, issueItem(16, "o/r", EPOCH - 300, { title = string.rep("word ", 30) }))
	for n = 1, 2 do
		s.git.served["refs/pull/" .. n .. "/head"] = sha("b")
		s.gh.meta["o/r#" .. n] = { base = "o/r", sha = sha("b"), ref = "feature-" .. n, headRepo = "o/r", headOwner = "o", state = "open", title = if n == 1 then "Add a feature" else string.rep("word ", 30) }
	end
	w.kv.put("pr-dir-format", "{owner}-{repo}-p{key}-{slug}")
	w.kv.put("issue-dir-format", "i{key}-{slug}")
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	local a = hx.ask(w, prs, "p1", { op = "worktree", repo = "o/r", number = 1 })
	eq(a.path, "/wt/o-r-p1-add-a-feature", "a pull request's folder is named by its format: owner, repository, number and the title's slug")
	a = hx.ask(w, issues, "i1", freshAsk("o/r", "12"))
	eq(a.path, "/wt/i12-fix-login", "an issue's by its own: the key and the title's slug")
	eq(hx.ask(w, prs, "p2", { op = "worktree", repo = "o/r", number = 1 }).created, false, "the folder is found again by that name")
	eq(hx.ask(w, issues, "i2", freshAsk("o/r", "12")).created, false, "so is the issue's")
	-- a title long enough to make the format render a name no folder can have
	local tooLong = string.rep("{slug}", 6) .. "-{key}"
	w.kv.put("pr-dir-format", tooLong)
	w.kv.put("issue-dir-format", tooLong)
	local before = snapshot(s.git)
	a = hx.ask(w, prs, "p3", { op = "worktree", repo = "o/r", number = 2 })
	has(a.problem, "is not usable; change its format in Settings › Repositories.", "a pull request's name is refused with the way to fix it")
	a = hx.ask(w, issues, "i3", freshAsk("o/r", "16"))
	has(a.problem, "is not usable; change its format in Settings › Repositories.", "so is an issue's")
	eq(snapshot(s.git), before, "no branch or worktree was made")
end)

-- ---- window.luau: the questions of a new issue worktree, the users a prompt names, Go to tab

-- Helpers of the cases below, in one table: the suite's main chunk is near Luau's limit of 200 top-level locals.
local asks = {}
asks.protocol = "17" -- what host.luau's `main.rpc` node says: the one place the window cases below name it

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

windowCase("window: Worktree on an issue with no linked PR asks for the base branch", function(w: World)
	local s, b = issueWindow(w)
	s.git.served["refs/heads/alpha"] = sha("a")
	s.git.served["refs/heads/develop"] = sha("c")
	local target = "/wt/plotroom-o_r-issue-12"
	local before = snapshot(s.git)
	-- dismissed: the question is the whole answer
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(#w.window.picks, 1, "no pull request is linked: one question")
	eq(w.window.picks[1].placeholder, "Start octocat/12-fix-login from…", "it names the new branch, the gh login in it")
	same(asks.rows(w.window.picks[1]), { "main @ Default branch", "alpha @ Branches", "develop @ Branches" }, "the remote's default branch leads, alone in its group, the others follow in the host's order")
	same(asks.sent(w), { asks.issue("o/r", "12") }, "nothing was decided: the request carries no PR, no new branch, no base")
	eq(#w.toasts, 1, "the user was told once")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "that the worktree is being prepared")
	eq(snapshot(s.git), before, "no ref, worktree or config was made")
	eq(#w.window.launches, 0, "no tab opened")
	eq(cardOf(b), nil, "and the block noted no worktree")
	-- picked: the request is repeated with the new branch and its base
	w.window.choose = "develop"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	local fresh = asks.issue("o/r", "12", { fresh = true, base = "develop" })
	same(asks.sent(w), { asks.issue("o/r", "12"), asks.issue("o/r", "12"), fresh }, "the dismissed question sent nothing more; the pick is a new branch from it")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 2, "the user is told once per click, not again when the host asks the second question")
	eq(#w.toasts, 3, "and the worktree toast is the only other")
	eq(w.toasts[3].level, "success", "it is a success")
	eq(w.toasts[3].text, "Worktree ready for o/r#12", "naming the issue")
	eq(w.toasts[3].sub, "Created · octocat/12-fix-login at ccccccc · Clean", "the new branch starts at the pick, not at the default branch")
	eq(#w.window.picks, 2, "one question per click")
	eq(#w.window.launches, 1, "one tab opened")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree")
	eq(countLog(s.git, "ls-remote --symref origin HEAD refs/heads/*"), 2, "the remote's branches were listed once per click, not again for the answer")
	eq(countLog(s.git, "fetch"), 1, "one fetch")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/develop:refs/remotes/origin/develop"), 1, "of the base picked, into its remote-tracking ref")
	eq(s.git.refs["refs/remotes/origin/develop"], sha("c"), "which now holds it")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("c"), "the new branch is made there")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b octocat/12-fix-login " .. target .. " " .. sha("c")), 1, "and the worktree added through omp at that commit")
	eq(countLog(s.git, "config"), 0, "a new branch gets no upstream: the first push sets it")
	eq(#requestsOf(s.gh, "linked"), 2, "the linked pull requests were read once per click: the pick's request does not look again")
end)

windowCase("window: Worktree on an issue with several linked PRs asks which", function(w: World)
	local s, b = asks.several(w)
	local target = "/wt/plotroom-o_r-issue-12"
	local before = snapshot(s.git)
	-- dismissed: the question is the whole answer
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(#w.window.picks, 1, "two linked pull requests have their branch: one question")
	eq(w.window.picks[1].placeholder, "Which branch for o/r#12?", "it names the issue")
	same(asks.rows(w.window.picks[1]), {
		"#7 Fix login — fix-login @ Linked pull requests",
		"#9 Fix login on mobile — fix-login-mobile @ Linked pull requests",
		"New branch… — Starts from a base branch you pick next @ Or",
	}, "each pull request that still has its branch, with the branch; one whose branch is gone is not offered; then a new branch")
	same(asks.sent(w), { asks.issue("o/r", "12") }, "nothing was decided: the request carries no PR, no new branch, no base")
	eq(#w.toasts, 1, "the user was told once")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "that the worktree is being prepared")
	eq(snapshot(s.git), before, "no ref, worktree or config was made")
	eq(#w.window.launches, 0, "no tab opened")
	eq(cardOf(b), nil, "and the block noted no worktree")
	-- picked: the request is repeated with the pull request, and only with it
	w.window.choose = "#9 Fix login on mobile"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	same(asks.sent(w), { asks.issue("o/r", "12"), asks.issue("o/r", "12"), asks.issue("o/r", "12", { pr = 9 }) }, "the dismissed question sent nothing more; the pick names its pull request, no new branch or base")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 2, "the user is told once per click, not again when the host asks the question")
	eq(#w.toasts, 3, "and the worktree toast is the only other")
	eq(w.toasts[3].level, "success", "it is a success")
	eq(w.toasts[3].text, "Worktree ready for o/r#12", "naming the issue")
	eq(w.toasts[3].sub, "Created · fix-login-mobile at ddddddd · Clean", "on the pull request's own branch, at its head")
	eq(#w.window.picks, 2, "one question per click: the pick ended them")
	eq(#w.window.launches, 1, "one tab opened")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree, not a folder named for the pull request")
	eq(s.git.refs["refs/heads/fix-login-mobile"], sha("d"), "the branch is the pick's")
	eq(s.git.refs["refs/heads/fix-login"], nil, "not the other pull request's")
	eq(s.git.config["branch.fix-login-mobile.remote"], "origin", "its upstream is set to the remote")
	eq(s.git.config["branch.fix-login-mobile.merge"], "refs/heads/fix-login-mobile", "and to the head branch")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b fix-login-mobile " .. target .. " " .. sha("d")), 1, "the worktree was added through omp at the pull request's head")
	eq(countLog(s.git, "ls-remote"), 0, "no base branch was asked for")
	eq(#requestsOf(s.gh, "linked"), 2, "the linked pull requests were read once per click")
end)

windowCase("window: Worktree on an issue with several linked PRs and a new branch asks for the base next", function(w: World)
	local s = asks.several(w)
	s.git.served["refs/heads/develop"] = sha("e")
	local target = "/wt/plotroom-o_r-issue-12"
	w.window.choose = { "New branch…", "develop" }
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	same(asks.sent(w), {
		asks.issue("o/r", "12"),
		asks.issue("o/r", "12", { fresh = true }),
		asks.issue("o/r", "12", { fresh = true, base = "develop" }),
	}, "a new branch is asked for with no pull request; the base pick adds to it, not replaces it")
	eq(#w.window.picks, 2, "the pull request question, then the base")
	eq(w.window.picks[2].placeholder, "Start octocat/12-fix-login from…", "which names the new branch, not a pull request's")
	same(asks.rows(w.window.picks[2]), { "main @ Default branch", "develop @ Branches", "fix-login @ Branches", "fix-login-mobile @ Branches" }, "the base question lists the remote's branches, its default first")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 1, "the user was told once")
	eq(w.toasts[#w.toasts].text, "Worktree ready for o/r#12", "then the worktree is ready")
	eq(w.toasts[#w.toasts].sub, "Created · octocat/12-fix-login at eeeeeee · Clean", "on the issue's own branch, at the base")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("e"), "the new branch starts at the base")
	eq(s.git.refs["refs/heads/fix-login"], nil, "no pull request's branch was made")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/develop:refs/remotes/origin/develop"), 1, "only the base was fetched")
	eq(countLog(s.git, "fetch"), 1, "and no pull request head")
	eq(countLog(s.git, "config"), 0, "a new branch gets no upstream")
end)

windowCase("window: Worktree on an issue with exactly one linked PR needs no question", function(w: World)
	local s, b = issueWindow(w)
	-- a second pull request, whose branch is gone, does not count
	s.gh.linked["o/r#12"] = array({
		{ number = 3, title = "First try", head = "old-try", branch = NULL, base = "o/r" },
		asks.pr(s, 7, "Fix login", "fix-login", "c"),
	})
	local target = "/wt/plotroom-o_r-issue-12"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(#w.window.picks, 0, "nothing is asked")
	same(asks.sent(w), { asks.issue("o/r", "12") }, "one request: the host's second look, at the one pull request, is its own")
	eq(#requestsOf(s.gh, "linked"), 1, "the host read the linked pull requests")
	eq(#w.toasts, 2, "two toasts")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "the worktree is being prepared")
	eq(w.toasts[2].level, "success", "then it is ready")
	eq(w.toasts[2].text, "Worktree ready for o/r#12", "naming the issue")
	eq(w.toasts[2].sub, "Created · fix-login at ccccccc · Clean", "on the pull request's branch, at its head")
	eq(#w.window.launches, 1, "one tab opened")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree")
	eq(s.git.refs["refs/heads/fix-login"], sha("c"), "the branch is the pull request's")
	eq(s.git.config["branch.fix-login.remote"], "origin", "its upstream is set to the remote")
	eq(s.git.config["branch.fix-login.merge"], "refs/heads/fix-login", "and to the head branch")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b fix-login " .. target .. " " .. sha("c")), 1, "the worktree was added through omp at the pull request's head")
	eq(countLog(s.git, "ls-remote"), 0, "no base branch was listed")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	has(cardText(b), target, "and the card says where the worktree is")
end)

windowCase("window: an answer to the pull request or base question that arrives without a window context asks nothing more", function(w: World)
	local s, b = asks.several(w)
	w.window.decide = function(opts: any): (string?, boolean?)
		return (if string.find(opts.placeholder, "^Start ") then "main" else "#7 Fix login"), true
	end
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	showPr(b, 13)
	cardSurface(w, b)
	w.click(issueLink("worktree", "o/r", "13"))
	w.flush()
	same(asks.rows(w.window.picks[1])[1], "#7 Fix login — fix-login @ Linked pull requests", "the pull request question was asked")
	eq(w.window.picks[2].placeholder, "Start octocat/13-add-dark-mode from…", "and the base question")
	eq(#asks.sent(w), 2, "answered without a context, neither sent a request")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made")
	eq(#w.toasts, 2, "and nothing was said beyond the two starts")
	eq(#w.window.launches, 0, "no tab opened")
end)

windowCase("window: a Jira issue's decisions after its repository is picked carry that repository and every answer settled before", function(w: World)
	local s, b = jiraWindow(w)
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }) })
	s.git.served["refs/heads/develop"] = sha("e")
	s.gh.linked["o/r#ABC-12"] = array({
		asks.pr(s, 7, "ABC-12 Fix login", "abc-12-fix-login", "c"),
		asks.pr(s, 9, "ABC-12: mobile", "abc-12-mobile", "d"),
	})
	s.gh.linked["o/r#ABC-13"] = array({
		asks.pr(s, 8, "ABC-13 Old bug", "abc-13-old-bug", "f"),
		asks.pr(s, 6, "ABC-13: another", "abc-13-another", "a"),
	})
	local function placeholders(): { string }
		local out: { string } = {}
		for _, pick in w.window.picks do
			table.insert(out, pick.placeholder)
		end
		return out
	end
	-- a new branch: the repository, a new branch among the linked pull requests, the base
	w.window.choose = { "o/r", "New branch…", "develop" }
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	same(placeholders(), { "Which repository for ABC-12?", "Which branch for ABC-12?", "Start octocat/ABC-12-fix-login from…" }, "three questions, in that order")
	local chosen: { [string]: any } = { target = "o/r" }
	same(asks.sent(w), {
		asks.issue("ABC", "ABC-12"),
		asks.issue("ABC", "ABC-12", chosen),
		asks.issue("ABC", "ABC-12", { target = "o/r", fresh = true }),
		asks.issue("ABC", "ABC-12", { target = "o/r", fresh = true, base = "develop" }),
	}, "every repeat names the repository, and the base's keeps the new branch asked before it")
	eq(asks.toasted(w, "Preparing worktree for ABC-12"), 1, "the user was told once")
	eq(w.toasts[#w.toasts].sub, "Created · octocat/ABC-12-fix-login at eeeeeee · Clean", "the new branch starts at the base")
	eq(w.window.launches[1].cwd, "/wt/plotroom-o_r-issue-ABC-12", "in the worktree of the repository picked")
	eq(s.git.refs["refs/heads/octocat/ABC-12-fix-login"], sha("e"), "made from it")
	-- a linked pull request: the repository, then the pull request
	b.event({ ev = "select", id = "layer.queue", item = "nabc_23ABC-13" })
	cardSurface(w, b)
	local asked = #asks.sent(w)
	w.window.choose = { "o/r", "#8 ABC-13 Old bug" }
	w.click(issueLink("worktree", "ABC", "ABC-13"))
	w.flush()
	same({ table.unpack(asks.sent(w), asked + 1) }, {
		asks.issue("ABC", "ABC-13"),
		asks.issue("ABC", "ABC-13", chosen),
		asks.issue("ABC", "ABC-13", { target = "o/r", pr = 8 }),
	}, "the pull request is added to the repository, with no new branch or base")
	same(placeholders(), {
		"Which repository for ABC-12?",
		"Which branch for ABC-12?",
		"Start octocat/ABC-12-fix-login from…",
		"Which repository for ABC-13?",
		"Which branch for ABC-13?",
	}, "two questions for the second issue: no base")
	eq(w.toasts[#w.toasts].sub, "Created · abc-13-old-bug at fffffff · Clean", "on the pull request's branch")
	eq(w.window.launches[2].cwd, "/wt/plotroom-o_r-issue-ABC-13", "in the issue's worktree")
	eq(s.git.config["branch.abc-13-old-bug.merge"], "refs/heads/abc-13-old-bug", "with its upstream")
	same(w.kv.get("jira-repos").ABC, { "o/r", "x/y" }, "choosing among several saves nothing")
end)

windowCase("window: a Jira issue's repository without a checkout asks for its folder, keeps the repository picked, then asks the base", function(w: World)
	local s = jiraWindow(w)
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }) })
	-- x/y is a repository the block has no checkout of yet
	local g = newGit(w, "/work/y")
	g.remotes.origin = { "https://github.com/x/y.git" }
	g.served["refs/heads/main"] = sha("b")
	g.defaultBranch = "main"
	w.window.choose = { "x/y", "main" }
	w.window.typed = "/work/y"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	same(asks.sent(w), {
		asks.issue("ABC", "ABC-12"),
		asks.issue("ABC", "ABC-12", { target = "x/y" }),
		{ op = "checkout", repo = "x/y", path = "/work/y" },
		asks.issue("ABC", "ABC-12", { target = "x/y" }),
		asks.issue("ABC", "ABC-12", { target = "x/y", fresh = true, base = "main" }),
	}, "the repository picked is asked for again once its folder is saved, and the base's request keeps it")
	eq(w.kv.get("checkouts")["x/y"], "/work/y", "the folder is saved for the repository")
	eq(asks.toasted(w, "Preparing worktree for ABC-12"), 1, "the user was told once")
	eq(#w.window.picks, 2, "the repository, then the base: the folder was asked by typing")
	eq(w.toasts[#w.toasts].sub, "Created · octocat/ABC-12-fix-login at bbbbbbb · Clean", "the worktree is made")
	eq(w.window.launches[1].cwd, "/wt/plotroom-x_y-issue-ABC-12", "in the repository picked, not the project's first")
	eq(countLog(g, "worktree add"), 1, "by the new checkout")
	eq(countLog(s.git, "worktree add"), 0, "and not by the other")
end)

windowCase("window: Worktree asked again once its checkout was given does not announce the preparation twice", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	linkQueue(w, s)
	w.kv.put("checkouts", {})
	w.window.typed = "/work/r"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	local ops: { string } = {}
	for _, q in asks.sent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "worktree", "checkout", "worktree" }, "the worktree is asked for again once the checkout is saved")
	eq(asks.toasted(w, "Preparing worktree for o/r#5"), 1, "the user was told once")
	eq(w.toasts[#w.toasts].level, "success", "and the worktree came")
end)

windowCase("window: {github.user} in a pull request prompt is filled with the gh login", function(w: World)
	local s, b = agentScene(w)
	savePrompts(w, {
		promptOf("p1", "Plain", "Review {url}"),
		promptOf("p2", "Mine", "Review {url} as {github.user}; {nope} {no.such}"),
	})
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(requestsSent(w)[2].op, "worktree", "the prompt's worktree is asked for")
	eq(requestsSent(w)[2].users, false, "a prompt that names no user does not ask for them")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5", "and runs as written")
	w.click(runLink("o/r", 5, "p2"))
	w.flush()
	local sent = requestsSent(w)
	eq(sent[4].op, "worktree", "the next prompt's worktree is asked for")
	eq(sent[4].users, true, "a prompt that names {github.user} asks for the users")
	eq(#w.window.agents, 2, "an agent started for each")
	eq(w.window.agents[2].prompt, "Review https://github.com/o/r/pull/5 as octocat; {nope} {no.such}", "{github.user} is the login gh is signed in as; unknown variables, dotted or not, stay as typed")
	eq(w.window.agents[2].cwd, s.target, "in the PR's worktree")
	w.window.choose, w.window.typed = { "Start another agent", "Type a prompt…" }, "Ping {github.user} about {number}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	sent = requestsSent(w)
	eq(sent[#sent].users, true, "typed text that names it asks for the users too")
	eq(w.window.agents[3].prompt, "Ping octocat about 5", "and gets the login")
end)

windowCase("window: a pull request prompt naming {github.user} still runs when gh cannot say who is signed in", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { status = 1, stderr = "You are not logged into any GitHub hosts.\n" }
		end
		return nil
	end
	local b = linkQueue(w, s)
	savePrompts(w, { promptOf("p1", "Mine", "Review {url} as {github.user}; {nope}") })
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(requestsSent(w)[2].users, true, "the users were asked for")
	eq(#w.window.agents, 1, "the agent started all the same")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5 as ; {nope}", "the user the host could not read is blank; the rest is filled as always")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	eq(w.toasts[#w.toasts].level, "success", "and the user is told it started")
end)

windowCase("window: {github.user} and {jira.user} in an issue prompt are filled in, the users asked for only when it names one", function(w: World)
	local _, b = jiraWindow(w)
	saveIssuePrompts(w, {
		issuePrompt("p1", "Plain", "Work on {key}", false),
		issuePrompt("p2", "Both", "{github.user} ({jira.user}) works on {key}; {nope}", false),
		issuePrompt("p3", "Jira", "Ask {jira.user}", false),
	})
	b.render()
	cardSurface(w, b)
	w.click(issueRunLink("ABC", "ABC-12", "p1"))
	w.flush()
	same(asks.sent(w)[2], { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = false }, "a prompt that names no user does not ask for them")
	eq(w.window.agents[1].prompt, "Work on ABC-12", "and runs as written")
	w.click(issueRunLink("ABC", "ABC-12", "p2"))
	w.flush()
	same(asks.sent(w)[4], { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = true }, "one that names both asks for them")
	eq(#w.window.agents, 2, "an agent started for each")
	eq(w.window.agents[2].prompt, "octocat (ann) works on ABC-12; {nope}", "the gh login and the Jira user's name; an unknown variable stays as typed")
	eq(w.window.agents[2].cwd, "/work/r", "in the main checkout, as the prompt says")
	w.click(issueRunLink("ABC", "ABC-12", "p3"))
	w.flush()
	same(asks.sent(w)[6], { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = true }, "one that names only {jira.user} asks for them too")
	eq(w.window.agents[3].prompt, "Ask ann", "and gets the Jira user's name")
end)

windowCase("window: an issue prompt that runs in a worktree keeps its text and its users through the pull request and base questions", function(w: World)
	local s, b = asks.several(w)
	s.gh.linked["o/r#13"] = s.gh.linked["o/r#12"]
	s.git.served["refs/heads/develop"] = sha("e")
	-- a format that names no user: only the prompt asks for them
	w.kv.put("branch-format", "{key}-{slug}")
	saveIssuePrompts(w, { issuePrompt("p1", "Fix", "Fix {title} on {branch} as {github.user}", true) })
	b.render()
	cardSurface(w, b)
	w.window.choose = "#7 Fix login"
	w.click(issueRunLink("o/r", "12", "p1"))
	w.flush()
	same(asks.sent(w), {
		{ op = "menu", only = "p1" },
		asks.issue("o/r", "12", { users = true }),
		asks.issue("o/r", "12", { users = true, pr = 7 }),
	}, "the prompt is looked up once; the users are asked for again with the pull request picked")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 1, "the user is told once")
	eq(#w.window.agents, 1, "the agent started once the questions were answered")
	eq(w.window.agents[1].cwd, "/wt/plotroom-o_r-issue-12", "in the issue's worktree")
	eq(w.window.agents[1].prompt, "Fix Fix login on fix-login as octocat", "on the pull request's branch")
	-- a new branch: the same on the way through the base question
	showPr(b, 13)
	cardSurface(w, b)
	local asked = #asks.sent(w)
	w.window.choose = { "New branch…", "develop" }
	w.click(issueRunLink("o/r", "13", "p1"))
	w.flush()
	same({ table.unpack(asks.sent(w), asked + 1) }, {
		{ op = "menu", only = "p1" },
		asks.issue("o/r", "13", { users = true }),
		asks.issue("o/r", "13", { users = true, fresh = true }),
		asks.issue("o/r", "13", { users = true, fresh = true, base = "develop" }),
	}, "and the users are asked for with the new branch, and with its base")
	eq(#w.window.agents, 2, "a second agent started")
	eq(w.window.agents[2].cwd, "/wt/plotroom-o_r-issue-13", "in the second issue's worktree")
	eq(w.window.agents[2].prompt, "Fix Add dark mode on 13-add-dark-mode as octocat", "on the new branch")
	eq(s.git.refs["refs/heads/13-add-dark-mode"], sha("e"), "made from the base")
end)

windowCase("window: a second Worktree click on an issue while the first is being prepared is told so and the question is asked once", function(w: World)
	local s = asks.several(w)
	w.window.choose = "#7 Fix login"
	w.click(issueLink("worktree", "o/r", "12"))
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(asks.toasted(w, "A worktree for o/r#12 is already being prepared"), 1, "the repeat is told the first is under way")
	eq(#w.window.picks, 1, "one question")
	eq(countLog(s.git, "worktree add"), 1, "and one worktree")
	eq(#w.window.launches, 1, "and one tab")
	eq(#requestsOf(s.gh, "linked"), 1, "the linked pull requests were read once")
end)

windowCase("window: a second Worktree click on an issue while gh or git is still being read for its question is told so too", function(w: World)
	local s, b = asks.several(w)
	local real = s.gh.linked["o/r#12"]
	-- gh lists the linked pull requests of #12 only after a second; git lists the remote's branches as slowly
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" and req.fields.n == "12" then
			return { stdout = jsonEncode(array(real)), delay = 1000 }
		end
		return nil
	end
	s.git.fail["ls-remote"] = { stdout = "ref: refs/heads/main\tHEAD\n" .. sha("b") .. "\tHEAD\n" .. sha("b") .. "\trefs/heads/main\n", delay = 1000 }
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	w.advance(1500)
	eq(asks.toasted(w, "A worktree for o/r#12 is already being prepared"), 1, "the repeat while the linked pull requests are read is told the first is under way")
	eq(#w.window.picks, 1, "one question: which pull request")
	eq(#requestsOf(s.gh, "linked"), 1, "the linked pull requests were read once")
	showPr(b, 13)
	cardSurface(w, b)
	w.click(issueLink("worktree", "o/r", "13"))
	w.flush()
	w.click(issueLink("worktree", "o/r", "13"))
	w.flush()
	w.advance(1500)
	eq(asks.toasted(w, "A worktree for o/r#13 is already being prepared"), 1, "the repeat while the remote's branches are listed is told so too")
	eq(#w.window.picks, 2, "one question more: which base")
	eq(countLog(s.git, "ls-remote"), 1, "the remote's branches were listed once")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made: the questions were dismissed")
end)

windowCase("window: Go to tab finds the worktree through the host's noted path, whatever its folder is called", function(w: World)
	local s, b = agentScene(w)
	w.kv.put("pr-dir-format", "pr-{key}")
	local target = "/wt/pr-5"
	-- a worktree in a folder the default format would not have named: the host notes where it is
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.window.launches[1].cwd, target, "the worktree's tab opened in the folder the format names")
	has(cardText(b), target, "which the host noted: its card says where it is")
	-- Plotroom's block sees the tab (the fake host lists panes apart from the window's), so the card offers Go to tab
	table.insert(w.panes, { pane = 11, cwd = target })
	w.window.tabs[2].session = 4
	w.window.focused = 1
	b.render()
	cardSurface(w, b)
	eq(buttonLink(b, "goto"), prLink("goto", "o/r", 5), "a tab working in the worktree: the card has its Go to tab link")
	local said, tabs, switched = #w.toasts, #w.window.launches, #w.window.switches
	w.click(prLink("goto", "o/r", 5))
	w.flush()
	local sent = asks.sent(w)
	same(sent[#sent], { op = "where", kind = "pr", key = "o/r#5" }, "the host is asked where the pull request's worktree is")
	eq(w.window.focused, 11, "the pane working in it is focused")
	same({ table.unpack(w.window.switches, switched + 1) }, { 4 }, "after its session is switched to")
	eq(#w.toasts, said, "with nothing said")
	eq(#w.window.launches, tabs, "and no tab opened")
	-- the card was drawn while the tab was open; the click comes after it closed
	w.window.panes[11] = nil
	table.remove(w.panes)
	local function addPane(id: number, cwd: string, tab: number, session: number)
		w.window.panes[id] = { block = nil, cwd = cwd, tab = tab }
		table.insert(w.window.tabs, { id = tab, session = session })
	end
	-- panes beside the worktree, none in it: a sibling folder that starts with its name, a folder named as the default
	-- format would, the worktrees folder itself
	addPane(21, "/wt/pr-50/src", 21, 5)
	addPane(22, "/wt/plotroom-o_r-pr-5", 22, 5)
	addPane(23, "/wt", 23, 5)
	w.window.focused = 1
	switched = #w.window.switches
	local function nobody(what: string)
		said = #w.toasts
		w.click(prLink("goto", "o/r", 5))
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "info", what .. ": as news, not an error")
		eq(w.toasts[#w.toasts].text, "No tab is open for o/r#5", what .. ": that no tab is open")
		eq(w.window.focused, 1, what .. ": no pane was focused")
		eq(#w.window.switches, switched, what .. ": no session was switched to")
		eq(#w.window.launches, tabs, what .. ": no tab opened")
	end
	nobody("a worktree nobody works in")
	-- nothing noted for it at all: git does not list the worktree, so the host has no note of it and its tab is no tab of the panes there are
	local made = table.remove(s.git.worktrees, 2) :: any
	refreshNow(w, b)
	nobody("a worktree the host has no note of")
	-- listed again, with a pane in the worktree itself, deeper down, among the others
	table.insert(s.git.worktrees, made)
	refreshNow(w, b)
	addPane(24, target .. "/src/lib", 24, 6)
	w.click(prLink("goto", "o/r", 5))
	w.flush()
	eq(w.window.focused, 24, "a pane inside the worktree is found among the others")
	eq(w.window.switches[#w.window.switches], 6, "and its session shown")
end)

windowCase("window: Go to tab asks for a pull request of a mixed-case repository by its lowercase key, as the worktree was noted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "Octo", "Repo", 5)
	local b = linkQueue(w, s)
	local target = "/wt/plotroom-octo_repo-pr-5"
	w.click(prLink("worktree", "Octo/Repo", 5))
	w.flush()
	eq(w.window.launches[1].cwd, target, "the worktree's tab opened")
	table.insert(w.panes, { pane = 11, cwd = target })
	w.window.focused = 1
	b.render()
	cardSurface(w, b)
	eq(buttonLink(b, "goto"), prLink("goto", "Octo/Repo", 5), "the card's link names the repository as GitHub spells it")
	w.click(prLink("goto", "Octo/Repo", 5))
	w.flush()
	local sent = asks.sent(w)
	same(sent[#sent], { op = "where", kind = "pr", key = "octo/repo#5" }, "the host is asked for the lowercase key its note is under")
	eq(w.window.focused, 11, "so the pane working in the worktree is focused")
	eq(#w.toasts, 2, "with nothing said but the worktree's start and its end")
end)

windowCase("window: Go to tab on a Jira issue asks for the project's lowercase key, as its worktree was noted", function(w: World)
	local _, b = jiraWindow(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	w.window.choose = "main"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(w.window.launches[1].cwd, target, "the worktree's tab opened")
	has(cardText(b), target, "the host noted it: its card says where it is")
	table.insert(w.panes, { pane = 11, cwd = target })
	w.window.focused = 1
	b.render()
	cardSurface(w, b)
	w.click(issueLink("goto", "ABC", "ABC-12"))
	w.flush()
	local sent = asks.sent(w)
	same(sent[#sent], { op = "where", kind = "issue", key = "abc#ABC-12" }, "the host is asked for that key")
	eq(w.window.focused, 11, "so the pane working in the worktree is focused")
end)

windowCase("window: an agent joins the tab working in its worktree, not a pane in a sibling folder that shares the path's start", function(w: World)
	local s = agentScene(w)
	w.window.choose, w.window.typed = "Type a prompt…", "go"
	-- a pane in /wt/plotroom-o_r-pr-5-old, beside the worktree /wt/plotroom-o_r-pr-5
	w.window.panes[21] = { block = nil, cwd = s.target .. "-old/src", tab = 21 }
	table.insert(w.window.tabs, { id = 21, session = 5 })
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[#w.toasts].text, "Agent started for o/r#5", "no tab works in the worktree yet: the agent has a tab of its own")
	eq(w.window.switches[#w.window.switches], 1, "in the session of the block")
	eq(w.window.panes[11].cwd, s.target, "that tab works in the worktree")
	w.window.panes[11] = nil -- and is closed again
	-- a pane inside the worktree
	w.window.panes[22] = { block = nil, cwd = s.target .. "/src", tab = 22 }
	table.insert(w.window.tabs, { id = 22, session = 6 })
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[#w.toasts].text, "Agent started in the tab of o/r#5", "a tab works in the worktree: the agent joins it")
	eq(w.window.switches[#w.window.switches], 6, "in its session")
	eq(w.window.panes[12].tab, 22, "the agent's pane moved into that tab")
	eq(#w.window.agents, 2, "two agents started")
end)

windowCase("window: a host announcing another protocol is refused for the new asks too: a pull request's or an issue's worktree, a tab, a prompt", function(w: World)
	w.load("window")
	-- the buttons of the block's selected row, as links, and what the block's main region announces
	local function offer(links: { string }, announces: string?)
		local names = { "worktree", "goto", "agent", "prompt-p1" }
		local buttons: { any } = {}
		for i, url in links do
			table.insert(buttons, { id = "layer.queue.buttons." .. names[i], p = { href = url } })
		end
		w.window.surfaces[1] = {
			layer = { id = "layer", c = { { id = "layer.queue", c = buttons } } },
			main = if announces then { id = "main", c = { { id = "main.rpc", p = { text = announces, hidden = true } } } } else nil,
		}
	end
	local pull = { prLink("worktree", "o/r", 5), prLink("goto", "o/r", 5), prLink("agent", "o/r", 5), runLink("o/r", 5, "p1") }
	local issue = { issueLink("worktree", "o/r", "12"), issueLink("goto", "o/r", "12"), issueLink("agent", "o/r", "12"), issueRunLink("o/r", "12", "p1") }
	local function refused(what: string, links: { string }, announces: string?)
		offer(links, announces)
		for _, url in links do
			local said = #w.toasts
			w.click(url)
			eq(#w.toasts, said + 1, what .. ", " .. url .. ": the click is answered")
			eq(w.toasts[#w.toasts].level, "error", what .. ", " .. url .. ": with an error")
			has(w.toasts[#w.toasts].text, "another version", what .. ", " .. url .. ": that says why")
		end
		w.flush()
		eq(#w.window.events + #w.window.picks + #w.calls + #w.window.launches, 0, what .. ": nothing was sent, asked, run or opened")
	end
	for _, links in { pull, issue } do
		refused("a block with no marker", links, nil)
		refused("a block of protocol 10", links, "10")
		refused("a block of protocol 11", links, "11")
		refused("a block of protocol 12", links, "12")
		refused("a block of protocol 13", links, "13")
	end
	-- the same links, with the marker of this protocol, are asked of the host: one block, both kinds
	offer(issue, asks.protocol)
	w.click(issue[2])
	local sent = asks.sent(w)
	eq(#sent, 1, "a host that announces this protocol is asked")
	eq(sent[1].op, "where", "where the issue's worktree is")
	offer(pull, asks.protocol)
	w.click(pull[2])
	sent = asks.sent(w)
	same(sent[2], { op = "where", kind = "pr", key = "o/r#5" }, "and where the pull request's is")
end)

-- BEGIN backend cases
-- Helpers hang on `asks` (one top-level local): this file is at Luau's local limit.
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

case("github.parseItemUrl: only https github.com pull and issues links, a query, fragment or one trailing slash ignored", function(w: World)
	local github = w.load("github") :: Github
	local brief = asks.bk.brief
	eq(brief(github.parseItemUrl("https://github.com/o/r/pull/5")), "pr:o/r:5", "pull request")
	eq(brief(github.parseItemUrl("https://github.com/o/r/issues/7")), "issue:o/r:7", "issue")
	eq(brief(github.parseItemUrl("https://github.com/o/r/pull/5/")), "pr:o/r:5", "trailing slash")
	eq(brief(github.parseItemUrl("https://github.com/o/r/pull/5?diff=split#discussion_r1")), "pr:o/r:5", "query and fragment")
	for _, url in {
		"http://github.com/o/r/pull/5",
		"https://github.com/o/r/pulls/5",
		"https://github.com/o/r/pull/0",
		"https://github.com/o/r/pull/5/files",
		"https://github.com/o/r/pull/99999999999",
		"https://github.com/o/r/commit/5",
		"https://github.com/o/../pull/5",
		"https://evil.com/o/r/pull/5",
		"https://github.com.evil.com/o/r/pull/5",
		"https://github.com/o/r",
		"",
	} do
		eq(brief(github.parseItemUrl(url)), "nil", "refused: " .. url)
	end
	eq(brief(github.parseItemUrl(nil)), "nil", "not a string")
end)

case("github.runIdOf: a workflow run id from a job or run link, never from a check suite or check run link", function(w: World)
	local github = w.load("github") :: Github
	eq(github.runIdOf("https://github.com/o/r/actions/runs/123/job/456"), "123", "job link")
	eq(github.runIdOf("https://github.com/o/r/actions/runs/123"), "123", "run link")
	for _, url in {
		"https://github.com/o/r/runs/456",
		"https://github.com/o/r/suites/789",
		"https://github.com/o/r/actions/runs/0/job/1",
		"https://github.com/o/r/actions/runs/1234567890123456",
		"http://github.com/o/r/actions/runs/123",
		"https://example.com/o/r/actions/runs/123",
	} do
		eq(github.runIdOf(url), nil, "no run id: " .. url)
	end
	eq(github.runIdOf(nil), nil, "not a string")
end)

case("github: Run.runId is set by the search and by the checks detail, only for workflow links", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local base = "https://github.com/o/r"
	local list = {
		checkRun("build", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { id = "A", detailsUrl = base .. "/actions/runs/123/job/9" }),
		checkRun("lint", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "B", detailsUrl = base .. "/runs/77" }),
		{ context = "ci/x", state = "FAILURE", targetUrl = base .. "/actions/runs/456", id = "C" },
	}
	gh.items.octocat = { searchItem(5, "o/r", EPOCH - 60, { runs = array(list), runTotal = 3 }) }
	gh.checks["o/r#5"] = list
	local function ids(runs: any): string
		local out: { string } = {}
		for _, run in runs do
			table.insert(out, run.name .. "=" .. tostring(run.runId))
		end
		table.sort(out)
		return table.concat(out, ",")
	end
	local want = "build=123,ci/x=456,lint=nil"
	eq(ids(runSearch(w, github, nil).result.prs[1].runs), want, "from the search")
	local detail = runChecks(github, nil)
	w.flush()
	eq(ids(detail.runs), want, "from the detail load")
end)

case("github.editIssue: an invalid input is refused before gh runs, a valid edit is one argv with --flag=value", function(w: World)
	local github = w.load("github") :: Github
	local gh, seen = asks.bk.gh(w, function(_line: string): Reply?
		return { stdout = "" }
	end)
	local function edit(e: any, account: string?): any
		return asks.bk.once(w, function(done)
			github.editIssue(e, account, done)
		end)
	end
	local refused: { [string]: any } = {
		["a label with a control character"] = { repo = "o/r", number = 5, addLabels = { "a\tb" } },
		["a label that starts with a dash"] = { repo = "o/r", number = 5, addLabels = { "-x" } },
		["a label added and removed"] = { repo = "o/r", number = 5, addLabels = { "bug" }, removeLabels = { "BUG" } },
		["an assignee added and removed"] = { repo = "o/r", number = 5, addAssignees = { "bob" }, removeAssignees = { "Bob" } },
		["a login with a space"] = { repo = "o/r", number = 5, addAssignees = { "bob smith" } },
		["no change"] = { repo = "o/r", number = 5 },
		["a repo that is not owner/name"] = { repo = "o", number = 5, addLabels = { "bug" } },
		["a fractional number"] = { repo = "o/r", number = 5.5, addLabels = { "bug" } },
	}
	for what, e in refused do
		local p = edit(e, nil)
		eq(p and p.kind, "invalid", what .. ": invalid")
	end
	eq(#w.calls, 0, "nothing was spawned for any of them")
	eq(#seen, 0, "gh never ran")
	eq(edit({ repo = "o/r", number = 5, addAssignees = { "@me", "bob" }, removeAssignees = { "ann" }, addLabels = { "good first issue", "a,b" }, removeLabels = { "wip" } }, nil), nil, "a valid edit succeeds")
	same(seen, { "gh issue edit 5 --repo github.com/o/r --add-assignee=@me --add-assignee=bob --remove-assignee=ann --add-label=\"good first issue\" --add-label=\"a,b\" --remove-label=\"wip\"" }, "one argv, every label CSV-quoted: a comma stays inside one label")
	eq(#gh.requests, 1, "one gh request")
end)

case("github: a saved gh login that cannot sign in sends no mutation", function(w: World)
	local github = w.load("github") :: Github
	local gh, seen = asks.bk.gh(w, function(_line: string): Reply?
		return { stdout = "https://github.com/o/r/pull/9\n" }
	end)
	local e = asks.bk.once(w, function(done)
		github.editIssue({ repo = "o/r", number = 5, addLabels = { "bug" } }, "ghost", done)
	end)
	eq(e.kind, "auth", "edit: the account is not signed in")
	local r = asks.bk.once(w, function(done)
		github.rerunFailed("o/r", "123", "ghost", done)
	end)
	eq(r.kind, "auth", "rerun: the account is not signed in")
	local created: any = nil
	local problem = asks.bk.once(w, function(done)
		github.createPr({ repo = "o/r", base = "main", head = "feat", title = "T", body = "B", draft = true }, "ghost", function(url, p)
			created = url
			done(p)
		end)
	end)
	eq(problem.kind, "auth", "create: the account is not signed in")
	eq(created, nil, "no URL")
	eq(#seen, 0, "no mutation or read of a run was spawned")
	eq(#requestsOf(gh, "token"), 3, "only the token reads ran")
end)

case("github.rerunFailed: only a finished, failed run of the repository is re-run, with its own argv", function(w: World)
	local github = w.load("github") :: Github
	local view = "gh run view 123 --repo github.com/o/r --json databaseId,status,conclusion,url"
	local run: { [string]: any } = { databaseId = 123, status = "completed", conclusion = "failure", url = "https://github.com/o/r/actions/runs/123" }
	local missing = false
	local gh, seen = asks.bk.gh(w, function(line: string): Reply?
		if line == view then
			if missing then
				return { status = 1, stderr = "HTTP 404: Not Found\n" }
			end
			return { stdout = jsonEncode(run) }
		end
		return { stdout = "" }
	end)
	local function rerun(id: string): any
		return asks.bk.once(w, function(done)
			github.rerunFailed("o/r", id, nil, done)
		end)
	end
	local function reruns(): number
		local n = 0
		for _, line in seen do
			if string.find(line, "run rerun", 1, true) then
				n += 1
			end
		end
		return n
	end
	for _, bad in { "12a", "0", "", "-1", "1234567890123456" } do
		eq(rerun(bad).kind, "invalid", "refused id " .. bad)
	end
	eq(#seen, 0, "a malformed id spawns nothing")
	missing = true
	eq(rerun("123").kind, "not-found", "a run that is not this repository's")
	eq(reruns(), 0, "no rerun for it")
	missing = false
	run.databaseId = 999
	eq(rerun("123").kind, "failed", "gh answered another run")
	run.databaseId = 123
	run.status = "in_progress"
	eq(rerun("123").kind, "invalid", "a run that has not finished")
	run.status = "completed"
	run.conclusion = "success"
	eq(rerun("123").kind, "invalid", "a run that passed")
	eq(reruns(), 0, "none of those re-ran")
	run.conclusion = "failure"
	eq(rerun("123"), nil, "a failed run is re-run")
	eq(reruns(), 1, "one rerun")
	eq(seen[#seen], "gh run rerun 123 --repo github.com/o/r --failed", "failed jobs only, in the same repository")
	eq(#gh.requests > 0, true, "gh was used")
end)

case("github.createPr: an exact draft argv, and bad input is refused before gh runs", function(w: World)
	local github = w.load("github") :: Github
	local reply = "https://github.com/o/r/pull/9\n"
	local gh, seen = asks.bk.gh(w, function(_line: string): Reply?
		return { stdout = reply }
	end)
	local function create(d: any): (string?, any)
		local url: string? = nil
		local p = asks.bk.once(w, function(done)
			github.createPr(d, nil, function(u, problem)
				url = u
				done(problem)
			end)
		end)
		return url, p
	end
	local good: { [string]: any } = { repo = "o/r", base = "main", head = "feat/x", title = "Fix login", body = "Closes #4\n- a", draft = true }
	local function with(key: string, value: any): any
		local copy: { [string]: any } = {}
		for k, v in good do
			copy[k] = v
		end
		copy[key] = value
		return copy
	end
	local invalid: { [string]: any } = {
		["draft = false"] = with("draft", false),
		["a head with spaces"] = with("head", "my branch"),
		["a head that starts with a dash"] = with("head", "--web"),
		["a base with a dot-dot"] = with("base", "a..b"),
		["a title with a newline"] = with("title", "a\nb"),
		["a blank title"] = with("title", "  "),
		["a body of the wrong type"] = with("body", 5),
		["a repo with a slash too many"] = with("repo", "o/r/x"),
	}
	for what, d in invalid do
		local url, p = create(d)
		eq(url, nil, what .. ": no url")
		eq(p and p.kind, "invalid", what .. ": invalid")
	end
	eq(#seen, 0, "none of them reached gh")
	local url, p = create(good)
	eq(p, nil, "problem")
	eq(url, "https://github.com/o/r/pull/9", "the new pull request's URL")
	same(w.calls[#w.calls].argv, { "gh", "pr", "create", "--repo", "github.com/o/r", "--draft", "--base=main", "--head=feat/x", "--title=Fix login", "--body=Closes #4\n- a" }, "the argv: draft, explicit head and base, no --fill")
	local fork = create(with("head", "fork:feat"))
	eq(fork, "https://github.com/o/r/pull/9", "a fork's owner:branch head is allowed")
	reply = "done\n"
	local _, odd = create(good)
	eq(odd.kind, "failed", "gh printing no URL is a failure")
	eq(#gh.requests, 3, "three creates ran")
end)

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

case("jira.parseUrl and keyOfUrl: browse and board links, refused on another site or another shape", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local key, host = jira.parseUrl("https://acme.atlassian.net/browse/ABC-1")
	eq(key, "ABC-1", "browse key")
	eq(host, "acme.atlassian.net", "host")
	eq((jira.parseUrl("https://acme.atlassian.net/browse/ABC-1/")), "ABC-1", "trailing slash")
	eq((jira.parseUrl("https://acme.atlassian.net/jira/software/projects/ABC/boards/1?selectedIssue=ABC-12")), "ABC-12", "board link")
	for _, url in { "http://acme.atlassian.net/browse/ABC-1", "https://acme.atlassian.net/browse/abc-1", "https://acme.atlassian.net/browse/ABC-1/x", "https://acme.atlassian.net/", "ftp://x" } do
		eq((jira.parseUrl(url)), nil, "refused: " .. url)
	end
	eq((jira.parseUrl(nil)), nil, "not a string")
	local function keyOf(url: string): (string?, any)
		local k: string?, p: any = nil, nil
		local calls = 0
		jira.keyOfUrl(url, function(a, b)
			calls += 1
			k, p = a, b
		end)
		eq(calls, 0, "never synchronous")
		w.flush()
		eq(calls, 1, "answers once")
		return k, p
	end
	local k, p = keyOf("https://other.atlassian.net/browse/ABC-1")
	eq(k, nil, "another site: no key")
	eq(p.kind, "invalid", "another site: invalid")
	has(p.message, "other.atlassian.net", "names the site it saw")
	eq((keyOf("https://ACME.atlassian.net/browse/ABC-1")), "ABC-1", "the signed-in site, in any letter case")
	local before = #acli.requests
	local _, notJira = keyOf("https://acme.atlassian.net/wiki/x")
	eq(notJira.kind, "invalid", "not a work item link")
	eq(#acli.requests, before, "acli was not asked about it")
end)

case("jira.item: one work item by key, as the list's items; a bad key or another item is refused", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	acli.views["ABC-1"] = jiraItem("ABC-1", "Fix login")
	acli.views["ABC-2"] = jiraItem("ABC-3", "Another")
	local function item(key: string): (any, any)
		local got: any, problem: any = nil, nil
		local calls = 0
		jira.item(key, function(i, p)
			calls += 1
			got, problem = i, p
		end)
		eq(calls, 0, "never synchronous")
		w.flush()
		eq(calls, 1, "answers once")
		return got, problem
	end
	local issue, problem = item("ABC-1")
	eq(problem, nil, "problem")
	eq(issue.ref, "ABC-1", "ref")
	eq(issue.title, "Fix login", "title")
	eq(issue.url, "https://acme.atlassian.net/browse/ABC-1", "browse URL")
	local view = acli.requests[#acli.requests].argv
	eq(view[4], "view", "a view")
	eq(view[5], "ABC-1", "of that key")
	local _, other = item("ABC-2")
	eq(other.kind, "failed", "acli printed another work item")
	local count = #acli.requests
	local _, bad = item("abc-1; rm")
	eq(bad.kind, "failed", "a bad key")
	eq(#acli.requests, count, "acli was not run for it")
end)

case("jira.assignMe: one acli argv for the signed-in user, a bad key spawns nothing", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local failing = false
	acli.override = function(req: AcliReq): Reply?
		if req.kind ~= "other" then
			return nil
		end
		return if failing then { status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login'\n" } else { stdout = "✓ done\n" }
	end
	local function assign(key: string): any
		return asks.bk.once(w, function(done)
			jira.assignMe(key, done)
		end)
	end
	eq(assign("ABC-1"), nil, "problem")
	same(w.calls[#w.calls].argv, { "acli", "jira", "workitem", "assign", "--key", "ABC-1", "--assignee", "@me", "--yes" }, "the argv")
	local count = #w.calls
	eq(assign("ABC-1 --ignore-errors").kind, "invalid", "a key that is not one")
	eq(assign("abc-1").kind, "invalid", "a lowercase key")
	eq(#w.calls, count, "nothing spawned for them")
	failing = true
	eq(assign("ABC-1").kind, "auth", "a signed-out acli")
end)

case("jira.transitions: no API token is an auth problem naming the setup, and nothing is requested or leaked", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	local reqs = asks.bk.rest(w, "ann@example.com", {})
	local problem: any = nil
	jira.transitions("ABC-1", function(_list, p)
		problem = p
	end)
	w.flush()
	eq(problem.kind, "auth", "auth")
	has(problem.message, "PLOTROOM_JIRA_API_TOKEN", "names the variable")
	has(problem.message, "restart Tern", "and the setup")
	lacks(problem.message, "Authorization", "no header text")
	eq(#reqs, 0, "no request was made")
	w.env.PLOTROOM_JIRA_API_TOKEN = ""
	problem = nil
	jira.transition("ABC-1", "31", function(p)
		problem = p
	end)
	w.flush()
	eq(problem.kind, "auth", "an empty token is none")
	eq(#reqs, 0, "still no request")
end)

case("jira.transitions: an API token of another account sends nothing past /myself and never appears in a message", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	w.env.PLOTROOM_JIRA_API_TOKEN = "s3cret-token"
	local reqs = asks.bk.rest(w, "bob@example.com", { { id = "31", name = "Done" } })
	local problem: any = nil
	jira.transition("ABC-1", "31", function(p)
		problem = p
	end)
	w.flush()
	eq(problem.kind, "auth", "auth")
	has(problem.message, "bob@example.com", "names the token's account")
	for _, secret in { "s3cret-token", "Authorization", "Basic", "b64:" } do
		lacks(problem.message, secret, "the message does not leak " .. secret)
	end
	eq(#reqs, 1, "only /myself was requested")
	eq(reqs[1].line, "GET /rest/api/3/myself", "that request")
	for _, t in w.toasts do
		lacks(t.text, "s3cret-token", "no toast carries the token")
	end
	for _, call in w.calls do
		lacks(table.concat(call.argv, " "), "s3cret-token", "the token is in no argv")
	end
end)

case("jira.transitions: the list drops non-numeric ids, and the request is the fixed REST route with Basic auth", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	w.env.PLOTROOM_JIRA_API_TOKEN = "tok"
	local reqs = asks.bk.rest(w, "Ann@Example.com", {
		{ id = "31", name = "Done", to = { name = "Done" } },
		{ id = "x1", name = "Bad id" },
		{ id = "41", name = "Start" },
		{ id = 5, name = "Number id" },
		{ id = "51" },
	})
	local got: any = nil
	jira.transitions("ABC-1", function(list, p)
		eq(p, nil, "problem")
		got = list
	end)
	w.flush()
	eq(#got, 2, "two usable transitions")
	eq(got[1].id .. ":" .. got[1].name .. ":" .. tostring(got[1].to), "31:Done:Done", "first")
	eq(got[2].id .. ":" .. got[2].name .. ":" .. tostring(got[2].to), "41:Start:nil", "second")
	eq(#reqs, 2, "myself, then the list")
	eq(reqs[1].url, "https://acme.atlassian.net/rest/api/3/myself", "myself")
	eq(reqs[2].url, "https://acme.atlassian.net/rest/api/3/issue/ABC-1/transitions", "the list")
	eq(reqs[1].headers.Authorization, "Basic b64:ann@example.com:tok", "Basic auth of the acli email and the token")
	eq(reqs[2].body, nil, "a read has no body")
	local bad: any = nil
	jira.transitions("abc", function(_list, p)
		bad = p
	end)
	w.flush()
	eq(bad.kind, "invalid", "a bad key")
	eq(#reqs, 2, "and no request for it")
end)

case("jira.transition: the id must be in the re-listed set, then one POST of exactly the transition id", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	w.env.PLOTROOM_JIRA_API_TOKEN = "tok"
	local post: { status: number, body: string }? = nil
	local reqs = asks.bk.rest(w, "ann@example.com", { { id = "31", name = "Done" } }, nil)
	local function go(id: string): any
		return asks.bk.once(w, function(done)
			jira.transition("ABC-1", id, done)
		end)
	end
	local function posts(): number
		local n = 0
		for _, r in reqs do
			if r.method == "POST" then
				n += 1
			end
		end
		return n
	end
	eq(go("99").kind, "invalid", "an id Jira no longer offers")
	has(go("99").message, "no longer available", "says so")
	eq(go("3x").kind, "invalid", "a malformed id")
	eq(posts(), 0, "no POST for either")
	eq(go("31"), nil, "the offered id succeeds")
	eq(posts(), 1, "one POST")
	local sent = reqs[#reqs]
	eq(sent.line, "POST /rest/api/3/issue/ABC-1/transitions", "route")
	eq(sent.body, '{"transition":{"id":"31"}}', "body")
	eq(sent.headers["Content-Type"], "application/json", "content type")
	post = { status = 400, body = jsonEncode({ errorMessages = array({ "Field 'resolution' is required" }) }) }
	reqs = asks.bk.rest(w, "ann@example.com", { { id = "31", name = "Done" } }, post)
	local refused = go("31")
	eq(refused.kind, "failed", "Jira refusing the transition")
	has(refused.message, "resolution", "carries Jira's own reason")
end)

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

case("worktree.inventory: lists every worktree of the checkout, marks main, flags locked, prunable, missing and detached, writes nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	local before = snapshot(g)
	local got = asks.bk.pack(w, function(done)
		worktree.inventory("/work/r", "o/r", done)
	end)
	eq(got[2], nil, "problem")
	local entries = got[1]
	eq(#entries, 8, "main and seven linked worktrees")
	eq(entries[1].path, "/work/r", "the main worktree first")
	local by: { [string]: any } = {}
	for _, e in entries do
		by[e.path] = e
	end
	eq(by["/work/r"].main, true, "main is marked")
	eq(by["/work/r"].root, "/work/r", "root")
	eq(by["/work/r"].branch, "main", "main's branch")
	eq(by["/work/r"].number, nil, "main has no item")
	local pr = by["/wt/pr5"]
	eq(pr.main, false, "a linked one is not main")
	eq(pr.branch, "feature", "branch without refs/heads/")
	eq(pr.number, 5, "the pull request Plotroom noted")
	eq(pr.ref, worktree.prRef("o", "r", 5), "and its fetched ref")
	eq(pr.locked or pr.prunable or pr.missing or pr.detached, false, "a plain one has no flags")
	eq(by["/wt/lk"].locked, true, "locked")
	eq(by["/wt/prune"].prunable, true, "prunable")
	eq(by["/wt/gone"].missing, true, "a folder that is gone is missing")
	eq(by["/wt/pr5"].missing, false, "a folder that exists is not")
	eq(by["/wt/det"].detached, true, "detached")
	eq(by["/wt/det"].branch, nil, "and has no branch")
	eq(by["/wt/issue"].key, "ABC-1", "an issue's noted key")
	eq(by["/wt/foreign"].key, nil, "a note made for another repository is not this one's")
	eq(by["/wt/foreign"].number, nil, "nor a number")
	eq(snapshot(g), before, "git state is untouched")
	for _, never in { "fetch", "push", "worktree add", "worktree remove", "branch", "status" } do
		eq(countLog(g, never), 0, "git " .. never .. " was not run")
	end
	local linked = asks.bk.pack(w, function(done)
		worktree.inventory("/wt/pr5", "o/r", done)
	end)
	eq(linked[1][1].path, "/work/r", "asked from a linked worktree, main is still first")
	eq(linked[1][1].main, true, "and marked")
end)

case("worktree.removeEntry: refuses main, locked, prunable, missing, changed and unknown worktrees, touching nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	local function refused(path: string, branch: string?, needle: string, what: string)
		local before = snapshot(g)
		local got = asks.bk.pack(w, function(done)
			worktree.removeEntry("/work/r", "o/r", path, branch, done)
		end)
		eq(got[1], nil, what .. ": no removal")
		has(got[2], needle, what)
		eq(snapshot(g), before, what .. ": git state is untouched")
	end
	refused("/work/r", "main", "main checkout", "the main checkout")
	refused("/wt/lk", "lk", "locked, prunable or missing", "a locked worktree")
	refused("/wt/prune", "pr", "locked, prunable or missing", "a prunable worktree")
	refused("/wt/gone", "gn", "locked, prunable or missing", "a worktree whose folder is gone")
	refused("/wt/pr5", "changed", "changed", "a worktree now on another branch than the window remembers")
	refused("/wt/det", "feature", "changed", "a detached worktree claimed to be on a branch")
	refused("/wt/pr5", nil, "changed", "a branch claimed to be detached")
	refused("/nowhere", "x", "not a worktree", "a path git does not list")
	eq(countLog(g, "worktree remove"), 0, "git was never asked to remove any of them")
end)

case("worktree.removeEntry: a dirty worktree is never forced, a clean one goes with its branch kept unless merged", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	asks.bk.tree(w, g, "/wt/um", "um")
	g.unmerged.um = true
	local function remove(path: string, branch: string?): any
		return asks.bk.pack(w, function(done)
			worktree.removeEntry("/work/r", "o/r", path, branch, done)
		end)
	end
	local function listed(path: string): boolean
		for _, t in g.worktrees do
			if t.path == path then
				return true
			end
		end
		return false
	end
	g.dirty["/wt/pr5"] = " M a.txt\n"
	local dirty = remove("/wt/pr5", "feature")
	eq(dirty[1], nil, "a dirty worktree is not removed")
	has(dirty[2], "uncommitted changes", "problem")
	eq(dirty[3], true, "and reported dirty")
	eq(listed("/wt/pr5"), true, "it is still there")
	eq(countLog(g, "worktree remove /wt/pr5"), 1, "git was asked once, without force")
	for _, line in g.log do
		if string.sub(line, 1, 15) == "worktree remove" then
			lacks(line, "--force", "no --force")
			lacks(line, " -f", "no -f")
		end
	end
	g.dirty["/wt/pr5"] = nil
	local ok = remove("/wt/pr5", "feature")
	eq(ok[2], nil, "problem")
	yes(ok[1], "a removal")
	eq(listed("/wt/pr5"), false, "the clean worktree is gone")
	eq(countLog(g, "branch -d feature"), 1, "its branch is deleted without force")
	eq(countLog(g, "branch -D"), 0, "never with -D: the pull request's fetched ref is not there to compare with")
	local unmerged = remove("/wt/um", "um")
	eq(listed("/wt/um"), false, "the worktree of an unmerged branch is removed")
	yes(unmerged[1], "a removal")
	has(unmerged[1].branch, "kept", "the removal says the branch was kept")
	eq(g.refs["refs/heads/um"], sha("b"), "but its unmerged branch is kept")
	eq(countLog(g, "branch -D"), 0, "and still never forced")
	local det = remove("/wt/det", nil)
	eq(det[2], nil, "problem")
	eq(det[1].branch, "It had no branch.", "a detached worktree has no branch to drop")
	eq(listed("/wt/det"), false, "and is removed")
	eq(countLog(g, "branch -d um"), 0, "no branch command for a branch Plotroom did not note")
	eq(countLog(g, "branch -D"), 0, "and none was ever forced")
end)

case("worktree.inventoryDirty: re-reads git's list for the path and branch before reading its status", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	local function dirty(path: string, branch: string?): any
		return asks.bk.pack(w, function(done)
			worktree.inventoryDirty("/work/r", "o/r", path, branch, done)
		end)
	end
	local clean = dirty("/wt/pr5", "feature")
	eq(clean[1], false, "clean")
	eq(clean[2], nil, "no problem")
	eq(countLog(g, "status --porcelain --untracked-files=normal"), 1, "status read once")
	g.dirty["/wt/pr5"] = "?? new.txt\n"
	eq(dirty("/wt/pr5", "feature")[1], true, "dirty")
	local marks = countLog(g, "status")
	has(dirty("/work/r", "main")[2], "main checkout", "the main checkout is refused")
	has(dirty("/wt/pr5", "changed")[2], "changed", "another branch than remembered is refused")
	has(dirty("/wt/gone", "gn")[2], "gone", "a missing folder is reported")
	eq(countLog(g, "status"), marks, "none of them read a status")
	for i, t in g.worktrees do
		if t.path == "/wt/pr5" then
			table.remove(g.worktrees, i)
			break
		end
	end
	local away = dirty("/wt/pr5", "feature")
	eq(away[1], nil, "a worktree git no longer lists has no answer")
	has(away[2], "not a worktree", "problem")
	eq(countLog(g, "status"), marks, "and no status was read")
end)

-- A checkout with the worktree /wt/x on my-feat at sha("c"), two commits over main, which the remote serves at sha("1").
function asks.bk.drafted(w: World): Git
	local g = asks.bk.repo(w)
	asks.bk.tree(w, g, "/wt/x", "my-feat", sha("c"))
	g.served["refs/heads/main"] = sha("1")
	g.counts[sha("c")] = 2
	return g
end

case("worktree.draftPreview: reads the branch and its commits over the base fetched read-only, writing nothing but its tracking ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	local function preview(base: string): any
		return asks.bk.pack(w, function(done)
			worktree.draftPreview("/wt/x", "o/r", base, done)
		end)
	end
	local got = preview("main")
	eq(got[2], nil, "problem")
	local d = got[1]
	eq(d.branch, "my-feat", "branch")
	eq(d.head, sha("c"), "head")
	eq(d.base, "main", "base")
	eq(d.baseSha, sha("1"), "the base as just fetched")
	eq(d.count, 2, "commits over the base")
	eq(#d.commits, 2, "listed")
	eq(d.remote, "origin", "the remote of o/r")
	eq(d.path, "/wt/x", "path")
	eq(d.title, "my feat", "a title from the branch name")
	eq(d.needsPush, true, "the remote has no such branch")
	eq(d.remoteHead, nil, "so no remote head")
	eq(d.dirty, false, "clean")
	eq(countLog(g, "fetch"), 1, "one fetch")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "of the chosen base, into its tracking ref only")
	eq(g.refs["refs/remotes/origin/main"], sha("1"), "which holds the remote's commit")
	for _, never in { "push", "worktree add", "worktree remove", "branch" } do
		eq(countLog(g, never), 0, "git " .. never .. " was not run")
	end
	g.refs["refs/remotes/origin/my-feat"] = sha("c")
	local pushed = preview("main")[1]
	eq(pushed.needsPush, false, "the remote already has this commit")
	eq(pushed.remoteHead, sha("c"), "remote head")
	g.served["refs/heads/develop"] = sha("2")
	local other = preview("develop")[1]
	eq(other.baseSha, sha("2"), "another base is read from its own tracking ref")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head origin +refs/heads/develop:refs/remotes/origin/develop"), 1, "after fetching exactly that base")
end)

case("worktree.draftPreview: a detached HEAD, the base itself, no commits, a bad or unfetched base are refused", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	local function refused(base: string, what: string)
		local got = asks.bk.pack(w, function(done)
			worktree.draftPreview("/wt/x", "o/r", base, done)
		end)
		eq(got[1], nil, what .. ": no draft")
		yes(type(got[2]) == "string" and got[2] ~= "", what .. ": an actionable problem")
	end
	local tree = g.worktrees[2]
	tree.branch = nil
	refused("main", "a detached HEAD")
	eq(countLog(g, "fetch"), 0, "nothing was fetched for it")
	tree.branch = "refs/heads/my-feat"
	refused("my-feat", "the base is the current branch")
	yes(countLog(g, "fetch") <= 1, "at most the read-only base fetch ran")
	eq(countLog(g, "push") + countLog(g, "worktree add") + countLog(g, "worktree remove"), 0, "nothing was written")
	g.counts[sha("c")] = 0
	refused("main", "a branch with no commits over the base")
	g.counts[sha("c")] = 2
	local fetches = countLog(g, "fetch")
	refused("bad name", "a base git rejects")
	eq(countLog(g, "fetch"), fetches, "which is not fetched")
	refused("gone", "a base the remote does not have")
	eq(countLog(g, "fetch"), fetches + 1, "its fetch was tried")
	eq(g.refs["refs/remotes/origin/gone"], nil, "and left nothing behind")
	eq(countLog(g, "push"), 0, "nothing was ever pushed")
end)

case("worktree.pushBranch: pushes exactly the previewed commit unforced, and only while the branch and commit still hold", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	local function preview(): any
		return asks.bk.pack(w, function(done)
			worktree.draftPreview("/wt/x", "o/r", "main", done)
		end)[1]
	end
	local function push(d: any): any
		return asks.bk.pack(w, function(done)
			worktree.pushBranch(d, done)
		end)[1]
	end
	local d = preview()
	eq(push(d), nil, "pushed")
	eq(#g.pushes, 1, "one push")
	eq(g.pushes[1], "push --no-force-with-lease origin " .. sha("c") .. ":refs/heads/my-feat", "the previewed commit to the previewed branch")
	for _, call in w.calls do
		for _, arg in call.argv do
			for _, forced in { "--force", "-f", "--force-with-lease", "--mirror", "--delete", "+" .. sha("c") .. ":refs/heads/my-feat" } do
				eq(arg == forced, false, "git was given no " .. forced)
			end
		end
	end
	g.worktrees[2].head = sha("d")
	has(push(d), "moved since the preview", "a HEAD that moved")
	g.worktrees[2].head = sha("c")
	g.worktrees[2].branch = "refs/heads/other"
	has(push(d), "moved since the preview", "another branch")
	g.worktrees[2].branch = nil
	has(push(d), "detached", "a detached HEAD")
	g.worktrees[2].branch = "refs/heads/my-feat"
	eq(#g.pushes, 1, "none of those pushed")
	-- a draft whose branch is already on the remote (needsPush false) is checked again as well
	g.refs["refs/remotes/origin/my-feat"] = sha("c")
	local synced = preview()
	eq(synced.needsPush, false, "nothing to push at preview")
	g.worktrees[2].head = sha("d")
	has(push(synced), "moved since the preview", "a HEAD that moved after a preview that needed no push")
	eq(#g.pushes, 1, "still no push")
	g.worktrees[2].head = sha("c")
	g.pushFail = { status = 1, stderr = "! [rejected] my-feat -> my-feat (non-fast-forward)\nerror: failed to push some refs\n" }
	has(push(d), "refused", "a rejected push is the problem")
	eq(#g.pushes, 2, "tried once, never retried with force")
	g.remotes.origin = { "https://github.com/o/other.git" }
	local lost = push(d)
	yes(lost ~= nil, "a checkout whose remote is no longer o/r's is refused")
	eq(#g.pushes, 2, "and nothing was pushed")
end)

case("worktree.draftDestinations: GitHub remotes only, origin first, one per repository, none is a problem", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.repo(w)
	local function dest(): (any, any)
		local got = asks.bk.pack(w, function(done)
			worktree.draftDestinations("/work/r", done)
		end)
		return got[1], got[2]
	end
	local function show_(list: any): string
		local out: { string } = {}
		for _, d in list do
			table.insert(out, d.remote .. "=" .. d.repo)
		end
		return table.concat(out, ",")
	end
	local list, problem = dest()
	eq(problem, nil, "problem")
	eq(show_(list), "origin=o/r", "one remote")
	g.remotes.fork = { "https://github.com/O/R.git" }
	eq(show_((dest())), "origin=o/r", "the same repository twice is listed once")
	g.remotes.fork = { "https://github.com/me/r.git" }
	g.remotes.lab = { "https://gitlab.com/me/r.git" }
	eq(show_((dest())), "origin=o/r,fork=me/r", "two repositories, origin first, gitlab ignored")
	g.remotes = { lab = { "https://gitlab.com/me/r.git" } }
	local none, why = dest()
	eq(none, nil, "no GitHub remote: no list")
	yes(why ~= nil, "and a problem")
end)

case("worktree: draftPreview and remoteBranches resolve the remote of the repository asked for", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	g.remotes.fork = { "https://github.com/me/r.git" }
	g.served["refs/heads/main"] = sha("1")
	local got = asks.bk.pack(w, function(done)
		worktree.draftPreview("/wt/x", "me/r", "main", done)
	end)
	eq(got[2], nil, "problem")
	eq(got[1].remote, "fork", "the draft's remote")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head fork +refs/heads/main:refs/remotes/fork/main"), 1, "the fetch names that remote")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head origin"), 0, "and not origin")
	asks.bk.pack(w, function(done)
		worktree.remoteBranches("/wt/x", "me/r", done)
	end)
	eq(countLog(g, "ls-remote --symref fork"), 1, "remoteBranches lists that remote's branches")
	eq(countLog(g, "ls-remote --symref origin"), 0, "not origin's")
end)
-- END backend cases

-- ---------------------------------------------------------------- runner

-- ---------------------------------------------------------------- window flows (flows.luau)

type FlowStub = { reply: (string, any) -> any, link: (string, string) -> (), ops: () -> { string } }

-- A Plotroom block's host that answers by hand: `reply(op, answer)` answers the oldest unanswered request of that op
-- (through the block's hidden r<id> node and its rpc link) and returns the request; `link(node id, href)` keeps a
-- hidden link node the window validates a link against.
local function flowHost(w: World, pane: number?): FlowStub
	local at = pane or 1
	local main: { any } = { { id = "main.rpc", p = { text = asks.protocol, hidden = true } }, { id = "main.more", p = { href = "plotroom://more", hidden = true } } }
	-- The host acknowledges an agent-status event by publishing main.agents: the sorted `key=state;` signature.
	local session: any = w.cx.session
	local sendEvent = session.event
	session.event = function(self: any, id: number, ev: { [string]: any })
		sendEvent(self, id, ev)
		if id == at and ev.act == "agent-status" then
			local map: any = jsonDecode(ev.value)
			local keys: { string } = {}
			for k in map do
				table.insert(keys, k)
			end
			table.sort(keys)
			local sig = ""
			for _, k in keys do
				sig ..= k .. "=" .. map[k] .. ";"
			end
			for i = #main, 1, -1 do
				if main[i].id == "main.agents" then
					table.remove(main, i)
				end
			end
			table.insert(main, { id = "main.agents", p = { text = sig, hidden = true } })
		end
	end
	local layer: { any } = {}
	w.window.surfaces[at] = { main = { id = "main", c = main }, layer = { id = "layer", c = layer } }
	local done: { [string]: boolean } = {}
	for _, q in requestsSent(w) do
		done[q.id] = true -- what was asked before this stub is not its to answer
	end
	return {
		reply = function(op: string, answer: any): any
			for _, q in requestsSent(w) do
				if q.op == op and not done[q.id] then
					done[q.id] = true
					table.insert(main, { id = "main.r" .. q.id, p = { text = jsonEncode(answer), hidden = true } })
					w.click("plotroom://rpc/" .. q.id, at)
					w.flush()
					return q
				end
			end
			error("no unanswered request of op " .. op, 2)
		end,
		link = function(id: string, href: string)
			table.insert(layer, { id = id, p = { href = href } })
		end,
		ops = function(): { string }
			local out: { string } = {}
			for _, q in requestsSent(w) do
				table.insert(out, q.op)
			end
			return out
		end,
	}
end

local function flowRows(pick: any): { string }
	local out: { string } = {}
	for _, item in pick.items do
		table.insert(out, item.label)
	end
	return out
end

-- An agent block `pane` in a tab of its own on host `hostId`, linked to `key` in kv (as the window would have kept it).
local function seedAgent(w: World, pane: number, state: string, hostId: number, key: string)
	w.window.panes[pane] = { cwd = "/wt/seed" .. pane, tab = pane }
	table.insert(w.window.tabs, { id = pane, session = 1 })
	w.window.agentStates[pane] = state
	w.window.hostOf[pane] = hostId
	local links: any = w.kv.get("agent-links") or {}
	table.insert(links, { key = key, agent = pane, host = { id = hostId, name = "", address = if hostId == 1 then "" else "host" .. hostId }, at = 1 })
	w.kv.put("agent-links", links)
end

local function statusEvents(w: World): { any }
	local out: { any } = {}
	for _, e in w.window.events do
		if e.ev.act == "agent-status" then
			table.insert(out, { pane = e.pane, map = jsonDecode(e.ev.value) })
		end
	end
	return out
end

-- Starts an agent on o/r#5 through the real link flow: menu pick, worktree answer, cx.agents:start.
local function startAgentOn(w: World, st: FlowStub)
	st.link("layer.queue.buttons.agent", "plotroom://github/agent/o/r/5")
	w.window.choose = "Review"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	st.reply("menu", { items = { { label = "Review", send = "Review {url}", worktree = true } } })
	st.reply("worktree", { path = "/wt/r5", summary = "Created", created = true, current = true })
end

windowCase("window flows: an agent started from a block is linked in kv and the block hears its state", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	eq(#w.window.agents, 1, "the agent started")
	local links: any = w.kv.get("agent-links")
	eq(#links, 1, "one link kept")
	eq(links[1].key, "o/r#5", "under the lowercase item key")
	eq(links[1].host.id, 1, "with the block's host")
	eq(w.window.agentStates[links[1].agent], "working", "to the agent block the start made")
	local status = statusEvents(w)
	eq(#status, 1, "the block was told at once")
	same(status[1].map, { ["o/r#5"] = "working" }, "the state of the key")
	eq(status[1].pane, 1, "the Plotroom block")
	w.advance(4100)
	eq(#statusEvents(w), 1, "nothing changed: nothing more is sent")
	w.window.agentStates[links[1].agent] = "waiting_input"
	w.advance(4000)
	eq(#statusEvents(w), 2, "a changed state is sent")
	same(statusEvents(w)[2].map, { ["o/r#5"] = "waiting_input" }, "in full")
	w.window.panes[links[1].agent] = nil
	w.advance(4000)
	same(statusEvents(w)[3].map, { ["o/r#5"] = "exited" }, "a closed agent pane is exited")
	w.advance(12000)
	eq(#statusEvents(w), 3, "and then it is quiet")
end)

windowCase("window flows: links survive a plugin VM reboot (kv) and the timer starts again with the window", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "idle", 1, "o/r#5")
	w.advance(10000)
	eq(#statusEvents(w), 0, "nothing runs before a window event starts the timer")
	local start: any = w.window.handlers.window_start
	start(w.cx)
	w.advance(4100)
	same(statusEvents(w)[1].map, { ["o/r#5"] = "idle" }, "the saved link gives the state")
	w.window.choose = nil
	w.click("plotroom://github/agentgo/o/r/5")
	eq(w.window.focused, 50, "the link focuses the recorded agent")
end)

local function announce(w: World, pane: number, text: string?)
	w.window.surfaces[pane] = if text then { main = { id = "main", c = { { id = "main.rpc", p = { text = text, hidden = true } } } } } else {}
end

local function protocolWarning(w: World, pane: number): string?
	local segments = (w.window.status :: any)({ pane = pane })
	return if segments then segments[1].text else nil
end

windowCase("window status: a mismatched host warns while its block is focused, a missing marker waits, and it follows the host back to a match", function(w: World)
	w.load("window")
	announce(w, 1, "2")
	w.window.handlers.window_start(w.cx)
	eq(protocolWarning(w, 1), "Plotroom protocol mismatch", "an announcement of another protocol warns at once")
	eq(w.window.refreshes, 1, "the status line was redrawn")
	announce(w, 1, "17")
	w.advance(2100)
	eq(protocolWarning(w, 1), nil, "a reloaded host that matches clears it while focused")
	announce(w, 1, "3")
	w.advance(2000)
	eq(protocolWarning(w, 1), "Plotroom protocol mismatch", "and a later mismatch warns again")
	announce(w, 1, nil)
	w.advance(2000)
	eq(protocolWarning(w, 1), nil, "a host that has not announced yet is loading, not mismatched")
	announce(w, 1, "17")
	w.advance(2000)
	eq(protocolWarning(w, 1), nil, "and its marker arriving as a match stays quiet")
	local before = w.window.refreshes
	w.advance(10000)
	eq(w.window.refreshes, before, "polling with no change redraws nothing")
	eq(w.window.reads[1], 11, "one read at start, one at load and one per tick: a single timer")
end)

windowCase("window status: a window loaded while a Plotroom block is focused checks without any lifecycle event, with one timer", function(w: World)
	announce(w, 1, "2")
	w.load("window")
	eq(protocolWarning(w, 1), nil, "nothing is read while the plugin loads")
	w.advance(1)
	eq(protocolWarning(w, 1), "Plotroom protocol mismatch", "the load's own check warns")
	eq(w.window.reads[1], 1, "with one read")
	w.window.handlers.focus({ pane = 1, tab = 1 }, w.cx)
	w.window.handlers.window_start(w.cx)
	eq(w.window.reads[1], 3, "events check at once")
	w.advance(2000)
	eq(w.window.reads[1], 4, "and add no second timer")
	w.advance(6000)
	eq(w.window.reads[1], 7, "one read per tick afterwards")
end)

windowCase("window status: only the focused Plotroom pane is checked, and leaving it stops the polling and the warning", function(w: World)
	w.load("window")
	w.window.panes[2] = { block = "plugin.terminal", cwd = "/", tab = 1 }
	w.window.panes[3] = { block = "plugin.plotroom.prs", cwd = "/work/r", tab = 1 }
	announce(w, 1, "2")
	announce(w, 3, "17")
	w.window.handlers.pane_created({ pane = 3 }, w.cx)
	eq(protocolWarning(w, 1), "Plotroom protocol mismatch", "the focused pane's host is checked")
	eq(w.window.reads[3], nil, "an unfocused Plotroom pane is not read")
	w.window.focused = 3
	w.window.handlers.focus({ pane = 3, tab = 1 }, w.cx)
	eq(protocolWarning(w, 1), nil, "another matching pane does not carry the first one's warning")
	eq(w.window.reads[3], 1, "the newly focused pane is read at once")
	w.window.focused = 2
	w.window.handlers.focus({ pane = 2, tab = 1 }, w.cx)
	local reads = { w.window.reads[1], w.window.reads[3] }
	w.advance(20000)
	same({ w.window.reads[1], w.window.reads[3] }, reads, "an unrelated pane stops the polling")
	w.window.focused = 1
	w.window.handlers.focus({ pane = 1, tab = 1 }, w.cx)
	eq(protocolWarning(w, 1), "Plotroom protocol mismatch", "focus back checks at once")
	w.window.panes[1] = nil
	w.window.focused = 2
	w.window.handlers.pane_closed({ pane = 1 }, w.cx)
	eq(protocolWarning(w, 1), nil, "a closed pane's warning is cleared")
end)

windowCase("window flows: a link recorded for another host is ignored, and an agent on another host is not linked", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/x/y/1")
	seedAgent(w, 51, "idle", 2, "x/y#1")
	seedAgent(w, 52, "idle", 1, "o/r#9")
	w.window.handlers.window_start(w.cx)
	w.advance(4100)
	same(statusEvents(w)[1].map, { ["o/r#9"] = "idle" }, "the other host's key is not in this block's map")
	w.window.focused = 1
	local said = #w.toasts
	w.click("plotroom://github/agentgo/x/y/1")
	eq(w.window.focused, 1, "its agent is not focused")
	eq(w.toasts[said + 1].text, "No agent is running for x/y#1", "and the link says so")
	-- a new agent block on another host than the block: no link
	local before = #(w.kv.get("agent-links") :: any)
	w.window.hostOf = setmetatable({ [1] = 1 }, { __index = function() return 2 end }) :: any
	startAgentOn(w, st)
	eq(#w.window.agents, 1, "the agent started")
	eq(#(w.kv.get("agent-links") :: any), before, "but no link was saved")
end)

windowCase("window flows: a malformed agent-links store is never written over", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.kv.put("agent-links", { { key = 5 } })
	local before = w.kv.store["agent-links"]
	startAgentOn(w, st)
	eq(#w.window.agents, 1, "the agent started")
	eq(w.kv.store["agent-links"], before, "the store is as it was")
	eq(w.toasts[#w.toasts - 1].text, "Agent started, but not linked to o/r#5", "and the user is told")
end)

windowCase("window flows: an agent link switches to the exact recorded pane, even with other agents in the same folder", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "idle", 1, "o/r#4")
	seedAgent(w, 51, "working", 1, "o/r#5")
	w.window.panes[50].cwd = w.window.panes[51].cwd
	w.click("plotroom://github/agentgo/o/r/5")
	eq(w.window.focused, 51, "the recorded pane, not a pane in the same cwd")
	eq(w.window.switches[#w.window.switches], 1, "in its session")
	local said = #w.toasts
	w.click("plotroom://github/agentgo/o/r/6")
	eq(w.toasts[said + 1].level, "error", "a link its node does not carry is refused")
end)

windowCase("window flows: a live agent is offered before another is started", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agent", "plotroom://github/agent/o/r/5")
	seedAgent(w, 50, "waiting_input", 1, "o/r#5")
	w.window.choose = "Go to agent (needs input)"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	same(flowRows(w.window.picks[1]), { "Go to agent (needs input)", "Start another agent" }, "the existing agent first")
	same(st.ops(), {}, "the saved actions are not even asked for")
	eq(w.window.focused, 50, "going to it focuses it")
	w.window.choose = "Start another agent"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	same(st.ops(), { "menu" }, "another agent leads to the usual menu")
	-- an exited agent is not offered
	w.window.agentStates[50] = "exited"
	local picks = #w.window.picks
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	same(st.ops(), { "menu", "menu" }, "the menu again")
	eq(#w.window.picks, picks, "with nothing offered before it")
end)

windowCase("window flows: a plan is confirmed Cancel first, and nothing is committed on Cancel, dismissal or a target row", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function plan(token: string)
		w.command("assign-me")
		w.flush()
		st.reply("act", { token = token, confirm = { head = "Assign o/r#7 to you?", label = "Assign", lines = { "o/r#7", "as octocat" } } })
	end
	plan("t1")
	same(flowRows(w.window.picks[1]), { "Cancel", "Assign", "o/r#7", "as octocat" }, "Cancel, the commit choice, then the target lines")
	eq(w.window.picks[1].placeholder, "Assign o/r#7 to you?", "the host's head")
	w.window.choose = nil
	plan("t2")
	w.window.choose = "Cancel"
	plan("t3")
	w.window.choose = "o/r#7"
	plan("t4")
	same(st.ops(), { "act", "act", "act", "act" }, "no commit for a dismissal, Cancel or a target row")
	w.window.choose = "Assign"
	plan("t5")
	local ops = st.ops()
	eq(ops[#ops], "commit", "the choice commits")
	local commit = st.reply("commit", { ok = true, message = "Assigned", url = "https://github.com/o/r/issues/7" })
	eq(commit.token, "t5", "with the token of this very plan")
	eq(w.toasts[#w.toasts].text, "Assigned", "the result is told")
	eq(w.toasts[#w.toasts].sub, "https://github.com/o/r/issues/7", "with its link")
	w.command("assign-me")
	w.flush()
	st.reply("act", { problem = "Already assigned" })
	eq(w.toasts[#w.toasts].level, "error", "a refusal is an error")
	eq(w.toasts[#w.toasts].sub, "Already assigned", "that says why")
end)

windowCase("window flows: labels and Jira transitions offer exactly what the host lists", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.typed = "  bug "
	w.command("label-add")
	w.flush()
	eq(st.reply("act", { problem = "stop" }).label, "bug", "the typed label, trimmed")
	w.command("label-remove")
	w.flush()
	st.reply("ctx", { item = { kind = "issue", tracker = "github", repo = "o/r", ref = "7", key = "o/r#7", labels = { "a", "b" } } })
	same(flowRows(w.window.picks[#w.window.picks]), { "a", "b" }, "the item's labels")
	w.window.choose = "b"
	w.command("label-remove")
	w.flush()
	st.reply("ctx", { item = { key = "o/r#7", labels = { "a", "b" } } })
	local removed = st.reply("act", { problem = "stop" })
	eq(removed.name .. ":" .. removed.label, "label-remove:b", "the picked label")
	w.window.choose = "Done"
	w.command("jira-transition")
	w.flush()
	local options: { any } = {}
	options[1] = { id = "11", name = "Done" }
	options[2] = { id = "21", name = "In Progress" }
	options[3] = { id = 3, name = "Bad" }
	local listed = { options = options, current = "In Progress" }
	st.reply("act", listed)
	same(flowRows(w.window.picks[#w.window.picks]), { "Done", "In Progress" }, "exactly the usable options")
	local plan = st.reply("act", { token = "j1", confirm = { head = "Move ABC-1 to Done?", label = "Move", lines = { "ABC-1" } } })
	eq(plan.to, "11", "the picked option's id")
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Move", "ABC-1" }, "then the plan, Cancel first")
	local after = st.ops()
	eq(after[#after], "act", "and no commit unless chosen")
end)

windowCase("window flows: the draft PR flow asks info, destination, bases, preview, edits, plan, confirm, then commits", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local reviews = 0
	w.window.decide = function(opts: any): (string?, boolean?)
		local ph: string = opts.placeholder or ""
		if string.find(ph, "^Where should the draft PR") then
			return "Open the pull request on o/r", nil
		elseif string.find(ph, "^Open a draft PR from feat into") then
			return "develop", nil
		elseif string.find(ph, "^Draft PR: ") then
			reviews += 1
			return if reviews == 1 then "Edit title…" else "Create with this title and description", nil
		end
		return "Create draft PR", nil
	end
	w.window.typedQueue = { "New title" }
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "o/r", branch = "feat", path = "/wt/r5", destinations = { { repo = "o/r", remote = "origin" } } })
	same(flowRows(w.window.picks[1]), { "Open the pull request on o/r" }, "a single destination is still asked, and named")
	eq(w.window.picks[1].items[1].detail, "origin", "with its remote")
	local bases = st.reply("draft", { repo = "o/r", remote = "origin", bases = { "develop", "main" }, defaultBase = "main" })
	eq(bases.repo, "o/r", "the bases are asked for the chosen repository")
	same(flowRows(w.window.picks[2]), { "main", "develop" }, "the default base first, the others after")
	local preview = st.reply("draft", { draft = true, token = "d1", repo = "o/r", title = "Add thing", body = "Body", commits = { "abc1234 Add thing" }, branch = "feat", base = "develop", remote = "origin", count = 1, needsPush = true })
	eq(preview.base, "develop", "the preview is for the picked base")
	eq(preview.repo, "o/r", "and the chosen repository")
	eq(w.window.picks[3].items[1].label, "Cancel", "the review lists Cancel first")
	eq(w.window.picks[3].items[2].label, "Create with this title and description", "then the way on")
	eq(w.window.prompts[1].value, "Add thing", "the title edit starts from the host's title")
	local plan = st.reply("draft", { token = "p1", confirm = { head = "Push feat and create draft PR", label = "Create draft PR", lines = { "Repository: o/r", "Push feat to origin" } } })
	eq(plan.title, "New title", "the edited title is planned")
	eq(plan.body, "Body", "the body as the host made it")
	eq(plan.token, "d1", "under the preview's token")
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Create draft PR", "Repository: o/r", "Push feat to origin" }, "the plan's confirm, Cancel first")
	local phases: { string } = {}
	for _, q in requestsSent(w) do
		if q.op == "draft" then
			table.insert(phases, q.phase)
		end
	end
	same(phases, { "info", "bases", "preview", "plan" }, "phases in order")
	local ops = st.ops()
	eq(ops[#ops], "commit", "then the commit")
	local commit = st.reply("commit", { ok = true, message = "Draft PR created", url = "https://github.com/o/r/pull/9" })
	eq(commit.token, "p1", "with the plan's token")
	eq(w.toasts[#w.toasts].sub, "https://github.com/o/r/pull/9", "the toast links the PR")
end)

windowCase("window flows: several draft destinations are all offered, the chosen one gets the bases, and cancelling sends nothing more", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.choose = "Open the pull request on up/r"
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "me/r", branch = "feat", destinations = { { repo = "me/r", remote = "origin" }, { repo = "up/r", remote = "upstream" } } })
	same(flowRows(w.window.picks[1]), { "Open the pull request on me/r", "Open the pull request on up/r" }, "every destination, the default first")
	local bases = st.reply("draft", { repo = "up/r", remote = "upstream", bases = { "main" }, defaultBase = "main" })
	eq(bases.repo, "up/r", "the bases of the chosen destination")
	local sent = #requestsSent(w)
	w.window.choose = nil
	w.flush()
	eq(#requestsSent(w), sent, "a dismissed base picker sends nothing")
	-- cancelling the destination picker sends nothing after info
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "me/r", branch = "feat", destinations = { { repo = "me/r", remote = "origin" } } })
	local ops = st.ops()
	eq(ops[#ops], "draft", "only info was asked")
	eq(#requestsSent(w), sent + 1, "nothing followed a dismissed destination picker")
end)

windowCase("window flows: rerun-failed offers every failed run, plans the picked one, and sends nothing when cancelled", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local runs: { any } = {}
	for i = 1, 8 do
		table.insert(runs, { id = tostring(1000 + i), label = "CI run " .. i })
	end
	w.window.choose = "CI run 7"
	w.command("rerun-failed")
	w.flush()
	st.reply("act", { runs = runs })
	eq(#w.window.picks[1].items, 8, "all eight runs are in the picker")
	local again = st.reply("act", { token = "r1", confirm = { head = "Re-run?", label = "Re-run", lines = { "o/r run 1007" } } })
	eq(again.run, "1007", "the 7th run's id is sent")
	eq(again.name, "rerun-failed", "for the same action")
	w.window.choose = nil
	local sent = #requestsSent(w)
	w.command("rerun-failed")
	w.flush()
	st.reply("act", { runs = runs })
	eq(#requestsSent(w), sent + 1, "a cancelled run picker sends nothing more")
end)

windowCase("window flows: import asks conflicts with Skip first, maps slots, and applies only after a Cancel-first confirm", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local final = "Cancel"
	w.window.decide = function(opts: any): (string?, boolean?)
		local ph: string = opts.placeholder or ""
		if string.find(ph, "^Import: what") then
			return "Continue", nil
		elseif string.find(ph, "^Mine is already") then
			return "Replace", nil
		elseif string.find(ph, "^Review is already") then
			return "Skip", nil
		elseif string.find(ph, "^Which account") then
			return "octocat", nil
		end
		return final, nil
	end
	local entries: { any } = {}
	entries[1] = { id = 1, type = "view", kind = "prs", name = "Mine", conflict = "same-name" }
	entries[2] = { id = 2, type = "prompt", kind = "prs", name = "Review", conflict = "identical" }
	entries[3] = { id = 3, type = "view", kind = "prs", name = "New" }
	local preview: any = {
		token = "i1",
		entries = entries,
		slots = { "work" },
		accounts = { "octocat", "other" },
		problems = {},
	}
	local function run()
		w.window.typed = '{"v":1}'
		w.command("import")
		w.flush()
		return st.reply("import", preview)
	end
	local first = run()
	eq(first.text, '{"v":1}', "JSON text goes as text")
	eq(first.path, nil, "not as a path")
	local conflict: any = nil
	for _, p in w.window.picks do
		if string.find(p.placeholder or "", "^Mine is already") then
			conflict = p
		end
	end
	eq(conflict.items[1].label, "Skip", "a conflict's first row is Skip")
	eq(w.window.picks[1].items[1].label, "Cancel", "the summary opens with Cancel")
	local last: any = w.window.picks[#w.window.picks]
	eq(flowRows(last)[1], "Cancel", "the final confirm is Cancel first")
	eq(flowRows(last)[2], "Import", "then Import")
	same(st.ops(), { "import" }, "Cancel applies nothing")
	final = "Import"
	w.window.typed = "/tmp/export.json"
	w.command("import")
	w.flush()
	local second = st.reply("import", preview)
	eq(second.path, "/tmp/export.json", "anything not JSON is a file path")
	local ops = st.ops()
	eq(ops[#ops], "import", "the confirm applies")
	local apply = nil
	for _, q in requestsSent(w) do
		if q.phase == "apply" then
			apply = q
		end
	end
	eq((apply :: any).token, "i1", "with the preview's token")
	same((apply :: any).choices, { ["1"] = "replace", ["2"] = "skip" }, "only conflicts carry a choice")
	same((apply :: any).mapping, { work = "octocat" }, "and the slot the user mapped")
end)

windowCase("window flows: export confirms the host's actual counts and notes, then commits that snapshot's token", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local order = { "Mine", "Done" }
	local at = 0
	local final = "Cancel"
	w.window.typed = "/tmp/out.json"
	w.window.decide = function(opts: any): (string?, boolean?)
		local ph: string = opts.placeholder or ""
		if string.find(ph, "^Pick what to export") then
			at += 1
			return order[at], nil
		elseif string.find(ph, "^Export ") then
			return final, nil
		end
		return nil, nil
	end
	local function run(copyable: boolean): any
		at = 0
		w.command("export")
		w.flush()
		st.reply("export-list", { views = { { id = "v1", name = "Mine", kind = "prs", integration = "github" } }, prompts = { { id = "p1", name = "Review", kind = "prs" } } })
		return st.reply("export", { token = "e1", count = { views = 1, prompts = 0 }, notes = { "Review left out: it names a login" }, size = 12, copyable = copyable })
	end
	local req = run(true)
	same(req.views, { "v1" }, "the picked views")
	eq(req.phase, nil, "the first call is the preview")
	eq(#w.copied, 0, "nothing is copied before the confirm")
	local confirm: any = w.window.picks[#w.window.picks]
	same(flowRows(confirm), { "Cancel", "Copy to the clipboard", "Write to a file…", "Review left out: it names a login" }, "Cancel first, then the way out, then the host's notes")
	has(confirm.placeholder, "1 view(s), 0 action(s)", "the host's counts, not the picks")
	eq(#requestsSent(w), 2, "Cancel commits nothing")
	final = "Copy to the clipboard"
	run(true)
	local commit = st.reply("export", { ok = true, json = '{"views":1}', count = { views = 1, prompts = 0 }, notes = {} })
	eq(commit.phase, "commit", "the second call commits")
	eq(commit.token, "e1", "the snapshot the confirm showed")
	eq(commit.path, nil, "copying sends no path")
	eq(w.copied[1], '{"views":1}', "the clipboard gets the commit reply's json")
	eq(w.toasts[#w.toasts].level, "success", "and says so")
	-- too large to copy: only a file is offered
	final = "Write to a file…"
	run(false)
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Too large to copy: file only", "Write to a file…", "Review left out: it names a login" }, "no copy row")
	local file = st.reply("export", { ok = true, path = "/tmp/out.json", count = { views = 1, prompts = 0 }, notes = {} })
	eq(file.path, "/tmp/out.json", "the path goes with the commit")
	eq(#w.copied, 1, "and nothing more is copied")
end)

windowCase("window flows: Esc on the draft title prompt returns to the review with the earlier values", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local reviews = 0
	w.window.decide = function(opts: any): (string?, boolean?)
		local ph: string = opts.placeholder or ""
		if string.find(ph, "^Where should") then
			return "Open the pull request on o/r", nil
		elseif string.find(ph, "^Open a draft PR from") then
			return "main", nil
		elseif string.find(ph, "^Draft PR: ") then
			reviews += 1
			return if reviews == 1 then "Edit title…" else "Create with this title and description", nil
		end
		return "Cancel", nil
	end
	w.window.typed = nil -- Esc
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "o/r", branch = "feat", destinations = { { repo = "o/r", remote = "origin" } } })
	st.reply("draft", { repo = "o/r", remote = "origin", bases = { "main" }, defaultBase = "main" })
	st.reply("draft", { draft = true, token = "d1", repo = "o/r", title = "Add thing", body = "Body", commits = {}, branch = "feat", base = "main", remote = "origin", count = 1, needsPush = false })
	eq(reviews, 2, "the review came back after Esc")
	local plan = st.reply("draft", { token = "p1", confirm = { head = "Create", label = "Create draft PR", lines = { "Repository: o/r" } } })
	eq(plan.title, "Add thing", "the earlier title is planned")
	eq(plan.body, "Body", "and the earlier body")
end)

windowCase("window flows: an import that did nothing is info, notes are shown, remaps are listed before the confirm", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.decide = function(opts: any): (string?, boolean?)
		if string.find(opts.placeholder or "", "^Import: what") then
			return "Continue", nil
		end
		return "Import", nil
	end
	w.window.typed = '{"v":1}'
	w.command("import")
	w.flush()
	local preview: any = { token = "i2", entries = { { id = 1, type = "prompt", kind = "prs", name = "Review", remap = { "shortcut t removed: already used by Third" } } }, accounts = {}, problems = {} }
	st.reply("import", preview)
	local rows = flowRows(w.window.picks[1])
	yes(table.find(rows, "Review: shortcut t removed: already used by Third") ~= nil, "the remap is listed in the summary")
	local last = flowRows(w.window.picks[#w.window.picks])
	yes(table.find(last, "Review: shortcut t removed: already used by Third") ~= nil, "and in the final confirm")
	st.reply("import", { ok = true, nothing = true, message = "Nothing imported", notes = { "Review skipped" }, counts = { views = 0, prompts = 0 } })
	eq(w.toasts[#w.toasts].level, "info", "a no-op is never success")
	eq(w.toasts[#w.toasts].sub, "Review skipped", "its notes are shown")
end)

windowCase("window flows: agent status is resent when the block's acknowledgement is absent or differs", function(w: World)
	w.load("window")
	local st = flowHost(w)
	seedAgent(w, 50, "idle", 1, "o/r#5")
	w.window.handlers.window_start(w.cx)
	w.advance(4100)
	eq(#statusEvents(w), 1, "sent once")
	w.advance(8000)
	eq(#statusEvents(w), 1, "the host holds it: quiet")
	local main: any = (w.window.surfaces[1] :: any).main.c
	for i = #main, 1, -1 do
		if main[i].id == "main.agents" then
			table.remove(main, i)
		end
	end
	w.advance(4000)
	eq(#statusEvents(w), 2, "a host that lost its map (no acknowledgement) is told again")
	st.ops()
end)

windowCase("window flows: palette commands send plain events, and the command palette lists, in its groups, the typed prompt, the saved actions, the queue's actions and only the commands the host says apply", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function last(): any
		return w.window.events[#w.window.events].ev
	end
	local rows: { any } = {
		{ "mark-seen", "triage", "seen" },
		{ "snooze", "triage", "snooze" },
		{ "toggle-snoozed", "triage", "toggle-snoozed" },
		{ "attention", "triage", "toggle-attention" },
		{ "sort", "sort", "next" },
		{ "worktrees-open", "open-worktrees" },
	}
	for _, row in rows do
		w.command(row[1])
		same(last(), { ev = "action", act = row[2], value = row[3] }, row[1])
	end
	-- What the host says applies with no item selected, and with a GitHub issue selected.
	local nothing = {
		queue = { { id = "snoozed", label = "Show or hide snoozed", key = "", group = "View" }, { id = "settings", label = "Settings", key = "", group = "Configuration" } },
		commands = { "open-url", "export", "import", "worktrees-open" },
	}
	local issue = {
		queue = {
			{ id = "open", label = "Open in GitHub", key = "", group = "Item" },
			{ id = "seen", label = "Mark seen", key = "m", group = "Item" },
			{ id = "agent", label = "Agent picker", key = "", group = "Agents" },
			{ id = "settings", label = "Settings", key = "", group = "Configuration" },
		},
		commands = { "open-url", "export", "import", "worktrees-open", "assign-me", "label-add", "issue-close", "comment", "draft-pr" },
	}
	-- Opens the palette and answers its menu request with `ctx`: what it lists, by label, and the pick request.
	local function palette(choose: string?, ctx: any): ({ string }, any)
		w.window.choose = choose
		local picks = #w.window.picks
		w.click("plotroom://more")
		w.flush()
		local q = st.reply("menu", {
			items = { { id = "p1", label = "Review", detail = "Review {url}", key = "e", send = "Review {url}", worktree = true } },
			queue = ctx.queue,
			commands = ctx.commands,
		})
		eq(q.palette, true, "the menu is asked for the palette's queue actions and commands too")
		local pick = w.window.picks[picks + 1]
		return flowRows(pick), pick
	end
	local listed, pick = palette(nil, nothing)
	same(listed, { "Worktrees board", "Show or hide snoozed", "Open item by URL…", "Settings", "Export views and actions…", "Import views and actions…" }, "with no item selected: what needs none, in the group order, the queue's actions before the commands of their group")
	eq(pick.items[1].group, "Worktree", "Worktrees board is under Worktree")
	eq(pick.items[2].group, "View", "the view's action under View")
	st.link("layer.queue.buttons.agent", prLink("agent", "o/r", 5))
	st.link("layer.queue.buttons.prompt-p1", runLink("o/r", 5, "p1"))
	listed, pick = palette(nil, issue)
	same(listed, { "Open in GitHub", "Mark seen", "Assign to me", "Comment…", "Agent picker", "Type a prompt…", "Review", "Add label…", "Close issue…", "Draft PR…", "Worktrees board", "Open item by URL…", "Settings", "Export views and actions…", "Import views and actions…" }, "with an item selected: Item, Agents, Saved actions, then GitHub, Worktree, View and Configuration, and nothing the host did not name")
	eq(table.find(listed, "Jira transition…"), nil, "a command the host left out is not offered: no Jira transition on a GitHub issue")
	eq(table.find(listed, "Re-run failed checks"), nil, "nor a re-run without a failed run")
	eq(pick.items[1].detail, nil, "an action with no key says nothing")
	eq(pick.items[2].detail, "key m", "a queue action says its key")
	eq(pick.items[1].group, "Item", "the item's actions are the Item group")
	eq(pick.items[5].group, "Agents", "the agent picker is the Agents group")
	eq(pick.items[7].detail, "key e · Review {url}", "a saved action says its key and its text")
	eq(pick.items[6].group, "Saved actions", "under Saved actions")
	local every = {
		queue = { { id = "extra", label = "Extra", key = "", group = "Elsewhere" } },
		commands = { "rerun-failed", "rerun-all", "cancel-run", "pr-ready", "comment", "jira-transition", "label-add", "draft-pr", "export", "import", "open-url", "worktrees-open", "mark-seen", "no-such-command" },
	}
	listed = palette(nil, every)
	same(listed, { "Comment…", "Type a prompt…", "Review", "Add label…", "Ready for review…", "Jira transition…", "Re-run failed checks", "Re-run all jobs…", "Cancel running workflow…", "Draft PR…", "Worktrees board", "Open item by URL…", "Export views and actions…", "Import views and actions…", "Extra" }, "every group in its place: Item, Saved actions, GitHub, Jira, CI, Worktree, View, Configuration, then one the window does not know; a keyed command and an unknown id are never listed")
	palette("Mark seen", issue)
	same(last(), { ev = "action", act = "queue", value = "seen" }, "a queue action is sent back as the block's queue action")
	palette("Assign to me", issue)
	eq(st.ops()[#st.ops()], "act", "an item command runs its flow")
	w.window.typed = "  Looks good to me  "
	palette("Comment…", issue)
	local commentAsk = requestsSent(w)[#requestsSent(w)]
	eq(commentAsk.op, "act", "Comment asks the host")
	eq(commentAsk.name, "comment", "for a comment")
	eq(commentAsk.text, "Looks good to me", "with the typed text, trimmed")
	w.window.typed = nil
	palette("Review", issue)
	eq(st.ops()[#st.ops()], "menu", "a saved action runs through its hidden link: the host is asked for it")
	eq(requestsSent(w)[#requestsSent(w)].only, "p1", "just that one")
	st.reply("menu", { items = {} })
	w.window.typed = "Fix the flaky test"
	palette("Type a prompt…", issue)
	local wt = st.reply("worktree", { path = "/wt/five", summary = "Created", created = true, current = true })
	eq(wt.number, 5, "a typed prompt prepares the selected item's worktree, with no agent picker")
	local said = #w.toasts
	w.window.surfaces[1] = { main = { id = "main", c = { { id = "main.rpc", p = { text = asks.protocol } } } } }
	w.click("plotroom://more")
	eq(w.toasts[said + 1].level, "error", "a link the block does not carry is refused")
end)

windowCase("window flows: comment, close, reopen, ready for review, convert to draft, re-run all and cancel run ask the host to plan and only a confirmed plan is committed, Cancel first", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function plan(command: string, head: string, label: string): any
		w.command(command)
		w.flush()
		return st.reply("act", { token = "t-" .. command, confirm = { head = head, label = label, lines = { "o/r#7: Fix login", "Account: @octocat" } } })
	end
	local asked = plan("issue-close", "Close o/r#7?", "Close issue")
	eq(asked.name, "issue-close", "Close issue asks for the issue-close plan")
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Close issue", "o/r#7: Fix login", "Account: @octocat" }, "Cancel first, then the choice, then the plan's lines")
	eq(w.window.picks[#w.window.picks].placeholder, "Close o/r#7?", "under the host's question")
	same(st.ops(), { "act" }, "nothing is committed before it is confirmed")
	w.window.choose = "Cancel"
	asked = plan("issue-reopen", "Reopen o/r#7?", "Reopen issue")
	eq(asked.name, "issue-reopen", "Reopen issue asks for issue-reopen")
	asked = plan("pr-ready", "Mark o/r#7 ready for review?", "Ready for review")
	eq(asked.name, "pr-ready", "Ready for review asks for pr-ready")
	asked = plan("pr-draft", "Convert o/r#7 to a draft?", "Convert to draft")
	eq(asked.name, "pr-draft", "Convert to draft asks for pr-draft")
	same(st.ops(), { "act", "act", "act", "act" }, "Cancel committed none of the four")
	w.window.choose = "Close issue"
	plan("issue-close", "Close o/r#7?", "Close issue")
	local ops = st.ops()
	eq(ops[#ops], "commit", "the confirming row commits")
	eq(st.reply("commit", { ok = true, message = "Closed o/r#7" }).token, "t-issue-close", "with the token of that very plan")
	eq(w.toasts[#w.toasts].text, "Closed o/r#7", "and the result is told")
	w.window.typed = "  Thanks, merging\nsoon  "
	w.window.choose = "Add comment"
	w.command("comment")
	w.flush()
	local commentAsk = st.reply("act", { token = "t-comment", confirm = { head = "Comment on o/r#7?", label = "Add comment", lines = { "o/r#7: Fix login", "Comment (20 characters): Thanks, merging ⏎ soon" } } })
	eq(commentAsk.name, "comment", "Comment asks for a comment plan")
	eq(commentAsk.text, "Thanks, merging\nsoon", "with the typed text, trimmed")
	eq(st.reply("commit", { ok = true, message = "Commented on o/r#7" }).token, "t-comment", "and commits only once confirmed")
	w.window.typed = "   "
	local before = #requestsSent(w)
	w.command("comment")
	w.flush()
	eq(#requestsSent(w), before, "a blank comment asks nothing")
	w.window.typed = nil
	w.window.choose = "CI run 2"
	w.command("rerun-all")
	w.flush()
	st.reply("act", { runs = { { id = "2001", label = "CI run 1" }, { id = "2002", label = "CI run 2" } } })
	local again = requestsSent(w)[#requestsSent(w)]
	eq(again.name .. ":" .. tostring(again.run), "rerun-all:2002", "Re-run all jobs plans exactly the picked run")
	st.reply("act", { problem = "stop" })
	w.window.choose = "CI run 1"
	w.command("cancel-run")
	w.flush()
	st.reply("act", { runs = { { id = "3001", label = "CI run 1" } } })
	again = requestsSent(w)[#requestsSent(w)]
	eq(again.name .. ":" .. tostring(again.run), "cancel-run:3001", "Cancel running workflow plans exactly the picked run")
	st.reply("act", { problem = "stop" })
	w.window.choose = nil
	w.command("cancel-run")
	w.flush()
	st.reply("act", { problem = "No check of this pull request has a queued or running GitHub Actions run." })
	eq(w.toasts[#w.toasts].level, "error", "a refusal is an error")
	eq(w.toasts[#w.toasts].text, "Nothing to cancel", "titled for the command")
end)

windowCase("window flows: a Worktrees board link opens the path, or focuses the tab already there", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.wtopen", "plotroom://worktrees/open/2")
	w.click("plotroom://worktrees/open/2")
	w.flush()
	local req = st.reply("worktree-path", { path = "/wt/one" })
	eq(req.n, 2, "row 2 is asked for")
	eq(w.window.launches[1].cwd, "/wt/one", "a tab opens at its path")
	local tabs = #w.window.launches
	w.click("plotroom://worktrees/open/2")
	w.flush()
	st.reply("worktree-path", { path = "/wt/one" })
	eq(#w.window.launches, tabs, "a tab already working there is focused instead")
	yes(w.window.focused ~= 1, "and focused")
	local said = #w.toasts
	w.click("plotroom://worktrees/open/3")
	eq(w.toasts[said + 1].level, "error", "a row the node does not carry is refused")
end)

windowCase("window flows: Open item by URL reuses a Plotroom block, and launches one (waiting for it) when there is none", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.typed = "https://github.com/o/r/pull/5"
	w.command("open-url")
	w.flush()
	local req = st.reply("open-url", { ok = true, message = "Opened o/r#5" })
	eq(req.url, "https://github.com/o/r/pull/5", "the URL goes to the block")
	eq(#w.window.launches, 0, "no block is launched")
	eq(w.toasts[#w.toasts].text, "Opened o/r#5", "the answer is told")
	-- no Plotroom block: launch one, wait for its protocol node, then send
	w.window.panes[1].block = nil
	w.window.surfaces[1] = nil
	w.command("open-url")
	w.flush()
	eq(#w.window.launches, 1, "a block is launched")
	local launched = 0
	for id, p in w.window.panes do
		if p.block == "plotroom.prs" then
			launched = id
		end
	end
	w.advance(1200)
	same(st.ops(), { "open-url" }, "nothing is sent while the block is not ready")
	local st2 = flowHost(w, launched)
	w.advance(2000)
	same(st2.ops(), { "open-url", "open-url" }, "once it says its protocol the URL is sent, to the launched block")
	st2.reply("open-url", { problem = "Not an item URL" })
	eq(w.toasts[#w.toasts].level, "error", "a refusal is an error")
	-- never ready: a toast, after about ten seconds
	w.window.panes[launched] = nil
	w.window.surfaces[launched] = nil
	w.command("open-url")
	w.flush()
	w.advance(11000)
	eq(w.toasts[#w.toasts].text, "Plotroom did not start in time", "a block that never answers is given up on")
end)

-- BEGIN host workflow cases
-- Triage, sorts, agent status, item mutations, draft pull requests, the Worktrees board, export and import, open by URL.
-- Helpers hang on `asks.hx` (one top-level local): this file is at Luau's local limit.
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

-- The window's `agent-status` report.
function asks.hx.agents(b: Block, map: { [string]: string })
	b.event({ ev = "action", act = "agent-status", value = jsonEncode(map) })
end

-- Sends the block a request as the window does and returns its answer once everything it started has finished.
function asks.hx.ask(w: World, b: Block, body: { [string]: any }): any
	asks.hx.seq += 1
	local id = "h" .. asks.hx.seq
	request(b, id, body)
	w.flush()
	return answerOf(b, id)
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

case("host triage: unseen rows are New, picking a row marks it seen on its own and saves kv triage, a refresh writes nothing, a changed check or review shows Changed on a row nobody reads and is marked again on the row being read", function(w: World)
	local s = hostScene(w, 3)
	local b = hx.openBare(w)
	same(asks.hx.marks(b), { "New", "New", "New" }, "nothing was marked seen yet")
	eq(w.kv.store["triage"], nil, "and nothing is saved: no row is selected")
	local said = #w.toasts
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_231", "Down picks the first row")
	same(asks.hx.marks(b), { "-", "New", "New" }, "its preview marks it seen")
	eq(#w.toasts, said, "without a toast")
	local saved: any = w.kv.get("triage")
	eq(saved.version, 1, "the store is versioned")
	same(asks.hx.keys(saved.items), { "o/r#1" }, "and holds the one row")
	eq(#saved.items["o/r#1"].seen, 16, "by its signature")
	b.press("down")
	same(asks.hx.marks(b), { "-", "-", "New" }, "moving on marks the next one too")
	b.press("up")
	b.press("escape")
	eq(pickerOf(b).selected, nil, "Escape closes the preview")
	local text = w.kv.store["triage"]
	refreshNow(w, b)
	eq(w.kv.store["triage"], text, "a refresh writes nothing")
	same(asks.hx.marks(b), { "-", "-", "New" }, "the refreshed rows are still seen")
	s.gh.items.octocat[1] = searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE" })
	refreshNow(w, b)
	same(asks.hx.marks(b), { "Changed", "-", "New" }, "the same update time with new checks is Changed on a row nobody has open")
	eq(w.kv.store["triage"], text, "showing it writes nothing")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	same(asks.hx.marks(b), { "-", "-", "New" }, "opening it marks it seen again")
	local again = w.kv.store["triage"]
	yes(again ~= text, "and saves that")
	s.gh.items.octocat[1] = searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE", review = "REVIEW_REQUIRED" })
	refreshNow(w, b)
	same(asks.hx.marks(b), { "-", "-", "New" }, "a new review decision on the row being read is marked at once")
	yes(w.kv.store["triage"] ~= again, "with its new signature saved")
	b.typeText("m")
	eq(w.toasts[#w.toasts].text, "Marked seen", "m still marks and says so")
end)

case("host triage: a poll and a closed preview mark nothing seen, and a save that fails is told once and tried again only when the row changes", function(w: World)
	local s = hostScene(w, 3)
	local b = hx.openBare(w)
	w.advance(10 * 60 * 1000)
	eq(w.kv.store["triage"], nil, "polls with no row selected mark nothing")
	w.kv.failSet["triage"] = "read-only file system"
	b.press("down")
	eq(w.toasts[#w.toasts].level, "error", "a save that fails is an error toast")
	eq(w.toasts[#w.toasts].text, "Not saved", "saying nothing was saved")
	same(asks.hx.marks(b), { "New", "New", "New" }, "the row stays New")
	local told = #w.toasts
	b.render()
	b.render()
	w.advance(61 * 1000)
	eq(#w.toasts, told, "later renders and polls do not try again, or tell again")
	w.kv.failSet["triage"] = nil
	b.render()
	eq(w.kv.store["triage"], nil, "even once the disk works")
	s.gh.items.octocat[1] = searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE" })
	refreshNow(w, b)
	same(asks.hx.marks(b), { "-", "New", "New" }, "a change to the row tries again, and saves")
end)

case("host triage: z snoozes the selected row until 08:00 tomorrow and selects no neighbour, Z lists snoozed rows with a Snoozed badge, z on one ends the snooze, and a snooze that ran out hides nothing", function(w: World)
	hostScene(w, 3)
	local b = hx.openBare(w)
	local all = { "no_2fr_231", "no_2fr_232", "no_2fr_233" }
	b.typeText("z")
	same(listed(b), all, "with no row selected z does nothing")
	eq(w.kv.store["triage"], nil, "and saves nothing")
	b.press("down")
	b.typeText("z")
	same(listed(b), { "no_2fr_232", "no_2fr_233" }, "the snoozed row leaves the list")
	eq(pickerOf(b).selected, nil, "and no neighbour is selected in its place")
	has(w.toasts[#w.toasts].text, "Snoozed until", "the toast says so")
	has(w.toasts[#w.toasts].text, "08:00", "tomorrow morning")
	local entry: any = w.kv.get("triage").items["o/r#1"]
	eq(entry.snoozeUntil, EPOCH + 20 * 3600, "saved until 08:00 the next day")
	eq(type(entry.seen), "string", "it was marked seen when it was picked; snoozing itself marks nothing")
	b.typeText("Z")
	same(listed(b), all, "Z lists the snoozed rows too")
	eq(asks.hx.mark(b, "no_2fr_231"), "Snoozed", "the snoozed one wears a Snoozed badge")
	eq(asks.hx.mark(b, "no_2fr_232"), "New", "the others keep theirs")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	b.typeText("z")
	eq(w.toasts[#w.toasts].text, "Snooze ended", "z on a snoozed row ends the snooze")
	eq(asks.hx.mark(b, "no_2fr_231"), "-", "it stays seen: ending a snooze marks nothing")
	eq(w.kv.get("triage").items["o/r#1"].snoozeUntil, nil, "and the saved snooze is gone")
	b.typeText("Z")
	same(listed(b), all, "hiding snoozed rows hides nothing while none is")
	w.kv.put("triage", { version = 1, items = { ["o/r#2"] = { at = 1, snoozeUntil = EPOCH - 10 }, ["o/r#3"] = { at = 1, snoozeUntil = EPOCH + 3600 } } })
	local c = hx.openBare(w, 2)
	same(listed(c), { "no_2fr_231", "no_2fr_232" }, "a snooze that ran out hides its row no longer, one still running does")
end)

case("host triage: n lists only rows that need attention: unseen, changed or whose agent waits for input; an idle or exited agent clears nothing", function(w: World)
	hostScene(w, 3)
	local b = hx.openBare(w)
	local all = { "no_2fr_231", "no_2fr_232", "no_2fr_233" }
	b.press("down")
	b.typeText("n")
	same(listed(b), all, "the row being read stays listed, though reading it marked it seen")
	b.press("escape")
	same(listed(b), { "no_2fr_232", "no_2fr_233" }, "closing the preview lets the seen row go")
	eq(pickerOf(b).selected, nil, "and nothing is selected in its place")
	asks.hx.agents(b, { ["o/r#1"] = "waiting_input" })
	same(listed(b), all, "an agent waiting for input brings its row back, though it was seen")
	eq(asks.hx.agent(b, "no_2fr_231"), "Needs input", "wearing its badge")
	asks.hx.agents(b, { ["o/r#1"] = "idle", ["o/r#2"] = "exited", ["o/r#3"] = "working" })
	same(listed(b), { "no_2fr_232", "no_2fr_233" }, "an idle agent does not keep a seen row on the list")
	eq(asks.hx.agent(b, "no_2fr_231"), "Idle", "though its badge is shown")
	eq(asks.hx.mark(b, "no_2fr_232"), "New", "an exited agent does not clear New")
	eq(asks.hx.mark(b, "no_2fr_233"), "New", "nor does a working one")
	b.typeText("n")
	same(listed(b), all, "n again lists every row")
end)

case("host triage: with n the selected row stays listed until the selection moves or closes, and no neighbour is selected when it goes", function(w: World)
	hostScene(w, 3)
	local b = hx.openBare(w)
	local all = { "no_2fr_231", "no_2fr_232", "no_2fr_233" }
	b.typeText("n")
	same(listed(b), all, "every row is unseen")
	b.press("down")
	same(listed(b), all, "picking the first marks it seen, and it stays while it is read")
	b.press("down")
	same(listed(b), { "no_2fr_232", "no_2fr_233" }, "moving on lets the seen row go")
	eq(pickerOf(b).selected, "no_2fr_232", "the selection is the row moved to")
	b.press("down")
	same(listed(b), { "no_2fr_233" }, "and so on down the list")
	b.press("escape")
	same(listed(b), {}, "closing the preview lets the last one go")
	eq(pickerOf(b).selected, nil, "with nothing selected in its place")
	b.press("escape")
	b.typeText("n")
	same(listed(b), all, "n again lists every row")
end)

case("host triage: a malformed or unreadable kv triage is never overwritten: marking is refused with an error toast and no row is marked", function(w: World)
	hostScene(w, 3)
	w.kv.put("triage", { version = 7, items = {} })
	local bad = w.kv.store["triage"]
	local b = openQueue(w)
	same(asks.hx.marks(b), { "-", "-", "-" }, "without a trusted store no row is marked")
	for _, key in { "m", "z" } do
		b.typeText(key)
		local t = w.toasts[#w.toasts]
		eq(t.level, "error", key .. ": an error toast")
		eq(t.text, "Not saved", key .. ": says nothing was saved")
		has(t.sub, "malformed", key .. ": and why")
		eq(w.kv.store["triage"], bad, key .. ": the saved text is untouched")
	end
	w.kv.put("triage", { version = 1, items = { ["o/r#1"] = { at = "yesterday" } } })
	local odd = w.kv.store["triage"]
	b.typeText("m")
	has(w.toasts[#w.toasts].sub, "malformed", "an entry of the wrong shape makes the store untrusted")
	eq(w.kv.store["triage"], odd, "and is left as it is")
	w.kv.failGet["triage"] = "disk offline"
	b.typeText("m")
	has(w.toasts[#w.toasts].sub, "disk offline", "an unreadable store says why")
	w.kv.failGet["triage"] = nil
	eq(w.kv.store["triage"], odd, "and is not touched")
	w.kv.put("triage", { version = 1, items = {} })
	b.typeText("m")
	eq(w.toasts[#w.toasts].text, "Marked seen", "a readable store works again")
	yes(w.kv.get("triage").items["o/r#1"] ~= nil, "and holds the mark")
end)

case("host triage: two blocks share the store: a row seen or snoozed in one reaches the other", function(w: World)
	hostScene(w, 3)
	local a = hx.openBare(w, 1)
	local c = hx.openBare(w, 2)
	same(asks.hx.marks(c), { "New", "New", "New" }, "both start with unseen rows")
	local drawn = c.renders()
	a.press("down")
	yes(c.renders() > drawn, "the other block is drawn again")
	same(asks.hx.marks(c), { "-", "New", "New" }, "and shows the row seen")
	eq(pickerOf(c).selected, nil, "without selecting anything there")
	c.press("down")
	c.typeText("z")
	same(listed(c), { "no_2fr_232", "no_2fr_233" }, "a snooze in the second block hides the row there")
	same(listed(a), { "no_2fr_232", "no_2fr_233" }, "and in the first")
	eq(pickerOf(a).selected, nil, "which drops its selection without taking a neighbour")
end)

case("host sort: a saved sort orders the list, one this view cannot take is dropped, and the Sort by row saves a choice, refuses a foreign one and resets to the default order", function(w: World)
	local s = hostScene(w, 3)
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 300), searchItem(2, "o/r", EPOCH - 60), searchItem(3, "o/r", EPOCH - 180, { review = "REVIEW_REQUIRED" }) }
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}), sort = "priority" },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", logins = array({}), group = "none", prompts = array({}), sort = "oldest" },
	}) })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "a sort pull requests do not offer is dropped: the default order stays")
	pickScope(b, "prs:v2")
	w.flush()
	same(listed(b), { "no_2fr_231", "no_2fr_233", "no_2fr_232" }, "a saved oldest-first sort orders the other view")
	pickScope(b, "prs:v1")
	w.flush()
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	eq(rowIn(b, "vsort:prs:v1").control.value, "default", "the row shows the dropped sort as the default order")
	same(asks.hx.options(b, "vsort:prs:v1"), { "default", "updated", "oldest", "review" }, "pull requests offer these three")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "review" })
	eq(w.kv.get("views-prs").items[1].sort, "review", "a choice is saved with the view")
	same(listed(b), { "no_2fr_233", "no_2fr_232", "no_2fr_231" }, "review required first, then the newest update")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "priority" })
	eq(w.kv.get("views-prs").items[1].sort, "review", "another integration's sort is refused")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "updated" })
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "the newest update first")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "default" })
	eq(w.kv.get("views-prs").items[1].sort, nil, "the default order saves no sort")
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "and is the default order")
end)

case("host sort: o cycles the view's sorts, saves each with the view and ends on the default order, which leaves the search order untouched", function(w: World)
	local s = hostScene(w, 3)
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 300), searchItem(2, "o/r", EPOCH - 60), searchItem(3, "o/r", EPOCH - 180, { review = "REVIEW_REQUIRED" }) }
	local b = openQueue(w)
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "without a sort the default order is kept")
	local steps: { { string } } = {
		{ "updated", "Sorted: Recently updated", "no_2fr_232", "no_2fr_233", "no_2fr_231" },
		{ "oldest", "Sorted: Oldest waiting", "no_2fr_231", "no_2fr_233", "no_2fr_232" },
		{ "review", "Sorted: Review required first", "no_2fr_233", "no_2fr_232", "no_2fr_231" },
	}
	for _, step in steps do
		b.typeText("o")
		eq(w.kv.get("views-prs").items[1].sort, step[1], step[1] .. ": saved with the view")
		eq(w.toasts[#w.toasts].text, step[2], step[1] .. ": the toast names it")
		same(listed(b), { step[3], step[4], step[5] }, step[1] .. ": the list follows")
	end
	b.typeText("o")
	eq(w.kv.get("views-prs").items[1].sort, nil, "after the last comes the default order, saved as none")
	eq(w.toasts[#w.toasts].text, "Sorted: Default order", "named")
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "the default order again")
	b.typeText("/")
	b.typeText("o")
	eq(pickerOf(b).query, "o", "while searching o is text")
	eq(w.kv.get("views-prs").items[1].sort, nil, "and sorts nothing")
end)

case("host sort: a Jira view offers priority alone, o turns it on and off, and GitHub issues offer updated and oldest", function(w: World)
	local s = jiraHost(w)
	s.acli.searches[JIRA_ASSIGNED] = { jiraItem("ABC-12", "Fix login", { priority = { name = "Low" } }), jiraItem("ABC-13", "Old bug", { priority = { name = "Highest" } }) }
	local b = openIssues(w)
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "acli's order without a sort")
	b.typeText("o")
	eq(w.kv.get("views-issues").items[1].sort, "priority", "o saves the one sort Jira has")
	same(listed(b), { "nabc_23ABC-13", "nabc_23ABC-12" }, "Highest before Low")
	b.typeText("o")
	eq(w.kv.get("views-issues").items[1].sort, nil, "o again is the default order")
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "acli's order")
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	same(asks.hx.options(b, "vsort:issues:v1"), { "default", "priority" }, "the Sort by row lists only that")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:issues:v1", value = "updated" })
	eq(w.kv.get("views-issues").items[1].sort, nil, "a GitHub sort is refused for a Jira view")
end)

case("host sort: GitHub issues offer updated and oldest, never a review order", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	same(asks.hx.options(b, "vsort:issues:v1"), { "default", "updated", "oldest" }, "the Sort by row lists those")
	local before = w.kv.store["views-issues"]
	b.event({ ev = "change", id = "layer.settings", item = "vsort:issues:v1", value = "review" })
	eq(w.kv.store["views-issues"], before, "an order only pull requests have is refused: nothing was written")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:issues:v1", value = "oldest" })
	eq(w.kv.get("views-issues").items[1].sort, "oldest", "oldest is saved")
	same(listed(b), { "no_2fr_2314", "no_2fr_2313", "no_2fr_2312" }, "the longest waiting issue first")
end)

case("host agents: agent-status shows a badge per row, drops values and keys it does not know, replaces the whole map and caps it at 200 keys", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	asks.hx.agents(b, { ["o/r#1"] = "working", ["o/r#2"] = "waiting_input", ["o/r#3"] = "idle" })
	same({ asks.hx.agent(b, "no_2fr_231"), asks.hx.agent(b, "no_2fr_232"), asks.hx.agent(b, "no_2fr_233") }, { "Working", "Needs input", "Idle" }, "one badge per state")
	asks.hx.agents(b, { ["o/r#3"] = "exited" })
	same({ asks.hx.agent(b, "no_2fr_231"), asks.hx.agent(b, "no_2fr_232"), asks.hx.agent(b, "no_2fr_233") }, { "-", "-", "Exited" }, "a new report replaces the whole map")
	asks.hx.agents(b, { ["o/r#1"] = "sleeping", ["o/r#2"] = "working", ["bad\nkey"] = "working" })
	same({ asks.hx.agent(b, "no_2fr_231"), asks.hx.agent(b, "no_2fr_232"), asks.hx.agent(b, "no_2fr_233") }, { "-", "Working", "-" }, "an unknown state is dropped")
	eq(b.state().agents["bad\nkey"], nil, "and so is a key with a control character")
	b.event({ ev = "action", act = "agent-status", value = string.rep("x", 40001) })
	b.event({ ev = "action", act = "agent-status", value = "not json" })
	b.event({ ev = "action", act = "agent-status", value = 5 })
	eq(asks.hx.agent(b, "no_2fr_232"), "Working", "an oversize, malformed or mistyped report changes nothing")
	local many: { [string]: string } = {}
	for i = 1, 230 do
		many["x/y#" .. i] = "working"
	end
	asks.hx.agents(b, many)
	local n = 0
	for _ in b.state().agents do
		n += 1
	end
	eq(n, 200, "at most 200 keys are kept")
end)

case("host agents: Go to agent is a button, a hidden link and the G key only for a row whose agent state is known", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	eq(actionOf(b, "agentgo"), nil, "no state yet: no button")
	eq(buttonLink(b, "agentgo"), nil, "and no link")
	eq(b.press("G", "s", "G"), false, "G is left to the pane")
	asks.hx.agents(b, { ["o/r#1"] = "working" })
	eq(actionOf(b, "agentgo").label, "Go to agent", "a known state adds the button")
	same(actionOf(b, "agentgo").keys, { "G" }, "with its key")
	eq(buttonLink(b, "agentgo"), prLink("agentgo", "o/r", 1), "and the link the window follows")
	local ids: { string } = {}
	for _, a in pickerOf(b).actions do
		table.insert(ids, a.id)
	end
	same(ids, { "settings", "retry", "worktree", "agent", "agentgo", "seen", "more" }, "after Agent, before Seen and the command palette")
	eq(b.press("G", "s", "G"), true, "G is handled")
	eq(w.opened[#w.opened], prLink("agentgo", "o/r", 1), "and opens the link")
	b.typeText("j")
	eq(actionOf(b, "agentgo"), nil, "a row with no state has no button")
	eq(buttonLink(b, "agentgo"), nil, "nor a link")
	eq(b.press("G", "s", "G"), false, "and G is the pane's again")
	asks.hx.agents(b, {})
	b.typeText("k")
	eq(actionOf(b, "agentgo"), nil, "an empty report takes the button away")
end)

case("host mutations: ctx describes the selected issue, and assign-me offers a plan naming the issue and the account that only its commit runs", function(w: World)
	local s = issueHost(w)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local ctx = asks.hx.ask(w, b, { op = "ctx" })
	eq(ctx.item.key, "o/r#12", "the selected issue")
	eq(ctx.item.kind, "issue", "an issue")
	eq(ctx.item.tracker, "github", "of GitHub")
	eq(ctx.item.repo, "o/r", "in its repository")
	eq(ctx.item.ref, "12", "with its number as the ref")
	eq(ctx.item.title, "Fix login", "and title")
	same(ctx.item.labels, { "bug", "ui" }, "its labels")
	same(ctx.item.assignees, { "ann", "bob" }, "and assignees")
	eq(ctx.view.name, "Assigned to me", "the view it is shown in")
	eq(ctx.view.integration, "github", "its integration")
	eq(ctx.worktree, nil, "no worktree")
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	yes(type(p.token) == "string" and p.token ~= "", "a plan carries its token")
	eq(p.confirm.head, "Assign o/r#12 to you?", "the question names the issue")
	eq(p.confirm.label, "Assign to me", "the confirming choice")
	eq(p.confirm.lines[1], "o/r#12: Fix login", "the first line is the issue")
	has(p.confirm.lines[2], "octocat", "the second is the account")
	eq(p.confirm.lines[3], "Current assignees: ann, bob", "the third what it has now")
	eq(#seen, 0, "a plan sends nothing")
	local done = asks.hx.ask(w, b, { op = "commit", token = p.token })
	eq(done.ok, true, "the commit answers ok")
	eq(done.message, "Assigned o/r#12 to you", "and what it did")
	same(seen, { "gh issue edit 12 --repo github.com/o/r --add-assignee=@me" }, "one gh call: assign me, nothing else")
	local sent = requestsOf(s.gh, "other")
	eq(sent[#sent].login, "octocat", "run with the token of the account the plan named")
	local pr = asks.hx.ask(w, b, { op = "act", name = "bogus" })
	eq(pr.problem, "Plotroom does not know that command.", "an unknown command is refused")
end)

case("host mutations: a commit with no token, a made-up or replaced token, after the selection, the view or five minutes changed, or twice sends nothing", function(w: World)
	local s = issueHost(w)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local function plan(): any
		return asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	end
	local function commit(token: any): any
		return asks.hx.ask(w, b, { op = "commit", token = token })
	end
	request(b, "n1", { op = "commit" })
	w.flush()
	eq(answerOf(b, "n1"), nil, "a commit with no token is not answered")
	has(commit("p1_1_123456").problem, "no longer valid", "a made-up token")
	local first = plan()
	local second = plan()
	has(commit(first.token).problem, "no longer valid", "the token of a replaced plan")
	has(commit(second.token).problem, "no longer valid", "a refused commit drops the pending plan as well")
	local moved = plan()
	b.typeText("j")
	has(commit(moved.token).problem, "selection or the view changed", "after the selection moved")
	b.typeText("k")
	local viewed = plan()
	pickScope(b, "issues:v2")
	w.flush()
	has(commit(viewed.token).problem, "selection or the view changed", "after the view changed")
	pickScope(b, "issues:v1")
	w.flush()
	hx.selectFirst(b)
	local late = plan()
	w.advance(301 * 1000)
	has(commit(late.token).problem, "nothing was sent", "after five minutes")
	eq(#seen, 0, "none of them sent anything")
	local good = plan()
	eq(commit(good.token).ok, true, "a fresh plan commits")
	eq(#seen, 1, "once")
	has(commit(good.token).problem, "no longer valid", "the same token twice")
	eq(#seen, 1, "sends nothing again")
end)

case("host mutations: label-add and label-remove check the label and the issue's labels, then run one gh issue edit with exactly that label", function(w: World)
	local s = issueHost(w)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local function act(name: string, label: any): any
		return asks.hx.ask(w, b, { op = "act", name = name, label = label })
	end
	eq(act("label-add", "bug").problem, "It already has that label.", "a label it has is not added")
	eq(act("label-remove", "nope").problem, "It does not have that label.", "one it lacks is not removed")
	for _, bad in { "", "a,b", "-x", string.rep("x", 51), "tab\tbell" } do
		has(act("label-add", bad).problem, "usable label", "refused: " .. show(bad))
	end
	has(act("label-remove", nil).problem, "usable label", "no label at all")
	eq(#seen, 0, "none of that sent anything")
	local add = act("label-add", "good first issue")
	eq(add.confirm.head, "Add label “good first issue” on o/r#12?", "the question names label and issue")
	eq(add.confirm.label, "Add label", "the confirming choice")
	eq(add.confirm.lines[3], "Add label: good first issue", "the exact label is a line")
	eq(asks.hx.ask(w, b, { op = "commit", token = add.token }).message, "Added label good first issue on o/r#12", "committed")
	local remove = act("label-remove", "ui")
	eq(remove.confirm.label, "Remove label", "removing says so")
	eq(remove.confirm.lines[3], "Remove label: ui", "and names it")
	eq(asks.hx.ask(w, b, { op = "commit", token = remove.token }).message, "Removed label ui on o/r#12", "committed")
	same(seen, {
		'gh issue edit 12 --repo github.com/o/r --add-label="good first issue"',
		'gh issue edit 12 --repo github.com/o/r --remove-label="ui"',
	}, "each is one gh call with the label as a --flag=value argument")
end)

case("host mutations: on a Jira issue assign-me runs acli, transition lists Jira's own options and plans only one of them, and labels are refused", function(w: World)
	local s = jiraHost(w)
	local ran: { string } = {}
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "other" then
			table.insert(ran, table.concat(req.argv, " "))
			return { stdout = "✓ done\n" }
		end
		return nil
	end
	w.env.PLOTROOM_JIRA_API_TOKEN = "tok"
	local reqs = asks.bk.fetch(w, function(req: any): { status: number, body: string }?
		if req.line == "GET /rest/api/3/myself" then
			return { status = 200, body = jsonEncode({ emailAddress = "ann@example.com" }) }
		elseif req.line == "GET /rest/api/3/issue/ABC-12/transitions" then
			return { status = 200, body = jsonEncode({ transitions = array({ { id = "31", name = "Done", to = { name = "Done" } }, { id = "41", name = "Back to To Do" } }) }) }
		elseif req.line == "POST /rest/api/3/issue/ABC-12/transitions" then
			return { status = 204, body = "" }
		end
		return nil
	end)
	local function posts(): number
		local n = 0
		for _, r in reqs do
			if r.method == "POST" then
				n += 1
			end
		end
		return n
	end
	local b = openIssues(w)
	local ctx = asks.hx.ask(w, b, { op = "ctx" })
	eq(ctx.item.tracker, "jira", "a Jira issue")
	eq(ctx.item.ref, "ABC-12", "its key is the ref")
	eq(ctx.item.status, "In Progress", "with its status")
	eq(ctx.view.integration, "jira", "in a Jira view")
	has(asks.hx.ask(w, b, { op = "act", name = "label-add", label = "x" }).problem, "GitHub issues", "labels are for GitHub")
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	eq(p.confirm.head, "Assign ABC-12 to you?", "the question names the issue")
	eq(p.confirm.lines[1], "ABC-12: Fix login", "the issue")
	eq(p.confirm.lines[2], "Jira account: the one acli is signed in with", "the account")
	has(p.confirm.lines[3], "Current assignee:", "and what it has now")
	eq(#ran, 0, "a plan runs nothing")
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).message, "Assigned ABC-12 to you", "committed")
	same(ran, { "acli jira workitem assign --key ABC-12 --assignee @me --yes" }, "one acli call for the signed-in user")
	local listing = asks.hx.ask(w, b, { op = "act", name = "transition" })
	eq(#listing.options, 2, "Jira's own transitions are the options")
	eq(listing.options[1].id .. ":" .. listing.options[1].name, "31:Done", "the first with its real id")
	eq(listing.options[2].id .. ":" .. listing.options[2].name, "41:Back to To Do", "the second")
	eq(listing.current, "In Progress", "and where the issue is now")
	eq(posts(), 0, "listing posts nothing")
	has(asks.hx.ask(w, b, { op = "act", name = "transition", to = "99" }).problem, "no longer offers", "an id Jira does not offer is refused")
	local plan = asks.hx.ask(w, b, { op = "act", name = "transition", to = "31" })
	eq(plan.confirm.head, "Move ABC-12 to Done?", "the question")
	eq(plan.confirm.label, "Move to Done", "the confirming choice")
	eq(plan.confirm.lines[3], "From: In Progress", "from")
	eq(plan.confirm.lines[4], "Transition: Done (id 31)", "and the exact transition")
	eq(posts(), 0, "a plan posts nothing")
	eq(asks.hx.ask(w, b, { op = "commit", token = plan.token }).message, "Moved ABC-12 with “Done”", "committed")
	eq(posts(), 1, "one POST")
	eq(reqs[#reqs].body, '{"transition":{"id":"31"}}', "of exactly that id")
	w.env.PLOTROOM_JIRA_API_TOKEN = nil
	local before = #reqs
	has(asks.hx.ask(w, b, { op = "act", name = "transition" }).problem, "PLOTROOM_JIRA_API_TOKEN", "no API token: the problem names the setup")
	eq(#reqs, before, "and nothing was requested")
end)

case("host mutations: a Jira comment shows the whole text and the full account and site, and is sent only as that account on that site", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local ran: { string } = {}
	local auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@example.com\n"
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = auth }
		elseif req.kind == "other" then
			table.insert(ran, table.concat(req.argv, " "))
			return { stdout = "✓ done\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local text = string.rep("a", 2999) .. "TAIL"
	local p = asks.hx.ask(w, b, { op = "act", name = "comment", text = text })
	has(p.confirm.lines[2], "ann@example.com", "the full email is shown, not its local part")
	has(p.confirm.lines[2], "https://acme.atlassian.net", "with its site")
	local shown = table.concat(p.confirm.lines, "", 4)
	eq(shown, text, "every character of the text is in the rows, the tail too")
	local long = asks.hx.ask(w, b, { op = "act", name = "comment", text = string.rep("b", 3700) })
	has(long.problem, "too long to show", "a text that would not show in full is refused")
	eq(#ran, 0, "planning wrote nothing")
	auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@other.org\n"
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "account changed", "the same local part at another domain is another account")
	eq(#ran, 0, "and nothing was written")
	auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@example.com\n"
	p = asks.hx.ask(w, b, { op = "act", name = "comment", text = "Looks good" })
	auth = "✓ Authenticated\n  Site: elsewhere.atlassian.net\n  Email: ann@example.com\n"
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "account changed", "the same email on another site is refused too")
	eq(#ran, 0, "nothing was written there either")
	auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@example.com\n"
	p = asks.hx.ask(w, b, { op = "act", name = "comment", text = "Looks good" })
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).message, "Commented on ABC-12", "the same account and site commits")
	same(ran, { "acli jira workitem comment create --key ABC-12 --body=Looks good" }, "one comment, as shown")
end)

case("host mutations: rerun-failed plans the failed runs by their real run ids, runs view then rerun, and refuses a pull request with none", function(w: World)
	local s = hostScene(w, 0)
	local base = "https://github.com/o/r"
	local done = "2026-01-01T00:00:00Z"
	local checks = {
		checkRun("build", "COMPLETED", "FAILURE", done, { id = "A", detailsUrl = base .. "/actions/runs/123/job/9" }),
		checkRun("lint", "COMPLETED", "FAILURE", done, { id = "B", detailsUrl = base .. "/actions/runs/123/job/10" }),
		checkRun("deploy", "COMPLETED", "FAILURE", done, { id = "C", detailsUrl = base .. "/runs/77" }),
		checkRun("test", "COMPLETED", "SUCCESS", done, { id = "D", detailsUrl = base .. "/actions/runs/124/job/1" }),
	}
	local legacy = { checkRun("old", "COMPLETED", "FAILURE", done, { id = "E", detailsUrl = base .. "/runs/78" }) }
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE", runs = array(checks), runTotal = 4 }),
		searchItem(2, "o/r", EPOCH - 120, { checks = "FAILURE", runs = array(legacy), runTotal = 1 }),
	}
	s.gh.checks["o/r#1"] = checks
	s.gh.checks["o/r#2"] = legacy
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		if line == "gh run view 123 --repo github.com/o/r --json databaseId,status,conclusion,url" then
			return { stdout = jsonEncode({ databaseId = 123, status = "completed", conclusion = "failure", url = base .. "/actions/runs/123" }) }
		end
		return nil
	end)
	local b = openQueue(w)
	w.advance(300)
	has(asks.hx.ask(w, b, { op = "act", name = "assign-me" }).problem, "Assigning works on issues", "assigning is for issues")
	local p = asks.hx.ask(w, b, { op = "act", name = "rerun-failed" })
	eq(p.confirm.head, "Rerun failed jobs of o/r#1?", "the question names the pull request")
	eq(p.confirm.label, "Rerun failed jobs", "the confirming choice")
	eq(#p.confirm.lines, 3, "one line for the pull request, one for the account, one for the run")
	eq(p.confirm.lines[1], "o/r#1: PR 1", "the pull request")
	eq(p.confirm.lines[3], "Rerun the failed jobs of workflow run 123 (build, lint)", "the one run that has an id, with its failed checks; a check-run link has none")
	eq(#seen, 0, "a plan runs nothing")
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	eq(r.ok, true, "committed")
	same(seen, {
		"gh run view 123 --repo github.com/o/r --json databaseId,status,conclusion,url",
		"gh run rerun 123 --repo github.com/o/r --failed",
	}, "the run is read again, then only its failed jobs rerun")
	b.typeText("j")
	w.advance(300)
	has(asks.hx.ask(w, b, { op = "act", name = "rerun-failed" }).problem, "has a GitHub Actions run to rerun", "a failed check with no run id is not rerun")
	eq(#seen, 2, "and sends nothing")
end)

case("host mutations: a workflow run with any job still running is not finished: no Re-run all for it, Cancel stays, in the palette and when asked", function(w: World)
	local s = hostScene(w, 0)
	local base = "https://github.com/o/r"
	local done = "2026-01-01T00:00:00Z"
	local checks = {
		checkRun("build", "COMPLETED", "SUCCESS", done, { id = "A", detailsUrl = base .. "/actions/runs/300/job/1" }),
		checkRun("test", "IN_PROGRESS", nil, nil, { id = "B", detailsUrl = base .. "/actions/runs/300/job/2" }),
	}
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60, { checks = "PENDING", runs = array(checks), runTotal = 2 }) }
	s.gh.checks["o/r#1"] = checks
	local b = openQueue(w)
	w.advance(300)
	local cmds = hx.palette(w, b).commands
	yes(table.find(cmds, "cancel-run") ~= nil, "Cancel is offered for the running run")
	eq(table.find(cmds, "rerun-all"), nil, "Re-run all is not, though one of its jobs finished")
	has(asks.hx.ask(w, b, { op = "act", name = "rerun-all" }).problem, "No finished", "asked anyway, it plans nothing")
	eq(asks.hx.ask(w, b, { op = "act", name = "cancel-run" }).confirm.lines[3], "Cancel run 300 (test)", "Cancel plans the run's running job")
end)

case("host mutations: rerun-failed with several failed workflow runs lists them, plans exactly the picked one, refuses one that did not fail, and reruns only that run", function(w: World)
	local s = hostScene(w, 0)
	local base = "https://github.com/o/r"
	local done = "2026-01-01T00:00:00Z"
	local checks: { any } = {}
	for i = 1, 7 do
		table.insert(checks, checkRun("job" .. i, "COMPLETED", "FAILURE", done, { id = "J" .. i, detailsUrl = base .. "/actions/runs/20" .. i .. "/job/1" }))
	end
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE", runs = array(checks), runTotal = 7 }) }
	s.gh.checks["o/r#1"] = checks
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		local id = string.match(line, "^gh run view (%d+) ")
		if id then
			return { stdout = jsonEncode({ databaseId = tonumber(id), status = "completed", conclusion = "failure", url = base .. "/actions/runs/" .. id }) }
		end
		return nil
	end)
	local b = openQueue(w)
	w.advance(300)
	local listing = asks.hx.ask(w, b, { op = "act", name = "rerun-failed" })
	eq(#listing.runs, 7, "all seven failed runs are pickable")
	eq(listing.runs[1].id, "201", "by run id")
	has(listing.runs[1].label, "job1", "labelled with its failed checks")
	eq(listing.token, nil, "listing is no plan")
	eq(#seen, 0, "nothing was sent")
	local missing = asks.hx.ask(w, b, { op = "act", name = "rerun-failed", run = "999" })
	has(missing.problem, "no longer has failed checks", "a run that is not among the failed ones is refused")
	eq(#seen, 0, "with no gh call")
	local p = asks.hx.ask(w, b, { op = "act", name = "rerun-failed", run = "205" })
	eq(p.confirm.lines[3], "Rerun the failed jobs of workflow run 205 (job5)", "the plan names the picked run alone")
	eq(#p.confirm.lines, 3, "and no other")
	eq(#seen, 0, "a plan sends nothing")
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).ok, true, "committed")
	same(seen, {
		"gh run view 205 --repo github.com/o/r --json databaseId,status,conclusion,url",
		"gh run rerun 205 --repo github.com/o/r --failed",
	}, "exactly the picked run is read and rerun")
end)

case("host mutations: a gh account that cannot sign in fails the commit closed: the plan names it, nothing is sent", function(w: World)
	local s = issueHost(w)
	s.gh.tokens.work = "tok-work"
	s.gh.issueItems.work = { issueItem(12, "o/r", EPOCH - 60, { title = "Fix login" }) }
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Work", integration = "github", query = "is:open assignee:@me", logins = array({ "work" }), group = "none", prompts = array({}) },
	}) })
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	eq(pickerOf(b).selected, "no_2fr_2312", "the work account's issue is selected")
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	eq(p.confirm.lines[2], "Account: @work", "the plan names the view's account")
	s.gh.tokens["work"] = nil :: any
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	has(r.problem, "not signed in", "the commit says the account is not signed in")
	eq(r.ok, nil, "and is no success")
	eq(#seen, 0, "no gh mutation was spawned")
	local l = asks.hx.ask(w, b, { op = "act", name = "label-add", label = "x" })
	s.gh.tokens["work"] = nil :: any
	has(asks.hx.ask(w, b, { op = "commit", token = l.token }).problem, "not signed in", "a label edit fails closed the same way")
	eq(#seen, 0, "still nothing was sent")
end)

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

case("host draft: info, preview, plan and commit push the previewed commit unforced, then create the draft pull request and pin it", function(w: World)
	local s = asks.hx.draftScene(w)
	local created = "https://github.com/o/r/pull/21"
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		if string.find(line, "pr create", 1, true) then
			return { stdout = created .. "\n" }
		end
		return nil
	end)
	s.gh.pulls[created] = searchItem(21, "o/r", EPOCH - 10, { title = "Fix login flow", isDraft = true })
	local b = openIssues(w)
	local info = asks.hx.ask(w, b, { op = "draft", phase = "info" })
	eq(info.repo, "o/r", "the repository")
	has(info.branch, "12-fix-login", "the worktree's branch")
	eq(info.path, "/wt/plotroom-o_r-issue-12", "and folder")
	eq(#info.destinations, 1, "one remote: one destination, still listed")
	eq(info.destinations[1].repo, "o/r", "the checkout's repository")
	eq(info.destinations[1].remote, "origin", "on origin")
	local bases = asks.hx.ask(w, b, { op = "draft", phase = "bases", repo = "o/r" })
	eq(bases.bases[1], "main", "the remote's branches are the bases")
	eq(bases.defaultBase, "main", "the default one first")
	local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
	eq(pv.draft, true, "a preview")
	eq(pv.branch, "12-fix-login", "of the branch")
	eq(pv.base, "main", "over the base")
	eq(pv.remote, "origin", "pushed to the repository's remote")
	eq(pv.count, 2, "two commits")
	eq(#pv.commits, 2, "listed")
	eq(pv.needsPush, true, "the remote lacks the branch")
	eq(pv.body, "Closes #12", "the issue is closed by the body")
	eq(#s.git.pushes, 0, "a preview pushes nothing")
	local plan = asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "Fix login flow", body = pv.body })
	eq(plan.confirm.head, "Create a draft pull request?", "the question")
	eq(plan.confirm.label, "Push and create draft", "the confirming choice says it pushes")
	eq(plan.confirm.lines[1], "Repository: o/r", "the repository")
	eq(plan.confirm.lines[2], "First pushes 12-fix-login to origin (never forced)", "the push is a line of its own")
	has(plan.confirm.lines[3], "12-fix-login → main (2 commits)", "the branch and base")
	eq(plan.confirm.lines[4], "Title: Fix login flow", "the title")
	has(plan.confirm.lines[5], "Opens a draft pull request", "and what is created")
	eq(#s.git.pushes, 0, "a plan pushes nothing")
	eq(#seen, 0, "and creates nothing")
	local mark = #w.calls
	local done = asks.hx.ask(w, b, { op = "commit", token = plan.token })
	eq(done.ok, true, "the commit answers ok")
	eq(done.url, created, "with the new pull request's URL")
	same(s.git.pushes, { "push --no-force-with-lease origin " .. sha("c") .. ":refs/heads/12-fix-login" }, "the previewed commit was pushed, not forced")
	same(seen, { "gh pr create --repo github.com/o/r --draft --base=main --head=12-fix-login --title=Fix login flow --body=Closes #12" }, "one draft pull request, from that branch to that base")
	local pushAt: number?, createAt: number? = nil, nil
	for i, line in ranSince(w, mark) do
		if not pushAt and string.find(line, "push --no-force-with-lease", 1, true) then
			pushAt = i
		end
		if not createAt and string.find(line, "pr create", 1, true) then
			createAt = i
		end
	end
	yes(pushAt ~= nil and createAt ~= nil and pushAt < createAt, "the push came before the pull request was created")
	eq(pickerOf(b).scopes[1].label, "o/r#21", "the new pull request is the pinned scope")
	eq(pickerOf(b).selected, "no_2fr_2321", "and selected")
	eq(pickerOf(b).items[1].label, "Fix login flow", "showing the created pull request")
	same(b.saved().pins, { created }, "the created pull request is the saved pin")
end)

case("host draft: a repository that is not one of the worktree's remotes is refused before any fetch, push or create, and a second GitHub remote is a destination of its own", function(w: World)
	local s = asks.hx.draftScene(w)
	s.git.remotes.upstream = { "https://github.com/u/r.git" }
	local created = "https://github.com/u/r/pull/3"
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		if string.find(line, "pr create", 1, true) then
			return { stdout = created .. "\n" }
		end
		return nil
	end)
	s.gh.pulls[created] = searchItem(3, "u/r", EPOCH - 10, { title = "Fix login flow", isDraft = true })
	local b = openIssues(w)
	local info = asks.hx.ask(w, b, { op = "draft", phase = "info" })
	eq(#info.destinations, 2, "both GitHub remotes are destinations")
	eq(info.destinations[1].repo, "o/r", "the checkout's saved repository first")
	eq(info.destinations[1].remote, "origin", "on its remote")
	eq(info.destinations[2].repo, "u/r", "the second remote's repository after it")
	eq(info.destinations[2].remote, "upstream", "on its own remote")
	eq(info.repo, "o/r", "the default is the first")
	local fetches = countLog(s.git, "fetch")
	local repos: { any } = {}
	table.insert(repos, "evil/x")
	table.insert(repos, "O/R/x")
	table.insert(repos, 5)
	for _, bad in repos do
		for _, phase in { "bases", "preview" } do
			local r = asks.hx.ask(w, b, { op = "draft", phase = phase, repo = bad, base = "main" })
			has(r.problem, "not one of this worktree's GitHub remotes", phase .. " refuses " .. show(bad))
		end
	end
	has(asks.hx.ask(w, b, { op = "draft", phase = "preview", base = "main" }).problem, "not one of this worktree's GitHub remotes", "no repository at all")
	eq(countLog(s.git, "fetch"), fetches, "nothing was fetched for any of them")
	eq(#s.git.pushes, 0, "nor pushed")
	eq(#seen, 0, "nor created")
	local bases = asks.hx.ask(w, b, { op = "draft", phase = "bases", repo = "u/r" })
	eq(bases.repo, "u/r", "the bases are the second repository's")
	eq(bases.defaultBase, "main", "with its default first")
	local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "u/r", base = "main" })
	eq(pv.repo, "u/r", "the preview is for it")
	eq(pv.remote, "upstream", "pushed to its remote")
	eq(pv.body, "Issue: https://github.com/o/r/issues/12", "the body links an issue of another repository")
	local plan = asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "Fix login flow", body = pv.body })
	eq(plan.confirm.lines[1], "Repository: u/r", "the plan names it")
	eq(plan.confirm.lines[2], "First pushes 12-fix-login to upstream (never forced)", "and the remote it pushes to")
	eq(#s.git.pushes, 0, "a plan pushes nothing")
	local done = asks.hx.ask(w, b, { op = "commit", token = plan.token })
	eq(done.url, created, "the pull request is created")
	same(s.git.pushes, { "push --no-force-with-lease upstream " .. sha("c") .. ":refs/heads/12-fix-login" }, "the branch went to THAT remote")
	same(seen, { "gh pr create --repo github.com/u/r --draft --base=main --head=12-fix-login --title=Fix login flow --body=Issue: https://github.com/o/r/issues/12" }, "on that repository")
end)

case("host draft: only an issue with a worktree starts a draft, the commit reads the branch again even when no push is needed, and title and body are limited", function(w: World)
	local s, tree = asks.hx.draftScene(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local function draft(body: { [string]: any }): any
		return asks.hx.ask(w, b, body)
	end
	b.typeText("j")
	has(draft({ op = "draft", phase = "info" }).problem, "Make a worktree for o/r#13 first", "an issue without a worktree")
	b.typeText("k")
	pickScope(b, "prs:v1")
	w.flush()
	hx.selectFirst(b)
	has(draft({ op = "draft", phase = "info" }).problem, "Select an issue that has a worktree", "a pull request")
	pickScope(b, "issues:v1")
	w.flush()
	hx.selectFirst(b)
	eq(pickerOf(b).selected, "no_2fr_2312", "back on the issue with the worktree")
	has(draft({ op = "draft", phase = "preview", repo = "o/r", base = "--evil" }).problem, "not a branch name", "a base that looks like an option")
	has(draft({ op = "draft", phase = "bogus" }).problem, "does not know that step", "an unknown step")
	local pv = draft({ op = "draft", phase = "preview", repo = "o/r", base = "main" })
	local function plan(title: string, body: string): any
		return draft({ op = "draft", phase = "plan", token = pv.token, title = title, body = body })
	end
	has(plan("", "b").problem, "title needs 1 to 256", "an empty title")
	has(plan("   ", "b").problem, "title needs 1 to 256", "a blank one")
	has(plan(string.rep("x", 257), "b").problem, "title needs 1 to 256", "a title of 257 bytes")
	has(plan("a\nb", "b").problem, "title needs 1 to 256", "a title of two lines")
	has(plan("ok", string.rep("y", 8001)).problem, "too long", "a body of 8001 bytes")
	yes(plan(string.rep("x", 256), string.rep("y", 8000)).token ~= nil, "a title of 256 and a body of 8000 bytes pass")
	has(draft({ op = "draft", phase = "plan", token = "d0_0", title = "t", body = "b" }).problem, "Preview the draft again", "a plan for a preview this block never made")
	eq(#s.git.pushes, 0, "nothing was pushed")
	eq(#seen, 0, "nor created")
	s.git.refs["refs/remotes/origin/12-fix-login"] = sha("c")
	local synced = draft({ op = "draft", phase = "preview", repo = "o/r", base = "main" })
	eq(synced.needsPush, false, "the remote already has the commit")
	local plan2 = draft({ op = "draft", phase = "plan", token = synced.token, title = "T", body = "B" })
	eq(plan2.confirm.label, "Create draft", "no push is offered")
	lacks(table.concat(plan2.confirm.lines, "\n"), "First pushes", "or listed")
	s.git.counts[sha("d")] = 3
	tree.head = sha("d")
	has(asks.hx.ask(w, b, { op = "commit", token = plan2.token }).problem, "moved since the preview", "a HEAD that moved is caught though no push was planned")
	eq(#s.git.pushes, 0, "nothing was pushed")
	eq(#seen, 0, "and no pull request was created")
end)

case("host draft: the commit is refused when the remote's copy of the branch changed since the confirmed preview, or the view changed after the plan, with no push and no create", function(w: World)
	local s = asks.hx.draftScene(w)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local function planned(): any
		local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
		eq(pv.needsPush, true, "the preview needs a push")
		return asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "T", body = "B" })
	end
	local p = planned()
	s.git.refs["refs/remotes/origin/12-fix-login"] = sha("c")
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "moved since the preview", "someone pushed the branch meanwhile: needsPush changed")
	eq(#s.git.pushes, 0, "nothing was pushed")
	eq(#seen, 0, "nothing was created")
	s.git.refs["refs/remotes/origin/12-fix-login"] = nil
	local q = planned()
	pickScope(b, "issues:v2")
	w.flush()
	has(asks.hx.ask(w, b, { op = "commit", token = q.token }).problem, "selection or the view changed", "the view changed after the plan")
	eq(#s.git.pushes, 0, "still nothing was pushed")
	eq(#seen, 0, "and nothing created")
end)

case("host mutations: with no known GitHub account every GitHub plan refuses and spawns nothing", function(w: World)
	local s = asks.hx.draftScene(w)
	s.gh.items.octocat = manyItems("o/r", 2)
	local seen: { string } = {}
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { status = 1, stderr = "gh: unavailable\n" }
		elseif req.kind == "other" then
			table.insert(seen, table.concat(req.call.argv, " "))
			return { stdout = "" }
		end
		return nil
	end
	local b = openIssues(w)
	local unknown = "Could not tell which GitHub account is active"
	has(asks.hx.ask(w, b, { op = "act", name = "assign-me" }).problem, unknown, "assign-me")
	has(asks.hx.ask(w, b, { op = "act", name = "label-add", label = "new" }).problem, unknown, "a label")
	local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
	has(asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "T", body = "B" }).problem, unknown, "a draft plan")
	pickScope(b, "prs:v1")
	w.flush()
	hx.selectFirst(b)
	has(asks.hx.ask(w, b, { op = "act", name = "rerun-failed" }).problem, "has a GitHub Actions run to rerun", "a pull request with no failed run is refused first")
	eq(#seen, 0, "no gh mutation was spawned")
	eq(#s.git.pushes, 0, "nothing was pushed")
end)

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

-- The Worktrees board's rows as "repo/branch", in the order listed (group headings skipped).
function asks.hx.board(b: Block): { string }
	local byId: { [string]: any } = {}
	for _, item in pickerOf(b).items do
		byId[item.id] = item
	end
	local out: { string } = {}
	for _, entry in pickerOf(b).order do
		if type(entry) ~= "table" then
			table.insert(out, asks.hx.nameOf(b, byId[entry]))
		end
	end
	return out
end

-- The picker id of the board row `name` ("o/r/feature").
function asks.hx.rowId(b: Block, name: string): string
	local byId: { [string]: any } = {}
	for _, item in pickerOf(b).items do
		byId[item.id] = item
	end
	for _, entry in pickerOf(b).order do
		if type(entry) ~= "table" and asks.hx.nameOf(b, byId[entry]) == name then
			return entry
		end
	end
	error("no board row " .. name, 2)
end

-- The picker item of the board row `name`.
function asks.hx.rowItem(b: Block, name: string): any
	local id = asks.hx.rowId(b, name)
	for _, item in pickerOf(b).items do
		if item.id == id then
			return item
		end
	end
	return nil
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

case("host worktrees board: the Worktrees scope lists every worktree of every saved checkout, not only the shown view's repository, with badges, an open link and a way back", function(w: World)
	local s = asks.hx.boardScene(w)
	local b = openQueue(w)
	local scopes = pickerOf(b).scopes
	eq(scopes[#scopes].id, "worktrees", "the sidebar ends with the Worktrees scope")
	eq(scopes[#scopes].label, "Worktrees", "named so")
	eq(scopes[#scopes].count, nil, "with no count until it was read")
	eq(pickerOf(b).scope, "prs:v1", "the view is the active scope")
	pickScope(b, "worktrees")
	w.flush()
	eq(pickerOf(b).scope, "worktrees", "opening it makes it the active scope")
	eq(pickerOf(b).noun, "worktrees", "the board lists worktrees")
	same(asks.hx.board(b), { "o/r/feature", "o/r/lk", "o/r/main", "x/y/main", "x/y/yb" }, "every checkout's worktrees, grouped by repository, the other repository's too")
	scopes = pickerOf(b).scopes
	eq(scopes[#scopes].count, 5, "the scope counts them")
	has(asks.hx.badges(b, "o/r/main"), "Main", "the main worktree is marked")
	has(asks.hx.badges(b, "x/y/main"), "Main", "in every repository")
	has(asks.hx.badges(b, "o/r/lk"), "Locked", "a locked worktree is marked")
	has(asks.hx.badges(b, "o/r/lk"), "Unnoted", "and one no item was noted for")
	lacks(asks.hx.badges(b, "o/r/feature"), "Unnoted", "a pull request's is linked")
	lacks(asks.hx.badges(b, "o/r/feature"), "In tab", "no tab works in it yet")
	eq(detailText(asks.hx.rowItem(b, "o/r/feature")), "/wt/pr5 · #5", "a row shows its folder and its pull request")
	table.insert(w.panes, { pane = 9, cwd = "/wt/pr5/src" })
	b.render()
	has(asks.hx.badges(b, "o/r/feature"), "In tab", "a tab working in it marks the row")
	lacks(asks.hx.badges(b, "x/y/yb"), "In tab", "and no other")
	eq(pickerOf(b).selected, nil, "no row is selected until one is picked")
	eq(findKey(pickerNode(b), "wtopen"), nil, "so there is no open link and no preview")
	eq(b.press("enter"), true, "Enter handles the key")
	eq(#w.opened, 0, "but opens nothing with no row")
	b.press("down")
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "Down from nothing selects the first row")
	eq(findKey(pickerNode(b), "wtopen").p.href, "plotroom://worktrees/open/1", "its hidden link carries the row's number")
	eq(b.press("enter"), true, "Enter opens it")
	eq(w.opened[#w.opened], "plotroom://worktrees/open/1", "through that link")
	eq(asks.hx.ask(w, b, { op = "worktree-path", n = 1 }).path, "/wt/pr5", "the window asks the host for the folder by number")
	eq(asks.hx.ask(w, b, { op = "worktree-path", n = 3 }).path, "/work/r", "the main worktree's too")
	has(asks.hx.ask(w, b, { op = "worktree-path", n = 9 }).problem, "no longer listed", "a number no row has")
	eq(asks.hx.ask(w, b, { op = "worktree-path", n = "1" }), nil, "a number that is no number is not answered")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	eq(b.press("escape"), true, "Escape closes the preview first")
	eq(pickerOf(b).selected, nil, "nothing is selected again")
	eq(pickerOf(b).scope, "worktrees", "and the board is still shown")
	eq(b.press("escape"), true, "the second Escape leaves the board")
	eq(pickerOf(b).scope, "prs:v1", "for the view")
	eq(pickerOf(b).noun, "pull requests", "which lists pull requests again")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "its rows")
	pickScope(b, "worktrees")
	pickScope(b, "prs:v1")
	eq(pickerOf(b).scope, "prs:v1", "a click on the view leaves the board too")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "with its rows")
end)

case("host worktrees board: the changes of every worktree are read on their own and again every 30 seconds while the board is shown, never after it is left; u marks closed and merged items as cleanup candidates without removing anything", function(w: World)
	local s, y = asks.hx.boardScene(w)
	asks.bk.tree(w, s.git, "/wt/iss", "12-fix")
	s.git.notes["branch.12-fix.plotroomkey"] = "o/r#12"
	s.git.notes["branch.12-fix.plotroomrepo"] = "o/r"
	s.git.dirty["/wt/pr5"] = " M a.txt\n"
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { state = "MERGED" })
	s.gh.pulls["https://github.com/o/r/issues/12"] = issueItem(12, "o/r", EPOCH - 60, { state = "CLOSED", reason = "COMPLETED" })
	w.kv.put("keys", { ["wt-cleanup"] = "u" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	same(asks.hx.board(b), { "o/r/12-fix", "o/r/feature", "o/r/lk", "o/r/main", "x/y/main", "x/y/yb" }, "the rows")
	has(asks.hx.badges(b, "o/r/feature"), "Changes", "a worktree with uncommitted changes says so with no key pressed")
	for _, name in { "o/r/12-fix", "o/r/lk", "o/r/main", "x/y/main", "x/y/yb" } do
		lacks(asks.hx.badges(b, name), "Changes", name .. ": has none")
	end
	s.git.dirty["/wt/pr5"] = nil
	local reads = countLog(s.git, "status")
	w.advance(29000)
	eq(countLog(s.git, "status"), reads, "the changes are not read again before 30 seconds")
	w.advance(1000)
	yes(countLog(s.git, "status") > reads, "they are read again 30 seconds after the last scan")
	has(asks.hx.badges(b, "o/r/feature"), "Clean", "and the badge follows")
	lacks(asks.hx.badges(b, "o/r/feature"), "Changes", "the old one is gone")
	b.typeText("u")
	w.flush()
	has(w.toasts[#w.toasts].text, "Checked 2 worktrees", "u counts the two worktrees gh could answer for")
	has(asks.hx.badges(b, "o/r/feature"), "Merged", "a merged pull request is a candidate")
	has(asks.hx.badges(b, "o/r/12-fix"), "Closed", "a closed issue too")
	lacks(asks.hx.badges(b, "x/y/yb"), "Merged", "a pull request gh cannot see is none")
	lacks(asks.hx.badges(b, "x/y/yb"), "Closed", "neither closed")
	lacks(asks.hx.badges(b, "o/r/lk"), "Closed", "a worktree with no item is not asked about")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed in o/r")
	eq(countLog(y, "worktree remove"), 0, "nor in x/y")
	eq(#s.git.worktrees, 4, "every worktree is still there")
	same(asks.hx.board(b), { "o/r/12-fix", "o/r/feature", "o/r/lk", "o/r/main", "x/y/main", "x/y/yb" }, "and listed")
	b.press("escape")
	eq(pickerOf(b).scope, "prs:v1", "leaving the board")
	eq(b.state().boardTimer, nil, "stops its scan timer")
	local left = countLog(s.git, "status")
	w.advance(120 * 1000)
	eq(countLog(s.git, "status"), left, "and nothing reads the worktrees any more")
end)

case("host worktrees board: the preview of a row names its folder, the pull request or issue it was made for as the tracker answered, its branch, repository, path and head, and closes with Escape or its Close preview row", function(w: World)
	local s = asks.hx.boardScene(w)
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Fix the board" })
	local b = hx.openBare(w)
	pickScope(b, "worktrees")
	w.flush()
	eq(pickerOf(b).selected, nil, "nothing is selected on arrival")
	eq(pickerOf(b).preview, "none", "the board has no preview pane before a pick")
	eq(#(pickerNode(b).c or {}), 0, "and no preview children")
	b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, "o/r/feature") })
	w.advance(300)
	w.flush()
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "a row event selects it")
	eq(findKey(findKey(pickerNode(b), "titlerow"), "title").p.spans[1].t, "pr5", "the preview's title is its folder's name")
	has(b.text(), "Pull request #5", "the pull request it was made for is named")
	has(b.text(), "Fix the board", "with the title the tracker answered")
	local facts: { [string]: string } = {}
	for _, fact in findKey(pickerNode(b), "facts", "kv").p.items do
		facts[fact.k] = fact.v[1].t
	end
	eq(facts.Branch, "feature", "the branch")
	eq(facts.Repository, "o/r", "the repository")
	eq(facts.Path, "/wt/pr5", "the path")
	yes(facts.Head ~= nil and #facts.Head <= 8, "a short head")
	yes(facts.Status ~= nil, "and a status")
	yes(findKey(pickerNode(b), "close-preview") ~= nil, "a Close preview row is offered")
	b.event({ ev = "action", id = "layer.queue.controls.close-preview", act = "close-preview" })
	eq(pickerOf(b).selected, nil, "it closes the preview")
	eq(pickerOf(b).preview, "none", "no preview pane is left open")
	eq(#(pickerNode(b).c or {}), 0, "and nothing is drawn in it")
	eq(pickerOf(b).scope, "worktrees", "and stays on the board")
	b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, "o/r/lk") })
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/lk"), "another row can be picked")
	b.press("escape")
	eq(pickerOf(b).selected, nil, "Escape closes it too")
	b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, "o/r/feature") })
	b.event({ ev = "action", id = "layer.queue", act = "refresh" })
	w.flush()
	eq(pickerOf(b).scope, "worktrees", "a refresh keeps the board")
	w.advance(300)
	w.flush()
	has(b.text(), "Fix the board", "the preview read the tracker again")
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Merged since" })
	w.flush()
	has(b.text(), "Fix the board", "nothing changes until Refresh")
	b.event({ ev = "action", id = "layer.queue", act = "refresh" })
	w.advance(300)
	w.flush()
	has(b.text(), "Merged since", "Refresh reads the previewed pull request again, not only git")
	eq(w.kv.store["triage"], nil, "reading worktrees marks no pull request seen")
end)

case("host worktrees board: u asks about at most twenty worktrees a press, rows not yet asked first, and removes none", function(w: World)
	local s = hostScene(w, 3)
	for i = 1, 25 do
		asks.bk.tree(w, s.git, "/wt/n" .. i, "n" .. i)
		s.git.notes["branch.n" .. i .. ".plotroompr"] = tostring(100 + i)
		s.gh.pulls["https://github.com/o/r/pull/" .. (100 + i)] = searchItem(100 + i, "o/r", EPOCH - 60)
		s.git.notes["branch.n" .. i .. ".plotroomrepo"] = "o/r"
	end
	w.kv.put("keys", { ["wt-cleanup"] = "u" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	eq(#asks.hx.board(b), 26, "main and 25 worktrees")
	local before = #requestsOf(s.gh, "pull")
	b.typeText("u")
	w.flush()
	eq(#requestsOf(s.gh, "pull") - before, 20, "twenty were asked")
	has(w.toasts[#w.toasts].text, "Checked 20 worktrees", "the toast says so")
	eq(w.toasts[#w.toasts].sub, "5 more not checked: press u again", "and that five were left")
	local asked = 0
	for _, row in b.state().board.rows do
		if row.candidateChecked then
			asked += 1
		end
	end
	eq(asked, 20, "twenty rows were checked")
	b.typeText("u")
	w.flush()
	for _, row in b.state().board.rows do
		yes(row.main or row.candidateChecked, "every row was checked after the second press: " .. row.path)
	end
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	eq(#asks.hx.board(b), 26, "every row is still listed")
end)

case("host worktrees board: with the default keys its bar shows only the command palette; a bound key brings its button back", function(w: World)
	asks.hx.boardScene(w)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	local function bar(): { string }
		local ids: { string } = {}
		for _, a in pickerOf(b).actions do
			table.insert(ids, a.id)
		end
		return ids
	end
	same(bar(), { "more" }, "no Find cleanup, Remove or Open button without a key")
	eq(b.press("u", nil, "u"), false, "u is no shortcut by default")
	w.kv.put("keys", { ["wt-cleanup"] = "u" })
	b.render()
	same(bar(), { "more", "wt-cleanup" }, "bound, Find cleanup shows")
	same(actionOf(b, "wt-cleanup").keys, { "u" }, "with its key")
end)

case("host worktrees board: d asks first, Enter or Esc keeps the worktree, d again removes it without force, and dirty, main and locked rows are refused", function(w: World)
	local s = asks.hx.boardScene(w)
	w.kv.put("keys", { ["wt-remove"] = "d" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	b.typeText("d")
	eq(confirmOf(b), nil, "d asks nothing while no row is selected")
	yes(actionOf(b, "wt-remove").disabled ~= nil, "and Remove is off")
	b.press("down")
	eq(actionOf(b, "wt-remove").disabled, nil, "Remove is on for a linked worktree once it is selected")
	b.typeText("d")
	local overlay = confirmOf(b)
	yes(overlay ~= nil, "d asks first")
	local texts: { string } = {}
	collectTexts(overlay, texts)
	has(table.concat(texts, " "), "/wt/pr5", "naming its folder")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed yet")
	b.press("enter")
	eq(confirmOf(b), nil, "Enter keeps it")
	b.typeText("d")
	b.press("escape")
	eq(confirmOf(b), nil, "Esc keeps it")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	yes(table.find(asks.hx.board(b), "o/r/feature") ~= nil, "and it is still listed")
	s.git.dirty["/wt/pr5"] = " M a.txt\n"
	b.typeText("d")
	b.typeText("d")
	w.flush()
	eq(w.toasts[#w.toasts].level, "error", "a dirty worktree is refused")
	eq(w.toasts[#w.toasts].text, "Worktree not removed", "the toast says so")
	eq(w.toasts[#w.toasts].sub, "The worktree has uncommitted changes.", "and why")
	eq(countLog(s.git, "worktree remove"), 0, "git was never asked to remove it")
	s.git.dirty["/wt/pr5"] = nil
	b.typeText("d")
	b.typeText("d")
	w.flush()
	eq(w.toasts[#w.toasts].text, "Worktree removed", "a clean one is removed")
	eq(countLog(s.git, "worktree remove /wt/pr5"), 1, "by one git command")
	for _, line in s.git.log do
		if string.sub(line, 1, 15) == "worktree remove" then
			lacks(line, "--force", "never forced")
			lacks(line, " -f", "nor with -f")
		end
	end
	same(asks.hx.board(b), { "o/r/lk", "o/r/main", "x/y/main", "x/y/yb" }, "the row left the board")
	for _, name in { "o/r/main", "o/r/lk" } do
		b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, name) })
		yes(actionOf(b, "wt-remove").disabled ~= nil, name .. ": Remove is disabled")
		b.typeText("d")
		eq(confirmOf(b), nil, name .. ": d asks nothing")
		eq(table.find(hx.palette(w, b).ids, "wt-remove"), nil, name .. ": the palette lists no Remove either")
	end
	eq(countLog(s.git, "worktree remove /work/r"), 0, "the main worktree was never offered to git")
	eq(countLog(s.git, "worktree remove /wt/lk"), 0, "nor the locked one")
end)

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

case("host export: export-list names the saved views and actions, and an export leaves out checkouts, setup commands, paths, secrets and real logins", function(w: World)
	asks.hx.saved(w)
	local b = openQueue(w)
	local list = asks.hx.ask(w, b, { op = "export-list" })
	local views: { string } = {}
	for _, v in list.views do
		table.insert(views, v.id)
	end
	yes(table.find(views, "prs:v1") ~= nil and table.find(views, "prs:v2") ~= nil, "the saved views are listed by their qualified ids")
	local prompts: { string } = {}
	for _, p in list.prompts do
		if p.kind == "prs" then
			table.insert(prompts, p.id .. "=" .. p.name)
		end
	end
	same(prompts, { "prs:p1=Review", "prs:p2=Leaky" }, "and the saved actions")
	local pv = asks.hx.ask(w, b, { op = "export", views = { "prs:v1" }, prompts = { "prs:p1", "prs:p2" } })
	eq(pv.count.views, 1, "one view was asked for")
	eq(pv.count.prompts, 1, "the document holds one action: the secret one is left out")
	has(pv.notes[1], "Leaky", "a note says the secret action was left out")
	local a = asks.hx.ask(w, b, { op = "export", phase = "commit", token = pv.token })
	local doc: any = jsonDecode(a.json)
	eq(doc.format, "plotroom-export", "the format")
	eq(doc.version, 1, "its version")
	eq(#doc.prompts, 1, "the action with a secret is not exported")
	eq(doc.prompts[1].id, "prs:p1", "the other is")
	eq(doc.prompts[1].key, "e", "with its shortcut")
	eq(#doc.views, 1, "the view")
	eq(doc.views[1].name, "My PRs", "by name")
	same(doc.views[1].accounts, { "account-1" }, "its login is an anonymous slot")
	same(doc.views[1].prompts, { "prs:p1" }, "and its action is the exported one")
	for _, never in { "octocat", "/work/r", "npm install", "ghp_", "Leaky", "checkout", "setup", "token", "secret" } do
		lacks(a.json, never, "the export has no " .. never)
	end
	eq(a.path, nil, "without a path it only answers")
end)

case("host export: the preview only counts, a commit serves the same snapshot once even if views changed, and a file is written only when it names a new file", function(w: World)
	asks.hx.saved(w)
	local b = openQueue(w)
	w.fs.dirs["/tmp"] = true
	local pv = asks.hx.ask(w, b, { op = "export", views = { "prs:v1" } })
	eq(pv.count.views, 1, "the preview counts what the document holds")
	eq(pv.count.prompts, 1, "the view's action comes along")
	eq(pv.copyable, true, "a small export can be copied")
	yes(pv.size > 0, "with its size")
	eq(pv.json, nil, "the preview carries no JSON")
	eq(#w.copied, 0, "nothing was copied")
	eq(w.fs.files["/tmp/out.json"], nil, "nor written")
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "review" })
	eq(w.kv.get("views-prs").items[1].sort, "review", "the view was edited after the preview")
	b.press("escape")
	local done = asks.hx.ask(w, b, { op = "export", phase = "commit", token = pv.token })
	eq(done.ok, true, "the commit answers ok")
	local doc: any = jsonDecode(done.json)
	eq(doc.views[1].sort, nil, "with the snapshot of the preview, not what was saved since")
	has(asks.hx.ask(w, b, { op = "export", phase = "commit", token = pv.token }).problem, "expired", "a token works once")
	local again = asks.hx.ask(w, b, { op = "export", views = { "prs:v1" } })
	eq(jsonDecode(asks.hx.ask(w, b, { op = "export", phase = "commit", token = again.token }).json).views[1].sort, "review", "a new preview sees the edit")
	has(asks.hx.ask(w, b, { op = "export", phase = "commit", token = "x0_0" }).problem, "expired", "a token this block never issued")
	local p2 = asks.hx.ask(w, b, { op = "export", views = { "prs:v1" } })
	local a = asks.hx.ask(w, b, { op = "export", phase = "commit", token = p2.token, path = "/tmp/out.json" })
	eq(a.ok, true, "a new file is written")
	eq(a.path, "/tmp/out.json", "at that path")
	eq(a.json, nil, "and the answer carries no JSON")
	yes(w.fs.files["/tmp/out.json"] ~= nil, "the file exists")
	eq(jsonDecode(w.fs.files["/tmp/out.json"]).format, "plotroom-export", "holding the export")
	w.fs.files["/tmp/out.json"] = "mine"
	local function commitTo(path: string): any
		local p = asks.hx.ask(w, b, { op = "export", views = { "prs:v1" } })
		return asks.hx.ask(w, b, { op = "export", phase = "commit", token = p.token, path = path })
	end
	has(commitTo("/tmp/out.json").problem, "exists already", "a file that exists is refused")
	eq(w.fs.files["/tmp/out.json"], "mine", "and left as it was")
	has(commitTo("relative.json").problem, "not a usable path", "a relative path")
	has(commitTo("/nowhere/out.json").problem, "Not written", "a folder that is not there")
	eq(w.fs.files["/nowhere/out.json"], nil, "nothing was written")
	has(asks.hx.ask(w, b, { op = "export", views = {}, prompts = {} }).problem, "Nothing to export", "an empty selection")
end)

case("host export: a snapshot too big to copy is file-only: the commit without a path is refused, with a path it is written, and the limit is the importer's", function(w: World)
	hostScene(w, 3)
	local list: { { [string]: any } } = {}
	for i = 1, 95 do
		table.insert(list, promptOf("p" .. i, "Action " .. i, string.rep("x", 520)))
	end
	savePrompts(w, list)
	w.fs.dirs["/tmp"] = true
	local b = openQueue(w)
	local ids: { string } = {}
	for i = 1, 95 do
		table.insert(ids, "prs:p" .. i)
	end
	local pv = asks.hx.ask(w, b, { op = "export", prompts = ids })
	eq(pv.count.prompts, 95, "every action is in")
	eq(pv.copyable, false, "its escaped JSON is over 50000 bytes")
	yes(pv.size <= 60000, "within the importer's limit")
	has(asks.hx.ask(w, b, { op = "export", phase = "commit", token = pv.token }).problem, "too large to copy", "no path: refused")
	local p2 = asks.hx.ask(w, b, { op = "export", prompts = ids })
	local done = asks.hx.ask(w, b, { op = "export", phase = "commit", token = p2.token, path = "/tmp/big.json" })
	eq(done.ok, true, "with a path it is written")
	eq(#w.fs.files["/tmp/big.json"], pv.size, "all of it")
	local p3 = asks.hx.ask(w, b, { op = "export", prompts = ids })
	has(asks.hx.ask(w, b, { op = "export", phase = "commit", token = p3.token, path = "/tmp/big.json" }).problem, "exists already", "an existing file is still refused")
end)

case("host import: the preview lists conflicts and account slots, and apply honours skip, replace and duplicate per entry", function(w: World)
	asks.hx.saved(w)
	local b = openQueue(w)
	local exported = asks.hx.exported(w, b, { "prs:v1" }, { "prs:p1" })
	local function preview(): any
		return asks.hx.ask(w, b, { op = "import", phase = "preview", text = exported })
	end
	local function apply(p: any, choice: string, login: string): any
		return asks.hx.ask(w, b, { op = "import", phase = "apply", token = p.token, choices = { ["1"] = choice }, mapping = { ["account-1"] = login } })
	end
	local p = preview()
	eq(#p.entries, 2, "a view and an action")
	eq(p.entries[1].type, "view", "the view comes first")
	eq(p.entries[1].name, "My PRs", "by name")
	eq(p.entries[1].conflict, "same-name", "a saved view has that name")
	eq(p.entries[1].remap[1], "runs as account slot account-1", "and it runs as an exported slot")
	eq(p.entries[2].type, "prompt", "then the action")
	eq(p.entries[2].conflict, "identical", "which is saved as it is")
	same(p.slots, { "account-1" }, "one slot needs a login")
	yes(table.find(p.accounts, "octocat") ~= nil, "the local logins are offered")
	eq(#p.problems, 0, "no problems")
	local views = w.kv.store["views-prs"]
	local skipped = apply(p, "skip", "octocat")
	eq(skipped.ok, true, "skip applies")
	eq(w.kv.store["views-prs"], views, "and writes no view")
	local replaced = apply(preview(), "replace", "@active")
	eq(replaced.ok, true, "replace applies")
	local after: any = w.kv.get("views-prs")
	eq(#after.items, 2, "it replaced the saved view: no new one")
	eq(after.items[1].name, "My PRs", "the view by that name")
	eq(#after.items[1].logins, 0, "now running as gh's active account, the slot's mapping")
	local duplicated = apply(preview(), "duplicate", "octocat")
	eq(duplicated.ok, true, "duplicate applies")
	after = w.kv.get("views-prs")
	eq(#after.items, 3, "a third view was added")
	eq(after.items[3].name, "My PRs (imported)", "under a new name")
	same(after.items[3].logins, { "octocat" }, "as the chosen login")
	same(after.items[3].prompts, { "p1" }, "listing the action it was exported with, which was already saved")
	eq(#w.kv.get("prompts-prs").items, 2, "the identical action was not saved again")
end)

case("host import: an account slot needs an explicit local login, or the view is skipped and nothing is written", function(w: World)
	asks.hx.saved(w)
	local b = openQueue(w)
	local exported = asks.hx.exported(w, b, { "prs:v1" }, { "prs:p1" })
	local views = w.kv.store["views-prs"]
	local cases: { [string]: any } = {
		["no mapping"] = {},
		["an empty login"] = { ["account-1"] = "" },
		["a login that is none"] = { ["account-1"] = "bad login!" },
		["a slot of another name"] = { ["account-9"] = "octocat" },
	}
	for what, mapping in cases do
		local p = asks.hx.ask(w, b, { op = "import", phase = "preview", text = exported })
		local r = asks.hx.ask(w, b, { op = "import", phase = "apply", token = p.token, choices = { ["1"] = "duplicate" }, mapping = mapping })
		eq(r.ok, true, what .. ": answered")
		has(table.concat(r.notes, " "), "no account was chosen for account-1", what .. ": the view is skipped, naming the slot")
		eq(w.kv.store["views-prs"], views, what .. ": nothing was written")
	end
end)

case("host import: a slot mapped to a login with an underscore keeps it, and a login with a space or a slash is not mapped", function(w: World)
	local s = asks.hx.saved(w)
	s.gh.tokens.octo_cat = "tok-underscore"
	local b = openQueue(w)
	local exported = asks.hx.exported(w, b, { "prs:v1" }, { "prs:p1" })
	local views = w.kv.store["views-prs"]
	for _, bad in { "a b", "a/b" } do
		local p = asks.hx.ask(w, b, { op = "import", phase = "preview", text = exported })
		local r = asks.hx.ask(w, b, { op = "import", phase = "apply", token = p.token, choices = { ["1"] = "duplicate" }, mapping = { ["account-1"] = bad } })
		has(table.concat(r.notes, " "), "no account was chosen for account-1", show(bad) .. ": the view is skipped")
		eq(w.kv.store["views-prs"], views, show(bad) .. ": nothing was written")
	end
	local p = asks.hx.ask(w, b, { op = "import", phase = "preview", text = exported })
	local r = asks.hx.ask(w, b, { op = "import", phase = "apply", token = p.token, choices = { ["1"] = "duplicate" }, mapping = { ["account-1"] = "octo_cat" } })
	eq(r.ok, true, "applied")
	eq(r.counts.views, 1, "one view was added")
	lacks(table.concat(r.notes, " "), "View 'My PRs' skipped", "the view was not skipped")
	local saved: any = w.kv.get("views-prs")
	same(saved.items[#saved.items].logins, { "octo_cat" }, "the underscore login is kept")
end)

case("host import: a shortcut an imported action asks for is removed when a Plotroom key, a saved action or an earlier import holds it", function(w: World)
	asks.hx.saved(w)
	local b = openQueue(w)
	local text = jsonEncode({ format = "plotroom-export", version = 1, views = array({}), prompts = array({
		{ id = "prs:p1", kind = "prs", name = "Fresh", text = "Fresh {url}", key = "m" },
		{ id = "prs:p2", kind = "prs", name = "Other", text = "Other {url}", key = "e" },
		{ id = "prs:p3", kind = "prs", name = "Third", text = "Third {url}", key = "t" },
		{ id = "prs:p4", kind = "prs", name = "Clash", text = "Clash {url}", key = "t" },
	}) })
	local p = asks.hx.ask(w, b, { op = "import", phase = "preview", text = text })
	eq(#p.entries, 4, "four actions")
	eq(p.entries[1].remap[1], "shortcut m removed: already used by a Plotroom shortcut", "m is the queue's Mark seen")
	eq(p.entries[2].remap[1], "shortcut e removed: already used by Review", "e is a saved action's")
	eq(#p.entries[3].remap, 0, "t is free")
	eq(p.entries[4].remap[1], "shortcut t removed: already used by Third", "until an earlier action of the import takes it")
	local r = asks.hx.ask(w, b, { op = "import", phase = "apply", token = p.token, choices = {}, mapping = {} })
	eq(r.ok, true, "applied")
	local keys: { string } = {}
	for _, item in w.kv.get("prompts-prs").items do
		table.insert(keys, item.name .. "=" .. (item.key or "-"))
	end
	same(keys, { "Review=e", "Leaky=-", "Fresh=-", "Other=-", "Third=t", "Clash=-" }, "only the free shortcut was kept")
end)

case("host import: nothing is written while saved views or actions cannot be read, a preview token works once, and bad, forbidden or oversize exports are refused", function(w: World)
	asks.hx.saved(w)
	local b = openQueue(w)
	local exported = asks.hx.exported(w, b, { "prs:v1" }, { "prs:p1" })
	local function preview(body: { [string]: any }?): any
		local q: { [string]: any } = { op = "import", phase = "preview", text = exported }
		local extra: { [string]: any } = body or {}
		for k, v in extra do
			q[k] = v
		end
		return asks.hx.ask(w, b, q)
	end
	local function apply(token: any): any
		return asks.hx.ask(w, b, { op = "import", phase = "apply", token = token, choices = { ["1"] = "duplicate" }, mapping = { ["account-1"] = "octocat" } })
	end
	local views, prompts = w.kv.store["views-prs"], w.kv.store["prompts-prs"]
	local p = preview()
	w.kv.failGet["prompts-prs"] = "disk gone"
	has(apply(p.token).problem, "disk gone", "an apply that cannot read the saved actions is refused")
	has(preview().problem, "disk gone", "so is a preview")
	w.kv.failGet["prompts-prs"] = nil
	w.kv.failGet["views-prs"] = "disk gone"
	has(preview().problem, "disk gone", "and one that cannot read the saved views")
	w.kv.failGet["views-prs"] = nil
	eq(w.kv.store["views-prs"], views, "no view was overwritten")
	eq(w.kv.store["prompts-prs"], prompts, "no action was overwritten")
	has(apply(p.token).problem, "expired", "a refused apply used the token up")
	local q = preview()
	eq(apply(q.token).ok, true, "a new preview applies")
	has(apply(q.token).problem, "expired", "a token works once")
	has(apply("i0_0").problem, "expired", "a token this block never issued")
	has(preview({ text = string.rep("x", 60001) }).problem, "larger than 60000", "an export over 60000 bytes")
	eq(preview({ text = string.rep("x", 130000) }), nil, "a request over the size cap is not answered")
	has(preview({ text = "hello" }).problem, "not an export", "text that is not JSON")
	has(preview({ text = jsonEncode({ format = "plotroom-export", version = 2 }) }).problem, "not a version 1", "another version")
	local forbidden = jsonEncode({
		format = "plotroom-export",
		version = 1,
		prompts = array({}),
		views = array({ { kind = "prs", name = "X", integration = "github", query = "q", group = "none", accounts = array({}), prompts = array({}), path = "/etc" } }),
	})
	has(preview({ text = forbidden }).problem, "never accepts", "a field that could carry a path")
	eq(asks.hx.ask(w, b, { op = "import", phase = "preview" }).problem, "Paste the exported JSON or give a file path.", "neither text nor path")
	w.fs.files["/tmp/in.json"] = exported
	local byPath = asks.hx.ask(w, b, { op = "import", phase = "preview", path = "/tmp/in.json" })
	eq(#byPath.entries, 2, "a file on this host previews like its text")
	has(asks.hx.ask(w, b, { op = "import", phase = "preview", path = "/tmp/missing.json" }).problem, "could not be read", "a file that is not there")
	has(asks.hx.ask(w, b, { op = "import", phase = "preview", path = "relative.json" }).problem, "not a usable path", "a relative path")
end)

case("host open-url: a GitHub pull request, a GitHub issue and a Jira issue URL are fetched and shown as pinned scopes that accumulate, the other views stay, and the pins are saved", function(w: World)
	local s = jiraHost(w)
	local prUrl = "https://github.com/o/r/pull/45"
	local issueUrl = "https://github.com/o/r/issues/12"
	s.gh.pulls[prUrl] = searchItem(45, "o/r", EPOCH - 60)
	s.gh.pulls[issueUrl] = issueItem(12, "o/r", EPOCH - 60, { title = "Fix login" })
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local b = openIssues(w)
	local function labels(): { string }
		local out: { string } = {}
		for _, scope in pickerOf(b).scopes do
			table.insert(out, scope.label)
		end
		return out
	end
	local r = asks.hx.ask(w, b, { op = "open-url", url = prUrl })
	eq(r.ok, true, "a pull request URL is accepted")
	eq(r.message, "Showing o/r#45 in Plotroom", "and said so")
	eq(requestsOf(s.gh, "pull")[1].fields.q, prUrl, "gh looked it up by its URL")
	eq(pickerOf(b).scopes[1].label, "o/r#45", "it is the first scope")
	eq(pickerOf(b).scopes[1].group, "Pins", "under the Pins group")
	eq(pickerOf(b).scope, "pin:o/r#45", "and the active one, by its item's key")
	eq(pickerOf(b).selected, "no_2fr_2345", "its pull request is selected")
	yes(table.find(labels(), "Assigned to me") ~= nil, "the other views are still in the sidebar")
	same(b.saved().pins, { prUrl }, "the pin is saved with the block")
	eq(b.saved().activeViewId, "pin:o/r#45", "and its scope is the saved active view")
	r = asks.hx.ask(w, b, { op = "open-url", url = issueUrl })
	eq(r.message, "Showing o/r#12 in Plotroom", "an issue URL is shown the same way")
	same({ labels()[1], labels()[2] }, { "o/r#45", "o/r#12" }, "the new pin joins the earlier one")
	eq(pickerOf(b).scope, "pin:o/r#12", "and is the active scope")
	eq(pickerOf(b).noun, "issues", "the pin lists issues")
	eq(pickerOf(b).selected, "no_2fr_2312", "with its issue selected")
	yes(table.find(labels(), "Assigned to me") ~= nil, "the other views stay")
	same(b.saved().pins, { prUrl, issueUrl }, "an issue pin is saved by its URL after the first")
	local again = asks.hx.ask(w, b, { op = "open-url", url = prUrl })
	eq(again.ok, true, "the same URL again is accepted")
	same({ labels()[1], labels()[2] }, { "o/r#45", "o/r#12" }, "without a second pin")
	eq(#b.saved().pins, 2, "or a second saved URL")
	eq(pickerOf(b).scope, "pin:o/r#45", "it shows the pin it already has")
	local restored = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	same({ pickerOf(restored).scopes[1].label, pickerOf(restored).scopes[2].label }, { "o/r#45", "o/r#12" }, "a restored block shows both pins again")
	eq(pickerOf(restored).scope, "pin:o/r#45", "on the active one")
	eq(pickerOf(restored).selected, nil, "with nothing selected")
	r = asks.hx.ask(w, b, { op = "open-url", url = "https://acme.atlassian.net/browse/ABC-12" })
	eq(r.message, "Showing ABC-12 in Plotroom", "a Jira browse URL is shown too")
	yes(acliCount(s.acli, "view") >= 1, "acli read the work item")
	eq(pickerOf(b).scopes[3].label, "ABC-12", "as a pinned scope, though the Jira view lists the issue")
	eq(pickerOf(b).scope, "pin:abc#ABC-12", "the active one")
	eq(pickerOf(b).selected, "nabc_23ABC-12", "selected")
	yes(table.find(labels(), "Assigned to me") ~= nil, "beside the Jira view")
	same(b.saved().pins, { prUrl, issueUrl, "https://acme.atlassian.net/browse/ABC-12" }, "and saved")
	eq(b.saved().activeViewId, "pin:abc#ABC-12", "the Jira pin's id is saved whole")
end)

case("host open-url: another site's URL, garbage, an item that is not found and an oversize URL are refused with nothing shown and no gh or acli call for a URL that names no item", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local b = openIssues(w)
	eq(asks.hx.ask(w, b, { op = "open-url", url = "https://acme.atlassian.net/browse/ABC-12" }).ok, true, "a first pin, though the view lists it")
	local views = acliCount(s.acli, "view")
	local function same_pin()
		eq(pickerOf(b).scopes[1].label, "ABC-12", "the pin is as it was")
	end
	for _, url in {
		"garbage",
		"",
		"https://evil.com/o/r/pull/1",
		"https://github.com.evil.com/o/r/pull/1",
		"http://github.com/o/r/pull/1",
		"https://github.com/o/r/commit/1",
		"https://acme.atlassian.net/wiki/x",
	} do
		local calls = #w.calls
		local r = asks.hx.ask(w, b, { op = "open-url", url = url })
		has(r.problem, "not a GitHub pull request or issue URL, or a Jira issue URL", "refused: " .. url)
		eq(r.ok, nil, "not accepted: " .. url)
		eq(#w.calls, calls, "nothing was spawned for " .. url)
		same_pin()
	end
	local other = asks.hx.ask(w, b, { op = "open-url", url = "https://other.atlassian.net/browse/ABC-12" })
	has(other.problem, "other.atlassian.net", "another Jira site is refused, naming it")
	eq(acliCount(s.acli, "view"), views, "its work item was never read")
	same_pin()
	eq(asks.hx.ask(w, b, { op = "open-url", url = "https://github.com/o/r/" .. string.rep("a", 2049) }), nil, "a URL over 2048 bytes is not answered")
	local missing = asks.hx.ask(w, b, { op = "open-url", url = "https://github.com/o/r/pull/999" })
	yes(missing.problem ~= nil and missing.ok == nil, "a pull request gh cannot see is reported, not shown")
	same_pin()
end)

case("host open-url: the pin cap refuses only a new pin, tells Open by URL, and a pin already kept is shown again; a pin scope has no sort", function(w: World)
	local s = jiraHost(w)
	local url = function(n: number): string
		return "https://github.com/o/r/pull/" .. n
	end
	for n = 1, 21 do
		s.gh.pulls[url(n)] = searchItem(n, "o/r", EPOCH - 60)
	end
	local b = openIssues(w)
	for n = 1, 20 do
		eq(asks.hx.ask(w, b, { op = "open-url", url = url(n) }).ok, true, "pin " .. n)
	end
	goToSettings(b, "keys")
	local scopeBefore = pickerOf(b).scope
	local full = asks.hx.ask(w, b, { op = "open-url", url = url(21) })
	has(full.problem, "Pins are full", "a 21st pin is refused to the window, not answered with success")
	eq(full.ok, nil, "no contradictory success")
	eq(#b.saved().pins, 20, "and nothing was added")
	yes(b.state().settings ~= nil, "a refused pin leaves Settings open")
	eq(pickerOf(b).scope, scopeBefore, "and the shown scope as it was")
	eq(asks.hx.ask(w, b, { op = "open-url", url = url(3) }).ok, true, "a pin already kept is shown again at the cap")
	eq(table.find(hx.palette(w, b).ids, "sort"), nil, "a pin scope offers no sort order")
end)

case("host open-url: a lookup that answers another item than the URL names shows nothing and leaves the pin as it was", function(w: World)
	local s = jiraHost(w)
	local good = "https://github.com/o/r/pull/45"
	local wrong = "https://github.com/o/r/pull/46"
	s.gh.pulls[good] = searchItem(45, "o/r", EPOCH - 60)
	s.gh.pulls[wrong] = searchItem(99, "o/r", EPOCH - 60) -- gh answers a different pull request than the one asked for
	local b = openIssues(w)
	eq(asks.hx.ask(w, b, { op = "open-url", url = good }).ok, true, "a first pin")
	eq(pickerOf(b).scopes[1].label, "o/r#45", "it is pinned")
	same(listed(b), { "no_2fr_2345" }, "and lists only that pull request")
	local r = asks.hx.ask(w, b, { op = "open-url", url = wrong })
	yes(r.problem ~= nil and r.ok == nil, "the answer for another item is refused")
	eq(pickerOf(b).scopes[1].label, "o/r#45", "the earlier pin is still the first scope")
	same(listed(b), { "no_2fr_2345" }, "and still lists only its own pull request")
end)

case("host keys: a saved custom key equal to an action's default leaves that action with no key, the binding keeps working, and Settings shows the removal", function(w: World)
	hostScene(w, 3)
	w.kv.put("keys", { worktree = "." })
	local b = openQueue(w)
	eq(actionOf(b, "more"), nil, "the command palette has no key, so no button: the user's binding holds .")
	same(actionOf(b, "worktree").keys, { "." }, "the custom binding is the Worktree key")
	local opened = #w.opened
	eq(b.press(".", nil, "."), true, ". is handled")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and still makes the worktree")
	eq(#w.opened, opened + 1, "it opened no palette")
	goToSettings(b, "keys")
	eq(rowIn(b, "key:more").control.value, "", "Settings shows the shortcut removed")
	same(w.kv.get("keys"), { worktree = "." }, "nothing was written")
end)

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

case("host import: a preview lists every entry up to 150 and refuses more, storing nothing", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local big = asks.hx.ask(w, b, { op = "import", phase = "preview", text = asks.hx.doc(100, 51) })
	has(big.problem, "151 entries", "151 entries are refused, naming the count")
	eq(big.token, nil, "with no token")
	local views, prompts = w.kv.store["views-prs"], w.kv.store["prompts-prs"]
	local r = asks.hx.ask(w, b, { op = "import", phase = "apply", token = "i0_1", choices = {}, mapping = {} })
	has(r.problem, "expired", "an apply has nothing to apply")
	eq(w.kv.store["views-prs"], views, "no view was written")
	eq(w.kv.store["prompts-prs"], prompts, "no action was written")
	local ok = asks.hx.ask(w, b, { op = "import", phase = "preview", text = asks.hx.doc(100, 50) })
	eq(#ok.entries, 150, "150 entries list every one")
	yes(ok.token ~= nil, "with a token")
end)

case("host import: an apply that skips everything says nothing was imported and writes nothing; a real one counts the views and actions it added", function(w: World)
	asks.hx.saved(w)
	local b = openQueue(w)
	local exported = asks.hx.exported(w, b, { "prs:v1" }, { "prs:p1" })
	local views, prompts = w.kv.store["views-prs"], w.kv.store["prompts-prs"]
	local p = asks.hx.ask(w, b, { op = "import", phase = "preview", text = exported })
	local r = asks.hx.ask(w, b, { op = "import", phase = "apply", token = p.token, choices = { ["1"] = "skip", ["2"] = "skip" }, mapping = { ["account-1"] = "octocat" } })
	eq(r.ok, true, "answered")
	eq(r.nothing, true, "and says nothing was imported")
	eq(r.counts, nil, "with no counts")
	eq(w.kv.store["views-prs"], views, "no view was written")
	eq(w.kv.store["prompts-prs"], prompts, "no action was written")
	p = asks.hx.ask(w, b, { op = "import", phase = "preview", text = exported })
	r = asks.hx.ask(w, b, { op = "import", phase = "apply", token = p.token, choices = { ["1"] = "duplicate", ["2"] = "replace" }, mapping = { ["account-1"] = "octocat" } })
	eq(r.ok, true, "a real apply is ok")
	eq(r.nothing, nil, "and is not nothing")
	same(r.counts, { views = 1, prompts = 0 }, "one view added; the replaced action is not a new one")
	has(r.message, "Imported 1 view and 0 actions", "the message says what was added")
end)

case("host views: moving a view to the other kind keeps a sort that kind offers, and resets one it does not with a toast", function(w: World)
	hostScene(w, 3)
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Reviews", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}), sort = "review" },
		{ id = "v2", name = "Recent", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}), sort = "updated" },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open assignee:@me", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v2")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:prs:v2", value = "issues" })
	local moved: any = w.kv.get("views-issues").items[#w.kv.get("views-issues").items]
	eq(moved.name, "Recent", "the view moved")
	eq(moved.sort, "updated", "a sort issues offer is kept")
	for _, t in w.toasts do
		lacks(t.text, "Sort order reset", "and nothing was said")
	end
	expand(b, "vopen:prs:v1")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:prs:v1", value = "issues" })
	moved = w.kv.get("views-issues").items[#w.kv.get("views-issues").items]
	eq(moved.name, "Reviews", "the second view moved")
	eq(moved.sort, nil, "a review order issues do not offer is reset")
	eq(w.toasts[#w.toasts].text, "Sort order reset", "and a toast says so")
	has(w.toasts[#w.toasts].sub, "Review required first", "naming the order")
end)

case("host agents: the hidden main.agents node says the agent map as sorted key=state; pairs, empty with none, and a reloaded block starts empty", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local function sig(block: Block): any
		return findKey(block.view().main, "agents").p.text
	end
	eq(sig(b), "", "no agents: empty")
	asks.hx.agents(b, { ["o/r#2"] = "idle", ["o/r#1"] = "working" })
	eq(sig(b), "o/r#1=working;o/r#2=idle;", "pairs in key order")
	asks.hx.agents(b, {})
	eq(sig(b), "", "an empty report empties it")
	asks.hx.agents(b, { ["o/r#3"] = "waiting_input" })
	eq(sig(b), "o/r#3=waiting_input;", "one pair")
	local again = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(sig(again), "", "a reloaded block holds no map, so the window sends it again")
end)

-- END host workflow cases

function M.run(instantiate: Loader)
	local failed = 0
	for _, c in cases do
		local w = newWorld(instantiate, c.context)
		local ok, err = xpcall(function()
			c.run(w)
			w.finish()
		end, debug.traceback)
		if not ok then
			failed += 1
			print("FAIL " .. c.name .. "\n" .. tostring(err) .. "\n")
		end
	end
	print(string.format("REGRESSION cases=%d failed=%d", #cases, failed))
	if failed > 0 then
		error(failed .. " regression case(s) failed", 0)
	end
end

-- Prints `BENCH <name> ms=<n>` per measured step of the real queue view with 1000 loaded PRs; scripts/check.py fails the
-- gate when a step is slower than its budget.
function M.bench(instantiate: Loader)
	local w = newWorld(instantiate, "host")
	w.setEncodeViews(false) -- Tern serializes the view itself; the fake's encoder is not what is measured
	local s = hostScene(w, 0)
	local items: { { [string]: any } } = {}
	for i = 1, 1000 do
		table.insert(items, searchItem(i, "o/r", EPOCH - i * 60, {
			title = "A reasonably long pull request title, number " .. i .. ", that wraps in a narrow pane",
			labels = array({ "bug", "area/ui" }),
			review = if i % 3 == 0 then "APPROVED" else "REVIEW_REQUIRED",
			checks = if i % 5 == 0 then "FAILURE" else "SUCCESS",
			isDraft = i % 7 == 0,
		}))
	end
	s.gh.items.octocat = items
	local b = openQueue(w)
	local shown: any = pickerOf(b).items
	if #shown ~= 1000 then
		error("the benchmark expected 1000 loaded pull requests, got " .. #shown, 0)
	end
	local function timed(name: string, rounds: number, step: (number) -> ())
		local started = os.clock()
		for i = 1, rounds do
			step(i)
		end
		print(string.format("BENCH %s ms=%.2f rounds=%d", name, (os.clock() - started) * 1000 / rounds, rounds))
	end
	timed("render", 20, function(_i: number)
		b.render()
	end)
	timed("cursor-down", 20, function(_i: number)
		b.press("down")
	end)
	b.typeText("/")
	local typed = { "a", " ", "r" }
	timed("search-keystroke", #typed, function(i: number)
		b.typeText(typed[i])
	end)
	b.press("escape")
	b.press("escape")
	local payload = jsonEncode(b.view())
	print(string.format("BENCH payload bytes=%d items=%d", #payload, #shown))
end

return M
