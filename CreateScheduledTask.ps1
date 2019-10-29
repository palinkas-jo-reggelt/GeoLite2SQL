param ( 
	[string]$File
)

$TaskOutput = "$PSScriptRoot\taskoutput.txt"
$ErrorLog = "$PSScriptRoot\ErrorLog.log"
$TaskName = "Update MaxMinds Database"
$Trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Wednesday -At 2am
$User = "NT AUTHORITY\SYSTEM"
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-windowstyle hidden -executionpolicy bypass -File $File"
Register-ScheduledTask -TaskName $TaskName -Trigger $Trigger -User $User -Action $Action -RunLevel Highest -Force

New-Item $TaskOutput

$TaskName = "A Test Import"
$TaskExists = Get-ScheduledTask | Where-Object {$_.TaskName -like $TaskName }

if($TaskExists) {
	Write-Output "Success" | Out-File $TaskOutput
} else {
	Write-Output "ERROR" | Out-File $TaskOutput
}