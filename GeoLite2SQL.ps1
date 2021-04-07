<#

.SYNOPSIS
	Install MaxMinds geoip database to database server

.DESCRIPTION
	Downloads and unzips MaxMinds csv geoip data, then populate table on database server with csv data

.FUNCTIONALITY
	1) If geoip table does not exist, it gets created
	2) Deletes old files if existing
	3) Downloads MaxMinds geolite2 cvs data and converts it
	4) Loads data into database
	5) Feedback on console and by email on weekly updates.

.NOTES
	
	Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)
	
.EXAMPLE
	Example query to return country code and country name from database:
	
		SELECT country_iso_code, country_name 
		FROM (
			SELECT * 
			FROM geocountry 
			WHERE INET_ATON('212.186.81.105') <= network_last_integer
			LIMIT 1
			) AS a 
		INNER JOIN geolocations AS b on a.geoname_id = b.geoname_id
		WHERE network_start_integer <= INET_ATON('212.186.81.105')
		LIMIT 1;

#>

<#  Include required files  #>
Try {
	.("$PSScriptRoot\GeoLite2SQL-Config.ps1")
}
Catch {
	Write-Output "$(Get-Date -f G) : ERROR : Unable to load supporting PowerShell Scripts : $($Error[0])" | Out-File "$PSScriptRoot\PSError.log" -Append
}

<###   FUNCTIONS   ###>
Function Debug ($DebugOutput) {
	If ($VerboseFile) {Write-Output "$(Get-Date -f G) : $DebugOutput" | Out-File $DebugLog -Encoding ASCII -Append}
	If ($VerboseConsole) {Write-Host "$(Get-Date -f G) : $DebugOutput"}
}

Function Email ($Email) {
	If ($UseHTML){
		If ($Email -match "\[OK\]") {$Email = $Email -Replace "\[OK\]","<span style=`"background-color:green;color:white;font-weight:bold;font-family:Courier New;`">[OK]</span>"}
		If ($Email -match "\[INFO\]") {$Email = $Email -Replace "\[INFO\]","<span style=`"background-color:yellow;font-weight:bold;font-family:Courier New;`">[INFO]</span>"}
		If ($Email -match "\[ERROR\]") {$Email = $Email -Replace "\[ERROR\]","<span style=`"background-color:red;color:white;font-weight:bold;font-family:Courier New;`">[ERROR]</span>"}
		If ($Email -match "^\s$") {$Email = $Email -Replace "\s","&nbsp;"}
		Write-Output "<tr><td>$Email</td></tr>" | Out-File $EmailBody -Encoding ASCII -Append
	} Else {
		Write-Output $Email | Out-File $EmailBody -Encoding ASCII -Append
	}	
}

Function EmailResults {
	If (($AttachDebugLog) -and (Test-Path $DebugLog)) {
		If (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize) {
			Email "Debug log too large to email. Please see file in GeoLite2SQL script folder."
		}
	}
	Try {
		$Body = (Get-Content -Path $EmailBody | Out-String )
		If (($AttachDebugLog) -and (Test-Path $DebugLog) -and (((Get-Item $DebugLog).length/1MB) -lt $MaxAttachmentSize)){$Attachment = New-Object System.Net.Mail.Attachment $DebugLog}
		$Message = New-Object System.Net.Mail.Mailmessage $EmailFrom, $EmailTo, $Subject, $Body
		$Message.IsBodyHTML = $UseHTML
		If (($AttachDebugLog) -and (Test-Path $DebugLog) -and (((Get-Item $DebugLog).length/1MB) -lt $MaxAttachmentSize)){$Message.Attachments.Add($DebugLog)}
		$SMTP = New-Object System.Net.Mail.SMTPClient $SMTPServer,$SMTPPort
		$SMTP.EnableSsl = $UseSSL
		$SMTP.Credentials = New-Object System.Net.NetworkCredential($SMTPAuthUser, $SMTPAuthPass); 
		$SMTP.Send($Message)
	}
	Catch {
		Debug "Email ERROR : $($Error[0])"
	}
}

Function Plural ($Integer) {
	If ($Integer -eq 1) {$S = ""} Else {$S = "s"}
	Return $S
}

Function ElapsedTime ($EndTime) {
	$TimeSpan = New-Timespan $EndTime
	If (([int]($TimeSpan).Hours) -eq 0) {$Hours = ""} ElseIf (([int]($TimeSpan).Hours) -eq 1) {$Hours = "1 hour "} Else {$Hours = "$([int]($TimeSpan).Hours) hours "}
	If (([int]($TimeSpan).Minutes) -eq 0) {$Minutes = ""} ElseIf (([int]($TimeSpan).Minutes) -eq 1) {$Minutes = "1 minute "} Else {$Minutes = "$([int]($TimeSpan).Minutes) minutes "}
	If (([int]($TimeSpan).Seconds) -eq 1) {$Seconds = "1 second"} Else {$Seconds = "$([int]($TimeSpan).Seconds) seconds"}
	
	If (($TimeSpan).TotalSeconds -lt 1) {
		$Return = "less than 1 second"
	} Else {
		$Return = "$Hours$Minutes$Seconds"
	}
	Return $Return
}

Function MySQLQuery($Query) {
	$Today = (Get-Date).ToString("yyyyMMdd")
	$DBErrorLog = "$PSScriptRoot\$Today-DBError.log"
	$ConnectionString = "server=" + $MySQLHost + ";port=" + $MySQLPort + ";uid=" + $MySQLUserName + ";pwd=" + $MySQLPassword + ";database=" + $MySQLDatabase + ";SslMode=" + $MySQLSSL + ";Default Command Timeout=" + $MySQLCommandTimeOut + ";Connect Timeout=" + $MySQLConnectTimeout + ";"
	$Error.Clear()
	Try {
		[void][System.Reflection.Assembly]::LoadWithPartialName("MySql.Data")
		$Connection = New-Object MySql.Data.MySqlClient.MySqlConnection
		$Connection.ConnectionString = $ConnectionString
		$Connection.Open()
		$Command = New-Object MySql.Data.MySqlClient.MySqlCommand($Query, $Connection)
		$DataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($Command)
		$DataSet = New-Object System.Data.DataSet
		$RecordCount = $DataAdapter.Fill($DataSet, "data")
		$DataSet.Tables[0]
	}
	Catch {
		Debug "DATABASE ERROR : Unable to run query : $Query $($Error[0])"
	}
	Finally {
		$Connection.Close()
	}
}

Function CheckForUpdates {
	Debug "----------------------------"
	Debug "Checking for script update at GitHub"
	$GitHubVersion = $LocalVersion = $NULL
	$GetGitHubVersion = $GetLocalVersion = $False
	$GitHubVersionTries = 1
	Do {
		Try {
			$GitHubVersion = [decimal](Invoke-WebRequest -UseBasicParsing -Method GET -URI https://raw.githubusercontent.com/palinkas-jo-reggelt/GeoLite2SQL/main/version.txt).Content
			$GetGitHubVersion = $True
		}
		Catch {
			Debug "[ERROR] Obtaining GitHub version : Try $GitHubVersionTries : Obtaining version number: $($Error[0])"
		}
		$GitHubVersionTries++
	} Until (($GitHubVersion -gt 0) -or ($GitHubVersionTries -eq 6))
	If (Test-Path "$PSScriptRoot\version.txt") {
		$LocalVersion = [decimal](Get-Content "$PSScriptRoot\version.txt")
		$GetLocalVersion = $True
	}
	If (($GetGitHubVersion) -and ($GetLocalVersion)) {
		If ($LocalVersion -lt $GitHubVersion) {
			Debug "[INFO] Upgrade to version $GitHubVersion available at https://github.com/palinkas-jo-reggelt/GeoLite2SQL"
			If ($UseHTML) {
				Email "[INFO] Upgrade to version $GitHubVersion available at <a href=`"https://github.com/palinkas-jo-reggelt/GeoLite2SQL`">GitHub</a>"
			} Else {
				Email "[INFO] Upgrade to version $GitHubVersion available at https://github.com/palinkas-jo-reggelt/GeoLite2SQL"
			}
		} Else {
			Debug "Backup & Upload script is latest version: $GitHubVersion"
		}
	} Else {
		If ((-not($GetGitHubVersion)) -and (-not($GetLocalVersion))) {
			Debug "[ERROR] Version test failed : Could not obtain either GitHub nor local version information"
			Email "[ERROR] Version check failed"
		} ElseIf (-not($GetGitHubVersion)) {
			Debug "[ERROR] Version test failed : Could not obtain version information from GitHub"
			Email "[ERROR] Version check failed"
		} ElseIf (-not($GetLocalVersion)) {
			Debug "[ERROR] Version test failed : Could not obtain local install version information"
			Email "[ERROR] Version check failed"
		} Else {
			Debug "[ERROR] Version test failed : Unknown reason - file issue at GitHub"
			Email "[ERROR] Version check failed"
		}
	}
}


<############################
#
#       BEGIN SCRIPT
#
############################>

<#  Clear out any errors  #>
$Error.Clear()

<#  Set file locations  #>
$CountryBlocksIPV4 = "$PSScriptRoot\GeoLite2-Country-CSV\GeoLite2-Country-Blocks-IPv4.csv"
$CountryBlocksConverted = "$PSScriptRoot\GeoLite2-Country-CSV\GeoCountry.csv"
$CountryLocations = "$PSScriptRoot\GeoLite2-Country-CSV\GeoLite2-Country-Locations-$CountryLocationLang.csv"
$LocationsRenamed = "$PSScriptRoot\GeoLite2-Country-CSV\GeoLocations.csv"
$EmailBody = "$PSScriptRoot\Script-Created-Files\EmailBody.txt"
$DebugLog = "$PSScriptRoot\Script-Created-Files\DebugLog.log"

<#	Create folder for temporary script files if it doesn't exist  #>
If (-not(Test-Path "$PSScriptRoot\Script-Created-Files")) {
	md "$PSScriptRoot\Script-Created-Files"
}

<#	Delete old debug log before debugging  #>
If (Test-Path $DebugLog) {Remove-Item -Force -Path $DebugLog}
If (Test-Path $EmailBody) {Remove-Item -Force -Path $EmailBody}
New-Item $DebugLog
New-Item $EmailBody
Write-Output "::: $UploadName Backup Routine $(Get-Date -f D) :::" | Out-File $DebugLog -Encoding ASCII -Append
Write-Output " " | Out-File $DebugLog -Encoding ASCII -Append
If ($UseHTML) {
	Write-Output "
		<!DOCTYPE html><html>
		<head><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0 `" /></head>
		<body style=`"font-family:Arial Narrow`">
		<table>
		<tr><td style='text-align:center;'>::: $UploadName Backup Routine $(Get-Date -f D) :::</td></tr>
		<tr><td>&nbsp;</td></tr>
	" | Out-File $EmailBody -Encoding ASCII -Append
} Else {
	Write-Output "::: $UploadName Backup Routine $(Get-Date -f D) :::" | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
}

<#  Set start time  #>
$StartScriptTime = Get-Date
Debug "GeoIP Update Start"

<#	Delete old files if exist  #>
Debug "----------------------------"
Debug "Deleting old files"
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV") {Remove-Item -Recurse -Force "$PSScriptRoot\GeoLite2-Country-CSV"}
If (Test-Path "$PSScriptRoot\Script-Created-Files\GeoLite2-Country-CSV.zip") {Remove-Item -Force -Path "$PSScriptRoot\Script-Created-Files\GeoLite2-Country-CSV.zip"}

<#	Download latest GeoLite2 data and unzip  #>
Debug "----------------------------"
Debug "Downloading MaxMind data"
$Timer = Get-Date
Try {
	$url = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country-CSV&license_key=$LicenseKey&suffix=zip"
	$output = "$PSScriptRoot\Script-Created-Files\GeoLite2-Country-CSV.zip"
	Start-BitsTransfer -Source $url -Destination $output -ErrorAction Stop
	Debug "MaxMind data successfully downloaded MaxMind data in $(ElapsedTime $Timer)"
	Email "[OK] MaxMind data successfully downloaded"
}
Catch {
	Debug "ERROR : Unable to download MaxMind data : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to download MaxMind data. See error log."
	EmailResults
	Exit
}

$Timer = Get-Date
Try {
	Expand-Archive $output -DestinationPath $PSScriptRoot -ErrorAction Stop
	Debug "MaxMind data successfully unzipped in $(ElapsedTime $Timer)"
	Email "[OK] MaxMind data successfully unzipped"
}
Catch {
	Debug "ERROR : Unable to unzip MaxMind data : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to unzip MaxMind data. See error log."
	EmailResults
	Exit
}

<#	Rename folder so script can find it  #>
Get-ChildItem $PSScriptRoot | Where-Object {$_.PSIsContainer -eq $true} | ForEach {
	If ($_.Name -match 'GeoLite2-Country-CSV_[0-9]{8}') {
		$FolderName = $_.Name
		Rename-Item "$PSScriptRoot\$FolderName" "$PSScriptRoot\GeoLite2-Country-CSV"
	}
}

<# 	If new downloaded folder does not exist or could not be renamed, then throw error  #>
If (-not (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV")){
	Debug "ERROR : Unable to rename data folder : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to rename data folder. See error log."
	EmailResults
	Exit
}

<#  Rename Locations CSV  #>
Try {
	Rename-Item $CountryLocations $LocationsRenamed -ErrorAction Stop
	Debug "Locations CSV successfully renamed"
}
Catch {
	Debug "ERROR : Unable to rename locations CSV : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to rename locations CSV. See error log."
	EmailResults
	Exit
}

<#  Convert CSV for import  #>
Debug "----------------------------"
Debug "Converting CSV"
$Timer = Get-Date
Try {
	& $GeoIP2CSVConverter -block-file="$CountryBlocksIPV4" -output-file="$CountryBlocksConverted" -include-integer-range
	Debug "Country IP CSV successfully converted to integer-range in $(ElapsedTime $Timer)"
	Email "[OK] Converted country block CSV"
}
Catch {
	Debug "ERROR : Unable to convert country IP CSV : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to convert country IP CSV. See error log."
	EmailResults
	Exit
}

<#  Add tables if they don't exist  #>
Debug "----------------------------"
Debug "Drop and recreate database tables"
Try {
	$GCQuery = "
	DROP TABLE IF EXISTS geocountry;
	CREATE TABLE geocountry (
		network_start_integer BIGINT,
		network_last_integer BIGINT,
		geoname_id BIGINT,
		registered_country_geoname_id BIGINT,
		represented_country_geoname_id BIGINT,
		is_anonymous_proxy TINYINT,
		is_satellite_provider TINYINT,
		KEY geoname_id (geoname_id),
		KEY network_start_integer (network_start_integer),
		PRIMARY KEY network_last_integer (network_last_integer)
	) ENGINE=InnoDB DEFAULT CHARSET=utf8
	"
	MySQLQuery $GCQuery

	$GLQuery = "
	DROP TABLE IF EXISTS geolocations;
	CREATE TABLE geolocations (                       
		geoname_id BIGINT,
		locale_code TINYTEXT,
		continent_code TINYTEXT,
		continent_name TINYTEXT,
		country_code TINYTEXT,
		country_name TINYTEXT,
		is_in_european_union TINYINT,
		KEY geoname_id (geoname_id)
	) ENGINE=InnoDB DEFAULT CHARSET=utf8
	"
	MySQLQuery $GLQuery
	Debug "Database tables successfully dropped and created"
	Email "[OK] Database tables successfully dropped"
}
Catch {
	Debug "ERROR : Unable to drop/create database tables : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to drop/create database tables. See error log."
	EmailResults
	Exit
}

<#  Import IP data  #>
$MySQLPasswordString = "-p$MySQLPassword"
$Timer = Get-Date
Debug "----------------------------"
Debug "Import country IP information"
Try {
	& $MySQLImport -h localhost -P 3306 -u $MySQLUserName $MySQLPasswordString --local -v --ignore-lines=1 --fields-terminated-by="," --lines-terminated-by="\n" $MySQLDatabase $CountryBlocksConverted
	Debug "Country IP data imported in $(ElapsedTime $Timer)"
	Email "[OK] Country IP data imported"
}
Catch {
	Debug "ERROR : Unable to convert country IP CSV : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to convert country IP CSV. See error log."
	EmailResults
	Exit
}

<#  Import IP data  #>
$Timer = Get-Date
Debug "----------------------------"
Debug "Import country name information"
Try {
	& $MySQLImport -h localhost -P 3306 -u $MySQLUserName $MySQLPasswordString --local -v --ignore-lines=1 --fields-terminated-by="," --lines-terminated-by="\n" $MySQLDatabase $LocationsRenamed
	Debug "Country name data imported in $(ElapsedTime $Timer)"
	Email "[OK] Country name data imported"
}
Catch {
	Debug "ERROR : Unable to convert country IP CSV : $($Error[0])"
	Debug "ERROR : Quitting Script"
	Email "[ERROR] Failed to convert country IP CSV. See error log."
	EmailResults
	Exit
}

<#########################################
#
#  FINISH UP
#
#########################################>

<#  Check for updates  #>
CheckForUpdates

<#  Now finish up with email results  #>
Debug "----------------------------"
Debug "GeoIP update finished"
Email " "
Email "GeoIP update finish: $(Get-Date -f G)"
Email "Successfully completed update in $(ElapsedTime $StartScriptTime)"
Debug "Successfully completed update in $(ElapsedTime $StartScriptTime)"
If ($UseHTML) {Write-Output "</table></body></html>" | Out-File $EmailBody -Encoding ASCII -Append}
EmailResults