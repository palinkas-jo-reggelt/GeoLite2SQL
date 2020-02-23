<#

.SYNOPSIS
	Install MaxMindas geoip database to database server

.DESCRIPTION
	Downloads and unzips MaxMinds csv geoip data, then populate table on database server with csv data

.FUNCTIONALITY
	1) If geoip table does not exist, it gets created
	2) Deletes old files if existing, renames previously "new" "old" in order to compare
	3) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
	4) Compares new and old data for incremental changes
	5) Reads IPv4 cvs data, then calculates the lowest and highest IP from each network in the database
	6) Deletes obsolete records
	7) Inserts lowest and highest IP in range and geoname_id from IPv4 cvs file
	8) Reads geo-name cvs file and updates each record with country code and country name based on the geoname_id
	9) Includes various error checking to keep from blowing up a working database on error
	10) Feedback on console on initial database load, then by email on weekly updates.

.NOTES
	* Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)
	* Initial loading of the database takes over one hour - subsequent updates are incremental, so they only take a few minutes
	
.EXAMPLE
	Example query to return countrycode and countryname from database:
	
	SELECT countrycode, countryname FROM (SELECT * FROM geo_ip WHERE INET_ATON('125.64.94.220') <= maxipaton LIMIT 1) AS A WHERE minipaton <= INET_ATON('125.64.94.220')

#>

# Include required files
Try {
	.("$PSScriptRoot\Config.ps1")
	.("$PSScriptRoot\CommonCode.ps1")
}
Catch {
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to load supporting PowerShell Scripts : $query `n$Error[0]" | out-file "$PSScriptRoot\PSError.log" -append
}

############################
#
#       BEGIN SCRIPT
#
############################

$ErrorLog = "$PSScriptRoot\ErrorLog.log"
$MMcsv = "$PSScriptRoot\Script-Created-Files\CSV-MM.csv"
$DBcsv = "$PSScriptRoot\Script-Created-Files\CSV-DB.csv"
$ToAddIPv4 = "$PSScriptRoot\Script-Created-Files\ToAddIPv4.csv"
$ToDelIPv4 = "$PSScriptRoot\Script-Created-Files\ToDelIPv4.csv"
$CountryBlocksIPV4 = "$PSScriptRoot\GeoLite2-Country-CSV\GeoLite2-Country-Blocks-IPv4.csv"
$CountryLocations = "$PSScriptRoot\GeoLite2-Country-CSV\GeoLite2-Country-Locations-$CountryLocationLang.csv"
$EmailBody = "$PSScriptRoot\Script-Created-Files\EmailBody.txt"

#	Create ConsolidateRules folder if it doesn't exist
If (-not(Test-Path "$PSScriptRoot\Script-Created-Files")) {
	md "$PSScriptRoot\Script-Created-Files"
}

#	Delete old files if exist
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV") {Remove-Item -Recurse -Force "$PSScriptRoot\GeoLite2-Country-CSV"}
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV.zip") {Remove-Item -Force -Path "$PSScriptRoot\GeoLite2-Country-CSV.zip"}
If (Test-Path $EmailBody) {Remove-Item -Force -Path $EmailBody}
If (Test-Path $MMcsv) {Remove-Item -Force -Path $MMcsv}
If (Test-Path $DBcsv) {Remove-Item -Force -Path $DBcsv}
If (Test-Path $ToAddIPv4) {Remove-Item -Force -Path $ToAddIPv4}
If (Test-Path $ToDelIPv4) {Remove-Item -Force -Path $ToDelIPv4}
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-New") {Rename-Item -Path "$PSScriptRoot\GeoLite2-Country-CSV-New" "$PSScriptRoot\GeoLite2-Country-CSV-Old"}

$StartTime = (Get-Date -f G)
Write-Output "GeoIP update start: $StartTime" | Out-File $EmailBody -Encoding ASCII -Append

#	Check to make sure files deleted
If ((Test-Path $ToAddIPv4) -or (Test-Path $ToDelIPv4)){
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Failed to delete old ToDelIPv4.csv and/or ToAddIPv4.csv" | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Write-Output "GeoIP update failed to delete old files. See error log." | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

#	Create new comparison CSVs
New-Item $ToAddIPv4 -value "`"network`",`"geoname_id`"`n"  -ItemType "file"
New-Item $ToDelIPv4 -value "`"network`",`"geoname_id`"`n"  -ItemType "file"

#	Check to make sure new comparison CSVs created
If ((-not (Test-Path $ToAddIPv4)) -or (-not (Test-Path $ToDelIPv4))){
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : $ToAddIPv4 and/or $ToDelIPv4 do not exist" | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Write-Output "GeoIP update failed: Failed to create new ToAdd/ToDel. See error log." | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

#	Download latest GeoLite2 data and unzip
Try {
	$url = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country-CSV&license_key=$LicenseKey&suffix=zip"
	$output = "$PSScriptRoot\GeoLite2-Country-CSV.zip"
	Start-BitsTransfer -Source $url -Destination $output -ErrorAction Stop
	Expand-Archive $output -DestinationPath $PSScriptRoot -ErrorAction Stop
}
Catch {
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to download and/or unzip : `n$Error[0]" | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Write-Output "GeoIP update failed to download or unzip maxminds data zip file. See error log  : `n$Error[0]" | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

#	Rename folder so script can find it
Get-ChildItem $PSScriptRoot | Where-Object {$_.PSIsContainer -eq $true} | ForEach {
	If ($_.Name -match 'GeoLite2-Country-CSV_[0-9]{8}') {
		$FolderName = $_.Name
		Rename-Item "$PSScriptRoot\$FolderName" "$PSScriptRoot\GeoLite2-Country-CSV"
	}
}

# If new downloaded folder does not exist or could not be renamed, then throw error
If (-not (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV")){
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : $PSScriptRoot\GeoLite2-Country-CSV-New does not exist" | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Write-Output "GeoIP update failed at folder rename. See error log." | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

CreateTablesIfNeeded

#	If database previously loaded then use ToAdd/ToDel to make incremental changes - otherwise, load entire CSV into database
#	First, check to see database has previously loaded entries
$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
RunSQLQuery($Query) | ForEach {
	$EntryCount = $_.numrows
}

############################
#
#    INCREMENTAL UPDATE
#
############################

#	If pass 2 tests: exists exists new folder, database previously populated - THEN proceed to load table from incremental
If ((Test-Path "$PSScriptRoot\GeoLite2-Country-CSV") -and ($EntryCount -gt 0)){

	Write-Host "Loading CountryBlocks CSV"
	#	Dump relevant MaxMind data into comparison csv
	$MMMakeComparisonCSV = Import-CSV -Path $CountryBlocksIPV4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
	Write-Host "CSV Loaded"
	Write-Host "Exporting to aux CSV"
	$MMMakeComparisonCSV | Select-Object -Property network,@{Name = 'geoname_id'; Expression = {If([string]::IsNullOrWhiteSpace($_.geoname_id)){$_.registered_country_geoname_id} Else {$_.geoname_id}}} | Export-CSV -Path $MMcsv
	Write-Host "CSV Exported"

	$TotalLinesCountryBlocks = $MMMakeComparisonCSV.Count - 1
	
	Write-Host "Loading entries from DB"
	#	Dump relevant database data into comparison csv
	$Query = "SELECT network, geoname_id FROM $GeoIPTable"
	RunSQLQuery($Query) | Export-CSV -Path $DBcsv
	Write-Host "Entries Loaded"

	#	Compare database and MaxMind data for changes

	If ((Test-Path $MMcsv) -and (Test-Path $DBcsv)){
		Write-Host "Comparing entries"
		Compare-Object -ReferenceObject $(Get-Content $DBcsv) -DifferenceObject $(Get-Content $MMcsv) | ForEach-Object {
			If ($_.SideIndicator -eq '=>') {
				Write-Output $_.InputObject | Out-File $ToAddIPv4 -Encoding ASCII -Append
			} Else {
				Write-Output $_.InputObject | Out-File $ToDelIPv4 -Encoding ASCII -Append
			}
		}
		Write-Host "Comparing terminated"
	}

	Try {
		
		$RegexNetwork = '((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\/([0-2][0-9]|3[0-2])))'
		
		Write-Host "Loading networks to delete from CSV"
		# 	Read ToDelIPv4 cvs file, delete matches from database
		$GeoIPObjects = Import-CSV -Path $ToDelIPv4 -Delimiter "," -Header network,geoname_id
		Write-Host "CSV loaded"
		
		$TotalLines = $GeoIPObjects.Count
		$LinesToDel = $TotalLines - 2
		$LineCounter = 0
		$StartTime = (Get-Date -f G)

		$GeoIPObjects | ForEach-Object {

			$LineCounter = $LineCounter + 1
		
			$CurrentTime = (Get-Date -f G)
			$OperationTime = New-Timespan $StartTime $CurrentTime
			$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
			$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
			$percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
			Write-Progress -Activity "Processing lines - deleting old networks" -Status "$percent% Complete:" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;
			
			$Network = $_.network
			$GeoNameID = $_.geoname_id
			If ($Network -match $RegexNetwork){
				$Query = "DELETE FROM $GeoIPTable WHERE network='$Network'"
				RunSQLQuery($Query)
			}
		}

		Write-Host "Loading networks to add from CSV"
		# 	Read ToAddIPv4 cvs file, convert CIDR network address to lowest and highest IPs in range, then insert into database
		$GeoIPObjects = Import-CSV -Path $ToAddIPv4 -Delimiter "," -Header network,geoname_id
		Write-Host "CSV loaded"

		$TotalLines = $GeoIPObjects.Count
		$LinesToAdd = $TotalLines - 3
		$LineCounter = 0
		$StartTime = (Get-Date -f G)
		
		$GeoIPObjects | ForEach-Object {

			$LineCounter = $LineCounter + 1
		
			$CurrentTime = (Get-Date -f G)
			$OperationTime = New-Timespan $StartTime $CurrentTime
			$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
			$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
			$percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
			Write-Progress -Activity "Processing lines - inserting new networks" -Status "$percent% Complete:" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;		
			
			$Network = $_.network
			$GeoNameID = $_.geoname_id
			If ($Network -match $RegexNetwork){
				Get-IPv4NetworkInfo -CIDRAddress $Network | ForEach-Object {
					$MinIP = $_.NetworkAddress
					$MaxIP = $_.BroadcastAddress
				}
				$Query = "INSERT INTO $GeoIPTable (network,minip,maxip,geoname_id,minipaton,maxipaton,countrycode,countryname) VALUES ('$Network','$MinIP','$MaxIP','$GeoNameID',$(DBIpStringToIntField $MinIP), $(DBIpStringToIntField $MaxIP),'','')"
				RunSQLQuery($Query)
			}
		}

		Write-Host "Loading CountryLocations CSV"
		# 	Read country info cvs and insert into database
		$GeoIPNameObjects = Import-CSV -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
		Write-Host "CSV loaded"

		$TotalLines = $GeoIPNameObjects.Count
		$LineCounter = 0
		$StartTime = (Get-Date -f G)

		$GeoIPNameObjects | ForEach-Object {

		$LineCounter = $LineCounter + 1
		
			$CurrentTime = (Get-Date -f G)
			$OperationTime = New-Timespan $StartTime $CurrentTime
			$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
			$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
			$percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
			Write-Progress -Activity "Processing lines - updating countries name" -Status "$percent% Complete:" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;		
			
			$GeoNameID = $_.geoname_id
			$CountryCode = $_.country_iso_code
			$CountryName = $_.country_name
			If ($GeoNameID -notmatch 'geoname_id'){
				$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID' AND countrycode='' AND countryname=''"
				RunSQLQuery($Query)
			}
		}
	}
	Catch {
		Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Incremental update failed : `n$Error[0]" | out-file $ErrorLog -append
		Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
		Write-Output "GeoIP update failed at loading database. See error log." | Out-File $EmailBody -Encoding ASCII -Append
		EmailResults
		Exit
	}

	#	Count lines in new country block csv
	[int]$LinesNewCSV = $TotalLinesCountryBlocks #Account for 1 header line

	#	Count records in database (post-update)
	$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
	RunSQLQuery($Query) | ForEach {
		$DBCountAfterIncrUpdate = $_.numrows
	}

	#	Count lines in "ToAdd" and "ToDel" csv's
	#[int]$LinesToDel = ([Linq.Enumerable]::Count([System.IO.File]::ReadLines("$ToDelIPv4")) - 2) #Account for 2 header lines
	#[int]$LinesToAdd = ([Linq.Enumerable]::Count([System.IO.File]::ReadLines("$ToAddIPv4")) - 3) #Account for 3 header lines

	#	Report Results
	Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output ("{0,7} : (A) Records in database prior to update" -f ($EntryCount).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append

	Write-Output ("{0,7} : (B) Records tabulated to be removed from database" -f ($LinesToDel).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append

	Write-Output ("{0,7} : (C) Records tabulated to be inserted into database" -f ($LinesToAdd).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output "======= :" | Out-File $EmailBody -Encoding ASCII -Append

	[int]$SumOldDelAdd = ($EntryCount - $LinesToDel + $LinesToAdd)
	Write-Output ("{0,7} : Tabulated (A - B + C) number of records (should match NEW IPV4 csv)" -f ($SumOldDelAdd).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output "======= :" | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output ("{0,7} : Actual number of records in NEW IPV4 csv" -f ($LinesNewCSV).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output "======= :" | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output ("{0,7} : Queried number of records in database (should match NEW IPV4 csv)" -f ($DBCountAfterIncrUpdate).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append

	#	Determine success or failure
	If (($SumOldDelAdd -ne $LinesNewCSV) -or ($DBCountAfterIncrUpdate -ne $LinesNewCSV)) {
		Write-Output "GeoIP database update ***FAILED**. Record Count Mismatch" | Out-File $EmailBody -Encoding ASCII -Append
	} Else {
		Write-Output "GeoIP database update SUCCESS. All records accounted for." | Out-File $EmailBody -Encoding ASCII -Append
	}
}

#########################################
#
#  INITIAL DATABASE LOADING (FIRST RUN)
#
#########################################

#	If pass 2 tests: exists new folder, database UNpopulated - then proceed to load table as new
ElseIf ((Test-Path "$PSScriptRoot\GeoLite2-Country-CSV") -and ($EntryCount -eq 0)){

	Write-Host ""
	Write-Host "Please be patient. Initially loading the database can take two hours or more."
	Write-Host ""

	Try {

		Write-Host "Loading CountryBlocks CSV"
		# 	Read cvs file, convert CIDR network address to lowest and highest IPs in range, then insert into database
		$GeoIPObjects = Import-CSV -Path $CountryBlocksIPV4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
		Write-Host "CSV loaded"
		
		$TotalLines = $GeoIPObjects.Count
		$TotalLinesCountryBlocks = $TotalLines - 1 #must subtract header line
		$LineCounter = 0
		
		$StartTime = (Get-Date -f G)

		$SecondsRemaining = 0
		$GeoIPObjects | ForEach-Object {
			$LineCounter = $LineCounter + 1
		
			If ($LineCounter % 100 -eq 1 -or $LineCounter -eq 1){
				$CurrentTime = (Get-Date -f G)
				$OperationTime = New-Timespan $StartTime $CurrentTime
				$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
				$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
				$percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
				Write-Progress -Activity "Processing lines" -Status "$percent% Complete:" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;
			}
			
			$Network = $_.network
			IF([string]::IsNullOrWhiteSpace($_.geoname_id)){
				$GeoNameID = $_.registered_country_geoname_id
			} Else {
				$GeoNameID = $_.geoname_id
			}
			If ($GeoNameID -notmatch 'geoname_id'){
				Get-IPv4NetworkInfo -CIDRAddress $Network | ForEach-Object {
					$MinIP = $_.NetworkAddress
					$MaxIP = $_.BroadcastAddress
				}
				$Query = "INSERT INTO $GeoIPTable (network,minip,maxip,geoname_id,minipaton,maxipaton,countrycode,countryname) VALUES ('$Network','$MinIP','$MaxIP','$GeoNameID',$(DBIpStringToIntField  $MinIP),$(DBIpStringToIntField $MaxIP),'','')"
				RunSQLQuery($Query)
			}
		}

		Write-Host "Loading CountryLocations CSV"
		# 	Read country info cvs and insert into database
		$GeoIPNameObjects = Import-CSV -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
		Write-Host "CSV loaded"
		
		$TotalLines = $GeoIPNameObjects.Count
		$LineCounter = 0

		$StartTime = (Get-Date -f G)

		$GeoIPNameObjects | ForEach-Object {

			$LineCounter = $LineCounter + 1
			
			If ($LineCounter % 10 -eq 1 -or $LineCounter -eq 1){
				$CurrentTime = (Get-Date -f G)
				$OperationTime = New-Timespan $StartTime $CurrentTime
				$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
				$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
				$percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
				Write-Progress -Activity "Processing lines" -Status "$percent% Complete:" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;
			}

			$GeoNameID = $_.geoname_id
			$CountryCode = $_.country_iso_code
			$CountryName = $_.country_name
			#IF ip is not allocated to a specific country, put continent info
			If ([string]::IsNullOrWhiteSpace($CountryName))
			{
				$CountryName = $_.continent_name
				$CountryCode = $_.continent_code
			}
	
			If ($GeoNameID -notmatch 'geoname_id'){
				$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID' AND countrycode='' AND countryname=''"
				RunSQLQuery($Query)
			} 
		}
	}
	Catch {
		Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Full (new) db load failed : `n$Error[0]" | out-file $ErrorLog -append
		Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
		Write-Host "GeoIP update failed with database error. See error log."
		Exit
	}

	#	Count lines in NEW IPv4 csv
	$Lines = $TotalLinesCountryBlocks
	Write-Host "Records in MaxMinds csv: $Lines"

	#	Count records in database
	$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
	RunSQLQuery($Query) | ForEach {
		$EntryCount = $_.numrows
	}
	Write-Host "Records in database: $EntryCount"

	#	Check if number of records in csv and database match to determine success or failure
	$Diff = ([int]$Lines - [int]$EntryCount)
	If ($EntryCount -eq $Lines) {
		Write-Host "Database successfully loaded."
	} Else {
		Write-Host "Database loading **FAILED**."
		Write-Host "Failed to load $Diff records into database."
		Write-Host " "
		Write-Host "GeoIP update failed to load the correct number of records. See error log."
		Exit
	}

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
}

#########################################
#
#  NO DATABASE LOADING (ERROR)
#
#########################################

#	Else Exit since neither incremental nor new load can be accomplished
Else {
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to complete database load : Either Old or New data doesn't exist." | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | Out-File $ErrorLog -append
	Write-Output "GeoIP update failed: Either Old or New data doesn't exist. See error log." | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

#########################################
#
#  FINISH UP
#
#########################################

#	Now finish up with email results
Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
Write-Output "GeoIP update successful." | Out-File $EmailBody -Encoding ASCII -Append
Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append

$EndTime = (Get-Date -f G)
Write-Output "GeoIP update finish: $EndTime" | Out-File $EmailBody -Encoding ASCII -Append
$OperationTime = New-Timespan $StartTime $EndTime
If (($Duration).Hours -eq 1) {$sh = ""} Else {$sh = "s"}
If (($Duration).Minutes -eq 1) {$sm = ""} Else {$sm = "s"}
If (($Duration).Seconds -eq 1) {$ss = ""} Else {$ss = "s"}
Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
Write-Output ("Completed update in {0:%h} hour$sh {0:%m} minute$sm {0:%s} second$ss" -f $OperationTime) | Out-File $EmailBody -Encoding ASCII -Append

EmailResults