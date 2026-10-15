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
}
export type Linked = { ref: string, title: string, url: string, state: string, relation: string?, status: { text: string, tone: string }? } -- state "open"|"draft"|"merged"|"closed"|"done"; relation (Jira) "blocks", "is blocked by", "subtask", ...; status (Jira) its workflow status as a badge
export type Field = { label: string, value: string? } -- nil value: shown as None
export type IssueDetail = { body: string, fields: { Field }, linked: { Linked }, comments: number?, created: number?, updated: number? }
export type IssueResult = { issues: { Issue }, total: number, complete: boolean }

-- Name formats (Settings › Repositories): an issue's new branch, and the folder name of a PR's or an issue's worktree.
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

-- Local search over loaded issues: whether `issue` matches, and the matched UTF-16
-- range in its title (nil when the match is elsewhere or the needle is blank).
function M.match(issue: Issue, needle: string): (boolean, { number }?)
	local q = string.lower(string.match(needle, "^%s*(.-)%s*$") or "")
	if q == "" then
		return true, nil
	end
	local at = string.find(string.lower(issue.title), q, 1, true)
	if at then
		return true, { input.u16(issue.title, at - 1), input.u16(issue.title, at - 1 + #q) }
	end
	local hay = M.refLabel(issue.ref) .. " " .. issue.author .. " " .. table.concat(issue.labels, " ") .. " " .. table.concat(issue.assignees, " ")
	return string.find(string.lower(hay), q, 1, true) ~= nil, nil
end

-- Jira's status categories, fixed across every site, in the default sort order: what is being worked on first.
M.CATEGORIES = { "indeterminate", "new", "done" }
M.CATEGORY_LABEL = { indeterminate = "In Progress", new = "To Do", done = "Done" }

-- The status category `issue` sorts under: Jira's own, else open GitHub issues are to do and closed ones done.
function M.category(issue: Issue): string
	return issue.category or (if issue.state == "closed" then "done" else "new")
end

-- Sorts `issues` in place by status category in CATEGORIES order, keeping their order within a category: the
-- tracker's own (Jira: priority, then newest update; GitHub: newest update).
function M.byStatus(issues: { Issue })
	local at: { [Issue]: number } = {}
	for i, issue in issues do
		at[issue] = i
	end
	local function rank(issue: Issue): number
		return table.find(M.CATEGORIES, M.category(issue)) or #M.CATEGORIES + 1
	end
	table.sort(issues, function(a, b)
		local x, y = rank(a), rank(b)
		if x ~= y then
			return x < y
		end
		return at[a] < at[b]
	end)
end

-- Deduplicated by identity, newest update first, identity as the tie-break.
function M.reconcile(issues: { Issue }): { Issue }
	local seen: { [string]: boolean } = {}
	local out: { Issue } = {}
	for _, issue in issues do
		if not seen[issue.key] then
			seen[issue.key] = true
			table.insert(out, issue)
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

return M
