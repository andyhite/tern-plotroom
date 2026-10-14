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
	id: string, -- picker id "n" .. ref
	title: string,
	url: string,
	author: string,
	state: string, -- "open" | "closed"
	reason: string?, -- GitHub, closed: "completed" | "not-planned" | "duplicate"
	status: { text: string, tone: string }?, -- Jira: the workflow status as a badge, toned by its category
	type: string?, -- Jira issue type
	priority: string?, -- Jira priority
	labels: { string },
	assignees: { string },
	comments: number, -- Jira: 0, its count comes with the details
	created: number, -- Jira: 0 (unknown); the details carry it
	updated: number, -- Jira: 0 (unknown); the details carry it
}
export type Linked = { ref: string, title: string, url: string, state: string, relation: string? } -- state "open"|"draft"|"merged"|"closed"|"done"; relation (Jira) "blocks", "is blocked by", "subtask", ...
export type Field = { label: string, value: string? } -- nil value: shown as None
export type IssueDetail = { body: string, fields: { Field }, linked: { Linked }, comments: number?, created: number?, updated: number? }
export type IssueResult = { issues: { Issue }, total: number, complete: boolean }

M.FORMAT_DEFAULT = "{key}-{slug}"
M.VARS = { github = { "key", "slug", "owner", "repo" }, jira = { "key", "slug", "project" } }
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

-- Why `fmt` cannot name branches, or nil.
function M.formatProblem(fmt: string, trackerId: string): string?
	if string.match(fmt, "^%s*$") then
		return "A format is required."
	end
	local known = M.VARS[trackerId] or {}
	for name in string.gmatch(fmt, "{(%a+)}") do
		if not table.find(known, name) then
			return "Unknown variable {" .. name .. "}."
		end
	end
	if not string.find(fmt, "{key}", 1, true) then
		return "Include {key}, so each issue gets its own branch."
	end
	return nil
end

-- The branch `fmt` makes of `vars`, or nil and why.
function M.branchName(fmt: string, trackerId: string, vars: { [string]: string }): (string?, string?)
	local why = M.formatProblem(fmt, trackerId)
	if why then
		return nil, why
	end
	local name = string.gsub(fmt, "{(%a+)}", vars)
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
