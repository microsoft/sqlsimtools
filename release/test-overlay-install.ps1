#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Tests that sqlsim and sqlpysim publish safely into an existing project.

.DESCRIPTION
    Publishes into a temporary project and verifies that publishing:
      - reports created files on a fresh install and nothing to do on a repeat;
      - refuses to replace a changed file without -Force and writes nothing;
      - lists the change with -Preview and writes nothing;
      - replaces with -Force and records it in the JSON report;
      - keeps files the project added under an overlay directory;
      - treats only the repository's release\sqlsimtools tree as disposable;
      - produces a package that passes validate-package-layout.ps1.

    Needs no SQL Server. sqlsim must already be built for -Architecture.

.PARAMETER Architecture
    sqlsim architecture to publish. Defaults to x64.

.EXAMPLE
    .\release\test-overlay-install.ps1
#>

param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sqlsimPublish = Join-Path $repositoryRoot 'sqlsim\publish.ps1'
$sqlpysimPublish = Join-Path $repositoryRoot 'sqlpysim\publish.ps1'
$validator = Join-Path $PSScriptRoot 'validate-package-layout.ps1'
Import-Module (Join-Path $PSScriptRoot 'OverlayInstall.psm1') -Force

$workspace = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimtools-overlay-test-{0}" -f [guid]::NewGuid().ToString('N'))
$reportPath = Join-Path $workspace '.overlay-report.json'
$script:passed = 0
$script:failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Check)
    try {
        $problem = & $Check
        if ($problem) { throw $problem }
        Write-Host "  ok      $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "  FAILED  $Name" -ForegroundColor Red
        Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkGray
        $script:failed++
    }
}

# Publishing prints progress through Write-Host; keep it for diagnosis
# without flooding the test output.
function Invoke-Publish {
    param([string]$Script, [hashtable]$Arguments)
    Remove-Item -LiteralPath $reportPath -ErrorAction SilentlyContinue
    $output = & $Script @Arguments -ReleaseDir $workspace -ReportPath $reportPath *>&1 | Out-String
    $report = if (Test-Path -LiteralPath $reportPath) { Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Report = $report }
}

$sqlsimArguments = @{ SkipBuild = $true; Architecture = $Architecture }
$sqlpysimArguments = @{ SkipHtmlGeneration = $true }
$skill = Join-Path $workspace '.github\skills\sqlsim\SKILL.md'
$agent = Join-Path $workspace '.github\agents\sqlsimtools-workload-builder.agent.md'
$userExample = Join-Path $workspace 'sqlsim\examples\my-team-workload.sql'

New-Item -ItemType Directory -Path $workspace -Force | Out-Null
Write-Host "Overlay install tests in $workspace" -ForegroundColor Cyan

try {
    Test-Case 'a fresh sqlsim install creates every file and replaces none' {
        $r = Invoke-Publish $sqlsimPublish $sqlsimArguments
        if ($r.ExitCode -ne 0) { return "publish failed:`n$($r.Output)" }
        if (@($r.Report.created).Count -lt 8) { return "expected the overlay to be created, report listed $(@($r.Report.created).Count) files" }
        if (@($r.Report.replaced).Count -ne 0) { return 'a fresh install reported replacements' }
        if (-not (Test-Path -LiteralPath (Join-Path $workspace "sqlsim\$Architecture\sqlsim.exe"))) { return 'executable not installed' }
    }

    Test-Case 'republishing the same release changes nothing' {
        $r = Invoke-Publish $sqlsimPublish $sqlsimArguments
        if ($r.ExitCode -ne 0) { return "publish failed:`n$($r.Output)" }
        if (@($r.Report.created).Count + @($r.Report.replaced).Count -ne 0) { return 'a repeat publish created or replaced files' }
    }

    Set-Content -LiteralPath $skill -Value '# my locally edited skill' -NoNewline
    Set-Content -LiteralPath $userExample -Value 'SELECT 1;' -NoNewline

    Test-Case 'a changed project file is not replaced without -Force, and nothing is written' {
        $before = (Get-FileHash -LiteralPath $skill).Hash
        $r = Invoke-Publish $sqlsimPublish $sqlsimArguments
        if ($r.ExitCode -eq 0) { return 'publish succeeded although a project file would have been replaced' }
        if ($r.Output -notmatch '\.github/skills/sqlsim/SKILL\.md') { return 'the refusal did not name the file' }
        if ($r.Output -notmatch '-Force') { return 'the refusal did not explain how to proceed' }
        if ((Get-FileHash -LiteralPath $skill).Hash -ne $before) { return 'the project file was changed anyway' }
    }

    Test-Case '-Preview lists the replacement and writes nothing' {
        $before = (Get-FileHash -LiteralPath $skill).Hash
        $r = Invoke-Publish $sqlsimPublish ($sqlsimArguments + @{ Preview = $true })
        if ($r.ExitCode -ne 0) { return "preview failed:`n$($r.Output)" }
        if (-not $r.Report.preview) { return 'report did not mark a preview' }
        if (@($r.Report.wouldReplace) -notcontains '.github/skills/sqlsim/SKILL.md') { return 'preview did not list the file it would replace' }
        if ((Get-FileHash -LiteralPath $skill).Hash -ne $before) { return 'preview changed the project file' }
    }

    Test-Case '-Force replaces the changed file and keeps the project''s own example' {
        $r = Invoke-Publish $sqlsimPublish ($sqlsimArguments + @{ Force = $true })
        if ($r.ExitCode -ne 0) { return "forced publish failed:`n$($r.Output)" }
        if (@($r.Report.replaced) -notcontains '.github/skills/sqlsim/SKILL.md') { return 'report did not record the replacement' }
        if ((Get-Content -LiteralPath $skill -Raw) -notmatch '^---\s+name: sqlsim') { return 'the release skill was not restored' }
        if (-not (Test-Path -LiteralPath $userExample)) { return 'the project''s own example file was deleted' }
        if (@($r.Report.kept) -notcontains 'sqlsim/examples/my-team-workload.sql') { return 'report did not list the kept example' }
    }

    Test-Case 'sqlpysim installs beside sqlsim and shares the Workload Builder' {
        $r = Invoke-Publish $sqlpysimPublish $sqlpysimArguments
        if ($r.ExitCode -ne 0) { return "publish failed:`n$($r.Output)" }
        if (@($r.Report.unchanged) -notcontains '.github/agents/sqlsimtools-workload-builder.agent.md') { return 'the shared agent was not recognised as already installed' }
        if (-not (Test-Path -LiteralPath (Join-Path $workspace 'sqlpysim\sqlpysim.py'))) { return 'sqlpysim was not installed' }
    }

    Test-Case 'sqlpysim also refuses to replace a changed shared agent without -Force' {
        Add-Content -LiteralPath $agent -Value "`n<!-- local note -->"
        $before = (Get-FileHash -LiteralPath $agent).Hash
        $r = Invoke-Publish $sqlpysimPublish $sqlpysimArguments
        if ($r.ExitCode -eq 0) { return 'publish succeeded although the shared agent would have been replaced' }
        if ((Get-FileHash -LiteralPath $agent).Hash -ne $before) { return 'the shared agent was changed anyway' }
        $forced = Invoke-Publish $sqlpysimPublish ($sqlpysimArguments + @{ Force = $true })
        if ($forced.ExitCode -ne 0) { return "forced publish failed:`n$($forced.Output)" }
    }

    Test-Case 'only the repository release staging tree is disposable' {
        if (-not (Test-OverlayStagingDirectory -Target (Join-Path $repositoryRoot 'release\sqlsimtools\1.0') -RepositoryRoot $repositoryRoot)) { return 'the default staging directory was not disposable' }
        if (Test-OverlayStagingDirectory -Target (Join-Path $repositoryRoot 'release') -RepositoryRoot $repositoryRoot) { return 'the release scripts directory was treated as disposable' }
        if (Test-OverlayStagingDirectory -Target $workspace -RepositoryRoot $repositoryRoot) { return 'a project directory was treated as disposable' }
        if (Test-OverlayStagingDirectory -Target (Join-Path $repositoryRoot 'release\sqlsimtools-other') -RepositoryRoot $repositoryRoot) { return 'a sibling directory matched the staging prefix' }
    }

    Test-Case 'the installed overlay passes offline package validation' {
        Remove-Item -LiteralPath $userExample -Force
        $output = & $validator -InstallRoot $workspace -Tool sqlsim, sqlpysim -SqlsimExecutable "sqlsim/$Architecture/sqlsim.exe" -SkipExecution:($Architecture -eq 'ARM64' -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64') *>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return "validation failed:`n$output" }
    }

    # Each check below breaks one thing in a copy of the package and expects
    # validation to fail for that reason.
    function Test-BrokenPackage {
        param([scriptblock]$Break, [string]$ExpectedMessage, [string]$Executable = "sqlsim/$Architecture/sqlsim.exe", [switch]$SkipExecution)
        $copy = "$workspace-broken"
        Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $workspace -Destination $copy -Recurse
        try {
            & $Break $copy
            $output = & $validator -InstallRoot $copy -Tool sqlsim, sqlpysim -SqlsimExecutable $Executable -SkipExecution:$SkipExecution *>&1 | Out-String
            if ($LASTEXITCODE -eq 0) { return 'validation passed a broken package' }
            if ($output -notmatch $ExpectedMessage) { return "validation failed for the wrong reason:`n$output" }
        } finally {
            Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'validation rejects a binary built for the wrong architecture' {
        Test-BrokenPackage -SkipExecution -Executable 'sqlsim/ARM64/sqlsim.exe' -ExpectedMessage 'is a x64 binary; its folder requires ARM64' -Break {
            param($root)
            New-Item -ItemType Directory -Path (Join-Path $root 'sqlsim\ARM64') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "sqlsim\$Architecture\sqlsim.exe") -Destination (Join-Path $root 'sqlsim\ARM64\sqlsim.exe')
        }
    }

    Test-Case 'validation recognises a macOS ARM64 binary and rejects a mismatched one' {
        # Headers only: a 64-bit Mach-O magic followed by the CPU type.
        $macArm64 = [byte[]](0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01) + [byte[]]::new(64)
        $macX64 = [byte[]](0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01) + [byte[]]::new(64)
        $problem = Test-BrokenPackage -SkipExecution -Executable 'sqlsim/arm64/sqlsim' -ExpectedMessage 'is a x64 binary; its folder requires ARM64' -Break {
            param($root)
            New-Item -ItemType Directory -Path (Join-Path $root 'sqlsim\arm64') -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $root 'sqlsim\arm64\sqlsim'), $macX64)
        }
        if ($problem) { return $problem }
        $copy = "$workspace-macos"
        Copy-Item -LiteralPath $workspace -Destination $copy -Recurse
        try {
            New-Item -ItemType Directory -Path (Join-Path $copy 'sqlsim\arm64') -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $copy 'sqlsim\arm64\sqlsim'), $macArm64)
            $output = & $validator -InstallRoot $copy -Tool sqlsim -SqlsimExecutable 'sqlsim/arm64/sqlsim' -SkipExecution *>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { return "a valid macOS ARM64 binary was rejected:`n$output" }
        } finally {
            Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'validation rejects an option the help lists but the manual omits' {
        if ($Architecture -eq 'ARM64' -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64') { return $null }
        Test-BrokenPackage -ExpectedMessage 'help lists options missing from the sqlpysim/sqlpysim.md Command Reference: -workload' -Break {
            param($root)
            $manual = Join-Path $root 'sqlpysim\sqlpysim.md'
            (Get-Content -LiteralPath $manual) | Where-Object { $_ -notmatch '^\|\s*`-workload' } | Set-Content -LiteralPath $manual
        }
    }

    Test-Case 'validation rejects a skill whose frontmatter names another tool' {
        Test-BrokenPackage -SkipExecution -ExpectedMessage "frontmatter name is not 'sqlsim'" -Break {
            param($root)
            $skillFile = Join-Path $root '.github\skills\sqlsim\SKILL.md'
            (Get-Content -LiteralPath $skillFile -Raw) -replace '(?m)^name: sqlsim', 'name: something-else' | Set-Content -LiteralPath $skillFile -NoNewline
        }
    }
} finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $script:passed  Failed: $script:failed" -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
exit ([int]($script:failed -gt 0))
