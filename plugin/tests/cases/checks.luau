--!strict
-- Regression cases: host checks, worktree card (removal, refusals, scans), Settings views and prompts, and the issue filters.

local h = require("../harness")

type Block = h.Block
type GhReq = h.GhReq
type HostScene = h.HostScene
type Reply = h.Reply
type World = h.World

local EPOCH, NULL, agentScene, answerOf, array, badgeOf = h.EPOCH, h.NULL, h.agentScene, h.answerOf, h.array, h.badgeOf
local bindKey, buttonLink, cardOf, cardText, case, checkRun = h.bindKey, h.buttonLink, h.cardOf, h.cardText, h.case, h.checkRun
local chipsOf, commandsOf, confirmOf, countLog, detailText, eq = h.chipsOf, h.commandsOf, h.confirmOf, h.countLog, h.detailText, h.eq
local expand, factOf, findKey, forgetCheckouts, freshAsk, goToSettings = h.expand, h.factOf, h.findKey, h.forgetCheckouts, h.freshAsk, h.goToSettings
local has, helpRows, hostScene, hx, issueHost, issueItem = h.has, h.helpRows, h.hostScene, h.hx, h.issueHost, h.issueItem
local issueLink, issuePrompt, issueRunLink, jiraHost, jsonEncode, lacks = h.issueLink, h.issuePrompt, h.issueRunLink, h.jiraHost, h.jsonEncode, h.lacks
local leaveIssueWt, leaveWt, listed, logFrom, loginsSavedBy, manyItems = h.leaveIssueWt, h.leaveWt, h.listed, h.logFrom, h.loginsSavedBy, h.manyItems
local newAcli, newGit, nodes, openIssues, openQueue, pickScope = h.newAcli, h.newGit, h.nodes, h.openIssues, h.openQueue, h.pickScope
local pickerNode, pickerOf, porcelain, prLink, prefsOf, pressCard = h.pickerNode, h.pickerOf, h.porcelain, h.prLink, h.prefsOf, h.pressCard
local promptOf, refreshNow, request, requestsOf, rowIn, same = h.promptOf, h.refreshNow, h.request, h.requestsOf, h.rowIn, h.same
local saveIssuePrompts, savePrompts, searchItem, sectionIn, sha, show = h.saveIssuePrompts, h.savePrompts, h.searchItem, h.sectionIn, h.sha, h.show
local showPr, snapshot, windowCase, yes = h.showPr, h.snapshot, h.windowCase, h.yes

-- The worktree card's buttons as "key:label", in order; none for a failed attempt.
local function buttonsOf(b: Block): { string }
	local out: { string } = {}
	local list: any = findKey(cardOf(b), "actions", "row")
	local rows: { any } = if list then list.c else {}
	for _, row in rows do
		table.insert(out, row.p.key .. ":" .. row.p.label)
	end
	return out
end

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
	newAcli(w)
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
	-- another block saves the shown view with a login of its own: this one reloads the views
	local c = w.open(2, { "/work/r" })
	goToSettings(c, "views")
	expand(c, "vopen:prs:v1")
	loginsSavedBy(w, c, { "work" }, "Mine")
	w.flush()
	w.advance(300)
	local sent = requestsOf(s.gh, "checks")
	eq(sent[#sent].login, "work", "the new account asked for its own, as itself")
	has(b.text(), "work-job", "and shows what it got")
	w.advance(5000)
	has(b.text(), "work-job", "the old account's late answer changes nothing")
	lacks(b.text(), "old-job", "and is not shown")
end)

case("host: items from two repositories with the same number get distinct ids", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { searchItem(12, "o/a", EPOCH - 60), searchItem(12, "o/b", EPOCH - 120) }
	local b = openQueue(w)
	same(listed(b), { "no_2fa_2312", "no_2fb_2312" }, "one id per repository, though both are #12")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fb_2312" })
	eq(pickerOf(b).selected, "no_2fb_2312", "selecting the second puts the cursor on it")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/b", 12), "and the Worktree link names o/b, not o/a")
end)

case("host: selecting and activating rows follows the picker, and a row that is gone is ignored", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	eq(pickerOf(b).selected, "no_2fr_232", "selecting a row moves the selection")
	b.event({ ev = "activate", id = "layer.queue", item = "no_2fr_233" })
	eq(pickerOf(b).selected, "no_2fr_233", "activating a row selects it")
	eq(w.opened[#w.opened], prLink("open", "o/r", 3), "and opens it in a Browser block")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2399" })
	eq(pickerOf(b).selected, "no_2fr_233", "a row that a refresh removed is ignored")
	b.event({ ev = "select", id = "somewhere.else", item = "no_2fr_231" })
	eq(pickerOf(b).selected, "no_2fr_233", "and so is an event for another surface")
end)

case("host: with Settings open the queue beside it takes clicks, a field being typed is saved first, and keys stay Settings'", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	b.event({ ev = "select", id = "layer.settings", item = "name:prs:v1" })
	b.press("enter")
	for _ = 1, 40 do
		b.press("backspace")
	end
	b.typeText("Mine")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	eq(pickerOf(b).selected, "no_2fr_232", "a row click moves the selection")
	eq(w.kv.get("views-prs").items[1].name, "Mine", "after saving the name being typed")
	eq(prefsOf(b).editing, nil, "which closes its edit")
	eq(prefsOf(b).page, "views", "Settings stays open")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_232", "keys still go to Settings")
	pickScope(b, "prs:v2")
	eq(pickerOf(b).scope, "prs:v2", "a sidebar view click switches the view")
	yes(prefsOf(b) ~= nil, "beside Settings")
	b.event({ ev = "action", id = "layer.queue", act = "settings" })
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "the Settings button closes the sheet")
end)

case("host: a worktree request becomes a badge and a card with its status, place and update commands, and removes nothing", function(w: World)
	local s = hostScene(w, 2)
	for n = 1, 2 do
		s.git.served["refs/pull/" .. n .. "/head"] = sha("b")
		s.gh.meta["o/r#" .. n] = { base = "o/r", sha = sha("b"), ref = if n == 1 then "feature" else "feature-2", headRepo = "o/r", headOwner = "o", state = "open" }
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
	eq(commandsOf(b, "update"), "git -C " .. target .. " pull --ff-only", "the update command too")
	eq(#w.calls, ran, "showing them ran nothing")
	s.gh.meta["o/r#1"].sha = sha("b")
	ask(1)
	eq(badgeOf(b).tone, "success", "caught up with its PR, the worktree is a success again")
	eq(commandsOf(b, "update"), nil, "no update commands to show")
	s.gh.meta["o/r#1"] = nil
	yes(type(ask(1).problem) == "string", "a PR that cannot be read is answered with the reason")
	eq(badgeOf(b), nil, "a failed attempt shows no badge")
	eq(cardOf(b).p.tone, "error", "but an error card")
	eq(findKey(cardOf(b), "actions"), nil, "with no buttons: there is no worktree to go to or remove")
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

case("host: the worktree card is two badges, the branch and the path, then the buttons that go to its tab, open one or remove it", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	w.env.HOME = "/wt"
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	local function ask()
		request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
		w.flush()
	end
	ask()
	same(chipsOf(b), { "Up to date", "Clean" }, "at the PR head and clean: two badges")
	eq(findKey(cardOf(b), "sync", "badge").p.tone, "success", "a good state")
	has(findKey(cardOf(b), "sync", "badge").p.title, "Created", "with the one-line summary of the attempt as the tooltip")
	for _, gone in { "summary", "never", "facts" } do
		eq(findKey(cardOf(b), gone), nil, "no " .. gone .. " line: the summary sentence, the footer and the kv are gone")
	end
	eq(findKey(cardOf(b), "cleanup", "section"), nil, "nor cleanup commands")
	eq(findKey(cardOf(b), "update", "section"), nil, "and no update commands: it is at the PR head")
	local branch = findKey(cardOf(b), "wbranch")
	eq(findKey(branch, "v").p.spans[1].t, "feature", "the branch")
	eq(findKey(branch, "copy", "icon").p.href, "feature", "copied as it is")
	local path = findKey(cardOf(b), "wpath")
	eq(findKey(path, "v").p.spans[1].t, "~/plotroom-o_r-pr-1", "the path, home written ~")
	eq(findKey(path, "v").p.truncate, "middle", "cut in the middle when it is long")
	eq(findKey(path, "v").p.title, target, "the tooltip has all of it")
	eq(findKey(path, "copy", "icon").p.href, target, "and so does the copy icon")
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree", "git:Open in Git" }, "no tab works in it: open one, remove it, or open Tern's git view on it")
	local open: any = findKey(cardOf(b), "open", "item")
	same(open.p.hint, { "w" }, "Open in new tab wears the Worktree key")
	eq(open.p.actions.click, "worktree", "and is the Worktree button")
	local remove: any = findKey(cardOf(b), "remove", "item")
	eq(remove.p.tone, "error", "Remove is red")
	eq(remove.p.icon, "trash", "with a trash can")
	eq(remove.p.hint, nil, "and no key")
	pressCard(b, "open")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "a click opens the Worktree link, as the key does")
	table.insert(w.panes, { pane = 9, cwd = target .. "/src" })
	b.render()
	same(buttonsOf(b), { "go:Go to tab", "remove:Remove worktree", "git:Open in Git" }, "while a tab works in it, the button goes there instead")
	same(findKey(cardOf(b), "go", "item").p.hint, { "g" }, "wearing the Go to tab key")
	pressCard(b, "go")
	eq(w.opened[#w.opened], prLink("goto", "o/r", 1), "and its click opens the Go to tab link")
	table.remove(w.panes)
	s.gh.meta["o/r#1"].sha = sha("c")
	s.git.dirty[target] = " M src/a.lua\n"
	ask()
	same(chipsOf(b), { "Not at PR head", "Uncommitted changes" }, "behind its PR and modified")
	eq(findKey(cardOf(b), "sync", "badge").p.tone, "warning", "both are warnings")
	eq(findKey(cardOf(b), "changes", "badge").p.tone, "warning", "")
	eq(cardOf(b).p.tone, "warning", "and so is the card")
	eq(findKey(cardOf(b), "update", "section").p.collapsed, true, "the update commands are folded away")
	eq(commandsOf(b, "update"), "git -C " .. target .. " pull --ff-only", "and complete")
	s.gh.meta["o/r#1"].sha = sha("b")
	s.git.dirty[target] = nil
	s.git.fail["status"] = { status = 128, stderr = "fatal: unable to read the index\n" }
	ask()
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "a status git could not read is never Clean")
	eq(findKey(cardOf(b), "changes", "badge").p.tone, "muted", "and is no warning either")
	s.git.fail["status"] = nil
	s.gh.meta["o/r#1"] = nil
	ask()
	eq(cardOf(b).p.tone, "error", "a failed attempt is a red card")
	eq(findKey(cardOf(b), "status"), nil, "with no badges")
	same(buttonsOf(b), {}, "and no buttons: there is no worktree to go to or remove")
end)

case("host: the card says how many commits are unpushed, and a git command finishing in the worktree reads it again", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	same(chipsOf(b), { "Up to date", "Clean" }, "no upstream (a fork's worktree): no unpushed badge")
	table.insert(w.panes, { pane = 9, cwd = target .. "/src" })
	table.insert(w.panes, { pane = 10, cwd = "/work/r" })
	local finish: any = w.window.handlers.command_finished
	local function done(pane: number, line: string)
		finish({ pane = pane, line = line, status = 0, took_ms = 5 }, nil)
		w.advance(400)
		w.flush()
	end
	s.git.unpushed[target] = 2
	local reads = countLog(s.git, "status")
	done(9, "ls -la")
	done(10, "git commit -m x")
	done(9, "gitk")
	eq(countLog(s.git, "status"), reads, "a command that is not git, git outside the worktree, and a program only named git... read nothing")
	same(chipsOf(b), { "Up to date", "Clean" }, "so the badges stay")
	done(9, "git commit -m x")
	eq(countLog(s.git, "status"), reads + 1, "git finishing inside the worktree reads its status once")
	same(chipsOf(b), { "Up to date", "Clean", "2 unpushed" }, "and the card shows the commits no upstream has")
	s.git.dirty[target] = " M src/a.lua\n"
	s.git.unpushed[target] = nil
	done(9, "git pull")
	same(chipsOf(b), { "Up to date", "Uncommitted changes" }, "the badges follow the next command, and the unpushed count goes")
	s.git.unpushed[target] = 0
	s.git.dirty[target] = nil
	done(9, "git push")
	same(chipsOf(b), { "Up to date", "Clean" }, "nothing unpushed shows no badge")
end)

case("host: a Worktree press keeps the unpushed count, and a git finish runs the worktree scan again", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	s.git.unpushed[target] = 3
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	w.advance(400)
	w.flush()
	same(chipsOf(b), { "Up to date", "Clean", "3 unpushed" }, "the card reads the count again after the attempt")
	table.insert(w.panes, { pane = 9, cwd = target })
	local scans = countLog(s.git, "worktree")
	local finish: any = w.window.handlers.command_finished
	finish({ pane = 9, line = "git pull", status = 0, took_ms = 5 }, nil)
	w.advance(400)
	w.flush()
	eq(countLog(s.git, "worktree") > scans, true, "git finishing in the worktree scans the checkouts again")
end)

case("host: the card and the Worktrees list offer Open in Git while the folder exists, and ask the window to open it", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree", "git:Open in Git" }, "the card has the button")
	eq(buttonLink(b, "git"), "plotroom://worktrees/git", "and its link")
	pressCard(b, "git")
	eq(w.opened[#w.opened], "plotroom://worktrees/git", "a click opens that link")
	eq(hx.ask(w, b, "g1", { op = "git-path" }).path, target, "the host names the card's folder")
	w.fs.dirs[target] = nil
	b.render()
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree" }, "a folder that is gone has no button")
	eq(buttonLink(b, "git"), nil, "and no link")
	has(hx.ask(w, b, "g2", { op = "git-path" }).problem, "no longer there", "nor a path")
end)

case("host: Remove worktree asks first: Esc or Enter keeps it, d or the Remove button takes it away, on the host, with its card and badge", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target, branch, ref = "/wt/plotroom-o_r-pr-1", "feature", "refs/plotroom-pr/o/r/pr-1"
	local function ask()
		request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
		w.flush()
	end
	ask()
	eq(confirmOf(b), nil, "nothing is asked yet")
	pressCard(b, "remove")
	local box = confirmOf(b)
	yes(box ~= nil, "Remove worktree asks")
	eq(box.p.head, "Remove worktree?", "with its question")
	eq(box.p.modal, true, "over everything")
	same(findKey(box, "facts", "kv").p.items, {
		{ k = "Path", v = { { t = target, s = "code" } } },
		{ k = "Branch", v = { { t = branch, s = "code" } } },
	}, "naming the worktree's path and branch")
	eq(findKey(box, "tab"), nil, "no tab works in it: no warning")
	eq(b.press("j"), false, "other keys are not taken while it asks")
	eq(b.press("escape"), true, "Esc keeps it")
	eq(confirmOf(b), nil, "the question closes")
	pressCard(b, "remove")
	eq(b.press("enter"), true, "Enter keeps it too")
	eq(confirmOf(b), nil, "and closes it")
	table.insert(w.panes, { pane = 9, cwd = target })
	pressCard(b, "remove")
	has(findKey(confirmOf(b), "tab", "text").p.spans[1].t, "A tab works in it", "while a tab works in it, the question warns that it is left in a folder that is gone")
	b.press("escape")
	table.remove(w.panes)
	pressCard(b, "remove")
	local keep: any = findKey(confirmOf(b), "keep", "item")
	b.event({ ev = "action", id = "layer.confirm.buttons.keep", act = keep.p.actions.click })
	eq(confirmOf(b), nil, "the Keep button keeps it")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed so far")
	local mark = #s.git.log
	local told = #w.toasts
	pressCard(b, "remove")
	b.typeText("d")
	eq(confirmOf(b), nil, "d closes the question")
	eq(w.toasts[told + 1].level, "info", "and starts the removal")
	has(w.toasts[told + 1].text, "o/r#1", "naming the pull request")
	request(b, "a2", { op = "worktree", repo = "o/r", number = 1 })
	eq(answerOf(b, "a2").busy, true, "no request for the worktree is served while it is removed")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree remove " .. target,
		"merge-base --is-ancestor refs/heads/" .. branch .. " " .. ref,
		"branch -D " .. branch,
		"update-ref -d " .. ref,
		"worktree list --porcelain -z",
	}, "the worktree without --force, then -D only after the ancestry check, then the ref, then a read of the checkout")
	eq(cardOf(b), nil, "its card is gone")
	eq(badgeOf(b), nil, "and the row's badge")
	eq(w.toasts[#w.toasts].level, "success", "the removal is reported")
	eq(w.toasts[#w.toasts].text, "Worktree removed", "")
	eq(w.toasts[#w.toasts].sub, "Branch feature was deleted too.", "with what became of the branch")
	eq(#s.git.worktrees, 1, "only the main worktree is left")
	ask()
	eq(answerOf(b, "a1").created, true, "asking again makes a new worktree: the old one is really gone")
	pressCard(b, "remove")
	local remove: any = findKey(confirmOf(b), "delete", "item")
	eq(remove.p.label, "Remove", "the question's button says what it does")
	b.event({ ev = "action", id = "layer.confirm.buttons.delete", act = remove.p.actions.click })
	w.flush()
	eq(cardOf(b), nil, "its Remove button removes it as d does")
	ask()
	b.typeText("s")
	yes(findKey(b.view().layer, "settings", "prefs") ~= nil, "Settings is open")
	b.event({ ev = "action", id = "layer.queue.worktree.actions.remove", act = "remove-worktree" })
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "the Remove button closes Settings")
	yes(confirmOf(b) ~= nil, "and asks")
	b.press("escape")
	yes(confirmOf(b) == nil and cardOf(b) ~= nil, "Esc keeps the worktree")
end)

case("host: a worktree git refuses to remove stays: its card says why, its badge follows, and nothing else was done", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target = "/wt/plotroom-o_r-pr-1"
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(badgeOf(b).tone, "success", "a clean worktree starts as a success")
	s.git.dirty[target] = " M src/a.lua\n"
	local before = snapshot(s.git)
	local mark = #s.git.log
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree remove " .. target,
		"worktree list --porcelain -z",
	}, "git was asked once, without --force, and only read the checkout afterwards")
	eq(snapshot(s.git), before, "no worktree, branch or ref changed")
	yes(cardOf(b) ~= nil, "the card stays")
	has(cardText(b), "Not removed. It has uncommitted changes; commit, stash or remove it yourself.", "and says why")
	same(chipsOf(b), { "Up to date", "Uncommitted changes" }, "with what git found")
	eq(cardOf(b).p.tone, "warning", "so it is a warning now")
	eq(badgeOf(b).tone, "warning", "and so is the row's badge")
	eq(w.toasts[#w.toasts].level, "error", "the refusal is toasted too")
	eq(w.toasts[#w.toasts].text, "Worktree not removed", "")
	eq(w.toasts[#w.toasts].sub, "It has uncommitted changes; commit, stash or remove it yourself.", "with the same reason")
	s.git.dirty[target] = nil
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	eq(cardOf(b), nil, "once the changes are dealt with, it goes")
end)

case("host: removing a worktree whose branch holds commits of its own keeps the branch, and says so", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local target, branch, ref = "/wt/plotroom-o_r-pr-1", "feature", "refs/plotroom-pr/o/r/pr-1"
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	s.git.ahead[branch] = true
	s.git.unmerged[branch] = true
	local mark = #s.git.log
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree remove " .. target,
		"merge-base --is-ancestor refs/heads/" .. branch .. " " .. ref,
		"branch -d " .. branch,
		"worktree list --porcelain -z",
	}, "-d, never -D, and the ref stays with its branch; then a read of the checkout")
	eq(cardOf(b), nil, "the worktree is gone, and so is its card")
	eq(w.toasts[#w.toasts].level, "success", "removing it worked")
	eq(w.toasts[#w.toasts].sub, "Branch feature was kept. The branch 'feature' is not fully merged.", "and the branch that stayed is named")
	eq(s.git.refs["refs/heads/" .. branch], sha("b"), "it holds its commits")
end)

case("host: Remove worktree is refused while the worktree is being prepared, at the button and at the question", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	local told = #w.toasts
	request(b, "a2", { op = "worktree", repo = "o/r", number = 1 }) -- in flight: its git commands are not answered yet
	pressCard(b, "remove")
	eq(confirmOf(b), nil, "no question while it is being prepared")
	eq(w.toasts[told + 1].text, "Worktree is busy", "the button says why")
	w.flush()
	pressCard(b, "remove")
	yes(confirmOf(b) ~= nil, "idle again, it asks")
	request(b, "a3", { op = "worktree", repo = "o/r", number = 1 })
	b.typeText("d")
	eq(confirmOf(b), nil, "the question closes")
	eq(w.toasts[#w.toasts].text, "Worktree is busy", "and d is refused the same")
	eq(#w.toasts, told + 2, "each refusal toasted once")
	w.flush()
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	yes(cardOf(b) ~= nil, "and the card is still there")
end)

-- ---- the worktree card, read from git
-- Nothing about a worktree is remembered between runs: after each refresh, Worktree attempt and removal the block lists
-- its checkouts' worktrees with git, so a block that never made one shows the ones that exist, and one removed outside
-- Plotroom goes.

case("host: a fresh block shows the card and the row badge of a worktree its checkout already has, read from git with no Worktree press", function(w: World)
	local s = hostScene(w, 2)
	local path = leaveWt(w, s, 1)
	s.gh.items.octocat[1].headSha = sha("b")
	local b = openQueue(w)
	yes(badgeOf(b) ~= nil, "the PR's row wears the Worktree badge")
	eq(badgeOf(b).tone, nil, "with no tone while its changes are unread")
	eq(badgeOf(b, 2), nil, "the PR with no worktree wears none")
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "the card: at the PR's head, its changes unread")
	eq(cardOf(b).p.tone, nil, "no tone either")
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree", "git:Open in Git" }, "with the buttons that open a tab in it or remove it")
	has(cardText(b), "plotroom/o/r/pr-1", "its branch")
	has(cardText(b), path, "and where it is")
	eq(countLog(s.git, "worktree list"), 1, "git listed the checkout once")
	eq(countLog(s.git, "config"), 0, "and read no git config: a worktree is known by its branch or folder name")
	eq(countLog(s.git, "status"), 0, "no worktree's changes were read yet")
	eq(countLog(s.git, "worktree add"), 0, "nothing was made")
	w.advance(300)
	same(chipsOf(b), { "Up to date", "Clean" }, "the selected PR's changes are read once the cursor has rested on it")
	eq(badgeOf(b).tone, "success", "and the row follows")
	eq(cardOf(b).p.tone, "success", "and the card")
	eq(countLog(s.git, "status"), 1, "by one status")
	eq(countLog(s.git, "worktree list"), 1, "the status read lists nothing again, nor does the preview")
	eq(#w.toasts, 0, "nothing was said")
end)

case("host: a block opened after another made a worktree shows its card at once, though it made nothing", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", state = "open" }
	s.gh.items.octocat[1].headSha = sha("b")
	local first = openQueue(w)
	request(first, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(answerOf(first, "a1").created, true, "the first block made the worktree")
	w.advance(300)
	eq(countLog(s.git, "status"), 1, "the attempt read the worktree's changes: its card does not read them again")
	first.close()
	local fresh = openQueue(w, 2)
	yes(badgeOf(fresh) ~= nil, "a block that never made one wears its row badge")
	same(chipsOf(fresh), { "Up to date", "Changes unchecked" }, "and shows its card, read from git: at the PR's head, its changes unread")
	has(cardText(fresh), "/wt/plotroom-o_r-pr-1", "where it is")
	eq(countLog(s.git, "worktree add"), 1, "the worktree was made once, by the first block")
	request(fresh, "b1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(answerOf(fresh, "b1").created, false, "and the second block reuses it")
end)

case("host: a worktree removed outside Plotroom leaves its card and badge at the next refresh, and a scan that fails changes nothing", function(w: World)
	local s = hostScene(w, 2)
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	local one = leaveWt(w, s, 1)
	leaveWt(w, s, 2)
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil and badgeOf(b, 2) ~= nil, "both rows wear the badge")
	-- git removes the first behind Plotroom's back
	table.remove(s.git.worktrees, 2)
	w.fs.dirs[one] = nil
	b.render()
	yes(cardOf(b) ~= nil, "a render asks git nothing: the card stays")
	local mark = #s.git.log
	s.git.fail["worktree list"] = { status = 128, stderr = "fatal: unable to read the worktrees\n" }
	refreshNow(w, b)
	yes(cardOf(b) ~= nil, "a scan that fails changes nothing")
	yes(badgeOf(b, 1) ~= nil and badgeOf(b, 2) ~= nil, "not the badges either")
	eq(#w.toasts, 0, "and says nothing")
	s.git.fail["worktree list"] = nil
	refreshNow(w, b)
	eq(cardOf(b), nil, "the next scan that works finds it gone, and the card goes")
	eq(badgeOf(b, 1), nil, "and the row's badge")
	yes(badgeOf(b, 2) ~= nil, "the other worktree stays")
	same(logFrom(s.git, mark), {
		"worktree list --porcelain -z",
		"worktree list --porcelain -z",
	}, "one list per refresh")
	showPr(b, 2)
	yes(cardOf(b) ~= nil, "the other PR's card is there")
	-- git moves it: the card follows
	s.git.worktrees[2].path = "/moved/plotroom-o_r-pr-2"
	w.fs.dirs["/moved/plotroom-o_r-pr-2"] = true
	refreshNow(w, b)
	has(cardText(b), "/moved/plotroom-o_r-pr-2", "git moves the worktree: the card names where it is now")
	lacks(cardText(b), "/wt/plotroom-o_r-pr-2", "and no longer where it was")
end)

case("host: the card says Up to date or Not at PR head by the head the last refresh saw, with the commands to catch up", function(w: World)
	local s = hostScene(w, 1)
	local path = leaveWt(w, s, 1)
	local function head(at: string?)
		s.gh.items.octocat[1].headSha = at
	end
	head(sha("b"))
	local b = openQueue(w)
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "the worktree is at the PR's head")
	eq(commandsOf(b, "update"), nil, "nothing to catch up on")
	head(sha("c"))
	refreshNow(w, b)
	same(chipsOf(b), { "Not at PR head", "Changes unchecked" }, "the PR moved on: the worktree is behind it")
	eq(findKey(cardOf(b), "sync", "badge").p.tone, "warning", "a warning")
	eq(badgeOf(b).tone, "warning", "as is the row's badge")
	eq(findKey(cardOf(b), "sync", "badge").p.title, "Reused · Different (local bbbbbbb, PR head ccccccc on branch-1; not updated) · Changes unchecked", "the tooltip says how")
	eq(commandsOf(b, "update"), "git -C " .. path .. " pull --ff-only", "and the command to catch up is one pull: the branch tracks the PR's head branch")
	local ran = #w.calls
	b.render()
	eq(#w.calls, ran, "showing them ran nothing")
	s.git.worktrees[2].head = sha("c") -- the user caught up
	refreshNow(w, b)
	same(chipsOf(b), { "Up to date", "Changes unchecked" }, "its head is the PR's again")
	eq(commandsOf(b, "update"), nil, "and there is nothing to run")
	eq(badgeOf(b).tone, nil, "the row's badge is calm again")
	s.git.worktrees[2].head = sha("d") -- a commit of its own
	refreshNow(w, b)
	same(chipsOf(b), { "Not at PR head", "Changes unchecked" }, "a worktree on commits of its own is not at the PR's head either")
	head(nil)
	refreshNow(w, b)
	same(chipsOf(b), { "Not at PR head", "Changes unchecked" }, "a refresh that does not say where the PR's head is leaves the last verdict")
	local fresh = openQueue(w, 2)
	same(chipsOf(fresh), { "Up to date", "Changes unchecked" }, "and a block that has no verdict yet takes the worktree as current")
	eq(badgeOf(fresh).title, "Worktree ready · " .. path, "with nothing to say of its head")
end)

case("host: a worktree's changes are read for the selected item only, once the cursor has rested, and again after each refresh", function(w: World)
	local s = hostScene(w, 4)
	leaveWt(w, s, 1)
	local two = leaveWt(w, s, 2)
	leaveWt(w, s, 3)
	s.git.dirty[two] = " M src/a.lua\n"
	local b = openQueue(w)
	eq(countLog(s.git, "status"), 0, "no status is read as the list is shown")
	w.advance(299)
	eq(countLog(s.git, "status"), 0, "nor before the cursor has rested")
	w.advance(1)
	eq(countLog(s.git, "status"), 1, "then the selected PR's worktree is read")
	same(chipsOf(b), { "Up to date", "Clean" }, "and its card says what git found")
	eq(badgeOf(b, 1).tone, "success", "its row too")
	eq(badgeOf(b, 2).tone, nil, "the others are not read: their badges have no tone yet")
	eq(badgeOf(b, 3).tone, nil, "")
	showPr(b, 2)
	w.advance(100)
	showPr(b, 3)
	w.advance(100)
	showPr(b, 4)
	w.advance(1000)
	eq(countLog(s.git, "status"), 1, "a cursor that moves on before it has rested reads nothing")
	showPr(b, 2)
	w.advance(299)
	eq(countLog(s.git, "status"), 1, "one that rests...")
	w.advance(1)
	eq(countLog(s.git, "status"), 2, "...on a worktree reads it")
	same(chipsOf(b), { "Up to date", "Uncommitted changes" }, "its card shows the changes")
	eq(badgeOf(b, 2).tone, "warning", "and its row")
	showPr(b, 4)
	w.advance(1000)
	eq(countLog(s.git, "status"), 2, "an item with no worktree has nothing to read")
	showPr(b, 1)
	w.advance(1000)
	showPr(b, 2)
	w.advance(1000)
	eq(countLog(s.git, "status"), 2, "and a worktree read since the last refresh is not read again")
	s.git.dirty[two] = nil
	local mark = #s.git.log
	refreshNow(w, b)
	eq(countLog(s.git, "worktree list", mark), 1, "a refresh lists the checkout once...")
	eq(countLog(s.git, "status", mark), 0, "...and reads no status by itself")
	same(chipsOf(b), { "Up to date", "Uncommitted changes" }, "the card keeps what it knew")
	w.advance(300)
	eq(countLog(s.git, "status", mark), 1, "it reads the selected worktree again once the cursor rests")
	same(chipsOf(b), { "Up to date", "Clean" }, "and shows what changed")
	eq(badgeOf(b, 2).tone, "success", "in its row too")
end)

case("host: a scan that began before a worktree attempt or a removal ended cannot undo it", function(w: World)
	local s = hostScene(w, 2)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", state = "open" }
	leaveWt(w, s, 2)
	local b = openQueue(w)
	eq(cardOf(b), nil, "the selected PR has no worktree")
	-- The next listing git gives is `porcelain(s.git)` as it stands now, and comes `ms` late.
	local function slowly(ms: number)
		s.git.fail["worktree list"] = { stdout = porcelain(s.git), delay = ms }
	end
	-- A refresh starts a scan; its answer was read before the worktree existed and comes late.
	slowly(5000)
	refreshNow(w, b)
	s.git.fail["worktree list"] = nil
	request(b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	w.flush()
	eq(answerOf(b, "a1").created, true, "the worktree is made while the scan is out")
	yes(cardOf(b) ~= nil, "and its card shown")
	slowly(1000) -- the listing made again once the late answer is dropped is slow as well
	w.advance(5000)
	yes(cardOf(b) ~= nil, "the late answer does not list the worktree, and does not take its card away")
	w.advance(1000)
	yes(cardOf(b) ~= nil and badgeOf(b, 1) ~= nil and badgeOf(b, 2) ~= nil, "the listing made again confirms it")
	eq(countLog(s.git, "worktree list"), 4, "the first scan, the refresh's, the attempt's own and the one made again")
	-- The same for a removal: a scan that listed the worktree before it went cannot bring it back.
	slowly(5000)
	refreshNow(w, b)
	s.git.fail["worktree list"] = nil
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	eq(cardOf(b), nil, "the worktree is removed")
	slowly(1000)
	w.advance(5000)
	eq(cardOf(b), nil, "the late answer still lists it, and cannot bring its card back")
	eq(badgeOf(b, 1), nil, "nor its badge")
	w.advance(1000)
	eq(cardOf(b), nil, "the listing made again agrees")
	yes(badgeOf(b, 2) ~= nil, "the other worktree stays")
end)

case("host: every worktree git lists keeps its card, however many there are; only remembered attempts git has not confirmed are capped", function(w: World)
	local s = hostScene(w, 50)
	for n = 1, 25 do
		leaveWt(w, s, n)
	end
	local b = openQueue(w)
	for n = 1, 25 do
		yes(badgeOf(b, n) ~= nil, "PR " .. n .. " wears its badge: there are more worktrees than the cap")
	end
	-- 22 attempts that fail, none of those PRs being known to GitHub: two more than the cap
	for n = 26, 47 do
		request(b, "f" .. n, { op = "worktree", repo = "o/r", number = n })
		w.flush()
	end
	for n = 1, 25 do
		yes(badgeOf(b, n) ~= nil, "PR " .. n .. " still wears it")
	end
	showPr(b, 26)
	eq(cardOf(b), nil, "the oldest failed attempt was forgotten")
	showPr(b, 27)
	eq(cardOf(b), nil, "and the next")
	showPr(b, 28)
	eq(cardOf(b).p.tone, "error", "the rest are kept")
	showPr(b, 47)
	eq(cardOf(b).p.tone, "error", "the newest too")
	showPr(b, 25)
	yes(cardOf(b) ~= nil, "and a worktree git lists keeps its card")
end)

case("host: each saved checkout of the listed repositories is listed once per refresh, however many rows there are, and one with no checkout is left alone", function(w: World)
	local s = hostScene(w, 0)
	local other = newGit(w, "/work/y")
	other.remotes.origin = { "https://github.com/x/y.git" }
	w.kv.put("checkouts", { ["o/r"] = "/work/r", ["x/y"] = "/work/y", ["z/w"] = "" })
	local items: { { [string]: any } } = {}
	for i = 1, 6 do
		table.insert(items, searchItem(i, if i <= 2 then "o/r" elseif i <= 4 then "x/y" else "z/w", EPOCH - i * 60))
	end
	s.gh.items.octocat = items
	leaveWt(w, s, 1)
	table.insert(other.worktrees, { path = "/wt/plotroom-x_y-pr-3", branch = "refs/heads/plotroom/x/y/pr-3", head = sha("b"), locked = false })
	w.fs.dirs["/wt/plotroom-x_y-pr-3"] = true
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil and badgeOf(b, 3) ~= nil, "the worktrees of both repositories show")
	yes(badgeOf(b, 2) == nil and badgeOf(b, 4) == nil and badgeOf(b, 5) == nil and badgeOf(b, 6) == nil, "and no other row wears a badge")
	eq(countLog(s.git, "worktree list"), 1, "o/r's checkout was listed once")
	eq(countLog(other, "worktree list"), 1, "x/y's once")
	refreshNow(w, b)
	eq(countLog(s.git, "worktree list"), 2, "each again at the next refresh, and not once more for the six rows")
	eq(countLog(other, "worktree list"), 2, "")
end)

case("host: a checkout the window gives after the list is shown is read at once: the worktrees it holds show with no refresh", function(w: World)
	local s = hostScene(w, 2)
	leaveWt(w, s, 1)
	local b = w.open(1, { "/nowhere" }) -- a launch folder that is gone maps no checkout
	w.flush()
	eq(#listed(b), 2, "the list is shown")
	eq(cardOf(b), nil, "with no checkout there is no worktree to show")
	eq(countLog(s.git, "worktree list"), 0, "and none was looked for")
	request(b, "c1", { op = "checkout", repo = "o/r", path = "/work/r" })
	w.flush()
	eq(answerOf(b, "c1").ok, true, "the window gives the checkout")
	yes(cardOf(b) ~= nil, "its worktree shows")
	eq(countLog(s.git, "worktree list"), 1, "after one listing")
end)

case("host: a checkout typed in Settings is read once git confirms it: the worktrees it holds show with no refresh", function(w: World)
	local s = hostScene(w, 2)
	leaveWt(w, s, 1)
	local b = w.open(1, { "/nowhere" })
	w.flush()
	eq(cardOf(b), nil, "with no checkout there is no worktree to show")
	w.kv.put("checkouts", { ["o/r"] = "" })
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	b.event({ ev = "select", id = "layer.settings", item = "checkout:o/r" })
	b.press("enter")
	b.typeText("/work/r")
	b.press("enter")
	w.flush()
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the checkout is saved once git confirms it")
	yes(cardOf(b) ~= nil, "and its worktree shows")
	eq(countLog(s.git, "worktree list"), 1, "after one listing")
end)

case("host: a pull request listed as from a fork is found on <owner>/<branch>, whatever its folder is called, and not on the repository's own branch of that name", function(w: World)
	local s = hostScene(w, 2)
	s.gh.items.octocat[1].fork = "bob"
	local function add(path: string, branch: string)
		table.insert(s.git.worktrees, { path = path, branch = "refs/heads/" .. branch, head = sha("b"), locked = false })
		w.fs.dirs[path] = true
	end
	add("/wt/bobs", "bob/branch-1")
	add("/wt/mine", "branch-1")
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil, "the fork's pull request wears the badge of the worktree on its owner's branch")
	has(cardText(b), "/wt/bobs", "and its card names that one")
	lacks(cardText(b), "/wt/mine", "not the repository's own branch of the same name")
	eq(badgeOf(b, 2), nil, "which is no other pull request's either")
end)

case("host: a malformed request from a window gets no answer and starts nothing", function(w: World)
	hostScene(w, 2)
	local b = openQueue(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, value: any)
		b.event({ ev = "action", act = "rpc", value = value })
		w.flush()
		for _, probe in { "a1", "m1" } do
			eq(answerOf(b, probe), nil, what .. ": no answer is kept for " .. probe)
		end
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.toasts, 0, what .. ": or said")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	ignored("a value that is not text", 42)
	ignored("text that is not JSON", "{not json")
	ignored("JSON that is not an object", "[1,2]")
	ignored("a request too big", jsonEncode({ id = "a1", op = "menu", pad = string.rep("x", 130000) }))
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
	same(answerOf(b, "m1").items, { { id = "p1", label = "Review", detail = "Review {url}", group = "All actions", send = "Review {url}\nthen report", worktree = true } }, "a well-formed request is answered with the saved prompts")
	eq(w.opened[#w.opened], "plotroom://rpc/m1", "and announced")
end)

windowCase("window: an agent run notes its worktree on the block as the Worktree key does, and the card replaces the failure before it", function(w: World)
	local s, b = agentScene(w)
	w.window.choose, w.window.typed = "Type a prompt…", "go"
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
	eq(findKey(findKey(cardOf(b), "wbranch"), "v").p.spans[1].t, "feature", "and the worktree's branch")
	s.gh.meta["o/r#5"].sha = sha("c")
	s.git.served["refs/pull/5/head"] = sha("c")
	w.window.choose = { "Start another agent", "Type a prompt…" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(badgeOf(b).tone, "warning", "a reused worktree behind its pull request is flagged")
	eq(commandsOf(b, "update"), "git -C /wt/plotroom-o_r-pr-5 pull --ff-only", "with the command that brings it up to date")
	w.cx.agents.start = function(_self: any, _opts: any): number
		error("no agent program", 0)
	end
	w.window.choose = { "Start another agent", "Type a prompt…" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[#w.toasts].text, "Could not start an agent for o/r#5", "an agent that cannot start is toasted")
	has(cardText(b), s.target, "and the worktree's card is still on screen")
end)

-- ---------------------------------------------------------------- issue filters of the Plotroom block
-- The Plotroom block lists GitHub pull requests, GitHub issues and Jira issues (tracker.luau) from one sidebar. Issue
-- filters and prompts keep their own kv stores (views-issues, prompts-issues) beside the PR ones, and a worktree of an
-- issue is on a branch named after it.

case("host: the palette names a GitHub issue's own operations GitHub - Issue, and a pull request-only one is not offered", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local p = hx.palette(w, b)
	for _, id in { "assign-me", "comment", "label-add", "issue-close" } do
		eq(p.commandGroups[id], "GitHub - Issue", id .. " is under GitHub - Issue")
	end
	eq(p.commandGroups["jira-transition"], nil, "a GitHub issue has no Jira transition")
	eq(p.commandGroups["pr-draft"], nil, "nor a pull request's conversion")
	eq(p.groups.seen, "Triage", "marking it seen is Triage")
end)

case("host: the palette names a Jira issue's own operations Jira - Issue", function(w: World)
	jiraHost(w)
	local b = openIssues(w)
	local p = hx.palette(w, b)
	for _, id in { "assign-me", "comment", "jira-transition" } do
		eq(p.commandGroups[id], "Jira - Issue", id .. " is under Jira - Issue")
	end
	eq(p.commandGroups["label-add"], nil, "a Jira issue has no GitHub label")
	eq(p.groups.snooze, "Triage", "snoozing it is Triage")
end)

case("host: an issue filter lists issues under its own search, noun, icon, group and shortcuts", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	local searches = requestsOf(s.gh, "issue-search")
	eq(#searches, 1, "one request covers three issues")
	eq(searches[1].fields.q, "is:open assignee:@me is:issue sort:updated-desc", "the active view's query across every repository, issues only")
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "newest update first")
	eq(pickerOf(b).selected, "no_2fr_2312", "the first issue is selected")
	eq(pickerOf(b).state, "ready", "the list is ready")
	eq(b.title(), "Plotroom · Assigned to me (3) · 2 new", "the title names the filter, counts the issues and the new ones")
	eq(pickerOf(b).noun, "issues", "the picker counts issues")
	eq(pickerOf(b).placeholder, "Filter the loaded issues", "and filters them")
	eq(pickerOf(b).icon, "list-checks", "with an icon of its own")
	local sidebar: { string } = {}
	local loaded: any = nil
	for _, scope in pickerOf(b).scopes do
		if scope.id ~= "worktrees" and scope.id ~= "agents" and scope.id ~= "inbox" then
			table.insert(sidebar, scope.group .. ": " .. scope.label)
		end
		if scope.id == "issues:v1" then
			loaded = scope
		end
	end
	same(sidebar, {
		"GitHub - octocat: My PRs",
		"GitHub - octocat: Review requested",
		"GitHub - octocat: Assigned to me",
		"GitHub - octocat: Created by me",
		"Jira: Assigned to me",
		"Jira: Created by me",
	}, "the sidebar lists every filter under its integration's group, pull request filters and issue filters together")
	eq(loaded.count, 3, "the loaded one with its count")
	-- the local search reads titles, labels, assignees, authors and numbers
	local function found(text: string): { string }
		b.typeText("/")
		b.typeText(text)
		local ids = listed(b)
		b.press("escape")
		b.press("escape")
		return ids
	end
	same(found("dark"), { "no_2fr_2313" }, "the search matches titles")
	same(found("ui"), { "no_2fr_2312" }, "labels")
	same(found("ann"), { "no_2fr_2312", "no_2fr_2314" }, "assignees and authors")
	same(found("#14"), { "no_2fr_2314" }, "and numbers")
	-- the shortcut list speaks of issues
	b.typeText("?")
	local byKeys: { [string]: string } = {}
	for _, row in helpRows(b.view().layer) do
		byKeys[row.keys] = row.text
		if row.keys ~= "w" then
			lacks(row.text, "pull request", "no other shortcut speaks of pull requests: " .. row.keys)
		end
	end
	eq(byKeys.w, "Create or reuse the selected issue's worktree and open it in a new tab: on its linked pull request's branch (Plotroom asks which when several have one), else on a new branch from the base you pick (Plotroom asks for the repository, and its checkout, the first time)", "w makes the issue's worktree, on a linked pull request's branch or a new one")
	eq(byKeys.a, "Pick a saved action, or type a prompt, and run it on the selected issue (typed prompts run in its worktree)", "a runs a prompt on the issue")
	b.press("escape")
	-- the second filter searches its own query
	b.press("tab")
	b.press("down")
	w.flush()
	eq(pickerOf(b).scope, "issues:v2", "the second issue filter is active")
	eq(requestsOf(s.gh, "issue-search")[2].fields.q, "is:open author:@me is:issue sort:updated-desc", "and searched")
	has(b.title(), "Created by me", "the title follows")
end)

case("host: narrowing the block folds the scope rail into a dropdown that names integration and profile, drops counts, and keeps the same scopes", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	b.cx.cols = 140
	b.cx:render()
	local function snap(): ({ string }, { [string]: any })
		local ids: { string } = {}
		local labels: { [string]: any } = {}
		for _, scope in pickerOf(b).scopes do
			table.insert(ids, scope.id)
			labels[scope.id] = scope
		end
		return ids, labels
	end
	local wideIds, wide = snap()
	eq(wide["issues:v1"].count, 3, "wide: the loaded filter has a count")
	b.cx.cols = 100
	b.cx:render()
	local narrowIds, narrow = snap()
	same(narrowIds, wideIds, "narrow: the same scopes in the same order")
	for id, scope in narrow do
		eq(scope.count, nil, "narrow: no count on " .. id)
	end
	has(narrow["issues:v1"].label, "GitHub - octocat", "narrow: the label carries integration and profile")
	has(narrow["issues:v1"].label, "Assigned to me", "narrow: and the filter name")
	eq(narrow["issues:v3"].label:sub(1, 6), "Jira: ", "narrow: an integration without a profile gets no dash")
	b.cx.cols = 140
	b.cx:render()
	local backIds, back = snap()
	same(backIds, wideIds, "wide again: the same scopes")
	eq(back["issues:v1"].count, 3, "wide again: the count returns")
	eq(back["issues:v1"].label, wide["issues:v1"].label, "and the plain label")
end)

case("host: the Keys page refuses a pull request prompt's shortcut while an issue filter is shown, and one set of keys serves both kinds of filter", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	w.kv.put("prompts-prs", { version = 1, nextId = 2, items = array({ promptOf("p1", "Review", "Review {url}", "e") }) })
	local b = openIssues(w)
	goToSettings(b, "keys")
	eq(bindKey(b, "agent", "e"), "Already the shortcut of the pull request action “Review”.", "a pull request prompt's key is refused on an issue filter too")
	b.press("escape")
	eq(bindKey(b, "worktree", "W"), nil, "a free key is accepted")
	b.press("escape")
	eq(b.press("w", nil, "w"), false, "the old key is left to the pane")
	eq(b.press("w", "s", "W"), true, "the new one works")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "on the selected issue")
	pickScope(b, "prs:v1")
	w.flush()
	eq(b.press("w", nil, "w"), false, "a pull request filter follows")
	eq(b.press("w", "s", "W"), true, "with the same key")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "on its selected pull request")
end)

case("host: pull request and issue filters share one sidebar with an icon each, and the active filter decides what is searched, listed, loaded and offered", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local b = openQueue(w)
	local entries: { string } = {}
	for _, scope in pickerOf(b).scopes do
		if scope.id ~= "worktrees" and scope.id ~= "agents" and scope.id ~= "inbox" then
			table.insert(entries, scope.id .. " " .. scope.icon .. " " .. scope.label)
		end
	end
	same(entries, {
		"prs:v1 merge My PRs",
		"prs:v2 merge Review requested",
		"issues:v1 list-checks Assigned to me",
		"issues:v2 list-checks Created by me",
		"issues:v3 list-checks Assigned to me",
		"issues:v4 list-checks Created by me",
	}, "one entry per filter of both stores, an icon for its kind: both stores have a v1, the entries do not")
	eq(pickerOf(b).scope, "prs:v1", "a new block starts on the first pull request filter")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "listing its pull requests")
	eq(pickerOf(b).noun, "pull requests", "counted as pull requests")
	eq(pickerOf(b).icon, "merge", "under the pull request icon")
	eq(buttonLink(b, "worktree"), prLink("worktree", "o/r", 1), "with the pull request's buttons")
	w.advance(300)
	eq(#requestsOf(s.gh, "checks"), 1, "its checks load")
	eq(#requestsOf(s.gh, "issue"), 0, "and no issue's details")
	pickScope(b, "issues:v1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 1, "no pull request was searched for the issue filter")
	eq(requestsOf(s.gh, "issue-search")[1].fields.q, "is:open assignee:@me is:issue sort:updated-desc", "the issue search is the filter's own")
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the list is its issues")
	eq(b.title(), "Plotroom · Assigned to me (3) · 2 new", "the title names it")
	eq(pickerOf(b).noun, "issues", "counted as issues")
	eq(pickerOf(b).icon, "list-checks", "under the issue icon")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "with the issue's buttons")
	b.typeText("w")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "and the Worktree key opens the issue's link")
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 1, "the issue's details load")
	eq(#requestsOf(s.gh, "checks"), 1, "and no pull request's checks")
	pickScope(b, "prs:v1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "back on the pull request filter, a list of issues is no list of its pull requests: it searches again")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and lists them")
	eq(buttonLink(b, "worktree"), prLink("worktree", "o/r", 1), "with the pull request's buttons")
	b.typeText("w")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and its Worktree key")
	eq(#requestsOf(s.gh, "issue-search"), 1, "the issues were searched once")
end)

case("host: a block saves the kind of its filter and restores it: both stores have a v1, and a pane saved before issue filters joined the block is on a pull request filter", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local b = openQueue(w)
	eq(b.saved().activeKind, nil, "a pull request filter saves no kind, as before")
	pickScope(b, "issues:v1")
	w.flush()
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the store's own id is saved")
	eq(saved.activeKind, "issues", "with the kind of its store")
	local again = w.open(2, { "/work/r" }, saved)
	w.flush()
	eq(pickerOf(again).scope, "issues:v1", "a restored block is on the issue filter, not the pull request filter of the same id")
	same(listed(again), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "listing its issues")
	pickScope(again, "prs:v2")
	w.flush()
	eq(again.saved().activeKind, nil, "back on a pull request filter it saves none again")
	local back = w.open(3, { "/work/r" }, again.saved())
	w.flush()
	eq(pickerOf(back).scope, "prs:v2", "one saved on a pull request filter is restored on it")
	local before = w.open(4, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeViewId = "v2" })
	w.flush()
	eq(pickerOf(before).scope, "prs:v2", "a pane saved with no kind, as every pane was before issue filters, is on a pull request filter")
	local odd = w.open(5, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "bugs", activeViewId = "v2" })
	w.flush()
	eq(pickerOf(odd).scope, "prs:v2", "so is one saved with a kind the block does not know")
end)

case("host: a search that lands after the filter switched to the other kind is dropped, whichever kind it was for", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	-- gh answers the searches of the kinds in `late` five seconds late, with the list its model holds
	local late: { [string]: boolean } = { search = true }
	s.gh.override = function(req: GhReq): Reply?
		if not late[req.kind] then
			return nil
		end
		local list = if req.kind == "search" then s.gh.items.octocat else s.gh.issueItems.octocat
		return { delay = 5000, stdout = jsonEncode({ total = #list, next = NULL, cost = 1, items = list }) }
	end
	local b = openQueue(w)
	eq(pickerOf(b).state, "loading", "the pull request search is on its way")
	late.search = false
	pickScope(b, "issues:v1")
	w.flush()
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the issue filter shows its own list at once")
	w.advance(5000)
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the pull request answer that came late does not replace it")
	eq(pickerOf(b).noun, "issues", "the block still counts issues")
	eq(b.title(), "Plotroom · Assigned to me (3) · 2 new", "under the issue filter's title")
	pickScope(b, "prs:v1")
	w.flush()
	eq(#requestsOf(s.gh, "search"), 2, "the late answer was dropped, not kept: the pull request filter searches again")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and lists its own pull requests")
	late["issue-search"] = true
	pickScope(b, "issues:v2")
	late["issue-search"] = false
	pickScope(b, "prs:v2")
	w.flush()
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "a second pull request filter lists its pull requests while the issue search is out")
	w.advance(5000)
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the issue answer that came late does not replace them")
	eq(pickerOf(b).noun, "pull requests", "the block still counts pull requests")
	eq(pickerOf(b).scope, "prs:v2", "on the filter that was shown")
end)

case("host: a pull request's worktree and an issue's stay each their own kind's across filter switches: neither wears the other's badge or card", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 2)
	local prPath = leaveWt(w, s, 1)
	local issuePath = leaveIssueWt(w, s, 12)
	local b = openQueue(w)
	yes(badgeOf(b, 1) ~= nil, "the pull request with a worktree wears its badge")
	eq(badgeOf(b, 2), nil, "the other wears none")
	has(cardText(b), prPath, "its card says where the worktree is")
	pickScope(b, "issues:v1")
	w.flush()
	yes(badgeOf(b, 1) ~= nil, "issue 12 wears its own badge")
	eq(badgeOf(b, 2), nil, "issue 13 wears none")
	eq(badgeOf(b, 3), nil, "nor does issue 14")
	has(cardText(b), issuePath, "the selected issue's card is its worktree")
	lacks(cardText(b), prPath, "not the pull request's")
	pickScope(b, "prs:v1")
	w.flush()
	yes(badgeOf(b, 1) ~= nil, "back on the pull requests the first still wears its badge")
	eq(badgeOf(b, 2), nil, "and the second none")
	has(cardText(b), prPath, "its card is the pull request's again")
	eq(countLog(s.git, "worktree add"), 0, "nothing was made")
end)

case("host: an issue row names its number, repository, author and age, wears its labels, shows no assignee, and says why a closed issue closed", function(w: World)
	local s = issueHost(w)
	s.gh.issueItems.octocat = {
		issueItem(12, "o/r", EPOCH - 60, { title = "Fix login", labels = array({ "bug", "ui" }), assignees = array({ "ann", "bob" }), comments = 3 }),
		issueItem(13, "o/r", EPOCH - 120, { state = "CLOSED", reason = "COMPLETED", comments = 0 }),
		issueItem(14, "o/r", EPOCH - 180, { state = "CLOSED", reason = "NOT_PLANNED", assignees = array({ "cy" }) }),
		issueItem(15, "o/r", EPOCH - 240, { state = "CLOSED", reason = "DUPLICATE" }),
		issueItem(16, "o/r", EPOCH - 300, { state = "CLOSED" }),
	}
	local b = openIssues(w)
	local function row(i: number): any
		return pickerOf(b).items[i]
	end
	-- A row's badges as "text/tone", in order.
	local function badges(i: number): string
		local out: { string } = {}
		for _, badge in row(i).badges or {} do
			if badge.text ~= "New" then
				table.insert(out, badge.text .. "/" .. (badge.tone or "-"))
			end
		end
		return table.concat(out, " ")
	end
	eq(row(1).id, "no_2fr_2312", "the id is n and the issue's reference")
	eq(row(1).label, "Fix login", "the title is the label")
	eq(detailText(row(1)), "#12 · o/r · @octo opened 1m ago", "the number, the repository, the author and the age")
	eq(detailText(row(3)), "#14 · o/r · @octo opened 3m ago", "a lone assignee is not in the detail")
	eq(detailText(row(2)), "#13 · o/r · @octo opened 2m ago", "nor is the lack of one")
	eq(row(1).mark.text, "octo", "the author's mark")
	eq(row(1).facts, nil, "the rows carry no facts column: no comment count, no assignee")
	eq(pickerOf(b).columns, nil, "and the picker has no columns")
	local head: any = findKey(pickerNode(b), "head")
	eq(findKey(head, "integration").p.text, "GitHub", "the head row names GitHub")
	eq(findKey(head, "integration").p.tone, "muted", "muted for GitHub")
	eq(findKey(findKey(pickerNode(b), "titlerow"), "integration"), nil, "and the title row has no badge")
	eq(badges(1), "GitHub/muted bug/- ui/-", "the integration is the first badge, then the labels")
	eq(badges(2), "GitHub/muted Completed/accent", "a completed issue")
	eq(badges(3), "GitHub/muted Not planned/muted", "one closed as not planned")
	eq(badges(4), "GitHub/muted Duplicate/muted", "a duplicate")
	eq(badges(5), "GitHub/muted Closed/error", "and a closed one with no reason")
	leaveIssueWt(w, s, 14)
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-14/src" })
	refreshNow(w, b)
	eq(badges(3), "GitHub/muted In tab/accent Worktree/- Not planned/muted", "a tab working in the issue's worktree marks its row, after the integration and before its worktree and state")
	eq(badges(1), "GitHub/muted bug/- ui/-", "and no other row")
end)

case("host: the issue preview shows its body, assignees, milestone, linked pull requests and the branch it would create", function(w: World)
	local s = issueHost(w)
	leaveIssueWt(w, s, 12)
	s.gh.issueDetail["o/r#12"] = {
		body = "Steps to reproduce:\n\n1. Open /login",
		milestone = "v2",
		linked = array({
			{ number = 45, title = "Fix the login redirect", url = "https://github.com/o/r/pull/45", state = "OPEN", isDraft = false },
			{ number = 44, title = "A first try", url = "https://github.com/o/r/pull/44", state = "OPEN", isDraft = true },
			{ number = 43, title = "An older fix", url = "https://github.com/o/r/pull/43", state = "MERGED", isDraft = false },
		}),
	}
	local b = openIssues(w)
	has(b.text(), "Loading details…", "the linked pull requests shimmer while the details load")
	eq(#requestsOf(s.gh, "issue"), 0, "nothing loads the moment an issue is selected")
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 1, "the details load once the cursor rests")
	lacks(b.text(), "Loading details…", "the shimmer is gone")
	local preview = pickerNode(b)
	local branch = findKey(preview, "branch")
	eq(findKey(branch, "v").p.spans[1].t, "octocat/12-fix-login", "the branch Worktree would make: the default format over gh's active login, the issue's key and its title's slug")
	eq(findKey(branch, "copy", "icon").p.href, "octocat/12-fix-login", "with a copy icon")
	w.kv.put("branch-format", "{key}-{slug}")
	b.render()
	eq(findKey(findKey(pickerNode(b), "branch"), "v").p.spans[1].t, "12-fix-login", "a format saved in Settings shows through")
	local head = findKey(preview, "head")
	eq(findKey(head, "copy", "icon").p.href, "https://github.com/o/r/issues/12", "the head's copy icon takes the issue's link")
	eq(findKey(head, "state", "badge").p.text, "Open", "the state")
	eq(findKey(preview, "title").p.spans[1].t, "Fix login", "the title")
	eq(findKey(preview, "buttons").p.hidden, true, "the buttons' links sit in an unseen node")
	eq(factOf(b, "Author"), "@octo", "author")
	eq(factOf(b, "Assignees"), "@ann, @bob", "assignees")
	eq(factOf(b, "Milestone"), "v2", "milestone, from the details")
	eq(factOf(b, "Comments"), "3", "comments")
	local function card(): any
		return findKey(pickerNode(b), "description", "card")
	end
	eq(card().p.role, "plotroom.description", "the description is the PR's own card")
	eq(findKey(card(), "body", "md").p.text, "Steps to reproduce:\n\n1. Open /login", "the body as Markdown")
	local linked: { string } = {}
	for i = 1, 3 do
		local item: any = findKey(preview, "pr" .. i, "item")
		table.insert(linked, item.p.label .. " | " .. item.p.value .. " | " .. item.p.icon .. " | " .. item.p.tone .. " | " .. item.p.title)
	end
	same(linked, {
		"Fix the login redirect | #45 | merge | success | #45 · Open",
		"A first try | #44 | merge | muted | #44 · Draft",
		"An older fix | #43 | merge | accent | #43 · Merged",
	}, "each linked pull request: its title, its number at the right, the icon toned by its state, which the tooltip names")
	eq(findKey(preview, "linked-head1"), nil, "pull requests have no relation heading")
	has(b.text(), "12-fix-login", "the branch is on screen")
	has(b.text(), "#45", "and so is a linked pull request")
	eq(card().p.collapsed, true, "the description starts folded")
	b.event({ ev = "toggle", id = "layer.queue.description", key = "description", collapsed = false })
	eq(card().p.collapsed, false, "the more-lines button's unfolding is kept")
	local less: any = findKey(pickerNode(b), "less", "item")
	b.event({ ev = "action", id = "layer.queue.less", act = less.p.actions.click })
	eq(card().p.collapsed, true, "Show less folds it again")
	-- the chips: labels, and In tab while a tab works in the issue's worktree
	local function chips(): { string }
		local out: { string } = {}
		for _, chip in findKey(pickerNode(b), "chips").c do
			table.insert(out, chip.p.text)
		end
		return out
	end
	same(chips(), { "bug", "ui" }, "the labels are chips")
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-12" })
	b.render()
	same(chips(), { "In tab", "bug", "ui" }, "a tab in the issue's worktree adds In tab first")
	-- an issue with no milestone, assignee or pull request, and no description
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2313" })
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 2, "the next issue loads its own details")
	eq(factOf(b, "Milestone"), nil, "no milestone row")
	eq(factOf(b, "Assignees"), nil, "no assignee row")
	eq(findKey(pickerNode(b), "pr1"), nil, "no linked pull request")
	lacks(b.text(), "Linked pull requests", "and no heading for them")
	eq(findKey(pickerNode(b), "description"), nil, "an empty body shows no card")
	eq(findKey(findKey(pickerNode(b), "head"), "state", "badge").p.text, "Not planned", "a closed issue says why in the head's badge")
end)

case("host: the issue preview shows the pull request whose head is its worktree's branch (the open one first), unless the linked list has it", function(w: World)
	local s = issueHost(w)
	leaveIssueWt(w, s, 12)
	s.gh.heads["o/r@12-fix-login"] = {
		{ number = 40, title = "Old try", state = "CLOSED", isDraft = false, url = "https://github.com/o/r/pull/40" },
		{ number = 45, title = "Fix the login redirect", state = "OPEN", isDraft = true, url = "https://github.com/o/r/pull/45" },
	}
	local b = openIssues(w)
	w.advance(300)
	local item: any = findKey(pickerNode(b), "hp1", "item")
	eq(item.p.label, "Fix the login redirect", "the open pull request, not the older closed one")
	eq(item.p.value, "#45", "its number")
	eq(item.p.title, "#45 · Draft", "and its state")
	eq(item.p.href, "plotroom://github/show/o/r/45", "a link that shows it in this block")
	has(b.text(), "Pull request", "under its heading")
	-- Another issue has no worktree: nothing is asked for it.
	local asked = #requestsOf(s.gh, "head")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2313" })
	w.advance(300)
	eq(findKey(pickerNode(b), "headpr-head"), nil, "an issue with no worktree shows no pull request")
	eq(#requestsOf(s.gh, "head"), asked, "and looks none up")
end)

case("host: the issue preview does not repeat a pull request the linked list already shows", function(w: World)
	local t = issueHost(w)
	leaveIssueWt(w, t, 12)
	t.gh.heads["o/r@12-fix-login"] = { { number = 45, title = "Fix the login redirect", state = "OPEN", isDraft = false, url = "https://github.com/o/r/pull/45" } }
	t.gh.issueDetail["o/r#12"] = {
		body = "x",
		linked = array({ { number = 45, title = "Fix the login redirect", url = "https://github.com/o/r/pull/45", state = "OPEN", isDraft = false } }),
	}
	local c = openIssues(w)
	w.advance(300)
	eq(#requestsOf(t.gh, "head"), 1, "the lookup ran")
	yes(findKey(pickerNode(c), "pr1", "item") ~= nil, "the linked list shows the pull request")
	eq(findKey(pickerNode(c), "headpr-head"), nil, "and the head lookup does not repeat it")
end)

-- A PR's preview takes the issue noted on its worktree's branch from the last scan's notes: the issue list's scan noted
-- issue 12 on `bob/12-fix-login`, the head branch of fork PR 1 (a fork's worktree is on <owner>/<branch>).
local function notedScene(w: World): (HostScene, Block)
	local s = issueHost(w)
	s.gh.items.work = { searchItem(1, "o/r", EPOCH - 60, { head = "12-fix-login", fork = "bob" }), searchItem(2, "o/r", EPOCH - 120) }
	s.gh.tokens.work = "tok-work"
	local views: any = w.kv.get("views-prs")
	views.items[1].logins = array({ "work" })
	w.kv.put("views-prs", views)
	w.kv.put("branch-formats", { ["o/r"] = "bob/{key}-{slug}" })
	table.insert(s.git.worktrees, { path = "/wt/iss", branch = "refs/heads/bob/12-fix-login", head = sha("b"), locked = false })
	w.fs.dirs["/wt/iss"] = true
	s.gh.pulls["https://github.com/o/r/issues/12"] = issueItem(12, "o/r", EPOCH - 60, { title = "Fix login" })
	local b = openIssues(w)
	pickScope(b, "prs:v1")
	w.flush()
	return s, b
end

case("host: the pull request preview shows the issue noted for a fork's worktree, read as the view's account", function(w: World)
	local s, b = notedScene(w)
	w.advance(300)
	local item: any = findKey(pickerNode(b), "issue1", "item")
	eq(item.p.label, "Fix login", "the issue's title")
	eq(item.p.value, "#12", "its key")
	eq(item.p.title, "#12 · Open", "and its status")
	eq(string.sub(item.p.href, 1, 22), "plotroom://issue/open/", "a link that opens it in a Browser block")
	eq(#requestsOf(s.gh, "head"), 0, "a pull request preview looks up no pull request")
	local read: GhReq? = nil
	for _, req in requestsOf(s.gh, "pull") do
		if req.fields.q == "https://github.com/o/r/issues/12" then
			read = req
		end
	end
	eq(if read then read.login else nil, "work", "the issue was read as the view's login, not gh's active one (octocat)")
end)

case("host: selecting a pull request lists no worktrees, and one before its checkout's scan shows no issue", function(w: World)
	local s, b = notedScene(w)
	w.advance(300)
	local mark = #s.git.log
	showPr(b, 2)
	w.advance(300)
	showPr(b, 1)
	w.advance(300)
	eq(countLog(s.git, "worktree list", mark), 0, "no listing for the selections")
	yes(findKey(pickerNode(b), "issue1", "item") ~= nil, "and the issue is still shown")
	local fresh = w.open(2, { "/work/r" })
	w.flush()
	w.advance(300)
	yes(findKey(pickerNode(fresh), "issue1", "item") == nil, "a block that scanned only its pull requests has noted no issue")
end)

case("host: a block told to show a pull request selects it where its pull request filter lists it, else looks it up alone in a pinned scope, and from an issue filter always pins", function(w: World)
	local s = hostScene(w, 3)
	local url = "https://github.com/o/r/pull/45"
	s.gh.pulls[url] = searchItem(45, "o/r", EPOCH - 600, { title = "Fix the login redirect" })
	local b = openQueue(w)
	b.typeText("s")
	b.event({ ev = "action", act = "show-pr", value = "https://github.com/o/r/pull/2" })
	eq(pickerOf(b).selected, "no_2fr_232", "a PR the view lists is selected in it")
	eq(findKey(b.view().layer, "settings", "prefs"), nil, "Settings closes to show it")
	eq(#requestsOf(s.gh, "pull"), 0, "nothing is looked up")
	eq(pickerOf(b).scopes[1].label, "My PRs", "and nothing is pinned")
	b.event({ ev = "action", act = "show-pr", value = url })
	w.flush()
	eq(requestsOf(s.gh, "pull")[1].fields.q, url, "one the view does not list is looked up by its URL")
	same(listed(b), { "no_2fr_2345" }, "and listed alone")
	eq(pickerOf(b).selected, "no_2fr_2345", "selected")
	eq(pickerOf(b).scopes[1].label, "o/r#45", "under a scope named after it, first in the sidebar")
	eq(pickerOf(b).scope, pickerOf(b).scopes[1].id, "which is the active one")
	eq(b.title(), "Plotroom · o/r#45 (1)", "the block's title names it")
	b.event({ ev = "action", act = "show-pr", value = "https://example.com/o/r/pull/1" })
	eq(#requestsOf(s.gh, "pull"), 1, "anything but a pull request URL is ignored")
	eq(pickerOf(b).scopes[1].label, "o/r#45", "and keeps the pin")
	eq(b.saved().activeViewId, "pin:o/r#45", "the pinned scope is saved by its id")
	same(b.saved().pins, { url }, "and its URL is in the saved pins")
	local restored = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(pickerOf(restored).scopes[1].label, "o/r#45", "a restored block has its pin in the sidebar")
	eq(pickerOf(restored).selected, "no_2fr_2345", "and the pinned item is selected")
	local launched = w.open(3, { "/work/r", url })
	w.flush()
	eq(pickerOf(launched).selected, "no_2fr_2345", "a block launched on a pull request starts on it")
	eq(pickerOf(launched).scope, "pin:o/r#45", "in its pinned scope")
	s.gh.pulls["https://github.com/o/r/pull/2"] = searchItem(2, "o/r", EPOCH - 120)
	local issues = w.open(4, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeKind = "issues", activeViewId = "v1" })
	w.flush()
	eq(pickerOf(issues).noun, "issues", "a block on an issue filter lists issues")
	local looked = #requestsOf(s.gh, "pull")
	issues.event({ ev = "action", act = "show-pr", value = "https://github.com/o/r/pull/2" })
	w.flush()
	eq(requestsOf(s.gh, "pull")[looked + 1].fields.q, "https://github.com/o/r/pull/2", "told to show a pull request, it looks it up alone: an issue filter lists no pull requests")
	same(listed(issues), { "no_2fr_232" }, "and lists that one")
	eq(pickerOf(issues).scope, "pin:o/r#2", "in the pinned scope")
	eq(pickerOf(issues).noun, "pull requests", "as pull requests")
	pickScope(issues, "issues:v1")
	w.flush()
	eq(pickerOf(issues).noun, "issues", "the issue filter is one click away")
	eq(issues.saved().activeKind, "issues", "and what the block saves again")
end)

case("host: an issue's details that fail to load show the error and a Retry that asks again", function(w: World)
	local s = issueHost(w)
	local failing = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" and failing then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	s.gh.issueDetail["o/r#12"] = { body = "Back again.", linked = array({}) }
	local b = openIssues(w)
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 1, "one load")
	has(b.text(), "Server Error", "the error is on screen")
	has(b.text(), "Retry", "with a Retry button")
	lacks(b.text(), "Loading details…", "and no shimmer")
	failing = false
	b.event({ ev = "action", id = "layer.queue", act = "retry-checks" })
	w.advance(300)
	eq(#requestsOf(s.gh, "issue"), 2, "Retry asks again")
	has(b.text(), "Back again.", "the details arrived")
	lacks(b.text(), "Server Error", "and the error is gone")
end)

case("host: a prompt set to the main checkout answers with the checkout and spawns nothing", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local ran = #w.calls
	request(b, "i1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	w.flush()
	local a = answerOf(b, "i1")
	eq(a.path, "/work/r", "the answer is the saved checkout")
	eq(a.summary, "Main checkout", "which says what it is")
	eq(a.created, false, "nothing was created")
	eq(a.current, true, "nothing is out of date")
	eq(a.busy, nil, "it is never busy")
	same(a.vars, {
		url = "https://github.com/o/r/issues/12",
		owner = "o",
		repo = "r",
		key = "12",
		number = "12",
		title = "Fix login",
		author = "octo",
		labels = "bug, ui",
	}, "the issue's variables, with no branch: there is no worktree")
	eq(#w.calls, ran, "nothing was spawned")
	eq(w.opened[#w.opened], "plotroom://rpc/i1", "the window is told to read the answer")
	eq(badgeOf(b), nil, "no worktree is noted on the row")
	eq(cardOf(b), nil, "or in the preview")
end)

case("host: an issue request makes its worktree once, notes it on the block, and refuses a repeat while it runs", function(w: World)
	local s = issueHost(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	local b = openIssues(w)
	local target = "/wt/plotroom-o_r-issue-12"
	eq(badgeOf(b), nil, "no badge before there is a worktree")
	eq(cardOf(b), nil, "and no card")
	request(b, "a1", freshAsk("o/r", "12"))
	request(b, "a2", freshAsk("o/r", "12"))
	eq(answerOf(b, "a2").busy, true, "a repeat while it runs is told so")
	w.flush()
	local a = answerOf(b, "a1")
	eq(a.path, target, "the answer says where the worktree is")
	eq(a.created, true, "created")
	eq(a.current, true, "a new branch starts at the default branch: current")
	eq(a.dirty, false, "clean")
	eq(a.summary, "Created · octocat/12-fix-login at bbbbbbb · Clean", "and sums it up")
	eq(a.setup, "pnpm install", "a new worktree is set up")
	eq(a.vars.branch, "octocat/12-fix-login", "its branch joins the variables: the default format, over the gh login")
	eq(a.vars.title, "Fix login", "with the rest")
	eq(countLog(s.git, "worktree add -b octocat/12-fix-login " .. target .. " " .. sha("b")), 1, "made once")
	eq(w.opened[#w.opened], "plotroom://rpc/a1", "the window is told to read it")
	yes(badgeOf(b) ~= nil, "a worktree puts a badge on the row")
	eq(badgeOf(b).tone, "success", "a current, clean worktree is a success")
	eq(cardOf(b).p.tone, "success", "and a card in the preview")
	has(cardText(b), target, "that says where it is")
	eq(findKey(findKey(cardOf(b), "wbranch"), "v").p.spans[1].t, "octocat/12-fix-login", "the card shows its branch")
	same(chipsOf(b), { "Clean" }, "and one badge: an issue has no pull request head to be at")
	same(buttonsOf(b), { "open:Open in new tab", "remove:Remove worktree", "git:Open in Git" }, "with the buttons to open its tab or remove it")
	eq(commandsOf(b, "update"), nil, "and none to update it: the issue has no head to follow")
	request(b, "a3", freshAsk("o/r", "12"))
	w.flush()
	local again = answerOf(b, "a3")
	eq(again.created, false, "the second request reuses it")
	eq(again.setup, nil, "which is not set up again")
	eq(again.summary, "Reused · octocat/12-fix-login at bbbbbbb · Clean", "and says so")
	eq(countLog(s.git, "worktree add"), 1, "still made once")
	s.git.dirty[target] = " M src/a.lua\n"
	request(b, "a4", freshAsk("o/r", "12"))
	w.flush()
	eq(answerOf(b, "a4").summary, "Reused · octocat/12-fix-login at bbbbbbb · Modified (uncommitted changes kept)", "local changes are reported")
	eq(badgeOf(b).tone, "warning", "and deserve a look")
	s.git.dirty[target] = nil
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2313" })
	w.fs.denyMkdir["/wt"] = "mkdir denied"
	request(b, "a5", freshAsk("o/r", "13"))
	w.flush()
	has(answerOf(b, "a5").problem, "mkdir denied", "a worktree that cannot be made is answered with the reason")
	eq(badgeOf(b, 2), nil, "it shows no badge")
	eq(cardOf(b).p.tone, "error", "but an error card")
	has(cardText(b), "mkdir denied", "with the reason")
	for _, never in { "worktree remove", "branch", "update-ref", "merge", "config" } do
		eq(countLog(s.git, never), 0, "git " .. never .. " was never run")
	end
end)

case("host: an issue's worktree is removed with its branch only when git agrees, and a branch git keeps is named", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	local target = "/wt/plotroom-o_r-issue-12"
	local function ask()
		request(b, "a1", freshAsk("o/r", "12"))
		w.flush()
	end
	ask()
	s.git.unmerged["octocat/12-fix-login"] = true
	local mark = #s.git.log
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), { "worktree remove " .. target, "branch -d octocat/12-fix-login", "worktree list --porcelain -z" }, "-d only: no ancestry check, no -D, no ref; then a read of the checkout")
	eq(cardOf(b), nil, "the card goes")
	eq(badgeOf(b), nil, "and the row's badge")
	eq(w.toasts[#w.toasts].sub, "Branch octocat/12-fix-login was kept. The branch 'octocat/12-fix-login' is not fully merged.", "the branch git kept is named")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("b"), "with its commits")
	s.git.unmerged["octocat/12-fix-login"] = nil
	ask()
	eq(answerOf(b, "a1").created, true, "a new worktree attaches the branch that stayed")
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	eq(w.toasts[#w.toasts].sub, "Branch octocat/12-fix-login was deleted too.", "merged now, it goes with the next removal")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], nil, "and is gone")
	ask()
	s.git.dirty[target] = " M src/a.lua\n"
	pressCard(b, "remove")
	b.typeText("d")
	w.flush()
	has(cardText(b), "Not removed. It has uncommitted changes; commit, stash or remove it yourself.", "changes git refuses to lose keep the card, with the reason")
	same(chipsOf(b), { "Uncommitted changes" }, "and the badge learns of them")
end)

case("host: an issue request is dropped unless it is well formed", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, value: any)
		b.event({ ev = "action", act = "rpc", value = value })
		w.flush()
		for _, probe in { "a1", "m1" } do
			eq(answerOf(b, probe), nil, what .. ": no answer is kept for " .. probe)
		end
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.toasts, 0, what .. ": or said")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	local repos: { any } = { 5, "o", "o/r/x", "o/..", "../r", "o/r r" }
	for _, repo in repos do
		ignored("the repository " .. show(repo), jsonEncode({ id = "a1", op = "issue", repo = repo, ref = "12", worktree = false }))
	end
	local refs: { any } = { "", "a/b", "a b", "1.5", string.rep("1", 65), true }
	for _, ref in refs do
		ignored("the reference " .. show(ref), jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = ref, worktree = false }))
	end
	local wheres: { any } = { "yes", 1 }
	for _, where in wheres do
		ignored("worktree " .. show(where), jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = "12", worktree = where }))
	end
	ignored("no worktree field", jsonEncode({ id = "a1", op = "issue", repo = "o/r", ref = "12" }))
	request(b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	w.flush()
	eq(answerOf(b, "a2").path, "/work/r", "a well-formed request is answered")
end)

case("host: an issue request reports an issue the block no longer lists, a missing checkout and a branch format that no longer holds", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	local ran = #w.calls
	-- the issue is looked up in every list the block has loaded, not only the one on screen
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "issue-search" and string.find(req.fields.q, "author:@me", 1, true) then
			return { stdout = jsonEncode({ total = 1, next = NULL, cost = 1, items = array({ issueItem(20, "o/r", EPOCH - 30, { title = "Mine" }) }) }) }
		end
		return nil
	end
	b.press("tab")
	b.press("down")
	w.flush()
	same(listed(b), { "no_2fr_2320" }, "the second filter lists another issue")
	request(b, "k1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(answerOf(b, "k1").vars.title, "Fix login", "an issue of the first filter's list is still known")
	request(b, "k2", { op = "issue", repo = "o/r", ref = "20", worktree = false })
	eq(answerOf(b, "k2").vars.title, "Mine", "and so is one of the list on screen")
	request(b, "k3", { op = "issue", repo = "o/r", ref = "99", worktree = false })
	eq(answerOf(b, "k3").problem, "That issue is not loaded here any more; Refresh and try again.", "an issue no list has is refused")
	request(b, "k4", { op = "issue", repo = "O/R", ref = "12", worktree = false })
	eq(answerOf(b, "k4").vars.title, "Fix login", "the repository's case does not matter")
	ran = #w.calls
	-- a branch format that no longer holds
	w.kv.put("branch-formats", { ["o/r"] = "{foo}" })
	request(b, "f1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	w.flush()
	eq(answerOf(b, "f1").problem, "Unknown variable {foo}.", "a worktree is refused with the format's problem")
	eq(#w.calls, ran, "and git was never asked anything")
	request(b, "f2", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(answerOf(b, "f2").path, "/work/r", "the main checkout needs no branch")
	-- no saved checkout
	forgetCheckouts(w)
	request(b, "c1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(answerOf(b, "c1").needCheckout, "o/r", "no checkout, no main checkout: the window is asked for one")
	request(b, "c2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(answerOf(b, "c2").needCheckout, "o/r", "nor a worktree")
	eq(#w.calls, ran, "and nothing ran")
end)

case("host: the branch format rejects unknown variables and saves per repository", function(w: World)
	issueHost(w)
	w.kv.put("checkouts", { ["x/y"] = "/work/y" })
	w.kv.put("branch-formats", { ["x/y"] = "keep/{key}" })
	local b = openIssues(w)
	goToSettings(b, "repos")
	local function rows(): { string }
		local out: { string } = {}
		for _, section in prefsOf(b).sections do
			for _, r in section.rows do
				table.insert(out, r.id)
			end
		end
		return out
	end
	same(rows(), { "ropen:o/r", "ropen:x/y", "radd" }, "each repository is a summary row, then the Add button: the launch one was added")
	eq(rowIn(b, "ropen:x/y").hint, "/work/y · keep/{key}", "a summary shows the checkout and the repository's own branch format")
	eq(rowIn(b, "ropen:x/y").control.label, "Edit", "and opens with Edit")
	eq(rowIn(b, "branch:o/r"), nil, "the fields stay folded")
	expand(b, "ropen:o/r")
	eq(prefsOf(b).focus, "checkout:o/r", "Edit opens the form on its checkout")
	same(rows(), { "ropen:o/r", "rremove:o/r", "checkout:o/r", "branch:o/r", "setup:o/r:new", "ropen:x/y", "radd" }, "one form is open, its Remove right after its Done")
	eq(rowIn(b, "ropen:o/r").control.label, "Done", "Edit turned Done")
	local row = rowIn(b, "branch:o/r")
	eq(row.label, "Issue branch name", "label")
	eq(row.hint, nil, "no description")
	eq(row.control.k, "text", "a text field")
	eq(row.control.placeholder, "{github.user}/{key}-{slug}", "the Worktrees format is its placeholder")
	eq(row.control.value, "", "nothing is saved for o/r")
	eq(row.changed, false, "so the row is not marked changed")
	has(row.defaultLabel, "Worktrees", "and a reset says where the default comes from")
	has(b.text(), "octocat/12-fix-login", "the preview shows the branch the Worktrees format makes")
	local function save(text: string)
		b.event({ ev = "select", id = "layer.settings", item = "branch:o/r" })
		b.press("enter")
		for _ = 1, 40 do
			b.press("backspace")
		end
		b.typeText(text)
		b.press("enter")
	end
	save("{foo}")
	eq(rowIn(b, "branch:o/r").warning, "Unknown variable {foo}.", "an unknown variable is refused by name")
	eq(prefsOf(b).editing.row, "branch:o/r", "the draft stays for a correction")
	b.press("escape")
	save("x-{slug}")
	eq(rowIn(b, "branch:o/r").warning, "Include {key}, so each issue gets its own branch.", "a format without {key} would give every issue one branch")
	b.press("escape")
	same(w.kv.get("branch-formats"), { ["x/y"] = "keep/{key}" }, "nothing was saved")
	save("feat/{key}")
	eq(prefsOf(b).editing, nil, "a good format closes the edit")
	eq(w.kv.get("branch-formats")["o/r"], "feat/{key}", "and is saved under the repository")
	eq(w.kv.get("branch-formats")["x/y"], "keep/{key}", "another repository's format is kept")
	eq(rowIn(b, "branch:o/r").control.value, "feat/{key}", "the row shows it")
	eq(rowIn(b, "branch:o/r").changed, true, "as changed")
	has(b.text(), "feat/12", "and the preview's branch follows")
	save("")
	eq(w.kv.get("branch-formats")["o/r"], nil, "an empty format goes back to the default")
	eq(w.kv.get("branch-formats")["x/y"], "keep/{key}", "without touching the other repository")
	save("{owner}/{key}")
	eq(w.kv.get("branch-formats")["o/r"], "{owner}/{key}", "saved again")
	b.event({ ev = "change", id = "layer.settings", item = "branch:o/r" })
	eq(w.kv.get("branch-formats")["o/r"], nil, "Reset clears it")
	eq(rowIn(b, "branch:o/r").control.value, "", "the row is empty again")
	eq(rowIn(b, "branch:o/r").changed, false, "and unchanged")
	-- a saved format that no longer holds, by hand, shows no branch; an unreadable map is never overwritten
	w.kv.put("branch-formats", { ["o/r"] = "{foo}" })
	b.render()
	eq(findKey(pickerNode(b), "branch"), nil, "the preview shows no branch the format cannot name")
	w.kv.put("branch-formats", "garbage")
	b.render()
	save("feat/{key}")
	eq(w.kv.get("branch-formats"), "garbage", "an unreadable map is never overwritten")
	eq(findKey(findKey(pickerNode(b), "branch"), "v").p.spans[1].t, "octocat/12-fix-login", "and the Worktrees format applies meanwhile")
end)

case("host: issue prompts are separate from PR prompts, each kind's on the Prompts page and offered under its own filters, and they carry where they run", function(w: World)
	issueHost(w)
	savePrompts(w, { promptOf("p1", "PR only", "Review {url}") })
	saveIssuePrompts(w, {
		issuePrompt("p1", "Triage", "Triage {url}", true, "t"),
		issuePrompt("p2", "Notes", "Summarise {title}", false),
		issuePrompt("p3", "Old", "Old {url}"),
	})
	local b = openIssues(w)
	local asked = 0
	-- The rows the block answers a menu request with.
	local function menu(): { any }
		asked += 1
		request(b, "m" .. asked, { op = "menu" })
		w.flush()
		return answerOf(b, "m" .. asked).items
	end
	same(menu(), {
		{ id = "p1", label = "Triage", detail = "Triage {url}", group = "All actions", send = "Triage {url}", worktree = true, key = "t" } :: any,
		{ id = "p2", label = "Notes", detail = "Summarise {title}", group = "All actions", send = "Summarise {title}", worktree = false },
		{ id = "p3", label = "Old", detail = "Old {url}", group = "All actions", send = "Old {url}", worktree = true },
	}, "an issue filter offers the issue prompts, each saying where it runs and its key; one saved without the field runs in a worktree")
	pickScope(b, "prs:v1")
	w.flush()
	same(menu(), {
		{ id = "p1", label = "PR only", detail = "Review {url}", group = "All actions", send = "Review {url}", worktree = true },
	}, "a pull request filter offers the pull request prompts, saying where each runs too: both stores have a p1")
	pickScope(b, "issues:v1")
	w.flush()
	goToSettings(b, "prompts")
	local order: { string } = {}
	for _, section in prefsOf(b).sections do
		table.insert(order, section.id)
	end
	same(order, { "prompts:prs", "add:prs", "prompts:issues", "add:issues" }, "the page lists both kinds' prompts in a section each, the pull request prompts first, each followed by its Add button")
	local listed: { string } = {}
	for _, section in prefsOf(b).sections do
		for _, r in section.rows do
			table.insert(listed, r.id)
		end
	end
	same(listed, { "popen:prs:p1", "padd:prs", "prestore:prs", "popen:issues:p1", "popen:issues:p2", "popen:issues:p3", "padd:issues", "prestore:issues" }, "each kind's prompts are summary rows with the kind's Add row, then Restore defaults (none of these is named like a default), last")
	expand(b, "popen:issues:p1")
	local ids: { string } = {}
	for _, section in prefsOf(b).sections do
		if section.id == "form:issues:p1" then
			for _, r in section.rows do
				table.insert(ids, r.id)
			end
		end
	end
	same(ids, { "popen:issues:p1", "pdelete:issues:p1", "pname:issues:p1", "ptext:issues:p1", "pmodel:issues:p1", "pstatus:issues:p1", "pwhere:issues:p1", "psplit:issues:p1", "pnext:issues:p1" }, "an open prompt first in its kind takes over the kind's card: Done and Delete, then Move to status, Runs in and Opens in after the model, and its next action")
	eq(sectionIn(b, "popen:issues:p1").title, "Issue actions", "keeping the kind's title")
	local where = rowIn(b, "pwhere:issues:p1")
	eq(where.label, "Runs in", "label")
	eq(where.control.k, "choice", "a choice")
	eq(where.control.style, "segmented", "of segments")
	eq(where.control.value, "worktree", "on the worktree for a prompt that runs in one")
	same(where.control.options, { { value = "worktree", label = "Worktree" }, { value = "checkout", label = "Main checkout" } }, "the two places")
	expand(b, "popen:issues:p2")
	eq(rowIn(b, "pwhere:issues:p2").control.value, "checkout", "the main checkout for one that runs there")
	expand(b, "popen:issues:p3")
	eq(rowIn(b, "pwhere:issues:p3").control.value, "worktree", "and the worktree for one saved without the field")
	expand(b, "popen:issues:p1")
	local function choose(id: string, value: string)
		b.event({ ev = "change", id = "layer.settings", item = "pwhere:issues:" .. id, value = value })
	end
	choose("p1", "checkout")
	eq(w.kv.get("prompts-issues").items[1].worktree, false, "choosing the main checkout saves worktree = false")
	eq(rowIn(b, "pwhere:issues:p1").control.value, "checkout", "the row shows it")
	eq(menu()[1].worktree, false, "and the menu says so")
	b.event({ ev = "select", id = "layer.settings", item = "pwhere:issues:p1" })
	b.press("enter")
	eq(w.kv.get("prompts-issues").items[1].worktree, true, "Enter on the segments switches to the next one at once and saves it")
	eq(prefsOf(b).editing, nil, "without opening a menu")
	b.press("enter")
	eq(w.kv.get("prompts-issues").items[1].worktree, false, "and on again wraps round to the first")
	eq(menu()[1].worktree, false, "and the menu says so")
	choose("p2", "worktree")
	eq(w.kv.get("prompts-issues").items[2].worktree, true, "the worktree again")
	eq(w.kv.get("prompts-issues").items[1].name, "Triage", "the rest of the prompt is kept")
	eq(w.kv.get("prompts-prs").items[1].worktree, nil, "the PR prompts are untouched")
	b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:issues" })
	local saved = w.kv.get("prompts-issues")
	eq(#saved.items, 4, "Add prompt on the issue side saves a new one with the issue prompts")
	eq(saved.items[4].worktree, true, "that runs in a worktree")
	eq(#w.kv.get("prompts-prs").items, 1, "and none with the PR prompts")
	b.press("escape")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "psplit:prs:p1").control.value, "tab", "a PR prompt on the same page opens in a tab of its own until told otherwise")
	b.event({ ev = "change", id = "layer.settings", item = "psplit:prs:p1", value = "split" })
	eq(w.kv.get("prompts-prs").items[1].split, true, "the Beside the queue segment saves split")
	eq(rowIn(b, "psplit:prs:p1").control.value, "split", "the row shows it")
	b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:prs" })
	eq(#w.kv.get("prompts-prs").items, 2, "Add prompt on the pull request side saves one with the PR prompts")
	eq(#w.kv.get("prompts-issues").items, 4, "and none with the issue prompts")
	b.press("escape")
	b.press("escape")
	b.typeText("?")
	local keyed = false
	for _, row in helpRows(b.view().layer) do
		keyed = keyed or row.text == "Run the action “Triage” on the selected issue"
	end
	yes(keyed, "a prompt's shortcut is listed for the selected issue")
	b.press("escape")
	pickScope(b, "prs:v1")
	w.flush()
	eq(menu()[1].split, true, "the pull request filter's menu says the prompt opens beside the queue")
end)

case("host: the issue's buttons, keys and links: Worktree, Go to tab and Agent, each opening the link the card keeps unseen beside each prompt's", function(w: World)
	leaveIssueWt(w, issueHost(w), 12)
	saveIssuePrompts(w, {
		issuePrompt("p1", "Triage", "Triage {url}", true, "t"),
		issuePrompt("p2", "Notes", "Notes on {title}", false),
		issuePrompt("p3", "Blank", "", true, "b"),
	})
	local b = openIssues(w)
	local function bar(): { string }
		local out: { string } = {}
		for _, a in pickerOf(b).actions do
			table.insert(out, a.id)
		end
		return out
	end
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "Worktree, Agent, no button per prompt, Seen, and the command palette last")
	eq(buttonLink(b, "open"), "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12", "Open's link carries the issue's page, percent-encoded")
	local globe: any = findKey(findKey(pickerNode(b), "head"), "open", "icon")
	eq(globe.p.href, buttonLink(b, "open"), "the preview head's Open icon opens it")
	eq(globe.p.title, "Open in GitHub", "named for the issue's tracker")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "Worktree's")
	eq(buttonLink(b, "agent"), issueLink("agent", "o/r", "12"), "the Agent link for the a key and the palette command")
	eq(buttonLink(b, "prompt-p1"), issueRunLink("o/r", "12", "p1"), "each prompt's unseen link runs it on the selected issue")
	eq(buttonLink(b, "prompt-p3"), nil, "none for a prompt with no text")
	eq(buttonLink(b, "goto"), nil, "no tab works in its worktree: no Go to tab")
	eq(b.press("g", nil, "g"), false, "and g does nothing")
	b.event({ ev = "action", id = "layer.queue", act = "worktree" })
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "a click opens the button's link")
	b.event({ ev = "action", id = "layer.queue", act = "agent" })
	eq(w.opened[#w.opened], issueLink("agent", "o/r", "12"), "Agent's too")
	b.typeText("w")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "w opens the Worktree link")
	b.typeText("a")
	eq(w.opened[#w.opened], issueLink("agent", "o/r", "12"), "a the Agent link")
	b.typeText("t")
	eq(w.opened[#w.opened], issueRunLink("o/r", "12", "p1"), "a prompt's key its run link")
	b.press("enter")
	eq(w.opened[#w.opened], "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12", "Enter the Open link")
	b.typeText("j")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "13"), "the links follow the selection")
	b.typeText("k")
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-12/src" })
	b.render()
	same(bar(), { "settings", "retry", "worktree", "goto", "agent", "seen", "more" }, "a tab in the issue's worktree adds Go to tab before Agent")
	eq(buttonLink(b, "goto"), issueLink("goto", "o/r", "12"), "with its link")
	b.typeText("g")
	eq(w.opened[#w.opened], issueLink("goto", "o/r", "12"), "g opens it")
	table.remove(w.panes)
	forgetCheckouts(w)
	b.render()
	same(bar(), { "settings", "retry", "worktree", "agent", "seen", "more" }, "without a saved checkout the buttons stay: the window asks for one when it runs")
	lacks(b.text(), "No local checkout", "and the heading says nothing of it")
	local opened = #w.opened
	b.typeText("w")
	eq(w.opened[#w.opened], issueLink("worktree", "o/r", "12"), "w opens the Worktree link")
	eq(#w.opened, opened + 1, "and only that one")
end)

case("host: an account's Add makes a view of the kind on screen, saved with that kind's views; Jira's Add always makes an issue view", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat" -- a view with its own login runs as it, by token
	local b = openIssues(w)
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(#w.kv.get("views-issues").items, 5, "Add saved an issue view with the issue views")
	eq(#w.kv.get("views-prs").items, 2, "and none with the pull request views")
	eq(prefsOf(b).editing.row, "name:issues:v5", "and starts naming it")
	b.press("escape")
	b.press("escape")
	w.flush()
	eq(pickerOf(b).scope, "issues:v5", "the new view is the one shown")
	pickScope(b, "prs:v1")
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "on a pull request view the same Add saved a pull request view with the pull request views")
	eq(#w.kv.get("views-issues").items, 5, "and the issue views are as they were")
	eq(prefsOf(b).editing.row, "name:prs:v3", "naming it")
	b.press("escape")
	b.press("escape")
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:jira:" })
	b.press("enter")
	eq(#w.kv.get("views-prs").items, 3, "Jira has no pull requests")
	eq(w.kv.get("views-issues").items[6].integration, "jira", "so its Add made an issue view")
	b.press("escape")
	b.press("escape")
	goToSettings(b, "views")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:nowhere:" })
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:github:bad name" })
	same({ #w.kv.get("views-prs").items, #w.kv.get("views-issues").items }, { 3, 6 }, "a malformed Add value (an unknown integration, a login that is none) saves nothing")
end)

case("host: an Enterprise Managed User account (a login with an underscore) can have a view added, saved and shown", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "mona-cat_octo"
	s.gh.tokens["mona-cat_octo"] = "tok-emu"
	local b = openIssues(w)
	goToSettings(b, "views")
	yes(rowIn(b, "vadd:github:mona-cat_octo") ~= nil, "the account has its group and Add")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:github:mona-cat_octo" })
	local made = w.kv.get("views-issues").items[#w.kv.get("views-issues").items]
	same(made.logins, { "mona-cat_octo" }, "the view is saved as that account")
	b.press("escape")
	b.press("escape")
	w.flush()
	eq(pickerOf(b).scope, "issues:v" .. (#w.kv.get("views-issues").items), "and is the one shown")
end)

case("host: deleting a view takes only its own kind's view of that id, and the block moves on to the view now at its place in the list", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	b.event({ ev = "select", id = "layer.settings", item = "delete:issues:v1" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "delete:issues:v1" })
	w.flush()
	local gone: { string } = {}
	for _, v in w.kv.get("views-issues").items do
		table.insert(gone, v.id)
	end
	same(gone, { "v2", "v3", "v4" }, "the issue view is gone")
	eq(#w.kv.get("views-prs").items, 2, "the pull request view of the same id is not")
	eq(pickerOf(b).scope, "issues:v2", "the view now at its place in the list is shown")
	eq(b.saved().activeViewId, "v2", "and saved")
	eq(prefsOf(b).focus, "vopen:issues:v2", "and Settings focuses its summary row")
end)

case("host: a view's Type row moves it to the other kind's store under a new id with no prompts, and the shown view follows it", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open label:x", logins = array({ "work" }), group = "repo", prompts = array({ "p1" }) },
		{ id = "v2", name = "Other", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	eq(rowIn(b, "vint:prs:v1"), nil, "a view has no integration to pick")
	eq(rowIn(b, "vkind:prs:v1").control.value, "prs", "its Type row shows its kind")
	eq(rowIn(b, "vkind:prs:v1").label, "Type", "labelled Type")
	same(rowIn(b, "vkind:prs:v1").control.options, { { value = "prs", label = "Pull requests" }, { value = "issues", label = "Issues" } }, "and offers both kinds by name")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:prs:v1", value = "issues" })
	local prs = w.kv.get("views-prs")
	eq(#prs.items, 1, "the pull request store lost it")
	eq(prs.nextId, 3, "and keeps its next id")
	eq(prs.items[1].id, "v2", "and the other view stays")
	local issues = w.kv.get("views-issues")
	same({ #issues.items, issues.nextId }, { 5, 6 }, "the issue store took it as its next view")
	same(issues.items[5], { id = "v5", name = "Mine", integration = "github", query = "is:open label:x", logins = { "work" }, group = "repo", prompts = array({}) }, "keeping its query, login and the grouping both kinds have, with none of the pull request prompts")
	eq(pickerOf(b).scope, "issues:v5", "the view that was shown is still the one shown, under its new id")
	eq(prefsOf(b).focus, "vkind:issues:v5", "its Type row keeps the focus")
	yes(rowIn(b, "name:issues:v5") ~= nil, "and its form stays open")
	eq(b.saved().activeKind, "issues", "the block saves the new kind")
	eq(b.saved().activeViewId, "v5", "and the new id")
	b.event({ ev = "change", id = "layer.settings", item = "vgroup:issues:v5", value = "assignee" })
	b.event({ ev = "change", id = "layer.settings", item = "vkind:issues:v5", value = "prs" })
	same(w.kv.get("views-prs").items[2], { id = "v3", name = "Mine", integration = "github", query = "is:open label:x", logins = { "work" }, group = "none", prompts = array({}) }, "moved back, a grouping only issues have starts over")
	eq(#w.kv.get("views-issues").items, 4, "the issue store lost it")
	eq(pickerOf(b).scope, "prs:v3", "and the block shows it as a pull request view")
	-- a Jira view has no pull request kind to move to
	expand(b, "vopen:issues:v3")
	eq(rowIn(b, "vkind:issues:v3"), nil, "a Jira view's form has no Type row")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:issues:v3", value = "prs" })
	eq(#w.kv.get("views-issues").items, 4, "an event for it moves nothing")
	eq(#w.kv.get("views-prs").items, 2, "and adds nothing to the pull request views")
end)

case("host: a views store that cannot be read locks its own kind's views, says which kind it is, and leaves the other kind editable", function(w: World)
	issueHost(w)
	newAcli(w)
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", query = "is:open", group = "none", prompts = array({}) } }) })
	local before = w.kv.store["views-prs"]
	w.kv.failGet["views-prs"] = "disk offline"
	local b = openIssues(w)
	has(b.text(), "Saved pull request views could not be read: disk offline", "the block says which kind of views could not be read")
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	eq(rowIn(b, "name:issues:v1").disabled, nil, "the issue views stay editable")
	eq(rowIn(b, "vadd:github:octocat").disabled, nil, "and Add makes an issue view")
	b.press("enter")
	b.typeText("!")
	b.press("enter")
	eq(w.kv.get("views-issues").items[1].name, "Assigned to me!", "a rename of an issue view is saved")
	expand(b, "vopen:prs:v1")
	has(rowIn(b, "name:prs:v1").disabled, "disk offline", "the pull request views' rows are locked, with the cause")
	eq(w.kv.store["views-prs"], before, "and the unreadable store was not overwritten")
	b.press("escape")
	pickScope(b, "prs:v1")
	w.flush()
	goToSettings(b, "views")
	has(rowIn(b, "vadd:github:octocat").disabled, "disk offline", "on a pull request filter Add is locked, as its kind's views are")
end)

case("host: a click on another row first ends the line being typed, so a new view's Group by menu opens at once", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat"
	local b = openQueue(w)
	goToSettings(b, "views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(prefsOf(b).editing.row, "name:prs:v3", "a new view starts with its name being typed")
	b.event({ ev = "activate", id = "layer.settings", item = "vgroup:prs:v3" })
	eq(prefsOf(b).editing.row, "vgroup:prs:v3", "a click on Group by opens its menu over the untouched name")
	eq(w.kv.get("views-prs").items[3].name, "New view", "which is dropped, not saved empty")
	b.press("escape")
	b.event({ ev = "activate", id = "layer.settings", item = "name:prs:v3" })
	b.typeText("2")
	b.event({ ev = "activate", id = "layer.settings", item = "name:prs:v3" })
	eq(prefsOf(b).editing.draft, "New view2", "a click inside the field being typed keeps the draft")
	b.event({ ev = "activate", id = "layer.settings", item = "vgroup:prs:v3" })
	eq(w.kv.get("views-prs").items[3].name, "New view2", "a click on another row saves the typed name")
	eq(prefsOf(b).editing.row, "vgroup:prs:v3", "and does what it does")
	b.press("escape")
	b.event({ ev = "activate", id = "layer.settings", item = "name:prs:v3" })
	b.typeText("3")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "vopen:prs:v3" })
	eq(w.kv.get("views-prs").items[3].name, "New view23", "Done saves it too")
	eq(rowIn(b, "name:prs:v3"), nil, "and closes the form")
end)

case("host: a collapsed view is one summary row; Edit expands its form, another's Edit collapses the first, and Done collapses", function(w: World)
	hostScene(w, 3)
	newAcli(w)
	local b = openQueue(w)
	goToSettings(b, "views")
	local function sectionOf(id: string): any
		return sectionIn(b, id)
	end
	local summary = rowIn(b, "vopen:prs:v1")
	eq(summary.label, "My PRs · active", "the summary names the view and marks the active one")
	has(summary.hint, "is:open author:@me", "its hint shows the query")
	lacks(summary.hint, "GitHub", "and no longer names the integration")
	eq(summary.control.act, "expand", "its button expands the form")
	eq(summary.control.label, "Edit", "labelled Edit")
	eq(sectionOf("vopen:prs:v1").id, "group:github - octocat", "the first view of a group opens the group's section, named by the lowercased label")
	eq(sectionOf("vopen:prs:v1").title, "GitHub - octocat", "titled with the group")
	eq(rowIn(b, "name:prs:v1"), nil, "a collapsed view shows no form row")
	eq(rowIn(b, "query:prs:v1"), nil, "not the query")
	eq(rowIn(b, "delete:prs:v1"), nil, "nor Delete")
	expand(b, "vopen:prs:v1")
	local open = rowIn(b, "vopen:prs:v1")
	eq(open.control.act, "collapse", "an expanded view keeps its row, now collapsing")
	eq(open.control.label, "Done", "labelled Done")
	eq(open.hint, nil, "with no hint")
	local form: { string } = {}
	for _, r in sectionOf("vopen:prs:v1").rows do
		table.insert(form, r.id)
	end
	same(form, { "vopen:prs:v1", "delete:prs:v1", "name:prs:v1", "vkind:prs:v1", "query:prs:v1", "vgroup:prs:v1", "vsort:prs:v1", "vprompts:prs:v1" }, "Done on top, then Delete, which the sheet draws beside Done")
	eq(sectionOf("vopen:prs:v1").id, "form:prs:v1", "the group's first view, open, takes over the group's card")
	eq(sectionOf("vopen:prs:v1").title, "GitHub - octocat", "title and all")
	eq(sectionOf("vopen:prs:v2").id, "after:prs:v1", "the group's later views go on in a section after the form")
	eq(prefsOf(b).focus, "name:prs:v1", "with the name focused")
	expand(b, "vopen:prs:v2")
	eq(rowIn(b, "vopen:prs:v1").control.act, "expand", "expanding another view collapses the first")
	eq(rowIn(b, "name:prs:v1"), nil, "its form is gone")
	yes(rowIn(b, "name:prs:v2") ~= nil, "and the other's form shows")
	eq(sectionOf("vopen:prs:v2").id, "form:prs:v2", "in a section of its own when it is not the group's first")
	eq(sectionOf("vopen:prs:v2").rows[1].id, "vopen:prs:v2", "Done first")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "vopen:prs:v2" })
	yes(rowIn(b, "vopen:prs:v2").control.act == "expand" and rowIn(b, "name:prs:v2") == nil, "Done collapses it")
	eq(prefsOf(b).focus, "vopen:prs:v2", "and focuses its summary")
	w.kv.put("prompts-prs", { version = 1, nextId = 3, items = array({ promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") }) })
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({ { id = "v1", name = "Mine", integration = "github", logins = array({ "work" }), query = "is:open", group = "repo", prompts = array({ "p2" }) } }) })
	local other = openQueue(w, 2)
	goToSettings(other, "views")
	local hint = rowIn(other, "vopen:prs:v1").hint
	lacks(hint, "work", "a login is not in the summary")
	eq(sectionIn(other, "vopen:prs:v1").title, "GitHub - work", "the login is in the group's title")
	eq(hint, "Pull requests · is:open", "the summary is the kind and the query: no grouping, no prompt count")
end)

return {}
