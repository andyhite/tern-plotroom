--!strict
-- Regression cases: the fake SDK (harness.luau) is as strict as the pinned SDK, so a case or module never passes on
-- behavior the real Tern raises on.

local h = require("../harness")

type Call = h.Call
type Reply = h.Reply
type World = h.World

local case, windowCase, eq, has, same, yes = h.case, h.windowCase, h.eq, h.has, h.same, h.yes

local function raised(fn: () -> ()): string
	local results = { pcall(fn) }
	yes(results[1] == false, "the call raises")
	return tostring(results[2])
end

case("fake sdk: fs.list and fs.remove raise on a missing path, and list on a file", function(w: World)
	local fs = w.tern.fs
	fs.mkdir("/data/dir")
	fs.write("/data/dir/a.txt", "a")
	same(fs.list("/data/dir"), { "a.txt" }, "a directory lists its entries")
	has(raised(function()
		fs.list("/data/missing")
	end), "No such file or directory", "list of a missing directory")
	has(raised(function()
		fs.list("/data/dir/a.txt")
	end), "Not a directory", "list of a file")
	has(raised(function()
		fs.remove("/data/missing")
	end), "No such file or directory", "remove of a missing path")
	fs.remove("/data/dir")
	yes(not fs.exists("/data/dir/a.txt"), "remove still takes a directory with its files")
end)

case("fake sdk: process.run raises on a non-string argv entry and on an option outside cwd/env/stdin/timeout_ms", function(w: World)
	local run: any = w.tern.process.run
	local function noop() end
	has(raised(function()
		local bad: { any } = { "git", 5 }
		run(bad, noop)
	end), "argv[2] is a number", "a number argv entry")
	has(raised(function()
		run({ "git" }, { timeout = 10 }, noop)
	end), "unknown option timeout", "a mistyped option key")
	has(raised(function()
		run({}, noop)
	end), "non-empty array", "an empty argv")
	eq(#w.calls, 0, "none of them spawned")
end)

case("fake sdk: process.run without a callback returns an Awaitable that delivers the result to next", function(w: World)
	w.respond(function(_call: Call): Reply?
		return { stdout = "out", delay = 5 }
	end)
	local run: any = w.tern.process.run
	local pending: any = run({ "git", "status" }, { cwd = "/r" })
	eq(#w.calls, 1, "the process starts before run returns")
	local got: any = nil
	pending:next(function(result: any)
		got = result
	end)
	yes(got == nil, "nothing is delivered before the process ends")
	w.advance(5)
	eq(got.stdout, "out", "the result arrives at next")
end)

case("fake sdk: a member of the SDK the fake does not model fails loudly", function(w: World)
	has(raised(function()
		w.tern.sleep(1)
	end), "the fake tern has no sleep", "tern.sleep")
end)

windowCase("fake sdk: w.command from the palette cannot reach a command the palette hides; by action name it runs", function(w: World)
	w.load("window")
	w.command("focus") -- hidden from the palette, runnable by its action name (a key bind)
	has(raised(function()
		w.command("focus", true)
	end), "not in Tern's palette", "a palette pick of the hidden command")
end)

return {}
