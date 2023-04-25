# For each app's Gemfile, find all of the gems that are duplicates of
# ones included in govuk_app_config, govuk-publishing-components,
# or govuk_test.
# Usage: GITHUB_TOKEN=abc123 ruby unnecessary-gems.rb alphagov/whitehall

require "octokit"
require "json"

client = Octokit::Client.new(access_token: ENV["GITHUB_TOKEN"], auto_paginate: true)

govuk_app = ARGV[0].start_with?("alphagov/") ? ARGV[0] : "alphagov/#{ARGV[0]}"

@govuk_app_config_deps = []
Base64.decode64(client.contents("alphagov/govuk_app_config", path: "govuk_app_config.gemspec").content).each_line do |line|
  @govuk_app_config_deps << line.split(" ")[1].gsub!(",", "") if line.match?(/spec\.add_dependency/)
end

@govuk_test_deps = []
Base64.decode64(client.contents("alphagov/govuk_test", path: "govuk_test.gemspec").content).each_line do |line|
  @govuk_test_deps << line.split(" ")[1].gsub!(",", "") if line.match?(/spec\.add_dependency/)
end

@govuk_publishing_components_deps = []
Base64.decode64(client.contents("alphagov/govuk_publishing_components", path: "govuk_publishing_components.gemspec").content).each_line do |line|
  @govuk_publishing_components_deps << line.split(" ")[1].gsub!(",", "") if line.match?(/spec\.add_dependency/)
end

@govuk_sidekiq_deps = []
Base64.decode64(client.contents("alphagov/govuk_sidekiq", path: "govuk_sidekiq.gemspec").content).each_line do |line|
  @govuk_sidekiq_deps << line.split(" ")[1].gsub!(",", "") if line.match?(/spec\.add_dependency/)
end

puts "Scanning #{govuk_app}..."
Base64.decode64(client.contents(govuk_app, path: "Gemfile").content).each_line do |line|
  next unless line.match?(/gem\s+/)

  gem = line.split(" ")[1].gsub(",", "")

  if @govuk_app_config_deps.compact.include?(gem)
    puts "Gem #{gem} is duplicated from govuk-app-config."
  elsif @govuk_test_deps.compact.include?(gem)
    puts "Gem #{gem} is duplicated from govuk_test."
  elsif @govuk_publishing_components_deps.compact.include?(gem)
    puts "Gem #{gem} is duplicated from govuk-publishing-components."
  elsif @govuk_sidekiq_deps.compact.include?(gem)
    puts "Gem #{gem} is duplicated from govuk_sidekiq."
  end
end

puts "Done!"
