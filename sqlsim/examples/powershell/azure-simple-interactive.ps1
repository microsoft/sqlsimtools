# Simple Azure SQL Database example using interactive Microsoft Entra authentication (-A)
# This will prompt for credentials via browser-based device code flow
# For automated scripts, use access tokens (-T) instead (see other Azure examples)

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

# Simple query with interactive auth
# -S = Azure SQL Server name
# -d master = Database name
# -A = Microsoft Entra Interactive authentication (browser-based)
# -Q = Execute single query
& $exe -S myserver.database.windows.net -d master -A -Q "SELECT @@VERSION"

# Run catalog view queries (works on any database)
# -S = Azure SQL Server name
# -d master = Database name
# -A = Microsoft Entra Interactive authentication (browser-based)
# -i = Input SQL file to execute
& $exe -S myserver.database.windows.net -d master -A -i (Join-Path $sqlDir "01-simple-queries.sql")
