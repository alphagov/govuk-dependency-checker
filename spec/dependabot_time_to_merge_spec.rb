require 'rspec'
require_relative '../dependabot_time_to_merge'

RSpec.describe '#dependabot_time_to_merge' do
  let(:dependabot) do
    Dependabot.new
  end

  let (:repo_name) { 'alphagov/test_api' }
  let (:from) { Time.parse('2023-03-01 00:00:00') }
  let (:to) { Time.parse('2023-03-16 00:00:00') }

  let(:dependabot_prs) do
    {
      "foo": [
        {
          from_version: '1.0.0',
          created_at: Time.parse('2023-03-07 00:00:00'),
          closed_at: nil,
          merged_at: nil
        },
        {
          from_version: '1.0.0',
          created_at: Time.parse('2023-03-01 00:00:00'),
          closed_at: Time.parse('2023-03-07 00:00:00'),
          merged_at: nil
        },
        {
          from_version: '1.0.0',
          created_at: Time.parse('2023-02-27 00:00:00'), # opened outside the timeframe, should not be counted
          closed_at: Time.parse('2023-03-01 00:00:00'),
          merged_at: nil
        }
      ],
      "bar": [
        {
          from_version: '1.0.2',
          created_at: Time.parse('2023-03-09 00:00:00'),
          closed_at: nil,
          merged_at: nil
        },
        {
          from_version: '1.0.1',
          created_at: Time.parse('2023-03-07 00:00:00'),
          closed_at: Time.parse('2023-03-08 00:00:00'),
          merged_at: Time.parse('2023-03-08 00:00:00')
        },
        {
          from_version: '1.0.1',
          created_at: Time.parse('2023-03-01 00:00:00'),
          closed_at: Time.parse('2023-03-07 00:00:00'),
          merged_at: nil
        },
        {
          from_version: '1.0.1',
          created_at: Time.parse('2023-02-26 00:00:00'), # opened outside the timeframe, should not be counted
          closed_at: Time.parse('2023-03-01 00:00:00'),
          merged_at: nil
        }
      ]
    }
  end

  def stub_govuk_repos(repo_names)
    stub_request(:get, 'https://docs.publishing.service.gov.uk/repos.json')
      .to_return(
        status: 200,
        headers: { "Content-Type": 'application/json' },
        body: repo_names.map { |repo_name| { "app_name": repo_name } }.to_json
      )
  end

  def stub_govuk_dependabot_prs(repo_name, return_values)
    stub_request(:get, "https://api.github.com/repos/#{repo_name}/issues?labels=dependencies&state=all")
      .to_return(
        status: 200,
        headers: { "Content-Type": 'application/json' },
        body: return_values.to_json
      )
  end

  it 'gets dependency name and version' do
    pr_titles = [
      'Bump test from 2.2.0 to 2.2.1',
      '[Security] Bump test from 2.2.0 to 2.2.1',
      'build(deps): bump test from 2.2.0 to 2.2.1',
      'build(deps-dev): bump test from 2.2.0 to 2.2.1',
      'Update test requirement from = 2.2.0 to = 2.2.1',
      'Update test requirement from ~> 2.2.0 to ~> 2.2.1'
    ]

    pr_titles.each do |title|
      name, version = dependabot.get_dependency_name_and_version(title)

      expect(name).to eq('test')
      expect(version).to eq('2.2.0')
    end
  end

  it 'returns noop name and version if title cannot be parsed' do
    name, version = dependabot.get_dependency_name_and_version('Upgrade test')

    expect(name).to eq(nil)
    expect(version).to eq(nil)
  end

  it 'gets number of prs opened in a time frame' do
    allow(dependabot).to receive(:dependabot_history_per_repo).with(repo_name).and_return(dependabot_prs)
    allow(Time).to receive(:now).and_return(Time.parse('2023-03-10 00:00:00'))

    results = dependabot.get_repo_metrics(repo_name, from, to, 20)
    expect(results[:total_opened_prs]).to eq(5)
  end

  it 'gets the time since the prs are open including superseded prs' do
    allow(dependabot).to receive(:dependabot_history_per_repo).with(repo_name).and_return(dependabot_prs)
    allow(Time).to receive(:now).and_return(Time.parse('2023-03-10 00:00:00'))

    results = dependabot.get_repo_metrics(repo_name, from, to, 20)
    expect(results[:time_since_open]).to eq([11, 1])# how many days since the pr was open
  end

  it 'gets how long it took for the prs to be merged including superseded prs' do
    allow(dependabot).to receive(:dependabot_history_per_repo).with(repo_name).and_return(dependabot_prs)
    allow(Time).to receive(:now).and_return(Time.parse('2023-03-10 00:00:00'))

    results = dependabot.get_repo_metrics(repo_name, from, to, 20)
    expect(results[:time_to_merge]).to eq([10]) # how many days until the pr was merged
  end
end
