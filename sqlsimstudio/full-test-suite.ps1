#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Full test suite for sqlsim Studio, focused on error handling and rejection paths.

.DESCRIPTION
    smoke-test.ps1 proves the happy path works. This suite proves Studio fails
    correctly: that bad input is rejected with a specific reason, that security
    boundaries hold, and that a failed workload reports why.

    Tests are grouped so a failure tells you which contract broke:

      1. Startup and argument handling
      2. Authentication boundary
      3. Request validation - connection
      4. Request validation - workload shape
      5. Request validation - engine capability
      6. Request validation - execution options
      7. Payload limits
      8. App settings
      9. Connection failure reporting
     10. Workload failure reporting
     11. Concurrency and lifecycle

    Sections 1 through 8 need no SQL Server. Sections 9 through 11 use the
    target given by -Server and -Database.

.PARAMETER Server
    SQL Server target for failure-reporting tests. Defaults to localhost.

.PARAMETER Database
    Database for failure-reporting tests. Defaults to tempdb.

.PARAMETER StudioExecutable
    Path to a packaged sqlsimstudio executable. Without it, the suite builds and
    runs the project DLL.

.PARAMETER SkipBuild
    Reuse the existing build.

.PARAMETER OfflineOnly
    Run only the sections that need no SQL Server.

.PARAMETER StopOnError
    Stop at the first failure instead of continuing.

.EXAMPLE
    .\full-test-suite.ps1

.EXAMPLE
    .\full-test-suite.ps1 -StudioExecutable .\build\win-x64\sqlsimstudio.exe -SkipBuild

.EXAMPLE
    .\full-test-suite.ps1 -OfflineOnly
#>

param(
    [string]$Server = 'localhost',
    [string]$Database = 'tempdb',
    [string]$StudioExecutable,
    [switch]$SkipBuild,
    [switch]$OfflineOnly,
    [switch]$StopOnError
)

$ErrorActionPreference = 'Stop'
$studioRoot = $PSScriptRoot
$projectPath = Join-Path $studioRoot 'server\SqlsimStudio.csproj'
$dllPath = Join-Path $studioRoot 'server\bin\Release\net10.0\sqlsimstudio.dll'
$bootstrapFile = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-full-{0}.txt" -f [guid]::NewGuid().ToString('N'))
# Every Studio this suite starts saves preferences here, never in the user's profile.
$settingsDirectory = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-full-settings-{0}" -f [guid]::NewGuid().ToString('N'))

# Mirrors RuntimeLocator: a packaged Studio finds sqlsim beside it or, in the
# sqlsimtools bundle, in ..\sqlsim\x64; the source build finds the repository's
# sqlsim build. CI builds only Studio, so there the honest answer from
# /api/engines is that sqlsim was not found.
$sqlsimCandidates = if ($StudioExecutable) {
    $studioDirectory = Split-Path -Parent (Resolve-Path $StudioExecutable).Path
    @((Join-Path $studioDirectory 'sqlsim\sqlsim.exe'), (Join-Path $studioDirectory '..\sqlsim\x64\sqlsim.exe'))
} else {
    @(Join-Path $studioRoot '..\sqlsim\build\x64\Release\sqlsim.exe')
}
$sqlsimExpected = [bool]$env:SQLSIM_STUDIO_SQLSIM_PATH -or [bool]($sqlsimCandidates | Where-Object { Test-Path -LiteralPath $_ })

$script:testsPassed = 0
$script:testsFailed = 0
$script:testsSkipped = 0
$script:failures = [System.Collections.Generic.List[string]]::new()
$startTime = Get-Date

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Test-Case {
    param(
        [string]$Name,
        [scriptblock]$Check,
        # The check starts a real run, which can only complete against a live SQL Server.
        [switch]$RequiresServer
    )

    if ($RequiresServer -and $OfflineOnly) {
        Write-Host "  skip    $Name (needs a live SQL Server)" -ForegroundColor DarkGray
        $script:testsSkipped++
        return
    }

    try {
        $result = & $Check
        if ($result -is [string] -and $result) {
            Write-Host "  FAILED  $Name" -ForegroundColor Red
            Write-Host "          $result" -ForegroundColor DarkGray
            $script:testsFailed++
            $script:failures.Add("$Name - $result")
            if ($StopOnError) { throw "Stopping: $Name" }
        } else {
            Write-Host "  ok      $Name" -ForegroundColor Green
            $script:testsPassed++
        }
    } catch {
        if ($StopOnError -and $_.Exception.Message -like 'Stopping:*') { throw }
        Write-Host "  FAILED  $Name" -ForegroundColor Red
        Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkGray
        $script:testsFailed++
        $script:failures.Add("$Name - $($_.Exception.Message)")
        if ($StopOnError) { throw "Stopping: $Name" }
    }
}

if (-not $SkipBuild -and -not $StudioExecutable) {
    & dotnet build $projectPath -c Release | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Studio build failed.' }
}

# ---------------------------------------------------------------------------
# 1. Startup and argument handling
# ---------------------------------------------------------------------------

Write-Section '1. Startup and argument handling'

function Invoke-Studio {
    param([string[]]$Arguments)

    $info = [Diagnostics.ProcessStartInfo]::new()
    if ($StudioExecutable) {
        $info.FileName = (Resolve-Path $StudioExecutable).Path
    } else {
        $info.FileName = (Get-Command dotnet).Source
        $null = $info.ArgumentList.Add($dllPath)
    }
    foreach ($argument in $Arguments) { $null = $info.ArgumentList.Add($argument) }
    $info.Environment['SQLSIMSTUDIO_SETTINGS_DIR'] = $settingsDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $proc = [Diagnostics.Process]::Start($info)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(15000) | Out-Null
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

# Start a Studio that stays up, for the lifecycle tests below. Every one of
# them needs the same launch, and repeating it obscured what each was actually
# checking.
function Start-StudioProcess {
    param([string]$BootstrapFile, [string[]]$ExtraArguments = @(), [hashtable]$Environment = @{})

    $info = [Diagnostics.ProcessStartInfo]::new()
    if ($StudioExecutable) {
        $info.FileName = (Resolve-Path $StudioExecutable).Path
    } else {
        $info.FileName = (Get-Command dotnet).Source
        $null = $info.ArgumentList.Add($dllPath)
    }
    foreach ($argument in @('--no-open', '--bootstrap-file', $BootstrapFile) + $ExtraArguments) {
        $null = $info.ArgumentList.Add($argument)
    }
    $info.Environment['SQLSIMSTUDIO_SETTINGS_DIR'] = $settingsDirectory
    foreach ($name in $Environment.Keys) { $info.Environment[$name] = $Environment[$name] }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    return [Diagnostics.Process]::Start($info)
}

function Wait-ForBootstrap {
    param([string]$Path, [int]$TimeoutSeconds = 15)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path $Path) {
            $url = (Get-Content $Path -Raw).Trim()
            if ($url) { return $url }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

Test-Case '--help exits 0 and lists every documented option' {
    $r = Invoke-Studio @('--help')
    if ($r.ExitCode -ne 0) { return "expected exit 0, got $($r.ExitCode)" }
    foreach ($option in @('--no-open', '--bootstrap-file', '--port')) {
        if ($r.Stdout -notmatch [regex]::Escape($option)) { return "help omits $option" }
    }
    # Studio has no window and no usable Ctrl+C, so the help has to say how to
    # stop it. A user who cannot find the exit reaches for Task Manager and
    # orphans the workload.
    if ($r.Stdout -notmatch 'Shut down') { return 'help does not say how to stop Studio' }
    if ($r.Stdout -notmatch 'cleanup') { return 'help does not mention the cleanup script' }
    return $null
}

Test-Case '--idle-timeout is no longer accepted' {
    # The watchdog is gone. Silently ignoring the old option would leave a
    # script looking like it still controls a timeout that no longer exists.
    $r = Invoke-Studio @('--idle-timeout', '300', '--no-open', '--bootstrap-file', $bootstrapFile)
    if ($r.ExitCode -eq 0) { return 'a removed option was accepted' }
    return $null
}

Test-Case 'the packaged executable does not allocate a console window' {
    if (-not $StudioExecutable) { return $null }
    if (-not $IsWindows) { return $null }
    # Subsystem 2 is WINDOWS_GUI, 3 is WINDOWS_CUI. A console subsystem binary
    # makes Windows open a console window on every launch, and closing that
    # window kills Studio.
    $path = (Resolve-Path $StudioExecutable).Path
    $bytes = [IO.File]::ReadAllBytes($path)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $subsystem = [BitConverter]::ToUInt16($bytes, $peOffset + 0x5C)
    if ($subsystem -ne 2) { return "expected PE subsystem 2 (GUI), got $subsystem" }
    return $null
}

Test-Case 'Shut down stops Studio and removes its session file' {
    $shutdownBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-shutdown-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $proc = Start-StudioProcess -BootstrapFile $shutdownBootstrap
    try {
        $bootstrapUrl = Wait-ForBootstrap -Path $shutdownBootstrap
        if (-not $bootstrapUrl) { return 'Studio never published a bootstrap URL' }

        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri $bootstrapUrl -WebSession $session -MaximumRedirection 5 | Out-Null
        $baseUrl = ([uri]$bootstrapUrl).GetLeftPart([UriPartial]::Authority)

        $response = Invoke-WebRequest -Uri "$baseUrl/api/session/shutdown" -Method Post `
            -WebSession $session -Headers @{ Origin = $baseUrl } -SkipHttpErrorCheck
        if ($response.StatusCode -ne 200) {
            return "shutdown returned $($response.StatusCode)"
        }

        if (-not $proc.WaitForExit(30000)) { return 'Studio did not exit after Shut down' }
        if ($proc.ExitCode -ne 0) { return "expected a graceful exit 0, got $($proc.ExitCode)" }
        if (Test-Path $shutdownBootstrap) {
            return 'the session file survived shutdown, so it still points at a Studio that is gone'
        }
        return $null
    } finally {
        if (-not $proc.HasExited) { $proc.Kill($true) }
        Remove-Item $shutdownBootstrap -ErrorAction SilentlyContinue
    }
}

Test-Case 'Shut down requires a session like any other state-changing request' {
    $guardBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-guard-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $proc = Start-StudioProcess -BootstrapFile $guardBootstrap
    try {
        $bootstrapUrl = Wait-ForBootstrap -Path $guardBootstrap
        if (-not $bootstrapUrl) { return 'Studio never published a bootstrap URL' }
        $baseUrl = ([uri]$bootstrapUrl).GetLeftPart([UriPartial]::Authority)

        # No cookie. Anything on the machine could otherwise stop a running
        # workload by posting to a known path on a known port.
        $response = Invoke-WebRequest -Uri "$baseUrl/api/session/shutdown" -Method Post `
            -Headers @{ Origin = $baseUrl } -SkipHttpErrorCheck
        if ($response.StatusCode -ne 404) {
            return "an unauthenticated shutdown returned $($response.StatusCode), expected 404"
        }
        Start-Sleep -Seconds 2
        if ($proc.HasExited) { return 'an unauthenticated request stopped Studio' }
        return $null
    } finally {
        if (-not $proc.HasExited) { $proc.Kill($true) }
        Remove-Item $guardBootstrap -ErrorAction SilentlyContinue
    }
}

Test-Case 'the session file is refilled so the interface can be reopened' {
    # Studio no longer stops when the browser goes away, so a closed tab must
    # not strand it. Each bootstrap token opens one session and is immediately
    # replaced, which keeps single use while leaving a way back in.
    $reconnectBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-reconnect-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $proc = Start-StudioProcess -BootstrapFile $reconnectBootstrap
    try {
        $firstUrl = Wait-ForBootstrap -Path $reconnectBootstrap
        if (-not $firstUrl) { return 'Studio never published a bootstrap URL' }
        $baseUrl = ([uri]$firstUrl).GetLeftPart([UriPartial]::Authority)

        $first = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri $firstUrl -WebSession $first -MaximumRedirection 5 | Out-Null

        $secondUrl = (Get-Content $reconnectBootstrap -Raw).Trim()
        if ($secondUrl -eq $firstUrl) { return 'the session file still holds the token that was just spent' }

        $replay = Invoke-WebRequest -Uri $firstUrl -SkipHttpErrorCheck -MaximumRedirection 0
        if ($replay.StatusCode -ne 404) {
            return "the spent token returned $($replay.StatusCode), expected 404"
        }

        # A completely separate browser, as if the first had been closed.
        $second = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri $secondUrl -WebSession $second -MaximumRedirection 5 | Out-Null
        $health = Invoke-WebRequest -Uri "$baseUrl/api/health" -WebSession $second -SkipHttpErrorCheck
        if ($health.StatusCode -ne 200) {
            return "the reopened session did not work: /api/health returned $($health.StatusCode)"
        }
        return $null
    } finally {
        if (-not $proc.HasExited) { $proc.Kill($true) }
        Remove-Item $reconnectBootstrap -ErrorAction SilentlyContinue
    }
}

Test-Case 'a missing Python is reported for sqlpysim' {
    $pythonBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-python-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $missingPython = Join-Path ([IO.Path]::GetTempPath()) ("missing-python-{0}.exe" -f [guid]::NewGuid().ToString('N'))
    $proc = Start-StudioProcess -BootstrapFile $pythonBootstrap -Environment @{ SQLSIM_STUDIO_PYTHON_PATH = $missingPython }
    try {
        $url = Wait-ForBootstrap -Path $pythonBootstrap
        if (-not $url) { return 'Studio never published a bootstrap URL' }
        $baseUrl = ([uri]$url).GetLeftPart([UriPartial]::Authority)
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri $url -WebSession $session -MaximumRedirection 5 | Out-Null
        $engines = Invoke-RestMethod -Uri "$baseUrl/api/engines" -WebSession $session
        if ($engines.sqlpysim.problem -ne 'Python not found') {
            return "expected 'Python not found', got '$($engines.sqlpysim.problem)'"
        }
        if ($sqlsimExpected -and -not $engines.sqlsim.version) { return 'the sqlsim version was lost when Python was missing' }
        if (-not $sqlsimExpected -and $engines.sqlsim.problem -ne 'not found') { return "expected sqlsim 'not found', got '$($engines.sqlsim.problem)'" }
        return $null
    } finally {
        if (-not $proc.HasExited) { $proc.Kill($true) }
        Remove-Item $pythonBootstrap -ErrorAction SilentlyContinue
    }
}

Test-Case 'Studio keeps running when the browser goes silent' {
    # The behaviour the watchdog used to get wrong. A browser that stops
    # reporting is indistinguishable from a backgrounded tab, a frozen tab, or
    # a sleeping machine, so Studio no longer tries to tell them apart.
    $silentBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-silent-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $proc = Start-StudioProcess -BootstrapFile $silentBootstrap
    try {
        $bootstrapUrl = Wait-ForBootstrap -Path $silentBootstrap
        if (-not $bootstrapUrl) { return 'Studio never published a bootstrap URL' }

        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri $bootstrapUrl -WebSession $session -MaximumRedirection 5 | Out-Null

        # Connect, then say nothing at all.
        if ($proc.WaitForExit(20000)) {
            return 'Studio stopped itself after the browser went quiet'
        }
        $baseUrl = ([uri]$bootstrapUrl).GetLeftPart([UriPartial]::Authority)
        $health = Invoke-WebRequest -Uri "$baseUrl/api/health" -WebSession $session -SkipHttpErrorCheck
        if ($health.StatusCode -ne 200) {
            return "Studio was still running but not serving: /api/health returned $($health.StatusCode)"
        }
        return $null
    } finally {
        if (-not $proc.HasExited) { $proc.Kill($true) }
        Remove-Item $silentBootstrap -ErrorAction SilentlyContinue
    }
}

Test-Case 'Studio survives the machine sleeping' {
    # The closest a test can get to closing a laptop lid: suspend every thread
    # so no time passes for the process while the clock keeps running. This is
    # the failure that started the redesign, and it must stay fixed.
    if (-not ('Native.ProcessControl' -as [type])) {
        Add-Type -Namespace Native -Name ProcessControl -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtSuspendProcess(System.IntPtr processHandle);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtResumeProcess(System.IntPtr processHandle);
'@
    }

    $sleepBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-sleep-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $proc = Start-StudioProcess -BootstrapFile $sleepBootstrap
    try {
        $bootstrapUrl = Wait-ForBootstrap -Path $sleepBootstrap
        if (-not $bootstrapUrl) { return 'Studio never published a bootstrap URL' }

        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri $bootstrapUrl -WebSession $session -MaximumRedirection 5 | Out-Null

        $null = [Native.ProcessControl]::NtSuspendProcess($proc.Handle)
        Start-Sleep -Seconds 15
        $null = [Native.ProcessControl]::NtResumeProcess($proc.Handle)
        Start-Sleep -Seconds 3

        if ($proc.HasExited) { return 'Studio exited while the machine was asleep' }
        $baseUrl = ([uri]$bootstrapUrl).GetLeftPart([UriPartial]::Authority)
        $health = Invoke-WebRequest -Uri "$baseUrl/api/health" -WebSession $session -SkipHttpErrorCheck
        if ($health.StatusCode -ne 200) {
            return "the interface did not work after waking: /api/health returned $($health.StatusCode)"
        }
        return $null
    } finally {
        if (-not $proc.HasExited) { $proc.Kill($true) }
        Remove-Item $sleepBootstrap -ErrorAction SilentlyContinue
    }
}

Test-Case '--no-open without --bootstrap-file is rejected with exit 2' {
    $r = Invoke-Studio @('--no-open')
    if ($r.ExitCode -ne 2) { return "expected exit 2, got $($r.ExitCode)" }
    if ($r.Stderr -notmatch 'requires --bootstrap-file') { return "stderr lacked the reason: $($r.Stderr)" }
    return $null
}

Test-Case 'argument errors do not print a stack trace' {
    $r = Invoke-Studio @('--no-open')
    if ($r.Stderr -match 'Unhandled exception|at StudioOptions|System\.ArgumentException') {
        return 'raw exception leaked to stderr'
    }
    return $null
}

Test-Case '--port rejects a non-numeric value rather than binding a random port' {
    $r = Invoke-Studio @('--port', 'not-a-port', '--no-open', '--bootstrap-file', $bootstrapFile)
    if ($r.ExitCode -eq 0) { return 'a non-numeric port was accepted' }
    return $null
}

# ---------------------------------------------------------------------------
# Start a Studio instance for the request-level sections
# ---------------------------------------------------------------------------

$startInfo = [Diagnostics.ProcessStartInfo]::new()
if ($StudioExecutable) {
    $startInfo.FileName = (Resolve-Path $StudioExecutable).Path
} else {
    $startInfo.FileName = (Get-Command dotnet).Source
    $null = $startInfo.ArgumentList.Add($dllPath)
}
$null = $startInfo.ArgumentList.Add('--no-open')
$null = $startInfo.ArgumentList.Add('--bootstrap-file')
$null = $startInfo.ArgumentList.Add($bootstrapFile)
$startInfo.Environment['SQLSIMSTUDIO_SETTINGS_DIR'] = $settingsDirectory
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($startInfo)

try {
    $baseUrl = $null
    $bootstrapReady = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline -and (-not $baseUrl -or -not $bootstrapReady)) {
        $readTask = $process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait(2000)) {
            if ($process.HasExited) { throw "Studio exited before startup: $($process.StandardError.ReadToEnd())" }
            continue
        }
        $line = $readTask.Result
        if ($line -like 'SQLSIM_STUDIO_URL=*') { $baseUrl = $line.Substring('SQLSIM_STUDIO_URL='.Length) }
        elseif ($line -eq 'SQLSIM_STUDIO_BOOTSTRAP_READY=1') { $bootstrapReady = $true }
    }
    if (-not $baseUrl -or -not $bootstrapReady) { throw 'Studio did not publish startup URLs within 20 seconds.' }

    $bootstrapUrl = (Get-Content -LiteralPath $bootstrapFile -Raw).Trim()
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)

    $bootstrapResponse = $client.GetAsync($bootstrapUrl).GetAwaiter().GetResult()
    $cookie = ($bootstrapResponse.Headers.GetValues('Set-Cookie') -split ';')[0]

    function Invoke-StudioApi {
        param(
            [string]$Method = 'POST',
            [string]$Path = '/api/runs',
            [hashtable]$Payload,
            [switch]$NoCookie,
            [switch]$NoOrigin,
            [string]$HostHeader
        )

        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "$baseUrl$Path")
        if (-not $NoCookie) { $request.Headers.Add('Cookie', $cookie) }
        if (-not $NoOrigin -and $Method -ne 'GET') { $request.Headers.Add('Origin', $baseUrl) }
        if ($HostHeader) { $request.Headers.Host = $HostHeader }
        if ($Payload) {
            $request.Content = [Net.Http.StringContent]::new(
                ($Payload | ConvertTo-Json -Depth 8), [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.Send($request)
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = $null
        if ($body) { try { $parsed = $body | ConvertFrom-Json } catch { $parsed = $null } }
        return [pscustomobject]@{ Status = $response.StatusCode; Body = $body; Json = $parsed }
    }

    function New-RunPayload {
        param([hashtable]$Overrides = @{})

        $payload = @{
            engine = 'sqlsim'; mode = 'query'; server = $Server; database = $Database
            authentication = 'integrated'; username = $null; secret = $null
            query = 'SELECT 1'; inputFileName = $null; inputContent = $null
            replayMode = $null; workloadGroups = $null
            threads = 1; iterations = 1; quiet = $true
            trustServerCertificate = $true; stopOnError = $true
            telemetry = 'final'; statisticsSource = 'none'
        }
        foreach ($key in $Overrides.Keys) { $payload[$key] = $Overrides[$key] }
        return $payload
    }

    function Assert-Rejected {
        param([hashtable]$Payload, [string]$ExpectedError)

        $response = Invoke-StudioApi -Payload $Payload
        if ($response.Status -ne [Net.HttpStatusCode]::BadRequest) {
            return "expected 400, got $($response.Status)"
        }
        if (-not $response.Json.error) { return 'rejection carried no error message' }
        if ($ExpectedError -and $response.Json.error -notmatch $ExpectedError) {
            return "expected error matching '$ExpectedError', got '$($response.Json.error)'"
        }
        return $null
    }

    # -----------------------------------------------------------------------
    # 2. Authentication boundary
    # -----------------------------------------------------------------------

    Write-Section '2. Authentication boundary'

    Test-Case 'unauthenticated API returns 404 rather than 401' {
        $r = Invoke-StudioApi -Method 'GET' -Path '/api/health' -NoCookie
        if ($r.Status -ne [Net.HttpStatusCode]::NotFound) { return "expected 404, got $($r.Status)" }
        return $null
    }

    Test-Case 'unauthenticated static asset returns 404' {
        $r = Invoke-StudioApi -Method 'GET' -Path '/app.js' -NoCookie
        if ($r.Status -ne [Net.HttpStatusCode]::NotFound) { return "expected 404, got $($r.Status)" }
        return $null
    }

    Test-Case 'bootstrap token cannot be replayed' {
        $replay = $client.GetAsync($bootstrapUrl).GetAwaiter().GetResult()
        if ($replay.StatusCode -ne [Net.HttpStatusCode]::NotFound) {
            return "expected 404 on replay, got $($replay.StatusCode)"
        }
        return $null
    }

    Test-Case 'hostile Host header is refused' {
        $r = Invoke-StudioApi -Method 'GET' -Path '/api/health' -HostHeader 'evil.example.test'
        if ($r.Status -ne [Net.HttpStatusCode]::NotFound) { return "expected 404, got $($r.Status)" }
        return $null
    }

    Test-Case 'unsafe method without matching Origin is refused' {
        $r = Invoke-StudioApi -Method 'POST' -Path '/api/health' -NoOrigin
        if ($r.Status -ne [Net.HttpStatusCode]::Forbidden) { return "expected 403, got $($r.Status)" }
        return $null
    }

    Test-Case 'a run request without a session is refused' {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/runs")
        $request.Headers.Add('Origin', $baseUrl)
        $request.Content = [Net.Http.StringContent]::new(
            ((New-RunPayload) | ConvertTo-Json -Depth 8), [Text.Encoding]::UTF8, 'application/json')
        $response = $client.Send($request)
        if ($response.StatusCode -eq [Net.HttpStatusCode]::Accepted) { return 'an unauthenticated run was accepted' }
        return $null
    }

    # -----------------------------------------------------------------------
    # 3. Request validation - connection
    # -----------------------------------------------------------------------

    Write-Section '3. Request validation - connection'

    Test-Case 'empty server is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ server = '' }) -ExpectedError 'Server is required'
    }

    Test-Case 'server containing a connection-string separator is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ server = 'host;Trusted_Connection=yes' }) -ExpectedError 'invalid connection-string characters'
    }

    Test-Case 'server containing brace injection is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ server = 'host{0}' }) -ExpectedError 'invalid connection-string characters'
    }

    Test-Case 'empty database is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ database = '' }) -ExpectedError 'Database is required'
    }

    Test-Case 'database containing a connection-string separator is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ database = 'db;Encrypt=no' }) -ExpectedError 'invalid connection-string characters'
    }

    Test-Case 'oversized server name is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ server = ('s' * 254) }) -ExpectedError '253 characters'
    }

    Test-Case 'oversized database name is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ database = ('d' * 129) }) -ExpectedError '128 characters'
    }

    Test-Case 'unknown authentication mode is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'kerberos-lite' }) -ExpectedError 'Unsupported authentication mode'
    }

    Test-Case 'SQL authentication without a username is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'sql'; username = ''; secret = 'x' }) -ExpectedError 'requires a username'
    }

    Test-Case 'SQL authentication without a secret is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'sql'; username = 'sa'; secret = $null }) -ExpectedError 'requires a secret'
    }

    Test-Case 'token authentication without a token is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'token'; secret = $null }) -ExpectedError 'requires a secret'
    }

    Test-Case 'service principal without a client ID is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'service-principal'; username = ''; secret = 'x' }) -ExpectedError 'requires a client ID'
    }

    Test-Case 'service principal without a secret is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'service-principal'; username = 'client-id'; secret = $null }) -ExpectedError 'requires a secret'
    }

    Test-Case 'managed identity with a secret is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'managed'; secret = 'not-allowed' }) -ExpectedError 'does not accept a password or token'
    }

    Test-Case 'integrated authentication with a secret is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'integrated'; secret = 'not-allowed' }) -ExpectedError 'does not accept a password or token'
    }

    Test-Case 'Entra interactive with a username is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'interactive'; username = 'me@example.test' }) -ExpectedError 'does not accept a username'
    }

    Test-Case 'oversized credential is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ authentication = 'token'; secret = ('t' * 10001) }) -ExpectedError 'maximum supported length'
    }

    Test-Case 'application name containing a connection-string separator is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ applicationName = "app;Encrypt=no" }) -ExpectedError "cannot contain"
    }

    Test-Case 'unknown encryption level is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ encryption = 'sometimes' }) -ExpectedError 'Unknown encryption level'
    }

    Test-Case 'out-of-range login timeout is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ loginTimeoutSeconds = 86401 }) -ExpectedError 'Login timeout'
    }

    Test-Case 'out-of-range retry count is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ retryCount = 256 }) -ExpectedError 'Retry count'
    }

    # -----------------------------------------------------------------------
    # 4. Request validation - workload shape
    # -----------------------------------------------------------------------

    Write-Section '4. Request validation - workload shape'

    Test-Case 'unknown mode is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'benchmark' }) -ExpectedError 'Mode must be'
    }

    Test-Case 'query mode without a query is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ query = '' }) -ExpectedError 'Query is required'
    }

    Test-Case 'zero connections is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ threads = 0 }) -ExpectedError 'Connections must be'
    }

    Test-Case 'negative connections is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ threads = -5 }) -ExpectedError 'Connections must be'
    }

    Test-Case 'connections above the ceiling is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ threads = 10001 }) -ExpectedError 'Connections must be'
    }

    Test-Case 'zero iterations is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ iterations = 0 }) -ExpectedError 'Iterations must be'
    }

    Test-Case 'file mode without content is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'file'; query = $null; inputFileName = 'x.sql'; inputContent = '' }) -ExpectedError 'SQL file content is required'
    }

    Test-Case 'file mode with a non-.sql extension is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'file'; query = $null; inputFileName = 'script.txt'; inputContent = 'SELECT 1' }) -ExpectedError '\.sql extension'
    }

    Test-Case 'replay mode with an unknown replay type is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'replay'; query = $null; replayMode = 'turbo'; inputFileName = 'c.xml'; inputContent = '<events/>' }) -ExpectedError 'Replay mode must be'
    }

    Test-Case 'replay mode with a non-.xml extension is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'replay'; query = $null; replayMode = 'fast'; inputFileName = 'capture.txt'; inputContent = '<events/>' }) -ExpectedError '\.xml extension'
    }

    Test-Case 'workload mode with no groups is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'workload'; query = $null; workloadGroups = @() }) -ExpectedError 'between 1 and 20 groups'
    }

    Test-Case 'workload mode with more than 20 groups is rejected' {
        $groups = 1..21 | ForEach-Object { @{ fileName = "g$_.sql"; content = 'SELECT 1'; threads = 1; iterations = 1; thinkTimeMs = 0 } }
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'workload'; query = $null; workloadGroups = $groups }) -ExpectedError 'between 1 and 20 groups'
    }

    Test-Case 'workload group with empty content is rejected' {
        $groups = @(@{ fileName = 'g.sql'; content = ''; threads = 1; iterations = 1; thinkTimeMs = 0 })
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'workload'; query = $null; workloadGroups = $groups }) -ExpectedError 'requires SQL content'
    }

    Test-Case 'workload group with a non-.sql file is rejected' {
        $groups = @(@{ fileName = 'g.txt'; content = 'SELECT 1'; threads = 1; iterations = 1; thinkTimeMs = 0 })
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'workload'; query = $null; workloadGroups = $groups }) -ExpectedError '\.sql file'
    }

    Test-Case 'workload group with out-of-range think time is rejected' {
        $groups = @(@{ fileName = 'g.sql'; content = 'SELECT 1'; threads = 1; iterations = 1; thinkTimeMs = 86400001 })
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'workload'; query = $null; workloadGroups = $groups }) -ExpectedError 'think time'
    }

    Test-Case 'workload group with zero connections is rejected' {
        $groups = @(@{ fileName = 'g.sql'; content = 'SELECT 1'; threads = 0; iterations = 1; thinkTimeMs = 0 })
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'workload'; query = $null; workloadGroups = $groups }) -ExpectedError 'group connections'
    }

    # -----------------------------------------------------------------------
    # 5. Request validation - engine capability
    # -----------------------------------------------------------------------

    Write-Section '5. Request validation - engine capability'

    Test-Case 'unknown engine is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ engine = 'sqlgosim' }) -ExpectedError 'Engine must be'
    }

    Test-Case 'sqlpysim with mixed workload is accepted' {
        # sqlpysim gained -workload, so Studio no longer refuses the mode.
        # This proves only that validation accepts it; the run itself is
        # covered by the smoke suite.
        $groups = @(@{ fileName = 'g.sql'; content = 'SELECT 1'; threads = 1; iterations = 1; thinkTimeMs = 0 })
        $response = Invoke-StudioApi -Payload (New-RunPayload @{
            engine = 'sqlpysim'; mode = 'workload'; query = $null; workloadGroups = $groups })
        if ($response.Status -eq [Net.HttpStatusCode]::BadRequest) {
            return "mixed workload was rejected for sqlpysim: $($response.Json.error)"
        }
        # Leave nothing running: a live run would refuse the next request.
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 200
            $state = (Invoke-StudioApi -Method GET -Path '/api/runs/current').Json.state
        } while ($state -notin 'completed', 'failed', 'stopped' -and [DateTime]::UtcNow -lt $deadline)
        return $null
    }

    Test-Case 'sqlpysim with replay is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ engine = 'sqlpysim'; mode = 'replay'; query = $null; replayMode = 'fast'; inputFileName = 'c.xml'; inputContent = '<events/>' }) -ExpectedError 'supported only by sqlsim'
    }

    Test-Case 'sqlpysim with live telemetry is accepted' -RequiresServer {
        # sqlpysim gained -stream-json, so Studio no longer refuses live
        # telemetry. Accepting the request is not enough on its own: a run
        # that produced no events would still report progress of nothing, so
        # this waits for the run to end and then checks Studio actually
        # recorded throughput from the stream.
        $response = Invoke-StudioApi -Payload (New-RunPayload @{
            engine = 'sqlpysim'; telemetry = 'live'; query = 'SELECT 1 AS StudioLiveProbe'
            threads = 2; iterations = 25 })
        if ($response.Status -eq [Net.HttpStatusCode]::BadRequest) {
            return "live telemetry was rejected for sqlpysim: $($response.Json.error)"
        }

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 200
            $current = (Invoke-StudioApi -Method GET -Path '/api/runs/current').Json
        } while ($current.state -notin 'completed', 'failed', 'stopped' -and [DateTime]::UtcNow -lt $deadline)

        if ($current.state -ne 'completed') {
            return "expected the live run to complete, got '$($current.state)'"
        }
        if ($null -eq $current.progress) {
            return 'the live run recorded no progress from the stream'
        }
        if ([int]$current.progress.successful_executions -ne 50) {
            return "expected 50 executions from the stream, got $($current.progress.successful_executions)"
        }
        return $null
    }

    Test-Case 'sqlpysim with runtime query statistics is accepted' -RequiresServer {
        # sqlpysim gained -querystats-interval and -querystats-file, so Studio
        # no longer refuses runtime statistics. A live run must actually
        # produce the snapshot Studio reads, not merely be allowed to start.
        $response = Invoke-StudioApi -Payload (New-RunPayload @{
            engine = 'sqlpysim'; telemetry = 'live'; statisticsSource = 'runtime'
            query = 'SELECT TOP 20 name FROM sys.objects'; threads = 2; iterations = 20 })
        if ($response.Status -eq [Net.HttpStatusCode]::BadRequest) {
            return "runtime statistics were rejected for sqlpysim: $($response.Json.error)"
        }

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 200
            $current = (Invoke-StudioApi -Method GET -Path '/api/runs/current').Json
        } while ($current.state -notin 'completed', 'failed', 'stopped' -and [DateTime]::UtcNow -lt $deadline)

        if ($current.state -ne 'completed') {
            return "expected the run to complete, got '$($current.state)'"
        }
        if ($null -eq $current.liveQueryStats) {
            return 'the run produced no query-statistics snapshot'
        }
        if ([int]$current.liveQueryStats.query_stats.totals.executions -ne 40) {
            return "expected 40 executions in the snapshot, got $($current.liveQueryStats.query_stats.totals.executions)"
        }
        return $null
    }

    Test-Case 'sqlpysim runs with connection pooling' -RequiresServer {
        $response = Invoke-StudioApi -Payload (New-RunPayload @{
            engine = 'sqlpysim'; reconnect = $true; connectionPooling = $true; iterations = 2 })
        if ($response.Status -eq [Net.HttpStatusCode]::BadRequest) {
            return "connection pooling was rejected for sqlpysim: $($response.Json.error)"
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 200
            $run = (Invoke-StudioApi -Method GET -Path '/api/runs/current').Json
        } while ($run.state -notin 'completed', 'failed', 'stopped' -and [DateTime]::UtcNow -lt $deadline)
        if ($run.state -ne 'completed') { return "expected the run to complete, got '$($run.state)'" }
        return $null
    }

    Test-Case 'sqlpysim with service principal is accepted' {
        $response = Invoke-StudioApi -Payload (New-RunPayload @{
            engine = 'sqlpysim'; authentication = 'service-principal';
            username = 'client-id'; secret = 'not-a-real-secret' })
        if ($response.Status -eq [Net.HttpStatusCode]::BadRequest) {
            return "service principal was rejected for sqlpysim: $($response.Json.error)"
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 200
            $run = (Invoke-StudioApi -Method GET -Path '/api/runs/current').Json
        } while ($run.state -notin 'completed', 'failed', 'stopped' -and [DateTime]::UtcNow -lt $deadline)
        if ($run.state -notin 'completed', 'failed') {
            return "expected the authentication attempt to finish, got '$($run.state)'"
        }
        return $null
    }

    Test-Case 'an application name does not reach sqlpysim' -RequiresServer {
        # The driver reserves the application name, so sqlpysim refuses -app.
        # Studio's field always holds a value, so forwarding it would fail
        # every Python run. The request must succeed with the name dropped,
        # rather than be rejected or passed through.
        $response = Invoke-StudioApi -Payload (New-RunPayload @{
            engine = 'sqlpysim'; applicationName = 'StudioAppNameProbe' })
        if ($response.Status -eq [Net.HttpStatusCode]::BadRequest) {
            return "an application name was rejected for sqlpysim: $($response.Json.error)"
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 200
            $run = (Invoke-StudioApi -Method GET -Path '/api/runs/current').Json
        } while ($run.state -notin 'completed', 'failed', 'stopped' -and [DateTime]::UtcNow -lt $deadline)
        if ($run.state -ne 'completed') { return "expected the run to complete, got '$($run.state)'" }
        $logText = ($run.logs.message -join ' ') + ' ' + $run.consoleOutput
        if ($logText -match 'StudioAppNameProbe') { return 'the application name was forwarded to sqlpysim' }
        return $null
    }

    # -----------------------------------------------------------------------
    # 6. Request validation - execution options
    # -----------------------------------------------------------------------

    Write-Section '6. Request validation - execution options'

    Test-Case 'unknown telemetry mode is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ telemetry = 'firehose' }) -ExpectedError 'Telemetry must be'
    }

    Test-Case 'unknown statistics source is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ statisticsSource = 'extended-events' }) -ExpectedError 'Unknown statistics source'
    }

    Test-Case 'connection pooling without reconnect is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ connectionPooling = $true; reconnect = $false }) -ExpectedError 'requires reconnect'
    }

    Test-Case 'out-of-range query timeout is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ queryTimeoutSeconds = 86401 }) -ExpectedError 'Query timeout'
    }

    Test-Case 'certificate hostname containing a separator is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ certificateHostname = "host;x=1" }) -ExpectedError "cannot contain"
    }

    # -----------------------------------------------------------------------
    # 7. Payload limits (offline)
    # -----------------------------------------------------------------------

    Write-Section '7. Payload limits'

    Test-Case 'SQL file content above 1 MB is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'file'; query = $null; inputFileName = 'big.sql'; inputContent = ('x' * 1000001) }) -ExpectedError '1 MB or smaller'
    }

    Test-Case 'query above 1 MB is rejected' {
        Assert-Rejected -Payload (New-RunPayload @{ query = ('x' * 1000001) }) -ExpectedError '1 MB or smaller'
    }

    Test-Case 'combined workload content above 10 MB is rejected' {
        $groups = 1..11 | ForEach-Object { @{ fileName = "g$_.sql"; content = ('x' * 999000); threads = 1; iterations = 1; thinkTimeMs = 0 } }
        Assert-Rejected -Payload (New-RunPayload @{ mode = 'workload'; query = $null; workloadGroups = $groups }) -ExpectedError '10 MB or smaller'
    }

    Test-Case 'malformed JSON body is refused without crashing Studio' {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/runs")
        $request.Headers.Add('Cookie', $cookie)
        $request.Headers.Add('Origin', $baseUrl)
        $request.Content = [Net.Http.StringContent]::new('{ this is not json', [Text.Encoding]::UTF8, 'application/json')
        $response = $client.Send($request)
        if ($response.StatusCode -eq [Net.HttpStatusCode]::Accepted) { return 'malformed JSON was accepted' }
        $health = Invoke-StudioApi -Method 'GET' -Path '/api/health'
        if ($health.Status -ne [Net.HttpStatusCode]::OK) { return 'Studio stopped responding after malformed JSON' }
        return $null
    }

    Test-Case 'engine versions are reported for packaged engines' {
        $r = Invoke-StudioApi -Method 'GET' -Path '/api/engines'
        if ($r.Status -ne [Net.HttpStatusCode]::OK) { return "expected 200, got $($r.Status)" }
        if ($sqlsimExpected) {
            if (-not $r.Json.sqlsim.available -or $r.Json.sqlsim.version -notmatch '^\d+\.\d+\.\d+$') {
                return "sqlsim version was not reported: $($r.Body)"
            }
        } elseif ($r.Json.sqlsim.available -or $r.Json.sqlsim.problem -ne 'not found') {
            return "sqlsim is not built here, so it should be reported as not found: $($r.Body)"
        }
        if ($r.Json.sqlpysim.available -and $r.Json.sqlpysim.version -and $r.Json.sqlpysim.version -notmatch '^\d+\.\d+\.\d+$') {
            return "sqlpysim version was malformed: $($r.Body)"
        }
        return $null
    }

    # -----------------------------------------------------------------------
    # 8. App settings (offline)
    # -----------------------------------------------------------------------

    Write-Section '8. App settings'

    $settingsFile = Join-Path $settingsDirectory 'settings.json'

    Test-Case 'no theme is saved before the user chooses one' {
        $r = Invoke-StudioApi -Method 'GET' -Path '/api/settings'
        if ($r.Status -ne [Net.HttpStatusCode]::OK) { return "expected 200, got $($r.Status)" }
        if ($null -ne $r.Json.theme) { return "expected no saved theme, got '$($r.Json.theme)'" }
        $page = Invoke-StudioApi -Method 'GET' -Path '/'
        if ($page.Body -match 'data-saved-theme') { return 'the page carried a saved theme before one was saved' }
        return $null
    }

    Test-Case 'a saved theme is written to the settings file and into the page' {
        $r = Invoke-StudioApi -Method 'PUT' -Path '/api/settings' -Payload @{ theme = 'green-gold' }
        if ($r.Status -ne [Net.HttpStatusCode]::OK) { return "expected 200, got $($r.Status): $($r.Body)" }
        if (-not (Test-Path -LiteralPath $settingsFile)) { return 'settings.json was not written' }
        if ((Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).theme -ne 'green-gold') { return 'settings.json does not hold the saved theme' }
        $saved = Invoke-StudioApi -Method 'GET' -Path '/api/settings'
        if ($saved.Json.theme -ne 'green-gold') { return "GET returned '$($saved.Json.theme)'" }
        $page = Invoke-StudioApi -Method 'GET' -Path '/'
        if ($page.Body -notmatch '<html lang="en" data-saved-theme="green-gold">') { return 'the page did not carry the saved theme' }
        return $null
    }

    Test-Case 'an unknown or injected theme is rejected with the allowed list' {
        foreach ($theme in @('neon', '"><script>alert(1)</script>', '')) {
            $r = Invoke-StudioApi -Method 'PUT' -Path '/api/settings' -Payload @{ theme = $theme }
            if ($r.Status -ne [Net.HttpStatusCode]::BadRequest) { return "theme '$theme' returned $($r.Status)" }
            if ($r.Json.error -notmatch 'Theme must be one of') { return "theme '$theme' lacked the reason: $($r.Body)" }
        }
        if ((Invoke-StudioApi -Method 'GET' -Path '/api/settings').Json.theme -ne 'green-gold') { return 'a rejected theme replaced the saved one' }
        return $null
    }

    Test-Case 'saving a theme requires the Studio origin and session' {
        $noOrigin = Invoke-StudioApi -Method 'PUT' -Path '/api/settings' -Payload @{ theme = 'dark' } -NoOrigin
        if ($noOrigin.Status -ne [Net.HttpStatusCode]::Forbidden) { return "missing Origin returned $($noOrigin.Status)" }
        $noCookie = Invoke-StudioApi -Method 'PUT' -Path '/api/settings' -Payload @{ theme = 'dark' } -NoCookie
        if ($noCookie.Status -ne [Net.HttpStatusCode]::NotFound) { return "missing session returned $($noCookie.Status)" }
        if ((Invoke-StudioApi -Method 'GET' -Path '/api/settings').Json.theme -ne 'green-gold') { return 'an unauthenticated request changed the theme' }
        return $null
    }

    Test-Case 'a restarted Studio applies the saved theme' {
        $null = Invoke-StudioApi -Method 'PUT' -Path '/api/settings' -Payload @{ theme = 'royal-blue' }
        $restartBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-restart-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $restarted = Start-StudioProcess -BootstrapFile $restartBootstrap
        try {
            $restartUrl = Wait-ForBootstrap -Path $restartBootstrap
            if (-not $restartUrl) { return 'the second Studio never published a bootstrap URL' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $page = Invoke-WebRequest -Uri $restartUrl -WebSession $session -MaximumRedirection 5
            if ($page.Content -notmatch 'data-saved-theme="royal-blue"') { return 'the restarted Studio did not apply the saved theme' }
            return $null
        } finally {
            if (-not $restarted.HasExited) { $restarted.Kill($true) }
            Remove-Item $restartBootstrap -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'a corrupt settings file is ignored rather than stopping Studio' {
        Set-Content -LiteralPath $settingsFile -Value '{ not json' -NoNewline
        $r = Invoke-StudioApi -Method 'GET' -Path '/api/settings'
        if ($r.Status -ne [Net.HttpStatusCode]::OK) { return "expected 200, got $($r.Status)" }
        if ($null -ne $r.Json.theme) { return "a corrupt file produced theme '$($r.Json.theme)'" }
        $page = Invoke-StudioApi -Method 'GET' -Path '/'
        if ($page.Status -ne [Net.HttpStatusCode]::OK -or $page.Body -match 'data-saved-theme') { return 'the page failed or carried a theme from a corrupt file' }
        $repair = Invoke-StudioApi -Method 'PUT' -Path '/api/settings' -Payload @{ theme = 'light' }
        if ($repair.Status -ne [Net.HttpStatusCode]::OK) { return 'saving over a corrupt file failed' }
        return $null
    }

    # -----------------------------------------------------------------------
    # 9. Connection failure reporting
    # -----------------------------------------------------------------------

    if (-not $OfflineOnly) {
        Write-Section '9. Connection failure reporting'

        Test-Case 'connection test to an unreachable port reports a specific failure' {
            $payload = New-RunPayload @{ server = 'localhost,65500'; query = $null; loginTimeoutSeconds = 3 }
            $r = Invoke-StudioApi -Path '/api/connection-test' -Payload $payload
            if ($r.Status -ne [Net.HttpStatusCode]::OK) { return "expected 200, got $($r.Status)" }
            if ($r.Json.success) { return 'an unreachable port reported success' }
            if (-not $r.Json.error) { return 'failure carried no error message' }
            return $null
        }

        Test-Case 'connection test to a nonexistent database reports a specific failure' {
            $payload = New-RunPayload @{ database = 'ThisDatabaseDoesNotExist_sqlsimstudio'; query = $null; loginTimeoutSeconds = 10 }
            $r = Invoke-StudioApi -Path '/api/connection-test' -Payload $payload
            if ($r.Json.success) { return 'a nonexistent database reported success' }
            if (-not $r.Json.error) { return 'failure carried no error message' }
            return $null
        }

        Test-Case 'successful connection test reports every field the interface shows' {
            $payload = New-RunPayload @{ query = $null }
            $r = Invoke-StudioApi -Path '/api/connection-test' -Payload $payload
            if (-not $r.Json.success) { return "connection failed: $($r.Json.error)" }
            foreach ($field in @('serverVersion', 'edition', 'database', 'driver', 'elapsedMs')) {
                if (-not $r.Json.$field) { return "field '$field' was empty" }
            }
            return $null
        }

        # -------------------------------------------------------------------
        # 10. Workload failure reporting
        # -------------------------------------------------------------------

        Write-Section '10. Workload failure reporting'

        function Wait-ForRun {
            param([int]$TimeoutSeconds = 60)

            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                $snapshot = (Invoke-StudioApi -Method 'GET' -Path '/api/runs/current').Json
                if ($snapshot.state -in @('completed', 'failed', 'stopped')) { return $snapshot }
                Start-Sleep -Milliseconds 400
            }
            throw 'Run did not reach a terminal state in time.'
        }

        Test-Case 'a query against a missing object reports the SQL error in the log' {
            $payload = New-RunPayload @{ query = 'SELECT * FROM dbo.ThisTableDoesNotExist_sqlsimstudio' }
            $start = Invoke-StudioApi -Payload $payload
            if ($start.Status -ne [Net.HttpStatusCode]::Accepted) { return "run was not accepted: $($start.Body)" }
            $snapshot = Wait-ForRun
            $errors = @($snapshot.logs | Where-Object { $_.level -eq 'error' })
            if ($errors.Count -eq 0) { return 'a failing query produced no error log entry' }
            if ($errors[0].message -notmatch 'Invalid object name|ThisTableDoesNotExist') {
                return "error text did not name the cause: $($errors[0].message)"
            }
            return $null
        }

        Test-Case 'a failing run reports a non-zero exit code' {
            $snapshot = (Invoke-StudioApi -Method 'GET' -Path '/api/runs/current').Json
            if ($snapshot.exitCode -eq 0) { return 'a failing run reported exit code 0' }
            return $null
        }

        Test-Case 'logs never contain the credential that was supplied' {
            $payload = New-RunPayload @{
                authentication = 'sql'; username = 'sqlsimstudio_probe'
                secret = 'Sentinel-Not-In-Logs-9f2c'; loginTimeoutSeconds = 5
            }
            $start = Invoke-StudioApi -Payload $payload
            if ($start.Status -ne [Net.HttpStatusCode]::Accepted) { return "run was not accepted: $($start.Body)" }
            $snapshot = Wait-ForRun
            $serialized = $snapshot | ConvertTo-Json -Depth 10 -Compress
            if ($serialized -match 'Sentinel-Not-In-Logs-9f2c') { return 'the supplied secret appeared in the run snapshot' }
            return $null
        }

        Test-Case 'a stopped run is recorded as stopped rather than failed' {
            $payload = New-RunPayload @{ query = 'WAITFOR DELAY ''00:00:20'''; threads = 2; iterations = 5 }
            $start = Invoke-StudioApi -Payload $payload
            if ($start.Status -ne [Net.HttpStatusCode]::Accepted) { return "run was not accepted: $($start.Body)" }
            Start-Sleep -Seconds 2
            $stop = Invoke-StudioApi -Method 'DELETE' -Path '/api/runs/current'
            if ($stop.Status -notin @([Net.HttpStatusCode]::Accepted, [Net.HttpStatusCode]::OK)) {
                return "stop returned $($stop.Status)"
            }
            $snapshot = Wait-ForRun -TimeoutSeconds 30
            if ($snapshot.state -ne 'stopped') { return "expected state 'stopped', got '$($snapshot.state)'" }
            return $null
        }

        # -------------------------------------------------------------------
        # Concurrency and lifecycle
        # -------------------------------------------------------------------

        Write-Section '11. Concurrency and lifecycle'

        Test-Case 'a second run is refused while one is already running' {
            $payload = New-RunPayload @{ query = 'WAITFOR DELAY ''00:00:10'''; threads = 1; iterations = 2 }
            $first = Invoke-StudioApi -Payload $payload
            if ($first.Status -ne [Net.HttpStatusCode]::Accepted) { return "first run was not accepted: $($first.Body)" }
            try {
                Start-Sleep -Milliseconds 800
                $second = Invoke-StudioApi -Payload (New-RunPayload)
                if ($second.Status -ne [Net.HttpStatusCode]::BadRequest) {
                    return "expected the second run to be refused, got $($second.Status)"
                }
                if ($second.Json.error -notmatch 'already running') {
                    return "refusal did not explain why: $($second.Json.error)"
                }
                return $null
            } finally {
                $null = Invoke-StudioApi -Method 'DELETE' -Path '/api/runs/current'
                try { Wait-ForRun -TimeoutSeconds 30 | Out-Null } catch { }
            }
        }

        Test-Case 'a connection test is refused while a workload is running' {
            $payload = New-RunPayload @{ query = 'WAITFOR DELAY ''00:00:10'''; threads = 1; iterations = 2 }
            $first = Invoke-StudioApi -Payload $payload
            if ($first.Status -ne [Net.HttpStatusCode]::Accepted) { return "run was not accepted: $($first.Body)" }
            try {
                Start-Sleep -Milliseconds 800
                $test = Invoke-StudioApi -Path '/api/connection-test' -Payload (New-RunPayload @{ query = $null })
                if ($test.Json.success) { return 'a connection test ran during an active workload' }
                if ($test.Json.error -notmatch 'already running') {
                    return "refusal did not explain why: $($test.Json.error)"
                }
                return $null
            } finally {
                $null = Invoke-StudioApi -Method 'DELETE' -Path '/api/runs/current'
                try { Wait-ForRun -TimeoutSeconds 30 | Out-Null } catch { }
            }
        }

        Test-Case 'stopping when nothing is running reports not found' {
            $stop = Invoke-StudioApi -Method 'DELETE' -Path '/api/runs/current'
            if ($stop.Status -ne [Net.HttpStatusCode]::NotFound) {
                return "expected 404, got $($stop.Status)"
            }
            return $null
        }

        Test-Case 'a stop sent while the run is still starting is honoured' {
            # Studio writes input files, and may take a Query Store snapshot,
            # before it launches the engine. A stop in that window must not be
            # lost and leave the workload to run to the end. A large script makes
            # the private input-file write take real time, so the stop lands there.
            $content = "WAITFOR DELAY '00:00:20';`n" + ("-- padding so writing the private input file takes real time`n" * 14000)
            $payload = New-RunPayload @{ mode = 'file'; query = $null; inputFileName = 'slow-start.sql'; inputContent = $content }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $start = Invoke-StudioApi -Payload $payload
            if ($start.Status -ne [Net.HttpStatusCode]::Accepted) { return "run was not accepted: $($start.Body)" }
            $stop = Invoke-StudioApi -Method 'DELETE' -Path '/api/runs/current'
            if ($stop.Status -ne [Net.HttpStatusCode]::Accepted) { return "stop returned $($stop.Status): $($stop.Body)" }
            $snapshot = Wait-ForRun -TimeoutSeconds 30
            if ($snapshot.state -ne 'stopped') { return "expected stopped, got $($snapshot.state)" }
            if ($watch.Elapsed.TotalSeconds -ge 10) {
                return "the workload kept running for $([int]$watch.Elapsed.TotalSeconds) s after an early stop"
            }
            return $null
        }

        Test-Case 'a stop sent while the workload is running ends it promptly' {
            $payload = New-RunPayload @{ query = 'WAITFOR DELAY ''00:00:20''' }
            $start = Invoke-StudioApi -Payload $payload
            if ($start.Status -ne [Net.HttpStatusCode]::Accepted) { return "run was not accepted: $($start.Body)" }
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while ([DateTime]::UtcNow -lt $deadline) {
                $state = (Invoke-StudioApi -Method 'GET' -Path '/api/runs/current').Json
                if (@($state.logs | Where-Object { $_.message -like 'Started process*' }).Count -gt 0) { break }
                Start-Sleep -Milliseconds 100
            }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $stop = Invoke-StudioApi -Method 'DELETE' -Path '/api/runs/current'
            if ($stop.Status -ne [Net.HttpStatusCode]::Accepted) { return "stop returned $($stop.Status): $($stop.Body)" }
            $snapshot = Wait-ForRun -TimeoutSeconds 30
            if ($snapshot.state -ne 'stopped') { return "expected stopped, got $($snapshot.state)" }
            if ($watch.Elapsed.TotalSeconds -ge 5) {
                return "stopping took $([int]$watch.Elapsed.TotalSeconds) s"
            }
            return $null
        }
    } else {
        Write-Section '9-11. Live target sections'
        Write-Host '  skipped (OfflineOnly)' -ForegroundColor DarkGray
    }
}
finally {
    if ($process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit(5000) | Out-Null
    }
    Remove-Item -LiteralPath $bootstrapFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $settingsDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$elapsed = (Get-Date) - $startTime
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Passed:  $script:testsPassed" -ForegroundColor Green
if ($script:testsFailed -gt 0) {
    Write-Host "Failed:  $script:testsFailed" -ForegroundColor Red
    Write-Host ''
    foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
} else {
    Write-Host "Failed:  0" -ForegroundColor Green
}
if ($script:testsSkipped -gt 0) {
    Write-Host "Skipped: $script:testsSkipped (need a live SQL Server)" -ForegroundColor DarkGray
}
Write-Host ("Elapsed: {0:mm\:ss}" -f $elapsed) -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

exit ($(if ($script:testsFailed -gt 0) { 1 } else { 0 }))
