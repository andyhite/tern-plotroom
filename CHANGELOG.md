# Changelog

All notable changes to Plotroom are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version in `plugin/plugin.toml` is the release; the protocol a window and its hosts speak is separate (see README › Install › Remote hosts).

## [Unreleased]

### Added

- Commands › Configuration › Copy usage report: plain text with how often each queue action, Commands row, palette command and action ran (on this machine and on the block's host) and how each agent run ended, with the median run time. Counts live in kv `usage`, the newest 1000 runs in kv `runs`; nothing leaves the machine.

### Removed

- Commands: Add label… and Remove label…, Re-run all jobs… and Cancel running workflow…, Send a Browser page element to an agent…, and the Jira transition… picker with its REST client. `PLOTROOM_JIRA_API_TOKEN` is no longer read; an action's Move to status (acli) still moves Jira issues.
- The action field Tell Carly when it finishes and the `plotroom_agents` Carly export. Saved actions that carry it still load; the field is dropped the next time that kind's actions are saved.
- Export and import of views and actions.
- Open floating preview: Enter and Open show the item's page in Tern's Browser beside the queue.

### Changed

- Protocol 33: a window asks only hosts that run this release (removed rpc ops raise the minimum).

## [0.33.0] - 2026-11-02

### Added

- Product direction: PRODUCT.md (who Plotroom is for, the loop, principles, glossary, roadmap) and LEDGER.md (a verdict for every feature). Plotroom is built for Tern and omp developers beyond its author; GitHub comes first, Jira stays at its current depth; no rewrite. Features are frozen until Phase 0 (groundwork) is done.
- This changelog. Plotroom's version no longer tracks its protocol.
- A window works with a host one protocol older. Actions that host knows run as usual; an action it does not know is refused at once with a toast saying to install the current Plotroom on that host. A 0.32.0 host speaks this release's protocol.

### Changed

- The status-bar protocol warning and the "another version" toast name the host, and appear only for a host outside the supported protocol range.
