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

They all require `GITHUB_TOKEN` as an environment variable, with at
least `repo` scope.

Owned by GOV.UK Platform Health.
