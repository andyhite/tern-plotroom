--!strict
-- Plotroom's shell lenses. `pr-create` (`gh pr create`): when the output holds the new pull request's URL, the lens
-- view offers to show it in Plotroom, copy it or open it in the browser. `git push` (manifest lens `git-push`): when
-- GitHub prints its "Create a pull request" line, the view offers that page and Show in Plotroom, which looks the
-- branch's pull request up only when clicked. `pr-checks` (`gh pr checks`): gh's checks table as a native table in the
-- preview's check tones. Any other output stays raw. Tern lenses only simple commands, never pipelines or redirects.
-- Lens handlers have no side effects: Tern may run them again to rebuild their state.

local core = require("./core")

local ui = tern.ui

type Lens = { url: string? }
-- `pending`: the last line was GitHub's "Create a pull request for '<branch>' on GitHub by visiting:".
type Push = { url: string?, pending: boolean }

-- One `gh pr checks` row as the terminal shows it.
type Check = { mark: string, name: string, took: string, url: string, href: string? }
-- `at`: the first character of NAME, DESCRIPTION, ELAPSED and URL in gh's header; nil until a header arrives.
-- `open`: rows still belong to the last header.
type Checks = { at: { number }?, open: boolean, rows: { Check } }

-- gh's mark for each check state, read as the preview reads a run's status (core.RUN_TONE). gh marks a cancelled check
-- as it marks a skipped one.
local MARK: { [string]: { status: string, word: string } } = {
	["✓"] = { status = "success", word = "Pass" },
	X = { status = "failure", word = "Fail" },
	["*"] = { status = "pending", word = "Pending" },
	["-"] = { status = "neutral", word = "Skipped" },
}

local M = {}

-- The last pull request URL on a line: gh prints it last, after any "Creating pull request for …" notice.
function M.urlIn(text: string): string?
	local found: string? = nil
	for url in string.gmatch(text, "https://[%w%.%-]+/[%w%._%-]+/[%w%._%-]+/pull/%d+") do
		found = url
	end
	return found
end

-- Characters `from` to `to` (to the end when nil) of `text`, trimmed. gh pads columns in characters and its pass mark
-- is three bytes, so offsets count characters.
-- ponytail: one character per cell; a wide (CJK) check name shifts the columns after it, add a width table if gh prints them.
local function cut(text: string, from: number, to: number?): string
	local a = utf8.offset(text, from)
	if not a or a > #text then
		return ""
	end
	local b = if to then utf8.offset(text, to + 1) else nil
	return (string.gsub(string.sub(text, a, if b then b - 1 else -1), "^%s*(.-)%s*$", "%1"))
end

-- Reads one line of `gh pr checks` as a terminal shows it: a header starts a table (again under `--watch`), a row
-- with a known mark joins it, anything else ends it.
function M.checksLine(state: Checks, text: string, links: { LensLink })
	-- The header is ASCII, so its byte positions are character positions.
	local atName, atDesc, atTook, atUrl = string.match(text, "^%s*()NAME%s+()DESCRIPTION%s+()ELAPSED%s+()URL$")
	if atName and atDesc and atTook and atUrl then
		state.at = { tonumber(atName) :: number, tonumber(atDesc) :: number, tonumber(atTook) :: number, tonumber(atUrl) :: number }
		state.open, state.rows = true, {}
		return
	end
	local at = state.at
	if not at or not state.open then
		return
	end
	local mark, name = cut(text, 1, at[1] - 1), cut(text, at[1], at[2] - 1)
	if not MARK[mark] or name == "" then
		state.open = false
		return
	end
	local url = cut(text, at[4])
	-- A link gh printed wins; a URL the terminal width cut (ending in "...") opens nothing.
	local href = if links[1] then links[1].href elseif string.match(url, "^https://%S+$") and not string.find(url, "...", 1, true) then url else nil
	table.insert(state.rows, { mark = mark, name = name, took = cut(text, at[3], at[4] - 1), url = url, href = href })
end

-- The checks table, or nil (raw output) when no row was read.
function M.checksView(state: Checks): Node?
	if #state.rows == 0 then
		return nil
	end
	local rows: { { Cell } } = {}
	for i, r in state.rows do
		local m = MARK[r.mark]
		rows[i] = {
			{ ui.span(r.name) },
			{ ui.span("● ", core.RUN_TONE[m.status]), ui.span(m.word) },
			{ ui.span(r.took, "num") },
			{ if r.href then ui.link(r.url, r.href) else ui.span(r.url, "muted") },
		}
	end
	return ui.col({
		ui.table({
			{ id = "check", head = "Check", grow = 1 },
			{ id = "status", head = "Status" },
			{ id = "took", head = "Took", align = "end" },
			{ id = "link", head = "Link", grow = 1, truncate = "middle", priority = -1 },
		}, rows),
	})
end

-- GitHub's page for a new pull request from a pushed branch, as `git push` prints it (checked against real pushes):
--   remote: Create a pull request for 'feat/x' on GitHub by visiting:
--   remote:      https://github.com/o/r/pull/new/feat/x
-- Only the line right after the notice counts, so a URL elsewhere in the output is never taken for it.
function M.pushLine(state: Push, text: string)
	local url = if state.pending then string.match(text, "^remote:%s+(https://[%w%.%-]+/[%w%._%-]+/[%w%._%-]+/pull/new/%S+)$") else nil
	state.url = url or state.url
	state.pending = string.match(text, "^remote:%s+Create a pull request for '.+' on GitHub by visiting:$") ~= nil
end

-- Whether Plotroom can show `url` (a /pull/new/ page): a github.com repository and a branch name of plain characters.
-- window.luau's lens route and the host's open-url accept exactly this shape.
function M.showable(url: string): boolean
	return string.match(url, "^https://github%.com/[%w%._%-]+/[%w%._%-]+/pull/new/[%w%._%-/]+$") ~= nil
end

local function showLink(url: string): Node
	return ui.button("Show in Plotroom", { key = "show", size = "sm", icon = "merge", href = "plotroom://lens/show/" .. core.pct(url), actions = { click = "open" } })
end

function M.define()
	local def: LensDef<Lens> = {
		open = function(_run: LensRun, _cx: EffectCx): Lens
			return { url = nil }
		end,
		line = function(state: Lens, l: LensLine)
			state.url = M.urlIn(l.text) or state.url
		end,
		finish = function(state: Lens, status: number)
			if status ~= 0 then
				state.url = nil
			end
		end,
		view = function(state: Lens): Node?
			local url = state.url
			if not url then
				return nil
			end
			local buttons = {
				ui.button("Copy", { key = "copy", size = "sm", icon = "copy", href = url, actions = { click = "copy" } }),
				ui.button("Open", { key = "browser", size = "sm", icon = "globe", href = url, actions = { click = "open" } }),
			}
			-- Only github.com pull requests parse, so only they can be shown in Plotroom.
			if string.match(url, "^https://github%.com/") then
				table.insert(buttons, 1, showLink(url))
			end
			return ui.node("col", { key = "pr" }, {
				ui.node("text", { key = "url", spans = { ui.span(url) } }),
				ui.node("row", { key = "buttons", gap = "sm", wrap = true, align = "center" }, buttons),
			})
		end,
	}
	local checks: LensDef<Checks> = {
		open = function(_run: LensRun, _cx: EffectCx): Checks
			return { at = nil, open = false, rows = {} }
		end,
		line = function(state: Checks, l: LensLine)
			M.checksLine(state, l.text, l.links)
		end,
		-- gh exits 1 with a failing check and 8 with a pending one; the table says which, so the status changes nothing.
		finish = function(_state: Checks, _status: number) end,
		view = M.checksView,
	}
	tern.lens.define("pr-checks", checks)
	tern.lens.define("pr-create", def)
	local push: LensDef<Push> = {
		open = function(_run: LensRun, _cx: EffectCx): Push
			return { url = nil, pending = false }
		end,
		line = function(state: Push, l: LensLine)
			M.pushLine(state, l.text)
		end,
		finish = function(state: Push, status: number)
			if status ~= 0 then
				state.url = nil
			end
		end,
		view = function(state: Push): Node?
			local url = state.url
			if not url then
				return nil
			end
			local buttons = { ui.button("Create pull request", { key = "create", size = "sm", icon = "globe", href = url, actions = { click = "open" } }) }
			if M.showable(url) then
				table.insert(buttons, showLink(url))
			end
			return ui.node("col", { key = "push" }, {
				ui.node("text", { key = "url", spans = { ui.span(url) } }),
				ui.node("row", { key = "buttons", gap = "sm", wrap = true, align = "center" }, buttons),
			})
		end,
	}
	tern.lens.define("git-push", push)
end

return M
