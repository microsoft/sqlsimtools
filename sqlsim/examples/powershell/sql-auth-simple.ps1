# Simple SQL Server Authentication example
# Use -U for the username and -P - to read the password from stdin

param(
    [string]$ServerName = "localhost",
    [string]$DatabaseName = "master",
    [string]$Username = "myusername",
    [securestring]$Password = (Read-Host "SQL password for $Username" -AsSecureString)
)

# sqlsim reads the password from stdin with -P - so it never appears in process arguments.
$PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))

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

Write-Host "Using SQL Authentication:" -ForegroundColor Cyan
Write-Host "  Server: $ServerName" -ForegroundColor Gray
Write-Host "  Database: $DatabaseName" -ForegroundColor Gray
Write-Host "  Username: $Username" -ForegroundColor Gray
Write-Host ""

# Simple query with SQL auth
# -S = Server name
# -d = Database name
# -U = SQL Server username
# -P - = Read the password from stdin
# -Q = Execute single query
$PlainPassword | & $exe -S $ServerName -d $DatabaseName -U $Username -P - -Q "SELECT @@VERSION"

# Run catalog view queries (works on any database)
# -S = Server name
# -d = Database name
# -U = SQL Server username
# -P - = Read the password from stdin
# -i = Input SQL file to execute
$PlainPassword | & $exe -S $ServerName -d $DatabaseName -U $Username -P - -i (Join-Path $sqlDir "01-simple-queries.sql")
