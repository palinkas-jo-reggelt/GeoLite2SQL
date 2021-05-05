<#

.SYNOPSIS
	Install MaxMinds geoip database to database server

.DESCRIPTION
	Downloads and unzips MaxMinds csv geoip data, then populate table on database server with csv data

.FUNCTIONALITY
	1) If geoip table does not exist, it gets created
	2) Deletes old files if existing
	3) Downloads MaxMinds geolite2 csv data and converts it
	4) Loads data into database
	5) Feedback on console and by email on weekly updates

.NOTES
	
	Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)
	
.EXAMPLE
	Example query to return city code and city name from database:
	
		SELECT * 
		FROM (
			SELECT * 
			FROM geocity 
			WHERE INET_ATON('212.186.81.105') <= network_last_integer
			LIMIT 1
		) AS a 
		INNER JOIN geocitylocations AS b on a.geoname_id = b.geoname_id
		WHERE network_start_integer <= INET_ATON('212.186.81.105')
		LIMIT 1;

#>

<#  Include required files  #>
Try {
	.("$PSScriptRoot\GeoLite2SQL-Config.ps1")
	.("$PSScriptRoot\GeoLite2SQL-Functions.ps1")
}
Catch {
	Write-Output "$(Get-Date -f G) : [ERROR] : Unable to load supporting PowerShell Scripts : $($Error[0])" | Out-File "$PSScriptRoot\PSError.log" -Append
}


<###   BEGIN SCRIPT   ###>

<#  Clear out any errors  #>
$Error.Clear()

<#  Set file locations  #>
$CityBlocksIPV4 = "$PSScriptRoot\GeoLite2-City-CSV\GeoLite2-City-Blocks-IPv4.csv"
$CityBlocksConverted = "$PSScriptRoot\GeoLite2-City-CSV\GeoCity.csv"
$CityLocations = "$PSScriptRoot\GeoLite2-City-CSV\GeoLite2-City-Locations-$LocationLanguage.csv"
$CityLocationsRenamed = "$PSScriptRoot\GeoLite2-City-CSV\GeoCityLocations.csv"
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
Email "GeoIP update Start: $(Get-Date -f G)"
Email " "

<#  Check for updates  #>
CheckForUpdates

<#	Delete old MaxMind files if exist  #>
Debug "----------------------------"
Debug "Deleting old files"
If (Test-Path "$PSScriptRoot\GeoLite2-City-CSV") {
	Try {
		Remove-Item -Recurse -Force "$PSScriptRoot\GeoLite2-City-CSV"
		Debug "Folder $PSScriptRoot\GeoLite2-City-CSV successfully deleted"
	}
	Catch {
		Debug "[INFO] : Unable to delete old MaxMind data : $($Error[0])"
		Email "[INFO] Failed to delete old MaxMind data. See error log."
	}
}
If (Test-Path "$PSScriptRoot\Script-Created-Files\GeoLite2-City-CSV.zip") {
	Try {
		Remove-Item -Force -Path "$PSScriptRoot\Script-Created-Files\GeoLite2-City-CSV.zip"
		Debug "Old zip file $PSScriptRoot\Script-Created-Files\GeoLite2-City-CSV.zip successfully deleted"
	}
	Catch {
		Debug "[INFO] : Unable to delete old MaxMind zip file : $($Error[0])"
		Email "[INFO] Failed to delete old MaxMind zip file. See error log."
	}
}

<#	Download latest GeoLite2 data  #>
Debug "----------------------------"
Debug "Downloading MaxMind data"
$Timer = Get-Date
Try {
	$url = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City-CSV&license_key=$LicenseKey&suffix=zip"
	$output = "$PSScriptRoot\Script-Created-Files\GeoLite2-City-CSV.zip"
	Start-BitsTransfer -Source $url -Destination $output -ErrorAction Stop
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
	Expand-Archive $output -DestinationPath $PSScriptRoot -ErrorAction Stop
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
Get-ChildItem $PSScriptRoot | Where-Object {$_.PSIsContainer -eq $true} | ForEach {
	If ($_.Name -match 'GeoLite2-City-CSV_[0-9]{8}') {
		$FolderName = $_.Name
		Rename-Item "$PSScriptRoot\$FolderName" "$PSScriptRoot\GeoLite2-City-CSV"
	}
}

<# 	If new downloaded folder does not exist or could not be renamed, then throw error  #>
If (-not (Test-Path "$PSScriptRoot\GeoLite2-City-CSV")){
	Debug "[ERROR] : Unable to rename data folder : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to rename data folder. See error log."
	EmailResults
	Exit
}

<#  Rename Locations CSV  #>
Try {
	Rename-Item $CityLocations $CityLocationsRenamed -ErrorAction Stop
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
$Query = "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'geocity'"
MySQLQuery $Query | ForEach {
	[int]$CountTables = $_.count
}
If ($CountTables -gt 0) {
	$Query = "SELECT COUNT(*) AS count FROM geocity"
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
[int]$CountIPv4 = 0
$Reader = New-Object IO.StreamReader $CityBlocksIPV4
While($Reader.ReadLine() -ne $NULL) {$CountIPv4++}
$CountIPv4 = $CountIPv4 - 1  # Remove header from count
Debug "Counted $(($CountIPv4).ToString('#,###')) IPv4 records in new CSV in $(ElapsedTime $Timer)"

<#  Convert CSV for import  #>
Debug "----------------------------"
Debug "Converting CSV"
$Timer = Get-Date
Try {
	& $GeoIP2CSVConverter -block-file="$CityBlocksIPV4" -output-file="$CityBlocksConverted" -include-integer-range
	Debug "City IP CSV successfully converted to integer-range in $(ElapsedTime $Timer)"
	Email "[OK] Converted city block CSV"
}
Catch {
	Debug "[ERROR] : Unable to convert city IP CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert city IP CSV. See error log."
	EmailResults
	Exit
}

<#  Drop and add database tables  #>
Debug "----------------------------"
Debug "Drop and recreate database tables"
Try {
	$GCQuery = "
		DROP TABLE IF EXISTS geocity;
		CREATE TABLE geocity (
			network_start_integer BIGINT,
			network_last_integer BIGINT,
			geoname_id BIGINT,
			registered_country_geoname_id BIGINT,
			represented_country_geoname_id BIGINT,
			is_anonymous_proxy TINYINT,
			is_satellite_provider TINYINT,
			postal_code TINYINT,
			latitude DECIMAL(7,4),
			longitude DECIMAL(7,4),
			accuracy_radius TINYINT,
			KEY geoname_id (geoname_id),
			KEY network_start_integer (network_start_integer),
			PRIMARY KEY network_last_integer (network_last_integer)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8;
	"
	MySQLQuery $GCQuery

	$GLQuery = "
		DROP TABLE IF EXISTS geocitylocations;
		CREATE TABLE geocitylocations (
			geoname_id BIGINT,
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

<#  Import IP data  #>
$MySQLPasswordString = "-p$MySQLPassword"
$Timer = Get-Date
Debug "----------------------------"
Debug "Import city IP information"
Try {
	$ImportIP = & $MySQLImport -h localhost -P 3306 -u $MySQLUserName $MySQLPasswordString --local -v --ignore-lines=1 --fields-terminated-by="," --lines-terminated-by="\n" $MySQLDatabase $CityBlocksConverted | Out-String | Where {$_ -match "Records: (?<numrec>\d+)"}
	[int]$CountImport = $Matches.numrec
	Debug "$(($CountImport).ToString('#,###')) city IP records imported in $(ElapsedTime $Timer)"
	Email "[OK] City IP data imported"
}
Catch {
	Debug "[ERROR] : Unable to convert city IP CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert city IP CSV. See error log."
	EmailResults
	Exit
}

<#  Import IP data  #>
$Timer = Get-Date
Debug "----------------------------"
Debug "Import city name information"
Try {
	$ImportCo = & $MySQLImport -h localhost -P 3306 -u $MySQLUserName $MySQLPasswordString --local -v --ignore-lines=1 --fields-terminated-by="," --lines-terminated-by="\n" $MySQLDatabase $CityLocationsRenamed | Out-String | Where {$_ -match "Records: (?<numrec>\d+)"}
	[int]$CountCo = $Matches.numrec
	Debug "$(($CountCo).ToString('#,###')) city name records imported in $(ElapsedTime $Timer)"
	Email "[OK] City name data imported"
}
Catch {
	Debug "[ERROR] : Unable to convert city IP CSV : $($Error[0])"
	Debug "[ERROR] : Quitting Script"
	Email "[ERROR] Failed to convert city IP CSV. See error log."
	EmailResults
	Exit
}

<#########################################
#
#  FINISH UP
#
#########################################>

<#  Now finish up  #>
Debug "----------------------------"
If ($CountImport -eq $CountIPv4) {
	Email "[OK] Successfully imported $(($CountImport).ToString('#,###')) records in $(ElapsedTime $StartScriptTime)"
	Email ("[INFO] Net change of {0:n0} records since last update" -f ($CountDB - $CountImport))
	Debug "Successfully imported $(($CountImport).ToString('#,###')) records in $(ElapsedTime $StartScriptTime)"
	Debug ("[INFO] Net change of {0:n0} records since last update" -f ($CountDB - $CountImport))
} Else {
	If (($CountIPv4 - $CountImport) -lt 0) {$Mismatch = ($CountImport - $CountIPv4)} Else {$Mismatch = ($CountIPv4 - $CountImport)}
	Email "[ERROR] Count mismatched by $(($Mismatch).ToString('#.###')) records"
	Email "$(($CountImport).ToString('#,###')) records imported to database"
	Email "$(($CountIPv4).ToString('#,###')) records in MaxMind CSV"
	Email "Completed update in $(ElapsedTime $StartScriptTime)"
	Debug "[ERROR] record count mismatch:"
	Debug "$(($CountImport).ToString('#,###')) records imported to database"
	Debug "$(($CountIPv4).ToString('#,###')) records in MaxMind CSV"
	Debug "Completed update in $(ElapsedTime $StartScriptTime)"
}

<#  Email results  #>
EmailResults