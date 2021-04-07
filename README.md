## GeoLite2SQL
Powershell script to import MaxMinds GeoLite2 data into database server table

## NEW

MaxMind no longer allows anonymous downloads of the GeoLite2 databases. You must create an account and obtain a free license key. More information here:

https://blog.maxmind.com/2019/12/18/significant-changes-to-accessing-and-using-geolite2-databases/

## FUNCTIONALITY
1) If geoip tables do not exist, they get created
2) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
3) Converts IPv4 cvs IPs into integer using MaxMind's geoip2-csv-converter (included) https://github.com/maxmind/geoip2-csv-converter
4) Imports IPv4 cvs and country name cvs files into MySQL
5) Includes various error checking
6) Email notification on completion or error

## INSTRUCTIONS
1) Register for a GeoLite2 account here: https://www.maxmind.com/en/geolite2/signup
2) After successful login to your MaxMind account, generate a new license key (Services > License Key > Generate New Key)
3) Create folder to contain scripts and MaxMinds data
4) Rename GeoLite2SQL-Config.dist.ps1 to GeoLite2SQL-Config.ps1 and modify the config variables.
5) First time run can be either from powershell console or from scheduled task.

## NOTES
Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)

## EXAMPLE QUERY
Returns countrycode and countryname from a given IP address:

MySQL	
```
SELECT country_code, country_name
FROM (
	SELECT * 
	FROM geocountry 
	WHERE INET_ATON('212.186.81.105') <= network_last_integer
	LIMIT 1
	) AS a 
INNER JOIN geolocations AS b on a.geoname_id = b.geoname_id
WHERE network_start_integer <= INET_ATON('212.186.81.105')
LIMIT 1;
```

## Thanks
Many thanks to @SorenRR for providing the ridiculously simple yet completely overlooked MySQLImport concept vs the way I was doing it before.
