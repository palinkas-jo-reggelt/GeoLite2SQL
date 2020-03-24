<#
.SYNOPSIS
	Setup database for MaxMindas geoip 

.DESCRIPTION
	Setup database for MaxMindas geoip 

.FUNCTIONALITY


.NOTES
	Run first to setup database before attempting to run main script
	
.EXAMPLE


#>

<#  Include required files  #>
Try {
	.("$PSScriptRoot\Config.ps1")
	.("$PSScriptRoot\CommonCode.ps1")
}
Catch {
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to load supporting PowerShell Scripts : $query `n$Error[0]" | out-file "$PSScriptRoot\PSError.log" -append
}

<#  Create tables if they don't exist  #>
CreateTablesIfNeeded

<#  Create scheduled task  #>

$File = $MyInvocation.MyCommand.Source
$CreateScheduledTask = "$PSScriptRoot\CreateScheduledTask.ps1"
$TaskOutput = "$PSScriptRoot\taskoutput.txt"

If (Test-Path $TaskOutput) {Remove-Item -Force -Path $TaskOutput}

Write-Host " "
Write-Host "Scheduled Task Creation...."
Write-Host "If you chose YES, you will be prompted for UAC if not in Administrator console."
Write-Host "Administrator privileges required to create scheduled task."
Write-Host " "
$AskTask = Read-Host -prompt "Do you want to create a scheduled task? (y/n)"
If ($AskTask -eq 'y') {
	If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
		Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$CreateScheduledTask`" -File `"$File`"" -Verb RunAs  -Wait
	} Else {
		Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$CreateScheduledTask`" -File `"$File`"" -Wait
	}
	If (Test-Path $TaskOutput) {
		Get-Content $TaskOutput | ForEach {
			$TaskOutputAnswer = $_
		}
		If ($TaskOutputAnswer -match 'Success') {
			Write-Host "Scheduled Task was created successfully."
		} Else {
			Write-Host "Scheduled Task creation **FAILED**."
		}
	} Else {
		Write-Host "Scheduled Task creation **FAILED**. Did not run."
	}
}
Else {
	Write-Host "You chose NOT to create scheduled task. Please manually create one to automatically update the database weekly."
	Write-Host " "
}