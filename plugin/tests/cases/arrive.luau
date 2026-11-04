--!strict
-- Regression cases: arrivals, a row a refresh (or an agent) moves into Needs you, Blocked or Ready to merge, ringed for a
-- moment, and the one toast per refresh (engine.arrive).

local h = require("../harness")

type Block = h.Block
type World = h.World

local EPOCH, case, eq, hostScene, hx, openQueue = h.EPOCH, h.case, h.eq, h.hostScene, h.hx, h.openQueue
local pickerOf, refreshNow, same, searchItem = h.pickerOf, h.refreshNow, h.same, h.searchItem
local asks = h.asks

local OPEN = { review = "REVIEW_REQUIRED", merge = "BLOCKED", checks = "SUCCESS" }
local READY = { review = "APPROVED", mergeable = "MERGEABLE", merge = "CLEAN", checks = "SUCCESS" }
local FAILING = { review = "REVIEW_REQUIRED", merge = "BLOCKED", checks = "FAILURE" }
local CONFLICTS = { review = "REVIEW_REQUIRED", mergeable = "CONFLICTING", merge = "DIRTY", checks = "SUCCESS" }
local CHANGES = { review = "CHANGES_REQUESTED", merge = "BLOCKED", checks = "SUCCESS" }

-- Pull request o/r#n in `stage`, as the search lists it.
local function pr(n: number, stage: { [string]: any }): { [string]: any }
	return searchItem(n, "o/r", EPOCH - 60 * n, table.clone(stage))
end

-- The ringed rows as "row id/tone", in the order listed.
local function rings(b: Block): { string }
	local out: { string } = {}
	for _, row in pickerOf(b).items do
		if row.tone then
			table.insert(out, row.id .. "/" .. row.tone)
		end
	end
	return out
end

-- The toasts about arrivals (they name an item), as "level text · sub".
local function arrivals(w: World): { string }
	local out: { string } = {}
	for _, t in w.toasts do
		if string.find(t.text, "o/r#", 1, true) or string.find(t.text, "need you", 1, true) then
			table.insert(out, t.level .. " " .. t.text .. (if t.sub then " · " .. t.sub else ""))
		end
	end
	return out
end

case("arrive: a refresh that moves a pull request into Blocked rings its row red for 1.4 s and toasts why; the first listing rings nothing", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { pr(1, OPEN), pr(2, READY) }
	local b = openQueue(w)
	same(rings(b), {}, "the first listing is no move, Ready to merge included")
	same(arrivals(w), {}, "and toasts nothing")
	s.gh.items.octocat = { pr(1, FAILING), pr(2, READY) }
	refreshNow(w, b)
	same(rings(b), { "no_2fr_231/error" }, "the row that moved into Blocked takes the needs-fixing tone")
	same(arrivals(w), { "error o/r#1: Fix checks" }, "one error toast names the item and its first chip")
	same(hx.offPalette(b.view().layer), {}, "the ring is a meaning colour")
	w.advance(1399)
	same(rings(b), { "no_2fr_231/error" }, "it holds for the ring's time")
	w.advance(1)
	same(rings(b), {}, "then it is gone")
	refreshNow(w, b)
	same(rings(b), {}, "a refresh that moves nothing rings nothing")
	same(arrivals(w), { "error o/r#1: Fix checks" }, "and toasts nothing more")
	s.gh.items.octocat = { pr(1, OPEN), pr(2, READY) }
	refreshNow(w, b)
	s.gh.items.octocat = { pr(1, FAILING), pr(2, READY) }
	refreshNow(w, b)
	same(rings(b), { "no_2fr_231/error" }, "leaving Blocked and coming back is an arrival again")
end)

case("arrive: Ready to merge rings green with no toast; Blocked only by conflicts rings with no toast; several arrivals make one toast", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { pr(1, OPEN), pr(2, OPEN), pr(3, OPEN), pr(4, OPEN) }
	local b = openQueue(w)
	s.gh.items.octocat = { pr(1, READY), pr(2, CONFLICTS), pr(3, OPEN), pr(4, OPEN) }
	refreshNow(w, b)
	same(rings(b), { "no_2fr_231/success", "no_2fr_232/error" }, "Ready to merge rings in the done colour, Blocked in the needs-fixing one")
	same(arrivals(w), {}, "neither a Ready to merge nor a conflict toasts")
	s.gh.items.octocat = { pr(1, READY), pr(2, CONFLICTS), pr(3, FAILING), pr(4, CHANGES) }
	refreshNow(w, b)
	same(rings(b), { "no_2fr_233/error", "no_2fr_234/error" }, "a new arrival replaces the rings shown")
	same(arrivals(w), { "error 2 items need you or are Blocked · o/r#3: Fix checks and 1 more" }, "one toast for the refresh, counting them")
end)

case("arrive: a change your own confirmed command made is no arrival, in that refresh only", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { pr(1, OPEN), pr(2, OPEN) }
	local live = { number = 1, state = "OPEN", isDraft = false, headRefOid = h.sha("a"), mergeStateStatus = "BLOCKED", url = "https://github.com/o/r/pull/1" }
	local seen = asks.hx.writes(s.gh, function(line: string): h.Reply?
		return if string.find(line, "gh pr view ", 1, true) then { stdout = h.jsonEncode(live) } else nil
	end)
	local b = openQueue(w)
	w.advance(300)
	local p = asks.hx.ask(w, b, { op = "act", name = "pr-approve" })
	eq(p.confirm.head, "Approve o/r#1?", "an approval of the selected pull request is planned")
	s.gh.items.octocat = { pr(1, READY), pr(2, READY) }
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	eq(r.ok, true, "and committed: " .. tostring(r.problem))
	eq(#seen, 2, "the pull request was read, then one review sent")
	same(rings(b), { "no_2fr_232/success" }, "the approved one is yours, the other moved on its own")
	s.gh.items.octocat = { pr(1, OPEN), pr(2, READY) }
	refreshNow(w, b)
	s.gh.items.octocat = { pr(1, READY), pr(2, READY) }
	refreshNow(w, b)
	same(rings(b), { "no_2fr_231/success" }, "a later move of the same item is an arrival again")
end)

case("arrive: an agent that starts needing you rings its row with no toast; the first agent states a block hears ring nothing", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { pr(1, OPEN), pr(2, OPEN) }
	local b = openQueue(w)
	asks.hx.agents(b, { ["o/r#1"] = "waiting_input" })
	eq(asks.hx.stage(b, "no_2fr_231"), "Needs you", "the agent waits")
	same(rings(b), {}, "the first states a block hears are a restore, not a move")
	asks.hx.agents(b, { ["o/r#1"] = "working", ["o/r#2"] = "working" })
	same(rings(b), {}, "Agent working rings nothing")
	asks.hx.agents(b, { ["o/r#1"] = "working", ["o/r#2"] = "waiting_input" })
	same(rings(b), { "no_2fr_232/accent" }, "a row whose agent starts needing you is ringed in your-turn accent")
	same(arrivals(w), {}, "the host toasts nothing: the window says an agent needs input")
	w.advance(1400)
	same(rings(b), {}, "and the ring ends")
	s.gh.items.octocat = { pr(1, FAILING), pr(2, OPEN) }
	refreshNow(w, b)
	same(rings(b), {}, "an item whose agent works is Agent working, whatever its checks say")
	asks.hx.agents(b, { ["o/r#2"] = "waiting_input" })
	same(rings(b), {}, "its agent leaving shows it Blocked, but only a refresh's move into Blocked rings")
	refreshNow(w, b)
	same(rings(b), {}, "nor does the next refresh: it was Blocked already")
end)

return {}
