<#
.SYNOPSIS
    Show current sqlsimtools release downloads, website, and repository traffic numbers.

.DESCRIPTION
    Uses the GitHub CLI to collect:

    - Release download counts for every uploaded release file. GitHub keeps
      running totals only; the automatic "Source code" archives are not counted.
    - GitHub Pages site status and click-throughs from the site into GitHub.
      GitHub provides no visitor analytics for Pages, so the referrer count
      for microsoft.github.io is the closest built-in signal.
    - Repository views, clones, top referrers, and popular pages for the last
      14 days, which is all GitHub retains.
    - Stars, forks, watchers, and open issues and pull requests.

    Traffic numbers require push access to the repository. Without it, the
    script still reports downloads and repository counts.

.PARAMETER Json
    Write a single JSON document instead of the formatted report.

.EXAMPLE
    ./scripts/get-project-stats.ps1

.EXAMPLE
    ./scripts/get-project-stats.ps1 -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [string]$Owner = 'microsoft',

    [string]$Repo = 'sqlsimtools',

    [string]$SiteUrl = 'https://microsoft.github.io/sqlsimtools/',

    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'The GitHub CLI (gh) is required. Install it from https://cli.github.com/ and run "gh auth login".'
}
$null = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'The GitHub CLI is not signed in. Run "gh auth login" and try again.'
}

$repoPath = "repos/$Owner/$Repo"
$siteHost = ([Uri]$SiteUrl).Host

function Invoke-GhApi {
    param([Parameter(Mandatory)][string]$Path)

    $output = gh api -H 'Accept: application/vnd.github+json' $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Ok = $false; Data = $null; Error = ($output | Out-String).Trim() }
    }
    return [pscustomobject]@{ Ok = $true; Data = (($output | Out-String) | ConvertFrom-Json); Error = $null }
}

# Repository counts
$repoResult = Invoke-GhApi $repoPath
if (-not $repoResult.Ok) { throw "Could not read $Owner/$Repo. $($repoResult.Error)" }
$repoInfo = $repoResult.Data
$repository = [ordered]@{
    stars                   = $repoInfo.stargazers_count
    forks                   = $repoInfo.forks_count
    watchers                = $repoInfo.subscribers_count
    openIssuesAndPulls      = $repoInfo.open_issues_count
}

# Release downloads
$releases = @()
$page = 1
do {
    $result = Invoke-GhApi "$repoPath/releases?per_page=100&page=$page"
    if (-not $result.Ok) { throw "Could not read releases. $($result.Error)" }
    $batch = @($result.Data)
    $releases += $batch
    $page++
} while ($batch.Count -eq 100)

$releaseRows = foreach ($release in $releases) {
    $assets = foreach ($asset in @($release.assets)) {
        [ordered]@{
            name      = $asset.name
            downloads = [int]$asset.download_count
            uploaded  = ([datetime]$asset.created_at).ToString('yyyy-MM-dd')
        }
    }
    [ordered]@{
        tag        = $release.tag_name
        published  = if ($release.published_at) { ([datetime]$release.published_at).ToString('yyyy-MM-dd') } else { 'draft' }
        prerelease = [bool]$release.prerelease
        downloads  = [int](($assets | ForEach-Object { $_.downloads } | Measure-Object -Sum).Sum)
        assets     = @($assets)
    }
}
$releaseRows = @($releaseRows)
$totalDownloads = [int](($releaseRows | ForEach-Object { $_.downloads } | Measure-Object -Sum).Sum)

# Repository traffic (last 14 days; requires push access)
$views     = Invoke-GhApi "$repoPath/traffic/views"
$clones    = Invoke-GhApi "$repoPath/traffic/clones"
$referrers = Invoke-GhApi "$repoPath/traffic/popular/referrers"
$paths     = Invoke-GhApi "$repoPath/traffic/popular/paths"
$trafficAvailable = $views.Ok -and $clones.Ok -and $referrers.Ok -and $paths.Ok

$traffic = $null
$siteReferrer = $null
if ($trafficAvailable) {
    $siteReferrer = @($referrers.Data) | Where-Object { $_.referrer -eq $siteHost } | Select-Object -First 1
    $traffic = [ordered]@{
        views      = [ordered]@{ total = $views.Data.count; unique = $views.Data.uniques }
        clones     = [ordered]@{ total = $clones.Data.count; unique = $clones.Data.uniques }
        dailyViews = @(@($views.Data.views) | ForEach-Object {
                [ordered]@{ date = ([datetime]$_.timestamp).ToUniversalTime().ToString('yyyy-MM-dd'); total = $_.count; unique = $_.uniques }
            })
        referrers  = @(@($referrers.Data) | ForEach-Object { [ordered]@{ referrer = $_.referrer; total = $_.count; unique = $_.uniques } })
        pages      = @(@($paths.Data) | ForEach-Object { [ordered]@{ path = $_.path; total = $_.count; unique = $_.uniques } })
    }
}

# Website status
$siteStatus = $null
try {
    $siteStatus = (Invoke-WebRequest -Uri $SiteUrl -UseBasicParsing -Method Head -TimeoutSec 20).StatusCode
} catch {
    $siteStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'unreachable' }
}
$website = [ordered]@{
    url                 = $SiteUrl
    status              = $siteStatus
    clickThroughs       = if ($siteReferrer) { $siteReferrer.count } elseif ($trafficAvailable) { 0 } else { $null }
    uniqueClickThroughs = if ($siteReferrer) { $siteReferrer.uniques } elseif ($trafficAvailable) { 0 } else { $null }
    searchConsole       = 'https://search.google.com/search-console'
    bingWebmasterTools  = 'https://www.bing.com/webmasters'
}

$report = [ordered]@{
    repository       = "$Owner/$Repo"
    generatedUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    downloads        = [ordered]@{ total = $totalDownloads; releases = $releaseRows }
    website          = $website
    traffic          = $traffic
    trafficError     = if ($trafficAvailable) { $null } else { 'Traffic data requires push access to the repository.' }
    repositoryCounts = $repository
}

if ($Json) {
    $report | ConvertTo-Json -Depth 8
    return
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor Cyan
}

Write-Host "sqlsimtools project stats for $Owner/$Repo ($($report.generatedUtc))" -ForegroundColor White

Write-Section 'Release downloads (running totals)'
if ($releaseRows.Count -eq 0) {
    Write-Host '  No releases found.'
}
foreach ($release in $releaseRows) {
    $label = if ($release.prerelease) { ' (prerelease)' } else { '' }
    Write-Host ("  {0}{1}, published {2}: {3} downloads" -f $release.tag, $label, $release.published, $release.downloads)
    foreach ($asset in ($release.assets | Sort-Object { $_.downloads } -Descending)) {
        Write-Host ("    {0,6}  {1}" -f $asset.downloads, $asset.name)
    }
}
Write-Host ("  Total: {0} downloads" -f $totalDownloads) -ForegroundColor Green

Write-Section 'Website (GitHub Pages)'
Write-Host "  $SiteUrl  status: $siteStatus"
if ($trafficAvailable) {
    Write-Host ("  Click-throughs from the site into GitHub (14 days): {0} ({1} unique)" -f $website.clickThroughs, $website.uniqueClickThroughs)
} else {
    Write-Host '  Click-throughs: unavailable (traffic data requires push access)'
}
Write-Host '  GitHub has no visitor analytics for Pages. For search impressions and clicks, see:'
Write-Host "    Google Search Console: $($website.searchConsole)"
Write-Host "    Bing Webmaster Tools:  $($website.bingWebmasterTools)"

Write-Section 'Repository traffic (last 14 days)'
if (-not $trafficAvailable) {
    Write-Host '  Unavailable: traffic data requires push access to the repository.' -ForegroundColor Yellow
} else {
    Write-Host ("  Views:  {0} ({1} unique)" -f $traffic.views.total, $traffic.views.unique)
    Write-Host ("  Clones: {0} ({1} unique; includes CI checkouts)" -f $traffic.clones.total, $traffic.clones.unique)
    if ($traffic.dailyViews.Count -gt 0) {
        Write-Host '  Daily views:'
        foreach ($day in $traffic.dailyViews) {
            Write-Host ("    {0}  {1,4} ({2} unique)" -f $day.date, $day.total, $day.unique)
        }
    }
    Write-Host '  Top referrers:'
    if ($traffic.referrers.Count -eq 0) { Write-Host '    none yet' }
    foreach ($item in $traffic.referrers) {
        Write-Host ("    {0,4} ({1} unique)  {2}" -f $item.total, $item.unique, $item.referrer)
    }
    Write-Host '  Popular pages:'
    if ($traffic.pages.Count -eq 0) { Write-Host '    none yet' }
    foreach ($item in $traffic.pages) {
        Write-Host ("    {0,4} ({1} unique)  {2}" -f $item.total, $item.unique, $item.path)
    }
}

Write-Section 'Repository'
Write-Host ("  Stars: {0}   Forks: {1}   Watchers: {2}   Open issues and PRs: {3}" -f `
        $repository.stars, $repository.forks, $repository.watchers, $repository.openIssuesAndPulls)
Write-Host ''
