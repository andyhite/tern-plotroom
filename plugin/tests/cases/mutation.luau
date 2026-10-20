--!strict
-- Regression cases: github, jira and worktree mutations.

local h = require("../harness")

type AcliReq = h.AcliReq
type Github = h.Github
type Jira = h.Jira
type Reply = h.Reply
type Worktree = h.Worktree
type World = h.World

local EPOCH, array, asks, case, checkRun, countLog = h.EPOCH, h.array, h.asks, h.case, h.checkRun, h.countLog
local eq, has, jiraItem, jsonEncode, lacks = h.eq, h.has, h.jiraItem, h.jsonEncode, h.lacks
local newAcli, newGh, requestsOf, runChecks, runSearch = h.newAcli, h.newGh, h.requestsOf, h.runChecks, h.runSearch
local same, searchItem, sha, snapshot, yes = h.same, h.searchItem, h.sha, h.snapshot, h.yes

case("github.parseItemUrl: only https github.com pull and issues links, a query, fragment or one trailing slash ignored", function(w: World)
	local github = w.load("github") :: Github
	local brief = asks.bk.brief
	eq(brief(github.parseItemUrl("https://github.com/o/r/pull/5")), "pr:o/r:5", "pull request")
	eq(brief(github.parseItemUrl("https://github.com/o/r/issues/7")), "issue:o/r:7", "issue")
	eq(brief(github.parseItemUrl("https://github.com/o/r/pull/5/")), "pr:o/r:5", "trailing slash")
	eq(brief(github.parseItemUrl("https://github.com/o/r/pull/5?diff=split#discussion_r1")), "pr:o/r:5", "query and fragment")
	for _, url in {
		"http://github.com/o/r/pull/5",
		"https://github.com/o/r/pulls/5",
		"https://github.com/o/r/pull/0",
		"https://github.com/o/r/pull/5/files",
		"https://github.com/o/r/pull/99999999999",
		"https://github.com/o/r/commit/5",
		"https://github.com/o/../pull/5",
		"https://evil.com/o/r/pull/5",
		"https://github.com.evil.com/o/r/pull/5",
		"https://github.com/o/r",
		"",
	} do
		eq(brief(github.parseItemUrl(url)), "nil", "refused: " .. url)
	end
	eq(brief(github.parseItemUrl(nil)), "nil", "not a string")
end)

case("github.runIdOf: a workflow run id from a job or run link, never from a check suite or check run link", function(w: World)
	local github = w.load("github") :: Github
	eq(github.runIdOf("https://github.com/o/r/actions/runs/123/job/456"), "123", "job link")
	eq(github.runIdOf("https://github.com/o/r/actions/runs/123"), "123", "run link")
	for _, url in {
		"https://github.com/o/r/runs/456",
		"https://github.com/o/r/suites/789",
		"https://github.com/o/r/actions/runs/0/job/1",
		"https://github.com/o/r/actions/runs/1234567890123456",
		"http://github.com/o/r/actions/runs/123",
		"https://example.com/o/r/actions/runs/123",
	} do
		eq(github.runIdOf(url), nil, "no run id: " .. url)
	end
	eq(github.runIdOf(nil), nil, "not a string")
end)

case("github: Run.runId is set by the search and by the checks detail, only for workflow links", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local base = "https://github.com/o/r"
	local list = {
		checkRun("build", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { id = "A", detailsUrl = base .. "/actions/runs/123/job/9" }),
		checkRun("lint", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "B", detailsUrl = base .. "/runs/77" }),
		{ context = "ci/x", state = "FAILURE", targetUrl = base .. "/actions/runs/456", id = "C" },
	}
	gh.items.octocat = { searchItem(5, "o/r", EPOCH - 60, { runs = array(list), runTotal = 3 }) }
	gh.checks["o/r#5"] = list
	local function ids(runs: any): string
		local out: { string } = {}
		for _, run in runs do
			table.insert(out, run.name .. "=" .. tostring(run.runId))
		end
		table.sort(out)
		return table.concat(out, ",")
	end
	local want = "build=123,ci/x=456,lint=nil"
	eq(ids(runSearch(w, github, nil).result.prs[1].runs), want, "from the search")
	local detail = runChecks(github, nil)
	w.flush()
	eq(ids(detail.runs), want, "from the detail load")
end)

case("github.editIssue: an invalid input is refused before gh runs, a valid edit is one argv with --flag=value", function(w: World)
	local github = w.load("github") :: Github
	local gh, seen = asks.bk.gh(w, function(_line: string): Reply?
		return { stdout = "" }
	end)
	local function edit(e: any, account: string?): any
		return asks.bk.once(w, function(done)
			github.editIssue(e, account, done)
		end)
	end
	local refused: { [string]: any } = {
		["a label with a control character"] = { repo = "o/r", number = 5, addLabels = { "a\tb" } },
		["a label that starts with a dash"] = { repo = "o/r", number = 5, addLabels = { "-x" } },
		["a label added and removed"] = { repo = "o/r", number = 5, addLabels = { "bug" }, removeLabels = { "BUG" } },
		["an assignee added and removed"] = { repo = "o/r", number = 5, addAssignees = { "bob" }, removeAssignees = { "Bob" } },
		["a login with a space"] = { repo = "o/r", number = 5, addAssignees = { "bob smith" } },
		["no change"] = { repo = "o/r", number = 5 },
		["a repo that is not owner/name"] = { repo = "o", number = 5, addLabels = { "bug" } },
		["a fractional number"] = { repo = "o/r", number = 5.5, addLabels = { "bug" } },
	}
	for what, e in refused do
		local p = edit(e, nil)
		eq(p and p.kind, "invalid", what .. ": invalid")
	end
	eq(#w.calls, 0, "nothing was spawned for any of them")
	eq(#seen, 0, "gh never ran")
	eq(edit({ repo = "o/r", number = 5, addAssignees = { "@me", "bob" }, removeAssignees = { "ann" }, addLabels = { "good first issue", "a,b" }, removeLabels = { "wip" } }, nil), nil, "a valid edit succeeds")
	same(seen, { "gh issue edit 5 --repo github.com/o/r --add-assignee=@me --add-assignee=bob --remove-assignee=ann --add-label=\"good first issue\" --add-label=\"a,b\" --remove-label=\"wip\"" }, "one argv, every label CSV-quoted: a comma stays inside one label")
	eq(#gh.requests, 1, "one gh request")
end)

case("github: a saved gh login that cannot sign in sends no mutation", function(w: World)
	local github = w.load("github") :: Github
	local gh, seen = asks.bk.gh(w, function(_line: string): Reply?
		return { stdout = "https://github.com/o/r/pull/9\n" }
	end)
	local e = asks.bk.once(w, function(done)
		github.editIssue({ repo = "o/r", number = 5, addLabels = { "bug" } }, "ghost", done)
	end)
	eq(e.kind, "auth", "edit: the account is not signed in")
	local r = asks.bk.once(w, function(done)
		github.rerunFailed("o/r", "123", "ghost", done)
	end)
	eq(r.kind, "auth", "rerun: the account is not signed in")
	local created: any = nil
	local problem = asks.bk.once(w, function(done)
		github.createPr({ repo = "o/r", base = "main", head = "feat", title = "T", body = "B", draft = true }, "ghost", function(url, p)
			created = url
			done(p)
		end)
	end)
	eq(problem.kind, "auth", "create: the account is not signed in")
	eq(created, nil, "no URL")
	eq(#seen, 0, "no mutation or read of a run was spawned")
	eq(#requestsOf(gh, "token"), 3, "only the token reads ran")
end)

case("github.rerunFailed: only a finished, failed run of the repository is re-run, with its own argv", function(w: World)
	local github = w.load("github") :: Github
	local view = "gh run view 123 --repo github.com/o/r --json databaseId,status,conclusion,url"
	local run: { [string]: any } = { databaseId = 123, status = "completed", conclusion = "failure", url = "https://github.com/o/r/actions/runs/123" }
	local missing = false
	local gh, seen = asks.bk.gh(w, function(line: string): Reply?
		if line == view then
			if missing then
				return { status = 1, stderr = "HTTP 404: Not Found\n" }
			end
			return { stdout = jsonEncode(run) }
		end
		return { stdout = "" }
	end)
	local function rerun(id: string): any
		return asks.bk.once(w, function(done)
			github.rerunFailed("o/r", id, nil, done)
		end)
	end
	local function reruns(): number
		local n = 0
		for _, line in seen do
			if string.find(line, "run rerun", 1, true) then
				n += 1
			end
		end
		return n
	end
	for _, bad in { "12a", "0", "", "-1", "1234567890123456" } do
		eq(rerun(bad).kind, "invalid", "refused id " .. bad)
	end
	eq(#seen, 0, "a malformed id spawns nothing")
	missing = true
	eq(rerun("123").kind, "not-found", "a run that is not this repository's")
	eq(reruns(), 0, "no rerun for it")
	missing = false
	run.databaseId = 999
	eq(rerun("123").kind, "failed", "gh answered another run")
	run.databaseId = 123
	run.status = "in_progress"
	eq(rerun("123").kind, "invalid", "a run that has not finished")
	run.status = "completed"
	run.conclusion = "success"
	eq(rerun("123").kind, "invalid", "a run that passed")
	eq(reruns(), 0, "none of those re-ran")
	run.conclusion = "failure"
	eq(rerun("123"), nil, "a failed run is re-run")
	eq(reruns(), 1, "one rerun")
	eq(seen[#seen], "gh run rerun 123 --repo github.com/o/r --failed", "failed jobs only, in the same repository")
	eq(#gh.requests > 0, true, "gh was used")
end)

case("github.createPr: an exact draft argv, and bad input is refused before gh runs", function(w: World)
	local github = w.load("github") :: Github
	local reply = "https://github.com/o/r/pull/9\n"
	local gh, seen = asks.bk.gh(w, function(_line: string): Reply?
		return { stdout = reply }
	end)
	local function create(d: any): (string?, any)
		local url: string? = nil
		local p = asks.bk.once(w, function(done)
			github.createPr(d, nil, function(u, problem)
				url = u
				done(problem)
			end)
		end)
		return url, p
	end
	local good: { [string]: any } = { repo = "o/r", base = "main", head = "feat/x", title = "Fix login", body = "Closes #4\n- a", draft = true }
	local function with(key: string, value: any): any
		local copy: { [string]: any } = {}
		for k, v in good do
			copy[k] = v
		end
		copy[key] = value
		return copy
	end
	local invalid: { [string]: any } = {
		["draft = false"] = with("draft", false),
		["a head with spaces"] = with("head", "my branch"),
		["a head that starts with a dash"] = with("head", "--web"),
		["a base with a dot-dot"] = with("base", "a..b"),
		["a title with a newline"] = with("title", "a\nb"),
		["a blank title"] = with("title", "  "),
		["a body of the wrong type"] = with("body", 5),
		["a repo with a slash too many"] = with("repo", "o/r/x"),
	}
	for what, d in invalid do
		local url, p = create(d)
		eq(url, nil, what .. ": no url")
		eq(p and p.kind, "invalid", what .. ": invalid")
	end
	eq(#seen, 0, "none of them reached gh")
	local url, p = create(good)
	eq(p, nil, "problem")
	eq(url, "https://github.com/o/r/pull/9", "the new pull request's URL")
	same(w.calls[#w.calls].argv, { "gh", "pr", "create", "--repo", "github.com/o/r", "--draft", "--base=main", "--head=feat/x", "--title=Fix login", "--body=Closes #4\n- a" }, "the argv: draft, explicit head and base, no --fill")
	local fork = create(with("head", "fork:feat"))
	eq(fork, "https://github.com/o/r/pull/9", "a fork's owner:branch head is allowed")
	reply = "done\n"
	local _, odd = create(good)
	eq(odd.kind, "failed", "gh printing no URL is a failure")
	eq(#gh.requests, 3, "three creates ran")
end)

case("jira.parseUrl and keyOfUrl: browse and board links, refused on another site or another shape", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local key, host = jira.parseUrl("https://acme.atlassian.net/browse/ABC-1")
	eq(key, "ABC-1", "browse key")
	eq(host, "acme.atlassian.net", "host")
	eq((jira.parseUrl("https://acme.atlassian.net/browse/ABC-1/")), "ABC-1", "trailing slash")
	eq((jira.parseUrl("https://acme.atlassian.net/jira/software/projects/ABC/boards/1?selectedIssue=ABC-12")), "ABC-12", "board link")
	for _, url in { "http://acme.atlassian.net/browse/ABC-1", "https://acme.atlassian.net/browse/abc-1", "https://acme.atlassian.net/browse/ABC-1/x", "https://acme.atlassian.net/", "ftp://x" } do
		eq((jira.parseUrl(url)), nil, "refused: " .. url)
	end
	eq((jira.parseUrl(nil)), nil, "not a string")
	local function keyOf(url: string): (string?, any)
		local k: string?, p: any = nil, nil
		local calls = 0
		jira.keyOfUrl(url, function(a, b)
			calls += 1
			k, p = a, b
		end)
		eq(calls, 0, "never synchronous")
		w.flush()
		eq(calls, 1, "answers once")
		return k, p
	end
	local k, p = keyOf("https://other.atlassian.net/browse/ABC-1")
	eq(k, nil, "another site: no key")
	eq(p.kind, "invalid", "another site: invalid")
	has(p.message, "other.atlassian.net", "names the site it saw")
	eq((keyOf("https://ACME.atlassian.net/browse/ABC-1")), "ABC-1", "the signed-in site, in any letter case")
	local before = #acli.requests
	local _, notJira = keyOf("https://acme.atlassian.net/wiki/x")
	eq(notJira.kind, "invalid", "not a work item link")
	eq(#acli.requests, before, "acli was not asked about it")
end)

case("jira.item: one work item by key, as the list's items; a bad key or another item is refused", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	acli.views["ABC-1"] = jiraItem("ABC-1", "Fix login")
	acli.views["ABC-2"] = jiraItem("ABC-3", "Another")
	local function item(key: string): (any, any)
		local got: any, problem: any = nil, nil
		local calls = 0
		jira.item(key, function(i, p)
			calls += 1
			got, problem = i, p
		end)
		eq(calls, 0, "never synchronous")
		w.flush()
		eq(calls, 1, "answers once")
		return got, problem
	end
	local issue, problem = item("ABC-1")
	eq(problem, nil, "problem")
	eq(issue.ref, "ABC-1", "ref")
	eq(issue.title, "Fix login", "title")
	eq(issue.url, "https://acme.atlassian.net/browse/ABC-1", "browse URL")
	local view = acli.requests[#acli.requests].argv
	eq(view[4], "view", "a view")
	eq(view[5], "ABC-1", "of that key")
	local _, other = item("ABC-2")
	eq(other.kind, "failed", "acli printed another work item")
	local count = #acli.requests
	local _, bad = item("abc-1; rm")
	eq(bad.kind, "failed", "a bad key")
	eq(#acli.requests, count, "acli was not run for it")
end)

case("jira.assignMe: one acli argv for the signed-in user, a bad key spawns nothing", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local failing = false
	acli.override = function(req: AcliReq): Reply?
		if req.kind ~= "other" then
			return nil
		end
		return if failing then { status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login'\n" } else { stdout = "✓ done\n" }
	end
	local function assign(key: string): any
		return asks.bk.once(w, function(done)
			jira.assignMe(key, done)
		end)
	end
	eq(assign("ABC-1"), nil, "problem")
	same(w.calls[#w.calls].argv, { "acli", "jira", "workitem", "assign", "--key", "ABC-1", "--assignee", "@me", "--yes" }, "the argv")
	local count = #w.calls
	eq(assign("ABC-1 --ignore-errors").kind, "invalid", "a key that is not one")
	eq(assign("abc-1").kind, "invalid", "a lowercase key")
	eq(#w.calls, count, "nothing spawned for them")
	failing = true
	eq(assign("ABC-1").kind, "auth", "a signed-out acli")
end)

case("jira.transitions: no API token is an auth problem naming the setup, and nothing is requested or leaked", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	local reqs = asks.bk.rest(w, "ann@example.com", {})
	local problem: any = nil
	jira.transitions("ABC-1", function(_list, p)
		problem = p
	end)
	w.flush()
	eq(problem.kind, "auth", "auth")
	has(problem.message, "PLOTROOM_JIRA_API_TOKEN", "names the variable")
	has(problem.message, "restart Tern", "and the setup")
	lacks(problem.message, "Authorization", "no header text")
	eq(#reqs, 0, "no request was made")
	w.env.PLOTROOM_JIRA_API_TOKEN = ""
	problem = nil
	jira.transition("ABC-1", "31", function(p)
		problem = p
	end)
	w.flush()
	eq(problem.kind, "auth", "an empty token is none")
	eq(#reqs, 0, "still no request")
end)

case("jira.transitions: an API token of another account sends nothing past /myself and never appears in a message", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	w.env.PLOTROOM_JIRA_API_TOKEN = "s3cret-token"
	local reqs = asks.bk.rest(w, "bob@example.com", { { id = "31", name = "Done" } })
	local problem: any = nil
	jira.transition("ABC-1", "31", function(p)
		problem = p
	end)
	w.flush()
	eq(problem.kind, "auth", "auth")
	has(problem.message, "bob@example.com", "names the token's account")
	for _, secret in { "s3cret-token", "Authorization", "Basic", "b64:" } do
		lacks(problem.message, secret, "the message does not leak " .. secret)
	end
	eq(#reqs, 1, "only /myself was requested")
	eq(reqs[1].line, "GET /rest/api/3/myself", "that request")
	eq(#w.toasts, 0, "no toast is shown, so none carries the token")
	for _, call in w.calls do
		lacks(table.concat(call.argv, " "), "s3cret-token", "the token is in no argv")
	end
end)

case("jira.transitions: the list drops non-numeric ids, and the request is the fixed REST route with Basic auth", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	w.env.PLOTROOM_JIRA_API_TOKEN = "tok"
	local reqs = asks.bk.rest(w, "Ann@Example.com", {
		{ id = "31", name = "Done", to = { name = "Done" } },
		{ id = "x1", name = "Bad id" },
		{ id = "41", name = "Start" },
		{ id = 5, name = "Number id" },
		{ id = "51" },
	})
	local got: any = nil
	jira.transitions("ABC-1", function(list, p)
		eq(p, nil, "problem")
		got = list
	end)
	w.flush()
	eq(#got, 2, "two usable transitions")
	eq(got[1].id .. ":" .. got[1].name .. ":" .. tostring(got[1].to), "31:Done:Done", "first")
	eq(got[2].id .. ":" .. got[2].name .. ":" .. tostring(got[2].to), "41:Start:nil", "second")
	eq(#reqs, 2, "myself, then the list")
	eq(reqs[1].url, "https://acme.atlassian.net/rest/api/3/myself", "myself")
	eq(reqs[2].url, "https://acme.atlassian.net/rest/api/3/issue/ABC-1/transitions", "the list")
	eq(reqs[1].headers.Authorization, "Basic b64:ann@example.com:tok", "Basic auth of the acli email and the token")
	eq(reqs[2].body, nil, "a read has no body")
	local bad: any = nil
	jira.transitions("abc", function(_list, p)
		bad = p
	end)
	w.flush()
	eq(bad.kind, "invalid", "a bad key")
	eq(#reqs, 2, "and no request for it")
end)

case("jira.transition: the id must be in the re-listed set, then one POST of exactly the transition id", function(w: World)
	local jira = w.load("jira") :: Jira
	newAcli(w)
	w.env.PLOTROOM_JIRA_API_TOKEN = "tok"
	local post: { status: number, body: string }? = nil
	local reqs = asks.bk.rest(w, "ann@example.com", { { id = "31", name = "Done" } }, nil)
	local function go(id: string): any
		return asks.bk.once(w, function(done)
			jira.transition("ABC-1", id, done)
		end)
	end
	local function posts(): number
		local n = 0
		for _, r in reqs do
			if r.method == "POST" then
				n += 1
			end
		end
		return n
	end
	eq(go("99").kind, "invalid", "an id Jira no longer offers")
	has(go("99").message, "no longer available", "says so")
	eq(go("3x").kind, "invalid", "a malformed id")
	eq(posts(), 0, "no POST for either")
	eq(go("31"), nil, "the offered id succeeds")
	eq(posts(), 1, "one POST")
	local sent = reqs[#reqs]
	eq(sent.line, "POST /rest/api/3/issue/ABC-1/transitions", "route")
	eq(sent.body, '{"transition":{"id":"31"}}', "body")
	eq(sent.headers["Content-Type"], "application/json", "content type")
	post = { status = 400, body = jsonEncode({ errorMessages = array({ "Field 'resolution' is required" }) }) }
	reqs = asks.bk.rest(w, "ann@example.com", { { id = "31", name = "Done" } }, post)
	local refused = go("31")
	eq(refused.kind, "failed", "Jira refusing the transition")
	has(refused.message, "resolution", "carries Jira's own reason")
end)

case("jira.transition: a site switch between list and post sends to the current site, and a failed status sends nothing", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	w.env.PLOTROOM_JIRA_API_TOKEN = "tok"
	local reqs = asks.bk.rest(w, "ann@example.com", { { id = "31", name = "Done" } }, nil)
	jira.transitions("ABC-1", function() end)
	w.flush()
	local listed = #reqs
	acli.site = "other.atlassian.net"
	local problem: any = "unset"
	jira.transition("ABC-1", "31", function(p)
		problem = p
	end)
	w.flush()
	eq(problem, nil, "the write succeeds")
	eq(reqs[#reqs].url, "https://other.atlassian.net/rest/api/3/issue/ABC-1/transitions", "the POST goes to the current site")
	for i = listed + 1, #reqs do
		lacks(reqs[i].url, "acme", "nothing went to the old site after the switch")
	end
	local before = #reqs
	acli.override = function(req: any): any
		if req.kind == "auth" then
			return { status = 1, stderr = "✗ Error: boom\n" }
		end
		return nil
	end
	jira.transition("ABC-1", "31", function(p)
		problem = p
	end)
	w.flush()
	eq(#reqs, before, "nothing sent when status fails")
	eq(problem and problem.kind, "auth", "a failed status read is an auth problem")
end)

case("worktree.inventory: lists every worktree of the checkout, marks main, flags locked, prunable, missing and detached, writes nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	local before = snapshot(g)
	local got = asks.bk.pack(w, function(done)
		worktree.inventory("/work/r", "o/r", done)
	end)
	eq(got[2], nil, "problem")
	local entries = got[1]
	eq(#entries, 8, "main and seven linked worktrees")
	eq(entries[1].path, "/work/r", "the main worktree first")
	local by: { [string]: any } = {}
	for _, e in entries do
		by[e.path] = e
	end
	eq(by["/work/r"].main, true, "main is marked")
	eq(by["/work/r"].root, "/work/r", "root")
	eq(by["/work/r"].branch, "main", "main's branch")
	eq(by["/work/r"].number, nil, "main has no item")
	local pr = by["/wt/pr5"]
	eq(pr.main, false, "a linked one is not main")
	eq(pr.branch, "feature", "branch without refs/heads/")
	eq(pr.number, 5, "the pull request Plotroom noted")
	eq(pr.ref, worktree.prRef("o", "r", 5), "and its fetched ref")
	eq(pr.locked or pr.prunable or pr.missing or pr.detached, false, "a plain one has no flags")
	eq(by["/wt/lk"].locked, true, "locked")
	eq(by["/wt/prune"].prunable, true, "prunable")
	eq(by["/wt/gone"].missing, true, "a folder that is gone is missing")
	eq(by["/wt/pr5"].missing, false, "a folder that exists is not")
	eq(by["/wt/det"].detached, true, "detached")
	eq(by["/wt/det"].branch, nil, "and has no branch")
	eq(by["/wt/issue"].key, "ABC-1", "an issue's noted key")
	eq(by["/wt/foreign"].key, nil, "a note made for another repository is not this one's")
	eq(by["/wt/foreign"].number, nil, "nor a number")
	eq(snapshot(g), before, "git state is untouched")
	for _, never in { "fetch", "push", "worktree add", "worktree remove", "branch", "status" } do
		eq(countLog(g, never), 0, "git " .. never .. " was not run")
	end
	local linked = asks.bk.pack(w, function(done)
		worktree.inventory("/wt/pr5", "o/r", done)
	end)
	eq(linked[1][1].path, "/work/r", "asked from a linked worktree, main is still first")
	eq(linked[1][1].main, true, "and marked")
end)

case("worktree.removeEntry: refuses main, locked, prunable, missing, changed and unknown worktrees, touching nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	local function refused(path: string, branch: string?, needle: string, what: string)
		local before = snapshot(g)
		local got = asks.bk.pack(w, function(done)
			worktree.removeEntry("/work/r", "o/r", path, branch, done)
		end)
		eq(got[1], nil, what .. ": no removal")
		has(got[2], needle, what)
		eq(snapshot(g), before, what .. ": git state is untouched")
	end
	refused("/work/r", "main", "main checkout", "the main checkout")
	refused("/wt/lk", "lk", "locked, prunable or missing", "a locked worktree")
	refused("/wt/prune", "pr", "locked, prunable or missing", "a prunable worktree")
	refused("/wt/gone", "gn", "locked, prunable or missing", "a worktree whose folder is gone")
	refused("/wt/pr5", "changed", "changed", "a worktree now on another branch than the window remembers")
	refused("/wt/det", "feature", "changed", "a detached worktree claimed to be on a branch")
	refused("/wt/pr5", nil, "changed", "a branch claimed to be detached")
	refused("/nowhere", "x", "not a worktree", "a path git does not list")
	eq(countLog(g, "worktree remove"), 0, "git was never asked to remove any of them")
end)

case("worktree.removeEntry: a dirty worktree is never forced, a clean one goes with its branch kept unless merged, and a branch Plotroom did not note is left alone", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	asks.bk.tree(w, g, "/wt/um", "um")
	local function remove(path: string, branch: string?): any
		return asks.bk.pack(w, function(done)
			worktree.removeEntry("/work/r", "o/r", path, branch, done)
		end)
	end
	local function listed(path: string): boolean
		for _, t in g.worktrees do
			if t.path == path then
				return true
			end
		end
		return false
	end
	g.dirty["/wt/pr5"] = " M a.txt\n"
	local dirty = remove("/wt/pr5", "feature")
	eq(dirty[1], nil, "a dirty worktree is not removed")
	has(dirty[2], "uncommitted changes", "problem")
	eq(dirty[3], true, "and reported dirty")
	eq(listed("/wt/pr5"), true, "it is still there")
	eq(countLog(g, "worktree remove /wt/pr5"), 1, "git was asked once, without force")
	for _, line in g.log do
		if string.sub(line, 1, 15) == "worktree remove" then
			lacks(line, "--force", "no --force")
			lacks(line, " -f", "no -f")
		end
	end
	g.dirty["/wt/pr5"] = nil
	local ok = remove("/wt/pr5", "feature")
	eq(ok[2], nil, "problem")
	yes(ok[1], "a removal")
	eq(listed("/wt/pr5"), false, "the clean worktree is gone")
	eq(countLog(g, "branch -d feature"), 1, "its branch is deleted without force")
	eq(countLog(g, "branch -D"), 0, "never with -D: the pull request's fetched ref is not there to compare with")
	local unmerged = remove("/wt/um", "um")
	eq(listed("/wt/um"), false, "the worktree of a branch Plotroom did not note is removed")
	yes(unmerged[1], "a removal")
	has(unmerged[1].branch, "kept", "the removal says the branch was kept")
	eq(g.refs["refs/heads/um"], sha("b"), "and that branch is kept")
	eq(countLog(g, "branch -D"), 0, "and still never forced")
	local det = remove("/wt/det", nil)
	eq(det[2], nil, "problem")
	eq(det[1].branch, "It had no branch.", "a detached worktree has no branch to drop")
	eq(listed("/wt/det"), false, "and is removed")
	eq(countLog(g, "branch -d um"), 0, "no branch command for a branch Plotroom did not note")
	eq(countLog(g, "branch -D"), 0, "and none was ever forced")
end)

case("worktree.status: porcelain v2 header lines are never changes, an ahead count needs an upstream, and a status git could not read is unknown", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.inventoryRepo(w)
	local function status(): any
		return asks.bk.pack(w, function(done)
			worktree.status("/wt/pr5", done)
		end)[1]
	end
	local clean = status()
	eq(clean.dirty, false, "a clean worktree with headers only is clean")
	eq(clean.ahead, nil, "and with no upstream there is no ahead count")
	g.unpushed["/wt/pr5"] = 3
	local ahead = status()
	eq(ahead.dirty, false, "commits ahead of the upstream are not changes")
	eq(ahead.ahead, 3, "they are counted")
	g.unpushed["/wt/pr5"] = 0
	eq(status().ahead, 0, "an upstream with nothing ahead counts 0")
	g.dirty["/wt/pr5"] = "1 .M N... 100644 100644 100644 a b src/a.lua\n? notes.txt\n"
	eq(status().dirty, true, "a changed file and an untracked one are changes")
	eq(countLog(g, "status --porcelain=v2 --branch --untracked-files=normal"), 4, "one spawn each")
	g.fail["status"] = { status = 128, stderr = "fatal: unable to read the index\n" }
	eq(status(), nil, "a failed status tells nothing")
	local parsed = worktree.parseStatus("# branch.oid x\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -7\n")
	eq(parsed.dirty, false, "headers only: clean")
	eq(parsed.ahead, 2, "the behind count is not used")
end)
case("worktree.draftPreview: reads the branch and its commits over the base fetched read-only, writing nothing but its tracking ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	local function preview(base: string): any
		return asks.bk.pack(w, function(done)
			worktree.draftPreview("/wt/x", "o/r", base, done)
		end)
	end
	local got = preview("main")
	eq(got[2], nil, "problem")
	local d = got[1]
	eq(d.branch, "my-feat", "branch")
	eq(d.head, sha("c"), "head")
	eq(d.base, "main", "base")
	eq(d.baseSha, sha("1"), "the base as just fetched")
	eq(d.count, 2, "commits over the base")
	eq(#d.commits, 2, "listed")
	eq(d.remote, "origin", "the remote of o/r")
	eq(d.path, "/wt/x", "path")
	eq(d.title, "my feat", "a title from the branch name")
	eq(d.needsPush, true, "the remote has no such branch")
	eq(d.remoteHead, nil, "so no remote head")
	eq(d.dirty, false, "clean")
	eq(countLog(g, "fetch"), 1, "one fetch")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "of the chosen base, into its tracking ref only")
	eq(g.refs["refs/remotes/origin/main"], sha("1"), "which holds the remote's commit")
	for _, never in { "push", "worktree add", "worktree remove", "branch" } do
		eq(countLog(g, never), 0, "git " .. never .. " was not run")
	end
	g.refs["refs/remotes/origin/my-feat"] = sha("c")
	local pushed = preview("main")[1]
	eq(pushed.needsPush, false, "the remote already has this commit")
	eq(pushed.remoteHead, sha("c"), "remote head")
	g.served["refs/heads/develop"] = sha("2")
	local other = preview("develop")[1]
	eq(other.baseSha, sha("2"), "another base is read from its own tracking ref")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head origin +refs/heads/develop:refs/remotes/origin/develop"), 1, "after fetching exactly that base")
end)

case("worktree.draftPreview: a detached HEAD, the base itself, no commits, a bad or unfetched base are refused", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	local function refused(base: string, what: string)
		local got = asks.bk.pack(w, function(done)
			worktree.draftPreview("/wt/x", "o/r", base, done)
		end)
		eq(got[1], nil, what .. ": no draft")
		yes(type(got[2]) == "string" and got[2] ~= "", what .. ": an actionable problem")
	end
	local tree = g.worktrees[2]
	tree.branch = nil
	refused("main", "a detached HEAD")
	eq(countLog(g, "fetch"), 0, "nothing was fetched for it")
	tree.branch = "refs/heads/my-feat"
	refused("my-feat", "the base is the current branch")
	yes(countLog(g, "fetch") <= 1, "at most the read-only base fetch ran")
	eq(countLog(g, "push") + countLog(g, "worktree add") + countLog(g, "worktree remove"), 0, "nothing was written")
	g.counts[sha("c")] = 0
	refused("main", "a branch with no commits over the base")
	g.counts[sha("c")] = 2
	local fetches = countLog(g, "fetch")
	refused("bad name", "a base git rejects")
	eq(countLog(g, "fetch"), fetches, "which is not fetched")
	refused("gone", "a base the remote does not have")
	eq(countLog(g, "fetch"), fetches + 1, "its fetch was tried")
	eq(g.refs["refs/remotes/origin/gone"], nil, "and left nothing behind")
	eq(countLog(g, "push"), 0, "nothing was ever pushed")
end)

case("worktree.pushBranch: pushes exactly the previewed commit unforced, and only while the branch and commit still hold", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	local function preview(): any
		return asks.bk.pack(w, function(done)
			worktree.draftPreview("/wt/x", "o/r", "main", done)
		end)[1]
	end
	local function push(d: any): any
		return asks.bk.pack(w, function(done)
			worktree.pushBranch(d, done)
		end)[1]
	end
	local d = preview()
	eq(push(d), nil, "pushed")
	eq(#g.pushes, 1, "one push")
	eq(g.pushes[1], "push --no-force-with-lease origin " .. sha("c") .. ":refs/heads/my-feat", "the previewed commit to the previewed branch")
	for _, call in w.calls do
		for _, arg in call.argv do
			for _, forced in { "--force", "-f", "--force-with-lease", "--mirror", "--delete", "+" .. sha("c") .. ":refs/heads/my-feat" } do
				eq(arg == forced, false, "git was given no " .. forced)
			end
		end
	end
	g.worktrees[2].head = sha("d")
	has(push(d), "moved since the preview", "a HEAD that moved")
	g.worktrees[2].head = sha("c")
	g.worktrees[2].branch = "refs/heads/other"
	has(push(d), "moved since the preview", "another branch")
	g.worktrees[2].branch = nil
	has(push(d), "detached", "a detached HEAD")
	g.worktrees[2].branch = "refs/heads/my-feat"
	eq(#g.pushes, 1, "none of those pushed")
	-- a draft whose branch is already on the remote (needsPush false) is checked again as well
	g.refs["refs/remotes/origin/my-feat"] = sha("c")
	local synced = preview()
	eq(synced.needsPush, false, "nothing to push at preview")
	g.worktrees[2].head = sha("d")
	has(push(synced), "moved since the preview", "a HEAD that moved after a preview that needed no push")
	eq(#g.pushes, 1, "still no push")
	g.worktrees[2].head = sha("c")
	g.pushFail = { status = 1, stderr = "! [rejected] my-feat -> my-feat (non-fast-forward)\nerror: failed to push some refs\n" }
	has(push(d), "refused", "a rejected push is the problem")
	eq(#g.pushes, 2, "tried once, never retried with force")
	g.remotes.origin = { "https://github.com/o/other.git" }
	local lost = push(d)
	yes(lost ~= nil, "a checkout whose remote is no longer o/r's is refused")
	eq(#g.pushes, 2, "and nothing was pushed")
end)

case("worktree.draftDestinations: GitHub remotes only, origin first, one per repository, none is a problem", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.repo(w)
	local function dest(): (any, any)
		local got = asks.bk.pack(w, function(done)
			worktree.draftDestinations("/work/r", done)
		end)
		return got[1], got[2]
	end
	local function show_(list: any): string
		local out: { string } = {}
		for _, d in list do
			table.insert(out, d.remote .. "=" .. d.repo)
		end
		return table.concat(out, ",")
	end
	local list, problem = dest()
	eq(problem, nil, "problem")
	eq(show_(list), "origin=o/r", "one remote")
	g.remotes.fork = { "https://github.com/O/R.git" }
	eq(show_((dest())), "origin=o/r", "the same repository twice is listed once")
	g.remotes.fork = { "https://github.com/me/r.git" }
	g.remotes.lab = { "https://gitlab.com/me/r.git" }
	eq(show_((dest())), "origin=o/r,fork=me/r", "two repositories, origin first, gitlab ignored")
	g.remotes = { lab = { "https://gitlab.com/me/r.git" } }
	local none, why = dest()
	eq(none, nil, "no GitHub remote: no list")
	yes(why ~= nil, "and a problem")
end)

case("worktree: draftPreview and remoteBranches resolve the remote of the repository asked for", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = asks.bk.drafted(w)
	g.remotes.fork = { "https://github.com/me/r.git" }
	g.served["refs/heads/main"] = sha("1")
	local got = asks.bk.pack(w, function(done)
		worktree.draftPreview("/wt/x", "me/r", "main", done)
	end)
	eq(got[2], nil, "problem")
	eq(got[1].remote, "fork", "the draft's remote")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head fork +refs/heads/main:refs/remotes/fork/main"), 1, "the fetch names that remote")
	eq(countLog(g, "fetch --no-tags --no-write-fetch-head origin"), 0, "and not origin")
	asks.bk.pack(w, function(done)
		worktree.remoteBranches("/wt/x", "me/r", done)
	end)
	eq(countLog(g, "ls-remote --symref fork"), 1, "remoteBranches lists that remote's branches")
	eq(countLog(g, "ls-remote --symref origin"), 0, "not origin's")
end)

return {}
