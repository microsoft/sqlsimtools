# Run basic AdventureWorksLT tests on Azure SQL Database using access token
# Get token first: $token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)

# Find sqlsim: the installed release for this machine's architecture, then the
# x64 release (ARM64 Windows can run it), then a source build, then PATH.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
$searchPaths = @(
    (Join-Path $PSScriptRoot "..\..\$arch\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\x64\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\build\$arch\Release\sqlsim.exe")
)
$exe = $searchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = (Get-Command sqlsim -ErrorAction SilentlyContinue).Source }

if (-not $exe) {
    Write-Host "ERROR: sqlsim.exe not found. Searched:" -ForegroundColor Red
    $searchPaths | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

$sqlDir = Join-Path $PSScriptRoot "..\sql"

$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)

# -S = Azure SQL Server name
# -d AdventureWorksLT = Database name
# -T - = Access token authentication, read from stdin. Piping $token keeps it out
#        of the process list, where other tools and users could read it.
# -i = Input SQL file to execute

$token | & $exe -S myserver.database.windows.net -d AdventureWorksLT -T - -i (Join-Path $sqlDir "01-simple-queries.sql")
$token | & $exe -S myserver.database.windows.net -d AdventureWorksLT -T - -i (Join-Path $sqlDir "02-customer-queries-adventureworkslt.sql")
$token | & $exe -S myserver.database.windows.net -d AdventureWorksLT -T - -i (Join-Path $sqlDir "03-product-queries-adventureworkslt.sql")
$token | & $exe -S myserver.database.windows.net -d AdventureWorksLT -T - -i (Join-Path $sqlDir "04-sales-queries-adventureworkslt.sql")
