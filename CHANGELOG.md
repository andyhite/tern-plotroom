# Changelog

All notable changes to Plotroom are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version in `plugin/plugin.toml` is the release; the protocol a window and its hosts speak is separate (see [docs/reference.md › Setup](docs/reference.md#setup), Remote hosts).

## [Unreleased]

### Added

- Commands › Configuration › Copy usage report: plain text with how often each queue action, Commands row, Tern's palette command and action ran (on this machine and on the block's host) and how each agent run ended, with the median run time. Counts live in kv `usage`, the newest 1000 runs in kv `runs`; nothing leaves the machine.
- Get started: a first-run checklist above the preview until every line is done or it is dismissed (Commands › Get started shows it again): `gh` installed and signed in, `omp` installed, a checkout for each listed repository without one, and the one-key shortcuts (Use them / No thanks). Each line not done has one action: a setup guide, **Use <folder>** for a checkout found, or a folder to choose (a new or empty one gets a clone).
- Checkout detection: a repository with no checkout is offered the folder Plotroom opened in, or the folder of an open Tern pane on the same host, when it is inside a checkout with a remote on that github.com repository (verified as Settings › Repositories verifies; the disk is never scanned). Worktree, an action and Type a prompt… offer it as **Use <folder>** before asking for a folder.

### Removed

- Commands: Add label… and Remove label…, Re-run all jobs… and Cancel running workflow…, Send a Browser page element to an agent…, and the Jira transition… picker with its REST client. `PLOTROOM_JIRA_API_TOKEN` is no longer read; an action's Move to status (acli) still moves Jira issues.
- The action field Tell Carly when it finishes and the `plotroom_agents` Carly export. Saved actions that carry it still load; the field is dropped the next time that kind's actions are saved.
- Export and import of views and actions.
- Open floating preview: Enter and Open show the item's page in Tern's Browser beside the queue.

### Changed

- Protocol 34: a repository's missing-checkout answer may name the folder found for it. A window still asks protocol 33 hosts, which ask for a folder as before.
- Protocol 33: a window asks only hosts that run this release (removed rpc ops raise the minimum).
- Settings has four pages: Views, Actions, Repositories and General (the GitHub and Jira setup pages still show while their CLI is missing). Repositories holds the name formats (formerly Worktrees), each repository and the Jira projects; General holds Keyboard shortcuts and Refresh now with the GitHub quota. Every setting keeps its value. Restore defaults is now **Add missing defaults**: it never overwrote edited defaults.
- Tern's palette lists only Plotroom: Open, Open item by URL, Message an agent with the selection… and Go to the first agent that needs input. Every other Plotroom command stays in Commands (`.`) with its key, and stays runnable by its action name `plugin.plotroom.<id>` (key binds, `tern ctl plugins run`).
- README.md is a product page (who Plotroom is for, the loop, screenshots, install and first run); the full behavior spec moved, unchanged, to [docs/reference.md](docs/reference.md), ordered by the loop's steps.
- UI text uses only PRODUCT.md's glossary: **Commands** (the `.` menu, its first group **Actions**), **Worktrees**, **Needs attention only**, **Snooze until tomorrow**, **Open** and **Open Git view**, and **Checkout** for the repository's main clone (an action's Runs in reads Worktree / Checkout; the shell lens offers Show in Plotroom, Copy, Open). Commands rows show an action's first line filled for the selected item, or no detail, never `{placeholders}`; the duplicate-agent offer names the action, not a pane; the protocol warning reads "Plotroom on <host> is a different version from this window's". Pickers say what Enter does; a GitHub view with no sort reads "Sort: GitHub's order"; the narrow layout's view dropdown no longer repeats the view's name as the title.

## [0.33.0] - 2026-11-02

### Added

- Product direction: PRODUCT.md (who Plotroom is for, the loop, principles, glossary, roadmap) and LEDGER.md (a verdict for every feature). Plotroom is built for Tern and omp developers beyond its author; GitHub comes first, Jira stays at its current depth; no rewrite. Features are frozen until Phase 0 (groundwork) is done.
- This changelog. Plotroom's version no longer tracks its protocol.
- A window works with a host one protocol older. Actions that host knows run as usual; an action it does not know is refused at once with a toast saying to install the current Plotroom on that host. A 0.32.0 host speaks this release's protocol.

### Changed

- The status-bar protocol warning and the "another version" toast name the host, and appear only for a host outside the supported protocol range.
