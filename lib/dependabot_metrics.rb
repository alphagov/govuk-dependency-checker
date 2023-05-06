require 'net/http'
require 'json'
require 'octokit'
require 'date'
require 'prometheus/client'
require 'prometheus/client/push'

# PROMETHEUS_PUSHGATEWAY_URL = ENV.fetch("PROMETHEUS_PUSHGATEWAY_URL")

class DependabotMetrics
  attr_accessor :metrics_by_date, :from_date, :to_date, :output_format

  def initialize(from_date, to_date, output_format)
    @from_date = Date.parse(from_date)
    @to_date = Date.parse(to_date)
    @output_format = output_format
    @metrics_by_date = {}
    (@from_date..@to_date).each do |date|
      @metrics_by_date[date] = initialize_metrics
    end
  end

  def initialize_metrics
    {
      total_new_prs: 0,
      prs_by_update_type: Hash.new(0),
      prs_per_dependency: Hash.new(0),
      total_merged_prs: 0,
      total_closed_prs: 0,
      total_open_prs: 0,
      prs_success_percentage: 0.0,
      average_merge_time: 0.0,
      average_open_pr_age: 0.0,
      open_prs: [],
      open_failing_prs: [],
      merge_time_distribution: Hash.new(0),
      frequently_updated_repos: Hash.new(0),
      open_prs_per_dependency: Hash.new(0),
      total_security_alerts: 0,
      security_alerts_per_repo: Hash.new(0),
      security_alerts_per_dependency: Hash.new(0)
    }
  end

  def client
    @client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: false)
  end

  def govuk_repos
    @govuk_repos ||=
      JSON.parse(Net::HTTP.get(URI("https://docs.publishing.service.gov.uk/repos.json"))).map { |repo| "alphagov/#{repo['app_name']}" }
  end

  def get_repo_prs(repo)
    repo_prs = []
    page = 1

    loop do
      puts "#{repo} page: #{page}"
      issues = client.list_issues(repo, { state: "all", labels: "dependencies", since: from_date, page: page, per_page: 100 })
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

  def fetch_checks_status(repo, commit_ref)
    check_runs = client.check_runs_for_ref(repo, commit_ref)
    check_runs.check_runs.map(&:conclusion)
  rescue Octokit::BadGateway => e
    puts "Error: #{e.message}"
    []
  end

  def failing_checks?(repo, pr_number)
    pr_data = client.pull_request(repo, pr_number)
    commit_ref = pr_data[:head][:sha]
    check_conclusions = fetch_checks_status(repo, commit_ref)
    failing_checks = check_conclusions.count { |conclusion| conclusion != "success" && conclusion != "neutral" && conclusion != "skipped" }
    failing_checks.positive?
  rescue StandardError => e
    puts e.message
    false
  end

  def extract_pr_info(pr_title)
    match = pr_title.match(/Bump (?<dependency>[\w-]+)(?:-|\/)?(?<subpackage>[\w-]+)? from (?<from_version>[\w.]+(?:-[\w.]+)?) to (?<to_version>[\w.]+(?:-[\w.]+)?)/) ||
            pr_title.match(/^(?:(?:\[Security\]\ )?Bump|build\(deps.*\): bump) (?<dependency>.+) from (?<from_version>.+) to (?<to_version>.+)/) ||
            pr_title.match(/^Update (?<dependency>.+) requirement from (?:=|~>) (?<from_version>.+) to (?:=|~>)(?<to_version>.+)/) ||
            pr_title.match(/^Update (?<dependency>.+) requirement from (?:>=\s)?(?<from_version>.+),\s<\s(?<to_version>.+) to (?:>=\s)?(?<from_version_2>.+),\s<\s(?<to_version_2>.+)/)
  
    return nil unless match
  
    dependency = match[:dependency]
    from_version = match[:from_version] || match[:from_version_2]
    to_version = match[:to_version] || match[:to_version_2]
  
    { dependency: dependency, from_version: from_version, to_version: to_version }
  end
  
  def determine_update_type(from_version, to_version)
    return nil unless Gem::Version.correct?(from_version) && Gem::Version.correct?(to_version)
  
    from_version_obj = Gem::Version.new(from_version)
    to_version_obj = Gem::Version.new(to_version)
    index_of_diff = nil
  
    to_version_obj.segments.zip(from_version_obj.segments).each_with_index do |(a, b), index|
      if a != b
        index_of_diff = index
        break
      end
    end
  
    case index_of_diff
    when 0 then "major"
    when 1 then "minor"
    else "patch"
    end
  end

  def export_metrics_to_prometheus(metrics)
    prometheus = Prometheus::Client.registry
  
    # Initialize and register metrics
    register_prometheus_metrics
  
    # Update metric values
    update_prometheus_metrics(metrics)
  
    # Push metrics to Pushgateway
    # Prometheus::Client::Push.new(job: 'dependabot_metrics', gateway: PROMETHEUS_PUSHGATEWAY_URL).add(prometheus)
    puts prometheus
  end
  
  def register_prometheus_metrics
    total_new_prs = Prometheus::Client::Counter.new(:total_new_prs, "Total number of pull requests opened by Dependabot each day")
    prometheus.register(total_new_prs)

    prs_by_update_type = Prometheus::Client::Counter.new(:prs_by_update_type, "Number of PRs raised by update type (major, minor, patch) each day", %i[update_type])
    prometheus.register(prs_by_update_type)

    prs_per_dependency = Prometheus::Client::Counter.new(:prs_per_dependency, "Number of update type (major, minor, patch) per dependency each day", %i[dependency update_type])
    prometheus.register(prs_per_dependency)

    total_merged_prs = Prometheus::Client::Counter.new(:total_merged_prs, "Total number of pull requests merged each day")
    prometheus.register(total_merged_prs)

    total_closed_prs = Prometheus::Client::Counter.new(:total_closed_prs, "Total number of pull requests closed without merging each day")
    prometheus.register(total_closed_prs)

    total_open_prs = Prometheus::Client::Gauge.new(:total_open_prs, "Total number of pull requests opened by Dependabot each day that are still open")
    prometheus.register(total_open_prs)

    prs_success_percentage = Prometheus::Client::Gauge.new(:prs_success_percentage, "Percentage of Dependabot PRs that have been successfully merged or closed without merging each day")
    prometheus.register(prs_success_percentage)

    average_merge_time = Prometheus::Client::Gauge.new(:average_merge_time, "Average number of days it takes to merge a Dependabot PR")
    prometheus.register(average_merge_time)

    average_open_pr_age = Prometheus::Client::Gauge.new(:average_open_pr_age, "Average number of days that open Dependabot PRs have been waiting for a merge")
    prometheus.register(average_open_pr_age)

    open_failing_prs = Prometheus::Client::Gauge.new(:open_failing_prs, "Number of open Dependabot PRs that currently have failing checks", %i[repo pr_number])
    prometheus.register(open_failing_prs)

    merge_time_distribution = Prometheus::Client::Histogram.new(:merge_time_distribution, "Distribution of the number of days it takes to merge Dependabot PRs", %i[repo])
    prometheus.register(merge_time_distribution)

    frequently_updated_repos = Prometheus::Client::Counter.new(:frequently_updated_repos, "Number of repositories that receive the most frequent Dependabot PRs", %i[repo])
    prometheus.register(frequently_updated_repos)

    prs_per_dependency_total = Prometheus::Client::Counter.new(:prs_per_dependency_total, "Total number of Dependabot PRs per dependency", %i[dependency])
    prometheus.register(prs_per_dependency_total)

    open_prs_per_dependency = Prometheus::Client::Gauge.new(:open_prs_per_dependency, "Number of still open Dependabot PRs per dependency", %i[dependency])
    prometheus.register(open_prs_per_dependency)

    total_security_alerts = Prometheus::Client::Gauge.new(:total_security_alerts, "Total Security Alerts")
    prometheus.register(total_security_alerts)

    security_alerts_per_repo = Prometheus::Client::Gauge.new(:security_alerts_per_repo, "Number of open security alerts per repository", %i[repo])
    prometheus.register(security_alerts_per_repo)

    security_alerts_per_dependency = Prometheus::Client::Gauge.new(:security_alerts_per_dependency, "Number of open security alerts per dependency", %i[dependency])
    prometheus.register(security_alerts_per_dependency)
  end
  
  def update_prometheus_metrics(metrics)
    total_new_prs.increment(by: metrics[:total_new_prs])
    metrics[:prs_by_update_type].each { |update_type, count| prs_by_update_type.increment({ update_type: update_type }, by: count) }
    metrics[:prs_per_dependency].each { |dependency, update_types| update_types.each { |update_type, count| prs_per_dependency.increment({ dependency: dependency, update_type: update_type }, by: count) } }
    total_merged_prs.increment(by: metrics[:total_merged_prs])
    total_closed_prs.increment(by: metrics[:total_closed_prs])
    total_open_prs.set(metrics[:total_open_prs])
    prs_success_percentage.set(metrics[:prs_success_percentage])
    average_merge_time.set(metrics[:average_merge_time])
    average_open_pr_age.set(metrics[:average_open_pr_age])
    metrics[:open_failing_prs].each { |repo, pr_number| open_failing_prs.set({ repo: repo, pr_number: pr_number }, 1) }
    metrics[:merge_time_distribution].each { |repo, days| merge_time_distribution.observe({ repo: repo }, days) }
    metrics[:frequently_updated_repos].each { |repo, count| frequently_updated_repos.increment({ repo: repo }, by: count) }
    metrics[:prs_per_dependency_total].each { |dependency, count| prs_per_dependency_total.increment({ dependency: dependency }, by: count) }
    metrics[:open_prs_per_dependency].each { |dependency, count| open_prs_per_dependency.set({ dependency: dependency }, count) }
    total_security_alerts.set(metrics[:total_security_alerts])
    metrics[:security_alerts_per_repo].each { |repo, count| security_alerts_per_repo.set({ repo: repo }, count) }
    metrics[:security_alerts_per_dependency].each { |dependency, count| security_alerts_per_dependency.set({ dependency: dependency }, count) }
  end
  

  def run
    govuk_repos.each do |repo|
      prs = get_repo_prs(repo)
      security_alerts = fetch_security_alerts(repo)
  
      prs.each do |pr|
        pr_info = extract_pr_info(pr[:title])

        if pr_info.nil?
          puts "THE FOLLOWING PR DID NOT MATCH ANY REGEX IN THE extract_pr_info METHOD:"
          puts "PR ##{pr.number} ON #{repo} TITLED: #{pr[:title]}"
          next
        end

        dependency = pr_info[:dependency]
        from_version = pr_info[:from_version]
        to_version = pr_info[:to_version]

        update_type = determine_update_type(from_version, to_version)
  
        pr_date = pr[:created_at].to_date
        next unless metrics_by_date.key?(pr_date)

        metrics = metrics_by_date[pr_date]
  
        metrics[:total_new_prs] += 1
        metrics[:prs_by_update_type][update_type] += 1
        metrics[:prs_per_dependency][dependency] += 1
  
        if pr.state == 'closed'
          if pr.pull_request[:merged_at]
            merge_date = pr.pull_request[:merged_at].to_date
            next unless metrics_by_date.key?(merge_date)
  
            metrics = metrics_by_date[merge_date]
  
            metrics[:total_merged_prs] += 1
            merge_time = (pr.pull_request.merged_at.to_date - pr.created_at.to_date).to_i
            metrics[:merge_time_distribution][merge_time] += 1
          elsif pr.closed_at
            close_date = pr.closed_at.to_date
            next unless metrics_by_date.key?(close_date)
  
            metrics = metrics_by_date[close_date]
  
            metrics[:total_closed_prs] += 1
          end
        else
          metrics[:open_prs] << { created_at: pr[:created_at], title: pr[:title], repo: repo, number: pr[:number] }
          metrics[:total_open_prs] += 1
          metrics[:open_prs_per_dependency][dependency] += 1
  
          if failing_checks?(repo, pr.number)
            metrics[:open_failing_prs] << { created_at: pr[:created_at], title: pr[:title], repo: repo, number: pr[:number] }
          end
        end
  
        metrics[:frequently_updated_repos][repo] += 1
      end
  
      security_alerts.each do |alert|
        alert_date = alert.created_at.to_date
        next unless metrics_by_date.key?(alert_date)

        metrics = metrics_by_date[alert_date]
  
        metrics[:total_security_alerts] += 1
        metrics[:security_alerts_per_repo][repo] += 1
        metrics[:security_alerts_per_dependency][alert.dependency] += 1
      end
    end
  
    metrics_by_date.each do |date, metrics|
      total_closed_and_merged_prs = metrics[:total_merged_prs] + metrics[:total_closed_prs]
      metrics[:prs_success_percentage] = total_closed_and_merged_prs.to_f / metrics[:total_new_prs] * 100

      total_merge_time = metrics[:merge_time_distribution].reduce(0) { |sum, (days, count)| sum + (days * count) }
      metrics[:average_merge_time] = total_merge_time.to_f / metrics[:total_merged_prs]

      open_pr_age_sum = metrics[:open_prs].reduce(0) { |sum, pr_data| sum + (Date.today - pr_data[:created_at].to_date).to_i }
      metrics[:average_open_pr_age] = open_pr_age_sum.to_f / metrics[:total_open_prs]
    end

    export_metrics_to_prometheus(metrics_by_date) if output_format == :prometheus
  end
end