--!strict
-- The shell lenses. `gh pr create` (manifest lens `pr-create`): when the output holds the new pull request's URL, the
-- lens view offers to show it in Plotroom, copy it or open it in the browser. `git push` (manifest lens `git-push`):
-- when GitHub prints its "Create a pull request" line, the view offers that page and Show in Plotroom, which looks the
-- branch's pull request up only when clicked (handlers re-run on rehydration, so they run nothing). Any other output
-- stays raw. Tern lenses only simple commands, never pipelines or redirects.

local core = require("./core")

local ui = tern.ui

type Lens = { url: string? }
-- `pending`: the last line was GitHub's "Create a pull request for '<branch>' on GitHub by visiting:".
type Push = { url: string?, pending: boolean }

local M = {}

-- The last pull request URL on a line: gh prints it last, after any "Creating pull request for …" notice.
function M.urlIn(text: string): string?
	local found: string? = nil
	for url in string.gmatch(text, "https://[%w%.%-]+/[%w%._%-]+/[%w%._%-]+/pull/%d+") do
		found = url
	end
	return found
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
