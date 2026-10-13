--!strict
-- What an agent run needs from the machine its checkout is on: the omp prompt templates and skills to offer, and the
-- checks that `/name` of a picked template still reaches that template in the pull request's worktree. host.luau runs
-- it there (the remote host for a remote pane); window.luau only asks and shows.

local process = require("./process")

local M = {}

local RPC_MS = 10000
-- Template files are listed and compared up to this size.
local TEMPLATE_CAP = 65536
-- omp loads prompt templates from every depth of a `prompts` directory. Looking through one gives up, and the agent
-- is refused, past this many entries or levels: a huge tree or a symlink loop must not hang the host.
local SCAN_ENTRIES = 2000
local SCAN_DEPTH = 8

-- The file a template row was listed from, as it read then: `text` is nil when it could not be read (or is over
-- TEMPLATE_CAP); `project` marks the repository's own templates, as opposed to the user's.
export type Source = { path: string, text: string?, name: string, project: boolean }
-- One picker row: `tpl` is the path of a template row's file, its key in `Menu.sources`.
export type Item = { label: string, detail: string?, group: string, send: string, tpl: string? }
-- `consent`: omp would run in that directory, where project config can run code, so the user must agree first.
export type Menu = { consent: string?, items: { Item }, problem: string?, sources: { [string]: Source } }

local function readCapped(path: string): string?
	local ok, text = pcall(tern.fs.read, path, TEMPLATE_CAP)
	return if ok and type(text) == "string" then text else nil
end

-- omp's slash commands over its RPC mode, run in `cwd`: done(commands, problem), the commands nil when omp did not
-- list them. Skills and file commands are in that list, prompt templates are not.
local function ompCatalog(cwd: string, done: ({ any }?, string?) -> ())
	local ask = tern.json.encode({ id = "plotroom", type = "get_available_commands" }) .. "\n"
	process.run({ "omp", "--mode", "rpc", "--no-session" }, { cwd = cwd, stdin = ask, timeout_ms = RPC_MS }, function(result, problem)
		if not result then
			return done(nil, problem)
		end
		for line in string.gmatch(result.stdout, "[^\n]+") do
			local ok, msg = pcall(tern.json.decode, line)
			if ok and type(msg) == "table" and msg.id == "plotroom" then
				local cmds = if msg.success == true and type(msg.data) == "table" then msg.data.commands else nil
				if type(cmds) ~= "table" then
					return done(nil, "omp answered without a command list")
				end
				return done(cmds, nil)
			end
		end
		done(nil, if result.timed_out then "omp did not answer within 10 seconds" else "omp did not list its commands (exit " .. result.status .. ")")
	end)
end

-- Where omp keeps the user's config (its templates and commands among it) unless something moves it.
local function userAgentDir(): string?
	local home = tern.getenv("HOME")
	return if home and home ~= "" then (string.gsub(home, "/+$", "")) .. "/.omp/agent" else nil
end

-- Where omp, run in `cwd`, reads the user's config: `omp config path`. A checkout's `.env` can move it, even into the
-- checkout. done(dir, problem).
local function ompAgentDir(cwd: string, done: (string?, string?) -> ())
	process.run({ "omp", "config", "path" }, { cwd = cwd, timeout_ms = RPC_MS }, function(result, problem)
		if not result then
			return done(nil, problem)
		end
		local dir = if result.status == 0 and not result.timed_out then string.match(result.stdout, "^(/[^\r\n]+)\r?\n?$") else nil
		done(dir, if dir then nil else "omp did not report its agent directory (exit " .. result.status .. ")")
	end)
end

-- Adds to `found` the path of every entry called `file` below `dir`, as omp loads prompt templates from every depth.
-- Raises when the tree is bigger or deeper than a scan allows, which a symlink loop always is.
local function findNamed(dir: string, file: string, scan: { left: number }, depth: number, found: { string })
	local ok, entries = pcall(tern.fs.list, dir)
	if not ok then
		return -- a file, not a directory
	end
	for _, entry in entries do
		scan.left -= 1
		if scan.left < 0 or depth >= SCAN_DEPTH then
			error("more than " .. SCAN_ENTRIES .. " entries or " .. SCAN_DEPTH .. " levels of directories in a prompts directory", 0)
		end
		local path = dir .. "/" .. entry
		if entry == file then
			table.insert(found, path)
		end
		findNamed(path, file, scan, depth + 1, found)
	end
end

-- How omp's list names a command called `name` (a builtin's aliases count): its source; nil when the list has none.
local function listedAs(cmds: { any }, name: string): string?
	for _, c in cmds do
		if type(c) == "table" and (c.name == name or (type(c.aliases) == "table" and table.find(c.aliases, name) ~= nil)) then
			return tostring(c.source)
		end
	end
	return nil
end

-- Why `/name` of a picked template would no longer be that template; nil when it still is. Always: its file reads back
-- as it was listed. With the pull request's checkout `root`: every `<name>.md` anywhere under its `.omp/prompts` reads
-- back as the same text, and the repository's own template has one. With `agent`, where omp reads the user's config
-- there: unless that is ~/.omp/agent (a checkout's `.env` can move it, even into the checkout) its `prompts` are held
-- to the same, and the template must be somewhere. omp 18.10.3 reads the user's templates first, but that order has
-- no contract, so any difference refuses. Commands of the name are not looked for in files, whatever they are called
-- or wherever they sit: only omp's own list says which exist (`M.verify`).
local function mismatch(src: Source, root: string?, agent: string?): string?
	if src.text == nil or readCapped(src.path) ~= src.text then
		return src.path .. " is gone, unreadable, over 64 KiB or changed since it was listed"
	end
	if not root then
		return nil
	end
	local file = src.name .. ".md"
	local found: { string } = {}
	findNamed(root .. "/.omp/prompts", file, { left = SCAN_ENTRIES }, 0, found)
	local moved = if agent and agent ~= userAgentDir() then agent else nil
	if moved then
		findNamed(moved .. "/prompts", file, { left = SCAN_ENTRIES }, 0, found)
	end
	for _, path in found do
		if readCapped(path) ~= src.text then
			return "omp would read a different template: " .. path
		end
	end
	if #found == 0 then
		if moved then
			return "omp reads its templates from " .. moved .. "/prompts there, which has no " .. file
		elseif src.project then
			return "The pull request has no .omp/prompts/" .. file
		end
	end
	return nil
end

-- `mismatch`, with a filesystem call that raises as a refusal too.
function M.unbound(src: Source, root: string?, agent: string?): string?
	local ok, why = pcall(mismatch, src, root, agent)
	return if ok then why else "The checkout could not be inspected: " .. tostring(why)
end

-- Once the user agreed to run omp in `root`, asks omp itself about `/name` of a picked template there. A skill, file
-- command (from any config family, named by its file, its frontmatter or its directory), extension or builtin command
-- of that name runs instead, and omp's dispatch has no form that names the template: only omp's own list is
-- complete, so no list, or a command of the name in it, refuses. It also says where omp reads the user's templates
-- there, which a checkout's `.env` can change. The files are checked again last: the user may have waited.
-- done(why): nil when the agent may start.
-- ponytail: code can answer for itself (an extension's input hook, an MCP server whose prompts connect after the list
-- is read), so only the consent covers that.
function M.verify(src: Source, root: string, done: (string?) -> ())
	local name = src.name
	local function cannot(what: string, problem: string?): string
		return "omp could not " .. what .. " in the checkout, so /" .. name .. " cannot be confirmed: " .. tostring(problem)
	end
	ompAgentDir(root, function(agent, problem)
		if not agent then
			return done(cannot("report where it reads templates", problem))
		end
		ompCatalog(root, function(cmds, problem2)
			if not cmds then
				return done(cannot("list its commands", problem2))
			end
			local source = listedAs(cmds, name)
			if source then
				return done("omp lists /" .. name .. " in the checkout (" .. source .. "), and that runs instead of your template")
			end
			done(M.unbound(src, root, agent))
		end)
	end)
end

-- omp prompt templates in `dir` (`<name>.md`, frontmatter description as the detail), skipping names in `seen`. Each
-- row keeps its file as read: `/name` must still mean that when the agent runs.
local function templatesIn(dir: string, group: string, project: boolean, seen: { [string]: boolean }, out: { Item }, sources: { [string]: Source })
	local ok, files = pcall(function(): { string }
		return if tern.fs.exists(dir) then tern.fs.list(dir) else {}
	end)
	if not ok then
		return
	end
	table.sort(files)
	for _, file in files do
		local name = string.match(file, "^([^%.%s][^%s]*)%.md$")
		if name and not seen[name] then
			seen[name] = true
			local path = dir .. "/" .. file
			local text = readCapped(path)
			local front = if text then string.match(text, "^%-%-%-\r?\n(.-)\r?\n%-%-%-") else nil
			local desc = if front then string.match("\n" .. front .. "\n", "\ndescription:[ \t]*([^\r\n]-)[ \t]*\r?\n") else nil
			sources[path] = { path = path, text = text, name = name, project = project }
			table.insert(out, { label = "/" .. name, detail = if desc ~= "" then desc else nil, group = group, send = "/" .. name, tpl = path })
		end
	end
end

-- Prompt templates omp would expand: the nearest `.omp/prompts` above `cwd`, then `~/.omp/agent/prompts`. omp reads the
-- user's before the project's and the first of a name wins, so a user template hides a same-named repository one.
local function templates(cwd: string?, sources: { [string]: Source }): { Item }
	local seen: { [string]: boolean } = {}
	local user: { Item } = {}
	local agent = userAgentDir()
	if agent then
		templatesIn(agent .. "/prompts", "Your templates", false, seen, user, sources)
	end
	local out: { Item } = {}
	local dir = cwd
	while dir and dir ~= "" and dir ~= "/" do
		if tern.fs.exists(dir .. "/.omp/prompts") then
			templatesIn(dir .. "/.omp/prompts", "This repository's templates", true, seen, out, sources)
			break
		end
		dir = string.match(dir, "^(.*)/[^/]*$")
	end
	for _, t in user do
		table.insert(out, t)
	end
	return out
end

-- What to offer for an agent run of a block launched in `cwd`: its templates, then omp's skills and file commands
-- (prompt templates are not in its list). omp lists them by running in `cwd`, where project config can run code, so
-- without `consent` that answers with the directory to ask about instead; the home directory needs no asking, omp
-- never treats it as a project.
function M.menu(cwd: string?, consent: boolean, done: (Menu) -> ())
	local home = tern.getenv("HOME")
	local dir = cwd or home or ""
	local function offer(cmds: { any }?, problem: string?)
		local sources: { [string]: Source } = {}
		local items = templates(cwd, sources)
		local listed: { any } = cmds or {}
		for _, c in listed do
			if type(c) == "table" and type(c.name) == "string" and (c.source == "skill" or c.source == "file") and not string.find(c.name, "%s") then
				local desc = if type(c.description) == "string" then string.match(c.description, "^[^\r\n]*") else nil
				table.insert(items, {
					label = "/" .. c.name,
					detail = if desc ~= "" then desc else nil,
					group = if c.source == "skill" then "Skills" else "Commands",
					send = "/" .. c.name,
				})
			end
		end
		done({ items = items, problem = problem, sources = sources })
	end
	local atHome = home ~= nil and (string.gsub(dir, "/+$", "")) == (string.gsub(home, "/+$", ""))
	if dir == "" then
		tern.timer(0, function()
			offer(nil, "No directory is known to ask omp in")
		end)
	elseif not atHome and not consent then
		tern.timer(0, function()
			done({ consent = dir, items = {}, sources = {} })
		end)
	else
		ompCatalog(dir, offer)
	end
end

return M
