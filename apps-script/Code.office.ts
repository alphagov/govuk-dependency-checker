const CONFIG = {
  reposSheetName: "Repos",
  trackingSheetName: "Tracking and reference",
  csvUrl: "https://docs.publishing.service.gov.uk/repos.csv",
  githubOrg: "alphagov",
  branches: {
    default: "master",
    rubyVersion: "main",
    dependabotMerger: "main",
  },
  debugMaxRepos: 0,
};

const HEADERS = [
  "Ruby",
  "Rails",
  "Mongoid",
  "Sidekiq",
  "Schema",
  "govuk_publishing_components",
  "govuk_app_config",
  "activesupport",
  "activerecord",
  "Gem?",
  "Has dependabot.yml?",
  "Uses Dependabot Auto-merger?",
  "Dependabot Auto-Merger version",
  "Auto-merging external dependencies?",
];

const fileCache: Record<string, string | undefined> = {};

interface RunSummary {
  success: boolean;
  csvRowCount: number;
  csvColumnCount: number;
  reposFound: number;
  reposAttempted: number;
  reposCompleted: number;
  lastRepoStarted: string;
  lastRepoCompleted: string;
  fetchCount: number;
  cacheHits: number;
  missingFiles: number;
  rowErrors: string[];
  httpErrors: string[];
  steps: string[];
}

function createSummary(): RunSummary {
  return {
    success: false,
    csvRowCount: 0,
    csvColumnCount: 0,
    reposFound: 0,
    reposAttempted: 0,
    reposCompleted: 0,
    lastRepoStarted: "",
    lastRepoCompleted: "",
    fetchCount: 0,
    cacheHits: 0,
    missingFiles: 0,
    rowErrors: [],
    httpErrors: [],
    steps: [],
  };
}

function logStep(summary: RunSummary, message: string) {
  summary.steps.push(message);
}

async function main(workbook: ExcelScript.Workbook): Promise<RunSummary> {
  const summary = createSummary();

  try {
    await updateRepos(workbook, summary);
    summary.success = true;
    logStep(summary, "Run completed");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    logStep(summary, `Run failed: ${message}`);
  }

  return summary;
}

async function updateRepos(workbook: ExcelScript.Workbook, summary: RunSummary): Promise<void> {
  logStep(summary, `Fetching CSV from ${CONFIG.csvUrl}`);
  const csvContent = await fetchText(CONFIG.csvUrl, summary);

  logStep(summary, "Parsing CSV");
  const csvData = parseCsv(csvContent);

  if (csvData.length === 0 || csvData[0].length === 0) {
    throw new Error("CSV returned no data");
  }

  summary.csvRowCount = csvData.length;
  summary.csvColumnCount = csvData[0].length;
  summary.reposFound = Math.max(csvData.length - 1, 0);
  logStep(summary, `CSV parsed: ${summary.csvRowCount} rows x ${summary.csvColumnCount} columns`);

  const outputRows = await buildOutputRows(csvData, summary);

  logStep(summary, `Opening worksheet ${CONFIG.reposSheetName}`);
  const sheet = getWorksheetOrThrow(workbook, CONFIG.reposSheetName);

  logStep(summary, "Clearing worksheet contents");
  clearSheetContents(sheet);

  logStep(summary, "Writing CSV data to worksheet");
  sheet.getRangeByIndexes(0, 0, csvData.length, csvData[0].length).setValues(csvData);

  logStep(summary, "Writing derived headers");
  writeHeaders(sheet);

  if (outputRows.length > 0) {
    logStep(summary, `Writing ${outputRows.length} derived rows`);
    sheet.getRangeByIndexes(1, 2, outputRows.length, HEADERS.length).setValues(outputRows);
  } else {
    logStep(summary, "No derived rows to write");
  }
}

async function buildOutputRows(csvData: string[][], summary: RunSummary): Promise<string[][]> {
  const dataRows = csvData.slice(1);
  const rowsToProcess = CONFIG.debugMaxRepos > 0 ? dataRows.slice(0, CONFIG.debugMaxRepos) : dataRows;

  if (CONFIG.debugMaxRepos > 0) {
    logStep(summary, `Debug mode enabled: processing first ${rowsToProcess.length} repos`);
  }

  const outputRows: string[][] = [];

  for (let rowIndex = 0; rowIndex < rowsToProcess.length; rowIndex += 1) {
    const repo = String(rowsToProcess[rowIndex][0] ?? "").trim();
    outputRows.push(await buildOutputRowForRepo(repo, summary, rowsToProcess.length));
  }

  for (let rowIndex = rowsToProcess.length; rowIndex < dataRows.length; rowIndex += 1) {
    outputRows.push(blankOutputRow());
  }

  return outputRows;
}

async function buildOutputRowForRepo(repo: string, summary: RunSummary, totalRows: number): Promise<string[]> {
  if (!repo) {
    return blankOutputRow();
  }

  summary.reposAttempted += 1;
  summary.lastRepoStarted = repo;

  return await safelyBuildRepoRow(repo, summary, totalRows);
}

async function safelyBuildRepoRow(repo: string, summary: RunSummary, totalRows: number): Promise<string[]> {
  try {
    const row = await buildRow(repo);
    summary.reposCompleted += 1;
    summary.lastRepoCompleted = repo;

    if (summary.reposCompleted <= 5 || summary.reposCompleted % 25 === 0) {
      logStep(summary, `Processed ${summary.reposCompleted}/${totalRows}: ${repo}`);
    }

    return row;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const rowError = `${repo}: ${message}`;
    summary.rowErrors.push(rowError);
    logStep(summary, `Row error: ${rowError}`);
    return errorOutputRow(message);
  }
}

function getWorksheetOrThrow(workbook: ExcelScript.Workbook, sheetName: string): ExcelScript.Worksheet {
  const sheet = workbook.getWorksheet(sheetName);

  if (!sheet) {
    throw new Error(`Worksheet not found: ${sheetName}`);
  }

  return sheet;
}

function clearSheetContents(sheet: ExcelScript.Worksheet) {
  const usedRange = sheet.getUsedRange();

  if (usedRange) {
    usedRange.clear(ExcelScript.ClearApplyTo.contents);
  }
}

async function getFileContents(url: string, summary?: RunSummary): Promise<string | undefined> {
  if (Object.prototype.hasOwnProperty.call(fileCache, url)) {
    if (summary) summary.cacheHits += 1;
    return fileCache[url];
  }

  if (summary) summary.fetchCount += 1;
  const response = await fetch(url);
  let content: string | undefined;

  if (response.status === 200) {
    content = (await response.text()).trim();
  } else if (response.status === 404) {
    if (summary) summary.missingFiles += 1;
    content = undefined;
  } else {
    const body = await response.text();
    const message = `HTTP ${response.status} for ${url}`;
    if (summary) summary.httpErrors.push(message);
    console.log(`${message} :: ${body}`);
    content = undefined;
  }

  fileCache[url] = content;
  return content;
}

async function fetchText(url: string, summary?: RunSummary): Promise<string> {
  if (summary) summary.fetchCount += 1;
  const response = await fetch(url);

  if (!response.ok) {
    const body = await response.text();
    const message = `Failed to fetch ${url}: ${response.status}`;
    if (summary) summary.httpErrors.push(message);
    throw new Error(`${message} :: ${body}`);
  }

  return await response.text();
}

function writeHeaders(sheet: ExcelScript.Worksheet) {
  sheet.getRangeByIndexes(0, 2, 1, HEADERS.length).setValues([HEADERS]);
}

function blankOutputRow(): string[] {
  return HEADERS.map(() => "");
}

function errorOutputRow(message: string): string[] {
  return [
    `ERROR`,
    truncate(message),
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
  ];
}

async function buildRow(repo: string): Promise<string[]> {
  return [
    await getRubyVersion(repo),
    await getRailsVersion(repo),
    await getMongoidVersion(repo),
    await getDependencyVersion(repo, "sidekiq"),
    await getDependencyVersion(repo, "govuk_schemas"),
    await getDependencyVersion(repo, "govuk_publishing_components"),
    await getDependencyVersion(repo, "govuk_app_config"),
    await getDependencyVersion(repo, "activesupport"),
    await getDependencyVersion(repo, "activerecord"),
    await getRepoType(repo),
    await getDependabotYml(repo),
    await getDependabotMerger(repo),
    await getDependabotMergerVersion(repo),
    await getDependabotMergingExternalDependencies(repo),
  ];
}

async function getRubyVersion(repo: string): Promise<string> {
  const version = await getFileContents(rawUrl(repo, CONFIG.branches.rubyVersion, ".ruby-version"));
  return version || "n/a";
}

async function getRailsVersion(repo: string): Promise<string> {
  if (repo === "errbit") return getErrbitRailsVersion(repo);
  if (repo === "bouncer") return getBouncerRailsVersion(repo);

  return (
    (await getVersionFromGemfileLock(repo, "rails")) ||
    (await getVersionFromGemfile(repo, "rails")) ||
    ""
  );
}

async function getMongoidVersion(repo: string): Promise<string> {
  return (
    (await getVersionFromGemfileLock(repo, "mongoid")) ||
    (await getVersionFromGemfile(repo, "mongoid")) ||
    ""
  );
}

async function getErrbitRailsVersion(repo: string): Promise<string> {
  return (await getVersionFromGemfileLock(repo, "actionpack")) || "";
}

async function getBouncerRailsVersion(repo: string): Promise<string> {
  return (await getVersionFromGemfileLock(repo, "activerecord")) || "";
}

async function getVersionFromGemfileLock(repo: string, dependencyName: string): Promise<string | undefined> {
  const gemfileLock = await getFileContents(rawUrl(repo, CONFIG.branches.default, "Gemfile.lock"));
  if (!gemfileLock) return undefined;

  const regex = new RegExp(`\\n    ${escapeRegex(dependencyName)}\\s+\\(([\\d.]+)\\)`);
  const matches = gemfileLock.match(regex);
  return matches ? matches[1] || "unable to fetch version from Gemfile.lock" : "n/a";
}

async function getVersionFromGemfile(repo: string, dependencyName: string): Promise<string | undefined> {
  const gemfile = await getFileContents(rawUrl(repo, CONFIG.branches.default, "Gemfile"));
  if (!gemfile) return undefined;

  const regex = new RegExp(`gem\\s+['\"]${escapeRegex(dependencyName)}['\"], ['\"]([^'\"]+)['\"]`);
  const matches = gemfile.match(regex);
  if (matches) return matches[1] || "Unable to fetch version from Gemfile";

  if (gemfile.match(/\ngemspec/)) return getVersionFromGemspec(repo, dependencyName);
  return "n/a";
}

async function getVersionFromGemspec(repo: string, dependencyName: string): Promise<string | undefined> {
  const gemspec = await getFileContents(rawUrl(repo, CONFIG.branches.default, `${repo}.gemspec`));
  if (!gemspec) return undefined;

  const regex = new RegExp(`\"${escapeRegex(dependencyName)}\"(?:,\\s+['\"](.+)[\"'])+`);
  const matches = gemspec.match(regex);
  return matches ? matches[1] || "any version" : "n/a";
}

async function getRepoType(repo: string): Promise<string> {
  const gemspec = await getFileContents(rawUrl(repo, CONFIG.branches.default, `${repo}.gemspec`));
  return gemspec ? "Yes" : "No";
}

async function getDependabotYml(repo: string): Promise<string> {
  const dependabotYml = await getFileContents(rawUrl(repo, CONFIG.branches.default, ".github/dependabot.yml"));
  return dependabotYml ? "Yes" : "No";
}

async function getDependabotMerger(repo: string): Promise<string> {
  const yml = await getFileContents(rawUrl(repo, CONFIG.branches.dependabotMerger, ".govuk_dependabot_merger.yml"));
  return yml ? "Yes" : "No";
}

async function getDependabotMergerVersion(repo: string): Promise<string> {
  const config = await getFileContents(rawUrl(repo, CONFIG.branches.dependabotMerger, ".govuk_dependabot_merger.yml"));

  if (config === undefined) return "";
  if (config.includes("api_version: 2")) return "2";
  if (config.includes("api_version: 1")) return "1";
  return "";
}

async function getDependabotMergingExternalDependencies(repo: string): Promise<string> {
  const config = await getFileContents(rawUrl(repo, CONFIG.branches.dependabotMerger, ".govuk_dependabot_merger.yml"));

  if (config === undefined) return "";
  return config.includes("update_external_dependencies: true") ? "Yes" : "No";
}

async function getDependencyVersion(repo: string, dependencyName: string): Promise<string> {
  return (await getVersionFromGemfileLock(repo, dependencyName)) || "";
}

function rawUrl(repo: string, branch: string, path: string): string {
  return `https://raw.githubusercontent.com/${CONFIG.githubOrg}/${repo}/${branch}/${path}`;
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function truncate(value: string, maxLength: number = 120): string {
  return value.length > maxLength ? `${value.slice(0, maxLength - 3)}...` : value;
}

function parseCsv(csvText: string): string[][] {
  const rows: string[][] = [];
  let currentRow: string[] = [];
  let currentValue = "";
  let insideQuotes = false;

  for (let index = 0; index < csvText.length; index += 1) {
    const char = csvText[index];
    const nextChar = csvText[index + 1];

    if (char === '"') {
      if (insideQuotes && nextChar === '"') {
        currentValue += '"';
        index += 1;
      } else {
        insideQuotes = !insideQuotes;
      }
    } else if (char === "," && !insideQuotes) {
      currentRow.push(currentValue);
      currentValue = "";
    } else if ((char === "\n" || char === "\r") && !insideQuotes) {
      if (char === "\r" && nextChar === "\n") {
        index += 1;
      }

      currentRow.push(currentValue);
      rows.push(currentRow);
      currentRow = [];
      currentValue = "";
    } else {
      currentValue += char;
    }
  }

  if (currentValue.length > 0 || currentRow.length > 0) {
    currentRow.push(currentValue);
    rows.push(currentRow);
  }

  const width = rows.reduce((max, row) => Math.max(max, row.length), 0);
  return rows.map((row) => [...row, ...Array(width - row.length).fill("")]);
}
