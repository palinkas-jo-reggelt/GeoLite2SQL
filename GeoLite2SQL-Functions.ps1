<###   FUNCTIONS   ###>
Function Debug ($DebugOutput) {
	If ($VerboseFile) {Write-Output "$(Get-Date -f G) : $DebugOutput" | Out-File $DebugLog -Encoding ASCII -Append}
	If ($VerboseConsole) {Write-Host "$(Get-Date -f G) : $DebugOutput"}
}

Function Email ($Email) {
	If ($UseHTML){
		If ($Email -match "\[OK\]") {$Email = $Email -Replace "\[OK\]","<span style=`"background-color:green;color:white;font-weight:bold;font-family:Courier New;`">[OK]</span>"}
		If ($Email -match "\[INFO\]") {$Email = $Email -Replace "\[INFO\]","<span style=`"background-color:yellow;font-weight:bold;font-family:Courier New;`">[INFO]</span>"}
		If ($Email -match "\[ERROR\]") {$Email = $Email -Replace "\[ERROR\]","<span style=`"background-color:red;color:white;font-weight:bold;font-family:Courier New;`">[ERROR]</span>"}
		If ($Email -match "^\s$") {$Email = $Email -Replace "\s","&nbsp;"}
		Write-Output "<tr><td>$Email</td></tr>" | Out-File $EmailBody -Encoding ASCII -Append
	} Else {
		Write-Output $Email | Out-File $EmailBody -Encoding ASCII -Append
	}	
}

Function EmailResults {
	Debug "GeoIP update finished"
	Email " "
	Email "GeoIP update finish: $(Get-Date -f G)"
	If ($UseHTML) {
		If ($UseHTML) {Write-Output "</table></body></html>" | Out-File $EmailBody -Encoding ASCII -Append}
	}
	If (($AttachDebugLog) -and (Test-Path $DebugLog)) {
		If (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize) {
			Email "Debug log too large to email. Please see file in GeoLite2SQL script folder."
		}
	}
	Try {
		$Body = (Get-Content -Path $EmailBody | Out-String )
		If (($AttachDebugLog) -and (Test-Path $DebugLog) -and (((Get-Item $DebugLog).length/1MB) -lt $MaxAttachmentSize)){$Attachment = New-Object System.Net.Mail.Attachment $DebugLog}
		$Message = New-Object System.Net.Mail.Mailmessage $EmailFrom, $EmailTo, $Subject, $Body
		$Message.IsBodyHTML = $UseHTML
		If (($AttachDebugLog) -and (Test-Path $DebugLog) -and (((Get-Item $DebugLog).length/1MB) -lt $MaxAttachmentSize)){$Message.Attachments.Add($DebugLog)}
		$SMTP = New-Object System.Net.Mail.SMTPClient $SMTPServer,$SMTPPort
		$SMTP.EnableSsl = $UseSSL
		$SMTP.Credentials = New-Object System.Net.NetworkCredential($SMTPAuthUser, $SMTPAuthPass); 
		$SMTP.Send($Message)
	}
	Catch {
		Debug "Email ERROR : $($Error[0])"
	}
}

Function Plural ($Integer) {
	If ($Integer -eq 1) {$S = ""} Else {$S = "s"}
	Return $S
}

Function ElapsedTime ($EndTime) {
	$TimeSpan = New-Timespan $EndTime
	If (([int]($TimeSpan).Hours) -eq 0) {$Hours = ""} ElseIf (([int]($TimeSpan).Hours) -eq 1) {$Hours = "1 hour "} Else {$Hours = "$([int]($TimeSpan).Hours) hours "}
	If (([int]($TimeSpan).Minutes) -eq 0) {$Minutes = ""} ElseIf (([int]($TimeSpan).Minutes) -eq 1) {$Minutes = "1 minute "} Else {$Minutes = "$([int]($TimeSpan).Minutes) minutes "}
	If (([int]($TimeSpan).Seconds) -eq 1) {$Seconds = "1 second"} Else {$Seconds = "$([int]($TimeSpan).Seconds) seconds"}
	
	If (($TimeSpan).TotalSeconds -lt 1) {
		$Return = "less than 1 second"
	} Else {
		$Return = "$Hours$Minutes$Seconds"
	}
	Return $Return
}

Function MySQLQuery($Query) {
	$Today = (Get-Date).ToString("yyyyMMdd")
	$DBErrorLog = "$PSScriptRoot\$Today-DBError.log"
	$ConnectionString = "server=" + $MySQLHost + ";port=" + $MySQLPort + ";uid=" + $MySQLUserName + ";pwd=" + $MySQLPassword + ";database=" + $MySQLDatabase + ";SslMode=" + $MySQLSSL + ";Default Command Timeout=" + $MySQLCommandTimeOut + ";Connect Timeout=" + $MySQLConnectTimeout + ";"
	$Error.Clear()
	Try {
		[void][System.Reflection.Assembly]::LoadWithPartialName("MySql.Data")
		$Connection = New-Object MySql.Data.MySqlClient.MySqlConnection
		$Connection.ConnectionString = $ConnectionString
		$Connection.Open()
		$Command = New-Object MySql.Data.MySqlClient.MySqlCommand($Query, $Connection)
		$DataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($Command)
		$DataSet = New-Object System.Data.DataSet
		$RecordCount = $DataAdapter.Fill($DataSet, "data")
		$DataSet.Tables[0]
	}
	Catch {
		Debug "[ERROR] DATABASE ERROR : Unable to run query : $Query $($Error[0])"
	}
	Finally {
		$Connection.Close()
	}
}

Function CheckForUpdates {
	Debug "----------------------------"
	Debug "Checking for script update at GitHub"
	$GitHubVersion = $LocalVersion = $NULL
	$GetGitHubVersion = $GetLocalVersion = $False
	$GitHubVersionTries = 1
	Do {
		Try {
			$GitHubVersion = [decimal](Invoke-WebRequest -UseBasicParsing -Method GET -URI https://raw.githubusercontent.com/palinkas-jo-reggelt/GeoLite2SQL/master/version.txt).Content
			$GetGitHubVersion = $True
		}
		Catch {
			Debug "[ERROR] Obtaining GitHub version : Try $GitHubVersionTries : Obtaining version number: $($Error[0])"
		}
		$GitHubVersionTries++
	} Until (($GitHubVersion -gt 0) -or ($GitHubVersionTries -eq 6))
	If (Test-Path "$PSScriptRoot\version.txt") {
		$LocalVersion = [decimal](Get-Content "$PSScriptRoot\version.txt")
		$GetLocalVersion = $True
	}
	If (($GetGitHubVersion) -and ($GetLocalVersion)) {
		If ($LocalVersion -lt $GitHubVersion) {
			Debug "[INFO] Upgrade to version $GitHubVersion available at https://github.com/palinkas-jo-reggelt/GeoLite2SQL"
			If ($UseHTML) {
				Email "[INFO] Upgrade to version $GitHubVersion available at <a href=`"https://github.com/palinkas-jo-reggelt/GeoLite2SQL`">GitHub</a>"
			} Else {
				Email "[INFO] Upgrade to version $GitHubVersion available at https://github.com/palinkas-jo-reggelt/GeoLite2SQL"
			}
		} Else {
			Debug "Backup & Upload script is latest version: $GitHubVersion"
		}
	} Else {
		If ((-not($GetGitHubVersion)) -and (-not($GetLocalVersion))) {
			Debug "[ERROR] Version test failed : Could not obtain either GitHub nor local version information"
			Email "[ERROR] Version check failed"
		} ElseIf (-not($GetGitHubVersion)) {
			Debug "[ERROR] Version test failed : Could not obtain version information from GitHub"
			Email "[ERROR] Version check failed"
		} ElseIf (-not($GetLocalVersion)) {
			Debug "[ERROR] Version test failed : Could not obtain local install version information"
			Email "[ERROR] Version check failed"
		} Else {
			Debug "[ERROR] Version test failed : Unknown reason - file issue at GitHub"
			Email "[ERROR] Version check failed"
		}
	}
}

