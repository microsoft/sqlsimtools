#!/usr/bin/env pwsh

param(
    [switch]$SkipBuild,
    [switch]$StartupOnly,
    [string]$StudioExecutable,
    [string]$QueryStoreDatabase
)

$ErrorActionPreference = 'Stop'
$studioRoot = $PSScriptRoot
$projectPath = Join-Path $studioRoot 'server\SqlsimStudio.csproj'
$dllPath = Join-Path $studioRoot 'server\bin\Release\net10.0\sqlsimstudio.dll'
$bootstrapFile = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-bootstrap-{0}.txt" -f [guid]::NewGuid().ToString('N'))

if (-not $SkipBuild) {
    & dotnet build $projectPath -c Release
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if (-not $StudioExecutable -and -not (Test-Path -LiteralPath $dllPath)) {
    throw "Studio assembly not found: $dllPath"
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = if ($StudioExecutable) { (Resolve-Path $StudioExecutable).Path } else { (Get-Command dotnet).Source }
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
if (-not $StudioExecutable) {
    $null = $startInfo.ArgumentList.Add($dllPath)
}
$null = $startInfo.ArgumentList.Add('--no-open')
$null = $startInfo.ArgumentList.Add('--bootstrap-file')
$null = $startInfo.ArgumentList.Add($bootstrapFile)
# Keep the smoke test away from the user's saved Studio preferences.
$settingsDirectory = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimstudio-smoke-settings-{0}" -f [guid]::NewGuid().ToString('N'))
$startInfo.Environment['SQLSIMSTUDIO_SETTINGS_DIR'] = $settingsDirectory
$process = [Diagnostics.Process]::Start($startInfo)

try {
    $baseUrl = $null
    $bootstrapReady = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline -and (-not $baseUrl -or -not $bootstrapReady)) {
        $readTask = $process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait(2000)) {
            if ($process.HasExited) {
                throw "Studio exited before startup: $($process.StandardError.ReadToEnd())"
            }
            continue
        }

        $line = $readTask.Result
        if ($null -eq $line -and $process.HasExited) {
            throw "Studio exited with code $($process.ExitCode) before startup: $($process.StandardError.ReadToEnd())"
        }
        if ($line -like 'SQLSIM_STUDIO_URL=*') {
            $baseUrl = $line.Substring('SQLSIM_STUDIO_URL='.Length)
        } elseif ($line -eq 'SQLSIM_STUDIO_BOOTSTRAP_READY=1') {
            $bootstrapReady = $true
        }
    }

    if (-not $baseUrl -or -not $bootstrapReady -or -not (Test-Path -LiteralPath $bootstrapFile)) {
        throw 'Studio did not publish startup URLs within 15 seconds.'
    }
    $bootstrapUrl = Get-Content -LiteralPath $bootstrapFile -Raw

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)

    try {
        $unauthenticated = $client.GetAsync("$baseUrl/api/health").GetAwaiter().GetResult()
        if ($unauthenticated.StatusCode -ne [Net.HttpStatusCode]::NotFound) {
            throw "Unauthenticated health returned $($unauthenticated.StatusCode), expected 404."
        }

        $bootstrap = $client.GetAsync($bootstrapUrl).GetAwaiter().GetResult()
        if ($bootstrap.StatusCode -ne [Net.HttpStatusCode]::Found) {
            throw "Bootstrap returned $($bootstrap.StatusCode), expected 302."
        }

        $setCookie = ($bootstrap.Headers.GetValues('Set-Cookie') -join '; ')
        $sessionMatch = [regex]::Match($setCookie, 'sqlsimstudio_session=([^;]+)', 'IgnoreCase')
        if (-not $sessionMatch.Success -or
            $setCookie -notmatch 'httponly' -or
            $setCookie -notmatch 'samesite=strict') {
            throw "Bootstrap cookie is missing required security attributes: $setCookie"
        }
        $cookie = "sqlsimstudio_session=$($sessionMatch.Groups[1].Value)"

        $healthRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/api/health")
        $healthRequest.Headers.Add('Cookie', $cookie)
        $health = $client.Send($healthRequest)
        if ($health.StatusCode -ne [Net.HttpStatusCode]::OK) {
            throw "Authenticated health returned $($health.StatusCode), expected 200."
        }
        $healthJson = $health.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $expectedReleaseStage = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [Runtime.InteropServices.OSPlatform]::Linux) -or
            [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [Runtime.InteropServices.OSPlatform]::OSX) -or
            [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq
            [Runtime.InteropServices.Architecture]::Arm64) { 'Private Preview' } else { 'Public Preview' }
        if ($healthJson.status -ne 'ok' -or
            $healthJson.application -ne 'sqlsim Studio' -or
            $healthJson.version -ne '1.0.0' -or
            $healthJson.releaseStage -ne $expectedReleaseStage) {
            throw 'Authenticated health payload is invalid.'
        }
        if ($health.Headers.GetValues('Content-Security-Policy') -notmatch "default-src 'self'") {
            throw 'Content-Security-Policy header is missing.'
        }

        $pageRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/")
        $pageRequest.Headers.Add('Cookie', $cookie)
        $page = $client.Send($pageRequest)
        $pageContent = $page.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($page.StatusCode -ne [Net.HttpStatusCode]::OK -or
            $pageContent -notmatch 'vendor/lucide\.min\.js' -or
            $pageContent -notmatch 'assets/sqlsim-icon\.svg' -or
            $pageContent -match 'unpkg\.com|sqlsim Studio mockup|mock-action') {
            throw 'Authenticated Studio UI is missing or references a remote script.'
        }
        if ($pageContent -notmatch 'class="required-mark"' -or
            $pageContent -notmatch 'id="server" value="localhost" required' -or
            $pageContent -match 'Ramp batch' -or
            $pageContent -notmatch 'id="test-connection"><i data-lucide="plug-zap"') {
            throw 'Studio required-field or connection-test presentation is invalid.'
        }
        foreach ($authMode in @('integrated', 'token', 'sql', 'interactive', 'managed', 'service-principal')) {
            if ($pageContent -notmatch ('<option value="{0}"' -f $authMode)) {
                throw "Studio must offer the $authMode authentication mode."
            }
        }
        foreach ($enabledMode in @('integrated', 'token', 'sql', 'interactive', 'managed', 'service-principal')) {
            if ($pageContent -match ('<option value="{0}" disabled' -f $enabledMode)) {
                throw "Studio must not disable the verified $enabledMode authentication mode."
            }
        }
        # Unimplemented controls are removed, not shipped disabled. Auth modes are the
        # documented exception: they belong to the saved-configuration contract.
        foreach ($absentControl in @('Copy events', 'Run again', 'Open configuration',
                                     'Clear display', 'Copy log', 'Export log',
                                     'Save HTML report', 'Ramp batch')) {
            if ($pageContent -match [Regex]::Escape($absentControl)) {
                throw "Studio must not present the unimplemented control '$absentControl'."
            }
        }
        if ($pageContent -match 'Not yet implemented') {
            throw 'Studio must not ship a control marked as not yet implemented.'
        }
        foreach ($builtControl in @('import-workload-json', 'export-results-json', 'export-comparison')) {
            if ($pageContent -notmatch ('id="{0}"[^>]*>' -f $builtControl) -or
                $pageContent -match ('id="{0}"[^>]*disabled' -f $builtControl)) {
                throw "Studio control '$builtControl' must be present and enabled."
            }
        }
        # HTML reporting belongs to sqlsim/examples/reports/execution-report.ps1, not Studio.
        if ($pageContent -match 'Save HTML report') {
            throw 'Studio must not present a Save HTML report control.'
        }
        if ($pageContent -notmatch 'id="quiet-mode-toggle" checked disabled' -or
            $pageContent -notmatch '<option value="console">Console output · show result rows</option>') {
            throw 'Studio must offer console result rows while keeping quiet mode enabled for structured telemetry.'
        }
        $scriptRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/app.js")
        $scriptRequest.Headers.Add('Cookie', $cookie)
        $script = $client.Send($scriptRequest)
        $scriptContent = $script.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($script.StatusCode -ne [Net.HttpStatusCode]::OK -or
            $scriptContent -match 'startMockRun|Math\.random|11,300|1,307') {
            throw 'Studio client script contains a fabricated workload path.'
        }
        if ($scriptContent -notmatch 'progress\?\.odbc_driver_version' -or
            $scriptContent -notmatch 'progress\?\.server_version' -or
            $scriptContent -notmatch 'progress\?\.server_edition' -or
            $scriptContent -match 'Not reported for live runs') {
            throw 'Studio does not surface driver and SQL Server metadata from live events.'
        }
        if ($scriptContent -notmatch "run-state-label'\)\.textContent = 'Running\.\.\.'" -or
            $pageContent -notmatch 'class="run-state" aria-live="polite"') {
            throw 'Studio does not expose an accessible active Running state.'
        }
        $monitorMatch = [regex]::Match(
            $pageContent,
            '<section id="monitor-view".*?<section id="results-view"',
            [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $monitorMatch.Success -or
            $monitorMatch.Value -match 'orders-read\.sql|customer-search\.sql|inventory-write\.sql|1,284|7,842|11,300') {
            throw 'Studio Monitor contains seeded mock workload data.'
        }
        $resultsMatch = [regex]::Match(
            $pageContent,
            '<section id="results-view".*?<section id="compare-view"',
            [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $resultsMatch.Success -or
            $resultsMatch.Value -match 'orders-read\.sql|customer-search\.sql|inventory-write\.sql|11,300|1,307|AdventureWorks2022|studio-workload\.json') {
            throw 'Studio Results contains seeded mock data.'
        }
        $compareMatch = [regex]::Match(
            $pageContent,
            '<section id="compare-view".*?</section>\s*</main>',
            [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $compareMatch.Success -or
            $compareMatch.Value -match 'Before index|After index|1,172|11\.5%|IX_OrderDate') {
            throw 'Studio Compare contains seeded mock data.'
        }

        $iconRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/assets/sqlsim-icon.svg")
        $iconRequest.Headers.Add('Cookie', $cookie)
        $icon = $client.Send($iconRequest)
        if ($icon.StatusCode -ne [Net.HttpStatusCode]::OK -or
            $icon.Content.Headers.ContentType.MediaType -ne 'image/svg+xml') {
            throw 'Authenticated sqlsim icon is missing or has the wrong content type.'
        }

        $unauthenticatedAsset = $client.GetAsync("$baseUrl/assets/sqlsim-icon.svg").GetAwaiter().GetResult()
        if ($unauthenticatedAsset.StatusCode -ne [Net.HttpStatusCode]::NotFound) {
            throw "Unauthenticated asset returned $($unauthenticatedAsset.StatusCode), expected 404."
        }

        $replayedBootstrap = $client.GetAsync($bootstrapUrl).GetAwaiter().GetResult()
        if ($replayedBootstrap.StatusCode -ne [Net.HttpStatusCode]::NotFound) {
            throw "Replayed bootstrap returned $($replayedBootstrap.StatusCode), expected 404."
        }
        if (-not (Test-Path -LiteralPath $bootstrapFile)) {
            throw 'Bootstrap file was not rotated after successful session establishment.'
        }
        $rotatedBootstrapUrl = Get-Content -LiteralPath $bootstrapFile -Raw
        if ($rotatedBootstrapUrl -eq $bootstrapUrl -or
            $rotatedBootstrapUrl -notmatch ('^{0}/bootstrap/[A-F0-9]{{64}}$' -f [Regex]::Escape($baseUrl))) {
            throw 'Bootstrap file does not contain a fresh single-use session URL.'
        }

        $hostRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/api/health")
        $hostRequest.Headers.Host = 'attacker.invalid'
        $hostRequest.Headers.Add('Cookie', $cookie)
        $hostResponse = $client.Send($hostRequest)
        if ($hostResponse.StatusCode -ne [Net.HttpStatusCode]::NotFound) {
            throw "Host-header attack returned $($hostResponse.StatusCode), expected 404."
        }

        $postRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/health")
        $postRequest.Headers.Add('Cookie', $cookie)
        $postResponse = $client.Send($postRequest)
        if ($postResponse.StatusCode -ne [Net.HttpStatusCode]::Forbidden) {
            throw "Unsafe request without Origin returned $($postResponse.StatusCode), expected 403."
        }

        # Authentication validation is pure request logic, so it runs without a SQL target.
        function Assert-RejectedRequest {
            param([hashtable]$Payload, [string]$Because)

            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/runs")
            $request.Headers.Add('Cookie', $cookie)
            $request.Headers.Add('Origin', $baseUrl)
            $request.Content = [Net.Http.StringContent]::new(
                ($Payload | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8, 'application/json')
            $response = $client.Send($request)
            if ($response.StatusCode -ne [Net.HttpStatusCode]::BadRequest) {
                throw "$Because returned $($response.StatusCode), expected 400."
            }
        }

        $authBase = @{
            engine = 'sqlsim'; mode = 'query'; server = 'localhost'; database = 'tempdb'
            query = 'SELECT 1'; threads = 1; iterations = 1; quiet = $true
            trustServerCertificate = $true; stopOnError = $true
            telemetry = 'final'; statisticsSource = 'none'
        }

        $servicePrincipalNoUser = $authBase.Clone()
        $servicePrincipalNoUser.authentication = 'service-principal'
        $servicePrincipalNoUser.username = ''
        $servicePrincipalNoUser.secret = 'secret-value'
        Assert-RejectedRequest -Payload $servicePrincipalNoUser -Because 'Service principal without a client ID'

        $servicePrincipalNoSecret = $authBase.Clone()
        $servicePrincipalNoSecret.authentication = 'service-principal'
        $servicePrincipalNoSecret.username = 'client-id'
        $servicePrincipalNoSecret.secret = $null
        Assert-RejectedRequest -Payload $servicePrincipalNoSecret -Because 'Service principal without a secret'

        $managedWithSecret = $authBase.Clone()
        $managedWithSecret.authentication = 'managed'
        $managedWithSecret.username = $null
        $managedWithSecret.secret = 'not-allowed'
        Assert-RejectedRequest -Payload $managedWithSecret -Because 'Managed identity with a secret'

        $interactiveWithUser = $authBase.Clone()
        $interactiveWithUser.authentication = 'interactive'
        $interactiveWithUser.username = 'someone@example.test'
        $interactiveWithUser.secret = $null
        Assert-RejectedRequest -Payload $interactiveWithUser -Because 'Entra interactive with a username'

        $malformedReplay = $authBase.Clone()
        $malformedReplay.mode = 'replay'
        $malformedReplay.authentication = 'integrated'
        $malformedReplay.Remove('query')
        $malformedReplay.inputFileName = 'malformed.xml'
        $malformedReplay.inputContent = '<replay><event></replay>'
        $malformedReplay.replayMode = 'fast'
        Assert-RejectedRequest -Payload $malformedReplay -Because 'Malformed replay XML'

        if ($StartupOnly) {
            Write-Host 'Studio startup and security smoke test passed.' -ForegroundColor Green
            return
        }

        function Invoke-StudioRun {
            param([hashtable]$Payload, [string]$Name)

            $runRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/runs")
            $runRequest.Headers.Add('Cookie', $cookie)
            $runRequest.Headers.Add('Origin', $baseUrl)
            $runRequest.Content = [Net.Http.StringContent]::new(
                ($Payload | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8, 'application/json')
            $runResponse = $client.Send($runRequest)
            if ($runResponse.StatusCode -ne [Net.HttpStatusCode]::Accepted) {
                $runError = $runResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                throw "$Name run returned $($runResponse.StatusCode): $runError"
            }

            $run = $null
            $runDeadline = [DateTime]::UtcNow.AddSeconds(30)
            while ([DateTime]::UtcNow -lt $runDeadline) {
                $statusRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/api/runs/current")
                $statusRequest.Headers.Add('Cookie', $cookie)
                $statusResponse = $client.Send($statusRequest)
                $run = $statusResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                if ($run.state -in @('completed', 'failed', 'stopped')) {
                    break
                }
                [Threading.Thread]::Sleep(100)
            }

            $consoleMode = $Payload.telemetry -eq 'console'
            $failed = $run.state -ne 'completed' -or $run.exitCode -ne 0
            if (-not $consoleMode) {
                $failed = $failed -or -not $run.result.success -or $run.result.metrics.errors.total -ne 0
            }
            if ($failed) {
                throw "Studio $Name workload did not complete successfully: $($run | ConvertTo-Json -Depth 8 -Compress)"
            }
            return $run
        }

        $baseRunPayload = @{
            engine = 'sqlsim'
            server = 'localhost'
            database = 'tempdb'
            authentication = 'integrated'
            username = $null
            secret = $null
            threads = 1
            iterations = 1
            quiet = $true
            trustServerCertificate = $true
            stopOnError = $true
            telemetry = 'final'
            statisticsSource = 'none'
        }

        $missingDatabasePayload = $baseRunPayload.Clone()
        $missingDatabasePayload.mode = 'query'
        $missingDatabasePayload.database = ''
        $missingDatabasePayload.query = 'SELECT 1'
        $missingDatabaseRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/runs")
        $missingDatabaseRequest.Headers.Add('Cookie', $cookie)
        $missingDatabaseRequest.Headers.Add('Origin', $baseUrl)
        $missingDatabaseRequest.Content = [Net.Http.StringContent]::new(
            ($missingDatabasePayload | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8, 'application/json')
        $missingDatabaseResponse = $client.Send($missingDatabaseRequest)
        if ($missingDatabaseResponse.StatusCode -ne [Net.HttpStatusCode]::BadRequest) {
            throw "Missing database returned $($missingDatabaseResponse.StatusCode), expected 400."
        }

        $queryPayload = $baseRunPayload.Clone()
        $queryPayload.mode = 'query'
        $queryPayload.query = 'SELECT 1 AS StudioSmokeTest'
        $queryRun = Invoke-StudioRun -Payload $queryPayload -Name 'Query'
        if (-not $queryRun.result.server_version -or -not $queryRun.result.server_edition) {
            throw 'Final-result runs must report the SQL Server version and edition.'
        }
        # Final-result runs omit -v so per-execution detail does not inflate the
        # result; -v is the only source of the echoed connection string.
        if ($queryRun.result.connection_string) {
            throw 'Final-result runs must not pass -v.'
        }

        $connectionTestPayload = $baseRunPayload.Clone()
        $connectionTestPayload.mode = 'query'
        $connectionTestPayload.query = $null
        $connectionTestPayload.applicationName = 'sqlsimstudio'
        $connectionTestRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/connection-test")
        $connectionTestRequest.Headers.Add('Cookie', $cookie)
        $connectionTestRequest.Headers.Add('Origin', $baseUrl)
        $connectionTestRequest.Content = [Net.Http.StringContent]::new(
            ($connectionTestPayload | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8, 'application/json')
        $connectionTestResponse = $client.Send($connectionTestRequest)
        $connectionTest = $connectionTestResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($connectionTestResponse.StatusCode -ne [Net.HttpStatusCode]::OK -or
            -not $connectionTest.success -or
            -not $connectionTest.serverVersion -or
            -not $connectionTest.edition -or
            -not $connectionTest.driver -or
            $connectionTest.database -ne 'tempdb' -or
            $null -eq $connectionTest.elapsedMs) {
            throw "Studio connection test did not report live server details: $($connectionTest | ConvertTo-Json -Depth 6 -Compress)"
        }

        $badConnectionPayload = $connectionTestPayload.Clone()
        $badConnectionPayload.server = 'localhost,65500'
        $badConnectionPayload.loginTimeoutSeconds = 2
        $badConnectionRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUrl/api/connection-test")
        $badConnectionRequest.Headers.Add('Cookie', $cookie)
        $badConnectionRequest.Headers.Add('Origin', $baseUrl)
        $badConnectionRequest.Content = [Net.Http.StringContent]::new(
            ($badConnectionPayload | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8, 'application/json')
        $badConnectionResponse = $client.Send($badConnectionRequest)
        $badConnection = $badConnectionResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($badConnectionResponse.StatusCode -ne [Net.HttpStatusCode]::OK -or
            $badConnection.success -or
            -not $badConnection.error) {
            throw 'Studio connection test did not report a failure for an unreachable server.'
        }

        $queryRepeatRun = Invoke-StudioRun -Payload $queryPayload -Name 'Repeated Query'
        $historyRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/api/runs/history")
        $historyRequest.Headers.Add('Cookie', $cookie)
        $historyResponse = $client.Send($historyRequest)
        $history = @($historyResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
        $historyQueryRuns = @($history | Where-Object { $_.id -in @($queryRun.id, $queryRepeatRun.id) })
        if ($historyResponse.StatusCode -ne [Net.HttpStatusCode]::OK -or
            $historyQueryRuns.Count -ne 2 -or
            $historyQueryRuns[0].comparisonKey -ne $historyQueryRuns[1].comparisonKey -or
            -not $historyQueryRuns[0].result.metrics) {
            throw 'Studio history did not retain two comparable canonical runs.'
        }

        $consolePayload = $baseRunPayload.Clone()
        $consolePayload.mode = 'query'
        $consolePayload.query = 'SELECT 42 AS StudioConsoleResult'
        $consolePayload.telemetry = 'console'
        $consolePayload.quiet = $false
        $consoleRun = Invoke-StudioRun -Payload $consolePayload -Name 'Console results'
        if ($consoleRun.result -or
            $consoleRun.consoleOutput -notmatch 'StudioConsoleResult' -or
            $consoleRun.consoleOutput -notmatch '\b42\b' -or
            $consoleRun.consoleOutputTruncated) {
            throw 'Studio console mode did not return the expected bounded result rows.'
        }
        $historyAfterConsoleRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$baseUrl/api/runs/history")
        $historyAfterConsoleRequest.Headers.Add('Cookie', $cookie)
        $historyAfterConsoleResponse = $client.Send($historyAfterConsoleRequest)
        $historyAfterConsole = @($historyAfterConsoleResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
        if ($historyAfterConsole.Count -ne $history.Count) {
            throw 'Studio history must exclude console runs without canonical metrics.'
        }

        $pythonPayload = $baseRunPayload.Clone()
        $pythonPayload.engine = 'sqlpysim'
        $pythonPayload.mode = 'query'
        $pythonPayload.query = 'SELECT 1 AS StudioPythonSmokeTest'
        $pythonRun = Invoke-StudioRun -Payload $pythonPayload -Name 'sqlpysim Query'

        $pythonConsolePayload = $consolePayload.Clone()
        $pythonConsolePayload.engine = 'sqlpysim'
        $pythonConsolePayload.query = 'SELECT 84 AS StudioPythonConsoleResult'
        $pythonConsoleRun = Invoke-StudioRun -Payload $pythonConsolePayload -Name 'sqlpysim Console results'
        if ($pythonConsoleRun.consoleOutput -notmatch 'StudioPythonConsoleResult' -or
            $pythonConsoleRun.consoleOutput -notmatch '\b84\b') {
            throw 'Studio sqlpysim console mode did not return the expected result rows.'
        }

        if ($QueryStoreDatabase) {
            $queryStorePayload = $baseRunPayload.Clone()
            $queryStorePayload.mode = 'query'
            $queryStorePayload.database = $QueryStoreDatabase
            $queryStorePayload.query = 'SELECT TOP (10) name FROM sys.objects ORDER BY object_id'
            $queryStorePayload.iterations = 20
            $queryStorePayload.statisticsSource = 'query-store'
            $queryStoreRun = Invoke-StudioRun -Payload $queryStorePayload -Name 'Query Store'
            if ($queryStoreRun.queryStore.source -ne 'aggregate_delta') {
                throw 'Studio Query Store result is missing the aggregate delta source.'
            }
            $unrelatedQuery = $queryStoreRun.queryStore.queries |
                Where-Object { $_.queryText.Trim() -ne $queryStorePayload.query }
            if ($unrelatedQuery) {
                throw 'Query-mode Query Store results included SQL text other than the submitted query.'
            }
        }

        $filePayload = $baseRunPayload.Clone()
        $filePayload.mode = 'file'
        $filePayload.inputFileName = 'studio-smoke.sql'
        $filePayload.inputContent = "SELECT 1 AS FirstBatch;`nGO`nSELECT 2 AS SecondBatch;"
        $fileRun = Invoke-StudioRun -Payload $filePayload -Name 'SQL File'
        if ($fileRun.result.configuration.batch_count -ne 2) {
            throw 'Studio SQL File workload did not execute both GO-separated batches.'
        }

        $workloadPayload = $baseRunPayload.Clone()
        $workloadPayload.mode = 'workload'
        $workloadPayload.workloadGroups = @(
            @{ fileName = 'read.sql'; content = 'SELECT 1 AS ReadValue'; threads = 2; iterations = 2; thinkTimeMs = 0 },
            @{ fileName = 'write.sql'; content = 'SELECT 2 AS WriteValue'; threads = 1; iterations = 3; thinkTimeMs = 1 }
        )
        $workloadRun = Invoke-StudioRun -Payload $workloadPayload -Name 'Mixed Workload'
        if ($workloadRun.result.configuration.workload_groups -ne 2 -or
            $workloadRun.result.configuration.total_batches -ne 7) {
            throw 'Studio mixed workload did not preserve generated group load settings.'
        }

        $replayPayload = $baseRunPayload.Clone()
        $replayPayload.mode = 'replay'
        $replayPayload.database = 'master'
        $replayPayload.inputFileName = 'studio-smoke.xml'
        $replayPayload.inputContent = Get-Content (Join-Path $studioRoot '..\sqlsim\testing\replay-test-data.xml') -Raw
        $replayPayload.replayMode = 'fast'
        $replayRun = Invoke-StudioRun -Payload $replayPayload -Name 'Replay'

        Write-Host 'Studio smoke test passed:' -ForegroundColor Green
        Write-Host '  unauthenticated API denied'
        Write-Host '  one-time bootstrap enforced'
        Write-Host '  HttpOnly SameSite=Strict session established'
        Write-Host '  authenticated health returned runtime metadata'
        Write-Host '  authenticated UI served only local scripts'
        Write-Host '  fabricated workload simulation absent'
        Write-Host '  seeded A/B comparison data absent'
        Write-Host '  console result-row mode available with structured quiet mode protected'
        Write-Host '  unauthenticated static assets denied'
        Write-Host '  hostile Host denied'
        Write-Host '  unsafe request without matching Origin denied'
        Write-Host '  structured Query-mode workload completed with canonical JSON'
        Write-Host '  connection test reported live server details and a reachable failure'
        Write-Host '  all six authentication modes offered'
        Write-Host '  authentication credential rules enforced per mode'
        Write-Host '  unimplemented controls absent rather than shipped disabled'
        Write-Host '  workload import, results export, and comparison export enabled'
        Write-Host '  comparable final runs retained in bounded session history'
        Write-Host '  console Query-mode workload returned result rows without JSON'
        Write-Host '  sqlpysim Query-mode workload completed with canonical JSON'
        Write-Host '  sqlpysim console workload returned result rows without JSON'
        if ($QueryStoreDatabase) { Write-Host '  Query Store before/after aggregate delta captured' }
        Write-Host '  SQL File workload executed both GO-separated batches'
        Write-Host '  generated mixed workload preserved per-group load settings'
        Write-Host '  Replay workload completed from private staged XML'
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
} finally {
    if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $process.Dispose()
    Remove-Item -LiteralPath $bootstrapFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $settingsDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
