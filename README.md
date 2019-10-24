## GeoLite2MySQL
Import MaxMinds GeoLite2 data into MySQL

## FUNCTIONALITY
1) If geoip table does not exist, it gets created
2) Deletes all data from table if exists (required when updating database)
3) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
4) Reads IPv4 cvs data, then calculates the lowest and highest IP from each network in the database
5) Inserts lowest and highest IP calculated above and geoname_id from IPv4 cvs file
6) Reads geo-name cvs file and updates each record with country code and country name based on the geoname_id

## NOTES
Run once per month or once per 3 months via task scheduler
Loading the database takes over one hour - set your scheduled task for after midnight
	
## EXAMPLE QUERY
Returns countrycode and countryname from a given IP address:
	
```SELECT countrycode, countryname FROM geo_ip WHERE INET_ATON('182.253.228.22') >= INET_ATON(minip) AND INET_ATON('182.253.228.22') <= INET_ATON(maxip)```