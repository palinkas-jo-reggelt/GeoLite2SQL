<#

.SYNOPSIS
	Install MaxMind GeoLite2 database to local database server

.DESCRIPTION
	Downloads and unzips MaxMinds csv geoip data, then populates tables on local database

.FUNCTIONALITY
	1) If geoip table does not exist, it gets created
	2) Deletes old files if existing
	3) Downloads MaxMinds geolite2 csv data and converts it
	4) Loads data into database
	5) Feedback on console and by email on weekly updates

.NOTES
	--!!!--   
	Requires user privileges: GRANT FILE ON *.* TO 'db-user'@'%' in order for LOAD DATA INFILE to work!
	Data import will FAIL due to access denied to user without these privileges!
	--!!!--
	
	Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)

	License Key required from MaxMind in order to download data (its free, sign up here: https://www.maxmind.com/en/geolite2/signup)

.PARAMETER SelectType
	Specifies the type of MaxMind data to download and import.
	
	Options are "country" and "city".
	
.EXAMPLE
	Run script as follows:

	C:\path\to\Geolite2SQL.ps1 country
	C:\path\to\Geolite2SQL.ps1 city

.EXAMPLE
	Example queries to return country code and country name from country database:
	
		SELECT country_code, country_name
		FROM (
			SELECT * 
			FROM geocountry 
			WHERE INET6_ATON('212.186.81.105') <= network_last
			LIMIT 1
		) AS a 
		INNER JOIN countrylocations AS b on a.geoname_id = b.geoname_id
		WHERE network_start <= INET6_ATON('212.186.81.105');
		
		SELECT country_code, country_name
		FROM (
			SELECT * 
			FROM geocountry 
			WHERE INET6_ATON('2001:67c:28a4::') <= network_last
			LIMIT 1
		) AS a 
		INNER JOIN countrylocations AS b on a.geoname_id = b.geoname_id
		WHERE network_start <= INET6_ATON('2001:67c:28a4::');

	Example queries to return all columns from city database:
	
		SELECT *
		FROM (
			SELECT * 
			FROM geocity 
			WHERE INET6_ATON('212.186.81.105') <= network_last
			LIMIT 1
		) AS a 
		INNER JOIN citylocations AS b on a.geoname_id = b.geoname_id
		WHERE network_start <= INET6_ATON('212.186.81.105');
		
		SELECT *
		FROM (
			SELECT * 
			FROM geocity 
			WHERE INET6_ATON('2001:67c:28a4::') <= network_last
			LIMIT 1
		) AS a 
		INNER JOIN citylocations AS b on a.geoname_id = b.geoname_id
		WHERE network_start <= INET6_ATON('2001:67c:28a4::');

.LINK
	GitHub Repository: https://github.com/palinkas-jo-reggelt/GeoLite2SQL

#>

Param(
	[string]$SelectType
)

<#  Include required files  #>
Try {
	.("$PSScriptRoot\GeoLite2SQL-Config.ps1")
}
Catch {
	Write-Output "$(Get-Date -f G) : [ERROR] : Unable to load supporting PowerShell Scripts : $($Error[0])" | Out-File "$PSScriptRoot\PSError.log" -Append
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
	Debug "GeoIP update finished"
	Email " "
	Email "GeoIP update finish: $(Get-Date -f G)"
	If ($UseHTML) {
		If ($UseHTML) {Write-Output "</table></body></html>" | Out-File $EmailBody -Encoding ASCII -Append}
	}
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

Function EmailInitError {
	$Body = "Failed to provide proper parameter. Use 'city' or 'country'. Script quit on parameter error."
	$Message = New-Object System.Net.Mail.Mailmessage $EmailFrom, $EmailTo, $Subject, $Body
	$Message.IsBodyHTML = $False
	$SMTP = New-Object System.Net.Mail.SMTPClient $SMTPServer,$SMTPPort
	$SMTP.EnableSsl = $UseSSL
	$SMTP.Credentials = New-Object System.Net.NetworkCredential($SMTPAuthUser, $SMTPAuthPass); 
	$SMTP.Send($Message)
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
	$ConnectionString = "server=" + $MySQLHost + ";port=" + $MySQLPort + ";uid=" + $MySQLUserName + ";pwd=" + $MySQLPassword + ";database=" + $MySQLDatabase + ";SslMode=" + $MySQLSSL + ";Default Command Timeout=" + $MySQLCommandTimeOut + ";Connect Timeout=" + $MySQLConnectTimeout + ";Allow User Variables=True;AllowLoadLocalInfile=true;"
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
		Debug "[ERROR] DATABASE ERROR : Unable to run query : $Query `n$($Error[0])`n$($Error[1])`n$($Error[2])`n$($Error[3])"
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
			$GitHubVersion = [decimal](Invoke-WebRequest -UseBasicParsing -Method GET -URI https://raw.githubusercontent.com/palinkas-jo-reggelt/GeoLite2SQL/master/version.txt).Content
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


<###   BEGIN SCRIPT   ###>
If ($SelectType -notmatch '^[cC][iI][tT][yY]$|^[cC][oO][uU][nN][tT][rR][yY]$') {
	Write-Host "Failed to provide proper parameter. Use 'city' or 'country'."
	Write-Host "Quitting Script"
	EmailInitError
	Exit
} Else {
	If ($SelectType -match 'country') {
		$Type = "Country"
	} Else {
		$Type = "City"
	}
}

<#  Clear out any errors  #>
$Error.Clear()

<#  Set file locations  #>
$DownloadFolder = "$PSScriptRoot\Script-Created-Files\GeoLite2-" + $Type + "-CSV"
$DownloadedZip = "$DownloadFolder.zip"
$BlocksIPV4 = "$DownloadFolder\GeoLite2-" + $Type + "-Blocks-IPv4.csv"
$BlocksIPV6 = "$DownloadFolder\GeoLite2-" + $Type + "-Blocks-IPv6.csv"
$BlocksConvertedIPv4 = "$DownloadFolder\Geo" + $Type + "IPv4.csv"
$BlocksConvertedIPv6 = "$DownloadFolder\Geo" + $Type + "IPv6.csv"
$LangLocations = "$DownloadFolder\GeoLite2-" + $Type + "-Locations-" + $LocationLanguage + ".csv"
$LocationsRenamed = "$DownloadFolder\GeoLocations.csv"
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

<#  Fill debug log header  #>
Write-Output "::: $UploadName Backup Routine $(Get-Date -f D) :::" | Out-File $DebugLog -Encoding ASCII -Append
Write-Output " " | Out-File $DebugLog -Encoding ASCII -Append

<#  Fill email header  #>
If ($UseHTML) {
	Write-Output "
		<!DOCTYPE html><html>
		<head><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0 `" /></head>
		<body style=`"font-family:Arial Narrow`">
		<table>
		<tr><td style='text-align:center;'>::: Geo$Type Update Routine $(Get-Date -f D) :::</td></tr>
		<tr><td>&nbsp;</td></tr>
	" | Out-File $EmailBody -Encoding ASCII -Append
} Else {
	Write-Output "::: Geo$Type Update Routine $(Get-Date -f D) :::" | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
}

<#  Set start time  #>
$StartScriptTime = Get-Date
Debug "GeoIP $Type Update Start"
Email "GeoIP $Type update Start: $(Get-Date -f G)"
Email " "

<#  Check for updates  #>
CheckForUpdates

<#	Delete old MaxMind files if exist  #>
Debug "----------------------------"
Debug "Deleting old files"
If (Test-Path $DownloadFolder) {
	Try {
		Remove-Item -Recurse -Force $DownloadFolder
		Debug "Folder $DownloadFolder successfully deleted"
	}
	Catch {
		Debug "[INFO] : Unable to delete old MaxMind data : $($Error[0])"
		Email "[INFO] Failed to delete old MaxMind data. See error log."
	}
} Else {
	Debug "No old files to delete"
}

<#	Download latest GeoLite2 data  #>
Debug "----------------------------"
Debug "Downloading MaxMind data"
$Timer = Get-Date
Try {
	$URL = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-" + $Type + "-CSV&license_key=" + $LicenseKey + "&suffix=zip"
	Start-BitsTransfer -Source $URL -Destination $DownloadedZip -ErrorAction Stop
	Debug "MaxMind data successfully downloaded in $(ElapsedTime $Timer)"
	Email "[OK] MaxMind data downloaded"
}
Catch {
	Debug "[ERROR] : Unable to download MaxMind data : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to download MaxMind data. See error log."
	EmailResults
	Exit
}

<#	Unzip fresh GeoLite2 data  #>
$Timer = Get-Date
Try {
	Expand-Archive $DownloadedZip -DestinationPath "$PSScriptRoot\Script-Created-Files" -ErrorAction Stop
	Debug "MaxMind data successfully unzipped in $(ElapsedTime $Timer)"
	Email "[OK] MaxMind data unzipped"
}
Catch {
	Debug "[ERROR] : Unable to unzip MaxMind data : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to unzip MaxMind data. See error log."
	EmailResults
	Exit
}

<#	Rename GeoLite2 data folder so script can find it  #>
Get-ChildItem "$PSScriptRoot\Script-Created-Files" | Where-Object {$_.PSIsContainer -eq $true} | ForEach {
	[regex]$strRegEx = "GeoLite2-" + $Type + "-CSV_[0-9]{8}"
	If ($_.Name -match $strRegEx) {
		$FolderName = $_.FullName
		Rename-Item $FolderName $DownloadFolder
	}
}

<# 	If new downloaded folder does not exist or could not be renamed, then throw error  #>
If (-not (Test-Path $DownloadFolder)){
	Debug "[ERROR] : Unable to rename data folder : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to rename data folder. See error log."
	EmailResults
	Exit
}

<#  Rename Locations CSV  #>
Try {
	Rename-Item $LangLocations $LocationsRenamed -ErrorAction Stop
	Debug "Locations CSV successfully renamed"
}
Catch {
	Debug "[ERROR] : Unable to rename locations CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to rename locations CSV. See error log."
	EmailResults
	Exit
}

<#  Count database records  #>
Debug "----------------------------"
Debug "Counting database records for comparison"
$Query = "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'geo" + $Type + "'"
MySQLQuery $Query | ForEach {
	[int]$CountTables = $_.count
}
If ($CountTables -gt 0) {
	$Query = "SELECT COUNT(*) AS count FROM geo" + $Type
	MySQLQuery $Query | ForEach {
		[int]$CountDB = $_.count
	}
	Debug "$(($CountDB).ToString('#,###')) database records prior to starting update"
} Else {
	Debug "No database records to count"
	[int]$CountDB = 0
}

<#  Count CSV records  #>
Debug "----------------------------"
Debug "Counting CSV records for comparison"
$Timer = Get-Date
[int]$CountIPs = 0
$Reader = New-Object IO.StreamReader $BlocksIPV4
While($Reader.ReadLine() -ne $NULL) {$CountIPs++}
$Reader = New-Object IO.StreamReader $BlocksIPV6
While($Reader.ReadLine() -ne $NULL) {$CountIPs++}
$CountIPs = $CountIPs - 2  # Remove headers from count
Debug "Counted $(($CountIPs).ToString('#,###')) records in new IPv4 & IPv6 CSVs in $(ElapsedTime $Timer)"

<#  Convert CSV for import  #>
Debug "----------------------------"
Debug "Converting CSV"
$Timer = Get-Date
Try {
	& $GeoIP2CSVConverter -block-file="$BlocksIPV4" -output-file="$BlocksConvertedIPv4" -include-hex-range
	Debug "Country IPv4 CSV successfully converted to hex-range in $(ElapsedTime $Timer)"
	Email "[OK] Converted IPv4 country block CSV"
}
Catch {
	Debug "[ERROR] : Unable to convert country IPv4 CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert country IPv4 CSV. See error log."
	EmailResults
	Exit
}

$Timer = Get-Date
Try {
	& $GeoIP2CSVConverter -block-file="$BlocksIPV6" -output-file="$BlocksConvertedIPv6" -include-hex-range
	Debug "Country IPv6 CSV successfully converted to hex-range in $(ElapsedTime $Timer)"
	Email "[OK] Converted IPv6 country block CSV"
}
Catch {
	Debug "[ERROR] : Unable to convert country IPv6 CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert country IPv6 CSV. See error log."
	EmailResults
	Exit
}

<#  Drop and add database tables  #>
Debug "----------------------------"
Debug "Drop and recreate database tables"
Try {
	If ($Type -match "country") {
		$GCQuery = "
			DROP TABLE IF EXISTS geocountry;
			CREATE TABLE geocountry (
				network_start VARBINARY(16) NOT NULL,
				network_last VARBINARY(16) NOT NULL,
				geoname_id INT NOT NULL,
				registered_country_geoname_id INT,
				represented_country_geoname_id INT,
				is_anonymous_proxy TINYINT,
				is_satellite_provider TINYINT,
				KEY geoname_id (geoname_id),
				KEY network_start (network_start),
				PRIMARY KEY network_last (network_last)
			) ENGINE=InnoDB DEFAULT CHARSET=utf8
		"
	} Else {
		$GCQuery = "
			DROP TABLE IF EXISTS geocity;
			CREATE TABLE geocity (
				network_start VARBINARY(16) NOT NULL,
				network_last VARBINARY(16) NOT NULL,
				geoname_id INT NOT NULL,
				registered_country_geoname_id INT,
				represented_country_geoname_id INT,
				is_anonymous_proxy TINYINT,
				is_satellite_provider TINYINT,
				postal_code TINYINT,
				latitude DECIMAL(7,4),
				longitude DECIMAL(7,4),
				accuracy_radius TINYINT,
				KEY geoname_id (geoname_id),
				KEY network_start (network_start),
				PRIMARY KEY network_last (network_last)
			) ENGINE=InnoDB DEFAULT CHARSET=utf8;
		"
	}
	MySQLQuery $GCQuery

	If ($Type -match "country") {
		$GLQuery = "
			DROP TABLE IF EXISTS countrylocations;
			CREATE TABLE countrylocations (                       
				geoname_id INT NOT NULL,
				locale_code TINYTEXT,
				continent_code TINYTEXT,
				continent_name TINYTEXT,
				country_code TINYTEXT,
				country_name TINYTEXT,
				is_in_european_union TINYINT,
				KEY geoname_id (geoname_id)
			) ENGINE=InnoDB DEFAULT CHARSET=utf8
		"
	} Else {
		$GLQuery = "
			DROP TABLE IF EXISTS citylocations;
			CREATE TABLE citylocations (
				geoname_id INT NOT NULL,
				locale_code TINYTEXT,
				continent_code TINYTEXT,
				continent_name TINYTEXT,
				country_code TINYTEXT,
				country_name TINYTEXT,
				subdivision_1_iso_code TINYTEXT,
				subdivision_1_name TINYTEXT,
				subdivision_2_iso_code TINYTEXT,
				subdivision_2_name TINYTEXT,
				city_name TINYTEXT,
				metro_code TINYINT,
				time_zone TINYTEXT,
				is_in_european_union TINYINT,
				KEY geoname_id (geoname_id)
			) ENGINE=InnoDB DEFAULT CHARSET=utf8;
		"
	}
	MySQLQuery $GLQuery
	Debug "Database tables successfully dropped and created"
	Email "[OK] Database tables dropped & recreated"
}
Catch {
	Debug "[ERROR] : Unable to drop/create database tables : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to drop/create database tables. See error log."
	EmailResults
	Exit
}

<#  Import IPv4 data  #>
$Timer = Get-Date
Debug "----------------------------"
Debug "Import country IP information"
Try {
	$strFileLocIPv4 = $BlocksConvertedIPv4 -Replace "\\","\\"
	If ($Type -match "country") {
		$ImportIPv4Query = "
			LOAD DATA INFILE '$strFileLocIPv4'
			INTO TABLE geocountry
			FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' IGNORE 1 ROWS
			(@network_start_hex, @network_last_hex, @geoname_id, @registered_country_geoname_id, @represented_country_geoname_id, @is_anonymous_proxy, @is_satellite_provider)
			SET 
				network_start = UNHEX(@network_start_hex),
				network_last = UNHEX(@network_last_hex),
				geoname_id = @geoname_id,
				registered_country_geoname_id = @registered_country_geoname_id,
				represented_country_geoname_id = @represented_country_geoname_id,
				is_anonymous_proxy = @is_anonymous_proxy,
				is_satellite_provider = @is_satellite_provider;
		"
	} Else {
		$ImportIPv4Query = "
			LOAD DATA INFILE '$strFileLocIPv4'
			INTO TABLE geocity
			FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' IGNORE 1 ROWS
			(@network_start_hex, @network_last_hex, @geoname_id, @registered_country_geoname_id, @represented_country_geoname_id, @is_anonymous_proxy, @is_satellite_provider, @postal_code, @latitude, @longitude, @accuracy_radius)
			SET 
				network_start = UNHEX(@network_start_hex),
				network_last = UNHEX(@network_last_hex),
				geoname_id = @geoname_id,
				registered_country_geoname_id = @registered_country_geoname_id,
				represented_country_geoname_id = @represented_country_geoname_id,
				is_anonymous_proxy = @is_anonymous_proxy,
				is_satellite_provider = @is_satellite_provider,
				postal_code = @postal_code,
				latitude = @latitude,
				longitude = @longitude,
				accuracy_radius = @accuracy_radius;
		"
	}
	MySQLQuery $ImportIPv4Query
	DEBUG "[OK] Country IPv4 data imported in $(ElapsedTime $Timer)"
}
Catch {
	Debug "[ERROR] : Unable to convert country IPv4 CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert country IPv4 CSV. See error log."
	EmailResults
	Exit
}

$Timer = Get-Date
Try {
	$strFileLocIPv6 = $BlocksConvertedIPv6 -Replace "\\","\\"
	If ($Type -match "country") {
		$ImportIPv6Query = "
			LOAD DATA INFILE '$strFileLocIPv6'
			INTO TABLE geocountry
			FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' IGNORE 1 ROWS
			(@network_start_hex, @network_last_hex, @geoname_id, @registered_country_geoname_id, @represented_country_geoname_id, @is_anonymous_proxy, @is_satellite_provider)
			SET 
				network_start = UNHEX(@network_start_hex),
				network_last = UNHEX(@network_last_hex),
				geoname_id = @geoname_id,
				registered_country_geoname_id = @registered_country_geoname_id,
				represented_country_geoname_id = @represented_country_geoname_id,
				is_anonymous_proxy = @is_anonymous_proxy,
				is_satellite_provider = @is_satellite_provider;
		"
	} Else {
		$ImportIPv6Query = "
			LOAD DATA INFILE '$strFileLocIPv6'
			INTO TABLE geocity
			FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' IGNORE 1 ROWS
			(@network_start_hex, @network_last_hex, @geoname_id, @registered_country_geoname_id, @represented_country_geoname_id, @is_anonymous_proxy, @is_satellite_provider, @postal_code, @latitude, @longitude, @accuracy_radius)
			SET 
				network_start = UNHEX(@network_start_hex),
				network_last = UNHEX(@network_last_hex),
				geoname_id = @geoname_id,
				registered_country_geoname_id = @registered_country_geoname_id,
				represented_country_geoname_id = @represented_country_geoname_id,
				is_anonymous_proxy = @is_anonymous_proxy,
				is_satellite_provider = @is_satellite_provider,
				postal_code = @postal_code,
				latitude = @latitude,
				longitude = @longitude,
				accuracy_radius = @accuracy_radius;
		"
	}
	MySQLQuery $ImportIPv6Query
	DEBUG "[OK] Country IPv6 data imported in $(ElapsedTime $Timer)"
}
Catch {
	Debug "[ERROR] : Unable to convert country IPv6 CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert country IPv6 CSV. See error log."
	EmailResults
	Exit
}

<#  Import country name data  #>
$Timer = Get-Date
Try {
	$strFileLocName = $LocationsRenamed -Replace "\\","\\"
	If ($Type -match "country") {
		$ImportLocQuery = "
			LOAD DATA INFILE '$strFileLocName'
			INTO TABLE countrylocations
			FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' IGNORE 1 ROWS
			(@geoname_id, @locale_code, @continent_code, @continent_name, @country_iso_code, @country_name, @is_in_european_union)
			SET
				geoname_id = @geoname_id, 
				locale_code = @locale_code, 
				continent_code = @continent_code, 
				continent_name = @continent_name, 
				country_code = @country_iso_code, 
				country_name = @country_name, 
				is_in_european_union = @is_in_european_union;
		"
	} Else {
		$ImportLocQuery = "
			LOAD DATA INFILE '$strFileLocName'
			INTO TABLE citylocations
			FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' IGNORE 1 ROWS
			(@geoname_id, @locale_code, @continent_code, @continent_name, @country_iso_code, @country_name, @subdivision_1_iso_code, @subdivision_1_name, @subdivision_2_iso_code, @subdivision_2_name, @city_name, @metro_code, @time_zone, @is_in_european_union)
			SET 
				geoname_id = @geoname_id, 
				locale_code = @locale_code, 
				continent_code = @continent_code, 
				continent_name = @continent_name, 
				country_code = @country_iso_code, 
				country_name = @country_name, 
				subdivision_1_iso_code = @subdivision_1_iso_code, 
				subdivision_1_name = @subdivision_1_name, 
				subdivision_2_iso_code = @subdivision_2_iso_code, 
				subdivision_2_name = @subdivision_2_name, 
				city_name = @city_name, 
				metro_code = @metro_code, 
				time_zone = @time_zone, 
				is_in_european_union = @is_in_european_union;
		"
	}
	MySQLQuery $ImportLocQuery
	DEBUG "[OK] Country name data imported in $(ElapsedTime $Timer)"
}
Catch {
	Debug "[ERROR] : Unable to convert country name CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert country name CSV. See error log."
	EmailResults
	Exit
}

$CountImportSQL = "SELECT COUNT(*) AS count FROM geo" + $Type + ";"
MySQLQuery $CountImportSQL | ForEach {
	[int]$CountImport = $_.count
}

<#########################################
#
#  FINISH UP
#
#########################################>

<#  Now finish up  #>
Debug "----------------------------"
If ($CountImport -eq $CountIPs) {
	Email "[OK] Successfully imported $(($CountImport).ToString('#,###')) records"
	Email "[OK] Finished update in $(ElapsedTime $StartScriptTime)"
	Email ("[INFO] Net change of {0:n0} records since last update" -f ($CountImport - $CountDB))
	Debug "Successfully imported $(($CountImport).ToString('#,###')) records"
	Debug "Finished update in $(ElapsedTime $StartScriptTime)"
	Debug ("[INFO] Net change of {0:n0} records since last update" -f ($CountImport - $CountDB))
} Else {
	If (($CountIPs - $CountImport) -lt 0) {$Mismatch = ($CountImport - $CountIPs)} Else {$Mismatch = ($CountIPs - $CountImport)}
	Email "[ERROR] Count mismatched by $(($Mismatch).ToString('#.###')) records"
	Email "$(($CountImport).ToString('#,###')) records imported to database"
	Email "$(($CountIPs).ToString('#,###')) records in MaxMind CSV"
	Email "Completed update in $(ElapsedTime $StartScriptTime)"
	Debug "[ERROR] record count mismatch:"
	Debug "$(($CountImport).ToString('#,###')) records imported to database"
	Debug "$(($CountIPs).ToString('#,###')) records in MaxMind CSV"
	Debug "Completed update in $(ElapsedTime $StartScriptTime)"
}

<#  Email results  #>
EmailResults