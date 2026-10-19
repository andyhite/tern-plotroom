--!strict
-- Assertions over the Worktrees list's model with a fake backend api. No git.

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
		dirty = function(path, done)
			enter("dirty:" .. path)
			busy -= 1
			done(f.dirty[path] == true, nil)
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

	-- successive scans cover every row beyond the cap, a failing one included
	local lots: { board.Entry } = {}
	for i = 1, 100 do
		table.insert(lots, entry("/q" .. i))
	end
	local fl = fake({ ["/l"] = lots })
	local bl = loaded(fl, { ["o/l"] = "/l" })
	local realDirty = fl.api.dirty
	fl.api.dirty = function(path, d)
		if path == "/q50" then
			return d(nil, "boom")
		end
		realDirty(path, d)
	end
	for pass = 1, 3 do
		assert(board.scan(bl, fl.api, pass * 1000, yes, function() end))
	end
	for _, r in bl.rows do
		assert(r.scannedAt ~= nil and (r.dirty ~= nil or r.path == "/q50"))
	end

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
	assert(board.label({ path = "/w/feature-x/", branch = "b" } :: any) == "feature-x")
	assert(board.label({ path = "", branch = nil } :: any) == "(detached)")

	-- automatic dirty scan: sequential, deduped, selected first, due-gated, failures never clean
	local fs = fake({ ["/a"] = { entry("/a", { main = true }), entry("/w1"), entry("/w2"), entry("/gone", { prunable = true }) } })
	local bs = loaded(fs, { ["o/a"] = "/a", ["o/b"] = "/a" })
	for _, r in bs.rows do
		if r.path == "/w2" then
			bs.selected = r.id
		end
	end
	fs.dirty["/w1"] = true
	local ticks = 0
	local before2 = #fs.calls
	assert(board.scan(bs, fs.api, 100, yes, function()
		ticks += 1
	end))
	assert(fs.max == 1 and #fs.calls - before2 == 3 and fs.calls[before2 + 1] == "dirty:/w2" and not bs.scanning)
	for _, r in bs.rows do
		assert(r.missing or r.dirty == (r.path == "/w1"))
	end
	assert(not board.scan(bs, fs.api, 110, yes, function() end) and #fs.calls - before2 == 3)
	assert(board.scan(bs, fs.api, 110, yes, function() end, true))
	assert(board.scan(bs, fs.api, 110 + board.SCAN_SECONDS, yes, function() end)) -- due this long after the forced scan started
	-- offscreen: nothing starts; a live() that turns false stops it
	assert(not board.scan(bs, fs.api, 1e6, function()
		return false
	end, function() end, true))
	local on = true
	local fo = fake({ ["/a"] = { entry("/w1"), entry("/w2") } })
	local bo = loaded(fo, { ["o/a"] = "/a" })
	fo.api.dirty = function(path, d)
		table.insert(fo.calls, path)
		on = false
		d(true, nil)
	end
	board.scan(bo, fo.api, 0, function()
		return on
	end, function() end)
	-- the first answer took the board offscreen: the scan stops there, reads no more, and the next one is due at once
	assert(#fo.calls == 2 and not bo.scanning and bo.scanAt == nil)
	on = true
	assert(board.scan(bo, fo.api, 1, function()
		return on
	end, function() end))
	board.stop(bo)
	assert(not bo.scanning and bo.scanAt == nil)
	-- failure is unknown, not clean; stale answers after reload are ignored
	local ff = fake({ ["/a"] = { entry("/w1") } })
	local bf = loaded(ff, { ["o/a"] = "/a" })
	local held: ((boolean?, string?) -> ())? = nil
	ff.api.dirty = function(_, d)
		held = d
	end
	board.scan(bf, ff.api, 0, yes, function() end)
	board.load(bf, ff.api, { ["o/a"] = "/a" }, yes, function() end);
	(held :: (boolean?, string?) -> ())(false, nil)
	assert(bf.rows[1].dirty == nil and not bf.scanning)
	ff.api.dirty = function(_, d)
		d(nil, "git failed")
	end
	board.scan(bf, ff.api, 0, yes, function() end)
	assert(bf.rows[1].dirty == nil and bf.rows[1].scannedAt == 0)
	assert(board.badges(bf.rows[1], false)[1].text == "Unknown")

	-- boundaries: non-ASCII excerpt, reload mid-read, changed link, repeated select, scan stop/dedup, missing never clean
	local fb = fake({ ["/m"] = { entry("/m/a", { number = 1 }), entry("/m/gone", { prunable = true }) } })
	local bb = loaded(fb, { ["o/m"] = "/m" })
	local pend: { (board.Info?, string?) -> () } = {}
	local nPr = 0
	local lk: board.Links = {
		pr = function(_, _, d)
			nPr += 1
			table.insert(pend, d)
		end,
		issue = function(_, _, d)
			d(nil, nil)
		end,
		head = function(_, _, d)
			d(nil)
		end,
	}
	local a = bb.rows[1].id
	board.select(bb, lk, a, yes, function() end)
	board.select(bb, lk, a, yes, function() end)
	assert(nPr == 1) -- repeated select while loading asks nothing more and keeps its round
	pend[1]({ ref = "#1", title = "t", state = "open", tracker = "g", excerpt = string.rep("é", 300) }, nil)
	local dpr = bb.details[a].pr
	assert(dpr and dpr.info)
	local ex = dpr.info.excerpt :: string
	assert(dpr.state == "ready" and utf8.len(ex) ~= nil and #ex <= board.EXCERPT + 3)
	board.select(bb, lk, a, yes, function() end, true) -- explicit refresh reads again
	assert(nPr == 2)
	board.load(bb, fb.api, { ["o/m"] = "/m" }, yes, function() end) -- reload mid-read: asked again, never stuck loading
	local function prOf(id: string?): board.Section
		local d = bb.details[id :: string]
		assert(d and d.pr)
		return d.pr
	end
	local function infoOf(id: string?): board.Info
		local i = prOf(id).info
		assert(i)
		return i
	end
	assert(nPr == 3 and prOf(bb.selected).state == "loading")
	pend[2]({ ref = "#1", title = "old", state = "open", tracker = "g" }, nil)
	assert(prOf(bb.selected).state == "loading")
	pend[3]({ ref = "#1", title = "new", state = "open", tracker = "g" }, nil)
	assert(infoOf(bb.selected).title == "new")
	fb.api.inventory = function(_, _, d) -- the worktree moved to another PR: the old read is stale
		d({ entry("/m/a", { number = 2 }) }, nil)
	end
	board.load(bb, fb.api, { ["o/m"] = "/m" }, yes, function() end)
	assert(nPr == 4 and prOf(bb.selected).ref == "#2")
	-- stop makes the next scan due at once; the same folder under two checkouts is read once; a missing row is never clean
	local inventory = { ["/c1"] = { entry("/same"), entry("/gone") }, ["/c2"] = { entry("/same") } }
	local fm = fake(inventory)
	local bm = loaded(fm, { ["o/1"] = "/c1", ["o/2"] = "/c2" })
	for _, r in bm.rows do
		r.dirty = false
	end
	inventory["/c1"][2] = entry("/gone", { prunable = true })
	board.load(bm, fm.api, { ["o/1"] = "/c1", ["o/2"] = "/c2" }, yes, function() end)
	assert(board.scan(bm, fm.api, 5, yes, function() end))
	local reads = 0
	for _, c in fm.calls do
		if c == "dirty:/same" then
			reads += 1
		end
	end
	assert(reads == 1)
	for _, r in bm.rows do
		assert(not r.missing or r.dirty ~= false)
	end
	local held3: ((boolean?, string?) -> ())? = nil
	fm.api.dirty = function(_, d)
		held3 = d
	end
	assert(board.scan(bm, fm.api, 6, yes, function() end, true) and bm.scanning)
	board.stop(bm)
	assert(not bm.scanning and bm.scanAt == nil);
	(held3 :: (boolean?, string?) -> ())(true, nil) -- the cancelled scan's late answer changes nothing
	for _, r in bm.rows do
		assert(r.dirty ~= true)
	end
	assert(board.scan(bm, fm.api, 7, yes, function() end)) -- not held back by the cancelled scan's start time

	-- preview: starts unselected, PR + issue, enrichment, errors, close, stale
	local bp = loaded(fake({ ["/p"] = { entry("/p/one", { number = 7, key = "PRJ-1" }), entry("/p/two", { number = 8 }), entry("/p/three") } }), { ["o/p"] = "/p" })
	assert(bp.selected == nil)
	local asked2: { string } = {}
	local held2: { [string]: (board.Info?, string?) -> () } = {}
	local links: board.Links = {
		pr = function(_, n, d)
			table.insert(asked2, "pr" .. n)
			if n == 8 then
				return d({ ref = "#8", title = "T", state = "open", tracker = "github o/p", excerpt = "  a\n\n b  ", related = { key = "PRJ-2" } }, nil)
			end
			d({ ref = "#7", title = "Seven", state = "open", person = "ann", tracker = "github o/p" }, nil)
		end,
		issue = function(_, k, d)
			table.insert(asked2, k)
			held2[k] = d
		end,
		head = function(_, _, d)
			d(nil)
		end,
	}
	local function idOf(p: string): string
		for _, r in bp.rows do
			if r.path == p then
				return r.id
			end
		end
		error(p)
	end
	board.select(bp, links, idOf("/p/one"), yes, function() end)
	local function sec(p: string, which: "pr" | "issue"): board.Section
		local d = bp.details[idOf(p)]
		assert(d)
		local s = if which == "pr" then d.pr else d.issue
		assert(s)
		return s
	end
	assert(table.concat(asked2, ",") == "pr7,PRJ-1" and sec("/p/one", "issue").state == "loading")
	held2["PRJ-1"]({ ref = "PRJ-1", title = "Jira", state = "To Do", person = "bo", tracker = "jira PRJ" }, nil)
	local one = board.preview(bp, bp.rows[1])
	assert(one.pr and one.pr.state == "ready" and one.issue and one.issue.info and one.issue.info.tracker == "jira PRJ")
	-- cached: reselect asks nothing; a different row's late answer is ignored
	board.select(bp, links, idOf("/p/one"), yes, function() end)
	assert(#asked2 == 2)
	-- one identifier known: the verified related key fills in the issue; excerpt is plain and short
	board.select(bp, links, idOf("/p/two"), yes, function() end)
	assert(asked2[3] == "pr8" and asked2[4] == "PRJ-2")
	assert(sec("/p/two", "pr").info and (sec("/p/two", "pr").info :: board.Info).excerpt == "a b")
	board.select(bp, links, idOf("/p/one"), yes, function() end)
	held2["PRJ-2"]({ ref = "PRJ-2", title = "late", state = "x", tracker = "jira PRJ" }, nil)
	assert(sec("/p/two", "issue").state == "loading")
	-- error then retry; unlinked row has no sections; close ignores in-flight answers
	local bad = false
	links.pr = function(_, _, d)
		d(nil, if bad then "offline" else nil)
	end
	bad = true
	board.select(bp, links, idOf("/p/two"), yes, function() end)
	assert(sec("/p/two", "pr").state == "error" and sec("/p/two", "pr").problem == "offline")
	board.select(bp, links, idOf("/p/three"), yes, function() end)
	assert(board.preview(bp, bp.rows[1]).facts[1][1] == "Branch")
	assert(bp.details[idOf("/p/three")] and bp.details[idOf("/p/three")].pr == nil and bp.details[idOf("/p/three")].issue == nil)
	board.select(bp, links, idOf("/p/one"), yes, function() end)
	board.close(bp)
	assert(bp.selected == nil)
	board.select(bp, links, "nope", yes, function() end)
	assert(bp.selected == nil)
	-- an issue with no PR its tracker links: GitHub's head-ref match fills the PR in; no match, or a PR already known, asks nothing
	local bh = loaded(
		fake({ ["/h"] = { entry("/h/a", { key = "PRJ-3" }), entry("/h/b", { key = "PRJ-4" }), entry("/h/c", { key = "PRJ-5", number = 9 }), entry("/h/d", { key = "PRJ-6" }) } }),
		{ ["o/h"] = "/h" }
	)
	local heads: { string } = {}
	local prsRead: { number } = {}
	local lh: board.Links = {
		pr = function(_, n, d)
			table.insert(prsRead, n)
			d({ ref = "#" .. n, title = "T" .. n, state = "open", tracker = "github o/h" }, nil)
		end,
		issue = function(_, k, d)
			d({ ref = k, title = "I", state = "x", tracker = "jira PRJ", related = if k == "PRJ-6" then { number = 3 } else nil }, nil)
		end,
		head = function(_, b, d)
			table.insert(heads, b)
			d(if b == "b-/h/a" then 12 else nil)
		end,
	}
	local function hid(p: string): string
		for _, r in bh.rows do
			if r.path == p then
				return r.id
			end
		end
		error(p)
	end
	board.select(bh, lh, hid("/h/a"), yes, function() end)
	local ha = bh.details[hid("/h/a")]
	assert(ha and ha.pr and ha.pr.state == "ready" and (ha.pr.info :: board.Info).title == "T12" and table.concat(heads, ",") == "b-/h/a")
	board.select(bh, lh, hid("/h/b"), yes, function() end)
	local hb = bh.details[hid("/h/b")]
	assert(hb and hb.pr == nil and hb.issue and #heads == 2, "no PR on that head: no section")
	board.select(bh, lh, hid("/h/c"), yes, function() end)
	board.select(bh, lh, hid("/h/d"), yes, function() end)
	assert(#heads == 2 and prsRead[#prsRead] == 3, "a known or tracker-linked PR needs no head lookup")
	-- scan prefers the cheap read-only api.dirty (no re-listing); only listed paths reach it
	local fd = fake({ ["/a"] = { entry("/w1"), entry("/w2") } })
	local bd2 = loaded(fd, { ["o/a"] = "/a" })
	local cheap: { string } = {}
	fd.api.dirty = function(path, d)
		table.insert(cheap, path)
		d(path == "/w1", nil)
	end
	local invCalls = #fd.calls
	board.scan(bd2, fd.api, 0, yes, function() end)
	assert(#cheap == 2 and #fd.calls == invCalls and bd2.rows[1].dirty == true and bd2.rows[2].dirty == false)
end

return M
