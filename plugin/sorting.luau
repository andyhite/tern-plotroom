--!strict
-- Per-view list order: the choices a view may save (`View.sort`) and the stable sort that applies one. A view without a
-- sort keeps the list order it always had (search order; issues by status category).

local M = {}

export type Choice = { value: string, label: string }

local ALL: { [string]: Choice } = {
	updated = { value = "updated", label = "Recently updated" },
	oldest = { value = "oldest", label = "Oldest waiting" },
	review = { value = "review", label = "Review required first" },
	priority = { value = "priority", label = "Priority" },
}

-- Which sorts mean something for a kind ("prs" | "issues") and integration ("github" | "jira"): Jira keeps no update
-- time in its list rows, and only pull requests carry a review decision.
local OFFERED: { [string]: { string } } = {
	["prs\0github"] = { "updated", "oldest", "review" },
	["issues\0github"] = { "updated", "oldest" },
	["issues\0jira"] = { "priority" },
}

function M.choices(kind: string, integration: string): { Choice }
	local out: { Choice } = {}
	local values: { string } = OFFERED[kind .. "\0" .. integration] or {}
	for _, v in values do
		table.insert(out, ALL[v])
	end
	return out
end

-- Whether `sort` is a sort a view of this kind and integration may save.
function M.valid(kind: string, integration: string, sort: any): boolean
	return type(sort) == "string" and table.find(OFFERED[kind .. "\0" .. integration] or {}, sort) ~= nil
end

-- The label of sort `value` ("Default order" for none).
function M.label(value: string?): string
	local c = if value then ALL[value] else nil
	return if c then c.label else "Default order"
end

local PRIORITY: { [string]: number } = { highest = 1, critical = 1, blocker = 1, high = 2, major = 2, medium = 3, normal = 3, low = 4, minor = 4, lowest = 5, trivial = 5 }

local function rank(item: any, sort: string): number
	if sort == "updated" then
		return -(item.updated or 0)
	elseif sort == "oldest" then
		return item.updated or 0
	elseif sort == "review" then
		return if item.review == "required" then 0 else 1
	end
	local p = if type(item.priority) == "string" then PRIORITY[string.lower(item.priority)] else nil
	return p or 99
end

-- `items` in the order of `sort`, a copy; ties (and every item for an unknown sort) keep the list's order. "review"
-- then orders each half by recent update.
function M.apply(items: { any }, sort: string?): { any }
	local out: { any } = {}
	for _, item in items do
		table.insert(out, item)
	end
	if not sort or not ALL[sort] then
		return out
	end
	local at: { [any]: number } = {}
	for i, item in items do
		at[item] = i
	end
	table.sort(out, function(a: any, b: any): boolean
		local x, y = rank(a, sort), rank(b, sort)
		if x ~= y then
			return x < y
		end
		if sort == "review" and (a.updated or 0) ~= (b.updated or 0) then
			return (a.updated or 0) > (b.updated or 0)
		end
		return at[a] < at[b]
	end)
	return out
end

-- The next sort after `current` among those offered (default order last in the cycle).
function M.cycle(kind: string, integration: string, current: string?): string?
	local list = OFFERED[kind .. "\0" .. integration] or {}
	if #list == 0 then
		return nil
	end
	if not current then
		return list[1]
	end
	local at = table.find(list, current)
	return if at then list[at + 1] else list[1]
end

return M
