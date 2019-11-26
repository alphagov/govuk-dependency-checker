raise "You can only pass 0 or 2 arguments" if ARGV.length != 0 && ARGV.length != 2

require "octokit"
require "base64"

def client
  @client ||=
    Octokit::Client.new(
      access_token: ENV.fetch("GITHUB_TOKEN"),
      auto_paginate: true
    )
end

def govuk_repos
  @govuk_repos ||=
    client
      .search_repos("org:alphagov topic:govuk")
      .items
      .reject!(&:archived)
      .map { |repo| repo.full_name }
end

def path
  @path ||= (ARGV[0] || "Gemfile")
end

def query
  @query ||= (ARGV[1] || "govuk-lint")
end

def relevant_repos
  @relevant_repos ||= govuk_repos.map do |repo|
    contents = client.contents(repo)
    if contents.any? { |c| c["path"] == path }
      content = client.contents(repo, path: path)["content"]
      if Base64.decode64(content).include?(query)
        "https://www.github.com/#{repo}"
      end
    end
  end.compact
end

puts relevant_repos
