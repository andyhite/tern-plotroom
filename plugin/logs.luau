--!strict
-- A failing GitHub Actions check's log as `gh run view <run> --log-failed` prints it, cut to the lines worth reading
-- (adopted from tern-pr-guide's src/ci/log.luau and src/ci/actions.luau), the changed-file lines it names, and the
-- `{failures}` prompt block. Pure: the host reads the log and caches what this makes of it.
local input = require("./input")

local M = {}

local BEFORE, AFTER = 12, 3 -- lines kept around each error line
local TAIL = 30 -- lines kept from the end when no line reads as an error
local MAX_LINES = 120 -- log lines kept per job
local LINE_MAX = 300 -- characters of one log line (minified output can be one huge line)
local MAX_REFS = 5

-- One failed job cut down: its log lines with each run left out as a gap line ("… N lines"), and its first error line.
export type Excerpt = { job: string, lines: { string }, first: string? }

-- How a raw log line reads, first match wins: an error line, or not (a step heading that names an error is a heading).
local RULES: { { pattern: string, error: boolean } } = {
	{ pattern = "^##%[error%]", error = true }, -- Actions' own error flag
	{ pattern = "^##%[group%]", error = false }, -- an Actions step
	{ pattern = "^%-%-%- FAIL", error = true }, -- go test
	{ pattern = "^##%[%a+%]", error = false }, -- any other Actions marker
	{ pattern = "%f[%a][Ee]rror[%s:%[]", error = true }, -- Error:, error[E0308], error TS…
	{ pattern = "error TS%d", error = true },
	{ pattern = "FAIL", error = true },
	{ pattern = "Traceback", error = true },
	{ pattern = "panic:", error = true },
	{ pattern = "^%s*●", error = true }, -- jest
	{ pattern = "^E   ", error = true }, -- pytest
	{ pattern = "✕", error = true },
	{ pattern = "✗", error = true },
}

local function isError(text: string): boolean
	for _, rule in RULES do
		if string.find(text, rule.pattern) then
			return rule.error
		end
	end
	return false
end

function M.gap(n: number): string
	return "… " .. n .. (if n == 1 then " line" else " lines")
end

-- The log lines an excerpt entry stands for: a gap line its N, any other line 1.
-- ponytail: a log line that reads exactly "… N lines" counts as a gap; give Excerpt typed gaps if that ever matters.
local function weight(line: string): number
	local n = string.match(line, "^… (%d+) lines?$")
	return if n then tonumber(n) :: number else 1
end

-- Keeps BEFORE lines before and AFTER after each error line, or the last TAIL lines when none reads as one; at most
-- MAX_LINES of them, each run left out marked as a gap.
local function cut(job: string, lines: { string }, errors: { boolean }): Excerpt
	local keep: { boolean } = {}
	local first: string? = nil
	for i in lines do
		if errors[i] then
			first = first or lines[i]
			for k = math.max(1, i - BEFORE), math.min(#lines, i + AFTER) do
				keep[k] = true
			end
		end
	end
	if not first then
		for k = math.max(1, #lines - TAIL + 1), #lines do
			keep[k] = true
		end
	end
	local out: { string } = {}
	local kept, skipped = 0, 0
	for i, line in lines do
		if keep[i] and kept < MAX_LINES then
			if skipped > 0 then
				table.insert(out, M.gap(skipped))
			end
			skipped = 0
			kept += 1
			table.insert(out, line)
		else
			skipped += 1
		end
	end
	if skipped > 0 then
		table.insert(out, M.gap(skipped))
	end
	return { job = job, lines = out, first = first }
end

-- `gh run view --log-failed` prints "job<TAB>step<TAB>timestamp text" per line: one excerpt per job, in log order, with
-- the timestamps, colour codes and CI markers (`##[group]`, `##[error]`) stripped.
function M.parse(stdout: string): { Excerpt }
	local order: { string } = {}
	local byJob: { [string]: { lines: { string }, errors: { boolean } } } = {}
	for raw in string.gmatch(stdout, "[^\n]+") do
		local job, rest = string.match(raw, "^([^\t]*)\t[^\t]*\t(.*)$")
		local text = rest or raw
		text = string.gsub(text, "^\239\187\191", "")
		text = string.gsub(text, "^%d%d%d%d%-%d%d%-%d%dT[%d:%.]+Z ?", "")
		text = string.gsub(text, "\27%[[%d;]*[A-Za-z]", "")
		text = string.gsub(text, "%^%[%[[%d;]*[A-Za-z]", "") -- Actions' logs spell some escapes as a caret: ^[[36;1m
		text = string.gsub(text, "\t", "    ")
		text = input.clean(text)
		if not string.find(text, "##[endgroup]", 1, true) then
			local name = job or ""
			local entry = byJob[name]
			if not entry then
				entry = { lines = {}, errors = {} }
				byJob[name] = entry
				table.insert(order, name)
			end
			local err = isError(text)
			text = string.gsub(text, "^##%[%a+%]", "")
			local cutAt = utf8.offset(text, LINE_MAX + 1)
			if cutAt and cutAt <= #text then
				text = string.sub(text, 1, cutAt - 1) .. "…"
			end
			table.insert(entry.lines, text)
			table.insert(entry.errors, err)
		end
	end
	local out: { Excerpt } = {}
	for _, name in order do
		table.insert(out, cut(name, byJob[name].lines, byJob[name].errors))
	end
	return out
end

-- `path:line` mentions in `lines` that name one of the PR's changed `files`, each once, in log order, at most MAX_REFS.
-- A log path may carry the runner's folder ("/home/runner/work/r/r/src/a.ts"): it names a changed path it ends with.
function M.refs(lines: { string }, files: { string }): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, text in lines do
		for raw, line in string.gmatch(text, "([%w%._%-/]+%.%w+):(%d+)") do
			for _, path in files do
				if #out < MAX_REFS and string.sub(raw, -#path) == path and (#raw == #path or string.sub(raw, -#path - 1, -#path - 1) == "/") then
					local ref = path .. ":" .. (line :: string)
					if not seen[ref] then
						seen[ref] = true
						table.insert(out, ref)
					end
				end
			end
		end
	end
	return out
end

-- One failing check as the `{failures}` block lists it: its excerpt and refs once its log was read, or why there is none.
export type Failure = { name: string, url: string?, lines: { string }?, refs: { string }?, problem: string? }

local OPEN = "<failures>\n"
local CLOSE = "\n</failures>"

local function escape(s: string): string
	return (string.gsub(s, "</(%s*[Ff][Aa][Ii][Ll][Uu][Rr][Ee][Ss])", "</ %1"))
end

-- The `{failures}` block of the checks failing at `head`, at most `cap` bytes: each check gets an equal share of what
-- the headings leave, and an excerpt longer than its share keeps its first lines and marks the rest as a gap. Nothing
-- in a log can close the block or its fence.
function M.block(head: string, failures: { Failure }, cap: number): string
	if #failures == 0 then
		return OPEN .. "None: no check is failing at head " .. head .. "." .. CLOSE
	end
	local intro = "Checks failing at head " .. head .. ", as Plotroom read them from GitHub Actions (`gh run view <run> --log-failed`). Each excerpt keeps the lines around the error lines; `… N lines` marks lines left out.\n"
	local parts: { string } = {}
	local fixed = #OPEN + #intro + #CLOSE
	for i, f in failures do
		local headLines = { "", "## " .. f.name }
		if f.url then
			table.insert(headLines, f.url)
		end
		if f.problem then
			table.insert(headLines, f.problem)
		elseif f.refs and #f.refs > 0 then
			table.insert(headLines, "Changed-file lines it names: " .. table.concat(f.refs, ", "))
		end
		parts[i] = escape(table.concat(headLines, "\n"))
		fixed += #parts[i]
	end
	local FRAME = #"\n```text\n" + #"\n```"
	local room = (cap - fixed) // #failures - FRAME - #M.gap(999999999) -- per excerpt, with the gap that may end it
	local out = { OPEN, intro }
	for i, p in parts do
		table.insert(out, p)
		local lines: { string } = failures[i].lines or {}
		if #lines > 0 and room > 0 then
			local kept: { string } = {}
			local used = 0
			for n, line in lines do
				line = string.gsub(escape(line), "```", "'''")
				if used + #line + 1 > room then
					local left = 0
					for k = n, #lines do
						left += weight(lines[k])
					end
					local last = kept[#kept]
					if last and string.match(last, "^… %d+ lines?$") then -- one gap, never two in a row
						left += weight(last)
						table.remove(kept)
					end
					table.insert(kept, M.gap(left))
					break
				end
				used += #line + 1
				table.insert(kept, line)
			end
			table.insert(out, "\n```text\n" .. table.concat(kept, "\n") .. "\n```")
		end
	end
	table.insert(out, CLOSE)
	return table.concat(out)
end

return M
