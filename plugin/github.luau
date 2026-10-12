--!strict
-- GitHub through the user's existing `gh` authentication: complete paged PR
-- search snapshots and single-PR metadata. Shared by host and window.

local process = require("./process")
local input = require("./input")

local M = {}

export type Problem = { kind: string, message: string }
export type Run = { name: string, status: string, detail: string, required: boolean, url: string? } -- status: failure | pending | success | neutral
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
	created: number,
	head: string,
	base: string,
	additions: number,
	deletions: number,
	files: number,
	comments: number,
	review: string?,
	checks: string?,
	runs: { Run },
	runTotal: number,
	labels: { string },
}
export type SearchResult = { prs: { Pr }, total: number, complete: boolean }

local GH_TIMEOUT_MS = 30 * 1000
local CAP = 1000
local RATE_S = 300
local ENV = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1", NO_COLOR = "1" }

local SEARCH_GQL = "query($q: String!, $after: String) { rateLimit { cost } search(query: $q, type: ISSUE, first: 100, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { number title url isDraft state updatedAt createdAt author { login } headRefName baseRefName additions deletions changedFiles comments { totalCount } reviewDecision labels(first: 10) { nodes { name } } commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 25) { totalCount nodes { __typename ... on CheckRun { name status conclusion startedAt completedAt detailsUrl } ... on StatusContext { context state targetUrl } } } } } } } } } } }"
local SEARCH_JQ = "{total:.data.search.issueCount,next:(if .data.search.pageInfo.hasNextPage then .data.search.pageInfo.endCursor else null end),cost:.data.rateLimit.cost,items:[.data.search.nodes[]|{number,title,url,isDraft,state,updatedAt,createdAt,author:.author.login,head:.headRefName,base:.baseRefName,additions,deletions,changedFiles,comments:.comments.totalCount,review:.reviewDecision,checks:.commits.nodes[0].commit.statusCheckRollup.state,runs:(.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // []),runTotal:(.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount // 0),labels:[.labels.nodes[]?.name]}]}"
local REVIEW: { [string]: string } = { APPROVED = "approved", CHANGES_REQUESTED = "changes", REVIEW_REQUIRED = "required" }
local CHECKS: { [string]: string } =
	{ SUCCESS = "success", FAILURE = "failure", ERROR = "failure", PENDING = "pending", EXPECTED = "pending" }
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

local CONCLUSION: { [string]: { string } } = {
	SUCCESS = { "success", "Passed" },
	FAILURE = { "failure", "Failed" },
	TIMED_OUT = { "failure", "Timed out" },
	ACTION_REQUIRED = { "failure", "Action required" },
	STARTUP_FAILURE = { "failure", "Startup failure" },
	CANCELLED = { "neutral", "Cancelled" },
	SKIPPED = { "neutral", "Skipped" },
	NEUTRAL = { "neutral", "Neutral" },
	STALE = { "neutral", "Stale" },
}
local CONTEXT_STATE: { [string]: { string } } = {
	SUCCESS = { "success", "Passed" },
	FAILURE = { "failure", "Failed" },
	ERROR = { "failure", "Error" },
	PENDING = { "pending", "Pending" },
	EXPECTED = { "pending", "Expected" },
}
local RUN_RANK: { [string]: number } = { failure = 1, pending = 2, success = 3, neutral = 4 }

-- `2m 31s` for a duration in seconds.
local function took(s: number): string
	if s >= 3600 then
		return string.format("%dh %dm", s // 3600, s % 3600 // 60)
	elseif s >= 60 then
		return string.format("%dm %ds", s // 60, s % 60)
	end
	return s .. "s"
end

-- Check runs and commit statuses from the search JSON: worst first, original order within a status.
function M.runs(raw: any): { Run }
	local out: { Run } = {}
	local seen: { [string]: { at: number, run: Run } } = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, n in raw do
		if type(n) == "table" then
			local at = 0
			local name: string? = nil
			local status: string? = nil
			local detail: string? = nil
			if type(n.name) == "string" then
				local c = if n.status == "COMPLETED" and type(n.conclusion) == "string" then CONCLUSION[n.conclusion] else nil
				if c then
					status, detail = c[1], c[2]
					local a, b = M.epoch(tostring(n.startedAt)), M.epoch(tostring(n.completedAt))
					if a and b and b > a and status ~= "neutral" then
						detail = detail .. " · " .. took(b - a)
					end
				else
					status, detail = "pending", if n.status == "IN_PROGRESS" then "In progress" else "Queued"
				end
				name = n.name
				at = M.epoch(tostring(n.startedAt)) or 0
			elseif type(n.context) == "string" then
				local c = if type(n.state) == "string" then CONTEXT_STATE[n.state] else nil
				if c then
					name, status, detail = n.context, c[1], c[2]
				end
			end
			if name and status and detail then
				local link = if type(n.detailsUrl) == "string" then n.detailsUrl elseif type(n.targetUrl) == "string" then n.targetUrl else nil
				local run: Run = {
					name = name,
					status = status,
					detail = detail,
					required = n.isRequired == true,
					url = if link and string.sub(link, 1, 8) == "https://" and not string.find(link, "[%c%s]") then link else nil,
				}
				-- A re-run repeats the check's name: the newest start wins (later entry on a tie), in the first copy's place.
				local prev = seen[name]
				if not prev then
					table.insert(out, run)
					seen[name] = { at = at, run = run }
				elseif at >= prev.at then
					run.required = run.required or prev.run.required
					out[table.find(out, prev.run) :: number] = run
					seen[name] = { at = at, run = run }
				end
			end
		end
	end
	local idx: { [Run]: number } = {}
	for i, r in out do
		idx[r] = i
	end
	table.sort(out, function(a, b)
		if a.required ~= b.required then
			return a.required
		end
		if a.status ~= b.status then
			return RUN_RANK[a.status] < RUN_RANK[b.status]
		end
		return idx[a] < idx[b]
	end)
	return out
end

-- One search item as a Pr, or nil and why. Issues and malformed URLs are rejected.
function M.normalize(item: any): (Pr?, string?)
	if type(item) ~= "table" or type(item.number) ~= "number" then
		return nil, "the search returned an item that is not a pull request"
	end
	local o, r, n = M.parsePrUrl(item.url)
	if not o or not r or not n or item.number ~= n then
		return nil, "the search returned a pull request with an unexpected URL"
	end
	if type(item.title) ~= "string" then
		return nil, "the search returned a pull request without a title"
	end
	local state = "open"
	if item.state == "MERGED" then
		state = "merged"
	elseif item.state == "closed" or item.state == "CLOSED" then
		state = "closed"
	end
	local function count(v: any): number
		return if type(v) == "number" and v >= 0 then v else 0
	end
	local function str(v: any): string
		return if type(v) == "string" then v else ""
	end
	local labels: { string } = {}
	if type(item.labels) == "table" then
		for _, l in item.labels do
			if type(l) == "string" then
				table.insert(labels, l)
			end
		end
	end
	local runs = M.runs(item.runs)
	return {
		key = M.identity(o, r, n),
		repo = o .. "/" .. r,
		number = n,
		title = item.title,
		url = item.url,
		author = if type(item.author) == "string" then item.author else "ghost",
		state = state,
		draft = item.isDraft == true,
		updated = M.epoch(str(item.updatedAt)) or 0,
		created = M.epoch(str(item.createdAt)) or 0,
		head = str(item.head),
		base = str(item.base),
		additions = count(item.additions),
		deletions = count(item.deletions),
		files = count(item.changedFiles),
		comments = count(item.comments),
		review = if type(item.review) == "string" then REVIEW[item.review] else nil,
		checks = if type(item.checks) == "string" then CHECKS[item.checks] else nil,
		runs = runs,
		runTotal = #runs + math.max(0, count(item.runTotal) - (if type(item.runs) == "table" then #item.runs else 0)),
		labels = labels,
	}, nil
end

-- One page of the search JSON: total, next cursor, points cost, raw item count, PRs.
function M.parsePage(stdout: string): ({ total: number, next: string?, cost: number, raw: number, prs: { Pr } }?, string?)
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" or type(data.items) ~= "table" or type(data.total) ~= "number" then
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
	return {
		total = data.total,
		next = if type(data.next) == "string" and data.next ~= "" then data.next else nil,
		cost = if type(data.cost) == "number" and data.cost > 0 then data.cost else 1,
		raw = #data.items,
		prs = prs,
	}, nil
end

-- Local search over loaded PRs: whether `pr` matches, and the matched UTF-16
-- range in its title (nil when the match is elsewhere or the needle is blank).
function M.match(pr: Pr, needle: string): (boolean, { number }?)
	local q = string.lower(string.match(needle, "^%s*(.-)%s*$") or "")
	if q == "" then
		return true, nil
	end
	local at = string.find(string.lower(pr.title), q, 1, true)
	if at then
		return true, { input.u16(pr.title, at - 1), input.u16(pr.title, at - 1 + #q) }
	end
	return string.find(string.lower("#" .. pr.number .. " " .. pr.author .. " " .. pr.head), q, 1, true) ~= nil, nil
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

function M.classify(result: ProcessResult): Problem
	if result.timed_out then
		return { kind = "failed", message = "gh did not answer within 30 seconds." }
	end
	local err = result.stderr
	local low = string.lower(err)
	if string.find(err, "HTTP 429", 1, true) or string.find(low, "rate limit", 1, true) then
		return { kind = "rate-limit", message = "GitHub rate limit reached: " .. firstLines(err, 2) }
	end
	if result.status == 4 or string.find(err, "gh auth login", 1, true) or string.find(err, "HTTP 401", 1, true) then
		return { kind = "auth", message = "GitHub rejected the sign-in: " .. firstLines(err, 3) }
	end
	if string.find(err, "HTTP 403", 1, true) then
		-- Not a rate limit (checked above): permissions, or SAML SSO authorization.
		return { kind = "auth", message = "This GitHub account may not access the repository (permissions or SSO authorization): " .. firstLines(err, 3) }
	end
	if string.find(err, "HTTP 422", 1, true) or string.find(low, "cannot be searched", 1, true) then
		-- Validation Failed: bad query, or the account cannot search the repository. Retrying unchanged cannot help.
		return { kind = "invalid", message = "GitHub rejected the search: " .. firstLines(err, 3) }
	end
	if string.find(err, "HTTP 404", 1, true) then
		return { kind = "not-found", message = "The repository or pull request is not visible to this GitHub account: " .. firstLines(err, 3) }
	end
	return {
		kind = "failed",
		message = "gh exited with status " .. result.status .. ": " .. firstLines(err, 6),
	}
end

-- Runs `gh <args>` as `account` (nil = active account); done(stdout, problem, cx,
-- failedStdout). A failed run still passes its stdout (with `--include`, the
-- response headers) as the 4th value.
function M.gh(args: { string }, done: (string?, Problem?, WindowCx?, string?) -> (), account: string?)
	local argv: { string } = { "gh" }
	for _, a in args do
		table.insert(argv, a)
	end
	local function run(env: { [string]: string })
		process.run(argv, { timeout_ms = GH_TIMEOUT_MS, env = env }, function(result, perr, cx)
			if not result then
				return done(nil, { kind = "missing", message = perr or "gh could not be started" }, cx, nil)
			end
			if result.status ~= 0 or result.timed_out then
				return done(nil, M.classify(result), cx, result.stdout)
			end
			done(result.stdout, nil, cx, nil)
		end)
	end
	if not account then
		return run(ENV)
	end
	process.run({ "gh", "auth", "token", "--hostname", "github.com", "--user", account }, { timeout_ms = GH_TIMEOUT_MS, env = ENV }, function(r, perr, cx)
		if not r then
			return done(nil, { kind = "missing", message = perr or "gh could not be started" }, cx, nil)
		end
		local token = string.match(r.stdout, "^%s*(%S+)%s*$")
		if r.status ~= 0 or not token then
			return done(nil, { kind = "auth", message = "The gh account " .. account .. " is not signed in: run `gh auth login`, or choose another account for this repository." }, cx, nil)
		end
		local env: { [string]: string } = {}
		for k, v in ENV do
			env[k] = v
		end
		env.GH_TOKEN = token
		run(env)
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
-- without a header block is all body. Other rate-limit resources than graphql
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
				if k == "x-ratelimit-resource" and string.lower(v) ~= "graphql" then
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

-- One quota per runtime and gh account (key "" = the active account): accounts
-- do not share a budget.
local shared: { [string]: Quota } = {}

function M.record(q: Quota?, now: number, account: string?)
	if q then
		shared[account or ""] = M.merge(shared[account or ""], q, now)
	end
end

function M.quota(account: string?): Quota?
	return shared[account or ""]
end

-- Seconds every pane must still wait before any search request.
function M.wait(now: number, account: string?): number
	return M.cooldown(shared[account or ""], now)
end

-- ------------------------------------------------------------- repo accounts

-- Which gh account a repository uses is saved explicitly (kv "accounts",
-- key "github.com/<lowercase owner/repo>"): an SSH alias does not identify a gh
-- login. nil = the active gh account. Never `gh auth switch`: the account is
-- applied per command through GH_TOKEN.
local function accountKey(repo: string): string
	return "github.com/" .. string.lower(repo)
end

function M.account(repo: string): string?
	local ok, v = pcall(tern.kv.get, "accounts")
	local a = if ok and type(v) == "table" then v[accountKey(repo)] else nil
	if type(a) == "string" and string.match(a, "^[%w%-]+$") then
		return a
	end
	return nil
end

-- Saves (or with nil/"" clears) the account; returns an error message or nil.
function M.setAccount(repo: string, login: string?): string?
	if login == "" then
		login = nil
	end
	if login and not string.match(login, "^[%w%-]+$") then
		return "A GitHub login has letters, digits and hyphens only."
	end
	local ok, v = pcall(tern.kv.get, "accounts")
	local map: { [string]: string } = if ok and type(v) == "table" then v else {}
	map[accountKey(repo)] = login
	local ok2, err = pcall(tern.kv.set, "accounts", map)
	if not ok2 then
		return "Could not save: " .. tostring(err)
	end
	return nil
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
	query = "repo:" .. repo .. " " .. query .. " is:pr sort:updated-desc"
	local account = M.account(repo)
	local superseded: Problem = { kind = "superseded", message = "" }
	local all: { Pr } = {}
	local total = 0
	local loaded = 0
	local spent = 0
	local function finish(cut: boolean)
		done({ prs = M.reconcile(all), total = total, complete = not cut and total <= CAP }, nil, spent)
	end
	local function fetch(after: string?)
		if not shouldContinue() then
			return done(nil, superseded, spent)
		end
		spent += 1
		local args = { "api", "graphql", "--hostname", "github.com", "--include", "-f", "query=" .. SEARCH_GQL, "-f", "q=" .. query }
		if after then
			table.insert(args, "-f")
			table.insert(args, "after=" .. after)
		end
		table.insert(args, "--jq")
		table.insert(args, SEARCH_JQ)
		M.gh(args, function(out, problem, _, raw)
			local now = os.time()
			local q, body = M.parseResponse(out or raw or "", now)
			M.record(q, now, account)
			if not out and problem and problem.kind == "rate-limit" and M.wait(now, account) == 0 then
				-- A rate limit without usable headers (secondary limit): back off.
				M.record({ retryUntil = now + RATE_S }, now, account)
			end
			if not shouldContinue() then
				return done(nil, superseded, spent)
			end
			if not out then
				return done(nil, problem, spent)
			end
			local pg, why = M.parsePage(body)
			if not pg then
				return done(nil, { kind = "failed", message = why or "malformed response" }, spent)
			end
			spent += pg.cost - 1
			if after == nil then
				total = pg.total
			end
			loaded += pg.raw
			for _, pr in pg.prs do
				table.insert(all, pr)
			end
			if pg.next == nil or loaded >= math.min(total, CAP) then
				return finish(false)
			end
			if M.wait(now, account) > 0 then
				return finish(true) -- quota exhausted mid-snapshot: keep what arrived, flagged partial
			end
			fetch(pg.next)
		end, account)
	end
	fetch(nil)
end

local CHECKS_GQL = "query($o: String!, $r: String!, $n: Int!, $after: String) { rateLimit { cost } repository(owner: $o, name: $r) { pullRequest(number: $n) { commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100, after: $after) { totalCount pageInfo { hasNextPage endCursor } nodes { __typename ... on CheckRun { name status conclusion startedAt completedAt detailsUrl isRequired(pullRequestNumber: $n) } ... on StatusContext { context state targetUrl isRequired(pullRequestNumber: $n) } } } } } } } } } }"
local CHECKS_JQ = "(.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts // {}) | {total:(.totalCount // 0),next:(if .pageInfo.hasNextPage then .pageInfo.endCursor else null end),nodes:(.nodes // [])}"
local CHECK_PAGES = 3

-- Every check of one PR's latest commit (up to CHECK_PAGES * 100), required ones flagged; done(runs, total, problem).
function M.checks(repo: string, number: number, done: ({ Run }?, number, Problem?) -> ())
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	if not owner or not name then
		return done(nil, 0, { kind = "failed", message = "Unexpected repository name." })
	end
	local account = M.account(repo)
	local nodes: { any } = {}
	local function fetch(after: string?, page: number)
		local args = { "api", "graphql", "--hostname", "github.com", "--include", "-f", "query=" .. CHECKS_GQL, "-f", "o=" .. owner, "-f", "r=" .. name, "-F", "n=" .. number }
		if after then
			table.insert(args, "-f")
			table.insert(args, "after=" .. after)
		end
		table.insert(args, "--jq")
		table.insert(args, CHECKS_JQ)
		M.gh(args, function(out, problem, _, raw)
			local now = os.time()
			local q, body = M.parseResponse(out or raw or "", now)
			M.record(q, now, account)
			if not out then
				return done(nil, 0, problem)
			end
			local ok, data = pcall(tern.json.decode, body)
			if not ok or type(data) ~= "table" or type(data.nodes) ~= "table" or type(data.total) ~= "number" then
				return done(nil, 0, { kind = "failed", message = "gh printed unexpected check data." })
			end
			for _, n in data.nodes do
				table.insert(nodes, n)
			end
			if type(data.next) == "string" and data.next ~= "" and page < CHECK_PAGES and M.wait(now, account) == 0 then
				return fetch(data.next, page + 1)
			end
			local runs = M.runs(nodes)
			done(runs, #runs + math.max(0, data.total - #nodes), nil)
		end, account)
	end
	fetch(nil, 1)
end

export type PrMeta = { base: string, sha: string, ref: string, state: string }

-- Base repository and head of one PR; done(meta, problem, cx).
function M.pr(repo: string, number: number, done: (PrMeta?, Problem?, WindowCx?) -> ())
	local account = M.account(repo)
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
	end, account)
end

return M
