<#

.SYNOPSIS
	Install MaxMindas geoip database on MySQL

.DESCRIPTION
	Downloads and unzips MaxMinds csv geoip data, then populate MySQL with csv data

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

<#  Include required files  #>
Try {
	.("$PSScriptRoot\Config.ps1")
}
Catch {
	Write-Output "Error while loading supporting PowerShell Scripts" | Out-File -Path "$PSScriptRoot\PSError.log"
}

<#######################################
#                                      #
#             EMAIL CODE               #
#                                      #
#######################################>

Function EmailResults {
	$Subject = "GeoIP Update Results" 
	$Body = (Get-Content -Path $EmailBody | Out-String )
	$SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer, $SMTPPort) 
	$SMTPClient.EnableSsl = [System.Convert]::ToBoolean($SSL)
	$SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SMTPAuthUser, $SMTPAuthPass); 
	$SMTPClient.Send($EmailFrom, $EmailTo, $Subject, $Body)
}



<#  https://www.ryandrane.com/2016/05/getting-ip-network-information-powershell/  #>
Function Get-IPv4NetworkInfo {
	Param
	(
		[Parameter(ParameterSetName = "IPandMask", Mandatory = $true)] 
		[ValidateScript( { $_ -match [ipaddress]$_ })] 
		[System.String]$IPAddress,

		[Parameter(ParameterSetName = "IPandMask", Mandatory = $true)] 
		[ValidateScript( { $_ -match [ipaddress]$_ })] 
		[System.String]$SubnetMask,

		[Parameter(ParameterSetName = "CIDR", Mandatory = $true)] 
		[ValidateScript( { $_ -match '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/([0-9]|[0-2][0-9]|3[0-2])$' })]
		[System.String]$CIDRAddress,

		[Switch]$IncludeIPRange
	)

	<# If @CIDRAddress is set  #>
	if ($CIDRAddress) {
		<# Separate our IP address, from subnet bit count  #>
		$IPAddress, [int32]$MaskBits = $CIDRAddress.Split('/')

		<# Create array to hold our output mask  #>
		$CIDRMask = @()

		<# For loop to run through each octet,  #>
		for ($j = 0; $j -lt 4; $j++) {
			<# If there are 8 or more bits left  #>
			if ($MaskBits -gt 7) {
				<# Add 255 to mask array, and subtract 8 bits   #>
				$CIDRMask += [byte]255
				$MaskBits -= 8
			}
			else {
				<# bits are less than 8, calculate octet bits and  #>
				<# zero out our $MaskBits variable.  #>
				$CIDRMask += [byte]255 -shl (8 - $MaskBits)
				$MaskBits = 0
			}
		}

		<# Assign our newly created mask to the SubnetMask variable  #>
		$SubnetMask = $CIDRMask -join '.'
	}

	<# Get Arrays of [Byte] objects, one for each octet in our IP and Mask  #>
	$IPAddressBytes = ([ipaddress]::Parse($IPAddress)).GetAddressBytes()
	$SubnetMaskBytes = ([ipaddress]::Parse($SubnetMask)).GetAddressBytes()

	<# Declare empty arrays to hold output  #>
	$NetworkAddressBytes = @()
	$BroadcastAddressBytes = @()
	$WildcardMaskBytes = @()

	<# Determine Broadcast / Network Addresses, as well as Wildcard Mask  #>
	for ($i = 0; $i -lt 4; $i++) {
		<# Compare each Octet in the host IP to the Mask using bitwise  #>
		<# to obtain our Network Address  #>
		$NetworkAddressBytes += $IPAddressBytes[$i] -band $SubnetMaskBytes[$i]

		<# Compare each Octet in the subnet mask to 255 to get our wildcard mask  #>
		$WildcardMaskBytes += $SubnetMaskBytes[$i] -bxor 255

		<# Compare each octet in network address to wildcard mask to get broadcast.  #>
		$BroadcastAddressBytes += $NetworkAddressBytes[$i] -bxor $WildcardMaskBytes[$i] 
	}

	# Create variables to hold our NetworkAddress, WildcardMask, BroadcastAddress
	$NetworkAddress = $NetworkAddressBytes -join '.'
	$BroadcastAddress = $BroadcastAddressBytes -join '.'
	$WildcardMask = $WildcardMaskBytes -join '.'

	# Now that we have our Network, Widcard, and broadcast information, 
	# We need to reverse the byte order in our Network and Broadcast addresses
	[array]::Reverse($NetworkAddressBytes)
	[array]::Reverse($BroadcastAddressBytes)

	# We also need to reverse the array of our IP address in order to get its
	# integer representation
	[array]::Reverse($IPAddressBytes)

	# Next we convert them both to 32-bit integers
	$NetworkAddressInt = [System.BitConverter]::ToUInt32($NetworkAddressBytes, 0)
	$BroadcastAddressInt = [System.BitConverter]::ToUInt32($BroadcastAddressBytes, 0)
	$IPAddressInt = [System.BitConverter]::ToUInt32($IPAddressBytes, 0)

	#Calculate the number of hosts in our subnet, subtracting one to account for network address.
	$NumberOfHosts = ($BroadcastAddressInt - $NetworkAddressInt) - 1

	# Declare an empty array to hold our range of usable IPs.
	$IPRange = @()

	# If -IncludeIPRange specified, calculate it
	if ($IncludeIPRange) {
		# Now run through our IP range and figure out the IP address for each.
		For ($j = 1; $j -le $NumberOfHosts; $j++) {
			# Increment Network Address by our counter variable, then convert back
			# lto an IP address and extract as string, add to IPRange output array.
			$IPRange += [ipaddress]([convert]::ToDouble($NetworkAddressInt + $j)) | Select-Object -ExpandProperty IPAddressToString
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


#######################################
#                                     #
#           DATABASE CODE             #
#                                     #
#######################################

Function IsMSSQL() {
	return ($DatabaseType -eq "MSSQL")
}

Function IsMySQL() {
	return ($DatabaseType -eq "MYSQL")
}

Function RunSQLQuery($Query) {
	If ($(IsMySQL)) {
		MySQLQuery($Query)
	}
 ElseIf ($(IsMSSQL)) {
		MSSQLQuery($Query)
	}
 Else {
		Out-Null
	}
}

Function MySQLQuery($Query) {
	$Today = (Get-Date).ToString("yyyyMMdd")
	$DBErrorLog = "$PSScriptRoot\$Today-DBError.log"
	$ConnectionString = "server=" + $SQLHost + ";port=" + $SQLPort + ";uid=" + $SQLAdminUserName + ";pwd=" + $SQLAdminPassword + ";database=" + $SQLDatabase + ";SslMode=" + $SQLSSL + ";"
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

Function MSSQLQuery($Query) {
	$Today = (Get-Date).ToString("yyyyMMdd")
	$DBErrorLog = "$PSScriptRoot\$Today-DBError.log"
	$ConnectionString = "Data Source=" + $SQLHost + "," + $SQLPort + ";uid=" + $SQLAdminUserName + ";password=" + $SQLAdminPassword + ";Initial Catalog=" + $SQLDatabase
	Try {
		[void][System.Reflection.Assembly]::LoadWithPartialName("MySql.Data")
		$Connection = New-Object System.Data.SqlClient.SQLConnection($connectionString)
		$Connection.Open()
		$Command = New-Object System.Data.SqlClient.SqlCommand($Query, $Connection)
		$DataAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($Command)
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

Function CreateTablesIfNeeded() {
	If ($(IsMySQL)) {
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
		RunSQLQuery($Query)
	}
 ElseIf ($(IsMSSQL)) {
		$Query = "
			IF NOT EXISTS (SELECT 1 FROM SYSOBJECTS WHERE NAME='$GeoIPTable')
			BEGIN
				CREATE TABLE $GeoIPTable (
					network varchar(18) NOT NULL,
					minip varchar(15) NOT NULL,
					maxip varchar(15) NOT NULL,
					geoname_id int,
					countrycode varchar(2) NOT NULL DEFAULT '',
					countryname varchar(48) NOT NULL DEFAULT '',
					minipaton BIGINT CHECK (minipaton > 0) NOT NULL,
					maxipaton BIGINT CHECK (maxipaton > 0) NOT NULL,
					PRIMARY KEY (maxipaton)
				)
			END
			"
		RunSQLQuery($Query)

		#Create MSSQL Function equivalent to INET_ATON() from MySQL
		#first drop if exists
		$Query = "
			IF EXISTS (SELECT 1 FROM SYSOBJECTS WHERE NAME = 'ipStringToInt')
				DROP FUNCTION dbo.ipStringToInt 
			"
		RunSQLQuery $Query
		#then create
		$Query = "
			CREATE FUNCTION dbo.ipStringToInt 
			( 
				@ip CHAR(15) 
			) 
			RETURNS BIGINT 
			AS 
			BEGIN 
				DECLARE @rv BIGINT, 
					@o1 BIGINT, 
					@o2 BIGINT, 
					@o3 BIGINT, 
					@o4 BIGINT, 
					@base BIGINT 
			
				SELECT 
					@o1 = CONVERT(INT, PARSENAME(@ip, 4)), 
					@o2 = CONVERT(INT, PARSENAME(@ip, 3)), 
					@o3 = CONVERT(INT, PARSENAME(@ip, 2)), 
					@o4 = CONVERT(INT, PARSENAME(@ip, 1)) 
			
				IF (@o1 BETWEEN 0 AND 255) 
					AND (@o2 BETWEEN 0 AND 255) 
					AND (@o3 BETWEEN 0 AND 255) 
					AND (@o4 BETWEEN 0 AND 255) 
				BEGIN      
					SET @rv = (@o1 * 16777216)+
						(@o2 * 65536) +  
						(@o3 * 256) + 
						(@o4) 
				END 
				ELSE 
					SET @rv = -1 
				RETURN @rv 
			END
		"
		RunSQLQuery $Query

	}
}

Function DBIpStringToIntField($fieldName){
	$Return = "";

	if (IsMySQL) {
		$Return = "INET_ATON('$fieldName')"
	} ElseIf (IsMSSQL) {
		$Return = "dbo.ipStringToInt('$fieldName')"
	}
	return $Return
}

Function DBCastDateTimeFieldAsDate($fieldName) {
	$Return = ""
	If ($(IsMySQL)) {
		$Return = "DATE($fieldName)"
	}
 ElseIf ($(IsMSSQL)) {
		$Return = "CAST($fieldName AS DATE)"
	}
	return $Return
}

Function DBCastDateTimeFieldAsHour($fieldName) {
	$Return = ""
	If ($(IsMySQL)) {
		$Return = "HOUR($fieldName)"
	}
 ElseIf ($(IsMSSQL)) {
		$Return = "DATEPART(hour,$fieldName)"
	}
	return $Return;
}

Function DBSubtractIntervalFromDate() {
	param
	(
		$dateString,
		$intervalName, 
		$intervalValue
	)

	$Return = ""
	If ($(IsMySQL)) {
		$Return = "'$dateString' - interval $intervalValue $intervalName"
	}
 ElseIf ($(IsMSSQL)) {
		$Return = "DATEADD($intervalName,-$intervalValue, '$dateString')"
	}
	return $Return
}

Function DBSubtractIntervalFromField() {
	param
	(
		$fieldName, 
		$intervalName, 
		$intervalValue
	)

	$Return = ""
	If ($(IsMySQL)) {
		$Return = "$fieldName - interval $intervalValue $intervalName"
	}
 ElseIf ($(IsMSSQL)) {
		$Return = "DATEADD($intervalName,-$intervalValue, $fieldName)"
	}
	return $Return
}

Function DBGetCurrentDateTime() {
	$Return = ""
	If ($(IsMySQL)) {
		$Return = "NOW()"
	}
 ElseIf ($(IsMSSQL)) {
		$Return = "GETDATE()"
	}
	return $Return
}

Function DBLimitRowsWithOffset() {
	param(
		$offset,
		$numRows
	)

	$QueryLimit = ""

	If ($(IsMySQL)) {
		$QueryLimit = "LIMIT $offset, $numRows"
	}
 ElseIf ($(IsMSSQL)) {
		$QueryLimit = "OFFSET $offset ROWS 
		   	           FETCH NEXT $numRows ROWS ONLY"
	}
	return $QueryLimit
}

Function DBFormatDate() {

	param(
		$fieldName, 
		$formatSpecifier
	)

	$Return = ""

	$dateFormatSpecifiers = @{
		'%Y'                   = 'yyyy'
		'%c'                   = 'MM'
		'%e'                   = 'dd'
		'Y-m-d'                = 'yyyy-MM-dd'
		'%y/%m/%d'             = 'yy/MM/dd'
		'Y-m'                  = 'yyyy-MM'
		'%Y-%m'                = 'yyyy-MM'
		'%y/%m/%d %T'          = 'yy-MM-dd HH:mm:ss'
		'%Y/%m/%d %HH:%mm:%ss' = 'yyyy-MM-dd HH:mm:ss'
		'%Y/%m/01'             = 'yyyy-MM-01'
		'%y/%c/%e'             = 'yy/MM/dd'
		'%H'                   = 'HH'
	}
	
	If ($(IsMySQL)) {
		$Return = "DATE_FORMAT($fieldName, '$formatSpecifier')"
	}
 ElseIf ($(IsMSSQL)) {
		$Return = "FORMAT($fieldName, '$($dateFormatSpecifiers[$formatSpecifier])', 'en-US')"
	}
	return $Return
}

Function VerboseOutput($StringText){
	If ($VerboseConsole){
		Write-Host $StringText
	}
	If ($VerboseFile){
		Write-Output $StringText | Out-File $DebugLog -Append
	}
}

Function EmailOutput($StringText){
	Write-Output $StringText | Out-File $EmailBody -Encoding ASCII -Append
}