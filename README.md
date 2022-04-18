## GeoLite2SQL
Powershell script to import MaxMinds GeoLite2 data into database server table

## NEW

IPv6 Support!

Version 3 has major changes. If you are using an older version and want to upgrade, please make note that TABLE NAMES and COLUMN NAMES have changed, as well as queries. Please see example queries below.

## FUNCTIONALITY
1) If geoip tables do not exist, they get created
2) Downloads MaxMind GeoLite2 CSV data as zip file, uncompresses it, then renames the folder
3) Converts MaxMind CSV IP ranges to beginning/end IPs for import using MaxMind's geoip2-csv-converter (included) https://github.com/maxmind/geoip2-csv-converter
4) Imports IP and country name data into MySQL
5) Includes various error checking
6) Email notification on completion or error

## INSTRUCTIONS
MaxMind no longer allows anonymous downloads of the GeoLite2 databases. You must create an account and obtain a free license key. More information here:
https://blog.maxmind.com/2019/12/18/significant-changes-to-accessing-and-using-geolite2-databases/

1) Register for a GeoLite2 account here: https://www.maxmind.com/en/geolite2/signup
2) After successful login to your MaxMind account, generate a new license key (Services > License Key > Generate New Key)
3) Create folder to contain scripts and MaxMinds data
4) Rename GeoLite2SQL-Config.dist.ps1 to GeoLite2SQL-Config.ps1 and modify the config variables.
5) First time run can be either from powershell console or from scheduled task. Parameters 'city' or 'country' required. Country database contains only country-level geoip information. City database contains more localized data for cities, regions, etc.
```C:\path\to\Geolite2SQL.ps1 country```
```C:\path\to\Geolite2SQL.ps1 city```

## NOTES
--!!!--   
Requires user privileges: GRANT FILE ON *.* TO 'db-user'@'%' in order for LOAD DATA INFILE to work!  
Data import will FAIL due to access denied to user without these privileges!  
Use user 'root' if you cannot grant these privileges.  
--!!!-- 

Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)

License Key required from MaxMind in order to download data (its free, sign up here: https://www.maxmind.com/en/geolite2/signup)

## EXAMPLE QUERY
Returns country_code and country_name for a given IP address from the country database:

MySQL	
```
SELECT country_code, country_name
FROM (
	SELECT * 
	FROM geocountry 
	WHERE INET6_ATON('212.186.81.105') <= network_last
	LIMIT 1
) AS a 
INNER JOIN countrylocations AS b on a.geoname_id = b.geoname_id
WHERE network_start <= INET6_ATON('212.186.81.105');
```

```
SELECT country_code, country_name
FROM (
	SELECT * 
	FROM geocountry 
	WHERE INET6_ATON('2001:67c:28a4::') <= network_last
	LIMIT 1
) AS a 
INNER JOIN countrylocations AS b on a.geoname_id = b.geoname_id
WHERE network_start <= INET6_ATON('2001:67c:28a4::');
```

Returns all data for a given IP address from the city database:

MySQL	
```
SELECT *
FROM (
	SELECT * 
	FROM geocity 
	WHERE INET6_ATON('212.186.81.105') <= network_last
	LIMIT 1
) AS a 
INNER JOIN citylocations AS b on a.geoname_id = b.geoname_id
WHERE network_start <= INET6_ATON('212.186.81.105');
```

```
SELECT *
FROM (
	SELECT * 
	FROM geocity 
	WHERE INET6_ATON('2001:67c:28a4::') <= network_last
	LIMIT 1
) AS a 
INNER JOIN citylocations AS b on a.geoname_id = b.geoname_id
WHERE network_start <= INET6_ATON('2001:67c:28a4::');
```

## Thanks
Many thanks to @SorenRR for providing lots of help with lot of stuff.
Many thanks to @RvdHout for help with IPv6 integration.
