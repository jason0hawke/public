#
### This file has been sanitized ###
#!/usr/bin/env bash

# Created by Jason Hawke on 03.05.2026
# Edited by Jason Hawke on 03.08.2026

# region Script Background

# changeIT.sh is a Bash script to update settings on one or more F5 BigIP Appliances
# using iControl REST calls via the f5LibUtility.sh library script.

## To-Do List:
# 0. Continue to refine bounceAservice so that the wait period works until service is confirmed up.
# 1. How can I issue this command, "bigstart restart restjavad" remotely via iControl? Or is there an alternative?
# 2. How can I issue this command, "bigstart restart restnoded" remotely via iControl? Or is there an alternative?
# 3. How can we make this script more modular and reusable for other settings changes?
# 	Can we make the settings we want to change more dynamic so that we can easily update the script for different
# 	use cases without having to hard code specific settings in the changeIT function? I just want to update changeIT.cfg
# 4. Will multiple associative arrays that hold the URI endpoints and JSON config data work as a dynamic solution?

## Script Objectives:
# 1. Display the settings *before* changes are made.
# 2. Make the desired changes to the settings.
# 3. Display the settings *after* changes are made to verify that the changes were successful.
# 4. Log all actions and results to a log file and send an email report with the results.

# See help function and readme file for more detailed information

# The Required Inputs are:
# 1. A config file: changeIT.cfg
# 2. The pre-populated lists of hosts: hostInfo.cfg
# 3. The library script: f5LibUtility.sh
# 4. The library script config file: f5LibUtility.cfg

# endregion

# Check /var/log/messages and $logFilefor more information

# Debug option - type "DEBUG=1" in front of the script invocation:
[[ "${DEBUG:-}" == "1" ]] && set -x

#variables
scriptName=changeIT.sh
userConfigFile=changeIT.cfg
hostsConfigFile=hostsInfo.cfg
libScript=f5LibUtility.sh
libScriptConfigFile=f5LibUtility.cfg

# validate config files are present
for file in "$userConfigFile" "$hostsConfigFile" "$libScript" "$libScriptConfigFile"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: Configuration file $file not found."
        logger "Critical Error: $file missing."
        exit 1
    fi
done

# logs goto /var/log/messages and to $logFile
logger "..."
logger "******************* Starting $scriptName Script *******************"

# order matters!!! The host config file goes first, then the user config file, and then the library script
source $hostsConfigFile #contains info about the hosts
source $libScriptConfigFile #contains settings for the library script - this is separate to make it easier to update without breaking the main script
source $libScript #common used functions
source $userConfigFile #contains settings specfiic to this script and variables used by the library script

manageLog # this is a function in the library script to set up the log file for this script. It uses the $scriptName variable to name the log file and writes a starting log entry with the script name and timestamp.
myLogger "**** Local Script Specific Logs are in $logFile ****"

# talk2Hosts is a function to iterate through an array and execute tasks on those hosts
talk2Hosts() {
	echo "Please note - you *should* see three iterations fore each host: before, new value, and post-change."
	echo ""
	echo "Starting to communicate with hosts - please be patient - this may take awhile"

	setTable # this is a function in the library script to set up the table format for writing to screen and file. The headerLabels array is defined in the user config file and is used by this function to set the column headers and widths.

	# this loop iterates through the hostArray and calls the changeIT function for each host. The changeIT function is where the iControl calls are made to get the desired information from each host. The results are written to the screen and to the email file in a table format.
	for i in "${hostArray[@]}"
	do
		getAtoken "$i" "$userName" "$userPassword" || { logError "WARN" "$i" "skipping host - getAtoken failed"; continue; }
		getInfo "$i" || { logError "WARN" "$i" "skipping host - getInfo failed"; continue; }
		changeIT "$i" || { logError "WARN" "$i" "skipping host - changeIT failed"; continue; }
		getInfo "$i" || { logError "WARN" "$i" "skipping host - getInfo failed"; continue; }
		writeConfig2Disk "$i" || { logError "WARN" "$i" "skipping host - writeConfig2Disk failed"; continue; }
		bounceAservice "$i" || { logError "WARN" "$i" "skipping host - bounceAservice failed"; continue; }
		deleteToken "$i" || { logError "WARN" "$i" "skipping host - deleteToken failed"; continue; }
	done

	clearTable # this is a function in the library script to reset the table format variables for the next time we want to use it. This is important to avoid formatting issues if you want to write to the screen or file again later in the script.

	echo "" | tee -a "$emailFile"
	hostArraySize=${#hostArray[@]}
	echo "Done talking to $hostArraySize hosts - did your coffee get cold?"
	echo "***" >> "$emailFile"
	echo "$hostArraySize is the host count - check your numbers!" >> "$emailFile"
	myLogger "Done with host communication"
}

# displaySettings is a function to display the value of the settings we want to change.
# $1=host IP
displaySettings() {
	#local var's
	local host
	host=$1

	# Note that we're going to use the stats associative array to display our settings
	# Reset stats for the current loop iteration
	local -A stats

	# populating the host info - this is the first column in the table
	stats["Host"]="$host"

	# display icrd.timeout settings
	local icrd_json
		icrd_json="${newSettings["icrd.timeout"]}"
		stats["icrd.timeout"]="$icrd_json"

	# display restjavad.timeout settings
	local restjavad_json
		restjavad_json="${newSettings["restjavad.timeout"]}"
		stats["restjavad.timeout"]="$restjavad_json"

	# display restnoded.timeout settings
	local restnoded_json
		restnoded_json="${newSettings["restnoded.timeout"]}"
		stats["restnoded.timeout"]="$restnoded_json"

	# display iapplxrpm.timeout settings
	local iapplxrpm_json
		iapplxrpm_json="${newSettings["iapplxrpm.timeout"]}"
		stats["iapplxrpm.timeout"]="$iapplxrpm_json"

	# prepare rowData array for writing to screen and file
	rowData=() #emptying the array
	for label in "${headerLabels[@]}"; do
		rowData+=("${stats[$label]}")
	done

	# write data points
	printf "$FMT" "${rowData[@]}" | tee -a "$emailFile"
	myLogger "${rowData[@]}"
	myLogger "finished displaySettings function"
}

# testMode is a function to iterate through an array and execute test tasks on those hosts
testMode() {
	echo ""
	echo "We're in test mode - only settings are being displayed - no actual changes will occur"

	setTable # this is a function in the library script to set up the table format for writing to screen and file. The headerLabels array is defined in the user config file and is used by this function to set the column headers and widths.

	# this loop iterates through the hostArray and calls the changeIT function for each host. The changeIT function is where the iControl calls are made to get the desired information from each host. The results are written to the screen and to the email file in a table format.
	for i in "${hostArray[@]}"
	do
		getAtoken "$i" "$userName" "$userPassword" || { logError "WARN" "$i" "skipping host - getAtoken failed"; continue; }
		getInfo "$i" || { logError "WARN" "$i" "skipping host - getInfo failed"; continue; }
		displaySettings "$i" || { logError "WARN" "$i" "skipping host - changeIT failed"; continue; }
		getInfo "$i" || { logError "WARN" "$i" "skipping host - getInfo failed"; continue; }
		deleteToken "$i" || { logError "WARN" "$i" "skipping host - deleteToken failed"; continue; }
	done

	clearTable # this is a function in the library script to reset the table format variables for the next time we want to use it. This is important to avoid formatting issues if you want to write to the screen or file again later in the script.

	echo ""
	hostArraySize=${#hostArray[@]}
	echo "Done talking to $hostArraySize hosts - did your coffee get cold?"
	myLogger "Done with testMode function"
}

# getInfo is a function to get specified information before and after our change is made
# $1=host IP
getInfo() {
	#local var's
	local host
	host=$1

	# Note that we're going to use the stats associative array to store our data
	# Reset stats for the current loop iteration
	local -A stats

	# populating the host info
	stats["Host"]="$host"

	# check icrd.timeout settings
	local icrd_json
	if [[ " ${headerLabels[*]} " == *"icrd.timeout"* ]]; then
		icrd_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/icrd.timeout") || { logError "WARN" "$host" "skipping host - icrd timeout check failed"; return 1; }
		stats["icrd.timeout"]=$(echo "$icrd_json" | jq -r '.value // "N/A"')
	fi

	# check restjavad.timeout settings
	local restjavad_json
	if [[ " ${headerLabels[*]} " == *"restjavad.timeout"* ]]; then
		restjavad_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/restjavad.timeout") || { logError "WARN" "$host" "skipping host - restjavad timeout check failed"; return 1; }
		stats["restjavad.timeout"]=$(echo "$restjavad_json" | jq -r '.value // "N/A"')
	fi

	# check restnoded.timeout settings
	local restnoded_json
	if [[ " ${headerLabels[*]} " == *"restnoded.timeout"* ]]; then
		restnoded_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/restnoded.timeout") || { logError "WARN" "$host" "skipping host - restnoded timeout check failed"; return 1; }
		stats["restnoded.timeout"]=$(echo "$restnoded_json" | jq -r '.value // "N/A"')
	fi

	# check iapplxrpm.timeout settings
	local iapplxrpm_json
	if [[ " ${headerLabels[*]} " == *"iapplxrpm.timeout"* ]]; then
		iapplxrpm_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/iapplxrpm.timeout") || { logError "WARN" "$host" "skipping host - iapplxrpm timeout check failed"; return 1; }
		stats["iapplxrpm.timeout"]=$(echo "$iapplxrpm_json" | jq -r '.value // "N/A"')
	fi

	# prepare rowData array for writing to screen and file
	rowData=() #emptying the array
	for label in "${headerLabels[@]}"; do
		rowData+=("${stats[$label]}")
	done

	# write data points
	printf "$FMT" "${rowData[@]}" | tee -a "$emailFile"
	myLogger "${rowData[@]}"
}

# changeIT is a function to update settings on a given host
# $1=host IP
changeIT() {
	#local var's
	local host
	local timeout_value
	local timeout_json
	local response_json

	host=$1

	# Note that we're going to use the stats associative array to store our data
	# Reset stats for the current loop iteration
	local -A stats

	# populating the host info - this is the first column in the table
	stats["Host"]="$host"

	# change icrd.timeout settings
	timeout_value="${newSettings["icrd.timeout"]}"
	timeout_json=$(jq -n --arg v "$timeout_value" '{"value": $v}')
	response_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/icrd.timeout" "PATCH" "$timeout_json") || { logError "WARN" "$host" "skipping host - icrd timeout change failed"; return 1; }
	stats["icrd.timeout"]=$(echo "$response_json" | jq -r '.value // "N/A"')

	# check restjavad.timeout settings
	timeout_value="${newSettings["restjavad.timeout"]}"
	timeout_json=$(jq -n --arg v "$timeout_value" '{"value": $v}')
	response_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/restjavad.timeout" "PATCH" "$timeout_json") || { logError "WARN" "$host" "skipping host - restjavad timeout change failed"; return 1; }
	stats["restjavad.timeout"]=$(echo "$response_json" | jq -r '.value // "N/A"')

	# check restnoded.timeout settings
	timeout_value="${newSettings["restnoded.timeout"]}"
	timeout_json=$(jq -n --arg v "$timeout_value" '{"value": $v}')
	response_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/restnoded.timeout" "PATCH" "$timeout_json") || { logError "WARN" "$host" "skipping host - restnoded timeout change failed"; return 1; }
	stats["restnoded.timeout"]=$(echo "$response_json" | jq -r '.value // "N/A"')

	# check iapplxrpm.timeout settings
	timeout_value="${newSettings["iapplxrpm.timeout"]}"
	timeout_json=$(jq -n --arg v "$timeout_value" '{"value": $v}')
	response_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/iapplxrpm.timeout" "PATCH" "$timeout_json") || { logError "WARN" "$host" "skipping host - iapplxrpm timeout change failed"; return 1; }
	stats["iapplxrpm.timeout"]=$(echo "$response_json" | jq -r '.value // "N/A"')

	# prepare rowData array for writing to screen and file
	rowData=() #emptying the array
	for label in "${headerLabels[@]}"; do
		rowData+=("${stats[$label]}")
	done

	# write data points
	printf "$FMT" "${rowData[@]}" | tee -a "$emailFile"
	myLogger "${rowData[@]}"
	myLogger "finished changeIT function"
}

# goodBye function - housekeeping and cleanup
goodBye() {
	echo ""
	myLogger "******************* $scriptName Script is Complete *******************"
	exit
}

# help function
displayHelp() {
	#heredoc for base help display - note that we try and resuse the same switches to keep things consistent for the end user across different scripts. The help display should be updated as needed to reflect the functionality of this script and the available options. The myLogger function is used to log that the help function was displayed.
	cat << "EOF"
	***
	This is the help display
	***

	changeIT.sh is a Bash script to update settings on one or more F5 BigIP Appliances.

	Script Objectives:
	1. Display the settings *before* changes are made.
	2. Make the desired changes to the settings.
	3. Display the settings *after* changes are made to verify that the changes were successful.
	4. Log all actions and results to a log file and send an email report with the results.

	The 'test' option is a quick test function. This will perform a ping test and a simple iControl call.
	This test verifies that network connectivity is working and iControl is working.

	Syntax is: changeIT.sh -d <IDC> -e <ENV> -z <Zone>

	IDC is: east west all
	ENV is: lab tst qa prod all
	Zone is: dmz int all

	HINT: You can use 'all' for any of the above options in multiple combinations

	To run against a target group:     changeIT.sh -d <IDC> -e <ENV> -z <Zone>
	To check your connections use '-t': changeIT.sh -d <IDC> -e <ENV> -z <Zone> -t
	For interactive mode use '-i':      changeIT.sh -i
	To pass a target host use '-h':     changeIT.sh -h <FQDN or IP>
	To invoke this menu use '-?':       changeIT.sh -?

	Log data goes to /var/log/messages via the myLogger command. Hint - grep for your userID
	Log data also goes to logs/changeIT.sh.log in the script directory
	A job completion email is sent with abbreviated log data as well.

	All flags:
	-d is for the target data center (Options are: east west all)
	-e is for the target environment (Options are: lab tst qa prod all)
	-z is for the target security zone (Options are: dmz int all)

	-t is for connection test
	-i is for interactive mode (prompts for a single host IP or FQDN)
	-h is for a known host passed as either an IP or FQDN. Note FQDN must be valid in DNS

	-? is for help display

	***
EOF
	myLogger "Displayed help function"
	goodBye
}

# region of main line
#store arguments from run time

clear
echo "Starting changeIT script execution..."
echo ""

# This while loop uses getopts to parse the command line options passed to the script. The options include:
# -d for data center
# -e for environment
# -z for zone
# -t for test function
# -i for interactive mode
# -h for passing a target host at run time

while getopts "d:e:z:h:t?i" opt; do
	case $opt in
		d)
		#data center
		dcVar=$OPTARG
		;;

		e)
		#environment
		enVar=$OPTARG
		;;

		z)
		#zone
		zoneVar=$OPTARG
		;;

		t)
		#test function
		testFlag="1"
		;;

		i)
		#interactive
		askFlag="1"
		myLogger "askFlag=$askFlag"
		;;

		h)
		#set the target host
		targetHost=$OPTARG
		askFlag="2"
		myLogger "askFlag=$askFlag"
		;;

		?)
		# display help
		displayHelp
		exit
		;;
	esac
done
if [ "$askFlag" == "1" ]
	then
		#talk to user
		ask
	elif [ "$askFlag" == "2" ]
		then
			#host was passed at run time and stored in targetHost
			myLogger "$targetHost was passed at run time"
			hostArray=("$targetHost")
			dcVar="one"
			enVar="target"
			zoneVar="target"
			myLogger "target host is $hostArray"
	else
		#use arguments passed at run time
		configureEnvVariables "$dcVar" "$enVar" "$zoneVar"
		echo ""
fi
if [ "$testFlag" == "1" ]
	then
		#this is a test
		echo "You've selected to run a test - no changes will be made"
		echo ""
		grabTheKeys
		testMode
		goodBye
	else
		# proceed as usual
		echo ""
fi
grabTheKeys # this is a function in the library script to grab the necessary credentials for talking to the hosts
constructEmailFile "$dcVar" "$enVar" "$zoneVar" # this is a function in the library script to construct the email file
talk2Hosts # this is the main function to talk to the hosts. It iterates through the hostArray and calls the changeIT function
emailReport # this is a function in the library script to email the report to the user
goodBye # this is the end of the script

# endregion main line