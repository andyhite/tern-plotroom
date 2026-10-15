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
	runs: { { pane: number, text: string } }, -- every cx:run (text typed into a pane)
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
	open: (number, { string }?, any?, string?) -> Block, -- pane, launch args, saved state, block id ("prs" unless given)
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
	local responders: { Responder } = {}
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
		},
		hosts = {
			list = function(_self: any): any
				local ids: { number } = {}
				for id in win.panes do
					table.insert(ids, id)
				end
				return { { id = 1, kind = if win.remoteHost then "remote" else "local", panes = ids } }
			end,
		},
		browser = {
			call = function(_self: any, req: any): any
				table.insert(win.browser, req)
				return {
					next = function(_self2: any, fn: (any, any, any) -> ())
						schedule(0, function()
							fn({ ok = { block = 99 } }, nil, windowCx)
						end)
					end,
				}
			end,
		},
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
		prompt = function(_self: any, _opts: any): any
			return {
				next = function(_self2: any, fn: (any, any, any) -> ())
					schedule(0, function()
						fn(win.typed, nil, windowCx)
					end)
				end,
			}
		end,
		agents = {
			start = function(_self: any, opts: any): number
				table.insert(win.agents, opts)
				return addPane({ cwd = opts.cwd }, nil)
			end,
		},
	}

	local fakeOs: any = {
		time = function(t: any?): number
			if t ~= nil then
				error("the fake os.time does not take a table", 2)
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
				blocks[id] = def
			end,
		},
		command = function(def: any)
			commands[def.id] = def
		end,
		on = function(_name: string, _fn: any) end, -- lifecycle events never fire in the fake world
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

	local function open(pane: number, args: { string }?, savedState: any?, blockId: string?): Block
		local def: any = blocks[blockId or "prs"]
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
			cols = 120,
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
	meta: { [string]: { base: string, sha: string, ref: string, state: string, baseRef: string?, title: string?, author: string? } }, -- "owner/repo#N" -> pulls/N
	checks: { [string]: { any } }, -- "owner/repo#N" -> check nodes of its latest commit
	checkTotal: { [string]: number },
	about: { [string]: { [string]: any } }, -- "owner/repo#N" -> the `about` part CHECKS_JQ prints
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

type GitWorktree = { path: string, branch: string?, head: string, locked: boolean }
type Git = {
	root: string,
	remotes: { [string]: { string } }, -- name -> urls: `remote get-url --all` lists them, fetch uses the first
	served: { [string]: string }, -- what the remote serves (refs/pull/N/head) -> sha
	refs: { [string]: string }, -- local refs -> sha
	worktrees: { GitWorktree }, -- [1] is the main worktree
	dirty: { [string]: string }, -- worktree path -> `status --porcelain` output
	fail: { [string]: Reply }, -- "fetch", "status", "worktree add", "rev-parse HEAD"... -> the answer instead of the model's
	lockFetch: { winner: string? }?, -- another window holds the ref's lock; `winner` is the sha it leaves there
	onFetch: (() -> ())?, -- runs inside every fetch: the remote moves
	onAdd: (() -> ())?, -- runs before every worktree add: another window acts
	afterAdd: ((string) -> ())?, -- a post-checkout hook: runs after a worktree was added
	log: { string }, -- the arguments of every command, joined by spaces
}

local gitFallback: { [any]: boolean } = {}

local function newGit(w: World, root: string): Git
	local g: Git = {
		root = root,
		remotes = {},
		served = {},
		refs = { ["refs/heads/main"] = sha("1") },
		worktrees = { { path = root, branch = "refs/heads/main", head = sha("1"), locked = false } },
		dirty = {},
		fail = {},
		lockFetch = nil,
		onFetch = nil,
		onAdd = nil,
		afterAdd = nil,
		log = {},
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
		elseif sub == "check-ref-format" then
			-- `check-ref-format --branch <name>`: a valid name is echoed, anything else is refused
			local name = args[3] or ""
			if args[2] == "--branch" and validRef("refs/heads/" .. name) then
				return { stdout = name .. "\n" }
			end
			return { status = 128, stderr = "fatal: '" .. name .. "' is not a valid branch name\n" }
		elseif sub == "worktree" and args[2] == "list" then
			local out: { string } = {}
			for _, t in g.worktrees do
				table.insert(out, "worktree " .. t.path .. "\0")
				table.insert(out, "HEAD " .. t.head .. "\0")
				table.insert(out, if t.branch then "branch " .. t.branch .. "\0" else "detached\0")
				if t.locked then
					table.insert(out, "locked\0")
				end
				table.insert(out, "\0")
			end
			return { stdout = table.concat(out) }
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
		end
		return nil
	end)
	return g
end

local function snapshot(g: Git): string
	return jsonEncode({ refs = g.refs, worktrees = g.worktrees, dirty = g.dirty })
end

-- How many logged commands from entry `from`+1 on start with `prefix`.
local function countLog(g: Git, prefix: string, from: number?): number
	local n = 0
	for i = (from or 0) + 1, #g.log do
		if string.sub(g.log[i], 1, #prefix) == prefix then
			n += 1
		end
	end
	return n
end

-- ---- worktree.luau: names, remotes, wording

type Worktree = typeof(require("../worktree"))

case("worktree: git-illegal names that GitHub allows are encoded in the branch and ref, never rejected", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local expect: { { string } } = {
		{ "github", ".github", "plotroom/github/%2Egithub/pr-1" },
		{ "o", "a..b", "plotroom/o/a.%2Eb/pr-1" },
		{ "o", "x.lock", "plotroom/o/x%2Elock/pr-1" },
		{ "o", ".lock", "plotroom/o/%2Elock/pr-1" },
		{ "o", "...", "plotroom/o/%2E.%2E/pr-1" },
		{ "o", "foo.js", "plotroom/o/foo.js/pr-1" },
		{ "O", "R", "plotroom/o/r/pr-1" },
		{ "-x", "a.", "plotroom/-x/a./pr-1" },
	}
	for _, row in expect do
		local branch, ref = worktree.refNames(row[1], row[2], 1)
		eq(branch, row[3], "branch of " .. row[1] .. "/" .. row[2])
		eq(ref, "refs/plotroom-pr/" .. string.sub(row[3], #"plotroom/" + 1), "ref of " .. row[1] .. "/" .. row[2])
		yes(validRef("refs/heads/" .. branch), "git accepts the branch of " .. row[2])
		yes(validRef(ref), "git accepts the ref of " .. row[2])
	end
end)

case("worktree: ref names are injective and git-acceptable for every legal name over a small alphabet", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local alphabet = { ".", "a", "l", "o", "c", "k" }
	local seen: { [string]: string } = {}
	local count = 0
	local function visit(prefix: string, depth: number)
		if prefix ~= "" and worktree.validSegment(prefix) then
			local branch, ref = worktree.refNames("o", prefix, 1)
			yes(validRef("refs/heads/" .. branch), "branch for " .. prefix)
			yes(validRef(ref), "ref for " .. prefix)
			local clash = seen[branch]
			if clash ~= nil then
				error("the names " .. clash .. " and " .. prefix .. " share the branch " .. branch, 0)
			end
			seen[branch] = prefix
			count += 1
			local needsEscape = string.sub(prefix, 1, 1) == "." or string.find(prefix, "..", 1, true) ~= nil or string.sub(prefix, -5) == ".lock"
			if not needsEscape and branch ~= "plotroom/o/" .. prefix .. "/pr-1" then
				error("the name " .. prefix .. " needs no escaping but became " .. branch, 0)
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
		path = "/work/r.plotroom/o/r/pr-5",
		root = "/work/r",
		remote = "origin",
		branch = "plotroom/o/r/pr-5",
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

case("worktree: update and cleanup are single-line shell words, quoted for spaces, quotes and control characters", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local current = resultOf(false, sha("b"), sha("b"), false)
	same(worktree.update(current :: any), {}, "nothing to update when current")
	local behind = resultOf(false, sha("b"), sha("c"), false)
	same(worktree.update(behind :: any), {
		"git -C /work/r.plotroom/o/r/pr-5 fetch origin refs/pull/5/head",
		"git -C /work/r.plotroom/o/r/pr-5 merge --ff-only FETCH_HEAD",
	}, "update")
	same(worktree.cleanup(behind :: any), {
		"git -C /work/r worktree remove /work/r.plotroom/o/r/pr-5",
		"git -C /work/r branch -d plotroom/o/r/pr-5",
		"git -C /work/r update-ref -d refs/plotroom-pr/o/r/pr-5",
	}, "cleanup")
	local odd = resultOf(false, sha("b"), sha("c"), false)
	odd.path = "/tmp/a b/it's"
	eq(worktree.update(odd :: any)[1], "git -C '/tmp/a b/it'\\''s' fetch origin refs/pull/5/head", "spaces and quotes")
	odd.path = "/tmp/a\nb"
	local entries = worktree.update(odd :: any)
	eq(entries[1], "git -C $'/tmp/a\\x0ab' fetch origin refs/pull/5/head", "a newline")
	lacks(entries[1], "\n", "a command stays on one line")
	local encoded = resultOf(false, sha("b"), sha("c"), false)
	encoded.branch = "plotroom/github/%2Egithub/pr-1"
	eq(worktree.cleanup(encoded :: any)[2], "git -C /work/r branch -d plotroom/github/%2Egithub/pr-1", "an encoded branch is a plain word")
end)

-- ---- worktree.open against the git and gh models

type Scene = { git: Git, gh: Gh, repo: string, number: number, root: string, target: string, branch: string, ref: string, launch: string }

-- A checkout of owner/name at /work/<name> whose origin is github.com/owner/name, with PR `n` at sha("b") on both
-- the remote and gh.
local function scene(w: World, worktree: Worktree, owner: string, name: string, n: number): Scene
	local root = "/work/" .. name
	local g = newGit(w, root)
	local repo = owner .. "/" .. name
	g.remotes.origin = { "https://github.com/" .. repo .. ".git" }
	g.served["refs/pull/" .. n .. "/head"] = sha("b")
	local gh = newGh(w)
	gh.meta[repo .. "#" .. n] = { base = repo, sha = sha("b"), ref = "feature", state = "open", baseRef = "main", title = "Add a feature", author = "ann" }
	w.fs.dirs[root .. "/src"] = true
	local branch, ref = worktree.refNames(owner, name, n)
	return {
		git = g,
		gh = gh,
		repo = repo,
		number = n,
		root = root,
		target = "/wt/plotroom-" .. string.lower(owner) .. "_" .. string.lower(name) .. "-pr-" .. n,
		branch = branch,
		ref = ref,
		launch = root .. "/src",
	}
end

type Opened = { calls: number, result: any, problem: string?, cx: any }

-- Opens the scene's PR from `checkout` (the scene's launch directory by default).
local function openWt(w: World, worktree: Worktree, s: Scene, checkout: string?, waitMs: number?): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.open(checkout or s.launch, s.repo, s.number, "", nil, function(result, problem, cx)
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
	eq(r.branch, "plotroom/o/r/pr-5", "branch")
	eq(r.ref, "refs/plotroom-pr/o/r/pr-5", "ref")
	eq(r.created, true, "created")
	eq(r.head, sha("b"), "head")
	eq(r.prHead, sha("b"), "prHead")
	eq(r.prRef, "feature", "prRef")
	eq(r.dirty, false, "dirty")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], sha("b"), "the PR head is fetched into refs/plotroom-pr/")
	eq(s.git.refs["refs/heads/plotroom/o/r/pr-5"], sha("b"), "the branch starts at the PR head")
	eq(s.git.worktrees[2].path, s.target, "the worktree is registered")
	eq(w.fs.mkdirs[1], "/wt", "omp's worktrees directory was created")
	eq(countLog(s.git, "worktree add -b plotroom/o/r/pr-5 /wt/plotroom-o_r-pr-5 " .. sha("b")), 1, "added through omp worktree add")
	local created = worktree.describe(r)
	has(created, "Created", "summary: new")
	has(created, "Current", "summary: at the PR head")
	has(created, "Clean", "summary: no local changes")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5"), 1, "one fetch")
	eq(countLog(s.git, "worktree add -b plotroom/o/r/pr-5 " .. s.target .. " " .. sha("b")), 1, "one worktree add")
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
	eq(#worktree.update(again.result), 2, "the update commands are offered, not run")
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

windowCase("worktree: a local branch elsewhere is left untouched with the ways forward spelled out", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/plotroom/o/r/pr-5"] = sha("d")
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	has(out.problem, "plotroom/o/r/pr-5", "names the branch")
	has(out.problem, "ddddddd", "and where it is")
	has(out.problem, "bbbbbbb", "and where the pull request head is")
	has(out.problem, "worktree add " .. s.target .. " plotroom/o/r/pr-5", "reopen as it is")
	has(out.problem, "branch -D plotroom/o/r/pr-5", "start over")
	eq(s.git.refs["refs/heads/plotroom/o/r/pr-5"], sha("d"), "the branch did not move")
	eq(#s.git.worktrees, 1, "no worktree was added")
	eq(countLog(s.git, "worktree add"), 0, "no add was attempted")
end)

windowCase("worktree: a branch already at the PR head is attached, not recreated", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/plotroom/o/r/pr-5"] = sha("b")
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.created, true, "created")
	eq(countLog(s.git, "worktree add " .. s.target .. " plotroom/o/r/pr-5"), 1, "attached with the two-argument form")
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
		worktree.worktreesDir("", "/work/r", function(d: string?)
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

windowCase("worktree: worktree root is omp's directory when empty, an absolute path as it is, a relative one from the checkout", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local function pathFor(place: string): string?
		local s = scene(w, worktree, "o", "r", 1)
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.open(s.launch, s.repo, s.number, place, nil, function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		w.flush()
		eq(out.problem, nil, "problem for " .. place)
		return if out.result then out.result.path else nil
	end
	eq(pathFor(""), "/wt/plotroom-o_r-pr-1", "empty: omp's worktrees directory")
	eq(pathFor("/abs/wt"), "/abs/wt/plotroom-o_r-pr-1", "an absolute root is used as it is")
	eq(pathFor("../wt"), "/work/wt/plotroom-o_r-pr-1", "a relative root is resolved against the checkout /work/r")
end)

-- ---- worktree.openIssue against the git model

type IssueRepo = { git: Git, target: string, launch: string }

-- A checkout of o/r at /work/r (launched from its src directory) whose origin is github.com/o/r and whose remote serves
-- its default branch, HEAD, at sha("b"); `target` is where issue `ref`'s worktree goes.
local function issueRepo(w: World, ref: string): IssueRepo
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	g.served["HEAD"] = sha("b")
	w.fs.dirs["/work/r/src"] = true
	return { git = g, target = "/wt/plotroom-o_r-issue-" .. ref, launch = "/work/r/src" }
end

-- Opens issue `key` of o/r on `branch` from `checkout` (the repository's src directory by default).
local function openIssueWt(w: World, worktree: Worktree, r: IssueRepo, key: string, branch: string, checkout: string?): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.openIssue(checkout or r.launch, "o/r", key, branch, "", function(result, problem, cx)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.cx = cx
	end)
	w.flush()
	return out
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

windowCase("worktree.openIssue: creates the issue's branch at the remote's default branch and reports Created and Clean", function(w: World)
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
	eq(countLog(r.git, "fetch --no-tags --no-write-fetch-head origin +HEAD:refs/plotroom-base/o/r"), 1, "the default branch is fetched into Plotroom's own ref")
	eq(r.git.refs["refs/plotroom-base/o/r"], sha("b"), "which holds the remote's HEAD")
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
		worktree.openIssue(r.launch, repo, key, branch, "", function(result, problem, cx)
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
	eq(#w.calls, 0, "no process was started")
	r.git.remotes.origin = { "https://github.com/x/y.git" }
	local none = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(none.calls, 1, "done calls")
	eq(none.problem, worktree.NO_REPO, "a checkout of another repository is NO_REPO")
	eq(none.result, nil, "result")
	local other = newGit(w, "/work/other")
	other.remotes.origin = { "https://github.com/o/r.git" }
	other.served["HEAD"] = sha("c")
	local given = openIssueWt(w, worktree, r, "12", "12-fix-login", "/work/other")
	eq(given.problem, nil, "the checkout given resolves")
	eq(given.result.root, "/work/other", "and is the one used")
	eq(given.result.head, sha("c"), "with its own remote's default branch")
end)

windowCase("worktree.openIssue: a remote whose default branch cannot be read creates neither branch nor worktree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.served["HEAD"] = nil
	local missing = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(missing.calls, 1, "done calls")
	eq(missing.result, nil, "no result")
	has(missing.problem, "couldn't find remote ref HEAD", "git's own message")
	r.git.fail["fetch"] = {}
	local silent = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(silent.problem, "Could not read the default branch of o/r.", "a fetch that left no ref says so")
	eq(r.git.refs["refs/heads/12-fix-login"], nil, "no branch was made")
	eq(#r.git.worktrees, 1, "and no worktree")
	eq(countLog(r.git, "worktree add"), 0, "git was never asked to add one")
end)

windowCase("worktree.openIssue: a Jira issue is made in the GitHub repository's checkout, in the repository's own directory", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "ABC-7")
	local function open(key: string): Opened
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.openIssue(r.launch, "o/r", key, key .. "-fix", "", function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		w.flush()
		return out
	end
	local out = open("ABC-7")
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.result.path, "/wt/plotroom-o_r-issue-ABC-7", "the repository's slot, the key in its own case")
	eq(out.result.remote, "origin", "origin")
	eq(out.result.key, "ABC-7", "key")
	eq(out.result.branch, "ABC-7-fix", "branch")
	eq(out.result.created, true, "created")
	eq(countLog(r.git, "fetch --no-tags --no-write-fetch-head origin +HEAD:refs/plotroom-base/o/r"), 1, "the default branch is fetched into the repository's base ref")
	eq(r.git.refs["refs/heads/ABC-7-fix"], sha("b"), "the branch starts at the remote's default branch")
	same({ worktree.itemOfPath(out.result.path) }, { "abc#ABC-7", "issue" }, "the path maps back to the Jira key")
	same({ worktree.itemOfPath(out.result.path .. "/src") }, { "abc#ABC-7", "issue" }, "from a directory inside it too")
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
		worktree.openIssue(r.launch, bad[1], bad[2], "x", "", function(result, problem, cx)
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

case("worktree: describeIssue and cleanupIssue say how the issue's worktree stands and how to remove it", function(w: World)
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
	same(worktree.cleanupIssue(result(true, false)), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-issue-12",
		"git -C /work/r branch -d 12-fix-login",
	}, "the commands that remove the worktree, then its branch")
	local odd = result(false, false)
	odd.path = "/tmp/a b/it's"
	eq(worktree.cleanupIssue(odd)[1], "git -C /work/r worktree remove '/tmp/a b/it'\\''s'", "a path with spaces and quotes is one shell word")
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

-- The settings view's page props: the side sheet in the layer, after the queue's picker.
local function prefsOf(b: Block): any
	local view: any = b.view()
	return findKey(view.layer, "settings", "prefs").p
end

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

-- The shell commands the worktree card offers under `which` ("update" or "cleanup"), one per line; nil when none.
local function commandsOf(b: Block, which: string): string?
	local section = findKey(cardOf(b), which, "section")
	local md: any = if section then findKey(section, "commands", "md") else nil
	return if md then string.match(md.p.text, "^```sh\n(.-)\n```$") else nil
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

-- Saved prompts as kv keeps them: `filters` are the ids of the filters a prompt is offered under, none: every filter;
-- `key` is its shortcut in the queue.
local function promptOf(id: string, name: string, text: string, key: string?): { [string]: any }
	return { id = id, name = name, text = text, key = key }
end

-- Makes `list` the saved prompts.
local function savePrompts(w: World, list: { { [string]: any } })
	w.kv.put("prompts-prs", { version = 1, nextId = #list + 1, items = array(list) })
end

-- The picks the agent flow has asked: "consent" is the two-row question, asked once the worktree is ready, whose first
-- row, Deny, is what ↵ takes; "prompts" is the picker of saved prompts.
local function picksOf(w: World, kind: string): { any }
	local out: { any } = {}
	for _, p in w.window.picks do
		local consent = #p.items == 2 and p.items[2].go == true
		if consent == (kind == "consent") then
			table.insert(out, p)
		end
	end
	return out
end

-- How the user answers an agent run: the picker (`pick`, a row's label) and the question about starting the agent in
-- the worktree (`start`). "Allow" or "Deny"; nil dismisses. `onPick` runs when the picker is answered, so the world
-- changes between listing and choosing.
local function answering(w: World, pick: string?, start: string?, onPick: (() -> ())?)
	w.window.decide = function(opts: any): (string?, boolean?)
		if #opts.items == 2 and opts.items[2].go == true then
			return start, false
		end
		if onPick then
			onPick()
		end
		return pick, false
	end
end

-- Pull request `n` of the scene's repository, at the head the scene's own has.
local function addPr(s: Scene, n: number)
	s.git.served["refs/pull/" .. n .. "/head"] = sha("b")
	s.gh.meta[s.repo .. "#" .. n] = { base = s.repo, sha = sha("b"), ref = "feature", state = "open" }
end

-- The block lists PRs `s.number` to `last` of the scene's repository, the first the newest, as a refresh finds them.
local function listPrs(w: World, s: Scene, b: Block, last: number)
	local items: { { [string]: any } } = {}
	for n = s.number, last do
		table.insert(items, searchItem(n, s.repo, EPOCH - 60 * (n - s.number + 1)))
	end
	s.gh.items.octocat = items
	b.typeText("r")
	w.flush()
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
	has(commandsOf(b, "cleanup") or "", "worktree remove " .. s.target, "the block offers the cleanup commands")
	eq(commandsOf(b, "update"), nil, "and no update commands: the worktree is current")
end)

windowCase("window: Agent lists the saved prompts of the active filter first, runs the pick with {url} replaced in the PR's worktree once allowed, recent first next time", function(w: World)
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
	w.window.choose = { "Allow", "Review" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local items = picksOf(w, "prompts")[1].items
	local labels: { string } = {}
	for _, item in items do
		table.insert(labels, item.label)
	end
	same(labels, { "Type a prompt…", "Review", "Triage" }, "typing, then only the prompts the view lists; one it leaves out and one with no text are not offered")
	eq(items[1].detail, "Send your own text", "typing says what it does")
	eq(items[2].group, "For My PRs", "a prompt of a restricted view has that view's group")
	eq(items[2].detail, "Review {url}", "and its first line as its detail")
	eq(items[3].group, "For My PRs", "so does the next")
	local asked = picksOf(w, "consent")
	eq(#asked, 1, "the one question comes once the worktree is ready")
	eq(asked[1].placeholder, "Start an agent for o/r#5?", "it names the pull request")
	eq(asked[1].items[1].label, "Deny", "the row ↵ takes declines")
	eq(asked[1].items[2].detail, "Runs omp in " .. s.target, "and Allow names the worktree")
	eq(#w.window.agents, 1, "one agent")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5\nthen summarise", "the pick runs with {url} replaced by the PR's link")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	eq(countLog(s.git, "config branch.plotroom/o/r/pr-5.merge refs/pull/5/head"), 1, "its branch tracks the PR's ref, so gh there finds the PR")
	same(w.kv.get("agent-recent"), { "Review" }, "the pick is kept in kv, which outlives a plugin VM reboot")
	w.window.choose = { "Allow" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local again = picksOf(w, "prompts")[2].items
	eq(again[1].label, "Review", "the last pick comes first")
	eq(again[1].group, "Recent", "under Recent")
	eq(#w.window.agents, 1, "a dismissed picker runs nothing")
	w.window.choose = { "Allow", "Triage" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[2].prompt, "Triage https://github.com/o/r/pull/5, then triage https://github.com/o/r/pull/5 again", "every {url} is replaced")
	same(w.kv.get("agent-recent"), { "Triage", "Review" }, "the newest pick leads")
	w.window.choose, w.window.typed = { "Allow", "Type a prompt…" }, "Fix the flaky test in {url}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[3].prompt, "Fix the flaky test in https://github.com/o/r/pull/5", "typed text gets {url} replaced too")
	w.window.choose, w.window.typed = { "Allow", "Type a prompt…" }, "{owner}/{repo}#{number} {title} by {author}: {branch} into {base}, {nope}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[4].prompt, "o/r#5 Add a feature by ann: feature into main, {nope}", "every variable is filled from a fresh read of the PR; an unknown one stays")
end)

windowCase("window: Recent lists only prompts that are still saved, and with none saved the picker says where to write them", function(w: World)
	agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	w.window.choose = { "Allow", "Review" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	w.window.choose = { "Allow", "Triage" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	same(w.kv.get("agent-recent"), { "Triage", "Review" }, "two picks are remembered")
	savePrompts(w, { promptOf("p2", "Triage", "Triage {url}") })
	w.window.choose = nil
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local rows = picksOf(w, "prompts")[3].items
	local labels: { string } = {}
	local groups: { string } = {}
	for _, item in rows do
		table.insert(labels, item.label)
		table.insert(groups, item.group or "")
	end
	same(labels, { "Triage", "Type a prompt…", "Triage" }, "a prompt deleted since is no longer a recent row")
	same(groups, { "Recent", "", "All prompts" }, "the recent one leads, then typing, then the saved prompts")
	savePrompts(w, {})
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local none = picksOf(w, "prompts")[4].items
	eq(#none, 1, "with nothing saved only typing is offered")
	eq(none[1].label, "Type a prompt…", "typing")
	eq(none[1].detail, "Save prompts in Settings › Prompts (s)", "which says where to write prompts")
end)

windowCase("window: saved prompts the host cannot read are reported, and a prompt can still be typed", function(w: World)
	agentScene(w)
	w.kv.put("prompts-prs", "garbage")
	w.window.choose, w.window.typed = { "Allow", "Type a prompt…" }, "Look at {url}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[1].level, "error", "the user is told")
	eq(w.toasts[1].text, "Saved prompts are not listed", "what is missing")
	has(w.toasts[1].sub, "malformed", "and why")
	eq(#picksOf(w, "prompts")[1].items, 1, "the picker still opens")
	eq(w.window.agents[1].prompt, "Look at https://github.com/o/r/pull/5", "to type a prompt")
	eq(w.kv.get("prompts-prs"), "garbage", "and the saved prompts are untouched")
end)

windowCase("window: a card button's run link runs its prompt with every {url} replaced in the PR's worktree once allowed, as the prompt is saved now", function(w: World)
	local s, b = agentScene(w)
	savePrompts(w, {
		promptOf("p1", "Review", "Review {url}\nthen summarise {url}"),
		promptOf("p2", "Triage", "Triage {url}"),
	})
	b.render()
	cardSurface(w, b)
	w.window.choose = { "Allow" }
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "menu", "worktree" }, "the host is asked what the prompt is, then for the worktree")
	eq(requestsSent(w)[1].only, "p1", "and the request for the prompt names it")
	eq(#picksOf(w, "prompts"), 0, "no picker: the button names its prompt")
	local asked = picksOf(w, "consent")
	eq(#asked, 1, "the one question comes once the worktree is ready")
	eq(asked[1].placeholder, "Start an agent for o/r#5?", "it names the pull request")
	eq(asked[1].items[2].detail, "Runs omp in " .. s.target, "and Allow names the worktree")
	eq(#w.window.agents, 1, "Allow starts the agent")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5\nthen summarise https://github.com/o/r/pull/5", "with every {url} replaced by the PR's link")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	savePrompts(w, { promptOf("p1", "Review", "Review quickly: {url}") })
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(w.window.agents[2].prompt, "Review quickly: https://github.com/o/r/pull/5", "a prompt edited since the card was drawn runs as it is saved now")
	w.window.choose = { "Deny" }
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(#w.window.agents, 2, "Deny starts nothing")
	eq(w.toasts[#w.toasts].text, "Agent not started for o/r#5", "and says so")
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
	w.window.choose = { "Allow" }
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
	w.window.choose = { "Allow" }
	-- Saves `list` instead, then clicks the first prompt's button on the card as it was drawn.
	local function gone(what: string, list: { { [string]: any } })
		savePrompts(w, list)
		local asked, said = #picksOf(w, "consent"), #w.toasts
		w.click(runLink("o/r", 5, "p1"))
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		eq(w.toasts[#w.toasts].text, "That prompt is no longer offered here", what .. ": what is wrong")
		eq(#picksOf(w, "consent"), asked, what .. ": nothing is asked")
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
	w.window.choose = { "Allow", "Review" }
	w.command("agent-selected")
	w.flush()
	eq(#picksOf(w, "prompts"), 1, "the picker opens")
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
	w.window.choose, w.window.typed = { "Allow", "Type a prompt…" }, "go"
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

type Way = { what: string, pick: string, start: string? }

windowCase("window: declining the question about the agent leaves the worktree ready and starts nothing, however the prompt was picked", function(w: World)
	local s, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	w.window.typed = "go"
	local ways: { Way } = {
		{ what = "typed prompt", pick = "Type a prompt…", start = "Deny" },
		{ what = "saved prompt", pick = "Review", start = "Deny" },
		{ what = "recent prompt", pick = "Review", start = nil },
	}
	local lastPr = 5 + #ways + 1
	listPrs(w, s, b, lastPr)
	for i, way in ways do
		local n = 5 + i
		addPr(s, n)
		listPr(w, "o/r", n)
		answering(w, way.pick, way.start)
		w.click(prLink("agent", "o/r", n))
		w.flush()
		local target = "/wt/plotroom-o_r-pr-" .. n
		eq(#w.window.agents, 0, way.what .. ": no agent")
		eq(#w.window.runs, 0, way.what .. ": no setup, though the worktree is new")
		showPr(b, n)
		has(cardText(b), target, way.what .. ": the worktree was prepared and noted on the block")
		local told = w.toasts[#w.toasts]
		eq(told.level, "info", way.what .. ": toast level")
		eq(told.text, "Agent not started for o/r#" .. n, way.what .. ": toast")
		has(told.sub, target, way.what .. ": it says where the worktree is")
	end
	eq(picksOf(w, "prompts")[3].items[1].group, "Recent", "the last way was picked from Recent")
	addPr(s, lastPr)
	listPr(w, "o/r", lastPr)
	answering(w, "Type a prompt…", "Allow")
	w.click(prLink("agent", "o/r", lastPr))
	w.flush()
	eq(#w.window.agents, 1, "Allow starts the agent")
	eq(#w.window.runs, 1, "after the setup of its new worktree")
	listPr(w, "o/r", 6)
	w.click(prLink("agent", "o/r", 6))
	w.flush()
	eq(#w.window.agents, 2, "and a pull request whose agent was declined can be tried again")
end)

windowCase("window: an answer that arrives without a window context starts nothing", function(w: World)
	local s, b = agentScene(w)
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
	w.window.decide = function(opts: any): (string?, boolean?)
		if #opts.items == 2 and opts.items[2].go == true then
			return "Allow", string.find(opts.placeholder, "^Start an agent") ~= nil
		end
		return "Type a prompt…", false
	end
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(#w.window.agents + #w.window.runs, 0, "the question about the agent, answered without a context, ended with no agent and no setup")
	has(cardText(b), s.target, "though the worktree it prepared is noted on the block")
	eq(#w.toasts, 1, "and nothing is said but that it was being prepared")
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
	has(cardText(b), "plotroom/github/%2Egithub/pr-1", "the branch is encoded")
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
	local nodes: { any } = { { id = "main.rpc", p = { text = "8", hidden = true } } }
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

-- ---- host.luau: the `prs` block, driven through the def it registers with tern.block.define

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

-- The block of `pane` launched in /work/r, after its repository lookup and first search.
local function openQueue(w: World, pane: number?): Block
	local b = w.open(pane or 1, { "/work/r" })
	w.flush()
	return b
end

-- Forgets every saved checkout: opening the queue in /work/r saves that one.
local function forgetCheckouts(w: World)
	local store: any = w.kv.store
	store.checkouts = nil
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

-- Opens Settings on `page` with its first row focused.
local function goToSettings(b: Block, page: string, issues: boolean?)
	b.typeText("s")
	local pages = if issues then { "views", "prompts", "repos", "jira", "connection" } else { "views", "prompts", "repos", "connection" }
	local turns = (table.find(pages, page) or 1) - 1
	for _ = 1, turns do
		b.press("tab")
	end
	b.press("down")
end

-- Expands the view or prompt whose summary row is `row` ("vopen:<id>" / "popen:<id>"), as its Edit button does.
local function expand(b: Block, row: string)
	b.event({ ev = "action", id = "layer.settings", act = "expand", value = row })
end

-- The lowercased key labels of a shortcut list overlay found under `node`.
local function helpKeys(node: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local list: any = findKey(node, "keys")
	if list == nil then
		return out
	end
	for _, item in list.p.items do
		for _, cap in item.k do
			local label: any = if type(cap) == "table" then cap.t else cap
			if type(label) == "string" and label ~= " " then
				out[string.lower(label)] = true
			end
		end
	end
	return out
end

-- The rows of a shortcut list overlay found under `node`: each one's key labels, joined by a space, and what it does.
local function helpRows(node: any): { { keys: string, text: string } }
	local out: { { keys: string, text: string } } = {}
	local list: any = findKey(node, "keys")
	if list == nil then
		return out
	end
	for _, item in list.p.items do
		local labels: { string } = {}
		for _, cap in item.k do
			local label: any = if type(cap) == "table" then cap.t else cap
			if type(label) == "string" and label ~= " " then
				table.insert(labels, label)
			end
		end
		table.insert(out, { keys = table.concat(labels, " "), text = item.v })
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
	eq(pickerOf(b).selected, "no_2fr_231", "the first PR is selected")
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
	local b = openQueue(w)
	b.typeText("/")
	eq(pickerOf(b).query, "", "the search opens empty")
	b.typeText("2")
	same(listed(b), { "no_2fr_232" }, "the search narrows the list")
	eq(pickerOf(b).selected, "no_2fr_232", "and the selection follows")
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

case("host: ? lists the shortcuts of the current mode, and a ? is plain text while searching", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("?")
	local queueKeys = helpKeys(b.view().layer)
	for _, key in { "↑", "↓", "enter", "w", "/", "tab", "r", "s", "?" } do
		yes(queueKeys[key], "the queue list shows " .. key)
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
	eq(pickerOf(b).scope, "v2", "Down in the filter list switches view")
	b.typeText("s")
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "s opens Settings")
	eq(pickerNode(b).k, "picker", "as a sheet over the queue")
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
	eq(prefsOf(b).focus, "vopen:v1", "the first view is a one-row summary")
	expand(b, "vopen:v1")
	eq(prefsOf(b).focus, "name:v1", "the first row is focused")
	b.press("enter")
	eq(prefsOf(b).editing.row, "name:v1", "Enter starts the edit")
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
	b.press("down")
	b.press("enter")
	for _ = 1, 18 do
		b.press("backspace")
	end
	b.press("enter")
	eq(rowIn(b, "query:v1").warning, "A query is required.", "the rejected query is explained under its row")
	eq(prefsOf(b).editing.row, "query:v1", "the edit stays open for a correction")
	eq(prefsOf(b).editing.draft, "", "with the draft")
	eq(w.kv.get("views-prs").items[1].query, "is:open author:@me", "nothing was saved")
	eq(#requestsOf(s.gh, "search"), 1, "and nothing was searched")
	b.typeText("is:open label:bug")
	b.press("enter")
	eq(rowIn(b, "query:v1").warning, nil, "a saved value clears the warning")
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
	expand(b, "vopen:v1")
	w.kv.failSet["views-prs"] = "read-only file system"
	b.press("enter")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "Enter on unchanged text only closes the edit")
	eq(rowIn(b, "name:v1").warning, nil, "without a write, so without a warning")
	b.press("enter")
	b.typeText("2")
	b.press("enter")
	has(rowIn(b, "name:v1").warning, "read-only file system", "a failed write is explained under its row")
	eq(prefsOf(b).editing.draft, "My PRs2", "the draft is kept for another try")
	eq(w.kv.get("views-prs").items[1].name, "My PRs", "nothing was written")
	w.kv.failSet["views-prs"] = nil
	b.press("enter")
	eq(rowIn(b, "name:v1").warning, nil, "the retry saved it and cleared the warning")
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
	expand(b, "vopen:v1")
	has(rowIn(b, "name:v1").disabled, "disk offline", "the rows are locked, with the cause")
	has(rowIn(b, "query:v1").disabled, "disk offline", "and so is every other row of the form")
	same(w.kv.get("views-prs"), saved, "the saved views were not overwritten")
	w.kv.failGet["views-prs"] = nil
	w.kv.put("views-prs", { version = 2 })
	local other = openQueue(w, 2)
	same(listed(other), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "malformed views show the defaults too")
	same(w.kv.get("views-prs"), { version = 2 }, "and are not overwritten either")
end)

case("host: a first run saves the two default views, Add creates one, and Delete asks first", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	eq(#w.kv.get("views-prs").items, 2, "the default views were saved")
	same({ w.kv.get("views-prs").items[1].name, w.kv.get("views-prs").items[2].name }, { "My PRs", "Review requested" }, "the pull request seeds")
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "add" })
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "Add saved a new view")
	eq(prefsOf(b).editing.row, "name:v3", "and starts naming it")
	b.press("escape")
	eq(w.kv.get("views-prs").items[3].name, "New view", "cancelling the naming keeps the placeholder name")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "the new view became the active one and was searched")
	has(b.title(), "New view", "the title shows it")
	expand(b, "vopen:v2")
	b.event({ ev = "select", id = "layer.settings", item = "delete:v2" })
	b.press("enter")
	yes(findKey(b.view().layer, "confirm") ~= nil, "Delete asks for confirmation")
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "Enter keeps the view")
	eq(findKey(b.view().layer, "confirm"), nil, "and closes the question")
	b.press("enter")
	b.typeText("d")
	local items = w.kv.get("views-prs").items
	eq(#items, 2, "d deletes it")
	eq(items[2].id, "v3", "the other views stay")
	expand(b, "vopen:v3")
	b.event({ ev = "select", id = "layer.settings", item = "delete:v3" })
	b.press("enter")
	b.typeText("d")
	w.flush()
	eq(#w.kv.get("views-prs").items, 1, "the active view can be deleted too")
	has(b.title(), "My PRs", "the view that took its place is shown")
end)

case("host: Tab cycles the Settings pages in order, Views, Prompts, Repositories, Connection, and Shift+Tab goes back", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("s")
	local pages: { string } = { prefsOf(b).page }
	for _ = 1, 4 do
		b.press("tab")
		table.insert(pages, prefsOf(b).page)
	end
	same(pages, { "views", "prompts", "repos", "connection", "views" }, "Tab walks the pages and wraps around")
	b.press("tab", "s")
	eq(prefsOf(b).page, "connection", "Shift+Tab goes back, wrapping the other way")
end)

case("host: switching a view's integration resets its query, login and group", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", query = "is:open label:x", logins = array({ "work" }), group = "repo", prompts = array({}) } }) })
	local b = w.open(1, { "/work/r" }, nil, "issues")
	w.flush()
	goToSettings(b, "views", true)
	b.event({ ev = "change", id = "layer.settings", item = "vint:v1", value = array({ "jira" }) })
	local saved: any = w.kv.get("views-issues").items[1]
	eq(saved.integration, "jira", "the integration changed")
	eq(saved.query, "assignee = currentUser() AND statusCategory != Done", "to the new integration's starting query")
	same(saved.logins, array({}), "the GitHub logins are gone")
	eq(saved.group, "none", "and the grouping starts over")
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
	local b = openQueue(w)
	goToSettings(b, "prompts")
	eq(prefsOf(b).focus, "padd", "with nothing saved the Add row is the first")
	b.press("enter")
	same(w.kv.get("prompts-prs"), { version = 1, nextId = 2, items = array({ promptOf("p1", "New prompt", "") }) }, "Add saves a prompt with no text at once, offered under every view")
	eq(prefsOf(b).editing.row, "pname:p1", "and starts naming it")
	eq(prefsOf(b).editing.draft, "", "from an empty draft")
	eq(editorCard(b), nil, "the text editor waits for the name")
	eq(caretOf(w), nil, "and the caret has not been moved")
	b.press("enter")
	eq(rowIn(b, "pname:p1").warning, "A name is required.", "an empty name is refused under its row")
	eq(prefsOf(b).editing.row, "pname:p1", "and the name edit stays open")
	eq(w.kv.get("prompts-prs").items[1].name, "New prompt", "with nothing saved")
	b.typeText("Review")
	b.press("enter")
	eq(w.kv.get("prompts-prs").items[1].name, "Review", "Enter saves the name")
	eq(prefsOf(b).editing, nil, "the name edit is over")
	yes(editorCard(b) ~= nil, "and a prompt with no text opens its text editor next")
	eq(editorCard(b).p.role, "omp.prefs.editor", "in the editor card")
	eq(findKey(editorCard(b), "head", "text").p.spans[1].t, "Prompt · Review", "which names the prompt")
	eq(draftOf(b), "", "with nothing in it")
	eq(caretOf(w), "layer.settings.prompt.draft", "and the caret in its field")
	eq(prefsOf(b).focus, "ptext:p1", "the prompt's text row is the focused one")
	eq(rowIn(b, "ptext:p1").hint, "Empty", "and says it is empty")
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
	eq(rowIn(b, "ptext:p1").hint, "Review {url}", "the row shows the text's first line")
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
	local b = openQueue(w)
	goToSettings(b, "prompts")
	b.press("enter")
	b.typeText("New prompt")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "the name edit is over")
	eq(w.kv.get("prompts-prs").items[1].name, "New prompt", "the name stays what it was")
	yes(editorCard(b) ~= nil, "and the prompt, still with no text, opens its text editor")
	eq(caretOf(w), "layer.settings.prompt.draft", "with the caret in its field")
end)

case("host: a prompt's text that is empty or over 8000 bytes stays in the editor with the card's warning; Save and Cancel act like ⌘Enter and Esc", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:p1")
	b.press("down")
	eq(prefsOf(b).focus, "ptext:p1", "the prompt's text row")
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
	expand(b, "vopen:v1")
	b.event({ ev = "select", id = "layer.settings", item = "vprompts:v1" })
	eq(prefsOf(b).focus, "vprompts:v1", "the view's Prompts row")
	local chips: any = rowIn(b, "vprompts:v1").control
	same(chips.values, array({}), "a view that lists none offers every prompt")
	eq(#chips.options, 2, "among all the prompts")
	eq(chips.options[2].value, "p2", "by id")
	eq(chips.options[2].label, "Triage", "and name")
	local function saved(): any
		return w.kv.get("views-prs").items[1].prompts
	end
	local function changed(values: { any })
		b.event({ ev = "change", id = "layer.settings", item = "vprompts:v1", value = array(values) })
	end
	changed({ "p2", "gone" })
	same(saved(), { "p2" }, "a change saves only the prompts that still exist")
	same(rowIn(b, "vprompts:v1").control.values, { "p2" }, "and the row shows them")
	changed({ "p2", "p1" })
	same(saved(), { "p1", "p2" }, "in the prompts' order")
	changed({ "gone" })
	same(saved(), array({}), "none left means every prompt")
	b.press("enter")
	eq(prefsOf(b).editing.row, "vprompts:v1", "Enter starts picking: the chips take the keys")
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
	eq(prefsOf(b).focus, "delete:v1", "and does what it does")
	same(saved(), { "p1" }, "without changing the prompts")
end)

case("host: Delete on a prompt asks first, naming it: d deletes it, Enter keeps it", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:p1")
	b.event({ ev = "select", id = "layer.settings", item = "pdelete:p1" })
	b.press("enter")
	local question: any = findKey(b.view().layer, "confirm")
	yes(question ~= nil, "Delete asks for confirmation")
	eq(question.p.head, "Delete prompt “Review”?", "naming the prompt")
	b.press("enter")
	eq(#w.kv.get("prompts-prs").items, 2, "Enter keeps it")
	eq(findKey(b.view().layer, "confirm"), nil, "and closes the question")
	b.press("enter")
	b.typeText("d")
	local items = w.kv.get("prompts-prs").items
	eq(#items, 1, "d deletes it")
	eq(items[1].id, "p2", "the other prompt stays")
	eq(prefsOf(b).focus, "padd", "and the Add row takes the focus")
	b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:p2" })
	eq(findKey(b.view().layer, "confirm").p.head, "Delete prompt “Triage”?", "the Delete button asks the same question")
	b.event({ ev = "action", id = "layer.confirm.buttons.delete", act = "confirm-delete" })
	eq(#w.kv.get("prompts-prs").items, 0, "and the Delete in the question deletes it")
end)

case("host: changing page or closing Settings drops an open text edit and gives the caret back", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	-- Opens Settings on the Prompts page with the prompt's text being edited.
	local function editing()
		goToSettings(b, "prompts")
		expand(b, "popen:p1")
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
		b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:" .. id })
		b.event({ ev = "action", id = "layer.confirm.buttons.delete", act = "confirm-delete" })
	end
	expand(b, "popen:p2")
	b.event({ ev = "select", id = "layer.settings", item = "ptext:p2" })
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
	expand(b, "popen:p3")
	b.event({ ev = "select", id = "layer.settings", item = "pname:p3" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "pname:p3", "the name of another prompt is being edited")
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
		has(rowIn(b, "padd").disabled, why, what .. ": Add is locked, with the reason")
		b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd" })
		b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:p1" })
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
	eq(rowIn(b, "padd").disabled, nil, "a readable store unlocks Add")
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
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "For My PRs", send = "Look at {url}\nTwice" },
	}, "a view that lists a prompt offers only it, in the group For the view")
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "v2", "the second view is active")
	same(menu().items, {
		{ id = "p1", label = "Mine", detail = "Review {url}", group = "All prompts", send = "Review {url}" },
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "All prompts", send = "Look at {url}\nTwice" },
	}, "a view that lists none offers every prompt with text, as All prompts")
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
	same(only("p1"), { { id = "p1", label = "Mine", detail = "Review {url}", group = "For My PRs", send = "Review {url}" } }, "just the prompt asked for, in the group it has under the view")
	eq(#only("p2"), 0, "none that the view does not list")
	eq(#only("p4"), 0, "none with no text")
	eq(#only("p9"), 0, "none that is not saved")
end)

case("host: the picker's action bar has Settings and Refresh on the left, then the PR's Worktree, Go to tab and one button per offered prompt by Open; each opens the link the card keeps unseen", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", "m"),
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
	same(bar(), { "settings", "retry", "worktree", "prompt-p1", "prompt-p2", "open" }, "under My PRs the prompts it lists; none for a prompt it does not list, a blank one or one whose id is no link; Open last")
	eq(action("open").primary, true, "Open is the primary button")
	eq(action("open").keys, nil, "with no keycap")
	eq(action("settings")["end"], nil, "Settings and Refresh sit on the left")
	eq(action("retry")["end"], nil, "both of them")
	eq(action("worktree")["end"], true, "the PR's buttons sit on the right, by Open")
	eq(action("prompt-p1")["end"], true, "prompts too")
	eq(action("prompt-p1").label, "Mine", "a button is named for its prompt")
	same(action("prompt-p1").keys, { "m" }, "and shows its shortcut")
	eq(action("prompt-p2").keys, nil, "a prompt with no shortcut shows none")
	eq(findKey(pickerNode(b), "buttons").p.hidden, true, "the links sit in an unseen node")
	eq(link("prompt-p1"), "plotroom://github/run/o/r/1/p1", "each button's link runs its prompt on the selected pull request")
	eq(link("agent"), "plotroom://github/agent/o/r/1", "with the Agent link for the a key and the palette command")
	b.event({ ev = "action", id = "layer.queue", act = "prompt-p1" })
	eq(w.opened[#w.opened], "plotroom://github/run/o/r/1/p1", "a click opens the button's link")
	b.event({ ev = "action", id = "layer.queue", act = "worktree" })
	eq(w.opened[#w.opened], "plotroom://github/worktree/o/r/1", "Worktree's too")
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-pr-1" })
	b.render()
	same(bar(), { "settings", "retry", "worktree", "goto", "prompt-p1", "prompt-p2", "open" }, "a tab in the pull request's worktree adds Go to tab before the prompts")
	eq(link("goto"), "plotroom://github/goto/o/r/1", "with its link")
	table.remove(w.panes)
	b.press("tab")
	b.press("down")
	w.flush()
	same(bar(), { "settings", "retry", "worktree", "prompt-p3", "open" }, "under Review requested the prompt buttons swap")
	savePrompts(w, { promptOf("p4", "Blank", "", "b") })
	b.render()
	same(bar(), { "settings", "retry", "worktree", "open" }, "with none offered the bar has no prompt button")
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
		promptOf("p1", "Mine", "Review {url}", "m"),
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
	eq(b.press("m", nil, "m"), true, "the key is handled")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p1"), "and opens its prompt's run link for the selected pull request")
	eq(b.press("t", "s", "T"), true, "shift is allowed")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p2"), "a capital is a key of its own")
	b.press("down")
	b.typeText("m")
	eq(w.opened[#w.opened], runLink("o/r", 2, "p1"), "the link follows the selection")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 2), "a key the queue uses itself stays the queue's, whatever a prompt says")
	opened = #w.opened
	ignored("a key no prompt has", "z")
	ignored("a prompt of another view", "x")
	ignored("ctrl", "m", "c")
	ignored("alt", "m", "a")
	ignored("meta", "m", "m")
	b.typeText("/")
	b.typeText("m")
	eq(pickerOf(b).query, "m", "while searching the key is text")
	eq(#w.opened, opened, "and opens nothing")
	b.press("escape")
	b.press("escape")
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "v2", "under the second view")
	ignored("a prompt of the first view", "m")
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

case("host: a prompt's shortcut is one free key: the row refuses what the queue uses or another prompt has, and clearing it removes the key", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}", "t") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:p1")
	local ids: { string } = {}
	for _, row in prefsOf(b).sections[1].rows do
		table.insert(ids, row.id)
	end
	same(ids, { "pname:p1", "ptext:p1", "pkey:p1", "pdelete:p1", "pclose:p1" }, "a prompt has its name, text, shortcut, Delete and Done, in that order")
	local row = rowIn(b, "pkey:p1")
	eq(row.label, "Shortcut", "the row is the Shortcut")
	eq(row.control.value, "", "empty while the prompt has none")
	eq(row.control.placeholder, "None", "which it says")
	b.event({ ev = "select", id = "layer.settings", item = "pkey:p1" })
	-- Tries `text` as the first prompt's shortcut: what the row warns afterwards.
	local function try(text: string): string?
		if prefsOf(b).editing == nil then
			b.press("enter")
		end
		b.press("a", "c")
		b.press("backspace")
		b.typeText(text)
		b.press("enter")
		return rowIn(b, "pkey:p1").warning
	end
	local one = "One key: a single letter, digit or symbol."
	eq(try("ab"), one, "two characters are refused")
	eq(prefsOf(b).editing.draft, "ab", "the draft stays for a correction")
	eq(try("a b"), one, "so is a gap between them")
	eq(try("éa"), one, "whatever their bytes")
	for _, k in { "j", "k", "w", "g", "a", "/", "?", "r", "s" } do
		eq(try(k), "The queue already uses " .. k .. ".", "the queue's own " .. k .. " is refused")
	end
	eq(try("t"), "Already the shortcut of Triage.", "another prompt's key is refused")
	eq(w.kv.get("prompts-prs").items[1].key, nil, "nothing was saved")
	eq(try("m"), nil, "a free key is accepted")
	eq(prefsOf(b).editing, nil, "and closes the edit")
	same(w.kv.get("prompts-prs").items[1], { id = "p1", name = "Review", text = "Review {url}", key = "m" }, "it is saved as the prompt's key, the rest as it was")
	eq(w.kv.get("prompts-prs").items[2].key, "t", "another prompt keeps its key")
	eq(rowIn(b, "pkey:p1").control.value, "m", "the row shows it")
	eq(try("A"), nil, "a capital is not the queue's a")
	eq(w.kv.get("prompts-prs").items[1].key, "A", "and is saved as typed")
	eq(try("é"), nil, "one character is one key, whatever its bytes")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and is saved")
	eq(try(""), nil, "an empty shortcut is accepted")
	eq(w.kv.get("prompts-prs").items[1].key, nil, "and removes the key")
	eq(rowIn(b, "pkey:p1").control.value, "", "which the row shows")
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
			if string.find(row.text, "Run the prompt", 1, true) then
				table.insert(out, row)
			end
		end
		return out
	end
	b.typeText("?")
	same(promptRows(), {
		{ keys = "m", text = "Run the prompt “Mine” on the selected pull request" },
		{ keys = "T", text = "Run the prompt “Anywhere” on the selected pull request" },
	}, "each prompt offered under My PRs that has a key, in the menu's order; none without a key, with no text or for another view")
	b.press("escape")
	b.press("tab")
	b.press("down")
	w.flush()
	b.typeText("?")
	same(promptRows(), {
		{ keys = "x", text = "Run the prompt “Theirs” on the selected pull request" },
		{ keys = "T", text = "Run the prompt “Anywhere” on the selected pull request" },
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
	b.press("tab")
	eq(prefsOf(b).page, "connection", "the user moved on while gh was cloning")
	w.advance(5000)
	eq(#w.toasts, 1, "the refusal is reported once")
	eq(w.toasts[1].level, "error", "as an error")
	eq(w.toasts[1].text, "Checkout not saved", "that says what happened")
	has(w.toasts[1].sub, "not an empty directory", "with gh's reason")
	eq(prefsOf(b).page, "connection", "the page the user is on is left alone")
	for _ = 1, 3 do -- Views, Prompts, Repositories
		b.press("tab")
	end
	eq(prefsOf(b).page, "repos", "back on the Repositories page")
	submit()
	b.press("escape")
	w.advance(5000)
	eq(#w.toasts, 2, "closing Settings meanwhile reports it as well")
	eq(w.toasts[2].text, "Checkout not saved", "with the same toast")
	goToSettings(b, "repos")
	submit()
	for _ = 1, 4 do
		b.press("tab")
	end
	eq(prefsOf(b).page, "repos", "a user who is back on the page before gh answers")
	w.advance(5000)
	has(rowIn(b, "checkout:o/r").warning, "not an empty directory", "sees the refusal under its row")
	eq(prefsOf(b).editing.draft, "/elsewhere", "with the draft")
	eq(#w.toasts, 2, "and no extra toast")
	eq(w.kv.get("checkouts")["o/r"], "", "nothing was ever saved")
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
	scope("v2")
	w.flush()
	same(listed(b), { "no_2fr_2321", "no_2fr_2322" }, "the second view shows its own results")
	eq(#requestsOf(s.gh, "search"), 2, "it was searched")
	scope("v1")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "going back shows the cached list at once")
	scope("v1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "a fresh cached list and re-selecting the active view cost nothing")
	slow = true
	second = { searchItem(23, "o/r", EPOCH - 5) }
	b.typeText("r")
	scope("v2")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 4, "the switch sent its own search while the slow one is still pending")
	same(listed(b), { "no_2fr_2323" }, "the switch showed the new answer without waiting for the slow search")
	w.advance(5000)
	same(listed(b), { "no_2fr_2323" }, "and the superseded answer never replaces it")
	eq(pickerOf(b).scope, "v2", "the second view is still the one shown")
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
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "v2" })
	w.flush()
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "another view loads")
	eq(pickerOf(b).state, "ready", "without the first view's card")
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "v1" })
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
	expand(a, "vopen:v1")
	a.press("enter")
	a.press("a", "c")
	a.typeText("Mine")
	a.press("enter")
	has(c.title(), "Mine", "the other block shows the new name")
	eq(#requestsOf(s.gh, "search"), 2, "a rename needs no new search")
	a.press("down")
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

case("host: saving a view's login reaches every block: the old account's data goes and nothing runs as it", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30), searchItem(8, "o/r", EPOCH - 90) }
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	w.flush()
	same(listed(a), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the active gh account's PRs")
	local before = #s.gh.requests
	goToSettings(a, "views")
	expand(a, "vopen:v1")
	a.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({ "work" }) })
	same(w.kv.get("views-prs").items[1].logins, { "work" }, "the login was saved on the view")
	same(w.kv.get("views-prs").items[2].logins, array({}), "and on no other")
	eq(w.kv.get("views-prs").items[1].login, nil, "and not under the old key")
	a.press("escape")
	w.flush()
	same(listed(a), { "no_2fr_237", "no_2fr_238" }, "this block shows the new account's PRs")
	same(listed(c), { "no_2fr_237", "no_2fr_238" }, "and so does the other one")
	for i = before + 1, #s.gh.requests do
		eq(s.gh.requests[i].login, "work", "request " .. i .. " ran as the new account")
	end
	eq(#requestsOf(s.gh, "search"), 4, "each block searched once more")
	before = #s.gh.requests
	goToSettings(a, "views")
	expand(a, "vopen:v1")
	a.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({}) })
	a.press("escape")
	w.flush()
	same(w.kv.get("views-prs").items[1].logins, array({}), "clearing the logins empties the view's list")
	same(listed(a), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "this block is back on the active gh account")
	same(listed(c), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and so is the other one")
	for i = before + 1, #s.gh.requests do
		eq(s.gh.requests[i].login, "octocat", "request " .. i .. " ran as the active account")
	end
end)

case("host: a search still running for the old account never shows after the account changed", function(w: World)
	local s = hostScene(w, 3)
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
	goToSettings(b, "views")
	expand(b, "vopen:v1")
	b.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({ "work" }) })
	b.press("escape")
	w.flush()
	same(listed(b), { "no_2fr_237" }, "the new account's list is shown")
	w.advance(5000)
	same(listed(b), { "no_2fr_237" }, "the old account's late answer is dropped")
	eq(#requestsOf(s.gh, "search"), 2, "one search per account")
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
	goToSettings(b, "views")
	expand(b, "vopen:v1")
	b.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({ "work" }) })
	b.press("escape")
	w.flush()
	w.advance(300)
	local sent = requestsOf(s.gh, "checks")
	eq(#sent, 2, "the new account asked for its own")
	eq(sent[2].login, "work", "as itself")
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

case("host: a worktree request becomes a badge and a card that shows its commands, and nothing is ever run", function(w: World)
	local s = hostScene(w, 2)
	for n = 1, 2 do
		s.git.served["refs/pull/" .. n .. "/head"] = sha("b")
		s.gh.meta["o/r#" .. n] = { base = "o/r", sha = sha("b"), ref = "feature", state = "open" }
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
	eq(commandsOf(b, "cleanup"), "git -C /work/r worktree remove " .. target .. "\ngit -C /work/r branch -d plotroom/o/r/pr-1\ngit -C /work/r update-ref -d refs/plotroom-pr/o/r/pr-1", "the cleanup commands, one per line, in a shell block Tern copies")
	eq(commandsOf(b, "update"), "git -C " .. target .. " fetch origin refs/pull/1/head\ngit -C " .. target .. " merge --ff-only FETCH_HEAD", "the update commands too")
	eq(#w.calls, ran, "showing them ran nothing")
	s.gh.meta["o/r#1"].sha = sha("b")
	ask(1)
	eq(badgeOf(b).tone, "success", "caught up with its PR, the worktree is a success again")
	eq(commandsOf(b, "update"), nil, "no update commands to show")
	s.gh.meta["o/r#1"] = nil
	yes(type(ask(1).problem) == "string", "a PR that cannot be read is answered with the reason")
	eq(badgeOf(b), nil, "a failed attempt shows no badge")
	eq(cardOf(b).p.tone, "error", "but an error card")
	eq(commandsOf(b, "cleanup"), nil, "with no commands to run")
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

case("host: a malformed request from a window gets no answer and starts nothing", function(w: World)
	hostScene(w, 2)
	local b = openQueue(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, value: any)
		b.event({ ev = "action", act = "rpc", value = value })
		w.flush()
		eq(#b.view().main.c, 1, what .. ": no answer is kept")
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.toasts, 0, what .. ": or said")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	ignored("a value that is not text", 42)
	ignored("text that is not JSON", "{not json")
	ignored("JSON that is not an object", "[1,2]")
	ignored("a request too big", jsonEncode({ id = "a1", op = "menu", pad = string.rep("x", 17000) }))
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
	same(answerOf(b, "m1").items, { { id = "p1", label = "Review", detail = "Review {url}", group = "All prompts", send = "Review {url}\nthen report" } }, "a well-formed request is answered with the saved prompts")
	eq(w.opened[#w.opened], "plotroom://rpc/m1", "and announced")
end)

windowCase("window: an agent run notes its worktree on the block as the Worktree key does, and the card replaces the failure before it", function(w: World)
	local s, b = agentScene(w)
	w.window.typed = "go"
	answering(w, "Type a prompt…", "Allow")
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
	eq(commandsOf(b, "cleanup"), "git -C /work/r worktree remove /wt/plotroom-o_r-pr-5\ngit -C /work/r branch -d plotroom/o/r/pr-5\ngit -C /work/r update-ref -d refs/plotroom-pr/o/r/pr-5", "the cleanup commands are the real ones, for the user to run")
	s.gh.meta["o/r#5"].sha = sha("c")
	s.git.served["refs/pull/5/head"] = sha("c")
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(badgeOf(b).tone, "warning", "a reused worktree behind its pull request is flagged")
	eq(commandsOf(b, "update"), "git -C /wt/plotroom-o_r-pr-5 fetch origin refs/pull/5/head\ngit -C /wt/plotroom-o_r-pr-5 merge --ff-only FETCH_HEAD", "with the commands that bring it up to date")
	w.cx.agents.start = function(_self: any, _opts: any): number
		error("no agent program", 0)
	end
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[#w.toasts].text, "Could not start an agent for o/r#5", "an agent that cannot start is toasted")
	has(cardText(b), s.target, "and the worktree's card is still on screen")
end)

-- ---------------------------------------------------------------- the issues block
-- plugin.plotroom.issues runs the engine of the PR queue (host.luau) on tracker-neutral issues (tracker.luau): its own
-- filters, prompts and branch formats in kv, an issue sidebar, and worktrees on a branch named after the issue.

-- A checkout of o/r at /work/r whose origin is github.com/o/r and whose remote serves its default branch at sha("b"),
-- with three issues for the active gh account, the newest first: #12 "Fix login" (labels bug and ui, assigned to ann and
-- bob), #13 closed as not planned and #14 closed as completed.
local function issueHost(w: World): HostScene
	w.load("host")
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	g.served["HEAD"] = sha("b")
	local gh = newGh(w)
	gh.issueItems.octocat = {
		issueItem(12, "o/r", EPOCH - 60, { title = "Fix login", labels = array({ "bug", "ui" }), assignees = array({ "ann", "bob" }), comments = 3 }),
		issueItem(13, "o/r", EPOCH - 120, { title = "Add dark mode", state = "CLOSED", reason = "NOT_PLANNED" }),
		issueItem(14, "o/r", EPOCH - 180, { title = "Docs typo", author = "ann", state = "CLOSED", reason = "COMPLETED" }),
	}
	return { git = g, gh = gh }
end

-- The issues block of `pane` launched in /work/r, after its repository lookup and first search.
local function openIssues(w: World, pane: number?): Block
	local b = w.open(pane or 1, { "/work/r" }, nil, "issues")
	w.flush()
	return b
end

-- A window whose pane 1 is the issues block of `issueHost`, linked: the window's requests reach its host half, which
-- runs git and omp, and the answers come back. The window reads the links the block's own view keeps unseen.
local function issueWindow(w: World): (HostScene, Block)
	local s = issueHost(w)
	w.load("window")
	w.window.panes[1].block = "plugin.plotroom.issues"
	local b = openIssues(w)
	w.link(b)
	cardSurface(w, b)
	return s, b
end

-- The Jira side of the issues block: project ABC checked out at /work/r (its origin is on GitLab: a Jira project names
-- no repository) whose remote serves its default branch at sha("b"). acli is signed in to acme.atlassian.net and finds
-- under "Assigned to me" ABC-12 "Fix login" (In Progress, a High-priority Bug of Bob Ray, labelled ui) and ABC-13 "Old
-- bug" (Done), in that order. There is no gh: a Jira block must never ask for it.
type JiraScene = { git: Git, acli: Acli, gh: Gh }
local JIRA_ASSIGNED = "(assignee = currentUser() AND statusCategory != Done) ORDER BY priority DESC, updated DESC"

local function jiraHost(w: World): JiraScene
	w.load("host")
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	g.served["HEAD"] = sha("b")
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

-- The issues block of `pane` restored on Jira project ABC, after its first search.
local function openJira(w: World, pane: number?): Block
	local b = w.open(pane or 1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeViewId = "v1" }, "issues")
	w.flush()
	return b
end

local function issueLink(kind: string, repo: string, ref: string): string
	return "plotroom://issue/" .. kind .. "/" .. repo .. "/" .. ref
end

-- The link of the card's button that runs saved prompt `id` on issue `repo`#`ref`.
local function issueRunLink(repo: string, ref: string, id: string): string
	return issueLink("run", repo, ref) .. "/" .. id
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

case("host: the issues block lists issues under its own seeded filters", function(w: World)
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
	eq(w.kv.get("views-prs"), nil, "and leaves the PR views alone")
	local searches = requestsOf(s.gh, "issue-search")
	eq(#searches, 1, "one request covers three issues")
	eq(searches[1].fields.q, "is:open assignee:@me is:issue sort:updated-desc", "the active view's query across every repository, issues only")
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "newest update first")
	eq(pickerOf(b).selected, "no_2fr_2312", "the first issue is selected")
	eq(pickerOf(b).state, "ready", "the list is ready")
	eq(b.title(), "Plotroom · Assigned to me (3)", "the title names the filter and counts the issues")
	eq(pickerOf(b).noun, "issues", "the picker counts issues")
	eq(pickerOf(b).placeholder, "Filter the loaded issues", "and filters them")
	yes(pickerOf(b).icon ~= "merge", "with an icon of its own")
	local sidebar: { string } = {}
	for _, scope in pickerOf(b).scopes do
		table.insert(sidebar, scope.group .. ": " .. scope.label)
	end
	same(sidebar, { "GitHub - octocat: Assigned to me", "GitHub - octocat: Created by me", "Jira: Assigned to me", "Jira: Created by me" }, "the view list shows each integration's views under its own group")
	eq(pickerOf(b).scopes[1].count, 3, "the loaded one with its count")
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
		lacks(row.text, "pull request", "no shortcut speaks of pull requests: " .. row.keys)
	end
	eq(byKeys.w, "Create or reuse the selected issue's worktree on its own branch and open it in a new tab (Plotroom asks for the repository, and its checkout, the first time)", "w makes the issue's worktree")
	eq(byKeys.a, "Pick a saved prompt, or type one, and run it on the selected issue (typed prompts run in its worktree)", "a runs a prompt on the issue")
	b.press("escape")
	-- the second filter searches its own query
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "v2", "the second view is active")
	eq(requestsOf(s.gh, "issue-search")[2].fields.q, "is:open author:@me is:issue sort:updated-desc", "and searched")
	has(b.title(), "Created by me", "the title follows")
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
			table.insert(out, badge.text .. "/" .. (badge.tone or "-"))
		end
		return table.concat(out, " ")
	end
	eq(row(1).id, "no_2fr_2312", "the id is n and the issue's reference")
	eq(row(1).label, "Fix login", "the title is the label")
	eq(detailText(row(1)), "#12 · o/r · @octo opened 1m ago", "the number, the repository, the author and the age")
	eq(detailText(row(3)), "#14 · o/r · @octo opened 3m ago", "a lone assignee is not in the detail")
	eq(detailText(row(2)), "#13 · o/r · @octo opened 2m ago", "nor is the lack of one")
	eq(row(1).mark.text, "octo", "the author's mark")
	eq(row(1).facts.comments, "3", "the comment count")
	eq(row(2).facts.comments, nil, "none without comments")
	eq(row(1).facts.assignee, nil, "the row shows no assignee, with or without one")
	eq(row(3).facts.assignee, nil, "not even a lone one")
	same(pickerOf(b).columns, { { id = "comments", format = "text", priority = 50 } }, "the comment count is the only column")
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
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-14/src" })
	b.render()
	eq(badges(3), "GitHub/muted In tab/accent Not planned/muted", "a tab working in the issue's worktree marks its row, after the integration and before its state")
	eq(badges(1), "GitHub/muted bug/- ui/-", "and no other row")
end)

case("host: the issue preview shows its body, assignees, milestone, linked pull requests and the branch it would create", function(w: World)
	local s = issueHost(w)
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
	eq(findKey(branch, "v").p.spans[1].t, "12-fix-login", "the branch Worktree would make: the issue's key and its title's slug")
	eq(findKey(branch, "copy", "icon").p.href, "12-fix-login", "with a copy icon")
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

case("host: a PR block told to show a pull request selects it where its view lists it, else looks it up alone in a pinned scope", function(w: World)
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
	local restored = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(pickerOf(restored).selected, "no_2fr_2345", "a restored block shows its pin again")
	local launched = w.open(3, { "/work/r", url })
	w.flush()
	eq(pickerOf(launched).selected, "no_2fr_2345", "a block launched on a pull request starts on it")
	eq(pickerOf(launched).scope, "pin", "in its pinned scope")
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

case("host: an issue request makes its worktree once, notes it on the block with the commands that remove it, and refuses a repeat while it runs", function(w: World)
	local s = issueHost(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	local b = openIssues(w)
	local target = "/wt/plotroom-o_r-issue-12"
	eq(badgeOf(b), nil, "no badge before there is a worktree")
	eq(cardOf(b), nil, "and no card")
	request(b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	request(b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(answerOf(b, "a2").busy, true, "a repeat while it runs is told so")
	w.flush()
	local a = answerOf(b, "a1")
	eq(a.path, target, "the answer says where the worktree is")
	eq(a.created, true, "created")
	eq(a.current, true, "a new branch starts at the default branch: current")
	eq(a.dirty, false, "clean")
	eq(a.summary, "Created · 12-fix-login at bbbbbbb · Clean", "and sums it up")
	eq(a.setup, "pnpm install", "a new worktree is set up")
	eq(a.vars.branch, "12-fix-login", "its branch joins the variables")
	eq(a.vars.title, "Fix login", "with the rest")
	eq(countLog(s.git, "worktree add -b 12-fix-login " .. target .. " " .. sha("b")), 1, "made once")
	eq(w.opened[#w.opened], "plotroom://rpc/a1", "the window is told to read it")
	yes(badgeOf(b) ~= nil, "a worktree puts a badge on the row")
	eq(badgeOf(b).tone, "success", "a current, clean worktree is a success")
	eq(cardOf(b).p.tone, "success", "and a card in the preview")
	has(cardText(b), target, "that says where it is")
	eq(commandsOf(b, "cleanup"), "git -C /work/r worktree remove " .. target .. "\ngit -C /work/r branch -d 12-fix-login", "the cleanup commands, one per line")
	eq(commandsOf(b, "update"), nil, "and none to update it: the issue has no head to follow")
	request(b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	w.flush()
	local again = answerOf(b, "a3")
	eq(again.created, false, "the second request reuses it")
	eq(again.setup, nil, "which is not set up again")
	eq(again.summary, "Reused · 12-fix-login at bbbbbbb · Clean", "and says so")
	eq(countLog(s.git, "worktree add"), 1, "still made once")
	s.git.dirty[target] = " M src/a.lua\n"
	request(b, "a4", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	w.flush()
	eq(answerOf(b, "a4").summary, "Reused · 12-fix-login at bbbbbbb · Modified (uncommitted changes kept)", "local changes are reported")
	eq(badgeOf(b).tone, "warning", "and deserve a look")
	s.git.dirty[target] = nil
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2313" })
	w.fs.denyMkdir["/wt"] = "mkdir denied"
	request(b, "a5", { op = "issue", repo = "o/r", ref = "13", worktree = true })
	w.flush()
	has(answerOf(b, "a5").problem, "mkdir denied", "a worktree that cannot be made is answered with the reason")
	eq(badgeOf(b, 2), nil, "it shows no badge")
	eq(cardOf(b).p.tone, "error", "but an error card")
	has(cardText(b), "mkdir denied", "with the reason")
	for _, never in { "worktree remove", "branch", "update-ref", "merge", "config" } do
		eq(countLog(s.git, never), 0, "git " .. never .. " was never run")
	end
end)

case("host: an issue request is dropped unless it is well formed and meant for an issues block", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local pr = w.open(2, { "/work/r" })
	w.flush()
	local ran, told = #w.calls, #w.opened
	local function ignored(block: Block, what: string, value: any)
		block.event({ ev = "action", act = "rpc", value = value })
		w.flush()
		eq(#block.view().main.c, 1, what .. ": no answer is kept")
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.toasts, 0, what .. ": or said")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	ignored(pr, "an issue request to a PR block", jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = "12", worktree = false }))
	ignored(b, "a worktree request to an issues block", jsonEncode({ id = "a1", op = "worktree", repo = "o/r", number = 12 }))
	local repos: { any } = { 5, "o", "o/r/x", "o/..", "../r", "o/r r" }
	for _, repo in repos do
		ignored(b, "the repository " .. show(repo), jsonEncode({ id = "a1", op = "issue", repo = repo, ref = "12", worktree = false }))
	end
	local refs: { any } = { "", "a/b", "a b", "1.5", string.rep("1", 65), true }
	for _, ref in refs do
		ignored(b, "the reference " .. show(ref), jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = ref, worktree = false }))
	end
	local wheres: { any } = { "yes", 1 }
	for _, where in wheres do
		ignored(b, "worktree " .. show(where), jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = "12", worktree = where }))
	end
	ignored(b, "no worktree field", jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = "12" }))
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
	goToSettings(b, "repos", true)
	local sections: { string } = {}
	for _, section in prefsOf(b).sections do
		table.insert(sections, section.id)
	end
	same(sections, { "sec-wtroot", "repo:o/r", "repo:x/y", "rnew" }, "each repository has its own section: the launch one was added")
	local row = rowIn(b, "branch:o/r")
	eq(row.label, "Format (issue worktrees)", "label")
	eq(row.hint, "Variables {key} {slug} {owner} {repo} {project}. Empty: {key}-{slug}.", "the hint lists the variables and the default")
	eq(row.control.k, "text", "a text field")
	eq(row.control.placeholder, "{key}-{slug}", "the default is its placeholder")
	eq(row.control.value, "", "nothing is saved for o/r")
	eq(row.changed, false, "so the row is not marked changed")
	eq(row.defaultLabel, "{key}-{slug}", "and a reset says the default")
	has(b.text(), "12-fix-login", "the preview shows the branch the default makes")
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
	eq(findKey(findKey(pickerNode(b), "branch"), "v").p.spans[1].t, "12-fix-login", "and the default applies meanwhile")
end)

case("host: issue prompts are separate from PR prompts and carry where they run", function(w: World)
	issueHost(w)
	savePrompts(w, { promptOf("p1", "PR only", "Review {url}") })
	saveIssuePrompts(w, {
		issuePrompt("p1", "Triage", "Triage {url}", true, "t"),
		issuePrompt("p2", "Notes", "Summarise {title}", false),
		issuePrompt("p3", "Old", "Old {url}"),
	})
	local pr = w.open(2, { "/work/r" })
	local b = openIssues(w)
	local asked = 0
	-- The rows a block answers a menu request with.
	local function menu(block: Block): { any }
		asked += 1
		request(block, "m" .. asked, { op = "menu" })
		w.flush()
		return answerOf(block, "m" .. asked).items
	end
	same(menu(b), {
		{ id = "p1", label = "Triage", detail = "Triage {url}", group = "All prompts", send = "Triage {url}", worktree = true },
		{ id = "p2", label = "Notes", detail = "Summarise {title}", group = "All prompts", send = "Summarise {title}", worktree = false },
		{ id = "p3", label = "Old", detail = "Old {url}", group = "All prompts", send = "Old {url}", worktree = true },
	}, "the issues block offers its own prompts, each saying where it runs; one saved without the field runs in a worktree")
	same(menu(pr), {
		{ id = "p1", label = "PR only", detail = "Review {url}", group = "All prompts", send = "Review {url}" },
	}, "the PR block offers its own, with no such field")
	goToSettings(b, "prompts")
	expand(b, "popen:p1")
	local ids: { string } = {}
	for _, section in prefsOf(b).sections do
		if section.id == "prompt:p1" then
			for _, r in section.rows do
				table.insert(ids, r.id)
			end
		end
	end
	same(ids, { "pname:p1", "ptext:p1", "pkey:p1", "pwhere:p1", "pdelete:p1", "pclose:p1" }, "Runs in follows the shortcut")
	local where = rowIn(b, "pwhere:p1")
	eq(where.label, "Runs in", "label")
	eq(where.hint, "On: in the issue's worktree (made first if needed). Off: in the repository's main checkout, in a new tab.", "hint")
	eq(where.control.k, "multi", "one chip")
	same(where.control.values, { "worktree" }, "on for a prompt that runs in a worktree")
	same(where.control.options, { { value = "worktree", label = "Worktree" } }, "the chip")
	expand(b, "popen:p2")
	same(rowIn(b, "pwhere:p2").control.values, array({}), "off for one that runs in the checkout")
	expand(b, "popen:p3")
	same(rowIn(b, "pwhere:p3").control.values, { "worktree" }, "and on for one saved without the field")
	expand(b, "popen:p1")
	local function chip(id: string, values: { any })
		b.event({ ev = "change", id = "layer.settings", item = "pwhere:" .. id, value = array(values) })
	end
	chip("p1", {})
	eq(w.kv.get("prompts-issues").items[1].worktree, false, "turning the chip off saves worktree = false")
	same(rowIn(b, "pwhere:p1").control.values, array({}), "the row shows it")
	eq(menu(b)[1].worktree, false, "and the menu says so")
	chip("p2", { "worktree" })
	eq(w.kv.get("prompts-issues").items[2].worktree, true, "on again")
	eq(w.kv.get("prompts-issues").items[1].name, "Triage", "the rest of the prompt is kept")
	eq(w.kv.get("prompts-prs").items[1].worktree, nil, "the PR prompts are untouched")
	b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd" })
	local saved = w.kv.get("prompts-issues")
	eq(#saved.items, 4, "Add prompt saves a new one with the issue prompts")
	eq(saved.items[4].worktree, true, "that runs in a worktree")
	eq(#w.kv.get("prompts-prs").items, 1, "and none with the PR prompts")
	b.press("escape")
	b.press("escape")
	b.typeText("?")
	local keyed = false
	for _, row in helpRows(b.view().layer) do
		keyed = keyed or row.text == "Run the prompt “Triage” on the selected issue"
	end
	yes(keyed, "a prompt's shortcut is listed for the selected issue")
	goToSettings(pr, "prompts")
	eq(rowIn(pr, "pwhere:p1"), nil, "a PR prompt has no Runs in row")
end)

case("host: the issue's buttons, keys and links: Worktree, Go to tab and one button per prompt, each opening the link the card keeps unseen", function(w: World)
	issueHost(w)
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
	same(bar(), { "settings", "retry", "worktree", "prompt-p1", "prompt-p2", "open" }, "Worktree, a button per prompt that has text, and Open last")
	eq(buttonLink(b, "open"), "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12", "Open's link carries the issue's page, percent-encoded")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "Worktree's")
	eq(buttonLink(b, "agent"), issueLink("agent", "o/r", "12"), "the Agent link for the a key and the palette command")
	eq(buttonLink(b, "prompt-p1"), issueRunLink("o/r", "12", "p1"), "each prompt's button runs it on the selected issue")
	eq(buttonLink(b, "goto"), nil, "no tab works in its worktree: no Go to tab")
	eq(b.press("g", nil, "g"), false, "and g does nothing")
	b.event({ ev = "action", id = "layer.queue", act = "worktree" })
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "a click opens the button's link")
	b.event({ ev = "action", id = "layer.queue", act = "prompt-p2" })
	eq(w.opened[#w.opened], issueRunLink("o/r", "12", "p2"), "a prompt button's too")
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
	same(bar(), { "settings", "retry", "worktree", "goto", "prompt-p1", "prompt-p2", "open" }, "a tab in the issue's worktree adds Go to tab before the prompts")
	eq(buttonLink(b, "goto"), issueLink("goto", "o/r", "12"), "with its link")
	b.typeText("g")
	eq(w.opened[#w.opened], issueLink("goto", "o/r", "12"), "g opens it")
	table.remove(w.panes)
	forgetCheckouts(w)
	b.render()
	same(bar(), { "settings", "retry", "worktree", "prompt-p1", "prompt-p2", "open" }, "without a saved checkout the buttons stay: the window asks for one when it runs")
	lacks(b.text(), "No local checkout", "and the heading says nothing of it")
	local opened = #w.opened
	b.typeText("w")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "w opens the Worktree link")
	eq(#w.opened, opened + 1, "and only that one")
end)

case("host: the issues block's Settings speak of issues, the PR queue's keep their own words", function(w: World)
	issueHost(w)
	newAcli(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Triage", "Triage {url}", true) })
	local b = openIssues(w)
	local function page(name: string)
		b.event({ ev = "action", id = "layer.settings", act = "page", value = name })
	end
	goToSettings(b, "views", true)
	expand(b, "vopen:v1")
	eq(prefsOf(b).lead, "Saved searches for the sidebar. GitHub views search every repository the view's login can see; Jira views search every project acli can see.", "views")
	eq(rowIn(b, "name:v1").control.placeholder, "Assigned to me", "a view's name field")
	eq(rowIn(b, "query:v1").control.placeholder, "is:open involves:@me", "and query field")
	eq(rowIn(b, "add").hint, "Starts as GitHub: is:open involves:@me.", "the new view")
	b.event({ ev = "select", id = "layer.settings", item = "add" })
	b.press("enter")
	eq(#w.kv.get("views-issues").items, 5, "Add view saves with the issue views")
	eq(w.kv.get("views-prs"), nil, "and not with the PR views")
	b.press("escape")
	page("prompts")
	eq(prefsOf(b).lead, "Run a prompt on an issue from the action bar or the agent picker (a), in its worktree or the repository's main checkout. Variables such as {url} fill in the issue's details. Offer a prompt under particular views from Settings › Views.", "prompts")
	eq(rowIn(b, "padd").hint, "Starts empty and runs in a worktree.", "the new prompt")
	page("repos")
	eq(prefsOf(b).lead, "Repositories you work in, each with its local checkout (used for worktrees and prompts), the branch format of its issue worktrees and setup commands. Opening Plotroom inside a checkout adds it.", "repositories")
	page("jira")
	eq(prefsOf(b).lead, "Jira projects and the repositories their issues are worked in: Worktree on a Jira issue makes its worktree in the project's repository.", "jira")
	local pr = w.open(2, { "/work/r" })
	w.flush()
	goToSettings(pr, "views")
	eq(prefsOf(pr).lead, "Saved searches for the sidebar. GitHub views search every repository the view's login can see; Jira views search every project acli can see.", "the PR queue's views")
	eq(rowIn(pr, "add").hint, "Starts as GitHub: is:open involves:@me.", "its new view")
	expand(pr, "vopen:v1")
	eq(rowIn(pr, "name:v1").control.placeholder, "My PRs", "its name field")
	eq(rowIn(pr, "vint:v1"), nil, "and no integration to pick")
end)

case("host: a collapsed view is one summary row; Edit expands its form, another's Edit collapses the first, and Done collapses", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "views")
	local summary = rowIn(b, "vopen:v1")
	eq(summary.label, "My PRs · active", "the summary names the view and marks the active one")
	has(summary.hint, "GitHub", "its hint names the integration")
	has(summary.hint, "is:open author:@me", "and the query")
	eq(summary.control.act, "expand", "its button expands the form")
	eq(rowIn(b, "name:v1"), nil, "a collapsed view shows no form row")
	eq(rowIn(b, "query:v1"), nil, "not the query")
	eq(rowIn(b, "delete:v1"), nil, "nor Delete")
	expand(b, "vopen:v1")
	eq(rowIn(b, "vopen:v1"), nil, "an expanded view has no summary row")
	yes(rowIn(b, "name:v1") ~= nil and rowIn(b, "query:v1") ~= nil and rowIn(b, "vgroup:v1") ~= nil, "its form shows")
	eq(prefsOf(b).focus, "name:v1", "with the name focused")
	expand(b, "vopen:v2")
	yes(rowIn(b, "vopen:v1") ~= nil and rowIn(b, "name:v1") == nil, "expanding another view collapses the first")
	yes(rowIn(b, "name:v2") ~= nil, "and shows the other's form")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "vclose:v2" })
	yes(rowIn(b, "vopen:v2") ~= nil and rowIn(b, "name:v2") == nil, "Done collapses it")
	eq(prefsOf(b).focus, "vopen:v2", "and focuses its summary")
	w.kv.put("prompts-prs", { version = 1, nextId = 3, items = array({ promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") }) })
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", logins = array({ "work" }), query = "is:open", group = "repo", prompts = array({ "p2" }) } }) })
	local other = openQueue(w, 2)
	goToSettings(other, "views")
	local hint = rowIn(other, "vopen:v1").hint
	has(hint, "work", "a login shows in the summary")
	has(hint, "by repository", "and the grouping")
	has(hint, "1 prompt", "and how many prompts it offers")
end)

case("host: a collapsed prompt is one summary row; Edit expands it, another's Edit or Done collapses, and Add opens the new prompt expanded", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}", "r"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	local summary = rowIn(b, "popen:p1")
	eq(summary.label, "Review", "the summary names the prompt")
	has(summary.hint, "Review {url}", "its hint shows the text")
	eq(summary.control.act, "expand", "its button expands the form")
	eq(rowIn(b, "pname:p1"), nil, "a collapsed prompt shows no form row")
	eq(rowIn(b, "pdelete:p1"), nil, "nor Delete")
	expand(b, "popen:p1")
	eq(rowIn(b, "popen:p1"), nil, "an expanded prompt has no summary row")
	yes(rowIn(b, "pname:p1") ~= nil and rowIn(b, "ptext:p1") ~= nil and rowIn(b, "pkey:p1") ~= nil, "its form shows")
	expand(b, "popen:p2")
	yes(rowIn(b, "popen:p1") ~= nil and rowIn(b, "pname:p1") == nil, "expanding another prompt collapses the first")
	yes(rowIn(b, "pname:p2") ~= nil, "and shows the other's form")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "pclose:p2" })
	yes(rowIn(b, "popen:p2") ~= nil and rowIn(b, "pname:p2") == nil, "Done collapses it")
	eq(prefsOf(b).focus, "popen:p2", "and focuses its summary")
	expand(b, "popen:p1")
	b.event({ ev = "select", id = "layer.settings", item = "padd" })
	b.press("enter")
	eq(#w.kv.get("prompts-prs").items, 3, "Add saved a prompt")
	yes(rowIn(b, "pname:p3") ~= nil, "the new prompt opens expanded")
	yes(rowIn(b, "popen:p1") ~= nil and rowIn(b, "pname:p1") == nil, "and the one that was open collapses")
	eq(prefsOf(b).editing.row, "pname:p3", "with its name being edited")
end)

case("host: a view without a login sits under gh's active login in the sidebar, and moves when the active account changes", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "user-a"
	s.gh.tokens["user-a"] = "tok-a"
	s.gh.tokens["user-b"] = "tok-b"
	w.kv.put("views-issues", { version = 1, nextId = 4, items = array({
		{ id = "v1", name = "A's", integration = "github", query = "is:open", logins = array({ "user-a" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "B's", integration = "github", query = "is:open", logins = array({ "user-b" }), group = "none", prompts = array({}) },
		{ id = "v3", name = "Plain", integration = "github", query = "is:open", group = "none", prompts = array({}) },
	}) })
	local b = openIssues(w)
	-- The sidebar as "name @ group", in the order shown.
	local function sidebar(): { string }
		local out: { string } = {}
		for _, scope in pickerOf(b).scopes do
			table.insert(out, scope.label .. " @ " .. scope.group)
		end
		return out
	end
	same(sidebar(), { "A's @ GitHub - user-a", "Plain @ GitHub - user-a", "B's @ GitHub - user-b" }, "the view with no login sits with the active login's own view; user-b has its own group")
	s.gh.active = "user-b"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	b.typeText("r")
	w.flush()
	same(sidebar(), { "A's @ GitHub - user-a", "B's @ GitHub - user-b", "Plain @ GitHub - user-b" }, "after the active account switched, the view with no login moved to user-b's group, after user-b's own view")
end)

-- A PR view that runs as the logins `who`, saved as the only one of the PR block.
local function loginsView(w: World, who: { string })
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open author:@me", logins = array(who), group = "none", prompts = array({}) },
	}) })
end

-- The sidebar as "name @ group = id", in the order shown.
local function sidebarOf(b: Block): { string }
	local out: { string } = {}
	for _, scope in pickerOf(b).scopes do
		table.insert(out, scope.label .. " @ " .. (scope.group or "-") .. " = " .. scope.id)
	end
	return out
end

-- Clicks sidebar scope `id` of `b`.
local function pickScope(b: Block, id: string)
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = id })
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
	s.gh.meta["o/r#3"] = { base = "o/r", sha = sha("b"), ref = "feature", state = "open" }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	same(sidebarOf(b), { "Both @ GitHub - octocat = v1@octocat", "Both @ GitHub - work = v1@work" }, "the view is listed once in each login's group")
	eq(pickerOf(b).scope, "v1@octocat", "the first login's scope is the one shown")
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 1, "one search")
	eq(searches[1].login, "octocat", "as that login")
	has(searches[1].fields.q, "is:open author:@me", "with the view's query")
	same(listed(b), { "no_2fr_231", "no_2fr_232" }, "its PRs only")
	w.advance(300)
	eq(requestsOf(s.gh, "checks")[1].login, "octocat", "its checks load as it")
	pickScope(b, "v1@work")
	w.flush()
	searches = requestsOf(s.gh, "search")
	eq(#searches, 2, "the other scope searches on its own")
	eq(searches[2].login, "work", "as its login")
	same(listed(b), { "no_2fr_233" }, "and lists only what that login found, never a merge")
	eq(pickerOf(b).scope, "v1@work", "the scope is the one clicked")
	w.advance(300)
	eq(requestsOf(s.gh, "checks")[2].login, "work", "its checks load as it")
	request(b, "a1", { op = "worktree", repo = "o/r", number = 3 })
	w.flush()
	eq(requestsOf(s.gh, "pr")[1].login, "work", "and its worktree reads the PR as it")
	-- the keys walk the scopes in the order shown
	b.press("tab")
	b.press("up")
	eq(pickerOf(b).scope, "v1@octocat", "Up moves to the scope above")
	w.flush()
	eq(requestsOf(s.gh, "search")[3].login, "octocat", "and runs as its login again")
	same(listed(b), { "no_2fr_231", "no_2fr_232" }, "with its own list")
	b.press("down")
	eq(pickerOf(b).scope, "v1@work", "Down moves to the scope below")
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
	pickScope(b, "v1@work")
	w.flush()
	eq(pickerOf(b).state, "error", "the failing login's scope shows the problem")
	eq(#listed(b), 0, "and no list")
	pickScope(b, "v1@octocat")
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
	local b = openIssues(w)
	same(sidebarOf(b), {
		"Both @ GitHub - user-a = v1@user-a",
		"Active @ GitHub - user-a = v3",
		"Both @ GitHub - user-b = v1@user-b",
		"Just b @ GitHub - user-b = v2",
	}, "Both is under each of its logins; the view with none is under the active account's group")
	goToSettings(b, "views", true)
	has(rowIn(b, "vopen:v1").hint, "GitHub - user-a, user-b", "the summary in Settings lists the logins together")
	has(rowIn(b, "vopen:v3").hint, "GitHub - user-a", "and a view with none names the active account")
	s.gh.active = "user-b"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	b.typeText("r")
	w.flush()
	same(sidebarOf(b), {
		"Both @ GitHub - user-a = v1@user-a",
		"Both @ GitHub - user-b = v1@user-b",
		"Just b @ GitHub - user-b = v2",
		"Active @ GitHub - user-b = v3",
	}, "when the active account switches, the view with none follows it")
end)

case("host: removing the active scope's login from a view moves to its first remaining login", function(w: World)
	local s = hostScene(w, 0)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60) }
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	pickScope(b, "v1@work")
	w.flush()
	same(listed(b), { "no_2fr_237" }, "the work scope is shown")
	goToSettings(b, "views")
	expand(b, "vopen:v1")
	b.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({ "octocat" }) })
	w.flush()
	same(w.kv.get("views-prs").items[1].logins, { "octocat" }, "the list is saved without it")
	same(sidebarOf(b), { "Both @ - = v1" }, "the view is one scope again, and the block's sidebar needs no groups")
	same(listed(b), { "no_2fr_231" }, "and shows the login that is left")
	local searches = requestsOf(s.gh, "search")
	eq(searches[#searches].login, "octocat", "searched as it")
	-- adding a login keeps the scope shown; emptying the list is gh's active account
	b.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({ "octocat", "work" }) })
	eq(pickerOf(b).scope, "v1@octocat", "a login added keeps the scope that was shown")
	eq(#requestsOf(s.gh, "search"), #searches, "and searches nothing more")
	b.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({}) })
	w.flush()
	eq(pickerOf(b).scope, "v1", "with no login the view is one scope")
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
	pickScope(b, "v1@work")
	w.flush()
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the view is saved")
	eq(saved.activeLogin, "work", "and the login of its scope")
	local again = w.open(2, { "/work/r" }, saved)
	w.flush()
	eq(pickerOf(again).scope, "v1@work", "a restored block shows the same scope")
	same(listed(again), { "no_2fr_237" }, "with that login's list")
	local searches = requestsOf(s.gh, "search")
	eq(searches[#searches].login, "work", "searched as it")
	local stale = { version = 2, launchCwd = "/work/r", activeViewId = "v1", activeLogin = "gone" }
	local third = w.open(3, { "/work/r" }, stale)
	w.flush()
	eq(pickerOf(third).scope, "v1@octocat", "a saved login the view does not list falls back to its first")
	same(listed(third), { "no_2fr_231" }, "and shows that one's PRs")
	eq(third.saved().activeLogin, "octocat", "which is what is saved from then on")
end)

case("host: the logins chips of a view add and remove logins, save them, and search again as them", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	loginsView(w, {})
	local fresh = openQueue(w)
	same(listed(fresh), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "a view with no logins lists the active account's PRs")
	goToSettings(fresh, "views")
	expand(fresh, "vopen:v1")
	local row = rowIn(fresh, "vlogins:v1")
	eq(row.label, "GitHub logins", "the row")
	eq(row.control.k, "multi", "is a chips row")
	local options: { string } = {}
	for _, o in row.control.options do
		table.insert(options, o.value)
	end
	same(options, { "octocat", "work" }, "offering every signed-in login")
	same(row.control.values, array({}), "none on by default")
	-- the keys: Enter picks, Right moves, Space toggles
	fresh.event({ ev = "select", id = "layer.settings", item = "vlogins:v1" })
	fresh.press("enter")
	fresh.press("right")
	fresh.press("space")
	same(w.kv.get("views-prs").items[1].logins, { "work" }, "Space turns a login on, saved at once")
	w.flush()
	same(listed(fresh), { "no_2fr_237" }, "the view searched again, as that login: the old account's list is gone")
	eq(requestsOf(s.gh, "search")[#requestsOf(s.gh, "search")].login, "work", "its request ran as it")
	fresh.press("left")
	fresh.press("space")
	same(w.kv.get("views-prs").items[1].logins, { "work", "octocat" }, "another login goes after it, in the order picked")
	fresh.press("escape")
	fresh.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({ "octocat" }) })
	same(w.kv.get("views-prs").items[1].logins, { "octocat" }, "a changed list keeps what is still on and drops the rest")
	fresh.event({ ev = "change", id = "layer.settings", item = "vlogins:v1", value = array({ "octocat", "OCTOCAT", "bad name" }) })
	same(w.kv.get("views-prs").items[1].logins, { "octocat" }, "a repeat in another case and a name that is no login are dropped")
	-- a saved login gh does not know stays an option, so it can be switched off
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open author:@me", logins = array({ "gone" }), group = "none", prompts = array({}) },
	}) })
	local third = w.open(3, { "/work/r" })
	w.flush()
	goToSettings(third, "views")
	expand(third, "vopen:v1")
	local known: { string } = {}
	for _, o in rowIn(third, "vlogins:v1").control.options do
		table.insert(known, o.value)
	end
	same(known, { "octocat", "work", "gone" }, "the signed-in logins, then the saved one gh does not list")
end)

case("host: a view saved with one login loads as a list of one; a malformed list is not overwritten; repeats collapse on the next save", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Old", integration = "github", query = "is:open", login = "work", group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_237" }, "the old login still decides who searches")
	eq(requestsOf(s.gh, "search")[1].login, "work", "as that login")
	goToSettings(b, "views")
	same(rowIn(b, "vopen:v1").label, "Old · active", "the view")
	expand(b, "vopen:v1")
	same(rowIn(b, "vlogins:v1").control.values, { "work" }, "shows it in the chips")
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
	expand(again, "vopen:v1")
	same(rowIn(again, "vlogins:v1").control.values, { "work" }, "the same login in another case is one")
	-- a malformed list is refused whole
	local bad = { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Bad", integration = "github", query = "is:open", logins = array({ "no good" }), group = "none", prompts = array({}) },
	}) }
	w.kv.put("views-prs", bad)
	local third = openQueue(w, 3)
	has(third.text(), "malformed", "a login with a space makes the saved views malformed")
	same(w.kv.get("views-prs"), bad, "and they are not overwritten")
end)

case("host: a Jira issues block lists its view's issues and saves its active view", function(w: World)
	local s = jiraHost(w)
	local b = openJira(w)
	eq(w.kv.get("views-prs"), nil, "the PR views are left alone")
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
		-- the sidebar's group labels learn gh's active login; nothing else may ask gh
		eq(call.argv[1] == "gh" and call.argv[2] ~= "auth", false, "a Jira block never searches through gh: " .. table.concat(call.argv, " "))
		eq(call.argv[1] == "gh" and call.argv[3] ~= "status", false, "nor reads a token: " .. table.concat(call.argv, " "))
	end
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "listed in acli's order")
	eq(pickerOf(b).selected, "nabc_23ABC-12", "the first issue is selected")
	eq(pickerOf(b).state, "ready", "the list is ready")
	eq(b.title(), "Plotroom · Assigned to me (2)", "the title names the filter and counts the issues")
	eq(pickerOf(b).scopes[1].label, "Assigned to me", "the view list shows the Jira view")
	eq(actionOf(b, "repos"), nil, "the action bar has no repository button")
	b.typeText("o")
	eq(#w.opened, 0, "and o opens nothing")
	local function row(i: number): any
		return pickerOf(b).items[i]
	end
	-- A row's badges as "text/tone", in order.
	local function badges(i: number): string
		local out: { string } = {}
		for _, badge in row(i).badges or {} do
			table.insert(out, badge.text .. "/" .. (badge.tone or "-"))
		end
		return table.concat(out, " ")
	end
	eq(row(1).id, "nabc_23ABC-12", "the id is n and the issue's key, escaped")
	eq(row(1).label, "Fix login", "the summary is the label")
	eq(detailText(row(1)), "ABC-12 · Ann Lee · Bug", "the key, the reporter and the type: no repository, no age (the search carries no dates), no assignee")
	eq(detailText(row(2)), "ABC-13 · Ann Lee · Task", "the same for an unassigned issue")
	eq(row(1).facts.assignee, nil, "no assignee column: the rows do not show assignees")
	eq(row(2).facts.assignee, nil, "for any issue")
	same(pickerOf(b).columns, { { id = "comments", format = "text", priority = 50 } }, "the only column is the comment count")
	eq(badges(1), "Jira/accent In Progress/warning ui/-", "the integration comes first, accent for Jira, then the workflow status toned by its category, then the labels")
	eq(badges(2), "Jira/accent Done/success", "a done issue says Done")
	eq(row(1).facts.comments, nil, "the search carries no comment count")
	eq(actionOf(b, "open").label, "Jira ↗", "the Open button names the tracker")
	b.typeText("?")
	for _, r in helpRows(b.view().layer) do
		eq(r.keys == "o", false, "no shortcut for another project")
	end
	b.press("escape")
	local rerun = w.open(1, { "/work/r" }, nil, "issues")
	w.flush()
	same(listed(rerun), { "nabc_23ABC-12", "nabc_23ABC-13" }, "running init again for the live pane keeps its Jira list")
	eq(searched(), 1, "and does not search twice")
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the block saves its active view")
	local again = w.open(2, { "/work/r" }, saved, "issues")
	w.flush()
	eq(again.title(), "Plotroom · Assigned to me (2)", "a restored block shows the same view")
end)

case("host: issues list In Progress, then To Do, then Done, in acli's priority order within each; Settings moves a category up and every list re-sorts", function(w: World)
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
	local b = openJira(w)
	same(listed(b), { "nabc_23ABC-3", "nabc_23ABC-5", "nabc_23ABC-2", "nabc_23ABC-4", "nabc_23ABC-1" }, "by status category, acli's order within one")
	local views: any = w.kv.get("views-issues")
	views.items[1].group = "status"
	w.kv.put("views-issues", views)
	local grouped = openJira(w, 2)
	-- group headers by label, items by id
	local function shown(blk: Block): { string }
		local out: { string } = {}
		for _, id in pickerOf(blk).order do
			table.insert(out, if type(id) == "table" then id.label else id)
		end
		return out
	end
	same(shown(grouped), { "In Review", "nabc_23ABC-3", "In Development", "nabc_23ABC-5", "Proposed", "nabc_23ABC-2", "nabc_23ABC-4", "Done", "nabc_23ABC-1" }, "status groups follow the list, not the alphabet")
	goToSettings(b, "views", true)
	eq(rowIn(b, "sorder:indeterminate").disabled, "Listed first.", "the first category cannot move up")
	b.event({ ev = "action", id = "layer.settings", act = "move-up", value = "sorder:new" })
	same(w.kv.get("status-order"), array({ "new", "indeterminate", "done" }), "the order is saved")
	eq(prefsOf(b).focus, "sorder:indeterminate", "the focus moves to the row that can still move up")
	same(shown(grouped), { "Proposed", "nabc_23ABC-2", "nabc_23ABC-4", "In Review", "nabc_23ABC-3", "In Development", "nabc_23ABC-5", "Done", "nabc_23ABC-1" }, "every issues block re-sorts")
	w.kv.put("status-order", "garbage")
	b.event({ ev = "action", id = "layer.settings", act = "move-up", value = "sorder:done" })
	eq(rowIn(b, "sorder:done").warning, "The saved status order could not be read; not overwriting it.", "an unreadable order says so")
	eq(w.kv.get("status-order"), "garbage", "and is not overwritten")
	b.press("escape")
	same(listed(b), { "nabc_23ABC-2", "nabc_23ABC-4", "nabc_23ABC-3", "nabc_23ABC-5", "nabc_23ABC-1" }, "the block that moved it re-sorts too")
end)

case("host: a Jira view's Settings speak of JQL, the shared prompts, the repositories its issues are worked in and its branch format", function(w: World)
	local s = jiraHost(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Triage", "Triage {key} in {project}: {title}", true) })
	local b = openJira(w)
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
	goToSettings(b, "views", true)
	expand(b, "vopen:v1")
	eq(rowIn(b, "query:v1").hint, "JQL across every project, listed by status, then priority, so leave out ORDER BY.", "the query field names its syntax")
	eq(rowIn(b, "query:v1").control.placeholder, "assignee = currentUser() AND statusCategory != Done", "and shows an example")
	eq(rowIn(b, "vlogin:v1"), nil, "a Jira view has no gh login")
	save("query:v1", "a = 1) OR (b = 2")
	eq(rowIn(b, "query:v1").warning, "Unbalanced parentheses.", "a query that closes its own parenthesis is refused")
	eq(prefsOf(b).editing.row, "query:v1", "the draft stays for a correction")
	b.press("escape")
	s.acli.searches['(summary ~ "login") ORDER BY priority DESC, updated DESC'] = { jiraItem("ABC-12", "Fix login") }
	save("query:v1", 'summary ~ "login"')
	w.flush()
	eq(lastJql(), '(summary ~ "login") ORDER BY priority DESC, updated DESC', "a good query searches again, in parentheses, highest priority first")
	same(listed(b), { "nabc_23ABC-12" }, "and lists what it finds")
	page("prompts")
	expand(b, "popen:p1")
	eq(rowIn(b, "pname:p1").control.value, "Triage", "the prompts saved for issues are shared with GitHub's")
	eq(rowIn(b, "pwhere:p1").hint, "On: in the issue's worktree (made first if needed). Off: in the repository's main checkout, in a new tab.", "where a prompt runs")
	b.event({ ev = "action", id = "layer.settings", act = "edit-prompt", value = "ptext:p1" })
	local legend: { string } = {}
	for _, item in findKey(editorCard(b), "list", "kv").p.items do
		table.insert(legend, item.k[1].t)
	end
	same(legend, { "{url}", "{key}", "{title}", "{author}", "{labels}", "{branch}", "{owner}", "{repo}", "{number}", "{project}", "{status}", "{type}" }, "the variables of both trackers are listed")
	b.press("escape")
	page("jira")
	eq(rowIn(b, "jrepos:ABC").control.values[1], "o/r", "the project's repository")
	same(rowIn(b, "jrepos:ABC").control.options, { { value = "o/r", label = "o/r" } }, "chosen among the saved repositories")
	page("repos")
	eq(rowIn(b, "branch:o/r").hint, "Variables {key} {slug} {owner} {repo} {project}. Empty: {key}-{slug}.", "the branch format offers the Jira variable too")
	save("branch:o/r", "{project}/{key}")
	eq(w.kv.get("branch-formats")["o/r"], "{project}/{key}", "a good format is saved under the repository")
	has(b.text(), "ABC/ABC-12", "and the preview's branch follows")
	page("views")
	b.event({ ev = "select", id = "layer.settings", item = "add" })
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
	goToSettings(b, "repos", true)
	b.event({ ev = "select", id = "layer.settings", item = "rremove:x/y" })
	b.press("enter")
	b.typeText("d")
	eq(w.kv.get("checkouts")["x/y"], nil, "its checkout is forgotten")
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the other repository's stays")
	same(w.kv.get("branch-formats"), { ["o/r"] = "{key}" }, "so is its branch format")
	same(w.kv.get("setup-commands"), { ["o/r"] = { "pnpm install" } }, "and its setup commands")
	same(w.kv.get("jira-repos"), { ABC = { "o/r" }, DEF = array({}) }, "every Jira project drops it; one left with none stays listed")
	eq(rowIn(b, "checkout:x/y"), nil, "its section is gone from the page")
end)

case("host: an issues block's Settings pages cycle with Tab: views, prompts, repositories, Jira, connection", function(w: World)
	issueHost(w)
	newAcli(w)
	local b = openIssues(w)
	goToSettings(b, "views", true)
	local walked: { string } = { prefsOf(b).page }
	for _ = 1, 5 do
		b.press("tab")
		table.insert(walked, prefsOf(b).page)
	end
	same(walked, { "views", "prompts", "repos", "jira", "connection", "views" }, "Tab walks every page and around again")
	local ids: { string } = {}
	for _, p in prefsOf(b).pages do
		table.insert(ids, p.id)
	end
	same(ids, { "views", "prompts", "repos", "jira", "connection" }, "an issues block offers the Jira page; the PR queue has none")
	local pr = w.open(2, { "/work/r" })
	w.flush()
	goToSettings(pr, "views")
	local prIds: { string } = {}
	for _, p in prefsOf(pr).pages do
		table.insert(prIds, p.id)
	end
	same(prIds, { "views", "prompts", "repos", "connection" }, "the PR queue's pages")
end)

case("host: a Jira issue request makes its worktree in the project's mapped GitHub repository", function(w: World)
	local s = jiraHost(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	local b = openJira(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	eq(badgeOf(b), nil, "no badge before there is a worktree")
	request(b, "j1", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true })
	w.flush()
	local a = answerOf(b, "j1")
	eq(a.path, target, "the worktree is named after the repository and the issue's key")
	eq(a.created, true, "created")
	eq(a.summary, "Created · ABC-12-fix-login at bbbbbbb · Clean", "on a branch of the key and the summary's slug, at the remote's default branch")
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
		branch = "ABC-12-fix-login",
	}, "the issue's Jira variables, with the branch")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +HEAD:refs/plotroom-base/o/r"), 1, "the repository's default branch was fetched into its own base ref")
	eq(countLog(s.git, "worktree add -b ABC-12-fix-login " .. target .. " " .. sha("b")), 1, "and the worktree made once")
	eq(w.opened[#w.opened], "plotroom://rpc/j1", "the window is told to read the answer")
	eq(badgeOf(b).text, "Worktree", "a worktree puts a badge on the row")
	table.insert(w.panes, { pane = 9, cwd = target .. "/src" })
	b.render()
	eq(pickerOf(b).items[1].badges[1].text, "Jira", "the integration stays the first badge")
	eq(pickerOf(b).items[1].badges[2].text, "In tab", "a tab in the worktree marks the issue after it: the directory keeps the key's case")
	local titlerow: any = findKey(pickerNode(b), "titlerow")
	yes(titlerow ~= nil, "the preview has a title row")
	eq(titlerow.c[1].p.key, "title", "its first node is the title")
	eq(titlerow.c[2].p.key, "integration", "followed by the integration badge")
	eq(titlerow.c[2].p.text, "Jira", "naming the tracker")
	eq(titlerow.c[2].p.tone, "accent", "accent for Jira")
	eq(findKey(findKey(pickerNode(b), "head"), "integration"), nil, "and the head row no longer carries it")
	-- a format saved for the repository applies, with its {project}
	w.kv.put("branch-formats", { ["o/r"] = "{project}/{key}" })
	request(b, "j2", { op = "issue", repo = "ABC", ref = "ABC-13", worktree = true })
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
	local b = openJira(w)
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
	eq(#s.acli.requests, 2, "only the sign-in and the search were asked: the details wait for the cursor to rest")
	w.advance(300)
	eq(s.acli.requests[3].kind, "view", "the details load once the cursor rests")
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
	eq(findKey(findKey(preview, "branch"), "v").p.spans[1].t, "ABC-12-fix-login", "the branch Worktree would make")
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
		"  Login API | ABC-3 | circle-dot | muted | ABC-3 · To Do",
		"  Review copy | ABC-5 | circle-dot | warning | ABC-5 · In Review",
		"Relates to · 1",
		"  Old notes | ABC-6 | circle-dot | muted | ABC-6 · Backlog",
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
	local b = openJira(w)
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
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(w.toasts[1].level, "info", "start")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "names the issue")
	eq(w.toasts[2].level, "success", "level")
	eq(w.toasts[2].text, "Worktree ready for o/r#12", "names the issue")
	eq(w.toasts[2].sub, "Created · 12-fix-login at bbbbbbb · Clean", "a new worktree on the issue's branch, at the default branch")
	local sent = requestsSent(w)
	eq(#sent, 1, "one request")
	eq(sent[1].op, "issue", "the issue op")
	eq(sent[1].repo, "o/r", "of the repository")
	eq(sent[1].ref, "12", "and the issue")
	eq(sent[1].worktree, true, "in a worktree")
	eq(#w.window.launches, 1, "one tab")
	eq(w.window.launches[1].cwd, target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "#12 · r", "tab name")
	eq(s.git.refs["refs/heads/12-fix-login"], sha("b"), "the branch starts at the remote's default branch")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +HEAD:refs/plotroom-base/o/r"), 1, "which was fetched once")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b 12-fix-login " .. target .. " " .. sha("b")), 1, "and the worktree added through omp")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	has(cardText(b), target, "and the card says where the worktree is")
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(w.toasts[#w.toasts].level, "success", "the second click")
	has(w.toasts[#w.toasts].sub, "Reused", "reuses it")
	eq(countLog(s.git, "worktree add"), 1, "made once")
	eq(#w.window.launches, 2, "and opens its tab again")
end)

-- A window whose pane 1 is the issues block of `jiraHost` on project ABC, linked.
local function jiraWindow(w: World): (JiraScene, Block)
	local s = jiraHost(w)
	w.load("window")
	w.window.panes[1].block = "plugin.plotroom.issues"
	local b = openJira(w)
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
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(w.toasts[1].text, "Preparing worktree for ABC-12", "names the issue by its key")
	eq(w.toasts[2].level, "success", "level")
	eq(w.toasts[2].sub, "Created · ABC-12-fix-login at bbbbbbb · Clean", "a new worktree on the issue's branch")
	eq(requestsSent(w)[1].repo, "ABC", "the request names the project")
	eq(w.window.launches[1].cwd, target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "ABC-12", "tab name")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +HEAD:refs/plotroom-base/o/r"), 1, "the base is fetched into the repository's own ref")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
end)

windowCase("window: Jira issue picks its repository: asked when none is mapped, among several, never with one", function(w: World)
	local _, b = jiraWindow(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	-- none mapped: the pick maps the project, then the worktree is made there
	w.kv.put("jira-repos", {})
	w.window.choose = "o/r"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	local picks = w.window.picks
	eq(#picks, 1, "one question")
	eq(picks[1].placeholder, "Repository for Jira project ABC…", "it names the project")
	eq(picks[1].items[1].label, "o/r", "offering the saved repositories")
	eq(picks[1].items[#picks[1].items].label, "Other repository…", "and a typed one")
	same(w.kv.get("jira-repos").ABC, { "o/r" }, "the pick is saved for the project")
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "issue", "map-jira", "issue" }, "the request is repeated once the project is mapped")
	eq(requestsSent(w)[3].target, "o/r", "naming the repository picked")
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
	local _, b = issueWindow(w)
	w.window.panes[9] = { block = nil, cwd = "/wt/plotroom-o_r-issue-12/src", tab = 2 }
	table.insert(w.window.tabs, { id = 2, session = 1 })
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-12/src" })
	b.render()
	cardSurface(w, b)
	w.click(issueLink("goto", "o/r", "12"))
	same(w.window.switches, { 1 }, "its session is switched to")
	eq(w.window.focused, 9, "and the pane focused")
	eq(#w.toasts, 0, "with nothing said")
end)

windowCase("window: a prompt set to the main checkout starts its agent in a new tab at the checkout after consent, with no worktree made", function(w: World)
	local s, b = issueWindow(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Review", "Review {title} ({url}) in {owner}/{repo}#{number}, branch {branch}", false) })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	b.render()
	cardSurface(w, b)
	w.window.choose = { "Deny" }
	w.click(issueRunLink("o/r", "12", "p1"))
	w.flush()
	eq(#w.window.agents, 0, "Deny starts nothing")
	eq(w.toasts[#w.toasts].text, "Agent not started for o/r#12", "and says so")
	has(w.toasts[#w.toasts].sub, "The checkout is at /work/r", "naming the checkout")
	w.window.choose = { "Allow" }
	w.click(issueRunLink("o/r", "12", "p1"))
	w.flush()
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "menu", "issue", "menu", "issue" }, "the host is asked what the prompt is, then for the checkout")
	eq(requestsSent(w)[4].worktree, false, "and the request says no worktree")
	local asked = picksOf(w, "consent")
	eq(#asked, 2, "the one question comes once per run")
	eq(asked[2].placeholder, "Start an agent for o/r#12?", "it names the issue")
	eq(asked[2].items[1].detail, "Nothing changes; no agent starts", "Deny leaves everything as it is")
	eq(asked[2].items[2].detail, "Runs omp in /work/r", "and Allow names the checkout")
	eq(#w.window.agents, 1, "Allow starts the agent")
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
		issuePrompt("p1", "Here", "In {branch}: {title}", true),
		issuePrompt("p2", "There", "In the checkout, branch {branch}, labels {labels}", false),
	})
	b.render()
	cardSurface(w, b)
	w.window.choose, w.window.typed = { "Allow", "Type a prompt…" }, "Fix {title} ({key}) on {branch}; {nope}"
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	local rows = picksOf(w, "prompts")[1].items
	same({ rows[1].label, rows[2].label, rows[3].label }, { "Type a prompt…", "Here", "There" }, "typing, then the saved prompts")
	eq(rows[2].worktree, true, "a prompt that runs in a worktree says so")
	eq(rows[3].worktree, false, "and one that runs in the checkout")
	eq(#w.window.agents, 1, "the typed prompt started an agent")
	eq(w.window.agents[1].cwd, "/wt/plotroom-o_r-issue-12", "in the issue's worktree")
	eq(w.window.agents[1].prompt, "Fix Fix login (12) on 12-fix-login; {nope}", "with the issue's variables and the worktree's branch filled in; an unknown one stays")
	eq(picksOf(w, "consent")[1].items[1].detail, "The worktree stays; no agent starts", "its Deny leaves the worktree")
	eq(countLog(s.git, "worktree add -b 12-fix-login /wt/plotroom-o_r-issue-12 " .. sha("b")), 1, "the worktree was made for it")
	w.window.choose = { "Allow", "There" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	eq(#w.window.agents, 2, "a saved prompt starts one too")
	eq(w.window.agents[2].cwd, "/work/r", "in the main checkout, as the prompt says")
	eq(w.window.agents[2].prompt, "In the checkout, branch {branch}, labels bug, ui", "with no branch to fill in")
	w.window.choose = { "Allow", "Here" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	eq(#w.window.agents, 3, "and another")
	eq(w.window.agents[3].cwd, "/wt/plotroom-o_r-issue-12", "in the worktree, as that prompt says")
	eq(w.window.agents[3].prompt, "In 12-fix-login: Fix login", "with its branch")
	eq(countLog(s.git, "worktree add"), 1, "the worktree is made once")
end)

windowCase("window: Open on an issue docks a Browser at its URL", function(w: World)
	local _, b = issueWindow(w)
	local open = "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12"
	eq(buttonLink(b, "open"), open, "the block's Open link carries the issue's URL")
	w.click(open)
	w.flush()
	eq(#w.window.browser, 1, "one Browser request")
	same(w.window.browser[1], { op = "open", owner = 1, url = "https://github.com/o/r/issues/12" }, "to open the issue's page beside the block")
	eq(#w.toasts, 0, "it opened and docked, so nothing is said")
	w.command("open-selected")
	w.flush()
	eq(#w.window.browser, 2, "the palette command follows the same link")
end)

windowCase("window: a linked pull request in an issue's sidebar shows it in a GitHub PRs block: this tab's, else another tab's, else a new one beside the issues", function(w: World)
	local s, b = issueWindow(w)
	local url = "https://github.com/o/r/pull/45"
	s.gh.issueDetail["o/r#12"] = { body = "x", linked = array({ { number = 45, title = "Fix the login redirect", url = url, state = "OPEN", isDraft = false } }) }
	w.advance(300)
	cardSurface(w, b)
	local show = "plotroom://github/show/o/r/45"
	eq(findKey(pickerNode(b), "pr1", "item").p.href, show, "the linked row links to showing it")
	w.click(show)
	same(w.window.launches, { { block = "plotroom.prs", cwd = "/work/r", args = { "/work/r", url } } }, "no PRs block yet: one is launched on the pull request")
	eq(w.window.panes[11].tab, 1, "split beside the issues")
	w.click(show)
	eq(#w.window.launches, 1, "a second click opens no other block")
	same(w.window.events[#w.window.events], { pane = 11, ev = { ev = "action", act = "show-pr", value = url } }, "it tells the tab's PRs block to show the pull request")
	eq(w.window.focused, 11, "and focuses it")
	w.window.panes[11] = nil
	w.window.panes[20] = { block = "plugin.plotroom.prs", cwd = "/work/r", tab = 2 }
	table.insert(w.window.tabs, { id = 2, session = 2 })
	w.click(show)
	eq(w.window.events[#w.window.events].pane, 20, "a PRs block in another tab is used")
	eq(w.window.switches[#w.window.switches], 2, "its session is shown")
	eq(w.window.focused, 20, "and the block focused")
	local said, sent = #w.toasts, #w.window.events
	w.click("plotroom://github/show/o/r/46")
	eq(w.toasts[said + 1].text, "Plotroom: that pull request is no longer listed", "a pull request the sidebar does not link is refused")
	eq(#w.window.events, sent, "and no block is told anything")
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
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.window.picks, picked, "nothing was offered")
	eq(#w.window.browser, 0, "no Browser opened")
	eq(#w.window.agents + #w.window.launches, 0, "and nothing started")
end)

-- ---------------------------------------------------------------- runner

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
