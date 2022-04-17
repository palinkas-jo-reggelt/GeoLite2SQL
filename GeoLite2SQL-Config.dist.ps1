<#
.SYNOPSIS
	Install MaxMind GeoLite2 database to local database server

.DESCRIPTION
	Config file to GeoLite2SQL project

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

	LANGUAGE OPTIONS
	* Options offered by MaxMind - included in GeoLite2 package
	* de, en, es, fr, ja, pt-BR, ru, zh=CN
	
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

###   Database Variables   ###
$MySQLUserName        = "geoip"
$MySQLPassword        = "supersecretpassword"
$MySQLDatabase        = "geoip"
$MySQLHost            = "localhost"
$MySQLPort            =  3306
$MySQLSSL             = "none"
$MySQLConnectTimeout  = 300
$MySQLCommandTimeOut  = 9000000        # Leave high if read errors
$MySQLImport          = "C:\xampp\mysql\bin\mysqlimport.exe"

###   Email Variables   ###
$EmailFrom            = "notify@mydomain.tld"
$EmailTo              = "admin@mydomain.tld"
$Subject              = "GeoIP Update"
$SMTPServer           = "mail.mydomain.tld"
$SMTPAuthUser         = "notify@mydomain.tld"
$SMTPAuthPass         = "supersecretpassword"
$SMTPPort             =  587
$UseSSL               = $True          # Use SSL in email relay
$UseHTML              = $True          # If true, email in html format
$AttachDebugLog       = $True          # Attach debug log to email
$MaxAttachmentSize    = 1              # Size in MB

###   Script Variables   ###
$LicenseKey           = "supersecretlicensekey"
$LocationLanguage     = "en"
$GeoIP2CSVConverter   = "$PSScriptRoot\geoip2-csv-converter\geoip2-csv-converter.exe"

###   Verbosity   ###
# You can choose one, both or neither
$VerboseConsole       = $True          # Debug to screen
$VerboseFile          = $True          # Debug to file