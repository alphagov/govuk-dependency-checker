require "net/http"
require "json"
require "octokit"
require "date"
require "csv"

class AutoMergeMetrics
  def initialize
    @metrics = {
      total_new_prs: 0,
      total_closed_prs: 0,
      total_merged_prs: 0,
      auto_merged: 0,
      merged_by_user: 0,
      average_merge_time: 0,
      prs_by_update_type: Hash.new(0),
    }
  end

  def client
    @client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: false)
  end

  def govuk_repos
    @govuk_repos ||=
      JSON.parse(Net::HTTP.get(URI("https://docs.publishing.service.gov.uk/repos.json"))).map { |repo| (repo["app_name"]).to_s }
  end

  def get_repo_prs(repo, start_date, end_date)
    repo_prs = []
    page = 1

    loop do
      puts "#{repo} page: #{page}"
      issues = client.list_issues("alphagov/#{repo}", { state: "closed", labels: "dependencies", since: start_date.to_s, page: page, per_page: 100 })
      break if issues.empty?

      repo_prs += issues
      page += 1
    end

    repo_prs = repo_prs.select { |issue| issue.closed_at.to_date <= end_date }
    repo_prs.select(&:pull_request)
  rescue Octokit::NotFound
    []
  end

  def get_pr_timeline(repo, pr_number)
    client.issue_timeline("alphagov/#{repo}", pr_number)
  rescue Octokit::NotFound
    puts "Could not find PR number #{pr_number} in repo #{repo}"
    []
  end

  def extract_pr_info(pr_title)
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

    diff_index = Gem::Version.new(to_version).segments.zip(Gem::Version.new(from_version).segments).index { |a, b| a != b }

    %w[major minor patch][diff_index]
  end

  def run(options = {})
    start_date = Date.parse options[:from]
    end_date = Date.parse options[:to]
    merge_times = []

    govuk_repos.each do |repo|
      get_repo_prs(repo, start_date, end_date).each do |pr|
        pr_info = extract_pr_info(pr[:title])

        next unless pr_info

        update_type = determine_update_type(pr_info[:from_version], pr_info[:to_version])

        @metrics[:total_new_prs] += 1
        @metrics[:prs_by_update_type][update_type] += 1

        if pr.pull_request[:merged_at]
          timeline_events = get_pr_timeline(repo, pr[:number])
          @metrics[:total_merged_prs] += 1

          timeline_events.each do |event|
            @metrics[:auto_merged] += 1 if event[:event] == "merged" && event[:actor][:login] == "govuk-ci"
            @metrics[:merged_by_user] += 1 if event[:event] == "merged" && event[:actor][:login] != "govuk-ci"
          end

          superseded_pr_events = timeline_events.select do |event|
            event[:event] == "cross-referenced" && event[:actor][:login] == "dependabot[bot]"
          end

          earliest_pr_date = superseded_pr_events.map { |event| event[:source][:issue][:created_at].to_date }.min || pr.created_at.to_date
          merge_times << (pr.pull_request.merged_at.to_date - earliest_pr_date)
        elsif pr.closed_at
          @metrics[:total_closed_prs] += 1
        end
      end
    end

    @metrics[:average_merge_time] = merge_times.sum / merge_times.size
    puts @metrics
    export_metrics_to_csv(start_date, end_date)
  end

  def export_metrics_to_csv(from, to)
    filename = from == to ? "dependabot_metrics-#{to}.csv" : "dependabot_metrics-#{from}-#{to}.csv"
    CSV.open(filename, "wb") do |csv|
      csv << @metrics.keys
      csv << @metrics.values
    end

    puts "Metrics saved in #{filename}"
  end
end
