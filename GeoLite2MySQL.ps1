<#

.SYNOPSIS
	Install MaxMindas geoip database on MySQL

.DESCRIPTION
	Download and unzip MaxMinds cvs geoip data, then populate MySQL with csv data

.FUNCTIONALITY
	1) If geoip table does not exist, it gets created
	2) Deletes old files, renames previously "new" "old" in order to compare
	3) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
	4) Compares new and old data for incremental changes
	5) Reads IPv4 cvs data, then calculates the lowest and highest IP from each network in the database
	6) Deletes obsolete records
	7) Inserts lowest and highest IP in range and geoname_id from IPv4 cvs file
	8) Reads geo-name cvs file and updates each record with country code and country name based on the geoname_id
	9) Includes various error checking to keep from blowing up a working database on error

.NOTES
	Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)
	Initial loading of the database takes over one hour - subsequent updates are incremental, so they only take a few minutes
	
.EXAMPLE
	Example query to return countrycode and countryname from database:
	
	SELECT countrycode, countryname FROM geo_ip WHERE INET_ATON('182.253.228.22') >= INET_ATON(minip) AND INET_ATON('182.253.228.22') <= INET_ATON(maxip)

#>

### User Variables ###
$GeoIPDir = 'C:\scripts\geolite2' 	# Location of files. No trailing "\" please. Please make sure folder exists.
$MySQLAdminUserName = 'geoip'
$MySQLAdminPassword = 'supersecretpassword'
$MySQLDatabase = 'geoip'
$MySQLHost = 'localhost'
### End User Variables ###

# https://www.quadrotech-it.com/blog/querying-mysql-from-powershell/
Function MySQLQuery($Query) {
	$DBErrorLog = '$GeoIPDir\DBError.log'
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
	  Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to run query : $query `n$Error[0]" | out-file $DBErrorLog -append
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

$ErrorLog = "$GeoIPDir\ErrorLog.log"
$ToAddIPv4 = "$GeoIPDir\ToAddIPv4.csv"
$ToDelIPv4 = "$GeoIPDir\ToDelIPv4.csv"

#	Delete old files if exist
If (Test-Path $GeoIPDir\"GeoLite2-Country-CSV-Old") {Remove-Item -Recurse -Force $GeoIPDir\"GeoLite2-Country-CSV-Old"}
If (Test-Path $GeoIPDir\"GeoLite2-Country-CSV.zip") {Remove-Item -Force -Path $GeoIPDir\"GeoLite2-Country-CSV.zip"}
If (Test-Path $ToAddIPv4) {Remove-Item -Force -Path $ToAddIPv4}
If (Test-Path $ToDelIPv4) {Remove-Item -Force -Path $ToDelIPv4}
If (Test-Path "$GeoIPDir\GeoLite2-Country-CSV-New") {Rename-Item -Path "$GeoIPDir\GeoLite2-Country-CSV-New" "$GeoIPDir\GeoLite2-Country-CSV-Old"}

#	Check to make sure files deleted
If ((Test-Path $ToAddIPv4) -or (Test-Path $ToDelIPv4)){
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Failed to delete old ToDelIPv4.csv and/or ToAddIPv4.csv" | out-file $ErrorLog -append
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Exit
}

#	Create new comparison CSVs
New-Item $ToAddIPv4 -value "network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider`n"
New-Item $ToDelIPv4 -value "network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider`n"

#	Check to make sure new comparison CSVs created
If ((-not (Test-Path $ToAddIPv4)) -or (-not (Test-Path $ToDelIPv4))){
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : $ToAddIPv4 and/or $ToDelIPv4 do not exist" | out-file $ErrorLog -append
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Exit
}

#	Download latest GeoLite2 data and unzip
Try {
	$url = "https://geolite.maxmind.com/download/geoip/database/GeoLite2-Country-CSV.zip"
	$output = "$GeoIPDir\GeoLite2-Country-CSV.zip"
	Start-BitsTransfer -Source $url -Destination $output -ErrorAction Stop
	Expand-Archive $output -DestinationPath $GeoIPDir -ErrorAction Stop
}
Catch {
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to download and/or unzip : `n$Error[0]" | out-file $ErrorLog -append
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Exit
}

#	Rename folder so script can find it
Get-ChildItem $GeoIPDir | Where-Object {$_.PSIsContainer -eq $true} | ForEach {
	If ($_.Name -match 'GeoLite2-Country-CSV_[0-9]{8}') {
		$FolderName = $_.Name
	}
}
Rename-Item "$GeoIPDir\$FolderName" "$GeoIPDir\GeoLite2-Country-CSV-New"

# If new downloaded folder does not exist or could not be renamed, then throw error
If (-not (Test-Path "$GeoIPDir\GeoLite2-Country-CSV-New")){
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : $GeoIPDir\GeoLite2-Country-CSV-New does not exist" | out-file $ErrorLog -append
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Exit
}

#	Create table if it doesn't exist
$GeoIPTable = "geo_ip"
$Query = "
	CREATE TABLE IF NOT EXISTS $GeoIPTable (
	  minip varchar(15) NOT NULL,
	  maxip varchar(15) NOT NULL,
	  geoname_id int(7) NOT NULL,
	  countrycode varchar(2) NOT NULL,
	  countryname varchar(48) NOT NULL
	) ENGINE=InnoDB DEFAULT CHARSET=latin1;
	COMMIT;
	"
MySQLQuery($Query)

#	Compare Old and New data for changes
If ((Test-Path "$GeoIPDir\GeoLite2-Country-CSV-Old") -and (Test-Path "$GeoIPDir\GeoLite2-Country-CSV-New")){
$CompareCSVIPV4Old = Get-Content "$GeoIPDir\GeoLite2-Country-CSV-Old\GeoLite2-Country-Blocks-IPv4.csv"
$CompareCSVIPV4New = Get-Content "$GeoIPDir\GeoLite2-Country-CSV-New\GeoLite2-Country-Blocks-IPv4.csv"
	Compare-Object $CompareCSVIPV4Old $CompareCSVIPV4New | ForEach-Object {
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

#	If pass 3 tests: exists old folder, exists new folder, database previously populated - THEN proceed to load table from incremental
If ((Test-Path "$GeoIPDir\GeoLite2-Country-CSV-Old") -and (Test-Path "$GeoIPDir\GeoLite2-Country-CSV-New") -and ($EntryCount -gt 0)){

	# 	Load table from incremental: 
	# 	Read ToDelIPv4 cvs file, convert CIDR network address to lowest and highest IPs in range, then delete from database
	$GeoIPObjects = import-csv -Path $ToDelIPv4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
	$GeoIPObjects | foreach-object {
		$Network = $_.network
		$GeoNameID = $_.geoname_id
		If ($GeoNameID -match '[0-9]{1,12}'){
			Get-IPv4NetworkInfo -CIDRAddress $Network | ForEach-Object {
				$MinIP = $_.NetworkAddress
				$MaxIP = $_.BroadcastAddress
			}
			$Query = "DELETE FROM $GeoIPTable WHERE minip='$MinIP' AND maxip='$MaxIP'"
			MySQLQuery($Query)
		}
	}

	# 	Read ToAddIPv4 cvs file, convert CIDR network address to lowest and highest IPs in range, then insert into database
	$GeoIPObjects = import-csv -Path $ToAddIPv4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
	$GeoIPObjects | foreach-object {
		$Network = $_.network
		$GeoNameID = $_.geoname_id
		If ($GeoNameID -match '[0-9]{1,12}'){
			Get-IPv4NetworkInfo -CIDRAddress $Network | ForEach-Object {
				$MinIP = $_.NetworkAddress
				$MaxIP = $_.BroadcastAddress
			}
			$Query = "INSERT INTO $GeoIPTable (minip,maxip,geoname_id) VALUES ('$MinIP','$MaxIP','$GeoNameID')"
			MySQLQuery($Query)
		}
	}

	# 	Read country info cvs and insert into database
	$CountryLocations = "$GeoIPDir\GeoLite2-Country-CSV-New\GeoLite2-Country-Locations-en.csv"
	$GeoIPNameObjects = import-csv -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
	$GeoIPNameObjects | foreach-object {
		$GeoNameID = $_.geoname_id
		$CountryCode = $_.country_iso_code
		$CountryName = $_.country_name
		If ($GeoNameID -match '[0-9]{1,12}'){
			$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID' AND countrycode='' AND countryname=''"
			MySQLQuery($Query)
		}
	}
}

#	If pass 2 tests: exists new folder, database UNpopulated - then proceed to load table as new
ElseIf ((Test-Path "$GeoIPDir\GeoLite2-Country-CSV-New") -and ($EntryCount -eq 0)){

	# 	Load table from NEW: 
	# 	Read cvs file, convert CIDR network address to lowest and highest IPs in range, then insert into database
	$CountryBlocksIPV4 = "$GeoIPDir\GeoLite2-Country-CSV-New\GeoLite2-Country-Blocks-IPv4.csv"
	$GeoIPObjects = import-csv -Path $CountryBlocksIPV4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
	$GeoIPObjects | foreach-object {
		$Network = $_.network
		$GeoNameID = $_.geoname_id
		If ($GeoNameID -match '[0-9]{1,12}'){
			Get-IPv4NetworkInfo -CIDRAddress $Network | ForEach-Object {
				$MinIP = $_.NetworkAddress
				$MaxIP = $_.BroadcastAddress
			}
			$Query = "INSERT INTO $GeoIPTable (minip,maxip,geoname_id) VALUES ('$MinIP','$MaxIP','$GeoNameID')"
			MySQLQuery($Query)
		}
	}

	# 	Read country info cvs and insert into database
	$CountryLocations = "$GeoIPDir\GeoLite2-Country-CSV-New\GeoLite2-Country-Locations-en.csv"
	$GeoIPNameObjects = import-csv -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
	$GeoIPNameObjects | foreach-object {
		$GeoNameID = $_.geoname_id
		$CountryCode = $_.country_iso_code
		$CountryName = $_.country_name
		If ($GeoNameID -match '[0-9]{1,12}'){
			$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID' AND countrycode='' AND countryname=''"
			MySQLQuery($Query)
		}
	}
}

#	Else Exit since neither incremental nor new load can be accomplished
Else {
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to complete database load : Either Old or New data doesn't exist." | out-file $ErrorLog -append
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script" | out-file $ErrorLog -append
	Exit
}<#
.SYNOPSIS
	Install MaxMindas geoip database on MySQL

.DESCRIPTION
	Download and unzip MaxMinds cvs geoip data, then populate MySQL with csv data

.FUNCTIONALITY
	1) If geoip table does not exist, it gets created
	2) Deletes all data from table if exists (required when updating database)
	3) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
	4) Reads IPv4 cvs data, then calculates the lowest and highest IP from each network in the database
	5) Inserts lowest and highest IP calculated above and geoname_id from IPv4 cvs file
	6) Reads geo-name cvs file and updates each record with country code and country name based on the geoname_id

.NOTES
	Run once per month or once per 3 months via task scheduler
	Loading the database takes over one hour. Set your scheduled task for after midnight
	
.EXAMPLE
	Example query to return countrycode and countryname from database:
	
	SELECT countrycode, countryname FROM geo_ip WHERE INET_ATON('182.253.228.22') >= INET_ATON(minip) AND INET_ATON('182.253.228.22') <= INET_ATON(maxip)

#>

### User Variables 
$GeoIPDir = 'C:\scripts\geolite2' 	# Location of files. No trailing "\" please
$MySQLAdminUserName = 'geoip'
$MySQLAdminPassword = 'supersecretpassword'
$MySQLDatabase = 'geoip'
$MySQLHost = 'localhost'
### End User Variables 

#	Function from: https://www.quadrotech-it.com/blog/querying-mysql-from-powershell/
Function MySQLQuery($Query) {
	$DBErrorLog = '$GeoIPDir\DBError.log'
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
	  Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to run query : $query `n$Error[0]" | out-file $DBErrorLog -append
	}
	Finally {
	  $Connection.Close()
	}
}

#	Function from: https://www.ryandrane.com/2016/05/getting-ip-network-information-powershell/
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

#	Delete old files if exist
Remove-Item -Recurse -Force $GeoIPDir\"GeoLite2-Country-CSV"
Remove-Item -Force -Path $GeoIPDir\"GeoLite2-Country-CSV.zip"

#	Download latest GeoLite2 data
$url = "https://geolite.maxmind.com/download/geoip/database/GeoLite2-Country-CSV.zip"
$output = "$GeoIPDir\GeoLite2-Country-CSV.zip"
Start-BitsTransfer -Source $url -Destination $output
Expand-Archive $output -DestinationPath $GeoIPDir

#	Rename folder so script can find it
$MMErrorLog = "$GeoIPDir\error.log"
$MMFolder = Get-ChildItem $GeoIPDir | Where-Object {$_.PSIsContainer -eq $true} | Sort-Object
If ($MMFolder -match 'GeoLite2-Country-CSV_[0-9]{8}'){
	Rename-Item -Path $GeoIPDir\$MMFolder $GeoIPDir\"GeoLite2-Country-CSV"
} Else {
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : `n$Error[0]" | Out-File $MMErrorLog
}

#	Create table if it doesn't exist
$GeoIPTable = "geo_ip"
$Query = "
	CREATE TABLE IF NOT EXISTS $GeoIPTable (
	  minip varchar(15) NOT NULL,
	  maxip varchar(15) NOT NULL,
	  geoname_id int(7) NOT NULL,
	  countrycode varchar(2) NOT NULL,
	  countryname varchar(48) NOT NULL
	) ENGINE=InnoDB DEFAULT CHARSET=latin1;
	COMMIT;
	"
MySQLQuery($Query)

#	Delete all data on table (required when updating data)
$Query = "DELETE FROM $GeoIPTable"
MySQLQuery($Query)

#	Read IPv4 cvs file, convert CIDR network address to lowest and highest IPs in range, then insert into database
$CountryBlocksIPV4 = "$GeoIPDir\GeoLite2-Country-CSV\GeoLite2-Country-Blocks-IPv4-test.csv"
$GeoIPObjects = import-csv -Path $CountryBlocksIPV4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
$GeoIPObjects | foreach-object {
	$Network = $_.network
	$GeoNameID = $_.geoname_id
	If ($GeoNameID -match '[0-9]{1,12}'){
		Get-IPv4NetworkInfo -CIDRAddress $Network | ForEach-Object {
			$MinIP = $_.NetworkAddress
			$MaxIP = $_.BroadcastAddress
		}
		$Query = "INSERT INTO $GeoIPTable (minip,maxip,geoname_id) VALUES ('$MinIP','$MaxIP','$GeoNameID')"
		MySQLQuery($Query)
	}
}

#	Read country info cvs and insert into database
$CountryLocations = "$GeoIPDir\GeoLite2-Country-CSV\GeoLite2-Country-Locations-en.csv"
$GeoIPNameObjects = import-csv -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
$GeoIPNameObjects | foreach-object {
	$GeoNameID = $_.geoname_id
	$CountryCode = $_.country_iso_code
	$CountryName = $_.country_name
	If ($GeoNameID -match '[0-9]{1,12}'){
		$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID'"
		MySQLQuery($Query)
	}
}