/*
 @OnlyCurrentDoc
 */

/*
Formulas for conditional formatting of Repos tab
Green: =ISNUMBER(MATCH(C2,INDEX(INDIRECT("'Tracking and reference'!$B$2:$G$10"),MATCH(C$1,INDIRECT("'Tracking and reference'!$A$2:$A$10"),0)),0))
Red: =NOT(ISNUMBER(MATCH(C2,INDEX(INDIRECT("'Tracking and reference'!$B$2:$G$10"),MATCH(C$1,INDIRECT("'Tracking and reference'!$A$2:$A$10"),0)),0)))
*/

/*
Adds a custom menu to the spreadsheet on opening.
 */
function onOpen() {
  var spreadsheet = SpreadsheetApp.getActive();
  var menuItems = [
    {name: 'Refresh Repos tab', functionName: 'updateRepos'},
  ];
  spreadsheet.addMenu('Update Data', menuItems);
}

/*
 Fetches the CSV, clears the 'Repos' sheet.
 */
function updateRepos() {
  var csvUrl = "https://docs.publishing.service.gov.uk/repos.csv";
  var csvContent = UrlFetchApp.fetch(csvUrl).getContentText();
  var csvData = Utilities.parseCsv(csvContent);

  var sheet = SpreadsheetApp.getActive().getSheetByName('Repos');
  sheet.clear({ contentsOnly: true });
  sheet.getRange(1, 1, csvData.length, csvData[0].length).setValues(csvData);
  updateSheet_(sheet);
}

// Global cache object to store fetched file contents
var fileCache = {};

/*
 Fetches the contents of a file from a URL, using cache to reduce HTTP requests.
 */
function getFileContents_(url) {
  // Check if the file content is already cached
  if (fileCache[url]) {
    return fileCache[url];
  }

  var response = UrlFetchApp.fetch(url, {muteHttpExceptions: true});
  var content;
  switch(response.getResponseCode()) {
    case 200:
      content = response.getContentText().trim();
      break;
    case 404:
      content = undefined;
      break;
    default:
      Logger.log("HTTP code: %d, body: %s", response.getResponseCode(), response.getContentText());
      content = undefined;
  }

  // Store the fetched content in the cache
  fileCache[url] = content;
  return content;
}

/*
 Updates the sheet by setting headers and processing each row.
 */
function updateSheet_(sheet) {
  updateHeaders_(sheet);
  var endRow = sheet.getLastRow();

  for (var r = 2; r <= endRow; r++) {
    updateRow_(sheet.getRange(r, 1, 1, 5));
  }
}

/*
 Sets the headers for the 'Repos' sheet.
 */
function updateHeaders_(sheet) {
  var headers = ["Ruby", "Rails", "Mongoid", "Sidekiq", "Schema", "Slimmer",
                 "govuk_publishing_components", "govuk_app_config",
                 "activesupport", "activerecord", "Gem?", "Has dependabot.yml?"];
  sheet.getRange(1, 3, 1, headers.length).setValues([headers]);
}

/*
 Updates each row with version data.
 */
function updateRow_(row) {
  var repo = row.getValue();
  if (repo) {
    var updateFunctions = [
      updateRubyVersion_,
      updateRailsVersion_,
      updateMongoidVersion_,
      updateSidekiqVersion_,
      updateSchemasVersion_,
      updateSlimmerVersion_,
      updateComponentVersion_,
      updateAppConfigVersion_,
      updateActiveSupportVersion_,
      updateActiveRecordVersion_,
      updateRepoType,
      updateDependabotyml
    ];

    updateFunctions.forEach(function(updateFunc, index) {
      updateFunc(repo, row.offset(0, index + 2, 1, 1));
    });
  }
}

/*
 Fetches and updates the Ruby version.
 */
function updateRubyVersion_(repo, targetCell) {
  var url = `https://raw.githubusercontent.com/alphagov/${repo}/main/.ruby-version`;
  var version = getFileContents_(url);
  targetCell.setValue(version || "n/a");
}

/*
 Fetches and updates the Rails version.
 */
function updateRailsVersion_(repo, targetCell) {
  if (repo === 'errbit') return updateErrbitRailsVersion_(repo, targetCell);
  if (repo === 'bouncer') return updateBouncerRailsVersion_(repo, targetCell);

  var version = getVersionFromGemfileLock_(repo, 'rails') || getVersionFromGemfile_(repo, 'rails') || '';
  targetCell.setValue(version);
}

/*
 Fetches and updates the Mongoid version. Mongoid may be specified implicitly as a dependency
 (e.g. by using govuk_content_models, so we check Gemfile.lock, not Gemfile
 */
function updateMongoidVersion_(repo, targetCell) {
  var version = getVersionFromGemfileLock_(repo, 'mongoid') || getVersionFromGemfile_(repo, 'mongoid') || '';
  targetCell.setValue(version);
}

/*
 Handles specific logic for Errbit's Rails version. Errbit doesn't depend on all of Rails, it only
 depends on actionpack, actionmailer and railties. We therefore pull the pinned version of one of
 these from Gemfile.lock
 */
function updateErrbitRailsVersion_(repo, targetCell) {
  var version = getVersionFromGemfileLock_(repo, 'actionpack') || '';
  targetCell.setValue(version);
}

/*
 Handles specific logic for Bouncer's Rails version. Bouncer doesn't depend on Rails, but it does use
 ActiveRecord so we pull the pinned version of that from Gemfile.lock
 */
function updateBouncerRailsVersion_(repo, targetCell) {
  var version = getVersionFromGemfileLock_(repo, 'activerecord') || '';
  targetCell.setValue(version);
}

/*
 Fetches version from Gemfile.lock for specified dependency, or returns default.
 */
function getVersionFromGemfileLock_(repo, dependencyName) {
  var gemfileLock = getFileContents_(`https://raw.githubusercontent.com/alphagov/${repo}/master/Gemfile.lock`);
  if (!gemfileLock) return undefined;

  var regex = new RegExp(`\\n    ${dependencyName}\\s+\\(([\\d.]+)\\)`);
  var matches = gemfileLock.match(regex);
  return matches ? matches[1] || "unable to fetch version from Gemfile.lock" : "n/a";
}

/*
 Fetches version from Gemfile for specified dependency, with fallback options.
 */
function getVersionFromGemfile_(repo, dependencyName) {
  var gemfile = getFileContents_(`https://raw.githubusercontent.com/alphagov/${repo}/master/Gemfile`);
  if (!gemfile) return undefined;

  var regex = new RegExp(`gem\\s+['"]${dependencyName}['"], ['"]([^'"]+)['"]`);
  var matches = gemfile.match(regex);
  if (matches) return matches[1] || "Unable to fetch version from Gemfile";

  if (gemfile.match(/\ngemspec/)) return getVersionFromGemspec_(repo, dependencyName);
  return "n/a";
}

/*
 Fetches version from gemspec for specified dependency.
 */
function getVersionFromGemspec_(repo, dependencyName) {
  var gemspec = getFileContents_(`https://raw.githubusercontent.com/alphagov/${repo}/master/${repo}.gemspec`);
  if (!gemspec) return undefined;

  var regex = new RegExp(`"${dependencyName}"(?:,\\s+['"](.+)[\"'])+`);
  var matches = gemspec.match(regex);
  return matches ? matches[1] || "any version" : "n/a";
}

/*
 Checks if a repo is a gem by looking for a gemspec file.
 */
function updateRepoType(repo, targetCell) {
  var isGem = getFileContents_(`https://raw.githubusercontent.com/alphagov/${repo}/master/${repo}.gemspec`) ? "Yes" : "No";
  targetCell.setValue(isGem);
}

/*
 Checks for the presence of a dependabot.yml file.
 */
function updateDependabotyml(repo, targetCell) {
  var hasDependabot = getFileContents_(`https://raw.githubusercontent.com/alphagov/${repo}/master/.github/dependabot.yml`) ? "Yes" : "No";
  targetCell.setValue(hasDependabot);
}

// Fetch and update versions for various dependencies
function updateSidekiqVersion_(repo, targetCell) {
  updateDependencyVersion_(repo, targetCell, 'sidekiq');
}

function updateSchemasVersion_(repo, targetCell) {
  updateDependencyVersion_(repo, targetCell, 'govuk_schemas');
}

function updateSlimmerVersion_(repo, targetCell) {
  updateDependencyVersion_(repo, targetCell, 'slimmer');
}

function updateComponentVersion_(repo, targetCell) {
  updateDependencyVersion_(repo, targetCell, 'govuk_publishing_components');
}

function updateAppConfigVersion_(repo, targetCell) {
  updateDependencyVersion_(repo, targetCell, 'govuk_app_config');
}

function updateActiveSupportVersion_(repo, targetCell) {
  updateDependencyVersion_(repo, targetCell, 'activesupport');
}

function updateActiveRecordVersion_(repo, targetCell) {
  updateDependencyVersion_(repo, targetCell, 'activerecord');
}

/*
 General function to update dependency versions.
 */
function updateDependencyVersion_(repo, targetCell, dependencyName) {
  var version = getVersionFromGemfileLock_(repo, dependencyName) || '';
  targetCell.setValue(version);
}