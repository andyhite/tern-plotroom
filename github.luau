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

-- Runs `gh <args>`; done(stdout, problem, cx).
function M.gh(args: { string }, done: (string?, Problem?, WindowCx?) -> ())
	local argv: { string } = { "gh" }
	for _, a in args do
		table.insert(argv, a)
	end
	process.run(argv, { timeout_ms = GH_TIMEOUT_MS, env = ENV }, function(result, perr, cx)
		if not result then
			return done(nil, { kind = "missing", message = perr or "gh could not be started" }, cx)
		end
		if result.status ~= 0 or result.timed_out then
			return done(nil, classify(result), cx)
		end
		done(result.stdout, nil, cx)
	end)
end

-- All pages of the search, sequentially; one swap-ready SearchResult at the end.
-- `shouldContinue` is checked before every page and after every response; a
-- false answer ends with kind="superseded" and no further page runs.
function M.search(
	query: string,
	shouldContinue: () -> boolean,
	done: (SearchResult?, Problem?) -> ()
)
	query = string.match(query, "^%s*(.-)%s*$") or ""
	if query == "" then
		tern.timer(0, function()
			done(nil, { kind = "failed", message = "The filter query is empty." })
		end)
		return
	end
	local superseded: Problem = { kind = "superseded", message = "" }
	local all: { Pr } = {}
	local total = 0
	local incomplete = false
	local loaded = 0
	local function fetch(page: number)
		if not shouldContinue() then
			return done(nil, superseded)
		end
		M.gh({
			"api", "--hostname", "github.com", "--method", "GET", "search/issues",
			"-f", "q=" .. query .. " is:pr",
			"-f", "per_page=" .. PAGE,
			"-f", "page=" .. page,
			"-f", "sort=updated",
			"-f", "order=desc",
			"--jq", SEARCH_JQ,
		}, function(out, problem)
			if not shouldContinue() then
				return done(nil, superseded)
			end
			if not out then
				return done(nil, problem)
			end
			local pg, why = M.parsePage(out)
			if not pg then
				return done(nil, { kind = "failed", message = why or "malformed response" })
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
				return done({ prs = M.reconcile(all), total = total, complete = not incomplete and total <= CAP }, nil)
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
