require "octokit"
require "net/http"
require "json"
require "date"

class Dependabot
  def client
    @client ||=
      Octokit::Client.new(
        access_token: ENV.fetch("GITHUB_TOKEN"),
        auto_paginate: false,
      )
  end

  def govuk_repos
    [
      "alphagov/content-data-api",
      "alphagov/content-data-admin",
      "alphagov/datagovuk_find",
      "alphagov/govuk-puppet",
      "alphagov/whitehall",
    ]
  end

  def get_dependency_name_and_version(title)
    details = title.match(/^(?:(?:\[Security\]\ )?Bump|build\(deps.*\): bump) (.+) from (.+) to (.+)/) ||
      title.match(/^Update (.+) requirement from (?:=|~>) (.+) to (?:=|~>)/)

    return nil if details.nil?

    [details[1], details[2]]
  end

  def get_repo_prs(repo, from)
    repo_prs = []
    page = 1

    loop do
      puts "#{repo} page: #{page}"
      issues = client.list_issues(repo, { state: "all", labels: "dependencies", since: from, page: page, per_page: 100 })
      break if issues.empty?

      repo_prs += issues
      page += 1
    end

    repo_prs.select(&:pull_request)
  rescue Octokit::NotFound
    []
  end

  def dependabot_history_per_repo(repo, from)
    repo_dependabot_prs = {}

    get_repo_prs(repo, from).each do |pr|
      dependency_name, from_version = get_dependency_name_and_version(pr.title)

      next if dependency_name.nil?

      repo_dependabot_prs[dependency_name] = [] if repo_dependabot_prs[dependency_name].nil?
      repo_dependabot_prs[dependency_name] << {
        created_at: pr.created_at,
        merged_at: pr.pull_request["merged_at"],
        closed_at: pr.closed_at,
        from_version: from_version,
        pr_number: pr.number,
      }
    end
    repo_dependabot_prs
  end

  def fetch_checks_status(repo, pr_number)
    check_runs = client.check_runs_for_ref(repo, pr_number)
    check_runs.check_runs.map(&:conclusion)
  end

  def get_repo_metrics(repo, from, to, outdated_limit)
    dependabot_prs = dependabot_history_per_repo(repo, from)

    total_opened_prs = 0
    time_to_merge = []
    time_since_open = []
    prs_per_dependency = Hash.new(0)
    open_prs_per_dependency = Hash.new(0)
    outdated_dependencies = []
    long_merge_dependencies = []
    failing_prs = []

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
          days_since_open = (Date.today - created_at.to_date).to_i
          time_since_open << days_since_open
          open_prs_per_dependency[dependency] += 1

          if days_since_open >= outdated_limit
            outdated_dependencies << { dependency: dependency, repo: repo, days_outdated: days_since_open }
          end

          pr_number = opened_pr[:pr_number]
          pr_data = client.pull_request(repo, pr_number)
          commit_ref = pr_data[:head][:sha]
          check_conclusions = fetch_checks_status(repo, commit_ref)
          failing_checks = check_conclusions.count { |conclusion| conclusion != "success" && conclusion != "neutral" && conclusion != "skipped" }
          failing_prs << { dependency: dependency, repo: repo, pr_number: pr_number } if failing_checks.positive?
        end

        next unless opened_pr[:merged_at]

        days_to_merge = (opened_pr[:merged_at].to_date - created_at.to_date).to_i
        time_to_merge << days_to_merge

        if days_to_merge >= outdated_limit
          long_merge_dependencies << { dependency: dependency, repo: repo, days_to_merge: days_to_merge }
        end
      end
    end

    {
      total_opened_prs: total_opened_prs,
      time_since_open: time_since_open,
      time_to_merge: time_to_merge,
      prs_per_dependency: prs_per_dependency,
      open_prs_per_dependency: open_prs_per_dependency,
      outdated_dependencies: outdated_dependencies,
      long_merge_dependencies: long_merge_dependencies,
      dependabot_history: dependabot_prs,
      failing_prs: failing_prs,
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

  def dependabot_time_to_merge(from:, to:, outdated_limit:, output_format: "CLI")
    metrics = calculate_metrics(from: from, to: to, outdated_limit: outdated_limit)
    display_metrics(metrics, output_format, outdated_limit)
  end

  def calculate_metrics(from:, to:, outdated_limit:)
    from = Time.parse(from)
    to = Time.parse(to)
    total_opened_prs = 0
    closed_prs = 0
    time_to_merge = []
    time_since_open = []
    prs_per_dependency = Hash.new(0)
    open_prs_per_dependency = Hash.new(0)
    frequently_updated = {}
    outdated_dependencies = []
    long_merge_dependencies = []
    pr_data = []
    failing_prs = []

    govuk_repos.each do |repo|
      repo_metrics = get_repo_metrics(repo, from, to, outdated_limit)
      total_opened_prs += repo_metrics[:total_opened_prs]
      closed_prs += repo_metrics[:time_to_merge].size
      time_to_merge += repo_metrics[:time_to_merge]
      time_since_open += repo_metrics[:time_since_open]
      failing_prs += repo_metrics[:failing_prs]

      repo_metrics[:prs_per_dependency].each do |dependency, count|
        prs_per_dependency[dependency] += count
      end

      repo_metrics[:open_prs_per_dependency].each do |dependency, count|
        open_prs_per_dependency[dependency] += count
      end

      outdated_dependencies += repo_metrics[:outdated_dependencies]
      long_merge_dependencies += repo_metrics[:long_merge_dependencies]
      frequently_updated[repo] = repo_metrics[:total_opened_prs]

      repo_metrics[:prs_data] = []
      repo_metrics[:dependabot_history].each do |dependency, prs|
        opened_prs = prs.filter { |pr| pr[:created_at].between?(from, to) }

        opened_prs.each do |opened_pr|
          pr_data_item = {
            repo: repo,
            dependency: dependency,
            created_at: opened_pr[:created_at],
            merged_at: opened_pr[:merged_at],
            closed_at: opened_pr[:closed_at],
            from_version: opened_pr[:from_version],
          }
          pr_data << pr_data_item
          repo_metrics[:prs_data] << pr_data_item
        end
      end
    end

    time_to_merge_distribution = time_to_merge_distribution(time_to_merge)
    pr_success_rate = success_rate(total_opened_prs, closed_prs)
    frequently_updated = frequently_updated.select { |_, count| count.positive? }.sort_by { |_, count| -count }.to_h
    prs_per_dependency = prs_per_dependency.select { |_, count| count.positive? }.sort_by { |_, count| -count }.to_h
    open_prs_per_dependency = open_prs_per_dependency.select { |_, count| count.positive? }.sort_by { |_, count| -count }.to_h

    {
      from: from,
      to: to,
      total_opened_prs: total_opened_prs,
      closed_prs: closed_prs,
      pr_success_rate: pr_success_rate,
      average_time_to_merge: (time_to_merge.sum(0.0) / time_to_merge.size).round(2),
      average_time_since_open: (time_since_open.sum(0.0) / time_since_open.size).round(2),
      time_to_merge_distribution: time_to_merge_distribution,
      frequently_updated: frequently_updated,
      prs_per_dependency: prs_per_dependency,
      open_prs_per_dependency: open_prs_per_dependency,
      time_to_merge_count: time_to_merge.size,
      time_since_open_count: time_since_open.size,
      outdated_dependencies: outdated_dependencies,
      long_merge_dependencies: long_merge_dependencies,
      failing_prs: failing_prs,
      pr_data: pr_data,
    }
  end

  def display_metrics(metrics, output_format, outdated_limit)
    case output_format
    when "CLI"
      puts ""
      puts "Between #{metrics[:from]} and #{metrics[:to]}:"
      puts "- Dependabot raised #{metrics[:total_opened_prs]} PRs (total number of pull requests created by Dependabot)"
      puts "- #{metrics[:closed_prs]} PRs were merged or closed (total number of pull requests that were either merged or closed without merging)"
      puts "- Success rate of PRs: #{metrics[:pr_success_rate].round(2)}% (percentage of pull requests that were successfully merged)"
      puts "- #{metrics[:time_to_merge_count]} were merged, within #{metrics[:average_time_to_merge]} days on average, taking into account any superseded PRs (average time taken to merge a pull request, including those that were superseded by newer PRs)"
      puts "- #{metrics[:time_since_open_count]} are still open. They've been open for an average of #{metrics[:average_time_since_open]} days, taking into account any superseded PRs (average time that open pull requests have been waiting to be merged, including those superseded by newer PRs)"
      puts ""
      puts "#- Failing PRs:"
      puts metrics[:failing_prs].empty? ? "no PRs have failing checks" : metrics[:failing_prs].map { |item| "#{item[:repo]} - #{item[:dependency]} - PR ##{item[:pr_number]}" }
      puts ""
      puts "- Distribution of time-to-merge (number of pull requests grouped by the number of days taken to merge):"
      metrics[:time_to_merge_distribution].each do |days, count|
        puts "#{days} days: #{count} PRs"
      end
      puts ""
      puts "- Frequently updated repos (repositories with the highest number of pull requests created by Dependabot):"
      metrics[:frequently_updated].each { |repo, count| puts "#{repo}: #{count} PRs" }
      puts ""
      puts "- Number of PRs per dependency (total number of pull requests created for each dependency):"
      metrics[:prs_per_dependency].each { |dependency, count| puts "#{dependency}: #{count} PRs" }
      puts ""
      puts "- Number of open PRs per dependency (number of pull requests that are still open for each dependency):"
      metrics[:open_prs_per_dependency].each { |dependency, count| puts "#{dependency}: #{count} PRs" }
      puts ""
      puts "- Dependencies that have been outdated for more than #{outdated_limit} days (dependencies with open pull requests that have not been merged for a specified number of days):"
      metrics[:outdated_dependencies].each do |dependency_info|
        puts "Dependency #{dependency_info[:dependency]} from #{dependency_info[:repo]} has been outdated for #{dependency_info[:days_outdated]} days"
      end
      puts ""
      puts "- Dependencies that took more than #{outdated_limit} days to merge (dependencies with pull requests that took longer than a specified number of days to merge):"
      metrics[:long_merge_dependencies].each do |dependency_info|
        puts "Dependency #{dependency_info[:dependency]} from #{dependency_info[:repo]} was merged in #{dependency_info[:days_to_merge]} days"
      end
    when "json"
      json_output = {
        range: {
          from: metrics[:from].strftime("%Y-%m-%dT%H:%M:%SZ"),
          to: metrics[:to].strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        summary: {
          total_opened_prs: metrics[:total_opened_prs],
          closed_prs: metrics[:closed_prs],
          pr_success_rate: metrics[:pr_success_rate].round(2),
          average_time_to_merge: metrics[:average_time_to_merge],
          average_time_since_open: metrics[:average_time_since_open],
          time_to_merge_count: metrics[:time_to_merge_count],
          time_since_open_count: metrics[:time_since_open_count],
        },
        time_to_merge_distribution: metrics[:time_to_merge_distribution],
        frequently_updated: metrics[:frequently_updated],
        prs_per_dependency: metrics[:prs_per_dependency],
        open_prs_per_dependency: metrics[:open_prs_per_dependency],
        outdated_dependencies: metrics[:outdated_dependencies],
        long_merge_dependencies: metrics[:long_merge_dependencies],
        failing_prs: metrics[:failing_prs],
        pr_data: metrics[:pr_data],
      }

      puts JSON.pretty_generate(json_output)
    when "csv"
      # Display the results in CSV format
      # ...
    else
      raise "Invalid output format: #{output_format}"
    end
  end
end
