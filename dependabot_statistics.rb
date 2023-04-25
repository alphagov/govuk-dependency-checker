require "octokit"

FROM = /(?<=from )\d+\.\d+\.\d+/.freeze
TO = /(?<=to )\d+\.\d+\.\d+/.freeze

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

def dependabot_preview_prs
  @dependabot_preview_prs ||=
    client
      .search_issues("is:pr is:closed user:alphagov author:app/dependabot-preview")
      .items
end

def dependabot_prs
  @dependabot_prs ||=
    client
      .search_issues("is:pr is:closed user:alphagov author:app/dependabot")
      .items
end

def govuk_prs
  @govuk_prs ||=
    [dependabot_preview_prs, dependabot_prs].flatten.select do |pr|
      govuk_repos.any? { |repo| pr.repository_url.include?(repo) }
    end
end

def actionable_govuk_prs
  @actionable_govuk_prs ||=
    govuk_prs.map(&:to_h)
      .select { |e| e[:title].match?(FROM) && e[:title].match?(TO) }
  # If the title doesn't have the "from x.x.x to x.x.x" format,
  # it's not useful for what we need to do, so we reject it.
end

def processed_govuk_prs
  @processed_govuk_prs ||=
    actionable_govuk_prs.map do |pr|
      major_minor_patch = {
        major: [pr[:title].match(FROM)[0].split(".")[0], pr[:title].match(TO)[0].split(".")[0]],
        minor: [pr[:title].match(FROM)[0].split(".")[1], pr[:title].match(TO)[0].split(".")[1]],
        patch: [pr[:title].match(FROM)[0].split(".")[2], pr[:title].match(TO)[0].split(".")[2]],
      }
      pr[:changed_version] = major_minor_patch.map { |k, v| k if v[0] != v[1] }.compact.min
      pr
    end
end

def major_minor_patch_count
  @major_minor_patch_count ||=
    processed_govuk_prs
      .group_by { |e| e[:changed_version] }
      .transform_values(&:count)
end

puts major_minor_patch_count
