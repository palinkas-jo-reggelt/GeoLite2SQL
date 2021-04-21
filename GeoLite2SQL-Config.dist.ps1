<#
.SYNOPSIS
	Install MaxMindas geoip database to database server

.DESCRIPTION
	Config file to GeoLite2SQL project

.FUNCTIONALITY


.NOTES
	LANGUAGE OPTIONS
	* Options offered by MaxMind - included in GeoLite2 package
	* de, en, es, fr, ja, pt-BR, ru, zh=CN
	
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

###   Database Variables   ###
$MySQLUserName        = "geoip"
$MySQLPassword        = "supersecretpassword"
$MySQLDatabase        = "geoip"
$MySQLHost            = "localhost"
$MySQLPort            =  3306
$MySQLSSL             = "none"
$MySQLConnectTimeout  = 300
$MySQLCommandTimeOut  = 9000000        # Leave high if read errors
$MySQLImport          = "C:\mysql\bin\mysqlimport.exe"

###   Email Variables   ###
$EmailFrom            = "notify@mydomain.tld"
$EmailTo              = "admin@mydomain.tld"
$Subject              = "GeoIP Update"
$SMTPServer           = "mydomain.tld"
$SMTPAuthUser         = "notify@mydomain.tld"
$SMTPAuthPass         = "supersecretpassword"
$SMTPPort             =  587
$UseSSL               = $True          # Use SSL in email relay
$UseHTML              = $True          # If true, email in html format
$AttachDebugLog       = $True          # Attach debug log to email
$MaxAttachmentSize    = 10             # Size in MB

###   Script Variables   ###
$LicenseKey           = "supersecretlicensekey"
$LocationLang         = "en"
$GeoIP2CSVConverter   = "$PSScriptRoot\geoip2-csv-converter\geoip2-csv-converter.exe"

###   Verbosity   ###
# You can choose one, both or neither
$VerboseConsole       = $True          # Debug to screen
$VerboseFile          = $True          # Debug to file