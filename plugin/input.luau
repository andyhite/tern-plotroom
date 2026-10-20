--!strict
-- A text model for the picker search and settings rows: single-line by
-- default, with an opt-in multi-line mode (`multi`) for prompt editors.
-- Offsets (`cur`, `anchor`) are byte offsets at UTF-8 codepoint boundaries; the
-- SDK wants UTF-16 units for drawn fields, so `props` converts at the edge.

local M = {}

export type Model = {
	text: string,
	cur: number,
	anchor: number?,
	undo: { { text: string, cur: number, anchor: number? } },
	multi: boolean?,
}

local UNDO_LIMIT = 50

-- Valid UTF-8 only, other control characters dropped. Line breaks become
-- spaces, or with `multi` are kept as "\n" (and tabs kept).
-- A malformed byte is dropped alone; the valid characters around it stay.
function M.clean(s: string, multi: boolean?): string
	s = string.gsub(s, "\r\n", if multi then "\n" else " ")
	s = string.gsub(s, "[\r\n]", if multi then "\n" else " ")
	if string.find(s, "[%c\128-\255]") == nil then
		return s
	end
	local out: { string } = {}
	local from, i, n = 1, 1, #s
	while i <= n do
		local b = string.byte(s, i)
		local step = 1
		local ok: boolean
		if b < 0x80 then
			ok = (b >= 0x20 and b ~= 0x7F) or (multi == true and (b == 10 or b == 9))
		else
			step = if b >= 0xF0 then 4 elseif b >= 0xE0 then 3 elseif b >= 0xC0 then 2 else 1
			ok = step > 1 and utf8.len(s, i, i) ~= nil
			if not ok then
				step = 1
			end
		end
		if ok then
			i += step
		else
			if from < i then
				table.insert(out, string.sub(s, from, i - 1))
			end
			i += 1
			from = i
		end
	end
	if from <= n then
		table.insert(out, string.sub(s, from))
	end
	return table.concat(out)
end

-- `s` without leading and trailing whitespace.
function M.trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

function M.new(text: string, multi: boolean?): Model
	text = M.clean(text, multi)
	return { text = text, cur = #text, anchor = nil, undo = {}, multi = multi }
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

-- Byte offset of the start / end of the line containing `off`.
local function lineStart(text: string, off: number): number
	while off > 0 and string.byte(text, off) ~= 10 do
		off -= 1
	end
	return off
end

local function lineEnd(text: string, off: number): number
	local i = string.find(text, "\n", off + 1, true)
	return if i then i - 1 else #text
end

-- Offset on the line starting at `ls` (ending at `le`) `col` bytes in, clamped
-- to the line and snapped back to a codepoint boundary.
local function atColumn(text: string, ls: number, le: number, col: number): number
	local to = math.min(ls + col, le)
	while to > ls do
		local b = string.byte(text, to + 1)
		if b == nil or b < 0x80 or b >= 0xC0 then
			break
		end
		to -= 1
	end
	return to
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

local function range(m: Model): (number, number)
	local lo, hi = M.selection(m)
	if lo and hi then
		return lo, hi
	end
	return m.cur, m.cur
end

function M.insert(m: Model, s: string)
	s = M.clean(s, m.multi)
	local lo, hi = range(m)
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

-- Word characters: ASCII letters, digits, underscore, and every non-ASCII
-- byte (so a UTF-8 character is never split). No Unicode tables, by design.
local function isWord(b: number): boolean
	return b >= 0x80 or b == 95 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

-- Byte offset of the start of the word at or before `off`.
local function wordLeft(text: string, off: number): number
	while off > 0 and not isWord(string.byte(text, off)) do
		off -= 1
	end
	while off > 0 and isWord(string.byte(text, off)) do
		off -= 1
	end
	return off
end

-- Byte offset of the end of the word at or after `off`.
local function wordRight(text: string, off: number): number
	local n = #text
	while off < n and not isWord(string.byte(text, off + 1)) do
		off += 1
	end
	while off < n and isWord(string.byte(text, off + 1)) do
		off += 1
	end
	return off
end

-- Handles one key press; false when the key is not an editing key (so the
-- caller can route Tab/Enter/Escape). `copy` receives text for copy/cut.
-- Ctrl or Alt (without Cmd) with left/right/backspace/delete works by word.
function M.key(m: Model, key: Key, copy: (string) -> ()): boolean
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
	local word = (key.ctrl or key.alt) and not key.meta
	local nav = name == "left" or name == "right" or name == "backspace" or name == "delete"
	if (key.ctrl or key.meta) and not (word and nav) then
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
		elseif name == "z" and not key.shift then
			M.undo(m)
		elseif name == "z" then
			return true
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
			move(if word then wordLeft(m.text, m.cur) else prev(m.text, m.cur))
		end
	elseif name == "right" then
		if hi and not key.shift then
			m.cur, m.anchor = hi, nil
		else
			move(if word then wordRight(m.text, m.cur) else nextOff(m.text, m.cur))
		end
	elseif name == "home" then
		move(lineStart(m.text, m.cur))
	elseif name == "end" then
		move(lineEnd(m.text, m.cur))
	elseif m.multi and name == "enter" then
		if key.alt then
			return false
		end
		M.insert(m, "\n")
	elseif m.multi and name == "up" then
		local ls = lineStart(m.text, m.cur)
		if ls == 0 then
			move(0)
		else
			local ps = lineStart(m.text, ls - 1)
			move(atColumn(m.text, ps, ls - 1, m.cur - ls))
		end
	elseif m.multi and name == "down" then
		local le = lineEnd(m.text, m.cur)
		if le >= #m.text then
			move(#m.text)
		else
			move(atColumn(m.text, le + 1, lineEnd(m.text, le + 1), m.cur - lineStart(m.text, m.cur)))
		end
	elseif name == "backspace" then
		if lo and hi then
			splice(m, lo, hi, "")
		elseif m.cur > 0 then
			splice(m, if word then wordLeft(m.text, m.cur) else prev(m.text, m.cur), m.cur, "")
		end
	elseif name == "delete" then
		if lo and hi then
			splice(m, lo, hi, "")
		elseif m.cur < #m.text then
			splice(m, m.cur, if word then wordRight(m.text, m.cur) else nextOff(m.text, m.cur), "")
		end
	elseif key.text and key.text ~= "" and string.find(key.text, "^%c") == nil then
		M.insert(m, key.text)
	else
		return false
	end
	return true
end

return M
