--!strict
-- Regression cases: selftest, process discovery and text input.

local h = require("../harness")

type Call = h.Call
type Reply = h.Reply
type World = h.World

local case, eq, has, keyOf, same, yes = h.case, h.eq, h.has, h.keyOf, h.same, h.yes

type Input = typeof(require("../../input"))
type Process = typeof(require("../../process"))
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

return {}
