--!strict
-- Regression cases: the Inbox list (gh's unread, participating notifications), its polling, its mark-read plan and its problems.

local h = require("../harness")

type GhReq = h.GhReq
type Reply = h.Reply
type World = h.World

local asks, case, collectTexts, detailText, eq, has = h.asks, h.case, h.collectTexts, h.detailText, h.eq, h.has
local hostScene, openQueue, pickScope, pickerOf, refreshNow = h.hostScene, h.openQueue, h.pickScope, h.pickerOf, h.refreshNow
local requestsOf, same, yes = h.requestsOf, h.same, h.yes

-- One notification thread as GitHub's API answers it; `n` its pull request (or issue, `issue`) number, none for a thread
-- that is about neither (CI).
local function thread(id: string, repo: string, reason: string, title: string, n: number?, issue: boolean?, at: string?): { [string]: any }
	local subject: { [string]: any } = { title = title, type = if n then (if issue then "Issue" else "PullRequest") else "CheckSuite" }
	if n then
		subject.url = "https://api.github.com/repos/" .. repo .. "/" .. (if issue then "issues" else "pulls") .. "/" .. n
	end
	return { id = id, unread = true, reason = reason, updated_at = at or "2026-10-19T08:00:00Z", subject = subject, repository = { full_name = repo } }
end

-- A scene whose active login octocat has notifications; the block is open on its first view.
local function inboxScene(w: World, threads: { any }?): (h.HostScene, h.Block)
	local s = hostScene(w, 3)
	s.gh.tokens.octocat = "tok-octocat"
	s.gh.inbox.octocat = threads or {
		thread("11", "o/r", "review_requested", "Add feature", 2),
		thread("12", "o/r", "mention", "Login is broken", 7, true),
		thread("13", "x/y", "ci_activity", "CI failed on main"),
	}
	return s, openQueue(w)
end

local function textOf(node: any): string
	local out: { string } = {}
	collectTexts(node, out)
	return table.concat(out)
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

case("inbox: the sidebar ends with the Inbox list, after Agents, which lists gh's active login's unread participating notifications by repository with reason and item", function(w: World)
	local s, b = inboxScene(w)
	local scopes = pickerOf(b).scopes
	eq(scopes[#scopes].id, "inbox", "the sidebar ends with the Inbox")
	eq(scopes[#scopes - 1].id, "agents", "after Agents")
	eq(scopes[#scopes].count, nil, "its count is unknown before it is read")
	eq(#requestsOf(s.gh, "notifications"), 0, "nothing is read until it is opened")
	pickScope(b, "inbox")
	w.flush()
	eq(pickerOf(b).scope, "inbox", "opening it makes it the active scope")
	eq(pickerOf(b).noun, "notifications", "the list holds notifications")
	local reads = requestsOf(s.gh, "notifications")
	eq(#reads, 1, "one read")
	eq(reads[1].login, "octocat", "as gh's active login")
	yes(table.find(reads[1].call.argv, "notifications?participating=true&per_page=50") ~= nil, "of the unread notifications it takes part in")
	local rows: { string } = {}
	for _, item in pickerOf(b).items do
		table.insert(rows, item.label .. " | " .. detailText(item) .. " | " .. item.badges[1].text)
	end
	same(rows, { "Add feature | Review requested · #2 | Review requested", "Login is broken | Mention · #7 | Mention", "CI failed on main | CI | CI" }, "title, reason and the pull request or issue; a CI thread has none")
	eq(pickerOf(b).order[1].label, "o/r", "grouped by repository")
	eq(pickerOf(b).order[1].count, 2, "counting its threads")
	eq(pickerOf(b).order[4].label, "x/y", "the next repository")
	scopes = pickerOf(b).scopes
	eq(scopes[#scopes].count, 3, "the sidebar counts them")
	eq(pickerOf(b).selected, "n11", "the first is selected on arrival")
	b.press("down")
	eq(pickerOf(b).selected, "n12", "Down moves to the next")
	pickScope(b, "prs:v1")
	eq(pickerOf(b).scope, "prs:v1", "a click on the view leaves the Inbox")
end)

case("inbox: Enter shows the notification's pull request in the block as a linked one is, an issue pinned, and a thread about neither says so", function(w: World)
	local s, b = inboxScene(w)
	s.gh.pulls["https://github.com/o/r/issues/7"] = nil
	pickScope(b, "inbox")
	w.flush()
	eq(b.press("enter"), true, "Enter shows the first")
	eq(pickerOf(b).scope, "prs:v1", "a pull request the view lists is selected in place")
	eq(pickerOf(b).selected, "no_2fr_232", "that very one")
	eq(#b.state().pins, 0, "nothing is pinned for it")
	pickScope(b, "inbox")
	w.flush()
	b.press("down")
	b.press("enter")
	eq(#b.state().pins, 1, "an issue the view does not list is pinned")
	eq(b.state().pins[1].query, "https://github.com/o/r/issues/7", "by its page")
	pickScope(b, "inbox")
	w.flush()
	b.press("down")
	b.press("down")
	eq(pickerOf(b).selected, "n13", "the CI thread is selected")
	local toasts = #w.toasts
	b.press("enter")
	eq(w.toasts[toasts + 1].text, "Nothing to show", "it is about no pull request or issue")
	eq(pickerOf(b).scope, "inbox", "and the Inbox stays")
end)

case("inbox: an unchanged inbox costs nothing: no read within X-Poll-Interval, then a conditional read whose 304 keeps the rows, and a change is read in full", function(w: World)
	local s, b = inboxScene(w)
	s.gh.inboxPoll = 300
	pickScope(b, "inbox")
	w.flush()
	local before = #pickerOf(b).items
	eq(#requestsOf(s.gh, "notifications"), 1, "read once")
	refreshNow(w, b)
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
	refreshNow(w, b)
	eq(#requestsOf(s.gh, "notifications"), 2, "the 304 renewed the poll interval")
	s.gh.inboxStamp.octocat = "Tue, 20 Oct 2026 09:00:00 GMT"
	s.gh.inbox.octocat = { thread("21", "o/r", "assign", "Take this", 2) }
	w.advance(400 * 1000)
	w.flush()
	reads = requestsOf(s.gh, "notifications")
	eq(#reads, 3, "a later read")
	eq(sentSince(reads[3]), "Mon, 19 Oct 2026 09:00:00 GMT", "still conditional on what it knew")
	eq(#pickerOf(b).items, 1, "a changed inbox is shown whole")
	eq(pickerOf(b).items[1].label, "Take this", "with its new row")
end)

case("inbox: a 304 that gh reports with a zero exit still keeps the rows", function(w: World)
	local s, b = inboxScene(w)
	pickScope(b, "inbox")
	w.flush()
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "notifications" then
			return { stdout = "HTTP/2.0 304 Not Modified\r\nX-Poll-Interval: 60\r\n\r\n" }
		end
		return nil
	end
	w.advance(61 * 1000)
	w.flush()
	eq(#requestsOf(s.gh, "notifications"), 2, "read again")
	eq(#pickerOf(b).items, 3, "the rows stand")
	eq(pickerOf(b).state, "ready", "with no problem")
end)

case("inbox: Mark read… plans the listed threads as the login captured then, and commits exactly those after one confirm", function(w: World)
	local s, b = inboxScene(w)
	s.gh.tokens.other = "tok-other"
	pickScope(b, "inbox")
	w.flush()
	local p = asks.hx.ask(w, b, { op = "act", name = "inbox-read" })
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
	eq(#pickerOf(b).items, 0, "the list is read again and holds what is left")
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "no longer valid", "a plan commits once")
end)

case("inbox: a read still in flight when Mark read… commits cannot put the marked threads back", function(w: World)
	local s, b = inboxScene(w)
	s.gh.inboxPoll = 1
	pickScope(b, "inbox")
	w.flush()
	local stale = true
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "notifications" and stale then
			stale = false -- the periodic read starts now and answers, with the list as it was, long after the mark
			local body = '[{"id":"11","unread":true,"reason":"mention","updated_at":"2026-10-19T08:00:00Z","subject":{"title":"Add feature","type":"Issue","url":"https://api.github.com/repos/o/r/issues/2"},"repository":{"full_name":"o/r"}}]'
			return { stdout = "HTTP/2.0 200 OK\r\nX-Poll-Interval: 1\r\nLast-Modified: Mon, 19 Oct 2026 09:00:00 GMT\r\n\r\n" .. body, delay = 600 * 1000 }
		end
		return nil
	end
	local p = asks.hx.ask(w, b, { op = "act", name = "inbox-read" })
	w.advance(125 * 1000)
	eq(stale, false, "the periodic read is in flight")
	s.gh.inbox.octocat = {}
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).ok, true, "committed")
	w.advance(700 * 1000)
	w.flush()
	eq(#pickerOf(b).items, 0, "the older answer is ignored: nothing marked is listed again")
end)

case("inbox: a mark-read plan is refused after the view changed, when the list is empty, and stops at the first thread that fails", function(w: World)
	local s, b = inboxScene(w)
	has(asks.hx.ask(w, b, { op = "act", name = "inbox-read" }).problem, "lists no notifications", "the Inbox is not shown")
	pickScope(b, "inbox")
	w.flush()
	local p = asks.hx.ask(w, b, { op = "act", name = "inbox-read" })
	pickScope(b, "prs:v1")
	w.flush()
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "selection or the view changed", "after the Inbox was left")
	eq(#s.gh.inboxRead, 0, "nothing was sent")
	pickScope(b, "inbox")
	w.flush()
	p = asks.hx.ask(w, b, { op = "act", name = "inbox-read" })
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

case("inbox: the palette offers Mark read… only while the Inbox lists notifications", function(w: World)
	local s, b = inboxScene(w, {})
	pickScope(b, "inbox")
	w.flush()
	eq(table.find(h.hx.palette(w, b).commands, "inbox-read"), nil, "an empty Inbox offers none")
	s.gh.inboxStamp.octocat = "Tue, 20 Oct 2026 09:00:00 GMT"
	s.gh.inbox.octocat = { thread("11", "o/r", "mention", "Hello", 2) }
	w.advance(125 * 1000)
	w.flush()
	local p = h.hx.palette(w, b)
	yes(table.find(p.commands, "inbox-read") ~= nil, "a listed notification offers it")
	eq(p.commandGroups["inbox-read"], "Inbox", "under Inbox")
end)

case("inbox: a login that cannot read notifications shows the problem and the gh auth refresh that fixes it, and nothing falls back to another login", function(w: World)
	local s, b = inboxScene(w)
	s.gh.tokens.other = "tok-other"
	s.gh.inbox.other = { thread("99", "o/r", "mention", "Not yours", 2) }
	s.gh.inboxDenied.octocat = true
	pickScope(b, "inbox")
	w.flush()
	eq(pickerOf(b).state, "error", "the list is in error")
	local message = textOf(pickerOf(b).message)
	has(message, "@octocat cannot read GitHub notifications", "says whose")
	has(message, "gh auth refresh -h github.com -s notifications", "and the command that fixes it")
	eq(#pickerOf(b).items, 0, "no row")
	for _, req in requestsOf(s.gh, "notifications") do
		eq(req.login, "octocat", "no read was made as another login")
	end
	has(asks.hx.ask(w, b, { op = "act", name = "inbox-read" }).problem, "lists no notifications", "and there is nothing to mark")
end)

case("inbox: without gh the list says so", function(w: World)
	local s = hostScene(w, 3)
	h.hx.uninstalled(w, "gh")
	h.hx.uninstalled(w, "acli")
	local b = openQueue(w)
	pickScope(b, "inbox")
	w.flush()
	eq(#requestsOf(s.gh, "notifications"), 0, "nothing was read")
	has(textOf(pickerOf(b).message), "gh auth login", "the problem names the fix")
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
