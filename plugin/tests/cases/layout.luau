--!strict
-- Regression cases: a view laid out as a Board (Settings › Views › Layout, Commands › Show as Board).

local h = require("../harness")

type World = h.World

local EPOCH, array, asks, case, eq, expand, findKey = h.EPOCH, h.array, h.asks, h.case, h.eq, h.expand, h.findKey
local goToSettings, hostScene, hx, listed, openQueue = h.goToSettings, h.hostScene, h.hx, h.listed, h.openQueue
local pickerNode, pickerOf, rowIn, same, searchItem, yes = h.pickerNode, h.pickerOf, h.rowIn, h.same, h.searchItem, h.yes
local board = hx.board

-- The view My PRs (prs:v1, `layout` as given) listing o/r#1 Blocked (changes requested), o/r#2 Ready to merge, o/r#3
-- open with nothing to do (Waiting), o/r#4 merged and o/r#5 open under a working agent; the block opens on it.
local function scene(w: World, layout: any?): h.Block
	local s = hostScene(w, 0)
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { review = "CHANGES_REQUESTED" }),
		searchItem(2, "o/r", EPOCH - 120, { review = "APPROVED", mergeable = "MERGEABLE", merge = "CLEAN", checks = "SUCCESS" }),
		searchItem(3, "o/r", EPOCH - 180),
		searchItem(4, "o/r", EPOCH - 240, { state = "MERGED" }),
		searchItem(5, "o/r", EPOCH - 300),
	}
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "author:@me", logins = array({}), group = "none", prompts = array({}), layout = layout },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	asks.hx.agents(b, { ["o/r#5"] = "working" })
	w.flush()
	return b
end

-- The selected card as "<column>.list.<row id>".
local function at(b: h.Block): string
	local _, selected = board(b)
	return string.match(selected or "", "board%.%a+%.(.*)$") or "none"
end

local function layout(b: h.Block)
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" })
end

case("layout: a view's Layout (Settings › Views) saves Board with the view, which lays it out in columns by stage, merged and closed in the fold; List goes back", function(w: World)
	local b = scene(w)
	eq((board(b)), nil, "a view is a List until asked")
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	local row = rowIn(b, "vlayout:prs:v1")
	eq(row.label, "Layout", "the view's form has a Layout row")
	eq(row.control.value, "list", "showing List")
	b.event({ ev = "change", id = "layer.settings", item = "vlayout:prs:v1", value = "board" })
	eq(w.kv.get("views-prs").items[1].layout, "board", "Board is saved with the view")
	eq(w.kv.get("views-prs").items[2].layout, nil, "and with no other")
	eq(rowIn(b, "vlayout:prs:v1").control.value, "board", "the row shows it")
	local cols, selected = board(b)
	same(cols, { "needs: no_2fr_231", "working: no_2fr_235", "waiting: no_2fr_233", "ready: no_2fr_232" }, "Needs you (Blocked), Agent working, Waiting (PR open), Ready to merge in the view's order; the fold is closed")
	eq(selected, "layer.queue.board.lanes.needs.list.no_2fr_231", "the selection stays on the view's selected item")
	same(listed(b), {}, "the picker lists nothing of its own")
	local card: any = findKey(pickerNode(b), "no_2fr_231", "item")
	eq(card.p.value[1].t, "Changes requested", "a card says what blocks it")
	eq(card.p.detail[1].t, "o/r#1", "and names its item")
	local fold: any = findKey(pickerNode(b), "fold", "item")
	eq(fold.p.label, "Show Not started 0 · Worktree 0 · Merged or closed 1", "the merged item is in the fold's Merged or closed")
	b.event({ ev = "action", id = "layer.queue.board.foldbar.fold", act = fold.p.actions.click })
	eq((board(b) or {})[7], "done: no_2fr_234", "which the fold's button opens")
	b.event({ ev = "change", id = "layer.settings", item = "vlayout:prs:v1", value = "grid" })
	eq(w.kv.get("views-prs").items[1].layout, "board", "a layout the row does not offer is refused")
	b.event({ ev = "change", id = "layer.settings", item = "vlayout:prs:v1", value = "list" })
	eq(w.kv.get("views-prs").items[1].layout, nil, "List saves no layout")
	eq((board(b)), nil, "and the view is a List again")
	eq(#listed(b), 5, "listing every item")
end)

case("layout: Commands › Show as Board and Show as List switch the active view's layout and save it; a pinned item has none", function(w: World)
	local b = scene(w)
	local p = hx.palette(w, b)
	eq(p.labels.layout, "Show as Board", "Commands offers the Board")
	eq(p.groups.layout, "Filter & Sort", "under Filter & Sort")
	layout(b)
	yes(board(b) ~= nil, "it lays the view out as a Board")
	eq(w.kv.get("views-prs").items[1].layout, "board", "saved with the view")
	eq(hx.palette(w, b).labels.layout, "Show as List", "then offers the List")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "scope:prs:v2" })
	w.flush()
	eq((board(b)), nil, "another view keeps its own layout")
	eq(hx.palette(w, b).labels.layout, "Show as Board", "and Commands offers it its Board")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "scope:prs:v1" })
	w.flush()
	yes(board(b) ~= nil, "back on My PRs, its Board")
	layout(b)
	eq((board(b)), nil, "Show as List goes back")
	eq(w.kv.get("views-prs").items[1].layout, nil, "and saves it")
end)

case("layout: on a view's Board the keys move in and across columns, search and snoozing change what it lays out, and Commands and the Next move act on the selected card", function(w: World)
	local b = scene(w, "board")
	yes(board(b) ~= nil, "a view saved as a Board opens as one")
	b.press("right")
	eq(at(b), "working.list.no_2fr_235", "Right moves to the next column")
	b.typeText("l")
	eq(at(b), "waiting.list.no_2fr_233", "and so does l")
	eq(pickerOf(b).selected, nil, "the picker selects nothing of its own")
	b.press("down")
	eq(at(b), "waiting.list.no_2fr_233", "Down stops at the column's last card")
	b.typeText("lll")
	eq(at(b), "done.list.no_2fr_234", "past Ready to merge it goes into the fold and opens it, skipping empty columns")
	b.typeText("hhhh")
	eq(at(b), "needs.list.no_2fr_231", "h moves back to the first column")
	b.press("end")
	eq(at(b), "needs.list.no_2fr_231", "End stays in the column")
	-- Commands and the Next move are the selected card's item's, as in the List.
	local p = hx.palette(w, b)
	yes(table.find(p.ids, "snooze") ~= nil and table.find(p.ids, "open") ~= nil, "Commands offers the item's rows")
	layout(b)
	eq(pickerOf(b).selected, "no_2fr_231", "the List selects the same item")
	local list = hx.palette(w, b)
	same(list.ids, p.ids, "and Commands offers the same rows")
	eq(list.labels.next, p.labels.next, "with the same Next move")
	layout(b)
	-- Search: the Board lays out what the search lets through, and Left/Right stay in the search field.
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "search" })
	b.typeText("PR 3")
	w.flush()
	local cols = board(b) or {}
	same(cols, { "needs: ", "working: ", "waiting: no_2fr_233", "ready: ", "none: ", "worktree: " }, "only the matching item is laid out (the fold, still open, has no Merged or closed now)")
	eq(at(b), "waiting.list.no_2fr_233", "and selected")
	b.press("left")
	eq(at(b), "waiting.list.no_2fr_233", "Left moves the search field's caret, not the selection")
	b.press("escape")
	b.press("escape")
	w.flush()
	eq(#(board(b) or {}), 7, "clearing the search lays every item out again, Merged or closed back in the open fold")
	-- Snooze: the selected card leaves the Board, its column's next card taking the selection.
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "snooze" })
	w.flush()
	local after = board(b) or {}
	eq(after[3], "waiting: ", "a snoozed card leaves the Board")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "snoozed" })
	w.flush()
	eq((board(b) or {})[3], "waiting: no_2fr_233", "Show snoozed brings it back")
	local snoozed: any = findKey(pickerNode(b), "no_2fr_233", "item")
	eq(snoozed.p.detail[2].t, " · Snoozed", "marked Snoozed")
	-- A card is selected by a click and shown as the List shows it: nothing is marked seen without its preview.
	b.event({ ev = "select", id = "layer.queue.board.lanes.ready.list", item = "layer.queue.board.lanes.ready.list.no_2fr_232" })
	eq(at(b), "ready.list.no_2fr_232", "a click on a card selects it")
	local ready: any = findKey(pickerNode(b), "no_2fr_232", "item")
	eq(ready.p.value[1].t, "New", "and it is still New: a Board marks nothing seen")
end)

case("layout: below 80 columns a view's Board shows as the List with the List's keys", function(w: World)
	local b = scene(w, "board")
	b.cx.cols = 79
	b.render()
	eq((board(b)), nil, "a narrow block shows the List")
	eq(#listed(b), 5, "with every item")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_232", "and the List's keys")
	b.cx.cols = 80
	b.render()
	eq(at(b), "ready.list.no_2fr_232", "wide enough again, the Board, on the same item")
end)

case("layout: a stored layout this version does not know loads as the List, and Show as Board writes over it", function(w: World)
	local b = scene(w, "grid")
	eq((board(b)), nil, "an unknown layout is the List")
	eq(#listed(b), 5, "and the store is read")
	layout(b)
	eq(w.kv.get("views-prs").items[1].layout, "board", "Show as Board saves Board")
end)

return {}
