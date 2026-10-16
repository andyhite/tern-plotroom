--!strict
-- Assertions over the Worktrees board model with a fake backend api. No git.

local board = require("../board")

local M = {}

local function entry(path: string, extra: { [string]: any }?): board.Entry
	local e: { [string]: any } = {
		path = path,
		root = "/m",
		branch = "b-" .. path,
		main = false,
		detached = false,
		locked = false,
		prunable = false,
		missing = false,
	}
	local over: { [string]: any } = extra or {}
	for k, v in over do
		e[k] = v
	end
	return e :: any
end

type Fake = { api: board.Api, calls: { string }, max: number, dirty: { [string]: boolean }, removed: { string } }

local function fake(inv: { [string]: { board.Entry } }): Fake
	local f: Fake = { api = nil :: any, calls = {}, max = 0, dirty = {}, removed = {} }
	local busy = 0
	local function enter(name: string)
		busy += 1
		f.max = math.max(f.max, busy)
		table.insert(f.calls, name)
	end
	f.api = {
		inventory = function(checkout, repo, done)
			enter("inv:" .. repo)
			local r = inv[checkout]
			busy -= 1
			if r then
				done(r, nil)
			else
				done(nil, "boom")
			end
		end,
		inventoryDirty = function(_, _, path, _, done)
			enter("dirty:" .. path)
			busy -= 1
			done(f.dirty[path] == true, nil)
		end,
		removeEntry = function(_, _, path, _, done)
			enter("rm:" .. path)
			busy -= 1
			table.insert(f.removed, path)
			done({ branch = "deleted" }, nil, nil)
		end,
	}
	return f
end

local function yes(): boolean
	return true
end

local function loaded(f: Fake, cks: { [string]: string }): board.Board
	local b = board.new()
	local n = 0
	board.load(b, f.api, cks, yes, function()
		n += 1
	end)
	assert(n == 1 and b.loaded and not b.loading)
	return b
end

local function removeOf(b: board.Board, f: Fake, id: string): (boolean, string)
	local ok, msg = false, ""
	board.remove(b, f.api, id, yes, function(o, m)
		ok, msg = o, m
	end)
	return ok, msg
end

function M.run()
	local f = fake({
		["/a"] = { entry("/a", { main = true }), entry("/w1", { key = "#1", number = 1 }), entry("/shared") },
		["/b"] = { entry("/b", { main = true }), entry("/w2", { locked = true }), entry("/gone", { prunable = true }) },
	})
	-- spans checkouts, dedupes a shared path, skips '', stays sequential, reports a failing checkout
	local b = loaded(f, { ["o/z"] = "/b", ["o/a"] = "/a", ["o/dup"] = "/a", ["o/none"] = "", ["o/bad"] = "/nowhere" })
	assert(f.max == 1)
	assert(#f.calls == 3 and f.calls[1] == "inv:o/a" and f.calls[2] == "inv:o/bad" and f.calls[3] == "inv:o/z")
	assert(#b.rows == 6 and #b.problems == 1)
	assert(#board.rows(b, {}) == 4 and #board.rows(b, { showMain = true }) == 6)
	assert(board.rows(b, {})[1].repo == "o/a")
	local w1 = board.rows(b, {})[1]
	assert(w1.id == w1.repo .. "\0" .. w1.path)

	-- remove refusals
	local function row(path: string): board.Row
		for _, r in b.rows do
			if r.path == path then
				return r
			end
		end
		error("no row " .. path)
	end
	for _, p in { "/a", "/w2", "/gone" } do
		local ok = removeOf(b, f, row(p).id)
		assert(not ok and row(p).refused ~= nil)
	end
	assert(#f.removed == 0)
	-- dirty is re-read right before removal
	f.dirty["/w1"] = true
	local before = #f.calls
	local ok = removeOf(b, f, row("/w1").id)
	assert(not ok and f.calls[before + 1] == "dirty:/w1" and #f.removed == 0 and row("/w1").dirty == true)
	f.dirty["/w1"] = false
	local ok2 = removeOf(b, f, row("/w1").id)
	assert(ok2 and #f.removed == 1 and #b.rows == 5)
	assert(not removeOf(b, f, "gone"))

	-- reload keeps dirty info for rows still present
	row("/shared").dirty = true
	board.load(b, f.api, { ["o/a"] = "/a" }, yes, function() end)
	assert(row("/shared").dirty == true)

	-- inspect
	f.dirty["/shared"] = false
	board.inspect(b, f.api, row("/shared").id, yes, function() end)
	assert(row("/shared").dirty == false and row("/shared").checking == nil)

	-- candidates: bounded, never remove
	local many: { board.Entry } = {}
	for i = 1, 30 do
		table.insert(many, entry("/p" .. i, { key = "#" .. i, number = i }))
	end
	table.insert(many, entry("/inf", { key = "#99", number = 99, inferred = true }))
	table.insert(many, entry("/main", { main = true, key = "#98" }))
	local f2 = fake({ ["/c"] = many })
	local b2 = loaded(f2, { ["o/c"] = "/c" })
	local asked, busy, peak = 0, 0, 0
	local function check(r: board.Row, d: (string) -> ())
		busy += 1
		peak = math.max(peak, busy)
		asked += 1
		busy -= 1
		d(if r.number == 1 then "merged" elseif r.number == 2 then "closed" else "open")
	end
	local checked, skipped = -1, -1
	board.findCandidates(b2, check :: board.Check, yes, function(c, s)
		checked, skipped = c, s
	end)
	assert(checked == board.CAP_CHECKS and skipped == 10 and asked == 20 and peak == 1)
	assert(#b2.rows == 32 and #f2.removed == 0)
	local cands = 0
	for _, r in b2.rows do
		if r.candidate then
			cands += 1
		end
	end
	assert(cands == 2)
	-- second call prefers rows not yet checked
	board.findCandidates(b2, check :: board.Check, yes, function() end)
	assert(asked == 40)
	local fu = fake({ ["/u"] = { entry("/u1", { key = "#1", number = 1 }) } })
	local bu = loaded(fu, { ["o/u"] = "/u" })
	local got = -1
	board.findCandidates(bu, (function(_: board.Row, d: (string) -> ())
		d("unknown")
	end) :: board.Check, yes, function(c)
		got = c
	end)
	assert(got == 0 and not bu.rows[1].candidateChecked and bu.rows[1].candidate == nil)

	-- row cap
	local big: { board.Entry } = {}
	for i = 1, 250 do
		table.insert(big, entry("/r" .. i))
	end
	local b3 = loaded(fake({ ["/x"] = big }), { ["o/x"] = "/x" })
	assert(#b3.rows == board.CAP_ROWS and #b3.problems == 1)
	-- checkout cap
	local cks: { [string]: string } = {}
	for i = 1, 60 do
		cks[string.format("o/r%02d", i)] = "/k" .. i
	end
	local f4 = fake({})
	loaded(f4, cks)
	assert(#f4.calls == board.CAP_CHECKOUTS)

	-- stale live() abandons silently
	local f5 = fake({ ["/a"] = { entry("/w") } })
	local b5 = board.new()
	local fired = false
	board.load(b5, f5.api, { ["o/a"] = "/a" }, function()
		return false
	end, function()
		fired = true
	end)
	assert(not fired and not b5.loaded and #b5.rows == 0)
	local b6 = loaded(f5, { ["o/a"] = "/a" })
	local gone = false
	board.remove(b6, f5.api, b6.rows[1].id, function()
		return false
	end, function()
		gone = true
	end)
	assert(not gone and #f5.removed == 0)
	-- a newer load supersedes an older one
	local pending: (() -> ())? = nil
	local slow = fake({})
	slow.api.inventory = function(_, _, d)
		pending = function()
			d({ entry("/old") }, nil)
		end
	end
	local b7 = board.new()
	local oldDone = false
	board.load(b7, slow.api, { ["o/a"] = "/a" }, yes, function()
		oldDone = true
	end)
	board.load(b7, f5.api, { ["o/a"] = "/a" }, yes, function() end)
	assert(pending);
	(pending :: () -> ())()
	assert(not oldDone and b7.rows[1].path == "/w")

	-- badges
	local bd = board.badges({ id = "i", repo = "r", checkout = "c", path = "/p", main = false, locked = true, missing = true, dirty = true, candidate = "merged" } :: board.Row, true)
	local texts: { string } = {}
	for _, x in bd do
		table.insert(texts, x.text)
	end
	assert(table.concat(texts, ",") == "In tab,Changes,Merged,Locked,Missing,Unnoted")
	for _, x in board.badges({ id = "i", repo = "r", checkout = "c", path = "/p", main = false, number = 5, locked = false, missing = false } :: board.Row, false) do
		assert(x.text ~= "Unnoted")
	end
	assert(board.label({ branch = nil } :: any) == "(detached)")
end

return M
