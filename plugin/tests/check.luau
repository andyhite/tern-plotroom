--!strict
-- Assertions over the real parsing/editing helpers. Run by the window entry's
-- `plugin.plotroom.selftest` command when PLOTROOM_SELFTEST=1; a failed assert
-- propagates as a plugin error. No network, git or KV access.

local github = require("../github")
local input = require("../input")
local jira = require("../jira")
local process = require("../process")
local tracker = require("../tracker")
local worktree = require("../worktree")

local M = {}

local function item(n: number, repo: string, updated: string, extra: { [string]: any }?): { [string]: any }
	local t: { [string]: any } = {
		number = n,
		title = "T" .. n,
		url = "https://github.com/" .. repo .. "/pull/" .. n,
		author = "u",
		state = "OPEN",
		isDraft = false,
		updatedAt = updated,
		createdAt = updated,
		head = "b" .. n,
		base = "main",
		additions = 1,
		deletions = 2,
		changedFiles = 3,
		comments = 4,
		labels = tern.json.array({}),
	}
	if extra then
		for k, v in extra do
			t[k] = v
		end
	end
	return t
end

local function page(items: { any }, total: number?, next: string?): string
	return tern.json.encode({ total = total or #items, cost = 1, next = next, items = tern.json.array(items) })
end

local function ghRuns(nodes: { any })
	return github.runs(tern.json.array(nodes))
end

function M.run()
	-- search pages: rejection, empty, dedupe, order
	assert(github.parsePage("not json") == nil, "malformed JSON is rejected")
	assert(github.parsePage("{}") == nil, "missing items are rejected")
	assert(github.parsePage(page({ {} })) == nil, "non-PR nodes are rejected")
	assert(github.parsePage(page({ item(1, "a/b", "2026-01-01T00:00:00Z", { url = "https://evil.example/a/b/pull/1" }) })) == nil, "foreign URLs are rejected")
	assert(github.parsePage(page({ item(1, "a/b", "2026-01-01T00:00:00Z", { number = 2 }) })) == nil, "mismatched numbers are rejected")
	local empty = github.parsePage(page({}))
	assert(empty and #empty.prs == 0 and empty.total == 0, "empty results parse")
	local pg = github.parsePage(page({
		item(1, "A/B", "2026-01-01T00:00:00Z"),
		item(2, "a/b", "2026-03-01T00:00:00Z", { isDraft = true }),
		item(1, "a/b", "2026-01-01T00:00:00Z"),
		item(3, "a/b", "2026-03-01T00:00:00Z", { state = "MERGED" }),
	}))
	assert(pg and #pg.prs == 4, "four items parsed")
	local rec = github.reconcile(pg.prs)
	assert(#rec == 3, "duplicates are folded by lowercase identity")
	assert(rec[1].key == "a/b#2" and rec[2].key == "a/b#3" and rec[3].key == "a/b#1", "updated desc, key tie-break")
	assert(rec[1].draft and rec[2].state == "merged", "draft and merged states")
	assert(rec[3].repo == "A/B", "display spelling preserved")
	local rich = github.parsePage(page({ item(5, "a/b", "2026-01-01T00:00:00Z", { review = "CHANGES_REQUESTED", checks = "ERROR", labels = tern.json.array({ "bug" }) }) }))
	local rp = rich and rich.prs[1]
	assert(rp and rp.review == "changes" and rp.checks == "failure" and rp.labels[1] == "bug", "review, checks, labels")
	assert(rp and rp.additions == 1 and rp.files == 3 and rp.comments == 4 and rp.head == "b5" and rp.base == "main", "counts and branches")
	local ghost = item(6, "a/b", "2026-01-01T00:00:00Z")
	ghost.author = nil
	local gp = github.normalize(ghost)
	assert(gp and gp.author == "ghost", "missing author is ghost")
	local paged = github.parsePage(page({}, 250, "Y3Vy"))
	assert(paged and paged.next == "Y3Vy", "cursor parses")
	local bare = github.parsePage(tern.json.encode({ total = 0, items = tern.json.array({}) }))
	assert(bare and bare.cost == 1 and bare.next == nil, "cost and next default")
	assert(github.epoch("1970-01-02T00:00:00Z") == 86400, "epoch")
	assert(github.epoch("2026-05-27T09:38:49.512-0500") == github.epoch("2026-05-27T14:38:49Z"), "an offset moves the time to UTC")
	local runs = ghRuns({
		{ name = "ok", status = "COMPLETED", conclusion = "SUCCESS", startedAt = "2026-01-01T00:00:00Z", completedAt = "2026-01-01T00:02:31Z" },
		{ name = "skip", status = "COMPLETED", conclusion = "SKIPPED" },
		{ name = "run", status = "IN_PROGRESS" },
		{ context = "ci/x", state = "FAILURE" },
		{ __typename = "Other" },
	})
	assert(#runs == 4 and runs[1].name == "ci/x" and runs[1].status == "failure", "failures sort first, unknown nodes dropped")
	assert(runs[2].status == "pending" and runs[2].detail == "In progress", "unfinished runs are pending")
	assert(runs[3].detail == "Passed · 2m 31s" and runs[4].detail == "Skipped", "durations on finished runs only")
	local req = ghRuns({
		{ name = "bad", status = "COMPLETED", conclusion = "FAILURE" },
		{ name = "must", status = "COMPLETED", conclusion = "SUCCESS", isRequired = true },
	})
	assert(req[1].name == "must" and req[1].required and not req[2].required, "required checks sort above failing optional ones")
	local rerun = ghRuns({
		{ name = "build", status = "COMPLETED", conclusion = "FAILURE", startedAt = "2026-01-01T00:00:00Z", completedAt = "2026-01-01T00:01:00Z", checkSuite = { id = "S1" } },
		{ name = "build", status = "COMPLETED", conclusion = "SUCCESS", startedAt = "2026-01-01T01:00:00Z", completedAt = "2026-01-01T01:01:00Z", checkSuite = { id = "S1" } },
		{ name = "build", status = "COMPLETED", conclusion = "CANCELLED", startedAt = "2025-12-31T00:00:00Z", checkSuite = { id = "S1" } },
		{ name = "build", status = "COMPLETED", conclusion = "FAILURE", startedAt = "2026-01-01T00:00:00Z", checkSuite = { id = "S2" } },
	})
	assert(#rerun == 2 and rerun[1].status == "failure" and rerun[2].status == "success", "re-runs inside one check suite list the newest; the same name in another suite is its own row")
	assert(jira.scopeProblem('summary ~ "a) OR (b"') == nil, "parentheses inside quotes are text")
	assert(jira.scopeProblem("a = 1) OR (b = 2") ~= nil, "a view cannot close the query's parenthesis")
	local p422 = github.classify({ status = 1, stderr = "gh: Validation Failed (HTTP 422)\n", stdout = "", timed_out = false })
	assert(p422.kind == "invalid" and string.find(p422.message, "Validation Failed", 1, true), "HTTP 422 is terminal and keeps gh's text")
	assert(github.classify({ status = 1, stderr = "gh: API rate limit exceeded for user ID 1.", stdout = "", timed_out = false }).kind == "rate-limit", "graphql rate limit")
	assert(github.classify({ status = 1, stderr = "gh: The listed users and repositories cannot be searched either because the resources do not exist or you do not have permission to view them.", stdout = "", timed_out = false }).kind == "invalid", "unsearchable repo is terminal")
	local mp = github.normalize(item(12, "a/b", "2026-01-01T00:00:00Z", { title = "Fix 😀 parser", author = "octo", head = "fix/lexer" }))
	assert(mp, "match fixture normalizes")
	local hit, range = github.match(mp, " PARSER ")
	assert(hit and range and range[1] == 7 and range[2] == 13, "title match gives a UTF-16 range")
	hit, range = github.match(mp, "#12")
	assert(hit and range == nil, "number matches without a range")
	assert((github.match(mp, "lexer")), "branch matches")
	assert(not (github.match(mp, "zzz")), "no match")

	-- rate-limit headers (shape of real `gh api --include` output) and pacing
	local now = 1000
	local real = "HTTP/2.0 200 OK\nX-Ratelimit-Limit: 30\r\nx-ratelimit-remaining: 25\r\nX-Ratelimit-Reset: 1060\r\nX-Ratelimit-Resource: graphql\r\nRetry-After: 120\r\n\r\n{\"a\":1}"
	local q, body = github.parseResponse(real, now)
	assert(q and q.limit == 30 and q.remaining == 25 and q.reset == 1060 and q.retryUntil == 1120 and body == "{\"a\":1}", "headers parse case-insensitively, body is split off")
	q, body = github.parseResponse("HTTP/1.1 100 Continue\r\n\r\n" .. real, now)
	assert(q and q.remaining == 25 and body == "{\"a\":1}", "a 100 Continue block precedes the real one")
	q, body = github.parseResponse("{\"a\":1}", now)
	assert(q == nil and body == "{\"a\":1}", "no headers: all body, no quota")
	assert(github.parseResponse("HTTP/2.0 200 OK\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Remaining: 1\r\n\r\n{}", now) == nil, "other rate-limit resources are ignored")
	q = github.parseResponse("HTTP/2.0 403 Forbidden\r\nRetry-After: Thu, 01 Jan 1970 00:17:40 GMT\r\n\r\n{}", now)
	assert(q and q.retryUntil == 1060, "Retry-After accepts an HTTP-date")
	assert(github.cooldown({ remaining = 0, reset = 1060 }, now) == 61, "exhausted quota waits for the reset")
	assert(github.cooldown({ remaining = 0, reset = 900 }, now) == 0, "a passed reset ends the wait")
	assert(github.cooldown({ remaining = 5, reset = 1060, retryUntil = 1120 }, now) == 120, "Retry-After wins over remaining quota")
	assert(github.cooldown(nil, now) == 0, "unknown quota never waits")
	assert(github.interval(nil, now, 1, 1, 60000) == 60000, "no headers: base interval")
	assert(github.interval({ remaining = 30, reset = 1060 }, now, 1, 1, 60000) == 60000, "ample quota: base interval")
	assert(github.interval({ remaining = 5, reset = 1600 }, now, 2, 1, 60000) == 300000, "scarce quota spreads refreshes over the window")
	assert(github.interval({ remaining = 5, reset = 1600 }, now, 2, 2, 60000) == 600000, "panes divide the budget")
	assert(github.interval({ remaining = 1, reset = 1600 }, now, 2, 1, 60000) == 601000, "less than one refresh left waits for the reset")
	assert(github.interval({ remaining = 9, reset = 1060, retryUntil = 1120 }, now, 1, 1, 60000) == 120000, "cooldown sets the interval")
	assert(github.interval({ remaining = 1, reset = 1001 }, now, 1, 1, 60000) == 60000, "scarce quota never polls faster than the base")
	assert(github.interval({ remaining = 0, reset = 1005 }, now, 1, 1, 60000) == 60000, "a short cooldown never polls faster than the base")
	local merged = github.merge({ remaining = 0, reset = 1060, limit = 30 }, { remaining = 20, reset = 1060, limit = 30 }, now)
	assert(merged.remaining == 0, "a stale response cannot raise the remaining quota")
	merged = github.merge(merged, { remaining = 29, reset = 1120, limit = 30 }, now)
	assert(merged.remaining == 29 and merged.reset == 1120, "a newer window replaces the old one")
	merged = github.merge({ remaining = 5, reset = 1060, retryUntil = 1200 }, { retryUntil = 1100 }, now)
	assert(merged.retryUntil == 1200 and merged.remaining == 5, "an earlier Retry-After or missing quota never shortens the wait")

	-- UTF-8 / UTF-16 editing
	local m = input.new("a😀b")
	assert(input.u16(m.text, #m.text) == 4, "emoji is two UTF-16 units")
	assert(input.u16(m.text, #"a😀") == 3, "byte offset converts to units")
	m.anchor, m.cur = 1, #"a😀"
	local props = input.props(m)
	assert(props.cursor == 3 and props.anchor == 1, "selection offsets are UTF-16")
	local function curText(): string
		return m.text
	end
	local noop = function(_: string) end
	local function key(name: string, text: string?, shift: boolean?): Key
		return { name = name, text = text, ctrl = false, alt = false, shift = shift == true, meta = false }
	end
	input.key(m, key("backspace"), noop)
	assert(m.text == "ab" and m.cur == 1, "deleting a selection removes the whole emoji")
	input.key(m, { name = "paste", text = "x\r\ny😀", ctrl = false, alt = false, shift = false, meta = false }, noop)
	assert(curText() == "ax y😀b", "paste turns line breaks into spaces")
	input.key(m, key("left"), noop)
	input.key(m, key("left", nil, true), noop)
	assert(input.selected(m) == "y", "shift-left selects one codepoint")
	assert(input.undo(m) and curText() == "ab", "undo restores the earlier text")

	-- multi-line mode
	assert(input.clean("a\r\nb\rc\td\1") == "a b cd", "single-line clean: breaks become spaces, tabs and controls drop")
	assert(input.clean("a\r\nb\rc\td\1", true) == "a\nb\nc\td", "multi clean keeps and normalises breaks and tabs")
	assert(input.new("a\r\nb\tc", true).text == "a\nb\tc", "multi new keeps breaks and tabs")
	assert(input.new("a\nb").text == "a b", "single new still flattens")
	local function modKey(name: string, mod: string): Key
		return { name = name, ctrl = mod == "ctrl", alt = mod == "alt", shift = false, meta = mod == "meta" }
	end
	local s1 = input.new("ab")
	assert(not input.key(s1, key("enter"), noop) and s1.text == "ab", "enter is not handled single-line")
	assert(not input.key(s1, key("up"), noop) and not input.key(s1, key("down"), noop), "up/down unhandled single-line")
	s1.cur = 1
	input.key(s1, key("home"), noop)
	assert(s1.cur == 0, "home goes to the start single-line")
	input.key(s1, key("end"), noop)
	assert(s1.cur == 2, "end goes to the end single-line")
	local ml = input.new("héllo\nab", true)
	assert(input.key(ml, key("enter"), noop) and ml.text == "héllo\nab\n" and ml.cur == #ml.text, "enter inserts a newline")
	assert(not input.key(ml, modKey("enter", "meta"), noop), "meta+enter is left to the caller")
	assert(not input.key(ml, modKey("enter", "ctrl"), noop), "ctrl+enter is left to the caller")
	assert(not input.key(ml, modKey("enter", "alt"), noop) and ml.text == "héllo\nab\n", "alt+enter is left to the caller")
	ml = input.new("héllo\nab", true)
	input.key(ml, key("up"), noop)
	assert(ml.cur == #"h", "up keeps the byte column, snapped off the middle of é")
	input.key(ml, key("up"), noop)
	assert(ml.cur == 0, "up on the first line goes to 0")
	ml.cur = 1
	input.key(ml, key("down"), noop)
	assert(ml.cur == #"héllo\na", "down keeps the column")
	input.key(ml, key("down"), noop)
	assert(ml.cur == #ml.text, "down on the last line goes to the end")
	ml.cur = #"héllo"
	input.key(ml, key("down"), noop)
	assert(ml.cur == #ml.text, "down clamps to a shorter line")
	ml = input.new("abc\nhé", true)
	ml.cur = 2
	input.key(ml, key("down"), noop)
	assert(ml.cur == #"abc\nh", "down snaps off the middle of a multi-byte character")
	ml = input.new("a\nbcd", true)
	ml.cur = #"a\nbcd"
	input.key(ml, key("up"), noop)
	assert(ml.cur == 1, "up clamps to a shorter line")
	ml = input.new("héllo\nab", true)
	ml.cur = 0
	ml.anchor = nil
	input.key(ml, key("down", nil, true), noop)
	assert(input.selected(ml) == "héllo\n", "shift+down extends the selection")
	ml.cur, ml.anchor = #"héllo\nab", nil
	input.key(ml, key("home"), noop)
	assert(ml.cur == #"héllo\n", "home goes to the line start")
	input.key(ml, key("end"), noop)
	assert(ml.cur == #ml.text, "end goes to the line end")
	ml.cur = 1
	input.key(ml, key("end"), noop)
	assert(ml.cur == #"héllo", "end stops before the newline")
	input.key(ml, key("home", nil, true), noop)
	assert(input.selected(ml) == "héllo", "shift+home selects to the line start")
	local pm = input.new("", true)
	input.key(pm, { name = "paste", text = "x\r\ny", ctrl = false, alt = false, shift = false, meta = false }, noop)
	assert(pm.text == "x\ny", "paste keeps line breaks in multi")

	-- remotes and worktree records
	assert(worktree.normalizeRemote("https://github.com/cli/cli.git") == "cli/cli", "https remote")
	assert(worktree.normalizeRemote("https://user:tok@github.com/cli/cli") == "cli/cli", "https remote with credentials")
	assert(worktree.normalizeRemote("git@github.com:cli/cli.git") == "cli/cli", "scp remote")
	assert(worktree.normalizeRemote("ssh://git@github.com/cli/cli.git") == "cli/cli", "ssh remote")
	assert(worktree.normalizeRemote("https://github.com/cli/../x") == nil, "dot segments are rejected")
	assert(worktree.normalizeRemote("https://gitlab.com/cli/cli") == nil, "other hosts are rejected")
	assert(worktree.normalizeRemote("https://evilgithub.com/cli/cli") == nil, "lookalike hosts are rejected")
	assert(worktree.normalizeRemote("git@github.com-personal:cli/cli.git") == nil, "an alias is not github.com until ssh config says so")
	local ah, aid, assh = worktree.parseRemote("git@github.com-personal:cli/cli.git")
	assert(ah == "github.com-personal" and aid == "cli/cli" and assh, "scp alias parses to its transport host")
	local h2, id2, ssh2 = worktree.parseRemote("ssh://git@work-gh:22/cli/cli")
	assert(h2 == "work-gh" and id2 == "cli/cli" and ssh2, "ssh:// alias with port")
	assert(worktree.parseRemote("git@-oProxyCommand=x:a/b") == nil, "option-like host is rejected")
	assert(worktree.sshHostname("user git\nhostname GitHub.com\nport 22\n") == "github.com", "ssh -G hostname")
	assert(worktree.sshHostname("user git\nport 22\n") == nil, "no hostname line")
	local recs = worktree.parseWorktrees(
		"worktree /r/main\0HEAD aaa\0branch refs/heads/main\0\0"
			.. "worktree /r/with space\nnewline\0HEAD bbb\0detached\0locked reason\0\0"
			.. "worktree /r/gone\0HEAD ccc\0branch refs/heads/plotroom/a/b/pr-1\0prunable gitdir file points to non-existent location\0\0"
	)
	assert(#recs == 3 and recs[1].path == "/r/main" and recs[1].branch == "refs/heads/main", "main record")
	assert(recs[2].path == "/r/with space\nnewline" and recs[2].detached and recs[2].locked, "path with space and newline")
	assert(recs[3].prunable and recs[3].branch == "refs/heads/plotroom/a/b/pr-1", "prunable branch record")
	local verdict = worktree.reconcile(recs, "plotroom/a/b/pr-1", "/r.plotroom/a/b/pr-1")
	assert(verdict == "error", "prunable record for the branch is an error")
	assert(worktree.reconcile(recs, "plotroom/a/b/pr-2", "/r/gone") == "error", "a record on the target path collides")
	assert(worktree.reconcile(recs, "plotroom/a/b/pr-2", "/nonexistent/plotroom/target") == "create", "unrelated records do not block")
	assert(worktree.expandPath("~/x", "/home/u") == "/home/u/x" and worktree.expandPath("rel", "/h") == nil, "path expansion")
	assert(worktree.itemOfPath("/wt/plotroom-a_b-pr-12x") == nil, "not a PR worktree")
	assert(worktree.itemOfPath("/wt/plotroom-a_bc-pr-1") == "a/bc#1", "another repository's worktree maps to its own key")

	-- issues: slugs, branch formats, matching, ordering and worktree paths
	assert(tracker.slug("Fix: Login → redirect!!") == "fix-login-redirect", "a title becomes ASCII words joined by dashes")
	assert(tracker.slug("  --Hello__World--  ") == "hello-world", "a run of other characters is one dash, none at the ends")
	assert(tracker.slug(string.rep("abcdefghi ", 6)) == "abcdefghi-abcdefghi-abcdefghi-abcdefghi", "a long title is cut at 40 bytes, with no dash left at the end")
	assert(tracker.slug("¡¿") == "issue", "a title with no ASCII letter or digit is just issue")
	assert(tracker.branchName("{key}-{slug}", { key = "12", slug = "x" }) == "12-x", "a format fills in its variables")
	assert(tracker.branchName("{owner}/{repo}#{key}", { key = "12", slug = "x", owner = "o", repo = "r" }) == "o/r#12", "any variable, anywhere")
	local nobranch, nobranchWhy = tracker.branchName("{slug}", { slug = "x" })
	assert(nobranch == nil and nobranchWhy == "Include {key}, so each issue gets its own branch.", "a format without {key} names no branch")
	assert(tracker.formatProblem("   ") == "A format is required.", "a blank format is refused")
	assert(tracker.formatProblem("{foo}-{key}") == "Unknown variable {foo}.", "an unknown variable is named")
	assert(tracker.formatProblem("x-{slug}") == "Include {key}, so each issue gets its own branch.", "{key} is required")
	assert(tracker.formatProblem("feat/{owner}-{repo}-{key}-{slug}-{project}") == nil, "every variable is accepted")
	assert(tracker.refLabel("12") == "#12" and tracker.refLabel("ABC-12") == "ABC-12", "a number reads #12, a Jira key as it is")
	assert(tracker.jiraProject("ABC") and tracker.jiraProject("A1_B"), "a Jira project key is capitals, digits and underscores")
	for _, p in { "abc", "A", "o/r", "1AB", "" } do
		assert(not tracker.jiraProject(p), "not a Jira project key: " .. p)
	end
	local ip = github.normalizeIssue({ number = 12, title = "Fix 😀 login", url = "https://github.com/a/b/issues/12", author = "octo", state = "OPEN", labels = tern.json.array({ "bug" }), assignees = tern.json.array({ "ann" }) })
	assert(ip, "the issue fixture normalizes")
	assert(ip.key == "a/b#12" and ip.ref == "12" and ip.tracker == "github" and ip.state == "open", "an issue's identity and state")
	local ihit, irange = tracker.match(ip, " LOGIN ")
	assert(ihit and irange and irange[1] == 7 and irange[2] == 12, "an issue's title match gives a UTF-16 range")
	ihit, irange = tracker.match(ip, "#12")
	assert(ihit and irange == nil, "the number matches without a range")
	assert((tracker.match(ip, "bug")) and (tracker.match(ip, "ann")) and (tracker.match(ip, "octo")), "labels, assignees and the author match")
	assert(not (tracker.match(ip, "zzz")), "no match")
	local function ni(n: number, repo: string, updated: string): any
		local made = github.normalizeIssue({ number = n, title = "T" .. n, url = "https://github.com/" .. repo .. "/issues/" .. n, updatedAt = updated, createdAt = updated })
		assert(made, "the issue fixture normalizes")
		return made
	end
	local irec = tracker.reconcile({
		ni(1, "A/B", "2026-01-01T00:00:00Z"),
		ni(2, "a/b", "2026-03-01T00:00:00Z"),
		ni(1, "a/b", "2026-01-01T00:00:00Z"),
		ni(3, "a/b", "2026-03-01T00:00:00Z"),
	})
	assert(#irec == 3 and irec[1].key == "a/b#2" and irec[2].key == "a/b#3" and irec[3].key == "a/b#1", "duplicates fold by lowercase identity: updated desc, key tie-break")
	assert(irec[3].repo == "A/B", "display spelling preserved")
	assert(worktree.itemOfPath("/x/plotroom-o_r-pr-12/sub") == "o/r#12", "a PR worktree maps to its key")
	assert(select(2, worktree.itemOfPath("/x/plotroom-o_r-pr-12/sub")) == "pr", "and its kind")
	for _, p in { "/x/plotroom-o_r-issue-ABC-7", "/x/plotroom-jira.abc-issue-ABC-7" } do
		local k, kind = worktree.itemOfPath(p)
		assert(k == "abc#ABC-7" and kind == "issue", "a Jira issue worktree in any slot maps to its project key: " .. p)
	end
	local ik, ikind = worktree.itemOfPath("/x/plotroom-o_r-issue-7/src")
	assert(ik == "o/r#7" and ikind == "issue", "a GitHub issue worktree")
	local lk, lkind = worktree.itemOfPath("/r/x.plotroom/a/b/pr-7")
	assert(lk == "a/b#7" and lkind == "pr", "a worktree from an earlier version still maps")
	for _, p in { "/x/plotroom-o_r-prx", "/wt/xplotroom-o_r-issue-1", "/r/o/r/issue-1", "" } do
		assert(worktree.itemOfPath(p) == nil, "not an item worktree: " .. p)
	end

	-- PATH probe output
	assert(process.extractPath("banner\0PLOTROOM_PATH\0/a b:/c\n\0PLOTROOM_END\0tail") == "/a b:/c", "markers carry the PATH, spaces intact")
	assert(process.extractPath("\0PLOTROOM_PATH\0\n\0PLOTROOM_END\0") == nil, "empty PATH is rejected")
	assert(process.extractPath("\0PLOTROOM_PATH\0/a") == nil, "missing end marker is rejected")
end

return M
