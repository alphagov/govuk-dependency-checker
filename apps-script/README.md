# Apps Script

This directory contains spreadsheet automation for dependency tracking.

- `Code.gs` populates the Google Sheets `Repos` tab on the [dependencies spreadsheet](https://docs.google.com/spreadsheets/d/137KZhjctJ8qTKYPnq2QNVkyoIC6ok7KA2G1vErNC6Oo/edit#gid=1160366178)
- `Code.office.ts` is Office Scripts version for Excel Online

## Google Sheets

Whenever `Code.gs` is updated, it needs to be manually copied to the spreadsheet's Apps Script extension.

### How to make changes

After getting changes approved and merged:

- Go to spreadsheet
- Click Extensions -> Apps Script
- Paste new `Code.gs` in and save
- Press `Update Data` in spreadsheet to run script

## Excel Online

`Code.office.ts` is a port of Google Apps Script for Excel Online.

### Config

The top-level `CONFIG` object contains sheet names and URLs to change if needed:

- `reposSheetName`
- `trackingSheetName`
- `csvUrl`
- `githubOrg`
- `branches.default`
- `branches.rubyVersion`
- `branches.dependabotMerger`
- `debugMaxRepos` — set to a small number like `10` for diagnosis

### How to use

- Open workbook in Excel Online
- Go to `Automate`
- Create new script
- Paste contents of `Code.office.ts`
- Save script
- Run script from `Automate`
- Check returned output object for fetch counts, last processed repo, row errors, and HTTP errors

Excel Online does not support Apps Script custom menus, so this version is run from the `Automate` tab.
