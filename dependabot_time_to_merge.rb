require "date"
require "json"
require "net/http"
require "octokit"
require "prometheus/client"
require "prometheus/client/push"

PROMETHEUS_PUSHGATEWAY_URL = ENV.fetch("PROMETHEUS_PUSHGATEWAY_URL")

METRIC_DEFINITIONS = [
  { name: :total_opened_prs, type: Prometheus::Client::Gauge, docstring: "Total pull requests", labels: %i[timestamp repo_name dependency_name] },
  { name: :total_failing_prs, type: Prometheus::Client::Gauge, docstring: "Total failing PRs", labels: %i[timestamp repo_name dependency_name] },
  { name: :time_since_open_count, type: Prometheus::Client::Gauge, docstring: "Open pull requests", labels: %i[timestamp repo_name dependency_name] },
  { name: :closed_without_merging, type: Prometheus::Client::Gauge, docstring: "Closed pull requests", labels: %i[timestamp repo_name dependency_name] },
  { name: :merged_prs, type: Prometheus::Client::Gauge, docstring: "Merged pull requests", labels: %i[timestamp repo_name dependency_name] },
  { name: :total_security_alerts, type: Prometheus::Client::Gauge, docstring: "Total security alerts", labels: [:timestamp] },
  { name: :major_update_percentage, type: Prometheus::Client::Gauge, docstring: "Major update PRs raised", labels: [:timestamp] },
  { name: :minor_update_percentage, type: Prometheus::Client::Gauge, docstring: "Minor update PRs raised", labels: [:timestamp] },
  { name: :patch_update_percentage, type: Prometheus::Client::Gauge, docstring: "Patch update PRs raised", labels: [:timestamp] },
  { name: :average_time_to_merge, type: Prometheus::Client::Gauge, docstring: "Average time to merge a PR", labels: [:timestamp] },
  { name: :average_time_since_open, type: Prometheus::Client::Gauge, docstring: "Average time open PRs have been waiting (including superseded PRs)", labels: [:timestamp] },
  { name: :time_to_merge_distribution, type: Prometheus::Client::Histogram, docstring: "Time-to-merge distribution", labels: [:timestamp] },
  { name: :frequently_updated_repos, type: Prometheus::Client::Gauge, docstring: "Frequently updated repos", labels: [:timestamp, :repo_name] },
  { name: :prs_per_dependency, type: Prometheus::Client::Gauge, docstring: "Number of PRs per dependency", labels: [:timestamp, :dependency_name] },
  { name: :open_prs_per_dependency, type: Prometheus::Client::Gauge, docstring: "Number of open PRs per dependency", labels: [:timestamp, :dependency_name] },
  { name: :security_alerts_per_repo, type: Prometheus::Client::Gauge, docstring: "Security alerts per repo", labels: [:timestamp, :repo_name] },
  { name: :security_alerts_per_dependency, type: Prometheus::Client::Gauge, docstring: "Security alerts per dependency", labels: [:timestamp, :dependency_name] },
  { name: :outdated_dependencies, type: Prometheus::Client::Gauge, docstring: "Dependencies outdated for more than 20 days", labels: %i[:timestamp, dependency_name repo_name days_outdated] },
  { name: :long_merge_dependencies, type: Prometheus::Client::Gauge, docstring: "Dependencies that took more than 20 days to merge", labels: %i[:timestamp, dependency_name repo_name days_to_merge] },
].freeze

class Dependabot
  def client
    @client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: false)
  end

  def govuk_repos
    @govuk_repos ||=
      JSON.parse(Net::HTTP.get(URI("https://docs.publishing.service.gov.uk/repos.json"))).map { |repo| "alphagov/#{repo['app_name']}" }
  end

  def match_title(title)
    title.match(/^(?:(?:\[Security\]\ )?Bump|build\(deps.*\): bump) (.+) from (.+) to (.+)/) ||
      title.match(/^Update (.+) requirement from (?:=|~>) (.+) to (?:=|~>)(.+)/)
  end

  def determine_update_type(from_version_parts, to_version_parts)
    if from_version_parts[0] != to_version_parts[0]
      "major"
    elsif from_version_parts[1] != to_version_parts[1]
      "minor"
    else
      "patch"
    end
  end

  def get_dependency_name_and_version(title)
    details = match_title(title)
    return nil if details.nil?

    from_version_parts = details[2].split(".")
    to_version_parts = details[3].split(".")
    update_type = determine_update_type(from_version_parts, to_version_parts)
    [details[1], details[2], update_type]
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

  def fetch_security_alerts(repo)
    client.get("https://api.github.com/repos/#{repo}/dependabot/alerts", accept: "application/vnd.github+json", state: "open")
  rescue StandardError => e
    puts e.message
    []
  end

  def dependabot_history_per_repo(repo, from)
    repo_dependabot_prs = {}

    get_repo_prs(repo, from).each do |pr|
      dependency_name, from_version, update_type = get_dependency_name_and_version(pr.title)

      next if dependency_name.nil?

      repo_dependabot_prs[dependency_name] = [] if repo_dependabot_prs[dependency_name].nil?
      repo_dependabot_prs[dependency_name] << {
        created_at: pr.created_at,
        merged_at: pr.pull_request["merged_at"],
        closed_at: pr.closed_at,
        from_version: from_version,
        pr_number: pr.number,
        update_type: update_type,
      }
    end
    repo_dependabot_prs
  end

  def fetch_checks_status(repo, commit_ref)
    check_runs = client.check_runs_for_ref(repo, commit_ref)
    check_runs.check_runs.map(&:conclusion)
  rescue Octokit::BadGateway => e
    puts "Error: #{e.message}"
    []
  end

  def process_pr(metrics, opened_pr, created_at, dependency, repo, outdated_limit)
    update_type = opened_pr[:update_type]
    metrics["#{update_type}_updates".to_sym] += 1

    if opened_pr[:closed_at].nil?
      days_since_open = (Date.today - created_at.to_date).to_i
      metrics[:time_since_open] << days_since_open
      metrics[:open_prs_per_dependency][dependency] += 1

      if days_since_open >= outdated_limit
        metrics[:outdated_dependencies] << { dependency: dependency, repo: repo, days_outdated: days_since_open }
      end

      pr_number = opened_pr[:pr_number]
      pr_data = client.pull_request(repo, pr_number)
      commit_ref = pr_data[:head][:sha]
      check_conclusions = fetch_checks_status(repo, commit_ref)
      failing_checks = check_conclusions.count { |conclusion| conclusion != "success" && conclusion != "neutral" && conclusion != "skipped" }
      metrics[:failing_prs] << { dependency: dependency, repo: repo, pr_number: pr_number } if failing_checks.positive?
    elsif !opened_pr[:merged_at]
      metrics[:closed_without_merging] += 1
    else
      days_to_merge = (opened_pr[:merged_at].to_date - created_at.to_date).to_i
      metrics[:time_to_merge] << days_to_merge

      if days_to_merge >= outdated_limit
        metrics[:long_merge_dependencies] << { dependency: dependency, repo: repo, days_to_merge: days_to_merge }
      end
    end
  end

  def get_repo_metrics(repo, from, to, outdated_limit)
    dependabot_prs = dependabot_history_per_repo(repo, from)
    metrics = {
      total_opened_prs: 0,
      time_since_open: [],
      time_to_merge: [],
      prs_per_dependency: Hash.new(0),
      open_prs_per_dependency: Hash.new(0),
      outdated_dependencies: [],
      long_merge_dependencies: [],
      dependabot_history: dependabot_prs,
      failing_prs: [],
      closed_without_merging: 0,
      major_updates: 0,
      minor_updates: 0,
      patch_updates: 0,
    }

    update_types = %w[major minor patch]
    update_types.each { |type| metrics["#{type}_updates"] = 0 }

    dependabot_prs.each do |dependency, prs|
      opened_prs = prs.filter { |pr| pr[:created_at].between?(from, to) }
      metrics[:total_opened_prs] += opened_prs.size
      metrics[:prs_per_dependency][dependency] += opened_prs.size

      opened_prs.each do |opened_pr|
        created_at = dependabot_prs[dependency]
                     .filter { |pr| pr[:from_version] == opened_pr[:from_version] }
                     .map { |pr| pr[:created_at] }.min

        process_pr(metrics, opened_pr, created_at, dependency, repo, outdated_limit)
      end
    end

    metrics[:security_alerts] = fetch_security_alerts(repo)
    metrics[:repo_name] = repo
    metrics
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
    if output_format == "prometheus"
      push_to_prometheus(metrics)
    else
      display_metrics(metrics, output_format, outdated_limit)
    end
  end

  def calculate_metrics(from:, to:, outdated_limit:)
    from_time = Time.parse(from)
    to_time = Time.parse(to)

    metrics = {
      total_opened_prs: 0,
      merged_prs: 0,
      closed_without_merging: 0,
      major_updates: 0,
      minor_updates: 0,
      patch_updates: 0,
      prs_per_dependency: Hash.new(0),
      open_prs_per_dependency: Hash.new(0),
      frequently_updated_repos: Hash.new(0),
      outdated_dependencies: [],
      long_merge_dependencies: [],
      failing_prs: [],
      time_to_merge: [],
      time_since_open: [],
      security_alerts_per_repo: Hash.new(0),
      security_alerts_per_dependency: Hash.new(0),
      total_security_alerts: 0,
      total_failing_prs: 0,
    }

    govuk_repos.each do |repo|
      repo_metrics = get_repo_metrics(repo, from_time, to_time, outdated_limit)
      update_metrics(metrics, repo_metrics)
    end

    metrics[:time_to_merge_distribution] = time_to_merge_distribution(metrics[:time_to_merge])
    metrics[:pr_success_rate] = success_rate(metrics[:total_opened_prs], metrics[:time_to_merge].size + metrics[:closed_without_merging])
    metrics[:frequently_updated_repos] = sort_and_filter_count(metrics[:frequently_updated_repos])
    metrics[:prs_per_dependency] = sort_and_filter_count(metrics[:prs_per_dependency])
    metrics[:open_prs_per_dependency] = sort_and_filter_count(metrics[:open_prs_per_dependency])

    metrics[:major_update_percentage] = (metrics[:major_updates].to_f / metrics[:total_opened_prs] * 100).round(2)
    metrics[:minor_update_percentage] = (metrics[:minor_updates].to_f / metrics[:total_opened_prs] * 100).round(2)
    metrics[:patch_update_percentage] = (metrics[:patch_updates].to_f / metrics[:total_opened_prs] * 100).round(2)

    metrics[:from] = from_time
    metrics[:to] = to_time
    metrics[:average_time_to_merge] = average_time(metrics[:time_to_merge])
    metrics[:average_time_since_open] = average_time(metrics[:time_since_open])
    metrics[:time_since_open_count] = metrics[:time_since_open].size
    metrics[:merged_prs] = metrics[:time_to_merge].size
    metrics[:security_alerts_per_dependency] = sort_and_filter_count(metrics[:security_alerts_per_dependency])
    metrics[:security_alerts_per_repo] = sort_and_filter_count(metrics[:security_alerts_per_repo])
    metrics[:total_security_alerts] = metrics[:security_alerts_per_repo].values.sum
    metrics[:total_failing_prs] = metrics[:failing_prs].count

    metrics
  end

  def update_metrics(metrics, repo_metrics)
    metrics.each_key do |key|
      case metrics[key]
      when Hash
        repo_metrics[key].each { |dependency, count| metrics[key][dependency] += count } unless repo_metrics[key].nil?
      when Array
        metrics[key] += repo_metrics[key] unless repo_metrics[key].nil?
      when Numeric
        metrics[key] += repo_metrics[key] unless repo_metrics[key].nil?
      end
    end

    repo_name = repo_metrics[:repo_name]
    if repo_name
      metrics[:frequently_updated_repos][repo_name] = repo_metrics[:total_opened_prs]

      repo_metrics[:security_alerts].each do |alert|
        dependency_name = alert[:dependency][:package][:name]

        metrics[:security_alerts_per_repo][repo_name] ||= 0
        metrics[:security_alerts_per_repo][repo_name] += 1
        metrics[:security_alerts_per_dependency][dependency_name] ||= 0
        metrics[:security_alerts_per_dependency][dependency_name] += 1
      end
    end
  end

  def sort_and_filter_count(count_hash)
    count_hash.select { |_, count| count.positive? }.sort_by { |_, count| -count }.to_h
  end

  def average_time(time_values)
    (time_values.sum(0.0) / time_values.size).round(2)
  end

  def push_to_prometheus(metrics)
    prometheus = Prometheus::Client.registry

    METRIC_DEFINITIONS.each do |definition|
      metric = prometheus.get(definition[:name]) || prometheus.register(definition[:type].new(definition[:name], docstring: definition[:docstring], labels: definition[:labels] || []))
      metric_value = metrics[definition[:name]]

      if metric_value.nil?
        puts "Error: metric_value is nil for #{definition[:name]}"
        next
      end

      case metric
      when Prometheus::Client::Gauge
        if definition[:labels]
          if definition[:name] == :outdated_dependencies || definition[:name] == :long_merge_dependencies
            metric_value.each do |entry|
              label_values = definition[:labels].map { |label| [label, entry[label]] }.to_h.transform_keys(&:to_sym)
              metric.set(1, labels: label_values)
            end
          else
            metric_value.each do |label_value, value|
              metric.set(value, labels: { definition[:labels][0] => label_value })
            end
          end
        else
          metric.set(metric_value)
        end
      when Prometheus::Client::Histogram
        metric_value.each do |bucket, count|
          count.times { metric.observe(bucket) }
        end
      else
        puts "Error: Unhandled metric type for #{definition[:name]}"
      end
    end

    Prometheus::Client::Push.new(job: 'dependabot_metrics', gateway: PROMETHEUS_PUSHGATEWAY_URL).add(prometheus)
  end

  def display_metrics(metrics, output_format, outdated_limit)
    case output_format
    when "CLI"
      puts ""
      puts "Dependabot Metrics (from #{metrics[:from]} to #{metrics[:to]}):"
      puts "-----------------------------------------------------------------"
      puts "Total PRs raised by Dependabot: #{metrics[:total_opened_prs]}"
      puts "  (The total number of pull requests opened by Dependabot during the specified time period)"
      puts ""
      puts "% PRs raised by update type:"
      puts "Major: #{metrics[:major_update_percentage]}%"
      puts "Minor: #{metrics[:minor_update_percentage]}%"
      puts "Patch: #{metrics[:patch_update_percentage]}%"
      puts "  (The percentage of pull requests opened by Dependabot during the specified time period classified into major, minor and patch update type)"
      puts ""
      puts "Total PRs merged: #{metrics[:merged_prs]}"
      puts "  (The total number of pull requests merged during the specified time period)"
      puts ""
      puts "Total PRs closed: #{metrics[:closed_without_merging]}"
      puts "  (The total number of pull requests closed without merging during the specified time period)"
      puts ""
      puts "Total PRs still open: #{metrics[:time_since_open_count]}"
      puts "  (The total number of pull requests opened by Dependabot during the specified time period that are still open)"
      puts ""
      puts "PR success rate: #{metrics[:pr_success_rate].round(2)}%"
      puts "  (The percentage of Dependabot PRs that have been successfully merged not counting PRs closed without)"
      puts ""
      puts "Average time to merge a PR (including superseded PRs): #{metrics[:average_time_to_merge]} days"
      puts "  (The average number of days it takes to merge a Dependabot PR, including those that were superseded by newer PRs)"
      puts ""
      puts "Average time open PRs have been waiting (including superseded PRs): #{metrics[:average_time_since_open]} days"
      puts "  (The average number of days that open Dependabot PRs have been waiting for a merge, including those that were superseded by newer PRs)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "#{metrics[:total_failing_prs]} Failing PRs:"
      puts metrics[:total_failing_prs].zero? ? "" : metrics[:failing_prs].map { |item| "#{item[:repo]} - #{item[:dependency]} - PR ##{item[:pr_number]}" }
      puts "  (A list of open Dependabot PRs that currently have failing checks)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Time-to-Merge Distribution:"
      metrics[:time_to_merge_distribution].each do |days, count|
        puts "#{days} days: #{count} PRs"
      end
      puts "  (A distribution of the number of days it takes to merge Dependabot PRs)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Frequently Updated Repos:"
      metrics[:frequently_updated_repos].each { |repo, count| puts "#{repo}: #{count} PRs" }
      puts "  (A list of repositories that receive the most frequent Dependabot PRs)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Number of PRs per Dependency:"
      metrics[:prs_per_dependency].each { |dependency, count| puts "#{dependency}: #{count} PRs" }
      puts "  (A breakdown of the number of Dependabot PRs per dependency)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Number of Open PRs per Dependency:"
      metrics[:open_prs_per_dependency].each { |dependency, count| puts "#{dependency}: #{count} PRs" }
      puts "  (A breakdown of the number of open Dependabot PRs per dependency)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Total Security Alerts: #{metrics[:total_security_alerts]}"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Security Alerts per Repo:"
      metrics[:security_alerts_per_repo].each { |repo, count| puts "#{repo}: #{count}" }
      puts "  (A breakdown of the number of open security alerts per repository)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Security Alerts per Dependency:"
      metrics[:security_alerts_per_dependency].each { |dependency, count| puts "#{dependency}: #{count}" }
      puts "  (A breakdown of the number of open security alerts per dependency)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "Dependencies Outdated for More Than #{outdated_limit} Days:"
      metrics[:outdated_dependencies].each do |dependency_info|
        puts "#{dependency_info[:dependency]} from #{dependency_info[:repo]}: #{dependency_info[:days_outdated]} days"
      end
      puts "  (A list of dependencies that have had open Dependabot PRs for more than the specified number of days, indicating that they may require attention)"
      puts ""
      puts "-----------------------------------------------------------------"
      puts "- Dependencies that took more than #{outdated_limit} days to merge (dependencies with pull requests that took longer than a specified number of days to merge):"
      metrics[:long_merge_dependencies].each do |dependency_info|
        puts "Dependency #{dependency_info[:dependency]} from #{dependency_info[:repo]} was merged in #{dependency_info[:days_to_merge]} days"
      end
    else
      raise "Invalid output format: #{output_format}"
    end
  end
end