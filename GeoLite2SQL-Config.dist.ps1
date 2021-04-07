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


#>

###   Database Variables   ###
$MySQLUserName        = 'geoip'
$MySQLPassword        = 'supersecretpassword'
$MySQLDatabase        = 'geoip'
$MySQLHost            = 'localhost'
$MySQLPort            =  3306
$MySQLSSL             = 'none'
$MySQLConnectTimeout  = 300
$MySQLCommandTimeOut  = 9000000        # Leave high if read errors
$MySQLImport          = 'C:\mysql\bin\mysqlimport.exe'

###   Email Variables   ###
$EmailFrom            = "notify@mydomain.tld"
$EmailTo              = "admin@mydomain.tld"
$Subject              = 'GeoIP Update'
$SMTPServer           = "mydomain.tld"
$SMTPAuthUser         = "notify@mydomain.tld"
$SMTPAuthPass         = "supersecretpassword"
$SMTPPort             =  587
$UseSSL               = $True          # Use SSL in email relay
$UseHTML              = $True          # If true, email in html format
$AttachDebugLog       = $True          # Attach debug log to email
$MaxAttachmentSize    = 10             # Size in MB

###   Script Variables   ###
$LicenseKey           = 'supersecretlicensekey'
$CountryLocationLang  = 'en'
$GeoIP2CSVConverter   = '$PSScriptRoot\geoip2-csv-converter\geoip2-csv-converter.exe'

###   Verbosity   ###
# You can choose one, both or neither
$VerboseConsole       = $True          # Debug to screen
$VerboseFile          = $True          # Debug to file