# Plotroom: PR agent commands and open-tab indicator

## Context

- **Ask.** Configurable *commands*: named prompts (plain text or an omp slash command) shown as buttons in a PR's preview. Clicking one creates or reuses the PR's Plotroom worktree, opens an agent block there and sends the prompt.
- **Scope axes.** A command is global or project-level ("Only this repository"). It shows on every filter or only on chosen filters.
- **Open-tab indicator.** PRs that already have a tab are marked in the list and preview, and the preview can jump to that tab.
- **Decided:**
  - Commands are edited on a new Settings › Commands page and saved in kv.json, inside the existing `filters` store.
  - Project-level means the command's `repo` is `github.com/<owner>/<repo>`, lowercase, the same key the `accounts`/`repos` maps use.
  - A new agent joins the PR's existing tab. With no tab, it opens a new tab named `PR #N · <repo>`.
  - "Open in a tab" means some pane's cwd is the PR's Plotroom worktree or is inside it (`<checkout>.plotroom/<owner>/<repo>/pr-N`, lowercase). No git calls.
- **Placeholders.** Prompt text gets `{number} {url} {title} {repo} {branch} {base} {author}` filled in. Without them the agent has no reliable way to know which PR it is on: the worktree branch is `plotroom/<owner>/<repo>/pr-N`, which is not the PR's head branch, so a bare `gh pr view` finds nothing.
- **Click target.** Picker rows only send select/activate (no clickable badges). So the clickable "Go to tab" is in the preview: a button, the `g` key and a palette command.

## Approach

Steps are ordered so the plugin loads and the self-test passes after each one. Do step 1 first. Steps 2 and 4 are then independent (4 uses `worktree.prOfPath`). Step 3 needs 2. Step 5 needs 1, 2 and 4.

### 1. Pure helpers and self-test (`plugin/worktree.luau`, `plugin/github.luau`, `plugin/tests/check.luau`)

- `worktree.luau`: add after `M.reconcile`. It must match the layout `M.open` builds: `suffix = owner .. "/" .. name .. "/pr-" .. number`, lowercase, under `<mainRoot>.plotroom/`.
  ```lua
  -- The PR number whose Plotroom worktree (`<checkout>.plotroom/<owner>/<repo>/pr-N`, lowercase as `M.open`
  -- creates it) holds `path`, the worktree root or any directory inside it; nil otherwise.
  function M.prOfPath(path: string, repo: string): number?
  	local _, e = string.find(path, ".plotroom/" .. string.lower(repo) .. "/pr-", 1, true)
  	if not e then
  		return nil
  	end
  	local n, rest = string.match(string.sub(path, e + 1), "^(%d+)(.*)$")
  	if not n or (rest ~= "" and string.sub(rest, 1, 1) ~= "/") then
  		return nil
  	end
  	return tonumber(n)
  end
  ```
- `github.luau`: add after `M.match`. `gsub` with a table keeps unknown names as typed and inserts values literally, with no `%` processing and no re-scan.
  ```lua
  -- `text` with {number}, {url}, {title}, {repo}, {branch}, {base} and {author} replaced by `pr`'s values; other braces stay.
  function M.fill(text: string, pr: Pr): string
  	local vars: { [string]: string } = {
  		number = tostring(pr.number), url = pr.url, title = pr.title, repo = pr.repo,
  		branch = pr.head, base = pr.base, author = pr.author,
  	}
  	return (string.gsub(text, "{(%a+)}", vars))
  end
  ```
- `tests/check.luau`: put these asserts after the `github.match` asserts (they reuse the `mp` fixture: PR 12 of `a/b`, head `fix/lexer`) and after the worktree `reconcile` asserts.
  - `github.fill("/review {url} #{number} on {branch} {nope}", mp) == "/review https://github.com/a/b/pull/12 #12 on fix/lexer {nope}"`
  - For a PR normalized from `item(13, "a/b", "2026-01-01T00:00:00Z", { title = "100% {url}" })`: `github.fill("{title}", that) == "100% {url}"`.
  - `worktree.prOfPath("/r/x.plotroom/a/b/pr-12", "A/B") == 12`
  - `worktree.prOfPath("/r/x.plotroom/a/b/pr-12/src/lib", "a/b") == 12`
  - These are all `nil`:
    - `prOfPath("/r/x.plotroom/a/b/pr-12x", "a/b")`
    - `prOfPath("/r/x.plotroom/a/bc/pr-1", "a/b")`
    - `prOfPath("/r/a/b/pr-1", "a/b")`
    - `prOfPath("", "a/b")`

### 2. Commands in the saved store (`plugin/host.luau`, storage section)

- **Types**, next to `Filter`:
  ```lua
  type Command = { id: string, name: string, text: string, filters: { string }, repo: string? } -- repo: "github.com/<owner>/<repo>" lowercase; nil = every repository
  type Store = { version: number, nextId: number, items: { Filter }, commands: { Command } }
  ```
- **`seeds()`**: add `commands = {}`. Commands start empty, with no seeded examples.
- **`validStore`**:
  - An absent `v.commands` gives `{}`. The user's current kv has none and must stay writable.
  - Any of these makes the whole store invalid (return `nil`, so it is read-only, never overwritten): `commands` is not a table; an entry is not a table; `id`, `name` or `text` is not a string; `repo` is present but not a string; `filters` is present but not a table of strings.
  - Copy each command as `{ id, name, text, filters = <copied array>, repo }`.
  - Keep `version = 1`; the field is additive.
- **`writeStore`**: tag each command's array with `tern.json.array(c.filters)`, then write `{ version = 1, nextId, items = tern.json.array(store.items), commands = tern.json.array(store.commands) }` under the same `filters` key.
- **ID counter**: commands share `nextId` with filters, with ids `"c" .. nextId`.
- **`liveFilters`**: add after `activeFilter`. Both the settings page and the queue use it, so a deleted filter's id is ignored everywhere. If none of a command's ids survive, it shows on every filter, which matches the settings page showing no chips selected.
  ```lua
  -- The ids of `c.filters` that still name a saved filter.
  local function liveFilters(state: State, c: Command): { string }
  ```

### 3. Settings › Commands page (`plugin/host.luau`, settings section and block handlers)

**Page and state**
- `PAGES = { "filters", "commands", "github", "worktrees" }`.
- In `PAGE_DEFS`, after Filters: `{ id = "commands", label = "Commands", group = "Queue", icon = "prompt" }`.
- `Settings` gets `option: number?`, the 1-based highlighted chip of the focused multi row.
- `confirm` now holds the **row id** awaiting delete confirmation: `"delete:<filter id>"` or `"cdelete:<command id>"`.

**`pageContent`, `s.page == "commands"` branch**
- `lead`: "Each command is a prompt for a coding agent. Clicking it on a pull request opens the pull request's worktree in a tab, starts an agent there and sends the prompt. {url}, {number}, {title}, {branch}, {base}, {author} and {repo} become the pull request's values."
- `locked` = `if state.writable then nil else (state.storeError or "Saved commands are read-only.")`.
- `key` = `"github.com/" .. string.lower(state.repo)` when there is a repo.
- One section per command with `c.repo == nil or c.repo == key`, in store order: `{ id = "command:" .. c.id, title = c.name .. (if c.repo then " · this repository" else "") }`. Rows:
  - `{ id = "cname:"..id, label = "Name", disabled = locked, control = { k = "text", value = c.name, placeholder = "Review this PR" } }`
  - `{ id = "ctext:"..id, label = "Prompt", hint = "Sent as one message after the placeholders are filled in.", disabled = locked, control = { k = "text", value = c.text, placeholder = "Review {url} and list the risks", mono = true } }`
  - `{ id = "cfilters:"..id, label = "Filters", hint = "Shown on the chosen filters; none chosen: every filter.", disabled = locked or (if #state.store.items == 0 then "No saved filters yet." else nil), control = { k = "multi", values = tern.json.array(liveFilters(state, c)), options = tern.json.array({ { value = f.id, label = f.name } for each saved filter }) } }`
  - `{ id = "crepo:"..id, label = "Only this repository", hint = if state.repo then "On: only " .. state.repo .. ". Off: every repository." else nil, disabled = locked or (if state.repo then nil else NO_REPO), control = { k = "switch", on = c.repo ~= nil } }`
  - Use `if … then … else nil` expressions for `hint`/`disabled`, not `a and b`: `Row.disabled` is `string?` and `false` would break `--!strict`.
  - `{ id = "cdelete:"..id, label = "Delete command", disabled = locked, control = { k = "action", act = "delete", label = "Delete" } }`
- A last section `{ id = "new-command" }` with `{ id = "cadd", label = "New command", hint = "Adds a command for every filter and repository; name it, then write its prompt.", disabled = locked, control = { k = "action", act = "add-command", label = "Add command" } }`.

**Mutations**
- Add one helper, used only by the command functions. Leave the filter functions as they are.
  ```lua
  -- Rereads the store, lets `fn` change it (an error string aborts) and writes it back; an error message or nil.
  local function saveStore(state: State, fn: (Store) -> string?): string?
  ```
  - Not writable: set `state.store/writable/storeError` and return `err or "Commands cannot be saved."`.
  - Then `fn`, then `writeStore` (on failure `"Could not save: " .. werr`), then set `state.store, state.writable, state.storeError = store, true, nil` and `propagate(state)`.
- `updateCommand(state, id, fn: (Command) -> ()): string?` runs `saveStore`. It finds `id` and applies `fn`. If `id` is missing it returns `"That command was deleted elsewhere."`.
- `addCommand(state)`:
  - Inside `saveStore`: `id = "c" .. store.nextId`, `nextId += 1`, append `{ id, name = "New command", text = "", filters = {} }`.
  - On error: `s.errors.cadd = err`. Otherwise `beginEdit(state, "cname:" .. id, "")`.
- `deleteCommand(state, id)`:
  - `s.confirm = nil`, then remove the entry inside `saveStore`. A missing id is not an error.
  - On error: `s.errors["cdelete:" .. id] = err`. Otherwise `s.focus = "cadd"`.
- `changeRow(state, row, value)`:
  - `crepo:<id>` with a boolean: needs `state.repo` (else error `NO_REPO`). Sets `c.repo = if value then "github.com/" .. string.lower(state.repo) else nil`.
  - `cfilters:<id>` with a table: keeps only string values that are ids in `state.store.items`, then sets `c.filters` to them.
  - Any other row or value is ignored and returns early.
  - Then `s.focus = row` and `s.errors[row] = err`.
- `commitEdit`: add a branch for kinds `cname`/`ctext`, matched by the existing `^(%a+):(.+)$`.
  - Empty text: `"A name is required."` / `"A prompt is required."`.
  - `ctext` over 1000 bytes (`#text > 1000`): `"Prompts are limited to 1000 bytes."`. This keeps the encoded link small (step 5).
  - Otherwise `updateCommand` sets `c.name`/`c.text`. Errors go to `s.errors[row]`; success clears `s.edit`.
- `runAction`: `act == "add-command"` runs `addCommand(state)`. `act == "delete"` now sets `s.confirm = row`; filters and commands share it.
- New `confirmDelete(state)`: reads `s.confirm`, splits it with `^(%a+):(.+)$`, then calls `deleteCommand` for `cdelete` or `deleteFilter` for `delete`.
- Replace both existing `deleteFilter(state, s.confirm)` calls with it: the overlay's Enter key and the `confirm-delete` event.
- `confirmOverlay(state, row)`:
  - Filters: head `Delete filter “<name>”?`, body "Every Plotroom pane loses this saved search.".
  - Commands: head `Delete command “<name>”?`, body "Every Plotroom pane loses this command.".
  - Look the name up with two separate loops (items vs commands; different types under `--!strict`).
  - `settingsView` passes `s.confirm`.

**Keyboard**
- `runRow` gains two control kinds:
  - `switch`: `changeRow(state, row, not def.control.on)`.
  - `multi`: take `opt = def.control.options[math.min(s.option or 1, #options)]`, toggle `opt.value` in a copy of `def.control.values`, then call `changeRow`.
- Settings key branch:
  - With focus on a non-disabled `multi` row, `left`/`right` set `s.option = math.clamp((s.option or 1) ± 1, 1, #options)`. Other rows return `false` for left/right, as now.
  - Reset `s.option = nil` when `up`/`down` moves focus, on Tab page cycling, and in the `page` and `select` events.
- `settingsView`: when not text-editing and the focused row is a non-disabled `multi` row with options, set `props.editing = { row = s.focus, option = options[math.min(s.option or 1, #options)].value }`. This draws the chip highlight.

**Events** (settings branch)
- Add `"add-command"` to the acts list routed to `runAction`, next to `add`, `delete` and `refresh`.
- After the existing reset branch (`change` with nil/null runs `resetRow`), add: `elseif ev.ev == "change" and item then changeRow(state, item, ev.value)`.

### 4. Open-tab indicator and Go to tab (`plugin/host.luau`, `plugin/window.luau`)

**Host**
- Add after `selectedPr`:
  ```lua
  -- Numbers of the launch repo's PRs whose Plotroom worktree holds some pane's cwd on this host.
  local function openPrs(state: State): { [number]: boolean }
  ```
  - It walks `tern.pane.list()` and calls `worktree.prOfPath(p.cwd, state.repo)` for each pane with a `cwd`. With no `state.repo` it returns `{}`.
- `queueView`: compute `local open = openPrs(state)` once. Call `pickerItem(p, open[p.number] == true)` and `previewNodes(state, open)`.
- `pickerItem(pr, open: boolean)`: when `open`, insert first into `badges`: `{ text = "In tab", tone = "accent", title = "A tab works in this pull request's worktree (g goes there)" }`. Badges past three fold into `+N`, so it must come first.
- `previewNodes(state, open)`, when `open[pr.number]`:
  - Chips: after the state badge, `ui.node("badge", { key = "tab", text = "In tab", tone = "accent" })`.
  - Buttons: after `worktree`, `ui.el("button", { key = "goto", class = "plotroom-btn", text = "Go to tab", href = prHref("goto", pr), actions = { click = "open" }, title = "Show the tab working in this pull request's worktree" }, { ui.node("kbd", { keys = { "g" } }) })`. Its node id is `layer.queue.buttons.goto`.
- Key `g` (plain, not searching, next to `w`): if there is no selected PR or `openPrs(state)[pr.number]` is false, return `false`. Otherwise `openSelected(state, "goto", false)`.
- Redraw on pane moves and exits. Add before `tern.block.define`:
  ```lua
  -- A pane moved into or out of a PR worktree, or ended: redraw every queue so "In tab" marks follow.
  local function redrawQueues()
  	for _, s in running do
  		if alive(s) then
  			s.cx:render()
  		end
  	end
  end
  tern.on("cwd", function(_ev: any, _cx: any) redrawQueues() end)
  tern.on("pane_exited", function(_ev: any, _cx: any) redrawQueues() end)
  ```
  - The host `cwd` event covers agent blocks too: Tern polls the program's directory.

**Window**
- `GOTO_NODE = "layer.queue.buttons.goto"`.
- `parseLink` also accepts kind `"goto"`.
- `handle` picks `GOTO_NODE` for it, checks the href the same way, then calls `gotoPr(cx, owner .. "/" .. repo, n)`.
- New shared lookup (step 5 reuses it):
  ```lua
  -- A pane in a tab of this window working in PR `repo`#`n`'s Plotroom worktree: pane, tab and session ids.
  local function prPane(cx: WindowCx, repo: string, n: number): (number?, number?, number?)
  ```
  - It returns the first `cx.session:panes()` entry with a `tab` and `worktree.prOfPath(p.cwd or "", repo) == n`, plus that tab's `session` from `cx.session:tabs()`.
- `gotoPr(cx, repo, n)`:
  - No pane found: `cx:toast("info", "No tab is open for " .. repo .. "#" .. n)`.
  - Otherwise `cx.sessions:switch(session)` and `cx.layout:focus(pane)`.
- `selected(cx, nodeId, missing: string?)`: the absent-href toast uses `missing or "No pull request is selected"`.
- New palette command, next to `worktree-selected`:
  - `{ id = "goto-selected", title = "Plotroom: Go to the selected PR's tab", icon = "merge", available = available }`.
  - `run`: `selected(cx, GOTO_NODE, "The selected pull request has no open tab")`.

### 5. Command buttons and dispatch (`plugin/host.luau`, `plugin/window.luau`)

**Host**
- Pull the encoder out of `checkHref`:
  ```lua
  -- Percent-encodes everything but unreserved URL characters.
  local function pct(s: string): string
  ```
  `checkHref` becomes `"plotroom://github/check/" .. i .. "/" .. pct(url)`.
- `commandHref(pr, i, prompt)` = `"plotroom://github/command/" .. pr.repo .. "/" .. pr.number .. "/" .. i .. "/" .. pct(prompt)`.
- Add before `previewNodes`:
  ```lua
  -- Commands shown for `pr` on the active filter, in store order, prompts filled in.
  local function commandsFor(state: State, pr: github.Pr): { { name: string, text: string } }
  ```
  A command is included when all of these hold:
  - `trim(c.text) ~= ""`
  - `c.repo == nil or c.repo == "github.com/" .. string.lower(pr.repo)`
  - with `ids = liveFilters(state, c)`: `#ids == 0 or table.find(ids, state.activeId)`
  - `text = github.fill(c.text, pr)`
- `previewNodes`: when `commandsFor` returns entries, insert these between `buttons` and the `facts` kv, so a short pane doesn't clip them:
  - `ui.node("text", { key = "commands-head", spans = { ui.span("Agent commands", "strong") } })`
  - `ui.el("div", { key = "commands", class = "plotroom-actions" }, buttons)`. Each button: `ui.el("button", { key = "cmd" .. i, class = "plotroom-btn", text = c.name, title = c.text, href = commandHref(pr, i, c.text), actions = { click = "open" } }, if i <= 9 then { ui.node("kbd", { keys = { tostring(i) } }) } else nil)`.
  - Node ids are `layer.queue.commands.cmd<i>`.
  - No CSS changes: the existing `.plotroom-actions` and `.plotroom-btn` rules apply.
- Keys `1`–`9` (plain, not searching, next to `w`): `pr = selectedPr(state)`, `i = tonumber(k)`, `c = if pr then commandsFor(state, pr)[i] else nil`. If there is no PR or no `c`, return `false`. Otherwise `state.cx:open(commandHref(pr, i, c.text))`.

**Window**
- `readNode` passes `{ root = id, max_chars = 64000 }`. The command href carries the encoded prompt: up to 1000 bytes before encoding, plus the filled-in values.
- Pull the decoder out of `parseCheck` as `local function unpct(s: string): string`.
- New `parseCommand(url)`:
  - Matches `^plotroom://github/command/([^/]+)/([^/]+)/(%d+)/(%d+)/([^/]+)$`.
  - Returns `owner, repo, number, index, prompt`, all nil when invalid.
  - Same checks as `parseLink`/`parseCheck`: `segment(owner/repo)`, number in 1..2147483647, index in 1..100000.
  - `prompt = unpct(enc)`; an all-whitespace prompt is rejected.
- `COMMAND_NODE = "layer.queue.commands.cmd"`.
- `handle`, after the check-link block:
  - Valid command link: if `not isPlotroom`, use the existing error toast.
  - Elif `nodeProp(readNode(cx, pane, COMMAND_NODE .. index), "href") ~= url`: `cx:toast("error", "Plotroom: that command is no longer listed", "Refresh and try again.")`.
  - Else `worktreePr(cx, pane, owner, repo, n, prompt)`.
  - `return true`.
- `worktreePr(cx, pane, owner, repo, n, prompt: string?)`:
  - The existing call passes `nil`. Local-host check, `inflight` guard and `worktree.open` stay as they are.
  - On success: `if prompt then finishAgent(cx2, pane, full, n, path, prompt) else finishWorktree(cx2, pane, full, n, path) end`.
  - The `NO_REPO` toast sub-line becomes "Enter its path in Plotroom, then try again.".
- Extract two helpers from `finishWorktree` (it then uses both):
  - `sourceSession(cx, pane): number?`: the existing tab → session → still-exists lookup.
  - `namePrTab(cx, pane, repo, n)`: `name_tab(tab_of(pane), "PR #" .. n .. " · " .. <name after "/">)`.
- New `finishAgent(cx, pane, repo, n, path, prompt)`:
  1. `local _, tab, session = prPane(cx, repo, n)`, then `session = session or sourceSession(cx, pane)`.
     - Still nil: `cx:toast("success", "Worktree ready", path .. " (the source pane closed, so no agent was started)")` and return.
  2. `cx.sessions:switch(session)`, then `local ok, agent = pcall(function() return cx.agents:start({ prompt = prompt, cwd = path, how = "tab" }) end)`. Command and model come from the user's agent settings.
     - `not ok` or `type(agent) ~= "number"`: `cx:toast("error", "Could not start an agent for " .. repo .. "#" .. n, tostring(agent))` and return.
  3. If `tab`: `local moved, why = cx.layout:move_to_tab(agent, tab)`. The temporary tab closes by itself once its only pane leaves.
     - Moved: `cx:toast("success", "Agent started in the tab of " .. repo .. "#" .. n, prompt)`.
     - Not moved: `namePrTab(cx, agent, repo, n)` and `cx:toast("info", "Agent started in a new tab for " .. repo .. "#" .. n, "It could not join the pull request's tab: " .. (why or "unknown reason"))`.
  4. If no `tab`: `namePrTab(cx, agent, repo, n)` and `cx:toast("success", "Agent started for " .. repo .. "#" .. n, prompt)`.

## Critical files & anchors

| File | Anchor | Why |
| --- | --- | --- |
| `plugin/host.luau` | `validStore`/`writeStore`/`seeds`; `pageContent`, `runAction`, `runRow`, `commitEdit`, `confirmOverlay`, `settingsView`; `checkHref`, `pickerItem`, `previewNodes`, `queueView`; `key`/`event` in `tern.block.define("prs")` | The store, settings page, preview and key wiring all change here |
| `plugin/window.luau` | `readNode`, `parseCheck`, `parseLink`, `finishWorktree`, `worktreePr`, `handle`, `selected`, the palette commands | Link validation and dispatch |
| `plugin/worktree.luau` | `M.open` (`suffix`, `target`) | `prOfPath` must match the path it builds (lowercase `owner/repo/pr-N` under `<root>.plotroom/`) |
| `plugin/tests/check.luau` | the `github.match` and `worktree.reconcile` assert blocks | Where the new asserts go |

## Verification

**Prerequisites**
- Run everything from `/Users/user/Code/andyhite/tern-plotroom`.
- `tern plugin list` shows `plotroom … ready`, and `~/Library/Application Support/Tern/plugins/plotroom.path` contains `<repo>/plugin`. Saving any file under `plugin/` reloads the plugin.
- `gh` is signed in, and the agent command is Tern's default `omp`.
- Fixture: `git clone --depth 1 https://github.com/cli/cli /tmp/plotroom-fixture/cli`, unless it already exists.
- Back up the store: `cp "$HOME/Library/Application Support/Tern/plugin-data/plotroom/kv.json" /tmp/plotroom-kv.before.json`. Before this change it holds filters `f1` "My PRs" and `f2` "Awaiting My Review", `nextId` 12, and no `commands`.
- Dev window:
  ```sh
  PLOTROOM_SELFTEST=1 tern --control /tmp/plotroom-ui.sock &
  C="tern ctl --control /tmp/plotroom-ui.sock"
  $C ready && $C session new plotroom-dev && $C ready
  $C run "cd /tmp/plotroom-fixture/cli"
  ```
  - Harness keys use DOM names: `Enter`, `Escape`, `Tab`, `Shift+Tab`, `ArrowUp/Down/Left/Right`. Toggle switches and chips with `Enter`; `runRow` treats Enter and Space the same.

**Checks** (each gives the action, then the expected result)
1. **Self-test** (step 1).
   - `$C plugins run plugin.plotroom.selftest`
   - Expect the toast "Plotroom self-test passed".
2. **Store compatibility** (step 2).
   - `$C plugins run plugin.plotroom.open`
   - Expect the queue to load with "My PRs" and "Awaiting My Review" and no "read-only"/"malformed" subtitle.
3. **Test filter.**
   - `$C key s`, `$C key ArrowUp`, `$C key Enter`, `$C type "Open PRs"`, `$C key Enter`, `$C key Escape`.
   - Expect the queue to show "Open PRs" (`is:open`) with PRs.
4. **Commands page** (step 3).
   - Open it: `$C key s`, `$C key Tab`.
     - Expect a "Commands" page with only "New command".
   - Add a command: `$C key ArrowDown`, `$C key Enter`, `$C type "Echo PR"`, `$C key Enter`.
   - Set its prompt: `$C key ArrowDown`, `$C key Enter`, `$C type "Reply with only this text: PR {number} {title}"`, `$C key Enter`.
     - Expect kv.json `filters.commands` to hold `{ "id": "c13", "name": "Echo PR", "text": "Reply with only this text: PR {number} {title}", "filters": [] }`. The id is `c` plus `nextId` after the filter took 12.
   - Toggle a filter chip: `$C key ArrowDown` (Filters), `$C key Enter`.
     - Expect the first chip, "My PRs", to turn on and `"filters": ["f1"]` in kv.
   - Toggle the repo switch: `$C key ArrowDown`, `$C key Enter`.
     - Expect `"repo": "github.com/cli/cli"` and the section title "Echo PR · this repository".
   - `$C key Escape`.
5. **Filter scoping.**
   - On "Open PRs", `$C tree "[data-surface='plugin.plotroom.prs'] .plotroom-actions button"`.
     - Expect no "Echo PR": it is assigned to My PRs only.
   - Move the chip: `$C key s`, `$C key Tab`, `$C key ArrowDown` ×3 (Name, Prompt, Filters), `$C key Enter` (My PRs off), `$C key ArrowRight` ×2 (to "Open PRs", the third chip), `$C key Enter`, `$C key Escape`.
     - Expect the preview to show "Agent commands" with an "Echo PR" button and keycap `1`.
6. **Dispatch to a new tab** (step 5).
   - `$C key 1`.
     - Expect the toasts "Preparing worktree for cli/cli#N", then "Agent started for cli/cli#N".
     - Expect a new tab "PR #N · cli" whose agent pane's cwd is `…/cli.plotroom/cli/cli/pr-N` (`$C state`).
     - Expect its first user message to read "Reply with only this text: PR N <title>", with N and the title filled in (`$C shot plotroom-agent`).
7. **Indicator** (step 4).
   - `$C previous-tab`.
   - Within about 3 s with no key press, expect:
     - the selected row to show an "In tab" badge (`$C tree "[data-surface='plugin.plotroom.prs'] .pk-row.sel .pk-badge"`);
     - the preview to show the "In tab" chip and a "Go to tab" button with keycap `g`.
8. **Go to tab.**
   - `$C key g`: expect the "PR #N · cli" tab to show with focus inside it (`$C state` focused pane). Then `$C previous-tab`.
   - `$C plugins run plugin.plotroom.goto-selected`: same result. Then `$C previous-tab`.
9. **Join the PR's tab.**
   - Once the agent is idle, `$C key 1`.
   - Expect the toast "Agent started in the tab of cli/cli#N", no new tab, and two agent panes in "PR #N · cli" (`$C state`).
10. **Slash command.**
    - Create `~/.omp/agent/prompts/plotroom-echo.md` with frontmatter `description: Plotroom test` and the body "Reply with only the word plotroom-ok.".
    - Add a command "Slash test" with prompt `/plotroom-echo`: `$C key s`, `$C key Tab`, `$C key ArrowUp` (New command), `$C key Enter`, `$C type "Slash test"`, `$C key Enter`, `$C key ArrowDown`, `$C key Enter`, `$C type "/plotroom-echo"`, `$C key Enter`, `$C key Escape`.
    - Back on "Open PRs" with the same PR selected, `$C key 2`. "Slash test" is global, so it is the second command.
    - Expect a third agent in that tab to answer "plotroom-ok". If it answers about the literal text instead, record that slash commands aren't expanded when sent this way.
    - Delete the template file.
11. **Indicator clears** (pane_exited redraw).
    - After all agents are idle, `$C key g`, then `$C plugins run close_tab`. Idle agents close without confirmation.
    - The queue's tab shows again: it is the session's only remaining tab. Expect the "In tab" badge and the "Go to tab" button to disappear within about 3 s, without a key press.
12. **Delete confirmations** (confirm refactor).
    - Commands page: `$C key s`, `$C key Tab`, `$C key ArrowDown` ×5 (Name, Prompt, Filters, Only this repository, Delete command of "Echo PR"), `$C key Enter`.
      - Expect the modal "Delete command “Echo PR”?". `$C key Enter` deletes it and focus moves to "New command".
    - "Slash test": `$C key ArrowUp` (its Delete command), `$C key Enter`, `$C key Enter`.
    - Filters page: `$C key Shift+Tab`, `$C key ArrowUp` (New filter), `$C key ArrowUp` (Delete filter of "Open PRs"), `$C key Enter`.
      - Expect the modal "Delete filter “Open PRs”?". `$C key Enter`, then `$C key Escape`. The queue falls back to "My PRs".
13. **Store restored.**
    - kv.json again holds only `f1`/`f2` with their original names and queries, plus `"commands": []`. `nextId` has advanced, which is expected.
    - Diff against `/tmp/plotroom-kv.before.json` to confirm nothing else changed.
14. **Wrap up.**
    - `git -C /tmp/plotroom-fixture/cli worktree remove --force /tmp/plotroom-fixture/cli.plotroom/cli/cli/pr-N`
    - `$C session close`, `$C quit`.

## Assumptions & contingencies

- **Agent cwd not seen by the host.** If check 7 shows no "In tab" mark within about 5 s while a shell from the Worktree button (`w`) does get it:
  - In `finishAgent`, after starting, add `tern.timer(2000, function(cx3) if cx3 and cx3.session:pane(pane) then cx3.session:event(pane, { ev = "action", act = "redraw" }) end end)`. The host `event` needs no new branch: any handled event renders.
  - If the mark still never shows, `tern.pane.list()` doesn't report agent cwds. Stop and report; do not build a window→host push.
- **Renders from `tern.on`.** If the mark only updates after a key press (check 11): wrap the body of `redrawQueues` in `tern.timer(0, …)`.
- **Focus doesn't switch tabs.** If `cx.layout:focus` leaves the queue tab showing (checks 8 and 11): in `gotoPr`, before `focus`, run `cx:action("goto_tab:" .. position)`, using that tab's `position` from `cx.session:tabs()`.
- **Slash commands.** Prompts reach omp through `cx.agents:start`'s queued prompt. Whether omp expands `/name` sent that way is only observed in check 10; no workaround is planned.
- **Not covered by the smoke test.** The repo-scope filter (hiding a command on another repository) is one equality check in `commandsFor`. The smoke test only proves the saved `repo` value. A second fixture repo would be needed to see it hidden.
