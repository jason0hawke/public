#
### This file has been sanitized ###
#!/usr/bin/env bash

# getInfo.sh is a Bash script to to get some specific information from one or more F5 BigIP Appliances using iControl REST calls
# See help function and readme file for more detailed information

# To-do's:
# 1. Add token-based authentication option
# 2. Add upgrade validation checks

# The Required Inputs are:
# 1. A config file: getInfo.cfg
# 2. The pre-populated lists of hosts: hostInfo.cfg

# Created by Jason Hawke on 09.26.2024
# Edited by Jason Hawke on 03.10.2026

# Check /var/log/messages for more information

# Debug option - type "DEBUG=1" in front of the script invocation:
[[ "${DEBUG:-}" == "1" ]] && set -x

#variables
scriptName=getInfo.sh
userConfigFile=getInfo.cfg
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

	setTable

	for i in "${hostArray[@]}"
	do
		getAtoken "$i" "$userName" "$userPassword" || { logError "WARN" "$i" "skipping host - getAtoken failed"; continue; }
		getInfo $i
		deleteToken "$i" || { logError "WARN" "$i" "skipping host - deleteToken failed"; continue; }
	done

	clearTable

	echo "" | tee -a "$emailFile"
	hostArraySize=${#hostArray[@]}
	echo "Done talking to $hostArraySize hosts - did your coffee get cold?"
	echo "***" >> $emailFile
	echo "$hostArraySize is the host count - check your numbers!" >> $emailFile
	myLogger "Done with host communication"
}

# getInfo is a function to get specified information for troubleshooting later
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

	vsNum=0
	poolNum=0
	nodeNum=0
	natNum=0
	objCnt=0

	# check TMOS version
	local version_json
	if [[ " ${headerLabels[*]} " == *"Version"* ]]; then
		version_json=$(talk2iControl "$host" "/mgmt/tm/sys/version") || { logError "WARN" "$host" "skipping host - version check failed"; return 1; }
		stats["Version"]=$(echo "$version_json" | jq -r 'first(.entries[].nestedStats.entries | select(has("Version"))) | .Version.description + (if (.Edition.description | test("Hotfix"; "i")) then " (HF)" else "" end)')
	fi

	# get platform name
	local platform_json
	if [[ " ${headerLabels[*]} " == *"Platform"* ]]; then
		platform_json=$(talk2iControl "$host" "/mgmt/tm/sys/hardware") || { logError "WARN" "$host" "skipping host - hardware check failed"; return 1; }
		stats["Platform"]=$(echo "$platform_json" | jq -r '.. | objects | select(has("marketingName")) | .marketingName.description')
	fi

	# Below object counts may come back - TBD
	# ### object counts ###
	# # count virtual servers
	# #vsNum=$(curl -sk -u $userName:$userPassword -H "Content-Type: application/json" -X GET https://$host/mgmt/tm/ltm/virtual/ | jq -r '.items[].name' | wc -l)
	# local virtual_json
	# virtual_json=$(talk2iControl "$host" "/mgmt/tm/ltm/virtual/") || { logError "WARN" "$host" "skipping host - virtual server count failed"; return 1; }
	# vsNum=$(echo "$virtual_json" | jq -r '.items[].name' | wc -l)
	#
	# # count pools
	# #poolNum=$(curl -sk -u $userName:$userPassword -H "Content-Type: application/json" -X GET https://$host/mgmt/tm/ltm/pool/ | jq -r '.items[].name' | wc -l)
	# local pool_json
	# pool_json=$(talk2iControl "$host" "/mgmt/tm/ltm/pool/") || { logError "WARN" "$host" "skipping host - pool count failed"; return 1; }
	# poolNum=$(echo "$pool_json" | jq -r '.items[].name' | wc -l)
	#
	# # count nodes
	# #nodeNum=$(curl -sk -u $userName:$userPassword -H "Content-Type: application/json" -X GET https://$host/mgmt/tm/ltm/node/ | jq -r '.items[].name' | wc -l)
	# local node_json
	# node_json=$(talk2iControl "$host" "/mgmt/tm/ltm/node/") || { logError "WARN" "$host" "skipping host - node count failed"; return 1; }
	# nodeNum=$(echo "$node_json" | jq -r '.items[].name' | wc -l)
	#
	# # count nats
	# #natNum=$(curl -sk -u $userName:$userPassword -H "Content-Type: application/json" -X GET https://$host/mgmt/tm/ltm/nat/ | jq -r '.items[].name' | wc -l)
	# local nat_json
	# nat_json=$(talk2iControl "$host" "/mgmt/tm/ltm/nat/") || { logError "WARN" "$host" "skipping host - nat count failed"; return 1; }
	# natNum=$(echo "$nat_json" | jq -r '.items[].name' | wc -l)
	#
	# # object count math
	# #objCnt=$((vsNum+poolNum+nodeNum+natNum))
	# stats["${headerLabels[3]}"]=$((vsNum+poolNum+nodeNum+natNum))
	# ###

	# check restjavad ext ram
	local restjava_json
	if [[ " ${headerLabels[*]} " == *"RESTjavaRAM"* ]]; then
		restjava_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/provision.restjavad.extramb") || { logError "WARN" "$host" "skipping host - RESTjava RAM check failed"; return 1; }
		stats["RESTjavaRAM"]=$(echo "$restjava_json" | jq -r '.value // "N/A"')
	fi

	# check tomcat ext ram
	local tomcat_json
	if [[ " ${headerLabels[*]} " == *"TomcatRAM"* ]]; then
		tomcat_json=$(talk2iControl "$host" "/mgmt/tm/sys/db/provision.tomcat.extramb") || { logError "WARN" "$host" "skipping host - Tomcat RAM check failed"; return 1; }
		stats["TomcatRAM"]=$(echo "$tomcat_json" | jq -r '.value // "N/A"')
	fi

	# check auth pam timeout
	local httpd_json
	if [[ " ${headerLabels[*]} " == *"AuthPAMtimeOut"* ]]; then
		httpd_json=$(talk2iControl "$host" "/mgmt/tm/sys/httpd") || { logError "WARN" "$host" "skipping host - auth PAM timeout check failed"; return 1; }
		stats["AuthPAMtimeOut"]=$(echo "$httpd_json" | jq -r '.authPamIdleTimeout')
	fi

	# check number of cores - reuses platform_json already fetched above
	if [[ " ${headerLabels[*]} " == *"Cores"* ]]; then
		stats["Cores"]=$(echo "$platform_json" | jq -r '.. | objects | select(has("tmName") and has("version") and .tmName.description == "cores") | .version.description')
	fi

	# check ram size - uses dedicated memory endpoint (more portable across TMOS versions and VE/physical)
	local memory_json
	if [[ " ${headerLabels[*]} " == *"RAMsize"* ]]; then
		memory_json=$(talk2iControl "$host" "/mgmt/tm/sys/memory") || { logError "WARN" "$host" "skipping host - RAM size check failed"; return 1; }
		stats["RAMsize"]=$(echo "$memory_json" | jq -r '.entries | to_entries[] | select(.key | contains("memory-host")) | .value.nestedStats.entries | to_entries[0].value.nestedStats.entries.memoryTotal.value / 1073741824 | round | "\(.) GB"')
	fi

	# check CPU speed - reuses platform_json already fetched above
	if [[ " ${headerLabels[*]} " == *"CPU"* ]]; then
		stats["CPU"]=$(echo "$platform_json" | jq -r '.. | objects | select(has("model") and has("tmName") and .tmName.description == "cpus") | .model.description')
	fi

	# check serial number
	local serial_json
	if [[ " ${headerLabels[*]} " == *"SerialNumber"* ]]; then
		serial_json=$(talk2iControl "$host" "/mgmt/tm/sys/hardware") || { logError "WARN" "$host" "skipping host - serial number check failed"; return 1; }
		stats["SerialNumber"]=$(echo "$serial_json" | jq -r '
	    .entries
	    | to_entries[]
	    | .value.nestedStats.entries
	    | to_entries[]
	    | select(.key | contains("system-info/"))
	    | .value.nestedStats.entries.bigipChassisSerialNum.description
	  ')
	fi

	# check software modules provisioned - this is for the software provisioned table header option
	local software_json
	if [[ " ${headerLabels[*]} " == *"SoftwareProvisioned"* ]]; then
		software_json=$(talk2iControl "$host" "/mgmt/tm/sys/provision?\$select=name,level") || { logError "WARN" "$host" "skipping host - software provisioned check failed"; return 1; }
		stats["SoftwareProvisioned"]=$(echo "$software_json" | jq -r '[.items[] | select(.level != "none") | "\(.name):\(.level)"] | join(", ")')
	fi

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

# goodBye function - housekeeping and cleanup
goodBye() {
	echo ""
	myLogger "******************* $scriptName Script is Complete *******************"
	exit
}

# help function
displayHelp() {

	#heredoc for base help display
	cat << "EOF"
	***
	This is the help display
	***

	getInfo.sh is a Bash script to get some specific information from one or more F5 BigIP Appliances using iControl REST calls

	The 'test' option is a quick test function. This will perform a ping test and a simple iControl call.
	This test verifies that network connectivity is working and iControl is working.

	Syntax is: getInfo.sh -d <IDC> -e <ENV> -z <Zone>

	IDC is: east west all
	ENV is: lab tst qa prod all
	Zone is: dmz int all

	HINT: You can use 'all' for any of the above options in multiple combinations

	To run against a target group:     getInfo.sh -d <IDC> -e <ENV> -z <Zone>
	To check your connections use '-t': getInfo.sh -d <IDC> -e <ENV> -z <Zone> -t
	For interactive mode use '-i':      getInfo.sh -i
	To pass a target host use '-h':     getInfo.sh -h <FQDN or IP>
	To invoke this menu use '-?':       getInfo.sh -?

	Log data goes to /var/log/messages via the myLogger command. Hint - grep for your userID
	Log data also goes to logs/getInfo.sh.log in the script directory
	A job completion email is sent with abbreviated log data as well.

	All flags:
	-d is for the target data center (Options are: east west all)
	-e is for the target environment (Options are: lab tst qa prod all)
	-z is for the target security zone (Options are: dmz int all)

	-t is for connection test
	-i is for interactive mode (prompts for a single host IP or FQDN)
	-h is for a known host passed as either an IP or FQDN. Note FQDN must be valid in DNS

	-M is for memory table (displays memory settings)
	-H is for hardware table (hardware basics)
	-S is for software provisioned table (includes software module info)

	-? is for help display

	***
EOF
	myLogger "Displayed help function"
	goodBye
}

# main line
#store arguments from run time

clear
echo "Starting getInfo script execution..."
echo ""

while getopts "d:e:z:h:t?iMHS" opt; do
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

		M)
		#use the memory table header
		tableHeader=("${memoryTableHeader[@]}")
		;;

		H)
		#use the hardware table header
		tableHeader=("${hardwareTableHeader[@]}")
		;;

		S)
		#use the software provisioned table header
		tableHeader=("${softwareTableHeader[@]}")
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
grabTheKeys
constructEmailFile $dcVar $enVar $zoneVar
talk2Hosts
emailReport
goodBye
