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
	open: (number, { string }?, any?) -> Block,
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

	local function open(pane: number, args: { string }?, savedState: any?): Block
		local def: any = blocks["prs"]
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
	total: { [string]: number }, -- login -> issueCount when it differs from #items
	meta: { [string]: { base: string, sha: string, ref: string, state: string } }, -- "owner/repo#N" -> pulls/N
	checks: { [string]: { any } }, -- "owner/repo#N" -> check nodes of its latest commit
	checkTotal: { [string]: number },
	about: { [string]: { [string]: any } }, -- "owner/repo#N" -> the `about` part CHECKS_JQ prints
	limits: { [string]: GhLimit }, -- login -> GraphQL quota, reported in the response headers
	pageSize: number,
	override: ((GhReq) -> Reply?)?, -- answers first: a failure, a malformed page
	requests: { GhReq },
}

local function newGh(w: World): Gh
	local gh: Gh = {
		active = "octocat",
		tokens = {},
		items = {},
		total = {},
		meta = {},
		checks = {},
		checkTotal = {},
		about = {},
		limits = {},
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
		local override = gh.override
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
				end
				i += 1
			end
		end
		local kind = "other"
		if fields.q then
			kind = "search"
		elseif fields.o and fields.r and fields.n then
			kind = "checks"
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
		local key = login or ""
		local lim = gh.limits[key]
		if kind == "search" or kind == "checks" then
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
		elseif kind == "checks" then
			local id = (fields.o or "") .. "/" .. (fields.r or "") .. "#" .. (fields.n or "")
			local nodes = gh.checks[id] or {}
			local slice, cursor = page(nodes, fields.after)
			local body = jsonEncode({ total = gh.checkTotal[id] or #nodes, next = cursor, nodes = slice, about = gh.about[id] })
			return { stdout = headers(lim) .. body }
		elseif kind == "pr" then
			local repo, n = string.match(path or "", "^repos/(.+)/pulls/(%d+)$")
			local meta = gh.meta[(repo or "") .. "#" .. (n or "")]
			if not meta then
				return { status = 1, stderr = "gh: Not Found (HTTP 404)\n" }
			end
			return { stdout = jsonEncode(meta) }
		end
		return nil
	end)
	return gh
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
	gh.meta[repo .. "#" .. n] = { base = repo, sha = sha("b"), ref = "feature", state = "open" }
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

local function openWt(w: World, worktree: Worktree, s: Scene, mapped: string?, waitMs: number?): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.open(s.launch, mapped, s.repo, s.number, function(result, problem, cx)
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

windowCase("worktree: no matching checkout is NO_REPO; a mapped checkout is used when the launch directory is not it", function(w: World)
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
	local mapped = openWt(w, worktree, s, "/work/other", nil)
	eq(mapped.problem, nil, "the mapped checkout resolves")
	eq(mapped.result.root, "/work/other", "root")
	eq(mapped.result.path, "/wt/plotroom-o_r-pr-5", "path")
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

-- The settings view's page props: its prefs node comes after the hidden nodes that hold the answers to the window.
local function prefsOf(b: Block): any
	local view: any = b.view()
	return findKey(view.main, "settings", "prefs").p
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
	b.event({ ev = "select", id = "layer.queue", item = "n" .. n })
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
local function promptOf(id: string, name: string, text: string, filters: { string }?, key: string?): { [string]: any }
	return { id = id, name = name, text = text, filters = array(filters or {}), key = key }
end

-- Makes `list` the saved prompts.
local function savePrompts(w: World, list: { { [string]: any } })
	w.kv.put("prompts", { version = 1, nextId = #list + 1, items = array(list) })
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
	local s = agentScene(w)
	savePrompts(w, {
		promptOf("p1", "Review", "Review {url}\nthen summarise", { "f1" }),
		promptOf("p2", "Triage", "Triage {url}, then triage {url} again"),
		promptOf("p3", "Others", "Check the tests", { "f2" }),
		promptOf("p4", "Blank", ""),
		promptOf("p5", "Orphan", "Look into {url}", { "f9" }),
	})
	w.window.choose = { "Allow", "Review" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local items = picksOf(w, "prompts")[1].items
	local labels: { string } = {}
	for _, item in items do
		table.insert(labels, item.label)
	end
	same(labels, { "Type a prompt…", "Review", "Triage", "Orphan" }, "typing, the filter's own prompts, then those offered under every filter; one for another filter and one with no text are left out")
	eq(items[1].detail, "Send your own text", "typing says what it does")
	eq(items[2].group, "For My PRs", "a prompt of the active filter has that filter's group")
	eq(items[2].detail, "Review {url}", "and its first line as its detail")
	eq(items[3].group, "All filters", "an every-filter prompt")
	eq(items[4].group, "All filters", "so is one scoped only to a filter that no longer exists")
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
	same(groups, { "Recent", "", "All filters" }, "the recent one leads, then typing, then the saved prompts")
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
	w.kv.put("prompts", "garbage")
	w.window.choose, w.window.typed = { "Allow", "Type a prompt…" }, "Look at {url}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[1].level, "error", "the user is told")
	eq(w.toasts[1].text, "Saved prompts are not listed", "what is missing")
	has(w.toasts[1].sub, "malformed", "and why")
	eq(#picksOf(w, "prompts")[1].items, 1, "the picker still opens")
	eq(w.window.agents[1].prompt, "Look at https://github.com/o/r/pull/5", "to type a prompt")
	eq(w.kv.get("prompts"), "garbage", "and the saved prompts are untouched")
end)

windowCase("window: a card button's run link runs its prompt with every {url} replaced in the PR's worktree once allowed, as the prompt is saved now", function(w: World)
	local s, b = agentScene(w)
	savePrompts(w, {
		promptOf("p1", "Review", "Review {url}\nthen summarise {url}", { "f1" }),
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
	gone("moved to another filter", { promptOf("p1", "Review", "Review {url}", { "f2" }) })
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
	w.kv.put("setup", { ["github.com/o/r"] = array({ "pnpm install", "  ", "make" }), ["github.com/x/y"] = array({ "nope" }) })
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
	w.kv.put("setup", { ["github.com/o/r"] = array({ "pnpm install" }) })
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
	w.kv.put("setup", { ["github.com/o/r"] = array({ "pnpm install" }) })
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

windowCase("window: no local checkout opens the block's settings for one; any other failure is noted and toasted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	s.git.remotes.origin = { "https://github.com/x/y.git" }
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "info", "level")
	has(w.toasts[2].text, "o/r", "names the repository")
	eq(prefsOf(b).page, "worktrees", "the block's settings open on the Worktrees page")
	eq(prefsOf(b).editing.row, "checkout", "with the checkout row ready for a path")
	eq(countLog(s.git, "worktree add"), 0, "nothing was created")
	b.press("escape")
	b.press("escape")
	s.git.remotes.origin = { "https://github.com/o/r.git" }
	s.gh.meta["o/r#5"] = nil
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[4].level, "error", "level")
	has(w.toasts[4].sub, "not visible to this GitHub account", "gh's classified reason")
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
	local nodes: { any } = { { id = "main.rpc", p = { text = "3", hidden = true } } }
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

case("github.account: an unreadable or malformed store fails closed and is never overwritten", function(w: World)
	local github = w.load("github") :: Github
	local saved = { ["github.com/a/b"] = "work", ["github.com/other/repo"] = "other-user" }
	w.kv.put("accounts", saved)
	w.kv.failGet["accounts"] = "disk offline"
	local login: string?, problem: any = github.account("a/b")
	eq(login, nil, "no login from an unreadable store")
	eq(problem.kind, "account", "problem kind")
	has(problem.message, "could not be read", "problem message")
	w.kv.failSet["*"] = "set must not be called"
	local err = github.setAccount("a/b", "ok-user")
	has(err, "could not be read", "setAccount refuses to write over an unreadable store")
	lacks(err, "set must not be called", "kv.set was never attempted")
	w.kv.failGet["accounts"] = nil
	same(w.kv.get("accounts"), saved, "the saved map is untouched")
	w.kv.failSet["*"] = nil
	local malformed: { any } = { "oops", { "x" } }
	for _, bad in malformed do
		w.kv.put("accounts", bad)
		local who: string?, why: any = github.account("a/b")
		eq(who, nil, "no login from a malformed store")
		has(why.message, "malformed", "malformed store")
		has(github.setAccount("a/b", "ok-user"), "malformed", "setAccount refuses a malformed store")
		same(w.kv.get("accounts"), bad, "a malformed store is not replaced")
	end
end)

case("github.account: entries are per repository; one bad entry does not touch the others", function(w: World)
	local github = w.load("github") :: Github
	local none: string?, nothing: any = github.account("a/b")
	eq(none, nil, "nothing saved: the active account")
	eq(nothing, nil, "and no problem")
	w.kv.put("accounts", { ["github.com/a/b"] = "bad name" })
	local login: string?, problem: any = github.account("a/b")
	eq(login, nil, "an invalid saved login is not used")
	has(problem.message, "not a valid login", "problem")
	eq(github.setAccount("c/d", "ok"), nil, "saving another repository works")
	same(w.kv.get("accounts"), { ["github.com/a/b"] = "bad name", ["github.com/c/d"] = "ok" }, "the other entry is kept verbatim")
	local ok: string?, fine: any = github.account("c/d")
	eq(ok, "ok", "login")
	eq(fine, nil, "no problem")
	w.kv.put("accounts", { ["github.com/a/b"] = "work", ["github.com/other/repo"] = "other-user" })
	eq((github.account("A/B")), "work", "keys are case-insensitive")
	eq(github.setAccount("a/b", nil), nil, "clearing works")
	same(w.kv.get("accounts"), { ["github.com/other/repo"] = "other-user" }, "only this repository's entry was removed")
	eq(github.setAccount("other/repo", ""), nil, "an empty login clears")
	same(w.kv.get("accounts"), {}, "the map is empty")
end)

case("github.setAccount: a bad login is refused before the store is read; a failing write is reported", function(w: World)
	local github = w.load("github") :: Github
	w.kv.failGet["*"] = "boom"
	has(github.setAccount("a/b", "bad name"), "letters, digits and hyphens", "validation comes first")
	w.kv.failGet["*"] = nil
	w.kv.failSet["accounts"] = "read-only file system"
	has(github.setAccount("a/b", "ok"), "read-only file system", "write failure")
end)

windowCase("github: with the saved accounts unreadable, search, checks and pr report an account problem and send nothing", function(w: World)
	local github = w.load("github") :: Github
	w.kv.failGet["accounts"] = "disk offline"
	local seen: { string } = {}
	local prCx: any = nil
	github.search("a/b", "is:open", always, function(result, problem, spent)
		table.insert(seen, "search " .. (if result then "result" else (if problem then problem.kind else "?")) .. " " .. spent)
	end)
	github.checks("a/b", 5, function(runs, total, problem)
		table.insert(seen, "checks " .. (if runs then "runs" else (if problem then problem.kind else "?")) .. " " .. total)
	end)
	github.pr("a/b", 5, function(meta, problem, cx)
		table.insert(seen, "pr " .. (if meta then "meta" else (if problem then problem.kind else "?")))
		prCx = cx
	end)
	eq(#seen, 0, "answers are deferred, never synchronous")
	w.flush()
	same(seen, { "search account 0", "checks account 0", "pr account" }, "answers")
	yes(prCx ~= nil, "pr's answer carries a window cx")
	eq(#w.calls, 0, "no gh process was started")
end)

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

case("github.scopeProblem: nothing may widen the search beyond the repository, quoted phrases stay plain text", function(w: World)
	local github = w.load("github") :: Github
	for _, fine in { 'is:open label:"bug OR regression"', '"foo OR bar" is:open', 'is:open "OR"', "is:open or later", "is:open author:@me" } do
		eq(github.scopeProblem(fine), nil, "allowed: " .. fine)
	end
	for _, bad in { "is:open OR is:draft", 'label:"x" OR is:draft', 'label:"bug OR', "is:open repo:x/y", '"repo:x/y"', 'label:"a repo:x/y"', "-org:x", "(user:x OR is:open)", "is:open (OR)" } do
		yes(github.scopeProblem(bad) ~= nil, "refused: " .. bad)
	end
end)

type SearchOut = { result: any, problem: any, spent: number?, calls: number }

local function runSearch(w: World, github: Github, shouldContinue: (() -> boolean)?): SearchOut
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.search("o/r", "is:open", shouldContinue or always, function(result, problem, spent)
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

case("github.search: a saved account searches as that account and never leaks the active one's PRs", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	w.kv.put("accounts", { ["github.com/o/r"] = "work" })
	gh.tokens.work = "tok-work"
	gh.items.work = manyItems("o/r", 3)
	gh.items.octocat = manyItems("o/r", 7)
	local out = runSearch(w, github, nil)
	eq(#out.result.prs, 3, "the work account's PRs")
	eq(gh.requests[1].kind, "token", "the token is read first")
	eq(gh.requests[2].kind, "search", "then the search")
	for _, req in gh.requests do
		eq(req.login, "work", "every request ran as the saved account")
	end
end)

case("github.search: an empty or scope-widening query fails asynchronously without a request", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.search("o/r", "   ", always, function(result, problem, spent)
		out.calls += 1
		out.result, out.problem, out.spent = result, problem, spent
	end)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	eq(out.problem.kind, "failed", "problem kind")
	eq(out.spent, 0, "spent")
	out.calls = 0
	github.search("o/r", "is:open repo:x/y", always, function(result, problem, spent)
		out.calls += 1
		out.result, out.problem, out.spent = result, problem, spent
	end)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	has(out.problem.message, "repo:x/y", "the offending word is named")
	eq(#gh.requests, 0, "nothing was sent")
end)

type ChecksOut = { runs: any, total: number?, problem: any, calls: number }

local function runChecks(github: Github, shouldContinue: (() -> boolean)?): ChecksOut
	local out: ChecksOut = { runs = nil, total = nil, problem = nil, calls = 0 }
	github.checks("o/r", 5, function(runs, total, problem)
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
	w.kv.put("accounts", { ["github.com/o/r"] = "limited" })
	github.record({ remaining = 0, reset = w.seconds() + 60, limit = 30 }, w.seconds(), "limited")
	local paused = runChecks(github, nil)
	eq(paused.calls, 0, "never synchronous")
	w.flush()
	eq(paused.problem.kind, "rate-limit", "problem kind")
	has(paused.problem.message, "checks resume at", "message")
	eq(#gh.requests, 0, "nothing was sent while paused")
	w.kv.put("accounts", { ["github.com/o/r"] = "fine" })
	gh.tokens.fine = "tok-fine"
	gh.checks["o/r#5"] = nodes(250)
	local cancelled = runChecks(github, function(): boolean
		return false
	end)
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
	end)
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
	github.checks("not-a-repo", 5, function(runs, total, problem)
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
		github.pr("o/r", 5, function(meta, problem, _cx)
			got, why = meta, problem
		end)
		w.flush()
	end
	gh.meta["o/r#5"] = { base = "o/r", sha = string.rep("A", 40), ref = "feature", state = "open" }
	ask()
	eq(got.sha, sha("a"), "lowercased")
	eq(got.base, "o/r", "base")
	gh.meta["o/r#5"] = { base = "o/r", sha = "abc123", ref = "feature", state = "open" }
	ask()
	eq(got, nil, "a short sha is refused")
	has(why.message, "unexpected pull request metadata", "message")
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
local function goToSettings(b: Block, page: string)
	b.typeText("s")
	local turns = (table.find({ "filters", "prompts", "github", "worktrees" }, page) or 1) - 1
	for _ = 1, turns do
		b.press("tab")
	end
	b.press("down")
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
	eq(#s.gh.requests, 0, "nothing is sent before the repository is known")
	eq(pickerOf(b).state, "loading", "the first card is the spinner")
	w.flush()
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 1, "one request covers three PRs")
	has(searches[1].fields.q, "repo:o/r", "the search is scoped to the launch repository")
	has(searches[1].fields.q, "is:open author:@me", "and runs the active filter")
	same(listed(b), { "n1", "n2", "n3" }, "newest update first")
	eq(pickerOf(b).selected, "n1", "the first PR is selected")
	eq(pickerOf(b).state, "ready", "the list is ready")
	has(b.title(), "My PRs", "the title names the filter")
	has(b.title(), "(3)", "and counts the PRs")
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
	same(listed(again), { "n1", "n2", "n3" }, "the loaded list is still there")
	eq(#requestsOf(s.gh, "search"), 1, "and nothing was searched again")
end)

case("host: a launch directory without a GitHub remote searches nothing until Refresh looks again", function(w: World)
	local s = hostScene(w, 3)
	s.git.remotes.origin = { "https://gitlab.com/o/r.git" }
	local b = openQueue(w)
	eq(#s.gh.requests, 0, "no search without a repository")
	eq(pickerOf(b).state, "error", "the card explains it")
	local looked = #w.calls
	w.advance(10 * 60 * 1000)
	eq(#w.calls, looked, "nothing respawns git on its own")
	s.git.remotes.origin = { "https://github.com/o/r.git" }
	b.typeText("r")
	w.flush()
	same(listed(b), { "n1", "n2", "n3" }, "an explicit Refresh looks again and loads")
end)

case("host: a launch directory that is gone starts no process and shows the card", function(w: World)
	w.load("host")
	local b = w.open(1, { "/nowhere" })
	w.flush()
	eq(#w.calls, 0, "no git for a directory that does not exist")
	eq(pickerOf(b).state, "error", "the card says there is no repository")
end)

case("host: Escape clears the search, then closes it, and is left to the pane when there is nothing to cancel", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("/")
	eq(pickerOf(b).query, "", "the search opens empty")
	b.typeText("2")
	same(listed(b), { "n2" }, "the search narrows the list")
	eq(pickerOf(b).selected, "n2", "and the selection follows")
	eq(b.press("escape"), true, "the first Escape is handled")
	eq(pickerOf(b).query, "", "it cleared the text but kept the search open")
	same(listed(b), { "n1", "n2", "n3" }, "the whole list is back")
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
	eq(b.view().layer.c[1].k, "picker", "Escape closes the list, then Settings")
end)

case("host: the documented queue keys move, open, refresh and switch filters", function(w: World)
	local s = hostScene(w, 12)
	local b = openQueue(w)
	b.typeText("j")
	eq(pickerOf(b).selected, "n2", "j moves down")
	b.press("down")
	eq(pickerOf(b).selected, "n3", "Down moves down")
	b.typeText("k")
	eq(pickerOf(b).selected, "n2", "k moves up")
	b.press("home")
	eq(pickerOf(b).selected, "n1", "Home jumps to the first PR")
	b.press("page_down")
	eq(pickerOf(b).selected, "n11", "Page Down jumps ten")
	b.press("page_up")
	eq(pickerOf(b).selected, "n1", "Page Up jumps back ten")
	b.press("end")
	eq(pickerOf(b).selected, "n12", "End jumps to the last PR")
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
	eq(pickerOf(b).scope, "f2", "Down in the filter list switches filter")
	b.typeText("s")
	eq(b.view().main.c[2].k, "prefs", "s opens Settings")
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
	eq(b.view().main.c[2].k, "prefs", "Settings opens the settings page")
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
	goToSettings(b, "filters")
	eq(prefsOf(b).focus, "name:f1", "the first row is focused")
	b.press("enter")
	eq(prefsOf(b).editing.row, "name:f1", "Enter starts the edit")
	b.typeText(" j?")
	eq(prefsOf(b).editing.draft, "My PRs j?", "keys are text while editing")
	eq(b.press("escape"), true, "Escape is handled")
	eq(prefsOf(b).editing, nil, "Escape ends the edit")
	eq(w.kv.get("filters").items[1].name, "My PRs", "nothing was saved")
	b.press("enter")
	b.typeText("!")
	eq(b.press("enter"), true, "Enter is handled")
	eq(prefsOf(b).editing, nil, "Enter ends the edit")
	eq(w.kv.get("filters").items[1].name, "My PRs!", "and saves it")
	has(b.title(), "My PRs!", "the title follows the new name")
	b.press("down")
	b.press("enter")
	b.typeText(" repo:x/y")
	b.press("enter")
	yes(type(rowIn(b, "query:f1").warning) == "string", "the rejected query is explained under its row")
	eq(prefsOf(b).editing.row, "query:f1", "the edit stays open for a correction")
	eq(prefsOf(b).editing.draft, "is:open author:@me repo:x/y", "with the draft")
	eq(w.kv.get("filters").items[1].query, "is:open author:@me", "nothing was saved")
	eq(#requestsOf(s.gh, "search"), 1, "and nothing was searched")
	for _ = 1, 9 do
		b.press("backspace")
	end
	b.typeText(" label:bug")
	b.press("enter")
	eq(rowIn(b, "query:f1").warning, nil, "a saved value clears the warning")
	eq(prefsOf(b).editing, nil, "and closes the edit")
	eq(w.kv.get("filters").items[1].query, "is:open author:@me label:bug", "the correction is saved")
	w.flush()
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 2, "the active filter searches again")
	has(searches[2].fields.q, "label:bug", "with its new query")
end)

case("host: a filter that cannot be written keeps its draft and says why; an unchanged Enter writes nothing", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "filters")
	w.kv.failSet["filters"] = "read-only file system"
	b.press("enter")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "Enter on unchanged text only closes the edit")
	eq(rowIn(b, "name:f1").warning, nil, "without a write, so without a warning")
	b.press("enter")
	b.typeText("2")
	b.press("enter")
	has(rowIn(b, "name:f1").warning, "read-only file system", "a failed write is explained under its row")
	eq(prefsOf(b).editing.draft, "My PRs2", "the draft is kept for another try")
	eq(w.kv.get("filters").items[1].name, "My PRs", "nothing was written")
	w.kv.failSet["filters"] = nil
	b.press("enter")
	eq(rowIn(b, "name:f1").warning, nil, "the retry saved it and cleared the warning")
	eq(w.kv.get("filters").items[1].name, "My PRs2", "the draft was saved")
end)

case("host: a opens the selected PR's agent link", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local n = string.match(pickerOf(b).selected, "%d+") :: string
	local link: any = findKey(pickerNode(b), "agent")
	eq(link.p.href, "plotroom://github/agent/o/r/" .. n, "the card keeps the selected PR's Agent link")
	eq(findKey(pickerNode(b), "buttons").p.hidden, true, "unseen: the action bar has no Agent button")
	b.typeText("a")
	eq(w.opened[#w.opened], "plotroom://github/agent/o/r/" .. n, "a opens it")
end)

case("host: setup commands are added, edited and removed per repository; unreadable ones are never overwritten", function(w: World)
	hostScene(w, 3)
	w.kv.put("setup", { ["github.com/x/y"] = array({ "make" }) })
	local b = openQueue(w)
	goToSettings(b, "worktrees")
	local function save(row: string, text: string)
		b.event({ ev = "select", id = "main.settings", item = row })
		b.press("enter")
		for _ = 1, 40 do
			b.press("backspace")
		end
		b.typeText(text)
		b.press("enter")
	end
	save("setup:new", "pnpm install")
	save("setup:new", "cp ../r/.env .")
	same(w.kv.get("setup")["github.com/o/r"], { "pnpm install", "cp ../r/.env ." }, "added in order under the launch repo")
	same(w.kv.get("setup")["github.com/x/y"], { "make" }, "another repository's commands are kept")
	eq(rowIn(b, "setup:2").control.value, "cp ../r/.env .", "each command is a row")
	save("setup:1", "pnpm i")
	same(w.kv.get("setup")["github.com/o/r"], { "pnpm i", "cp ../r/.env ." }, "edited in place")
	save("setup:1", "")
	same(w.kv.get("setup")["github.com/o/r"], { "cp ../r/.env ." }, "emptying a command removes it")
	eq(prefsOf(b).focus, "setup:new", "focus moves to the add row")
	save("setup:1", "")
	eq(w.kv.get("setup")["github.com/o/r"], nil, "the last one removed drops the repository's entry")
	w.kv.put("setup", "garbage")
	b.render()
	yes(type(rowIn(b, "setup:new").disabled) == "string", "an unreadable map disables the rows")
	eq(w.kv.get("setup"), "garbage", "and is never overwritten")
end)

case("host: unreadable or malformed saved filters are shown as defaults and never overwritten", function(w: World)
	hostScene(w, 3)
	local saved = { version = 1, nextId = 9, items = array({ { id = "f7", name = "Mine", query = "is:open label:x" } }) }
	w.kv.put("filters", saved)
	w.kv.failGet["filters"] = "disk offline"
	local b = openQueue(w)
	same(listed(b), { "n1", "n2", "n3" }, "the queue still works with the default filters")
	has(b.text(), "disk offline", "the cause is on screen")
	goToSettings(b, "filters")
	has(rowIn(b, "name:f1").disabled, "disk offline", "the rows are locked, with the cause")
	eq(b.press("down"), false, "nothing in the page can be focused")
	same(w.kv.get("filters"), saved, "the saved filters were not overwritten")
	w.kv.failGet["filters"] = nil
	w.kv.put("filters", { version = 2 })
	local other = openQueue(w, 2)
	same(listed(other), { "n1", "n2", "n3" }, "malformed filters show the defaults too")
	same(w.kv.get("filters"), { version = 2 }, "and are not overwritten either")
end)

case("host: a first run saves the two default filters, Add creates one, and Delete asks first", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	eq(#w.kv.get("filters").items, 2, "the default filters were saved")
	goToSettings(b, "filters")
	b.event({ ev = "select", id = "main.settings", item = "add" })
	b.press("enter")
	eq(#w.kv.get("filters").items, 3, "Add saved a new filter")
	eq(prefsOf(b).editing.row, "name:f3", "and starts naming it")
	b.press("escape")
	eq(w.kv.get("filters").items[3].name, "New filter", "cancelling the naming keeps the placeholder name")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "the new filter became the active one and was searched")
	has(b.title(), "New filter", "the title shows it")
	b.event({ ev = "select", id = "main.settings", item = "delete:f2" })
	b.press("enter")
	yes(findKey(b.view().layer, "confirm") ~= nil, "Delete asks for confirmation")
	b.press("enter")
	eq(#w.kv.get("filters").items, 3, "Enter keeps the filter")
	eq(b.view().layer, nil, "and closes the question")
	b.press("enter")
	b.typeText("d")
	local items = w.kv.get("filters").items
	eq(#items, 2, "d deletes it")
	eq(items[2].id, "f3", "the other filters stay")
	b.event({ ev = "select", id = "main.settings", item = "delete:f3" })
	b.press("enter")
	b.typeText("d")
	w.flush()
	eq(#w.kv.get("filters").items, 1, "the active filter can be deleted too")
	has(b.title(), "My PRs", "the filter that took its place is shown")
end)

case("host: Tab cycles the Settings pages in order, Filters, Prompts, GitHub, Worktrees, and Shift+Tab goes back", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("s")
	local pages: { string } = { prefsOf(b).page }
	for _ = 1, 4 do
		b.press("tab")
		table.insert(pages, prefsOf(b).page)
	end
	same(pages, { "filters", "prompts", "github", "worktrees", "filters" }, "Tab walks the pages and wraps around")
	b.press("tab", "s")
	eq(prefsOf(b).page, "worktrees", "Shift+Tab goes back, wrapping the other way")
end)

-- The prompt editor card of the Settings view; nil when no prompt's text is being edited.
local function editorCard(b: Block): any
	return findKey(b.view().main, "prompt", "col")
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
	return w.kv.get("prompts").items[index].text
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
	same(w.kv.get("prompts"), { version = 1, nextId = 2, items = array({ promptOf("p1", "New prompt", "") }) }, "Add saves a prompt with no text at once, offered under every filter")
	eq(prefsOf(b).editing.row, "pname:p1", "and starts naming it")
	eq(prefsOf(b).editing.draft, "", "from an empty draft")
	eq(editorCard(b), nil, "the text editor waits for the name")
	eq(caretOf(w), nil, "and the caret has not been moved")
	b.press("enter")
	eq(rowIn(b, "pname:p1").warning, "A name is required.", "an empty name is refused under its row")
	eq(prefsOf(b).editing.row, "pname:p1", "and the name edit stays open")
	eq(w.kv.get("prompts").items[1].name, "New prompt", "with nothing saved")
	b.typeText("Review")
	b.press("enter")
	eq(w.kv.get("prompts").items[1].name, "Review", "Enter saves the name")
	eq(prefsOf(b).editing, nil, "the name edit is over")
	yes(editorCard(b) ~= nil, "and a prompt with no text opens its text editor next")
	eq(editorCard(b).p.role, "omp.prefs.editor", "in the editor card")
	eq(findKey(editorCard(b), "head", "text").p.spans[1].t, "Prompt · Review", "which names the prompt")
	eq(draftOf(b), "", "with nothing in it")
	eq(caretOf(w), "main.settings.prompt.draft", "and the caret in its field")
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
	eq(caretOf(w), "main.settings.prompt.draft", "with the caret in the field")
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
	eq(w.kv.get("prompts").items[1].name, "New prompt", "the name stays what it was")
	yes(editorCard(b) ~= nil, "and the prompt, still with no text, opens its text editor")
	eq(caretOf(w), "main.settings.prompt.draft", "with the caret in its field")
end)

case("host: a prompt's text that is empty or over 8000 bytes stays in the editor with the card's warning; Save and Cancel act like ⌘Enter and Esc", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
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
	eq(caretOf(w), "main.settings.prompt.draft", "and the caret stays in the field")
	b.press("backspace")
	b.press("enter", "m")
	eq(#savedText(w, 1), 8000, "8000 bytes are accepted")
	eq(editorCard(b), nil, "and close the editor")
	local cancel: { [string]: any } = { ev = "action", id = "main.settings.prompt.buttons.cancel", act = "cancel-prompt" }
	local save: { [string]: any } = { ev = "action", id = "main.settings.prompt.buttons.save", act = "save-prompt" }
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

case("host: a prompt's Filters chips keep only filters that exist, and Enter, Right and Space toggle them from the keyboard", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}", { "f1" }) })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	b.press("down")
	b.press("down")
	b.press("down")
	eq(prefsOf(b).focus, "pscope:p1", "the prompt's Filters row")
	local chips: any = rowIn(b, "pscope:p1").control
	same(chips.values, { "f1" }, "the filters it is offered under are on")
	eq(#chips.options, 2, "among all the filters")
	eq(chips.options[2].value, "f2", "by id")
	eq(chips.options[2].label, "Review requested", "and name")
	local function saved(): any
		return w.kv.get("prompts").items[1].filters
	end
	local function changed(values: { any })
		b.event({ ev = "change", id = "main.settings", item = "pscope:p1", value = array(values) })
	end
	changed({ "f2", "gone" })
	same(saved(), { "f2" }, "a change saves only the filters that still exist")
	same(rowIn(b, "pscope:p1").control.values, { "f2" }, "and the row shows them")
	changed({ "f2", "f1" })
	same(saved(), { "f1", "f2" }, "in the filters' order")
	changed({ "gone" })
	same(saved(), array({}), "none left means every filter")
	b.press("enter")
	eq(prefsOf(b).editing.row, "pscope:p1", "Enter starts picking: the chips take the keys")
	eq(prefsOf(b).editing.option, "f1", "at the first filter")
	b.press("right")
	eq(prefsOf(b).editing.option, "f2", "Right moves to the next filter")
	b.press("space")
	same(saved(), { "f2" }, "Space turns it on, saved at once")
	b.press("enter")
	same(saved(), array({}), "Enter turns it off again")
	b.press("right")
	eq(prefsOf(b).editing.option, "f2", "Right stops at the last filter")
	b.press("left")
	b.press("left")
	eq(prefsOf(b).editing.option, "f1", "Left stops at the first")
	b.press("space")
	same(saved(), { "f1" }, "and toggles that one")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc leaves the chips")
	eq(prefsOf(b).page, "prompts", "with Settings still open")
	b.press("space")
	eq(prefsOf(b).editing.option, "f1", "Space starts picking too")
	b.press("down")
	eq(prefsOf(b).editing, nil, "any other key leaves the chips")
	eq(prefsOf(b).focus, "pdelete:p1", "and does what it does")
	same(saved(), { "f1" }, "without changing the filters")
end)

case("host: Delete on a prompt asks first, naming it: d deletes it, Enter keeps it", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	b.event({ ev = "select", id = "main.settings", item = "pdelete:p1" })
	b.press("enter")
	local question: any = findKey(b.view().layer, "confirm")
	yes(question ~= nil, "Delete asks for confirmation")
	eq(question.p.head, "Delete prompt “Review”?", "naming the prompt")
	b.press("enter")
	eq(#w.kv.get("prompts").items, 2, "Enter keeps it")
	eq(b.view().layer, nil, "and closes the question")
	b.press("enter")
	b.typeText("d")
	local items = w.kv.get("prompts").items
	eq(#items, 1, "d deletes it")
	eq(items[1].id, "p2", "the other prompt stays")
	eq(prefsOf(b).focus, "padd", "and the Add row takes the focus")
	b.event({ ev = "action", id = "main.settings", act = "delete", value = "pdelete:p2" })
	eq(findKey(b.view().layer, "confirm").p.head, "Delete prompt “Triage”?", "the Delete button asks the same question")
	b.event({ ev = "action", id = "layer.confirm.buttons.delete", act = "confirm-delete" })
	eq(#w.kv.get("prompts").items, 0, "and the Delete in the question deletes it")
end)

case("host: changing page, closing Settings or being sent to the Worktrees page drops an open text edit and gives the caret back", function(w: World)
	local s = hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	-- Opens Settings on the Prompts page with the prompt's text being edited.
	local function editing()
		goToSettings(b, "prompts")
		b.press("down")
		b.press("enter")
		eq(caretOf(w), "main.settings.prompt.draft", "the text is being edited")
	end
	editing()
	b.event({ ev = "action", id = "main.settings", act = "page", value = "filters" })
	eq(prefsOf(b).page, "filters", "a click on another page leaves the Prompts page")
	eq(editorCard(b), nil, "the editor is gone")
	eq(caretOf(w), "released", "and the caret is given back")
	b.press("tab")
	eq(prefsOf(b).page, "prompts", "back on the Prompts page")
	eq(editorCard(b), nil, "the edit did not come back")
	b.press("escape")
	editing()
	b.event({ ev = "action", id = "main.settings", act = "close" })
	yes(b.view().layer ~= nil and b.view().layer.c[1].k == "picker", "closing Settings shows the queue")
	eq(caretOf(w), "released", "and gives the caret back")
	b.typeText("s")
	eq(editorCard(b), nil, "reopened Settings has no edit")
	b.press("escape")
	editing()
	s.git.remotes.origin = { "https://github.com/x/y.git" }
	request(b, "w1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(answerOf(b, "w1").noRepo, true, "a worktree for a repository with no local checkout")
	eq(prefsOf(b).page, "worktrees", "reopens Settings on the Worktrees page")
	eq(prefsOf(b).editing.row, "checkout", "to enter the checkout")
	eq(editorCard(b), nil, "the text edit that was open is gone")
	eq(caretOf(w), "released", "and the caret is given back")
end)

case("host: deleting a prompt drops an edit of its own name or text and leaves the edit of another prompt alone", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	-- Deletes prompt `id` with the mouse: the keys cannot while an edit is open.
	local function click(id: string)
		b.event({ ev = "action", id = "main.settings", act = "delete", value = "pdelete:" .. id })
		b.event({ ev = "action", id = "layer.confirm.buttons.delete", act = "confirm-delete" })
	end
	b.event({ ev = "select", id = "main.settings", item = "ptext:p2" })
	b.press("enter")
	eq(draftOf(b), "Triage {url}", "the text of the second prompt is being edited")
	click("p1")
	eq(#w.kv.get("prompts").items, 1, "the first prompt is deleted")
	eq(draftOf(b), "Triage {url}", "the edit of the other prompt goes on")
	eq(caretOf(w), "main.settings.prompt.draft", "with the caret where it was")
	click("p2")
	eq(#w.kv.get("prompts").items, 0, "the prompt being edited is deleted")
	eq(editorCard(b), nil, "its editor goes with it")
	eq(caretOf(w), "released", "and the caret is given back")
	savePrompts(w, { promptOf("p3", "Plan", "Plan {url}") })
	b.event({ ev = "select", id = "main.settings", item = "pname:p3" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "pname:p3", "the name of another prompt is being edited")
	click("p3")
	eq(#w.kv.get("prompts").items, 0, "it is deleted")
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
		local stored = w.kv.store.prompts
		has(rowIn(b, "padd").disabled, why, what .. ": Add is locked, with the reason")
		b.event({ ev = "action", id = "main.settings", act = "add-prompt", value = "padd" })
		b.event({ ev = "change", id = "main.settings", item = "pscope:p1", value = array({ "f1" }) })
		b.event({ ev = "action", id = "main.settings", act = "delete", value = "pdelete:p1" })
		b.press("d")
		eq(w.kv.store.prompts, stored, what .. ": nothing was written over it")
		asked += 1
		request(b, "m" .. asked, { op = "menu" })
		local answer = answerOf(b, "m" .. asked)
		eq(#answer.items, 0, what .. ": the menu lists no prompts")
		has(answer.problem, why, what .. ": and says why")
	end
	local malformed: { any } = {
		"garbage",
		{ version = 2, nextId = 1, items = array({}) },
		{ version = 1, nextId = 2, items = array({ { id = "p1", name = "Review", filters = array({}) } }) },
		{ version = 1, nextId = 2, items = array({ { id = "p1", name = "Review", text = "Review {url}", filters = array({}), key = 5 } }) },
	}
	for i, value in malformed do
		w.kv.put("prompts", value)
		locked("malformed value " .. i, "malformed")
	end
	w.kv.put("prompts", { version = 1, nextId = 2, items = array({ promptOf("p1", "Review", "Review {url}") }) })
	w.kv.failGet["prompts"] = "disk offline"
	locked("an unreadable store", "disk offline")
	w.kv.failGet["prompts"] = nil
	b.render()
	eq(rowIn(b, "padd").disabled, nil, "a readable store unlocks Add")
	request(b, "m9", { op = "menu" })
	local answer = answerOf(b, "m9")
	eq(answer.problem, nil, "and the menu has no problem")
	eq(#answer.items, 1, "but the prompt")
end)

case("host: the agent menu offers the prompts of the active filter first, then those of every filter, and swaps with the filter", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", { "f1" }),
		promptOf("p2", "Anywhere", "Look at {url}\nTwice"),
		promptOf("p3", "Theirs", "Only for review requests", { "f2" }),
		promptOf("p4", "Blank", ""),
		promptOf("p5", "Gone", "Gone {url}", { "f9" }),
		promptOf("p6", "Both", "Both", { "f1", "f2" }),
	})
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
		{ id = "p1", label = "Mine", detail = "Review {url}", group = "For My PRs", send = "Review {url}" },
		{ id = "p6", label = "Both", detail = "Both", group = "For My PRs", send = "Both" },
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "All filters", send = "Look at {url}\nTwice" },
		{ id = "p5", label = "Gone", detail = "Gone {url}", group = "All filters", send = "Gone {url}" },
	}, "under My PRs its own prompts come first, then those of every filter, one scoped to a deleted filter among them; the prompt for Review requested and the one with no text are left out")
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "f2", "the second filter is active")
	same(menu().items, {
		{ id = "p3", label = "Theirs", detail = "Only for review requests", group = "For Review requested", send = "Only for review requests" },
		{ id = "p6", label = "Both", detail = "Both", group = "For Review requested", send = "Both" },
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "All filters", send = "Look at {url}\nTwice" },
		{ id = "p5", label = "Gone", detail = "Gone {url}", group = "All filters", send = "Gone {url}" },
	}, "under Review requested the prompts swap")
end)

case("host: the menu asked for one prompt answers just that one, if it is offered, however many are saved", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", { "f1" }),
		promptOf("p2", "Anywhere", "Look at {url}"),
		promptOf("p3", "Theirs", "Only for review requests", { "f2" }),
		promptOf("p4", "Blank", ""),
	})
	local b = openQueue(w)
	local asked = 0
	-- The rows the block answers a menu request that names prompt `id`.
	local function only(id: string): { any }
		asked += 1
		request(b, "o" .. asked, { op = "menu", only = id })
		return answerOf(b, "o" .. asked).items
	end
	same(only("p2"), { { id = "p2", label = "Anywhere", detail = "Look at {url}", group = "All filters", send = "Look at {url}" } }, "just the prompt asked for")
	same(only("p1"), { { id = "p1", label = "Mine", detail = "Review {url}", group = "For My PRs", send = "Review {url}" } }, "in the group it has under the filter")
	eq(#only("p3"), 0, "none that the filter does not offer")
	eq(#only("p4"), 0, "none with no text")
	eq(#only("p9"), 0, "none that is not saved")
end)

case("host: the picker's action bar has Settings and Refresh on the left, then the PR's Worktree, Go to tab and one button per offered prompt by Open; each opens the link the card keeps unseen", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", { "f1" }, "m"),
		promptOf("p2", "Anywhere", "Look at {url}\nTwice"),
		promptOf("p3", "Theirs", "Only for review requests", { "f2" }, "x"),
		promptOf("p4", "Blank", "", {}, "b"),
		promptOf("p-5", "Dashed", "Its id cannot be part of a link", {}, "d"),
	})
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
	same(bar(), { "settings", "retry", "worktree", "prompt-p1", "prompt-p2", "open" }, "under My PRs its own prompt, then the one of every filter; none for another filter's prompt, a blank one or one whose id is no link; Open last")
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
	same(bar(), { "settings", "retry", "worktree", "prompt-p3", "prompt-p2", "open" }, "under Review requested the prompt buttons swap")
	savePrompts(w, { promptOf("p1", "Mine", "Review {url}", { "f1" }, "m") })
	b.render()
	same(bar(), { "settings", "retry", "worktree", "open" }, "with none offered the bar has no prompt button")
end)

case("host: a prompt's key opens its run link for the selected pull request, but not while searching, under a filter that does not offer it, or with ctrl, alt or meta", function(w: World)
	local s = hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", { "f1" }, "m"),
		promptOf("p2", "Anywhere", "Look at {url}", {}, "T"),
		promptOf("p3", "Theirs", "Only for review requests", { "f2" }, "x"),
		promptOf("p4", "Hand edited", "The queue's own key wins", {}, "w"),
	})
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
	ignored("a prompt of another filter", "x")
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
	eq(pickerOf(b).scope, "f2", "under the second filter")
	ignored("a prompt of the first filter", "m")
	local n = tonumber(string.match(pickerOf(b).selected, "%d+")) :: number
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
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}", {}, "t") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	local ids: { string } = {}
	for _, row in prefsOf(b).sections[1].rows do
		table.insert(ids, row.id)
	end
	same(ids, { "pname:p1", "ptext:p1", "pkey:p1", "pscope:p1", "pdelete:p1" }, "a prompt has its name, text, shortcut, filters and Delete, in that order")
	local row = rowIn(b, "pkey:p1")
	eq(row.label, "Shortcut", "the row is the Shortcut")
	eq(row.control.value, "", "empty while the prompt has none")
	eq(row.control.placeholder, "None", "which it says")
	b.event({ ev = "select", id = "main.settings", item = "pkey:p1" })
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
	eq(w.kv.get("prompts").items[1].key, nil, "nothing was saved")
	eq(try("m"), nil, "a free key is accepted")
	eq(prefsOf(b).editing, nil, "and closes the edit")
	same(w.kv.get("prompts").items[1], { id = "p1", name = "Review", text = "Review {url}", filters = array({}), key = "m" }, "it is saved as the prompt's key, the rest as it was")
	eq(w.kv.get("prompts").items[2].key, "t", "another prompt keeps its key")
	eq(rowIn(b, "pkey:p1").control.value, "m", "the row shows it")
	eq(try("A"), nil, "a capital is not the queue's a")
	eq(w.kv.get("prompts").items[1].key, "A", "and is saved as typed")
	eq(try("é"), nil, "one character is one key, whatever its bytes")
	eq(w.kv.get("prompts").items[1].key, "é", "and is saved")
	eq(try(""), nil, "an empty shortcut is accepted")
	eq(w.kv.get("prompts").items[1].key, nil, "and removes the key")
	eq(rowIn(b, "pkey:p1").control.value, "", "which the row shows")
end)

case("host: ? adds a row for each prompt offered under the filter that has a key, in the queue only", function(w: World)
	hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", { "f1" }, "m"),
		promptOf("p2", "Quiet", "Has no key {url}"),
		promptOf("p3", "Theirs", "Only for review requests", { "f2" }, "x"),
		promptOf("p4", "Blank", "", {}, "b"),
		promptOf("p5", "Anywhere", "Look at {url}", {}, "T"),
	})
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
	}, "each prompt offered under My PRs that has a key, in the menu's order; none without a key, with no text or for another filter")
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

case("host: a checkout git does not confirm keeps its draft; a real one is saved only after git confirms it", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "worktrees")
	eq(prefsOf(b).focus, "checkout", "the checkout row is focused")
	b.press("enter")
	b.typeText("/elsewhere")
	b.press("enter")
	w.flush()
	yes(type(rowIn(b, "checkout").warning) == "string", "git's refusal is shown under the row")
	eq(prefsOf(b).editing.draft, "/elsewhere", "the draft stays for a correction")
	eq(w.kv.get("repos"), nil, "nothing was saved")
	w.kv.failGet["repos"] = "disk offline"
	b.press("a", "c")
	b.typeText("/work/r")
	b.press("enter")
	w.flush()
	yes(type(rowIn(b, "checkout").warning) == "string", "an unreadable checkout map is refused")
	eq(prefsOf(b).editing.draft, "/work/r", "with the draft kept")
	eq(w.kv.get("repos"), nil, "and nothing written over it")
	w.kv.failGet["repos"] = nil
	b.press("enter")
	w.flush()
	eq(w.kv.get("repos")["github.com/o/r"], "/work/r", "the confirmed checkout is saved")
	eq(w.toasts[#w.toasts].level, "success", "and reported")
	eq(prefsOf(b).editing, nil, "the edit is closed")
	eq(rowIn(b, "checkout").warning, nil, "without a warning")
end)

case("host: a checkout refusal that arrives late stays inline on the Worktrees page and is a toast anywhere else", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	-- git answers about /elsewhere only after five seconds
	w.respond(function(call: Call): Reply?
		if call.argv[1] == "git" and call.argv[3] == "/elsewhere" then
			return { status = 128, stderr = "fatal: cannot change to '/elsewhere': No such file or directory\n", delay = 5000 }
		end
		return nil
	end)
	local function submit()
		b.press("enter")
		b.typeText("/elsewhere")
		b.press("enter")
		eq(prefsOf(b).editing, nil, "the edit closes while git checks the path")
	end
	goToSettings(b, "worktrees")
	submit()
	w.advance(5000)
	has(rowIn(b, "checkout").warning, "No such file or directory", "on the Worktrees page git's refusal is shown under the row")
	eq(prefsOf(b).editing.draft, "/elsewhere", "with the draft kept for a correction")
	eq(#w.toasts, 0, "and no toast")
	b.press("escape")
	submit()
	b.press("tab")
	eq(prefsOf(b).page, "filters", "the user moved on while git was checking")
	w.advance(5000)
	eq(#w.toasts, 1, "the refusal is reported once")
	eq(w.toasts[1].level, "error", "as an error")
	eq(w.toasts[1].text, "Checkout not saved", "that says what happened")
	has(w.toasts[1].sub, "No such file or directory", "with git's reason")
	eq(prefsOf(b).page, "filters", "the page the user is on is left alone")
	for _ = 1, 3 do -- Filters, Prompts, GitHub, Worktrees
		b.press("tab")
	end
	b.press("down")
	eq(prefsOf(b).focus, "checkout", "back on the Worktrees page")
	submit()
	b.press("escape")
	w.advance(5000)
	eq(#w.toasts, 2, "closing Settings meanwhile reports it as well")
	eq(w.toasts[2].text, "Checkout not saved", "with the same toast")
	goToSettings(b, "worktrees")
	submit()
	for _ = 1, 4 do
		b.press("tab")
	end
	eq(prefsOf(b).page, "worktrees", "a user who is back on the page before git answers")
	w.advance(5000)
	has(rowIn(b, "checkout").warning, "No such file or directory", "sees the refusal under its row")
	eq(prefsOf(b).editing.draft, "/elsewhere", "with the draft")
	eq(#w.toasts, 2, "and no extra toast")
	eq(w.kv.get("repos"), nil, "nothing was ever saved")
end)

case("host: switching filters searches the new query, reuses a fresh cached list, and never waits for a superseded request", function(w: World)
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
	scope("f2")
	w.flush()
	same(listed(b), { "n21", "n22" }, "the second filter shows its own results")
	eq(#requestsOf(s.gh, "search"), 2, "it was searched")
	scope("f1")
	same(listed(b), { "n1", "n2", "n3" }, "going back shows the cached list at once")
	scope("f1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "a fresh cached list and re-selecting the active filter cost nothing")
	slow = true
	second = { searchItem(23, "o/r", EPOCH - 5) }
	b.typeText("r")
	scope("f2")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 4, "the switch sent its own search while the slow one is still pending")
	same(listed(b), { "n23" }, "the switch showed the new answer without waiting for the slow search")
	w.advance(5000)
	same(listed(b), { "n23" }, "and the superseded answer never replaces it")
	eq(pickerOf(b).scope, "f2", "the second filter is still the one shown")
end)

case("host: a rejected query pauses only itself: no automatic retry, and another filter still loads", function(w: World)
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
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "f2" })
	w.flush()
	same(listed(b), { "n1", "n2", "n3" }, "another filter loads")
	eq(pickerOf(b).state, "ready", "without the first filter's card")
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "f1" })
	w.flush()
	eq(#requestsOf(s.gh, "search"), sent + 2, "going back asks again instead of trusting the old rejection")
	eq(pickerOf(b).state, "error", "and it is rejected again")
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
	same(listed(b), { "n1", "n2", "n3" }, "and loads")
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
	local calls = #w.calls
	local again = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(#w.calls, calls, "a restored block starts no process while the pause stands")
	eq(pickerOf(again).state, "error", "and shows the same card")
	signedIn = true
	again.typeText("r")
	w.flush()
	same(listed(again), { "n1", "n2", "n3" }, "Refresh tries again and loads")
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
	same(listed(b), { "n1", "n2", "n3" }, "the one search lands")
	eq(#requestsOf(s.gh, "search"), 1, "once")
end)

case("host: a filter change in one block reaches the other live blocks, and a closed pane is skipped", function(w: World)
	local s = hostScene(w, 3)
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "each block searches for itself")
	goToSettings(a, "filters")
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
	same(listed(c), { "n1", "n2", "n3" }, "the other block still lists the PRs")
	c.close()
	local drawn = c.renders()
	a.press("enter")
	a.typeText(" -label:wip")
	a.press("enter")
	eq(#requestsOf(s.gh, "search"), 5, "a closed pane is not searched for")
	eq(c.renders(), drawn, "and not drawn")
end)

case("host: saving a repository's account reaches every block: the old account's data goes and nothing runs as it", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30), searchItem(8, "o/r", EPOCH - 90) }
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	w.flush()
	same(listed(a), { "n1", "n2", "n3" }, "the active gh account's PRs")
	local before = #s.gh.requests
	goToSettings(a, "github")
	a.press("enter")
	a.typeText("work")
	a.press("enter")
	eq(w.toasts[1].level, "success", "the account was saved")
	same(w.kv.get("accounts"), { ["github.com/o/r"] = "work" }, "for this repository")
	a.press("escape")
	w.flush()
	same(listed(a), { "n7", "n8" }, "this block shows the new account's PRs")
	same(listed(c), { "n7", "n8" }, "and so does the other one")
	for i = before + 1, #s.gh.requests do
		eq(s.gh.requests[i].login, "work", "request " .. i .. " ran as the new account")
	end
	eq(#requestsOf(s.gh, "search"), 4, "each block searched once more")
	before = #s.gh.requests
	goToSettings(a, "github")
	a.press("enter")
	a.press("a", "c")
	a.press("backspace")
	a.press("enter")
	a.press("escape")
	w.flush()
	same(w.kv.get("accounts"), {}, "clearing the account removes only this repository's entry")
	same(listed(a), { "n1", "n2", "n3" }, "this block is back on the active gh account")
	same(listed(c), { "n1", "n2", "n3" }, "and so is the other one")
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
	goToSettings(b, "github")
	b.press("enter")
	b.typeText("work")
	b.press("enter")
	b.press("escape")
	w.flush()
	same(listed(b), { "n7" }, "the new account's list is shown")
	w.advance(5000)
	same(listed(b), { "n7" }, "the old account's late answer is dropped")
	eq(#requestsOf(s.gh, "search"), 2, "one search per account")
end)

case("host: an unreadable or malformed saved account stops every request, and an explicit Refresh recovers", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	w.kv.put("accounts", { ["github.com/o/r"] = "work" })
	w.kv.failGet["accounts"] = "disk offline"
	local a = openQueue(w, 1)
	eq(pickerOf(a).state, "error", "an unreadable store shows the card")
	has(a.text(), "disk offline", "with the cause")
	w.kv.failGet["accounts"] = nil
	w.kv.put("accounts", { ["github.com/o/r"] = "bad name" })
	eq(pickerOf(openQueue(w, 2)).state, "error", "a damaged entry shows the card too")
	w.kv.put("accounts", "oops")
	eq(pickerOf(openQueue(w, 3)).state, "error", "and so does a malformed store")
	w.advance(30 * 60 * 1000)
	eq(#s.gh.requests, 0, "nothing was ever sent, not even a token request")
	w.kv.put("accounts", { ["github.com/o/r"] = "work" })
	a.typeText("r")
	w.flush()
	same(listed(a), { "n7" }, "Refresh recovers once the store is readable")
	eq(s.gh.requests[1].kind, "token", "the first thing sent is the account's token request")
end)

case("host: an account that becomes unreadable under a loaded block takes its data off the screen", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	same(listed(b), { "n1", "n2", "n3" }, "loaded")
	local before = #s.gh.requests
	w.kv.failGet["accounts"] = "disk offline"
	w.advance(60000)
	same(listed(b), {}, "nothing of the old identity stays on screen")
	eq(pickerOf(b).state, "error", "the card says why")
	eq(#s.gh.requests, before, "and nothing was sent")
	w.kv.failGet["accounts"] = nil
	b.typeText("r")
	w.flush()
	same(listed(b), { "n1", "n2", "n3" }, "Refresh loads again once it is readable")
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
	goToSettings(b, "github")
	b.press("enter")
	b.typeText("work")
	b.press("enter")
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

case("host: selecting and activating rows follows the picker, and a row that is gone is ignored", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.event({ ev = "select", id = "layer.queue", item = "n2" })
	eq(pickerOf(b).selected, "n2", "selecting a row moves the selection")
	b.event({ ev = "activate", id = "layer.queue", item = "n3" })
	eq(pickerOf(b).selected, "n3", "activating a row selects it")
	eq(w.opened[#w.opened], prLink("open", "o/r", 3), "and opens it in a Browser block")
	b.event({ ev = "select", id = "layer.queue", item = "n99" })
	eq(pickerOf(b).selected, "n3", "a row that a refresh removed is ignored")
	b.event({ ev = "select", id = "somewhere.else", item = "n1" })
	eq(pickerOf(b).selected, "n3", "and so is an event for another surface")
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
	same(answerOf(b, "m1").items, { { id = "p1", label = "Review", detail = "Review {url}", group = "All filters", send = "Review {url}\nthen report" } }, "a well-formed request is answered with the saved prompts")
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
