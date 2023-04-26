require "octokit"
require "net/http"
require "json"
require "date"

PAGINATION_LIMIT = 10
DAY_IN_SECONDS = 24 * 60 * 60

class Dependabot
  def client
    @client ||=
      Octokit::Client.new(
        access_token: ENV.fetch("GITHUB_TOKEN"),
        auto_paginate: false,
      )
  end

  def govuk_repos
    @govuk_repos ||=
      JSON.parse(
        Net::HTTP.get(
          URI("https://docs.publishing.service.gov.uk/repos.json"),
        ),
      )
          .map { |repo| "alphagov/#{repo['app_name']}" }
  end

  def get_dependency_name_and_version(title)
    # Extract the dependency name and version from the PR title.
    details = title.match(/^(?:(?:\[Security\]\ )?Bump|build\(deps.*\): bump) (.+) from (.+) to (.+)/) || title.match(/^Update (.+) requirement from (?:=|~>) (.+) to (?:=|~>)/)

    # There are a few PRs that don't have the expected structure.
    # We can ignore those since the number is low (for example, from 1040 PRs raised 33 have a different structure)
    # and it won't have a big impact on the final results
    return nil if details.nil?

    [details[1], details[2]]
  end

  def get_repo_prs(repo)
    repo_prs = []
    (1..PAGINATION_LIMIT).each do |page|
      repo_prs += client.list_issues(repo, { state: "all", labels: "dependencies", page: page })
    end
    repo_prs
  rescue Octokit::NotFound
    []
  end

  def dependabot_history_per_repo(repo)
    repo_dependabot_prs = {}

    get_repo_prs(repo).each do |pr|
      dependency_name, from_version = get_dependency_name_and_version(pr.title)

      next if dependency_name.nil?

      repo_dependabot_prs[dependency_name] = [] if repo_dependabot_prs[dependency_name].nil?
      repo_dependabot_prs[dependency_name] << {
        created_at: pr.created_at,
        merged_at: pr.pull_request["merged_at"],
        closed_at: pr.closed_at,
        from_version: from_version,
      }
    end
    repo_dependabot_prs
  end

  def get_repo_metrics(repo, from, to, outdated_limit)
    # Get the insights for each repository
    dependabot_prs = dependabot_history_per_repo(repo)

    total_opened_prs = 0
    time_to_merge = []
    time_since_open = []
    prs_per_dependency = Hash.new(0)
    open_prs_per_dependency = Hash.new(0)

    dependabot_prs.each do |dependency, prs|
      opened_prs = prs.filter { |pr| pr[:created_at].between?(from, to) }

      total_opened_prs += opened_prs.size
      prs_per_dependency[dependency] += opened_prs.size

      opened_prs.each do |opened_pr|
        # Get the date when the earliest PR for bumping the current version was created
        # In this way we include superseded PRs in our calculations
        created_at = dependabot_prs[dependency]
                     .filter { |pr| pr[:from_version] == opened_pr[:from_version] }
                     .map { |pr| pr[:created_at] }.min

        if opened_pr[:closed_at].nil?
          days_since_open = (Time.now - created_at).to_i / DAY_IN_SECONDS
          time_since_open << days_since_open
          open_prs_per_dependency[dependency] += 1
          puts "Dependency #{dependency} from #{repo} has been outdated for #{days_since_open} days" if days_since_open >= outdated_limit
        end

        next unless opened_pr[:merged_at]

        days_to_merge = (opened_pr[:merged_at] - created_at).to_i / DAY_IN_SECONDS
        time_to_merge << days_to_merge
        puts "Dependency #{dependency} from #{repo} was merged in #{days_to_merge} days" if days_to_merge >= outdated_limit
      end
    end

    {
      total_opened_prs: total_opened_prs,
      time_since_open: time_since_open,
      time_to_merge: time_to_merge,
      prs_per_dependency: prs_per_dependency,
      open_prs_per_dependency: open_prs_per_dependency,
    }
  end

  def time_to_merge_distribution(time_to_merge)
    distribution = Hash.new(0)
    time_to_merge.each { |days| distribution[days] += 1 }
    distribution.sort.to_h
  end

  def success_rate(total_prs, closed_prs)
    closed_prs / total_prs.to_f * 100
  end

  def frequently_updated_repos(from, to)
    repo_update_count = {}

    govuk_repos.each do |repo|
      repo_metrics = get_repo_metrics(repo, from, to, 0) # set outdated_limit to 0 to skip printing outdated dependencies
      repo_update_count[repo] = repo_metrics[:total_opened_prs]
    end

    repo_update_count.select { |_, count| count.positive? }.sort_by { |_, count| -count }
  end

  def dependabot_time_to_merge(from:, to:, days_range:, outdated_limit:)
    puts "Fetching dependabot PRs..."
    total_opened_prs = 0
    closed_prs = 0
    time_to_merge = []
    time_since_open = []
    prs_per_dependency = Hash.new(0)
    open_prs_per_dependency = Hash.new(0)

    if days_range
      to = Time.parse(Date.today.to_s)
      from = Time.parse((Date.today - days_range).to_s)
    elsif from && to
      from = Time.parse(from)
      to = Time.parse(to)
    else
      raise ArgumentError, "You must provide either --days-range or both --from and --to."
    end

    govuk_repos.each do |repo|
      repo_metrics = get_repo_metrics(repo, from, to, outdated_limit)
      total_opened_prs += repo_metrics[:total_opened_prs]
      closed_prs += repo_metrics[:time_to_merge].size
      time_to_merge += repo_metrics[:time_to_merge]
      time_since_open += repo_metrics[:time_since_open]

      repo_metrics[:prs_per_dependency].each do |dependency, count|
        prs_per_dependency[dependency] += count
      end

      repo_metrics[:open_prs_per_dependency].each do |dependency, count|
        open_prs_per_dependency[dependency] += count
      end
    end

    time_to_merge_distribution = time_to_merge_distribution(time_to_merge)
    pr_success_rate = success_rate(total_opened_prs, closed_prs)
    frequently_updated = frequently_updated_repos(from, to)

    puts ""
    puts "Between #{from} and #{to}:"
    puts "- Dependabot raised #{total_opened_prs} PRs"
    puts "- #{closed_prs} PRs were merged or closed"
    puts "- Success rate of PRs: #{pr_success_rate.round(2)}%"
    puts "- #{time_to_merge.size} were merged, within #{(time_to_merge.sum(0.0) / time_to_merge.size).round(2)} days on average, taking into account any superseded PRs."
    puts "- #{time_since_open.size} are still open. They've been open for an average of #{(time_since_open.sum(0.0) / time_since_open.size).round(2)} days, taking into account any superseded PRs."
    puts "Distribution of time-to-merge:"
    time_to_merge_distribution.each do |days, count|
      puts "#{days} days: #{count} PRs"
    end
    puts "Frequently updated repos:"
    frequently_updated.each { |repo, count| puts "#{repo}: #{count} PRs" }
    puts "Number of PRs per dependency:"
    prs_per_dependency
      .select { |_, count| count.positive? }
      .sort_by { |_, count| -count }
      .each { |dependency, count| puts "#{dependency}: #{count} PRs" }
    puts "Number of open PRs per dependency:"
    open_prs_per_dependency
      .select { |_, count| count.positive? }
      .sort_by { |_, count| -count }
      .each { |dependency, count| puts "#{dependency}: #{count} open PRs" }
  end
end
