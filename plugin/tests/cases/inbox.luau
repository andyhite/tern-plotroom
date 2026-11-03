--!strict
-- Regression cases: Now (everything that needs you, ranked), its reads and pacing, its Mark read… plan and its problems.

local h = require("../harness")

type GhReq = h.GhReq
type Reply = h.Reply
type World = h.World

local asks, case, collectTexts, eq, has = h.asks, h.case, h.collectTexts, h.eq, h.has
local hostScene, issueItem, jiraItem, listed, newAcli = h.hostScene, h.issueItem, h.jiraItem, h.listed, h.newAcli
local pickScope, pickerOf, refreshNow, requestsOf, same, searchItem, yes = h.pickScope, h.pickerOf, h.refreshNow, h.requestsOf, h.same, h.searchItem, h.yes
local EPOCH = h.EPOCH

-- Now's fixed searches, as the gh model tells them apart.
local MINE, REVIEW, ASSIGNED = "author:@me archived:false", "user-review-requested:@me", "assignee:@me archived:false"

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

local function sentSince(req: GhReq): string?
	for _, a in req.call.argv do
		local stamp = string.match(a, "^If%-Modified%-Since: (.*)$")
		if stamp then
			return stamp
		end
	end
	return nil
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
		acli.searches[h.JIRA_ASSIGNED] = { jiraItem("ABC-1", "Fix login") }
	end)
	local scopes = pickerOf(b).scopes
	eq(scopes[1].id, "now", "Now is first in the sidebar")
	eq(pickerOf(b).scope, "now", "and shown when the block opens")
	eq(pickerOf(b).selected, "no_2fr_231", "on its top row")
	asks.hx.agents(b, { ["o/r#3"] = "waiting_input" })
	scopes = pickerOf(b).scopes
	same(whys(b), {
		"no_2fr_233 Agent needs input",
		"no_2fr_231 Blocked: changes requested",
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
			eq(h.detailText(row), "#1 · o/r", "a Now row names its repository (Now spans them all) and leaves what blocks it to its first badge")
		end
	end
	eq(pickerOf(b).selected, "no_2fr_231", "the selection stays on its row as rows arrive above it")
	eq(scopes[1].count, 9, "the sidebar counts them")
	local need = "1 agent needs you · 1 Blocked · 2 reviews requested · 1 Ready to merge · 2 notifications · 2 assigned"
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
	eq(b.title(), "Plotroom · Now · 1 review requested", "and still not counted")
	b.typeText("Z")
	asks.hx.agents(b, { ["o/r#4"] = "waiting_input" })
	same(listed(b), { "no_2fr_234", "no_2fr_235" }, "an agent that needs input lists its snoozed item")
	eq(pickerOf(b).items[1].badges[1].text, "Agent needs input", "first")
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

case("now: an unchanged inbox costs nothing: no read within X-Poll-Interval, then a conditional read whose 304 keeps the rows", function(w: World)
	local s, b = nowScene(w, nil, function(s: h.HostScene)
		s.gh.inboxPoll = 300
	end)
	refreshNow(w, b)
	local before = #pickerOf(b).items
	eq(#requestsOf(s.gh, "notifications"), 1, "read once")
	w.advance(200 * 1000)
	w.flush()
	eq(#requestsOf(s.gh, "notifications"), 1, "nothing is sent within the poll interval, Refresh or the queue's own refresh included")
	w.advance(101 * 1000)
	w.flush()
	local reads = requestsOf(s.gh, "notifications")
	eq(#reads, 2, "after it the queue's refresh reads again")
	eq(sentSince(reads[1]), nil, "the first read is unconditional")
	eq(sentSince(reads[2]), "Mon, 19 Oct 2026 09:00:00 GMT", "the next carries Last-Modified back")
	eq(#pickerOf(b).items, before, "a 304 keeps the rows")
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

case("now: Mark read… plans only the threads Now lists: a thread about an item listed higher is not among them", function(w: World)
	local s, b = nowScene(w)
	s.gh.queries[REVIEW] = { searchItem(2, "o/r", EPOCH - 60) }
	refreshNow(w, b)
	same(listed(b), { "no_2fr_232", "no_2fr_237", "t13" }, "o/r#2 is listed once, as a review request")
	eq(pickerOf(b).items[1].badges[1].text, "Review requested", "for its higher rank")
	local p = asks.hx.ask(w, b, { op = "act", name = "mark-read" })
	eq(p.confirm.head, "Mark 2 notifications read?", "only the two threads Now lists as notifications")
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
	s.gh.inboxStamp.octocat = "Tue, 20 Oct 2026 09:00:00 GMT"
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
	acli.searches[h.JIRA_ASSIGNED] = { jiraItem("ABC-1", "Fix login") }
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
	local actions: { string } = {}
	for _, a in pickerOf(b).actions do
		table.insert(actions, a.id)
	end
	eq(table.find(actions, "agentreply"), nil, "nor is its button")
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

return {}
