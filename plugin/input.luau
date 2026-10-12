--!strict
-- A single-line text model for the picker search and settings rows. Offsets
-- (`cur`, `anchor`) are byte offsets at UTF-8 codepoint boundaries; the SDK
-- wants UTF-16 units for drawn fields, so `props` converts at the edge.

local M = {}

export type Model = {
	text: string,
	cur: number,
	anchor: number?,
	undo: { { text: string, cur: number, anchor: number? } },
}

local UNDO_LIMIT = 50

-- Valid UTF-8 only, line breaks as spaces, other control characters dropped.
function M.clean(s: string): string
	s = string.gsub(s, "\r\n", " ")
	s = string.gsub(s, "[\r\n]", " ")
	local out = {}
	for ch in string.gmatch(s, utf8.charpattern) do
		if utf8.len(ch) ~= nil and string.find(ch, "^[%c]") == nil then
			table.insert(out, ch)
		end
	end
	return table.concat(out)
end

function M.new(text: string): Model
	text = M.clean(text)
	return { text = text, cur = #text, anchor = nil, undo = {} }
end

-- UTF-16 units in the first `bytes` bytes of `text`.
function M.u16(text: string, bytes: number): number
	local n = 0
	for _, c in utf8.codes(string.sub(text, 1, bytes)) do
		n += if c > 0xFFFF then 2 else 1
	end
	return n
end

local function prev(text: string, off: number): number
	if off <= 0 then
		return 0
	end
	return (utf8.offset(text, -1, off + 1) :: number) - 1
end

local function nextOff(text: string, off: number): number
	if off >= #text then
		return #text
	end
	return (utf8.offset(text, 2, off + 1) or #text + 1) - 1
end

function M.selection(m: Model): (number?, number?)
	local a = m.anchor
	if a and a ~= m.cur then
		return math.min(a, m.cur), math.max(a, m.cur)
	end
	return nil, nil
end

function M.selected(m: Model): string
	local lo, hi = M.selection(m)
	if lo and hi then
		return string.sub(m.text, lo + 1, hi)
	end
	return ""
end

local function push(m: Model)
	table.insert(m.undo, { text = m.text, cur = m.cur, anchor = m.anchor })
	if #m.undo > UNDO_LIMIT then
		table.remove(m.undo, 1)
	end
end

-- Replace byte range [lo, hi) with `s` and put the caret after it.
local function splice(m: Model, lo: number, hi: number, s: string)
	push(m)
	m.text = string.sub(m.text, 1, lo) .. s .. string.sub(m.text, hi + 1)
	m.cur = lo + #s
	m.anchor = nil
end

function M.insert(m: Model, s: string)
	s = M.clean(s)
	local lo, hi = M.selection(m)
	if not lo or not hi then
		lo, hi = m.cur, m.cur
	end
	if s == "" and lo == hi then
		return
	end
	splice(m, lo, hi, s)
end

function M.undo(m: Model): boolean
	local last = table.remove(m.undo)
	if not last then
		return false
	end
	m.text, m.cur, m.anchor = last.text, last.cur, last.anchor
	return true
end

-- SDK props for a drawn text field (picker search, settings row): text, UTF-16 cursor and anchor.
function M.props(m: Model): { [string]: any }
	local anchor = m.anchor
	return {
		text = m.text,
		cursor = M.u16(m.text, m.cur),
		anchor = if anchor and anchor ~= m.cur then M.u16(m.text, anchor) else nil,
	}
end

-- Handles one key press; false when the key is not an editing key (so the
-- caller can route Tab/Enter/Escape). `copy` receives text for copy/cut.
function M.key(m: Model, key: Key, copy: (string) -> ()): boolean
	local mod = key.ctrl or key.meta
	local name = key.name
	if name == "paste" then
		M.insert(m, key.text or "")
		return true
	end
	local function move(to: number)
		if key.shift then
			if m.anchor == nil then
				m.anchor = m.cur
			end
		else
			m.anchor = nil
		end
		m.cur = to
	end
	if mod then
		if name == "a" then
			m.anchor, m.cur = 0, #m.text
		elseif name == "c" or name == "x" then
			local sel = M.selected(m)
			if sel == "" then
				return true
			end
			copy(sel)
			if name == "x" then
				M.insert(m, "")
			end
		elseif name == "z" then
			M.undo(m)
		else
			return false
		end
		return true
	end
	local lo, hi = M.selection(m)
	if name == "left" then
		if lo and not key.shift then
			m.cur, m.anchor = lo, nil
		else
			move(prev(m.text, m.cur))
		end
	elseif name == "right" then
		if hi and not key.shift then
			m.cur, m.anchor = hi, nil
		else
			move(nextOff(m.text, m.cur))
		end
	elseif name == "home" then
		move(0)
	elseif name == "end" then
		move(#m.text)
	elseif name == "backspace" then
		if lo and hi then
			splice(m, lo, hi, "")
		elseif m.cur > 0 then
			splice(m, prev(m.text, m.cur), m.cur, "")
		end
	elseif name == "delete" then
		if lo and hi then
			splice(m, lo, hi, "")
		elseif m.cur < #m.text then
			splice(m, m.cur, nextOff(m.text, m.cur), "")
		end
	elseif key.text and key.text ~= "" and string.find(key.text, "^%c") == nil then
		M.insert(m, key.text or "")
	else
		return false
	end
	return true
end

return M
