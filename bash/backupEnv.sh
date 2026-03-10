#
### This file has been sanitized ###
#!/usr/bin/env bash

# backupEnv.sh is a Bash script to to backup one or more F5 BigIP Appliances using iControl REST calls

# To-Do List:
# 0. Implement a table system for reporting on status of backups:
#   Hostname | Backup Status | Job Duration | File Copied | Size of Backup
#   Can we do a dynamic update in the table while job is in process? Ideally with a spinner?
# 1. Make sure all required external programs are installed (e.g., sshpass, jq)
# 2. Can we externalize the file copying and cleanup functions to the library script for reuse?
# 3. Environment check for ~/f5backups/ and create if not present. NOTE this should be a *LINK* to /foo1/f5backups/ to avoid filling up the local disk
# 4. Convert error and log handling to new functions in the library script for consistency and ease of maintenance
# 5. Add a function to delete the UCS file from the host after it's copied to the local host - this will save space on the F5
# 6. Validate there are no constants and that everything is a variable that can be set in the config file or passed at run time

# The Required Inputs are:
# 1. A config file: backupEnv.cfg
# 2. The pre-populated lists of hosts: hostInfo.cfg

# Created by Jason Hawke on 02.28.2022
# Edited by Jason Hawke on 03.08.2026

# Check /var/log/messages for more information

# Debug option - type "DEBUG=1" in front of the script invocation:
[[ "${DEBUG:-}" == "1" ]] && set -x

#variables
scriptName=backupEnv.sh
userConfigFile=backupEnv.cfg
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

manageLog
myLogger "**** Local Script Specific Logs are in $logFile ****"

# talk2Hosts is a function to iterate through an array and execute tasks on those hosts
talk2Hosts() {
	echo "Starting to communicate with hosts - please be patient - this may take awhile"

	for i in "${hostArray[@]}"
	do
		getAtoken "$i" "$userName" "$userPassword" || { logError "WARN" "$i" "skipping host - getAtoken failed"; continue; }
		if saveMyButt "$i"; then
			grabFiles "$i"
		else
			myLogger "Skipping file copy for $i - backup task did not complete successfully"
			echo "Skipping file copy for $i - backup task did not complete successfully" | tee -a "$emailFile"
		fi
		deleteToken "$i" || { logError "WARN" "$i" "skipping host - deleteToken failed"; continue; }
	done

	printSummaryTable

	hostArraySize=${#hostArray[@]}
	fileList
	echo "Done talking to $hostArraySize hosts - did your coffee get cold?"
	echo "***" >> $emailFile
	echo "$hostArraySize is the host count - check your numbers!" >> $emailFile
	myLogger "Done with host communication"
}

# make a backup receives $1=host IP
saveMyButt() {
	echo "*** Starting saveMyButt function for $1 ***"
	host=$1
	echo ""

	# create the backup task and store its ID in taskID var
	# taskID=`curl -sk -u $userName:$userPassword -H "Content-Type: application/json" -X POST https://$host/mgmt/tm/task/sys/ucs -d '{"command":"save","name":"/var/local/ucs/saveMyButt.ucs"}' | jq -r '._taskId'`
	local createTask_json
	createTask_json=$(talk2iControl "$host" "/mgmt/tm/task/sys/ucs" "POST" '{"command":"save","name":"/var/local/ucs/saveMyButt.ucs"}') \
	    || { logError "ERROR" "$host" "Failed to create backup task - skipping host"; return 1; }
	taskID=$(jq -r '._taskId' <<< "$createTask_json")
	echo "backup job on $host is being tracked via task $taskID"
	myLogger "backup job on $host is being tracked via task $taskID"
	echo ""

	# activate the backup taskinfo
	# curl -sk -u $userName:$userPassword -H 'Content-Type: application/json' -X PUT -d '{"_taskState":"VALIDATING"}' https://$host/mgmt/tm/task/sys/ucs/"$taskID" | jq '.'
	local activateTask_json
	activateTask_json=$(talk2iControl "$host" "/mgmt/tm/task/sys/ucs/$taskID" "PUT" '{"_taskState":"VALIDATING"}') \
	    || { logError "ERROR" "$host" "Failed to activate backup task - skipping host"; return 1; }
	myLogger "$(jq '.' <<< "$activateTask_json")" # redirecting from screen to log
	echo "backup task $taskID on $host has been activated"
	myLogger "backup task $taskID on $host has been activated"
	echo ""

	# monitor the status of the backup task
	taskStatus="UNKNOWN"
	jobDuration="N/A"
	myLogger "checking on backup task $taskID on $host"
	if ! waitForTask "$host" "/mgmt/tm/task/sys/ucs/$taskID" '._taskState' "COMPLETED"; then
	    addTableRow "$host" "$taskStatus" "$jobDuration"
	    return 1
	fi
	echo "UCS creation function on host $1 is done"
	myLogger "UCS creation function on host $1 is done"

	addTableRow "$host" "$taskStatus" "$jobDuration"

	echo ""
	echo "***"
}

# scp the ucs file to the local host
# receives $1=host IP
grabFiles() {
	echo "Starting grabFiles function for $1"
	host=$1
	mkdir -p "$targetDir"
	echo ""
	local scp_output # redirect scp output from screen to log
	scp_output=$(sshpass -p $userPassword scp -o StrictHostKeyChecking=accept-new $userName@$host:/var/local/ucs/$ucsVar "$targetDir""$host.$ucsVar" 2>&1)
	[[ -n "$scp_output" ]] && myLogger "$scp_output"
	echo "UCS file copied from $i"
	logger "UCS file copied from $i"
	chgrp -R UserGroup "$targetDir"*
	chmod -R g+w "$targetDir"*
	echo "Group ownership udpated for access reasons"
	echo ""
	myLogger "Group ownership udpated for access reasons"
}

# list the archives and drop them into the end of the email
fileList() {
	fileCount=`ls -1 "$targetDir"*ucs | wc -l`

	# screen display below
	echo ""
	echo "*** Here is a list of the archives we have ****"
	du -sh "$targetDir"*ucs
	echo ""
	echo "We have $fileCount backup files"

	# email display below
	echo "*** This is the size of the archives ****" >> $emailFile
	du -sh "$targetDir"*ucs >> $emailFile
	echo "" >> $emailFile
	echo "We have $fileCount backup files" >> $emailFile
	echo "" >> $emailFile
	echo "PLEASE DELETE THE OLD BACKUP FILES in $targetPath " >> $emailFile
	echo "" >> $emailFile
	myLogger "$fileCount backup files detected and added to email"
}

# goodBye function - housekeeping and cleanup
goodBye() {
	echo ""
	echo "IMPORTANT: Please delete the old backup files in $targetPath when you're done!"
	echo ""
	myLogger "******************* $scriptName Script is Complete *******************"
	exit
}

# help function
displayHelp() {
	cat << "EOF"
	***
	This is the help display
	***

	backupEnv.sh is a Bash script to backup one or more F5 BigIP Appliances using iControl REST calls
	After the UCS is created the script SCPs the file to the local host.
	Backups are stored in a timestamped subdirectory under ~/f5backups/ (e.g., ~/f5backups/YYYY.MM.DD.HHMMSS.ucsBackups/)
	UCS files are named <host>.saveMyButt.ucs

	The 'test' option is a quick test function. This will perform a ping test and a simple iControl call.
	This test verifies that network connectivity is working and iControl is working.

	Syntax is: backupEnv.sh -d <IDC> -e <ENV> -z <Zone>

	IDC is: east west all
	ENV is: lab tst qa prod all
	Zone is: dmz int all

	HINT: You can use 'all' for any of the above options in multiple combinations

	To run against a target group:      backupEnv.sh -d <IDC> -e <ENV> -z <Zone>
	To check your connections use '-t': backupEnv.sh -d <IDC> -e <ENV> -z <Zone> -t
	For interactive mode use '-i':      backupEnv.sh -i
	To pass a target host use '-h':     backupEnv.sh -h <FQDN or IP>
	To invoke this menu use '-?':       backupEnv.sh -?

	Log data goes to /var/log/messages via the logger command. Hint - grep for your userID
	Log data also goes to logs/backupEnv.sh.log in the script directory
	A job completion email is sent with the summary table, file list, and sizes.

	All flags:
	-d is for the target data center (Options are: east west all)
	-e is for the target environment (Options are: lab tst qa prod all)
	-z is for the target security zone (Options are: dmz int all)

	-t is for connection test
	-i is for interactive mode (prompts for a single host IP or FQDN)
	-h is for a known host passed as either an IP or FQDN. Note FQDN must be valid in DNS

	-? is for help display

	VERY IMPORTANT - please delete the old backups when you're done!!!

	***
EOF
	myLogger "Displayed help function"
	goodBye
}

# main line
#store arguments from run time

clear
echo "Starting backup script execution..."
echo ""

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
			logger "$targetHost was passed at run time"
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
grabTheKeys
constructEmailFile $dcVar $enVar $zoneVar
talk2Hosts
emailReport
goodBye
