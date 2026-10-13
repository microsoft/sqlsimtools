# Run basic AdventureWorksLT tests

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

# First test: Demonstrate localhost default behavior (no -S required)
Write-Host "Test 1: Localhost default (no -S parameter)" -ForegroundColor Cyan
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -i = Input SQL file to execute
& $exe -d AdventureWorksLT -E -i (Join-Path $sqlDir "01-simple-queries.sql")

# Remaining tests: Explicit -S localhost
Write-Host "`nTest 2: Explicit -S localhost" -ForegroundColor Cyan
# -S localhost = Server name
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -i = Input SQL file to execute
& $exe -S localhost -d AdventureWorksLT -E -i (Join-Path $sqlDir "02-customer-queries-adventureworkslt.sql")

Write-Host "`nTest 3: Explicit -S localhost" -ForegroundColor Cyan
# -S localhost = Server name
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -i = Input SQL file to execute
& $exe -S localhost -d AdventureWorksLT -E -i (Join-Path $sqlDir "03-product-queries-adventureworkslt.sql")

Write-Host "`nTest 4: Explicit -S localhost" -ForegroundColor Cyan
# -S localhost = Server name
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -i = Input SQL file to execute
& $exe -S localhost -d AdventureWorksLT -E -i (Join-Path $sqlDir "04-sales-queries-adventureworkslt.sql")
