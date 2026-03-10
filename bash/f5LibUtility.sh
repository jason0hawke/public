#
### This file has been sanitized ###
#!/usr/bin/env bash

# region script info

# f5LibUtility.sh is a Bash script library of utility functions that support another utility script that will
# be used to administer F5 BigIP Appliances using iControl REST calls.

# This is not meant to be a standalone script but rather a library of functions that can be used in other scripts.

# See help function and readme file for more detailed information.

# The Required Inputs are:
# 1. The pre-populated lists of hosts: hostInfo.cfg
# 2. The supporting config file f5LibUtility.cfg

## To-Do:
# 1. Add error handling and security improvements around using control-c to exit the script

# endregion

# Created by Jason Hawke on 02.25.2026
# Edited by Jason Hawke on 03.08.2026

# Check /var/log/messages  and $logFile for more information

# grabTheKeys is a function to read in the userID and password from the CLI
grabTheKeys() {
	myLogger "asking dad for the keys"
	echo "In order to execute this script we need to use an account with access to the systems."
	echo "Please answer the next two questions:"

	echo ""
	echo "What userID do you want to use?"
	read -r userName
	[[ -z "$userName" ]] && { logError ERROR "$(uname -n)" "username cannot be empty"; exit 1; }

	echo ""
	echo "What is the password?"
	read -r -s  userPassword
	[[ -z "$userPassword" ]] && { logError ERROR "$(uname -n)" "password cannot be empty"; exit 1; }

	myLogger "got the keys but not telling anyone"
}

# getAtoken is a function to get an authentication token from the F5 BigIP Appliance
# token and tokenID will be set after this function is called
# $1=host, $2=userName, $3=userPassword
getAtoken() {
	local host=$1
	local user=$2
	local pass=$3
	
	local auth_json
	auth_json=$(jq -n \
		--arg user "$user" \
		--arg pass "$pass" \
		--arg loginProviderName "$authProvider" \
		'{
			"username": $user,
			"password": $pass,
			"loginProviderName": $loginProviderName
		}') || { logError "ERROR" "$host" "failed to construct authentication JSON"; return 1; }
	
	local token_json
	token_json=$(curl -sk -X POST \
		-H "Content-Type: application/json" \
		-d "$auth_json" \
		"https://$host/mgmt/shared/authn/login") || { logError "ERROR" "$host" "failed to connect to authentication endpoint"; return 1; }

	token=$(echo "$token_json" | jq -r '.token.token // empty')
	tokenID=$(echo "$token_json" | jq -r '.token.tokenId // empty')
	[[ -z "$token" || "$token" == "null" ]] && { logError "ERROR" "$host" "authentication failed - could not obtain a valid token (check credentials)"; return 1; }

	# set the token expiration time using tokenTime from cfg
	local timeout_json
	timeout_json=$(jq -n \
		--arg timeout "$tokenTime" \
		'{
			"timeout": $timeout
		}') || { logError "ERROR" "$host" "failed to construct token timeout JSON"; return 1; }

	local extend_response
	extend_response=$(curl -sk -X PATCH \
		-H "Content-Type: application/json" \
		-H "X-F5-Auth-Token: $token" \
		-d "$timeout_json" \
		"https://$host/mgmt/shared/authz/tokens/$tokenID") || { logError "ERROR" "$host" "failed to set token expiration time"; return 1; }
		
	myLogger "done getting a token from $host for $user"
}

# deleteToken is a function to delete the authentication token from the F5 BigIP Appliance when we're done
# $1=host
deleteToken() {
	local host=$1

	local delete_response
	delete_response=$(curl -sk -X DELETE \
		-H "Content-Type: application/json" \
		-H "X-F5-Auth-Token: $token" \
		"https://$host/mgmt/shared/authz/tokens/$tokenID") || { logError "ERROR" "$host" "failed to delete authentication token"; return 1; }
	
	token=""
	tokenID=""

	myLogger "done deleting token on $host for $userName"
}

# myLogger function sends messages to system log facility and to a local app log
# $1=message to log
myLogger() {
	logger "$1" 2>/dev/null || true   # system logger, fail silently
	echo "$1" >> "$logFile"
}

# manageLog creates the log directory if needed, then rotates the current log to .old
# keeps only the current run and the previous one
manageLog() {
	mkdir -p "$logDir"
	[[ -f "$logFile" ]] && mv "$logFile" "${logFile}.old"
	myLogger "******************* Log started for $scriptName *******************"
}

# logError function aids in error capture
logError() {
	local level=$1    # e.g., INFO, WARN, ERROR
	local target=$2   # The host IP or "SYSTEM"
	local message=$3  # The description of what happened

	# Format: Timestamp [LEVEL] [HOST] - MESSAGE
	local log_msg
	log_msg="$(date '+%Y-%m-%d %H:%M:%S') [$level] [$target] - $message"

	# Send to system log and echo to screen for the user
	echo "$log_msg" >&2
	myLogger "$log_msg"
}

# setTable is a function to setup our table for reporting data
setTable() {

	for entry in "${tableHeader[@]}"; do
	    width="${entry#*:}" # extracting width for each column
	    FMT+="%-${width}s " # Build FMT dynamically for printf so we have a pretty table
		headerLabels+=("${entry%%:*}") # extracting header lables
		tableWidth=$((tableWidth + width + 1)) # calculate the total column size of the table for borders. +1 for the space between columns
	done
	FMT+="\n"

	# starting to create the table and populate it
	echo "<pre>" >> "$emailFile"
	printf "$FMT" "${headerLabels[@]}" | tee -a "$emailFile"
	printf "%${tableWidth}s\n" | tr ' ' '=' | tee -a "$emailFile"

	myLogger "table is set"
}

# clearTable is a function to make any final edits to the table before email and script close out
clearTable() {
	printf "%${tableWidth}s\n" | tr ' ' '=' | tee -a "$emailFile"
	echo "</pre>" >> "$emailFile"

	myLogger "done with building table"
}

# printTableRow writes one data row immediately to screen and email
# Pass column values as arguments in the same order as tableHeader
# Example: printTableRow "$host" "SUCCEEDED" "45s"
printTableRow() {
	# shellcheck disable=SC2059
	printf "$FMT" "$@" | tee -a "$emailFile"
	myLogger "${*}"
}

# addTableRow buffers a row for later batch printing via printSummaryTable
# Pass column values as arguments in the same order as tableHeader
# Example: addTableRow "$host" "SUCCEEDED" "45s"
addTableRow() {
	local row
	row=$(printf '%s|' "$@")
	summaryRows+=("${row%|}")
}

# printSummaryTable prints the complete table (header + all buffered rows + footer) at once
# Call this after all hosts are processed so the table appears as a clean summary
printSummaryTable() {
	setTable
	for row in "${summaryRows[@]}"; do
	    IFS='|' read -ra cols <<< "$row"
	    # shellcheck disable=SC2059
	    printf "$FMT" "${cols[@]}" | tee -a "$emailFile"
	    myLogger "${cols[*]}"
	done
	clearTable
	summaryRows=()
}

# waitForTask polls an async iControl task until it reaches a success state or times out
# $1=host, $2=uri (full path including taskID), $3=jq status field (e.g. '.status'), $4=success value (e.g. "SUCCEEDED")
# Sets globals: taskStatus, jobDuration
# Returns: 0 on success, 1 on timeout or API error
waitForTask() {
	local host=$1
	local uri=$2
	local statusField=$3
	local successValue=$4
	local timer=0
	local startTime=$SECONDS
	local startEpoch
	local displayPid=""
	local task_endpoint_seen=0
	startEpoch=$(date +%s)
	taskStatus="pending"
	jobDuration=""

	echo "checking on task at $uri on $host"
	echo "We have $timeOut seconds to complete the task"
	myLogger "waitForTask: polling $uri on $host (expecting $statusField == $successValue)"

	# _startDisplay and _stopDisplay manage a background subprocess that shows a live
	# elapsed-time counter. date +%s is used (not $SECONDS) because $SECONDS resets
	# to 0 in a forked subshell; date +%s is absolute and consistent across processes.
	# _startDisplay kills any existing display before starting a new one so that
	# calling it multiple times never leaks orphaned background processes.
	_startDisplay() {
	    local msg=$1
	    [[ -n "$displayPid" ]] && { kill "$displayPid" 2>/dev/null; wait "$displayPid" 2>/dev/null; }
	    ( trap 'exit 0' INT TERM
	      while true; do
	        local elapsed=$(( $(date +%s) - startEpoch ))
	        printf "\r  [ elapsed: %02d:%02d:%02d ] %s" \
	            $((elapsed / 3600)) \
	            $(( (elapsed % 3600) / 60 )) \
	            $((elapsed % 60)) \
	            "$msg"
	        sleep 0.5
	      done ) &
	    displayPid=$!
	}

	_stopDisplay() {
	    [[ -n "$displayPid" ]] && { kill "$displayPid" 2>/dev/null; wait "$displayPid" 2>/dev/null; }
	    printf "\r%70s\r" ""
	    displayPid=""
	}

	while [ "$timer" != "$timeOut" ]
	    do
	    local statusCheck_json

	    # Start display at the top of every iteration so it covers the API call time
	    _startDisplay "checking with iControl on $host..."
	    local talk2iControl_rc=0
	    statusCheck_json=$(talk2iControl "$host" "$uri" "GET") || talk2iControl_rc=$?

	    if [[ "$talk2iControl_rc" -eq 2 ]]; then
	        # 404: only treat as completion if we've seen the endpoint respond before.
	        # If task_endpoint_seen=0, the endpoint never existed - that's a real error.
	        _stopDisplay
	        if [[ "$task_endpoint_seen" -eq 1 ]]; then
	            taskStatus="$successValue"
	            jobDuration="$((SECONDS - startTime))s"
	            echo "task on $host is complete - TMOS removed the task record (duration was $jobDuration)"
	            myLogger "waitForTask: task on $host: 404 after prior response - TMOS cleaned up task record, treating as $successValue"
	            return 0
	        else
	            logError "ERROR" "$host" "Task endpoint $uri not found (404) and was never reached - task ID may be invalid"
	            taskStatus="ERROR"
	            jobDuration="${timer}s (error)"
	            return 1
	        fi
	    elif [[ "$talk2iControl_rc" -eq 3 ]]; then
	        # 400: body was returned - endpoint was reached (mark it seen) and fall through
	        # to parse whatever state is in the body. If _taskState is absent, loop again.
	        task_endpoint_seen=1
	    elif [[ "$talk2iControl_rc" -ne 0 ]]; then
	        _stopDisplay
	        logError "ERROR" "$host" "Failed to check task status at $uri - exiting loop"
	        taskStatus="ERROR"
	        jobDuration="${timer}s (error)"
	        return 1
	    else
	        # 2xx: normal successful poll - endpoint is confirmed reachable
	        task_endpoint_seen=1
	    fi

	    taskStatus=$(jq -r "$statusField // \"UNKNOWN\"" <<< "$statusCheck_json")
	    _stopDisplay

	    if [[ "$taskStatus" == "$successValue" ]]
	        then
	            echo "The current task status is: $taskStatus"
	            jobDuration="$((SECONDS - startTime))s"
	            echo "task on $host is complete (duration was $jobDuration)"
	            myLogger "waitForTask: task on $host completed with status $taskStatus in $jobDuration"
	            return 0
	        else
	            ((timer += sleepTime))
	            myLogger "waitForTask: task on $host still running (status=$taskStatus, timer=${timer}s) - will check again in ${sleepTime}s"
	            # Embed the current status in the display message so it rolls with the timer in-place
	            _startDisplay "status: $taskStatus | waiting before next check on $host..."
	            sleep "$sleepTime"
	    fi
	done

	_stopDisplay
	echo "The current task status is: $taskStatus (timed out)"
	[[ -z "$jobDuration" ]] && jobDuration="${timeOut}s (timed out)"
	myLogger "waitForTask: task on $host timed out after $timeOut seconds (last status=$taskStatus)"
	return 1
}

# talk2iControl is a function to connect directly to iControl endpoint
# $1=host, $2=uri, $3=method, $4=json data
talk2iControl() {
	local host=$1
	local uri=$2
	local method=$3
	local json=$4
	local tmp_file
	local http_status

	tmp_file=$(mktemp talk2iControl.resp.json.XXXXXX)
	trap 'rm -f "$tmp_file"' RETURN


	# Execute curl: capture status code and save body to file
	myLogger "talk2iControl is using $method to access https://$host$uri"

	# Case is used to determine HTTP Method
	case $method in
		GET)
		# HTTP Method is a 'GET'
		http_status=$(curl -sk -H "X-F5-Auth-Token: $token" \
	        -H "Content-Type: application/json" \
	        -X GET "https://$host$uri" \
	        -o "$tmp_file" \
	        -w "%{http_code}")
		;;

		POST)
		# HTTP Method is a 'POST'
		http_status=$(curl -sk -H "X-F5-Auth-Token: $token" \
	        -H "Content-Type: application/json" \
	        -X POST "https://$host$uri" \
			-d "$json"\
	        -o "$tmp_file" \
	        -w "%{http_code}")
		;;

		PATCH)
		# HTTP Method is a 'PATCH'
		http_status=$(curl -sk -H "X-F5-Auth-Token: $token" \
	        -H "Content-Type: application/json" \
	        -X PATCH "https://$host$uri" \
			-d "$json"\
	        -o "$tmp_file" \
	        -w "%{http_code}")
		;;

		PUT)
		# HTTP Method is a 'PUT'
		http_status=$(curl -sk -H "X-F5-Auth-Token: $token" \
	        -H "Content-Type: application/json" \
	        -X PUT "https://$host$uri" \
			-d "$json"\
	        -o "$tmp_file" \
	        -w "%{http_code}")
		;;

		DELETE)
		# HTTP Method is a 'DELETE'
		http_status=$(curl -sk -H "X-F5-Auth-Token: $token" \
	        -H "Content-Type: application/json" \
	        -X DELETE "https://$host$uri" \
	        -o "$tmp_file" \
	        -w "%{http_code}")
		;;

		*)
		# HTTP Method is a 'GET' the default choice
		http_status=$(curl -sk -H "X-F5-Auth-Token: $token" \
	        -H "Content-Type: application/json" \
	        -X GET "https://$host$uri" \
	        -o "$tmp_file" \
	        -w "%{http_code}")
		;;

	esac

	    if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
	        # Success: Output the file content so it can be captured in a variable
	        cat "$tmp_file"
	    elif [ "$http_status" -eq 401 ]; then
	        # Bad credentials - username or password was rejected
	        logError "ERROR" "$host" "Authentication failed (401) for user '$userName' - check username and password"
	        return 1
	    elif [ "$http_status" -eq 403 ]; then
	        # Credentials valid but account lacks permission for this endpoint
	        logError "ERROR" "$host" "Authorization denied (403) for user '$userName' on $uri - check account role (requires Administrator or Resource Administrator)"
	        return 1
	    elif [ "$http_status" -eq 400 ]; then
	        # Bad request - F5 sometimes returns 400 with the final task state in the body
	        # (e.g., when a completed UCS task is polled). Return exit code 3 and the body
	        # so waitForTask can track that this endpoint was reached and inspect the state.
	        logError "WARN" "$host" "Received 400 from $uri - task may be in a terminal state; inspecting response body"
	        cat "$tmp_file"
	        return 3
	    elif [ "$http_status" -eq 404 ]; then
	        # Endpoint not found. For async task endpoints this is expected on success -
	        # TMOS deletes the task record when it completes. Return exit code 2 so
	        # waitForTask can distinguish this from a hard failure.
	        logError "WARN" "$host" "API endpoint $uri not found (404) - task may have completed and been cleaned up by TMOS"
	        echo "{}"
	        return 2
	    else
	        # Failure: Log the error and return a non-zero exit code
	        logError "ERROR" "$host" "API call to $uri failed with status $http_status"
	        return 1
	    fi
}

# bounceAservice is a function to restart a service when required
# $1=host IP
bounceAservice() {
	#local var's
	local host
	host=$1
	
	# a guard clause to make sure the stub version of the serviceList array isn't being used.
	if [[ ${#serviceList[@]} -eq 0 ]]; then
		logError "WARN" "$host" "the serviceList array is empty - did you forget something?"
		return 1
	fi

	echo ""
	echo "NOTE: Service restarts may display alerts - DON'T PANIC!" 
	echo "The script is polling the service status and will report when the service is back up or if it fails to restart."
	echo ""
	for service in "${serviceList[@]}"; do
		local status="false" # track the outcome of the service restart and polling

		echo "Restarting of $service on $host is starting - this may take awhile - please be patient"

		# service restart
		local service_json
		service_json=$(jq -n \
			--arg cmd "bigstart restart ${service}" \
    		'{
				"command": "run", "utilCmdArgs": ("-c \"" + $cmd + "\"")
			}') || { logError "WARN" "$host" "skipping host - $service JSON construction failed"; continue; }
		local response
		response=$(talk2iControl "$host" "/mgmt/tm/util/bash" "POST" "$service_json") ||  logError "WARN" "$host" "Non-Actionable response"
		myLogger "Restart command issued for $service on $host - response: $response"

		# service polling
		sleep "$startTime" # pause before checking if the service is up
		local timer="$startTime" # initialize timer
		while [ "$timer" -le "$breakTime" ]; do
			# Check if the service is up
			local servicePoll_json
			servicePoll_json=$(jq -n \
				--arg cmd "bigstart status ${service}" \
				'{
					"command": "run", "utilCmdArgs": ("-c \"" + $cmd + "\"")
				}') || { logError "WARN" "$host" "skipping host - $service poll JSON construction failed"; continue; }
			
			local serviceResponse
			serviceResponse=$(talk2iControl "$host" "/mgmt/tm/util/bash" "POST" "$servicePoll_json") || logError "WARN" "$host" "skipping host - $service poll failed"
			myLogger "Service Poll Response is: $serviceResponse"

			if echo "$serviceResponse" | jq -r '.commandResult' | grep -q "run (pid"; then
				myLogger "$service is running on $host - response: $serviceResponse"
				echo "Restarting of $service on $host took $timer seconds to complete"
				status="true"
				break
			else
				myLogger "$service is not up yet on $host - response: $serviceResponse"
				sleep "$serviceTimer" # wait before the next poll
				timer=$((timer + serviceTimer)) # increment timer
				echo "Waiting for $service to start on $host - $timer seconds elapsed so far"
			fi
		done

		if [ "$status" != "true" ]; then
			logError "WARN" "$host" "$service did not start within expected time - manual check recommended"
			echo " *** ALERT *** Restarting of $service on $host did not complete within expected time - please investigate!" 
		fi
	done
	myLogger "bounceAservice function finished for $host"
}

# constructEmailFile function will construct a skeleton of an email
# $1=IDC, $2=ENV, $3=Zone
constructEmailFile() {
	echo ""
	echo "... writing an email"
	myLogger "constructing an email via constructEmailFile function"

	#clean up any previous files
	if [[ -f "$emailFile" ]]; then
	        rm "$emailFile"
	fi
	touch "$emailFile"
	echo ""

	# heredoc for base email
	cat > "$emailFile" << EOF
To: $f5_email
From: $f5_email
Subject: $userName ran the $scriptName script from $HOSTNAME
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
<pre>
The $enVar environment in the $zoneVar zone in the $dcVar IDC is being operated on.
<hr>
EOF

	echo "... ready to send the email"
	echo ""

	myLogger "base email is complete done with constructEmailFile function"
}

# emailReport is a function to email a report
emailReport() {
	echo "</pre>" >> "$emailFile"
	echo "<hr>" >> "$emailFile"
	sendmail -vt < "$emailFile"
	myLogger "emailed report - content below:"
	myLogger "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

	while IFS= read -r line
		do myLogger "$line"
	done < "$emailFile"

	rm "$emailFile" #clean up for the next user
	myLogger "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}

# connectionTest is a function to validate network connectivity to the hosts
connectionTest() {
	echo "A connection test will be conducted and then we'll quit"
	grabTheKeys
	verNum=0
	myLogger "Starting the connection test"
	constructEmailFile
	{
	    echo "<pre>"
	    echo "************ Below is a list of hosts that were tested ************"
	    echo ""
	} >> "$emailFile"
	echo "Ready to start the connection test - will we get there or not?"
	for i in "${hostArray[@]}"
	do
		echo "Ping test for host $i"
		ping -c 3 "$i"
		echo ""

		{
			echo ""
			echo "$i was tested on $(date)"
			echo "######################################"
			ping -c 3 "$i"
		} >> "$emailFile"
		myLogger "ping test for $i complete"

		host=$i
		# check TMOS version
		local version_json
		version_json=$(talk2iControl "$host" "/mgmt/tm/sys/version" "GET") || { logError "WARN" "$host" "skipping host - version check failed"; continue; }
		verNum=$(echo "$version_json" | jq -r 'first(.entries[].nestedStats.entries | select(has("Version"))) | .Version.description + (if (.Edition.description | test("Hotfix"; "i")) then " (HF)" else "" end)')

		myLogger "curl test for $i complete"

		echo ""
		echo "iControl test for host $i"
		echo "$host is running TMOS version $verNum"
		echo ""

		{
			echo ""
			echo "iControl test for host $i"
			echo "$host is running TMOS version $verNum"
			echo ""
			echo "######################################"
		} >> "$emailFile"
	done
	echo "</pre>" >> "$emailFile"
	hostArraySize=${#hostArray[@]}
	echo ""
	echo "***"
	echo "$hostArraySize is the host count - check your numbers!"
	echo "***"
	echo ""

	{
	    echo ""
	    echo "***"
	    echo "$hostArraySize is the host count - check your numbers!"
	    echo ""
	} >> "$emailFile"
	emailReport
	myLogger "Done with the testing"
}

# ask function to interactively gather the variables
ask() {
	# can request a 'target' so that just one IP is used - this could be used to go 'back' and fix broken installs
	echo ""
	myLogger "interactive mode triggered - talking to the user"
	echo "Interactive mode triggered - what host do you want to talk to?"
	read -r targetHost
	hostArray=("$targetHost")
}

# any_key function will pause the script until a key is typed
any_key() {
	logger "any_key function started"
	echo "Press any key to continue"
	while true
		do
			read -n 1
				if [[ $? = 0 ]]
				then
					break
				fi
		done
	logger "any_key function finished"
}

logger "the function library f5LibUtility.sh has been sourced"

# writeConfig2Disk saves the TMSH configuration to disk
# $1=host (IP or FQDN)
writeConfig2Disk () {
	local host=$1

	echo ""
	echo ""
	echo "Saving the configuration to disk on $1"
	host=$1

	local save_json
	if ! save_json=$(talk2iControl "$host" "/mgmt/tm/sys/config" "POST" '{"command":"save"}'); then
		logError "WARN" "$host" "configuration save failed - continuing anyway"
	elif ! echo "$save_json" | jq -e '.kind == "tm:sys:config:savestate"' > /dev/null 2>&1; then
	    logError "WARN" "$host" "configuration save response was unexpected: $save_json - continuing anyway"
	else
	    echo "Configuration saved successfully on $host"
	fi

	echo ">>> $host has written its configuration to disk >>>" >> "$emailFile"
	myLogger "configuration saved to disk on $host"
}

# EOF
