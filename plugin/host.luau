--!strict
-- The Plotroom block: one engine for live GitHub pull request queues and GitHub or Jira issue lists, with saved, editable views of both.

local board = require("./board")
local input = require("./input")
local keys = require("./keys")
local worktree = require("./worktree")
local core = require("./host/core")
local storage = require("./host/storage")
local engine = require("./host/engine")
local render = require("./host/render")
local settings = require("./host/settings")
local requests = require("./host/requests")
local lens = require("./host/lens")

type Note = core.Note
type Prompt = core.Prompt
type Settings = core.Settings
type State = core.State
type View = core.View

local COST_GUESS, DETAIL_DEBOUNCE_MS, KINDS, QUEUE_ID, SETTINGS_ID = core.COST_GUESS, core.DETAIL_DEBOUNCE_MS, core.KINDS, core.QUEUE_ID, core.SETTINGS_ID
local runHrefOf, running, cli = core.runHrefOf, core.running, core.cli
local checkoutOf, isTable, jiraReposOf, kindAndId = storage.checkoutOf, storage.isTable, storage.jiraReposOf, storage.kindAndId
local loadAll, readCheckouts, saveCheckout = storage.loadAll, storage.readCheckouts, storage.saveCheckout
local TERMINAL, accountOf, activeView, alive, cancelDetails = engine.TERMINAL, engine.accountOf, engine.activeView, engine.alive, engine.cancelDetails
local detailKey, ensureCursor, itemOf, moveCursor, moveView = engine.detailKey, engine.ensureCursor, engine.itemOf, engine.moveCursor, engine.moveView
local offered, openItems, openSelected, refresh, retire = engine.offered, engine.openItems, engine.openSelected, engine.refresh, engine.retire
local retry, selected, snapKey, ghActive = engine.retry, engine.selected, engine.snapKey, engine.ghActive
local trim = input.trim
local queueView = render.queueView
local addJira, addRepo, commitEdit, confirmDelete, discardEdit = settings.addJira, settings.addRepo, settings.commitEdit, settings.confirmDelete, settings.discardEdit
local focusRows, openSettings, pressOption, resetRow, rowById = settings.focusRows, settings.openSettings, settings.pressOption, settings.resetRow, settings.rowById
local runAction, runRow, setValue, settingsView, showPage = settings.runAction, settings.runRow, settings.setValue, settings.settingsView, settings.showPage
local preparing, rpc = requests.preparing, requests.rpc

local AGENT_ACTS = { agentgo = true, agentint = true, agentstop = true, agentmsg = true }

-- Runs queue action `act` (keys.ACTIONS' ids but the moves, and `open`) as its key does: false when it is none, or
-- needs a selected item, a tab or an agent the selection lacks.
local function queueAction(state: State, act: string): boolean
	local chosen = selected(state)
	if act == "search" then
		state.query = input.new("")
	elseif act == "help" then
		state.help = true
	elseif act == "refresh" then
		if state.boardOn then
			engine.boardAct(state, "retry")
		else
			retry(state)
		end
	elseif AGENT_ACTS[act] and state.agentsOn then
		engine.agentGo(state, act)
	elseif act == "settings" then
		openSettings(state)
	elseif act == "more" then
		state.cx:open("plotroom://more")
	elseif act == "open" or act == "worktree" or act == "agent" or act == "goto" or AGENT_ACTS[act] then
		-- an agent command needs an agent not exited (Go to agent shows any state it knows)
		if not chosen or (act == "goto" and not openItems(state)[chosen.key]) or (AGENT_ACTS[act] and (state.agents[chosen.key] == nil or (act ~= "agentgo" and state.agents[chosen.key] == "exited"))) then
			return false
		end
		openSelected(state, act, false)
	elseif act == "open-git" then
		return engine.openGit(state)
	elseif string.sub(act, 1, 5) == "copy-" then
		return requests.copy(state, act)
	elseif act == "seen" or act == "snooze" then
		engine.mark(state, act)
	elseif act == "snoozed" or act == "attention" then
		engine.toggle(state, act)
	elseif act == "sort" then
		settings.cycleSort(state)
	elseif string.sub(act, 1, 3) == "wt-" then
		return state.boardOn and engine.boardAct(state, act)
	elseif string.sub(act, 1, 6) == "scope:" then
		return engine.goScope(state, string.sub(act, 7))
	elseif act == "unpin" then
		return requests.unpin(state)
	else
		return false
	end
	return true
end

-- Shows the previewed Inbox notification's pull request or issue in the block, as a linked pull request's row does; a
-- thread that is about neither (CI, a release) says so.
local function openNotice(state: State)
	local row = engine.inboxSelected(state)
	if not row then
		return
	elseif not row.url then
		state.cx:toast("info", "Nothing to show", "That notification is not about a pull request or an issue.")
	else
		requests.show(state, row.url)
	end
end

-- The block: one engine for pull request and issue views alike, each taking its search, details and wording from its kind.
local function blockDef(): BlockDef<State>
	-- The worktree card's helpers (summaryOf to removeNow) live here, not in a host/ layer: they share this block's
	-- scan/status state and are only ever called from the handlers below.
	-- One line for the badges' tooltip on where the worktree of `note` stands (`item`: the listed item it is of); nil
	-- when that cannot be said: its head is unread, or a pull request's head is unknown.
	local function summaryOf(issues: boolean, note: Note, item: any): string?
		local head = note.head
		if not head then
			return nil
		elseif issues then
			return worktree.describeIssue({ created = false, branch = note.branch or "", head = head, dirty = note.dirty })
		end
		local prHead = if item then item.headSha else nil
		if not prHead then
			return nil
		end
		return worktree.describe({ created = false, head = head, prHead = prHead, prRef = item.head, dirty = note.dirty })
	end
	-- Brings the notes into line with what the scans read, `scans[1..count]` (a failed scan is absent): the note of a
	-- worktree that is listed follows its head; a listed worktree of a listed item with no note of it, or only a note of
	-- another worktree, gets one (root, path, branch, ref and, for a pull request, whether it is at the head the last
	-- refresh saw; `dirty` is unread); the ok note of a worktree its checkout no longer lists goes. A report of a worktree
	-- attempt stands until a later scan confirms it: the refresh's head may predate it. A failed attempt's note stays as
	-- it is: it answers the last Worktree press, and it names no worktree to ask git about. true when anything changed.
	-- ponytail: `current` follows the head the last refresh saw, so a pull request pushed since then reads as it was until
	-- the next refresh; a card that must be exact needs the PR read again.
	local function applyScans(state: State, scans: { [number]: worktree.Scan? }, count: number, scanned: string): boolean
		local listed: { [string]: any } = {} -- every item of the scanned kind's lists by key: its freshest listing
		for _, snap in state.snaps do
			if snap.kind == scanned then
				for _, item in snap.items do
					local seen = listed[item.key]
					if not seen or item.updated > seen.updated then
						listed[item.key] = item
					end
				end
			end
		end
		local lists: { [string]: { [string]: worktree.Found } } = {} -- main worktree -> what git lists there
		local pick: { [string]: worktree.Found } = {} -- one worktree per item: the one its note is about, else the first
		for i = 1, count do
			local scan = scans[i]
			if scan then
				lists[scan.root] = scan.found
				for key, f in scan.found do
					local note = state.notes[key]
					if pick[key] == nil or (note ~= nil and note.path == f.path) then
						pick[key] = f
					end
				end
			end
		end
		local changed = false
		for key, note in state.notes do
			local at = if note.ok and note.root then lists[note.root] else nil
			if at and at[key] == nil then
				state.notes[key] = nil
				changed = true
			end
		end
		local now = os.time()
		local saved = readCheckouts()
		-- The repository whose checkout is `root`: the item's own, or for a Jira issue the mapped one saved at `root`.
		local function repoOf(item: any, root: string): string?
			if item.tracker == "jira" then
				for _, code in jiraReposOf(item.repo) do
					if saved[string.lower(code)] == root then
						return code
					end
				end
				return nil
			end
			return item.repo
		end
		for key, f in pick do
			local item = listed[key]
			local note = state.notes[key]
			-- A worktree is of the kind its note says; one with no note yet is of an item of the scanned list.
			local kind = if note then note.kind else scanned
			local issues = kind == "issues"
			local sha: string? = if item and not issues then item.headSha else nil
			if note and note.ok and note.path == f.path then
				local current = if sha then f.head == sha else note.current
				local switched = note.branch ~= f.branch
				local moved = note.git == true and (f.head ~= note.head or current ~= note.current or switched)
				note.git, note.head, note.at, note.branch = true, f.head, now, f.branch
				if moved then
					note.current = current
					if current then
						note.update = {}
					elseif sha then
						note.update = worktree.update({ path = f.path, head = f.head, prHead = sha })
					end
					note.summary = summaryOf(issues, note, item) or note.summary
					changed = true
				end
			elseif item and (not note or note.ok) then
				local current = if sha then f.head == sha else true
				local fresh: Note = {
					seq = state.noteSeq + 1,
					kind = kind,
					at = now,
					ok = true,
					current = current,
					dirty = nil,
					root = f.root,
					repo = repoOf(item, f.root),
					path = f.path,
					branch = f.branch,
					ref = f.ref,
					summary = nil,
					message = nil,
					refused = nil,
					update = if not current and sha then worktree.update({ path = f.path, head = f.head, prHead = sha }) else {},
					git = true,
					head = f.head,
					checked = nil,
					checking = nil,
				}
				fresh.summary = summaryOf(issues, fresh, item)
				state.notes[key] = fresh
				changed = true
			end
		end
		return changed
	end
	-- Scans the checkouts of the shown items (a pull request's repository, an issue's, a Jira project's repositories:
	-- the saved checkout of each) with one `worktree list` apiece and applies what they read. Idempotent, as every render
	-- asks: it runs for a snapshot it has not scanned yet, or when `state.scanned` was reset (a worktree attempt, a
	-- removal, a checkout saved), one at a time. A scan that failed changes nothing, and so does one that a note changed
	-- under: it may predate that attempt or removal, so it is dropped and made again.
	local scanWorktrees: (State) -> ()
	scanWorktrees = function(state: State)
		local snap = state.snap
		if not snap or state.scanning or state.scanned == snap or not alive(state) then
			return
		end
		state.scanned = snap
		local issues = snap.kind == "issues"
		local paths: { string } = {}
		local wants: { [string]: { [string]: worktree.Want } } = {} -- checkout -> item key -> how its worktree is known
		local saved = readCheckouts() -- one read, not one per repository
		for _, item in snap.items do
			local codes: { string } = if issues and item.tracker == "jira" then jiraReposOf(item.repo) else { item.repo }
			for _, code in codes do
				local path = saved[string.lower(code)]
				if type(path) == "string" and path ~= "" then
					if not wants[path] then
						wants[path] = {}
						table.insert(paths, path)
					end
					wants[path][item.key] = engine.worktreeWant(state, snap.kind, item, { code })
				end
			end
		end
		if #paths == 0 then
			return
		end
		-- A noted worktree is still known by what it was in its own checkout, though its item left the list or a format
		-- changed since.
		for key, note in state.notes do
			local root = note.root
			if note.ok and note.branch and note.path and root and wants[root] then
				local w = wants[root][key] or { branches = {}, dirs = {}, ref = note.ref }
				table.insert(w.branches, note.branch)
				table.insert(w.dirs, string.match(note.path, "([^/]+)/*$") or "")
				wants[root][key] = w
			end
		end
		state.scanning = true
		local rev = state.noteSeq
		local scans: { [number]: worktree.Scan? } = {}
		-- One checkout at a time: a list of many repositories must not start a git process for each at once.
		local function step(i: number)
			if i <= #paths and alive(state) then
				local once = false
				worktree.scan(paths[i], wants[paths[i]], function(scan)
					if not once then
						once = true
						scans[i] = scan -- nil for a scan that failed
						step(i + 1)
					end
				end)
				return
			end
			state.scanning = false
			if not alive(state) then
				return
			end
			if state.noteSeq ~= rev then
				state.scanned = nil
			elseif applyScans(state, scans, #paths, snap.kind) then
				state.noteSeq += 1
				state.cx:render()
			end
			scanWorktrees(state) -- the shown snapshot may have changed meanwhile
		end
		step(1)
	end
	-- Reads `git status` of the selected item's worktree once the cursor has rested on it (never one per row), and
	-- again after each refresh: the card's Clean / Uncommitted changes badge and the row's tone follow. Idempotent: every
	-- render asks.
	local function inspectSelected(state: State)
		local item = selected(state)
		local note = if item then state.notes[item.key] else nil
		local path = if note then note.path else nil
		if not item or not note or not note.ok or not path or note.checking or note.checked == state.round then
			return
		end
		local key, round = item.key, state.round
		note.checking = true
		tern.timer(DETAIL_DEBOUNCE_MS, function()
			local at = selected(state)
			if not alive(state) or state.notes[key] ~= note or not at or at.key ~= key then
				note.checking = nil
				return -- the cursor moved on or the note went: a render asks again if it still matters
			end
			worktree.status(path, function(status)
				note.checking = nil
				note.checked = round
				if not alive(state) or state.notes[key] ~= note or status == nil or (status.dirty == note.dirty and status.ahead == note.ahead) then
					return
				end
				note.dirty = status.dirty
				note.ahead = status.ahead
				note.summary = summaryOf(note.kind == "issues", note, item) or note.summary
				state.noteSeq += 1
				state.cx:render()
			end)
		end)
	end
	-- The card's Remove worktree: asks first (a confirm overlay), and not while the worktree is being prepared or removed.
	local function askRemove(state: State)
		local chosen = selected(state)
		local note = if chosen then state.notes[chosen.key] else nil
		if not chosen or not note or not note.ok then
			return
		end
		if preparing[chosen.key] then
			return state.cx:toast("info", "Worktree is busy", "Plotroom is still working on it; try again in a moment.")
		end
		local key = chosen.key
		state.removing, state.removeFate, state.removeRefusal = key, nil, nil
		-- The confirm says exactly what becomes of the branch, from git's own list now (removal re-reads it again).
		local root, repo, path, branch = note.root, note.repo, note.path, note.branch
		if not root or not repo or not path then
			state.removeRefusal = "Plotroom cannot tell which repository this worktree belongs to, so removal will be refused."
			state.cx:render()
			return
		end
		worktree.inventory(root, repo, function(entries, why)
			if not alive(state) or state.removing ~= key then
				return
			end
			local refusal: string? = if why then why:gsub("%s*%.?$", ".") else "Git no longer lists this worktree."
			local listed: { worktree.Entry } = entries or {}
			for _, e in listed do
				if e.path == path and e.branch == branch then
					state.removeFate = board.fate(e)
					refusal = nil
				end
			end
			state.removeRefusal = refusal
			state.cx:render()
		end)
	end
	-- Removes the worktree whose removal was confirmed, on this host where git runs (never in a window). A removal drops
	-- the note in every block of this host, and the row's Worktree badge with it; a refusal keeps the note, with the
	-- reason on its card. Either way the next render scans the checkouts again, so git has the last word.
	local function removeNow(state: State)
		local key = state.removing
		state.removing = nil
		local note = if key then state.notes[key] else nil
		if not key or not note or not note.ok then
			return
		end
		local root, repo, path, branch = note.root, note.repo, note.path, note.branch
		if not root or not repo or not path then
			local why = "Plotroom cannot tell which repository this worktree belongs to; remove it with git."
			note.refused = why
			state.noteSeq += 1
			state.cx:toast("error", "Worktree not removed", why)
			state.cx:render()
			return
		end
		if preparing[key] then
			return state.cx:toast("info", "Worktree is busy", "Plotroom is still working on it; try again in a moment.")
		end
		preparing[key] = true
		state.cx:toast("info", "Removing the worktree of " .. key .. "…")
		worktree.removeEntry(root, repo, path, branch, function(removal, why, dirty)
			preparing[key] = nil
			if not alive(state) then
				return
			end
			if removal then
				for _, s in running do
					if s.notes[key] then
						s.notes[key] = nil
						s.noteSeq += 1
						s.scanned = nil
						if s ~= state and alive(s) then
							s.cx:render()
						end
					end
				end
				state.cx:toast("success", "Worktree removed", removal.branch)
			else
				note.refused = why
				if dirty then
					note.dirty = true
				end
				state.cx:toast("error", "Worktree not removed", why)
			end
			state.noteSeq += 1 -- the picker's cached rows carry the Worktree badge
			state.scanned = nil
			state.cx:render()
		end)
	end
	return {
		init = function(cx: BlockCx, args: { string }, saved: any): State
			local cwd: string? = nil
			local from: { any } = { if isTable(saved) then saved.launchCwd else nil, args[1], cx.cwd }
			for _, c in from do
				if type(c) == "string" and c ~= "" and tern.fs.exists(c) then
					cwd = c
					break
				end
			end
			local previous = running[cx.pane]
			if previous and previous.launchCwd == cwd and alive(previous) then
				-- The runtime re-runs init on every settings reload (observed every 7-15 s).
				-- Keep the live state: a fresh one would restart the GitHub search each time, flashing the spinner/card.
				previous.cx = cx
				return previous
			end
			if previous then
				retire(previous)
			end
			-- State saved by another Plotroom version is ignored: a fresh start.
			local mine = isTable(saved) and saved.version == 2
			-- The saved view id is the view's own in its kv store (the pin's is "pin"); `activeKind` says which store: what
			-- the older PR block saved has none, and anything but "issues" is a pull request view.
			local active: string? = nil
			if mine and type(saved.activeViewId) == "string" then
				local own: string = saved.activeViewId
				-- A pin's id is its own ("pin:<key>"; an older save's "pin" is its one pin).
				active = if string.sub(own, 1, 3) == "pin" then own else (if saved.activeKind == "issues" then "issues" else "prs") .. ":" .. own
			end
			local sp: { kind: string, message: string, by: string? }? = nil
			if mine and isTable(saved.pause) and saved.launchCwd == cwd then
				local k, m = saved.pause.kind, saved.pause.message
				if type(m) == "string" and (k == "auth" or k == "missing" or k == "not-found" or k == "invalid") then
					local by = saved.pause.by
					sp = { kind = k :: string, message = m, by = if by == "github" or by == "jira" then by :: string else nil }
				end
			end
			-- The pins restored are in the sidebar's Pins group; a pin that is the scope shown opens on its item (ensureCursor).
			local pins: { View } = {}
			local function addSaved(url: any)
				local p = engine.pinView(url)
				if p and #pins < engine.PIN_CAP and not engine.pinFor(pins, engine.pinKey(p)) then
					table.insert(pins, p)
				end
			end
			if mine then
				if isTable(saved.pins) then
					for _, u in saved.pins do
						addSaved(u)
					end
				end
				addSaved(saved.pin) -- an older save's one pin
			else
				addSaved(args[2])
			end
			local state: State = {
				cx = cx,
				kind = KINDS.prs,
				launchCwd = cwd,
				activeId = active,
				views = {},
				locked = {},
				-- A block launched to show one item (window.luau's `showPr`) starts on it.
				pins = pins,
				snaps = {},
				snap = nil,
				cursor = nil,
				focus = "list",
				inflight = nil,
				gen = 0,
				account = "",
				tracker = "github",
				applied = nil,
				cost = COST_GUESS,
				interval = nil,
				nextAt = nil,
				problem = if sp then { kind = sp.kind, message = sp.message } else nil,
				problemBy = if sp then sp.by else nil,
				timer = nil,
				query = nil,
				help = false,
				vis = nil,
				details = {},
				detailFail = {},
				detailBusy = {},
				detailAttempt = nil,
				round = 0,
				notes = {},
				descOpen = nil,
				removing = nil,
				removeFate = nil,
				removeRefusal = nil,
				noteSeq = 0,
				scanned = nil,
				scanning = false,
				settings = nil,
				replies = {},
				listing = 0,
				rev = 0,
				triage = nil,
				triageProblem = nil,
				showSnoozed = false,
				attention = false,
				agents = {},
				agentInfo = {},
				agentsOn = false,
				agentAt = nil,
				inboxOn = false,
				inboxAt = nil,
				inbox = { login = nil, rows = {}, problem = nil, busy = false, loaded = false, gen = 0 },
				plan = nil,
				draft = nil,
				imported = nil,
				exported = nil,
				board = board.new(),
				boardOn = false,
				boardRemoving = nil,
				boardBusy = false,
			}
			loadAll(state)
			if state.activeId == "pin" then
				state.activeId = if pins[1] then pins[1].id else nil
			end
			if pins[1] and not mine then
				state.activeId, state.cursor = pins[1].id, engine.pinKey(pins[1])
			elseif not activeView(state) and cli.ready() then
				state.activeId = if state.views[1] then state.views[1].id else nil
			end
			-- What the first scope runs as is the identity from the start, so a restored pause survives identify. A saved
			-- login the view no longer lists falls back to the view's first. Before the CLIs answered no view is listed: the
			-- restored one and its login are kept for when it is.
			local picked = if mine and type(saved.activeLogin) == "string" then saved.activeLogin else nil
			local first = activeView(state)
			state.activeLogin = picked
			if first then
				state.activeLogin = if #first.logins > 1 then accountOf(first, picked) else nil
				state.kind = KINDS[first.kind]
				state.account, state.tracker, state.applied = accountOf(first, state.activeLogin), first.integration, snapKey(first, state.activeLogin)
			end
			running[cx.pane] = state
			engine.probeClis() -- the first block of this runtime: its views are listed once the CLIs answer
			if cwd then
				-- Launching inside a checkout maps its repository to it, unless it has one already.
				worktree.currentRepository(cwd, function(found)
					if found and alive(state) and checkoutOf(found.id) == nil then
						saveCheckout(found.id, found.checkout)
						-- A checkout that is new may already hold worktrees, and the first refresh may have landed without it.
						state.scanned = nil
						scanWorktrees(state)
					end
				end)
			end
			ghActive.note(state)
			refresh(state)
			return state
		end,

		title = function(state: State): string?
			local snap = state.snap
			local v = activeView(state)
			if not v then
				return "Plotroom"
			end
			local need = 0
			if snap then
				for _, item in snap.items do
					if engine.needs(state, snap.kind, item) then
						need += 1
					end
				end
			end
			return "Plotroom · " .. v.name .. (if snap then " (" .. #snap.items .. ")" else "") .. (if need > 0 then " · " .. need .. " new" else "")
		end,

		view = function(state: State, _cx: BlockCx): BlockView
			engine.boardScan(state)
			ensureCursor(state)
			engine.autoSeen(state)
			scanWorktrees(state)
			inspectSelected(state)
			return if state.settings then settingsView(state) else queueView(state)
		end,

		key = function(state: State, key: Key, cx: BlockCx): boolean?
			local plain = not (key.ctrl or key.alt or key.meta)
			local name = key.name
			local k = key.text or name
			local s = state.settings
			if state.removing and not state.notes[state.removing] then
				state.removing = nil -- its note was evicted: nothing left to ask about
			end
			if state.removing and not s then
				-- Like a delete: Enter keeps the worktree, only a deliberate `d` or a click removes it.
				if name == "enter" or name == "escape" then
					state.removing = nil
				elseif plain and k == "d" then
					removeNow(state)
				else
					return false
				end
				return true
			end
			if state.help then
				if name == "escape" or name == "enter" or (plain and keys.action((keys.load()), k) == "help") then
					state.help = false
					return true
				end
				return false
			end
			if s then
				local e = s.edit
				if e and string.match(e.row, "^p?key:") then
					-- A shortcut row takes the next key as the shortcut: Backspace or Delete removes it, Esc or Enter keeps it.
					if name == "escape" or name == "enter" then
						discardEdit(state)
					elseif name == "backspace" or name == "delete" then
						e.model = input.new("")
						commitEdit(state)
					elseif plain and key.text and key.text ~= "" then
						-- Checked before commitEdit, which trims: a Space would otherwise save as no shortcut.
						local bad = keys.shape(key.text)
						if bad then
							s.errors[e.row] = bad
						else
							e.model = input.new(key.text)
							commitEdit(state)
						end
					end
					return true
				elseif e then
					if name == "escape" then
						discardEdit(state)
					elseif name == "enter" and (not e.model.multi or key.meta or key.ctrl) then
						commitEdit(state)
					elseif not input.key(e.model, key, function(t)
						cx:copy(t)
					end) then
						return false
					end
					return true
				end
				local pick = s.pick
				local pdef = if pick then rowById(state, pick.row) else nil
				if pick and pdef then
					local c = pdef.control
					-- A choice's menu runs down the sheet, chips across it.
					local vertical = c.k == "choice" and (name == "up" or name == "down")
					if name == "left" or name == "right" or vertical then
						local list: { any } = {}
						for _, o in c.options do
							table.insert(list, o.value)
						end
						local at = table.find(list, pick.option) or 0
						local back = name == "left" or name == "up"
						pick.option = list[math.clamp(at + (if back then -1 else 1), 1, math.max(#list, 1))]
						return true
					elseif (name == "enter" or name == "space") and pick.option then
						pressOption(state, pick.row, pick.option)
						return true
					elseif name == "escape" then
						s.pick = nil
						return true
					end
				end
				s.pick = nil -- any other key leaves the chips
				if name == "escape" then
					state.settings = nil
				elseif name == "tab" and plain then
					local pages = cli.pages()
					local at = 1
					for i, p in pages do
						if p.id == s.page then
							at = i
						end
					end
					showPage(state, s, pages[((at - 1 + (if key.shift then -1 else 1)) % #pages) + 1].id)
				elseif plain and keys.action((keys.load()), k) == "help" then
					state.help = true
				elseif name == "up" or name == "down" then
					local rows = focusRows(state)
					if #rows == 0 then
						return false
					end
					local at = if s.focus then table.find(rows, s.focus) else nil
					local down = name == "down"
					s.focus = rows[if at then math.clamp(at + (if down then 1 else -1), 1, #rows) elseif down then 1 else #rows]
				elseif name == "enter" or name == "space" then
					runRow(state, s.focus)
				else
					return false
				end
				return true
			end

			-- The Worktrees board and the Agents scope share their list keys: the rows move with the arrows, Page Up/Down and Home/End,
			-- and Enter runs `enter`. `extra` answers the keys only that list has.
			local function listKeys(move: (number) -> (), enter: () -> (), extra: (string?) -> boolean): boolean
				local onScopes = state.focus == "scopes"
				local lact = if plain then keys.action((keys.load()), k) else nil
				if name == "tab" and plain then
					state.focus = if onScopes then "list" else "scopes"
				elseif name == "escape" then
					if onScopes then
						state.focus = "list"
					else
						return false
					end
				elseif name == "up" or lact == "up" or name == "down" or lact == "down" then
					local d = if name == "up" or lact == "up" then -1 else 1
					if onScopes then
						moveView(state, d)
					else
						move(d)
					end
				elseif name == "page_up" or name == "page_down" then
					move(if name == "page_up" then -10 else 10)
				elseif name == "home" or name == "end" then
					local d = if name == "home" then -100000 else 100000
					if onScopes then
						moveView(state, d)
					else
						move(d)
					end
				elseif name == "enter" then
					if onScopes then
						state.focus = "list"
					else
						enter()
					end
				elseif lact == "refresh" or lact == "settings" or lact == "help" or lact == "more" then
					queueAction(state, lact)
				elseif not extra(lact) then
					return false
				end
				return true
			end

			if state.boardOn then
				-- The Worktrees board: Enter opens a row; cleanup and removal are the keys bound to them.
				if state.boardRemoving or state.boardFinished then
					if name == "enter" or name == "escape" then
						engine.boardAct(state, "wt-cancel-remove")
					elseif plain and k == "d" then
						engine.boardAct(state, "wt-confirm-remove")
					else
						return false
					end
					return true
				end
				return listKeys(function(d)
					engine.boardMove(state, d)
				end, function()
					engine.boardAct(state, "wt-open")
				end, function(a)
					if a == "wt-cleanup" or a == "wt-remove" then
						engine.boardAct(state, a)
						return true
					end
					return false
				end)
			end
			if state.agentsOn then
				-- The Agents scope: Enter goes to the agent's tab.
				return listKeys(function(d)
					engine.agentMove(state, d)
				end, function()
					engine.agentGo(state)
				end, function(a)
					if a == "agentgo" then
						engine.agentGo(state)
						return true
					end
					return false
				end)
			end
			if state.inboxOn then
				-- The Inbox list: Enter shows the notification's pull request or issue.
				return listKeys(function(d)
					engine.inboxMove(state, d)
				end, function()
					openNotice(state)
				end, function()
					return false
				end)
			end
			local searching = state.query ~= nil
			local scopes = state.focus == "scopes"
			-- The queue action the key is (Settings › Keyboard shortcuts). While searching it is text, and with ctrl, alt or meta it is no shortcut.
			local act = if plain and not searching and name ~= "paste" then keys.action((keys.load()), k) else nil
			-- A saved action's own key beats the newer built-in shortcuts: it was its key before they existed.
			if act == "agentgo" or act == "seen" or act == "snooze" or act == "snoozed" or act == "attention" or act == "sort" or act == "more" then
				local owned: { { prompt: Prompt, here: boolean } } = {}
				local here = false
				if selected(state) then
					owned = offered(state)
				end
				for _, o in owned do
					here = here or o.prompt.key == k
				end
				if here then
					act = nil
				end
			end
			if name == "tab" and plain then
				state.focus = if scopes then "list" else "scopes"
			elseif name == "escape" then
				local q = state.query
				if q then
					state.query = if q.text ~= "" then input.new("") else nil
					ensureCursor(state)
				elseif scopes then
					state.focus = "list"
				else
					return false
				end
			elseif name == "up" or act == "up" then
				if scopes then
					moveView(state, -1)
				else
					moveCursor(state, -1)
				end
			elseif name == "down" or act == "down" then
				if scopes then
					moveView(state, 1)
				else
					moveCursor(state, 1)
				end
			elseif name == "page_up" or name == "page_down" then
				moveCursor(state, if name == "page_up" then -10 else 10)
			elseif not searching and (name == "home" or name == "end") then
				local d = if name == "home" then -100000 else 100000
				if scopes then
					moveView(state, d)
				else
					moveCursor(state, d)
				end
			elseif name == "enter" then
				if scopes then
					state.focus = "list"
				else
					openSelected(state, "open", false)
				end
			elseif name == "paste" and not searching then
				requests.paste(state, key.text or "")
			elseif state.query then
				local q = state.query
				local before = q.text
				if not input.key(q, key, function(t)
					cx:copy(t)
				end) then
					return false
				end
				if q.text ~= before then
					ensureCursor(state)
				end
			elseif act and queueAction(state, act) then
				-- the key's queue action ran
			else
				-- A saved prompt's own key runs it, through its button's link (the window honours only links shown).
				local chosen = selected(state)
				local hit: Prompt? = nil
				local list: { { prompt: Prompt, here: boolean } } = if plain and chosen then offered(state) else {}
				for _, o in list do
					if o.prompt.key == k and string.match(o.prompt.id, "^%w+$") then
						hit = o.prompt
					end
				end
				if not chosen or not hit then
					return false
				end
				state.cx:open(runHrefOf(state, chosen, hit.id))
			end
			return true
		end,

		event = function(state: State, ev: UiEvent, _cx: BlockCx)
			if not alive(state) then
				return
			end
			local s = state.settings
			local act = if ev.ev == "action" and type(ev.act) == "string" then ev.act else nil
			local item = if type(ev.item) == "string" then ev.item else nil
			-- Ends the single-line edit in progress (none: true): saves it, drops an empty draft or a shortcut being captured,
			-- and is false when a refused draft stays open with its warning. The prompt editor card stays open.
			local function leaveEdit(s: Settings): boolean
				local e = s.edit
				if not e or e.model.multi then
					return true
				end
				local capture = string.match(e.row, "^p?key:") ~= nil
				if not capture then
					commitEdit(state)
				end
				if s.edit and not capture and trim(s.edit.model.text) ~= "" then
					return false
				end
				discardEdit(state)
				return true
			end
			if act == "retry-checks" then
				local chosen = selected(state)
				local key = if chosen then detailKey(state, chosen) else nil
				if key then
					state.detailFail[key] = nil
					cancelDetails(state)
				end
			elseif act == "rpc" then
				rpc(state, ev.value)
			elseif act == "show-pr" then
				requests.show(state, ev.value)
			elseif act == "agent-status" then
				engine.agentStatus(state, ev.value)
			elseif act == "triage" then
				engine.triageEvent(state, ev.value)
			elseif act == "sort" then
				settings.cycleSort(state)
			elseif act == "open-worktrees" then
				engine.openBoard(state)
			elseif act and string.sub(act, 1, 3) == "wt-" then
				engine.boardAct(state, act)
			elseif act == "add-repo" and ev.id ~= SETTINGS_ID then
				addRepo(state, ev.value)
			elseif act == "add-jira" and ev.id ~= SETTINGS_ID then
				addJira(state, ev.value)
			elseif act == "fold-description" then
				state.descOpen = nil
			elseif ev.ev == "toggle" and ev.key == "description" then
				local chosen = selected(state)
				state.descOpen = if chosen and ev.collapsed == false then chosen.key else nil
			elseif act == "close-help" then
				state.help = false
			elseif act == "confirm-delete" or act == "cancel-delete" then
				-- The window palette's answer, acted on only for the row this block asked about.
				if s and s.confirm and s.confirm == ev.value then
					if act == "confirm-delete" then
						confirmDelete(state)
					else
						s.confirm = nil
					end
				end
			elseif act == "remove-worktree" then
				-- Its question is a modal over the queue, which Settings' sheet does not draw: Settings closes first.
				if s then
					discardEdit(state)
					state.settings = nil
				end
				askRemove(state)
			elseif act == "confirm-remove" then
				if state.removing then
					removeNow(state)
				end
			elseif act == "cancel-remove" then
				state.removing = nil
			elseif act == "goto" or act == "worktree" or act == "open-git" then
				-- The worktree card's rows and the action bar's buttons alike: a click in the preview carries the row's own id.
				queueAction(state, act)
			elseif act == "unpin" then
				requests.unpin(state)
			elseif act == "queue" then
				-- The command palette's pick: only an action it offers now runs.
				for _, a in requests.paletteActions(state) do
					if a.id == ev.value then
						queueAction(state, a.id)
					end
				end
			elseif act == "save-prompt" or act == "cancel-prompt" then
				-- The editor card's buttons: their own ids, not the prefs node's.
				if s and act == "save-prompt" then
					commitEdit(state)
				elseif s then
					discardEdit(state)
				end
			elseif s and ev.id == SETTINGS_ID then
				-- A click on another row or button (a menu, a field, Done, Delete...) first saves the line being typed:
				-- a refused draft keeps its row open with the warning, an empty one (a new view's untouched name) is
				-- dropped, and so is a shortcut being captured. A menu option under the pointer ("<row>=<value>") is no
				-- click.
				local e = s.edit
				local target: string? = if ev.ev == "action" and act ~= "page" and act ~= "close" and type(ev.value) == "string"
					then ev.value
					elseif ev.ev ~= "action" and item and not string.find(item, "=", 1, true) then item
					else nil
				if e and target and target ~= e.row and not leaveEdit(s) then
					return
				end
				if act == "page" then
					for _, p in cli.pages() do
						if p.id == ev.value then
							showPage(state, s, p.id)
						end
					end
				elseif act == "close" then
					discardEdit(state)
					if ev.value == nil then
						state.settings = nil
					else
						s.pick = nil -- a click outside an open choice's menu, or away from a text being edited
					end
				elseif act == "add" or act == "add-prompt" or act == "restore-prompts" or act == "restore-views" or act == "edit-prompt" or act == "delete" or act == "refresh" or act == "add-repo" or act == "add-jira" or act == "guide" or act == "expand" or act == "collapse" then
					if type(ev.value) == "string" then
						s.focus = ev.value
						runAction(state, act, ev.value)
					end
				elseif ev.ev == "activate" and item then
					runRow(state, item) -- a click on a text field or a choice's popup
				elseif ev.ev == "select" and item then
					-- The pointer on an open menu's option ("<row>=<value>") moves the keys' highlight there; a click on a row
					-- off its control focuses it.
					local menu, option = string.match(item, "^(.-)=(.*)$")
					if menu and s.pick and s.pick.row == menu then
						s.pick.option = option
					elseif not menu then
						s.focus, s.pick = item, nil
					end
				elseif ev.ev == "change" and item and (ev.value == nil or ev.value == tern.json.null) then
					resetRow(state, item)
				elseif ev.ev == "change" and item then
					s.focus = item
					if type(ev.value) == "string" then
						s.pick = nil -- a choice made closes its menu
					end
					setValue(state, item, ev.value)
				end
			elseif ev.id == QUEUE_ID then
				-- The queue beside Settings' sheet takes clicks too (its keys stay Settings'): one first ends the line
				-- being typed, as a click on another Settings row does.
				if s and s.edit then
					leaveEdit(s)
				end
				if ev.ev == "select" or ev.ev == "activate" then
					if state.inboxOn then
						-- The Inbox list's rows are not the queue's items either.
						for _, r in engine.inboxRows(state) do
							if item and engine.inboxId(r) == item then
								state.inboxAt, state.focus = r.id, "list"
								if ev.ev == "activate" then
									openNotice(state)
								end
							end
						end
						return
					end
					if state.agentsOn then
						-- The Agents scope's rows are not the queue's items either.
						for _, r in engine.agentRows(state) do
							if item and engine.pickerId("g", r.key) == item then
								state.agentAt, state.focus = r.key, "list"
								if ev.ev == "activate" then
									engine.agentGo(state)
								end
							end
						end
						return
					end
					if state.boardOn then
						-- The Worktrees board's rows are not the queue's items.
						local row: any = nil
						for _, r in engine.boardRows(state) do
							if item and engine.pickerId("w", r.id) == item then
								row = r
							end
						end
						if row then
							engine.boardPick(state, row)
							state.focus = "list"
							if ev.ev == "activate" then
								engine.boardAct(state, "wt-open")
							end
						end
						return
					end
					local picked = if item then itemOf(state, item) else nil
					if not picked then
						return -- a refresh replaced the snapshot
					end
					engine.select(state, picked.key)
					state.focus = "list"
					if ev.ev == "activate" then
						openSelected(state, "open", true)
					end
				elseif act == "scope" then
					state.focus = "list"
					engine.goScope(state, ev.value)
				elseif act == "clear" or act == "close" then
					state.query = nil
					ensureCursor(state)
				elseif act == "settings" then
					-- Settings' own button: opens Settings, or closes the sheet it sits beside.
					if s then
						discardEdit(state)
						state.settings = nil
					else
						openSettings(state)
					end
				elseif act == "retry" then
					queueAction(state, "refresh")
				elseif act then
					-- An item's button in the action bar, or the command palette's: runs as its key does.
					queueAction(state, act)
				end
			end
		end,

		save = function(state: State): any
			local p = state.problem
			local pause: { kind: string, message: string, by: string? }? = nil
			if p and TERMINAL[p.kind] then
				pause = { kind = p.kind, message = p.message, by = state.problemBy }
			end
			-- The active view as its kv store has it: the saved id without the kind, and the kind only for an issue view (a
			-- save without one is a pull request view's, as the older PR block saved). Read from its id, as one restored
			-- before the CLIs answered is not listed yet.
			local kind, own = kindAndId(state.activeId or "")
			return {
				version = 2,
				launchCwd = state.launchCwd,
				activeViewId = if state.activeId then (if engine.isPin(state.activeId) then state.activeId else own) else nil,
				activeKind = if kind == KINDS.issues then "issues" else nil,
				activeLogin = state.activeLogin,
				pause = pause,
				pins = requests.pinUrls(state),
			}
		end,
	}
end

tern.block.define("prs", blockDef())
lens.define()
