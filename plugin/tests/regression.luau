--!strict
-- Behavioral regression suite. scripts/check.py wraps every plugin module as function(tern, require, os) and calls
-- `run` (or `bench`). Each case file in tests/cases registers its cases with the harness when required; each case
-- builds a fresh fake world (see harness.luau), loads the real modules into it and checks outcomes.

local M = {}

local h = require("./harness")
require("./cases/basics")
require("./cases/worktree")
require("./cases/window")
require("./cases/tracker")
require("./cases/queue")
require("./cases/checks")
require("./cases/issues")
require("./cases/mutation")
require("./cases/flows")
require("./cases/inbox")

type Loader = h.Loader

local EPOCH, array, cases, hostScene, jsonEncode, newWorld = h.EPOCH, h.array, h.cases, h.hostScene, h.jsonEncode, h.newWorld
local openQueue, pickerOf, searchItem = h.openQueue, h.pickerOf, h.searchItem

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
	-- 1000 seen items in a cached view: the sidebar's counts read snooze state without hashing each of them.
	local seen: { [string]: any } = {}
	for i = 1, 1000 do
		seen["o/r#" .. i] = { seen = "x", at = EPOCH }
	end
	w.kv.put("triage", { version = 1, items = seen })
	b.state().triage = nil -- the block rereads the store
	timed("seen-render", 20, function(_i: number)
		b.render()
	end)
	-- The rows rebuild (rev bump) over 1000 seen items: each is classified without rehashing its signature.
	timed("seen-rebuild", 20, function(_i: number)
		b.state().rev += 1
		b.render()
	end)
	-- The attention filter rebuilds the list on every cursor step.
	b.typeText("n")
	timed("attention-cursor-down", 20, function(_i: number)
		b.press("down")
	end)
	b.typeText("n")
	-- A scan builds what each of the 1000 items' worktree is known by: formats and Jira map are read once, not per item.
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	timed("scan", 5, function(_i: number)
		b.state().scanned = nil
		b.render()
		w.flush()
	end)
	print(string.format("BENCH payload bytes=%d items=%d", #payload, #shown))
end

return M
