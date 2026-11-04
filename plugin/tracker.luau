--!strict
-- Tracker-neutral issue model: the Issue shape every tracker normalizes to, branch
-- naming from a per-repository format, and local matching/ordering of loaded issues.

local input = require("./input")

local M = {}

export type Issue = {
	key: string, -- identity, lowercase project: GitHub "owner/repo#12" (github.identity), Jira "abc#ABC-12"
	tracker: string, -- "github" | "jira"
	repo: string, -- the project: GitHub "Owner/Repo" as GitHub spells it, or a Jira project key "ABC"
	ref: string, -- "12" or "ABC-12": links, {key}, directory names; matches ^[%w_%-]+$
	title: string,
	url: string,
	author: string,
	state: string, -- "open" | "closed"
	reason: string?, -- GitHub, closed: "completed" | "not-planned" | "duplicate"
	status: { text: string, tone: string }?, -- Jira: the workflow status as a badge, toned by its category
	category: string?, -- Jira: the status category key, one of CATEGORIES (GitHub: by state, see category)
	type: string?, -- Jira issue type
	priority: string?, -- Jira priority
	labels: { string },
	assignees: { string },
	comments: number, -- Jira: 0, its count comes with the details
	created: number, -- Jira: 0 (unknown); the details carry it
	updated: number, -- Jira: 0 (unknown); the details carry it
	events: { Event }?, -- GitHub, Now's assigned search only: the newest timeline events, oldest first
}
-- One change to an issue: when (epoch seconds), by which login (nil: unknown or deleted) and, for an assignment, to whom.
export type Event = { at: number, by: string?, to: string? }
export type Linked = { ref: string, title: string, url: string, state: string, relation: string?, status: { text: string, tone: string }? } -- state "open"|"draft"|"merged"|"closed"|"done"; relation (Jira) "blocks", "is blocked by", "subtask", ...; status (Jira) its workflow status as a badge
export type Field = { label: string, value: string? } -- nil value: shown as None
-- One of an item's newest comments, as a Summary reads it: its author and its text (both untrusted, cut short).
export type Comment = { author: string, body: string }
export type IssueDetail = { body: string, fields: { Field }, linked: { Linked }, comments: number?, created: number?, updated: number?, recent: { Comment }? }
export type IssueResult = { issues: { Issue }, total: number, complete: boolean, note: string? }

-- Name formats (Settings › Repositories): an issue's new branch (a default, or per repository), and the folder name of a PR's or an issue's worktree.
-- `{github.user}` is the gh login the repository is worked with, `{jira.user}` the Jira sign-in's email before the `@`.
M.BRANCH_DEFAULT = "{github.user}/{key}-{slug}"
M.VARS = { "key", "slug", "owner", "repo", "project", "github.user", "jira.user" }
-- Worktree folders keep the names of earlier versions by default, so worktrees made then are still found. `{key}` is
-- the PR number or the issue key; `{owner}` and `{repo}` are lowercase there.
M.PR_DIR_DEFAULT = "plotroom-{owner}_{repo}-pr-{key}"
M.ISSUE_DIR_DEFAULT = "plotroom-{owner}_{repo}-issue-{key}"
M.DIR_VARS = { "key", "slug", "owner", "repo" }
-- The detail rows each tracker fills, in order.
M.FIELDS = { github = { "Milestone" }, jira = { "Parent", "Sprint", "Components", "Fix versions" } }

local SLUG_BYTES = 40

-- A title as a branch-name part: lowercase ASCII words joined by "-", at most 40 bytes, "issue" when nothing is left.
function M.slug(title: string): string
	local s = string.gsub(string.lower(title), "[^a-z0-9]+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(string.sub(s, 1, SLUG_BYTES), "%-+$", "")
	return if s == "" then "issue" else s
end

-- A `{name}` variable as formats and prompts spell it: letters, dots between words (`{github.user}`).
M.VAR = "{([%a%.]+)}"

-- Why `fmt` cannot name branches (or, `dir`, worktree folders), or nil.
function M.formatProblem(fmt: string, dir: boolean?): string?
	if string.match(fmt, "^%s*$") then
		return "A format is required."
	end
	local known = if dir then M.DIR_VARS else M.VARS
	for name in string.gmatch(fmt, M.VAR) do
		if not table.find(known, name) then
			return "Unknown variable {" .. name .. "}."
		end
	end
	if dir and string.find(fmt, "/", 1, true) then
		return "A folder name holds no /."
	end
	if not string.find(fmt, "{key}", 1, true) then
		return if dir then "Include {key}, so each worktree gets its own folder." else "Include {key}, so each issue gets its own branch."
	end
	return nil
end

-- The name `fmt` makes of `vars` (a missing one is empty), or nil and why.
function M.render(fmt: string, vars: { [string]: string }, dir: boolean?): (string?, string?)
	local why = M.formatProblem(fmt, dir)
	if why then
		return nil, why
	end
	local name = string.gsub(fmt, M.VAR, function(k: string): string
		return vars[k] or ""
	end)
	return name, nil
end

-- "#12" for a numeric ref, "ABC-12" as is.
function M.refLabel(ref: string): string
	return if string.match(ref, "^%d+$") then "#" .. ref else ref
end

-- Whether `s` is a Jira project key.
function M.jiraProject(s: string): boolean
	return #s <= 32 and string.match(s, "^[A-Z][A-Z0-9_]+$") ~= nil
end

-- Local search: whether a record titled `title` matches `needle` (case-insensitive substring), and the matched UTF-16
-- range in the title (nil when the match is elsewhere or the needle is blank). `hay` is the other text searched,
-- built only when the title misses.
function M.search(title: string, needle: string, hay: () -> string): (boolean, { number }?)
	local q = string.lower(input.trim(needle))
	if q == "" then
		return true, nil
	end
	local at = string.find(string.lower(title), q, 1, true)
	if at then
		return true, { input.u16(title, at - 1), input.u16(title, at - 1 + #q) }
	end
	return string.find(string.lower(hay()), q, 1, true) ~= nil, nil
end

-- Local search over loaded issues: see `search`.
function M.match(issue: Issue, needle: string): (boolean, { number }?)
	return M.search(issue.title, needle, function()
		return M.refLabel(issue.ref) .. " " .. issue.author .. " " .. table.concat(issue.labels, " ") .. " " .. table.concat(issue.assignees, " ")
	end)
end

-- Value at a key path of decoded JSON; nil when a step is missing or not a table.
function M.field(v: any, ...: string): any
	for _, key in { ... } do
		if type(v) ~= "table" then
			return nil
		end
		v = v[key]
	end
	return v
end

function M.nonEmpty(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- `text` cut to `n` characters, `tail` appended when it was cut.
function M.clip(text: string, n: number, tail: string): string
	local cut = utf8.offset(text, n + 1)
	if cut and cut <= #text then
		return string.sub(text, 1, cut - 1) .. tail
	end
	return text
end

-- How much of a description a run's acceptance criteria keep, in characters.
M.CRITERIA_CHARS = 2000

-- `lines` joined, without the blank ones at either end.
local function trimLines(lines: { string }): string
	local first, last = 1, #lines
	while first <= last and not string.find(lines[first], "%S") do
		first += 1
	end
	while last >= first and not string.find(lines[last], "%S") do
		last -= 1
	end
	return table.concat(lines, "\n", first, last)
end

-- The acceptance criteria of an issue of tracker `name` ("github" | "jira") whose description is `body`, as saved on a
-- run at dispatch: a GitHub issue's task-list lines (`- [ ] …`, `1. [x] …`), a Jira description's Acceptance criteria
-- section (from its heading, or a line saying only that, to the next heading as high), else the whole description;
-- cut to CRITERIA_CHARS. "" when the description is empty.
function M.criteria(name: string, body: string): string
	local lines: { string } = {}
	for line in string.gmatch(string.gsub(body, "\r\n?", "\n") .. "\n", "([^\n]*)\n") do
		table.insert(lines, (string.gsub(line, "%s+$", "")))
	end
	local picked: { string } = {}
	if name == "github" then
		for _, line in lines do
			if string.match(line, "^%s*[-*+]%s+%[[ xX]%]") or string.match(line, "^%s*%d+[.)]%s+%[[ xX]%]") then
				table.insert(picked, line)
			end
		end
	else
		local level: number? = nil -- inside the section: the level of its heading (0: a plain line named it)
		for _, line in lines do
			local hashes = string.match(line, "^(#+)%s")
			if level then
				if hashes and (level == 0 or #hashes <= level) then
					break
				end
				table.insert(picked, line)
			else
				local bare = string.lower((string.gsub(string.gsub(line, "^[#%s*_]+", ""), "[%s*_:]+$", "")))
				if bare == "acceptance criteria" then
					level = if hashes then #hashes else 0
				end
			end
		end
	end
	local text = trimLines(picked)
	if text == "" then
		text = trimLines(lines)
	end
	return M.clip(text, M.CRITERIA_CHARS, "\n…")
end

-- Jira's status categories, fixed across every site, in the default sort order: what is being worked on first.
M.CATEGORIES = { "indeterminate", "new", "done" }
M.CATEGORY_LABEL = { indeterminate = "In Progress", new = "To Do", done = "Done" }

-- The status category `issue` sorts under: Jira's own, else open GitHub issues are to do and closed ones done.
function M.category(issue: Issue): string
	return issue.category or (if issue.state == "closed" then "done" else "new")
end

-- Where `issue`'s category falls in CATEGORIES (lower first).
function M.categoryRank(issue: Issue): number
	return table.find(M.CATEGORIES, M.category(issue)) or #M.CATEGORIES + 1
end

-- Sorts `issues` in place by status category in CATEGORIES order, keeping their order within a category: the
-- tracker's own (Jira: priority, then newest update; GitHub: newest update).
function M.byStatus(issues: { Issue })
	local at: { [Issue]: number } = {}
	for i, issue in issues do
		at[issue] = i
	end
	table.sort(issues, function(a, b)
		local x, y = M.categoryRank(a), M.categoryRank(b)
		if x ~= y then
			return x < y
		end
		return at[a] < at[b]
	end)
end

-- Deduplicated by `key`, newest `updated` first, `key` as the tie-break (PRs and issues alike).
function M.reconcile<T>(items: { T }): { T }
	local seen: { [string]: boolean } = {}
	local out: { T } = {}
	for _, item in items do
		local key = (item :: any).key
		if not seen[key] then
			seen[key] = true
			table.insert(out, item)
		end
	end
	table.sort(out, function(a, b)
		local x, y = a :: any, b :: any
		if x.updated ~= y.updated then
			return x.updated > y.updated
		end
		return x.key < y.key
	end)
	return out
end

return M
