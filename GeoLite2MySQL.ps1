<#

.SYNOPSIS
	Install MaxMindas geoip database on MySQL

.DESCRIPTION
	Download and unzip MaxMinds cvs geoip data, then populate MySQL with csv data

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

### MySQL Variables #############################
                                                #
$GeoIPTable         = "geo_ip"                  #
$MySQLAdminUserName = 'geoip'                   #
$MySQLAdminPassword = 'supersecretpassword'     #
$MySQLDatabase      = 'geoip'                   #
$MySQLHost          = 'localhost'               #
                                                #
### Email Variables #############################
                                                #
$EmailFrom          = "sender@gmail.com"        #
$EmailTo            = "recipient@mydomain.tld"  #
$SMTPServer         = "smtp.gmail.com"          #
$SMTPAuthUser       = "sender@gmail.com"        #
$SMTPAuthPass       = "supersecretpassword"     #
                                                #
#################################################

Function EmailResults {
	$Subject = "GeoIP Update Results" 
	$Body = (Get-Content -Path $EmailBody | Out-String )
	$SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer, 587) 
	$SMTPClient.EnableSsl = $true 
	$SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SMTPAuthUser, $SMTPAuthPass); 
	$SMTPClient.Send($EmailFrom, $EmailTo, $Subject, $Body)
}

# https://www.quadrotech-it.com/blog/querying-mysql-from-powershell/
Function MySQLQuery($Query) {
	$DBErrorLog = "$PSScriptRoot\DBError.log"
	$ConnectionString = "server=" + $MySQLHost + ";port=3306;uid=" + $MySQLAdminUserName + ";pwd=" + $MySQLAdminPassword + ";database=" + $MySQLDatabase
	Try {
	  [void][System.Reflection.Assembly]::LoadWithPartialName("MySql.Data")
	  $Connection = New-Object MySql.Data.MySqlClient.MySqlConnection
	  $Connection.ConnectionString = $ConnectionString
	  $Connection.Open()
	  $Command = New-Object MySql.Data.MySqlClient.MySqlCommand($Query, $Connection)
	  $DataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($Command)
	  $DataSet = New-Object System.Data.DataSet
	  $RecordCount = $dataAdapter.Fill($dataSet, "data")
	  $DataSet.Tables[0]
	  }
	Catch {
	  Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to run query : $query `n$Error[0]" | out-file $DBErrorLog -append
	}
	Finally {
	  $Connection.Close()
	}
}

# https://www.ryandrane.com/2016/05/getting-ip-network-information-powershell/
Function Get-IPv4NetworkInfo
{
    Param
    (
        [Parameter(ParameterSetName="IPandMask",Mandatory=$true)] 
        [ValidateScript({$_ -match [ipaddress]$_})] 
        [System.String]$IPAddress,

        [Parameter(ParameterSetName="IPandMask",Mandatory=$true)] 
        [ValidateScript({$_ -match [ipaddress]$_})] 
        [System.String]$SubnetMask,

        [Parameter(ParameterSetName="CIDR",Mandatory=$true)] 
        [ValidateScript({$_ -match '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/([0-9]|[0-2][0-9]|3[0-2])$'})]
        [System.String]$CIDRAddress,

        [Switch]$IncludeIPRange
    )

    # If @CIDRAddress is set
    if($CIDRAddress)
    {
         # Separate our IP address, from subnet bit count
        $IPAddress, [int32]$MaskBits =  $CIDRAddress.Split('/')

        # Create array to hold our output mask
        $CIDRMask = @()

        # For loop to run through each octet,
        for($j = 0; $j -lt 4; $j++)
        {
            # If there are 8 or more bits left
            if($MaskBits -gt 7)
            {
                # Add 255 to mask array, and subtract 8 bits 
                $CIDRMask += [byte]255
                $MaskBits -= 8
            }
            else
            {
                # bits are less than 8, calculate octet bits and
                # zero out our $MaskBits variable.
                $CIDRMask += [byte]255 -shl (8 - $MaskBits)
                $MaskBits = 0
            }
        }

        # Assign our newly created mask to the SubnetMask variable
        $SubnetMask = $CIDRMask -join '.'
    }

    # Get Arrays of [Byte] objects, one for each octet in our IP and Mask
    $IPAddressBytes = ([ipaddress]::Parse($IPAddress)).GetAddressBytes()
    $SubnetMaskBytes = ([ipaddress]::Parse($SubnetMask)).GetAddressBytes()

    # Declare empty arrays to hold output
    $NetworkAddressBytes   = @()
    $BroadcastAddressBytes = @()
    $WildcardMaskBytes     = @()

    # Determine Broadcast / Network Addresses, as well as Wildcard Mask
    for($i = 0; $i -lt 4; $i++)
    {
        # Compare each Octet in the host IP to the Mask using bitwise
        # to obtain our Network Address
        $NetworkAddressBytes +=  $IPAddressBytes[$i] -band $SubnetMaskBytes[$i]

        # Compare each Octet in the subnet mask to 255 to get our wildcard mask
        $WildcardMaskBytes +=  $SubnetMaskBytes[$i] -bxor 255

        # Compare each octet in network address to wildcard mask to get broadcast.
        $BroadcastAddressBytes += $NetworkAddressBytes[$i] -bxor $WildcardMaskBytes[$i] 
    }

    # Create variables to hold our NetworkAddress, WildcardMask, BroadcastAddress
    $NetworkAddress   = $NetworkAddressBytes -join '.'
    $BroadcastAddress = $BroadcastAddressBytes -join '.'
    $WildcardMask     = $WildcardMaskBytes -join '.'

    # Now that we have our Network, Widcard, and broadcast information, 
    # We need to reverse the byte order in our Network and Broadcast addresses
    [array]::Reverse($NetworkAddressBytes)
    [array]::Reverse($BroadcastAddressBytes)

    # We also need to reverse the array of our IP address in order to get its
    # integer representation
    [array]::Reverse($IPAddressBytes)

    # Next we convert them both to 32-bit integers
    $NetworkAddressInt   = [System.BitConverter]::ToUInt32($NetworkAddressBytes,0)
    $BroadcastAddressInt = [System.BitConverter]::ToUInt32($BroadcastAddressBytes,0)
    $IPAddressInt        = [System.BitConverter]::ToUInt32($IPAddressBytes,0)

    #Calculate the number of hosts in our subnet, subtracting one to account for network address.
    $NumberOfHosts = ($BroadcastAddressInt - $NetworkAddressInt) - 1

    # Declare an empty array to hold our range of usable IPs.
    $IPRange = @()

    # If -IncludeIPRange specified, calculate it
    if ($IncludeIPRange)
    {
        # Now run through our IP range and figure out the IP address for each.
        For ($j = 1; $j -le $NumberOfHosts; $j++)
        {
            # Increment Network Address by our counter variable, then convert back
            # lto an IP address and extract as string, add to IPRange output array.
            $IPRange +=[ipaddress]([convert]::ToDouble($NetworkAddressInt + $j)) | Select-Object -ExpandProperty IPAddressToString
        }
    }

    # Create our output object
    $obj = New-Object -TypeName psobject

    # Add our properties to it
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "IPAddress"           -Value $IPAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "SubnetMask"          -Value $SubnetMask
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "NetworkAddress"      -Value $NetworkAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "BroadcastAddress"    -Value $BroadcastAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "WildcardMask"        -Value $WildcardMask
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "NumberOfHostIPs"     -Value $NumberOfHosts
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "IPRange"             -Value $IPRange

    # Return the object
    return $obj
}

############################
#
#       BEGIN SCRIPT
#
############################

$ErrorLog = "$PSScriptRoot\ErrorLog.log"
$ToAddIPv4 = "$PSScriptRoot\ToAddIPv4.csv"
$ToDelIPv4 = "$PSScriptRoot\ToDelIPv4.csv"
$CountryBlocksIPV4 = "$PSScriptRoot\GeoLite2-Country-CSV-New\GeoLite2-Country-Blocks-IPv4.csv"
$CountryBlocksIPV4Old = "$PSScriptRoot\GeoLite2-Country-CSV-Old\GeoLite2-Country-Blocks-IPv4.csv"
$CountryLocations = "$PSScriptRoot\GeoLite2-Country-CSV-Old\GeoLite2-Country-Locations-en.csv"
$EmailBody = "$PSScriptRoot\Results.txt"

#	Delete old files if exist
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-Old") {Remove-Item -Recurse -Force "$PSScriptRoot\GeoLite2-Country-CSV-Old"}
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV.zip") {Remove-Item -Force -Path "$PSScriptRoot\GeoLite2-Country-CSV.zip"}
If (Test-Path $EmailBody) {Remove-Item -Force -Path $EmailBody}
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
New-Item $ToAddIPv4 -value "network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider`n"
New-Item $ToDelIPv4 -value "network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider`n"

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
	$url = "https://geolite.maxmind.com/download/geoip/database/GeoLite2-Country-CSV.zip"
	$output = "$PSScriptRoot\GeoLite2-Country-CSV.zip"
	Start-BitsTransfer -Source $url -Destination $output -ErrorAction Stop
	Expand-Archive $output -DestinationPath $PSScriptRoot -ErrorAction Stop
}
Catch {
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to download and/or unzip : `n$Error[0]" | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Write-Output "GeoIP update failed to download or unzip maxminds data zip file. See error log." | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

#	Rename folder so script can find it
Get-ChildItem $PSScriptRoot | Where-Object {$_.PSIsContainer -eq $true} | ForEach {
	If ($_.Name -match 'GeoLite2-Country-CSV_[0-9]{8}') {
		$FolderName = $_.Name
	}
}
Rename-Item "$PSScriptRoot\$FolderName" "$PSScriptRoot\GeoLite2-Country-CSV-New"

# If new downloaded folder does not exist or could not be renamed, then throw error
If (-not (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-New")){
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : $PSScriptRoot\GeoLite2-Country-CSV-New does not exist" | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Write-Output "GeoIP update failed at folder rename. See error log." | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

#	Create table if it doesn't exist
$Query = "
	CREATE TABLE IF NOT EXISTS $GeoIPTable (
	  network varchar(18) NOT NULL,
	  minip varchar(15) NOT NULL,
	  maxip varchar(15) NOT NULL,
	  geoname_id int(7),
	  countrycode varchar(2) NOT NULL,
	  countryname varchar(48) NOT NULL,
	  minipaton int(12) UNSIGNED ZEROFILL NOT NULL,
	  maxipaton int(12) UNSIGNED ZEROFILL NOT NULL,
	  PRIMARY KEY (maxipaton)
	) ENGINE=InnoDB DEFAULT CHARSET=latin1;
	COMMIT;
	"
MySQLQuery($Query)

#	Compare Old and New data for changes
If ((Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-Old") -and (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-New")){
	Compare-Object (Get-Content $CountryBlocksIPV4Old) (Get-Content $CountryBlocksIPV4) | ForEach-Object {
		If ($_.SideIndicator -eq '=>') {
			Write-Output $_.InputObject | Out-File $ToAddIPv4 -Encoding ASCII -Append
		} Else {
			Write-Output $_.InputObject | Out-File $ToDelIPv4 -Encoding ASCII -Append
		}
	}
}

#	If database previously loaded then use ToAdd/ToDel to make incremental changes - otherwise, load entire CSV into database
#	First, check to see database has previously loaded entries
$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
MySQLQuery($Query) | ForEach {
	$EntryCount = $_.numrows
}

############################
#
#    INCREMENTAL UPDATE
#
############################
#	If pass 3 tests: exists old folder, exists new folder, database previously populated - THEN proceed to load table from incremental
If ((Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-Old") -and (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-New") -and ($EntryCount -gt 0)){

	Try {

		# 	Read ToDelIPv4 cvs file, delete matches from database
		$GeoIPObjects = Import-CSV -Path $ToDelIPv4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
		$GeoIPObjects | ForEach-Object {
			$Network = $_.network
			$GeoNameID = $_.geoname_id
			If ($GeoNameID -notmatch 'geoname_id'){
				$Query = "DELETE FROM $GeoIPTable WHERE network='$Network'"
				MySQLQuery($Query)
			}
		}

		# 	Read ToAddIPv4 cvs file, convert CIDR network address to lowest and highest IPs in range, then insert into database
		$GeoIPObjects = Import-CSV -Path $ToAddIPv4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
		$GeoIPObjects | ForEach-Object {
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
				$Query = "INSERT INTO $GeoIPTable (network,minip,maxip,geoname_id,minipaton,maxipaton) VALUES ('$Network','$MinIP','$MaxIP','$GeoNameID',INET_ATON('$MinIP'),INET_ATON('$MaxIP'))"
				MySQLQuery($Query)
			}
		}

		# 	Read country info cvs and insert into database
		$GeoIPNameObjects = Import-CSV -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
		$GeoIPNameObjects | ForEach-Object {
			$GeoNameID = $_.geoname_id
			$CountryCode = $_.country_iso_code
			$CountryName = $_.country_name
			If ($GeoNameID -notmatch 'geoname_id'){
				$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID' AND countrycode='' AND countryname=''"
				MySQLQuery($Query)
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
	[int]$LinesNewCSV = ([Linq.Enumerable]::Count([System.IO.File]::ReadLines("$CountryBlocksIPV4")) - 1)

	#	Count records in database (post-update)
	$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
	MySQLQuery($Query) | ForEach {
		$DBCountAfterIncrUpdate = $_.numrows
	}

	#	Report Results
	Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output ("{0,7} : (A) Records in database prior to update" -f ($EntryCount).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append

	[int]$LinesToDel = ([Linq.Enumerable]::Count([System.IO.File]::ReadLines("$ToDelIPv4")) - 1)
	Write-Output ("{0,7} : (B) Records removed from database" -f ($LinesToDel).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append

	[int]$LinesToAdd = ([Linq.Enumerable]::Count([System.IO.File]::ReadLines("$ToAddIPv4")) - 1)
	Write-Output ("{0,7} : (C) Records inserted into database" -f ($LinesToAdd).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output "======= :" | Out-File $EmailBody -Encoding ASCII -Append

	[int]$SumOldDelAdd = ($EntryCount - $LinesToDel + $LinesToAdd)
	Write-Output ("{0,7} : Tabulated (A - B + C) number of records (should match NEW IPV4 csv)" -f ($SumOldDelAdd).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output "======= :" | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output ("{0,7} : Actual number of records in NEW IPV4 csv" -f ($LinesNewCSV).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output "======= :" | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output ("{0,7} : Queried number of records in database (should match NEW IPV4 csv)" -f ($DBCountAfterIncrUpdate).ToString("#,###")) | Out-File $EmailBody -Encoding ASCII -Append
	Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append

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
ElseIf ((Test-Path "$PSScriptRoot\GeoLite2-Country-CSV-New") -and ($EntryCount -eq 0)){

	Write-Host ""
	Write-Host "Please be patient. Initially loading the database can take two hours or more."
	Write-Host ""

	Try {

		# 	Read cvs file, convert CIDR network address to lowest and highest IPs in range, then insert into database
		$CountryBlocksIPV4 = "$PSScriptRoot\GeoLite2-Country-CSV-New\GeoLite2-Country-Blocks-IPv4.csv"
		$GeoIPObjects = Import-CSV -Path $CountryBlocksIPV4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
		$GeoIPObjects | ForEach-Object {
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
				$Query = "INSERT INTO $GeoIPTable (network,minip,maxip,geoname_id,minipaton,maxipaton) VALUES ('$Network','$MinIP','$MaxIP','$GeoNameID',INET_ATON('$MinIP'),INET_ATON('$MaxIP'))"
				MySQLQuery($Query)
			}
		}

		# 	Read country info cvs and insert into database
		$CountryLocations = "$PSScriptRoot\GeoLite2-Country-CSV-New\GeoLite2-Country-Locations-en.csv"
		$GeoIPNameObjects = Import-CSV -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
		$GeoIPNameObjects | ForEach-Object {
			$GeoNameID = $_.geoname_id
			$CountryCode = $_.country_iso_code
			$CountryName = $_.country_name
			If ($GeoNameID -notmatch 'geoname_id'){
				$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID' AND countrycode='' AND countryname=''"
				MySQLQuery($Query)
			}
		}
	}
	Catch {
		Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Full (new) db load failed : `n$Error[0]" | out-file $ErrorLog -append
		Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
		Write-Output "GeoIP update failed with database error. See error log." | Out-File $EmailBody -Encoding ASCII -Append
		EmailResults
		Exit
	}

	$Lines = ([Linq.Enumerable]::Count([System.IO.File]::ReadLines("$CountryBlocksIPV4")) - 1)
	Write-Host "Records in MaxMinds csv: $Lines"

	$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
	MySQLQuery($Query) | ForEach {
		$EntryCount = $_.numrows
	}
	Write-Host "Records in database: $EntryCount"

	$Diff = ([int]$Lines - [int]$EntryCount)
	If ($EntryCount -eq $Lines) {
		Write-Host "Database successfully loaded."
	} Else {
		Write-Host "Database loading **FAILED**."
		Write-Host "Failed to load $Diff records into database."
		Write-Host " "
		Write-Output "GeoIP update failed to load the correct number of records. See error log." | Out-File $EmailBody -Encoding ASCII -Append
		EmailResults
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

#	Else Exit since neither incremental nor new load can be accomplished
Else {
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to complete database load : Either Old or New data doesn't exist." | out-file $ErrorLog -append
	Write-Output "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | Out-File $ErrorLog -append
	Write-Output "GeoIP update failed: Either Old or New data doesn't exist. See error log." | Out-File $EmailBody -Encoding ASCII -Append
	EmailResults
	Exit
}

Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append
Write-Output "GeoIP update successful." | Out-File $EmailBody -Encoding ASCII -Append
Write-Output " " | Out-File $EmailBody -Encoding ASCII -Append

$EndTime = (Get-Date -f G)
Write-Output "GeoIP update finish: $EndTime" | Out-File $EmailBody -Encoding ASCII -Append

EmailResults