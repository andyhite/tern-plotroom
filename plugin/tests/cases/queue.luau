--!strict
-- Regression cases: host queue, settings sheet and prompts.

local h = require("../harness")

type AcliReq = h.AcliReq
type Block = h.Block
type GhReq = h.GhReq
type HostScene = h.HostScene
type Reply = h.Reply
type World = h.World

local EPOCH, NULL, actionOf, agentScene, answerOf, array = h.EPOCH, h.NULL, h.actionOf, h.agentScene, h.answerOf, h.array
local bindKey, case, editorCard, eq, expand, findKey = h.bindKey, h.case, h.editorCard, h.eq, h.expand, h.findKey
local forgetCheckouts, goToSettings, has, helpEntries, helpRows, hostScene = h.forgetCheckouts, h.goToSettings, h.has, h.helpEntries, h.helpRows, h.hostScene
local hx, jsonDecode, jsonEncode, lacks, leaveWt, listPr = h.hx, h.jsonDecode, h.jsonEncode, h.lacks, h.leaveWt, h.listPr
local listed, loginsSavedBy, newAcli, newGh, newGit, openQueue = h.listed, h.loginsSavedBy, h.newAcli, h.newGh, h.newGit, h.openQueue
local pickScope, pickerNode, pickerOf, prLink, prefsOf, promptOf = h.pickScope, h.pickerNode, h.pickerOf, h.prLink, h.prefsOf, h.promptOf
local refreshNow, request, requestsOf, rowIn, runLink, same = h.refreshNow, h.request, h.requestsOf, h.rowIn, h.runLink, h.same
local savePrompts, searchItem, sectionIn, sha, windowCase, yes = h.savePrompts, h.searchItem, h.sectionIn, h.sha, h.windowCase, h.yes
local asks = h.asks

-- The delete the block asks the window to confirm: its hidden `confirm` node, decoded ({row, head, label, detail}); nil when none is pending.
local function pendingOf(b: Block): any
	local view: any = b.view()
	local node = findKey(view.main, "confirm")
	return if node then jsonDecode(node.p.text) else nil
end

-- The lowercased key labels of a shortcut list overlay found under `node`.
local function helpKeys(node: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, entry in helpEntries(node) do
		for _, label in entry.caps do
			out[string.lower(label)] = true
		end
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
	eq(pickerOf(b).selected, "no_2fr_231", "the first PR is selected as the list arrives")
	eq(pickerOf(b).state, "ready", "the list is ready")
	has(b.title(), "My PRs", "the title names the filter")
	has(b.title(), "(3)", "and counts the PRs")
	local prHead: any = findKey(pickerNode(b), "head")
	eq(findKey(prHead, "integration").p.text, "GitHub", "the preview's head row carries the integration badge")
	eq(findKey(findKey(pickerNode(b), "titlerow"), "integration"), nil, "and the title row does not")
	for _, item in pickerOf(b).items do
		for _, badge in item.badges or {} do
			eq(badge.text == "GitHub", false, "a row carries no integration badge")
		end
		eq(item.mark.seed, nil, "nor a redundant seed on the author mark")
	end
	w.advance(59999)
	eq(#requestsOf(s.gh, "search"), 1, "no refresh before the minute is up")
	w.advance(1)
	eq(#requestsOf(s.gh, "search"), 2, "a refresh a minute later")
	b.close()
	w.advance(10 * 60 * 1000)
	eq(#requestsOf(s.gh, "search"), 2, "a closed pane stops polling")
end)

case("host: any number of cwd and pane_exited events inside the 250 ms window render a block once", function(w: World)
	hostScene(w, 1)
	local b = w.open(1, { "/work/r" })
	w.flush()
	w.advance(2000) -- the opening's own detail timers fire first, so only redraws are counted below
	local before = b.renders()
	for _ = 1, 3 do
		w.window.handlers.cwd({}, w.cx)
	end
	for _ = 1, 2 do
		w.window.handlers.pane_exited({}, w.cx)
	end
	w.advance(250)
	eq(b.renders(), before + 1, "five events, one render")
	local mid = b.renders()
	w.advance(250)
	w.window.handlers.cwd({}, w.cx)
	w.advance(250)
	eq(b.renders(), mid + 1, "a second burst after the window renders once more")
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
	eq(pickerOf(b).selected, "no_2fr_232", "and the selection follows to the first hit")
	eq(b.press("escape"), true, "the first Escape is handled")
	eq(pickerOf(b).query, "", "it cleared the text but kept the search open")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the whole list is back")
	eq(b.press("escape"), true, "the second Escape is handled")
	eq(pickerOf(b).query, nil, "it closed the search")
	eq(b.press("escape"), false, "with nothing to cancel Escape is not consumed")
	eq(pickerOf(b).selected, "no_2fr_232", "and Escape never closes the preview")
	b.press("tab")
	eq(pickerOf(b).focus, "scopes", "Tab moves to the filter list")
	eq(b.press("escape"), true, "Escape leaves the filter list")
	eq(pickerOf(b).focus, "list", "back to the pull requests")
end)

case("host: the first item is selected on arrival; a refresh, a search or a view switch keeps the selection on a listed item, and Escape never closes it", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	eq(pickerOf(b).selected, "no_2fr_231", "the first item is selected as the first search lands")
	eq(pickerOf(b).preview, "side", "so its preview is open")
	yes(#(pickerNode(b).c or {}) > 0, "and drawn")
	yes(w.kv.store["triage"] ~= nil, "reading it marked it seen")
	refreshNow(w, b)
	eq(pickerOf(b).selected, "no_2fr_231", "a refresh keeps it")
	b.typeText("/")
	b.typeText("2")
	eq(pickerOf(b).selected, "no_2fr_232", "a search that drops it selects the first hit")
	b.press("escape")
	b.press("escape")
	eq(pickerOf(b).selected, "no_2fr_232", "closing the search keeps what is selected")
	eq(b.press("escape"), false, "Escape with nothing to cancel is left to the pane")
	eq(pickerOf(b).selected, "no_2fr_232", "and the preview stays open")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_233", "Down moves on")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	eq(pickerOf(b).selected, "no_2fr_232", "a row event selects it")
	refreshNow(w, b)
	eq(pickerOf(b).selected, "no_2fr_232", "a refresh keeps it")
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60), searchItem(3, "o/r", EPOCH - 180) }
	refreshNow(w, b)
	eq(pickerOf(b).selected, "no_2fr_233", "a refresh that drops its item selects the row that took its place")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_233" })
	pickScope(b, "prs:v2")
	w.flush()
	eq(pickerOf(b).scope, "prs:v2", "another view")
	eq(pickerOf(b).selected, "no_2fr_231", "opens on its first item")
	s.gh.items.octocat = {}
	refreshNow(w, b)
	eq(pickerOf(b).selected, nil, "an empty list selects nothing")
	eq(pickerOf(b).preview, "none", "and has no preview")
end)

case("host: ? lists the shortcuts of the current mode, and a ? is plain text while searching", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("?")
	local queueKeys = helpKeys(b.view().layer)
	for _, key in { "↑", "↓", "enter", "w", "/", "tab", "r", "s", "?" } do
		yes(queueKeys[key], "the queue list shows " .. key)
	end
	local entries = helpEntries(b.view().layer)
	same(entries[1].caps, { "↑", "↓", "j", "k" }, "the first row puts its four keycaps in its caps text")
	has(entries[1].text, "Move through the pull requests", "and what it does in its text")
	lacks(entries[1].text, "↑", "apart from them")
	local row: any = findKey(findKey(b.view().layer, "keys"), "r1")
	same({ row.c[1].p.key, row.c[2].p.key }, { "caps", "text" }, "a row is its caps and its description")
	for i, cap in row.c[1].p.spans do
		if i % 2 == 1 then
			eq(cap.s, "key", "each keycap wears the key token")
		else
			eq(cap, " ", "a gap between them")
		end
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
	eq(pickerOf(b).scope, "prs:v2", "Down in the filter list switches view")
	b.typeText("s")
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "s opens Settings")
	eq(pickerNode(b).k, "picker", "as a sheet over the queue")
end)

case("host: Settings › Keys binds an action to a key: the key works, ? and the action bar show it, and Reset goes back to no key", function(w: World)
	hostScene(w, 3)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	goToSettings(b, "keys")
	local page: any = nil
	for _, p in prefsOf(b).pages do
		if p.id == "keys" then
			page = p
		end
	end
	same(page, { id = "keys", label = "Keyboard shortcuts", group = "Queue", icon = "keyboard" }, "Keyboard shortcuts is a page of the Queue group")
	local ids: { string } = {}
	for _, r in prefsOf(b).sections[1].rows do
		table.insert(ids, r.id)
	end
	same(ids, { "kpreset", "key:down", "key:up", "key:worktree", "key:goto", "key:agent", "key:agentgo", "key:seen", "key:snooze", "key:snoozed", "key:attention", "key:sort", "key:wt-cleanup", "key:wt-remove", "key:more", "key:search", "key:refresh", "key:settings", "key:help" }, "the one-key set's row, then one row for each action of the queue")
	eq(prefsOf(b).sections[1].title, "Queue", "under the queue's title")
	local row = rowIn(b, "key:worktree")
	eq(row.label, "Worktree", "named for its action")
	eq(row.control.value, "", "with no key: only the command palette has one by default")
	eq(row.control.placeholder, "None", "which it says")
	eq(row.changed, false, "the default is no change")
	eq(row.defaultLabel, "None", "and is what Reset goes back to")
	eq(rowIn(b, "key:more").control.value, ".", "the command palette's key is .")
	eq(#pickerOf(b).actions, 1, "the action bar has one button")
	for _, a in pickerOf(b).actions do
		eq(a.id, "more", "the action bar shows only the command palette's button, the one with a key")
	end
	eq(bindKey(b, "worktree", "w"), nil, "a free key is accepted")
	eq(prefsOf(b).editing, nil, "and closes the edit")
	same(w.kv.get("keys"), { worktree = "w" }, "it is saved as the one difference from the defaults")
	row = rowIn(b, "key:worktree")
	eq(row.control.value, "w", "the row shows it")
	eq(row.changed, true, "as a change")
	eq(bindKey(b, "down", "j"), nil, "a move key binds too")
	eq(bindKey(b, "help", "h"), nil, "and so does the list's own")
	same(w.kv.get("keys"), { down = "j", help = "h", worktree = "w" }, "each is saved beside the others")
	b.press("escape")
	local opened = #w.opened
	eq(b.press("w", "s", "W"), false, "a key no action has is left to the pane")
	eq(#w.opened, opened, "and opens nothing")
	eq(b.press("w", nil, "w"), true, "the bound one is handled")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and makes the selected pull request's worktree")
	b.typeText("j")
	eq(pickerOf(b).selected, "no_2fr_232", "j moves down")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_233", "and the arrow still does")
	b.typeText("k")
	eq(pickerOf(b).selected, "no_2fr_233", "an action nobody bound has no key")
	same(actionOf(b, "worktree").keys, { "w" }, "the action bar shows the button once it has a key")
	eq(actionOf(b, "agent"), nil, "and none for an action without one")
	b.typeText("?")
	eq(findKey(b.view().layer, "help"), nil, "? opens nothing")
	b.typeText("h")
	local shown: { string } = {}
	for _, r in helpRows(b.view().layer) do
		table.insert(shown, r.keys)
	end
	same(shown, { "↑ ↓ j", "Enter", "w", ".", "Tab", "h" }, "the list shows every key there is")
	eq(b.press("h", nil, "h"), true, "its key closes it")
	eq(findKey(b.view().layer, "help"), nil, "and it is gone")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	b.typeText("h")
	local inSettings = helpRows(b.view().layer)
	eq(inSettings[#inSettings].keys, "h", "Settings' own list shows it")
	b.press("escape")
	eq(prefsOf(b).page, "keys", "Settings reopened on the Keys page it last showed")
	b.event({ ev = "change", id = "layer.settings", item = "key:worktree" })
	same(w.kv.get("keys"), { down = "j", help = "h" }, "Reset drops that one change")
	row = rowIn(b, "key:worktree")
	eq(row.control.value, "", "the row has no key again")
	eq(row.changed, false, "as no change")
	b.event({ ev = "change", id = "layer.settings", item = "key:down" })
	b.event({ ev = "change", id = "layer.settings", item = "key:help" })
	same(w.kv.get("keys"), {}, "Reset on the others leaves nothing changed")
	eq(bindKey(b, "refresh", "R"), nil, "a key can be bound again")
	same(w.kv.get("keys"), { refresh = "R" }, "and is saved")
	eq(bindKey(b, "refresh", ""), nil, "and removed")
	same(w.kv.get("keys"), { refresh = "" }, "which is saved as no key")
	b.press("escape")
	eq(b.press("w", nil, "w"), false, "the reset key is the pane's again")
end)

case("host: Use one-key shortcuts binds the classic set to actions with no key, keeps a saved key, skips a clash and says so, and refuses unreadable keys", function(w: World)
	hostScene(w, 3)
	w.kv.store.keys = nil :: any
	w.kv.put("keys", { worktree = "x", ["goto"] = "j" })
	local b = openQueue(w)
	goToSettings(b, "keys")
	local function press()
		b.event({ ev = "action", id = "layer.settings", act = "preset-keys", value = "kpreset" })
	end
	press()
	local saved: any = w.kv.get("keys")
	eq(saved.worktree, "x", "a saved key keeps its action")
	eq(saved["goto"], "j", "even when it is a preset key")
	eq(saved.down, nil, "a preset key another action holds is skipped")
	eq(saved.up, "k", "a free action gets its preset key")
	eq(saved.agentgo, "G", "uppercase keys too")
	eq(saved["wt-remove"], "d", "and the Worktrees list's")
	eq(saved.more, nil, "an action with a default is not saved")
	local toast = w.toasts[#w.toasts]
	eq(toast.text, "One-key shortcuts set", "the toast says it is done")
	eq(toast.sub, "Skipped, key in use: Move down (j)", "and lists what was skipped")
	eq(rowIn(b, "key:up").control.value, "k", "the row shows the key")
	local before = w.kv.store["keys"]
	press()
	eq(w.kv.store["keys"], before, "pressing again changes nothing")
	w.kv.put("keys", "garbage")
	press()
	has(rowIn(b, "kpreset").warning, "malformed", "unreadable keys are refused with the existing message")
	eq(w.kv.get("keys"), "garbage", "and never written over")
end)

case("host: a key removed after Use one-key shortcuts stays removed when it is used again", function(w: World)
	hostScene(w, 3)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	goToSettings(b, "keys")
	local function press()
		b.event({ ev = "action", id = "layer.settings", act = "preset-keys", value = "kpreset" })
	end
	press()
	eq((w.kv.get("keys") :: any)["wt-remove"], "d", "the set binds d")
	eq(bindKey(b, "wt-remove", ""), nil, "Backspace removes it")
	press()
	eq((w.kv.get("keys") :: any)["wt-remove"], "", "using the set again keeps it unbound")
end)

case("host: an empty Keys row removes a shortcut: no key does it, ? and the action bar leave it out, and the command palette's Reset brings its . back", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "keys")
	for _, id in { "worktree", "agent", "search", "down", "up", "more" } do
		eq(bindKey(b, id, ""), nil, "an empty row is accepted: " .. id)
	end
	local saved = w.kv.get("keys")
	for _, id in { "worktree", "agent", "search", "down", "up" } do
		eq(saved[id], "", "a removal is saved as no key, a choice the one-key set keeps: " .. id)
	end
	eq(saved.more, "", "the command palette's removal is saved")
	local row = rowIn(b, "key:worktree")
	eq(row.control.value, "", "the row is empty")
	eq(row.changed, false, "as it is by default")
	row = rowIn(b, "key:more")
	eq(row.control.value, "", "the palette's row is empty too")
	eq(row.changed, true, "and changed")
	eq(row.defaultLabel, ".", "so Reset can bring its key back")
	b.press("tab", "s")
	eq(prefsOf(b).page, "prompts", "the Prompts page is before Keys")
	b.press("escape")
	local opened = #w.opened
	for _, k in { "w", "a", "." } do
		eq(b.press(k, nil, k), false, k .. " is left to the pane")
	end
	eq(#w.opened, opened, "nothing was opened")
	b.typeText("/")
	eq(pickerOf(b).query, nil, "/ opens no search")
	b.typeText("j")
	eq(pickerOf(b).selected, "no_2fr_231", "j moves nowhere")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_232", "the arrow does")
	b.typeText("k")
	eq(pickerOf(b).selected, "no_2fr_232", "k does not move up")
	b.press("up")
	eq(pickerOf(b).selected, "no_2fr_231", "the arrow does")
	eq(actionOf(b, "worktree"), nil, "the action bar leaves the button out")
	eq(actionOf(b, "more"), nil, "the palette's too")
	b.typeText("?")
	local shown: { string } = {}
	for _, r in helpRows(b.view().layer) do
		table.insert(shown, r.keys)
	end
	same(shown, { "↑ ↓", "Enter", "g", "G", "m", "z", "Z", "n", "o", "Tab", "r", "s", "?" }, "the list leaves out what has no key")
	b.press("escape")
	goToSettings(b, "keys")
	eq(bindKey(b, "help", ""), nil, "the list's own key can go")
	eq(bindKey(b, "settings", ""), nil, "and Settings'")
	b.press("escape")
	b.typeText("?")
	eq(findKey(b.view().layer, "help"), nil, "no key opens the list")
	b.typeText("s")
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "no key opens Settings")
	eq(actionOf(b, "settings"), nil, "and its button is gone")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "the event still opens it")
	b.typeText("?")
	eq(findKey(b.view().layer, "help"), nil, "Settings has no key for its list either")
	b.press("tab")
	b.press("tab")
	b.event({ ev = "change", id = "layer.settings", item = "key:more" })
	eq(w.kv.get("keys").more, nil, "Reset brings the palette's key back")
	b.press("escape")
	eq(b.press(".", nil, "."), true, "and it works again")
	eq(w.opened[#w.opened], "plotroom://more", "opening the command palette")
end)

case("host: the empty queue's hint names the Settings key, or just Settings when it has none", function(w: World)
	hostScene(w, 3)
	w.kv.put("views-prs", { version = 1, nextId = 1, items = array({}) })
	w.kv.put("views-issues", { version = 1, nextId = 1, items = array({}) })
	local b = openQueue(w)
	eq(pickerOf(b).empty[1].t, "No saved views yet. Press s to add one.", "the hint names the key")
	w.kv.put("keys", { settings = "S" })
	b.render()
	eq(pickerOf(b).empty[1].t, "No saved views yet. Press S to add one.", "as it is now")
	w.kv.put("keys", { settings = "" })
	b.render()
	eq(pickerOf(b).empty[1].t, "No saved views yet. Press . and pick Settings to add one.", "or the command palette's once it is removed")
	w.kv.put("keys", { settings = "", more = "" })
	b.render()
	eq(pickerOf(b).empty[1].t, "No saved views yet. Open Settings to add one.", "or just Settings with neither")
end)

case("host: the In tab tooltip names the key that goes to the tab, or none once it is removed", function(w: World)
	local s = hostScene(w, 3)
	leaveWt(w, s, 1)
	local b = openQueue(w)
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-pr-1/src" })
	b.render()
	local function tip(): string?
		for _, badge in pickerOf(b).items[1].badges do
			if badge.text == "In tab" then
				return badge.title
			end
		end
		return nil
	end
	eq(tip(), "A tab works in this pull request's worktree (g goes there)", "the tooltip names the key")
	w.kv.put("keys", { ["goto"] = "G" })
	b.render()
	eq(tip(), "A tab works in this pull request's worktree (G goes there)", "as it is now, the rows rebuilt")
	same(actionOf(b, "goto").keys, { "G" }, "like the button's keycap")
	w.kv.put("keys", { ["goto"] = "" })
	b.render()
	eq(tip(), "A tab works in this pull request's worktree", "and not at all once it is removed")
	eq(actionOf(b, "goto"), nil, "nor is the button shown")
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

case("host: the command palette's menu lists the queue actions and the commands the block offers now, in typed groups, and a queue event runs only one of those", function(w: World)
	local s = hostScene(w, 3)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	eq(findKey(b.view().main, "more").p.href, "plotroom://more", "the palette's link is always on screen, for the window to check")
	local p = hx.palette(w, b)
	local expectedIds: { string } = { "open", "worktree", "copy-link", "copy-number", "copy-branch", "seen", "snooze", "snoozed", "attention", "sort", "search", "refresh" }
	for _, scope in pickerOf(b).scopes do
		table.insert(expectedIds, "scope:" .. scope.id)
	end
	table.insert(expectedIds, "settings")
	table.insert(expectedIds, "help")
	same(p.ids, expectedIds, "the selected item's, then the view's, every sidebar scope in the sidebar's order and the configuration's: no Go to tab or Go to agent without a tab or an agent, no Unpin without a pin, and no agent picker")
	eq(p.ids[#p.ids - 4], "scope:worktrees", "the Worktrees list is the last scope but two")
	eq(p.ids[#p.ids - 3], "scope:agents", "the Agents list the last but one")
	eq(p.ids[#p.ids - 2], "scope:inbox", "the Inbox list the last")
	eq(p.labels.open, "Open in GitHub", "Open names the integration")
	eq(p.keys.worktree, "", "an action without a key says none")
	eq(p.groups.open, "GitHub - PR", "the selected pull request's actions carry its type, not an Item heading")
	eq(p.groups.seen, "Triage", "marking seen is Triage")
	eq(p.groups.snooze, "Triage", "so is snoozing")
	eq(p.groups.sort, "Filter & Sort", "the view's actions are the Filter & Sort group")
	eq(p.groups.refresh, "Filter & Sort", "with Refresh")
	eq(p.groups["scope:prs:v2"], "Views", "every sidebar scope is a Views row")
	eq(p.labels["scope:worktrees"], "Worktrees list", "the one before the last is the Worktrees list")
	eq(p.groups.settings, "Configuration", "Settings and the shortcut list are Configuration")
	same(p.commands, { "open-url", "export", "import", "open-preview", "pr-draft", "pr-approve", "pr-request-changes", "comment" }, "the commands: the ones that need no item, the floating preview, then what an open pull request takes (no merge without a known head, no branch update unless behind)")
	eq(p.commandGroups["pr-draft"], "GitHub - PR", "a pull request's operation is under GitHub - PR")
	eq(p.commandGroups.comment, "GitHub - PR", "and so is its comment")
	eq(p.commandGroups["open-url"], nil, "one that needs no item has only its own group")
	request(b, "c2", { op = "menu" })
	w.flush()
	eq(answerOf(b, "c2").queue, nil, "the agent picker's menu carries no queue actions")
	eq(answerOf(b, "c2").commands, nil, "nor commands")
	local opened = #w.opened
	b.event({ ev = "action", act = "queue", value = "goto" })
	b.event({ ev = "action", act = "queue", value = "unpin" })
	b.event({ ev = "action", act = "queue", value = "agent" })
	b.event({ ev = "action", act = "queue", value = "rm" })
	eq(#w.opened, opened, "an action not offered now does nothing")
	b.event({ ev = "action", act = "queue", value = "worktree" })
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "an offered one runs as its key would")
	b.event({ ev = "action", act = "queue", value = "refresh" })
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "Refresh searches again")
	b.event({ ev = "action", act = "queue", value = "search" })
	eq(pickerOf(b).query, "", "Search opens the search")
end)

case("host: pasting into the queue opens and pins the first item URL in the text, text without one toasts, and a paste during search edits the query", function(w: World)
	local s = hostScene(w, 3)
	local url = "https://github.com/o/r/pull/45"
	s.gh.pulls[url] = searchItem(45, "o/r", EPOCH - 600, { title = "Fix the login redirect" })
	local b = openQueue(w)
	b.press("paste", nil, "see https://example.com/x then (" .. url .. "), thanks")
	w.flush()
	eq(pickerOf(b).scope, "pin:o/r#45", "the URL is fetched and pinned")
	eq(requestsOf(s.gh, "pull")[1].fields.q, url, "gh looked it up by the URL, without the closing parenthesis and comma")
	eq(w.toasts[#w.toasts].text, "Showing o/r#45 in Plotroom", "and the outcome is a toast")
	local toasts = #w.toasts
	b.press("paste", nil, "nothing to open here")
	eq(#w.toasts, toasts + 1, "text without an item URL toasts")
	eq(w.toasts[#w.toasts].text, "No item URL pasted", "saying so")
	eq(pickerOf(b).scope, "pin:o/r#45", "and changes nothing")
	local before = pickerOf(b).cursor
	for _, t in { "j", "k" } do
		b.press("paste", nil, t)
	end
	eq(#w.toasts, toasts + 3, "pasting a bound movement key toasts too")
	eq(pickerOf(b).cursor, before, "and does not move the cursor")
	b.typeText("/")
	b.press("paste", nil, "login")
	eq(pickerOf(b).query, "login", "a paste during search edits the search")
	eq(#w.toasts, toasts + 3, "with no toast")
end)

case("host: the palette copies the selected item's link, number and branch, and the title counts what is new", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	local p = hx.palette(w, b)
	eq(p.labels["copy-link"], "Copy link", "Copy link is offered")
	eq(p.labels["copy-number"], "Copy number", "so is Copy number")
	eq(p.labels["copy-branch"], "Copy branch", "and Copy branch for a pull request's head")
	local item = s.gh.items.octocat[1]
	b.event({ ev = "action", act = "queue", value = "copy-link" })
	b.event({ ev = "action", act = "queue", value = "copy-number" })
	b.event({ ev = "action", act = "queue", value = "copy-branch" })
	same(w.copied, { item.url, "#" .. item.number, item.head }, "each row copies its text")
	eq(b.title(), "Plotroom · My PRs (3) · 2 new", "the selected one is marked seen as it is read: two are still new")
end)

case("host: the palette's Views rows show the sidebar's scopes as a click does, and a scope the sidebar no longer lists is refused", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local p = hx.palette(w, b)
	b.event({ ev = "action", act = "queue", value = "scope:prs:v2" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v2", "a view's row shows the view")
	eq(pickerOf(b).selected ~= nil, true, "on its first item")
	b.event({ ev = "action", act = "queue", value = "scope:worktrees" })
	w.flush()
	eq(pickerOf(b).scope, "worktrees", "the Worktrees list's row shows the list")
	p = hx.palette(w, b)
	eq(p.groups["scope:prs:v1"], "Views", "its Views rows are the same")
	eq(p.groups["wt-cleanup"], "Worktree", "next to its own operations")
	eq(p.groups.refresh, "Filter & Sort", "and Refresh")
	b.event({ ev = "action", act = "queue", value = "scope:prs:gone" })
	w.flush()
	eq(pickerOf(b).scope, "worktrees", "a view that is not in the sidebar goes nowhere")
	b.event({ ev = "action", act = "queue", value = "scope:prs:v1" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "a listed view does")
end)

case("host: the palette's Views rows list the pins first like the sidebar and reach them, and a pin the sidebar no longer lists is refused", function(w: World)
	local s = hostScene(w, 3)
	local url = "https://github.com/o/r/pull/45"
	s.gh.pulls[url] = searchItem(45, "o/r", EPOCH - 600, { title = "Fix the login redirect" })
	local b = openQueue(w)
	b.event({ ev = "action", act = "show-pr", value = url })
	w.flush()
	local p = hx.palette(w, b)
	local scopes: { string } = {}
	for _, id in p.ids do
		if string.sub(id, 1, 6) == "scope:" then
			table.insert(scopes, id)
		end
	end
	local expectedScopes: { string } = {}
	for _, scope in pickerOf(b).scopes do
		table.insert(expectedScopes, "scope:" .. scope.id)
	end
	same(scopes, expectedScopes, "the sidebar's scopes in its order")
	eq(scopes[1], "scope:pin:o/r#45", "the pin first")
	eq(p.labels["scope:pin:o/r#45"], "o/r#45", "named as the sidebar names it")
	eq(p.details["scope:pin:o/r#45"], "Pins", "under its Pins group")
	b.event({ ev = "action", act = "queue", value = "scope:prs:v1" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "a view's row leaves the pin")
	b.event({ ev = "action", act = "queue", value = "scope:pin:o/r#45" })
	w.flush()
	eq(pickerOf(b).scope, "pin:o/r#45", "the pin's row shows it")
	eq(pickerOf(b).selected, "no_2fr_2345", "on its item")
	b.event({ ev = "action", act = "unpin" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "unpinning leaves it")
	b.event({ ev = "action", act = "queue", value = "scope:pin:o/r#45" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "a menu that still lists the dropped pin cannot show it")
end)


case("host: with nothing listed the palette offers no item action, and its commands are the ones that need no item", function(w: World)
	hostScene(w, 0)
	local b = openQueue(w)
	local p = hx.palette(w, b)
	eq(pickerOf(b).selected, nil, "nothing is selected in an empty list")
	eq(table.find(p.ids, "open"), nil, "so no item action is offered")
	eq(p.groups.snoozed, "Filter & Sort", "the view's and the sidebar's remain")
	eq(p.groups["scope:prs:v1"], "Views", "every scope still")
	same(p.commands, { "open-url", "export", "import" }, "and the commands that need no item")
	local opened = #w.opened
	b.event({ ev = "action", act = "queue", value = "worktree" })
	eq(#w.opened, opened, "an item action does nothing with nothing selected")
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
	eq(prefsOf(b).focus, "vopen:prs:v1", "the first view is a one-row summary")
	expand(b, "vopen:prs:v1")
	eq(prefsOf(b).focus, "name:prs:v1", "the first row is focused")
	b.press("enter")
	eq(prefsOf(b).editing.row, "name:prs:v1", "Enter starts the edit")
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
	b.event({ ev = "select", id = "layer.settings", item = "query:prs:v1" })
	b.press("enter")
	for _ = 1, 18 do
		b.press("backspace")
	end
	b.press("enter")
	eq(rowIn(b, "query:prs:v1").warning, "A query is required.", "the rejected query is explained under its row")
	eq(prefsOf(b).editing.row, "query:prs:v1", "the edit stays open for a correction")
	eq(prefsOf(b).editing.draft, "", "with the draft")
	eq(w.kv.get("views-prs").items[1].query, "is:open author:@me", "nothing was saved")
	eq(#requestsOf(s.gh, "search"), 1, "and nothing was searched")
	b.typeText("is:open label:bug")
	b.press("enter")
	eq(rowIn(b, "query:prs:v1").warning, nil, "a saved value clears the warning")
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
	expand(b, "vopen:prs:v1")
	w.kv.failSet["views-prs"] = "read-only file system"
	b.press("enter")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "Enter on unchanged text only closes the edit")
	eq(rowIn(b, "name:prs:v1").warning, nil, "without a write, so without a warning")
	b.press("enter")
	b.typeText("2")
	b.press("enter")
	has(rowIn(b, "name:prs:v1").warning, "read-only file system", "a failed write is explained under its row")
	eq(prefsOf(b).editing.draft, "My PRs2", "the draft is kept for another try")
	eq(w.kv.get("views-prs").items[1].name, "My PRs", "nothing was written")
	w.kv.failSet["views-prs"] = nil
	b.press("enter")
	eq(rowIn(b, "name:prs:v1").warning, nil, "the retry saved it and cleared the warning")
	eq(w.kv.get("views-prs").items[1].name, "My PRs2", "the draft was saved")
end)

case("host: a opens the selected PR's agent link", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local n = tonumber(string.match(pickerOf(b).selected, "_23(%d+)$")) :: number
	local link: any = findKey(pickerNode(b), "agent")
	eq(link.p.href, prLink("agent", "o/r", n), "the card keeps the selected PR's Agent link")
	eq(findKey(pickerNode(b), "buttons").p.hidden, true, "the card keeps its links in an unseen node")
	b.typeText("a")
	eq(w.opened[#w.opened], prLink("agent", "o/r", n), "a opens it")
end)

case("host: setup commands are added, edited and removed per repository; unreadable ones are never overwritten", function(w: World)
	hostScene(w, 3)
	w.kv.put("setup-commands", { ["x/y"] = array({ "make" }) })
	local b = openQueue(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
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
	local defaults: { any } = { { count = 3, group = "o/r", label = "o/r" }, "no_2fr_231", "no_2fr_232", "no_2fr_233" } -- My PRs, by repository
	same(pickerOf(b).order, defaults, "the queue still works with the default views")
	has(b.text(), "disk offline", "the cause is on screen")
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	has(rowIn(b, "name:prs:v1").disabled, "disk offline", "the rows are locked, with the cause")
	has(rowIn(b, "query:prs:v1").disabled, "disk offline", "and so is every other row of the form")
	same(w.kv.get("views-prs"), saved, "the saved views were not overwritten")
	w.kv.failGet["views-prs"] = nil
	w.kv.put("views-prs", { version = 2 })
	local other = openQueue(w, 2)
	same(pickerOf(other).order, defaults, "malformed views show the defaults too")
	same(w.kv.get("views-prs"), { version = 2 }, "and are not overwritten either")
end)

case("host: a first run saves the default views of both kinds, Add creates one, and Delete asks the window to confirm", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	local store: any = w.kv.store
	store["views-prs"], store["views-issues"] = nil, nil
	s.gh.tokens.octocat = "tok-octocat" -- a view with its own login runs as it, by token
	local b = openQueue(w)
	same(hx.viewRows(w, "views-prs"), {
		"v1 My PRs · github · repo",
		"v2 Review requested · github · none · oldest",
	}, "the default pull request views were saved: the review queue oldest first, My PRs by repository")
	same(hx.viewRows(w, "views-issues"), {
		"v1 Assigned to me · github · repo",
		"v2 Created by me · github · repo",
		"v3 My sprint · jira · status",
		"v4 Up for grabs · jira · none",
		"v5 My epics · jira · status",
	}, "and the default issue views beside them, in a store of their own: the sprint ones too, as the site has sprints")
	for _, v in w.kv.get("views-issues").items do
		if v.integration == "jira" then
			has(v.query, if v.name == "My epics" then "hierarchyLevel = 1" else "hierarchyLevel < 1", "only My epics lists epics: " .. v.name)
		end
	end
	eq(requestsOf(s.gh, "search")[1].fields.q, "is:open author:@me archived:false is:pr sort:updated-desc", "My PRs searches every repository that is not archived")
	local byRepo: { any } = { { count = 3, group = "o/r", label = "o/r" }, "no_2fr_231", "no_2fr_232", "no_2fr_233" }
	same(pickerOf(b).order, byRepo, "under a header per repository")
	goToSettings(b, "views")
	eq(rowIn(b, "vrestore:github:octocat"), nil, "with every default there, the account has nothing to restore")
	eq(rowIn(b, "vrestore:jira:"), nil, "nor has Jira")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "the signed-in account's Add saved a new view")
	same(w.kv.get("views-prs").items[3].logins, { "octocat" }, "for that account")
	eq(prefsOf(b).editing.row, "name:prs:v3", "and starts naming it")
	b.press("escape")
	eq(w.kv.get("views-prs").items[3].name, "New view", "cancelling the naming keeps the placeholder name")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "the new view became the active one and was searched")
	has(b.title(), "New view", "the title shows it")
	expand(b, "vopen:prs:v2")
	b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v2" })
	b.press("enter")
	local ask = pendingOf(b)
	same({ ask.row, ask.label }, { "delete:prs:v2", "Delete view" }, "Delete asks the window to confirm: this row, this action")
	has(ask.head, "Review requested", "naming the view")
	eq(w.opened[#w.opened], "plotroom://confirm", "through the window's link")
	eq(findKey(b.view().layer, "confirm"), nil, "Settings draws no overlay of its own")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "delete:prs:v1" })
	eq(#w.kv.get("views-prs").items, 3, "a confirmation of another row deletes nothing")
	b.typeText("d")
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "d and Enter do not confirm it")
	b.event({ ev = "action", id = "layer.settings", act = "cancel-delete", value = ask.row })
	eq(pendingOf(b), nil, "cancelling clears the question")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = ask.row })
	eq(#w.kv.get("views-prs").items, 3, "and a late confirmation deletes nothing")
	b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v2" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = ask.row })
	eq(pendingOf(b), nil, "confirming closes the question")
	local items = w.kv.get("views-prs").items
	eq(#items, 2, "and deletes the view")
	eq(items[2].id, "v3", "the other views stay")
	expand(b, "vopen:prs:v3")
	b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v3" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "delete:prs:v3" })
	w.flush()
	eq(#w.kv.get("views-prs").items, 1, "the active view can be deleted too")
	eq(pickerOf(b).scope, "issues:v1", "the filter now at its place in the list is shown: the pull request filters are followed by the issue filters")
end)

case("host: a first run saves its issue views once the Jira site said whether it has sprints; without them there is no sprint view until a Refresh finds some and Restore defaults adds them", function(w: World)
	hostScene(w, 3)
	local acli = newAcli(w)
	local store: any = w.kv.store
	store["views-issues"] = nil
	-- What a site without sprints starts with: the issue defaults but the sprint ones, each under its own id.
	local noSprint = {
		"v1 Assigned to me · github · repo",
		"v2 Created by me · github · repo",
		"v5 My epics · jira · status",
	}
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "sprints" then { delay = 1000, status = 1, stderr = "✗ Error: failed to parse JQL query: field 'sprint' does not exist or you do not have permission to view it.\n" } else nil
	end
	local b = openQueue(w)
	eq(w.kv.get("views-issues"), nil, "the issue views are not saved while the site has not answered")
	w.advance(1000)
	same(hx.viewRows(w, "views-issues"), noSprint, "then saved without the sprint views, the others keeping their ids")
	eq(w.kv.get("views-issues").nextId, 6, "and a new view never takes a left-out one's id")
	goToSettings(b, "views")
	eq(rowIn(b, "vrestore:jira:"), nil, "nothing to restore while the site has no sprints")
	b.press("escape")
	acli.override = nil -- the site has sprints now
	refreshNow(w, b) -- Refresh asks again
	goToSettings(b, "views")
	eq(rowIn(b, "vrestore:jira:").control.act, "restore-views", "the site has sprints now: Jira's group offers the sprint views")
	b.event({ ev = "action", id = "layer.settings", act = "restore-views", value = "vrestore:jira:" })
	local restored = table.clone(noSprint)
	for _, row in { "v6 My sprint · jira · status", "v7 Up for grabs · jira · none" } do
		table.insert(restored, row)
	end
	same(hx.viewRows(w, "views-issues"), restored, "Restore defaults saved them after the others, under new ids")
	eq(rowIn(b, "vrestore:jira:"), nil, "and is gone with nothing left to restore")
	eq(prefsOf(b).focus, "vadd:jira:", "Add takes the focus")
end)

case("host: an account's Restore defaults saves back the default views its group has none named like, as that account's; a failed save is told and changes nothing", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat"
	w.kv.put("views-issues", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Assigned to me", integration = "github", query = "is:open assignee:@me label:mine", group = "none", prompts = array({}) },
		{ id = "v2", name = "Assigned to me", integration = "jira", query = "assignee = currentUser()", group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	w.kv.failSet["views-issues"] = "disk full"
	b.event({ ev = "action", id = "layer.settings", act = "restore-views", value = "vrestore:github:octocat" })
	has(rowIn(b, "vrestore:github:octocat").warning, "disk full", "a failed save is told on its row")
	eq(#w.kv.get("views-issues").items, 2, "and saved nothing")
	w.kv.failSet["views-issues"] = nil
	b.event({ ev = "action", id = "layer.settings", act = "restore-views", value = "vrestore:github:octocat" })
	same(hx.viewRows(w, "views-prs"), {
		"v1 My PRs · github · none",
		"v2 Review requested · github · none",
	}, "the views named like a default stay as saved: every pull request default is there")
	same(hx.viewRows(w, "views-issues"), {
		"v1 Assigned to me · github · none",
		"v2 Assigned to me · jira · none",
		"v3 Created by me · github · repo",
	}, "and the missing GitHub issue view in the issue store; Jira's views are its own group's")
	same(w.kv.get("views-issues").items[3].logins, { "octocat" }, "running as the group's account")
	eq(w.kv.get("views-issues").items[1].query, "is:open assignee:@me label:mine", "an edited default is never replaced")
	eq(rowIn(b, "vrestore:github:octocat"), nil, "nothing is left to restore")
	yes(rowIn(b, "vrestore:jira:") ~= nil, "while Jira still has defaults to restore")
end)

windowCase("window: a Settings delete is confirmed in the palette with Cancel first; only the destructive item deletes, Cancel and dismissing delete nothing", function(w: World)
	local _, b = agentScene(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v2")
	-- Presses Delete on the second view and follows the link the block opened; returns the question and the picker the window showed.
	local function ask(): (any, any)
		b.event({ ev = "select", id = "layer.settings", item = "delete:prs:v2" })
		b.press("enter")
		local question = pendingOf(b)
		w.click(w.opened[#w.opened])
		w.flush()
		return question, w.window.picks[#w.window.picks]
	end
	local function views(): number
		return #w.kv.get("views-prs").items
	end
	local function lastEvent(): any
		return w.window.events[#w.window.events]
	end
	w.window.choose = "Cancel"
	local question, pick = ask()
	eq(#pick.items, 2, "two items")
	same({ pick.items[1].label, pick.items[1].icon }, { "Cancel", "x" }, "Cancel comes first")
	same({ pick.items[2].label, pick.items[2].detail, pick.items[2].icon, pick.items[2].confirm }, { question.label, question.detail, "trash", true }, "the destructive item second, as the block worded it")
	same({ pick.placeholder, pick.icon }, { question.head, "trash" }, "under the block's question")
	same(lastEvent(), { pane = 1, ev = { ev = "action", act = "cancel-delete", value = "delete:prs:v2" } }, "Cancel tells the pane to drop the question")
	eq(pendingOf(b), nil, "which does")
	eq(views(), 2, "and nothing is deleted")
	w.window.choose = nil
	ask()
	same(lastEvent(), { pane = 1, ev = { ev = "action", act = "cancel-delete", value = "delete:prs:v2" } }, "dismissing the picker cancels too")
	eq(views(), 2, "and nothing is deleted")
	w.window.choose = "Delete view"
	ask()
	same(lastEvent(), { pane = 1, ev = { ev = "action", act = "confirm-delete", value = "delete:prs:v2" } }, "the destructive item tells the pane to delete that row")
	eq(views(), 1, "the view is deleted")
	eq(pendingOf(b), nil, "and the question is closed")
end)

windowCase("window: the confirm link is refused from a pane of another version or another block, and with nothing pending", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local surface: any = w.window.surfaces[1]
	local question = jsonEncode({ row = "delete:prs:v2", head = "Delete view “B”?", label = "Delete view", detail = "Gone from every Plotroom pane" })
	local function refused(text: string, what: string, pane: number?)
		local said = #w.toasts
		w.click("plotroom://confirm", pane)
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		has(w.toasts[#w.toasts].text, text, what .. ": what is wrong")
		eq(#w.window.picks + #w.window.events, 0, what .. ": nothing was picked or sent")
	end
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = "2", hidden = true } }, { id = "main.confirm", p = { text = question, hidden = true } } } }
	refused("another version", "another protocol")
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = asks.protocol, hidden = true } } } }
	refused("nothing to delete", "no question")
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = asks.protocol, hidden = true } }, { id = "main.confirm", p = { text = "{not json", hidden = true } } } }
	refused("nothing to delete", "a malformed question")
	refused("did not come from a Plotroom block", "a pane that is not Plotroom", 2)
end)

case("host: Tab cycles the Settings pages in order, Views, Prompts, Keys, Worktrees, Repositories, Jira, Refresh, and Shift+Tab goes back; they are the same whichever kind of filter is shown", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	local b = openQueue(w)
	b.typeText("s")
	local pages: { string } = { prefsOf(b).page }
	for _ = 1, 7 do
		b.press("tab")
		table.insert(pages, prefsOf(b).page)
	end
	same(pages, { "views", "prompts", "keys", "worktrees", "repos", "jira", "connection", "views" }, "Tab walks the pages and wraps around")
	b.press("tab", "s")
	eq(prefsOf(b).page, "connection", "Shift+Tab goes back, wrapping the other way")
	b.press("escape")
	b.typeText("s")
	eq(prefsOf(b).page, "connection", "Settings reopens on the page it last showed")
	b.press("escape")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	eq(prefsOf(b).page, "connection", "and so does its button")
	local function ids(): { string }
		local out: { string } = {}
		for _, p in prefsOf(b).pages do
			table.insert(out, p.id)
		end
		return out
	end
	local expected = { "views", "prompts", "keys", "worktrees", "repos", "jira", "connection" }
	same(ids(), expected, "a pull request filter's pages")
	local byId: { [string]: any } = {}
	for _, p in prefsOf(b).pages do
		byId[p.id] = p
	end
	same(byId.worktrees, { id = "worktrees", label = "Worktrees", group = "Code", icon = "tree" }, "Worktrees is a page of the Code group")
	same(byId.connection, { id = "connection", label = "Refresh", group = "Connection", icon = "gauge" }, "and Refresh the Connection group's")
	b.press("escape")
	pickScope(b, "issues:v1")
	b.typeText("s")
	same(ids(), expected, "are an issue filter's")
end)

case("host: a view's Group by is a menu: Enter opens it, the arrows and the pointer move the highlight, Esc closes it, Enter saves; the integration cannot be changed", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", query = "is:open label:x", logins = array({ "work" }), group = "none", prompts = array({}) } }) })
	local b = w.open(1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "issues", activeViewId = "v1" })
	w.flush()
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	eq(rowIn(b, "vint:issues:v1"), nil, "the form has no Integration row")
	b.event({ ev = "change", id = "layer.settings", item = "vint:issues:v1", value = "jira" })
	eq(w.kv.get("views-issues").items[1].integration, "github", "an event for it changes nothing")
	b.event({ ev = "change", id = "layer.settings", item = "vint:issues:v1" })
	eq(w.kv.get("views-issues").items[1].query, "is:open label:x", "and so does Reset on it")
	-- Group by is a menu: Enter opens it on the current option, the arrows move the highlight, Enter picks and closes it.
	local vgroup = "vgroup:issues:v1"
	local menu: any = rowIn(b, vgroup).control
	eq(menu.k, "choice", "Group by is a choice")
	eq(menu.style, "menu", "shown as a menu")
	eq(menu.value, "none", "on None after the integration switched")
	local second: string = menu.options[2].value
	b.event({ ev = "select", id = "layer.settings", item = vgroup })
	b.press("enter")
	same(prefsOf(b).editing, { row = vgroup, option = "none" }, "Enter opens the menu on the current option")
	b.press("down")
	eq(prefsOf(b).editing.option, second, "Down moves the highlight")
	b.press("up")
	eq(prefsOf(b).editing.option, "none", "Up moves it back")
	b.press("right")
	eq(prefsOf(b).editing.option, second, "and so do the other arrows")
	b.event({ ev = "select", id = "layer.settings", item = vgroup .. "=none" })
	eq(prefsOf(b).editing.option, "none", "the pointer on an option moves the highlight there")
	eq(prefsOf(b).focus, vgroup, "without moving the focus")
	eq(w.kv.get("views-issues").items[1].group, "none", "or saving anything")
	b.event({ ev = "action", id = "layer.settings", act = "close", value = vgroup })
	eq(prefsOf(b).editing, nil, "a click outside closes the menu")
	b.press("enter")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc closes it too")
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "leaving Settings open")
	b.press("enter")
	b.press("down")
	b.press("enter")
	eq(w.kv.get("views-issues").items[1].group, second, "Enter on the highlighted option saves it")
	eq(prefsOf(b).editing, nil, "and closes the menu")
	eq(rowIn(b, vgroup).control.value, second, "the row shows it")
end)

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
	savePrompts(w, {})
	local b = openQueue(w)
	goToSettings(b, "prompts")
	eq(prefsOf(b).focus, "padd:prs", "with nothing saved the Add row is the first")
	b.press("enter")
	same(w.kv.get("prompts-prs"), { version = 1, nextId = 2, items = array({ promptOf("p1", "New action", "") }) }, "Add saves a prompt with no text at once, offered under every view")
	eq(prefsOf(b).editing.row, "pname:prs:p1", "and starts naming it")
	eq(prefsOf(b).editing.draft, "", "from an empty draft")
	eq(editorCard(b), nil, "the text editor waits for the name")
	eq(caretOf(w), nil, "and the caret has not been moved")
	b.press("enter")
	eq(rowIn(b, "pname:prs:p1").warning, "A name is required.", "an empty name is refused under its row")
	eq(prefsOf(b).editing.row, "pname:prs:p1", "and the name edit stays open")
	eq(w.kv.get("prompts-prs").items[1].name, "New action", "with nothing saved")
	b.typeText(string.rep("n", 121))
	b.press("enter")
	eq(rowIn(b, "pname:prs:p1").warning, "A name is at most 120 characters.", "a name over 120 characters is refused under its row")
	eq(w.kv.get("prompts-prs").items[1].name, "New action", "with nothing saved")
	b.press("a", "c")
	b.press("backspace")
	b.typeText("Review")
	b.press("enter")
	eq(w.kv.get("prompts-prs").items[1].name, "Review", "Enter saves the name")
	eq(prefsOf(b).editing, nil, "the name edit is over")
	yes(editorCard(b) ~= nil, "and a prompt with no text opens its text editor next")
	eq(editorCard(b).p.role, "omp.prefs.editor", "in the editor card")
	eq(findKey(editorCard(b), "head", "text").p.spans[1].t, "Prompt · Review", "which names the prompt")
	eq(draftOf(b), "", "with nothing in it")
	eq(caretOf(w), "layer.settings.prompt.draft", "and the caret in its field")
	eq(prefsOf(b).focus, "ptext:prs:p1", "the prompt's text row is the focused one")
	eq(rowIn(b, "ptext:prs:p1").hint, "Empty", "and says it is empty")
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
	eq(rowIn(b, "ptext:prs:p1").hint, "Review {url}", "the row shows the text's first line")
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
	savePrompts(w, {})
	local b = openQueue(w)
	goToSettings(b, "prompts")
	b.press("enter")
	b.typeText("New action")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "the name edit is over")
	eq(w.kv.get("prompts-prs").items[1].name, "New action", "the name stays what it was")
	yes(editorCard(b) ~= nil, "and the prompt, still with no text, opens its text editor")
	eq(caretOf(w), "layer.settings.prompt.draft", "with the caret in its field")
end)

case("host: a prompt's text that is empty or over 8000 bytes stays in the editor with the card's warning; Save and Cancel act like ⌘Enter and Esc", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	b.press("down")
	eq(prefsOf(b).focus, "ptext:prs:p1", "the prompt's text row")
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
	expand(b, "vopen:prs:v1")
	b.event({ ev = "select", id = "layer.settings", item = "vprompts:prs:v1" })
	eq(prefsOf(b).focus, "vprompts:prs:v1", "the view's Prompts row")
	local chips: any = rowIn(b, "vprompts:prs:v1").control
	same(chips.values, array({}), "a view that lists none offers every prompt")
	eq(#chips.options, 2, "among all the prompts")
	eq(chips.options[2].value, "p2", "by id")
	eq(chips.options[2].label, "Triage", "and name")
	local function saved(): any
		return w.kv.get("views-prs").items[1].prompts
	end
	local function changed(values: { any })
		b.event({ ev = "change", id = "layer.settings", item = "vprompts:prs:v1", value = array(values) })
	end
	changed({ "p2", "gone" })
	same(saved(), { "p2" }, "a change saves only the prompts that still exist")
	same(rowIn(b, "vprompts:prs:v1").control.values, { "p2" }, "and the row shows them")
	changed({ "p2", "p1" })
	same(saved(), { "p1", "p2" }, "in the prompts' order")
	changed({ "gone" })
	same(saved(), array({}), "none left means every prompt")
	b.press("enter")
	eq(prefsOf(b).editing.row, "vprompts:prs:v1", "Enter starts picking: the chips take the keys")
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
	eq(prefsOf(b).focus, "vopen:prs:v2", "and does what it does")
	same(saved(), { "p1" }, "without changing the prompts")
end)

case("host: Delete on a prompt asks the window to confirm, naming it: confirming deletes it, cancelling keeps it", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	b.event({ ev = "select", id = "layer.settings", item = "pdelete:prs:p1" })
	b.press("enter")
	local ask = pendingOf(b)
	same({ ask.row, ask.head, ask.label }, { "pdelete:prs:p1", "Delete action “Review”?", "Delete action" }, "Delete asks the window to confirm, naming the prompt")
	eq(w.opened[#w.opened], "plotroom://confirm", "through the window's link")
	b.event({ ev = "action", id = "layer.settings", act = "cancel-delete", value = "pdelete:prs:p1" })
	eq(#w.kv.get("prompts-prs").items, 2, "cancelling keeps it")
	eq(pendingOf(b), nil, "and closes the question")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p1" })
	eq(#w.kv.get("prompts-prs").items, 2, "a confirmation of a question that is gone deletes nothing")
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p1" })
	local items = w.kv.get("prompts-prs").items
	eq(#items, 1, "confirming deletes it")
	eq(items[1].id, "p2", "the other prompt stays")
	eq(prefsOf(b).focus, "padd:prs", "and the Add row takes the focus")
	b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:p2" })
	eq(pendingOf(b).head, "Delete action “Triage”?", "the Delete button asks the same question")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p2" })
	eq(#w.kv.get("prompts-prs").items, 0, "and confirming it deletes that prompt")
end)

case("host: changing page or closing Settings drops an open text edit and gives the caret back", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	-- Opens Settings on the Prompts page with the prompt's text being edited.
	local function editing()
		goToSettings(b, "prompts")
		expand(b, "popen:prs:p1")
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
		b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:" .. id })
		b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:" .. id })
	end
	expand(b, "popen:prs:p2")
	b.event({ ev = "select", id = "layer.settings", item = "ptext:prs:p2" })
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
	expand(b, "popen:prs:p3")
	b.event({ ev = "select", id = "layer.settings", item = "pname:prs:p3" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "pname:prs:p3", "the name of another prompt is being edited")
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
		has(rowIn(b, "padd:prs").disabled, why, what .. ": Add is locked, with the reason")
		b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:prs" })
		b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:p1" })
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
	eq(rowIn(b, "padd:prs").disabled, nil, "a readable store unlocks Add")
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
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "For My PRs", send = "Look at {url}\nTwice", worktree = true },
	}, "a view that lists a prompt offers only it, in the group For the view")
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "prs:v2", "the second view is active")
	same(menu().items, {
		{ id = "p1", label = "Mine", detail = "Review {url}", group = "All actions", send = "Review {url}", worktree = true },
		{ id = "p2", label = "Anywhere", detail = "Look at {url}", group = "All actions", send = "Look at {url}\nTwice", worktree = true },
	}, "a view that lists none offers every prompt with text, as All actions")
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
	same(only("p1"), { { id = "p1", label = "Mine", detail = "Review {url}", group = "For My PRs", send = "Review {url}", worktree = true } }, "just the prompt asked for, in the group it has under the view")
	eq(#only("p2"), 0, "none that the view does not list")
	eq(#only("p4"), 0, "none with no text")
	eq(#only("p9"), 0, "none that is not saved")
end)

case("host: the picker's action bar has Settings and Refresh on the left, then the PR's Worktree, Go to tab and Agent by the command palette, with no button per prompt and Open in the preview's head; each opens the link the card keeps unseen, beside each offered prompt's", function(w: World)
	local s = hostScene(w, 3)
	savePrompts(w, {
		promptOf("p1", "Mine", "Review {url}", "e"),
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
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "one Agent button, none per saved prompt; Seen before the command palette, which is last")
	eq(action("more")["end"], true, "the command palette is last, in the corner")
	eq(action("more").label, "Commands", "named Commands")
	same(action("more").keys, { "." }, "with its key")
	eq(action("open"), nil, "Open is no button of the bar")
	local globe: any = findKey(findKey(pickerNode(b), "head"), "open", "icon")
	eq(globe.p.href, link("open"), "but an icon in the preview's head, opening the hidden Open link")
	eq(globe.p.actions.click, "open", "on click")
	eq(globe.p.title, "Open in GitHub", "named for the integration")
	eq(action("settings")["end"], nil, "Settings and Refresh sit on the left")
	eq(action("retry")["end"], nil, "both of them")
	eq(action("worktree")["end"], true, "the PR's buttons sit on the right, by Open")
	eq(action("agent")["end"], true, "Agent too")
	eq(action("agent").label, "Agent", "named Agent")
	same(action("agent").keys, { "a" }, "with the Agent picker's key")
	eq(findKey(pickerNode(b), "buttons").p.hidden, true, "the links sit in an unseen node")
	eq(link("agent"), prLink("agent", "o/r", 1), "Agent's link opens the picker on the selected pull request")
	eq(link("prompt-p1"), runLink("o/r", 1, "p1"), "each offered prompt's link runs it, for its shortcut")
	eq(link("prompt-p2"), runLink("o/r", 1, "p2"), "one with no shortcut too")
	eq(link("prompt-p3"), nil, "none for a prompt the view does not list")
	eq(link("prompt-p4"), nil, "or a blank one")
	eq(link("prompt-p-5"), nil, "or one whose id is no link")
	b.event({ ev = "action", id = "layer.queue", act = "agent" })
	eq(w.opened[#w.opened], prLink("agent", "o/r", 1), "a click opens the button's link")
	b.event({ ev = "action", id = "layer.queue", act = "worktree" })
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "Worktree's too")
	leaveWt(w, s, 1)
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-pr-1" })
	refreshNow(w, b)
	same(bar(), { "settings", "retry", "worktree", "goto", "agent", "seen", "more" }, "a tab in the pull request's worktree adds Go to tab before Agent")
	eq(link("goto"), prLink("goto", "o/r", 1), "with its link")
	table.remove(w.panes)
	b.press("tab")
	b.press("down")
	w.flush()
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "under Review requested the bar stays the same")
	eq(link("prompt-p3"), runLink("o/r", 1, "p3"), "and the prompt links swap")
	eq(link("prompt-p1"), nil, "for the ones it lists")
	b.press("e")
	eq(w.opened[#w.opened] == runLink("o/r", 1, "p1"), false, "a prompt the view does not list has no key")
	b.press("x")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p3"), "one it lists runs on its key, through its link")
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
		promptOf("p1", "Mine", "Review {url}", "e"),
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
	eq(b.press("e", nil, "e"), true, "the key is handled")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p1"), "and opens its prompt's run link for the selected pull request")
	eq(b.press("t", "s", "T"), true, "shift is allowed")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p2"), "a capital is a key of its own")
	b.press("down")
	b.typeText("e")
	eq(w.opened[#w.opened], runLink("o/r", 2, "p1"), "the link follows the selection")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 2), "a key the queue uses itself stays the queue's, whatever a prompt says")
	opened = #w.opened
	ignored("a key no prompt has", "q")
	ignored("a prompt of another view", "x")
	ignored("ctrl", "e", "c")
	ignored("alt", "e", "a")
	ignored("meta", "e", "m")
	b.typeText("/")
	b.typeText("e")
	eq(pickerOf(b).query, "e", "while searching the key is text")
	eq(#w.opened, opened, "and opens nothing")
	b.press("escape")
	b.press("escape")
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "prs:v2", "under the second view")
	ignored("a prompt of the first view", "e")
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

case("host: Settings > Actions' Next action row offers the other actions, refuses a loop, and deleting an action drops it as a next", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Fix", "Fix {url}"), promptOf("p3", "Ship", "Ship {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "pnext:prs:p1").control.value, "none", "an action starts with no next action")
	same(asks.hx.options(b, "pnext:prs:p1"), { "none", "p2", "p3" }, "the others are offered, never itself")
	b.event({ ev = "change", id = "layer.settings", item = "pnext:prs:p1", value = "p2" })
	eq(w.kv.get("prompts-prs").items[1].next, "p2", "choosing one saves it")
	eq(rowIn(b, "pnext:prs:p1").control.value, "p2", "the row shows it")
	expand(b, "popen:prs:p2")
	same(asks.hx.options(b, "pnext:prs:p2"), { "none", "p3" }, "an action that leads back is not offered")
	b.event({ ev = "change", id = "layer.settings", item = "pnext:prs:p2", value = "p1" })
	eq(w.kv.get("prompts-prs").items[2].next, nil, "a loop is refused and nothing is saved")
	has(rowIn(b, "pnext:prs:p2").warning, "loop", "with the reason on its row")
	b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:p2" })
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p2" })
	eq(#w.kv.get("prompts-prs").items, 2, "the action is deleted")
	eq(w.kv.get("prompts-prs").items[1].next, nil, "and no longer anyone's next action")
end)

case("host: an issue action's Next action also offers the pull request actions by kind, saved qualified; a pull request action never offers issue actions, and deleting one clears it as a next", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Watch", "Watch {url}") })
	w.kv.put("prompts-issues", { version = 1, nextId = 4, items = array({ promptOf("p1", "Implement", "Do {url}"), promptOf("p2", "Triage", "Triage {url}"), promptOf("p3", "Plan", "Plan {url}") }) })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:issues:p1")
	same(asks.hx.options(b, "pnext:issues:p1"), { "none", "p2", "p3", "prs:p1", "prs:p2" }, "the issue actions, then the pull request actions")
	eq(rowIn(b, "pnext:issues:p1").control.options[4].label, "Review (pull request)", "a pull request action is labelled by its kind")
	b.event({ ev = "change", id = "layer.settings", item = "pnext:issues:p1", value = "prs:p2" })
	eq(w.kv.get("prompts-issues").items[1].next, "prs:p2", "a pull request action is saved qualified")
	eq(rowIn(b, "pnext:issues:p1").control.value, "prs:p2", "and the row shows it")
	b.event({ ev = "change", id = "layer.settings", item = "pnext:issues:p1", value = "prs:p9" })
	has(rowIn(b, "pnext:issues:p1").warning, "deleted", "one that does not exist is refused")
	eq(w.kv.get("prompts-issues").items[1].next, "prs:p2", "and nothing is saved")
	b.event({ ev = "change", id = "layer.settings", item = "pnext:issues:p1", value = "p2" })
	eq(w.kv.get("prompts-issues").items[1].next, "p2", "a bare id stays an issue action")
	b.event({ ev = "change", id = "layer.settings", item = "pnext:issues:p1", value = "prs:p2" })
	expand(b, "popen:prs:p1")
	same(asks.hx.options(b, "pnext:prs:p1"), { "none", "p2" }, "a pull request action offers only pull request actions")
	b.event({ ev = "action", id = "layer.settings", act = "delete", value = "pdelete:prs:p2" })
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "pdelete:prs:p2" })
	eq(w.kv.get("prompts-issues").items[1].next, nil, "deleting the pull request action clears it as an issue action's next")
	eq(#w.kv.get("prompts-issues").items, 3, "the issue actions stay")
end)

case("host: a prompt's shortcut is one free key on the Keys page: the row refuses what the queue uses or another prompt has, and clearing it removes the key", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}", "t") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	local ids: { string } = {}
	for _, row in prefsOf(b).sections[1].rows do
		table.insert(ids, row.id)
	end
	same(ids, { "popen:prs:p1", "pdelete:prs:p1", "pname:prs:p1", "ptext:prs:p1", "pmodel:prs:p1", "pwhere:prs:p1", "psplit:prs:p1", "pcarly:prs:p1", "pnext:prs:p1" }, "an open prompt has Done and Delete, then its name, text, model, where it runs and opens, whether Carly is told, and its next action: no shortcut")
	goToSettings(b, "keys")
	local row = rowIn(b, "pkey:prs:p1")
	eq(row.label, "Review", "the Keys page has a row for the saved action, named for it")
	eq(sectionIn(b, "pkey:prs:p1").title, "Pull request actions", "under its kind's title")
	eq(row.control.value, "", "empty while the prompt has none")
	eq(row.control.placeholder, "None", "which it says")
	eq(rowIn(b, "pkey:prs:p2").control.value, "t", "and one for each other saved action, showing its key")
	b.event({ ev = "select", id = "layer.settings", item = "pkey:prs:p1" })
	-- Presses `key` ("" is Backspace) on the first prompt's shortcut row: what the row warns afterwards. Enter starts the
	-- capture; a refused key leaves it open, and the next call presses another key.
	local function try(key: string): string?
		if prefsOf(b).editing == nil then
			b.press("enter")
			eq(prefsOf(b).editing.draft, "", "the capture starts empty")
		end
		if key == "" then
			b.press("backspace")
		else
			b.typeText(key)
		end
		return rowIn(b, "pkey:prs:p1").warning
	end
	eq(try(" "), "One key: a single letter, digit or symbol.", "a space is no key")
	eq(prefsOf(b).editing.row, "pkey:prs:p1", "the capture stays open")
	for _, k in { "j", "k", "w", "g", "a", "G", "m", "z", "Z", "n", "o", ".", "/", "?", "r", "s" } do
		eq(try(k), "The queue already uses " .. k .. ".", "the queue's own " .. k .. " is refused")
		eq(prefsOf(b).editing.row, "pkey:prs:p1", "with the capture still open for another key")
	end
	eq(try("t"), "Already the shortcut of Triage.", "another prompt's key is refused")
	eq(w.kv.get("prompts-prs").items[1].key, nil, "nothing was saved")
	eq(try("e"), nil, "a free key is accepted at once, with no Enter")
	eq(prefsOf(b).editing, nil, "and closes the capture")
	same(w.kv.get("prompts-prs").items[1], { id = "p1", name = "Review", text = "Review {url}", key = "e" }, "it is saved as the prompt's key, the rest as it was")
	eq(w.kv.get("prompts-prs").items[2].key, "t", "another prompt keeps its key")
	eq(rowIn(b, "pkey:prs:p1").control.value, "e", "the row shows it")
	eq(try("A"), nil, "a capital is not the queue's a")
	eq(w.kv.get("prompts-prs").items[1].key, "A", "and is saved as typed")
	eq(try("é"), nil, "one character is one key, whatever its bytes")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and is saved")
	b.press("enter")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc cancels the capture")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and keeps the key")
	b.press("enter")
	b.press("enter")
	eq(prefsOf(b).editing, nil, "Enter cancels it too")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and keeps the key")
	b.press("enter")
	b.press("x", "c", "x")
	eq(prefsOf(b).editing.row, "pkey:prs:p1", "a key with ctrl is swallowed: the capture stays open")
	eq(w.kv.get("prompts-prs").items[1].key, "é", "and nothing is saved")
	b.press("escape")
	eq(try(""), nil, "Backspace is accepted")
	eq(w.kv.get("prompts-prs").items[1].key, nil, "and removes the key")
	eq(rowIn(b, "pkey:prs:p1").control.value, "", "which the row shows")
end)

case("host: a Keys row refuses a key another action or a saved prompt of either kind has, and a prompt's shortcut refuses the keys the queue uses now", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}", "e") })
	w.kv.put("prompts-issues", { version = 1, nextId = 2, items = array({ promptOf("p1", "Triage", "Triage {url}", "i") }) })
	w.kv.put("keys", { ["goto"] = "g" })
	local b = openQueue(w)
	goToSettings(b, "keys")
	eq(bindKey(b, "worktree", "g"), "Already the shortcut of Go to tab.", "another action's key is refused, naming the action")
	eq(prefsOf(b).editing.row, "key:worktree", "and the capture stays open for another key")
	eq(bindKey(b, "worktree", " "), "One key: a single letter, digit or symbol.", "a space is no key")
	eq(prefsOf(b).editing.row, "key:worktree", "and the capture is still open")
	eq(bindKey(b, "worktree", "e"), "Already the shortcut of the pull request action “Review”.", "a pull request prompt's key is refused, naming the prompt")
	eq(bindKey(b, "worktree", "i"), "Already the shortcut of the issue action “Triage”.", "and an issue prompt's")
	same(w.kv.get("keys"), { ["goto"] = "g" }, "nothing was saved")
	eq(bindKey(b, "worktree", "x"), nil, "a free key is saved at once, with no Enter")
	eq(prefsOf(b).editing, nil, "and closes the capture")
	same(w.kv.get("keys"), { ["goto"] = "g", worktree = "x" }, "beside the other key")
	b.press("enter")
	b.press("escape")
	eq(prefsOf(b).editing, nil, "Esc cancels a capture")
	same(w.kv.get("keys"), { ["goto"] = "g", worktree = "x" }, "and keeps the old key")
	eq(bindKey(b, "worktree", ""), nil, "Backspace is accepted")
	same(w.kv.get("keys"), { ["goto"] = "g", worktree = "" }, "and removes the shortcut, saved as a deliberate no key")
	eq(bindKey(b, "goto", "Q"), nil, "an action's key is free once it has moved")
	eq(bindKey(b, "worktree", "g"), nil, "and another action can have it")
	same(w.kv.get("keys"), { ["goto"] = "Q", worktree = "g" }, "both are saved")
	b.event({ ev = "select", id = "layer.settings", item = "pkey:prs:p1" })
	-- Presses `key` on the prompt's shortcut row: the warning under its row afterwards.
	local function try(key: string): string?
		if prefsOf(b).editing == nil then
			b.press("enter")
		end
		b.typeText(key)
		return rowIn(b, "pkey:prs:p1").warning
	end
	eq(try("Q"), "The queue already uses Q.", "a prompt cannot take the key an action moved to")
	eq(try("w"), nil, "but takes the one the action gave up")
	eq(w.kv.get("prompts-prs").items[1].key, "w", "and it is saved")
	b.press("escape")
	b.typeText("w")
	eq(w.opened[#w.opened], runLink("o/r", 1, "p1"), "the prompt's key runs it")
	b.typeText("g")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and the action's new key makes the worktree")
end)

case("host: unreadable or malformed saved keys lock the Keys rows with the reason, the default keys keep working, and nothing is written over them", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "keys")
	-- Tries every way to write the keys while they cannot be loaded: `why` is what the rows must say.
	local function locked(what: string, why: string)
		b.render()
		local stored = w.kv.store["keys"]
		for _, r in prefsOf(b).sections[1].rows do
			has(r.disabled, why, what .. ": " .. r.id .. " is locked, with the reason")
		end
		b.event({ ev = "activate", id = "layer.settings", item = "key:worktree" })
		eq(prefsOf(b).editing, nil, what .. ": no edit opens")
		b.event({ ev = "change", id = "layer.settings", item = "key:worktree" })
		has(rowIn(b, "key:worktree").warning, why, what .. ": Reset says why")
		eq(w.kv.store["keys"], stored, what .. ": nothing was written over it")
	end
	local malformed: { any } = { "garbage", { worktree = 5 }, { worktree = "ww" }, { worktree = "a b" }, array({ "w" }) }
	for i, value in malformed do
		w.kv.put("keys", value)
		locked("malformed value " .. i, "malformed")
	end
	w.kv.put("keys", { more = "," })
	w.kv.failGet["keys"] = "disk offline"
	locked("an unreadable store", "disk offline")
	b.press("escape")
	eq(b.press(",", nil, ","), false, "the saved key is not in use while the keys cannot be read")
	eq(b.press(".", nil, "."), true, "the default one is")
	w.kv.failGet["keys"] = nil
	eq(b.press(",", nil, ","), true, "readable again, the saved key works")
	goToSettings(b, "keys")
	b.event({ ev = "select", id = "layer.settings", item = "key:goto" })
	b.press("enter")
	w.kv.put("keys", "garbage")
	local stored = w.kv.store["keys"]
	b.typeText("Q")
	has(rowIn(b, "key:goto").warning, "malformed", "a key pressed after the keys went bad is refused")
	eq(w.kv.store["keys"], stored, "and nothing is written over them")
	eq(prefsOf(b).editing.draft, "Q", "the capture stays open")
	w.kv.put("keys", { worktree = "W" })
	w.kv.failSet["keys"] = "read-only file system"
	b.typeText("Q")
	eq(rowIn(b, "key:goto").warning, "Could not save: read-only file system", "a failed write is reported under the row")
	eq(prefsOf(b).editing.draft, "Q", "with the capture still open")
	same(w.kv.get("keys"), { worktree = "W" }, "and the saved keys as they were")
	w.kv.failSet["keys"] = nil
	b.typeText("Q")
	eq(rowIn(b, "key:goto").warning, nil, "the retry clears the warning")
	same(w.kv.get("keys"), { ["goto"] = "Q", worktree = "W" }, "and saves the key beside the other")
end)

case("host: a key changed in one block reaches the other live blocks, and a closed pane is skipped", function(w: World)
	hostScene(w, 3)
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	local gone = w.open(3, { "/work/r" })
	w.flush()
	gone.close()
	goToSettings(a, "keys")
	local drawn, closed = c.renders(), gone.renders()
	eq(bindKey(a, "worktree", "W"), nil, "the key is saved")
	yes(c.renders() > drawn, "the other block is drawn again")
	same(actionOf(c, "worktree").keys, { "W" }, "and shows the new key")
	eq(gone.renders(), closed, "a closed pane is not drawn")
	eq(c.press("w", nil, "w"), false, "the other block's old key is its pane's again")
	eq(c.press("w", "s", "W"), true, "and the new one works there")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "on its selected pull request")
	a.event({ ev = "change", id = "layer.settings", item = "key:worktree" })
	eq(actionOf(c, "worktree"), nil, "Reset reaches it too: back to no key, the button goes")
end)

case("host: a prompt's model is a model pattern or omp role: the row refuses anything else, the menu sends it, reset clears it", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "pmodel:prs:p1").control.value, "", "empty while the prompt has none")
	b.event({ ev = "select", id = "layer.settings", item = "pmodel:prs:p1" })
	local function try(text: string): string?
		if prefsOf(b).editing == nil then
			b.press("enter")
		end
		b.press("a", "c")
		b.press("backspace")
		b.typeText(text)
		b.press("enter")
		return rowIn(b, "pmodel:prs:p1").warning
	end
	local bad = "A model such as opus or provider/model-id, or a role such as @slow."
	eq(try("opus; rm -rf ~"), bad, "shell syntax is refused: the window puts it on a command line")
	eq(try("@"), bad, "a bare @ is no role")
	eq(try("a b"), bad, "so is a gap")
	eq(w.kv.get("prompts-prs").items[1].model, nil, "nothing was saved")
	for _, ok in { "@slow", "opus", "anthropic/claude-opus-4-5", "gpt-5.2:high", "openrouter/x-ai/grok-4" } do
		eq(try(ok), nil, ok .. " is accepted")
		eq(w.kv.get("prompts-prs").items[1].model, ok, ok .. " is saved")
	end
	eq(rowIn(b, "pmodel:prs:p1").changed, true, "the row offers a reset")
	request(b, "m1", { op = "menu" })
	local item = answerOf(b, "m1").items[1]
	eq(item.model, "openrouter/x-ai/grok-4", "the menu sends the model")
	eq(item.detail, "openrouter/x-ai/grok-4 · Review {url}", "and names it before the first line")
	b.event({ ev = "change", id = "layer.settings", item = "pmodel:prs:p1", value = nil })
	eq(w.kv.get("prompts-prs").items[1].model, nil, "reset clears it")
	eq(try(""), nil, "an empty model is accepted")
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
			if string.find(row.text, "Run the action", 1, true) then
				table.insert(out, row)
			end
		end
		return out
	end
	b.typeText("?")
	same(promptRows(), {
		{ keys = "m", text = "Run the action “Mine” on the selected pull request" },
		{ keys = "T", text = "Run the action “Anywhere” on the selected pull request" },
	}, "each prompt offered under My PRs that has a key, in the menu's order; none without a key, with no text or for another view")
	b.press("escape")
	b.press("tab")
	b.press("down")
	w.flush()
	b.typeText("?")
	same(promptRows(), {
		{ keys = "x", text = "Run the action “Theirs” on the selected pull request" },
		{ keys = "T", text = "Run the action “Anywhere” on the selected pull request" },
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
	expand(b, "ropen:o/r")
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

-- gh's clone of o/r answers after 5s with a refusal (fail) or after 2s with a clone at /code/r
local function slowClone(w: World, s: any, fail: boolean)
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "clone" then
			if fail then
				return { status = 1, stderr = "fatal: destination path '/elsewhere' already exists and is not an empty directory.\n", delay = 5000 }
			end
			w.fs.dirs["/code/r"] = true
			w.fs.dirs["/code/r/.git"] = true
			return { stdout = "", delay = 2000 }
		end
		return nil
	end
end

-- o/r is listed without a checkout, and gh's clone of it into /code/r takes 2s; panes 1 and 2 hold blocks
local function cloneScene(w: World): (Block, Block, HostScene)
	local s = hostScene(w, 3)
	-- the clone's git state exists in the model, but the folder only appears once gh has run
	local fresh = newGit(w, "/code/r")
	fresh.remotes.origin = { "https://github.com/o/r.git" }
	w.fs.dirs["/code/r"] = nil
	w.fs.dirs["/code/r/.git"] = nil
	slowClone(w, s, false)
	local a = openQueue(w)
	local b = openQueue(w, 2)
	w.kv.put("checkouts", { ["o/r"] = "" })
	return a, b, s
end

case("host: a folder that does not exist is cloned into with gh, saved once git confirms the clone", function(w: World)
	local b, _, s = cloneScene(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "checkout:o/r", "the checkout row is ready for a path")
	b.typeText("/code/r")
	b.press("enter")
	has(rowIn(b, "checkout:o/r").disabled, "cloning into it", "while gh clones the row says so and cannot be edited")
	same(requestsOf(s.gh, "clone")[1].call.argv, { "gh", "repo", "clone", "github.com/o/r", "/code/r" }, "gh clones the repository into the folder, as github.com/owner/name so GH_HOST cannot redirect it")
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
		expand(b, "ropen:o/r")
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
	b.press("tab", "s")
	eq(prefsOf(b).page, "worktrees", "the user moved on while gh was cloning")
	w.advance(5000)
	eq(#w.toasts, 1, "the refusal is reported once")
	eq(w.toasts[1].level, "error", "as an error")
	eq(w.toasts[1].text, "Checkout not saved", "that says what happened")
	has(w.toasts[1].sub, "not an empty directory", "with gh's reason")
	eq(prefsOf(b).page, "worktrees", "the page the user is on is left alone")
	b.press("tab")
	eq(prefsOf(b).page, "repos", "back on the Repositories page")
	submit()
	b.press("escape")
	w.advance(5000)
	eq(#w.toasts, 2, "closing Settings meanwhile reports it as well")
	eq(w.toasts[2].text, "Checkout not saved", "with the same toast")
	goToSettings(b, "repos")
	submit()
	b.press("tab", "s")
	b.press("tab")
	eq(prefsOf(b).page, "repos", "a user who is back on the page before gh answers")
	w.advance(5000)
	has(rowIn(b, "checkout:o/r").warning, "not an empty directory", "sees the refusal under its row")
	eq(prefsOf(b).editing.draft, "/elsewhere", "with the draft")
	eq(#w.toasts, 2, "and no extra toast")
	eq(w.kv.get("checkouts")["o/r"], "", "nothing was ever saved")
end)

case("host: a clone that fails late leaves a draft being typed in another row alone", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	w.kv.put("checkouts", { ["o/r"] = "", ["x/y"] = "" })
	slowClone(w, s, true)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/elsewhere")
	b.press("enter")
	expand(b, "ropen:x/y")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:x/y" })
	b.press("enter")
	b.typeText("/mine")
	w.advance(5000)
	eq(prefsOf(b).editing.row, "checkout:x/y", "the form being typed in stays")
	eq(prefsOf(b).editing.draft, "/mine", "with its draft")
	eq(w.toasts[#w.toasts].text, "Checkout not saved", "the refusal is a toast instead")
end)

case("host: a checkout asked in the palette waits out a clone of the same repository", function(w: World)
	local b = cloneScene(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/code/r")
	b.press("enter")
	request(b, "c1", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	has(answerOf(b, "c1").problem, "being", "the second claim is answered busy")
	eq(w.kv.get("checkouts")["o/r"], "", "and saved nothing")
	w.advance(2000)
	eq(w.kv.get("checkouts")["o/r"], "/code/r", "the clone is the checkout")
end)

case("host: removing a repository while it clones does not bring it back", function(w: World)
	local b = cloneScene(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/code/r")
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "delete", value = "rremove:o/r" })
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "rremove:o/r" })
	w.advance(2000)
	eq(w.kv.get("checkouts")["o/r"], nil, "the removed repository stays removed")
	eq(w.toasts[#w.toasts].level, "error", "and the clone's end says why")
end)

case("host: a Settings checkout refused as busy keeps the typed path", function(w: World)
	local a, b = cloneScene(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/work/r")
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" }) -- another pane starts its claim while the field is open
	w.flush()
	b.press("enter")
	has(rowIn(b, "checkout:o/r").warning, "already being set up", "the refusal is shown under the row")
	eq(prefsOf(b).editing.draft, "/work/r", "the typed path stays for another try")
end)

case("host: a claim in one pane makes another pane's claim of the same repository wait", function(w: World)
	local a, b = cloneScene(w)
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	request(b, "c2", { op = "checkout", repo = "O/R", path = "/work/r" })
	w.flush()
	has(answerOf(b, "c2").problem, "being", "the other pane is told it is busy")
	eq(w.kv.get("checkouts")["o/r"], "", "and saved nothing")
	w.advance(2000)
	eq(answerOf(a, "c1").ok, true, "the first claim finishes")
	eq(w.kv.get("checkouts")["o/r"], "/code/r", "and is the checkout")
	request(b, "c3", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	eq(answerOf(b, "c3").ok, true, "the repository can be claimed again once it is done")
end)

case("host: a repository removed while a palette claim clones it is not listed again", function(w: World)
	local a = cloneScene(w)
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	w.kv.put("checkouts", {}) -- removed meanwhile, from Settings in any pane
	w.advance(2000)
	has(answerOf(a, "c1").problem, "changed or removed", "the claim is refused")
	eq(w.kv.get("checkouts")["o/r"], nil, "the repository stays removed")
end)

case("host: a claim of a repository that was not listed is still saved", function(w: World)
	local a = cloneScene(w)
	w.kv.put("checkouts", {})
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	w.advance(2000)
	eq(answerOf(a, "c1").ok, true, "claimed")
	eq(w.kv.get("checkouts")["o/r"], "/code/r", "and listed")
end)

case("host: a claim whose block closed saves nothing and frees the repository", function(w: World)
	local a, b = cloneScene(w)
	request(a, "c1", { op = "checkout", repo = "o/r", path = "/code/r" })
	table.remove(w.panes, 1) -- pane 1 closes while gh clones
	w.advance(2000)
	eq(w.kv.get("checkouts")["o/r"], "", "the retired block saved nothing")
	request(b, "c2", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	eq(answerOf(b, "c2").ok, true, "the repository is not left claimed")
end)

case("host: switching views searches the new query, shows the cached list at once, and never waits for a superseded request", function(w: World)
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
	scope("prs:v2")
	w.flush()
	same(listed(b), { "no_2fr_2321", "no_2fr_2322" }, "the second view shows its own results")
	eq(#requestsOf(s.gh, "search"), 2, "it was searched")
	scope("prs:v1")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "going back shows the cached list at once")
	w.flush()
	scope("prs:v1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 4, "going back and re-selecting the active view each search again")
	slow = true
	second = { searchItem(23, "o/r", EPOCH - 5) }
	b.typeText("r")
	scope("prs:v2")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 6, "the switch sent its own search while the slow one is still pending")
	same(listed(b), { "no_2fr_2323" }, "the switch showed the new answer without waiting for the slow search")
	w.advance(5000)
	same(listed(b), { "no_2fr_2323" }, "and the superseded answer never replaces it")
	eq(pickerOf(b).scope, "prs:v2", "the second view is still the one shown")
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
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "prs:v2" })
	w.flush()
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "another view loads")
	eq(pickerOf(b).state, "ready", "without the first view's card")
	b.event({ ev = "action", id = "layer.queue", act = "scope", value = "prs:v1" })
	w.flush()
	eq(#requestsOf(s.gh, "search"), sent + 2, "going back asks again instead of trusting the old rejection")
	eq(pickerOf(b).state, "error", "and it is rejected again")
end)

case("host: the error card offers Refresh and Settings with the default keys, though neither has a key", function(w: World)
	local s = hostScene(w, 3)
	w.kv.store.keys = nil :: any
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" then
			return { status = 1, stderr = "gh: Validation Failed (HTTP 422)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	eq(pickerOf(b).state, "error", "the card shows")
	local ids: { string } = {}
	for _, a in pickerOf(b).actions do
		table.insert(ids, a.id)
	end
	same(ids, { "settings", "retry", "more" }, "Settings and Refresh sit beside the palette")
end)

case("host: a list emptied by snoozing says how many rows are hidden and which key shows them", function(w: World)
	hostScene(w, 3)
	w.kv.put("triage", { version = 1, items = { ["o/r#1"] = { at = 1, snoozeUntil = EPOCH + 3600 }, ["o/r#2"] = { at = 1, snoozeUntil = EPOCH + 3600 }, ["o/r#3"] = { at = 1, snoozeUntil = EPOCH + 3600 } } })
	local b = openQueue(w)
	same(listed(b), {}, "every row is hidden")
	eq(pickerOf(b).empty[1].t, "3 pull requests hidden by snoozing; press Z to show them.", "the hint counts them and names the key")
	w.kv.put("keys", { snoozed = "" })
	b.render()
	eq(pickerOf(b).empty[1].t, "3 pull requests hidden by snoozing; pick Show or hide snoozed in the command palette to show them.", "or the palette row once the key is gone")
end)

case("host: a view with no matches keeps its plain empty text", function(w: World)
	hostScene(w, 0)
	local b = openQueue(w)
	eq(pickerOf(b).empty[1].t, "No pull requests match My PRs.", "no hidden count")
end)

-- A pull request view plus one Jira view; `acli.override` may answer the Jira search.
local function crossScene(w: World): (h.HostScene, h.Acli)
	local s = hostScene(w, 3)
	local acli = newAcli(w)
	acli.searches[h.JIRA_ASSIGNED] = { h.jiraItem("ABC-12", "Fix login"), h.jiraItem("ABC-13", "Old bug") }
	w.kv.put("views-issues", {
		version = 1,
		nextId = 2,
		items = array({ { id = "v1", name = "Assigned to me", integration = "jira", query = "assignee = currentUser() AND statusCategory != Done", group = "none", prompts = array({}) } }),
	})
	return s, acli
end

local function countOf(b: Block, id: string): any
	for _, scope in pickerOf(b).scopes do
		if scope.id == id then
			return scope.count
		end
	end
	return nil
end

case("host: switching across kinds shows each view's cached list and its sidebar count at once", function(w: World)
	local s = crossScene(w)
	local b = openQueue(w)
	local function scope(id: string)
		b.event({ ev = "action", id = "layer.queue", act = "scope", value = id })
	end
	scope("issues:v1")
	w.flush()
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "the Jira view lists its issues")
	eq(countOf(b, "prs:v1"), 3, "the pull request view keeps its count while Jira is shown")
	scope("prs:v1")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "back to the pull requests: the cached list shows before any search lands")
	eq(countOf(b, "issues:v1"), 2, "the Jira count stays")
	w.flush()
	eq(#requestsOf(s.gh, "search") >= 2, true, "and it refreshed meanwhile")
end)

case("host: a not-found belongs to its view: another view clears it and searches, while the view itself stays paused", function(w: World)
	local _, acli = crossScene(w)
	-- A second Jira view beside the failing one: the switch keeps the integration.
	w.kv.put("views-issues", {
		version = 1,
		nextId = 3,
		items = array({
			{ id = "v1", name = "Unknown project", integration = "jira", query = "project = nopexyz", group = "none", prompts = array({}) },
			{ id = "v2", name = "Assigned to me", integration = "jira", query = "assignee = currentUser() AND statusCategory != Done", group = "none", prompts = array({}) },
		}),
	})
	acli.override = function(req: AcliReq): Reply?
		if req.kind == "search" and string.find(table.concat(req.argv, " "), "nopexyz", 1, true) then
			return { status = 1, stderr = "✗ Error: failed to parse JQL query: the value 'nopexyz' does not exist for the field 'project'.\n" }
		end
		return nil
	end
	local b = openQueue(w)
	local function scope(id: string)
		b.event({ ev = "action", id = "layer.queue", act = "scope", value = id })
	end
	local function searches(): number
		local n = 0
		for _, req in acli.requests do
			if req.kind == "search" then
				n += 1
			end
		end
		return n
	end
	scope("issues:v1")
	w.flush()
	eq(pickerOf(b).state, "error", "the unknown project shows its card")
	local before = searches()
	scope("issues:v1")
	w.flush()
	eq(pickerOf(b).state, "error", "the view itself stays paused")
	eq(searches(), before, "re-clicking it sends no search")
	scope("issues:v2")
	w.flush()
	eq(pickerOf(b).state, "ready", "another Jira view does not show it")
	eq(searches() > before, true, "and searches")
	scope("prs:v1")
	w.flush()
	eq(pickerOf(b).state, "ready", "nor does a pull request view")
end)

local SIGNED_OUT: Reply = { status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login' to authenticate\n" }

case("host: an acli sign-out held across a restart is still labelled as Atlassian's, on a GitHub view too", function(w: World)
	local _, acli = crossScene(w)
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "search" then SIGNED_OUT else nil
	end
	local b = openQueue(w)
	pickScope(b, "issues:v1")
	w.flush()
	eq(pickerOf(b).state, "error", "the Jira view shows its card")
	b.cx:save()
	local again = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(pickerOf(again).state, "error", "the restored block holds the pause")
	has(jsonEncode(pickerOf(again).message), "Atlassian CLI not signed in", "labelled by Atlassian")
	pickScope(again, "prs:v1")
	w.flush()
	eq(pickerOf(again).state, "error", "and holds a GitHub view too")
	has(jsonEncode(pickerOf(again).message), "Atlassian CLI not signed in", "still labelled by Atlassian there")
	lacks(jsonEncode(pickerOf(again).message), "gh auth login", "not as a GitHub sign-in")
end)

case("host: a GitHub login change does not drop an acli sign-out held on every view", function(w: World)
	local s = hostScene(w, 0)
	local acli = newAcli(w)
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "search" then SIGNED_OUT else nil
	end
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60) }
	s.gh.items.work = { searchItem(3, "o/r", EPOCH - 30) }
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open author:@me", logins = array({ "octocat", "work" }), group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Jira", integration = "jira", query = "assignee = currentUser()", group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	pickScope(b, "issues:v1")
	w.flush()
	eq(pickerOf(b).state, "error", "Jira is signed out")
	pickScope(b, "prs:v1@octocat")
	w.flush()
	local sent = #requestsOf(s.gh, "search")
	pickScope(b, "prs:v1@work")
	w.flush()
	eq(pickerOf(b).state, "error", "another login's view still shows the sign-out")
	eq(#requestsOf(s.gh, "search"), sent, "and sends no search until Refresh")
end)

case("host: a GitHub sign-in failure of one login is cleared by another login's view, though a Jira view came between", function(w: World)
	local s = hostScene(w, 0)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(3, "o/r", EPOCH - 30) }
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and req.login == "octocat" then
			return { status = 1, stderr = "gh: Bad credentials (HTTP 401)\n" }
		end
		return nil
	end
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open author:@me", logins = array({ "octocat", "work" }), group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Jira", integration = "jira", query = "assignee = currentUser()", group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	pickScope(b, "prs:v1@octocat")
	w.flush()
	eq(pickerOf(b).state, "error", "octocat's sign-in fails")
	pickScope(b, "issues:v1")
	w.flush()
	pickScope(b, "prs:v1@work")
	w.flush()
	eq(pickerOf(b).state, "ready", "the other login does not wear it")
	same(listed(b), { "no_2fr_233" }, "and searches")
end)

-- The first block of a world, restored with `pause` on view `v1` (of `kind`) while gh's probe is still out, so its
-- first listing comes from the probe's answer, not from init.
local function openRestored(w: World, kind: string?, pause: { kind: string, message: string, by: string }): Block
	w.respond(function(call: h.Call): Reply?
		if call.argv[1] == "gh" and call.argv[2] == "--version" then
			return { delay = 1000, stdout = "gh version 2.98.0\n" }
		end
		return nil
	end)
	local b = w.open(1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeViewId = "v1", activeKind = kind, pause = pause })
	w.advance(1000)
	w.flush()
	return b
end

local function searchesOf(acli: h.Acli): number
	local n = 0
	for _, req in acli.requests do
		if req.kind == "search" then
			n += 1
		end
	end
	return n
end

case("host: a not-found held across a restart still holds when its restored view is first listed", function(w: World)
	local _, acli = crossScene(w)
	local b = openRestored(w, "issues", { kind = "not-found", message = "the project nopexyz does not exist", by = "jira" })
	eq(pickerOf(b).state, "error", "the restored block holds the pause")
	eq(searchesOf(acli), 0, "and searches nothing until Refresh")
end)

case("host: a restored acli sign-out is not adopted by a GitHub view's login, so a Jira view keeps it", function(w: World)
	local _, acli = crossScene(w)
	local b = openRestored(w, nil, { kind = "auth", message = "not signed in", by = "jira" })
	eq(pickerOf(b).state, "error", "the GitHub view the block restored on holds the sign-out")
	pickScope(b, "issues:v1")
	w.flush()
	eq(pickerOf(b).state, "error", "the Jira view holds it too")
	eq(searchesOf(acli), 0, "and sends no search until Refresh")
end)

case("host: a restored GitHub sign-in failure on a Jira view is adopted by the first GitHub login, which keeps it", function(w: World)
	local s, _ = crossScene(w)
	local b = openRestored(w, "issues", { kind = "auth", message = "Bad credentials", by = "github" })
	eq(pickerOf(b).state, "error", "the Jira view the block restored on holds the failure")
	pickScope(b, "prs:v1")
	w.flush()
	eq(pickerOf(b).state, "error", "the GitHub view keeps it")
	eq(#requestsOf(s.gh, "search"), 0, "and sends no search until Refresh")
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

case("host: group by Fork and by Label put each PR under its fork owner or first label, with a fallback group", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 10, { fork = "alice", labels = array({ "bug" }) }),
		searchItem(2, "o/r", EPOCH - 20),
		searchItem(3, "o/r", EPOCH - 30, { fork = "alice", labels = array({ "a", "bug" }) }),
	}
	local function groupBy(group: string)
		w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
			{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = group, prompts = array({}) },
		}) })
	end
	groupBy("fork")
	local b = openQueue(w)
	local byFork: { any } = { { group = "alice", label = "alice", count = 2 }, "no_2fr_231", "no_2fr_233", { group = "Same repository", label = "Same repository", count = 1 }, "no_2fr_232" }
	same(pickerOf(b).order, byFork, "forks by owner, the rest under Same repository")
	groupBy("label")
	local byLabel: { any } = { { group = "a", label = "a", count = 1 }, "no_2fr_233", { group = "bug", label = "bug", count = 1 }, "no_2fr_231", { group = "No label", label = "No label", count = 1 }, "no_2fr_232" }
	same(pickerOf(openQueue(w, 2)).order, byLabel, "by first label, No label last")
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	same(asks.hx.options(b, "vgroup:prs:v1"), { "none", "repo", "author", "state", "review", "checks", "base", "fork", "label" }, "Settings offers both")
end)

case("host: a search that matches nothing says so, with the text, instead of calling the view empty", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("/")
	b.typeText("zzz")
	eq(pickerOf(b).empty[1].t, "No loaded pull requests match “zzz”.", "the search text is named")
	b.press("escape")
	b.press("escape")
	yes(#listed(b) == 3, "clearing it lists everything again")
end)

case("host: a snoozed item's preview offers Unsnooze, which ends the snooze", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.typeText("z")
	b.typeText("Z")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	local row = findKey(pickerNode(b), "unsnooze")
	yes(row ~= nil, "the snoozed item's preview has the row")
	has(row.p.label, "Snoozed until", "it says until when")
	b.event({ ev = "action", act = "unsnooze" })
	eq(w.kv.get("triage").items["o/r#1"].snoozeUntil, nil, "the saved snooze is gone")
	eq(findKey(pickerNode(b), "unsnooze"), nil, "and the row with it")
end)

case("host: Settings keeps the refresh pace while a refresh runs", function(w: World)
	local s = hostScene(w, 3)
	local slow = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and slow then
			return { delay = 5000, stdout = jsonEncode({ total = 3, next = NULL, cost = 1, items = s.gh.items.octocat }) }
		end
		return nil
	end
	local b = openQueue(w)
	slow = true
	b.typeText("r")
	goToSettings(b, "connection")
	has(rowIn(b, "refresh").hint, "Auto-refresh every", "the pace shows while the refresh is still running")
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

case("host: clicking a view refreshes it, even a fresh cached one or the one already shown, and the worktrees list back to it", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	local function searches(): number
		return #requestsOf(s.gh, "search")
	end
	eq(searches(), 1, "the first view loaded")
	pickScope(b, "prs:v2")
	w.flush()
	eq(searches(), 2, "another view searches")
	pickScope(b, "prs:v1")
	w.flush()
	eq(searches(), 3, "back to a view whose snapshot is seconds old searches again")
	pickScope(b, "prs:v1")
	w.flush()
	eq(searches(), 4, "a click on the view already shown searches")
	b.event({ ev = "action", act = "queue", value = "scope:worktrees" })
	w.flush()
	b.event({ ev = "action", act = "queue", value = "scope:prs:v1" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "back from the Worktrees list")
	eq(searches(), 5, "searches too")
end)

case("host: a click on a view inside the rate-limit cooldown sends nothing", function(w: World)
	local s = hostScene(w, 3)
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" then
			return { status = 1, stderr = "gh: API rate limit exceeded (HTTP 403)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	eq(#requestsOf(s.gh, "search"), 1, "the first search was refused")
	pickScope(b, "prs:v1")
	w.flush()
	pickScope(b, "prs:v2")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 1, "clicks do not hammer a limited account")
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
	expand(a, "vopen:prs:v1")
	a.press("enter")
	a.press("a", "c")
	a.typeText("Mine")
	a.press("enter")
	has(c.title(), "Mine", "the other block shows the new name")
	eq(#requestsOf(s.gh, "search"), 2, "a rename needs no new search")
	a.event({ ev = "select", id = "layer.settings", item = "query:prs:v1" })
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

case("host: gh's active account changing reaches every block: the old account's data goes and nothing runs as it", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30), searchItem(8, "o/r", EPOCH - 90) }
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	w.flush()
	same(listed(a), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the active gh account's PRs")
	local before = #s.gh.requests
	s.gh.active = "work"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	a.typeText("r")
	w.flush()
	same(listed(a), { "no_2fr_237", "no_2fr_238" }, "this block shows the new account's PRs")
	same(listed(c), { "no_2fr_237", "no_2fr_238" }, "and so does the other one")
	local ranAsOld = false
	for i = before + 1, #s.gh.requests do
		if s.gh.requests[i].kind == "search" and s.gh.requests[i].login == "octocat" then
			ranAsOld = true
		end
	end
	eq(ranAsOld, false, "nothing searched as the old account after it changed")
end)

case("host: a search still running for the old account never shows after the account changed", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
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
	-- another block saves the shown view with a login of its own: this one reloads the views
	local c = w.open(2, { "/work/r" })
	goToSettings(c, "views")
	expand(c, "vopen:prs:v1")
	loginsSavedBy(w, c, { "work" }, "Mine")
	w.advance(1)
	same(listed(b), { "no_2fr_237" }, "the new account's list is shown")
	w.advance(5000)
	same(listed(b), { "no_2fr_237" }, "the old account's late answer is dropped")
end)

case("settings: Save on the prompt editor saves the typed text after Done closed the prompt's form", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	b.press("down")
	eq(prefsOf(b).focus, "ptext:prs:p1", "the prompt's text row")
	b.press("enter")
	b.press("a", "c")
	b.typeText("Summarise {url}")
	eq(draftOf(b), "Summarise {url}", "the new text is typed in the editor")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "popen:prs:p1" })
	eq(draftOf(b), "Summarise {url}", "Done on the prompt's form leaves the editor card open with the draft")
	b.event({ ev = "action", id = "layer.settings.prompt.buttons.save", act = "save-prompt" })
	eq(savedText(w, 1), "Summarise {url}", "Save saves the draft though its form was closed")
	eq(draftOf(b), nil, "and closes the editor")
	local op: any = w.frames[#w.frames].ops[1]
	eq(op[2], NULL, "giving the caret back")
end)

case("host: an invalid pause held across a restart still holds when its restored view is first listed", function(w: World)
	local _, acli = crossScene(w)
	local b = openRestored(w, "issues", { kind = "invalid", message = "the query is invalid", by = "jira" })
	eq(pickerOf(b).state, "error", "the restored block holds the pause")
	eq(searchesOf(acli), 0, "and searches nothing until Refresh")
end)

case("host: Needs attention only and Show snoozed are saved with the block and restored with it", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	eq(b.saved().attention, nil, "off is not saved")
	b.event({ ev = "action", act = "triage", value = "toggle-attention" })
	b.event({ ev = "action", act = "triage", value = "toggle-snoozed" })
	eq(b.saved().attention, true, "attention is saved")
	eq(b.saved().snoozed, true, "and so is snoozed")
	local again = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(again.state().attention, true, "a restored block filters to what needs attention")
	eq(again.state().showSnoozed, true, "and lists snoozed items")
	local fresh = w.open(3, { "/work/r" }, { version = 1, launchCwd = "/work/r", attention = true, snoozed = true })
	w.flush()
	eq(fresh.state().attention, false, "a save of another version restores fresh")
end)

case("host: a prompt, format, setup command or checkout saved in one block reaches the others", function(w: World)
	hostScene(w, 3)
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	local a = w.open(1, { "/work/r" })
	local c = w.open(2, { "/work/r" })
	w.flush()
	local function reaches(what: string, change: () -> ())
		local drawn = c.renders()
		change()
		yes(c.renders() > drawn, what .. " draws the other block")
	end
	goToSettings(a, "prompts")
	reaches("adding a prompt", function()
		a.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:prs" })
	end)
	reaches("naming it", function()
		hx.save(a, (prefsOf(a).editing :: any).row, "Review")
	end)
	a.press("escape")
	a.press("escape")
	goToSettings(a, "worktrees")
	reaches("a worktree name format", function()
		hx.save(a, "fmt:prdir", "pr-{key}")
	end)
	a.press("escape")
	goToSettings(a, "repos")
	expand(a, "ropen:o/r")
	reaches("a setup command", function()
		hx.save(a, "setup:o/r:new", "make")
	end)
	reaches("a branch format", function()
		hx.save(a, "branch:o/r", "feat/{key}")
	end)
	reaches("clearing a checkout", function()
		a.event({ ev = "change", id = "layer.settings", item = "checkout:o/r" })
	end)
end)

return {}
