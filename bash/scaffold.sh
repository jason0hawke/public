#
### This file has been sanitized ###
#!/usr/bin/env bash

# Created by Jason Hawke on 00.00.2024
# Edited by Jason Hawke on 00.00.2026

# region Script Background

# scaffold.sh is a Bash script to to get some specific information from one or more F5 BigIP Appliances
# using iControl REST calls via the f5LibUtility.sh library script. The information is collected and 
# written to a file and emailed to the user for troubleshooting purposes. This script is meant to be a 
# starting point for building out more complex scripts to collect specific information for troubleshooting or inventory purposes.

# To-Do List:
# 1. Things I need to cover next
#

## Script Objectives:
# 1. Clearly Worded objectives/Requirements to keep me focused.
#

# See help function and readme file for more detailed information

# The Required Inputs are:
# 1. A config file: scaffold.cfg
# 2. The pre-populated lists of hosts: hostInfo.cfg
# 3. The library script: f5LibUtility.sh
# 4. The library script config file: f5LibUtility.cfg

# endregion

# region Script Setup

# Check /var/log/messages and $logFile for more information

# Debug option - type "DEBUG=1" in front of the script invocation:
[[ "${DEBUG:-}" == "1" ]] && set -x

#variables
scriptName=scaffold.sh
userConfigFile=scaffold.cfg
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

# endregion

# talk2Hosts is a function to iterate through an array and execute tasks on those hosts
talk2Hosts() {
	echo "Starting to communicate with hosts - please be patient - this may take awhile"

	setTable # this is a function in the library script to set up the table format for writing to screen and file. The headerLabels array is defined in the user config file and is used by this function to set the column headers and widths.

	# this loop iterates through the hostArray and calls the scaffold function for each host. The scaffold function is where the iControl calls are made to get the desired information from each host. The results are written to the screen and to the email file in a table format.
	# note that the getAtoken and deleteToken functions from the library script are used to manage the authentication tokens for each host when making iControl REST calls. If either of these functions fail for a host, an error is logged and the script continues to the next host in the array.
	for i in "${hostArray[@]}"
	do
		getAtoken "$i" "$userName" "$userPassword" || { logError "WARN" "$i" "skipping host - getAtoken failed"; continue; }
		scaffold $i
		deleteToken "$i" || { logError "WARN" "$i" "skipping host - deleteToken failed"; continue; }
	done

	clearTable # this is a function in the library script to reset the table format variables for the next time we want to use it. This is important to avoid formatting issues if you want to write to the screen or file again later in the script.

	echo "" | tee -a "$emailFile"
	hostArraySize=${#hostArray[@]}
	echo "Done talking to $hostArraySize hosts - did your coffee get cold?"
	echo "***" >> $emailFile
	echo "$hostArraySize is the host count - check your numbers!" >> $emailFile
	myLogger "Done with host communication"
}

# scaffold is a function to get specified information for troubleshooting later $1=host IP
scaffold() {
	#local var's
	local host
	host=$1

	# Note that we're going to use the stats associative array to store our data
	# Reset stats for the current loop iteration
	local -A stats

	# populating the host info - this is usually the first column in the table
	stats["Host"]="$host"

	# below is an example of how to use the talk2iControl function from the library script to get specific information from the host using iControl REST calls. The results are stored in the stats associative array with keys corresponding to the header labels defined in the user config file. You can add as many of these as you want to collect different pieces of information from the hosts. Just make sure to update the headerLabels array in the user config file and to use the same keys in the stats array here in the scaffold function.
	# check restjavad ext ram
	local restjava_json
	if [[ " ${headerLabels[*]} " == *"RESTjavaRAM"* ]]; then
		restjava_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/provision.restjavad.extramb") || { logError "WARN" "$host" "skipping host - RESTjava RAM check failed"; return 1; }
		stats["RESTjavaRAM"]=$(echo "$restjava_json" | jq -r '.value // "N/A"')
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

	scaffold.sh is a Bash script to get some specific information from one or more F5 BigIP Appliances using iControl REST calls

	The 'test' option is a quick test function. This will perform a ping test and a simple iControl call.
	This test verifies that network connectivity is working and iControl is working.

	Syntax is: scaffold.sh -d <IDC> -e <ENV> -z <Zone>

	IDC is: east west all
	ENV is: lab tst qa prod all
	Zone is: dmz int all

	HINT: You can use 'all' for any of the above options in multiple combinations

	To run against a target group:     scaffold.sh -d <IDC> -e <ENV> -z <Zone>
	To check your connections use '-t': scaffold.sh -d <IDC> -e <ENV> -z <Zone> -t
	For interactive mode use '-i':      scaffold.sh -i
	To pass a target host use '-h':     scaffold.sh -h <FQDN or IP>
	To invoke this menu use '-?':       scaffold.sh -?

	Log data goes to /var/log/messages via the myLogger command. Hint - grep for your userID
	Log data also goes to logs/scaffold.sh.log in the script directory
	A job completion email is sent with abbreviated log data as well.

	All flags:
	-d is for the target data center (Options are: east west all)
	-e is for the target environment (Options are: lab tst qa prod all)
	-z is for the target security zone (Options are: dmz int all)

	-t is for connection test
	-i is for interactive mode (prompts for a single host IP or FQDN)
	-h is for a known host passed as either an IP or FQDN. Note FQDN must be valid in DNS

	-? is for help display

	DEBUG=1 scaffold.sh <flags> <options> to run in debug mode

	***
EOF
	myLogger "Displayed help function"
	goodBye
}

# region of main line
#store arguments from run time

clear
echo "Starting scaffold script execution..."
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
		configureEnvVariables $dcVar $enVar $zoneVar
		echo ""
fi
if [ "$testFlag" == "1" ]
	then
		#this is a test
		connectionTest
		goodBye
	else
		# proceed as usual
		echo ""
fi
grabTheKeys # this is a function in the library script to grab the necessary credentials for talking to the hosts. It uses the $dcVar, $enVar, and $zoneVar variables to determine which credentials to grab based on the configuration in the library script config file. The credentials are stored in variables that are used by the talk2iControl function when making iControl REST calls to the hosts.
constructEmailFile $dcVar $enVar $zoneVar # this is a function in the library script to construct the email file name and path based on the $dcVar, $enVar, and $zoneVar variables. The email file is where the output of the script will be written to and then emailed to the user at the end of the script. The file name includes the data center, environment, zone, and a timestamp for easy identification.
talk2Hosts # this is the main function to talk to the hosts. It iterates through the hostArray and calls the scaffold function for each host to collect the desired information and write it to the screen and email file in a table format.
emailReport # this is a function in the library script to email the report to the user. It uses the $emailFile variable for the file to attach and the $dcVar, $enVar, and $zoneVar variables to construct the email subject and body. The email is sent using the mail command and includes a brief message and the attached report file.
goodBye # this is the end of the script - the goodBye function is used to log that the script is complete and to exit the script.

# endregion main line