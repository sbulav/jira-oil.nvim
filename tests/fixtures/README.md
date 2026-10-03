# CLI output fixtures

`active-sprints.tsv` was captured from an authenticated Jira instance using:

```sh
jira sprint list --state active --table --plain --columns id,state
```

Only the public column headers, separators, and state values are retained.
Every sprint ID is replaced with a synthetic ID starting at 101. Names,
project/board identifiers, dates, users, hostnames, and authentication data
are not included. The original capture stays outside the repository.
