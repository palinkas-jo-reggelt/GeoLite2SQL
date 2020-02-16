## GeoLite2MySQL
Powershell script to import MaxMinds GeoLite2 data into MySQL

## NEW

MaxMind no longer allows anonymous downloads of the GeoLite2 databases. You must create an account and obtain a free license key. More information here:

https://blog.maxmind.com/2019/12/18/significant-changes-to-accessing-and-using-geolite2-databases/

## FUNCTIONALITY
1) If geoip table does not exist, it gets created
2) Deletes old files, renames previously "new" "old" in order to compare
3) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
4) Compares new and old data for incremental changes
5) Reads IPv4 cvs data, then calculates the lowest and highest IP from each network in the database
6) Deletes obsolete records
7) Inserts lowest and highest IP in range and geoname_id from IPv4 cvs file
8) Reads geo-name cvs file and updates each record with country code and country name based on the geoname_id
9) Creates scheduled task for weekly updates
10) Includes various error checking to keep from blowing up a working database on error
11) Email notification on error

## INSTRUCTIONS
1) Register for a GeoLite2 account here: https://www.maxmind.com/en/geolite2/signup
2) After successful login to your MaxMind account, generate a new license key (Services > License Key > Generate New Key)
3) Create folder to contain scripts and MaxMinds data
4) Modify user variables in GeoLite2MySQL.ps1
5) First time run from Powershell console

## NOTES
Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)

Initial loading of the database takes a LONG time, about 2 hours on my old hardware (338k+ records). Incremental updates are also time consuming, but unattended. Incremental is preferred over reloading the entire database if the database is in use (which it is, or why bother installing it in the first place?) even though incremental updates often take longer than the initial load.
	
## EXAMPLE QUERY
Returns countrycode and countryname from a given IP address:
	
```
SELECT countrycode, countryname FROM (SELECT * FROM geo_ip WHERE INET_ATON('125.64.94.220') <= maxipaton LIMIT 1) AS A WHERE minipaton <= INET_ATON('125.64.94.220')
```

## hMailServer VBS
Subroutine (credit to SorenR for error checking, among other things):
```
Sub GeoIPLookup(ByVal sIPAddress, ByRef m_CountryCode, ByRef m_CountryName)
    Dim oRecord, oConn : Set oConn = CreateObject("ADODB.Connection")
    oConn.Open "Driver={MariaDB ODBC 3.0 Driver}; Server=localhost; Database=geoip; User=geoip; Password=supersecretpassword;"

    If oConn.State <> 1 Then
'       EventLog.Write( "Sub GeoIPLookup - ERROR: Could not connect to database" )
        WScript.Echo( "Sub GeoIPLookup - ERROR: Could not connect to database" )
        m_CountryCode = "XX"
        m_CountryName = "ERROR"
        Exit Sub
    End If

    m_CountryCode = "NX"
    m_CountryName = "NOT FOUND"

    Set oRecord = oConn.Execute("SELECT countrycode, countryname FROM (SELECT * FROM geo_ip WHERE INET_ATON('" & sIPAddress & "') <= maxipaton LIMIT 1) AS A WHERE minipaton <= INET_ATON('" & sIPAddress & "')")
    Do Until oRecord.EOF
        m_CountryCode = oRecord("countrycode")
        m_CountryName = oRecord("countryname")
        oRecord.MoveNext
    Loop
    oConn.Close
    Set oRecord = Nothing
End Sub
```

Call Sub:
```
'	GeoIP Lookup
Dim m_CountryCode, m_CountryName
Call GeoIPLookup(oClient.IPAddress, m_CountryCode, m_CountryName)
```

## HISTORY
- v.11 fixed fundamental logical flaw in incremental update: BEFORE: network comparison was made between old and new MaxMind csv files. This worked as long as everything worked as expected. However, after a glitch on my system, the MaxMind files came out of sequence and therefore the number of entries no longer matched the database. NOW: network comparison is made directly between the database and the new MaxMind csv, so it doesn't matter if you skipped a week or a year updating. Additionally, some changes to csv exporting were made to remove foreach loops, speeding up the process dramatically. For example, before, an update containing a few thousand changes would take hours. My latest update with 6k changes took only 20 minutes. Big improvement. 
- v.10 fixed dowload url for new MaxMind API access; also fixed an issue renaming the extracted data folder
- v.09 fixed duration time display at success email notification
- v.08 cleaned up error notifications on initial loading; cleaned up email result body; included report total operation time in email result
- v.07 added column width formatting to email notification plus more and useful information; email report is meaningful more than "success/fail"
- v.06 housekeeping
- v.05 added create scheduled task and email notification
- v.04 bug fixes
- v.03 bug fixes
- v.02 added incremental update and error checking
- v.01 first commit
