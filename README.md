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
  have passed between Dependabot PRs being opened and merged. We are
  retrieving maximum 300 PRs per repository, so we won't have accurate
  statistics for the PRs opened a few months in the past. The script
  takes around 15 minutes to run.

  ```
  ./dependabot_time_to_merge --from 2023-03-27 --to 2023-03-28 --outdated-limit 30
  ```

  `--outdated-limit` option is used for displaying which dependencies were outdated
  for more than X number of days (default value is 20)

They all require `GITHUB_TOKEN` as an environment variable, with at
least `repo` scope.
