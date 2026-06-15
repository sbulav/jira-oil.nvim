# Contributing

Thanks for contributing to `jira-oil.nvim`.

## Keep Instance Data Local

This plugin is intended to work across Jira tenants. Do not commit organization-specific values to the repository.

Examples that must stay in local config:

- Jira project keys in `defaults.project`
- Team/group JQL in `cli.issues.team_jql`
- Personal assignee filters in `cli.epics.args` (for example `-a <user>`)
- Tenant-specific custom fields (for example `epic_field = "customfield_xxxxx"`)
- Internal component names in `create.available_components`

Use generic placeholders in docs and examples (`PROJ`, `TEAM_JQL`, etc.).

## Tests

Pure logic (URI build/parse, the line parser, label/assignee helpers) is covered
by a small headless-Neovim suite. Run it with:

```sh
make test
# or:
nvim --clean -l tests/run.lua
```

Add cases by dropping a `tests/<name>_spec.lua` file that calls
`require("minitest").test(...)`; `tests/run.lua` discovers `*_spec.lua`
automatically. The runner exits non-zero on any failure, so it is CI-friendly.
