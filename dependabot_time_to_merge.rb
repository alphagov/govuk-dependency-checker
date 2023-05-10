require "net/http"
require "json"
require "octokit"
require "date"
require "prometheus/client"
require "prometheus/client/push"

class DependabotMetrics
  attr_accessor :metrics_by_date, :from_date, :to_date, :output_format

  def initialize(from_date, to_date, output_format)
    @from_date = Date.parse(from_date)
    @to_date = Date.parse(to_date)
    @output_format = output_format
    # @earliest_pr_creation_times = Hash.new { |h, k| h[k] = {} } # This is only used within the script to track the first PR to update a version and account for superseded PRs
    @metrics_by_date = {}
    (@from_date..@to_date).each do |date|
      @metrics_by_date[date] = initialize_metrics
    end
  end

  def initialize_metrics
    {
      total_new_prs: 0,
      prs_by_update_type: Hash.new(0),
      prs_per_dependency: Hash.new { |h, k| h[k] = Hash.new(0) },
      total_merged_prs: 0,
      total_closed_prs: 0,
      total_open_prs: 0,
      open_prs: [],
      open_failing_prs: [],
      merge_times: [],
      frequently_updated_repos: Hash.new(0),
      open_prs_per_dependency: Hash.new(0),
      security_alerts_per_repo: Hash.new(0),
      security_alerts_per_dependency: Hash.new(0),
    }
  end

  def client
    @client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: false)
  end

  def govuk_repos
    # @govuk_repos ||=
    #   JSON.parse(Net::HTTP.get(URI("https://docs.publishing.service.gov.uk/repos.json"))).map { |repo| "alphagov/#{repo['app_name']}" }
    [
      "alphagov/govuk-networks"
    ]
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
    # Dependabot will sometimes raise PRs to update multiple dependencies ("Bump json5, @babel/core and loader-utils", "Bump engine.io and karma")
    # This method will not match those PRs. There aren't many of them and there's little value in tracking those.
    match = pr_title.match(/Bump (?<dependency>[\w-]+)(?:-|\/)?(?<subpackage>[\w-]+)? from (?<from_version>[\w.]+(?:-[\w.]+)?) to (?<to_version>[\w.]+(?:-[\w.]+)?)/) ||
      pr_title.match(/^(?:(?:\[Security\]\ )?Bump|build\(deps.*\): bump) (?<dependency>.+) from (?<from_version>.+) to (?<to_version>.+)/) ||
      pr_title.match(/^Update (?<dependency>.+) requirement from (?:=|~>) (?<from_version>.+) to (?:=|~>)(?<to_version>.+)/) ||
      pr_title.match(/^Update (?<dependency>.+) requirement from (?:>=\s)?(?<from_version>.+),\s<\s(?<to_version>.+) to (?:>=\s)?(?<from_version_2>.+),\s<\s(?<to_version_2>.+)/) ||
      pr_title.match(/Update (?<dependency>.+) requirement from (?:~> )?(?<from_version>.+) to (?:>= )?(?<to_version>.+), < (?<to_version_2>.+)/)

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

  def initialize_prometheus_metrics
    registry = Prometheus::Client.registry

    {
      total_new_prs: registry.counter(:total_new_prs, docstring: "Total number of new PRs created", labels: %i[date]),
      prs_by_update_type: registry.counter(:prs_by_update_type, docstring: "Number of PRs by update type", labels: %i[date update_type]),
      prs_per_dependency: registry.counter(:prs_per_dependency, docstring: "Number of PRs per dependency and update type", labels: %i[date dependency update_type]),
      total_merged_prs: registry.counter(:total_merged_prs, docstring: "Total number of merged PRs", labels: %i[date]),
      total_closed_prs: registry.counter(:total_closed_prs, docstring: "Total number of closed PRs", labels: %i[date]),
      total_open_prs: registry.gauge(:total_open_prs, docstring: "Total number of open PRs", labels: %i[date]),
      open_prs: registry.gauge(:open_prs, docstring: "Open PRs with their creation date, title, repo, and PR number", labels: %i[date created_at title repo pr_number]),
      open_failing_prs: registry.gauge(:open_failing_prs, docstring: "Number of open Dependabot PRs that currently have failing checks", labels: %i[date repo pr_number]),
      merge_times: registry.gauge(:merge_times, docstring: "Merge time in days for each PR", labels: %i[date repo pr_number]),
      frequently_updated_repos: registry.counter(:frequently_updated_repos, docstring: "Number of repositories that receive the most frequent Dependabot PRs", labels: %i[date repo]),
      open_prs_per_dependency: registry.gauge(:open_prs_per_dependency, docstring: "Number of still open Dependabot PRs per dependency", labels: %i[date dependency]),
      security_alerts_per_repo: registry.gauge(:security_alerts_per_repo, docstring: "Number of open security alerts per repository", labels: %i[date repo]),
      security_alerts_per_dependency: registry.gauge(:security_alerts_per_dependency, docstring: "Number of open security alerts per dependency", labels: %i[date dependency]),
    }
  end

  def update_prometheus_metrics(metrics, prometheus_metrics, date)
    prometheus_metrics[:total_new_prs].increment(labels: { date: date }, by: metrics[:total_new_prs])
    prometheus_metrics[:total_merged_prs].increment(labels: { date: date }, by: metrics[:total_merged_prs])
    prometheus_metrics[:total_closed_prs].increment(labels: { date: date }, by: metrics[:total_closed_prs])
    prometheus_metrics[:total_open_prs].with_labels(date: date).set(metrics[:total_open_prs])

    metrics[:prs_by_update_type].each do |update_type, count|
      prometheus_metrics[:prs_by_update_type].increment(labels: { date: date, update_type: update_type }, by: count)
    end

    metrics[:prs_per_dependency].each do |dependency, update_types|
      update_types.each do |update_type, count|
        prometheus_metrics[:prs_per_dependency].increment(labels: { date: date, dependency: dependency, update_type: update_type }, by: count)
      end
    end

    metrics[:open_prs].each do |pr_data|
      prometheus_metrics[:open_prs].with_labels(date: date, created_at: pr_data[:created_at], title: pr_data[:title], repo: pr_data[:repo], pr_number: pr_data[:number]).set(1)
    end

    metrics[:open_failing_prs].each do |pr_data|
      prometheus_metrics[:open_failing_prs].with_labels(date: date, created_at: pr_data[:created_at], title: pr_data[:title], repo: pr_data[:repo], pr_number: pr_data[:number]).set(1)
    end

    metrics[:merge_times].each do |mt|
      prometheus_metrics[:merge_times].with_labels(date: date, repo: mt[:repo], pr_number: mt[:pr_number]).set(mt[:merge_time])
    end

    metrics[:frequently_updated_repos].each do |repo, count|
      prometheus_metrics[:frequently_updated_repos].increment(labels: { date: date, repo: repo }, by: count)
    end

    metrics[:open_prs_per_dependency].each do |dependency, count|
      prometheus_metrics[:open_prs_per_dependency].with_labels(date: date, dependency: dependency).set(count)
    end

    metrics[:security_alerts_per_repo].each do |repo, count|
      prometheus_metrics[:security_alerts_per_repo].with_labels(date: date, repo: repo).set(count)
    end

    metrics[:security_alerts_per_dependency].each do |dependency, count|
      prometheus_metrics[:security_alerts_per_dependency].with_labels(date: date, dependency: dependency).set(count)
    end
  end

  def push_metrics_to_pushgateway
    # Prometheus::Client::Push.new(job: 'dependabot_metrics', gateway: ENV.fetch("PROMETHEUS_PUSHGATEWAY_URL")).add(Prometheus::Client.registry)

    # Print metric values (remove this in production)
    Prometheus::Client.registry.metrics.each do |metric|
      puts "#{metric.name}:"
      metric.values.each do |labels, value|
        puts "  #{labels.inspect} => #{value}"
      end
    end
  end

  def run
    prometheus_metrics = initialize_prometheus_metrics if output_format == "prometheus"
    earliest_pr_creation_times = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = {} } }

    govuk_repos.each do |repo|
      prs = get_repo_prs(repo)
      security_alerts = fetch_security_alerts(repo)

      prs.each do |pr|
        pr_info = extract_pr_info(pr[:title])

        # if pr_info.nil?
        #   puts "THE FOLLOWING PR DID NOT MATCH ANY REGEX IN THE extract_pr_info METHOD:"
        #   puts "PR ##{pr.number} ON #{repo} TITLED: #{pr[:title]}"
        #   next
        # end
        next if pr_info.nil?

        dependency = pr_info[:dependency]
        from_version = pr_info[:from_version]
        to_version = pr_info[:to_version]

        update_type = determine_update_type(from_version, to_version)

        pr_date = pr[:created_at].to_date
        next unless metrics_by_date.key?(pr_date)

        metrics = metrics_by_date[pr_date]

        metrics[:total_new_prs] += 1
        metrics[:prs_by_update_type][update_type] += 1
        metrics[:prs_per_dependency][dependency][update_type] += 1

        # Update the earliest PR creation time for each dependency and from_version
        earliest_time = earliest_pr_creation_times[repo][dependency][from_version]
        earliest_pr_creation_times[repo][dependency][from_version] = pr_date if earliest_time.nil? || pr_date < earliest_time

        if pr.state == "closed"
          if pr.pull_request[:merged_at]
            merge_date = pr.pull_request[:merged_at].to_date
            next unless metrics_by_date.key?(merge_date)

            metrics = metrics_by_date[merge_date]

            metrics[:total_merged_prs] += 1
            # Calculate the merge time based on the earliest PR creation time to account for superseded PRs
            # This will only catch superseded PRs closed after the `@from_date`
            earliest_pr_date = earliest_pr_creation_times[repo][dependency][from_version]
            merge_time = (pr.pull_request.merged_at.to_date - earliest_pr_date).to_i
            metrics[:merge_times] << { repo: repo, pr_number: pr[:number], merge_time: merge_time }
          elsif pr.closed_at
            close_date = pr.closed_at.to_date
            next unless metrics_by_date.key?(close_date)

            metrics = metrics_by_date[close_date]

            metrics[:total_closed_prs] += 1
          end
        else
          metrics[:open_prs] << { created_at: pr[:created_at].to_s, title: pr[:title], repo: repo, number: pr[:number] }
          metrics[:total_open_prs] += 1
          metrics[:open_prs_per_dependency][dependency] += 1

          if failing_checks?(repo, pr.number)
            metrics[:open_failing_prs] << { created_at: pr[:created_at].to_s, title: pr[:title], repo: repo, number: pr[:number] }
          end
        end

        metrics[:frequently_updated_repos][repo] += 1
      end

      security_alerts.each do |alert|
        alert_date = alert.created_at.to_date
        next unless metrics_by_date.key?(alert_date)

        metrics = metrics_by_date[alert_date]

        metrics[:security_alerts_per_repo][repo] += 1
        metrics[:security_alerts_per_dependency][alert.dependency.package.name] += 1
      end
    end

    if output_format == "prometheus"
      metrics_by_date.each do |date, metrics|
        puts "Exporting metrics for date: #{date}"
        update_prometheus_metrics(metrics, prometheus_metrics, date.to_s)
      end

      push_metrics_to_pushgateway
    end
  end
end
