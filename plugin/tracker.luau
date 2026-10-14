--!strict
-- Tracker-neutral issue model: the Issue shape every tracker normalizes to, branch
-- naming from a per-repository format, and local matching/ordering of loaded issues.

local input = require("./input")

local M = {}

export type Issue = {
	key: string, -- identity, lowercase "owner/repo#12" (github.identity)
	tracker: string, -- "github"
	repo: string, -- "Owner/Repo" as GitHub spells it
	ref: string, -- "12" (Jira later "ABC-12"): links, {key}, directory names; matches ^[%w%-]+$
	id: string, -- picker id "n" .. ref
	title: string,
	url: string,
	author: string,
	state: string, -- "open" | "closed"
	reason: string?, -- closed: "completed" | "not-planned" | "duplicate"
	labels: { string },
	assignees: { string },
	comments: number,
	created: number,
	updated: number,
}
export type Linked = { ref: string, title: string, url: string, state: string } -- state "open"|"draft"|"merged"|"closed"
export type IssueDetail = { body: string, milestone: string?, linked: { Linked } }
export type IssueResult = { issues: { Issue }, total: number, complete: boolean }

M.FORMAT_DEFAULT = "{key}-{slug}"
M.VARS = { "key", "slug", "owner", "repo" }

local SLUG_BYTES = 40

-- A title as a branch-name part: lowercase ASCII words joined by "-", at most 40 bytes, "issue" when nothing is left.
function M.slug(title: string): string
	local s = string.gsub(string.lower(title), "[^a-z0-9]+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(string.sub(s, 1, SLUG_BYTES), "%-+$", "")
	return if s == "" then "issue" else s
end

-- Why `fmt` cannot name branches, or nil.
function M.formatProblem(fmt: string): string?
	if string.match(fmt, "^%s*$") then
		return "A format is required."
	end
	for name in string.gmatch(fmt, "{(%a+)}") do
		if not table.find(M.VARS, name) then
			return "Unknown variable {" .. name .. "}."
		end
	end
	if not string.find(fmt, "{key}", 1, true) then
		return "Include {key}, so each issue gets its own branch."
	end
	return nil
end

-- The branch `fmt` makes of `vars`, or nil and why.
function M.branchName(fmt: string, vars: { [string]: string }): (string?, string?)
	local why = M.formatProblem(fmt)
	if why then
		return nil, why
	end
	local name = string.gsub(fmt, "{(%a+)}", vars)
	return name, nil
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
	local hay = "#" .. issue.ref .. " " .. issue.author .. " " .. table.concat(issue.labels, " ") .. " " .. table.concat(issue.assignees, " ")
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
