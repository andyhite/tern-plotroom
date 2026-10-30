--!strict
-- The shell lens for `gh pr create` (manifest lens `pr-create`): when the output holds the new pull request's URL, the
-- lens view offers to show it in Plotroom, copy it or open it in the browser; any other output stays raw. Tern lenses
-- only simple commands, never pipelines or redirects.

local core = require("./core")

local ui = tern.ui

type Lens = { url: string? }

local M = {}

-- The last pull request URL on a line: gh prints it last, after any "Creating pull request for …" notice.
function M.urlIn(text: string): string?
	local found: string? = nil
	for url in string.gmatch(text, "https://[%w%.%-]+/[%w%._%-]+/[%w%._%-]+/pull/%d+") do
		found = url
	end
	return found
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
			local items = {
				ui.node("item", { key = "copy", label = "Copy", icon = "copy", href = url, actions = { click = "copy" } }),
				ui.node("item", { key = "browser", label = "Open in browser", icon = "globe", href = url, actions = { click = "open" } }),
			}
			-- Only github.com pull requests parse, so only they can be shown in Plotroom.
			if string.match(url, "^https://github%.com/") then
				table.insert(items, 1, ui.node("item", { key = "show", label = "Show in Plotroom", icon = "merge", href = "plotroom://lens/show/" .. core.pct(url), actions = { click = "open" } }))
			end
			return ui.node("col", { key = "pr" }, {
				ui.node("text", { key = "url", spans = { ui.span(url) } }),
				ui.node("list", { key = "buttons" }, items),
			})
		end,
	}
	tern.lens.define("pr-create", def)
end

return M
