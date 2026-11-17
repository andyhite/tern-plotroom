# Security

## Reporting a vulnerability

Report privately: open a [private security advisory](https://github.com/andyhite/tern-plotroom/security/advisories/new) on GitHub. Do not file a public issue for a vulnerability.

Include the Plotroom version (`plugin/plugin.toml`), what you did, and what happened.

## Scope

Plotroom runs agents with your project's code and writes to GitHub and Jira through `gh` and `acli`. In scope: anything that breaks the [Trust](docs/reference.md#trust) model, such as:

- a command run or a mutation made without the confirm the reference describes;
- a prompt, item field or link that makes Plotroom run something other than the argv it builds;
- credentials or private data stored or shown where the reference says they are not.

Out of scope: what an agent does once you start it (it runs with your permissions), and bugs in `gh`, `acli`, `omp`, `git` or Tern themselves.
