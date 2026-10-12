--!strict
-- GitHub through the user's existing `gh` authentication: complete paged PR
-- search snapshots and single-PR metadata. Shared by host and window.

local process = require("./process")

local M = {}

export type Problem = { kind: string, message: string }
export type Pr = {
	key: string,
	repo: string,
	number: number,
	title: string,
	url: string,
	author: string,
	state: string,
	draft: boolean,
	updated: number,
}
export type SearchResult = { prs: { Pr }, total: number, complete: boolean }

local GH_TIMEOUT_MS = 30 * 1000
local PAGE = 100
local CAP = 1000
local RATE_S = 300
local ENV = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1", NO_COLOR = "1" }

local SEARCH_JQ =
	"{total_count,incomplete_results,items:[.items[]|{id,number,title,html_url,repository_url,user:{login:.user.login},state,draft,updated_at,pull_request}]}"
local PR_JQ = "{base:.base.repo.full_name,sha:.head.sha,ref:.head.ref,state:.state}"

-- Seconds since the epoch of `2026-09-30T14:03:11Z` (days-from-civil; `os.time`
-- with a table would read local time).
function M.epoch(iso: string): number?
	local y, m, d, hh, mm, ss = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not (y and m and d and hh and mm and ss) then
		return nil
	end
	local year, month, day = tonumber(y) :: number, tonumber(m) :: number, tonumber(d) :: number
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (if month > 2 then month - 3 else month + 9) + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + (tonumber(hh) :: number) * 3600 + (tonumber(mm) :: number) * 60 + (tonumber(ss) :: number)
end

function M.age(t: number): string
	local s = math.max(0, os.time() - t)
	if s < 3600 then
		return math.max(1, s // 60) .. "m"
	elseif s < 86400 then
		return s // 3600 .. "h"
	end
	return s // 86400 .. "d"
end

-- owner, repo, number of a canonical PR URL; nil for anything else.
function M.parsePrUrl(url: any): (string?, string?, number?)
	if type(url) ~= "string" then
		return nil, nil, nil
	end
	local o, r, n = string.match(url, "^https://github%.com/([%w%-_%.]+)/([%w%-_%.]+)/pull/(%d+)$")
	if not o or not r or not n or o == "." or o == ".." or r == "." or r == ".." then
		return nil, nil, nil
	end
	local num = tonumber(n)
	if not num or num < 1 or num > 2147483647 then
		return nil, nil, nil
	end
	return o, r, num
end

function M.identity(owner: string, repo: string, number: number): string
	return string.lower(owner) .. "/" .. string.lower(repo) .. "#" .. number
end

-- One search item as a Pr, or nil and why. Issues and malformed URLs are rejected.
function M.normalize(item: any): (Pr?, string?)
	if type(item) ~= "table" or type(item.pull_request) ~= "table" then
		return nil, "the search returned an item that is not a pull request"
	end
	local o, r, n = M.parsePrUrl(item.html_url)
	if not o or not r or not n or tonumber(item.number) ~= n then
		return nil, "the search returned a pull request with an unexpected URL"
	end
	if type(item.title) ~= "string" then
		return nil, "the search returned a pull request without a title"
	end
	local user = item.user
	local state = "open"
	if type(item.pull_request.merged_at) == "string" then
		state = "merged"
	elseif item.state == "closed" then
		state = "closed"
	end
	return {
		key = M.identity(o, r, n),
		repo = o .. "/" .. r,
		number = n,
		title = item.title,
		url = item.html_url,
		author = if type(user) == "table" and type(user.login) == "string" then user.login else "ghost",
		state = state,
		draft = item.draft == true,
		updated = M.epoch(if type(item.updated_at) == "string" then item.updated_at else "") or 0,
	}, nil
end

-- One page of the search JSON: total, incomplete flag, raw item count, PRs.
function M.parsePage(stdout: string): ({ total: number, incomplete: boolean, raw: number, prs: { Pr } }?, string?)
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" or type(data.items) ~= "table" or type(data.total_count) ~= "number" then
		return nil, "gh printed something other than a search result"
	end
	local prs: { Pr } = {}
	for _, item in data.items do
		local pr, why = M.normalize(item)
		if not pr then
			return nil, why
		end
		table.insert(prs, pr)
	end
	return { total = data.total_count, incomplete = data.incomplete_results == true, raw = #data.items, prs = prs }, nil
end

-- Deduplicated by identity, newest update first, identity as the tie-break.
function M.reconcile(prs: { Pr }): { Pr }
	local seen: { [string]: boolean } = {}
	local out: { Pr } = {}
	for _, pr in prs do
		if not seen[pr.key] then
			seen[pr.key] = true
			table.insert(out, pr)
		end
	end
	table.sort(out, function(a, b)
		if a.updated ~= b.updated then
			return a.updated > b.updated
		end
		return a.key < b.key
	end)
	return out
end

local function firstLines(text: string, n: number): string
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, line)
		if #out == n then
			break
		end
	end
	return table.concat(out, "\n")
end

local function classify(result: ProcessResult): Problem
	if result.timed_out then
		return { kind = "failed", message = "gh did not answer within 30 seconds." }
	end
	local err = result.stderr
	local low = string.lower(err)
	if
		string.find(err, "HTTP 429", 1, true)
		or (string.find(err, "HTTP 403", 1, true) and string.find(low, "rate limit", 1, true))
	then
		return { kind = "rate-limit", message = "GitHub rate limit reached: " .. firstLines(err, 2) }
	end
	if
		result.status == 4
		or string.find(err, "gh auth login", 1, true)
		or string.find(err, "GH_TOKEN", 1, true)
		or string.find(err, "HTTP 401", 1, true)
	then
		return { kind = "auth", message = "The GitHub CLI is not signed in: " .. firstLines(err, 3) }
	end
	return {
		kind = "failed",
		message = "gh exited with status " .. result.status .. ": " .. firstLines(err, 6),
	}
end

-- Runs `gh <args>`; done(stdout, problem, cx, failedStdout). A failed run still
-- passes its stdout (with `--include`, the response headers) as the 4th value.
function M.gh(args: { string }, done: (string?, Problem?, WindowCx?, string?) -> ())
	local argv: { string } = { "gh" }
	for _, a in args do
		table.insert(argv, a)
	end
	process.run(argv, { timeout_ms = GH_TIMEOUT_MS, env = ENV }, function(result, perr, cx)
		if not result then
			return done(nil, { kind = "missing", message = perr or "gh could not be started" }, cx, nil)
		end
		if result.status ~= 0 or result.timed_out then
			return done(nil, classify(result), cx, result.stdout)
		end
		done(result.stdout, nil, cx, nil)
	end)
end

-- ---------------------------------------------------------------- search quota

export type Quota = { limit: number?, remaining: number?, reset: number?, retryUntil: number? }

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

-- Epoch second a Retry-After value points at: delay seconds, or an HTTP-date.
local function retryAt(v: string, now: number): number?
	local n = tonumber(v)
	if n then
		return now + n
	end
	local d, mon, y, hh, mm, ss = string.match(v, "^%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT$")
	local m = if mon then MONTHS[mon] else nil
	if d and m and y and hh and mm and ss then
		return M.epoch(string.format("%04d-%02d-%02dT%02d:%02d:%02d", y, m, d, hh, mm, ss))
	end
	return nil
end

-- Quota and body of `gh api --include` output: one or more blocks of status
-- line, headers and a blank line (a `100 Continue` precedes the real one), then
-- the body. Lines end in LF or CRLF; header names are case-insensitive; text
-- without a header block is all body. Other rate-limit resources than search
-- are ignored.
function M.parseResponse(text: string, now: number): (Quota?, string)
	local q: Quota = {}
	local found = false
	local rest = string.gsub(text, "\r\n", "\n")
	while string.sub(rest, 1, 5) == "HTTP/" do
		local cut = string.find(rest, "\n\n", 1, true)
		local head = if cut then string.sub(rest, 1, cut - 1) else rest
		rest = if cut then string.sub(rest, cut + 2) else ""
		for line in string.gmatch(head, "[^\n]+") do
			local k, v = string.match(line, "^([%w%-]+):%s*(.-)%s*$")
			if k and v then
				k = string.lower(k)
				local n = tonumber(v)
				if k == "x-ratelimit-resource" and string.lower(v) ~= "search" then
					return nil, rest
				elseif k == "x-ratelimit-limit" and n then
					q.limit, found = n, true
				elseif k == "x-ratelimit-remaining" and n then
					q.remaining, found = n, true
				elseif k == "x-ratelimit-reset" and n then
					q.reset, found = n, true
				elseif k == "retry-after" then
					local at = retryAt(v, now)
					if at then
						q.retryUntil, found = at, true
					end
				end
			end
		end
	end
	return if found then q else nil, rest
end

-- Seconds until the quota allows a request: Retry-After, or the reset time once remaining hits 0.
function M.cooldown(q: Quota?, now: number): number
	local s = 0
	if q then
		if q.retryUntil then
			s = math.max(s, q.retryUntil - now)
		end
		if q.remaining and q.remaining <= 0 and q.reset then
			s = math.max(s, q.reset - now + 1)
		end
	end
	return math.max(0, s)
end

-- Milliseconds until the next automatic refresh: `base` when quota is unknown or
-- ample; otherwise the time to reset spread over the refreshes that fit in 80% of
-- what remains, shared by `users` panes, each costing `cost` requests.
function M.interval(q: Quota?, now: number, cost: number, users: number, base: number): number
	local cd = M.cooldown(q, now)
	if cd > 0 then
		return math.max(base, cd * 1000)
	end
	if not q or not q.remaining or not q.reset then
		return base
	end
	local toReset = math.max(1, q.reset - now)
	local affordable = math.floor(q.remaining * 0.8) / math.max(1, cost) / math.max(1, users)
	if affordable < 1 then
		return math.max(base, (toReset + 1) * 1000)
	end
	return math.max(base, math.ceil(toReset / affordable) * 1000)
end

-- `cur` updated with the response quota `q` (a new table): a response from an
-- older window, or one that saw more quota left in the same window, is stale;
-- a retry deadline only moves later.
function M.merge(cur: Quota?, q: Quota, now: number): Quota
	local out: Quota = { limit = cur and cur.limit, remaining = cur and cur.remaining, reset = cur and cur.reset, retryUntil = cur and cur.retryUntil }
	if q.remaining and q.reset then
		local fresher = not out.remaining
			or not out.reset
			or out.reset <= now
			or q.reset > out.reset
			or (q.reset == out.reset and q.remaining <= out.remaining)
		if fresher then
			out.limit, out.remaining, out.reset = q.limit or out.limit, q.remaining, q.reset
		end
	end
	if q.retryUntil and q.retryUntil > now then
		out.retryUntil = math.max(out.retryUntil or 0, q.retryUntil)
	end
	return out
end

-- One quota per runtime: every pane's search spends the same budget.
local shared: Quota? = nil

function M.record(q: Quota?, now: number)
	if q then
		shared = M.merge(shared, q, now)
	end
end

function M.quota(): Quota?
	return shared
end

-- Seconds every pane must still wait before any search request.
function M.wait(now: number): number
	return M.cooldown(shared, now)
end

-- Why `query` may not run inside one repository, or nil. Another repo:/org:/user:
-- or an OR would widen the request beyond the selected repository.
function M.scopeProblem(query: string): string?
	for word in string.gmatch(query, "%S+") do
		word = string.gsub(word, "^[%-%(\"]+", "")
		word = string.gsub(word, "[%)\"]+$", "")
		local low = string.lower(word)
		if string.match(low, "^repo:") or string.match(low, "^org:") or string.match(low, "^user:") or word == "OR" then
			return "Filters run inside the launch repository: remove `" .. word .. "` (repo:, org:, user: and OR are not allowed)."
		end
	end
	return nil
end

-- All pages of the search, sequentially; one swap-ready SearchResult at the end.
-- `shouldContinue` is checked before every page and after every response; a
-- false answer ends with kind="superseded" and no further page runs.
function M.search(
	repo: string,
	query: string,
	shouldContinue: () -> boolean,
	done: (SearchResult?, Problem?, number) -> ()
)
	query = string.match(query, "^%s*(.-)%s*$") or ""
	if query == "" then
		tern.timer(0, function()
			done(nil, { kind = "failed", message = "The filter query is empty." }, 0)
		end)
		return
	end
	local widened = M.scopeProblem(query)
	if widened then
		tern.timer(0, function()
			done(nil, { kind = "failed", message = widened }, 0)
		end)
		return
	end
	query = "repo:" .. repo .. " " .. query
	local superseded: Problem = { kind = "superseded", message = "" }
	local all: { Pr } = {}
	local total = 0
	local incomplete = false
	local loaded = 0
	local requests = 0
	local function finish(cut: boolean)
		done({ prs = M.reconcile(all), total = total, complete = not cut and not incomplete and total <= CAP }, nil, requests)
	end
	local function fetch(page: number)
		if not shouldContinue() then
			return done(nil, superseded, requests)
		end
		requests += 1
		M.gh({
			"api", "--hostname", "github.com", "--include", "--method", "GET", "search/issues",
			"-f", "q=" .. query .. " is:pr",
			"-f", "per_page=" .. PAGE,
			"-f", "page=" .. page,
			"-f", "sort=updated",
			"-f", "order=desc",
			"--jq", SEARCH_JQ,
		}, function(out, problem, _, raw)
			local now = os.time()
			local q, body = M.parseResponse(out or raw or "", now)
			M.record(q, now)
			if not out and problem and problem.kind == "rate-limit" and M.wait(now) == 0 then
				-- A rate limit without usable headers (secondary limit): back off.
				M.record({ retryUntil = now + RATE_S }, now)
			end
			if not shouldContinue() then
				return done(nil, superseded, requests)
			end
			if not out then
				return done(nil, problem, requests)
			end
			local pg, why = M.parsePage(body)
			if not pg then
				return done(nil, { kind = "failed", message = why or "malformed response" }, requests)
			end
			if page == 1 then
				total = pg.total
			end
			incomplete = incomplete or pg.incomplete
			loaded += pg.raw
			for _, pr in pg.prs do
				table.insert(all, pr)
			end
			if pg.raw < PAGE or loaded >= math.min(total, CAP) or page * PAGE >= CAP then
				return finish(false)
			end
			if M.wait(now) > 0 then
				return finish(true) -- quota exhausted mid-snapshot: keep what arrived, flagged partial
			end
			fetch(page + 1)
		end)
	end
	fetch(1)
end

export type PrMeta = { base: string, sha: string, ref: string, state: string }

-- Base repository and head of one PR; done(meta, problem, cx).
function M.pr(repo: string, number: number, done: (PrMeta?, Problem?, WindowCx?) -> ())
	M.gh({ "api", "--hostname", "github.com", "repos/" .. repo .. "/pulls/" .. number, "--jq", PR_JQ }, function(out, problem, cx)
		if not out then
			return done(nil, problem, cx)
		end
		local ok, data = pcall(tern.json.decode, out)
		if
			not ok
			or type(data) ~= "table"
			or type(data.base) ~= "string"
			or type(data.sha) ~= "string"
			or string.match(data.sha, "^%x+$") == nil
			or #data.sha ~= 40
			or type(data.ref) ~= "string"
		then
			return done(nil, { kind = "failed", message = "gh printed unexpected pull request metadata." }, cx)
		end
		done({ base = data.base, sha = string.lower(data.sha), ref = data.ref, state = tostring(data.state) }, nil, cx)
	end)
end

return M
