# dependency-checker

Scripts to check the state of GOV.UK dependencies. At the moment,
this repo includes:

- Checking for gems that are included both locally in an application,
  and in GOV.UK's own `govuk_app_config` gem. This way, we don't have
  to do duplicate Dependabot updates for unnecessary duplication.

- Some Ruby to get statistics on how many Dependabot PRs we've merged,
  split by `major`, `minor` and `patch` version. Used to inform how
  much work we do on Dependabot and how we approach the various
  version bumps.

- Statistics on "time to merge" Dependabot PRs, showing how many days
  have passed between Dependabot PRs being opened and merged. GitHub
  Search API has a limit of 1000 results, and that's before filtering
  out the non govuk repos, so we can only get statistics for the last
  few weeks. GitHub's Search API applies strict secondary rate-limiting,
  hence the need to stagger requests, which makes this a bit slow to run.

They all require `GITHUB_TOKEN` as an environment variable, with at
least `repo` scope.

There is also an Apps Script to pull dependency versions into a spreadsheet.