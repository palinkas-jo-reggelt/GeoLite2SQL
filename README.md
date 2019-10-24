## GeoLite2MySQL
Import MaxMinds GeoLite2 data into MySQL

##FUNCTIONALITY
1) If geoip table does not exist, it gets created
2) Deletes old files, renames previously "new" "old" in order to compare
3) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
4) Compares new and old data for incremental changes
5) Reads IPv4 cvs data, then calculates the lowest and highest IP from each network in the database
6) Deletes obsolete records
7) Inserts lowest and highest IP in range and geoname_id from IPv4 cvs file
8) Reads geo-name cvs file and updates each record with country code and country name based on the geoname_id
9) Includes various error checking to keep from blowing up a working database on error

##NOTES
Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)
Initial loading of the database takes over one hour - subsequent updates are incremental, so they only take a few minutes
	
## EXAMPLE QUERY
Returns countrycode and countryname from a given IP address:
	
```SELECT countrycode, countryname FROM geo_ip WHERE INET_ATON('182.253.228.22') >= INET_ATON(minip) AND INET_ATON('182.253.228.22') <= INET_ATON(maxip)```

## HISTORY
- v.02 added incremental update and error checking
- v.01 first commit