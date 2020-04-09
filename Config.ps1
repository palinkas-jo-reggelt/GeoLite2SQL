<#
.SYNOPSIS
	Install MaxMindas geoip database to database server

.DESCRIPTION
	Config file to GeoLite2SQL project

.FUNCTIONALITY


.NOTES
	DATABASE TYPE OPTIONS
	* MYSQL
	* MSSQL
	
	LANGUAGE OPTIONS
	* Options offered by MaxMind - included in GeoLite2 package
	* de, en, es, fr, ja, pt-BR, ru, zh=CN
	
	VERBOSITY 
	* Outputs debugging to console or file
	* You can choose one, both or none. No matter what is selected here, email report goes out.
	
.EXAMPLE


#>

### Database Variables ##############################
#                                                   #
# DatabaseType Options: 'MYSQL' or 'MSSQL'          #
$DatabaseType         = 'MYSQL'                     #
$GeoIPTable           = 'geo_ip'                    #
$SQLAdminUserName     = 'geoip'                     #
$SQLAdminPassword     = 'supersecretpassword'       #
$SQLDatabase          = 'geoip'                     #
$SQLHost              = '127.0.0.1'                 #
$SQLPort              =  3306                       #
$SQLSSL               = 'none'                      #
#                                                   #
### Email Variables #################################
#                                                   #
$EmailFrom            = "notifier.acct@gmail.com"   #
$EmailTo              = "me@mydomain.com"           #
$SMTPServer           = "smtp.gmail.com"            #
$SMTPAuthUser         = "notifier.acct@gmail.com"   #
$SMTPAuthPass         = "supersecretpassword"       #
$SMTPPort             =  587                        #
$SSL                  = 'True'                      #
#                                                   #
### MaxMind Download Token ##########################
#                                                   #
$LicenseKey           = 'SuperSecretLicenseKey'     #
$CountryLocationLang  = 'en'                        #
#                                                   #
### Verbosity #######################################
#                                                   #
$VerboseConsole       = $True   # Debug to screen   #
$VerboseFile          = $True   # Debug to file     #
#                                                   #
#####################################################
