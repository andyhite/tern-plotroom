--!strict
-- Assertions over the real parsing/editing helpers. Run by the window entry's
-- `plugin.plotroom.selftest` command when PLOTROOM_SELFTEST=1; a failed assert
-- propagates as a plugin error. No network, git or KV access.

local github = require("../github")
local input = require("../input")
local jira = require("../jira")
local keys = require("../keys")
local process = require("../process")
local tracker = require("../tracker")
local worktree = require("../worktree")
local sorting = require("../sorting")

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
	local function parse(s: string)
		return github.parsePage(s, github.normalize)
	end
	assert(parse("not json") == nil, "malformed JSON is rejected")
	assert(parse("{}") == nil, "missing items are rejected")
	assert(parse(page({ {} })) == nil, "non-PR nodes are rejected")
	assert(parse(page({ item(1, "a/b", "2026-01-01T00:00:00Z", { url = "https://evil.example/a/b/pull/1" }) })) == nil, "foreign URLs are rejected")
	assert(parse(page({ item(1, "a/b", "2026-01-01T00:00:00Z", { number = 2 }) })) == nil, "mismatched numbers are rejected")
	assert(github.parsePage(page({ item(1, "a/b", "2026-01-01T00:00:00Z") }), github.normalizeIssue) == nil, "the issue normalizer rejects a pull request")
	local empty = parse(page({}))
	assert(empty and #empty.items == 0 and empty.total == 0, "empty results parse")
	local pg = parse(page({
		item(1, "A/B", "2026-01-01T00:00:00Z"),
		item(2, "a/b", "2026-03-01T00:00:00Z", { isDraft = true }),
		item(1, "a/b", "2026-01-01T00:00:00Z"),
		item(3, "a/b", "2026-03-01T00:00:00Z", { state = "MERGED" }),
	}))
	assert(pg and #pg.items == 4, "four items parsed")
	local rec = tracker.reconcile(pg.items)
	assert(#rec == 3, "duplicates are folded by lowercase identity")
	assert(rec[1].key == "a/b#2" and rec[2].key == "a/b#3" and rec[3].key == "a/b#1", "updated desc, key tie-break")
	assert(rec[1].draft and rec[2].state == "merged", "draft and merged states")
	assert(rec[3].repo == "A/B", "display spelling preserved")
	local rich = parse(page({ item(5, "a/b", "2026-01-01T00:00:00Z", { review = "CHANGES_REQUESTED", checks = "ERROR", labels = tern.json.array({ "bug" }) }) }))
	local rp = rich and rich.items[1]
	assert(rp and rp.review == "changes" and rp.checks == "failure" and rp.labels[1] == "bug", "review, checks, labels")
	assert(rp and rp.additions == 1 and rp.files == 3 and rp.comments == 4 and rp.head == "b5" and rp.base == "main", "counts and branches")
	local ghost = item(6, "a/b", "2026-01-01T00:00:00Z")
	ghost.author = nil
	local gp = github.normalize(ghost)
	assert(gp and gp.author == "ghost", "missing author is ghost")
	local paged = parse(page({}, 250, "Y3Vy"))
	assert(paged and paged.next == "Y3Vy", "cursor parses")
	local bare = parse(tern.json.encode({ total = 0, items = tern.json.array({}) }))
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
	input.insert(m, "q")
	local before = curText()
	assert(input.key(m, { name = "z", ctrl = true, alt = false, shift = true, meta = false }, noop) and curText() == before, "ctrl-shift-z does nothing: no redo, no undo")
	input.key(m, { name = "z", ctrl = true, alt = false, shift = false, meta = false }, noop)
	assert(curText() ~= before, "ctrl-z still undoes")

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
			.. "worktree /r/gone\0HEAD ccc\0branch refs/heads/feature\0prunable gitdir file points to non-existent location\0\0"
	)
	assert(#recs == 3 and recs[1].path == "/r/main" and recs[1].branch == "refs/heads/main", "main record")
	assert(recs[2].path == "/r/with space\nnewline" and recs[2].detached and recs[2].locked, "path with space and newline")
	assert(recs[3].prunable and recs[3].branch == "refs/heads/feature", "prunable branch record")
	local verdict = worktree.reconcile(recs, "feature", "/wt/feature")
	assert(verdict == "error", "prunable record for the branch is an error")
	assert(worktree.reconcile(recs, "other", "/r/gone") == "error", "a record on the target path collides")
	assert(worktree.reconcile(recs, "other", "/nonexistent/wt/other") == "create", "unrelated records do not block")
	assert(worktree.expandPath("~/x", "/home/u") == "/home/u/x" and worktree.expandPath("rel", "/h") == nil, "path expansion")
	assert(worktree.within("/wt/p", "/wt/p") and worktree.within("/wt/p/src", "/wt/p"), "a worktree and any folder inside it are within it")
	assert(not worktree.within("/wt/p2", "/wt/p") and not worktree.within("/wt", "/wt/p") and not worktree.within("/wt/p", ""), "a sibling sharing the prefix, a parent and an empty root are not")
	assert(worktree.prRef("O", "R", 5) == "refs/plotroom-pr/o/r/pr-5", "a pull request's fetched ref is lowercase")
	assert(worktree.prRef("github", ".github", 1) == "refs/plotroom-pr/github/%2Egithub/pr-1", "with the dots git refuses spelled out")
	assert(worktree.prBranch("feature") == "feature", "a pull request is checked out on its head branch")
	assert(worktree.prBranch("feature", "bob") == "bob/feature", "a fork's under its owner")
	assert(worktree.validLeaf("plotroom-o_r-pr-5") and worktree.validLeaf("pr 5"), "a folder name is one printable segment")
	for _, bad in { "", ".", "..", "a/b", "a\nb", string.rep("x", 201) } do
		assert(not worktree.validLeaf(bad), "not a folder name: " .. bad)
	end

	-- issues: slugs, branch formats, matching, ordering and worktree paths
	assert(tracker.slug("Fix: Login → redirect!!") == "fix-login-redirect", "a title becomes ASCII words joined by dashes")
	assert(tracker.slug("  --Hello__World--  ") == "hello-world", "a run of other characters is one dash, none at the ends")
	assert(tracker.slug(string.rep("abcdefghi ", 6)) == "abcdefghi-abcdefghi-abcdefghi-abcdefghi", "a long title is cut at 40 bytes, with no dash left at the end")
	assert(tracker.slug("¡¿") == "issue", "a title with no ASCII letter or digit is just issue")
	assert(tracker.render("{key}-{slug}", { key = "12", slug = "x" }) == "12-x", "a format fills in its variables")
	assert(tracker.render("{owner}/{repo}#{key}", { key = "12", slug = "x", owner = "o", repo = "r" }) == "o/r#12", "any variable, anywhere")
	assert(tracker.render("{github.user}/{key}-{slug}", { ["github.user"] = "octocat", key = "12", slug = "x" }) == "octocat/12-x", "a dotted variable names a user")
	assert(tracker.render("{jira.user}/{key}", { key = "12" }) == "/12", "a variable the caller has no value for is empty")
	local nobranch, nobranchWhy = tracker.render("{slug}", { slug = "x" })
	assert(nobranch == nil and nobranchWhy == "Include {key}, so each issue gets its own branch.", "a format without {key} names no branch")
	assert(tracker.formatProblem("   ") == "A format is required.", "a blank format is refused")
	assert(tracker.formatProblem("{foo}-{key}") == "Unknown variable {foo}.", "an unknown variable is named")
	assert(tracker.formatProblem("{foo.bar}-{key}") == "Unknown variable {foo.bar}.", "a dotted one is named whole")
	assert(tracker.formatProblem("x-{slug}") == "Include {key}, so each issue gets its own branch.", "{key} is required")
	assert(tracker.formatProblem("feat/{owner}-{repo}-{key}-{slug}-{project}") == nil, "every variable is accepted")
	assert(tracker.formatProblem("{github.user}/{jira.user}-{key}") == nil, "so are both users")
	-- worktree folder names: the same formats in dir mode
	assert(tracker.render(tracker.PR_DIR_DEFAULT, { key = "5", owner = "o", repo = "r" }, true) == "plotroom-o_r-pr-5", "the default folder of a pull request is the name earlier versions gave")
	assert(tracker.render(tracker.ISSUE_DIR_DEFAULT, { key = "ABC-7", owner = "o", repo = "r" }, true) == "plotroom-o_r-issue-ABC-7", "and of an issue")
	assert(tracker.formatProblem(tracker.BRANCH_DEFAULT) == nil and tracker.formatProblem(tracker.PR_DIR_DEFAULT, true) == nil and tracker.formatProblem(tracker.ISSUE_DIR_DEFAULT, true) == nil, "every default is a usable format")
	assert(tracker.formatProblem("a/{key}", true) == "A folder name holds no /.", "a folder name is one path segment")
	assert(tracker.formatProblem("pr-{slug}", true) == "Include {key}, so each worktree gets its own folder.", "{key} is required, in the folder's words")
	assert(tracker.formatProblem("{github.user}-{key}", true) == "Unknown variable {github.user}.", "a folder name names no user")
	assert(tracker.formatProblem("{project}-{key}", true) == "Unknown variable {project}.", "nor a Jira project")
	local slashed, slashedWhy = tracker.render("a/{key}", { key = "1" }, true)
	assert(slashed == nil and slashedWhy == "A folder name holds no /." and tracker.render("a/{key}", { key = "1" }) == "a/1", "the same format names a branch but no folder")
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
	local gone, open1, open2, working = { state = "closed" } :: any, { state = "open" } :: any, { state = "open" } :: any, { category = "indeterminate" } :: any
	local mixed = { gone, open1, open2, working }
	tracker.byStatus(mixed)
	assert(mixed[1] == working and mixed[2] == open1 and mixed[3] == open2 and mixed[4] == gone, "in progress, then to do, then done; ties keep their order")

	-- queue keys: which action a typed key triggers, and which keys an action may have
	local queue: keys.Map = {}
	for _, a in keys.ACTIONS do
		assert(a.default == (if a.id == "more" then "." else ""), "only the command palette has a default key: " .. a.id)
		queue[a.id] = a.default
	end
	queue.worktree, queue["goto"], queue.help = "w", "g", "?"
	assert(keys.action(queue, "w") == "worktree" and keys.action(queue, "?") == "help" and keys.action(queue, ".") == "more" and keys.action(queue, "x") == nil, "a typed key triggers the action that has it")
	assert(keys.shape("") == nil and keys.shape("é") == nil and keys.shape("ab") ~= nil and keys.shape("a b") ~= nil and keys.shape(" ") ~= nil, "a key is one character that is not a gap, and empty is no key")
	assert(keys.problem(queue, "goto", "g") == nil, "an action keeps its own key")
	assert(keys.problem(queue, "worktree", "g") == "Already the shortcut of Go to tab.", "another action's key is refused, naming the action")
	queue.worktree = ""
	assert(keys.action(queue, "w") == nil and keys.action(queue, "") == nil, "a removed action has no key, and no key is its empty one")
	assert(keys.problem(queue, "goto", "w") == nil and keys.problem(queue, "goto", "") == nil, "a key nobody has is free, and empty removes the shortcut")
	assert(keys.caps(queue, "worktree") == nil and (keys.caps(queue, "goto") or {})[1] == "g", "a button shows its key, none once removed")

	-- PATH probe output
	assert(process.extractPath("banner\0PLOTROOM_PATH\0/a b:/c\n\0PLOTROOM_END\0tail") == "/a b:/c", "markers carry the PATH, spaces intact")
	assert(process.extractPath("\0PLOTROOM_PATH\0\n\0PLOTROOM_END\0") == nil, "empty PATH is rejected")
	assert(process.extractPath("\0PLOTROOM_PATH\0/a") == nil, "missing end marker is rejected")

	-- per-view sorts: only meaningful choices are offered, ties keep the list order, default is untouched
	assert(#sorting.choices("issues", "jira") == 1 and sorting.valid("prs", "github", "review") and not sorting.valid("issues", "jira", "updated"), "sorts are offered per kind and integration")
	local early, late, ask = { updated = 10, review = "approved" } :: any, { updated = 20, review = "approved" } :: any, { updated = 5, review = "required" } :: any
	local base = { early, late, ask }
	assert(sorting.apply(base, "updated")[1] == late and sorting.apply(base, "oldest")[1] == ask and sorting.apply(base, "review")[1] == ask and sorting.apply(base, "review")[2] == late, "updated, oldest and review order")
	assert(sorting.apply(base, nil)[1] == early and sorting.apply(base, "bogus")[3] == ask and base[1] == early, "no or unknown sort keeps the order and never changes the input")
	local hi, lo, none = { priority = "High" } :: any, { priority = "Low" } :: any, {} :: any
	assert(sorting.apply({ lo, none, hi }, "priority")[1] == hi and sorting.apply({ lo, none, hi }, "priority")[3] == none, "priority ranks Jira names, unknown last")
	local function cat(i: any): number return i.cat end
	local doneHi, todoLow, wipLow = { priority = "High", cat = 3 } :: any, { priority = "Low", cat = 2 } :: any, { priority = "Low", cat = 1 } :: any
	local byCat = sorting.apply({ doneHi, todoLow, wipLow }, "priority", cat)
	assert(byCat[1] == wipLow and byCat[2] == todoLow and byCat[3] == doneHi, "a category rank orders before the priority")
	assert(sorting.cycle("prs", "github", nil) == "updated" and sorting.cycle("prs", "github", "review") == nil and sorting.cycle("issues", "jira", "priority") == nil, "the cycle ends on the default order")
	assert(sorting.label("bogus") == sorting.label(nil), "an unknown sort reads as the default order")
	require("./triage_check").run()
	require("./portable_check").run()
	require("./board_check").run()
end

return M
