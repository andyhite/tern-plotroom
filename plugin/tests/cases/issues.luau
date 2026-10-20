--!strict
-- Regression cases: the host's Jira and issue previews and worktrees, issue prompts, Settings formats, and the issue-worktree window flows.

local h = require("../harness")

type AcliReq = h.AcliReq
type Block = h.Block
type Call = h.Call
type GhReq = h.GhReq
type JiraScene = h.JiraScene
type Reply = h.Reply
type Worktree = h.Worktree
type World = h.World

local EPOCH, JIRA_ASSIGNED, NULL, actionOf, agentScene, answerOf = h.EPOCH, h.JIRA_ASSIGNED, h.NULL, h.actionOf, h.agentScene, h.answerOf
local array, asks, badgeOf, buttonLink, cardOf, cardSurface = h.array, h.asks, h.badgeOf, h.buttonLink, h.cardOf, h.cardSurface
local cardText, case, chipsOf, countCalls, countLog, detailText = h.cardText, h.case, h.chipsOf, h.countCalls, h.countLog, h.detailText
local editorCard, eq, expand, factOf, findKey, freshAsk = h.editorCard, h.eq, h.expand, h.factOf, h.findKey, h.freshAsk
local goToSettings, has, helpRows, hostScene, hx, issueHost = h.goToSettings, h.has, h.helpRows, h.hostScene, h.hx, h.issueHost
local issueItem, issueLink, issuePrompt, issueRunLink, issueWindow, jiraHost = h.issueItem, h.issueLink, h.issuePrompt, h.issueRunLink, h.issueWindow, h.jiraHost
local jiraItem, jsonEncode, lacks, leaveIssueWt, leaveWt, linkQueue = h.jiraItem, h.jsonEncode, h.lacks, h.leaveIssueWt, h.leaveWt, h.linkQueue
local listed, logFrom, loginsSavedBy, manyItems, newAcli, newGit = h.listed, h.logFrom, h.loginsSavedBy, h.manyItems, h.newAcli, h.newGit
local nodes, openIssues, openQueue, pickScope, pickerNode, pickerOf = h.nodes, h.openIssues, h.openQueue, h.pickScope, h.pickerNode, h.pickerOf
local prLink, prefsOf, pressCard, promptOf, promptPicks, ranSince = h.prLink, h.prefsOf, h.pressCard, h.promptOf, h.promptPicks, h.ranSince
local refreshNow, request, requestsOf, requestsSent, rowIn, runLink = h.refreshNow, h.request, h.requestsOf, h.requestsSent, h.rowIn, h.runLink
local same, saveIssuePrompts, savePrompts, scene, searchItem, sectionIn = h.same, h.saveIssuePrompts, h.savePrompts, h.scene, h.searchItem, h.sectionIn
local sha, show, showPr, snapshot, windowCase, yes = h.sha, h.show, h.showPr, h.snapshot, h.windowCase, h.yes
local acliCount = h.acliCount

case("host: a collapsed prompt is one summary row; Edit expands it, another's Edit or Done collapses, and Add opens the new prompt expanded", function(w: World)
	hostScene(w, 3)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}", "r"), promptOf("p2", "Triage", "Triage {url}") })
	local b = openQueue(w)
	goToSettings(b, "prompts")
	local function sectionOf(id: string): any
		return sectionIn(b, id)
	end
	local summary = rowIn(b, "popen:prs:p1")
	eq(summary.label, "Review", "the summary names the prompt")
	eq(summary.hint, "Review {url}", "its hint shows the text, not the key: shortcuts are the Keys page's")
	eq(summary.control.act, "expand", "its button expands the form")
	eq(summary.control.label, "Edit", "labelled Edit")
	eq(sectionOf("popen:prs:p1").id, "prompts:prs", "the prompts of a kind share its section")
	eq(rowIn(b, "pname:prs:p1"), nil, "a collapsed prompt shows no form row")
	eq(rowIn(b, "pdelete:prs:p1"), nil, "nor Delete")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "popen:prs:p1").control.act, "collapse", "an expanded prompt keeps its row, now collapsing")
	eq(rowIn(b, "popen:prs:p1").control.label, "Done", "labelled Done")
	eq(sectionOf("popen:prs:p1").rows[1].id, "popen:prs:p1", "first in its form")
	yes(rowIn(b, "pname:prs:p1") ~= nil and rowIn(b, "ptext:prs:p1") ~= nil and rowIn(b, "pmodel:prs:p1") ~= nil, "its form shows")
	eq(rowIn(b, "pkey:prs:p1"), nil, "with no shortcut row")
	expand(b, "popen:prs:p2")
	yes(rowIn(b, "popen:prs:p1").control.act == "expand" and rowIn(b, "pname:prs:p1") == nil, "expanding another prompt collapses the first")
	yes(rowIn(b, "pname:prs:p2") ~= nil, "and shows the other's form")
	eq(sectionOf("popen:prs:p2").id, "form:prs:p2", "in a section of its own when it is not the kind's first")
	eq(sectionOf("padd:prs").id, "add:prs", "and the Add button follows the list in its own")
	b.event({ ev = "action", id = "layer.settings", act = "collapse", value = "popen:prs:p2" })
	yes(rowIn(b, "popen:prs:p2").control.act == "expand" and rowIn(b, "pname:prs:p2") == nil, "Done collapses it")
	eq(prefsOf(b).focus, "popen:prs:p2", "and focuses its summary")
	expand(b, "popen:prs:p1")
	b.event({ ev = "select", id = "layer.settings", item = "padd:prs" })
	b.press("enter")
	eq(#w.kv.get("prompts-prs").items, 3, "Add saved a prompt")
	yes(rowIn(b, "pname:prs:p3") ~= nil, "the new prompt opens expanded")
	yes(rowIn(b, "popen:prs:p1").control.act == "expand" and rowIn(b, "pname:prs:p1") == nil, "and the one that was open collapses")
	eq(prefsOf(b).editing.row, "pname:prs:p3", "with its name being edited")
end)

case("host: pull request and issue filters sit together in the group of the login they run as, and one without a login follows gh's active login", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "user-a"
	s.gh.tokens["user-a"] = "tok-a"
	s.gh.tokens["user-b"] = "tok-b"
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "PR of A", integration = "github", query = "is:open", logins = array({ "user-a" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "PR plain", integration = "github", query = "is:open", group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 5, items = array({
		{ id = "v1", name = "A's", integration = "github", query = "is:open", logins = array({ "user-a" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "B's", integration = "github", query = "is:open", logins = array({ "user-b" }), group = "none", prompts = array({}) },
		{ id = "v3", name = "Plain", integration = "github", query = "is:open", group = "none", prompts = array({}) },
		{ id = "v4", name = "Jira view", integration = "jira", query = "assignee = currentUser()", group = "none", prompts = array({}) },
	}) })
	local b = openIssues(w)
	-- The sidebar as "name @ group", in the order shown.
	local function sidebar(): { string }
		local out: { string } = {}
		for _, scope in pickerOf(b).scopes do
			if scope.id ~= "worktrees" and scope.id ~= "agents" and scope.id ~= "inbox" then
				table.insert(out, scope.label .. " @ " .. scope.group)
			end
		end
		return out
	end
	same(sidebar(), {
		"PR of A @ GitHub - user-a",
		"PR plain @ GitHub - user-a",
		"A's @ GitHub - user-a",
		"Plain @ GitHub - user-a",
		"B's @ GitHub - user-b",
		"Jira view @ Jira",
	}, "a group is an integration's and a login's, whatever the kind: pull request filters first, then issue filters; one with no login sits with the active login's own; user-b has its own group, and Jira follows")
	s.gh.active = "user-b"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	b.typeText("r")
	w.flush()
	same(sidebar(), {
		"PR of A @ GitHub - user-a",
		"A's @ GitHub - user-a",
		"PR plain @ GitHub - user-b",
		"B's @ GitHub - user-b",
		"Plain @ GitHub - user-b",
		"Jira view @ Jira",
	}, "after the active account switched, the filters with no login moved to user-b's group, after user-b's own")
end)

-- A PR view that runs as the logins `who`, saved as the only filter of the block: the issue store is left empty.
local function loginsView(w: World, who: { string })
	w.kv.put("views-issues", { version = 1, nextId = 1, items = array({}) })
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open author:@me", logins = array(who), group = "none", prompts = array({}) },
	}) })
end

-- The sidebar as "name @ group = id", in the order shown.
local function sidebarOf(b: Block): { string }
	local out: { string } = {}
	for _, scope in pickerOf(b).scopes do
		if scope.id ~= "worktrees" and scope.id ~= "agents" and scope.id ~= "inbox" then
			table.insert(out, scope.label .. " @ " .. (scope.group or "-") .. " = " .. scope.id)
		end
	end
	return out
end

case("host: a view of two logins is one scope in each login's group; each runs only as its login, and nothing is merged", function(w: World)
	local s = hostScene(w, 0)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60, { checks = "SUCCESS" }), searchItem(2, "o/r", EPOCH - 120) }
	s.gh.items.work = { searchItem(3, "o/r", EPOCH - 30, { checks = "SUCCESS" }) }
	s.gh.checks["o/r#1"] = nodes(1)
	s.gh.checks["o/r#3"] = nodes(1)
	s.git.served["refs/pull/3/head"] = sha("b")
	s.gh.meta["o/r#3"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	same(sidebarOf(b), { "Both @ GitHub - octocat = prs:v1@octocat", "Both @ GitHub - work = prs:v1@work" }, "the view is listed once in each login's group")
	eq(pickerOf(b).scope, "prs:v1@octocat", "the first login's scope is the one shown")
	local searches = requestsOf(s.gh, "search")
	eq(#searches, 1, "one search")
	eq(searches[1].login, "octocat", "as that login")
	has(searches[1].fields.q, "is:open author:@me", "with the view's query")
	same(listed(b), { "no_2fr_231", "no_2fr_232" }, "its PRs only")
	w.advance(300)
	eq(requestsOf(s.gh, "checks")[1].login, "octocat", "its checks load as it")
	pickScope(b, "prs:v1@work")
	w.flush()
	searches = requestsOf(s.gh, "search")
	eq(#searches, 2, "the other scope searches on its own")
	eq(searches[2].login, "work", "as its login")
	same(listed(b), { "no_2fr_233" }, "and lists only what that login found, never a merge")
	eq(pickerOf(b).scope, "prs:v1@work", "the scope is the one clicked")
	w.advance(300)
	eq(requestsOf(s.gh, "checks")[2].login, "work", "its checks load as it")
	request(b, "a1", { op = "worktree", repo = "o/r", number = 3 })
	w.flush()
	eq(requestsOf(s.gh, "pr")[1].login, "work", "and its worktree reads the PR as it")
	-- the keys walk the scopes in the order shown
	b.press("tab")
	b.press("up")
	eq(pickerOf(b).scope, "prs:v1@octocat", "Up moves to the scope above")
	w.flush()
	eq(requestsOf(s.gh, "search")[3].login, "octocat", "and runs as its login again")
	same(listed(b), { "no_2fr_231", "no_2fr_232" }, "with its own list")
	b.press("down")
	eq(pickerOf(b).scope, "prs:v1@work", "Down moves to the scope below")
end)

case("host: a login failing in one scope leaves the view's other scope alone", function(w: World)
	local s = hostScene(w, 3)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "search" and req.login == "work" then
			return { status = 1, stderr = "gh: Resource not accessible by integration (HTTP 403)\n" }
		end
		return nil
	end
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "the working login's scope lists its PRs")
	pickScope(b, "prs:v1@work")
	w.flush()
	eq(pickerOf(b).state, "error", "the failing login's scope shows the problem")
	eq(#listed(b), 0, "and no list")
	pickScope(b, "prs:v1@octocat")
	w.flush()
	eq(pickerOf(b).state, "ready", "the other scope is not an error card")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "and lists its PRs again")
	local who: { string } = {}
	for _, req in requestsOf(s.gh, "search") do
		table.insert(who, req.login or "")
	end
	same(who, { "octocat", "work", "octocat" }, "each scope searched as its own login, and the failure stopped nothing else")
end)

case("host: a view sits in the group of each login it lists, and one with none follows gh's active login", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "user-a"
	s.gh.tokens["user-a"] = "tok-a"
	s.gh.tokens["user-b"] = "tok-b"
	w.kv.put("views-issues", { version = 1, nextId = 4, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open", logins = array({ "user-a", "user-b" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "Just b", integration = "github", query = "is:open", logins = array({ "user-b" }), group = "none", prompts = array({}) },
		{ id = "v3", name = "Active", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-prs", { version = 1, nextId = 1, items = array({}) })
	local b = openIssues(w)
	same(sidebarOf(b), {
		"Both @ GitHub - user-a = issues:v1@user-a",
		"Active @ GitHub - user-a = issues:v3",
		"Both @ GitHub - user-b = issues:v1@user-b",
		"Just b @ GitHub - user-b = issues:v2",
	}, "Both is under each of its logins; the view with none is under the active account's group")
	goToSettings(b, "views")
	has(sectionIn(b, "vopen:issues:v1").title, "GitHub - user-a, user-b", "the section in Settings lists the logins together in its title")
	has(sectionIn(b, "vopen:issues:v3").title, "GitHub - user-a", "and a view with none names the active account")
	s.gh.active = "user-b"
	w.advance(11 * 60 * 1000) -- past the cached list of logins
	w.flush()
	b.typeText("r")
	w.flush()
	same(sidebarOf(b), {
		"Both @ GitHub - user-a = issues:v1@user-a",
		"Both @ GitHub - user-b = issues:v1@user-b",
		"Just b @ GitHub - user-b = issues:v2",
		"Active @ GitHub - user-b = issues:v3",
	}, "when the active account switches, the view with none follows it")
end)

case("host: each Views group of an available account or Jira ends in an Add button for a view of its own; a group that is not available has none", function(w: World)
	local s = issueHost(w)
	newAcli(w)
	s.gh.active = "user-a"
	s.gh.tokens["user-a"] = "tok-a"
	s.gh.tokens["user-b"] = "tok-b"
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}) },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Both", integration = "github", query = "is:open", logins = array({ "user-a", "user-b" }), group = "none", prompts = array({}) },
		{ id = "v2", name = "Sprint", integration = "jira", query = "sprint in openSprints()", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	local function ids(): { string }
		local out: { string } = {}
		for _, section in prefsOf(b).sections do
			for _, r in section.rows do
				table.insert(out, r.id)
			end
		end
		return out
	end
	same(ids(), { "vopen:prs:v1", "vadd:github:user-a", "vrestore:github:user-a", "vopen:issues:v1", "vadd:github:user-b", "vrestore:github:user-b", "vopen:issues:v2", "vadd:jira:", "vrestore:jira:" }, "user-a's group with the view that follows it, its Add and Restore defaults, the view of both logins in a group of its own with neither, user-b's group with only its buttons, Jira's group with its view and buttons; no status order row")
	eq(sectionIn(b, "vadd:github:user-a").id, "add:github:user-a", "the Add of a group with views closes it in a section of its own")
	eq(sectionIn(b, "vadd:github:user-a").title, nil, "with no title")
	eq(sectionIn(b, "vopen:issues:v1").id, "group:github - user-a, user-b", "the view of two logins sits in the group of both, named by its lowercased label")
	eq(sectionIn(b, "vadd:github:user-b").id, "add-to:github:user-b", "an account with no view is only its Add")
	eq(sectionIn(b, "vadd:github:user-b").title, "GitHub - user-b", "titled with the account's group")
	eq(sectionIn(b, "vadd:jira:").id, "add:jira:", "Jira's Add closes its group")
	eq(rowIn(b, "vadd:github:user-b").disabled, nil, "an Add is available while its views can be saved")
	eq(rowIn(b, "vadd:github:user-b").control.act, "add", "pressing it adds")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:github:user-b" })
	local made = w.kv.get("views-prs").items[2]
	eq(made.integration, "github", "user-b's Add makes a GitHub view")
	same(made.logins, { "user-b" }, "as user-b, though user-a is gh's active account")
	eq(made.query, "is:open involves:@me", "starting from the integration's query")
	eq(prefsOf(b).editing.row, "name:prs:v2", "a pull request view, the kind on screen, its form open on the name")
	yes(table.find(sidebarOf(b), "New view @ GitHub - user-b = prs:v2") ~= nil, "it sits in user-b's group in the sidebar")
	b.press("escape")
	b.press("escape")
	goToSettings(b, "views")
	eq(sectionIn(b, "vopen:prs:v2").id, "group:github - user-b", "user-b's group now lists it")
	eq(sectionIn(b, "vadd:github:user-b").id, "add:github:user-b", "and ends in its Add")
	b.event({ ev = "action", id = "layer.settings", act = "add", value = "vadd:jira:" })
	made = w.kv.get("views-issues").items[3]
	eq(made.integration, "jira", "Jira's Add makes a Jira view")
	eq(#made.logins, 0, "with no login")
	eq(made.query, "assignee = currentUser() AND statusCategory != Done", "and Jira's query")
	eq(#w.kv.get("views-prs").items, 2, "an issue view though a pull request view is shown: Jira has no pull requests")
end)

case("host: the Jira group of the Views page follows acli: with no Jira view it shows once acli answers, and not while acli cannot be started", function(w: World)
	hostScene(w, 3)
	local acli = newAcli(w)
	acli.override = function(_req: AcliReq): Reply?
		return { raise = "no such file or directory" }
	end
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	w.flush()
	eq(rowIn(b, "vadd:jira:"), nil, "acli cannot be started: no Jira group")
	yes(rowIn(b, "vadd:github:octocat") ~= nil, "while the signed-in account's group is there")
	acli.override = nil
	b.press("escape")
	refreshNow(w, b) -- Refresh asks again which CLIs start
	goToSettings(b, "views")
	w.flush()
	eq(sectionIn(b, "vadd:jira:").id, "add-to:jira:", "acli answers: Jira is a group with only its Add")
	eq(sectionIn(b, "vadd:jira:").title, "Jira", "titled Jira")
end)

case("host: a view's logins saved by another block: removing the shown scope's login moves to its first remaining login", function(w: World)
	local s = hostScene(w, 0)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60) }
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	pickScope(b, "prs:v1@work")
	w.flush()
	same(listed(b), { "no_2fr_237" }, "the work scope is shown")
	local c = openQueue(w, 2)
	goToSettings(c, "views")
	expand(c, "vopen:prs:v1")
	loginsSavedBy(w, c, { "octocat" }, "Mine")
	w.flush()
	same(sidebarOf(b), { "Mine @ - = prs:v1" }, "the view is one scope again, and the block's sidebar needs no groups")
	same(listed(b), { "no_2fr_231" }, "and shows the login that is left")
	local searches = requestsOf(s.gh, "search")
	eq(searches[#searches].login, "octocat", "searched as it")
	-- adding a login keeps the scope shown; emptying the list is gh's active account
	loginsSavedBy(w, c, { "octocat", "zed" }, "Mine again")
	eq(pickerOf(b).scope, "prs:v1@octocat", "a login added keeps the scope that was shown")
	eq(#requestsOf(s.gh, "search"), #searches, "and searches nothing more")
	loginsSavedBy(w, c, {}, "Mine once more")
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "with no login the view is one scope")
	eq(requestsOf(s.gh, "search")[#requestsOf(s.gh, "search")].login, "octocat", "run as gh's active account")
end)

case("host: the active login is saved with the block and restored; one the view no longer lists falls back to its first", function(w: World)
	local s = hostScene(w, 0)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60) }
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	loginsView(w, { "octocat", "work" })
	local b = openQueue(w)
	pickScope(b, "prs:v1@work")
	w.flush()
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the view is saved")
	eq(saved.activeLogin, "work", "and the login of its scope")
	local again = w.open(2, { "/work/r" }, saved)
	w.flush()
	eq(pickerOf(again).scope, "prs:v1@work", "a restored block shows the same scope")
	same(listed(again), { "no_2fr_237" }, "with that login's list")
	local searches = requestsOf(s.gh, "search")
	eq(searches[#searches].login, "work", "searched as it")
	local stale = { version = 2, launchCwd = "/work/r", activeViewId = "v1", activeLogin = "gone" }
	local third = w.open(3, { "/work/r" }, stale)
	w.flush()
	eq(pickerOf(third).scope, "prs:v1@octocat", "a saved login the view does not list falls back to its first")
	same(listed(third), { "no_2fr_231" }, "and shows that one's PRs")
	eq(third.saved().activeLogin, "octocat", "which is what is saved from then on")
end)

case("host: a view saved with one login loads as a list of one; a malformed list is not overwritten; repeats collapse on the next save", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.work = "tok-work"
	s.gh.items.work = { searchItem(7, "o/r", EPOCH - 30) }
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Old", integration = "github", query = "is:open", login = "work", group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_237" }, "the old login still decides who searches")
	eq(requestsOf(s.gh, "search")[1].login, "work", "as that login")
	goToSettings(b, "views")
	same(rowIn(b, "vopen:prs:v1").label, "Old · active", "the view")
	expand(b, "vopen:prs:v1")
	b.press("enter")
	b.typeText("!")
	b.press("enter")
	local saved = w.kv.get("views-prs").items[1]
	same(saved.logins, { "work" }, "the next save writes a list")
	eq(saved.login, nil, "and no longer the old field")
	-- repeats of another case collapse
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Dups", integration = "github", query = "is:open", logins = array({ "work", "Work" }), group = "none", prompts = array({}) },
	}) })
	local again = openQueue(w, 2)
	goToSettings(again, "views")
	expand(again, "vopen:prs:v1")
	again.press("enter")
	again.typeText("!")
	again.press("enter")
	same(w.kv.get("views-prs").items[1].logins, { "work" }, "the same login in another case is one once saved")
	-- a malformed list is refused whole
	local bad = { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Bad", integration = "github", query = "is:open", logins = array({ "no good" }), group = "none", prompts = array({}) },
	}) }
	w.kv.put("views-prs", bad)
	local third = openQueue(w, 3)
	has(third.text(), "malformed", "a login with a space makes the saved views malformed")
	same(w.kv.get("views-prs"), bad, "and they are not overwritten")
end)

case("host: a Jira filter lists its issues and saves its active view and kind", function(w: World)
	local s = jiraHost(w)
	local before = w.kv.get("views-issues")
	local b = openIssues(w)
	same(w.kv.get("views-issues"), before, "the saved Jira filters are read, never seeded over or rewritten")
	eq(#w.kv.get("views-prs").items, 4, "the PR filters, absent until now, are seeded beside them")
	-- How many searches acli was asked for.
	local function searched(): number
		local n = 0
		for _, req in s.acli.requests do
			if req.kind == "search" then
				n += 1
			end
		end
		return n
	end
	eq(searched(), 1, "one search covers the project's issues")
	for _, call in w.calls do
		-- whether gh starts, and the sidebar's group labels learn gh's active login; nothing else may ask gh
		if call.argv[2] ~= "--version" then
			eq(call.argv[1] == "gh" and call.argv[2] ~= "auth", false, "a Jira filter never searches through gh: " .. table.concat(call.argv, " "))
			eq(call.argv[1] == "gh" and call.argv[3] ~= "status", false, "nor reads a token: " .. table.concat(call.argv, " "))
		end
	end
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "listed in acli's order")
	eq(pickerOf(b).selected, "nabc_23ABC-12", "the first issue is selected")
	eq(pickerOf(b).state, "ready", "the list is ready")
	eq(b.title(), "Plotroom · Assigned to me (2) · 1 new", "the title names the filter and counts the issues and the new one")
	local jira: any = nil
	for _, scope in pickerOf(b).scopes do
		if scope.id == "issues:v1" then
			jira = scope
		end
	end
	eq(jira.label, "Assigned to me", "the sidebar lists the Jira view")
	eq(jira.group, "Jira", "under Jira's group")
	eq(actionOf(b, "repos"), nil, "the action bar has no repository button")
	b.typeText("q")
	eq(#w.opened, 0, "and q opens nothing")
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
	eq(row(1).id, "nabc_23ABC-12", "the id is n and the issue's key, escaped")
	eq(row(1).label, "Fix login", "the summary is the label")
	eq(detailText(row(1)), "ABC-12 · Ann Lee · Bug", "the key, the reporter and the type: no repository, no age (the search carries no dates), no assignee")
	eq(detailText(row(2)), "ABC-13 · Ann Lee · Task", "the same for an unassigned issue")
	eq(row(1).facts, nil, "the rows carry no facts column: no assignee, no comment count")
	eq(pickerOf(b).columns, nil, "and the picker has no columns")
	eq(badges(1), "In Progress/warning ui/-", "the workflow status toned by its category, then the labels; no integration badge")
	eq(badges(2), "Done/success", "a done issue says Done")
	eq(findKey(findKey(pickerNode(b), "head"), "open", "icon").p.title, "Open in Jira", "the preview head's Open icon names the tracker")
	b.typeText("?")
	local rows = helpRows(b.view().layer)
	yes(#rows > 0, "the shortcut list has rows")
	for _, r in rows do
		eq(r.keys == "p", false, "no shortcut for another project")
	end
	b.press("escape")
	local rerun = w.open(1, { "/work/r" })
	w.flush()
	same(listed(rerun), { "nabc_23ABC-12", "nabc_23ABC-13" }, "running init again for the live pane keeps its Jira list")
	eq(searched(), 1, "and does not search twice")
	local saved = b.saved()
	eq(saved.activeViewId, "v1", "the block saves its active view")
	eq(saved.activeKind, "issues", "and its kind: a PR filter may have the same id")
	local again = w.open(2, { "/work/r" }, saved)
	w.flush()
	eq(again.title(), "Plotroom · Assigned to me (2) · 1 new", "a restored block shows the same view")
end)

case("host: issues always list In Progress, then To Do, then Done, in acli's priority order within each; a saved status order and Settings change nothing", function(w: World)
	local s = jiraHost(w)
	local function status(name: string, category: string): any
		return { status = { name = name, statusCategory = { key = category } } }
	end
	s.acli.searches[JIRA_ASSIGNED] = {
		jiraItem("ABC-1", "Shipped", status("Done", "done")),
		jiraItem("ABC-2", "Next", status("Proposed", "new")),
		jiraItem("ABC-3", "Review", status("In Review", "indeterminate")),
		jiraItem("ABC-4", "Later", status("Proposed", "new")),
		jiraItem("ABC-5", "Coding", status("In Development", "indeterminate")),
	}
	local b = openIssues(w)
	same(listed(b), { "nabc_23ABC-3", "nabc_23ABC-5", "nabc_23ABC-2", "nabc_23ABC-4", "nabc_23ABC-1" }, "by status category, acli's order within one")
	local views: any = w.kv.get("views-issues")
	views.items[1].group = "status"
	w.kv.put("views-issues", views)
	local grouped = openIssues(w, 2)
	-- group headers by label, items by id
	local function shown(blk: Block): { string }
		local out: { string } = {}
		for _, id in pickerOf(blk).order do
			table.insert(out, if type(id) == "table" then id.label else id)
		end
		return out
	end
	same(shown(grouped), { "In Development", "nabc_23ABC-5", "In Review", "nabc_23ABC-3", "Proposed", "nabc_23ABC-2", "nabc_23ABC-4", "Done", "nabc_23ABC-1" }, "status groups go by category, then by name within one")
	goToSettings(b, "views")
	eq(rowIn(b, "sorder"), nil, "Settings has no status order row")
	local saved = array({ "done", "new", "indeterminate" })
	w.kv.put("status-order", saved)
	local later = openIssues(w, 3)
	same(shown(later), { "In Development", "nabc_23ABC-5", "In Review", "nabc_23ABC-3", "Proposed", "nabc_23ABC-2", "nabc_23ABC-4", "Done", "nabc_23ABC-1" }, "a saved status order is not read: a block opened after it sorts as before")
	same(listed(b), { "nabc_23ABC-3", "nabc_23ABC-5", "nabc_23ABC-2", "nabc_23ABC-4", "nabc_23ABC-1" }, "and the list of the block that was open stays the same")
	same(w.kv.get("status-order"), saved, "and it is left as it was")
end)

case("host: a priority sort on a grouped Jira view keeps status categories first, and two To Do statuses go by name", function(w: World)
	local s = jiraHost(w)
	local function item(key: string, status: string, category: string, priority: string): any
		return jiraItem(key, key, { status = { name = status, statusCategory = { key = category } }, priority = { name = priority } })
	end
	s.acli.searches[JIRA_ASSIGNED] = {
		item("ABC-1", "Done", "done", "Highest"),
		item("ABC-2", "Ready", "new", "Low"),
		item("ABC-3", "Backlog", "new", "High"),
		item("ABC-4", "Coding", "indeterminate", "Low"),
		item("ABC-5", "Ready", "new", "Highest"),
	}
	local views: any = w.kv.get("views-issues")
	views.items[1].sort = "priority"
	w.kv.put("views-issues", views)
	local b = openIssues(w)
	same(listed(b), { "nabc_23ABC-4", "nabc_23ABC-5", "nabc_23ABC-3", "nabc_23ABC-2", "nabc_23ABC-1" }, "category first, priority within it, Done last")
	views.items[1].group = "status"
	w.kv.put("views-issues", views)
	local out: { string } = {}
	for _, id in pickerOf(openIssues(w, 2)).order do
		table.insert(out, if type(id) == "table" then id.label else id)
	end
	same(out, { "Coding", "nabc_23ABC-4", "Backlog", "nabc_23ABC-3", "Ready", "nabc_23ABC-5", "nabc_23ABC-2", "Done", "nabc_23ABC-1" }, "groups by category then name, items by priority")
end)

case("host: a Jira view's Settings speak of JQL, the shared prompts, the repositories its issues are worked in and its branch format", function(w: World)
	local s = jiraHost(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Triage", "Triage {key} in {project}: {title}", true) })
	local b = openIssues(w)
	local function page(name: string)
		b.event({ ev = "action", id = "layer.settings", act = "page", value = name })
	end
	-- Types `text` over what text row `row` holds and saves it.
	local function save(row: string, text: string)
		b.event({ ev = "select", id = "layer.settings", item = row })
		b.press("enter")
		for _ = 1, 80 do
			b.press("backspace")
		end
		b.typeText(text)
		b.press("enter")
	end
	-- The JQL of acli's latest search.
	local function lastJql(): string
		local jql = ""
		for _, req in s.acli.requests do
			if req.kind == "search" then
				jql = req.argv[6]
			end
		end
		return jql
	end
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	eq(rowIn(b, "query:issues:v1").label, "JQL", "the query field is the JQL")
	eq(rowIn(b, "query:issues:v1").control.placeholder, "assignee = currentUser() AND statusCategory != Done", "and shows an example")
	save("query:issues:v1", "a = 1) OR (b = 2")
	eq(rowIn(b, "query:issues:v1").warning, "Unbalanced parentheses.", "a query that closes its own parenthesis is refused")
	eq(prefsOf(b).editing.row, "query:issues:v1", "the draft stays for a correction")
	b.press("escape")
	s.acli.searches['(summary ~ "login") ORDER BY priority DESC, updated DESC'] = { jiraItem("ABC-12", "Fix login") }
	save("query:issues:v1", 'summary ~ "login"')
	w.flush()
	eq(lastJql(), '(summary ~ "login") ORDER BY priority DESC, updated DESC', "a good query searches again, in parentheses, highest priority first")
	same(listed(b), { "nabc_23ABC-12" }, "and lists what it finds")
	page("prompts")
	expand(b, "popen:issues:p1")
	eq(rowIn(b, "pname:issues:p1").control.value, "Triage", "the prompts saved for issues are shared with GitHub's")
	b.event({ ev = "action", id = "layer.settings", act = "edit-prompt", value = "ptext:issues:p1" })
	local legend: { string } = {}
	for _, item in findKey(editorCard(b), "list", "kv").p.items do
		table.insert(legend, item.k[1].t)
	end
	same(legend, { "{url}", "{key}", "{title}", "{author}", "{labels}", "{branch}", "{base}", "{remote}", "{owner}", "{repo}", "{number}", "{project}", "{status}", "{type}", "{github.user}", "{jira.user}" }, "the variables of both trackers are listed, with the worktree's and the two users")
	b.press("escape")
	page("jira")
	eq(rowIn(b, "jopen:ABC").hint, "o/r", "the project's summary names its repositories")
	expand(b, "jopen:ABC")
	eq(prefsOf(b).focus, "jrepos:ABC", "and Edit opens them")
	eq(rowIn(b, "jrepos:ABC").control.values[1], "o/r", "the project's repository")
	same(rowIn(b, "jrepos:ABC").control.options, { { value = "o/r", label = "o/r" } }, "chosen among the saved repositories")
	page("repos")
	expand(b, "ropen:o/r")
	save("branch:o/r", "{project}/{key}")
	eq(w.kv.get("branch-formats")["o/r"], "{project}/{key}", "a good format is saved under the repository")
	has(b.text(), "ABC/ABC-12", "and the preview's branch follows")
	page("views")
	b.event({ ev = "select", id = "layer.settings", item = "vadd:github:octocat" })
	b.press("enter")
	eq(w.kv.get("views-issues").items[2].query, "is:open involves:@me", "a new view starts as the GitHub one")
end)

case("host: removing a repository drops it from jira-repos, branch-formats and setup-commands", function(w: World)
	issueHost(w)
	w.kv.put("checkouts", { ["x/y"] = "/work/y" })
	w.kv.put("branch-formats", { ["x/y"] = "keep/{key}", ["o/r"] = "{key}" })
	w.kv.put("setup-commands", { ["x/y"] = array({ "make" }), ["o/r"] = array({ "pnpm install" }) })
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }), DEF = array({ "x/y" }) })
	local b = openIssues(w)
	goToSettings(b, "repos")
	expand(b, "ropen:x/y")
	b.event({ ev = "select", id = "layer.settings", item = "rremove:x/y" })
	b.press("enter")
	b.event({ ev = "action", id = "layer.settings", act = "confirm-delete", value = "rremove:x/y" })
	eq(w.kv.get("checkouts")["x/y"], nil, "its checkout is forgotten")
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the other repository's stays")
	same(w.kv.get("branch-formats"), { ["o/r"] = "{key}" }, "so is its branch format")
	same(w.kv.get("setup-commands"), { ["o/r"] = { "pnpm install" } }, "and its setup commands")
	same(w.kv.get("jira-repos"), { ABC = { "o/r" }, DEF = array({}) }, "every Jira project drops it; one left with none stays listed")
	eq(rowIn(b, "ropen:x/y"), nil, "it is gone from the page")
	eq(prefsOf(b).focus, "radd", "and the Add button takes the focus")
end)

case("host: a Jira issue request makes its worktree in the project's mapped GitHub repository", function(w: World)
	local s = jiraHost(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	local b = openIssues(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	eq(badgeOf(b), nil, "no badge before there is a worktree")
	request(b, "j1", freshAsk("ABC", "ABC-12"))
	w.flush()
	local a = answerOf(b, "j1")
	eq(a.path, target, "the worktree is named after the repository and the issue's key")
	eq(a.created, true, "created")
	eq(a.summary, "Created · octocat/ABC-12-fix-login at bbbbbbb · Clean", "on a branch of the gh login, the key and the summary's slug, at the base chosen")
	eq(a.setup, "pnpm install", "the repository's saved setup commands run in a new worktree")
	same(a.vars, {
		url = "https://acme.atlassian.net/browse/ABC-12",
		key = "ABC-12",
		title = "Fix login",
		author = "Ann Lee",
		labels = "ui",
		owner = "o",
		repo = "r",
		project = "ABC",
		status = "In Progress",
		type = "Bug",
		["github.user"] = "octocat",
		["jira.user"] = "ann",
		branch = "octocat/ABC-12-fix-login",
		base = "main",
		remote = "origin",
	}, "the issue's Jira variables, with both users and the worktree's branch, base and remote")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base was fetched into its remote-tracking ref")
	eq(countLog(s.git, "worktree add -b octocat/ABC-12-fix-login " .. target .. " " .. sha("b")), 1, "and the worktree made once")
	eq(w.opened[#w.opened], "plotroom://rpc/j1", "the window is told to read the answer")
	eq(badgeOf(b).text, "Worktree", "a worktree puts a badge on the row")
	table.insert(w.panes, { pane = 9, cwd = target .. "/src" })
	b.render()
	local texts: { string } = {}
	for _, badge in pickerOf(b).items[1].badges do
		table.insert(texts, badge.text)
	end
	yes(table.find(texts, "In tab") ~= nil, "a tab in the worktree marks the issue: the directory keeps the key's case")
	local head: any = findKey(pickerNode(b), "head")
	yes(head ~= nil, "the preview has a head row")
	eq(findKey(head, "integration").p.text, "Jira", "naming the tracker")
	eq(findKey(head, "integration").p.tone, "accent", "accent for Jira")
	eq(findKey(findKey(pickerNode(b), "titlerow"), "integration"), nil, "and the title row no longer carries it")
	-- a format saved for the repository applies, with its {project}
	w.kv.put("branch-formats", { ["o/r"] = "{project}/{key}" })
	request(b, "j2", freshAsk("ABC", "ABC-13"))
	w.flush()
	eq(answerOf(b, "j2").vars.branch, "ABC/ABC-13", "the project's branch format names the branch")
	-- the main checkout
	request(b, "j3", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false })
	local main = answerOf(b, "j3")
	eq(main.path, "/work/r", "a prompt set to the main checkout runs in the repository's checkout")
	eq(main.vars.branch, nil, "with no branch: there is no worktree")
	eq(main.vars.project, "ABC", "but the project")
	-- what is not for this block is dropped
	local ran, told = #w.calls, #w.opened
	request(b, "g1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	request(b, "g2", { op = "issue", repo = "abc", ref = "ABC-12", worktree = false })
	request(b, "g3", { op = "issue", repo = "ABC", ref = "ABC 12", worktree = false })
	w.flush()
	eq(answerOf(b, "g1").problem, "That issue is not loaded here any more; Refresh and try again.", "a GitHub issue the Jira list never had is refused")
	eq(answerOf(b, "g2"), nil, "so is a project key that is not one")
	eq(answerOf(b, "g3"), nil, "and a reference that cannot name a directory")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.opened, told + 1, "and the window was told of that refusal only")
end)

case("host: an issue filter shows the card of an issue's worktree that git lists, with no pull request head to be at", function(w: World)
	local s = issueHost(w)
	local path = "/wt/plotroom-o_r-issue-12"
	table.insert(s.git.worktrees, { path = path, branch = "refs/heads/12-fix-login", head = sha("b"), locked = false })
	table.insert(s.git.worktrees, { path = "/wt/plotroom-o_r-pr-13", branch = "refs/heads/plotroom/o/r/pr-13", head = sha("b"), locked = false })
	w.fs.dirs[path] = true
	w.fs.dirs["/wt/plotroom-o_r-pr-13"] = true
	s.git.dirty[path] = " M src/a.lua\n"
	local b = openIssues(w)
	yes(badgeOf(b, 1) ~= nil, "the issue's row wears the badge")
	eq(badgeOf(b, 2), nil, "an issue with no worktree wears none, though a pull request of that number has one")
	same(chipsOf(b), { "Changes unchecked" }, "its card: only its changes, an issue has no head to be at")
	has(cardText(b), "12-fix-login", "its branch")
	has(cardText(b), path, "and where it is")
	eq(countLog(s.git, "config"), 0, "no remote is read: only a pull request's branch needs one")
	w.advance(300)
	same(chipsOf(b), { "Uncommitted changes" }, "its changes are read once the cursor has rested")
	eq(badgeOf(b).tone, "warning", "and the row follows")
	table.remove(s.git.worktrees, 2)
	w.fs.dirs[path] = nil
	table.remove(s.git.worktrees, 2)
	refreshNow(w, b)
	eq(cardOf(b), nil, "removed outside Plotroom, it leaves the next refresh")
end)

case("host: a Jira issue's worktree in a repository mapped to its project shows on its card, and a project with none mapped reads nothing", function(w: World)
	local s = jiraHost(w)
	local path = "/wt/plotroom-o_r-issue-ABC-12"
	table.insert(s.git.worktrees, { path = path, branch = "refs/heads/ABC-12-fix-login", head = sha("b"), locked = false })
	w.fs.dirs[path] = true
	local b = openIssues(w)
	yes(badgeOf(b, 1) ~= nil, "ABC-12's row wears the badge")
	eq(badgeOf(b, 2), nil, "ABC-13's does not")
	same(chipsOf(b), { "Changes unchecked" }, "its card")
	has(cardText(b), "ABC-12-fix-login", "names the branch")
	eq(countLog(s.git, "worktree list"), 1, "from one list of the repository the project is mapped to")
	w.kv.put("jira-repos", {})
	local unmapped = openIssues(w, 2)
	eq(cardOf(unmapped), nil, "a project mapped to no repository shows none")
	eq(countLog(s.git, "worktree list"), 1, "and looked in none")
end)

case("host: the Jira preview shows the union rows and Jira's own", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = {
		key = "ABC-12",
		fields = {
			description = { type = "doc", version = 1, content = { { type = "paragraph", content = { { type = "text", text = "Login fails." } } } } },
			parent = { key = "ABC-1", fields = { summary = "Auth epic" } },
			customfield_10020 = array({ { boardId = 3, state = "closed", name = "Sprint 1" }, { boardId = 3, state = "active", name = "Sprint 2" } }),
			fixVersions = array({ { name = "v2" } }),
			issuelinks = array({
				{ type = { inward = "is blocked by", outward = "blocks" }, outwardIssue = { key = "ABC-3", fields = { summary = "Login API", status = { statusCategory = { key = "new" } } } } },
				{ type = { inward = "relates to", outward = "relates to" }, inwardIssue = { key = "ABC-6", fields = { summary = "Old notes", status = { name = "Backlog", statusCategory = { key = "new" } } } } },
				{ type = { inward = "is blocked by", outward = "blocks" }, outwardIssue = { key = "ABC-5", fields = { summary = "Review copy", status = { name = "In Review", statusCategory = { key = "indeterminate" } } } } },
			}),
			subtasks = array({ { key = "ABC-14", fields = { summary = "Add test", status = { statusCategory = { key = "done" } } } } }),
			comment = { total = 2, comments = array({}) },
			created = "2026-10-12T08:00:00.000+0000",
			updated = "2026-10-12T11:30:00.000+0000",
		},
	}
	local b = openIssues(w)
	local function factKeys(): { string }
		local out: { string } = {}
		local facts: any = findKey(findKey(pickerNode(b), "about"), "facts", "kv")
		for _, item in facts.p.items do
			table.insert(out, item.k)
		end
		return out
	end
	same(factKeys(), { "Project", "Reporter", "Assignees", "Type", "Priority" }, "only the rows with a value; the details' rows wait for them")
	eq(factOf(b, "Reporter"), "Ann Lee", "the reporter is a name, not a login")
	eq(factOf(b, "Assignees"), "Bob Ray", "assignees")
	eq(factOf(b, "Type"), "Bug", "the type")
	eq(factOf(b, "Priority"), "High", "and the priority, which the search carries")
	has(b.text(), "Linked issues", "the linked items' heading shimmers meanwhile")
	has(b.text(), "Loading details…", "with the details loading")
	eq(acliCount(s.acli, "view"), 0, "the details wait for the cursor to rest")
	w.advance(300)
	eq(acliCount(s.acli, "view"), 1, "the details load once the cursor rests")
	eq(factOf(b, "Parent"), "ABC-1 Auth epic", "the parent")
	eq(factOf(b, "Sprint"), "Sprint 2", "the active sprint")
	eq(table.find(factKeys(), "Components"), nil, "no components row without components")
	eq(factOf(b, "Fix versions"), "v2", "the fix version")
	eq(factOf(b, "Comments"), "2", "the comment count")
	eq(factOf(b, "Opened"), "4h ago", "when it was opened")
	eq(factOf(b, "Updated"), "30m ago", "and last updated")
	local preview = pickerNode(b)
	local head = findKey(preview, "head")
	eq(findKey(head, "copy", "icon").p.href, "https://acme.atlassian.net/browse/ABC-12", "the head's copy icon takes the browse link")
	eq(findKey(head, "copy", "icon").p.aria, "Copy link to issue ABC-12", "which names the key")
	eq(findKey(head, "state", "badge").p.text, "In Progress", "the head's badge is the workflow status")
	eq(findKey(head, "state", "badge").p.tone, "warning", "toned by its category")
	eq(findKey(findKey(preview, "branch"), "v").p.spans[1].t, "octocat/ABC-12-fix-login", "the branch Worktree would make: the default format over gh's active login")
	eq(findKey(findKey(preview, "description", "card"), "body", "md").p.text, "Login fails.", "the description from Jira's document format, as Markdown")
	-- The linked section as lines: each relation's heading, then its rows.
	local function linked(): { string }
		local out: { string } = {}
		local g = 1
		while findKey(preview, "linked" .. g) do
			local h: any = findKey(preview, "linked-head" .. g)
			if h then
				table.insert(out, h.p.spans[1].t)
			end
			for _, item in (findKey(preview, "linked" .. g) :: any).c do
				table.insert(out, "  " .. item.p.label .. " | " .. item.p.value .. " | " .. item.p.icon .. " | " .. item.p.tone .. " | " .. item.p.title)
			end
			g += 1
		end
		return out
	end
	same(linked(), {
		"Blocks · 2",
		"  Login API | ABC-3 | list-checks | muted | ABC-3 · To Do",
		"  Review copy | ABC-5 | list-checks | warning | ABC-5 · In Review",
		"Relates to · 1",
		"  Old notes | ABC-6 | list-checks | muted | ABC-6 · Backlog",
		"Subtasks · 1",
		"  Add test | ABC-14 | check | success | ABC-14 · Done",
	}, "linked issues under one heading per relation, in the order Jira first names it; the icon and tone are the status category, the key at the right, the status in the tooltip")
	-- an issue whose details cannot be read says why
	b.event({ ev = "select", id = "layer.queue", item = "nabc_23ABC-13" })
	w.advance(300)
	has(b.text(), "Could not load the details: Issue does not exist or you do not have permission to see it.", "the reason is on screen")
	has(b.text(), "Retry", "with a Retry button")
	eq(factOf(b, "Comments"), nil, "and what only the details know stays hidden")
end)

case("host: the project pickers: Jira's list puts saved projects first with their repositories, and the repository lists are GitHub's", function(w: World)
	local s = jiraHost(w)
	local gh = s.gh
	gh.tokens.octocat = "tok-octo"
	gh.repos.octocat = { "o/r", "x/y" }
	s.acli.projects = {
		{ key = "ABC", name = "Alpha" },
		{ key = "LOW", name = "Lower" },
		{ key = "XYZ", name = "Xylo" },
		{ key = "lower", name = "Not a key" },
	}
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }), DEF = array({}), nope = array({ "o/r" }) })
	w.kv.put("checkouts", { ["o/r"] = "/work/o", ["x/y"] = "" })
	local b = openIssues(w)
	request(b, "p1", { op = "jira-projects" })
	w.flush()
	local answer = answerOf(b, "p1")
	local want: { any } = {
		{ key = "ABC", name = "Alpha", repos = "o/r, x/y", saved = true },
		{ key = "DEF", repos = "", saved = true },
		{ key = "LOW", name = "Lower", saved = false },
		{ key = "XYZ", name = "Xylo", saved = false },
	}
	same(answer.items, want, "saved projects by key with their repositories, then the rest of acli's list; a key that is none is left out")
	eq(answer.problem, nil, "nothing is wrong")
	eq(w.opened[#w.opened], "plotroom://rpc/p1", "and the window is told to read the answer")
	-- signed out: the saved projects, and why there are no more
	s.acli.site = nil
	request(b, "p2", { op = "jira-projects" })
	w.flush()
	local out = answerOf(b, "p2")
	local saved: { any } = {
		{ key = "ABC", repos = "o/r, x/y", saved = true },
		{ key = "DEF", repos = "", saved = true },
	}
	same(out.items, saved, "signed out, only the saved projects are listed")
	has(out.problem, "acli is not signed in to Jira", "and the problem says why")
	-- the repository picker lists the saved repositories with their checkouts, then the gh logins
	request(b, "r1", { op = "repos" })
	w.flush()
	local expectedRepos: { any } = { { repo = "o/r", path = "/work/o" }, { repo = "x/y" } }
	same(answerOf(b, "r1").items, expectedRepos, "the repository picker lists the saved repositories, a folder only where one is set")
	same(answerOf(b, "r1").accounts, { { login = "octocat", active = true } }, "and the gh logins")
	request(b, "r2", { op = "profile", login = "octocat" })
	w.flush()
	w.advance(5000)
	same(answerOf(b, "r2").repos, { "o/r", "x/y" }, "a login's list holds the repositories it can open")
	eq(answerOf(b, "r2").problem, nil, "with no problem")
end)

windowCase("window: Worktree on an issue opens a tab named \"#12 · r\" in plotroom-o_r-issue-12", function(w: World)
	local s, b = issueWindow(w)
	local target = "/wt/plotroom-o_r-issue-12"
	w.window.choose = "main"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(w.toasts[1].level, "info", "start")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "names the issue")
	eq(w.toasts[2].level, "success", "level")
	eq(w.toasts[2].text, "Worktree ready for o/r#12", "names the issue")
	eq(w.toasts[2].sub, "Created · octocat/12-fix-login at bbbbbbb · Clean", "a new worktree on the issue's branch, at the base picked")
	local sent = requestsSent(w)
	eq(#sent, 2, "the first request, which the host answers with the base branches to pick from, and the one that carries the pick")
	eq(sent[1].op, "issue", "the issue op")
	eq(sent[1].repo, "o/r", "of the repository")
	eq(sent[1].ref, "12", "and the issue")
	eq(sent[1].worktree, true, "in a worktree")
	eq(sent[1].fresh, nil, "with no decision yet")
	eq(sent[2].fresh, true, "the second asks for a new branch")
	eq(sent[2].base, "main", "from the base picked")
	eq(#w.window.picks, 1, "the base was asked once")
	eq(#w.window.launches, 1, "one tab")
	eq(w.window.launches[1].cwd, target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "#12 · r", "tab name")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("b"), "the branch starts at the base picked, named after the gh login")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "which was fetched once")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b octocat/12-fix-login " .. target .. " " .. sha("b")), 1, "and the worktree added through omp")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	has(cardText(b), target, "and the card says where the worktree is")
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(w.toasts[#w.toasts].level, "success", "the second click")
	has(w.toasts[#w.toasts].sub, "Reused", "reuses it")
	eq(countLog(s.git, "worktree add"), 1, "made once")
	eq(#w.window.launches, 2, "and opens its tab again")
end)

-- A window whose pane 1 is the Plotroom block of `jiraHost` on its Jira filter (project ABC), linked.
local function jiraWindow(w: World): (JiraScene, Block)
	local s, b = issueWindow(w, jiraHost)
	return s :: any, b
end

windowCase("window: the Jira project picker lists the saved projects and acli's; a typed key is added in Settings", function(w: World)
	local s, b = jiraWindow(w)
	s.acli.projects = { { key = "ABC", name = "Alpha" }, { key = "XYZ", name = "Xyz Project" } }
	w.window.choose = "Other project…"
	w.window.typed = "xyz"
	w.click("plotroom://jira-projects")
	w.flush()
	local items = w.window.picks[1].items
	eq(items[1].label, "ABC", "the saved project first")
	eq(items[1].group, "Saved", "in its group")
	eq(items[1].detail, "o/r", "with its repositories")
	eq(items[2].label, "XYZ", "then the one acli lists")
	eq(items[2].group, "Jira projects", "in its group")
	eq(items[2].detail, "Xyz Project", "with its name")
	eq(items[3].label, "Other project…", "then a typed one")
	same(w.kv.get("jira-repos").XYZ, array({}), "a typed key is saved upper-cased, with no repository yet")
	eq(prefsOf(b).page, "jira", "and Settings opens on the Jira page")
	eq(prefsOf(b).focus, "jrepos:XYZ", "at its repositories")
end)

windowCase("window: Worktree on a Jira issue opens a tab named \"ABC-12\"", function(w: World)
	local s, b = jiraWindow(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	w.window.choose = "main"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(w.toasts[1].text, "Preparing worktree for ABC-12", "names the issue by its key")
	eq(w.toasts[2].level, "success", "level")
	eq(w.toasts[2].sub, "Created · octocat/ABC-12-fix-login at bbbbbbb · Clean", "a new worktree on the issue's branch")
	eq(requestsSent(w)[1].repo, "ABC", "the request names the project")
	eq(w.window.launches[1].cwd, target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "ABC-12", "tab name")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base is fetched into its remote-tracking ref")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
end)

windowCase("window: Jira issue picks its repository: asked when none is mapped, among several, never with one", function(w: World)
	local _, b = jiraWindow(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	-- none mapped: the pick maps the project, then the worktree is made there
	w.kv.put("jira-repos", {})
	w.window.choose = { "o/r", "main" }
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	local picks = w.window.picks
	eq(#picks, 2, "two questions: the repository, then the base branch")
	eq(picks[1].placeholder, "Repository for Jira project ABC…", "it names the project")
	eq(picks[1].items[1].label, "o/r", "offering the saved repositories")
	eq(picks[1].items[#picks[1].items].label, "Other repository…", "and a typed one")
	same(w.kv.get("jira-repos").ABC, { "o/r" }, "the pick is saved for the project")
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "issue", "map-jira", "issue", "issue" }, "the request is repeated once the project is mapped, and again once the base is picked")
	eq(requestsSent(w)[3].target, "o/r", "naming the repository picked")
	eq(requestsSent(w)[4].target, "o/r", "which the base's answer keeps")
	eq(requestsSent(w)[4].base, "main", "with the base")
	eq(w.window.launches[1].cwd, target, "the tab opens in the worktree of the picked repository")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	-- one mapped: no question at all
	local asked, sent = #w.window.picks, #requestsSent(w)
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(#w.window.picks, asked, "a mapped project asks nothing")
	eq(#requestsSent(w), sent + 1, "and sends one request")
	-- several mapped: asked each time, nothing saved
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }) })
	w.window.choose = "x/y"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(w.window.picks[asked + 1].placeholder, "Which repository for ABC-12?", "several repositories are asked each time")
	same(w.kv.get("jira-repos").ABC, { "o/r", "x/y" }, "and the map is left as it was")
	local last = requestsSent(w)
	eq(last[#last - 1].op, "issue", "the first request found several")
	eq(last[#last].target, "x/y", "the second names the pick")
end)

windowCase("window: Go to tab on an issue focuses the pane working in its worktree", function(w: World)
	local s, b = issueWindow(w)
	leaveIssueWt(w, s, 12)
	w.window.panes[9] = { block = nil, cwd = "/wt/plotroom-o_r-issue-12/src", tab = 2 }
	table.insert(w.window.tabs, { id = 2, session = 1 })
	table.insert(w.panes, { pane = 9, cwd = "/wt/plotroom-o_r-issue-12/src" })
	refreshNow(w, b)
	cardSurface(w, b)
	w.click(issueLink("goto", "o/r", "12"))
	w.flush()
	eq(requestsSent(w)[1].op, "where", "the host is asked where the issue's worktree is")
	eq(requestsSent(w)[1].key, "o/r#12", "naming the issue")
	same(w.window.switches, { 1 }, "its session is switched to")
	eq(w.window.focused, 9, "and the pane focused")
	eq(#w.toasts, 0, "with nothing said")
end)

windowCase("window: a prompt set to the main checkout starts its agent in a new tab at the checkout, with no worktree made", function(w: World)
	local s, b = issueWindow(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Review", "Review {title} ({url}) in {owner}/{repo}#{number}, branch {branch}", false) })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	b.render()
	cardSurface(w, b)
	w.click(issueRunLink("o/r", "12", "p1"))
	w.flush()
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "menu", "issue" }, "the host is asked what the prompt is, then for the checkout")
	eq(requestsSent(w)[2].worktree, false, "and the request says no worktree")
	eq(#w.window.picks, 0, "nothing is asked")
	eq(#w.window.agents, 1, "the agent starts")
	eq(w.window.agents[1].cwd, "/work/r", "in the main checkout")
	eq(w.window.agents[1].how, "tab", "in a new tab")
	eq(w.window.agents[1].prompt, "Review Fix login (https://github.com/o/r/issues/12) in o/r#12, branch {branch}", "with the issue's variables filled in; {branch} stays as written: there is no worktree")
	eq(w.toasts[#w.toasts].text, "Agent started for o/r#12", "the agent got its own tab, not the worktree's")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "#12 · r", "named for the issue")
	eq(#w.window.launches, 1, "the agent's tab is the only one: no setup shell")
	eq(#w.window.runs, 0, "no setup commands ran")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made")
	eq(cardOf(b), nil, "nor noted on the block")
end)

windowCase("window: the Agent picker on an issue runs typed text in its worktree and a saved prompt where it says, every {variable} filled in", function(w: World)
	local s, b = issueWindow(w)
	saveIssuePrompts(w, {
		issuePrompt("p1", "Here", "In {branch} ({base}): {title}", true),
		issuePrompt("p2", "There", "In the checkout, branch {branch}, labels {labels}", false),
	})
	b.render()
	cardSurface(w, b)
	w.window.choose, w.window.typed = { "Type a prompt…", "main" }, "Fix {title} ({key}) on {branch} from {base} of {remote}; {nope}"
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	local rows = promptPicks(w)[1].items
	same({ rows[1].label, rows[2].label, rows[3].label }, { "Type a prompt…", "Here", "There" }, "typing, then the saved prompts")
	eq(rows[2].worktree, true, "a prompt that runs in a worktree says so")
	eq(rows[3].worktree, false, "and one that runs in the checkout")
	eq(#w.window.agents, 1, "the typed prompt started an agent")
	eq(w.window.agents[1].cwd, "/wt/plotroom-o_r-issue-12", "in the issue's worktree")
	eq(w.window.agents[1].prompt, "Fix Fix login (12) on octocat/12-fix-login from main of origin; {nope}", "with the issue's variables and the new worktree's branch, base and remote filled in; an unknown one stays")
	eq(countLog(s.git, "worktree add -b octocat/12-fix-login /wt/plotroom-o_r-issue-12 " .. sha("b")), 1, "the worktree was made for it")
	w.window.choose = { "Start another agent", "There" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	eq(#w.window.agents, 2, "a saved prompt starts one too")
	eq(w.window.agents[2].cwd, "/work/r", "in the main checkout, as the prompt says")
	eq(w.window.agents[2].prompt, "In the checkout, branch {branch}, labels bug, ui", "with no branch to fill in")
	w.window.choose = { "Start another agent", "Here" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	eq(#w.window.agents, 3, "and another")
	eq(w.window.agents[3].cwd, "/wt/plotroom-o_r-issue-12", "in the worktree, as that prompt says")
	eq(w.window.agents[3].prompt, "In octocat/12-fix-login (): Fix login", "with its branch, and no base: the branch was reused")
	eq(countLog(s.git, "worktree add"), 1, "the worktree is made once")
end)

windowCase("window: with no prompts saved, an issue offers Implement and Fix in its worktree and Plan in the main checkout, every variable they name filled in", function(w: World)
	local _, b = issueWindow(w)
	b.render()
	cardSurface(w, b)
	w.window.choose = { "Implement", "main" }
	w.click(issueLink("agent", "o/r", "12"))
	w.flush()
	local rows = promptPicks(w)[1].items
	same({ rows[2].label, rows[3].label, rows[4].label }, { "Implement", "Fix", "Plan" }, "after typing, the defaults")
	same({ rows[2].worktree, rows[3].worktree, rows[4].worktree }, { true, true, false }, "Plan alone runs in the main checkout")
	for i, name in { "Implement", "Fix", "Plan" } do
		if i > 1 then
			w.window.choose = { "Start another agent", name }
			w.click(issueLink("agent", "o/r", "12"))
			w.flush()
		end
		local agent = w.window.agents[i]
		eq(agent.cwd, if name == "Plan" then "/work/r" else "/wt/plotroom-o_r-issue-12", name .. " runs where it says")
		lacks(agent.prompt, "{", name .. " has every variable it names filled in")
	end
	has(w.window.agents[1].prompt, "Branch: `octocat/12-fix-login` from base `main` (remote `origin`)", "a new worktree's branch, base and remote")
	has(w.window.agents[2].prompt, "from base `` (remote `origin`)", "a reused one has no base to tell")
	eq(w.kv.get("prompts-issues"), nil, "running them saves nothing")
end)

windowCase("window: Open on an issue opens its URL beside the block it came from, whatever pane has focus", function(w: World)
	local _, b = issueWindow(w)
	local open = h.tokened("plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12")
	eq(buttonLink(b, "open"), open, "the block's Open link carries the issue's URL")
	w.window.focused = 7
	w.click(open)
	w.flush()
	same(w.window.browser, { { url = "https://github.com/o/r/issues/12", how = "beside", beside = 1 } }, "the issue's page, opened beside the block")
	eq(#w.toasts, 0, "nothing is said")
	w.command("open-selected")
	w.flush()
	eq(#w.window.browser, 2, "the palette command follows the same link")
end)

windowCase("window: a linked pull request in an issue's sidebar is shown by the Plotroom block it is in, which the window focuses: no other block, tab or session, and the issue filter is still there to go back to", function(w: World)
	local s, b = issueWindow(w)
	local url = "https://github.com/o/r/pull/45"
	s.gh.pulls[url] = searchItem(45, "o/r", EPOCH - 600, { title = "Fix the login redirect" })
	s.gh.issueDetail["o/r#12"] = { body = "x", linked = array({ { number = 45, title = "Fix the login redirect", url = url, state = "OPEN", isDraft = false } }) }
	w.advance(300)
	cardSurface(w, b)
	local show = "plotroom://github/show/o/r/45"
	eq(findKey(pickerNode(b), "pr1", "item").p.href, show, "the linked row links to showing it")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "the block's buttons are the issue's")
	w.window.focused = nil
	w.click(show)
	same(w.window.events[#w.window.events], { pane = 1, ev = { ev = "action", act = "show-pr", value = url } }, "it tells the block the link is in, not another one, to show the pull request")
	eq(w.window.focused, 1, "and focuses it")
	eq(#w.window.launches, 0, "no block is launched")
	eq(#w.window.switches, 0, "no session is switched to")
	w.flush()
	same(listed(b), { "no_2fr_2345" }, "the same block lists the pull request alone")
	eq(pickerOf(b).noun, "pull requests", "as pull requests")
	eq(pickerOf(b).scope, pickerOf(b).scopes[1].id, "in a scope of its own, the first of the sidebar")
	eq(buttonLink(b, "worktree"), prLink("worktree", "o/r", 45), "its buttons are the pull request's")
	pickScope(b, "issues:v1")
	w.flush()
	same(listed(b), { "no_2fr_2312", "no_2fr_2313", "no_2fr_2314" }, "the issue filter is one click away: its issues are back")
	eq(buttonLink(b, "worktree"), issueLink("worktree", "o/r", "12"), "with the issue's buttons")
	local said, sent = #w.toasts, #w.window.events
	w.click("plotroom://github/show/o/r/46")
	eq(w.toasts[said + 1].text, "Plotroom: that pull request is no longer listed", "a pull request the sidebar does not link is refused")
	eq(#w.window.events, sent, "and no block is told anything")
end)

windowCase("window: Plotroom has one launcher, which opens the one block beside the focused pane, and no command opens an Issues block of its own", function(w: World)
	w.load("window")
	w.command("open")
	same(w.window.launches, { { block = "plotroom.prs", cwd = "/work/r", args = { "/work/r" } } }, "the palette command launches the Plotroom block in the focused pane's folder")
	local ok = pcall(w.command, "open-issues")
	eq(ok, false, "there is no command for an Issues block")
end)

windowCase("window: a forged issue link not shown by the block is refused before anything is asked", function(w: World)
	local _, b = issueWindow(w)
	saveIssuePrompts(w, { issuePrompt("p1", "Triage", "Triage {url}", true) })
	b.render()
	cardSurface(w, b)
	local sent, ran, picked = #w.window.events, #w.calls, #w.window.picks
	local function refused(url: string, text: string, what: string, pane: number?)
		local said = #w.toasts
		w.click(url, pane)
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		eq(w.toasts[#w.toasts].text, text, what .. ": what is wrong")
	end
	local unlisted = "Plotroom: that issue is no longer listed"
	local malformed = "Plotroom: malformed link"
	refused(issueLink("worktree", "o/r", "13"), unlisted, "another issue")
	refused(issueLink("worktree", "x/r", "12"), unlisted, "another repository")
	refused(issueLink("agent", "o/r", "13"), unlisted, "the Agent link of another issue")
	refused(issueLink("goto", "o/r", "12"), unlisted, "a tab link the block shows none of")
	refused(issueRunLink("o/r", "12", "p9"), unlisted, "a prompt with no button")
	refused(issueRunLink("o/r", "13", "p1"), unlisted, "a prompt button of another issue")
	refused("plotroom://issue/open/https%3A%2F%2Fevil.example%2Fx", unlisted, "a page that is not the issue's")
	refused("plotroom://issue/open/javascript%3Aalert(1)", malformed, "a page that is not https")
	refused("plotroom://issue/open/https%3A%2F%2Fa.example%2F%0Ax", malformed, "a page with a control character")
	refused("plotroom://issue/open/https%3A%2F%2Fa.example%2Fx%20y", malformed, "a page with a space")
	refused("plotroom://issue/worktree/o/r", malformed, "a link with no issue")
	refused("plotroom://issue/bogus/o/r/12", malformed, "an action there is none of")
	refused("plotroom://issue/worktree/o/../12", malformed, "a dot-dot repository")
	refused(issueLink("worktree", "o/r", string.rep("1", 65)), malformed, "a reference over 64 bytes")
	refused(issueRunLink("o/r", "12", "p-1"), malformed, "an id that is no word")
	refused(issueLink("worktree", "o/r", "12"), "Plotroom: link did not come from a Plotroom block", "a pane that is not Plotroom", 2)
	w.window.panes[2] = { block = "plugin.plotroom.issues", cwd = "/work/r", tab = 1 }
	refused(issueLink("worktree", "o/r", "12"), "Plotroom: link did not come from a Plotroom block", "a pane of the retired Issues block", 2)
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.window.picks, picked, "nothing was offered")
	eq(#w.window.browser, 0, "no Browser opened")
	eq(#w.window.agents + #w.window.launches, 0, "and nothing started")
end)

case("host: a request is about what it names, not about the filter on screen: a pull request's worktree and Jira's projects are answered under either kind", function(w: World)
	local s = jiraHost(w)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	s.acli.projects = { { key = "ABC", name = "Alpha" } }
	local b = openIssues(w)
	eq(hx.ask(w, b, "p1", { op = "worktree", repo = "o/r", number = 1 }).path, "/wt/plotroom-o_r-pr-1", "a pull request's worktree is made while an issue filter is shown")
	eq(hx.ask(w, b, "w1", { op = "where", kind = "pr", key = "o/r#1" }).path, "/wt/plotroom-o_r-pr-1", "its block says where it is")
	eq(hx.ask(w, b, "w2", { op = "where", kind = "issue", key = "o/r#1" }).path, nil, "asked about an issue of that key, it knows none")
	pickScope(b, "prs:v1")
	w.flush()
	eq(hx.ask(w, b, "j1", { op = "jira-projects" }).items[1].key, "ABC", "Jira's projects are listed while a pull request filter is shown")
	goToSettings(b, "jira")
	expand(b, "jopen:ABC")
	eq(rowIn(b, "jrepos:ABC").control.values[1], "o/r", "Settings has the Jira page under a pull request filter too, with the project's repository")
	b.press("escape")
	hx.ask(w, b, "j2", { op = "map-jira", project = "ABC", repo = "x/y" })
	same(w.kv.get("jira-repos").ABC, { "o/r", "x/y" }, "and a repository is mapped to a project")
	eq(hx.ask(w, b, "i1", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false }).problem, "That issue is not loaded here any more; Refresh and try again.", "an issue is answered only while its list is loaded: the pull request filter replaced it")
end)

case("host: without gh, an issue action's Next action offers no pull request actions", function(w: World)
	jiraHost(w)
	hx.uninstalled(w, "gh")
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	local b = openIssues(w)
	goToSettings(b, "prompts")
	expand(b, "popen:issues:p1")
	same(asks.hx.options(b, "pnext:issues:p1"), { "none", "p2", "p3" }, "only the issue actions: a pull request action could only fail")
end)

case("host: without gh, GitHub is off everywhere: no GitHub view, group, prompt or request, and Settings shows its setup guide until gh starts", function(w: World)
	local s = jiraHost(w)
	local gh = hx.uninstalled(w, "gh")
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	-- restored on a GitHub pull request view
	local b = w.open(1, { "/work/r" }, { version = 2, launchCwd = "/work/r", activeViewId = "v1" })
	w.flush()
	same(sidebarOf(b), { "Assigned to me @ - = issues:v1" }, "only the Jira view is listed")
	eq(b.title(), "Plotroom · Assigned to me (2) · 1 new", "and shown in place of the GitHub view restored")
	eq(#w.kv.get("views-prs").items, 4, "the GitHub views stay saved")
	goToSettings(b, "views")
	same(hx.rows(b), { "vopen:issues:v1", "vadd:jira:", "vrestore:jira:" }, "Views has Jira's group alone")
	b.press("escape")
	goToSettings(b, "prompts")
	same(hx.rows(b), { "popen:issues:p1", "popen:issues:p2", "popen:issues:p3", "padd:issues" }, "Prompts has the issue prompts alone, the defaults here: the pull request one stays saved, unlisted")
	b.press("escape")
	goToSettings(b, "worktrees")
	same(hx.rows(b), { "fmt:branch", "fmt:issuedir" }, "no pull request folder name")
	b.press("escape")
	goToSettings(b, "setup-github")
	same(hx.pages(b), { "views", "prompts", "keys", "worktrees", "repos", "jira", "connection", "setup-github" }, "GitHub's setup page is offered")
	eq(prefsOf(b).focus, "guide:github", "its one row")
	b.press("enter")
	eq(w.opened[#w.opened], "https://github.com/cli/cli#installation", "opens gh's install guide")
	b.press("escape")
	w.kv.put("branch-format", "{key}-{slug}")
	same(hx.ask(w, b, "j1", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true }), { chooseBase = true, branch = "ABC-12-fix-login", branches = { "main" } }, "a Jira issue's worktree looks for no linked pull request: a new branch")
	w.kv.put("branch-format", "")
	has(hx.ask(w, b, "j2", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true }).problem, "{github.user}, which could not be read: install gh (Settings › GitHub)", "the default format's gh login says gh is missing")
	for _, call in w.calls do
		if call.argv[1] == "gh" then
			eq(table.concat(call.argv, " "), "gh --version", "gh is only asked whether it starts")
		end
	end
	-- gh is installed meanwhile: showing its setup page again finds it
	gh.missing = false
	goToSettings(b, "setup-github")
	w.flush()
	eq(prefsOf(b).page, "views", "the setup page gives way to Views")
	yes(rowIn(b, "vadd:github:octocat") ~= nil, "which has the signed-in account's group")
	b.press("escape")
	same(sidebarOf(b), {
		"My PRs @ GitHub - octocat = prs:v1",
		"Review requested @ GitHub - octocat = prs:v2",
		"Team reviews @ GitHub - octocat = prs:v3",
		"Reviewed by me @ GitHub - octocat = prs:v4",
		"Assigned to me @ Jira = issues:v1",
	}, "the GitHub views are listed again")
	eq(pickerOf(b).scope, "issues:v1", "the view on screen stays")
	eq(#requestsOf(s.gh, "search"), 0, "and nothing searches GitHub until one is picked")
end)

case("host: with no prompts saved, Settings lists each kind's default prompts, and the first change saves them with it", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	goToSettings(b, "prompts")
	local defaults = (w.load("prompts") :: any).prs
	local issueDefaults = (w.load("prompts") :: any).issues
	local expectRows: { string } = {}
	for _, d in defaults do
		table.insert(expectRows, "popen:prs:" .. d.id)
	end
	table.insert(expectRows, "padd:prs")
	for _, d in issueDefaults do
		table.insert(expectRows, "popen:issues:" .. d.id)
	end
	table.insert(expectRows, "padd:issues")
	same(hx.rows(b), expectRows, "both kinds list the defaults prompts.luau exports")
	eq(w.kv.get("prompts-prs"), nil, "showing them saves nothing")
	b.event({ ev = "action", id = "layer.settings", act = "add-prompt", value = "padd:prs" })
	local saved = w.kv.get("prompts-prs")
	local names: { string } = {}
	for _, p in saved.items do
		table.insert(names, p.name)
	end
	local expectNames: { string } = {}
	for _, d in defaults do
		table.insert(expectNames, d.name)
	end
	table.insert(expectNames, "New action")
	same(names, expectNames, "Add saves the defaults, then the new prompt")
	eq(saved.nextId, #saved.items + 1, "whose id follows theirs")
	eq(saved.items[1].text, defaults[1].text, "a default is saved with its text")
	eq(w.kv.get("prompts-issues"), nil, "the issue prompts stay the defaults")
end)

case("host: Restore defaults saves back the default actions no saved one is named like, and a kind with none keeps its title on its buttons", function(w: World)
	hostScene(w, 3)
	local defaults = (w.load("prompts") :: any).prs
	savePrompts(w, { promptOf("p1", defaults[1].name, "My own review"), promptOf("p2", "Mine", "Look at {url}") })
	saveIssuePrompts(w, {})
	local b = openQueue(w)
	goToSettings(b, "prompts")
	same(hx.rows(b), { "popen:prs:p1", "popen:prs:p2", "padd:prs", "prestore:prs", "padd:issues", "prestore:issues" }, "each kind can restore what it lacks")
	eq(sectionIn(b, "padd:issues").title, "Issue actions", "a kind with none saved titles its buttons, so they say whose they are")
	eq(sectionIn(b, "padd:prs").title, nil, "a kind with a list has them under it")
	b.event({ ev = "action", id = "layer.settings", act = "restore-prompts", value = "prestore:prs" })
	local saved = w.kv.get("prompts-prs")
	local names: { string } = {}
	for _, p in saved.items do
		table.insert(names, p.name)
	end
	local expectRestored: { string } = { defaults[1].name, "Mine" }
	for i = 2, #defaults do
		table.insert(expectRestored, defaults[i].name)
	end
	same(names, expectRestored, "the missing defaults are added after the saved ones")
	eq(saved.items[1].text, "My own review", "an edited default keeps its text")
	local last = #defaults + 1
	local ids: { string } = {}
	for i = 3, last do
		table.insert(ids, saved.items[i].id)
	end
	eq(#ids, #defaults - 1, "every missing default is restored")
	yes(saved.items[3].id ~= saved.items[1].id and saved.items[3].id ~= saved.items[2].id, "the restored ones take ids no saved prompt has")
	eq(saved.items[3].worktree, defaults[2].worktree, "and keep where they run")
	eq(saved.nextId, last + 1, "and the next free one follows them")
	local full: { string } = {}
	for i = 1, last do
		table.insert(full, "popen:prs:p" .. i)
	end
	table.insert(full, "padd:prs")
	table.insert(full, "padd:issues")
	table.insert(full, "prestore:issues")
	same(hx.rows(b), full, "with every default saved, Restore defaults goes")
	eq(prefsOf(b).focus, "padd:prs", "and Add takes the focus")
	eq(#w.kv.get("prompts-issues").items, 0, "the other kind is untouched")
end)

case("host: with neither gh nor acli installed, nothing is listed or asked, and Settings offers both setup guides", function(w: World)
	hostScene(w, 3)
	hx.uninstalled(w, "gh")
	hx.uninstalled(w, "acli")
	local b = openQueue(w)
	eq(#pickerOf(b).scopes, 3, "only the Worktrees, Agents and Inbox lists are listed: no view is")
	eq(pickerOf(b).state, "ready", "nothing is loading")
	has(b.text(), "Neither gh nor acli is installed on this host. Press s to set one up.", "the queue says what to do")
	for _, call in w.calls do
		if call.argv[1] == "gh" or call.argv[1] == "acli" then
			eq(call.argv[2], "--version", call.argv[1] .. " is only asked whether it starts")
		end
	end
	goToSettings(b, "setup-jira")
	same(hx.pages(b), { "views", "prompts", "keys", "worktrees", "repos", "connection", "setup-github", "setup-jira" }, "no Jira projects page, and a setup page each")
	b.press("enter")
	eq(w.opened[#w.opened], "https://developer.atlassian.com/cloud/acli/guides/install-acli/", "Jira's opens acli's install guide")
end)

case("host: until the CLIs answer no view is listed or searched, and the restored view is the active one once they do", function(w: World)
	local s = issueHost(w)
	w.respond(function(call: Call): Reply?
		if call.argv[1] == "gh" and call.argv[2] == "--version" then
			return { delay = 1000, stdout = "gh version 2.98.0\n" }
		end
		return nil
	end)
	local b = openIssues(w) -- acli has answered, gh not yet
	eq(#pickerOf(b).scopes, 3, "only the Worktrees, Agents and Inbox lists are listed while gh has not answered: no view is")
	eq(pickerOf(b).state, "loading", "the queue is loading")
	eq(#requestsOf(s.gh, "issue-search"), 0, "nothing is searched")
	eq(b.saved().activeViewId, "v1", "the block still saves the view it was restored on")
	eq(b.saved().activeKind, "issues", "with its kind")
	w.advance(1000)
	eq(pickerOf(b).scope, "issues:v1", "once gh answers, the restored view is the active one")
	eq(#requestsOf(s.gh, "issue-search"), 1, "and is searched")
	eq(#listed(b), 3, "its issues are listed")
end)

case("host: Settings › Worktrees lists the three name formats with their defaults, and saves only a format that can name a branch or a folder", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	goToSettings(prs, "worktrees")
	local formats: { { string } } = {
		{ "fmt:branch", "{github.user}/{key}-{slug}" },
		{ "fmt:prdir", "plotroom-{owner}_{repo}-pr-{key}" },
		{ "fmt:issuedir", "plotroom-{owner}_{repo}-issue-{key}" },
	}
	for _, e in formats do
		local row = rowIn(prs, e[1])
		eq(row.control.k, "text", e[1] .. ": a text field")
		eq(row.control.placeholder, e[2], e[1] .. ": the default is its placeholder")
		eq(row.control.value, "", e[1] .. ": nothing is saved")
		eq(row.changed, false, e[1] .. ": so the row is not marked changed")
		eq(row.defaultLabel, e[2], e[1] .. ": and a reset says the default")
	end
	-- a format that cannot name what it is for is refused by name, with the draft kept and nothing saved
	eq(hx.save(prs, "fmt:branch", "{foo}"), "Unknown variable {foo}.", "an unknown variable is refused by name")
	eq(prefsOf(prs).editing.row, "fmt:branch", "the draft stays for a correction")
	eq(hx.save(prs, "fmt:branch", "{foo.bar}/{key}"), "Unknown variable {foo.bar}.", "a dotted one is named whole")
	eq(hx.save(prs, "fmt:branch", "x-{slug}"), "Include {key}, so each issue gets its own branch.", "a branch format without {key} would give every issue one branch")
	eq(w.kv.get("branch-format"), nil, "nothing was saved")
	eq(hx.save(prs, "fmt:branch", "feat/{github.user}-{key}"), nil, "a slash and a user are fine in a branch")
	eq(prefsOf(prs).editing, nil, "a good format closes the edit")
	eq(w.kv.get("branch-format"), "feat/{github.user}-{key}", "and is saved")
	eq(rowIn(prs, "fmt:branch").control.value, "feat/{github.user}-{key}", "the row shows it")
	eq(rowIn(prs, "fmt:branch").changed, true, "as changed")
	eq(rowIn(prs, "fmt:branch").control.placeholder, "{github.user}/{key}-{slug}", "its placeholder is still the default")
	-- a folder name holds neither the branch's users and project nor a slash, and needs {key} in its own words
	eq(hx.save(prs, "fmt:prdir", "{github.user}-{key}"), "Unknown variable {github.user}.", "a folder name has no user")
	eq(hx.save(prs, "fmt:prdir", "{project}-{key}"), "Unknown variable {project}.", "nor a project")
	eq(hx.save(prs, "fmt:prdir", "wt/{key}"), "A folder name holds no /.", "a slash would nest the folder")
	eq(hx.save(prs, "fmt:prdir", "pr-{slug}"), "Include {key}, so each worktree gets its own folder.", "a folder format without {key} would give every pull request one folder")
	eq(hx.save(prs, "fmt:issuedir", "issue-{owner}"), "Include {key}, so each worktree gets its own folder.", "and so would an issue's")
	eq(w.kv.get("pr-dir-format"), nil, "no folder format was saved")
	eq(w.kv.get("issue-dir-format"), nil, "by any of them")
	eq(hx.save(prs, "fmt:prdir", "pr-{key}-{slug}"), nil, "a good folder format is accepted")
	eq(w.kv.get("pr-dir-format"), "pr-{key}-{slug}", "saved for pull requests")
	eq(rowIn(prs, "fmt:prdir").control.value, "pr-{key}-{slug}", "the row shows it")
	eq(rowIn(prs, "fmt:prdir").changed, true, "as changed")
	eq(rowIn(prs, "fmt:prdir").control.placeholder, "plotroom-{owner}_{repo}-pr-{key}", "its placeholder is still the default")
	eq(w.kv.get("issue-dir-format"), nil, "and only for them")
	eq(hx.save(prs, "fmt:issuedir", "{owner}-{repo}-i{key}"), nil, "an issue's folder has its own format")
	eq(w.kv.get("issue-dir-format"), "{owner}-{repo}-i{key}", "saved apart")
	eq(w.kv.get("branch-format"), "feat/{github.user}-{key}", "the branch format is as it was")
	-- an issue filter's pane reads the same formats
	goToSettings(issues, "worktrees")
	eq(rowIn(issues, "fmt:branch").control.value, "feat/{github.user}-{key}", "its page shows the branch format")
	eq(rowIn(issues, "fmt:prdir").control.value, "pr-{key}-{slug}", "the pull request folder format")
	eq(rowIn(issues, "fmt:issuedir").control.value, "{owner}-{repo}-i{key}", "and the issue folder format")
	eq(rowIn(issues, "fmt:issuedir").changed, true, "as changed")
	-- empty text, blank text and Reset go back to the default
	eq(hx.save(prs, "fmt:prdir", ""), nil, "an empty format is accepted")
	eq(w.kv.get("pr-dir-format"), "", "and saves the default")
	eq(rowIn(prs, "fmt:prdir").control.value, "", "the row is empty again")
	eq(rowIn(prs, "fmt:prdir").changed, false, "and unchanged")
	eq(hx.save(prs, "fmt:branch", "   "), nil, "blank text is an empty format too, not a format of blanks")
	eq(w.kv.get("branch-format"), "", "the default again")
	eq(rowIn(prs, "fmt:branch").changed, false, "unchanged")
	eq(hx.reset(prs, "fmt:issuedir"), nil, "Reset takes no warning")
	eq(w.kv.get("issue-dir-format"), "", "it saves the default")
	eq(rowIn(prs, "fmt:issuedir").control.value, "", "the row is empty again")
	eq(rowIn(prs, "fmt:issuedir").changed, false, "and unchanged")
	-- a format that cannot be written says so and keeps its draft; nothing is swallowed
	w.kv.failSet["issue-dir-format"] = "read-only file system"
	eq(hx.save(prs, "fmt:issuedir", "i{key}"), "Could not save: read-only file system", "a failed write is reported under the row")
	eq(prefsOf(prs).editing.draft, "i{key}", "with the draft kept")
	eq(w.kv.get("issue-dir-format"), "", "and the saved format as it was")
	w.kv.failSet["issue-dir-format"] = nil
	prs.press("enter")
	eq(rowIn(prs, "fmt:issuedir").warning, nil, "the retry clears the warning")
	eq(w.kv.get("issue-dir-format"), "i{key}", "and saves the draft")
	w.kv.failSet["issue-dir-format"] = "read-only file system"
	eq(hx.reset(prs, "fmt:issuedir"), "Could not save: read-only file system", "a Reset that cannot be written says so")
	eq(w.kv.get("issue-dir-format"), "i{key}", "and keeps the format")
	eq(rowIn(prs, "fmt:issuedir").changed, true, "which the row still shows")
end)

case("host: the repository's own branch format wins over the Worktrees one for an issue's new branch, and its Reset brings the Worktrees one back", function(w: World)
	local s = issueHost(w)
	table.insert(s.gh.issueItems.octocat, issueItem(15, "o/r", EPOCH - 240, { title = "Ship it" }))
	-- GitHub spells a repository as its owner did: the formats are found whatever the case
	table.insert(s.gh.issueItems.octocat, issueItem(16, "O/R", EPOCH - 300, { title = "Shout" }))
	local b = openIssues(w)
	goToSettings(b, "repos")
	expand(b, "ropen:o/r")
	eq(rowIn(b, "branch:o/r").control.placeholder, "{github.user}/{key}-{slug}", "the repository's row shows the Worktrees format, the default while none is saved")
	b.event({ ev = "action", id = "layer.settings", act = "page", value = "worktrees" })
	eq(hx.save(b, "fmt:branch", "{key}-{slug}"), nil, "a Worktrees format is saved")
	b.event({ ev = "action", id = "layer.settings", act = "page", value = "repos" })
	local row = rowIn(b, "branch:o/r")
	eq(row.control.placeholder, "{key}-{slug}", "it is now the placeholder of the repository's row")
	eq(row.control.value, "", "which holds none of its own")
	eq(row.changed, false, "so it is not marked changed")
	eq(hx.ask(w, b, "g1", freshAsk("o/r", "12")).vars.branch, "12-fix-login", "an issue's branch follows the Worktrees format")
	eq(hx.save(b, "branch:o/r", "feat/{github.user}-{key}"), nil, "the repository's own format is saved: it may name the gh login, which the Worktrees format does not")
	same(w.kv.get("branch-formats"), { ["o/r"] = "feat/{github.user}-{key}" }, "under the repository, lowercase")
	row = rowIn(b, "branch:o/r")
	eq(row.control.value, "feat/{github.user}-{key}", "the row shows it")
	eq(row.changed, true, "as changed")
	eq(row.control.placeholder, "{key}-{slug}", "its placeholder is still the Worktrees format")
	local a = hx.ask(w, b, "r1", freshAsk("o/r", "13"))
	eq(a.vars.branch, "feat/octocat-13", "the repository's format names the branch, over the Worktrees one")
	eq(a.path, "/wt/plotroom-o_r-issue-13", "in the folder the folder format names")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b feat/octocat-13 /wt/plotroom-o_r-issue-13 " .. sha("b")), 1, "git made that branch")
	a = hx.ask(w, b, "r4", freshAsk("o/r", "16"))
	eq(a.vars.branch, "feat/octocat-16", "an issue whose repository GitHub spells in capitals has the same format")
	eq(a.path, "/wt/plotroom-o_r-issue-16", "and its folder is lowercase")
	eq(w.kv.get("branch-format"), "{key}-{slug}", "the Worktrees format is as it was")
	eq(hx.reset(b, "branch:o/r"), nil, "Reset takes the repository's format away")
	eq(w.kv.get("branch-formats")["o/r"], nil, "from the saved ones")
	row = rowIn(b, "branch:o/r")
	eq(row.control.value, "", "the row is empty again")
	eq(row.changed, false, "and unchanged")
	eq(hx.ask(w, b, "r2", freshAsk("o/r", "14")).vars.branch, "14-docs-typo", "the Worktrees format names the branch again")
	-- formats that cannot be read leave the Worktrees one, and their row locked
	w.kv.put("branch-formats", "garbage")
	b.render()
	has(rowIn(b, "branch:o/r").disabled, "could not be read", "an unreadable map locks the row, saying why")
	eq(hx.ask(w, b, "r3", freshAsk("o/r", "15")).vars.branch, "15-ship-it", "and the Worktrees format applies meanwhile")
	eq(w.kv.get("branch-formats"), "garbage", "the map is never overwritten")
end)

case("host: an issue's new branch is named from the gh login by default, and the login is read only when the format or the prompt needs it", function(w: World)
	local s = issueHost(w)
	-- gh cannot say who is signed in until `healed`: every request that needs the login asks again
	local healed = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" and not healed then
			return { status = 1, stderr = "gh: not logged in\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local function asked(): number
		return #requestsOf(s.gh, "accounts")
	end
	local opened = asked()
	-- a prompt that runs in the main checkout needs no login unless it names one
	local a = hx.ask(w, b, "m1", { op = "issue", repo = "o/r", ref = "12", worktree = false })
	eq(a.path, "/work/r", "the main checkout is answered")
	eq(a.vars["github.user"], nil, "with no login among the variables")
	eq(asked(), opened, "gh was not asked who is signed in")
	-- the default format names the login: unreadable, the request is refused and nothing is made
	local before = snapshot(s.git)
	local mark = #w.calls
	a = hx.ask(w, b, "d1", freshAsk("o/r", "12"))
	eq(a.problem, "The branch format names {github.user}, which could not be read: sign in with gh auth login, or change the format in Settings › Repositories.", "the answer says what to do")
	eq(asked(), opened + 1, "gh was asked who is signed in")
	same(ranSince(w, mark), { "gh auth status --hostname github.com --json hosts" }, "and that was the only command: git was never asked anything")
	eq(snapshot(s.git), before, "no branch, worktree or setting was written")
	eq(badgeOf(b), nil, "the row has no Worktree badge")
	eq(hx.ask(w, b, "d2", freshAsk("o/r", "12")).busy, nil, "the refused request left the issue free for the next one")
	-- a format that cannot name a branch is refused for that, and frees the issue the same
	w.kv.put("branch-format", "{github.user}/{foo}")
	eq(hx.ask(w, b, "f1", freshAsk("o/r", "12")).problem, "Unknown variable {foo}.", "a variable there is none of is refused by name")
	eq(hx.ask(w, b, "f2", freshAsk("o/r", "12")).busy, nil, "and the next request finds the issue free")
	-- a format that names no user never asks
	w.kv.put("branch-format", "{key}-{slug}")
	local count = asked()
	a = hx.ask(w, b, "c1", freshAsk("o/r", "12"))
	eq(a.vars.branch, "12-fix-login", "the format names the branch")
	eq(a.path, "/wt/plotroom-o_r-issue-12", "in the issue's folder")
	eq(a.vars["github.user"], nil, "with no login among the variables")
	eq(asked(), count, "gh was not asked who is signed in")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b 12-fix-login /wt/plotroom-o_r-issue-12 " .. sha("b")), 1, "the worktree was made")
	-- the login is the branch's first part once gh can say it
	healed = true
	w.kv.put("branch-format", "")
	a = hx.ask(w, b, "g1", freshAsk("o/r", "13"))
	eq(a.vars.branch, "octocat/13-add-dark-mode", "the default format names the gh login, the key and the title's slug")
	eq(a.path, "/wt/plotroom-o_r-issue-13", "in the issue's folder")
	eq(a.vars["github.user"], "octocat", "the login joins the variables")
	eq(s.git.refs["refs/heads/octocat/13-add-dark-mode"], sha("b"), "git made the branch")
	-- a prompt that names the users gets them whatever the format says
	w.kv.put("branch-format", "{key}-{slug}")
	a = hx.ask(w, b, "u1", { op = "issue", repo = "o/r", ref = "14", worktree = true, fresh = true, base = "main", users = true })
	eq(a.vars.branch, "14-docs-typo", "the format still names the branch")
	eq(a.vars["github.user"], "octocat", "and the login is among the variables the prompt asked for")
	a = hx.ask(w, b, "u2", { op = "issue", repo = "o/r", ref = "12", worktree = false, users = true })
	eq(a.path, "/work/r", "so it is for a prompt that runs in the main checkout")
	eq(a.vars["github.user"], "octocat", "which gets the login too")
end)

case("host: {github.user} is the login the view runs as, and gh's active one for a view with none", function(w: World)
	local s = issueHost(w)
	s.gh.tokens.work = "tok-work"
	s.gh.issueItems.work = { issueItem(12, "o/r", EPOCH - 60, { title = "Fix login" }) }
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Work", integration = "github", query = "is:open", logins = array({ "work" }), group = "none", prompts = array({}) },
	}) })
	local work = openIssues(w, 1)
	eq(hx.ask(w, work, "w1", freshAsk("o/r", "12")).vars.branch, "work/12-fix-login", "a view that runs as work names work, not gh's active login")
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local mine = openIssues(w, 2)
	eq(hx.ask(w, mine, "m1", freshAsk("o/r", "13")).vars.branch, "octocat/13-add-dark-mode", "a view with no login runs as gh's active one")
end)

case("host: a Jira issue's branch can name {jira.user}, the sign-in's email before the @", function(w: World)
	local s = jiraHost(w)
	w.kv.put("branch-format", "{jira.user}/{key}-{slug}")
	local b = openIssues(w)
	local a = hx.ask(w, b, "j1", freshAsk("ABC", "ABC-12"))
	eq(a.vars.branch, "ann/ABC-12-fix-login", "the format names the email's local part, the key and the title's slug")
	eq(a.path, "/wt/plotroom-o_r-issue-ABC-12", "in the issue's folder")
	eq(a.vars["jira.user"], "ann", "the Jira user joins the variables")
	eq(s.git.refs["refs/heads/ann/ABC-12-fix-login"], sha("b"), "git made the branch")
	-- a format that names no user reads none unless the prompt asks for them
	w.kv.put("branch-format", "{key}-{slug}")
	a = hx.ask(w, b, "j2", freshAsk("ABC", "ABC-13"))
	eq(a.vars.branch, "ABC-13-old-bug", "the format names the branch")
	eq(a.vars["jira.user"], nil, "with no Jira user among the variables")
	eq(a.vars["github.user"], nil, "nor a gh login")
	a = hx.ask(w, b, "j3", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = true })
	eq(a.path, "/work/r", "a prompt that runs in the main checkout")
	eq(a.vars["jira.user"], "ann", "gets the Jira user when it asks")
	eq(a.vars["github.user"], "octocat", "and the gh login")
end)

case("host: a branch format naming {jira.user} is refused while the sign-in names no email, and nothing is made", function(w: World)
	local s = jiraHost(w)
	-- an API token's sign-in has no email to take the user from
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = "✓ Authenticated\n  Site: acme.atlassian.net\n  Authentication Type: api_token\n" }
		end
		return nil
	end
	w.kv.put("branch-format", "{jira.user}/{key}-{slug}")
	local b = openIssues(w)
	local before = snapshot(s.git)
	local mark = #w.calls
	local a = hx.ask(w, b, "t1", freshAsk("ABC", "ABC-12"))
	eq(a.problem, "The branch format names {jira.user}, which could not be read: sign in with acli jira auth login, or change the format in Settings › Repositories.", "the answer says what to do")
	eq(snapshot(s.git), before, "no branch or worktree was made")
	for _, line in ranSince(w, mark) do
		lacks(line, "worktree add", "no worktree was added: " .. line)
	end
	eq(cardOf(b), nil, "no worktree is noted: the issue has no card")
	eq(hx.ask(w, b, "t2", freshAsk("ABC", "ABC-12")).busy, nil, "the refused request left the issue free for the next one")
	w.kv.put("branch-format", "")
	eq(hx.ask(w, b, "t3", freshAsk("ABC", "ABC-12")).vars.branch, "octocat/ABC-12-fix-login", "a format that names no Jira user does not need one")
end)

case("host: a map-jira request naming something other than owner/name is answered with a problem, not left to time out", function(w: World)
	hostScene(w, 1)
	local b = openQueue(w)
	eq(hx.ask(w, b, "j1", { op = "map-jira", project = "ABC", repo = "github.com/o/r" }).problem, "Type it as owner/name.", "the typed text is refused with what to type")
	eq(w.kv.get("jira-repos"), nil, "and nothing is saved")
end)

case("host: a pull request worktree request answers the gh login only when it asks for it, and still makes the worktree when gh cannot say it", function(w: World)
	local s = hostScene(w, 1)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local healed = false
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" and not healed then
			return { status = 1, stderr = "gh: not logged in\n" }
		end
		return nil
	end
	local b = openQueue(w)
	local count = #requestsOf(s.gh, "accounts")
	local a = hx.ask(w, b, "a1", { op = "worktree", repo = "o/r", number = 1 })
	eq(a.path, "/wt/plotroom-o_r-pr-1", "the worktree is made")
	eq(a["github.user"], nil, "with no login in the answer")
	eq(#requestsOf(s.gh, "accounts"), count, "gh was not asked who is signed in")
	a = hx.ask(w, b, "a2", { op = "worktree", repo = "o/r", number = 1, users = true })
	eq(a.path, "/wt/plotroom-o_r-pr-1", "a login that cannot be read does not stop the worktree")
	eq(a["github.user"], "", "the answer says it is unknown")
	eq(#requestsOf(s.gh, "accounts"), count + 1, "gh was asked who is signed in")
	healed = true
	a = hx.ask(w, b, "a3", { op = "worktree", repo = "o/r", number = 1, users = true })
	eq(a["github.user"], "octocat", "the answer carries the login once gh says it")
	a = hx.ask(w, b, "a4", { op = "worktree", repo = "o/r", number = 1, users = "yes" })
	eq(a["github.user"], nil, "only true asks for it")
	request(b, "a5", { op = "worktree", repo = "o/r", number = 1, users = true })
	request(b, "a6", { op = "worktree", repo = "o/r", number = 1 })
	eq(answerOf(b, "a6").busy, true, "a repeat while the login is read is told the worktree is busy")
	w.flush()
	eq(answerOf(b, "a5")["github.user"], "octocat", "the first request is answered with it")
end)

case("host: an issue worktree request with nothing decided asks gh for the linked pull requests and, with none still on a branch, offers the remote's branches for a new one", function(w: World)
	local s = issueHost(w)
	s.git.served["refs/heads/zeta"] = sha("c")
	s.git.served["refs/heads/alpha"] = sha("d")
	s.git.served["refs/heads/dev/x"] = sha("e")
	-- #13's only linked pull request lost its branch
	s.gh.linked["o/r#13"] = array({ hx.linkedPr(s, 40, "Old try", "old-try", false) })
	local b = openIssues(w)
	local before = snapshot(s.git)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	same(a, { chooseBase = true, branch = "octocat/12-fix-login", branches = { "main", "alpha", "dev/x", "zeta" } }, "the new branch's name, and the remote's branches to start it from: the default one first, then by name")
	local linked = requestsOf(s.gh, "linked")
	eq(#linked, 1, "gh was asked once for the linked pull requests")
	same({ linked[1].fields.o, linked[1].fields.r, linked[1].fields.n }, { "o", "r", "12" }, "of o/r#12")
	eq(countLog(s.git, "ls-remote --symref origin HEAD refs/heads/*"), 1, "and git once for the remote's branches")
	eq(snapshot(s.git), before, "nothing was made")
	eq(badgeOf(b), nil, "the row has no Worktree badge")
	-- a pull request that lost its branch is no pull request to work on
	a = hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "13", worktree = true })
	same(a, { chooseBase = true, branch = "octocat/13-add-dark-mode", branches = { "main", "alpha", "dev/x", "zeta" } }, "an issue whose only pull request lost its branch gets the same question")
	linked = requestsOf(s.gh, "linked")
	eq(#linked, 2, "gh was asked for its pull requests too")
	eq(linked[2].fields.n, "13", "by its number")
	-- the list is cut to fit the window's read
	for i = 1, 3000 do
		s.git.served["refs/heads/release/candidate-" .. string.format("%04d", i)] = sha("e")
	end
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "14", worktree = true })
	eq(a.chooseBase, true, "an issue with many branches around is asked the same")
	eq(a.branches[1], "main", "the default branch is still first")
	yes(#a.branches > 100 and #a.branches < 3000, "the list is cut, not dropped: " .. #a.branches)
	yes(#jsonEncode(a) < 64000, "to fit the window's 64000-character read")
end)

case("host: an issue with exactly one linked pull request still on its branch is worked on that branch, asking nothing", function(w: World)
	local s = issueHost(w)
	s.gh.linked["o/r#12"] = array({ hx.linkedPr(s, 45, "Fix the login redirect", "fix-login", true), hx.linkedPr(s, 40, "Old try", "old-try", false) })
	local b = openIssues(w)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.path, "/wt/plotroom-o_r-issue-12", "the worktree is in the issue's folder")
	eq(a.created, true, "created")
	eq(a.vars.branch, "fix-login", "on the pull request's own branch, not a new one")
	eq(a.summary, "Created · fix-login at ccccccc · Clean", "at the pull request's head")
	eq(#requestsOf(s.gh, "linked"), 1, "gh was asked for the linked pull requests once")
	eq(countLog(s.git, "ls-remote"), 0, "no branch was offered")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b fix-login /wt/plotroom-o_r-issue-12 " .. sha("c")), 1, "git made the worktree on that branch")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], nil, "the issue's own branch was not made")
	eq(s.git.config["branch.fix-login.remote"], "origin", "the new branch tracks the remote")
	eq(s.git.config["branch.fix-login.merge"], "refs/heads/fix-login", "and the pull request's branch there")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-45"], sha("c"), "the pull request's head was fetched into Plotroom's own ref")
	has(cardText(b), "/wt/plotroom-o_r-issue-12", "the worktree is noted: its card says where it is")
	eq(findKey(findKey(cardOf(b), "wbranch"), "v").p.spans[1].t, "fix-login", "the card shows the pull request's branch")
	-- removing it takes the pull request's fetched ref with it
	local mark = #s.git.log
	pressCard(b, "remove")
	w.flush()
	b.typeText("d")
	w.flush()
	same(logFrom(s.git, mark), {
		"worktree list --porcelain -z",
		"config --local --get-regexp ^branch\\..*\\.plotroom(key|pr|repo)$",
		"for-each-ref --format=%(objectname) %(refname) refs/plotroom-pr/o/r/pr-*",
		"worktree list --porcelain -z",
		"config --local --get-regexp ^branch\\..*\\.plotroom(key|pr|repo)$",
		"for-each-ref --format=%(objectname) %(refname) refs/plotroom-pr/o/r/pr-*",
		"worktree remove /wt/plotroom-o_r-issue-12",
		"merge-base --is-ancestor refs/heads/fix-login refs/plotroom-pr/o/r/pr-45",
		"branch -D fix-login",
		"update-ref -d refs/plotroom-pr/o/r/pr-45",
		"worktree list --porcelain -z",
	}, "the worktree, then the branch the fetched ref holds in full, then the ref, then a read of the checkout")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-45"], nil, "the ref is gone")
end)

case("host: a fork's linked pull request is never picked unasked: a same-repository one beside it is, alone it is only offered", function(w: World)
	local s = issueHost(w)
	local fork = hx.linkedPr(s, 50, "From a fork", "fork-fix", true)
	fork.fork = "zed"
	local mine = hx.linkedPr(s, 45, "Fix the login redirect", "fix-login", true)
	s.gh.linked["o/r#12"] = array({ fork, mine })
	s.gh.linked["o/r#13"] = array({ fork })
	local b = openIssues(w)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.vars.branch, "fix-login", "the single same-repository PR is picked")
	local before = snapshot(s.git)
	a = hx.ask(w, b, "b1", { op = "issue", repo = "o/r", ref = "13", worktree = true })
	eq(a.choosePr, true, "an issue whose only live PR is a fork asks")
	same(a.prs, { { number = 50, title = "From a fork", branch = "fork-fix", fork = "zed" } }, "the fork is marked with its owner")
	eq(snapshot(s.git), before, "and nothing was fetched or made")
end)

case("host: an issue with several linked pull requests asks which one, and the window's answers decide the rounds that follow", function(w: World)
	local s = issueHost(w)
	s.git.served["refs/heads/dev"] = sha("e")
	local prs = {
		hx.linkedPr(s, 45, "Fix the login redirect", "fix-login", true),
		hx.linkedPr(s, 40, "Old try", "old-try", false),
		hx.linkedPr(s, 46, "Second\ntry " .. string.rep("x", 200), "second", true),
	}
	s.gh.linked["o/r#12"] = array(prs)
	s.gh.linked["o/r#13"] = array(prs)
	local b = openIssues(w)
	local before = snapshot(s.git)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.choosePr, true, "the window is asked which pull request")
	same(a.prs, {
		{ number = 45, title = "Fix the login redirect", branch = "fix-login" },
		{ number = 46, title = "Second try " .. string.rep("x", 149) .. "…", branch = "second" },
	}, "in gh's order, without the one whose branch is gone, each title on one line and cut at 160 characters")
	eq(snapshot(s.git), before, "nothing was made")
	eq(countLog(s.git, "ls-remote"), 0, "and no branch was offered yet")
	eq(cardOf(b), nil, "nor noted: the issue has no card")
	eq(hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true }).choosePr, true, "an open question is not busy: asked again, it is the same question")
	-- the pull request picked: its branch, with no second look at the linked ones
	local looked = #requestsOf(s.gh, "linked")
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true, pr = 46 })
	eq(a.vars.branch, "second", "the worktree is on the picked pull request's branch")
	eq(a.path, "/wt/plotroom-o_r-issue-12", "in the issue's folder")
	eq(#requestsOf(s.gh, "linked"), looked, "gh was not asked about the linked pull requests again")
	-- New branch… is the picker's other answer: fresh, then the base the remote's branches offer
	a = hx.ask(w, b, "b1", { op = "issue", repo = "o/r", ref = "13", worktree = true })
	eq(a.choosePr, true, "another issue with the same pull requests is asked too")
	a = hx.ask(w, b, "b2", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true })
	same(a, { chooseBase = true, branch = "octocat/13-add-dark-mode", branches = { "main", "dev", "fix-login", "second" } }, "a new branch asks which branch to start from: the remote's, the default one first")
	eq(#requestsOf(s.gh, "linked"), looked + 1, "without asking gh about the linked pull requests again")
	eq(hx.ask(w, b, "b3", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true }).chooseBase, true, "an open question is not busy either")
	request(b, "b4", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true, base = "dev" })
	request(b, "b5", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true, base = "dev" })
	eq(answerOf(b, "b5").busy, true, "while the worktree is being made a repeat is told so")
	w.flush()
	a = answerOf(b, "b4")
	eq(a.vars.branch, "octocat/13-add-dark-mode", "the branch is the issue's own")
	eq(a.summary, "Created · octocat/13-add-dark-mode at eeeeeee · Clean", "started at the base picked")
	eq(hx.ask(w, b, "b6", { op = "issue", repo = "o/r", ref = "13", worktree = true }).created, false, "and once it exists the issue asks nothing: its worktree is reused")
end)

case("host: an issue stays busy while gh reads its linked pull requests and git the remote's branches, and is free once the question is asked", function(w: World)
	local s = issueHost(w)
	local slow = 0 -- how long gh takes to list the linked pull requests, and git the remote's branches
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" and slow > 0 then
			return { stdout = "[]", delay = slow }
		end
		return nil
	end
	local branches = "ref: refs/heads/main\tHEAD\n" .. sha("b") .. "\tHEAD\n" .. sha("b") .. "\trefs/heads/main\n"
	w.respond(function(call: Call): Reply?
		if slow > 0 and call.argv[4] == "ls-remote" then
			return { stdout = branches, delay = slow }
		end
		return nil
	end)
	local b = openIssues(w)
	slow = 4000
	request(b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	w.advance(1000)
	eq(answerOf(b, "a1"), nil, "gh is still listing the linked pull requests: nothing is answered yet")
	request(b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(answerOf(b, "a2").busy, true, "a repeat meanwhile is told the issue is busy")
	w.advance(4000)
	eq(answerOf(b, "a1"), nil, "git is now listing the remote's branches: still nothing is answered")
	request(b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(answerOf(b, "a3").busy, true, "a repeat meanwhile is busy too")
	w.advance(4000)
	same(answerOf(b, "a1"), { chooseBase = true, branch = "octocat/12-fix-login", branches = { "main" } }, "the question is asked once both reads are over")
	slow = 0
	local a = hx.ask(w, b, "a4", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.busy, nil, "with the question on screen the issue is free: a new request asks it again")
	eq(a.chooseBase, true, "and gets it")
end)

case("host: an issue worktree request that names its pull request, or a new branch's base, asks neither gh nor the remote anything", function(w: World)
	local s = issueHost(w)
	s.git.served["refs/heads/dev"] = sha("e")
	hx.linkedPr(s, 46, "Second", "second", true)
	local b = openIssues(w)
	local a = hx.ask(w, b, "p1", { op = "issue", repo = "o/r", ref = "12", worktree = true, pr = 46 })
	eq(a.vars.branch, "second", "pr: the worktree is on that pull request's branch")
	eq(a.path, "/wt/plotroom-o_r-issue-12", "in the issue's folder")
	eq(#requestsOf(s.gh, "pr"), 1, "gh was asked for that pull request")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b second /wt/plotroom-o_r-issue-12 " .. sha("c")), 1, "git made the worktree on its branch, at its head")
	eq(#requestsOf(s.gh, "linked"), 0, "it was not asked for the linked pull requests")
	eq(countLog(s.git, "ls-remote"), 0, "nor for the remote's branches")
	a = hx.ask(w, b, "f1", { op = "issue", repo = "o/r", ref = "13", worktree = true, fresh = true, base = "dev" })
	eq(a.vars.branch, "octocat/13-add-dark-mode", "fresh: the worktree is on a new branch of the issue's own")
	eq(a.summary, "Created · octocat/13-add-dark-mode at eeeeeee · Clean", "started at the base's tip, not the default branch's")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/dev:refs/remotes/origin/dev"), 1, "the base was fetched into its remote-tracking ref")
	eq(s.git.refs["refs/heads/octocat/13-add-dark-mode"], sha("e"), "the branch starts there")
	eq(#requestsOf(s.gh, "linked"), 0, "gh was still not asked for the linked pull requests")
	eq(countLog(s.git, "ls-remote"), 0, "nor git for the remote's branches")
	-- a base the remote does not have makes nothing
	local before = snapshot(s.git)
	a = hx.ask(w, b, "f2", { op = "issue", repo = "o/r", ref = "14", worktree = true, fresh = true, base = "nope" })
	has(a.problem, "nope", "the answer names the base")
	eq(snapshot(s.git), before, "no branch or worktree was made")
	eq(hx.ask(w, b, "w14", { op = "where", kind = "issue", key = "o/r#14" }).path, nil, "and none is noted")
end)

case("host: an issue whose worktree exists is reused whatever else the request says: no question, no pull request read", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	eq(hx.ask(w, b, "a1", freshAsk("o/r", "12")).created, true, "the worktree is made")
	-- pull requests that would ask a question if there were no worktree
	s.gh.linked["o/r#12"] = array({ hx.linkedPr(s, 45, "Fix the login redirect", "fix-login", true), hx.linkedPr(s, 46, "Second", "second", true) })
	local mark = #w.calls
	local a = hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.created, false, "the worktree is reused")
	eq(a.summary, "Reused · octocat/12-fix-login at bbbbbbb · Clean", "and the answer says so")
	eq(a.vars.branch, "octocat/12-fix-login", "on the branch it has")
	eq(a.choosePr, nil, "no pull request is asked for")
	eq(#requestsOf(s.gh, "linked"), 0, "gh was not asked for the linked pull requests")
	eq(countLog(s.git, "ls-remote"), 0, "nor git for the remote's branches")
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true, pr = 46 })
	eq(a.created, false, "a pull request named in the request does not move it")
	eq(a.vars.branch, "octocat/12-fix-login", "it stays on its branch")
	eq(#requestsOf(s.gh, "pr"), 0, "and the pull request was not read")
	a = hx.ask(w, b, "a4", { op = "issue", repo = "o/r", ref = "12", worktree = true, fresh = true, base = "dev" })
	eq(a.created, false, "nor does a base")
	eq(countLog(s.git, "worktree add"), 1, "the worktree was made once")
	for _, line in ranSince(w, mark) do
		lacks(line, "gh api", "gh was not asked anything: " .. line)
		lacks(line, "fetch", "nothing was fetched: " .. line)
	end
end)

case("host: an issue worktree request whose linked pull requests cannot be read says so, makes nothing and leaves the issue free for a retry", function(w: World)
	local s = issueHost(w)
	local failing = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" and failing then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local before = snapshot(s.git)
	local a = hx.ask(w, b, "a1", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	has(a.problem, "The pull requests linked to #12 could not be read: ", "the answer says what failed")
	has(a.problem, "Server Error (HTTP 502)", "with gh's reason")
	eq(snapshot(s.git), before, "no branch or worktree was made")
	eq(cardOf(b), nil, "none is noted: the issue has no card")
	eq(countLog(s.git, "ls-remote"), 0, "and no branch was offered")
	a = hx.ask(w, b, "a2", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.busy, nil, "the failed request left the issue free for the next one")
	has(a.problem, "could not be read", "which is refused for the same reason")
	eq(#requestsOf(s.gh, "linked"), 2, "after asking gh again")
	failing = false
	a = hx.ask(w, b, "a3", { op = "issue", repo = "o/r", ref = "12", worktree = true })
	eq(a.chooseBase, true, "once gh answers, the question is asked")
end)

case("host: a Jira issue's linked pull requests are those a search for its key finds, and the choices work as for a GitHub issue", function(w: World)
	local s = jiraHost(w)
	local acliItems = s.acli.searches[JIRA_ASSIGNED]
	table.insert(acliItems, jiraItem("ABC-14", "Third thing"))
	-- ABC-12 is only named by ABC-123's pull request; ABC-13 has its own and ABC-130's; ABC-14 has two
	s.gh.linked["o/r#ABC-12"] = array({ hx.linkedPr(s, 50, "ABC-123 another thing", "abc-123-other", true) })
	s.gh.linked["o/r#ABC-13"] = array({
		hx.linkedPr(s, 51, "ABC-13 fix the bug", "abc-13-fix", true),
		hx.linkedPr(s, 52, "ABC-130 something else", "abc-130-else", true),
	})
	s.gh.linked["o/r#ABC-14"] = array({
		hx.linkedPr(s, 53, "ABC-14 first try", "abc-14-first", true),
		hx.linkedPr(s, 54, "[ABC-14] second try", "abc-14-second", true),
	})
	local b = openIssues(w)
	local a = hx.ask(w, b, "j1", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true })
	eq(a.chooseBase, true, "a key that only a longer key's pull request names has none: a new branch is asked for")
	eq(a.branch, "octocat/ABC-12-fix-login", "named from the gh login, the key and the title's slug")
	local linked = requestsOf(s.gh, "linked")
	eq(#linked, 1, "gh was asked once")
	eq(linked[1].fields.q, "repo:o/r is:pr ABC-12", "to search the repository's pull requests for the key")
	eq(linked[1].fields.o, nil, "not for an issue's closing references")
	a = hx.ask(w, b, "j2", { op = "issue", repo = "ABC", ref = "ABC-13", worktree = true })
	eq(a.vars.branch, "abc-13-fix", "the one pull request that names the key is worked on, asking nothing")
	eq(a.path, "/wt/plotroom-o_r-issue-ABC-13", "in the issue's folder")
	eq(s.git.refs["refs/heads/abc-13-fix"], sha("c"), "on its branch")
	request(b, "w1", { op = "where", kind = "issue", key = "abc#ABC-13" })
	eq(answerOf(b, "w1").path, "/wt/plotroom-o_r-issue-ABC-13", "the worktree is noted under the project's lowercase key")
	a = hx.ask(w, b, "j3", { op = "issue", repo = "ABC", ref = "ABC-14", worktree = true })
	same(a.prs, {
		{ number = 53, title = "ABC-14 first try", branch = "abc-14-first" },
		{ number = 54, title = "[ABC-14] second try", branch = "abc-14-second" },
	}, "two pull requests are asked about")
	eq(hx.ask(w, b, "j4", { op = "issue", repo = "ABC", ref = "ABC-14", worktree = true, pr = 54 }).vars.branch, "abc-14-second", "the one picked decides")
	eq(#requestsOf(s.gh, "linked"), 3, "a request that names its pull request searches no more")
	a = hx.ask(w, b, "j5", { op = "issue", repo = "ABC", ref = "ABC-12", worktree = true, fresh = true, base = "main" })
	eq(a.vars.branch, "octocat/ABC-12-fix-login", "a request that names its base makes the issue's own branch")
	eq(#requestsOf(s.gh, "linked"), 3, "without a search either")
end)

case("host: an issue request with a pull request or base it cannot use is dropped, and one with a fresh or users that is no boolean has them ignored", function(w: World)
	local s = issueHost(w)
	local b = openIssues(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, extra: { [string]: any })
		local body: { [string]: any } = { id = "m1", op = "issue", repo = "o/r", ref = "12", worktree = true }
		for k, v in extra do
			body[k] = v
		end
		b.event({ ev = "action", act = "rpc", value = jsonEncode(body) })
		w.flush()
		eq(answerOf(b, "m1"), nil, what .. ": no answer is kept")
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	local prs: { any } = { 0, -1, 1.5, "7", 2147483648, true }
	for _, pr in prs do
		ignored("the pull request " .. show(pr), { pr = pr })
	end
	local bases: { any } = { "-x", "a b", "a\nb", "a\tb", string.rep("a", 256), 5, true }
	for _, base in bases do
		ignored("the base " .. show(base), { fresh = true, base = base })
	end
	-- the largest ones that are fine
	local a = hx.ask(w, b, "k1", { op = "issue", repo = "o/r", ref = "12", worktree = false, pr = 2147483647, base = string.rep("a", 255) })
	eq(a.path, "/work/r", "a pull request number of 2147483647 and a base of 255 bytes are answered")
	-- a fresh that is not true is no fresh, a users that is not true asks for no users
	a = hx.ask(w, b, "k2", { op = "issue", repo = "o/r", ref = "12", worktree = true, fresh = "yes", base = "main" })
	eq(a.chooseBase, true, "fresh = \"yes\" is no fresh: the linked pull requests decide, and with none a base is asked for")
	eq(#requestsOf(s.gh, "linked"), 1, "gh was asked for them")
	a = hx.ask(w, b, "k3", { op = "issue", repo = "o/r", ref = "12", worktree = false, users = "yes" })
	eq(a.path, "/work/r", "the main checkout is answered")
	eq(a.vars["github.user"], nil, "users = \"yes\" asks for no login")
end)

case("host: where answers the worktree a block knows for a pull request or an issue, from its own attempt or from git, until the worktree is removed", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	local other = openQueue(w, 3)
	local asked = 0
	-- The folder block `b` says the worktree of item `key` of `kind` is in; nil when it knows none.
	local function where(b: Block, kind: string, key: string): string?
		asked += 1
		request(b, "w" .. asked, { op = "where", kind = kind, key = key })
		local a = answerOf(b, "w" .. asked)
		yes(a ~= nil, "where was answered")
		return a.path
	end
	eq(where(prs, "pr", "o/r#1"), nil, "a pull request with no worktree has no path")
	eq(where(issues, "issue", "o/r#12"), nil, "nor does an issue")
	eq(hx.ask(w, prs, "p1", { op = "worktree", repo = "o/r", number = 1 }).path, "/wt/plotroom-o_r-pr-1", "a pull request's worktree is made")
	eq(where(prs, "pr", "o/r#1"), "/wt/plotroom-o_r-pr-1", "its block says where it is")
	eq(where(other, "pr", "o/r#1"), nil, "another block of the host has not heard of it")
	refreshNow(w, other)
	eq(where(other, "pr", "o/r#1"), "/wt/plotroom-o_r-pr-1", "until its next refresh reads the checkout from git")
	eq(hx.ask(w, issues, "i1", freshAsk("o/r", "12")).path, "/wt/plotroom-o_r-issue-12", "an issue's worktree is made")
	eq(where(issues, "issue", "o/r#12"), "/wt/plotroom-o_r-issue-12", "its block says where it is")
	eq(where(prs, "pr", "o/r#7"), nil, "an item with none has no path, whoever asks")
	-- removing a worktree forgets it, for every block
	showPr(prs, 1)
	pressCard(prs, "remove")
	prs.typeText("d")
	w.flush()
	eq(where(prs, "pr", "o/r#1"), nil, "a removed pull request worktree has no path")
	eq(where(other, "pr", "o/r#1"), nil, "for another block too")
	eq(where(issues, "issue", "o/r#12"), "/wt/plotroom-o_r-issue-12", "the issue's is still there")
	pressCard(issues, "remove")
	issues.typeText("d")
	w.flush()
	eq(where(issues, "issue", "o/r#12"), nil, "until it is removed too")
end)

case("host: a where request with a kind or key it cannot use is dropped", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	local ran, told = #w.calls, #w.opened
	local function ignored(what: string, body: { [string]: any })
		body.id, body.op = "m1", "where"
		b.event({ ev = "action", act = "rpc", value = jsonEncode(body) })
		w.flush()
		eq(answerOf(b, "m1"), nil, what .. ": no answer is kept")
		eq(#w.calls, ran, what .. ": nothing was run")
		eq(#w.opened, told, what .. ": and the window was told nothing")
	end
	ignored("a kind that is neither", { kind = "commit", key = "o/r#12" })
	ignored("no kind", { key = "o/r#12" })
	ignored("a key that is no text", { kind = "pr", key = 5 })
	ignored("a key over 200 bytes", { kind = "pr", key = string.rep("k", 201) })
	request(b, "k1", { op = "where", kind = "pr", key = string.rep("k", 200) })
	eq(answerOf(b, "k1").path, nil, "a key of 200 bytes is answered")
end)

case("host: the In tab badge follows the panes working in a worktree the block knows, whatever its folder is called, and marks no other row", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60), searchItem(2, "o/r", EPOCH - 120), searchItem(12, "o/r", EPOCH - 180) }
	s.gh.issueItems.octocat = { issueItem(2, "o/r", EPOCH - 60, { title = "Second" }), issueItem(12, "o/r", EPOCH - 120, { title = "Fix login" }) }
	s.git.served["refs/pull/2/head"] = sha("b")
	s.gh.meta["o/r#2"] = { base = "o/r", sha = sha("b"), ref = "second", headRepo = "o/r", headOwner = "o", state = "open", title = "Second" }
	-- Worktrees git lists: PRs 1 and 12 in their folders, and issue 2 in a folder of its own, on the branch the format names
	-- (it names no user, so the block needs no sign-in to know it).
	w.kv.put("branch-format", "{key}-{slug}")
	leaveWt(w, s, 1)
	leaveWt(w, s, 12)
	table.insert(s.git.worktrees, { path = "/wt/custom-name", branch = "refs/heads/2-second", head = sha("b"), locked = false })
	w.fs.dirs["/wt/custom-name"] = true
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	-- Puts a pane working in `cwd` on the host, draws both panes and says which rows wear In tab: the PRs', then the issues'.
	local nextPane = 8
	local function working(cwd: string): { { string } }
		nextPane += 1
		table.insert(w.panes, { pane = nextPane, cwd = cwd })
		prs.render()
		issues.render()
		return { hx.inTab(prs), hx.inTab(issues) }
	end
	prs.render()
	issues.render()
	same({ hx.inTab(prs), hx.inTab(issues) }, { {}, {} }, "no pane in a worktree, no badge")
	same(working("/wt/plotroom-o_r-pr-12/src"), { { "no_2fr_2312" }, {} }, "a pane in a folder of pull request 12's worktree marks it; not 1, whose folder's name starts the same, nor issue 12")
	same(working("/wt/custom-name"), { { "no_2fr_2312" }, { "no_2fr_232" } }, "a pane in issue 2's worktree marks the issue whatever the folder is called; not pull request 2")
	same(working("/wt/plotroom-o_r-pr-1"), { { "no_2fr_231", "no_2fr_2312" }, { "no_2fr_232" } }, "a pane in the worktree itself marks it")
	same(working("/work/r"), { { "no_2fr_231", "no_2fr_2312" }, { "no_2fr_232" } }, "a pane elsewhere marks nothing")
	for _ = 1, 4 do
		table.remove(w.panes)
	end
	prs.render()
	issues.render()
	same({ hx.inTab(prs), hx.inTab(issues) }, { {}, {} }, "with the panes gone, so are the badges")
	-- a worktree made now is found by its noted folder, however the formats named it
	w.kv.put("pr-dir-format", "p{key}")
	w.kv.put("issue-dir-format", "i{key}-{slug}")
	eq(hx.ask(w, prs, "p2", { op = "worktree", repo = "o/r", number = 2 }).path, "/wt/p2", "a pull request's folder is named by its format")
	eq(hx.ask(w, issues, "i12", freshAsk("o/r", "12")).path, "/wt/i12-fix-login", "an issue's too")
	same(working("/wt/p2/src"), { { "no_2fr_232" }, {} }, "a pane in the pull request's folder marks it")
	same(working("/wt/i12-fix-login"), { { "no_2fr_232" }, { "no_2fr_2312" } }, "and one in the issue's marks the issue")
end)

case("host: a worktree noted for a pull request that left the list is still known, by its own branch and folder, until git no longer lists it", function(w: World)
	local s = hostScene(w, 2)
	s.git.served["refs/pull/1/head"] = sha("b")
	s.gh.meta["o/r#1"] = { base = "o/r", sha = sha("b"), ref = "feature", headRepo = "o/r", headOwner = "o", state = "open" }
	local b = openQueue(w)
	local asked = 0
	local function where(): string?
		asked += 1
		return hx.ask(w, b, "w" .. asked, { op = "where", kind = "pr", key = "o/r#1" }).path
	end
	eq(hx.ask(w, b, "p1", { op = "worktree", repo = "o/r", number = 1 }).path, "/wt/plotroom-o_r-pr-1", "a pull request's worktree is made")
	-- pull request 1 is merged: the next refresh lists pull request 2 only
	s.gh.items.octocat = { s.gh.items.octocat[2] }
	refreshNow(w, b)
	eq(#listed(b), 1, "the list holds one pull request now")
	eq(where(), "/wt/plotroom-o_r-pr-1", "the one that left is still known: git lists its worktree on the branch and in the folder the note says")
	table.remove(s.git.worktrees, 2)
	w.fs.dirs["/wt/plotroom-o_r-pr-1"] = nil
	refreshNow(w, b)
	eq(where(), nil, "until git no longer lists it")
end)

case("host: after a format changes, the block that made an issue's worktree still knows it by the branch and folder it noted, and a block that did not cannot", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	eq(hx.ask(w, b, "i1", freshAsk("o/r", "12")).path, "/wt/plotroom-o_r-issue-12", "an issue's worktree is made under the default formats")
	yes(cardOf(b) ~= nil, "its card shows")
	w.kv.put("branch-format", "{key}")
	w.kv.put("issue-dir-format", "i{key}")
	refreshNow(w, b)
	has(cardText(b), "/wt/plotroom-o_r-issue-12", "neither format names it now, and it is still known: by what its note says it was made on")
	local fresh = openIssues(w, 2)
	eq(cardOf(fresh), nil, "a block with no note of it cannot tell it from any other worktree")
end)

case("host: the issue preview's Branch row shows the real branch as soon as gh names its login, and the format's variable as written until then", function(w: World)
	local s = issueHost(w)
	local signedIn = false
	s.gh.override = function(req: GhReq): Reply?
		return if req.kind == "accounts" and not signedIn then { status = 1, stderr = "gh: not logged in\n" } else nil
	end
	local b = openIssues(w)
	eq(hx.branchRow(b), "{github.user}/12-fix-login", "gh named no login: the format's variable shows as written")
	signedIn = true
	hx.ask(w, b, "m1", { op = "issue", repo = "o/r", ref = "12", worktree = false, users = true })
	eq(hx.branchRow(b), "octocat/12-fix-login", "once gh named it the row shows the branch a worktree would make")
	w.kv.put("branch-formats", { ["o/r"] = "feat/{github.user}-{key}" })
	b.render()
	eq(hx.branchRow(b), "feat/octocat-12", "the repository's own format shows through, and wins")
	w.kv.put("branch-formats", { ["o/r"] = "{key}-{slug}" })
	b.render()
	eq(hx.branchRow(b), "12-fix-login", "whatever it names")
	w.kv.put("branch-formats", {})
	w.kv.put("branch-format", "{owner}/{repo}/{key}")
	b.render()
	eq(hx.branchRow(b), "o/r/12", "without one the Worktrees format shows")
	w.kv.put("branch-format", "{foo}")
	b.render()
	eq(hx.branchRow(b), nil, "a format that cannot name a branch shows none")
end)

case("host: a Jira issue's preview fills {jira.user} from the sign-in its search read and {github.user} from gh's active login", function(w: World)
	jiraHost(w)
	w.kv.put("branch-format", "{jira.user}/{github.user}/{key}")
	local b = openIssues(w)
	eq(hx.branchRow(b), "ann/octocat/ABC-12", "both users are known once the list loaded")
end)

case("host: the saved folder formats name the folders of pull request and issue worktrees, and a format that renders no usable folder says so", function(w: World)
	local s = issueHost(w)
	s.gh.items.octocat = manyItems("o/r", 2)
	table.insert(s.gh.issueItems.octocat, issueItem(16, "o/r", EPOCH - 300, { title = string.rep("word ", 30) }))
	for n = 1, 2 do
		s.git.served["refs/pull/" .. n .. "/head"] = sha("b")
		s.gh.meta["o/r#" .. n] = { base = "o/r", sha = sha("b"), ref = "feature-" .. n, headRepo = "o/r", headOwner = "o", state = "open", title = if n == 1 then "Add a feature" else string.rep("word ", 30) }
	end
	w.kv.put("pr-dir-format", "{owner}-{repo}-p{key}-{slug}")
	w.kv.put("issue-dir-format", "i{key}-{slug}")
	local issues = openIssues(w, 1)
	local prs = openQueue(w, 2)
	local a = hx.ask(w, prs, "p1", { op = "worktree", repo = "o/r", number = 1 })
	eq(a.path, "/wt/o-r-p1-add-a-feature", "a pull request's folder is named by its format: owner, repository, number and the title's slug")
	a = hx.ask(w, issues, "i1", freshAsk("o/r", "12"))
	eq(a.path, "/wt/i12-fix-login", "an issue's by its own: the key and the title's slug")
	eq(hx.ask(w, prs, "p2", { op = "worktree", repo = "o/r", number = 1 }).created, false, "the folder is found again by that name")
	eq(hx.ask(w, issues, "i2", freshAsk("o/r", "12")).created, false, "so is the issue's")
	-- a title long enough to make the format render a name no folder can have
	local tooLong = string.rep("{slug}", 6) .. "-{key}"
	w.kv.put("pr-dir-format", tooLong)
	w.kv.put("issue-dir-format", tooLong)
	local before = snapshot(s.git)
	a = hx.ask(w, prs, "p3", { op = "worktree", repo = "o/r", number = 2 })
	has(a.problem, "is not usable; change its format in Settings › Worktrees.", "a pull request's name is refused with the way to fix it")
	a = hx.ask(w, issues, "i3", freshAsk("o/r", "16"))
	has(a.problem, "is not usable; change its format in Settings › Worktrees.", "so is an issue's")
	eq(snapshot(s.git), before, "no branch or worktree was made")
end)

-- ---- window.luau: the questions of a new issue worktree, the users a prompt names, Go to tab

windowCase("window: Worktree on an issue with no linked PR asks for the base branch", function(w: World)
	local s, b = issueWindow(w)
	s.git.served["refs/heads/alpha"] = sha("a")
	s.git.served["refs/heads/develop"] = sha("c")
	local target = "/wt/plotroom-o_r-issue-12"
	local before = snapshot(s.git)
	-- dismissed: the question is the whole answer
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(#w.window.picks, 1, "no pull request is linked: one question")
	eq(w.window.picks[1].placeholder, "Start octocat/12-fix-login from…", "it names the new branch, the gh login in it")
	same(asks.rows(w.window.picks[1]), { "main @ Default branch", "alpha @ Branches", "develop @ Branches" }, "the remote's default branch leads, alone in its group, the others follow in the host's order")
	same(asks.sent(w), { asks.issue("o/r", "12") }, "nothing was decided: the request carries no PR, no new branch, no base")
	eq(#w.toasts, 1, "the user was told once")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "that the worktree is being prepared")
	eq(snapshot(s.git), before, "no ref, worktree or config was made")
	eq(#w.window.launches, 0, "no tab opened")
	eq(cardOf(b), nil, "and the block noted no worktree")
	-- picked: the request is repeated with the new branch and its base
	w.window.choose = "develop"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	local fresh = asks.issue("o/r", "12", { fresh = true, base = "develop" })
	same(asks.sent(w), { asks.issue("o/r", "12"), asks.issue("o/r", "12"), fresh }, "the dismissed question sent nothing more; the pick is a new branch from it")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 2, "the user is told once per click, not again when the host asks the second question")
	eq(#w.toasts, 3, "and the worktree toast is the only other")
	eq(w.toasts[3].level, "success", "it is a success")
	eq(w.toasts[3].text, "Worktree ready for o/r#12", "naming the issue")
	eq(w.toasts[3].sub, "Created · octocat/12-fix-login at ccccccc · Clean", "the new branch starts at the pick, not at the default branch")
	eq(#w.window.picks, 2, "one question per click")
	eq(#w.window.launches, 1, "one tab opened")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree")
	eq(countLog(s.git, "ls-remote --symref origin HEAD refs/heads/*"), 2, "the remote's branches were listed once per click, not again for the answer")
	eq(countLog(s.git, "fetch"), 1, "one fetch")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/develop:refs/remotes/origin/develop"), 1, "of the base picked, into its remote-tracking ref")
	eq(s.git.refs["refs/remotes/origin/develop"], sha("c"), "which now holds it")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("c"), "the new branch is made there")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b octocat/12-fix-login " .. target .. " " .. sha("c")), 1, "and the worktree added through omp at that commit")
	eq(countLog(s.git, "config"), 0, "a new branch gets no upstream: the first push sets it")
	eq(#requestsOf(s.gh, "linked"), 2, "the linked pull requests were read once per click: the pick's request does not look again")
end)

windowCase("window: Worktree on an issue with several linked PRs asks which", function(w: World)
	local s, b = asks.several(w)
	local target = "/wt/plotroom-o_r-issue-12"
	local before = snapshot(s.git)
	-- dismissed: the question is the whole answer
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(#w.window.picks, 1, "two linked pull requests have their branch: one question")
	eq(w.window.picks[1].placeholder, "Which branch for o/r#12?", "it names the issue")
	same(asks.rows(w.window.picks[1]), {
		"#7 Fix login — fix-login @ Linked pull requests",
		"#9 Fix login on mobile — fix-login-mobile @ Linked pull requests",
		"New branch… — Starts from a base branch you pick next @ Or",
	}, "each pull request that still has its branch, with the branch; one whose branch is gone is not offered; then a new branch")
	same(asks.sent(w), { asks.issue("o/r", "12") }, "nothing was decided: the request carries no PR, no new branch, no base")
	eq(#w.toasts, 1, "the user was told once")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "that the worktree is being prepared")
	eq(snapshot(s.git), before, "no ref, worktree or config was made")
	eq(#w.window.launches, 0, "no tab opened")
	eq(cardOf(b), nil, "and the block noted no worktree")
	-- picked: the request is repeated with the pull request, and only with it
	w.window.choose = "#9 Fix login on mobile"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	same(asks.sent(w), { asks.issue("o/r", "12"), asks.issue("o/r", "12"), asks.issue("o/r", "12", { pr = 9 }) }, "the dismissed question sent nothing more; the pick names its pull request, no new branch or base")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 2, "the user is told once per click, not again when the host asks the question")
	eq(#w.toasts, 3, "and the worktree toast is the only other")
	eq(w.toasts[3].level, "success", "it is a success")
	eq(w.toasts[3].text, "Worktree ready for o/r#12", "naming the issue")
	eq(w.toasts[3].sub, "Created · fix-login-mobile at ddddddd · Clean", "on the pull request's own branch, at its head")
	eq(#w.window.picks, 2, "one question per click: the pick ended them")
	eq(#w.window.launches, 1, "one tab opened")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree, not a folder named for the pull request")
	eq(s.git.refs["refs/heads/fix-login-mobile"], sha("d"), "the branch is the pick's")
	eq(s.git.refs["refs/heads/fix-login"], nil, "not the other pull request's")
	eq(s.git.config["branch.fix-login-mobile.remote"], "origin", "its upstream is set to the remote")
	eq(s.git.config["branch.fix-login-mobile.merge"], "refs/heads/fix-login-mobile", "and to the head branch")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b fix-login-mobile " .. target .. " " .. sha("d")), 1, "the worktree was added through omp at the pull request's head")
	eq(countLog(s.git, "ls-remote"), 0, "no base branch was asked for")
	eq(#requestsOf(s.gh, "linked"), 2, "the linked pull requests were read once per click")
end)

windowCase("window: Worktree on an issue with several linked PRs and a new branch asks for the base next", function(w: World)
	local s = asks.several(w)
	s.git.served["refs/heads/develop"] = sha("e")
	local target = "/wt/plotroom-o_r-issue-12"
	w.window.choose = { "New branch…", "develop" }
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	same(asks.sent(w), {
		asks.issue("o/r", "12"),
		asks.issue("o/r", "12", { fresh = true }),
		asks.issue("o/r", "12", { fresh = true, base = "develop" }),
	}, "a new branch is asked for with no pull request; the base pick adds to it, not replaces it")
	eq(#w.window.picks, 2, "the pull request question, then the base")
	eq(w.window.picks[2].placeholder, "Start octocat/12-fix-login from…", "which names the new branch, not a pull request's")
	same(asks.rows(w.window.picks[2]), { "main @ Default branch", "develop @ Branches", "fix-login @ Branches", "fix-login-mobile @ Branches" }, "the base question lists the remote's branches, its default first")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 1, "the user was told once")
	eq(w.toasts[#w.toasts].text, "Worktree ready for o/r#12", "then the worktree is ready")
	eq(w.toasts[#w.toasts].sub, "Created · octocat/12-fix-login at eeeeeee · Clean", "on the issue's own branch, at the base")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree")
	eq(s.git.refs["refs/heads/octocat/12-fix-login"], sha("e"), "the new branch starts at the base")
	eq(s.git.refs["refs/heads/fix-login"], nil, "no pull request's branch was made")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/develop:refs/remotes/origin/develop"), 1, "only the base was fetched")
	eq(countLog(s.git, "fetch"), 1, "and no pull request head")
	eq(countLog(s.git, "config"), 0, "a new branch gets no upstream")
end)

windowCase("window: Worktree on an issue with exactly one linked PR needs no question", function(w: World)
	local s, b = issueWindow(w)
	-- a second pull request, whose branch is gone, does not count
	s.gh.linked["o/r#12"] = array({
		{ number = 3, title = "First try", head = "old-try", branch = NULL, base = "o/r" },
		asks.pr(s, 7, "Fix login", "fix-login", "c"),
	})
	local target = "/wt/plotroom-o_r-issue-12"
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(#w.window.picks, 0, "nothing is asked")
	same(asks.sent(w), { asks.issue("o/r", "12") }, "one request: the host's second look, at the one pull request, is its own")
	eq(#requestsOf(s.gh, "linked"), 1, "the host read the linked pull requests")
	eq(#w.toasts, 2, "two toasts")
	eq(w.toasts[1].text, "Preparing worktree for o/r#12", "the worktree is being prepared")
	eq(w.toasts[2].level, "success", "then it is ready")
	eq(w.toasts[2].text, "Worktree ready for o/r#12", "naming the issue")
	eq(w.toasts[2].sub, "Created · fix-login at ccccccc · Clean", "on the pull request's branch, at its head")
	eq(#w.window.launches, 1, "one tab opened")
	eq(w.window.launches[1].cwd, target, "in the issue's worktree")
	eq(s.git.refs["refs/heads/fix-login"], sha("c"), "the branch is the pull request's")
	eq(s.git.config["branch.fix-login.remote"], "origin", "its upstream is set to the remote")
	eq(s.git.config["branch.fix-login.merge"], "refs/heads/fix-login", "and to the head branch")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b fix-login " .. target .. " " .. sha("c")), 1, "the worktree was added through omp at the pull request's head")
	eq(countLog(s.git, "ls-remote"), 0, "no base branch was listed")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	has(cardText(b), target, "and the card says where the worktree is")
end)

windowCase("window: an answer to the pull request or base question that arrives without a window context asks nothing more", function(w: World)
	local s, b = asks.several(w)
	w.window.decide = function(opts: any): (string?, boolean?)
		return (if string.find(opts.placeholder, "^Start ") then "main" else "#7 Fix login"), true
	end
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	showPr(b, 13)
	cardSurface(w, b)
	w.click(issueLink("worktree", "o/r", "13"))
	w.flush()
	same(asks.rows(w.window.picks[1])[1], "#7 Fix login — fix-login @ Linked pull requests", "the pull request question was asked")
	eq(w.window.picks[2].placeholder, "Start octocat/13-add-dark-mode from…", "and the base question")
	eq(#asks.sent(w), 2, "answered without a context, neither sent a request")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made")
	eq(#w.toasts, 2, "and nothing was said beyond the two starts")
	eq(#w.window.launches, 0, "no tab opened")
end)

windowCase("window: a Jira issue's decisions after its repository is picked carry that repository and every answer settled before", function(w: World)
	local s, b = jiraWindow(w)
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }) })
	s.git.served["refs/heads/develop"] = sha("e")
	s.gh.linked["o/r#ABC-12"] = array({
		asks.pr(s, 7, "ABC-12 Fix login", "abc-12-fix-login", "c"),
		asks.pr(s, 9, "ABC-12: mobile", "abc-12-mobile", "d"),
	})
	s.gh.linked["o/r#ABC-13"] = array({
		asks.pr(s, 8, "ABC-13 Old bug", "abc-13-old-bug", "f"),
		asks.pr(s, 6, "ABC-13: another", "abc-13-another", "a"),
	})
	local function placeholders(): { string }
		local out: { string } = {}
		for _, pick in w.window.picks do
			table.insert(out, pick.placeholder)
		end
		return out
	end
	-- a new branch: the repository, a new branch among the linked pull requests, the base
	w.window.choose = { "o/r", "New branch…", "develop" }
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	same(placeholders(), { "Which repository for ABC-12?", "Which branch for ABC-12?", "Start octocat/ABC-12-fix-login from…" }, "three questions, in that order")
	local chosen: { [string]: any } = { target = "o/r" }
	same(asks.sent(w), {
		asks.issue("ABC", "ABC-12"),
		asks.issue("ABC", "ABC-12", chosen),
		asks.issue("ABC", "ABC-12", { target = "o/r", fresh = true }),
		asks.issue("ABC", "ABC-12", { target = "o/r", fresh = true, base = "develop" }),
	}, "every repeat names the repository, and the base's keeps the new branch asked before it")
	eq(asks.toasted(w, "Preparing worktree for ABC-12"), 1, "the user was told once")
	eq(w.toasts[#w.toasts].sub, "Created · octocat/ABC-12-fix-login at eeeeeee · Clean", "the new branch starts at the base")
	eq(w.window.launches[1].cwd, "/wt/plotroom-o_r-issue-ABC-12", "in the worktree of the repository picked")
	eq(s.git.refs["refs/heads/octocat/ABC-12-fix-login"], sha("e"), "made from it")
	-- a linked pull request: the repository, then the pull request
	b.event({ ev = "select", id = "layer.queue", item = "nabc_23ABC-13" })
	cardSurface(w, b)
	local asked = #asks.sent(w)
	w.window.choose = { "o/r", "#8 ABC-13 Old bug" }
	w.click(issueLink("worktree", "ABC", "ABC-13"))
	w.flush()
	same({ table.unpack(asks.sent(w), asked + 1) }, {
		asks.issue("ABC", "ABC-13"),
		asks.issue("ABC", "ABC-13", chosen),
		asks.issue("ABC", "ABC-13", { target = "o/r", pr = 8 }),
	}, "the pull request is added to the repository, with no new branch or base")
	same(placeholders(), {
		"Which repository for ABC-12?",
		"Which branch for ABC-12?",
		"Start octocat/ABC-12-fix-login from…",
		"Which repository for ABC-13?",
		"Which branch for ABC-13?",
	}, "two questions for the second issue: no base")
	eq(w.toasts[#w.toasts].sub, "Created · abc-13-old-bug at fffffff · Clean", "on the pull request's branch")
	eq(w.window.launches[2].cwd, "/wt/plotroom-o_r-issue-ABC-13", "in the issue's worktree")
	eq(s.git.config["branch.abc-13-old-bug.merge"], "refs/heads/abc-13-old-bug", "with its upstream")
	same(w.kv.get("jira-repos").ABC, { "o/r", "x/y" }, "choosing among several saves nothing")
end)

windowCase("window: a Jira issue's repository without a checkout asks for its folder, keeps the repository picked, then asks the base", function(w: World)
	local s = jiraWindow(w)
	w.kv.put("jira-repos", { ABC = array({ "o/r", "x/y" }) })
	-- x/y is a repository the block has no checkout of yet
	local g = newGit(w, "/work/y")
	g.remotes.origin = { "https://github.com/x/y.git" }
	g.served["refs/heads/main"] = sha("b")
	g.defaultBranch = "main"
	w.window.choose = { "x/y", "main" }
	w.window.typed = "/work/y"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	same(asks.sent(w), {
		asks.issue("ABC", "ABC-12"),
		asks.issue("ABC", "ABC-12", { target = "x/y" }),
		{ op = "checkout", repo = "x/y", path = "/work/y" },
		asks.issue("ABC", "ABC-12", { target = "x/y" }),
		asks.issue("ABC", "ABC-12", { target = "x/y", fresh = true, base = "main" }),
	}, "the repository picked is asked for again once its folder is saved, and the base's request keeps it")
	eq(w.kv.get("checkouts")["x/y"], "/work/y", "the folder is saved for the repository")
	eq(asks.toasted(w, "Preparing worktree for ABC-12"), 1, "the user was told once")
	eq(#w.window.picks, 2, "the repository, then the base: the folder was asked by typing")
	eq(w.toasts[#w.toasts].sub, "Created · octocat/ABC-12-fix-login at bbbbbbb · Clean", "the worktree is made")
	eq(w.window.launches[1].cwd, "/wt/plotroom-x_y-issue-ABC-12", "in the repository picked, not the project's first")
	eq(countLog(g, "worktree add"), 1, "by the new checkout")
	eq(countLog(s.git, "worktree add"), 0, "and not by the other")
end)

windowCase("window: Worktree asked again once its checkout was given does not announce the preparation twice", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	linkQueue(w, s)
	w.kv.put("checkouts", {})
	w.window.typed = "/work/r"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	local ops: { string } = {}
	for _, q in asks.sent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "worktree", "checkout", "worktree" }, "the worktree is asked for again once the checkout is saved")
	eq(asks.toasted(w, "Preparing worktree for o/r#5"), 1, "the user was told once")
	eq(w.toasts[#w.toasts].level, "success", "and the worktree came")
end)

windowCase("window: {github.user} in a pull request prompt is filled with the gh login", function(w: World)
	local s, b = agentScene(w)
	savePrompts(w, {
		promptOf("p1", "Plain", "Review {url}"),
		promptOf("p2", "Mine", "Review {url} as {github.user}; {nope} {no.such}"),
	})
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(requestsSent(w)[2].op, "worktree", "the prompt's worktree is asked for")
	eq(requestsSent(w)[2].users, false, "a prompt that names no user does not ask for them")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5", "and runs as written")
	w.click(runLink("o/r", 5, "p2"))
	w.flush()
	local sent = requestsSent(w)
	eq(sent[4].op, "worktree", "the next prompt's worktree is asked for")
	eq(sent[4].users, true, "a prompt that names {github.user} asks for the users")
	eq(#w.window.agents, 2, "an agent started for each")
	eq(w.window.agents[2].prompt, "Review https://github.com/o/r/pull/5 as octocat; {nope} {no.such}", "{github.user} is the login gh is signed in as; unknown variables, dotted or not, stay as typed")
	eq(w.window.agents[2].cwd, s.target, "in the PR's worktree")
	w.window.choose, w.window.typed = { "Start another agent", "Type a prompt…" }, "Ping {github.user} about {number}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	sent = requestsSent(w)
	eq(sent[#sent].users, true, "typed text that names it asks for the users too")
	eq(w.window.agents[3].prompt, "Ping octocat about 5", "and gets the login")
end)

windowCase("window: a pull request prompt naming {github.user} still runs when gh cannot say who is signed in", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { status = 1, stderr = "You are not logged into any GitHub hosts.\n" }
		end
		return nil
	end
	local b = linkQueue(w, s)
	savePrompts(w, { promptOf("p1", "Mine", "Review {url} as {github.user}; {nope}") })
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(requestsSent(w)[2].users, true, "the users were asked for")
	eq(#w.window.agents, 1, "the agent started all the same")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5 as ; {nope}", "the user the host could not read is blank; the rest is filled as always")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	eq(w.toasts[#w.toasts].level, "success", "and the user is told it started")
end)

windowCase("window: {github.user} and {jira.user} in an issue prompt are filled in, the users asked for only when it names one", function(w: World)
	local _, b = jiraWindow(w)
	saveIssuePrompts(w, {
		issuePrompt("p1", "Plain", "Work on {key}", false),
		issuePrompt("p2", "Both", "{github.user} ({jira.user}) works on {key}; {nope}", false),
		issuePrompt("p3", "Jira", "Ask {jira.user}", false),
	})
	b.render()
	cardSurface(w, b)
	w.click(issueRunLink("ABC", "ABC-12", "p1"))
	w.flush()
	same(asks.sent(w)[2], { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = false }, "a prompt that names no user does not ask for them")
	eq(w.window.agents[1].prompt, "Work on ABC-12", "and runs as written")
	w.click(issueRunLink("ABC", "ABC-12", "p2"))
	w.flush()
	same(asks.sent(w)[4], { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = true }, "one that names both asks for them")
	eq(#w.window.agents, 2, "an agent started for each")
	eq(w.window.agents[2].prompt, "octocat (ann) works on ABC-12; {nope}", "the gh login and the Jira user's name; an unknown variable stays as typed")
	eq(w.window.agents[2].cwd, "/work/r", "in the main checkout, as the prompt says")
	w.click(issueRunLink("ABC", "ABC-12", "p3"))
	w.flush()
	same(asks.sent(w)[6], { op = "issue", repo = "ABC", ref = "ABC-12", worktree = false, users = true }, "one that names only {jira.user} asks for them too")
	eq(w.window.agents[3].prompt, "Ask ann", "and gets the Jira user's name")
end)

windowCase("window: an issue prompt that runs in a worktree keeps its text and its users through the pull request and base questions", function(w: World)
	local s, b = asks.several(w)
	s.gh.linked["o/r#13"] = s.gh.linked["o/r#12"]
	s.git.served["refs/heads/develop"] = sha("e")
	-- a format that names no user: only the prompt asks for them
	w.kv.put("branch-format", "{key}-{slug}")
	saveIssuePrompts(w, { issuePrompt("p1", "Fix", "Fix {title} on {branch} as {github.user}", true) })
	b.render()
	cardSurface(w, b)
	w.window.choose = "#7 Fix login"
	w.click(issueRunLink("o/r", "12", "p1"))
	w.flush()
	same(asks.sent(w), {
		{ op = "menu", only = "p1" },
		asks.issue("o/r", "12", { users = true }),
		asks.issue("o/r", "12", { users = true, pr = 7 }),
	}, "the prompt is looked up once; the users are asked for again with the pull request picked")
	eq(asks.toasted(w, "Preparing worktree for o/r#12"), 1, "the user is told once")
	eq(#w.window.agents, 1, "the agent started once the questions were answered")
	eq(w.window.agents[1].cwd, "/wt/plotroom-o_r-issue-12", "in the issue's worktree")
	eq(w.window.agents[1].prompt, "Fix Fix login on fix-login as octocat", "on the pull request's branch")
	-- a new branch: the same on the way through the base question
	showPr(b, 13)
	cardSurface(w, b)
	local asked = #asks.sent(w)
	w.window.choose = { "New branch…", "develop" }
	w.click(issueRunLink("o/r", "13", "p1"))
	w.flush()
	same({ table.unpack(asks.sent(w), asked + 1) }, {
		{ op = "menu", only = "p1" },
		asks.issue("o/r", "13", { users = true }),
		asks.issue("o/r", "13", { users = true, fresh = true }),
		asks.issue("o/r", "13", { users = true, fresh = true, base = "develop" }),
	}, "and the users are asked for with the new branch, and with its base")
	eq(#w.window.agents, 2, "a second agent started")
	eq(w.window.agents[2].cwd, "/wt/plotroom-o_r-issue-13", "in the second issue's worktree")
	eq(w.window.agents[2].prompt, "Fix Add dark mode on 13-add-dark-mode as octocat", "on the new branch")
	eq(s.git.refs["refs/heads/13-add-dark-mode"], sha("e"), "made from the base")
end)

windowCase("window: a second Worktree click on an issue while the first is being prepared is told so and the question is asked once", function(w: World)
	local s = asks.several(w)
	w.window.choose = "#7 Fix login"
	w.click(issueLink("worktree", "o/r", "12"))
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	eq(asks.toasted(w, "A worktree for o/r#12 is already being prepared"), 1, "the repeat is told the first is under way")
	eq(#w.window.picks, 1, "one question")
	eq(countLog(s.git, "worktree add"), 1, "and one worktree")
	eq(#w.window.launches, 1, "and one tab")
	eq(#requestsOf(s.gh, "linked"), 1, "the linked pull requests were read once")
end)

windowCase("window: a second Worktree click on an issue while gh or git is still being read for its question is told so too", function(w: World)
	local s, b = asks.several(w)
	local real = s.gh.linked["o/r#12"]
	-- gh lists the linked pull requests of #12 only after a second; git lists the remote's branches as slowly
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" and req.fields.n == "12" then
			return { stdout = jsonEncode(array(real)), delay = 1000 }
		end
		return nil
	end
	s.git.fail["ls-remote"] = { stdout = "ref: refs/heads/main\tHEAD\n" .. sha("b") .. "\tHEAD\n" .. sha("b") .. "\trefs/heads/main\n", delay = 1000 }
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	w.click(issueLink("worktree", "o/r", "12"))
	w.flush()
	w.advance(1500)
	eq(asks.toasted(w, "A worktree for o/r#12 is already being prepared"), 1, "the repeat while the linked pull requests are read is told the first is under way")
	eq(#w.window.picks, 1, "one question: which pull request")
	eq(#requestsOf(s.gh, "linked"), 1, "the linked pull requests were read once")
	showPr(b, 13)
	cardSurface(w, b)
	w.click(issueLink("worktree", "o/r", "13"))
	w.flush()
	w.click(issueLink("worktree", "o/r", "13"))
	w.flush()
	w.advance(1500)
	eq(asks.toasted(w, "A worktree for o/r#13 is already being prepared"), 1, "the repeat while the remote's branches are listed is told so too")
	eq(#w.window.picks, 2, "one question more: which base")
	eq(countLog(s.git, "ls-remote"), 1, "the remote's branches were listed once")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made: the questions were dismissed")
end)

windowCase("window: Go to tab finds the worktree through the host's noted path, whatever its folder is called", function(w: World)
	local s, b = agentScene(w)
	w.kv.put("pr-dir-format", "pr-{key}")
	local target = "/wt/pr-5"
	-- a worktree in a folder the default format would not have named: the host notes where it is
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.window.launches[1].cwd, target, "the worktree's tab opened in the folder the format names")
	has(cardText(b), target, "which the host noted: its card says where it is")
	-- Plotroom's block sees the tab (the fake host lists panes apart from the window's), so the card offers Go to tab
	table.insert(w.panes, { pane = 11, cwd = target })
	w.window.tabs[2].session = 4
	w.window.focused = 1
	b.render()
	cardSurface(w, b)
	eq(buttonLink(b, "goto"), prLink("goto", "o/r", 5), "a tab working in the worktree: the card has its Go to tab link")
	local said, tabs, switched = #w.toasts, #w.window.launches, #w.window.switches
	w.click(prLink("goto", "o/r", 5))
	w.flush()
	local sent = asks.sent(w)
	same(sent[#sent], { op = "where", kind = "pr", key = "o/r#5" }, "the host is asked where the pull request's worktree is")
	eq(w.window.focused, 11, "the pane working in it is focused")
	same({ table.unpack(w.window.switches, switched + 1) }, { 4 }, "after its session is switched to")
	eq(#w.toasts, said, "with nothing said")
	eq(#w.window.launches, tabs, "and no tab opened")
	-- the card was drawn while the tab was open; the click comes after it closed
	w.window.panes[11] = nil
	table.remove(w.panes)
	local function addPane(id: number, cwd: string, tab: number, session: number)
		w.window.panes[id] = { block = nil, cwd = cwd, tab = tab }
		table.insert(w.window.tabs, { id = tab, session = session })
	end
	-- panes beside the worktree, none in it: a sibling folder that starts with its name, a folder named as the default
	-- format would, the worktrees folder itself
	addPane(21, "/wt/pr-50/src", 21, 5)
	addPane(22, "/wt/plotroom-o_r-pr-5", 22, 5)
	addPane(23, "/wt", 23, 5)
	w.window.focused = 1
	switched = #w.window.switches
	local function nobody(what: string)
		said = #w.toasts
		w.click(prLink("goto", "o/r", 5))
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "info", what .. ": as news, not an error")
		eq(w.toasts[#w.toasts].text, "No tab is open for o/r#5", what .. ": that no tab is open")
		eq(w.window.focused, 1, what .. ": no pane was focused")
		eq(#w.window.switches, switched, what .. ": no session was switched to")
		eq(#w.window.launches, tabs, what .. ": no tab opened")
	end
	nobody("a worktree nobody works in")
	-- nothing noted for it at all: git does not list the worktree, so the host has no note of it and its tab is no tab of the panes there are
	local made = table.remove(s.git.worktrees, 2) :: any
	refreshNow(w, b)
	nobody("a worktree the host has no note of")
	-- listed again, with a pane in the worktree itself, deeper down, among the others
	table.insert(s.git.worktrees, made)
	refreshNow(w, b)
	addPane(24, target .. "/src/lib", 24, 6)
	w.click(prLink("goto", "o/r", 5))
	w.flush()
	eq(w.window.focused, 24, "a pane inside the worktree is found among the others")
	eq(w.window.switches[#w.window.switches], 6, "and its session shown")
end)

windowCase("window: Go to tab asks for a pull request of a mixed-case repository by its lowercase key, as the worktree was noted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "Octo", "Repo", 5)
	local b = linkQueue(w, s)
	local target = "/wt/plotroom-octo_repo-pr-5"
	w.click(prLink("worktree", "Octo/Repo", 5))
	w.flush()
	eq(w.window.launches[1].cwd, target, "the worktree's tab opened")
	table.insert(w.panes, { pane = 11, cwd = target })
	w.window.focused = 1
	b.render()
	cardSurface(w, b)
	eq(buttonLink(b, "goto"), prLink("goto", "Octo/Repo", 5), "the card's link names the repository as GitHub spells it")
	w.click(prLink("goto", "Octo/Repo", 5))
	w.flush()
	local sent = asks.sent(w)
	same(sent[#sent], { op = "where", kind = "pr", key = "octo/repo#5" }, "the host is asked for the lowercase key its note is under")
	eq(w.window.focused, 11, "so the pane working in the worktree is focused")
	eq(#w.toasts, 2, "with nothing said but the worktree's start and its end")
end)

windowCase("window: Go to tab on a Jira issue asks for the project's lowercase key, as its worktree was noted", function(w: World)
	local _, b = jiraWindow(w)
	local target = "/wt/plotroom-o_r-issue-ABC-12"
	w.window.choose = "main"
	w.click(issueLink("worktree", "ABC", "ABC-12"))
	w.flush()
	eq(w.window.launches[1].cwd, target, "the worktree's tab opened")
	has(cardText(b), target, "the host noted it: its card says where it is")
	table.insert(w.panes, { pane = 11, cwd = target })
	w.window.focused = 1
	b.render()
	cardSurface(w, b)
	w.click(issueLink("goto", "ABC", "ABC-12"))
	w.flush()
	local sent = asks.sent(w)
	same(sent[#sent], { op = "where", kind = "issue", key = "abc#ABC-12" }, "the host is asked for that key")
	eq(w.window.focused, 11, "so the pane working in the worktree is focused")
end)

windowCase("window: an agent joins the tab working in its worktree, not a pane in a sibling folder that shares the path's start", function(w: World)
	local s = agentScene(w)
	w.window.choose, w.window.typed = "Type a prompt…", "go"
	-- a pane in /wt/plotroom-o_r-pr-5-old, beside the worktree /wt/plotroom-o_r-pr-5
	w.window.panes[21] = { block = nil, cwd = s.target .. "-old/src", tab = 21 }
	table.insert(w.window.tabs, { id = 21, session = 5 })
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[#w.toasts].text, "Agent started for o/r#5", "no tab works in the worktree yet: the agent has a tab of its own")
	eq(w.window.switches[#w.window.switches], 1, "in the session of the block")
	eq(w.window.panes[11].cwd, s.target, "that tab works in the worktree")
	w.window.panes[11] = nil -- and is closed again
	-- a pane inside the worktree
	w.window.panes[22] = { block = nil, cwd = s.target .. "/src", tab = 22 }
	table.insert(w.window.tabs, { id = 22, session = 6 })
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[#w.toasts].text, "Agent started in the tab of o/r#5", "a tab works in the worktree: the agent joins it")
	eq(w.window.switches[#w.window.switches], 6, "in its session")
	eq(w.window.panes[12].tab, 22, "the agent's pane moved into that tab")
	eq(#w.window.agents, 2, "two agents started")
end)

windowCase("window: a host announcing another protocol is refused for the new asks too: a pull request's or an issue's worktree, a tab, a prompt", function(w: World)
	w.load("window")
	-- the buttons of the block's selected row, as links, and what the block's main region announces
	local function offer(links: { string }, announces: string?)
		local names = { "worktree", "goto", "agent", "prompt-p1" }
		local buttons: { any } = {}
		for i, url in links do
			table.insert(buttons, { id = "layer.queue.buttons." .. names[i], p = { href = url } })
		end
		w.window.surfaces[1] = {
			layer = { id = "layer", c = { { id = "layer.queue", c = buttons } } },
			main = if announces then { id = "main", c = { { id = "main.rpc", p = { text = announces, hidden = true } } } } else nil,
		}
	end
	local pull = { prLink("worktree", "o/r", 5), prLink("goto", "o/r", 5), prLink("agent", "o/r", 5), runLink("o/r", 5, "p1") }
	local issue = { issueLink("worktree", "o/r", "12"), issueLink("goto", "o/r", "12"), issueLink("agent", "o/r", "12"), issueRunLink("o/r", "12", "p1") }
	local function refused(what: string, links: { string }, announces: string?)
		offer(links, announces)
		for _, url in links do
			local said = #w.toasts
			w.click(url)
			eq(#w.toasts, said + 1, what .. ", " .. url .. ": the click is answered")
			eq(w.toasts[#w.toasts].level, "error", what .. ", " .. url .. ": with an error")
			has(w.toasts[#w.toasts].text, "another version", what .. ", " .. url .. ": that says why")
		end
		w.flush()
		eq(#w.window.events + #w.window.picks + #w.calls + #w.window.launches, 0, what .. ": nothing was sent, asked, run or opened")
	end
	for _, links in { pull, issue } do
		refused("a block with no marker", links, nil)
		refused("a block of protocol 10", links, "10")
		refused("a block of protocol 11", links, "11")
		refused("a block of protocol 12", links, "12")
		refused("a block of protocol 13", links, "13")
	end
	-- the same links, with the marker of this protocol, are asked of the host: one block, both kinds
	offer(issue, asks.protocol)
	w.click(issue[2])
	local sent = asks.sent(w)
	eq(#sent, 1, "a host that announces this protocol is asked")
	eq(sent[1].op, "where", "where the issue's worktree is")
	offer(pull, asks.protocol)
	w.click(pull[2])
	sent = asks.sent(w)
	same(sent[2], { op = "where", kind = "pr", key = "o/r#5" }, "and where the pull request's is")
end)

case("host: an issue action's Move to status is an issue-side row that saves, resets, and reaches the menu", function(w: World)
	jiraHost(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	saveIssuePrompts(w, { issuePrompt("p1", "Fix", "Fix {key}", true) })
	local b = openIssues(w)
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	eq(rowIn(b, "pstatus:prs:p1"), nil, "a pull request action has no status row")
	expand(b, "popen:issues:p1")
	eq(rowIn(b, "pstatus:issues:p1").control.value, "", "empty while the action has none")
	local function save(text: string)
		b.event({ ev = "select", id = "layer.settings", item = "pstatus:issues:p1" })
		if prefsOf(b).editing == nil then
			b.press("enter")
		end
		b.press("a", "c")
		b.press("backspace")
		b.typeText(text)
		b.press("enter")
	end
	save(string.rep("x", 101))
	has(rowIn(b, "pstatus:issues:p1").warning, "at most 100", "a long name is refused")
	eq(w.kv.get("prompts-issues").items[1].status, nil, "and not saved")
	b.press("escape")
	save("In Review")
	eq(w.kv.get("prompts-issues").items[1].status, "In Review", "saved")
	request(b, "m1", { op = "menu" })
	local sent: any = nil
	for _, it in answerOf(b, "m1").items do
		if it.id == "p1" then
			sent = it
		end
	end
	eq(sent.status, "In Review", "the menu sends it")
	b.event({ ev = "change", id = "layer.settings", item = "pstatus:issues:p1", value = nil })
	eq(w.kv.get("prompts-issues").items[1].status, nil, "reset clears it")
end)

return {}
