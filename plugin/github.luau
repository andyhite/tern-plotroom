--!strict
-- GitHub through the user's existing `gh` authentication: complete paged PR
-- search snapshots and single-PR metadata. Shared by host and window.

local process = require("./process")
local input = require("./input")
local tracker = require("./tracker")

local M = {}

-- Problem kinds: auth | missing | rate-limit | invalid | not-found | failed (gh, the API or a timeout), account (the
-- saved gh login of the repository cannot be used; nothing was sent) and superseded (the caller cancelled the request).
export type Problem = { kind: string, message: string }
-- status: failure | pending | success | neutral; detail spells it out ("Passed · 3s"); took is the bare duration of a
-- finished check run, when GitHub gives one.
export type Run = { name: string, status: string, detail: string, required: boolean, url: string?, took: string?, runId: string? }
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
	headSha: string?, -- the commit the pull request's head branch is at (40 hex); nil when GitHub did not say
	fork: string?, -- the owner of the fork the head branch lives in; nil for a branch of the repository itself
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
-- complete: every PR the search counts is in prs (the scan was not cut short and fits GitHub's result cap).
export type SearchResult = { prs: { Pr }, total: number, complete: boolean }
-- What one PR's detail load reads besides its checks. merge: conflicts | behind | blocked | unstable | ready | draft |
-- unknown (GitHub computes it lazily). Review state: approved | changes | commented | dismissed | requested.
export type Review = { login: string, state: string }
export type About = { merge: string, reviews: { Review }, body: string }

local GH_TIMEOUT_MS = 30 * 1000
local CAP = 1000
local SEARCH_PAGES = 10 -- CAP results at 100 a page
local RATE_S = 300
local MAX_RETRY_S = 24 * 60 * 60 -- the longest pause one Retry-After can ask for
local ENV: { [string]: string } = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1", NO_COLOR = "1" }

-- A check is identified by its node `id` and its check suite (one workflow run, or one app's checks of the commit); the
-- suite's workflow or app name labels same-named checks of different suites. `extra` adds fields to both node kinds.
local RUN_FIELDS = "id name status conclusion startedAt completedAt detailsUrl checkSuite { id app { name } workflowRun { workflow { name } } }"
local STATUS_FIELDS = "id context state targetUrl"
local function checkNodes(extra: string): string
	return "nodes { __typename ... on CheckRun { " .. RUN_FIELDS .. extra .. " } ... on StatusContext { " .. STATUS_FIELDS .. extra .. " } }"
end

-- What the queue reads of a pull request, as GraphQL selects it and as `--jq` hands it to M.normalize.
local PR_FIELDS = "number title url isDraft state updatedAt createdAt author { login } headRefName headRefOid isCrossRepository headRepositoryOwner { login } baseRefName additions deletions changedFiles comments { totalCount } reviewDecision labels(first: 10) { nodes { name } } commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 25) { totalCount " .. checkNodes("") .. " } } } } }"
local PR_ITEM_JQ = "{number,title,url,isDraft,state,updatedAt,createdAt,author:.author.login,head:.headRefName,headSha:.headRefOid,fork:(if .isCrossRepository then (.headRepositoryOwner.login // .author.login) else null end),base:.baseRefName,additions,deletions,changedFiles,comments:.comments.totalCount,review:.reviewDecision,checks:.commits.nodes[0].commit.statusCheckRollup.state,runs:(.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // []),runTotal:(.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount // 0),labels:[.labels.nodes[]?.name]}"
local SEARCH_GQL = "query($q: String!, $after: String) { rateLimit { cost } search(query: $q, type: ISSUE, first: 100, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { " .. PR_FIELDS .. " } } } }"
local SEARCH_JQ = "{total:.data.search.issueCount,next:(if .data.search.pageInfo.hasNextPage then .data.search.pageInfo.endCursor else null end),cost:.data.rateLimit.cost,items:[.data.search.nodes[]|" .. PR_ITEM_JQ .. "]}"
-- One pull request by its URL: a lookup, not a search (a search for its number also finds PRs that mention it).
local PULL_GQL = "query($q: URI!) { rateLimit { cost } resource(url: $q) { ... on PullRequest { " .. PR_FIELDS .. " } } }"
local PULL_JQ = "[.data.resource | select(.number != null) | " .. PR_ITEM_JQ .. "] as $items | {total:($items | length),next:null,cost:.data.rateLimit.cost,items:$items}"
local ISSUE_GQL = "query($q: String!, $after: String) { rateLimit { cost } search(query: $q, type: ISSUE, first: 100, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on Issue { number title url state stateReason updatedAt createdAt author { login } comments { totalCount } labels(first: 10) { nodes { name } } assignees(first: 10) { nodes { login } } } } } }"
local ISSUE_JQ = "{total:.data.search.issueCount,next:(if .data.search.pageInfo.hasNextPage then .data.search.pageInfo.endCursor else null end),cost:.data.rateLimit.cost,items:[.data.search.nodes[]|{number,title,url,state,reason:.stateReason,updatedAt,createdAt,author:.author.login,comments:.comments.totalCount,labels:[.labels.nodes[]?.name],assignees:[.assignees.nodes[]?.login]}]}"
local REVIEW: { [string]: string } = { APPROVED = "approved", CHANGES_REQUESTED = "changes", REVIEW_REQUIRED = "required" }
local CHECKS: { [string]: string } =
	{ SUCCESS = "success", FAILURE = "failure", ERROR = "failure", PENDING = "pending", EXPECTED = "pending" }
local PR_JQ = "{base:.base.repo.full_name,sha:.head.sha,ref:.head.ref,headRepo:.head.repo.full_name,headOwner:.head.user.login,state:.state,baseRef:.base.ref,title:.title,author:.user.login}"
local MERGE: { [string]: string } =
	{ DIRTY = "conflicts", BEHIND = "behind", BLOCKED = "blocked", UNSTABLE = "unstable", CLEAN = "ready", HAS_HOOKS = "ready", DRAFT = "draft" }
local VERDICT: { [string]: string } = { APPROVED = "approved", CHANGES_REQUESTED = "changes", COMMENTED = "commented", DISMISSED = "dismissed" }
local REVIEWERS = 20 -- latestReviews and reviewRequests are read up to this many each
local BODY_CHARS = 20000

-- Seconds since the epoch of a UTC date and time (days-from-civil; `os.time` with a table would read local time).
local function utc(year: number, month: number, day: number, hh: number, mm: number, ss: number): number
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (if month > 2 then month - 3 else month + 9) + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + hh * 3600 + mm * 60 + ss
end

-- Seconds since the epoch of `2026-09-30T14:03:11Z` (or with an offset, `2026-05-27T09:38:49.512-0500`); nil unless `iso` starts with a timestamp of that shape.
function M.epoch(iso: string): number?
	local y, m, d, h, mi, s, rest = string.match(iso, "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
	local year, month, day, hh, mm, ss = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
	if year and month and day and hh and mm and ss and rest then
		local t = utc(year, month, day, hh, mm, ss)
		local sign, oh, om = string.match(rest, "^[%.%d]*([%+%-])(%d%d):?(%d%d)$")
		if sign then
			t -= (if sign == "-" then -1 else 1) * ((tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60)
		end
		return t
	end
	return nil
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

-- Value at a key path of decoded JSON; nil when a step is missing or not a table.
local function field(v: any, ...: string): any
	for _, key in { ... } do
		if type(v) ~= "table" then
			return nil
		end
		v = v[key]
	end
	return v
end
M.field = field

local function nonEmpty(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function stamp(v: any): number?
	return if type(v) == "string" then M.epoch(v) else nil
end

-- One listed check: its run, when its attempt started, the workflow or app name that labels it, its first position.
type Attempt = { run: Run, at: number, label: string?, order: number }

-- Check runs and commit statuses from the search JSON: required first, then worst first, original order within a
-- status. Entries of one check suite with the same name are attempts of ONE check (a re-run repeats its name): the
-- newest attempt is listed, in the first attempt's place, and is required when any attempt was; an attempt that has
-- not started (queued) is newer than every attempt that has. Everything else is independent and listed: same-named
-- checks of other suites or providers, status contexts, entries that carry no suite (one node `id` twice is one
-- entry). A name that two listed checks share gets its workflow or app name in front.
-- ponytail: two different jobs of one suite that share a name look like a re-run (GraphQL has no attempt number): the newest is listed.
function M.runs(raw: any): { Run }
	local attempts: { Attempt } = {}
	local slot: { [string]: number } = {} -- identity -> index in attempts
	if type(raw) == "table" then
		for _, n in raw do
			local name: string? = nil
			local status: string? = nil
			local detail: string? = nil
			local spent: string? = nil
			local at = 0
			local suite: string? = nil
			local label: string? = nil
			local checkName = field(n, "name")
			local context = field(n, "context")
			if type(checkName) == "string" then
				local conclusion = field(n, "conclusion")
				local c = if field(n, "status") == "COMPLETED" and type(conclusion) == "string" then CONCLUSION[conclusion] else nil
				local started, finished = stamp(field(n, "startedAt")), stamp(field(n, "completedAt"))
				if c then
					local word = c[2]
					if started and finished and finished > started and c[1] ~= "neutral" then
						local d = took(finished - started)
						spent = d
						word = word .. " · " .. d
					end
					status, detail = c[1], word
					at = started or finished or 0
				else
					status, detail = "pending", if field(n, "status") == "IN_PROGRESS" then "In progress" else "Queued"
					at = started or math.huge
				end
				name = checkName
				suite = nonEmpty(field(n, "checkSuite", "id"))
				label = nonEmpty(field(n, "checkSuite", "workflowRun", "workflow", "name")) or nonEmpty(field(n, "checkSuite", "app", "name"))
			elseif type(context) == "string" then
				local state = field(n, "state")
				local c = if type(state) == "string" then CONTEXT_STATE[state] else nil
				if c then
					name, status, detail = context, c[1], c[2]
				end
			end
			if name and status and detail then
				local d, t = field(n, "detailsUrl"), field(n, "targetUrl")
				local link = if type(d) == "string" then d elseif type(t) == "string" then t else nil
				local run: Run = {
					name = name,
					status = status,
					detail = detail,
					required = field(n, "isRequired") == true,
					url = if link and string.sub(link, 1, 8) == "https://" and not string.find(link, "[%c%s]") then link else nil,
					took = spent,
					runId = M.runIdOf(link),
				}
				local id = nonEmpty(field(n, "id"))
				local key = if suite then "suite\0" .. suite .. "\0" .. name elseif id then "id\0" .. id else nil
				local i = if key then slot[key] else nil
				if i then
					local prev = attempts[i]
					local required = run.required or prev.run.required
					if at >= prev.at then
						prev.run = run
						prev.at = at
						prev.label = label
					end
					prev.run.required = required
				else
					table.insert(attempts, { run = run, at = at, label = label, order = #attempts + 1 })
					if key then
						slot[key] = #attempts
					end
				end
			end
		end
	end
	local count: { [string]: number } = {}
	for _, a in attempts do
		count[a.run.name] = (count[a.run.name] or 0) + 1
	end
	for _, a in attempts do
		local prefix = a.label
		if prefix and count[a.run.name] > 1 then
			a.run.name = prefix .. " / " .. a.run.name
		end
	end
	table.sort(attempts, function(a, b)
		if a.run.required ~= b.run.required then
			return a.run.required
		end
		if a.run.status ~= b.run.status then
			return RUN_RANK[a.run.status] < RUN_RANK[b.run.status]
		end
		return a.order < b.order
	end)
	local out: { Run } = {}
	for _, a in attempts do
		table.insert(out, a.run)
	end
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
		headSha = if type(item.headSha) == "string" and #item.headSha == 40 and string.match(item.headSha, "^%x+$") then string.lower(item.headSha) else nil,
		fork = if type(item.fork) == "string" and string.match(item.fork, "^[%w%-_]+$") then item.fork else nil,
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

local ISSUE_STATE: { [string]: string } = { COMPLETED = "completed", NOT_PLANNED = "not-planned", DUPLICATE = "duplicate" }

-- One search item as an Issue, or nil and why. Pull requests and malformed URLs are rejected.
function M.normalizeIssue(item: any): (tracker.Issue?, string?)
	if type(item) ~= "table" or type(item.number) ~= "number" or type(item.url) ~= "string" then
		return nil, "the search returned an item that is not an issue"
	end
	if string.find(item.url, "^https://github%.com/[^/]+/[^/]+/pull/%d+$") then
		return nil, "the search returned an item that is not an issue"
	end
	local o, r, ns = string.match(item.url, "^https://github%.com/([%w%-_%.]+)/([%w%-_%.]+)/issues/(%d+)$")
	local n = if ns then tonumber(ns) else nil
	if not o or not r or not n or item.number ~= n then
		return nil, "the search returned an issue with an unexpected URL"
	end
	if type(item.title) ~= "string" then
		return nil, "the search returned an issue without a title"
	end
	local function count(v: any): number
		return if type(v) == "number" and v >= 0 then v else 0
	end
	local function str(v: any): string
		return if type(v) == "string" then v else ""
	end
	local function strings(v: any): { string }
		local out: { string } = {}
		if type(v) == "table" then
			for _, s in v do
				if type(s) == "string" then
					table.insert(out, s)
				end
			end
		end
		return out
	end
	local closed = item.state == "CLOSED"
	return {
		key = M.identity(o, r, n),
		tracker = "github",
		repo = o .. "/" .. r,
		ref = tostring(n),
		title = item.title,
		url = item.url,
		author = if type(item.author) == "string" then item.author else "ghost",
		state = if closed then "closed" else "open",
		reason = if closed and type(item.reason) == "string" then ISSUE_STATE[item.reason] else nil,
		labels = strings(item.labels),
		assignees = strings(item.assignees),
		comments = count(item.comments),
		created = M.epoch(str(item.createdAt)) or 0,
		updated = M.epoch(str(item.updatedAt)) or 0,
	}, nil
end

-- One page of the issue search JSON: total, next cursor, points cost, raw item count, issues.
function M.parseIssuePage(stdout: string): ({ total: number, next: string?, cost: number, raw: number, issues: { tracker.Issue } }?, string?)
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" or type(data.items) ~= "table" or type(data.total) ~= "number" then
		return nil, "gh printed something other than a search result"
	end
	local issues: { tracker.Issue } = {}
	for _, item in data.items do
		local issue, why = M.normalizeIssue(item)
		if not issue then
			return nil, why
		end
		table.insert(issues, issue)
	end
	return {
		total = data.total,
		next = if type(data.next) == "string" and data.next ~= "" then data.next else nil,
		cost = if type(data.cost) == "number" and data.cost > 0 then data.cost else 1,
		raw = #data.items,
		issues = issues,
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
	local out: { string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, line)
		if #out == n then
			break
		end
	end
	return table.concat(out, "\n")
end

function M.classify(result: ProcessResult, limit: string?): Problem
	if result.timed_out then
		return { kind = "failed", message = "gh did not answer within " .. (limit or "30 seconds") .. "." }
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
		return { kind = "invalid", message = "GitHub rejected the request: " .. firstLines(err, 3) }
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
-- response headers) as the 4th value. An account's token is read per call with
-- `gh auth token` and kept in memory only: no answer in time is `failed`
-- (retryable); only a definite refusal is `auth`.
function M.gh(args: { string }, done: (string?, Problem?, WindowCx?, string?) -> (), account: string?, timeoutMs: number?)
	local argv: { string } = { "gh" }
	for _, a in args do
		table.insert(argv, a)
	end
	local limit = if timeoutMs then (timeoutMs // 60000) .. " minutes" else nil
	local function run(env: { [string]: string })
		process.run(argv, { timeout_ms = timeoutMs or GH_TIMEOUT_MS, env = env }, function(result, perr, cx)
			if not result then
				return done(nil, { kind = "missing", message = perr or "gh could not be started" }, cx, nil)
			end
			if result.status ~= 0 or result.timed_out then
				return done(nil, M.classify(result, limit), cx, result.stdout)
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
		if r.timed_out then
			-- No answer about the account (a keychain prompt, a slow disk): not "not signed in".
			return done(nil, { kind = "failed", message = "gh auth token did not answer within 30 seconds." }, cx, nil)
		end
		local token = string.match(r.stdout, "^%s*(%S+)%s*$")
		if r.status ~= 0 or not token then
			return done(nil, { kind = "auth", message = "The gh account " .. account .. " is not signed in: run `gh auth login`, or set another login on this view in Settings › Views." }, cx, nil)
		end
		local env: { [string]: string } = {}
		for k, v in ENV do
			env[k] = v
		end
		env.GH_TOKEN = token
		run(env)
	end)
end

local CLONE_MS = 10 * 60 * 1000

-- Clones `repo` into the absolute `path` with `gh repo clone`, as the repository's saved gh account: gh's own protocol
-- and credentials, so private repositories work. git makes the folder and refuses a non-empty one.
function M.clone(repo: string, path: string, account: string?, done: (Problem?, WindowCx?) -> ())
	if account == "" then
		account = nil
	end
	M.gh({ "repo", "clone", repo, path }, function(_, problem, cx)
		done(problem, cx)
	end, account, CLONE_MS)
end

-- ---------------------------------------------------------------- search quota

export type Quota = { limit: number?, remaining: number?, reset: number?, retryUntil: number? }

local MONTHS: { [string]: number } = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

-- A header value that is a plain non-negative integer of at most 10 digits (so always finite); nil for anything
-- else, including what `tonumber` would take: inf, nan, 0x10, 1e3, -5, 2.5.
local function whole(v: string): number?
	if #v <= 10 and string.match(v, "^%d+$") then
		return tonumber(v)
	end
	return nil
end

-- Epoch second a Retry-After value points at: delay seconds or an HTTP-date (IMF-fixdate), at most MAX_RETRY_S
-- ahead; nil when malformed. ponytail: RFC 850 and asctime dates are not parsed (GitHub sends seconds).
local function retryAt(v: string, now: number): number?
	local delay = whole(v)
	if delay then
		return now + math.min(delay, MAX_RETRY_S)
	end
	local d, mon, y, hh, mm, ss = string.match(v, "^%a+, (%d%d) (%a+) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$")
	local month = if mon then MONTHS[mon] else nil
	local day, year, h, m, s = tonumber(d), tonumber(y), tonumber(hh), tonumber(mm), tonumber(ss)
	if day and month and year and h and m and s then
		return math.min(utc(year, month, day, h, m, s), now + MAX_RETRY_S)
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
				local n = whole(v)
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

-- Records the quota a `gh api --include` answer reports and returns its body. A rate
-- limit that comes without usable headers (a secondary limit) backs the account off.
local function observe(out: string?, raw: string?, problem: Problem?, account: string?): string
	local now = os.time()
	local q, body = M.parseResponse(out or raw or "", now)
	M.record(q, now, account)
	if not out and problem and problem.kind == "rate-limit" and M.wait(now, account) == 0 then
		M.record({ retryUntil = now + RATE_S }, now, account)
	end
	return body
end

type Page = { total: number, next: string?, cost: number, raw: number, items: { any } }

-- All pages of the search, sequentially; `done(items, total, complete, problem, spent)` at the end.
-- `shouldContinue` is checked before every page and after every response; a
-- false answer ends with kind="superseded" and no further page runs. At most
-- SEARCH_PAGES requests are sent. `complete` holds only when every item the search
-- counts loaded within GitHub's CAP: a scan cut short (quota, page budget, an
-- empty page, a cursor that did not advance) or ended with fewer items than counted
-- is partial and keeps what arrived. `qualifier` closes the query (" is:pr sort:...").
local function searchAll(
	account: string?,
	query: string,
	qualifier: string,
	gql: string,
	jq: string,
	parse: (string) -> (Page?, string?),
	shouldContinue: () -> boolean,
	done: ({ any }?, number, boolean, Problem?, number) -> ()
)
	query = string.match(query, "^%s*(.-)%s*$") or ""
	if query == "" then
		tern.timer(0, function()
			done(nil, 0, false, { kind = "failed", message = "The view's query is empty." }, 0)
		end)
		return
	end
	if account == "" then
		account = nil
	end
	query = query .. qualifier
	local superseded: Problem = { kind = "superseded", message = "" }
	local all: { any } = {}
	local total = 0
	local loaded = 0
	local spent = 0
	local function finish(cut: boolean)
		done(all, total, not cut and loaded >= total and total <= CAP, nil, spent)
	end
	local function fetch(after: string?, page: number)
		if not shouldContinue() then
			return done(nil, 0, false, superseded, spent)
		end
		spent += 1
		local args = { "api", "graphql", "--hostname", "github.com", "--include", "-f", "query=" .. gql, "-f", "q=" .. query }
		if after then
			table.insert(args, "-f")
			table.insert(args, "after=" .. after)
		end
		table.insert(args, "--jq")
		table.insert(args, jq)
		M.gh(args, function(out, problem, _, raw)
			local body = observe(out, raw, problem, account)
			if not shouldContinue() then
				return done(nil, 0, false, superseded, spent)
			end
			if not out then
				return done(nil, 0, false, problem, spent)
			end
			local pg, why = parse(body)
			if not pg then
				return done(nil, 0, false, { kind = "failed", message = why or "malformed response" }, spent)
			end
			spent += pg.cost - 1
			if after == nil then
				total = pg.total
			end
			loaded += pg.raw
			for _, item in pg.items do
				table.insert(all, item)
			end
			local cursor = pg.next
			if cursor == nil or loaded >= math.min(total, CAP) then
				return finish(false)
			end
			if pg.raw == 0 or cursor == after or page >= SEARCH_PAGES or M.wait(os.time(), account) > 0 then
				return finish(true)
			end
			fetch(cursor, page + 1)
		end, account)
	end
	fetch(nil, 1)
end

-- searchAll over pull requests; one swap-ready SearchResult at the end.
local function searchPrs(account: string?, query: string, qualifier: string, gql: string, jq: string, shouldContinue: () -> boolean, done: (SearchResult?, Problem?, number) -> ())
	searchAll(account, query, qualifier, gql, jq, function(body)
		local pg, why = M.parsePage(body)
		if not pg then
			return nil, why
		end
		return { total = pg.total, next = pg.next, cost = pg.cost, raw = pg.raw, items = pg.prs }, nil
	end, shouldContinue, function(items, total, complete, problem, spent)
		if not items then
			return done(nil, problem, spent)
		end
		done({ prs = M.reconcile(items :: { Pr }), total = total, complete = complete }, nil, spent)
	end)
end

-- All pages of the PR search (see searchAll).
function M.search(account: string?, query: string, shouldContinue: () -> boolean, done: (SearchResult?, Problem?, number) -> ())
	searchPrs(account, query, " is:pr sort:updated-desc", SEARCH_GQL, SEARCH_JQ, shouldContinue, done)
end

-- The pull request at `url` alone, in the shape M.search answers: none when the login sees no PR there.
function M.pull(account: string?, url: string, shouldContinue: () -> boolean, done: (SearchResult?, Problem?, number) -> ())
	searchPrs(account, url, "", PULL_GQL, PULL_JQ, shouldContinue, done)
end

-- All pages of the issue search; one swap-ready IssueResult at the end (see searchAll).
function M.issues(
	account: string?,
	query: string,
	shouldContinue: () -> boolean,
	done: (tracker.IssueResult?, Problem?, number) -> ()
)
	searchAll(account, query, " is:issue sort:updated-desc", ISSUE_GQL, ISSUE_JQ, function(body)
		local pg, why = M.parseIssuePage(body)
		if not pg then
			return nil, why
		end
		return { total = pg.total, next = pg.next, cost = pg.cost, raw = pg.raw, items = pg.issues }, nil
	end, shouldContinue, function(items, total, complete, problem, spent)
		if not items then
			return done(nil, problem, spent)
		end
		done({ issues = tracker.reconcile(items :: { tracker.Issue }), total = total, complete = complete }, nil, spent)
	end)
end

local ABOUT_FIELDS = "mergeable mergeStateStatus body latestReviews(first: "
	.. REVIEWERS
	.. ") { nodes { author { login } state } } reviewRequests(first: "
	.. REVIEWERS
	.. ") { nodes { requestedReviewer { ... on User { login } ... on Team { slug } ... on Mannequin { login } ... on Bot { login } } } }"
local CHECKS_GQL = "query($o: String!, $r: String!, $n: Int!, $after: String) { rateLimit { cost } repository(owner: $o, name: $r) { pullRequest(number: $n) { "
	.. ABOUT_FIELDS
	.. " commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100, after: $after) { totalCount pageInfo { hasNextPage endCursor } "
	.. checkNodes(" isRequired(pullRequestNumber: $n)")
	.. " } } } } } } } }"
local CHECKS_JQ = "(.data.repository.pullRequest // {}) as $p | ($p.commits.nodes[0].commit.statusCheckRollup.contexts // {}) | {total:(.totalCount // 0),next:(if .pageInfo.hasNextPage then .pageInfo.endCursor else null end),nodes:(.nodes // []),about:($p | {mergeable,merge:.mergeStateStatus,body,reviews:[(.latestReviews.nodes // [])[] | {login:.author.login,state}],requested:[(.reviewRequests.nodes // [])[] | (.requestedReviewer.login // .requestedReviewer.slug)]})}"
local CHECK_PAGES = 3

local function login(v: any): string?
	return if type(v) == "string" and #v <= 64 and string.match(v, "^[%w][%w%-_%.%[%]]*$") then v else nil
end

-- A PR or issue body as the sidebar shows it: bot summaries stripped, cut to BODY_CHARS.
local function cleanBody(raw: any): string
	local body = if type(raw) == "string" then raw else ""
	-- Cursor's bot appends a generated summary between these markers; it repeats the diff, not the author.
	body = string.gsub(body, "<!%-%-%s*CURSOR_SUMMARY%s*%-%->.-<!%-%-%s*/CURSOR_SUMMARY%s*%-%->", "")
	local cut = utf8.offset(body, BODY_CHARS + 1)
	if cut and cut <= #body then
		body = string.sub(body, 1, cut - 1) .. "\n\n…"
	end
	return body
end

-- The `about` part of a checks page as CHECKS_JQ prints it; whatever is missing or malformed reads as unknown/empty.
-- A reviewer asked again shows as requested: their earlier verdict is what they were asked to revisit.
function M.about(raw: any): About
	local t = if type(raw) == "table" then raw else {}
	local merge = if t.mergeable == "CONFLICTING" then "conflicts" elseif type(t.merge) == "string" then MERGE[t.merge] or "unknown" else "unknown"
	local reviews: { Review } = {}
	local at: { [string]: number } = {}
	local function add(who: string?, state: string?)
		if who and state then
			if at[who] then
				reviews[at[who]].state = state
			elseif #reviews < REVIEWERS * 2 then
				table.insert(reviews, { login = who, state = state })
				at[who] = #reviews
			end
		end
	end
	for _, r in (if type(t.reviews) == "table" then t.reviews else {}) :: { any } do
		add(login(field(r, "login")), VERDICT[if type(field(r, "state")) == "string" then field(r, "state") else ""])
	end
	for _, who in (if type(t.requested) == "table" then t.requested else {}) :: { any } do
		add(login(who), "requested")
	end
	return { merge = merge, reviews = reviews, body = cleanBody(t.body) }
end

-- Every check of one PR's latest commit (up to CHECK_PAGES * 100), required ones flagged, and what the first page
-- says `about` the PR; done(runs, total, problem, about). Nothing is sent while the saved login is unusable (kind
-- "account") or the account's quota is paused (kind "rate-limit"). `shouldContinue` (optional) is checked before every
-- page and after every response; a false answer ends with kind="superseded". done never runs before this call
-- returns, and nothing is cached here: what a failure is worth is the caller's call.
function M.checks(repo: string, number: number, account: string?, done: ({ Run }?, number, Problem?, About?) -> (), shouldContinue: (() -> boolean)?)
	local superseded: Problem = { kind = "superseded", message = "" }
	-- Every result passes here: a cancelled request reports "superseded" whatever it found.
	local function finish(runs: { Run }?, total: number, problem: Problem?, about: About?)
		if shouldContinue and not shouldContinue() then
			return done(nil, 0, superseded)
		end
		done(runs, total, problem, about)
	end
	local function fail(problem: Problem)
		tern.timer(0, function()
			finish(nil, 0, problem)
		end)
	end
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	if not owner or not name then
		return fail({ kind = "failed", message = "Unexpected repository name." })
	end
	if account == "" then
		account = nil
	end
	if shouldContinue and not shouldContinue() then
		return fail(superseded)
	end
	local wait = M.wait(os.time(), account)
	if wait > 0 then
		return fail({ kind = "rate-limit", message = "GitHub's rate limit is reached; checks resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "." })
	end
	local first = { "api", "graphql", "--hostname", "github.com", "--include", "-f", "query=" .. CHECKS_GQL, "-f", "o=" .. owner, "-f", "r=" .. name, "-F", "n=" .. number }
	local nodes: { any } = {}
	local about: About? = nil
	local function fetch(after: string?, page: number)
		if shouldContinue and not shouldContinue() then
			return done(nil, 0, superseded)
		end
		local args = table.clone(first)
		if after then
			table.insert(args, "-f")
			table.insert(args, "after=" .. after)
		end
		table.insert(args, "--jq")
		table.insert(args, CHECKS_JQ)
		M.gh(args, function(out, problem, _, raw)
			local body = observe(out, raw, problem, account)
			if not out then
				return finish(nil, 0, problem)
			end
			local ok, data = pcall(tern.json.decode, body)
			if not ok or type(data) ~= "table" or type(data.nodes) ~= "table" or type(data.total) ~= "number" then
				return finish(nil, 0, { kind = "failed", message = "gh printed unexpected check data." })
			end
			for _, n in data.nodes do
				table.insert(nodes, n)
			end
			if page == 1 and type(data.about) == "table" then
				about = M.about(data.about)
			end
			local cursor = if type(data.next) == "string" and data.next ~= "" then data.next else nil
			if cursor and cursor ~= after and page < CHECK_PAGES and M.wait(os.time(), account) == 0 then
				return fetch(cursor, page + 1)
			end
			local runs = M.runs(nodes)
			finish(runs, #runs + math.max(0, data.total - #nodes), nil, about)
		end, account)
	end
	fetch(nil, 1)
end

local ISSUE_DETAIL_GQL = "query($o: String!, $r: String!, $n: Int!) { rateLimit { cost } repository(owner: $o, name: $r) { issue(number: $n) { body milestone { title } closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { number title url state isDraft } } } } }"
local ISSUE_DETAIL_JQ = "(.data.repository.issue // {}) | {body, milestone: .milestone.title, linked: [(.closedByPullRequestsReferences.nodes // [])[] | {number, title, url, state, isDraft}]}"

-- One issue's body, milestone and the pull requests that close it; done(detail, problem). Refusals, superseding and
-- the rate-limit pause behave as in M.checks. done never runs before this call returns.
function M.issue(repo: string, number: number, account: string?, done: (tracker.IssueDetail?, Problem?) -> (), shouldContinue: (() -> boolean)?)
	local superseded: Problem = { kind = "superseded", message = "" }
	local function finish(detail: tracker.IssueDetail?, problem: Problem?)
		if shouldContinue and not shouldContinue() then
			return done(nil, superseded)
		end
		done(detail, problem)
	end
	local function fail(problem: Problem)
		tern.timer(0, function()
			finish(nil, problem)
		end)
	end
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	if not owner or not name then
		return fail({ kind = "failed", message = "Unexpected repository name." })
	end
	if account == "" then
		account = nil
	end
	if shouldContinue and not shouldContinue() then
		return fail(superseded)
	end
	local wait = M.wait(os.time(), account)
	if wait > 0 then
		return fail({ kind = "rate-limit", message = "GitHub's rate limit is reached; details resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "." })
	end
	local args = { "api", "graphql", "--hostname", "github.com", "--include", "-f", "query=" .. ISSUE_DETAIL_GQL, "-f", "o=" .. owner, "-f", "r=" .. name, "-F", "n=" .. number, "--jq", ISSUE_DETAIL_JQ }
	M.gh(args, function(out, problem, _, raw)
		local body = observe(out, raw, problem, account)
		if not out then
			return finish(nil, problem)
		end
		local ok, data = pcall(tern.json.decode, body)
		if not ok or type(data) ~= "table" then
			return finish(nil, { kind = "failed", message = "gh printed unexpected issue data." })
		end
		local linked: { tracker.Linked } = {}
		for _, n in (if type(data.linked) == "table" then data.linked else {}) :: { any } do
			local num, title, url = field(n, "number"), field(n, "title"), field(n, "url")
			if type(num) == "number" and type(title) == "string" and type(url) == "string" and string.sub(url, 1, 8) == "https://" then
				local s = field(n, "state")
				local state = if s == "MERGED" then "merged" elseif s == "CLOSED" then "closed" elseif field(n, "isDraft") == true then "draft" else "open"
				table.insert(linked, { ref = tostring(num), title = title, url = url, state = state })
			end
		end
		local milestone = data.milestone
		finish({
			body = cleanBody(data.body),
			fields = { { label = "Milestone", value = if type(milestone) == "string" and milestone ~= "" then milestone else nil } },
			linked = linked,
		}, nil)
	end, account)
end

-- baseRef, title and author only feed prompt variables, so a missing one is "" rather than a failed read. `fork` is the
-- owner of the repository the head branch lives in when that is not `base` (a fork), and `forkRepo` that repository
-- ("owner/name"; nil when it was deleted).
export type PrMeta = { base: string, sha: string, ref: string, state: string, baseRef: string, title: string, author: string, fork: string?, forkRepo: string? }

-- Base repository, head and prompt details of one PR; done(meta, problem, cx).
function M.pr(repo: string, number: number, account: string?, done: (PrMeta?, Problem?, WindowCx?) -> ())
	if account == "" then
		account = nil
	end
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
		local function text(v: any): string
			return if type(v) == "string" then v else ""
		end
		local headRepo = text(data.headRepo)
		local forkRepo = if string.match(headRepo, "^[%w%-_%.]+/[%w%-_%.]+$") and string.lower(headRepo) ~= string.lower(data.base) then headRepo else nil
		local fork: string? = nil
		if forkRepo or headRepo == "" then
			-- A deleted fork's owner is still the head's user.
			local owner = if forkRepo then string.match(forkRepo, "^([^/]+)/") else text(data.headOwner)
			fork = if owner and string.match(owner, "^[%w%-_]+$") then owner else text(data.author)
		end
		done({
			base = data.base,
			sha = string.lower(data.sha),
			ref = data.ref,
			state = tostring(data.state),
			baseRef = text(data.baseRef),
			title = text(data.title),
			author = text(data.author),
			fork = if fork ~= "" then fork else nil,
			forkRepo = forkRepo,
		}, nil, cx)
	end, account)
end

-- A pull request an issue may be worked on: its number, title, and head branch while that branch still exists.
export type LinkedPr = { number: number, title: string, branch: string? }

local PR_LINK = "number title state headRefName headRef { name } baseRepository { nameWithOwner }"
local PR_LINK_JQ = "{number, title, state, head: .headRefName, branch: .headRef.name, base: .baseRepository.nameWithOwner}"
local CLOSING_GQL = "query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { issue(number: $n) { closedByPullRequestsReferences(first: 25, includeClosedPrs: true) { nodes { " .. PR_LINK .. " } } } } }"
local CLOSING_JQ = "[(.data.repository.issue.closedByPullRequestsReferences.nodes // [])[] | " .. PR_LINK_JQ .. "]"
local MENTION_GQL = "query($q: String!) { search(query: $q, type: ISSUE, first: 50) { nodes { ... on PullRequest { " .. PR_LINK .. " } } } }"
local MENTION_JQ = "[(.data.search.nodes // [])[] | select(.number != null) | " .. PR_LINK_JQ .. "]"

-- The pull requests of `repo` ("owner/name") issue `ref` is worked on: for a GitHub issue number those that close it,
-- for a Jira key those whose title or head branch names it. done(prs, problem).
function M.linkedPrs(repo: string, ref: string, account: string?, done: ({ LinkedPr }?, Problem?) -> ())
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	if account == "" then
		account = nil
	end
	local mention = string.match(ref, "^%d+$") == nil
	local args = if mention
		then { "api", "graphql", "--hostname", "github.com", "-f", "query=" .. MENTION_GQL, "-f", "q=repo:" .. repo .. " is:pr " .. ref, "--jq", MENTION_JQ }
		else { "api", "graphql", "--hostname", "github.com", "-f", "query=" .. CLOSING_GQL, "-f", "o=" .. (owner or ""), "-f", "r=" .. (name or ""), "-F", "n=" .. ref, "--jq", CLOSING_JQ }
	-- The key as a whole word: ABC-12 is not ABC-123.
	local word = "%f[%w]" .. string.gsub(string.lower(ref), "%p", "%%%0") .. "%f[^%w]"
	M.gh(args, function(out, problem)
		if not out then
			return done(nil, problem)
		end
		local ok, data = pcall(tern.json.decode, out)
		if not ok or type(data) ~= "table" then
			return done(nil, { kind = "failed", message = "gh printed unexpected pull request data." })
		end
		local list: { LinkedPr } = {}
		for i = 1, #data do
			local n = data[i]
			local num, title, head, branch, base = field(n, "number"), field(n, "title"), field(n, "head"), field(n, "branch"), field(n, "base")
			local names = mention and (string.find(string.lower(tostring(title)), word) or (type(head) == "string" and string.find(string.lower(head), word)))
			-- A pull request into another repository is no checkout of this one, and a merged one's branch is spent:
			-- new work on it would never reach the base.
			if type(num) == "number" and type(title) == "string" and type(base) == "string" and string.lower(base) == string.lower(repo) and (names or not mention) and field(n, "state") ~= "MERGED" then
				table.insert(list, { number = num, title = title, branch = if type(branch) == "string" and branch ~= "" then branch else nil })
			end
		end
		done(list, nil)
	end, account)
end

-- The pull request of `repo` whose head branch is `branch`, whatever its state: `gh pr list --head` (a branch name,
-- not owner:branch, so a fork's PR of the same name is listed too: cross-repository ones are skipped, the branch is not theirs).
-- An open one wins, else the newest. `state` is "open", "draft", "merged" or "closed". done(nil, nil): none.
export type HeadPr = { number: number, title: string, state: string, url: string }
function M.pullByHead(repo: string, branch: string, account: string?, done: (HeadPr?, Problem?) -> ())
	if account == "" then
		account = nil
	end
	-- `--head=` keeps a branch that starts with a dash from being read as a flag.
	M.gh({ "pr", "list", "--repo", repo, "--head=" .. branch, "--state", "all", "--limit", "10", "--json", "number,title,state,isDraft,url,isCrossRepository" }, function(out, problem)
		if not out then
			return done(nil, problem)
		end
		local ok, data = pcall(tern.json.decode, out)
		if not ok or type(data) ~= "table" then
			return done(nil, { kind = "failed", message = "gh printed unexpected pull request data." })
		end
		local best: HeadPr? = nil
		for i = 1, #data do
			local n = data[i]
			local num, title, state, url = field(n, "number"), field(n, "title"), field(n, "state"), field(n, "url")
			if type(num) == "number" and type(title) == "string" and type(state) == "string" and type(url) == "string" and field(n, "isCrossRepository") ~= true then
				local look = string.lower(state)
				if look == "open" and field(n, "isDraft") == true then
					look = "draft"
				end
				local pr: HeadPr = { number = num, title = title, state = look, url = url }
				if not best or (look == "open" or look == "draft") and best.state ~= "open" and best.state ~= "draft" then
					best = pr
				end
			end
		end
		done(best, nil)
	end, account)
end

-- What the repository picker lists, read slowly from gh, so kept by `key`: a known value answers at once (one older
-- than LIST_TTL_S is then read again in the background), and callers during a read share it. `read` calls its
-- callback once with the value, or nil and why. ponytail: in memory only; changes on GitHub show after the TTL.
local LIST_TTL_S = 10 * 60
local kept: { [string]: { at: number, value: any } } = {}
local reading: { [string]: { (any, Problem?) -> () } } = {}
local function cached(key: string, read: ((any, Problem?) -> ()) -> (), done: (any, Problem?) -> ())
	local hit = kept[key]
	if hit then
		local value = hit.value
		tern.timer(0, function()
			done(value, nil)
		end)
		if os.time() - hit.at < LIST_TTL_S or reading[key] then
			return
		end
		done = function() end
	end
	local waiting = reading[key]
	if waiting then
		table.insert(waiting, done)
		return
	end
	reading[key] = { done }
	read(function(value: any, problem: Problem?)
		if value ~= nil then
			kept[key] = { at = os.time(), value = value }
		end
		local callers: { (any, Problem?) -> () } = reading[key] or {}
		reading[key] = nil
		for _, cb in callers do
			cb(value, if value ~= nil then nil else problem)
		end
	end)
end

export type Account = { login: string, active: boolean }

-- The gh logins signed in to github.com, the active one first; done(accounts, problem). Needs gh 2.66 or newer
-- (`gh auth status --json`).
function M.accounts(done: ({ Account }?, Problem?) -> ())
	cached("accounts", function(finish)
		M.gh({ "auth", "status", "--hostname", "github.com", "--json", "hosts" }, function(out, problem, _, failed)
			-- An account whose token fails makes the exit status nonzero; the others are still listed.
			local ok, data = pcall(tern.json.decode, out or failed or "")
			local hosts = if ok and type(data) == "table" and type(data.hosts) == "table" then data.hosts["github.com"] else nil
			if type(hosts) ~= "table" then
				return finish(nil, problem or { kind = "failed", message = "gh auth status listed no accounts (it needs gh 2.66 or newer)." })
			end
			local list: { Account } = {}
			for _, a in hosts do
				if type(a) == "table" and a.state == "success" and type(a.login) == "string" and string.match(a.login, "^[%w%-_]+$") then
					table.insert(list, { login = a.login, active = a.active == true })
				end
			end
			table.sort(list, function(x, y)
				if x.active ~= y.active then
					return x.active
				end
				return string.lower(x.login) < string.lower(y.login)
			end)
			finish(list, nil)
		end)
	end, done)
end

-- `account` when it names one, else gh's active login; done(login, problem). done never runs before this returns.
function M.login(account: string?, done: (string?, Problem?) -> ())
	if account and account ~= "" then
		local who: string = account
		tern.timer(0, function()
			done(who, nil)
		end)
		return
	end
	M.accounts(function(list, problem)
		local first = if list then list[1] else nil
		if first and first.active then
			return done(first.login, nil)
		end
		done(nil, problem or { kind = "auth", message = "gh has no active account; run gh auth login." })
	end)
end

-- "owner/name" of every repository gh login `account` can access (owned, collaborator, org member), most recently
-- pushed first; done(names, problem).
function M.repos(account: string, done: ({ string }?, Problem?) -> ())
	cached("repos:" .. account, function(finish)
		M.gh({ "api", "--hostname", "github.com", "--paginate", "user/repos?per_page=100&sort=pushed", "--jq", ".[].full_name" }, function(out, problem)
			if not out then
				return finish(nil, problem)
			end
			local names: { string } = {}
			for line in string.gmatch(out, "[^\n]+") do
				local owner, name = string.match(line, "^([%w%-_%.]+)/([%w%-_%.]+)$")
				if owner and name and name ~= "." and name ~= ".." then
					table.insert(names, line)
				end
			end
			finish(names, nil)
		end, account)
	end, done)
end


-- ---------------------------------------------------------------- writes and single lookups
-- Every write is argv-only (`--flag=value`, so a value that starts with `-` stays a value), runs as the view's saved
-- gh account through M.gh, and checks its inputs first: a bad input never reaches gh. The host confirms with the user
-- before calling any of these.

local function bad(message: string): Problem
	return { kind = "invalid", message = message }
end

-- "owner/name" as gh's `--repo HOST/OWNER/REPO` takes it; nil unless well formed.
local function repoArg(repo: any): string?
	local o, r = string.match(if type(repo) == "string" then repo else "", "^([%w%-_%.]+)/([%w%-_%.]+)$")
	if not o or not r or o == "." or o == ".." or r == "." or r == ".." then
		return nil
	end
	return "github.com/" .. o .. "/" .. r
end

local function whole32(v: any): boolean
	return type(v) == "number" and v >= 1 and v <= 2147483647 and v == math.floor(v)
end

-- A gh login or `@me`; nil otherwise.
local function assignee(v: any): string?
	return if v == "@me" then v else login(v)
end

-- A label name. gh reads --add-label values as CSV, so csv() quotes the name when it is sent.
local function label(v: any): string?
	if type(v) == "string" and #v >= 1 and #v <= 50 and not string.find(v, "[%c]") and string.sub(v, 1, 1) ~= "-" and string.match(v, "%S") then
		return v
	end
	return nil
end

local function csv(v: string): string
	return '"' .. (string.gsub(v, '"', '""')) .. '"'
end

-- Valid entries of `values` as `--flag=value` args; the problem when one is invalid, over `max`, or repeated.
local function flagged(flag: string, values: any, check: (any) -> string?, what: string, args: { string }, seen: { [string]: string }, encode: ((string) -> string)?): Problem?
	if type(values) ~= "table" then
		return nil
	end
	if #values > 20 then
		return bad("At most 20 " .. what .. " per change.")
	end
	for _, v in values do
		local ok = check(v)
		if not ok then
			return bad("Not a valid " .. string.gsub(what, "s$", "") .. ": " .. tostring(v))
		end
		local k = string.lower(ok)
		if seen[k] and seen[k] ~= flag then
			return bad(ok .. " cannot be both added and removed.")
		end
		seen[k] = flag
		table.insert(args, flag .. "=" .. (if encode then encode(ok) else ok))
	end
	return nil
end

export type IssueEdit = {
	repo: string,
	number: number,
	addAssignees: { string }?,
	removeAssignees: { string }?,
	addLabels: { string }?,
	removeLabels: { string }?,
}

local function later(done: () -> ())
	tern.timer(0, done)
end

-- `gh issue edit` with validated assignees (logins, or `@me` for the account's own login) and labels; done(problem).
-- At least one change is required. Labels GitHub does not know are created by gh's own refusal: it fails, nothing is
-- invented here. done never runs before this call returns.
function M.editIssue(e: IssueEdit, account: string?, done: (Problem?) -> ())
	local repo = repoArg(e.repo)
	local args: { string } = { "issue", "edit", tostring(e.number), "--repo", repo or "" }
	local problem: Problem? = nil
	if not repo then
		problem = bad("Unexpected repository name.")
	elseif not whole32(e.number) then
		problem = bad("Unexpected issue number.")
	end
	local seenAssignee: { [string]: string } = {}
	local seenLabel: { [string]: string } = {}
	problem = problem
		or flagged("--add-assignee", e.addAssignees, assignee, "assignees", args, seenAssignee)
		or flagged("--remove-assignee", e.removeAssignees, assignee, "assignees", args, seenAssignee)
		or flagged("--add-label", e.addLabels, label, "labels", args, seenLabel, csv)
		or flagged("--remove-label", e.removeLabels, label, "labels", args, seenLabel, csv)
	if not problem and #args == 5 then
		problem = bad("Nothing to change.")
	end
	if problem then
		local p = problem
		return later(function()
			done(p)
		end)
	end
	if account == "" then
		account = nil
	end
	M.gh(args, function(_, p)
		done(p)
	end, account)
end

-- The Actions workflow run id in a check's link (`.../actions/runs/<id>/job/<job>`); nil for links that are not a
-- workflow run, a check suite or a check run id included.
function M.runIdOf(url: any): string?
	local id = if type(url) == "string" then string.match(url, "^https://github%.com/[%w%-_%.]+/[%w%-_%.]+/actions/runs/(%d+)/") or string.match(url, "^https://github%.com/[%w%-_%.]+/[%w%-_%.]+/actions/runs/(%d+)$") else nil
	return if id and #id <= 15 and tonumber(id) ~= 0 then id else nil
end

local RERUNNABLE: { [string]: boolean } = { failure = true, timed_out = true, cancelled = true, startup_failure = true }

-- Re-runs the failed jobs of workflow run `runId` (a `Run.runId`: never a check suite or check run id). The run is
-- read first and must belong to `repo`, be finished and have failed; a missing run id is a not-found, never remapped.
function M.rerunFailed(repo: string, runId: string, account: string?, done: (Problem?) -> ())
	local target = repoArg(repo)
	local problem: Problem? = nil
	if not target then
		problem = bad("Unexpected repository name.")
	elseif type(runId) ~= "string" or not string.match(runId, "^%d+$") or #runId > 15 or tonumber(runId) == 0 then
		problem = bad("Unexpected workflow run id.")
	end
	if problem then
		local p = problem
		return later(function()
			done(p)
		end)
	end
	if account == "" then
		account = nil
	end
	M.gh({ "run", "view", runId, "--repo", target or "", "--json", "databaseId,status,conclusion,url" }, function(out, p)
		if not out then
			return done(p)
		end
		local ok, data = pcall(tern.json.decode, out)
		local url = field(data, "url")
		if not ok or tostring(field(data, "databaseId")) ~= runId or type(url) ~= "string" or not string.find(url, "/actions/runs/" .. runId, 1, true) then
			return done({ kind = "failed", message = "gh printed unexpected run data." })
		end
		if field(data, "status") ~= "completed" then
			return done(bad("Workflow run " .. runId .. " has not finished."))
		end
		local conclusion = field(data, "conclusion")
		if type(conclusion) ~= "string" or not RERUNNABLE[conclusion] then
			return done(bad("Workflow run " .. runId .. " did not fail (" .. tostring(conclusion) .. ")."))
		end
		M.gh({ "run", "rerun", runId, "--repo", target or "", "--failed" }, function(_, p2)
			done(p2)
		end, account)
	end, account)
end

-- ---------------------------------------------------------------- confirmed item and run operations
-- The host confirms first. Every operation re-reads the live state as `account`, rejects a target in the wrong state
-- and only then changes it; argv arrays only, `--body=` keeps comment text from being read as a flag.

local COMMENT_MAX = 4000

-- The comment text as sent: CRLF/CR become LF (input.clean), edges trimmed. Multiline and tabs are kept; nil when empty,
-- over COMMENT_MAX characters, invalid UTF-8 or holding any other control byte (rejected, not silently dropped).
function M.commentText(v: any): string?
	if type(v) ~= "string" or utf8.len(v) == nil or string.find(v, "[%z\1-\8\11\12\14-\31\127]") then
		return nil
	end
	local t = string.match(input.clean(v, true), "^%s*(.-)%s*$") or ""
	if t == "" or (utf8.len(t) :: number) > COMMENT_MAX then
		return nil
	end
	return t
end

-- Reads `gh <kind> view <id>` of `repo` as `account` (normalized once: the read and the write run as the same login),
-- requires the answered number/id and its https://github.com/<owner>/<repo>/<seg>/<id> URL to match the target exactly,
-- then runs the argv `act(seg)` returns. `check(data)` returns a refusal text or nil. `id` is a validated digit string.
local function guarded(kind: string, fields: string, segs: { string }, repo: string, id: any, account: string?, check: (any) -> string?, act: (string, string) -> { string }, done: (Problem?) -> ())
	local target = repoArg(repo)
	local problem: Problem? = nil
	if not target then
		problem = bad("Unexpected repository name.")
	elseif type(id) ~= "string" or not string.match(id, "^%d+$") or #id > 15 or tonumber(id) == 0 then
		problem = bad("Unexpected " .. (if kind == "run" then "workflow run id" else kind .. " number") .. ".")
	end
	if problem then
		local p = problem
		return later(function()
			done(p)
		end)
	end
	local repoFlag = target or ""
	local who: string? = if account == "" then nil else account
	M.gh({ kind, "view", id, "--repo", repoFlag, "--json", fields }, function(out, p)
		if not out then
			return done(p)
		end
		local ok, data = pcall(tern.json.decode, out)
		local url = field(data, "url")
		local path = string.lower(string.sub(repoFlag, #"github.com" + 1)) -- "/owner/repo"
		local rest = if type(url) == "string" and string.sub(string.lower(url), 1, #"https://github.com" + #path + 1) == "https://github.com" .. path .. "/" then string.sub(url, #"https://github.com" + #path + 2) else nil
		local seg = if rest then string.match(rest, "^(.-)/" .. id .. "$") else nil
		local live = field(data, if kind == "run" then "databaseId" else "number")
		if not ok or not seg or not table.find(segs, seg) or (if type(live) == "number" then string.format("%d", live) else tostring(live)) ~= id then
			return done({ kind = "failed", message = "gh printed unexpected " .. kind .. " data." })
		end
		local why = check(data)
		if why then
			return done(bad(why))
		end
		M.gh(act(seg, id), function(_, p2)
			done(p2)
		end, who)
	end, who)
end

-- op "close" closes the open issue (gh's default reason), "reopen" reopens the closed one.
function M.setIssueState(repo: string, number: number, op: string, account: string?, done: (Problem?) -> ())
	local open = op == "reopen"
	if (not open and op ~= "close") or not whole32(number) then
		return later(function()
			done(bad(if whole32(number) then "Unexpected issue operation." else "Unexpected issue number."))
		end)
	end
	guarded("issue", "number,state,url", { "issues" }, repo, tostring(number), account, function(d)
		local expected = if open then "CLOSED" else "OPEN"
		if field(d, "state") ~= expected then
			return "Issue #" .. number .. (if open then " is not closed." else " is not open.")
		end
		return nil
	end, function(_, id)
		return { "issue", if open then "reopen" else "close", id, "--repo", repoArg(repo) or "" }
	end, done)
end

-- Marks the open draft PR ready (`ready` true) or converts the open non-draft PR to a draft.
function M.setPrReady(repo: string, number: number, ready: boolean, account: string?, done: (Problem?) -> ())
	if not whole32(number) then
		return later(function()
			done(bad("Unexpected pull request number."))
		end)
	end
	guarded("pr", "number,state,isDraft,url", { "pull" }, repo, tostring(number), account, function(d)
		if field(d, "state") ~= "OPEN" then
			return "Pull request #" .. number .. " is not open."
		elseif ready and field(d, "isDraft") ~= true then
			return "Pull request #" .. number .. " is not a draft."
		elseif not ready and field(d, "isDraft") ~= false then
			return "Pull request #" .. number .. " is already a draft."
		end
		return nil
	end, function(_, id)
		local args = { "pr", "ready", id, "--repo", repoArg(repo) or "" }
		if not ready then
			table.insert(args, "--undo")
		end
		return args
	end, done)
end

-- Adds `text` (M.commentText) to an existing issue or pull request of `repo`, any state.
function M.comment(repo: string, number: number, text: string, account: string?, done: (Problem?) -> ())
	local body = M.commentText(text)
	if not body or not whole32(number) then
		return later(function()
			done(bad(if body then "Unexpected issue number." else "The comment is empty, too long or has control characters."))
		end)
	end
	-- `gh issue view` also answers a pull request number (with its /pull/ URL), which picks the comment command.
	guarded("issue", "number,url", { "issues", "pull" }, repo, tostring(number), account, function()
		return nil
	end, function(seg, id)
		return { if seg == "pull" then "pr" else "issue", "comment", id, "--repo", repoArg(repo) or "", "--body=" .. body }
	end, done)
end

local CANCELLABLE: { [string]: boolean } = { queued = true, in_progress = true, waiting = true, pending = true, requested = true }

-- Cancels a queued or running workflow run (never --force). `runId` is a digit string of up to 15 digits.
function M.cancelRun(repo: string, runId: string, account: string?, done: (Problem?) -> ())
	guarded("run", "databaseId,status,url", { "actions/runs" }, repo, runId, account, function(d)
		local status = field(d, "status")
		if type(status) ~= "string" or not CANCELLABLE[status] then
			return "Workflow run " .. runId .. " is not queued or running (" .. tostring(status) .. ")."
		end
		return nil
	end, function(_, id)
		return { "run", "cancel", id, "--repo", repoArg(repo) or "" }
	end, done)
end

-- Re-runs the whole of a finished workflow run, whatever its conclusion (M.rerunFailed is the failed-jobs variant).
function M.rerunAll(repo: string, runId: string, account: string?, done: (Problem?) -> ())
	guarded("run", "databaseId,status,url", { "actions/runs" }, repo, runId, account, function(d)
		if field(d, "status") ~= "completed" then
			return "Workflow run " .. runId .. " has not finished."
		end
		return nil
	end, function(_, id)
		return { "run", "rerun", id, "--repo", repoArg(repo) or "" }
	end, done)
end

export type NewPr = { repo: string, base: string, head: string, title: string, body: string, draft: boolean }

-- A branch name as git allows it, or `owner:branch` for a head on a fork; nil otherwise.
local function branch(v: any, forkOk: boolean): string?
	if type(v) ~= "string" or #v < 1 or #v > 255 then
		return nil
	end
	local name = v
	if forkOk then
		local owner, rest = string.match(v, "^([%w%-_]+):(.+)$")
		name = rest or v
		if owner and not rest then
			return nil
		end
	end
	if string.find(name, "[%c%s~^:?*%[\\]") or string.find(name, "..", 1, true) or string.find(name, "@{", 1, true) or string.find(name, "//", 1, true) then
		return nil
	end
	local first, last = string.sub(name, 1, 1), string.sub(name, -1)
	if first == "-" or first == "/" or last == "/" or last == "." or string.sub(name, -5) == ".lock" or name == "@" then
		return nil
	end
	return v
end

-- Opens a DRAFT pull request of `repo` from `head` into `base` with the given title and body (never `--fill`, never a
-- prompt); done(url, problem). Only `draft = true` is accepted. `--head` is explicit, so gh never pushes or forks.
function M.createPr(d: NewPr, account: string?, done: (string?, Problem?) -> ())
	local repo = repoArg(d.repo)
	local problem: Problem? = nil
	if not repo then
		problem = bad("Unexpected repository name.")
	elseif d.draft ~= true then
		problem = bad("Only draft pull requests are created.")
	elseif not branch(d.base, false) then
		problem = bad("Unexpected base branch.")
	elseif not branch(d.head, true) then
		problem = bad("Unexpected head branch.")
	elseif type(d.title) ~= "string" or not string.match(d.title, "%S") or (utf8.len(d.title) or 257) > 256 or string.find(d.title, "[%c]") then
		problem = bad("The title must be one line of 1 to 256 characters.")
	elseif type(d.body) ~= "string" or #d.body > 60000 or string.find(d.body, "[\0-\8\11\12\14-\31]") then
		problem = bad("The body must be text of at most 60000 bytes.")
	end
	if problem then
		local p = problem
		return later(function()
			done(nil, p)
		end)
	end
	if account == "" then
		account = nil
	end
	local args = { "pr", "create", "--repo", repo or "", "--draft", "--base=" .. d.base, "--head=" .. d.head, "--title=" .. d.title, "--body=" .. d.body }
	M.gh(args, function(out, p)
		if not out then
			return done(nil, p)
		end
		local url = string.match(out, "(https://github%.com/[^%s]+)%s*$")
		if not url or not M.parsePrUrl(url) then
			return done(nil, { kind = "failed", message = "gh did not print the new pull request's URL: " .. firstLines(out, 3) })
		end
		done(url, nil)
	end, account)
end

-- Repository, number and kind of a github.com pull request or issue URL (https only; a query, fragment or trailing
-- slash is ignored); nil for anything else.
function M.parseItemUrl(url: any): { kind: string, repo: string, number: number }?
	if type(url) ~= "string" then
		return nil
	end
	local clean = string.gsub(string.match(url, "^[^?#]*") or "", "/$", "")
	local o, r, k, n = string.match(clean, "^https://github%.com/([%w%-_%.]+)/([%w%-_%.]+)/(%a+)/(%d+)$")
	local num = tonumber(n)
	if not o or not r or o == "." or o == ".." or r == "." or r == ".." or (k ~= "pull" and k ~= "issues") or not num or not whole32(num) then
		return nil
	end
	return { kind = if k == "pull" then "pr" else "issue", repo = o .. "/" .. r, number = num }
end

local ISSUE_ITEM_GQL = "query($q: URI!) { rateLimit { cost } resource(url: $q) { ... on Issue { number title url state stateReason updatedAt createdAt author { login } comments { totalCount } labels(first: 10) { nodes { name } } assignees(first: 10) { nodes { login } } } } }"
local ISSUE_ITEM_JQ = "[.data.resource | select(.number != null) | {number,title,url,state,reason:.stateReason,updatedAt,createdAt,author:.author.login,comments:.comments.totalCount,labels:[.labels.nodes[]?.name],assignees:[.assignees.nodes[]?.login]}] as $items | {total:($items | length),next:null,cost:.data.rateLimit.cost,items:$items}"

-- The one issue `repo`#`number`, normalized as the issue list's items are; done(issue, problem, spent). Not-found when
-- the login sees no issue there (a pull request's number is not an issue). done never runs before this returns.
function M.issueItem(repo: string, number: number, account: string?, done: (tracker.Issue?, Problem?) -> (), shouldContinue: (() -> boolean)?)
	local live = shouldContinue or function()
		return true
	end
	if not repoArg(repo) or not whole32(number) then
		return later(function()
			done(nil, bad("Unexpected issue address."))
		end)
	end
	searchAll(account, "https://github.com/" .. repo .. "/issues/" .. number, "", ISSUE_ITEM_GQL, ISSUE_ITEM_JQ, function(body)
		local pg, why = M.parseIssuePage(body)
		if not pg then
			return nil, why
		end
		return { total = pg.total, next = pg.next, cost = pg.cost, raw = pg.raw, items = pg.issues }, nil
	end, live, function(items, _, _, problem)
		local issue = if items then (items :: { tracker.Issue })[1] else nil
		if not issue then
			return done(nil, problem or { kind = "not-found", message = "This GitHub account sees no issue " .. repo .. "#" .. number .. "." })
		end
		done(issue, nil)
	end)
end
return M
