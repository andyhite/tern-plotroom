--!strict
-- Regression cases: Now (everything that needs you, ranked), its reads and pacing, its Mark read… plan and its problems.

local h = require("../harness")

type GhReq = h.GhReq
type Reply = h.Reply
type World = h.World

local asks, case, collectTexts, eq, expand, goToSettings, has = h.asks, h.case, h.collectTexts, h.eq, h.expand, h.goToSettings, h.has
local hostScene, issueItem, jiraItem, listed, newAcli = h.hostScene, h.issueItem, h.jiraItem, h.listed, h.newAcli
local pickScope, pickerOf, refreshNow, requestsOf, rowIn, same, searchItem, yes = h.pickScope, h.pickerOf, h.refreshNow, h.requestsOf, h.rowIn, h.same, h.searchItem, h.yes
local EPOCH = h.EPOCH

-- Now's fixed searches, as the gh model tells them apart.
local MINE, REVIEW, ASSIGNED = "author:@me archived:false", "user-review-requested:@me", "assignee:@me archived:false"
local DISMISSED = "reviewed-by:@me -author:@me"

-- One notification thread as GitHub's API answers it; `n` its pull request (or issue, `issue`) number, none for a thread
-- that is about neither (CI).
local function thread(id: string, repo: string, reason: string, title: string, n: number?, issue: boolean?, at: string?): { [string]: any }
	local subject: { [string]: any } = { title = title, type = if n then (if issue then "Issue" else "PullRequest") else "CheckSuite" }
	if n then
		subject.url = "https://api.github.com/repos/" .. repo .. "/" .. (if issue then "issues" else "pulls") .. "/" .. n
	end
	return { id = id, unread = true, reason = reason, updated_at = at or "2026-10-19T08:00:00Z", subject = subject, repository = { full_name = repo } }
end

-- A scene whose active login octocat has notifications (`threads`, else three), no pull request or issue of its own
-- unless the case adds them (s.gh.queries), Jira on with nothing assigned, and a new block, which opens on Now. `setup`
-- runs on the scene before the block opens.
local function nowScene(w: World, threads: { any }?, setup: ((h.HostScene, h.Acli) -> ())?): (h.HostScene, h.Block, h.Acli)
	local s = hostScene(w, 3)
	local acli = newAcli(w)
	s.gh.tokens.octocat = "tok-octocat"
	s.gh.queries[MINE], s.gh.queries[REVIEW], s.gh.queries[ASSIGNED] = {}, {}, {}
	s.gh.inbox.octocat = threads or {
		thread("11", "o/r", "review_requested", "Add feature", 2),
		thread("12", "o/r", "mention", "Login is broken", 7, true),
		thread("13", "x/y", "ci_activity", "CI failed on main"),
	}
	if setup then
		setup(s, acli)
	end
	w.setOpensNow(true)
	local b = w.open(1, { "/work/r" })
	w.flush()
	return s, b, acli
end

local function textOf(node: any): string
	local out: { string } = {}
	collectTexts(node, out)
	return table.concat(out)
end

-- Now's rows as "id why", top first.
local function whys(b: h.Block): { string }
	local out: { string } = {}
	for _, item in pickerOf(b).items do
		table.insert(out, item.id .. " " .. item.badges[1].text)
	end
	return out
end

case("now: a new block opens on Now, first in the sidebar, which ranks what needs you top first and says why", function(w: World)
	local ready = { review = "APPROVED", mergeable = "MERGEABLE", merge = "CLEAN", checks = "SUCCESS" }
	local _, b = nowScene(w, {
		thread("21", "o/r", "mention", "Ship it", 2, false, "2026-10-19T09:00:00Z"), -- already listed: Ready to merge
		thread("22", "x/y", "mention", "Docs question", 9, true, "2026-10-19T08:30:00Z"),
		thread("23", "x/y", "ci_activity", "CI failed on main", nil, nil, "2026-10-19T08:00:00Z"),
	}, function(s: h.HostScene, acli: h.Acli)
		s.gh.queries[MINE] = {
			searchItem(1, "o/r", EPOCH - 60, { review = "CHANGES_REQUESTED" }),
			searchItem(2, "o/r", EPOCH - 120, ready),
			searchItem(3, "o/r", EPOCH - 180), -- open, nothing asked of you
		}
		s.gh.queries[REVIEW] = {
			searchItem(5, "o/r", EPOCH - 60, { createdAt = h.iso(EPOCH - 600) }),
			searchItem(4, "o/r", EPOCH - 90, { createdAt = h.iso(EPOCH - 6000) }),
		}
		s.gh.queries[ASSIGNED] = { issueItem(12, "o/r", EPOCH - 300) }
		acli.searches[h.JIRA_NOW] = { jiraItem("ABC-1", "Fix login") }
	end)
	local scopes = pickerOf(b).scopes
	eq(scopes[1].id, "now", "Now is first in the sidebar")
	eq(pickerOf(b).scope, "now", "and shown when the block opens")
	eq(pickerOf(b).selected, "no_2fr_231", "on its top row")
	asks.hx.agents(b, { ["o/r#3"] = "waiting_input" })
	scopes = pickerOf(b).scopes
	same(whys(b), {
		"no_2fr_233 Agent needs input",
		"no_2fr_231 Blocked",
		"no_2fr_234 Review requested",
		"no_2fr_235 Review requested",
		"no_2fr_232 Ready to merge",
		"nx_2fy_239 Mention",
		"t23 CI",
		"no_2fr_2312 Assigned: new",
		"nabc_23ABC-1 Assigned: new",
	}, "agents that need input, your blocked PRs, reviews oldest first, your PRs ready to merge, notifications not already listed, then New items assigned to you; o/r#3 has nothing else and o/r#2's thread is not listed twice")
	for _, row in pickerOf(b).items do
		if row.id == "no_2fr_231" then
			eq(h.detailText(row), "#1 · o/r · Changes requested", "a Now row names its repository (Now spans them all), then the first chip's detail")
			eq(row.badges[2].text, "Address changes", "and its chips follow the Blocked badge, naming each job")
		elseif row.id == "no_2fr_234" then
			eq(#row.badges, 1, "a row listed for another reason carries no chips")
		end
	end
	eq(pickerOf(b).selected, "no_2fr_231", "the selection stays on its row as rows arrive above it")
	eq(scopes[1].count, 9, "the sidebar counts them")
	local need = "1 agent needs you · 1 Blocked · 2 reviews requested · 1 Ready to merge · 2 notifications · 2 assigned: new or changed"
	eq(b.title(), "Plotroom · Now · " .. need, "the pane title says what needs you by kind, in Now's order, adding up to the sidebar's count")
	local sub: { string } = {}
	for _, span in pickerOf(b).subtitle do
		table.insert(sub, if type(span) == "string" then span else span.t)
	end
	eq(table.concat(sub), need, "and so does Now's heading, with no bare count")
end)

case("now: snoozed items leave Now and its count until Show or hide snoozed lists them; an agent that needs input is always listed", function(w: World)
	local _, b = nowScene(w, {}, function(s: h.HostScene)
		s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 90), searchItem(5, "o/r", EPOCH - 60) }
		w.kv.put("triage", { version = 1, items = { ["o/r#4"] = { at = 1, snoozeUntil = EPOCH + 3600 } } })
	end)
	same(listed(b), { "no_2fr_235" }, "the snoozed one is not in Now")
	eq(b.title(), "Plotroom · Now · 1 review requested", "and the count leaves it out")
	b.typeText("Z")
	same(listed(b), { "no_2fr_234", "no_2fr_235" }, "Show or hide snoozed lists it again")
	has(table.concat(whys(b), ","), "Review requested", "under its reason")
	eq(pickerOf(b).items[1].badges[2].text, "Snoozed", "marked Snoozed")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_234" })
	eq(h.factOf(b, "Snoozed"), "Until Mon 13:00", "its preview says when the snooze ends (an hour after the clock's 12:00 UTC start)")
	eq(b.title(), "Plotroom · Now · 1 review requested", "and still not counted")
	b.typeText("Z")
	asks.hx.agents(b, { ["o/r#4"] = "waiting_input" })
	same(listed(b), { "no_2fr_234", "no_2fr_235" }, "an agent that needs input lists its snoozed item")
	eq(pickerOf(b).items[1].badges[1].text, "Agent needs input", "first")
end)

case("now: an item whose agent works shows the agent's bar and clock on its Now row and in its preview", function(w: World)
	local _, b = nowScene(w, {}, function(s: h.HostScene)
		s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 90), searchItem(5, "o/r", EPOCH - 60) }
	end)
	asks.hx.agents(b, { ["o/r#4"] = { state = "working", action = "Review", since = tostring(w.seconds() - 125), expected = "100" } })
	eq(h.detailText(pickerOf(b).items[1]), "#4 · o/r · ━━━━━━━━━━ 2:05", "its row ends with the bar and the clock")
	eq(h.detailText(pickerOf(b).items[2]), "#5 · o/r", "a row with no working agent has neither")
	eq(h.factOf(b, "Working"), "━━━━━━━━━━ 2:05", "and so does its preview")
	w.advance(1000)
	eq(h.factOf(b, "Working"), "━━━━━━━━━━ 2:06", "a second later the clock moved on")
end)

case("now: an empty Now says nothing needs you, and the view's own filters are gone", function(w: World)
	local _, b = nowScene(w, {})
	same(listed(b), {}, "nothing")
	has(textOf(pickerOf(b).empty), "Nothing needs you", "says so")
	eq(b.title(), "Plotroom · Now", "with no count in the title")
	pickScope(b, "prs:v1")
	w.flush()
	local p = h.hx.palette(w, b)
	eq(table.find(p.ids, "attention"), nil, "Needs attention only is gone from Commands")
	eq(table.find(p.ids, "scope:inbox"), nil, "and so is the Inbox list")
	has(table.concat(p.ids, ","), "scope:now", "Now is a Views row")
end)

case("now: Now is read per signed-in login with the queue's refresh, not more often, and a login GitHub's cooldown holds is not asked", function(w: World)
	local s, b = nowScene(w, {}, function(s: h.HostScene)
		s.gh.tokens.work = "tok-work"
	end)
	refreshNow(w, b)
	local function nowReads(login: string): number
		local n = 0
		for _, req in s.gh.requests do
			if req.kind == "search" and string.find(req.fields.q or "", MINE, 1, true) and req.login == login then
				n += 1
			end
		end
		return n
	end
	local function viewReads(): number
		local n = 0
		for _, req in requestsOf(s.gh, "search") do
			if not string.find(req.fields.q or "", "archived:false", 1, true) then
				n += 1
			end
		end
		return n
	end
	yes(nowReads("work") >= 1, "the other signed-in login's own pull requests are read as it")
	local before, views = nowReads("octocat"), viewReads()
	w.advance(20 * 1000)
	w.flush()
	eq(nowReads("octocat"), before, "nothing is read again before the queue's next refresh")
	w.advance(10 * 60 * 1000)
	w.flush()
	yes(nowReads("octocat") > before, "the queue's refresh reads Now again")
	eq(nowReads("octocat") - before, viewReads() - views, "once per refresh of the queue: Now adds no refresh of its own")
	s.gh.limits.octocat = { limit = 30, remaining = 0, reset = EPOCH + 3600 }
	refreshNow(w, b)
	local held = nowReads("octocat")
	refreshNow(w, b)
	eq(nowReads("octocat"), held, "while GitHub's cooldown holds octocat is not searched again")
	has(textOf(pickerOf(b).subtitle), "rate limit", "and Now says why")
end)

case("now: a block on a view counts what needs you, and a review request that arrives is counted at the next refresh", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat"
	s.gh.queries[MINE], s.gh.queries[ASSIGNED] = {}, {}
	s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 90) }
	s.gh.inbox.octocat = {}
	local b = w.open(1, { "/work/r" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "the block shows a view, not Now")
	eq(b.title(), "Plotroom · My PRs · 1 review requested", "the waiting review request is counted off Now")
	s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 90), searchItem(5, "o/r", EPOCH - 60) }
	w.advance(10 * 60 * 1000)
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "still on the view")
	eq(b.title(), "Plotroom · My PRs · 2 reviews requested", "the queue's refresh read Now again and counts the new one")
end)

case("now: Enter on a pull request shows it in the block as a linked one is, an issue pinned, and a thread about neither says so", function(w: World)
	local s, b = nowScene(w)
	s.gh.pulls["https://github.com/o/r/issues/7"] = nil
	same(listed(b), { "no_2fr_232", "no_2fr_237", "t13" }, "the three threads")
	eq(b.press("enter"), true, "Enter shows the first")
	eq(pickerOf(b).scope, "prs:v1", "a pull request the view lists is selected in place")
	eq(pickerOf(b).selected, "no_2fr_232", "that very one")
	eq(#b.state().pins, 0, "nothing is pinned for it")
	pickScope(b, "now")
	w.flush()
	b.press("down")
	b.press("enter")
	eq(#b.state().pins, 1, "an issue the view does not list is pinned")
	eq(b.state().pins[1].query, "https://github.com/o/r/issues/7", "by its page")
	pickScope(b, "now")
	w.flush()
	b.press("down")
	b.press("down")
	eq(pickerOf(b).selected, "t13", "the CI thread is selected")
	local toasts = #w.toasts
	b.press("enter")
	eq(w.toasts[toasts + 1].text, "Nothing to show", "it is about no pull request or issue")
	eq(pickerOf(b).scope, "now", "and Now stays")
end)

case("now: no read within X-Poll-Interval, then a full read, so a thread marked read elsewhere leaves", function(w: World)
	local s, b = nowScene(w, nil, function(s: h.HostScene)
		s.gh.inboxPoll = 300
	end)
	refreshNow(w, b)
	local before = #pickerOf(b).items
	eq(#requestsOf(s.gh, "notifications"), 1, "read once")
	table.remove(s.gh.inbox.octocat, 1) -- marked read on github.com; GitHub's Last-Modified does not move for that
	w.advance(200 * 1000)
	w.flush()
	eq(#requestsOf(s.gh, "notifications"), 1, "nothing is sent within the poll interval, Refresh or the queue's own refresh included")
	w.advance(101 * 1000)
	w.flush()
	eq(#requestsOf(s.gh, "notifications"), 2, "after it the queue's refresh reads again")
	eq(#pickerOf(b).items, before - 1, "and the thread read elsewhere is gone")
end)

case("now: Mark read… plans Now's listed threads as the login captured then, and commits exactly those after one confirm", function(w: World)
	local s, b = nowScene(w)
	s.gh.tokens.other = "tok-other"
	local p = asks.hx.ask(w, b, { op = "act", name = "mark-read" })
	yes(type(p.token) == "string" and p.token ~= "", "a plan carries its token")
	eq(p.confirm.head, "Mark 3 notifications read?", "the question counts the threads")
	eq(p.confirm.label, "Mark 3 read", "the confirming choice")
	eq(p.confirm.lines[1], "Account: @octocat", "names the account")
	has(p.confirm.lines[2], "none is marked done", "says they are read, not done")
	same({ p.confirm.lines[3], p.confirm.lines[4] }, { "o/r: 2", "x/y: 1" }, "and the repositories")
	eq(#s.gh.inboxRead, 0, "nothing is sent before the commit")
	s.gh.active = "other" -- gh's active account changes after the plan
	s.gh.inbox.octocat = {}
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	eq(r.ok, true, "committed")
	eq(r.message, "Marked 3 notifications read as @octocat", "told with the account")
	same(s.gh.inboxRead, { "11", "12", "13" }, "exactly the planned threads, one request each")
	for _, req in requestsOf(s.gh, "mark-read") do
		eq(req.login, "octocat", "as the login of the plan, not gh's active one")
		yes(table.find(req.call.argv, "PATCH") ~= nil, "a PATCH: read, never done (no DELETE)")
	end
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "no longer valid", "a plan commits once")
end)

case("now: Mark read… plans every thread Now read, also one about an item listed higher", function(w: World)
	local s, b = nowScene(w)
	s.gh.queries[REVIEW] = { searchItem(2, "o/r", EPOCH - 60) }
	refreshNow(w, b)
	same(listed(b), { "no_2fr_232", "no_2fr_237", "t13" }, "o/r#2 is listed once, as a review request")
	eq(pickerOf(b).items[1].badges[1].text, "Review requested", "for its higher rank")
	local p = asks.hx.ask(w, b, { op = "act", name = "mark-read" })
	eq(p.confirm.head, "Mark 3 notifications read?", "its thread is marked too, so GitHub keeps none unread")
end)

case("now: a mark-read plan is refused off Now, after Now was left, and stops at the first thread that fails", function(w: World)
	local s, b = nowScene(w)
	pickScope(b, "prs:v1")
	w.flush()
	has(asks.hx.ask(w, b, { op = "act", name = "mark-read" }).problem, "lists no notifications", "Now is not shown")
	pickScope(b, "now")
	w.flush()
	local p = asks.hx.ask(w, b, { op = "act", name = "mark-read" })
	pickScope(b, "prs:v1")
	w.flush()
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "selection or the view changed", "after Now was left")
	eq(#s.gh.inboxRead, 0, "nothing was sent")
	pickScope(b, "now")
	w.flush()
	p = asks.hx.ask(w, b, { op = "act", name = "mark-read" })
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "mark-read" and #s.gh.inboxRead >= 1 then
			return { status = 1, stderr = "gh: Server Error (HTTP 500)\n" }
		end
		return nil
	end
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	has(r.problem, "Marked 1 of 3 read, then stopped", "a failure says how far it got")
	same(s.gh.inboxRead, { "11" }, "and stops there")
end)

case("now: the palette offers Mark read… only while Now lists notifications, under Now", function(w: World)
	local s, b = nowScene(w, {})
	eq(table.find(h.hx.palette(w, b).commands, "mark-read"), nil, "no notification offers none")
	s.gh.inbox.octocat = { thread("11", "o/r", "mention", "Hello", 2) }
	w.advance(125 * 1000)
	w.flush()
	local p = h.hx.palette(w, b)
	yes(table.find(p.commands, "mark-read") ~= nil, "a listed notification offers it")
	eq(p.commandGroups["mark-read"], "Now", "under Now")
end)

case("now: a login that cannot read notifications says why and the gh auth refresh that fixes it, keeps the rest of Now, and nothing falls back to another login", function(w: World)
	local s = hostScene(w, 3)
	newAcli(w)
	s.gh.tokens.octocat = "tok-octocat"
	s.gh.tokens.other = "tok-other"
	s.gh.queries[MINE], s.gh.queries[ASSIGNED] = {}, {}
	s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 90) }
	s.gh.inbox.other = { thread("99", "o/r", "mention", "Not yours", 2) }
	s.gh.inboxDenied.octocat = true
	w.setOpensNow(true)
	local b = w.open(1, { "/work/r" })
	w.flush()
	local sub = textOf(pickerOf(b).subtitle)
	has(sub, "@octocat cannot read GitHub notifications", "says whose")
	has(sub, "gh auth refresh -h github.com -s notifications", "and the command that fixes it")
	has(table.concat(listed(b), ","), "no_2fr_234", "the review request is still listed")
	for _, req in requestsOf(s.gh, "notifications") do
		eq(req.login, "octocat", "no read was made as another login")
	end
	has(asks.hx.ask(w, b, { op = "act", name = "mark-read" }).problem, "lists no notifications", "and there is nothing to mark")
end)

case("now: without gh Now reads nothing from GitHub and says what needs you from Jira", function(w: World)
	local s = hostScene(w, 3)
	local acli = newAcli(w)
	h.hx.uninstalled(w, "gh")
	acli.searches[h.JIRA_NOW] = { jiraItem("ABC-1", "Fix login") }
	w.setOpensNow(true)
	local b = w.open(1, { "/work/r" })
	w.flush()
	eq(#requestsOf(s.gh, "notifications"), 0, "no notification was read")
	same(listed(b), { "nabc_23ABC-1" }, "Jira's New issue assigned to you is listed")
end)

case("now: an idle agent whose outcome is Not verified, or whose report says stuck or needs human, ranks with Needs you, with Go to agent and no Reply…", function(w: World)
	local _, b = nowScene(w, {})
	asks.hx.agents(b, {
		["o/r#3"] = { state = "idle", action = "Implement", outcome = "pr", verdict = "not" },
		["o/r#4"] = { state = "idle", action = "Fix", attention = "needs-human", reason = "Which base?" },
		["o/r#5"] = { state = "idle", outcome = "review", verdict = "verified" },
		["o/r#6"] = { state = "working", outcome = "pr", verdict = "not" },
		["o/r#7"] = { state = "idle", outcome = "pr", verdict = "unchecked" },
		["o/r#8"] = { state = "exited" },
	})
	same(whys(b), { "no_2fr_233 PR opened: Not verified", "no_2fr_234 Report: needs human" }, "Not verified and a needs-human report rank first; Verified, Unchecked and a working agent do not")
	eq(b.title(), "Plotroom · Now · 2 agents need you", "and are counted")
	local text = textOf(h.pickerNode(b))
	has(text, "GitHub does not show what its run must leave behind: PR opened: Not verified", "the preview says why")
	has(text, "Implement", "with the action")
	local p = h.hx.palette(w, b)
	yes(table.find(p.ids, "agentgo") ~= nil, "Go to agent is offered")
	eq(table.find(p.ids, "agentreply"), nil, "Reply… is not: the agent waits for no input")
	eq(h.findKey(h.pickerNode(b), "agentreply"), nil, "nor is its hidden link")
	asks.hx.agents(b, { ["o/r#3"] = { state = "idle", attention = "stuck", reason = "No database", outcome = "pr", verdict = "verified" } })
	same(whys(b), { "no_2fr_233 Report: stuck" }, "a stuck report needs you whatever the outcome")
end)

case("now: an idle checker whose check failed ranks with Needs you, its findings in the preview; a passing one does not", function(w: World)
	local _, b = nowScene(w, {})
	asks.hx.agents(b, {
		["o/r#3"] = { state = "idle", action = "Check", check = "fail", findings = "AC1: no test", attention = "ok" },
		["o/r#4"] = { state = "idle", action = "Check", check = "pass" },
	})
	same(whys(b), { "no_2fr_233 Check failed" }, "a failed check needs you; a pass does not")
	local text = textOf(h.pickerNode(b))
	has(text, "AC1: no test", "the preview lists the findings")
	has(text, "found what fails", "and says why it is listed")
end)

case("now: an item whose chain stopped at a limit ranks with Needs you and says which limit; a working agent does not", function(w: World)
	local _, b = nowScene(w, {})
	asks.hx.agents(b, {
		["o/r#3"] = { state = "idle", action = "Check", check = "fail", findings = "AC1", stop = "3 failed checks" },
		["o/r#4"] = { state = "working", action = "Implement", stop = "3 failed starts" },
	})
	same(whys(b), { "no_2fr_233 3 failed checks" }, "the limit is why it is listed, before the failed check")
	local text = textOf(h.pickerNode(b))
	has(text, "Plotroom stopped the item's chain of actions: 3 failed checks", "the preview says the chain stopped and why")
	has(text, "Stopped: 3 failed checks", "as its Chain fact")
end)

-- Logins the notification reads were made as, sorted and once each.
local function noticeLogins(s: h.HostScene): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, req in requestsOf(s.gh, "notifications") do
		local login = req.login or "?"
		if not seen[login] then
			seen[login] = true
			table.insert(out, login)
		end
	end
	table.sort(out)
	return out
end

case("now: every signed-in login's notifications are read as that login; one that cannot read them says why alone and the others are still listed", function(w: World)
	local s, b = nowScene(w, nil, function(s: h.HostScene)
		s.gh.tokens.work = "tok-work"
		s.gh.inbox.work = { thread("31", "w/z", "mention", "Work thing", 4, true, "2026-10-19T09:00:00Z") }
	end)
	refreshNow(w, b)
	same(listed(b), { "nw_2fz_234", "no_2fr_232", "no_2fr_237", "t13" }, "work's thread is listed beside octocat's, newest first")
	same(noticeLogins(s), { "octocat", "work" }, "each read as its own login")
	eq(b.title(), "Plotroom · Now · 4 notifications", "and counted")
end)

case("now: a login whose notifications cannot be read adds its own problem line; the other login's are listed and nothing falls back", function(w: World)
	local s, b = nowScene(w, nil, function(s: h.HostScene)
		s.gh.tokens.work = "tok-work"
		s.gh.inbox.work = { thread("31", "w/z", "mention", "Work thing", 4, true) }
		s.gh.inboxDenied.work = true
	end)
	refreshNow(w, b)
	local sub = textOf(pickerOf(b).subtitle)
	has(sub, "Notifications (@work): @work cannot read GitHub notifications. Run: gh auth refresh -h github.com -s notifications", "work says why, with the fix")
	eq(string.find(sub, "(@octocat)", 1, true), nil, "octocat has no problem")
	same(listed(b), { "no_2fr_232", "no_2fr_237", "t13" }, "octocat's threads are still listed")
	same(noticeLogins(s), { "octocat", "work" }, "work was asked as itself, and its threads were never read as octocat")
end)

case("now: Mark read… across two logins names each account with its threads per repository, and commits each login's threads as that login", function(w: World)
	local s, b = nowScene(w, nil, function(s: h.HostScene)
		s.gh.tokens.work = "tok-work"
		s.gh.inbox.work = { thread("31", "w/z", "mention", "Work thing", 4, true) }
	end)
	refreshNow(w, b)
	local p = asks.hx.ask(w, b, { op = "act", name = "mark-read" })
	eq(p.confirm.head, "Mark 4 notifications read?", "every listed thread")
	same(p.confirm.lines, {
		"Accounts: @octocat, @work",
		"Mark 4 notifications read (GitHub keeps them in the inbox; none is marked done)",
		"@octocat o/r: 2",
		"@octocat x/y: 1",
		"@work w/z: 1",
	}, "each account, and each one's threads per repository")
	s.gh.active = "work" -- gh's active account changes after the plan
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	eq(r.ok, true, "committed")
	eq(r.message, "Marked 4 notifications read as @octocat and @work", "told with both accounts")
	local as: { string } = {}
	for _, req in requestsOf(s.gh, "mark-read") do
		table.insert(as, (string.match(table.concat(req.call.argv, " "), "threads/(%d+)") or "?") .. "@" .. tostring(req.login))
	end
	same(as, { "11@octocat", "12@octocat", "13@octocat", "31@work" }, "each thread marked as the login it was read as, the one captured at plan time")
end)

-- One timeline event as Now's assigned search prints it: when, by whom and, for an assignment, to whom.
local function ev(at: number, by: string, to: string?): { [string]: any }
	return { at = h.iso(at), by = by, to = to or h.NULL }
end

-- An assigned GitHub issue of o/r with its newest timeline `events` (nil: they were not read).
local function assignedIssue(n: number, updated: number, events: { { [string]: any } }?): { [string]: any }
	return issueItem(n, "o/r", updated, { events = if events then h.array(events) else nil })
end

case("now: an assigned issue you changed yourself is not listed, until someone else changes it; one whose actor cannot be read is", function(w: World)
	local s, b = nowScene(w, { thread("41", "o/r", "mention", "Issue 21", 21, true) }, function(s: h.HostScene)
		s.gh.queries[ASSIGNED] = {
			assignedIssue(21, EPOCH - 300, { ev(EPOCH - 300, "octocat", "octocat") }), -- you assigned it to yourself
			assignedIssue(22, EPOCH - 400, { ev(EPOCH - 400, "boss", "octocat") }), -- someone else assigned it to you
			assignedIssue(23, EPOCH - 440, { ev(EPOCH - 500, "octocat", "octocat"), ev(EPOCH - 450, "octocat"), ev(EPOCH - 440, "octocat") }), -- then labelled and renamed it
			assignedIssue(24, EPOCH - 200, { ev(EPOCH - 2000, "carol"), ev(EPOCH - 200, "octocat") }), -- seen in between; only your comment since
			assignedIssue(25, EPOCH - 500, nil), -- who changed it was not read
			assignedIssue(26, EPOCH - 100, { ev(EPOCH - 100, "octocat") }), -- no assignment among its events
			assignedIssue(27, EPOCH - 50, { ev(EPOCH - 300, "octocat", "octocat") }), -- updated after your last event
		}
		w.kv.put("triage", { version = 1, items = { ["o/r#24"] = { at = EPOCH - 1000, seen = "0000000000000000" } } })
	end)
	refreshNow(w, b)
	same(whys(b), {
		"no_2fr_2321 Mention",
		"no_2fr_2327 Assigned: new",
		"no_2fr_2326 Assigned: new",
		"no_2fr_2322 Assigned: new",
		"no_2fr_2325 Assigned: new",
	}, "your own assignment, edits and comment list nothing; another's assignment and what cannot be read are listed; a notification about your own issue still is")
	s.gh.queries[ASSIGNED] = {
		assignedIssue(21, EPOCH + 30, { ev(EPOCH - 300, "octocat", "octocat"), ev(EPOCH + 30, "carol") }),
		assignedIssue(24, EPOCH - 200, { ev(EPOCH - 2000, "carol"), ev(EPOCH - 200, "octocat") }),
	}
	w.advance(60 * 1000)
	refreshNow(w, b)
	has(table.concat(whys(b), ","), "no_2fr_2321 Mention", "the notification is listed")
	eq(#pickerOf(b).items, 1, "o/r#21 once, at its higher rank")
	s.gh.inbox.octocat = {}
	w.advance(60 * 1000)
	refreshNow(w, b)
	same(whys(b), { "no_2fr_2321 Assigned: new" }, "someone else's comment lists it again; o/r#24 is still yours alone")
end)

case("now: a Jira issue whose newest change is your own is not listed, until someone else comments; one whose changes cannot be read is", function(w: World)
	local comment = function(email: string, at: number): any
		return { author = { emailAddress = email }, created = h.iso(at), updated = h.iso(at) }
	end
	local function changes(updated: number, comments: { any }): any
		return { key = "x", fields = { updated = h.iso(updated), comment = { comments = h.array(comments) } } }
	end
	local _, b, acli = nowScene(w, {}, function(_, acli: h.Acli)
		acli.searches[h.JIRA_NOW] = { jiraItem("ABC-1", "Self-assigned"), jiraItem("ABC-2", "Commented"), jiraItem("ABC-3", "Bob's"), jiraItem("ABC-4", "Unreadable"), jiraItem("ABC-5", "Seen") }
		acli.changes["ABC-1"], acli.owned["ABC-1"] = changes(EPOCH - 120, {}), true -- you assigned it to yourself
		acli.changes["ABC-2"] = changes(EPOCH - 60, { comment("bob@example.com", EPOCH - 900), comment("ann@example.com", EPOCH - 60) })
		acli.changes["ABC-3"] = changes(EPOCH - 60, {}) -- someone else changed a field
		acli.changes["ABC-5"], acli.owned["ABC-5"] = changes(EPOCH - 60, { comment("bob@example.com", EPOCH - 300) }), true
		w.kv.put("triage", { version = 1, items = { ["abc#ABC-5"] = { at = EPOCH - 600, seen = "0000000000000000" } } })
	end)
	same(whys(b), { "nabc_23ABC-3 Assigned: new", "nabc_23ABC-4 Assigned: new", "nabc_23ABC-5 Assigned: changed" }, "your own assignment and comment list nothing; another's change, an unreadable one and a comment of Bob's since you saw it do")
	acli.changes["ABC-1"], acli.owned["ABC-1"] = changes(EPOCH + 30, { comment("bob@example.com", EPOCH + 30) }), false
	w.advance(60 * 1000)
	refreshNow(w, b)
	has(table.concat(listed(b), ","), "nabc_23ABC-1", "Bob's comment lists it again")
end)

case("now: a seen assigned Jira issue someone else comments on is listed as Assigned: changed and is Changed in a view; your own comment lists nothing", function(w: World)
	local function changes(updated: number, comments: { any }): any
		return { key = "x", fields = { updated = h.iso(updated), comment = { comments = h.array(comments) } } }
	end
	local function comment(email: string, at: number): any
		return { author = { emailAddress = email }, created = h.iso(at), updated = h.iso(at) }
	end
	local _, b, acli = nowScene(w, {}, function(_, acli: h.Acli)
		acli.searches[h.JIRA_NOW] = { jiraItem("ABC-5", "Seen") }
		acli.searches[h.JIRA_ASSIGNED] = { jiraItem("ABC-6", "Other"), jiraItem("ABC-5", "Seen") }
		acli.changes["ABC-5"] = changes(EPOCH - 600, {})
	end)
	local ROW = "nabc_23ABC-5"
	pickScope(b, "issues:v3")
	w.flush()
	b.event({ ev = "select", id = "layer.queue", item = ROW }) -- its preview marks it seen
	b.event({ ev = "select", id = "layer.queue", item = "nabc_23ABC-6" })
	w.flush()
	eq(asks.hx.mark(b, ROW), "-", "seen in the view")
	pickScope(b, "now")
	refreshNow(w, b)
	same(whys(b), {}, "seen and nobody changed it: not listed")
	acli.changes["ABC-5"] = changes(EPOCH + 60, { comment("ann@example.com", EPOCH + 60) })
	w.advance(60 * 1000)
	refreshNow(w, b)
	same(whys(b), {}, "your own comment lists nothing")
	acli.changes["ABC-5"] = changes(EPOCH + 120, { comment("ann@example.com", EPOCH + 60), comment("bob@example.com", EPOCH + 120) })
	w.advance(60 * 1000)
	refreshNow(w, b)
	same(whys(b), { ROW .. " Assigned: changed" }, "Bob's comment lists it as changed")
	pickScope(b, "issues:v3")
	w.flush()
	eq(asks.hx.mark(b, ROW), "Changed", "and its view row is Changed")
	b.event({ ev = "select", id = "layer.queue", item = ROW })
	w.flush()
	eq(asks.hx.mark(b, ROW), "-", "seeing it again clears it")
	pickScope(b, "now")
	refreshNow(w, b)
	same(whys(b), {}, "and Now no longer lists it")
end)

case("now: snoozing a comment-Changed Jira issue keeps it Changed after the snooze; Mark seen or its preview clears it", function(w: World)
	local function changes(updated: number, comments: { any }): any
		return { key = "x", fields = { updated = h.iso(updated), comment = { comments = h.array(comments) } } }
	end
	local function comment(email: string, at: number): any
		return { author = { emailAddress = email }, created = h.iso(at), updated = h.iso(at) }
	end
	local _, b, acli = nowScene(w, {}, function(_, acli: h.Acli)
		acli.searches[h.JIRA_NOW] = { jiraItem("ABC-5", "Seen") }
		acli.searches[h.JIRA_ASSIGNED] = { jiraItem("ABC-6", "Other"), jiraItem("ABC-5", "Seen") }
		acli.changes["ABC-5"] = changes(EPOCH - 600, {})
	end)
	local ROW = "nabc_23ABC-5"
	local function inNow(): { string }
		pickScope(b, "now")
		refreshNow(w, b)
		return whys(b)
	end
	-- A view's List shows the selected item's preview, which marks it seen; its Board shows none, so snoozing and
	-- Mark seen act there on a card nobody has opened. Answers the Board's selected card and ROW's card title.
	local function onBoard(): (string?, string?)
		pickScope(b, "issues:v3")
		w.flush()
		local _, selected = h.hx.board(b)
		local card: any = h.findKey(h.pickerNode(b), ROW, "item")
		return selected and string.match(selected, "[^.]+$"), card and card.p.title
	end
	local CHANGED = "Changed since you marked it seen"
	pickScope(b, "issues:v3")
	w.flush()
	b.event({ ev = "select", id = "layer.queue", item = ROW }) -- its preview marks it seen
	w.flush()
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" })
	w.flush()
	w.advance(60 * 1000)
	acli.changes["ABC-5"] = changes(EPOCH + 30, { comment("bob@example.com", EPOCH + 30) }) -- after it was seen, before the snooze
	same(inNow(), { ROW .. " Assigned: changed" }, "Bob's comment lists it as changed")
	eq((onBoard()), ROW, "its card is selected on the view's Board")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "snooze" })
	w.flush()
	yes(w.kv.get("triage").items["abc#ABC-5"].snoozeUntil ~= nil, "it is snoozed")
	w.advance(2 * 24 * 3600 * 1000) -- past 08:00 tomorrow: the snooze has ended
	same(inNow(), { ROW .. " Assigned: changed" }, "once the snooze ends it is still changed: snoozing did not see Bob's comment")
	local at, title = onBoard()
	eq(title, CHANGED, "and its card on the view's Board is Changed")
	if at ~= ROW then
		b.press("down")
	end
	eq((onBoard()), ROW, "its card selected")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "seen" })
	w.flush()
	w.advance(60 * 1000)
	same(inNow(), {}, "Mark seen clears it, and Bob's comment, older than that, does not bring it back")
	yes(select(2, onBoard()) ~= CHANGED, "its card is no longer Changed")
	local later = EPOCH + 2 * 24 * 3600 + 300
	acli.changes["ABC-5"] = changes(later, { comment("bob@example.com", EPOCH + 30), comment("bob@example.com", later) })
	w.advance(600 * 1000) -- its preview below is shown after this comment
	same(inNow(), { ROW .. " Assigned: changed" }, "a newer comment of Bob's changes it again")
	eq(select(2, onBoard()), CHANGED, "on the Board too")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" }) -- the List shows its preview
	w.flush()
	eq(pickerOf(b).selected, ROW, "the List selects it")
	eq(asks.hx.mark(b, ROW), "-", "showing its preview clears it")
	w.advance(60 * 1000)
	same(inNow(), {}, "and Now no longer lists it")
end)

-- Whether Now asked acli's search for exactly `jql`.
local function askedJql(acli: h.Acli, jql: string): boolean
	for _, req in acli.requests do
		if req.kind == "search" and table.find(req.argv, jql) then
			return true
		end
	end
	return false
end

case("now: Jira's assigned work is My sprint's while the site has sprints", function(w: World)
	local _, _, acli = nowScene(w, {})
	yes(askedJql(acli, h.JIRA_NOW), "the open sprint's, as My sprint reads it")
	yes(not askedJql(acli, h.JIRA_ASSIGNED), "not the backlog's")
end)

case("now: without sprints, Jira's assigned work is all your open work", function(w: World)
	local _, _, acli = nowScene(w, {}, function(_, a: h.Acli)
		a.sprints = false
	end)
	yes(askedJql(acli, h.JIRA_ASSIGNED), "all your open work")
	yes(not askedJql(acli, h.JIRA_NOW), "and no sprint query")
end)

case("now: the Assigned heading says new or changed, and the preview says which", function(w: World)
	local _, b = nowScene(w, {}, function(s: h.HostScene)
		s.gh.queries[ASSIGNED] = { issueItem(12, "o/r", EPOCH - 300), issueItem(13, "o/r", EPOCH - 600) }
		w.kv.put("triage", { version = 1, items = { ["o/r#13"] = { at = EPOCH - 3600, seen = "0000000000000000" } } })
	end)
	eq(b.title(), "Plotroom · Now · 2 assigned: new or changed", "the heading says what Now lists of your assigned issues")
	same(whys(b), { "no_2fr_2312 Assigned: new", "no_2fr_2313 Assigned: changed" }, "the badges stay")
	has(textOf(h.pickerNode(b)), "Assigned to you, and you haven't seen it yet", "a New one's preview")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_2313" })
	has(textOf(h.pickerNode(b)), "Assigned to you, and changed since you last saw it", "a Changed one's")
end)

local function ciThreads(n: number): { any }
	local out: { any } = {}
	for i = 1, n do
		table.insert(out, thread(tostring(100 + i), "x/y", "ci_activity", "CI " .. i))
	end
	return out
end

case("now: a login whose notifications fill a whole page says the rest are on github.com", function(w: World)
	local _, b = nowScene(w, ciThreads(50))
	has(textOf(pickerOf(b).subtitle), "Notifications (@octocat): showing the newest 50; the rest are on github.com", "50 threads: the page is full")
end)

case("now: a login one thread short of a whole page has no cut-off line", function(w: World)
	local _, b = nowScene(w, ciThreads(49))
	eq(#pickerOf(b).items, 49, "all listed")
	eq(string.find(textOf(pickerOf(b).subtitle), "showing the newest", 1, true), nil, "49: no line")
end)

-- Now's switches as Settings › Views › Now saves them (kv "now").
local function nowPrefs(w: World, prefs: { [string]: any })
	w.kv.put("now", prefs)
end

-- What Now asked GitHub since request number `from`, as "<login> <source>" (mine, review, teams, dismissed, assigned, notices),
-- sorted and once each.
local function nowAsks(s: h.HostScene, from: number): { string }
	local out: { string } = {}
	for i = from + 1, #s.gh.requests do
		local req = s.gh.requests[i]
		local q = req.fields.q or ""
		local what: string? = if req.kind == "notifications"
			then "notices"
			elseif string.find(q, REVIEW, 1, true) then "review"
			elseif string.find(q, "is:open review-requested:@me", 1, true) then "teams"
			elseif string.find(q, DISMISSED, 1, true) then "dismissed"
			elseif string.find(q, MINE, 1, true) then "mine"
			elseif string.find(q, ASSIGNED, 1, true) then "assigned"
			else nil
		local line = (req.login or "?") .. " " .. (what or "")
		if what and not table.find(out, line) then
			table.insert(out, line)
		end
	end
	table.sort(out)
	return out
end

-- Sets Now's switch `id` (a reason, "teams", "jira" or "login:<login>") as its row in Settings › Views › Now does.
local function flip(w: World, b: h.Block, id: string, value: string)
	goToSettings(b, "views")
	b.event({ ev = "change", id = "layer.settings", item = "now:" .. id, value = value })
	w.flush()
end

case("now: a reason switched off is not read, and its rows, heading part and count are gone at once", function(w: World)
	local s, b = nowScene(w, nil, function(s: h.HostScene)
		s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 90) }
	end)
	eq(b.title(), "Plotroom · Now · 1 review requested · 3 notifications", "listed before")
	goToSettings(b, "views")
	expand(b, "nopen:now")
	eq(h.prefsOf(b).focus, "now:blocked", "Now's card opens on its first switch")
	eq(rowIn(b, "now:review").control.value, "on", "every reason is on by default")
	local from = #s.gh.requests
	flip(w, b, "review", "off")
	same(w.kv.get("now").off, { "review" }, "saved as a reason that is off")
	eq(b.title(), "Plotroom · Now · 3 notifications", "its heading part is gone")
	same(listed(b), { "no_2fr_232", "no_2fr_237", "t13" }, "and its row")
	eq(pickerOf(b).scopes[1].count, 3, "the sidebar does not count it")
	refreshNow(w, b)
	same(nowAsks(s, from), { "octocat assigned", "octocat mine" }, "its searches (requests and dismissed reviews) are not sent (the inbox is not due again yet)")
end)

case("now: with Blocked off and Ready to merge on, your pull requests are still searched and only the ready ones listed", function(w: World)
	local ready = { review = "APPROVED", mergeable = "MERGEABLE", merge = "CLEAN", checks = "SUCCESS" }
	local s, b = nowScene(w, {}, function(s: h.HostScene)
		nowPrefs(w, { off = h.array({ "blocked" }) })
		s.gh.queries[MINE] = { searchItem(1, "o/r", EPOCH - 60, { review = "CHANGES_REQUESTED" }), searchItem(2, "o/r", EPOCH - 120, ready) }
	end)
	same(whys(b), { "no_2fr_232 Ready to merge" }, "the Blocked one is not listed")
	has(table.concat(nowAsks(s, 0), ","), "octocat mine", "your pull requests were searched")
	local from = #s.gh.requests
	flip(w, b, "ready", "off")
	refreshNow(w, b)
	same(nowAsks(s, from), { "octocat assigned", "octocat dismissed", "octocat review" }, "with both off, they are not")
	same(listed(b), {}, "and nothing of theirs is listed")
end)

case("now: your pull request failing only an ignored check is not listed as Blocked; one failing another check is", function(w: World)
	local done = "2026-01-01T00:00:00Z"
	local only = { h.checkRun("approval", "COMPLETED", "FAILURE", done, { id = "A" }) }
	local more = { h.checkRun("approval", "COMPLETED", "FAILURE", done, { id = "B" }), h.checkRun("build", "COMPLETED", "FAILURE", done, { id = "C" }) }
	local _, b = nowScene(w, {}, function(s: h.HostScene)
		w.kv.put("ignored-checks", { ["o/r"] = h.array({ "approval" }) })
		s.gh.queries[MINE] = {
			searchItem(1, "o/r", EPOCH - 60, { review = "APPROVED", merge = "BLOCKED", checks = "FAILURE", runs = h.array(only), runTotal = 1 }),
			searchItem(2, "o/r", EPOCH - 120, { review = "APPROVED", merge = "BLOCKED", checks = "FAILURE", runs = h.array(more), runTotal = 2 }),
		}
		s.gh.checks["o/r#1"], s.gh.checks["o/r#2"] = only, more
	end)
	same(whys(b), { "no_2fr_232 Blocked" }, "only the PR another check blocks needs you")
	eq(pickerOf(b).items[1].badges[2].text, "Fix checks · 1/2 failing", "and its chip counts only the check not ignored")
end)

case("now: a login switched off is neither searched nor asked for notifications; a login that signs in later is on", function(w: World)
	local s, b = nowScene(w, nil, function(s: h.HostScene)
		s.gh.tokens.work = "tok-work"
		s.gh.inbox.work = { thread("31", "w/z", "mention", "Work thing", 4, true) }
		nowPrefs(w, { logins = h.array({ "work" }) })
	end)
	refreshNow(w, b)
	same(nowAsks(s, 0), { "octocat assigned", "octocat dismissed", "octocat mine", "octocat notices", "octocat review" }, "work is asked nothing")
	same(listed(b), { "no_2fr_232", "no_2fr_237", "t13" }, "and its thread is not listed")
	s.gh.tokens.later = "tok-later"
	w.advance(11 * 60 * 1000) -- the signed-in logins are read again
	refreshNow(w, b)
	refreshNow(w, b)
	has(table.concat(nowAsks(s, 0), ","), "later notices", "a login that signs in later is read")
	goToSettings(b, "views")
	expand(b, "nopen:now")
	eq(rowIn(b, "now:login:later").control.value, "on", "and its switch is on")
	eq(rowIn(b, "now:login:work").control.value, "off", "work's is off")
	flip(w, b, "login:work", "on")
	eq(#w.kv.get("now").logins, 0, "only logins that are off are saved")
	has(table.concat(listed(b), ","), "nw_2fz_234", "work's thread is read and listed at once")
end)

case("now: Jira switched off is not searched for Now", function(w: World)
	local _, b, acli = nowScene(w, {})
	yes(askedJql(acli, h.JIRA_NOW), "on by default")
	acli.requests = {}
	flip(w, b, "jira", "off")
	refreshNow(w, b)
	yes(not askedJql(acli, h.JIRA_NOW), "off: not asked")
	eq(w.kv.get("now").jira, false, "saved")
end)

case("now: with team review requests on, a request asked only of your team is listed and names the team; off, it is not", function(w: World)
	local mine = searchItem(4, "o/r", EPOCH - 60, { createdAt = h.iso(EPOCH - 600), teams = h.array({ "acme/web" }), reviewers = h.array({ "octocat" }) })
	local s, b = nowScene(w, {}, function(s: h.HostScene)
		s.gh.queries[REVIEW] = { mine }
		s.gh.queries["is:open review-requested:@me"] = { mine, searchItem(6, "o/r", EPOCH - 60, { createdAt = h.iso(EPOCH - 60), teams = h.array({ "acme/web" }), reviewers = h.array({}) }) }
	end)
	same(listed(b), { "no_2fr_234" }, "off: only the request asked of you")
	local from = #s.gh.requests
	flip(w, b, "teams", "on")
	eq(w.kv.get("now").teams, true, "saved")
	same(nowAsks(s, from), { "octocat assigned", "octocat dismissed", "octocat mine", "octocat teams" }, "the review search asks for your teams' requests too")
	same(whys(b), { "no_2fr_234 Review requested", "no_2fr_236 Review requested" }, "the team's request is listed under Review requested")
	b.press("escape")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_236" })
	has(textOf(h.pickerNode(b)), "Your team's review is requested: @acme/web", "its Why line names the team")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_234" })
	has(textOf(h.pickerNode(b)), "Your review is requested", "one asked of you too says so")
	flip(w, b, "teams", "off")
	same(listed(b), { "no_2fr_234" }, "off again: the team's request is gone")
end)

case("now: an open pull request whose review of yours was dismissed is Review requested; one you approved is not, and a re-request is listed once", function(w: World)
	local s, b = nowScene(w, {}, function(s: h.HostScene)
		local again = searchItem(4, "o/r", EPOCH - 60, { createdAt = h.iso(EPOCH - 600), yours = "DISMISSED" })
		s.gh.queries[REVIEW] = { again }
		s.gh.queries[DISMISSED] = {
			searchItem(8, "o/r", EPOCH - 60, { createdAt = h.iso(EPOCH - 6000), yours = "DISMISSED" }),
			searchItem(9, "o/r", EPOCH - 60, { createdAt = h.iso(EPOCH - 9000), yours = "APPROVED" }),
			searchItem(10, "o/r", EPOCH - 60, { createdAt = h.iso(EPOCH - 9000), yours = "COMMENTED" }),
			again,
		}
	end)
	has(table.concat(nowAsks(s, 0), ","), "octocat dismissed", "your reviewed pull requests are searched")
	same(whys(b), { "no_2fr_238 Review requested", "no_2fr_234 Review requested" }, "the dismissed ones, oldest first, each once; approved and commented ones are not listed")
	eq(b.title(), "Plotroom · Now · 2 reviews requested", "and counted as reviews requested")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_238" })
	has(textOf(h.pickerNode(b)), "Your review was dismissed, so it is requested again", "its Why line says why")
end)

case("now: with every reason off Now reads nothing and lists only agents that need you, and says so", function(w: World)
	local s, b = nowScene(w, nil, function()
		nowPrefs(w, { off = h.array({ "blocked", "review", "ready", "notices", "assigned" }) })
	end)
	same(nowAsks(s, 0), {}, "nothing is read")
	same(listed(b), {}, "nothing is listed")
	has(textOf(pickerOf(b).empty), "Only agents are listed: Settings › Views › Now", "the empty state says why")
	asks.hx.agents(b, { ["o/r#3"] = "waiting_input" })
	same(listed(b), { "no_2fr_233" }, "an agent that needs you is listed")
	eq(b.title(), "Plotroom · Now · 1 agent needs you", "and counted")
end)

case("now: a switch changed in one block applies at once to every other block", function(w: World)
	local _, b = nowScene(w)
	local c = w.open(2, { "/work/r" })
	w.flush()
	eq(c.title(), "Plotroom · Now · 3 notifications", "the other block lists the notifications")
	flip(w, b, "notices", "off")
	eq(c.title(), "Plotroom · Now", "and drops them at once")
	same(listed(c), {}, "from its list too")
end)

-- Now's heading as text: "Now · 3 left", "Now · 2 of 3".
local function heading(b: h.Block): string
	local out: { string } = {}
	for _, span in pickerOf(b).title do
		table.insert(out, if type(span) == "string" then span else span.t)
	end
	return table.concat(out)
end

-- Binds Next in Now to `n` beside the keys the case already has.
local function bindNext(w: World)
	local saved: { [string]: string } = {}
	for id, key in w.kv.get("keys") :: any do
		saved[id] = key
	end
	saved.nownext = "n"
	w.kv.put("keys", saved)
end

case("now: Next in Now shows Now from a view and walks it top first; the heading reads n of N while walking, N left at rest", function(w: World)
	local _, b = nowScene(w)
	bindNext(w)
	local rows = listed(b)
	same(rows, { "no_2fr_232", "no_2fr_237", "t13" }, "three rows")
	eq(heading(b), "Now · 3 left", "at rest the heading says how many are left")
	pickScope(b, "prs:v1")
	w.flush()
	b.typeText("n")
	eq(pickerOf(b).scope, "now", "the key shows Now from a view")
	eq(pickerOf(b).selected, rows[1], "on its first item")
	eq(heading(b), "Now · 1 of 3", "walking")
	b.typeText("n")
	eq(pickerOf(b).selected, rows[2], "then the next one")
	eq(heading(b), "Now · 2 of 3", "counted")
	b.typeText("n")
	eq(pickerOf(b).selected, rows[3], "then the last")
	eq(heading(b), "Now · 3 of 3", "counted")
	b.typeText("n")
	eq(pickerOf(b).selected, rows[3], "nothing comes after the last: it stays")
	eq(w.toasts[#w.toasts].text, "Last in Now", "and says so")
	eq(heading(b), "Now · 3 of 3", "still walking")
	pickScope(b, "prs:v1")
	w.flush()
	pickScope(b, "now")
	w.flush()
	eq(heading(b), "Now · 3 left", "showing Now again is at rest")
	b.typeText("n")
	eq(pickerOf(b).selected, rows[1], "and a new walk starts at the top")
end)

case("now: a hand move or a change of the list stops Next in Now's walk, and the next step resumes from the selected item", function(w: World)
	local s, b = nowScene(w)
	bindNext(w)
	local rows = listed(b)
	b.typeText("n")
	b.typeText("n")
	eq(heading(b), "Now · 2 of 3", "walking on the second")
	b.typeText("j")
	eq(pickerOf(b).selected, rows[3], "moved by hand")
	eq(heading(b), "Now · 3 left", "the walk stopped")
	b.typeText("k")
	eq(heading(b), "Now · 3 left", "and moving back onto its row does not restart it")
	b.typeText("n")
	eq(pickerOf(b).selected, rows[3], "it resumes after the selected item")
	eq(heading(b), "Now · 3 of 3", "walking again")
	b.event({ ev = "select", id = "layer.queue", item = rows[1] })
	eq(heading(b), "Now · 3 left", "a click stops it too")
	b.typeText("n")
	eq(pickerOf(b).selected, rows[2], "and the walk resumes after the clicked item")
	eq(heading(b), "Now · 2 of 3", "walking")
	s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 60) }
	refreshNow(w, b)
	same(listed(b), { "no_2fr_234", "no_2fr_232", "no_2fr_237", "t13" }, "a review request arrives above")
	eq(pickerOf(b).selected, rows[2], "the selection stays on its item")
	eq(heading(b), "Now · 4 left", "the list changed under the walk: it stopped")
	b.typeText("n")
	eq(pickerOf(b).selected, "t13", "it resumes after the selected item")
	eq(heading(b), "Now · 4 of 4", "in the new list")
end)

case("now: Next in Now has no key until bound, is a Commands row under Now and a row of the ? list", function(w: World)
	local _, b = nowScene(w)
	eq(b.press("n", nil, "n"), false, "unbound, n is the pane's")
	local p = h.hx.palette(w, b)
	eq(p.labels.nownext, "Next in Now", "Commands offers it")
	eq(p.groups.nownext, "Now", "under Now")
	eq(p.keys.nownext, "", "with no key")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "nownext" })
	eq(heading(b), "Now · 1 of 3", "its row walks as the key does")
	bindNext(w)
	b.typeText("n")
	eq(heading(b), "Now · 2 of 3", "once bound, n walks on")
	eq(h.hx.palette(w, b).keys.nownext, "n", "and Commands shows the key")
	b.typeText("?")
	local found = false
	for _, r in h.helpRows(b.view().layer) do
		found = found or (r.keys == "n" and string.find(r.text, "Next in Now", 1, true) ~= nil)
	end
	yes(found, "and in the ? list")
end)

case("github: parseNotices keeps a pull request's and an issue's page, drops malformed threads and cleans untrusted text", function(w: World)
	local github = w.load("github") :: any
	local notices = github.parseNotices(h.array({
		thread("1", "o/r", "mention", "Fix\1 it", 5),
		thread("2", "o/r", "assign", "An issue", 6, true),
		thread("3", "o/r", "ci_activity", "CI"),
		thread("x", "o/r", "mention", "bad id", 1),
		thread("4", "../evil", "mention", "bad repo", 1),
		thread("5", "o/r", "Mention!", "bad reason", 1),
		"junk",
	}))
	eq(#notices, 3, "only the well formed threads")
	eq(notices[1].kind .. " " .. tostring(notices[1].number) .. " " .. tostring(notices[1].url), "pr 5 https://github.com/o/r/pull/5", "a pull request's page")
	eq(notices[2].kind .. " " .. tostring(notices[2].number) .. " " .. tostring(notices[2].url), "issue 6 https://github.com/o/r/issues/6", "an issue's")
	eq(notices[3].kind .. " " .. tostring(notices[3].number) .. " " .. tostring(notices[3].url), "other nil nil", "a thread about neither has no page")
	eq(notices[1].title, "Fix it", "control characters are dropped")
end)

case("github: a gh login read from a list cache older than its TTL is still answered, and read again in the background", function(w: World)
	local s = hostScene(w, 3)
	local github = w.load("github") :: any
	local logins: { string } = {}
	local function ask()
		github.login(nil, function(login: string?)
			table.insert(logins, login or "none")
		end)
		w.flush()
	end
	ask()
	w.advance(11 * 60 * 1000)
	ask()
	same(logins, { "octocat", "octocat" }, "the stale value answers the caller who asked")
	eq(#requestsOf(s.gh, "accounts"), 2, "and the list is read again")
end)

local board = h.hx.board

-- A Now with one row in each column but Worktree: o/r#1 Blocked, o/r#5 under a working agent, o/r#4 a review asked of you
-- (PR open), o/r#2 Ready to merge and issue o/r#12 assigned to you and Not started.
local function boardScene(w: World): h.Block
	local _, b = nowScene(w, {}, function(s: h.HostScene)
		s.gh.queries[MINE] = {
			searchItem(1, "o/r", EPOCH - 60, { review = "CHANGES_REQUESTED" }),
			searchItem(2, "o/r", EPOCH - 120, { review = "APPROVED", mergeable = "MERGEABLE", merge = "CLEAN", checks = "SUCCESS" }),
		}
		s.gh.queries[REVIEW] = { searchItem(4, "o/r", EPOCH - 90), searchItem(5, "o/r", EPOCH - 60) }
		s.gh.queries[ASSIGNED] = { issueItem(12, "o/r", EPOCH - 300) }
	end)
	asks.hx.agents(b, { ["o/r#5"] = "working" })
	return b
end

case("now: Show Now as Board lays Now out in columns by stage, the fold closed; Show Now as List goes back", function(w: World)
	local b = boardScene(w)
	eq((board(b)), nil, "Now is a List until asked")
	eq(h.hx.palette(w, b).labels.layout, "Show Now as Board", "Commands offers the Board")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" })
	local cols, selected = board(b)
	same(cols, { "needs: no_2fr_231", "working: no_2fr_235", "waiting: no_2fr_234", "ready: no_2fr_232" }, "Needs you (Blocked), Agent working, Waiting (PR open), Ready to merge; the fold's columns are not drawn")
	eq(selected, "layer.queue.board.lanes.needs.list.no_2fr_231", "the selection stays on Now's top row")
	same(listed(b), {}, "the picker lists nothing of its own")
	has(pickerOf(b).role, ".board", "and its role says the Board takes its place")
	local fold: any = h.findKey(h.pickerNode(b), "fold", "item")
	eq(fold.p.label, "Show Not started 1 · Worktree 0", "the fold's button counts what it hides")
	eq(fold.p.role, "plotroom.button", "and is drawn as a button")
	b.event({ ev = "action", id = "layer.queue.board.foldbar.fold", act = fold.p.actions.click })
	local opened = board(b) or {}
	eq(opened[5], "none: no_2fr_2312", "it opens the fold: Not started")
	eq(opened[6], "worktree: ", "and Worktree")
	eq(h.hx.palette(w, b).labels.layout, "Show Now as List", "Commands now offers the List")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" })
	eq((board(b)), nil, "which goes back")
	eq(#listed(b), 5, "listing Now's rows again")
end)

case("now: on the Board the arrows and h/j/k/l move in and across columns, into the fold, which opens", function(w: World)
	local b = boardScene(w)
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" })
	local function at(): string
		local _, selected = board(b)
		return string.match(selected or "", "board%.%a+%.(.*)$") or "none"
	end
	b.press("right")
	eq(at(), "working.list.no_2fr_235", "Right moves to the next column")
	b.typeText("l")
	eq(at(), "waiting.list.no_2fr_234", "and so does l")
	b.press("down")
	eq(at(), "waiting.list.no_2fr_234", "Down stops at the column's last row")
	b.typeText("ll")
	eq(at(), "none.list.no_2fr_2312", "moving past Ready to merge goes into the fold and opens it")
	b.typeText("l")
	eq(at(), "none.list.no_2fr_2312", "an empty column (Worktree) is skipped, and there is nothing after it")
	b.typeText("h")
	eq(at(), "ready.list.no_2fr_232", "h moves back")
	b.press("left")
	b.press("left")
	b.press("left")
	b.press("left")
	eq(at(), "needs.list.no_2fr_231", "and Left stops at the first column")
	b.event({ ev = "select", id = "layer.queue.board.lanes.waiting.list", item = "layer.queue.board.lanes.waiting.list.no_2fr_234" })
	eq(at(), "waiting.list.no_2fr_234", "a click on a card selects it")
	b.press("enter")
	eq(b.state().nowOn, false, "Enter shows its item, as in the List")
end)

case("now: below 80 columns the Board shows as the List; the choice is Now's Layout, which every block shows", function(w: World)
	local b = boardScene(w)
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" })
	eq(w.kv.get("now").board, true, "the choice is saved as Now's Layout")
	b.cx.cols = 79
	b.render()
	eq((board(b)), nil, "a narrow block shows the List")
	eq(#listed(b), 5, "with every row")
	b.press("down")
	eq(pickerOf(b).selected, "no_2fr_234", "and the List's keys")
	b.cx.cols = 80
	b.render()
	yes(board(b) ~= nil, "wide enough again, the Board")
	local again = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	yes(board(again) ~= nil, "another block opens on the Board")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "layout" })
	w.flush()
	eq((board(again)), nil, "and goes back to the List with it")
end)

case("now: Settings › Views › Now › Layout saves Now's List or Board; a store without it is the List, and a malformed one is never written over", function(w: World)
	local b = boardScene(w)
	goToSettings(b, "views")
	expand(b, "nopen:now")
	local row = rowIn(b, "now:layout")
	eq(row.label, "Layout", "Now's card has a Layout row")
	eq(row.control.value, "list", "an older store without one is the List")
	b.event({ ev = "change", id = "layer.settings", item = "now:layout", value = "board" })
	eq(w.kv.get("now").board, true, "Board is saved with Now's switches")
	yes(board(b) ~= nil, "and Now shows as a Board")
	eq(h.hx.palette(w, b).labels.layout, "Show Now as List", "which Commands knows")
	b.event({ ev = "change", id = "layer.settings", item = "now:layout", value = "list" })
	eq(w.kv.get("now").board, false, "List saves it off")
	eq((board(b)), nil, "and Now is a List again")
	w.kv.put("now", { off = "review" })
	b.event({ ev = "change", id = "layer.settings", item = "now:layout", value = "board" })
	eq(w.kv.get("now").off, "review", "a malformed store is not written over")
	eq((board(b)), nil, "and Now stays a List")
end)

return {}
