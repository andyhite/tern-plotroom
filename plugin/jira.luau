--!strict
-- Jira through Atlassian's acli, as the account it is signed in to: one project's issue search, one issue's details and
-- the project list. Shared by host and window. Cloud only; every command is an argv array run through process.luau.

local github = require("./github")
local input = require("./input")
local process = require("./process")
local tracker = require("./tracker")

local M = {}

-- Problem kinds as github.luau's: auth | missing | rate-limit | invalid | not-found | failed | superseded.
type Problem = { kind: string, message: string }

local TIMEOUT_MS = 60 * 1000
-- ponytail: the newest 100 by update per view; page with --paginate if views need more
M.LIMIT = 100
-- The only fields acli's search accepts; a work item's dates and comment count come with its details.
local SEARCH_FIELDS = "key,summary,status,issuetype,priority,assignee,reporter,labels"
local BODY_CHARS = 20000
local TONE: { [string]: string } = { new = "muted", indeterminate = "warning", done = "success" }
local KEY = "^[A-Z][A-Z0-9_]*%-%d+$"

local field = github.field

local function nonEmpty(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function list(v: any): { any }
	return if type(v) == "table" then v else {}
end

-- The Problem acli's failure means; `text` is what it printed, stdout then stderr.
function M.classify(text: string): Problem
	local line = input.trim(string.match(text, "Error:%s*([^\n]+)") or string.match(text, "%S[^\n]*") or "")
	if line == "" then
		line = "acli failed."
	end
	local low = string.lower(text)
	if string.find(low, "unauthorized", 1, true) or string.find(low, "auth login", 1, true) then
		return { kind = "auth", message = "acli is not signed in to Jira: " .. line }
	end
	if string.find(low, "failed to parse jql", 1, true) then
		return { kind = if string.find(low, "field 'project'", 1, true) then "not-found" else "invalid", message = line }
	end
	if string.find(low, "%f[%w_%-]429%f[^%w_%-]") or string.find(low, "rate limit", 1, true) then
		return { kind = "rate-limit", message = line }
	end
	return { kind = "failed", message = line }
end

-- Runs `acli <args>`; done(stdout, problem). An acli that cannot be started is `missing`, no answer in time is
-- `failed`, and a nonzero exit is classified by M.classify.
local function acli(args: { string }, done: (string?, Problem?) -> ())
	local argv: { string } = { "acli" }
	for _, a in args do
		table.insert(argv, a)
	end
	process.run(argv, { timeout_ms = TIMEOUT_MS }, function(result, perr)
		if not result then
			return done(nil, { kind = "missing", message = perr or "acli could not be started" })
		end
		if result.timed_out then
			return done(nil, { kind = "failed", message = "acli did not answer within 60 seconds." })
		end
		if result.status ~= 0 then
			return done(nil, M.classify(result.stdout .. "\n" .. result.stderr))
		end
		done(result.stdout, nil)
	end)
end

-- The browse URL base ("https://<site>"): the issues' own `self` URLs name internal API hosts, so it comes from
-- `acli jira auth status`, once per sign-in, with the signed-in email's local part (`{jira.user}`; "" when unnamed).
local site: string? = nil
local user = ""
local email = ""

-- Forgets the site, so a changed sign-in is found without restarting Tern. The host's Retry calls this.
function M.reset()
	site = nil
end

local function withSite(done: (string?, Problem?) -> ())
	local known = site
	if known then
		return done(known, nil)
	end
	acli({ "jira", "auth", "status" }, function(out, problem)
		if not out then
			return done(nil, problem)
		end
		local host = string.match(out, "Site:%s*([%w%.%-]+)")
		if not host then
			return done(nil, { kind = "auth", message = "acli did not name a Jira site; run acli jira auth login." })
		end
		site = "https://" .. host
		user = string.match(out, "Email:%s*([%w%.%-_+]+)@") or ""
		email = string.match(out, "Email:%s*([%w%.%-_+]+@[%w%.%-]+)") or ""
		done(site, nil)
	end)
end

-- The signed-in Jira user as `{jira.user}` names it: the email before the `@`; done(user, problem).
function M.user(done: (string?, Problem?) -> ())
	withSite(function(found, problem)
		done(if found then user else nil, problem)
	end)
end

export type Identity = { site: string, email: string }

-- The account acli runs as, read fresh (never from the cache): its full email and site. A sign-in with no email is a
-- problem, because nothing could be bound to it. done(identity, problem).
function M.identity(done: (Identity?, Problem?) -> ())
	site = nil
	withSite(function(found, problem)
		if not found then
			return done(nil, problem)
		elseif email == "" then
			return done(nil, { kind = "auth", message = "acli did not name the signed-in email; run acli jira auth login." })
		end
		done({ site = found, email = email }, nil)
	end)
end

-- The signed-in Jira user once a search or M.user found the site, without asking; nil before then.
function M.known(): string?
	return if site then user else nil
end

-- A search or view that ends signed out forgets the site too: the next one asks again.
local function noted(problem: Problem?): Problem?
	if problem and problem.kind == "auth" then
		site = nil
	end
	return problem
end

-- acli's JSON from its stdout; whatever it printed before the first `[` or `{` (an update notice) is skipped.
local function decode(stdout: string): (boolean, any)
	return pcall(tern.json.decode, string.sub(stdout, (string.find(stdout, "[%[{]") or 1)))
end

-- The tables of a decoded array: null elements are skipped, `null` and an empty array are no elements; nil when it is
-- not an array.
local function elements(data: any): { any }?
	if data == nil or data == tern.json.null then
		return {}
	end
	if type(data) ~= "table" then
		return nil
	end
	local out: { any } = {}
	for i = 1, #data do
		local v = data[i]
		if type(v) == "table" and v ~= tern.json.null then
			table.insert(out, v)
		end
	end
	if #data == 0 and next(data) ~= nil then
		return nil
	end
	return out
end

-- Why `query` cannot be wrapped in parentheses, or nil: quotes and parentheses must balance (an extra `)` would
-- close the wrapper) and ordering is the search's own.
function M.scopeProblem(query: string): string?
	local depth = 0
	local quote: string? = nil
	local outside: { string } = {}
	local i = 1
	while i <= #query do
		local c = string.sub(query, i, i)
		if quote then
			if c == "\\" then
				i += 1
			elseif c == quote then
				quote = nil
			end
		elseif c == '"' or c == "'" then
			quote = c
			table.insert(outside, " ")
		else
			if c == "(" then
				depth += 1
			elseif c == ")" then
				depth -= 1
				if depth < 0 then
					return "Unbalanced parentheses."
				end
			end
			table.insert(outside, c)
		end
		i += 1
	end
	if quote or depth ~= 0 then
		return "Unbalanced quotes or parentheses."
	end
	if string.find(string.lower(table.concat(outside)), "order%s+by") then
		return "Leave out ORDER BY: issues are listed by status, then priority."
	end
	return nil
end

-- One work item of the search as an Issue, or nil and why. `siteUrl` is the browse URL base.
function M.normalize(item: any, siteUrl: string): (tracker.Issue?, string?)
	local key, fields = field(item, "key"), field(item, "fields")
	local summary = field(fields, "summary")
	local project = if type(key) == "string" then string.match(key, "^(.-)%-%d+$") else nil
	if type(key) ~= "string" or not project or not string.match(key, KEY) or type(fields) ~= "table" or type(summary) ~= "string" then
		return nil, "acli returned a work item without a key or summary"
	end
	local category = field(fields, "status", "statusCategory", "key")
	local statusName = nonEmpty(field(fields, "status", "name"))
	local assignee = nonEmpty(field(fields, "assignee", "displayName"))
	local labels: { string } = {}
	for _, l in list(field(fields, "labels")) do
		if type(l) == "string" then
			table.insert(labels, l)
		end
	end
	return {
		key = string.lower(project) .. "#" .. key,
		tracker = "jira",
		repo = project,
		ref = key,
		title = summary,
		url = siteUrl .. "/browse/" .. key,
		author = nonEmpty(field(fields, "reporter", "displayName")) or "Unknown",
		state = if category == "done" then "closed" else "open",
		reason = nil,
		status = if statusName then { text = statusName, tone = (if type(category) == "string" then TONE[category] else nil) or "muted" } else nil,
		category = if type(category) == "string" then category else nil,
		type = nonEmpty(field(fields, "issuetype", "name")),
		priority = nonEmpty(field(fields, "priority", "name")),
		labels = labels,
		assignees = if assignee then { assignee } else {},
		comments = 0,
		created = 0,
		updated = 0,
	}, nil
end

-- The work items that `query` (JQL) finds across every project, highest priority (the site's own order) then newest update
-- first; one swap-ready IssueResult, in acli's order. Spent is always 0: Jira has no quota to account for. done never runs
-- before this call returns.
function M.issues(query: string, shouldContinue: () -> boolean, done: (tracker.IssueResult?, Problem?, number) -> ())
	local superseded: Problem = { kind = "superseded", message = "" }
	-- Every result passes here: a cancelled request reports "superseded" whatever it found.
	local function finish(result: tracker.IssueResult?, problem: Problem?)
		if not shouldContinue() then
			return done(nil, superseded, 0)
		end
		done(result, problem, 0)
	end
	local function fail(problem: Problem)
		tern.timer(0, function()
			finish(nil, problem)
		end)
	end
	if string.match(query, "^%s*$") then
		return fail({ kind = "failed", message = "The view's query is empty." })
	end
	local why = M.scopeProblem(query)
	if why then
		return fail({ kind = "invalid", message = why })
	end
	withSite(function(base, problem)
		if not base then
			return finish(nil, problem)
		end
		if not shouldContinue() then
			return fail(superseded)
		end
		local jql = "(" .. query .. ") ORDER BY priority DESC, updated DESC"
		acli({ "jira", "workitem", "search", "--jql", jql, "--limit", tostring(M.LIMIT), "--json", "--fields", SEARCH_FIELDS }, function(out, problem2)
			if not out then
				return finish(nil, noted(problem2))
			end
			local ok, data = decode(out)
			local found = if ok then elements(data) else nil
			if not found then
				return finish(nil, { kind = "failed", message = "acli printed something other than a search result" })
			end
			local issues: { tracker.Issue } = {}
			for _, item in found do
				local issue, reason = M.normalize(item, base)
				if not issue then
					return finish(nil, { kind = "failed", message = reason or "acli printed something other than a search result" })
				end
				table.insert(issues, issue)
			end
			finish({ issues = issues, total = #issues, complete = #issues < M.LIMIT }, nil)
		end)
	end)
end

-- Whether the signed-in site has sprints, i.e. JQL knows a Sprint field (a site that never turned them on, or a user who
-- may not see it, does not); done(true | false), or done(nil) when acli could not tell (signed out, offline).
function M.sprints(done: (boolean?) -> ())
	acli({ "jira", "workitem", "search", "--jql", "sprint is EMPTY", "--count" }, function(out, problem)
		if out then
			return done(true)
		end
		local why = string.lower(if problem then problem.message else "")
		done(if string.find(why, "field 'sprint'", 1, true) then false else nil)
	end)
end

-- Wraps `s` in `left`/`right`, keeping its edge whitespace outside (markdown ends emphasis at a non-space).
local function wrap(s: string, left: string, right: string): string
	local lead, core, trail = string.match(s, "^(%s*)(.-)(%s*)$")
	if not lead or not core or not trail or core == "" then
		return s
	end
	return lead .. left .. core .. right .. trail
end

local function isInline(t: any): boolean
	return type(t) == "string" and (string.sub(t, 1, 5) == "media" or t == "text" or t == "hardBreak" or t == "mention" or t == "emoji" or t == "inlineCard" or t == "blockCard" or t == "status" or t == "date")
end

local inline: (node: any) -> string

local function inlineOf(node: any): string
	local out: { string } = {}
	for _, child in list(field(node, "content")) do
		table.insert(out, inline(child))
	end
	return table.concat(out)
end

-- ponytail: text is not escaped, so a literal * or _ in a description may render as emphasis
inline = function(node: any): string
	local t = field(node, "type")
	if t == "text" then
		local s = field(node, "text")
		if type(s) ~= "string" then
			return ""
		end
		for _, mark in list(field(node, "marks")) do
			local m = field(mark, "type")
			if m == "code" then
				s = wrap(s, "`", "`")
			elseif m == "strong" then
				s = wrap(s, "**", "**")
			elseif m == "em" then
				s = wrap(s, "*", "*")
			elseif m == "strike" then
				s = wrap(s, "~~", "~~")
			elseif m == "link" and type(field(mark, "attrs", "href")) == "string" then
				s = wrap(s, "[", "](" .. field(mark, "attrs", "href") .. ")")
			end
		end
		return s
	elseif t == "hardBreak" then
		return "\n"
	elseif t == "mention" or t == "status" then
		return nonEmpty(field(node, "attrs", "text")) or ""
	elseif t == "emoji" then
		return nonEmpty(field(node, "attrs", "text")) or nonEmpty(field(node, "attrs", "shortName")) or ""
	elseif t == "inlineCard" or t == "blockCard" then
		return nonEmpty(field(node, "attrs", "url")) or ""
	elseif isInline(t) then
		return "" -- date, media
	end
	return inlineOf(node)
end

local blocks: (node: any) -> string

local function block(node: any): string
	local t = field(node, "type")
	if t == "paragraph" then
		return inlineOf(node)
	elseif t == "heading" then
		local level = field(node, "attrs", "level")
		return string.rep("#", math.clamp(if type(level) == "number" then math.floor(level) else 1, 1, 6)) .. " " .. inlineOf(node)
	elseif t == "bulletList" or t == "orderedList" then
		local ordered = t == "orderedList"
		local n = field(node, "attrs", "order")
		n = if type(n) == "number" then math.floor(n) else 1
		local items: { string } = {}
		for _, item in list(field(node, "content")) do
			local marker = if ordered then n .. ". " else "- "
			n += 1
			local text = ""
			for _, child in list(field(item, "content")) do
				local s = block(child)
				if s ~= "" then
					local nested = field(child, "type")
					text = if text == "" then s else text .. (if nested == "bulletList" or nested == "orderedList" then "\n" else "\n\n") .. s
				end
			end
			-- what follows the first line sits under the marker, a nested list included
			table.insert(items, marker .. string.gsub(text, "\n([^\n])", "\n" .. string.rep(" ", #marker) .. "%1"))
		end
		return table.concat(items, "\n")
	elseif t == "codeBlock" then
		local lang = field(node, "attrs", "language")
		local text = inlineOf(node)
		local fence = "```"
		for run in string.gmatch(text, "`+") do
			if #run >= #fence then
				fence = string.rep("`", #run + 1)
			end
		end
		return fence .. (if type(lang) == "string" then lang else "") .. "\n" .. text .. "\n" .. fence
	elseif t == "blockquote" then
		return (string.gsub("> " .. blocks(node), "\n", "\n> "))
	elseif t == "rule" then
		return "---"
	elseif t == "table" then
		local rows: { string } = {}
		for _, row in list(field(node, "content")) do
			local cells: { string } = {}
			for _, cell in list(field(row, "content")) do
				local text = string.gsub(blocks(cell), "%s*\n+%s*", " ")
				table.insert(cells, (string.gsub(text, "|", "\\|")))
			end
			table.insert(rows, "| " .. table.concat(cells, " | ") .. " |")
			if #rows == 1 then
				table.insert(rows, "|" .. string.rep(" --- |", #cells))
			end
		end
		return table.concat(rows, "\n")
	elseif isInline(t) then
		return inline(node)
	end
	-- doc, panel, expand, nestedExpand and anything unknown: what they contain
	if isInline(field(list(field(node, "content"))[1], "type")) then
		return inlineOf(node)
	end
	return blocks(node)
end

blocks = function(node: any): string
	local out: { string } = {}
	for _, child in list(field(node, "content")) do
		local s = block(child)
		if s ~= "" then
			table.insert(out, s)
		end
	end
	return table.concat(out, "\n\n")
end

-- An ADF (Atlassian Document Format) node as markdown. Dates and media draw nothing.
function M.adf(node: any): string
	return input.trim(block(node))
end

-- The description's markdown, cut to BODY_CHARS characters.
local function bodyOf(description: any): string
	local text = if type(description) == "table" then M.adf(description) elseif type(description) == "string" then description else ""
	local cut = utf8.offset(text, BODY_CHARS + 1)
	if cut and cut <= #text then
		text = string.sub(text, 1, cut - 1) .. "…"
	end
	return text
end

-- Names of `{ name }` entries, joined; nil when there are none.
local function names(v: any): string?
	local out: { string } = {}
	for _, e in list(v) do
		local n = nonEmpty(field(e, "name"))
		if n then
			table.insert(out, n)
		end
	end
	return if #out > 0 then table.concat(out, ", ") else nil
end

-- ponytail: sprint field found by shape, not by its configured id
local function sprintOf(fields: any): string?
	if type(fields) ~= "table" then
		return nil
	end
	local ids: { string } = {}
	for k in fields do
		if type(k) == "string" and string.sub(k, 1, 12) == "customfield_" then
			table.insert(ids, k)
		end
	end
	table.sort(ids)
	for _, id in ids do
		local sprints = list(fields[id])
		local shaped = #sprints > 0
		for _, s in sprints do
			if type(field(s, "state")) ~= "string" or type(field(s, "boardId")) ~= "number" then
				shaped = false
				break
			end
		end
		if shaped then
			for _, state in { "active", "future" } do
				for _, s in sprints do
					if field(s, "state") == state then
						return nonEmpty(field(s, "name"))
					end
				end
			end
			return nonEmpty(field(sprints[#sprints], "name"))
		end
	end
	return nil
end

local function stamp(v: any): number?
	return if type(v) == "string" then github.epoch(v) else nil
end

-- One work item's details: its description as markdown, the rows tracker.FIELDS.jira names, its linked issues and
-- subtasks, comment count and dates. `base` is the browse URL base.
local function detailOf(fields: any, base: string): tracker.IssueDetail
	local parent = field(fields, "parent")
	local pkey, psummary = field(parent, "key"), field(parent, "fields", "summary")
	local byLabel: { [string]: string? } = {
		Parent = if type(pkey) == "string" then pkey .. (if type(psummary) == "string" then " " .. psummary else "") else nil,
		Sprint = sprintOf(fields),
		Components = names(field(fields, "components")),
		["Fix versions"] = names(field(fields, "fixVersions")),
	}
	local rows: { tracker.Field } = {}
	for _, label in tracker.FIELDS.jira do
		table.insert(rows, { label = label, value = byLabel[label] })
	end
	local linked: { tracker.Linked } = {}
	local function add(other: any, relation: any)
		local ref, title = field(other, "key"), field(other, "fields", "summary")
		if type(ref) == "string" and string.match(ref, KEY) and type(title) == "string" then
			local category = field(other, "fields", "status", "statusCategory", "key")
			local key = if type(category) == "string" then category else ""
			local name = nonEmpty(field(other, "fields", "status", "name")) or tracker.CATEGORY_LABEL[key] or "Open"
			table.insert(linked, {
				ref = ref,
				title = title,
				url = base .. "/browse/" .. ref,
				state = if category == "done" then "done" else "open",
				relation = nonEmpty(relation),
				status = { text = name, tone = TONE[key] or "muted" },
			})
		end
	end
	for _, l in list(field(fields, "issuelinks")) do
		if type(field(l, "outwardIssue")) == "table" then
			add(field(l, "outwardIssue"), field(l, "type", "outward"))
		else
			add(field(l, "inwardIssue"), field(l, "type", "inward"))
		end
	end
	for _, s in list(field(fields, "subtasks")) do
		add(s, "subtask")
	end
	local total = field(fields, "comment", "total")
	return {
		body = bodyOf(field(fields, "description")),
		fields = rows,
		linked = linked,
		comments = if type(total) == "number" and total >= 0 then total else nil,
		created = stamp(field(fields, "created")),
		updated = stamp(field(fields, "updated")),
	}
end

-- One work item's details; done(detail, problem). A bad key, superseding and an unsigned acli behave as in M.issues.
-- done never runs before this call returns.
function M.issue(key: string, done: (tracker.IssueDetail?, Problem?) -> (), shouldContinue: (() -> boolean)?)
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
	if not string.match(key, KEY) then
		return fail({ kind = "failed", message = "Unexpected issue key." })
	end
	withSite(function(base, problem)
		if not base then
			return finish(nil, problem)
		end
		if shouldContinue and not shouldContinue() then
			return fail(superseded)
		end
		acli({ "jira", "workitem", "view", key, "--json", "--fields", "*all" }, function(out, problem2)
			if not out then
				return finish(nil, noted(problem2))
			end
			local ok, data = decode(out)
			local fields = if ok then field(data, "fields") else nil
			if type(fields) ~= "table" then
				return finish(nil, { kind = "failed", message = "acli printed unexpected issue data." })
			end
			finish(detailOf(fields, base), nil)
		end)
	end)
end

-- The projects the account can see, sorted by key; done(projects, problem).
function M.projects(done: ({ { key: string, name: string } }?, Problem?) -> ())
	-- ponytail: read on every picker open (~1 s); cache like github's lists if it drags
	acli({ "jira", "project", "list", "--paginate", "--json" }, function(out, problem)
		if not out then
			return done(nil, problem)
		end
		local ok, data = decode(out)
		local found = if ok then elements(data) else nil
		if not found then
			return done(nil, { kind = "failed", message = "acli printed something other than a project list." })
		end
		local projects: { { key: string, name: string } } = {}
		for _, p in found do
			local key = field(p, "key")
			if type(key) == "string" and tracker.jiraProject(key) then
				table.insert(projects, { key = key, name = nonEmpty(field(p, "name")) or "" })
			end
		end
		table.sort(projects, function(a, b)
			return a.key < b.key
		end)
		done(projects, nil)
	end)
end

-- ---------------------------------------------------------------- lookups and writes
-- The host confirms with the user before calling a write. acli runs as the account it is signed in to; every write
-- is `acli jira workitem <verb> --key <KEY> ... --yes`, one work item, never JQL, a filter or --ignore-errors.

local function later(done: () -> ())
	tern.timer(0, done)
end

-- Host and key of a Jira browse link (`https://<host>/browse/ABC-1`, or any board link with `?selectedIssue=ABC-1`);
-- nil for anything else. The host is returned so a caller can compare it with the signed-in site.
function M.parseUrl(url: any): (string?, string?)
	if type(url) ~= "string" then
		return nil, nil
	end
	local host, rawPath, rawQuery = string.match(url, "^https://([%w%.%-]+)(/[^?#]*)%??([^#]*)")
	if not host then
		return nil, nil
	end
	local path: string = rawPath or ""
	local query: string = rawQuery or ""
	local key: string? = string.match(path, "^/browse/([%w_%-]+)/?$")
	if not key then
		for param in string.gmatch(query, "[^&]+") do
			key = string.match(param, "^selectedIssue=([%w_%-]+)$")
			if key then
				break
			end
		end
	end
	if key and string.match(key, KEY) then
		return key, host
	end
	return nil, nil
end

-- The key of a Jira link whose host is the signed-in site, or nil: done(key, problem). Asks acli for the site first.
-- done never runs before this call returns.
function M.keyOfUrl(url: string, done: (string?, Problem?) -> ())
	local key, host = M.parseUrl(url)
	if not key then
		return later(function()
			done(nil, { kind = "invalid", message = "Not a Jira work item link." })
		end)
	end
	local sync = true
	withSite(function(base, problem)
		local function finish(k: string?, p: Problem?)
			if sync then
				return later(function()
					done(k, p)
				end)
			end
			done(k, p)
		end
		if not base then
			return finish(nil, problem)
		end
		if base ~= "https://" .. string.lower(host or "") then
			return finish(nil, { kind = "invalid", message = "That link is on " .. tostring(host) .. ", not the signed-in site " .. string.sub(base, 9) .. "." })
		end
		finish(key, nil)
	end)
	sync = false
end

-- One work item as the issue list's items are (`M.normalize`); done(issue, problem). A bad key, superseding and an
-- unsigned acli behave as in M.issues. done never runs before this call returns.
function M.item(key: string, done: (tracker.Issue?, Problem?) -> (), shouldContinue: (() -> boolean)?)
	local superseded: Problem = { kind = "superseded", message = "" }
	local function finish(issue: tracker.Issue?, problem: Problem?)
		if shouldContinue and not shouldContinue() then
			return done(nil, superseded)
		end
		done(issue, problem)
	end
	if type(key) ~= "string" or not string.match(key, KEY) then
		return later(function()
			finish(nil, { kind = "failed", message = "Unexpected issue key." })
		end)
	end
	withSite(function(base, problem)
		if not base then
			return finish(nil, problem)
		end
		acli({ "jira", "workitem", "view", key, "--json", "--fields", SEARCH_FIELDS }, function(out, problem2)
			if not out then
				return finish(nil, noted(problem2))
			end
			local ok, data = decode(out)
			local issue: tracker.Issue?, why: string? = nil, "acli printed something other than a work item"
			if ok then
				issue, why = M.normalize(data, base)
			end
			if not issue or issue.ref ~= key then
				return finish(nil, { kind = "failed", message = why or "acli printed another work item than " .. key })
			end
			finish(issue, nil)
		end)
	end)
end

-- Assigns `key` to the signed-in user (`--assignee @me`); done(problem).
function M.assignMe(key: string, done: (Problem?) -> ())
	if type(key) ~= "string" or not string.match(key, KEY) then
		return later(function()
			done({ kind = "invalid", message = "Unexpected issue key." })
		end)
	end
	acli({ "jira", "workitem", "assign", "--key", key, "--assignee", "@me", "--yes" }, function(_, problem)
		done(noted(problem))
	end)
end

-- Moves `key` to the status named `status` with `acli jira workitem transition` (no REST, no API token); acli's own
-- refusal (no such status, a transition that needs fields) is the problem. done(problem).
function M.moveTo(key: string, status: string, done: (Problem?) -> ())
	if type(key) ~= "string" or not string.match(key, KEY) or type(status) ~= "string" or status == "" then
		return later(function()
			done({ kind = "invalid", message = "Unexpected issue key or status." })
		end)
	end
	acli({ "jira", "workitem", "transition", "--key", key, "--status", status, "--yes" }, function(_, problem)
		done(noted(problem))
	end)
end

-- Adds `text` (github.commentText: trimmed, nonempty, bounded) as a comment on `key` as the account `who` (M.identity: its
-- full email and site, read again here and required to match), read first so a missing item is a not-found;
-- `acli jira workitem comment create --key <KEY> --body=<text>` (one item, project-default visibility). done(problem).
function M.comment(key: string, text: string, who: Identity, done: (Problem?) -> ())
	local body = github.commentText(text)
	if type(key) ~= "string" or not string.match(key, KEY) or not body then
		return later(function()
			done({ kind = "invalid", message = if body then "Unexpected issue key." else "The comment is empty, too long or has control characters." })
		end)
	end
	-- Read the sign-in again now: the write goes only to the account and site the user was shown, and the lookup below
	-- (which reuses this read's site) finds the key on that site.
	M.identity(function(now, problem0)
		if not now then
			return done(problem0)
		elseif now.site ~= who.site or now.email ~= who.email then
			return done({ kind = "invalid", message = "The acli account changed since you were asked (" .. who.email .. " at " .. who.site .. ", now " .. now.email .. " at " .. now.site .. "); nothing was sent." })
		end
		M.item(key, function(_, problem)
			if problem then
				return done(problem)
			end
			acli({ "jira", "workitem", "comment", "create", "--key", key, "--body=" .. body }, function(_, p2)
				done(noted(p2))
			end)
		end)
	end)
end

-- ---------------------------------------------------------------- transitions (Jira REST)
-- acli cannot list a work item's transitions, so these two use Jira Cloud's REST API through tern.fetch: Basic auth of
-- the acli account's email (from `acli jira auth status`) and an API token the user opts in with in the host
-- environment, PLOTROOM_JIRA_API_TOKEN. The token is read per call, never stored, logged or put in argv or a message.
-- Only the acli site's own `https://<name>.atlassian.net/rest/api/3/...` fixed routes are requested, and `myself` must
-- name the acli email before anything is listed or written. tern.fetch follows redirects and has no policy to stop it.
-- ponytail: Jira Cloud's REST routes used here do not redirect; if that must be guaranteed, it needs a transport option.

export type Transition = { id: string, name: string, to: string? }

local TOKEN_HELP = "Listing Jira transitions needs a Jira API token: create one at https://id.atlassian.com/manage-profile/security/api-tokens, set PLOTROOM_JIRA_API_TOKEN to it in the environment Tern starts from, and restart Tern."

-- Jira's own refusal text (errorMessages or the first field error); "" when it sent none.
local function reason(body: string): string
	local ok, data = pcall(tern.json.decode, body)
	if not ok then
		return ""
	end
	local m = list(field(data, "errorMessages"))[1]
	if type(m) ~= "string" then
		local errors = field(data, "errors")
		m = if type(errors) == "table" then select(2, next(errors)) else nil
	end
	return if type(m) == "string" then ": " .. string.sub(m, 1, 300) else ""
end

-- One request to a fixed /rest/api/3 route as the verified account; done(decoded body or nil, problem).
local function rest(method: string, path: string, body: any, done: (any, Problem?) -> ())
	withSite(function(base, problem)
		if not base then
			return done(nil, problem)
		end
		if not string.match(base, "^https://[%w%-]+%.atlassian%.net$") or email == "" then
			return done(nil, { kind = "auth", message = "acli's Jira site or email is not a *.atlassian.net sign-in; the REST API is not used for it." })
		end
		local token = tern.getenv("PLOTROOM_JIRA_API_TOKEN")
		if not token or token == "" then
			return done(nil, { kind = "auth", message = TOKEN_HELP })
		end
		local headers = { Authorization = "Basic " .. tern.base64.encode(email .. ":" .. token), Accept = "application/json" }
		if body ~= nil then
			headers["Content-Type"] = "application/json"
		end
		local ok, err = pcall(function(): string?
			tern.fetch(base .. path, { method = method, headers = headers, body = if body ~= nil then tern.json.encode(body) else nil, timeout_ms = TIMEOUT_MS }, function(r)
			if r.timed_out or r.error then
				return done(nil, { kind = "failed", message = if r.timed_out then "Jira did not answer within 60 seconds." else "Jira could not be reached: " .. tostring(r.error) })
			end
			if r.status == 401 then
				return done(nil, { kind = "auth", message = "Jira rejected PLOTROOM_JIRA_API_TOKEN for " .. email .. "." })
			elseif r.status == 403 then
				return done(nil, { kind = "auth", message = "This Jira account may not do that" .. reason(r.body) })
			elseif r.status == 404 then
				return done(nil, { kind = "not-found", message = "Jira does not show that work item to this account." })
			elseif r.status == 429 then
				return done(nil, { kind = "rate-limit", message = "Jira rate limit reached." })
			elseif r.status < 200 or r.status > 299 then
				return done(nil, { kind = "failed", message = "Jira answered HTTP " .. r.status .. reason(r.body) })
			end
			if r.body == "" then
				return done({}, nil)
			end
			local decoded, data = pcall(tern.json.decode, r.body)
			if not decoded then
				return done(nil, { kind = "failed", message = "Jira printed something other than JSON." })
			end
			done(data, nil)
			end)
			return nil
		end)
		if not ok then
			done(nil, { kind = "failed", message = "Jira request refused: " .. tostring(err) })
		end
	end)
end

-- `done` once /myself names the acli account; the REST token may belong to another one, and nothing is sent then.
local function verified(done: (Problem?) -> ())
	site = nil -- every write rereads acli's current sign-in; nothing goes to a cached site
	withSite(function(base, siteProblem)
		if not base then
			local why = if siteProblem then siteProblem.message else ""
			return done({ kind = "auth", message = "Could not read acli's Jira sign-in; nothing was sent. " .. why })
		end
		rest("GET", "/rest/api/3/myself", nil, function(data, problem)
		if problem then
			return done(problem)
		end
		local who = field(data, "emailAddress")
		if type(who) ~= "string" then
			return done({ kind = "auth", message = "Jira did not report the token's email, so it cannot be matched to the acli account " .. email .. "." })
		end
		if string.lower(who) ~= string.lower(email) then
			return done({ kind = "auth", message = "PLOTROOM_JIRA_API_TOKEN belongs to " .. who .. ", not the acli account " .. email .. "; nothing was sent." })
		end
		done(nil)
	end)
	end)
end

local function listed(key: string, done: ({ Transition }?, Problem?) -> ())
	verified(function(problem)
		if problem then
			return done(nil, problem)
		end
		rest("GET", "/rest/api/3/issue/" .. key .. "/transitions", nil, function(data, problem2)
			if problem2 then
				return done(nil, problem2)
			end
			local out: { Transition } = {}
			for _, t in list(field(data, "transitions")) do
				local id, name = field(t, "id"), field(t, "name")
				if type(id) == "string" and string.match(id, "^%d+$") and type(name) == "string" then
					table.insert(out, { id = id, name = name, to = nonEmpty(field(t, "to", "name")) })
				end
			end
			done(out, nil)
		end)
	end)
end

local function badKey(key: any, done: (any, Problem?) -> ()): boolean
	if type(key) == "string" and string.match(key, KEY) then
		return false
	end
	later(function()
		done(nil, { kind = "invalid", message = "Unexpected issue key." })
	end)
	return true
end

-- The transitions Jira offers `key` right now, as Jira names them (id, name, target status `to`); done(list, problem).
-- An empty list is Jira's answer, not an error. Without PLOTROOM_JIRA_API_TOKEN: an `auth` problem naming the setup.
function M.transitions(key: string, done: ({ Transition }?, Problem?) -> ())
	if badKey(key, done) then
		return
	end
	listed(key, done)
end

-- Applies transition `id` (one M.transitions returned) to `key`; the list is read again first and the id must still be
-- in it. A transition that needs fields (a screen) is refused by Jira and that text is the problem. done(problem).
function M.transition(key: string, id: string, done: (Problem?) -> ())
	local function fail(p: Problem)
		later(function()
			done(p)
		end)
	end
	if type(key) ~= "string" or not string.match(key, KEY) then
		return fail({ kind = "invalid", message = "Unexpected issue key." })
	end
	if type(id) ~= "string" or not string.match(id, "^%d+$") or #id > 10 then
		return fail({ kind = "invalid", message = "Unexpected transition id." })
	end
	listed(key, function(found, problem)
		if not found then
			return done(problem)
		end
		for _, t in found do
			if t.id == id then
				return rest("POST", "/rest/api/3/issue/" .. key .. "/transitions", { transition = { id = id } }, function(_, p)
					done(p)
				end)
			end
		end
		done({ kind = "invalid", message = "Transition " .. id .. " is no longer available for " .. key .. "." })
	end)
end
return M
