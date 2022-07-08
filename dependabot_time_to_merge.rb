raise "You need to provide two dates in the following format: 2022-06-23" if ARGV.length != 2

require "octokit"
require "net/http"
require "json"
require "date"

def client
  @client ||=
    Octokit::Client.new(
      access_token: ENV.fetch("GITHUB_TOKEN"),
      auto_paginate: false
    )
end

def govuk_repos
  @govuk_repos ||= 
    JSON.parse(
      Net::HTTP.get(
        URI("https://docs.publishing.service.gov.uk/repos.json")
      )
    )
      .map { |repo| "alphagov/#{repo["app_name"]}" }
end

def dependabot_prs
  client.search_issues("is:pr user:alphagov is:closed author:app/dependabot archived:false", per_page: 100)
  
  last_response = client.last_response

  return [] if last_response.data.items.empty?

  pulls = []
  sleep_time = 60 # GitHub's Search API applies strict secondary rate-limiting

  # GitHub Search API has a limit of 1000 results,
  # so we should only loop through 100-results-per-page 10 times.
  # https://docs.github.com/en/rest/search#about-the-search-api
  10.times do |i|
    puts "Fetching next page of results... (API call ##{i+1})\nSleeping #{sleep_time} seconds to avoid rate-limiting..."
    pulls << last_response.data.items
    break if last_response.rels[:next].nil?
    sleep sleep_time
    last_response = last_response.rels[:next].get
  end
  pulls.flatten
end

def govuk_prs
  @govuk_prs ||=
    dependabot_prs.flatten.select do |pr|
      govuk_repos.any? { |repo| pr.repository_url.include?(repo) }
    end
end

def filter_by_date(from, to)
  govuk_prs.flatten.select do |pr|
    pr.pull_request["merged_at"].between?(Time.parse(from), Time.parse(to)) if pr.pull_request["merged_at"]
  end
end

def time_to_merge(from, to)
  @time_to_merge = []
  filter_by_date(from, to).each do |pr|
    days_to_merge = (pr.pull_request["merged_at"] - pr.created_at).to_i / (24 * 60 * 60)
    puts "Created at: #{pr.created_at}, merged at: #{pr.pull_request["merged_at"]}, time to merge: #{days_to_merge} days, url: #{pr.url}"
    @time_to_merge << days_to_merge
  end
  print "Time to merge days array #{@time_to_merge}"
  puts ""
  puts "Total PRs #{@time_to_merge.size}"
  puts "The time to merge was #{@time_to_merge.sum(0.0) / @time_to_merge.size} days on average"
  puts "The median time to merge was #{median(@time_to_merge)} days"
end

def median(values_array)
  return nil if values_array.empty?
  sorted = values_array.sort
  len = sorted.length
  (sorted[(len - 1) / 2] + sorted[len / 2]) / 2.0
end

time_to_merge(ARGV[0], ARGV[1])
