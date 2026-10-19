--!strict
-- Regression cases: github and jira modules.

local h = require("../harness")

type AcliReq = h.AcliReq
type Call = h.Call
type ChecksOut = h.ChecksOut
type Gh = h.Gh
type GhReq = h.GhReq
type Github = h.Github
type Jira = h.Jira
type Reply = h.Reply
type Responder = h.Responder
type SearchOut = h.SearchOut
type World = h.World

local EPOCH, NULL, acliCount, always, array, case = h.EPOCH, h.NULL, h.acliCount, h.always, h.array, h.case
local checkRun, eq, has, issueItem, jiraItem, jsonEncode = h.checkRun, h.eq, h.has, h.issueItem, h.jiraItem, h.jsonEncode
local manyItems, newAcli, newGh, nodes, runChecks, runSearch = h.manyItems, h.newAcli, h.newGh, h.nodes, h.runChecks, h.runSearch
local same, searchItem, sha, yes = h.same, h.searchItem, h.sha, h.yes

case("github.gh: a token that times out is 'failed' after one spawn, a refusal is 'auth', a token travels only in GH_TOKEN", function(w: World)
	local github = w.load("github") :: Github
	local script: Responder = function(_call: Call): Reply?
		return { delay = 40000 }
	end
	w.respond(function(call: Call): Reply?
		return script(call)
	end)
	local outcome: { out: string?, problem: any } = { out = nil, problem = nil }
	local function ask()
		outcome.out, outcome.problem = nil, nil
		github.gh({ "api", "user" }, function(out, problem, _cx, _raw)
			outcome.out, outcome.problem = out, problem
		end, "victim")
		w.flush()
		w.advance(30000)
	end
	ask()
	eq(outcome.problem.kind, "failed", "a timeout is retryable, not 'not signed in'")
	has(outcome.problem.message, "30 seconds", "message gives the timeout")
	eq(#w.calls, 1, "no gh call after a timed-out token")
	script = function(_call: Call): Reply?
		return { status = 1, stderr = "no such user\n" }
	end
	ask()
	eq(outcome.problem.kind, "auth", "a definite refusal")
	has(outcome.problem.message, "victim", "message names the account")
	script = function(call: Call): Reply?
		if call.argv[2] == "auth" then
			return { stdout = "tok\n" }
		end
		return { stdout = "ok" }
	end
	local before = #w.calls
	ask()
	eq(outcome.out, "ok", "output")
	eq(#w.calls - before, 2, "token, then the command")
	same(w.calls[before + 1].argv, { "gh", "auth", "token", "--hostname", "github.com", "--user", "victim" }, "token argv")
	eq(w.calls[before + 1].env.GH_TOKEN, nil, "the token call has no token")
	same(w.calls[before + 2].argv, { "gh", "api", "user" }, "command argv")
	eq(w.calls[before + 2].env.GH_TOKEN, "tok", "the token is in the environment only")
end)

case("github.runs: same-named checks of different suites are independent rows, the failing one stays visible", function(w: World)
	local github = w.load("github") :: Github
	local runs = github.runs({
		checkRun("test", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { id = "CR1", checkSuite = { id = "S1" } }),
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T01:00:00Z", { id = "CR2", checkSuite = { id = "S2" } }),
	})
	eq(#runs, 2, "rows")
	eq(runs[1].status, "failure", "failure first")
	eq(runs[2].status, "success", "then the pass")
end)

case("github.runs: attempts of one check in one suite collapse to the newest, a queued re-run counts as newest", function(w: World)
	local github = w.load("github") :: Github
	local failing = checkRun("build", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" } })
	local queued = checkRun("build", "QUEUED", nil, nil, { checkSuite = { id = "S1" } })
	for _, order in { { failing, queued }, { queued, failing } } do
		local runs = github.runs(order)
		eq(#runs, 1, "one row")
		eq(runs[1].status, "pending", "the queued re-run wins")
		eq(runs[1].detail, "Queued", "detail")
	end
	local passed = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T01:00:00Z", { checkSuite = { id = "S1" } })
	for _, order in { { failing, passed }, { passed, failing } } do
		local runs = github.runs(order)
		eq(#runs, 1, "one row")
		eq(runs[1].status, "success", "the later attempt wins in either order")
	end
	local stale = checkRun("build", "IN_PROGRESS", nil, "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" } })
	eq(github.runs({ stale, passed })[1].status, "success", "a newer completed attempt beats an older running one")
	local required = checkRun("build", "COMPLETED", "FAILURE", "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" }, isRequired = true })
	local optional = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T01:00:00Z", { checkSuite = { id = "S1" }, isRequired = false })
	local merged = github.runs({ required, optional })
	eq(#merged, 1, "one row")
	eq(merged[1].required, true, "required when any attempt was")
end)

case("github.about: merge state, reviewers (asked again wins) and a capped description from untrusted JSON", function(w: World)
	local github = w.load("github") :: Github
	local a = github.about({
		mergeable = "MERGEABLE",
		merge = "BEHIND",
		body = "Fixes #1",
		reviews = array({ { login = "ann", state = "APPROVED" }, { login = "bob", state = "CHANGES_REQUESTED" }, { login = "x y", state = "APPROVED" }, { login = "pat", state = "PENDING" } }),
		requested = array({ "bob", "core-team", NULL, 5 }),
	})
	eq(a.merge, "behind", "mergeStateStatus reads as its word")
	same(a.reviews, {
		{ login = "ann", state = "approved" },
		{ login = "bob", state = "requested" },
		{ login = "core-team", state = "requested" },
	}, "verdicts by login; a reviewer asked again is requested; a malformed login, a pending review and non-logins are dropped")
	eq(a.body, "Fixes #1", "the description")
	eq(github.about({ mergeable = "CONFLICTING", merge = "BLOCKED" }).merge, "conflicts", "a conflict wins over the merge state")
	eq(github.about({ merge = "SOMETHING_NEW" }).merge, "unknown", "an unknown state is unknown")
	eq(github.about(nil).merge, "unknown", "and so is nothing at all")
	local long = github.about({ body = string.rep("é", 20005) }).body
	eq(utf8.len(long), 20003, "a long description is cut at 20000 characters, on a character boundary, and marked")
end)

case("github.runs: entries without a suite are independent unless they are the same node", function(w: World)
	local github = w.load("github") :: Github
	local plain = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z")
	eq(#github.runs({ plain, plain, plain }), 3, "no identity at all: every entry is a row")
	local node = checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "N1" })
	eq(#github.runs({ node, node }), 1, "the same node id twice is one entry")
	local mixed = github.runs({
		{ context = "build", state = "SUCCESS" },
		checkRun("build", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { checkSuite = { id = "S1" } }),
	})
	eq(#mixed, 2, "a status context and a check run are separate even with one name")
end)

case("github.runs: a name two checks share is prefixed with its workflow or app", function(w: World)
	local github = w.load("github") :: Github
	local runs = github.runs({
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "1", checkSuite = { id = "S1", workflowRun = { workflow = { name = "CI" } } } }),
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "2", checkSuite = { id = "S2", workflowRun = { workflow = { name = "Lint" } } } }),
		checkRun("test", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "3", checkSuite = { id = "S3", app = { name = "Vercel" } } }),
		checkRun("unique", "COMPLETED", "SUCCESS", "2026-01-01T00:00:00Z", { id = "4", checkSuite = { id = "S4", workflowRun = { workflow = { name = "CI" } } } }),
	})
	local names: { string } = {}
	for _, run in runs do
		table.insert(names, run.name)
	end
	same(names, { "CI / test", "Lint / test", "Vercel / test", "unique" }, "names")
end)

case("github.parseResponse: only plain bounded integers and IMF dates are believed", function(w: World)
	local github = w.load("github") :: Github
	local function retry(value: string): number?
		local q: any = github.parseResponse("HTTP/2.0 429 Too Many Requests\r\nRetry-After: " .. value .. "\r\n\r\n{}", 1000)
		return if q then q.retryUntil else nil
	end
	for _, bad in { "inf", "nan", "0x10", "1e3", "-5", "2.5", "", "99999999999" } do
		eq(retry(bad), nil, "Retry-After '" .. bad .. "' is ignored")
	end
	eq(retry("120"), 1120, "seconds")
	eq(retry("99999999"), 1000 + 86400, "capped at a day")
	eq(retry("Thu, 01 Jan 1970 00:17:40 GMT"), 1060, "IMF-fixdate")
	local q: any = github.parseResponse("HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 5\r\nX-Ratelimit-Reset: inf\r\n\r\n{}", 1000)
	eq(q.remaining, 5, "a plain integer is read")
	eq(q.reset, nil, "inf is not a reset time")
end)

case("github.classify: statuses map to the pause kinds the host acts on", function(w: World)
	local github = w.load("github") :: Github
	local function kind(status: number, stderr: string, timedOut: boolean?): string
		return github.classify({ status = status, stdout = "", stderr = stderr, timed_out = timedOut == true }).kind
	end
	eq(kind(1, "gh: Bad credentials (HTTP 401)\n"), "auth", "401")
	eq(kind(4, ""), "auth", "gh exit 4")
	eq(kind(1, "gh: Resource not accessible by integration (HTTP 403)\n"), "auth", "403")
	eq(kind(1, "gh: Not Found (HTTP 404)\n"), "not-found", "404")
	eq(kind(1, "gh: Validation Failed (HTTP 422)\n"), "invalid", "422")
	eq(kind(1, "gh: API rate limit exceeded for user ID 1.\n"), "rate-limit", "primary limit")
	eq(kind(1, "gh: You have exceeded a secondary rate limit (HTTP 403)\n"), "rate-limit", "secondary limit")
	eq(kind(1, "gh: HTTP 429\n"), "rate-limit", "429")
	eq(kind(-1, "", true), "failed", "timeout")
	eq(kind(1, "gh: something broke\n"), "failed", "anything else")
end)

case("github.search: a count GitHub caps loads ten pages of 100 and is partial", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 1000)
	gh.total.octocat = 5000
	local out = runSearch(w, github, nil)
	eq(#gh.requests, 10, "gh calls")
	eq(#out.result.prs, 1000, "PRs")
	eq(out.result.total, 5000, "total")
	eq(out.result.complete, false, "complete")
	eq(out.spent, 10, "spent")
end)

case("github.search: complete means every counted PR arrived", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 250)
	local full = runSearch(w, github, nil)
	eq(#gh.requests, 3, "three pages")
	eq(#full.result.prs, 250, "PRs")
	eq(full.result.complete, true, "complete")
	gh.requests = {}
	gh.items.octocat = manyItems("o/r", 2)
	gh.total.octocat = 5
	local short = runSearch(w, github, nil)
	eq(#short.result.prs, 2, "the PRs that arrived are kept")
	eq(short.result.complete, false, "fewer PRs than counted is partial")
	gh.items.octocat = {}
	gh.total.octocat = 0
	local empty = runSearch(w, github, nil)
	eq(#empty.result.prs, 0, "no PRs")
	eq(empty.result.complete, true, "an empty search is complete")
end)

case("github.search: a pull request carries the commit its head branch is at: asked of GitHub, kept lowercase, and only when it is 40 hex digits", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function item(n: number, head: any): { [string]: any }
		return searchItem(n, "o/r", EPOCH - n * 60, { headSha = head })
	end
	gh.items.octocat = {
		item(1, sha("a")),
		item(2, string.rep("AB", 20)),
		item(3, string.rep("a", 39)),
		item(4, string.rep("g", 40)),
		item(5, 12345),
		item(6, NULL),
		searchItem(7, "o/r", EPOCH - 7 * 60),
	}
	local out = runSearch(w, github, nil)
	local argv = gh.requests[1].call.argv
	has(gh.requests[1].fields.query, "headRefOid", "the search selects the head commit")
	has(argv[(table.find(argv, "--jq") :: number) + 1], "headSha:.headRefOid", "and the filter hands it over as headSha")
	local got: { string? } = {}
	for i, pr in out.result.prs do
		got[i] = pr.headSha
	end
	eq(got[1], sha("a"), "a full commit id")
	eq(got[2], string.rep("ab", 20), "is lowercased")
	eq(got[3], nil, "too short")
	eq(got[4], nil, "not hexadecimal")
	eq(got[5], nil, "not text")
	eq(got[6], nil, "null")
	eq(got[7], nil, "absent")
	eq(#out.result.prs, 7, "none of them is lost for it")
end)

case("github.search: a pull request carries the owner of the fork its head branch lives in: asked of GitHub, and kept only as a login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function item(n: number, fork: any): { [string]: any }
		return searchItem(n, "o/r", EPOCH - n * 60, { fork = fork })
	end
	gh.items.octocat = {
		item(1, "bob"),
		item(2, "bob-2"),
		item(3, "not a login"),
		item(4, "a/b"),
		item(5, ""),
		item(6, 12345),
		item(7, NULL),
		searchItem(8, "o/r", EPOCH - 8 * 60),
	}
	local out = runSearch(w, github, nil)
	local argv = gh.requests[1].call.argv
	has(gh.requests[1].fields.query, "isCrossRepository", "the search asks whether the head is in another repository")
	has(gh.requests[1].fields.query, "headRepositoryOwner { login }", "and who owns it")
	has(argv[(table.find(argv, "--jq") :: number) + 1], "fork:(if .isCrossRepository then (.headRepositoryOwner.login // .author.login) else null end)", "the filter hands that owner over as fork (the author when the fork is gone), and nothing for a branch of the repository itself")
	local got: { string? } = {}
	for i, pr in out.result.prs do
		got[i] = pr.fork
	end
	eq(got[1], "bob", "a login")
	eq(got[2], "bob-2", "with a dash")
	eq(got[3], nil, "a name with spaces is no login")
	eq(got[4], nil, "nor one with a slash")
	eq(got[5], nil, "an empty one")
	eq(got[6], nil, "a number")
	eq(got[7], nil, "null: the head is in the repository itself")
	eq(got[8], nil, "absent")
	eq(#out.result.prs, 8, "none of them is lost for it")
end)

case("github.search: an empty page with a cursor, or a cursor that did not advance, stops the scan as partial", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 1000)
	gh.total.octocat = 5000
	local seen = 0
	gh.override = function(req: GhReq): Reply?
		if req.kind ~= "search" then
			return nil
		end
		seen += 1
		if seen == 2 then
			return { stdout = jsonEncode({ total = 5000, next = "c200", cost = 1, items = array({}) }) }
		end
		return nil
	end
	local empty = runSearch(w, github, nil)
	eq(#gh.requests, 2, "gh calls")
	eq(#empty.result.prs, 100, "the first page is kept")
	eq(empty.result.complete, false, "partial")
	seen = 0
	gh.requests = {}
	local second: { any } = {}
	for i = 101, 200 do
		table.insert(second, searchItem(i, "o/r", EPOCH - i * 60))
	end
	gh.override = function(req: GhReq): Reply?
		if req.kind == "search" then
			seen += 1
			if seen == 2 then
				return { stdout = jsonEncode({ total = 5000, next = "c100", cost = 1, items = array(second) }) }
			end
		end
		return nil
	end
	local stuck = runSearch(w, github, nil)
	eq(#gh.requests, 2, "gh calls")
	eq(#stuck.result.prs, 200, "both pages are kept")
	eq(stuck.result.complete, false, "the repeated cursor ends the scan")
end)

case("github.search: a failing request returns its problem and no partial result", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 300)
	local seen = 0
	gh.override = function(req: GhReq): Reply?
		if req.kind ~= "search" then
			return nil
		end
		seen += 1
		if seen == 2 then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local out = runSearch(w, github, nil)
	eq(out.result, nil, "no result")
	eq(out.problem.kind, "failed", "problem kind")
	eq(out.spent, 2, "both requests were counted")
end)

case("github.search: an exhausted quota mid-scan keeps the pages that arrived as partial", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 1000)
	gh.limits.octocat = { limit = 30, remaining = 1, reset = EPOCH + 600 }
	local out = runSearch(w, github, nil)
	eq(#gh.requests, 1, "no request after the quota ran out")
	eq(#out.result.prs, 100, "the first page is kept")
	eq(out.result.complete, false, "partial")
	eq(github.wait(w.seconds(), nil), 601, "every pane waits for the reset")
end)

case("github.search: a rate limit without headers backs the account off for five minutes", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.override = function(_req: GhReq): Reply?
		return { status = 1, stderr = "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)\n" }
	end
	local out = runSearch(w, github, nil)
	eq(out.problem.kind, "rate-limit", "problem kind")
	eq(github.wait(w.seconds(), nil), 300, "backoff")
end)

case("github.search: cancellation is checked before every page and after every response", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.items.octocat = manyItems("o/r", 300)
	local before = runSearch(w, github, function(): boolean
		return false
	end)
	eq(#gh.requests, 0, "a cancelled search sends nothing")
	eq(before.problem.kind, "superseded", "problem kind")
	eq(before.spent, 0, "spent")
	gh.items.octocat = manyItems("o/r", 50) -- a single page: only the check after the response can cancel it
	local go = true
	gh.override = function(req: GhReq): Reply?
		if req.kind == "search" then
			go = false
		end
		return nil
	end
	local during = runSearch(w, github, function(): boolean
		return go
	end)
	eq(#gh.requests, 1, "no second page after the answer arrived cancelled")
	eq(during.problem.kind, "superseded", "problem kind")
	eq(during.spent, 1, "spent")
end)

case("github.search: no repo qualifier, runs as the view's login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.tokens.work = "tok-work"
	gh.items.work = manyItems("o/r", 3)
	gh.items.octocat = manyItems("o/r", 7)
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.search("work", "is:open author:@me", always, function(result, problem, spent)
		out.calls += 1
		out.result, out.problem, out.spent = result, problem, spent
	end)
	w.flush()
	eq(#out.result.prs, 3, "the work account's PRs, not the active one's")
	eq(gh.requests[1].kind, "token", "the token is read first")
	eq(gh.requests[2].kind, "search", "then the search")
	eq(gh.requests[2].fields.q, "is:open author:@me is:pr sort:updated-desc", "the view's query, no repo: qualifier")
	for _, req in gh.requests do
		eq(req.login, "work", "every request ran as the view's login")
	end
end)

case("github.search: an empty query fails asynchronously without a request", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.search(nil, "   ", always, function(result, problem, spent)
		out.calls += 1
		out.result, out.problem, out.spent = result, problem, spent
	end)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	eq(out.problem.kind, "failed", "problem kind")
	eq(out.spent, 0, "spent")
	eq(#gh.requests, 0, "nothing was sent")
end)

case("github.checks: pages of 100 up to three, the total counts what the pages did not show", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.checks["o/r#5"] = nodes(250)
	gh.checkTotal["o/r#5"] = 400
	local out = runChecks(github, nil)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	eq(out.calls, 1, "done calls")
	eq(#gh.requests, 3, "three pages")
	eq(#out.runs, 250, "runs")
	eq(out.total, 400, "the 150 checks beyond the pages are counted")
	gh.requests = {}
	gh.checks["o/r#5"] = nodes(350)
	gh.checkTotal["o/r#5"] = nil
	local capped = runChecks(github, nil)
	w.flush()
	eq(#gh.requests, 3, "never more than three pages")
	eq(#capped.runs, 300, "runs")
	eq(capped.total, 350, "total")
end)

case("github.checks: a repeated cursor stops silently with what arrived", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.checks["o/r#5"] = nodes(300)
	local seen = 0
	gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" then
			seen += 1
			if seen == 2 then
				return { stdout = jsonEncode({ total = 300, next = "c100", nodes = array(nodes(5)) }) }
			end
		end
		return nil
	end
	local out = runChecks(github, nil)
	w.flush()
	eq(#gh.requests, 2, "gh calls")
	eq(out.problem, nil, "no problem")
	yes(#out.runs > 0, "runs")
end)

case("github.checks: a paused quota or an unusable account sends nothing, and cancellation wins everywhere", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.checks["o/r#5"] = nodes(250)
	github.record({ remaining = 0, reset = w.seconds() + 60, limit = 30 }, w.seconds(), "limited")
	local paused = runChecks(github, nil, "limited")
	eq(paused.calls, 0, "never synchronous")
	w.flush()
	eq(paused.problem.kind, "rate-limit", "problem kind")
	has(paused.problem.message, "checks resume at", "message")
	eq(#gh.requests, 0, "nothing was sent while paused")
	gh.tokens.fine = "tok-fine"
	gh.checks["o/r#5"] = nodes(250)
	local cancelled = runChecks(github, function(): boolean
		return false
	end, "fine")
	w.flush()
	eq(cancelled.problem.kind, "superseded", "cancelled before the call")
	eq(#gh.requests, 0, "nothing was sent")
	gh.checks["o/r#5"] = nodes(50) -- a single page: only the check after the response can cancel it
	local go = true
	gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" then
			go = false
		end
		return nil
	end
	local during = runChecks(github, function(): boolean
		return go
	end, "fine")
	w.flush()
	eq(during.problem.kind, "superseded", "cancelled while the first page was in flight")
	local checkCalls = 0
	for _, req in gh.requests do
		if req.kind == "checks" then
			checkCalls += 1
		end
	end
	eq(checkCalls, 1, "no second page")
	local bad: ChecksOut = { runs = nil, total = nil, problem = nil, calls = 0 }
	github.checks("not-a-repo", 5, nil, function(runs, total, problem)
		bad.runs, bad.total, bad.problem = runs, total, problem
	end)
	w.flush()
	eq(bad.problem.kind, "failed", "an unexpected repository name")
end)

case("github.pr: the head sha must be 40 hex digits and is lowercased", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local got: any = nil
	local why: any = nil
	local function ask()
		got, why = nil, nil
		github.pr("o/r", 5, nil, function(meta, problem, _cx)
			got, why = meta, problem
		end)
		w.flush()
	end
	gh.meta["o/r#5"] = { base = "o/r", sha = string.rep("A", 40), ref = "feature", state = "open" }
	ask()
	eq(got.sha, sha("a"), "lowercased")
	eq(got.base, "o/r", "base")
	eq(got.baseRef, "", "a base branch gh left out is empty, not a failed read")
	gh.meta["o/r#5"] = { base = "o/r", sha = "abc123", ref = "feature", state = "open" }
	ask()
	eq(got, nil, "a short sha is refused")
	has(why.message, "unexpected pull request metadata", "message")
end)

-- Shared by the github cases (one top-level local: regression.luau is near Luau's limit).
local ghx = {
	-- "<number>:<branch>" of every linked PR, "-" for a deleted branch: one string per PR, in order.
	brief = function(prs: any): { string }
		local out: { string } = {}
		for _, p in prs do
			table.insert(out, p.number .. ":" .. (p.branch or "-"))
		end
		return out
	end,
	-- The fake gh's requests of one kind (requestsOf is defined further down the suite).
	of = function(gh: Gh, kind: string): { GhReq }
		local out: { GhReq } = {}
		for _, req in gh.requests do
			if req.kind == kind then
				table.insert(out, req)
			end
		end
		return out
	end,
	-- github.linkedPrs once, flushed: the list, the problem and how often done ran (and whether before the call returned).
	linked = function(w: World, github: Github, ref: string, account: string?): { list: any, problem: any, calls: number, early: number }
		local out = { list = nil :: any, problem = nil :: any, calls = 0, early = 0 }
		github.linkedPrs("o/r", ref, account, function(list, problem)
			out.calls += 1
			out.list, out.problem = list, problem
		end)
		out.early = out.calls
		w.flush()
		return out
	end,
}

case("github.pr: the head's repository decides fork and forkRepo", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function ask(base: string, headRepo: string?, headOwner: string?, author: string?): any
		gh.meta["o/r#5"] = { base = base, sha = sha("a"), ref = "feature", state = "open", headRepo = headRepo, headOwner = headOwner, author = author }
		local calls, got, why = 0, nil :: any, nil :: any
		github.pr("o/r", 5, nil, function(meta, problem, _cx)
			calls += 1
			got, why = meta, problem
		end)
		w.flush()
		eq(calls, 1, "done runs once")
		eq(why, nil, "no problem")
		return got
	end
	local same1 = ask("o/r", "o/r", "o", "ann")
	eq(same1.fork, nil, "a head in the base repository is no fork")
	eq(same1.forkRepo, nil, "and names no fork repository")
	eq(same1.ref, "feature", "the head branch is still read")
	local cased = ask("o/r", "O/R", "O", "ann")
	eq(cased.fork, nil, "a head repository in another letter case is the same repository")
	eq(cased.forkRepo, nil, "so no fork repository")
	local cased2 = ask("O/r", "o/R", "o", "ann")
	eq(cased2.fork, nil, "the base's letter case does not matter either")
	eq(cased2.forkRepo, nil, "so no fork repository")
	local live = ask("o/r", "bob/r", "bob", "ann")
	eq(live.fork, "bob", "a live fork: the fork's owner")
	eq(live.forkRepo, "bob/r", "and its repository")
	local owned = ask("o/r", "bob/r", nil, "ann")
	eq(owned.fork, "bob", "the owner comes from the fork repository, not from headOwner")
	eq(owned.forkRepo, "bob/r", "so a missing headOwner does not hide the fork")
	local renamed = ask("o/r", "bob/other-name", "bob", "ann")
	eq(renamed.forkRepo, "bob/other-name", "a fork may be named differently")
	local gone = ask("o/r", nil, "carol", "ann")
	eq(gone.fork, "carol", "a deleted fork: the head's user")
	eq(gone.forkRepo, nil, "and no repository to fetch from")
	local blank = ask("o/r", "", "carol", "ann")
	eq(blank.fork, "carol", "an empty head repository is a deleted fork too")
	eq(blank.forkRepo, nil, "no repository either")
	local author = ask("o/r", nil, nil, "dave")
	eq(author.fork, "dave", "a deleted fork whose head user is unknown: the PR's author")
	eq(author.forkRepo, nil, "no repository")
	local badOwner = ask("o/r", nil, "not an owner", "dave")
	eq(badOwner.fork, "dave", "a head user that is no login falls back to the author")
	local nobody = ask("o/r", nil, nil, nil)
	eq(nobody.fork, nil, "no head user and no author: nobody to name")
	eq(nobody.forkRepo, nil, "no repository")
	local spaced = ask("o/r", "bob/my repo", "bob", "ann")
	eq(spaced.forkRepo, nil, "a head repository with a space is not a fork repository")
	eq(spaced.fork, nil, "and is not taken for a deleted fork")
	local deep = ask("o/r", "a/b/c", "bob", "ann")
	eq(deep.forkRepo, nil, "a head repository of three segments is not a fork repository")
	eq(deep.fork, nil, "and is not taken for a deleted fork")
end)

case("github.linkedPrs: an issue number reads its closing references, keeps this repository's PRs and marks deleted branches", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.linked["o/r#12"] = array({
		{ number = 9, title = "Late fix", head = "late", branch = "late", base = "o/r" },
		{ number = 4, title = "Fork PR", head = "x", branch = "x", base = "other/r" },
		{ number = 3, title = "Gone", head = "old", branch = NULL, base = "O/R" },
		{ number = 7, title = "Fix login", head = "fix-login", branch = "fix-login", base = "o/r" },
	})
	local out = ghx.linked(w, github, "12", nil)
	eq(out.early, 0, "done never runs before the call returns")
	eq(out.calls, 1, "done runs once")
	eq(out.problem, nil, "no problem")
	same(ghx.brief(out.list), { "9:late", "3:-", "7:fix-login" }, "the other repository's PR is dropped, the deleted branch is nil, the order is kept")
	eq(out.list[2].title, "Gone", "a PR whose branch is gone keeps its title")
	eq(out.list[1].base, nil, "only number, title and branch are kept")
	local sent = ghx.of(gh, "linked")
	eq(#sent, 1, "one GraphQL request")
	same({ sent[1].fields.o, sent[1].fields.r, sent[1].fields.n }, { "o", "r", "12" }, "owner, name and number are the variables")
	eq(sent[1].fields.q, nil, "and there is no search query")
	local argv = sent[1].call.argv
	same({ argv[1], argv[2], argv[3], argv[4], argv[5], argv[6] }, { "gh", "api", "graphql", "--hostname", "github.com", "-f" }, "gh api graphql on github.com")
	has(argv[7], "query=query($o: String!, $r: String!, $n: Int!)", "the issue query")
	has(argv[7], "closedByPullRequestsReferences", "reads the closing references")
	same({ argv[8], argv[9], argv[10], argv[11], argv[12], argv[13], argv[14] }, { "-f", "o=o", "-f", "r=r", "-F", "n=12", "--jq" }, "owner and name as strings, the number as an integer")
	has(argv[15], "baseRepository.nameWithOwner", "the jq keeps the base repository")
	eq(#argv, 15, "nothing else is passed")
end)

case("github.linkedPrs: a merged pull request is not offered as the issue's branch, a closed unmerged one still is", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.linked["o/r#12"] = array({
		{ number = 1, title = "Merged", head = "m", branch = "m", base = "o/r", state = "MERGED" },
		{ number = 2, title = "Closed", head = "c", branch = "c", base = "o/r", state = "CLOSED" },
		{ number = 3, title = "Open", head = "o", branch = "o", base = "o/r", state = "OPEN" },
	})
	same(ghx.brief(ghx.linked(w, github, "12", nil).list), { "2:c", "3:o" }, "only the merged one is dropped")
end)

case("github.linkedPrs: an issue number with no PRs is an empty list, and a failed or odd answer is a problem", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local none = ghx.linked(w, github, "12", nil)
	same(none.list, {}, "no closing references: an empty list")
	eq(none.problem, nil, "that is no problem")
	eq(none.calls, 1, "done runs once")
	gh.linked["o/r#12"] = array({ { number = 4, title = "Fork PR", head = "x", branch = "x", base = "other/r" } })
	local foreign = ghx.linked(w, github, "12", nil)
	same(foreign.list, {}, "only another repository's PR: an empty list")
	eq(foreign.problem, nil, "no problem")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { status = 1, stderr = "gh: Not Found (HTTP 404)\n" }
		end
		return nil
	end
	local missing = ghx.linked(w, github, "12", nil)
	eq(missing.list, nil, "a failed read has no list")
	eq(missing.problem.kind, "not-found", "gh's classification is passed through")
	eq(missing.calls, 1, "done runs once")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { status = 1, stderr = "gh: Bad credentials (HTTP 401)\n" }
		end
		return nil
	end
	local refused = ghx.linked(w, github, "12", nil)
	eq(refused.list, nil, "no list")
	eq(refused.problem.kind, "auth", "a refused sign-in is an auth problem")
	for _, odd in { "not json at all", "42", "" } do
		gh.override = function(req: GhReq): Reply?
			if req.kind == "linked" then
				return { stdout = odd }
			end
			return nil
		end
		local bad = ghx.linked(w, github, "12", nil)
		eq(bad.list, nil, "output that is no JSON array has no list: " .. odd)
		eq(bad.problem.kind, "failed", "and is a failed read: " .. odd)
		has(bad.problem.message, "unexpected pull request data", "with its message: " .. odd)
		eq(bad.calls, 1, "done runs once: " .. odd)
	end
end)

case("github.linkedPrs: a Jira key searches the repository and keeps PRs naming the key as a whole word", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local function pr(n: number, title: string, head: any, base: string?, branch: any): any
		return { number = n, title = title, head = head, branch = branch, base = base or "o/r" }
	end
	gh.linked["o/r#ABC-12"] = array({
		pr(1, "Fix ABC-12: login", "x", nil, "x"),
		pr(2, "abc-12 login", "y", nil, "y"),
		pr(3, "Login", "fix/ABC-12-login", nil, "fix/ABC-12-login"),
		pr(4, "Bump ABC-123", "bump", nil, "bump"),
		pr(5, "NABC-12 thing", "n", nil, "n"),
		pr(6, "ABC-12x", "z", nil, "z"),
		pr(7, "Other", "feat/abc-12_login", nil, "feat/abc-12_login"),
		pr(8, "ABC-12 elsewhere", "e", "other/r", "e"),
		pr(9, "Mentions ABC-12.", "gone", "O/R", NULL),
		pr(10, "Unrelated", NULL, nil, "u"),
		pr(11, "Nothing", "XABC-12", nil, "XABC-12"),
		pr(12, "Nothing", "fix-ABC-1234", nil, "fix-ABC-1234"),
		pr(13, "(ABC-12)", "q", nil, "q"),
	})
	local out = ghx.linked(w, github, "ABC-12", nil)
	eq(out.early, 0, "done never runs before the call returns")
	eq(out.calls, 1, "done runs once")
	eq(out.problem, nil, "no problem")
	same(ghx.brief(out.list), { "1:x", "2:y", "3:fix/ABC-12-login", "7:feat/abc-12_login", "9:-", "13:q" }, "the key as a whole word in the title or the head branch, any letter case; ABC-123, NABC-12, ABC-12x and other repositories' PRs are dropped; a deleted branch is nil")
	eq(out.list[5].title, "Mentions ABC-12.", "a PR whose branch is gone keeps its title")
	local sent = ghx.of(gh, "linked")
	eq(#sent, 1, "one GraphQL request")
	eq(sent[1].fields.q, "repo:o/r is:pr ABC-12", "the search names the repository, pull requests and the key")
	same({ sent[1].fields.o, sent[1].fields.r, sent[1].fields.n }, { nil, nil, nil }, "no issue variables")
	local argv = sent[1].call.argv
	same({ argv[1], argv[2], argv[3], argv[4], argv[5], argv[6] }, { "gh", "api", "graphql", "--hostname", "github.com", "-f" }, "gh api graphql on github.com")
	has(argv[7], "query=query($q: String!) { search(query: $q, type: ISSUE", "the search query")
	same({ argv[8], argv[9], argv[10] }, { "-f", "q=repo:o/r is:pr ABC-12", "--jq" }, "the search text as a string")
	has(argv[11], "baseRepository.nameWithOwner", "the jq keeps the base repository")
	eq(#argv, 11, "nothing else is passed")
	gh.linked["o/r#ABC-1"] = array({ pr(1, "Fix ABC-12", "x", nil, "x"), pr(2, "Fix ABC-1", "y", nil, "y") })
	same(ghx.brief(ghx.linked(w, github, "ABC-1", nil).list), { "2:y" }, "ABC-1 is not ABC-12")
	gh.linked["o/r#abc-12"] = array({ pr(1, "ABC-12 login", "x", nil, "x") })
	same(ghx.brief(ghx.linked(w, github, "abc-12", nil).list), { "1:x" }, "a lowercase key matches the same way")
end)

case("github.linkedPrs: a Jira key search failure is passed through and no PR is listed", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.linked["o/r#ABC-12"] = array({ { number = 1, title = "ABC-12", head = "x", branch = "x", base = "o/r" } })
	same(ghx.brief(ghx.linked(w, github, "ABC-12", nil).list), { "1:x" }, "found")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { status = 1, stderr = "gh: Validation Failed (HTTP 422)\n" }
		end
		return nil
	end
	local invalid = ghx.linked(w, github, "ABC-12", nil)
	eq(invalid.list, nil, "no list")
	eq(invalid.problem.kind, "invalid", "gh's classification is passed through")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { stdout = "{oops" }
		end
		return nil
	end
	local bad = ghx.linked(w, github, "ABC-12", nil)
	eq(bad.list, nil, "no list")
	eq(bad.problem.kind, "failed", "unexpected output is a failed read")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "linked" then
			return { stdout = jsonEncode(array({})) }
		end
		return nil
	end
	local empty = ghx.linked(w, github, "ABC-12", nil)
	same(empty.list, {}, "no match is an empty list")
	eq(empty.problem, nil, "not a problem")
end)

case("github.linkedPrs: runs as the given account, else as gh's active one", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.tokens.work = "tok-work"
	gh.linked["o/r#12"] = array({ { number = 3, title = "Fix", head = "fix", branch = "fix", base = "o/r" } })
	gh.linked["o/r#ABC-12"] = array({ { number = 5, title = "ABC-12", head = "abc", branch = "abc", base = "o/r" } })
	for _, ref in { "12", "ABC-12" } do
		local as = ghx.linked(w, github, ref, "work")
		eq(#as.list, 1, "the PR is listed for " .. ref)
		eq(gh.requests[1].kind, "token", "the account's token is read first for " .. ref)
		eq(gh.requests[1].login, "work", "its owner for " .. ref)
		eq(gh.requests[2].kind, "linked", "then the PR read for " .. ref)
		eq(gh.requests[2].login, "work", "runs as that account for " .. ref)
		eq(gh.requests[2].call.env.GH_TOKEN, "tok-work", "with its token for " .. ref)
		eq(#gh.requests, 2, "nothing else for " .. ref)
		gh.requests = {}
		for _, blank in { false, true } do
			local active = ghx.linked(w, github, ref, if blank then "" else nil)
			eq(#active.list, 1, "the PR is listed as the active login for " .. ref)
			eq(#gh.requests, 1, "no token is read for " .. ref)
			eq(gh.requests[1].kind, "linked", "just the PR read for " .. ref)
			eq(gh.requests[1].login, "octocat", "as the active account for " .. ref)
			eq(gh.requests[1].call.env.GH_TOKEN, nil, "without a GH_TOKEN for " .. ref)
			gh.requests = {}
		end
		local ghost = ghx.linked(w, github, ref, "ghost")
		eq(ghost.list, nil, "an account that is not signed in lists nothing for " .. ref)
		eq(ghost.problem.kind, "auth", "an auth problem for " .. ref)
		eq(#ghx.of(gh, "linked"), 0, "and sends no PR read for " .. ref)
		gh.requests = {}
	end
end)

case("github.login: the given account answers asynchronously without calling gh", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local got: { string } = {}
	local problems = 0
	github.login("work", function(login, problem)
		table.insert(got, login or "nil")
		if problem then
			problems += 1
		end
	end)
	eq(#got, 0, "done never runs before the call returns")
	w.flush()
	same(got, { "work" }, "the account, once")
	eq(problems, 0, "no problem")
	eq(#gh.requests, 0, "gh was not asked")
	eq(#w.calls, 0, "no command ran")
end)

case("github.login: gh's active login is read once and kept", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.active = "zed"
	gh.tokens.alpha = "tok-alpha"
	local got: { string } = {}
	local function ask(account: string?)
		github.login(account, function(login, problem)
			table.insert(got, (login or "nil") .. if problem then "!" else "")
		end)
	end
	ask(nil)
	eq(#got, 0, "done never runs before the call returns")
	w.flush()
	same(got, { "zed" }, "the active account, not the first alphabetically")
	eq(#ghx.of(gh, "accounts"), 1, "one accounts request")
	ask(nil)
	ask("")
	eq(#got, 1, "a known answer is still asynchronous")
	w.flush()
	same(got, { "zed", "zed", "zed" }, "an empty account is no account")
	eq(#ghx.of(gh, "accounts"), 1, "the second and third read nothing")
	eq(#gh.requests, 1, "and nothing else was asked")
end)

case("github.login: an Enterprise Managed User login with an underscore is an account", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.active = "mona-cat_octo"
	gh.tokens["mona-cat_octo"] = "tok-emu"
	local got: { string } = {}
	github.login(nil, function(login, problem)
		table.insert(got, (login or "nil") .. if problem then "!" else "")
	end)
	w.flush()
	same(got, { "mona-cat_octo" }, "the login is kept whole")
end)

case("github.login: callers during the read share one accounts request", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local got: { string } = {}
	for _ = 1, 2 do
		github.login(nil, function(login, _problem)
			table.insert(got, login or "nil")
		end)
	end
	w.flush()
	same(got, { "octocat", "octocat" }, "both callers are answered")
	eq(#ghx.of(gh, "accounts"), 1, "from one request")
end)

case("github.login: a gh that fails or lists no hosts is a problem with no login, and is read again next time", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	local calls, login, problem = 0, "unset" :: any, nil :: any
	local function ask()
		calls, login, problem = 0, "unset", nil
		github.login(nil, function(l, p)
			calls += 1
			login, problem = l, p
		end)
		w.flush()
		eq(calls, 1, "done runs once")
	end
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { status = 1, stderr = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n" }
		end
		return nil
	end
	ask()
	eq(login, nil, "no login")
	eq(problem.kind, "auth", "a signed-out gh is an auth problem")
	yes(#problem.message > 0, "with a message")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { stdout = "{}" }
		end
		return nil
	end
	ask()
	eq(login, nil, "an answer without hosts is no login")
	eq(problem.kind, "failed", "a failed read")
	has(problem.message, "2.66", "telling gh may be too old")
	gh.override = nil
	ask()
	eq(login, "octocat", "a failed read is not remembered: once gh is signed in the login is found")
	eq(problem, nil, "with no problem")
	eq(#ghx.of(gh, "accounts"), 3, "every failed attempt asked gh again")
end)

case("github.login: signed-in accounts without an active one are an auth problem with no login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { stdout = jsonEncode({ hosts = { ["github.com"] = array({ { state = "success", active = false, host = "github.com", login = "work" } }) } }) }
		end
		return nil
	end
	local calls, login, problem = 0, "unset" :: any, nil :: any
	github.login(nil, function(l, p)
		calls += 1
		login, problem = l, p
	end)
	w.flush()
	eq(calls, 1, "done runs once")
	eq(login, nil, "an account that is not the active one is no login")
	eq(problem.kind, "auth", "an auth problem")
	has(problem.message, "gh auth login", "naming how to sign in")
end)

case("github.login: a host with no accounts is an auth problem with no login", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { stdout = jsonEncode({ hosts = { ["github.com"] = array({}) } }) }
		end
		return nil
	end
	local calls, login, problem = 0, "unset" :: any, nil :: any
	github.login(nil, function(l, p)
		calls += 1
		login, problem = l, p
	end)
	w.flush()
	eq(calls, 1, "done runs once")
	eq(login, nil, "no account at all is no login")
	eq(problem.kind, "auth", "an auth problem")
	has(problem.message, "gh auth login", "naming how to sign in")
end)

case("jira.user: the email's local part before the @", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local got: { string } = {}
	local function ask()
		jira.user(function(user, problem)
			table.insert(got, (user or "nil") .. if problem then "!" else "")
		end)
		w.flush()
	end
	ask()
	same(got, { "ann" }, "ann@example.com is ann")
	ask()
	same(got, { "ann", "ann" }, "the second read answers the same")
	local function authCount(): number
		local n = 0
		for _, req in acli.requests do
			if req.kind == "auth" then
				n += 1
			end
		end
		return n
	end
	eq(authCount(), 1, "acli was asked once for the sign-in")
	local function signIn(status: string)
		acli.override = function(req: AcliReq): Reply?
			if req.kind == "auth" then
				return { stdout = status }
			end
			return nil
		end
		jira.reset()
	end
	signIn("✓ Authenticated\n  Site: acme.atlassian.net\n  Email: first.last+x@corp.com\n")
	ask()
	eq(got[3], "first.last+x", "dots and plus signs stay")
	signIn("✓ Authenticated\n  Site: acme.atlassian.net\n  Email: a_b-c@corp.com\n")
	ask()
	eq(got[4], "a_b-c", "underscores and hyphens stay")
end)

case("jira.user: an unnamed sign-in is empty and read once", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	jira.user(function() end)
	w.flush()
	acli.requests = {}
	acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = "✓ Authenticated\n  Site: acme.atlassian.net\n  Authentication Type: oauth_global\n" }
		end
		return nil
	end
	jira.reset()
	local got: { string } = {}
	for _ = 1, 2 do
		jira.user(function(user, problem)
			table.insert(got, (user or "nil") .. if problem then "!" else "")
		end)
		w.flush()
	end
	same(got, { "", "" }, "no Email line: an empty user, not the previous sign-in's and no problem")
	eq(#acli.requests, 1, "the sign-in was read once for both")
	eq(acli.requests[1].kind, "auth", "by acli jira auth status")
	same(acli.requests[1].argv, { "acli", "jira", "auth", "status" }, "exactly")
end)

case("jira.user: a signed-out acli is a problem with no user, and is read again once signed in", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	acli.site = nil
	local calls, user, problem = 0, "unset" :: any, nil :: any
	local function ask()
		calls, user, problem = 0, "unset", nil
		jira.user(function(u, p)
			calls += 1
			user, problem = u, p
		end)
		w.flush()
		eq(calls, 1, "done runs once")
	end
	ask()
	eq(user, nil, "no user")
	eq(problem.kind, "auth", "an auth problem")
	has(problem.message, "not signed in", "with a message")
	acli.site = "acme.atlassian.net"
	ask()
	eq(user, "ann", "signed in: the user")
	eq(problem, nil, "no problem")
end)

-- ---- github.issues and github.issue

local function runIssues(w: World, github: Github, query: string): SearchOut
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	github.issues(nil, query, always, function(result, problem, spent)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.spent = spent
	end)
	w.flush()
	return out
end

case("github.issues: searches is:issue in the repository and normalizes issues", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.issueItems.octocat = {
		issueItem(12, "O/R", EPOCH - 60, { title = "Fix login", state = "CLOSED", reason = "NOT_PLANNED", labels = array({ "bug", "ui" }), assignees = array({ "ann", "bob" }), comments = 7 }),
		issueItem(11, "o/r", EPOCH - 120),
	}
	local out = runIssues(w, github, "is:open assignee:@me")
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(#gh.requests, 1, "one request covers two issues")
	eq(gh.requests[1].kind, "issue-search", "an issue search")
	eq(gh.requests[1].fields.q, "is:open assignee:@me is:issue sort:updated-desc", "the view's own query, issues only, no repo: qualifier")
	eq(out.result.total, 2, "total")
	eq(out.result.complete, true, "complete")
	eq(out.spent, 1, "spent")
	local issues = out.result.issues
	eq(#issues, 2, "issues")
	local first = issues[1]
	eq(first.key, "o/r#12", "identity is lowercase")
	eq(first.tracker, "github", "tracker")
	eq(first.repo, "O/R", "the repository as GitHub spells it")
	eq(first.ref, "12", "ref")
	eq(first.title, "Fix login", "title")
	eq(first.url, "https://github.com/O/R/issues/12", "url")
	eq(first.author, "octo", "author")
	eq(first.state, "closed", "state")
	eq(first.reason, "not-planned", "NOT_PLANNED reads as not-planned")
	same(first.labels, { "bug", "ui" }, "labels")
	same(first.assignees, { "ann", "bob" }, "assignees")
	eq(first.comments, 7, "comments")
	eq(first.updated, EPOCH - 60, "updated")
	eq(first.created, EPOCH - 60, "created")
	eq(issues[2].state, "open", "an open issue")
	eq(issues[2].reason, nil, "has no reason")
	-- every closing reason, a closed issue without one, and a deleted author
	gh.issueItems.octocat = {
		issueItem(1, "o/r", EPOCH - 10, { state = "CLOSED", reason = "COMPLETED" }),
		issueItem(2, "o/r", EPOCH - 20, { state = "CLOSED", reason = "DUPLICATE" }),
		issueItem(3, "o/r", EPOCH - 30, { state = "CLOSED", reason = "NOT_PLANNED" }),
		issueItem(4, "o/r", EPOCH - 40, { state = "CLOSED" }),
		issueItem(5, "o/r", EPOCH - 50, { author = NULL }),
	}
	local closed = runIssues(w, github, "is:closed")
	local seen: { string } = {}
	for _, issue in closed.result.issues do
		table.insert(seen, issue.state .. ":" .. (issue.reason or "-") .. ":" .. issue.author)
	end
	same(seen, { "closed:completed:octo", "closed:duplicate:octo", "closed:not-planned:octo", "closed:-:octo", "open:-:ghost" }, "the closing reasons, and ghost for a deleted author")
	-- a pull request, or a URL that is not the issue's, fails the whole read
	gh.issueItems.octocat = { issueItem(5, "o/r", EPOCH - 60, { url = "https://github.com/o/r/pull/5" }) }
	local pull = runIssues(w, github, "is:open")
	eq(pull.result, nil, "a pull request in an issue search fails the read")
	eq(pull.problem.kind, "failed", "problem kind")
	eq(pull.problem.message, "the search returned an item that is not an issue", "message")
	gh.issueItems.octocat = { issueItem(5, "o/r", EPOCH - 60, { url = "https://evil.example/o/r/issues/5" }) }
	eq(runIssues(w, github, "is:open").problem.message, "the search returned an issue with an unexpected URL", "a foreign URL")
	gh.issueItems.octocat = { issueItem(5, "o/r", EPOCH - 60, { number = 6 }) }
	eq(runIssues(w, github, "is:open").problem.message, "the search returned an issue with an unexpected URL", "a URL of another number")
	-- the pages are the same
	gh.requests = {}
	local many: { { [string]: any } } = {}
	for i = 1, 250 do
		table.insert(many, issueItem(i, "o/r", EPOCH - i * 60))
	end
	gh.issueItems.octocat = many
	local paged = runIssues(w, github, "is:open")
	eq(#gh.requests, 3, "250 issues are three pages of 100")
	eq(#paged.result.issues, 250, "all of them")
	eq(paged.result.complete, true, "complete")
end)

type IssueOut = { detail: any, problem: any, calls: number }

local function runIssue(w: World, github: Github, shouldContinue: (() -> boolean)?, account: string?): IssueOut
	local out: IssueOut = { detail = nil, problem = nil, calls = 0 }
	github.issue("o/r", 12, account, function(detail, problem)
		out.calls += 1
		out.detail, out.problem = detail, problem
	end, shouldContinue)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	return out
end

case("github.issue: reads body, milestone and linked pull requests", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.issueDetail["o/r#12"] = {
		body = "Login fails.<!-- CURSOR_SUMMARY -->\nrecap\n<!-- /CURSOR_SUMMARY -->",
		milestone = "v2",
		linked = array({
			{ number = 45, title = "Fix login redirect", url = "https://github.com/o/r/pull/45", state = "OPEN", isDraft = true },
			{ number = 44, title = "Earlier attempt", url = "https://github.com/o/r/pull/44", state = "MERGED", isDraft = false },
			{ number = 43, title = "Abandoned", url = "https://github.com/o/r/pull/43", state = "CLOSED", isDraft = false },
			{ number = 42, title = "Ready", url = "https://github.com/o/r/pull/42", state = "OPEN", isDraft = false },
			{ number = 41, title = "Elsewhere", url = "javascript:alert(1)", state = "OPEN", isDraft = false },
			{ title = "No number", url = "https://github.com/o/r/pull/40", state = "OPEN", isDraft = false },
		}),
	}
	local out = runIssue(w, github, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(#gh.requests, 1, "one call")
	eq(gh.requests[1].kind, "issue", "an issue read")
	eq(gh.requests[1].fields.o, "o", "owner")
	eq(gh.requests[1].fields.r, "r", "repository")
	eq(gh.requests[1].fields.n, "12", "number")
	eq(out.detail.body, "Login fails.", "the body, without Cursor's generated summary")
	same(out.detail.fields, { { label = "Milestone", value = "v2" } }, "the milestone is the one detail row GitHub fills")
	same(out.detail.linked, {
		{ ref = "45", title = "Fix login redirect", url = "https://github.com/o/r/pull/45", state = "draft" },
		{ ref = "44", title = "Earlier attempt", url = "https://github.com/o/r/pull/44", state = "merged" },
		{ ref = "43", title = "Abandoned", url = "https://github.com/o/r/pull/43", state = "closed" },
		{ ref = "42", title = "Ready", url = "https://github.com/o/r/pull/42", state = "open" },
	}, "draft, merged, closed and open; an entry with a foreign URL or no number is dropped")
	-- an issue gh prints nothing of reads as empty, an empty milestone as none, a long body is cut
	gh.issueDetail["o/r#12"] = nil
	local none = runIssue(w, github, nil)
	eq(none.problem, nil, "an issue the account cannot see is not a failed read")
	eq(none.detail.body, "", "no body")
	same(none.detail.fields, { { label = "Milestone" } }, "no milestone")
	same(none.detail.linked, {}, "no linked pull requests")
	gh.issueDetail["o/r#12"] = { body = string.rep("é", 20005), milestone = "", linked = array({}) }
	local long = runIssue(w, github, nil)
	same(long.detail.fields, { { label = "Milestone" } }, "an empty milestone is none")
	eq(utf8.len(long.detail.body), 20003, "a long body is cut at 20000 characters, on a character boundary, and marked")
	-- what gh printed must be a JSON object, and a failing call returns its problem
	gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" then
			return { stdout = "not json" }
		end
		return nil
	end
	local bad = runIssue(w, github, nil)
	eq(bad.detail, nil, "no detail")
	eq(bad.problem.kind, "failed", "problem kind")
	eq(bad.problem.message, "gh printed unexpected issue data.", "message")
	gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local failed = runIssue(w, github, nil)
	eq(failed.detail, nil, "no detail")
	eq(failed.problem.kind, "failed", "the call's problem")
end)

case("github.issue: a paused quota or an unusable account sends nothing, and cancellation wins everywhere", function(w: World)
	local github = w.load("github") :: Github
	local gh = newGh(w)
	gh.issueDetail["o/r#12"] = { body = "x", linked = array({}) }
	github.record({ remaining = 0, reset = w.seconds() + 60, limit = 30 }, w.seconds(), "limited")
	local paused = runIssue(w, github, nil, "limited")
	eq(paused.problem.kind, "rate-limit", "problem kind")
	has(paused.problem.message, "resume at", "message")
	eq(#gh.requests, 0, "nothing was sent while paused")
	gh.tokens.fine = "tok-fine"
	local cancelled = runIssue(w, github, function(): boolean
		return false
	end, "fine")
	eq(cancelled.problem.kind, "superseded", "cancelled before the call")
	eq(#gh.requests, 0, "nothing was sent")
	local go = true
	gh.override = function(req: GhReq): Reply?
		if req.kind == "issue" then
			go = false
		end
		return nil
	end
	local during = runIssue(w, github, function(): boolean
		return go
	end, "fine")
	eq(during.problem.kind, "superseded", "cancelled while the call was in flight")
	local bad: IssueOut = { detail = nil, problem = nil, calls = 0 }
	github.issue("not-a-repo", 5, nil, function(detail, problem)
		bad.detail, bad.problem = detail, problem
	end)
	w.flush()
	eq(bad.problem.kind, "failed", "an unexpected repository name")
end)

-- ---- jira.luau: acli's search, one work item's details and the project list

local function runJira(w: World, jira: Jira, query: string, shouldContinue: (() -> boolean)?): SearchOut
	local out: SearchOut = { result = nil, problem = nil, spent = nil, calls = 0 }
	jira.issues(query, shouldContinue or always, function(result, problem, spent)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.spent = spent
	end)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	return out
end

local function runJiraIssue(w: World, jira: Jira, key: string, shouldContinue: (() -> boolean)?): IssueOut
	local out: IssueOut = { detail = nil, problem = nil, calls = 0 }
	jira.issue(key, function(detail, problem)
		out.calls += 1
		out.detail, out.problem = detail, problem
	end, shouldContinue)
	eq(out.calls, 0, "never synchronous")
	w.flush()
	return out
end

-- The value after option `name` of an acli call.
local function acliOption(argv: { string }, name: string): string?
	for i = 2, #argv - 1 do
		if argv[i] == name then
			return argv[i + 1]
		end
	end
	return nil
end

case("jira.issues: one search of the view's query, highest priority then newest update first, normalized", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local query = "assignee = currentUser() AND statusCategory != Done"
	local jql = "(" .. query .. ") ORDER BY priority DESC, updated DESC"
	acli.searches[jql] = {
		jiraItem("ABC-12", "Fix login", {
			status = { name = "In Progress", statusCategory = { key = "indeterminate" } },
			issuetype = { name = "Bug" },
			priority = { name = "High" },
			assignee = { displayName = "Bob Ray" },
			labels = array({ "ui", "bug" }),
		}),
		jiraItem("ABC-13", "Old bug", { status = { name = "Done", statusCategory = { key = "done" } } }),
	}
	local out = runJira(w, jira, query, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.spent, 0, "Jira has no quota to spend")
	eq(#acli.requests, 2, "the site, then one search")
	eq(acli.requests[1].kind, "auth", "the site comes first")
	eq(acli.requests[2].kind, "search", "then the search")
	local argv = acli.requests[2].argv
	eq(acliOption(argv, "--jql"), jql, "the view's query in parentheses, highest priority then newest update first, no project clause")
	eq(acliOption(argv, "--limit"), "100", "the newest 100")
	eq(acliOption(argv, "--fields"), "key,summary,status,issuetype,priority,assignee,reporter,labels", "only the fields acli's search allows")
	yes(table.find(argv, "--json"), "as JSON")
	eq(out.result.total, 2, "total")
	eq(out.result.complete, true, "fewer than a page is complete")
	local issues = out.result.issues
	eq(#issues, 2, "issues, in acli's order")
	local first = issues[1]
	eq(first.key, "abc#ABC-12", "identity: the lowercase project, then the key")
	eq(first.ref, "ABC-12", "ref")
	eq(first.repo, "ABC", "the project")
	eq(first.tracker, "jira", "tracker")
	eq(first.url, "https://acme.atlassian.net/browse/ABC-12", "browse URL from the site acli is signed in to")
	eq(first.title, "Fix login", "title")
	eq(first.author, "Ann Lee", "the reporter")
	eq(first.state, "open", "an unfinished status is open")
	eq(first.reason, nil, "no close reason")
	same(first.status, { text = "In Progress", tone = "warning" }, "the workflow status, toned by its category")
	eq(first.type, "Bug", "type")
	eq(first.priority, "High", "priority")
	same(first.labels, { "ui", "bug" }, "labels")
	same(first.assignees, { "Bob Ray" }, "the assignee")
	eq(first.comments, 0, "the list has no comment count")
	eq(first.created, 0, "and no creation date")
	eq(first.updated, 0, "nor update date")
	local second = issues[2]
	eq(second.key, "abc#ABC-13", "key")
	eq(second.state, "closed", "a done category is closed")
	same(second.status, { text = "Done", tone = "success" }, "status")
	same(second.assignees, {}, "a null assignee is none")
	-- an empty search prints [null], [] or null
	for i, text in { "[\n  null\n]\n", "[]\n", "null\n" } do
		acli.override = function(req: AcliReq): Reply?
			return if req.kind == "search" then { stdout = text } else nil
		end
		local none = runJira(w, jira, query, nil)
		eq(none.problem, nil, "empty form " .. i .. ": problem")
		eq(#none.result.issues, 0, "empty form " .. i .. ": issues")
		eq(none.result.total, 0, "empty form " .. i .. ": total")
		eq(none.result.complete, true, "empty form " .. i .. ": complete")
	end
	-- an update notice before the JSON and a null element inside it are skipped
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "search" then { stdout = "You're using an outdated version 1.3.36-stable. Update to the latest version 1.3.39-stable.\n[null," .. jsonEncode(jiraItem("ABC-5", "Five")) .. "]" } else nil
	end
	local noticed = runJira(w, jira, query, nil)
	eq(noticed.problem, nil, "problem")
	eq(#noticed.result.issues, 1, "the notice and the null are skipped")
	eq(noticed.result.issues[1].ref, "ABC-5", "the work item")
	-- a full page may have more behind it
	acli.override = nil
	local many: { any } = {}
	for i = 1, 100 do
		table.insert(many, jiraItem("ABC-" .. i, "Issue " .. i))
	end
	acli.searches[jql] = many
	local full = runJira(w, jira, query, nil)
	eq(#full.result.issues, 100, "a full page")
	eq(full.result.complete, false, "a full page is not known to be complete")
	eq(full.result.issues[1].ref, "ABC-1", "acli's order is kept")
	eq(full.result.issues[100].ref, "ABC-100", "to the last item")
	-- the site is read once per sign-in
	eq(acliCount(acli, "auth"), 1, "the site is asked for once")
	jira.reset()
	runJira(w, jira, query, nil)
	eq(acliCount(acli, "auth"), 2, "reset forgets it")
end)

case("jira.issues: acli's failures become problems, and a query that cannot be wrapped never reaches acli", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	local query = "assignee = currentUser()"
	-- acli is not installed: the spawn raises and there is no shell to look in
	acli.override = function(_req: AcliReq): Reply?
		return { raise = "no such file or directory" }
	end
	local missing = runJira(w, jira, query, nil)
	eq(missing.result, nil, "no result")
	eq(missing.problem.kind, "missing", "acli cannot be started")
	has(missing.problem.message, "acli could not be started", "and the message names the program")
	-- signed out: the site lookup is refused
	acli.override = nil
	acli.site = nil
	local signedOut = runJira(w, jira, query, nil)
	eq(signedOut.problem.kind, "auth", "signed out")
	eq(signedOut.problem.message, "acli is not signed in to Jira: unauthorized: use 'acli jira auth login' to authenticate", "in acli's words")
	eq(acliCount(acli, "search"), 0, "no search was sent")
	-- a sign-in that names no site
	acli.site = "acme.atlassian.net"
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "auth" then { stdout = "✓ Authenticated\n" } else nil
	end
	local nameless = runJira(w, jira, query, nil)
	eq(nameless.problem.kind, "auth", "no site named")
	has(nameless.problem.message, "did not name a Jira site", "message")
	eq(acliCount(acli, "search"), 0, "still no search")
	-- the site is known now; what a search fails with
	acli.override = nil
	eq(runJira(w, jira, query, nil).problem, nil, "a working search")
	local lookups = acliCount(acli, "auth")
	local function searchReplies(reply: Reply): SearchOut
		acli.override = function(req: AcliReq): Reply?
			return if req.kind == "search" then reply else nil
		end
		local out = runJira(w, jira, query, nil)
		eq(out.result, nil, "no result")
		return out
	end
	local bogus = searchReplies({ status = 1, stderr = "✗ Error: failed to parse JQL query: field 'bogus' does not exist or you do not have permission to view it.\n" })
	eq(bogus.problem.kind, "invalid", "a JQL error is terminal")
	eq(bogus.problem.message, "failed to parse JQL query: field 'bogus' does not exist or you do not have permission to view it.", "in acli's words")
	local gone = searchReplies({ status = 1, stderr = "✗ Error: failed to parse JQL query: the value 'nopexyz' does not exist for the field 'project'.\n" })
	eq(gone.problem.kind, "not-found", "an unknown project is not found")
	eq(searchReplies({ status = 1, stderr = "✗ Error: request failed: 429 Too Many Requests\n" }).problem.kind, "rate-limit", "a 429 is a rate limit")
	local boom = searchReplies({ status = 1, stderr = "✗ Error: boom\n" })
	eq(boom.problem.kind, "failed", "anything else")
	eq(boom.problem.message, "boom", "with acli's message")
	local slow = searchReplies({ timedOut = true })
	eq(slow.problem.kind, "failed", "no answer in time")
	eq(slow.problem.message, "acli did not answer within 60 seconds.", "message")
	eq(searchReplies({ stdout = "not json" }).problem.message, "acli printed something other than a search result", "no JSON")
	eq(searchReplies({ stdout = '{"issues":[]}' }).problem.message, "acli printed something other than a search result", "an object is no search result")
	eq(searchReplies({ stdout = '[{"key":"ABC-1"}]' }).problem.message, "acli returned a work item without a key or summary", "an item with no summary")
	eq(acliCount(acli, "auth"), lookups, "none of those forgot the site")
	-- a search that ends signed out forgets the site: the next one asks again
	eq(searchReplies({ status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login' to authenticate\n" }).problem.kind, "auth", "signed out mid-way")
	acli.override = nil
	eq(runJira(w, jira, query, nil).problem, nil, "signed in again")
	eq(acliCount(acli, "auth"), lookups + 1, "the site was looked up again")
	-- a query that cannot be wrapped in parentheses is refused without asking acli
	local sent = #acli.requests
	for _, bad in { "a = 1) OR (b = 2", "a = 1 ORDER BY created", "a = 1 order  by x", "x = 'open", "(a = 1" } do
		local refused = runJira(w, jira, bad, nil)
		eq(refused.result, nil, "no result: " .. bad)
		eq(refused.problem.kind, "invalid", "refused: " .. bad)
	end
	eq(#acli.requests, sent, "none of them reached acli")
	eq(jira.scopeProblem("a = 1) OR (b = 2"), "Unbalanced parentheses.", "an extra closing parenthesis")
	eq(jira.scopeProblem("(a = 1"), "Unbalanced quotes or parentheses.", "an open parenthesis")
	eq(jira.scopeProblem("a = 1 ORDER BY x"), "Leave out ORDER BY: issues are listed by status, then priority.", "ordering is the search's")
	local blank = runJira(w, jira, "  ", nil)
	eq(blank.problem.kind, "failed", "a blank filter")
	eq(blank.problem.message, "The view's query is empty.", "message")
	eq(runJira(w, jira, 'summary ~ "a) ORDER BY (b"', nil).problem, nil, "quoted text may hold parentheses and ORDER BY")
	-- cancellation wins everywhere
	local searches = acliCount(acli, "search")
	local cancelled = runJira(w, jira, query, function(): boolean
		return false
	end)
	eq(cancelled.problem.kind, "superseded", "cancelled before the search")
	eq(acliCount(acli, "search"), searches, "nothing was sent")
	local go = true
	acli.override = function(req: AcliReq): Reply?
		if req.kind == "search" then
			go = false
		end
		return nil
	end
	local during = runJira(w, jira, query, function(): boolean
		return go
	end)
	eq(during.problem.kind, "superseded", "cancelled while the search was in flight")
end)

case("jira.issue: body as markdown, fields, links and dates", function(w: World)
	local jira = w.load("jira") :: Jira
	local github = w.load("github") :: Github
	local acli = newAcli(w)
	local function ref(key: string, summary: string, category: string): any
		return { key = key, fields = { summary = summary, status = { statusCategory = { key = category } } } }
	end
	local blocks: { any } = {
		{ type = "heading", attrs = { level = 2 }, content = { { type = "text", text = "Steps" } } },
		{
			type = "paragraph",
			content = {
				{ type = "text", text = "See " },
				{ type = "text", text = "the guide", marks = { { type = "strong" }, { type = "link", attrs = { href = "https://example.com/guide" } } } },
				{ type = "text", text = "." },
			},
		},
		{
			type = "bulletList",
			content = {
				{ type = "listItem", content = { { type = "paragraph", content = { { type = "text", text = "Open /login" } } } } },
				{ type = "listItem", content = { { type = "paragraph", content = { { type = "text", text = "Press " }, { type = "text", text = "Enter", marks = { { type = "code" } } } } } } },
			},
		},
	}
	local links: { any } = {
		{ type = { inward = "is blocked by", outward = "blocks" }, outwardIssue = ref("ABC-3", "Login API", "done") },
		{ type = { inward = "is blocked by", outward = "blocks" }, inwardIssue = ref("ABC-4", "Design", "new") },
		{ type = { inward = "relates to", outward = "relates to" }, outwardIssue = { fields = { summary = "No key" } } },
	}
	acli.views["ABC-12"] = {
		key = "ABC-12",
		fields = {
			summary = "Fix login",
			description = { type = "doc", version = 1, content = blocks },
			parent = { key = "ABC-1", fields = { summary = "Auth rework" } },
			customfield_10020 = array({
				{ boardId = 1, state = "closed", name = "Sprint 1" },
				{ boardId = 1, state = "active", name = "Sprint 2" },
				{ boardId = 1, state = "future", name = "Sprint 3" },
			}),
			customfield_10036 = array({ { id = "1", value = "not a sprint" } }),
			components = array({ { name = "Web" }, { name = "API" } }),
			fixVersions = array({ { name = "v2" } }),
			issuelinks = array(links),
			subtasks = array({ ref("ABC-13", "Add a test", "indeterminate") }),
			comment = { total = 2 },
			created = "2026-05-27T09:38:49.512-0500",
			updated = "2026-05-28T10:00:00.000+0000",
		},
	}
	local out = runJiraIssue(w, jira, "ABC-12", nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(#acli.requests, 2, "the site, then the work item")
	eq(acli.requests[2].kind, "view", "a view")
	eq(acli.requests[2].argv[5], "ABC-12", "of the key")
	eq(acliOption(acli.requests[2].argv, "--fields"), "*all", "with every field")
	eq(out.detail.body, "## Steps\n\nSee [**the guide**](https://example.com/guide).\n\n- Open /login\n- Press `Enter`", "the description as markdown")
	same(out.detail.fields, {
		{ label = "Parent", value = "ABC-1 Auth rework" },
		{ label = "Sprint", value = "Sprint 2" },
		{ label = "Components", value = "Web, API" },
		{ label = "Fix versions", value = "v2" },
	}, "parent, the active sprint (the sprint field found by its shape), components and fix versions, in order")
	same(out.detail.linked, {
		{ ref = "ABC-3", title = "Login API", url = "https://acme.atlassian.net/browse/ABC-3", state = "done", relation = "blocks", status = { text = "Done", tone = "success" } },
		{ ref = "ABC-4", title = "Design", url = "https://acme.atlassian.net/browse/ABC-4", state = "open", relation = "is blocked by", status = { text = "To Do", tone = "muted" } },
		{ ref = "ABC-13", title = "Add a test", url = "https://acme.atlassian.net/browse/ABC-13", state = "open", relation = "subtask", status = { text = "In Progress", tone = "warning" } },
	}, "an outward link, an inward one, a subtask, each with its status (here its category's name: no status name); a link with no key is dropped")
	eq(out.detail.comments, 2, "comments")
	eq(out.detail.created, github.epoch("2026-05-27T14:38:49Z"), "a -0500 offset is converted to UTC")
	eq(out.detail.updated, github.epoch("2026-05-28T10:00:00Z"), "updated")
	-- a work item with nothing set reads as empty
	acli.views["ABC-14"] = { key = "ABC-14", fields = { summary = "Bare" } }
	local bare = runJiraIssue(w, jira, "ABC-14", nil)
	eq(bare.problem, nil, "problem")
	eq(bare.detail.body, "", "no description")
	same(bare.detail.fields, { { label = "Parent" }, { label = "Sprint" }, { label = "Components" }, { label = "Fix versions" } }, "every row, with no value")
	same(bare.detail.linked, {}, "no links")
	eq(bare.detail.comments, nil, "no comment count")
	eq(bare.detail.created, nil, "no creation date")
	-- a plain-text description, cut long
	acli.views["ABC-15"] = { key = "ABC-15", fields = { summary = "Long", description = string.rep("é", 20005) } }
	local long = runJiraIssue(w, jira, "ABC-15", nil)
	eq(utf8.len(long.detail.body), 20001, "a long description is cut at 20000 characters, on a character boundary, and marked")
	eq(string.sub(long.detail.body, -3), "…", "with an ellipsis")
	-- what acli answers that is no work item
	local requests = #acli.requests
	local badKey = runJiraIssue(w, jira, "abc-1", nil)
	eq(badKey.detail, nil, "no detail")
	eq(badKey.problem.kind, "failed", "a key that is none")
	eq(#acli.requests, requests, "and nothing was asked")
	local gone = runJiraIssue(w, jira, "ABC-99", nil)
	eq(gone.detail, nil, "an issue acli cannot see")
	eq(gone.problem.kind, "failed", "is a failed read")
	eq(gone.problem.message, "Issue does not exist or you do not have permission to see it.", "in acli's words")
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "view" then { stdout = "not json" } else nil
	end
	local junk = runJiraIssue(w, jira, "ABC-12", nil)
	eq(junk.problem.kind, "failed", "no JSON")
	eq(junk.problem.message, "acli printed unexpected issue data.", "message")
	-- signed out mid-way forgets the site; cancellation wins
	local lookups = acliCount(acli, "auth")
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "view" then { status = 1, stderr = "✗ Error: unauthorized: use 'acli jira auth login' to authenticate\n" } else nil
	end
	eq(runJiraIssue(w, jira, "ABC-12", nil).problem.kind, "auth", "signed out")
	acli.override = nil
	eq(runJiraIssue(w, jira, "ABC-12", nil).problem, nil, "signed in again")
	eq(acliCount(acli, "auth"), lookups + 1, "the site was looked up again")
	local views = acliCount(acli, "view")
	local cancelled = runJiraIssue(w, jira, "ABC-12", function(): boolean
		return false
	end)
	eq(cancelled.problem.kind, "superseded", "cancelled before the call")
	eq(acliCount(acli, "view"), views, "nothing was sent")
	local go = true
	acli.override = function(req: AcliReq): Reply?
		if req.kind == "view" then
			go = false
		end
		return nil
	end
	local during = runJiraIssue(w, jira, "ABC-12", function(): boolean
		return go
	end)
	eq(during.problem.kind, "superseded", "cancelled while the call was in flight")
end)

case("jira.adf: blocks, marks and inline nodes become markdown", function(w: World)
	local jira = w.load("jira") :: Jira
	local function t(s: string, marks: { any }?): any
		return { type = "text", text = s, marks = marks }
	end
	local function p(...: any): any
		return { type = "paragraph", content = { ... } }
	end
	local function doc(...: any): any
		return { type = "doc", version = 1, content = { ... } }
	end
	local function item(...: any): any
		return { type = "listItem", content = { ... } }
	end
	local function row(kind: string, ...: string): any
		local cells: { any } = {}
		for _, s in { ... } do
			table.insert(cells, { type = kind, content = { p(t(s)) } })
		end
		return { type = "tableRow", content = cells }
	end
	eq(jira.adf(doc(p(t("one")), p(t("two")))), "one\n\ntwo", "blocks are separated by a blank line")
	eq(jira.adf(doc(p(t("a"), { type = "hardBreak" }, t("b")))), "a\nb", "a hard break is a line break")
	eq(jira.adf(doc({ type = "heading", attrs = { level = 3 }, content = { t("Title") } })), "### Title", "a heading")
	eq(jira.adf(doc({ type = "heading", attrs = { level = 9 }, content = { t("Deep") } })), "###### Deep", "at most six hashes")
	eq(
		jira.adf(doc(p(
			t("a", { { type = "code" } }),
			t(" "),
			t("b ", { { type = "strong" } }),
			t("c", { { type = "em" } }),
			t(" "),
			t("d", { { type = "strike" } }),
			t(" "),
			t("e", { { type = "link", attrs = { href = "https://x.test/e" } } })
		))),
		"`a` **b** *c* ~~d~~ [e](https://x.test/e)",
		"marks; the space inside strong stays outside the asterisks"
	)
	eq(
		jira.adf(doc({ type = "bulletList", content = { item(p(t("a"))), item(p(t("b")), { type = "bulletList", content = { item(p(t("c"))) } }) } })),
		"- a\n- b\n  - c",
		"a bullet list, a nested one under its item"
	)
	eq(
		jira.adf(doc({ type = "orderedList", content = { item(p(t("one")), { type = "bulletList", content = { item(p(t("inner"))) } }), item(p(t("two"))) } })),
		"1. one\n   - inner\n2. two",
		"an ordered list counts, and a nested list sits under the marker's width"
	)
	eq(jira.adf(doc({ type = "orderedList", attrs = { order = 3 }, content = { item(p(t("x"))) } })), "3. x", "an ordered list starts at its order")
	eq(jira.adf(doc({ type = "codeBlock", attrs = { language = "lua" }, content = { t("print(1)\nprint(2)") } })), "```lua\nprint(1)\nprint(2)\n```", "a fenced code block with its language")
	eq(jira.adf(doc({ type = "codeBlock", content = { t("a ``` b") } })), "````\na ``` b\n````", "a fence longer than any run of backticks inside")
	eq(jira.adf(doc({ type = "blockquote", content = { p(t("a")), p(t("b")) } })), "> a\n> \n> b", "a quote marks every line")
	eq(jira.adf(doc(p(t("a")), { type = "rule" }, p(t("b")))), "a\n\n---\n\nb", "a rule")
	eq(
		jira.adf(doc({ type = "table", content = { row("tableHeader", "A", "B"), row("tableCell", "1", "x|y") } })),
		"| A | B |\n| --- | --- |\n| 1 | x\\|y |",
		"a table: the first row is the header, a pipe in a cell is escaped"
	)
	eq(jira.adf(doc({ type = "panel", attrs = { panelType = "info" }, content = { p(t("note")) } })), "note", "a panel shows its content")
	eq(
		jira.adf(doc(p(
			t("hi "),
			{ type = "mention", attrs = { text = "@Ann" } },
			t(" "),
			{ type = "emoji", attrs = { shortName = ":smile:" } },
			t(" "),
			{ type = "inlineCard", attrs = { url = "https://x.test/c" } },
			t(" "),
			{ type = "status", attrs = { text = "DONE" } },
			{ type = "date", attrs = { timestamp = "1" } }
		))),
		"hi @Ann :smile: https://x.test/c DONE",
		"mentions, emoji, smart links and statuses are text; a date draws nothing"
	)
	eq(jira.adf(doc(p(t("a")), { type = "mediaSingle", content = { { type = "media", attrs = { id = "1" } } } })), "a", "media draws nothing")
	eq(jira.adf(doc({ type = "taskList", content = { { type = "taskItem", content = { t("do it") } } } })), "do it", "an unknown block shows what it holds")
	eq(jira.adf(nil), "", "nothing is empty")
end)

case("jira.projects: lists the visible projects by key and leaves out what is no project key", function(w: World)
	local jira = w.load("jira") :: Jira
	local acli = newAcli(w)
	acli.projects = { { key = "OXYGEN", name = "Oxygen" }, { key = "CAR", name = "CARBON" }, { key = "lower", name = "Not a Jira key" }, { key = "NONAME" } }
	local got: any, why: any = nil, nil
	local calls = 0
	local function list()
		calls, got, why = 0, nil, nil
		jira.projects(function(projects, problem)
			calls += 1
			got, why = projects, problem
		end)
		w.flush()
	end
	list()
	eq(calls, 1, "done calls")
	eq(why, nil, "problem")
	eq(#acli.requests, 1, "one call, no site needed")
	eq(table.concat(acli.requests[1].argv, " "), "acli jira project list --paginate --json", "the project list")
	same(got, { { key = "CAR", name = "CARBON" }, { key = "NONAME", name = "" }, { key = "OXYGEN", name = "Oxygen" } }, "sorted by key; a missing name is empty; a key that is no project key is left out")
	acli.site = nil
	list()
	eq(got, nil, "no projects")
	eq(why.kind, "auth", "signed out")
	acli.site = "acme.atlassian.net"
	acli.override = function(req: AcliReq): Reply?
		return if req.kind == "projects" then { stdout = "not json" } else nil
	end
	list()
	eq(why.kind, "failed", "output that is no project list")
end)

-- ---- host.luau: the Plotroom block (`prs`), driven through the def it registers with tern.block.define

return {}
