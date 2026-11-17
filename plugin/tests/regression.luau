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
require("./cases/setup")
require("./cases/preview")
require("./cases/summary")
require("./cases/failures")
require("./cases/arrive")
require("./cases/review")
require("./cases/layout")
require("./cases/extension")
require("./cases/fake")

type Loader = h.Loader

local EPOCH, array, cases, hostScene, jsonEncode, newWorld = h.EPOCH, h.array, h.cases, h.hostScene, h.jsonEncode, h.newWorld
local findKey, openQueue, pickerNode, pickerOf, searchItem = h.findKey, h.openQueue, h.pickerNode, h.pickerOf, h.searchItem

-- `filter` runs only the cases whose name contains that plain substring; `verbose` prints `RUN <name>` before each case,
-- so a case that never returns is the last RUN line (scripts/check.py test -k <substring> -v).
function M.run(instantiate: Loader, filter: string?, verbose: boolean?)
	local failed, ran = 0, 0
	for _, c in cases do
		if filter == nil or filter == "" or string.find(c.name, filter, 1, true) then
			ran += 1
			if verbose then
				print("RUN " .. c.name)
			end
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
	end
	if ran == 0 then
		error(string.format("no regression case name contains %q (of %d cases)", filter or "", #cases), 0)
	end
	print(string.format("REGRESSION cases=%d failed=%d", ran, failed))
	if failed > 0 then
		error(failed .. " regression case(s) failed", 0)
	end
end

-- Prints `BENCH <name> ms=<n>` per measured step of the real queue view with 1000 loaded PRs, the median of three
-- samples (each the mean over its rounds); scripts/check.py fails the gate when a row is slower than its budget.
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
	h.newAcli(w) -- Now reads Jira's assigned work too
	local b = openQueue(w)
	local shown: any = pickerOf(b).items
	if #shown ~= 1000 then
		error("the benchmark expected 1000 loaded pull requests, got " .. #shown, 0)
	end
	local function timed(name: string, rounds: number, step: (number) -> (), samples: number?)
		local means: { number } = {}
		for _ = 1, samples or 3 do
			local started = os.clock()
			for i = 1, rounds do
				step(i)
			end
			table.insert(means, (os.clock() - started) * 1000 / rounds)
		end
		table.sort(means)
		print(string.format("BENCH %s ms=%.2f rounds=%d", name, means[(#means + 1) // 2], rounds))
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
	end, 1) -- one sample: each round types its own character
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
	-- Now over 1000 of your pull requests that are also review requests: its rows are built once per answer, not per step.
	b.event({ ev = "action", act = "open-now" })
	w.flush()
	if #pickerOf(b).items < 1000 then
		error("the benchmark expected Now to list 1000 items, got " .. #pickerOf(b).items, 0)
	end
	timed("now-cursor-down", 20, function(_i: number)
		b.press("down")
	end)
	timed("now-render", 20, function(_i: number)
		b.render()
	end)
	-- Now as a Board over the same 1000 rows: drawn, moved in a column and across, and rebuilt (rows regrouped, as a
	-- search keystroke on a view's Board would) each step.
	b.event({ ev = "action", act = "queue", value = "layout" })
	w.flush()
	if not findKey(pickerNode(b), "board", "col") then
		error("the benchmark expected Now's Board", 0)
	end
	timed("now-board-render", 20, function(_i: number)
		b.render()
	end)
	timed("now-board-down", 20, function(_i: number)
		b.press("down")
	end)
	timed("now-board-across", 20, function(i: number)
		b.press(if i % 2 == 0 then "left" else "right")
	end)
	timed("now-board-rebuild", 20, function(_i: number)
		b.state().rev += 1
		b.render()
	end)
	local boardPayload = jsonEncode(b.view())
	print(string.format("BENCH payload-board bytes=%d items=%d", #boardPayload, #b.state().now.rows))
	b.event({ ev = "action", act = "queue", value = "layout" })
	b.event({ ev = "action", act = "queue", value = "scope:prs:v1" })
	w.flush()
	-- The view as a Board over its 1000 items: drawn, moved in a column, and regrouped (a search keystroke or refresh).
	b.event({ ev = "action", act = "queue", value = "layout" })
	w.flush()
	if not findKey(pickerNode(b), "board", "col") then
		error("the benchmark expected the view's Board", 0)
	end
	timed("view-board-render", 20, function(_i: number)
		b.render()
	end)
	timed("view-board-down", 20, function(_i: number)
		b.press("down")
	end)
	timed("view-board-rebuild", 20, function(_i: number)
		b.state().rev += 1
		b.state().vis = nil
		b.render()
	end)
	print(string.format("BENCH payload-view-board bytes=%d items=%d", #jsonEncode(b.view()), #b.state().snap.items))
	b.event({ ev = "action", act = "queue", value = "layout" })
	w.flush()
	-- A scan builds what each of the 1000 items' worktree is known by: formats and Jira map are read once, not per item.
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	timed("scan", 5, function(_i: number)
		b.state().scanned = nil
		b.render()
		w.flush()
	end)
	-- The run log's index at its cap: what an agent's turn end, the merge sweep and the usage report read (files untouched).
	local usage: any = w.load("usage")
	local index: { any } = {}
	for i = 1, usage.RUNS_CAP do
		table.insert(index, { id = string.format("%d-%06x", EPOCH - i * 600, i), key = "o/r#" .. i % 50, action = if i % 2 == 0 then "Implement" else "Review", started = EPOCH - i * 600 - 300, ended = EPOCH - i * 600, result = "done", commit = string.rep("a", 40), outcome = "pr", verdict = "verified", login = "octocat", ghRepo = "o/r", number = i, branch = "fix-" .. i, depth = i % 3 })
	end
	w.kv.put("runs", array(index))
	timed("runs-index", 20, function(_i: number)
		usage.medians(usage.readRuns())
	end)
	-- Five views of 1000 items each, every one with a cached list, in a block wide enough to show the sidebar's counts:
	-- a render counts each view's items once per revision and minute, not once per render.
	local wide = newWorld(instantiate, "host")
	wide.setEncodeViews(false)
	local scene = hostScene(wide, 0)
	scene.gh.items.octocat = items
	local views: { any } = {}
	for i = 1, 5 do
		table.insert(views, { id = "v" .. i, name = "View " .. i, integration = "github", query = "is:open label:l" .. i, group = "none", prompts = array({}) })
	end
	wide.kv.put("views-prs", { version = 1, nextId = 6, items = array(views) })
	local snoozes: { [string]: any } = {}
	for i = 1, 1000 do
		snoozes["o/r#" .. i] = if i % 2 == 0 then { at = EPOCH, snoozeUntil = EPOCH + 86400 } else { seen = "x", at = EPOCH }
	end
	wide.kv.put("triage", { version = 1, items = snoozes })
	local many = openQueue(wide)
	for i = 2, 5 do
		many.event({ ev = "action", id = "layer.queue", act = "scope", value = "prs:v" .. i })
		wide.flush()
	end
	for i = 1, 5 do
		local count: any = nil
		for _, scope in pickerOf(many).scopes do
			if scope.id == "prs:v" .. i then
				count = scope.count
			end
		end
		if count ~= 500 then
			error("the benchmark expected view " .. i .. " to count 500 unsnoozed items, got " .. tostring(count), 0)
		end
	end
	timed("views-render", 20, function(_i: number)
		many.render()
	end)
	-- Settings over those views: a key press moves the focus and renders the sheet, which builds its page once.
	h.goToSettings(many, "views")
	timed("settings-key", 20, function(i: number)
		many.press(if i % 2 == 0 then "up" else "down")
	end)
	print(string.format("BENCH payload bytes=%d items=%d", #payload, #shown))
end

return M
