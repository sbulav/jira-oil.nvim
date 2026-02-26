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
