#!/usr/bin/env pwsh
# Simple SQL Server authentication example (-U and -P -)
# Works on any SQL Server database

param(
	[string]$ServerName = "localhost",
	[string]$DatabaseName = "master",
	[string]$Username = "sa",
	[securestring]$Password = (Read-Host "SQL password for $Username" -AsSecureString)
)

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQL AUTHENTICATION EXAMPLES" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

try {
	$plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

	Write-Host "Example 1: Simple query with SQL auth" -ForegroundColor Yellow
	Write-Host "Command: python sqlpysim.py -S $ServerName -U $Username -P - -C -Q `"SELECT @@VERSION`"`n" -ForegroundColor Gray
	$plainPassword | python $script -S $ServerName -U $Username -P - -C -Q "SELECT @@VERSION"

	Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

	Write-Host "Example 2: Specify database" -ForegroundColor Yellow
	Write-Host "Command: python sqlpysim.py -S $ServerName -d $DatabaseName -U $Username -P - -C -Q `"SELECT DB_NAME()`"`n" -ForegroundColor Gray
	$plainPassword | python $script -S $ServerName -d $DatabaseName -U $Username -P - -C -Q "SELECT DB_NAME()"

	Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

	Write-Host "Example 3: Run queries from file" -ForegroundColor Yellow
	Write-Host "Command: python sqlpysim.py -S $ServerName -d $DatabaseName -U $Username -P - -C -i ..\sql\01-simple-queries.sql`n" -ForegroundColor Gray
	$plainPassword | python $script -S $ServerName -d $DatabaseName -U $Username -P - -C `
		-i (Join-Path $PSScriptRoot "..\sql\01-simple-queries.sql")

	Write-Host "`n========================================" -ForegroundColor Cyan
	Write-Host "SQL auth examples completed!" -ForegroundColor Green
	Write-Host "========================================`n" -ForegroundColor Cyan
}
finally {
	if ($passwordPointer -ne [IntPtr]::Zero) {
		[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
	}
	$plainPassword = $null
}
