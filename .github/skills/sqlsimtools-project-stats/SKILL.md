---
name: sqlsimtools-project-stats
description: "Source-repository-only maintainer report of current sqlsimtools project numbers: release download counts per file, GitHub Pages website status and click-throughs, 14-day repository views, clones, referrers, and popular pages, plus stars, forks, and watchers. USE WHEN: a maintainer asks for project stats, download numbers, how many people downloaded a release, website or repository traffic, referrers, or how usage changed since earlier numbers. DO NOT USE FOR: tool run telemetry (sqlsimtools collects none), Google Search Console or Bing Webmaster Tools data (view those in their portals), or running SQL workloads (use the sqlsim, sqlpysim, or sqlsimstudio skills)."
argument-hint: "Optional: earlier numbers or a date to compare against"
---

# sqlsimtools project stats

Reports the latest public-interest numbers for `microsoft/sqlsimtools` by
running the repository script `scripts/get-project-stats.ps1`. The report is
read-only; never change repository settings, files, or releases while using
this skill.

## Procedure

1. From the repository root, run the script with JSON output and capture it in
   a variable. Do not add shell redirects or pipes to the command itself.

   ```powershell
   $stats = .\scripts\get-project-stats.ps1 -Json | ConvertFrom-Json
   ```

   If it fails because the GitHub CLI is missing or signed out, tell the user to
   install it from https://cli.github.com/ or run `gh auth login`, then stop.

2. Summarize for the user, in this order:
   - **Downloads:** `downloads.total`, then each release in
     `downloads.releases` with its files sorted by `downloads`, highest first.
   - **Website:** `website.status` for `website.url`, and
     `website.clickThroughs` (`website.uniqueClickThroughs` unique) from the
     site into GitHub over the last 14 days.
   - **Repository traffic (last 14 days):** `traffic.views`,
     `traffic.clones`, the top `traffic.referrers`, and the top
     `traffic.pages`. Mention any notable day in `traffic.dailyViews`.
   - **Repository:** stars, forks, watchers, and open issues and pull requests
     from `repositoryCounts`.

3. If the user supplied earlier numbers or asked about change over time,
   report the difference for each comparable value. Compare download totals
   per file, not only the grand total.

## Interpreting the numbers

State these caveats when they affect the answer:

- Download counts are running totals since each file was uploaded. GitHub keeps
  no daily history, and the automatic "Source code" archives are not counted.
  The maintainers' own test downloads are included.
- Traffic covers only the last 14 days. Unique visitors cannot be added across
  days or periods.
- Clones include CI checkouts, so they overstate real users.
- GitHub provides no visitor analytics for the Pages site. Click-throughs count
  only visitors who followed a link from the site into GitHub. For search
  impressions and clicks, point the user to Google Search Console and Bing
  Webmaster Tools (URLs in `website`).
- If `traffic` is null and `trafficError` is set, the signed-in account lacks
  push access. Report downloads and repository counts, and explain that
  traffic and click-throughs need a maintainer account.

## Formatted report

When the user wants the full console report instead of a summary, run:

```powershell
.\scripts\get-project-stats.ps1
```
