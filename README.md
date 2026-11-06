# GGX run evaluation

Runs GGX reports on the agents of a pull request, at the head commit of the pull request, and waits for the result.
GGX writes the result on the pull request as one comment that later runs edit in place: it does so through the GitHub
connection of the GGX user whose API key the workflow uses, so the workflow sends GGX no GitHub token.

```yaml
- uses: GenGuardX/run-eval@v1
  with:
    ggx-url: ${{ vars.GGX_URL }}
    ggx-api-key: ${{ secrets.GGX_API_KEY }}
    project: my-project
    reports: "Agent Response Stats"
    data-tables: "Support questions"
    max-rows: "25"
```

The agents that run are registered in GGX as Code Repo agents of the pull request, so the runs over its commits are
listed under the agent in the GGX UI. Setup, permissions and the API key are in
the GGX documentation (`docs/integrations/github-actions.md` in the GGX repository).

## Inputs

| Input | Default | |
|---|---|---|
| `ggx-url` | required | Base URL of GGX. |
| `ggx-api-key` | required | API key of the GGX user that runs the evaluations (a secret). |
| `project` | required | Slug of the GGX project with the Code Repo of this repository, the reports and the data. |
| `reports` | required | Report names, separated by commas or lines. The default tier. |
| `full-reports` | | Report names of the full tier, which runs when a comment starts the workflow. |
| `tier` | `auto` | Name of the set of reports: `full` for a comment, `default` otherwise. One comment and one set of runs per tier and commit. |
| `agents` | `changed` | `changed` (the agents whose code the pull request changes), `all`, or `module:attribute` entries. |
| `python-path` | | Folders the explicit entries are imported from, separated by `:` as in PYTHONPATH (the first one wins). |
| `data-tables` | | Names of the GGX data tables the reports run on. |
| `data-definition` | | Code that prepares the dataset from the tables. Default: the first table. |
| `report-data` | `{}` | JSON object with the report parameters, by alias. |
| `max-rows` | | Sample size, for a quick check. |
| `timeout-minutes` | `30` | How long to wait. The run goes on in GGX after that. |
| `poll-interval-seconds` | `15` | |
| `comment` | `true` | Have GGX write and update the comment. |
| `commit-status` | `false` | Also set the commit status `ggx/<tier>` (`statuses: write`). |
| `fail-on-error` | `true` | Fail the step when a run fails or does not finish. |
| `github-token` | `github.token` | Reads the pull request (head commit, changed files) and sets the commit status. Stays on the runner. |
| `pr-number` | | For events other than `pull_request` and `issue_comment`. |

## Outputs

`status` (`completed`, `failed`, `timeout` or `skipped` for a pull request from a fork), `run-ids`, `dashboard-urls`
(JSON arrays), `comment-url` and `summary` (the Markdown of the comment).

## Behaviour

- Only pull requests from a branch of the same repository run. A fork is skipped with a notice.
- Starting again for the same pull request, commit and tier returns the runs started before instead of paying for
  new ones. A run that failed is started again.
- The GGX API key and the token never appear in a command line or the log; the action needs only `bash`, `curl` and
  `jq`, which GitHub-hosted runners have.
- The `GITHUB_TOKEN` is not sent to GGX. The workflow needs `contents: read` and `pull-requests: read` to read the pull
  request (and `statuses: write` for `commit-status`). GGX fetches the branch and writes the comment with the GitHub
  connection of its user, which needs the GitHub App installed on the repository.
- The comment is edited when the first request for the run after it ended arrives, which is the last poll of this
  action. If the step stops waiting (`timeout-minutes`), the comment shows the state of the runs until somebody reads
  them again.

## Example workflow

Runs the quick reports on the agents a pull request changes, every time it gets a commit. Copy it to
`.github/workflows/ggx-pr.yml` of your repository.

```yaml
# Copy to .github/workflows/ggx-pr.yml of your repository.
#
# Runs the quick reports of GGX on the agents a pull request changes, every time the pull request gets a commit.
# The result is one comment on the pull request, edited in place, with a link to the GGX dashboard of each run.
#
# Needs the repository secret GGX_API_KEY and the repository variable GGX_URL. Pin the action to a commit SHA.
name: GGX evaluation

on:
  pull_request:
    types: [opened, synchronize, reopened]

# A newer commit makes the evaluation of the older one pointless
concurrency:
  group: ggx-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: read # The action reads the pull request; GGX writes the comment itself
  statuses: write # Only for commit-status: "true"

jobs:
  evaluate:
    # Pull requests from forks get no secrets and are not evaluated
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: GenGuardX/run-eval@v1
        with:
          ggx-url: ${{ vars.GGX_URL }}
          ggx-api-key: ${{ secrets.GGX_API_KEY }}
          project: my-project # The slug of the GGX project that has this repository as a Code Repo
          reports: "Agent Response Stats" # The names of the reports of the smoke tier, separated by commas
          data-tables: "Support questions" # The GGX data table the reports run on
          max-rows: "25" # A sample, so that every commit is cheap
          agents: changed # or "all", or "package.module:agent" entries
          commit-status: "false"
```
