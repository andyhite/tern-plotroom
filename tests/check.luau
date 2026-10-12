--!strict
-- Assertions over the real parsing/editing helpers. Run by the window entry's
-- `plugin.plotroom.selftest` command when PLOTROOM_SELFTEST=1; a failed assert
-- propagates as a plugin error. No network, git or KV access.

local github = require("../github")
local input = require("../input")
local process = require("../process")
local worktree = require("../worktree")

local M = {}

local function item(n: number, repo: string, updated: string, extra: { [string]: any }?): { [string]: any }
	local t: { [string]: any } = {
		number = n,
		title = "T" .. n,
		html_url = "https://github.com/" .. repo .. "/pull/" .. n,
		user = { login = "u" },
		state = "open",
		updated_at = updated,
		pull_request = { url = "x" },
	}
	for k, v in extra or {} do
		t[k] = v
	end
	return t
end

local function page(items: { any }, total: number?): string
	return tern.json.encode({ total_count = total or #items, incomplete_results = false, items = tern.json.array(items) })
end

function M.run()
	-- search pages: rejection, empty, dedupe, order
	assert(github.parsePage("not json") == nil, "malformed JSON is rejected")
	assert(github.parsePage("{}") == nil, "missing items are rejected")
	local issue = item(1, "a/b", "2026-01-01T00:00:00Z")
	issue.pull_request = nil
	assert(github.parsePage(page({ issue })) == nil, "issues are rejected")
	assert(github.parsePage(page({ item(1, "a/b", "2026-01-01T00:00:00Z", { html_url = "https://evil.example/a/b/pull/1" }) })) == nil, "foreign URLs are rejected")
	assert(github.parsePage(page({ item(1, "a/b", "2026-01-01T00:00:00Z", { number = 2 }) })) == nil, "mismatched numbers are rejected")
	local empty = github.parsePage(page({}))
	assert(empty and #empty.prs == 0 and empty.total == 0, "empty results parse")
	local pg = github.parsePage(page({
		item(1, "A/B", "2026-01-01T00:00:00Z"),
		item(2, "a/b", "2026-03-01T00:00:00Z", { draft = true }),
		item(1, "a/b", "2026-01-01T00:00:00Z"),
		item(3, "a/b", "2026-03-01T00:00:00Z", { state = "closed", pull_request = { merged_at = "2026-03-02T00:00:00Z" } }),
	}))
	assert(pg and #pg.prs == 4, "four items parsed")
	local rec = github.reconcile(pg.prs)
	assert(#rec == 3, "duplicates are folded by lowercase identity")
	assert(rec[1].key == "a/b#2" and rec[2].key == "a/b#3" and rec[3].key == "a/b#1", "updated desc, key tie-break")
	assert(rec[1].draft and rec[2].state == "merged", "draft and merged states")
	assert(rec[3].repo == "A/B", "display spelling preserved")
	assert(github.epoch("1970-01-02T00:00:00Z") == 86400, "epoch")
	assert(github.scopeProblem("is:open author:@me") == nil and github.scopeProblem("is:open review-requested:@me label:\"a b\"") == nil, "ordinary filters run")
	assert(github.scopeProblem("is:open label:\"bug or regression\"") == nil and github.scopeProblem("is:open a or b") == nil, "lowercase or is plain text")
	for _, bad in { "is:open repo:x/y", "is:open -org:x", "(user:x OR is:open)", "is:open Repo:x/y", "is:open a OR b" } do
		assert(github.scopeProblem(bad) ~= nil, "scope-widening filter is rejected: " .. bad)
	end

	-- rate-limit headers (shape of real `gh api --include` output) and pacing
	local now = 1000
	local real = "HTTP/2.0 200 OK\nX-Ratelimit-Limit: 30\r\nx-ratelimit-remaining: 25\r\nX-Ratelimit-Reset: 1060\r\nX-Ratelimit-Resource: search\r\nRetry-After: 120\r\n\r\n{\"a\":1}"
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
	assert(input.len16(m.text) == 4, "emoji is two UTF-16 units")
	assert(input.u16(m.text, #"a😀") == 3, "byte offset converts to units")
	assert(input.fromU16(m.text, 2) == 1, "offset inside a pair rounds down")
	m.anchor, m.cur = 1, #"a😀"
	local props = input.props(m)
	assert(props.cursor == 3 and props.anchor == 1, "selection offsets are UTF-16")
	local noop = function(_: string) end
	local function key(name: string, text: string?, shift: boolean?): Key
		return { name = name, text = text, ctrl = false, alt = false, shift = shift == true, meta = false }
	end
	input.key(m, key("backspace"), noop)
	assert(m.text == "ab" and m.cur == 1, "deleting a selection removes the whole emoji")
	input.key(m, { name = "paste", text = "x\r\ny😀", ctrl = false, alt = false, shift = false, meta = false }, noop)
	assert(m.text == "ax y😀b", "paste turns line breaks into spaces")
	input.key(m, key("left"), noop)
	input.key(m, key("left", nil, true), noop)
	assert(input.selected(m) == "y", "shift-left selects one codepoint")
	assert(input.undo(m) and m.text == "ab", "undo restores the earlier text")
	local m2 = input.new("héllo")
	assert(input.edit(m2, { from = 1, to = 2, text = "e", cursor = 2, len = 5 }) and m2.text == "hello", "native edit replaces a UTF-16 range")
	assert(not input.edit(m2, { from = 0, to = 0, text = "z", cursor = 1, len = 99 }) and m2.text == "hello", "stale edit is ignored")

	-- remotes and worktree records
	assert(worktree.normalizeRemote("https://github.com/cli/cli.git") == "cli/cli", "https remote")
	assert(worktree.normalizeRemote("https://user:tok@github.com/cli/cli") == "cli/cli", "https remote with credentials")
	assert(worktree.normalizeRemote("git@github.com:cli/cli.git") == "cli/cli", "scp remote")
	assert(worktree.normalizeRemote("ssh://git@github.com/cli/cli.git") == "cli/cli", "ssh remote")
	assert(worktree.normalizeRemote("https://github.com/cli/../x") == nil, "dot segments are rejected")
	assert(worktree.normalizeRemote("https://gitlab.com/cli/cli") == nil, "other hosts are rejected")
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

	-- PATH probe output
	assert(process.extractPath("banner\0PLOTROOM_PATH\0/a b:/c\n\0PLOTROOM_END\0tail") == "/a b:/c", "markers carry the PATH, spaces intact")
	assert(process.extractPath("\0PLOTROOM_PATH\0\n\0PLOTROOM_END\0") == nil, "empty PATH is rejected")
	assert(process.extractPath("\0PLOTROOM_PATH\0/a") == nil, "missing end marker is rejected")
end

return M
