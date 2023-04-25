raise "You can only pass 0 or 2 arguments" if !ARGV.empty? && ARGV.length != 2

require "octokit"
require "base64"

def client
  @client ||=
    Octokit::Client.new(
      access_token: ENV.fetch("GITHUB_TOKEN"),
      auto_paginate: true,
    )
end

def govuk_repos
  @govuk_repos ||=
    client
      .search_repos("org:alphagov topic:govuk")
      .items
      .reject!(&:archived)
      .map(&:full_name)
end

def path
  @path ||= (ARGV[0] || "Gemfile")
end

def query
  @query ||= (ARGV[1] || "govuk-lint")
end

def relevant_repos
  @relevant_repos ||= govuk_repos.map { |repo|
    contents = client.contents(repo)
    next unless contents.any? { |c| c["path"] == path }

    content = client.contents(repo, path: path)["content"]
    if Base64.decode64(content).include?(query)
      "https://www.github.com/#{repo}"
    end
  }.compact
end

puts relevant_repos
