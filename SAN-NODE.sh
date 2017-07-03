#!/bin/bash

### CONFIG ###
serviceSAN="10.10.10.100"
serviceSANBroad="10.10.10.255"
serviceLOCAL="10.150.132.100"
serviceLOCALBroad="10.150.132.255"

primarySAN="10.10.10.101"
primaryLOCAL="10.150.132.101"
primaryDRBD="10.100.100.101"

secondarySAN="10.10.10.102"
secondaryLOCAL="10.150.132.102"
secondaryDRBD="10.100.100.102"

vmwareHPSAN="10.10.10.3"
vmwareIBMSAN="10.10.10.6"

drbdName="BackgroundMain"
### END CONFIG ##

drbd_get_status() { # 0-primary uptodate; 1-secondary uptodate; 2-secondary inconsisten -> remote uptodate; 3-kataklizm;
	st="`drbdadm role $drbdName`"
	st_own=${st%/*}
	echo own: $st_own
	Log=$Log"OwnRole:$st_own\n"
	st_remote=${st#*/}
	echo remote: $st_remote
	Log=$Log"RemoteRole:$st_remote\n"
	dst="`drbdadm dstate $drbdName`"
	dst_own=${dst%/*}
	echo down: $dst_own
	Log=$Log"OwnData:$dst_own\n"
	dst_remote=${dst#*/}
	echo dremote: $dst_remote
	Log=$Log"RemoteData:$dst_remote\n"
	if [ "$st_own" == "Primary" ] && [ "$dst_own" == "UpToDate" ]; then
		return 0
	elif [ "$st_own" == "Secondary" ] && [ "$dst_own" == "UpToDate" ]; then
		return 1
	elif [ "$st_own" == "Secondary" ] && ! [ "$dst_own" == "UpToDate" ] && [ "$dst_remote" == "UpToDate" ]; then
		return 2
	else
		return 3 #TOTAL FAIL ...
	fi
	export $Log
}

drbd_try_sync(){
	cst="`drbdadm cstate $drbdName`"
	if [ "$cst" == "WFConnection" ] || [ "$cst" == "StandAlone" ]; then
		if [ "$dry_run" -eq 0 ]; then
			drbdadm connect $drbdName
			a=$?
		else
			a=0
		fi
		if [ $a -ne 0 ]; then
			mail_admin "Nie mogę się zsynchornizawać z drugim nodem, pozdrawiam $node"
		fi
		return $a
	else
		if [ "`cat /proc/drbd | grep SyncTarget`" ] || [ "`cat /proc/drbd | grep SyncSource`" ] ;then
			mail_admin "Trwa synchornizacja..., pozdrawiam $node"
			return $a
		fi
		return 0
	fi
}

reboot_primary() {
	if [ "$dry_run" -eq 0 ]; then
		ssh root@nas1.pnet "reboot"
	fi
}

check_primary() { # 0-jest NAS1; 1-NAS1 jest tylko po DRBD; 2-nie ma NAS1
	ping -c2 -W1 $primarySAN
	if [ $? -ne 0 ]; then
		ping -c 2 -W 1 $primaryLOCAL
		if [ $? -ne 0 ]; then
			ping -c 2 -W 1 $primaryDRBD 
			if [ $? -ne 0 ]; then
				return 2
			fi
			return 1
		fi
		return 0
	fi	
	return 0
}

check_vmware() {
	ping -c2 -W1 $vmwareHPSAN
	if [ $? -ne 0 ]; then
		ping -c2 -W1 $vmwareIBMSAN
		if [ $? -ne 0 ]; then
			return 1
		fi
		return 0
	fi
	return 0
}

check_service() {
	ping -c5 -W1 $serviceSAN
	if [ $? -ne 0 ]; then
		ping -c5 -W1 $serviceLOCAL
		if [ $? -ne 0 ]; then
			return 1
		fi
		return 0
	fi
	return 0
}

service_takeover() { #moze sprawdzenie ?
	if [ "$dry_run" -eq 0 ]; then
		echo Taking over service...
		if [ "$drbdstat" -gt 1 ];then
			mail_admin "Nieudana próba przejęcia zasobów, pozdrawiam $node"
			#czy drbd jest up to date ? jezeli nie to return -1
			return 2
		fi
		#TODO: sprawdzic primary/primary drbdadm 
		drbd_set_primary
		force_scst_ip
		/etc/init.d/scst stop
		/etc/init.d/scst start
		if [ $? -ne 0 ]; then
			mail_admin "Fatalnie nieudane przejęcie zasobów. pozdrawiam $node."
			return 1
		fi
		mail_admin "Udane przejęcie zasobów przez $node, pozdrawiam $node."
		return 0
	fi
}

drbd_set_primary() {
	if [ "$dry_run" -eq 0 ]; then
		if [ "$node" == "primary" ];then
			PID="`ssh root@$secondarySAN \"ps aux| grep '/scripts/SANwrapper.sh' | grep -v grep\"`";
			PID="`echo $PID | awk '{print $2}'`"
			if [ "$PID" -gt 0 ];then 
				ssh root@$secondarySAN "kill -9 $PID"
			fi
			#ssh root@$secondarySAN "killall -9 /scripts/SANwrapper.sh"
			ssh root@$secondarySAN "/etc/init.d/scst stop"
			#fi
			ssh root@$secondarySAN "drbdadm secondary $drbdName"
			drbdadm primary $drbdName > /tmp/drbd_error
			ssh root@$secondarySAN "/scripts/SANwrapper.sh secondary & disown"
		elif [ $node == "secondary" ]; then
			ssh root@$primarySAN "drbdadm secondary $drbdName"
			drbdadm primary $drbdName > /tmp/drbd_error
		fi
		if [ $? -ne 0 ];then
			mail_admin "Błąd przejmowania zasobów. `cat /tmp/drbd_error`, pozdrawiam $node"
		fi
	fi
}

force_scst_ip() { # moze jakies sprawdzenie ?
	
	if [ "$dry_run" -eq 0 ]; then
		if [ "$node" == "primary" ];then
			ssh root@$secondarySAN "ip addr del $serviceSAN/24 dev eth2"
			ssh root@$secondarySAN "ip addr del $serviceLOCAL/24 dev eth0"
		elif [ "$node" == "secondary" ]; then
			ssh root@$primarySAN "ip addr del $serviceSAN/24 dev eth2"
			ssh root@$primarySAN "ip addr del $serviceLOCAL/24 dev eth0"
		fi
		if [ "`ip a | egrep -c \"inet ($serviceSAN|$serviceLOCAL)\"`" -ne 2 ]; then
			ip add add $serviceSAN/24 dev eth2
			ip add add $serviceLOCAL/24 dev eth0
		fi

		arping -s 10.10.10.100 -I eth2 10.10.10.6 -c2 &
		arping -s 10.150.132.100 -I eth0 10.150.132.6 -c2 &
		arping -s 10.10.10.100 -I eth2 10.10.10.3 -c2 &
		arping -s 10.150.132.100 -I eth0 10.150.132.3 -c2 &
	fi
}

mail_admin() {
	echo "$*"
	if [ "$*" == "`cat /tmp/san_script_mail`" ];then 
		return 1
	fi
	if [ "$dry_run" -eq 0 ]; then
		echo Wysylam
		echo -e "From: srv@pnet\nContent-Type: text/plain; format=flowed; charset=UTF-8;\nSubject:Info SAN\nDate: `date -R`\n\n$*\nPoniżej LOG operacji:\n$Log\n\n" | msmtp --auto-from=off --from=srv@pnet --account=srv -- serwis@petroinform.net
		echo "$*" > /tmp/san_script_mail
	fi
	return 0;
}

## end of fun ##

node=$1
operation=$2
dry_run=0

if [ $# -gt 3 ]; then
	echo "Usage: $0 (node) (operation) [-d]"
	echo "node: primary | secondary"
	echo "operation: boot | check"
	echo "-d - dry run"
	exit -1;
elif [ $# -eq 3 ] && [ "$3" == "-d" ];then
	dry_run=1
	echo "Performing Dry RUN\n"
elif [ $# -eq 2 ];then
	echo "Performing Normal Run"
else
	echo "Usage: $0 (node) (operation) [-d]"
	echo "node: primary | secondary"
	echo "operation: boot | check"
	echo "-d - dry run"
	exit -1;
fi
if ! [ "$1" == "primary" ] && ! [ "$1" == "secondary" ]; then
	echo "Usage: $0 (node) (operation) [-d]"
	echo "node: primary | secondary"
	echo "operation: boot | check"
	echo "-d - dry run"
	exit -1;
fi
if ! [ "$2" == "boot" ] && ! [ "$2" == "check" ];then
	echo "Usage: $0 (node) (operation) [-d]"
	echo "node: primary | secondary"
	echo "operation: boot | check"
	echo "-d - dry run"
	exit -1;
fi

drbd_get_status # 0-primary uptodate; 1-secondary uptodate; 2-secondary inconsisten -> remote uptodate; 3-kataklizm;
drbdstat=$?

case $operation in
	"boot" )
		Log=$Log"Boot operation for node: $node\n"
		if [ "$node" == "primary" ]; then
			Log=$Log"Pinging service IP on SAN interface\n"
			ping $serviceSAN -c2 -W1
			if [ $? -ne 0 ]; then #w sieci nie ma adresu ip uslugi
				Log=$Log"Service NOT FOUND on SAN -- taking over\n"
				service_takeover
			else #w sieci jest adres ip uslugi (nie ma tym komputerze)
				if [ -z "`ip a | egrep \"inet $serviceSAN\"`" ]; then
					Log=$Log"Service IP is not on THIS host, checking DRDB status...\n"
					if [ "$drbdstat" -eq 0 ] || [ "$drbdstat" -eq 1 ]; then #ten node jest uptodate
						Log=$Log"DRBD UpToDate, taking over...\n"
						service_takeover
					elif [ "$drbdstat" -eq 2 ]; then #ten node jest inconsistent -- remote jest uptodate
						Log=$Log"DRBD NOT uptodate, trying to sync...\n"
						drbd_try_sync
					else #nie ma nikogo uptodate
						mail_admin "BRAINSPLIT !!! Data corrupted -- $node"
						exit 2
					fi
				else
					Log=$Log"Service IP is on this host, checking scst\n"
					iscst="`netstat -ntuape | grep iscsi-scstd`"
					if [ -z "$iscst" ];then #jezeli nie uslugi scstd na liscie netstata
						Log=$Log"SCST not launched -- takingover\n"
						service_takeover
					else
						Log=$Log"All in order\n"
					fi
				fi
					
			fi
		elif [ "$node" == "secondary" ]; then
			Log=$Log"Sleeping 120 sec\n"
			sleep 120
			Log=$Log"Checking for primary NAS\n"
			check_primary
			if [ $? -gt 0 ]; then
				Log=$Log"Could not find primary NAS\n"
				Log=$Log"Checking is VMWARE available\n"
				check_vmware
				if [ $? -eq 0 ]; then
					Log=$Log"VMWARE available, taking over\n"
					service_takeover
				else
					Log=$Log"VMWARE NOT available, network error ? No actions taken.\n"
				fi
			else
				Log=$Log"Primary present, checking service IP\n"
				if [ -z "`ip a | egrep \"inet $serviceSAN\"`" ]; then
					Log=$Log"Service IP is not on this host. Pinging service address\n"
					check_service
					if [ $? -ne 0 ];then
						Log=$Log"Service unavailable, sleeping 360 sec\n"
						sleep 360
						Log=$Log"Testing again service IP\n"
						check_service
						if [ $? -ne 0 ];then
							Log=$Log"Critical error on primary NAS, trying remote reboot\n"
							mail_admin "Primary does not have SCST IP address, forcing its reboot remotly -- $node"
							reboot_primary
						fi
					else
						Log=$Log"Service present, no action taken.\n"
					fi
				else
					Log=$Log"Service IP is on THIS host -- checking DRDB and SCST\n"
					if [ "$drbdstat" -eq 0]; then
						Log=$Log"This node is UPTODATE and PRIMARY, cheking scst\n"
						iscst="`netstat -ntuape | grep iscsi-scstd`"
						if [ -z "$iscst" ];then #jezeli nie uslugi scstd na liscie netstata
							Log=$Log"SCST not launched -- takingover\n"
							service_takeover
						else
							Log=$Log"This node is Service, no action taken.\n"
						fi
					else
						Log=$Log"Remote should be service, removing service IP and NOTIFYING ADMIN\n"
						if [ "$dry_run" -eq 0 ]; then
							/etc/init.d/scst stop
							ip addr del $serviceSAN/24 dev eth2
							ip addr del $serviceLOCAL/24 dev eth0
							mail_admin "Error detected in with IP addresses and SCST settings within SAN. Required human intevention -- $node"
						fi
					fi
				fi
			fi
		fi
		;;
	"check" )
		Log=$Log"Check operation for node: $node\n"
		cst="`drbdadm cstate $drbdName`"
		if [ "$cst" == "StandAlone" ]; then
			Log=$Log"This host is StandAlone, tryingto connect with remote"
			if [ "$dry_run" -eq 0 ]; then
				drbdadm connect $drbdName
			fi
		fi
		if [ "$drbdstat" -lt 2 ] && [ "$node" == "primary" ]; then
			Log=$Log"This PRIMARY host should have Service, checking ...\n"
			iscst="`netstat -ntuape | grep iscsi-scstd`"
			if [ -z "$iscst" ];then #jezeli nie uslugi scstd na liscie netstata
				Log=$Log"No scst running, taking over\n"
				service_takeover
			else
				Log=$Log"SCST running, checking service IP on THIS host\n"
				if [ "`ip a | egrep -c \"inet ($serviceSAN|$serviceLOCAL)\"`" -ne 2 ]; then
					Log=$Log"This host does not have service IP addresses, forcing IP setup and restarting SCST"
					if [ "$dry_run" -eq 0 ]; then
						force_scst_ip
						/etc/init.d/scst stop
						/etc/init.d/scst start
					fi
				fi
			fi
		elif [ "$drbdstat" -eq 2 ] && [ "$node" == "primary" ]; then
			Log=$Log"This host is not uptodate, trying to sync"
			drbd_try_sync
		elif [ "$drbdstat" -eq 3 ] && [ "$node" == "primary" ]; then
			Log=$Log"This host is not uptodate, trying to sync"
			drbd_try_sync
		elif [ "$node" == "secondary" ]; then
			Log=$Log"Checking for primary NAS\n"
			check_primary
			if [ $? -gt 0 ]; then
				Log=$Log"Could not find primary NAS\n"
				Log=$Log"Checking is VMWARE available\n"
				check_vmware
				if [ $? -eq 0 ]; then
					Log=$Log"VMWARE available, taking over\n"
					service_takeover
				else
					Log=$Log"VMWARE NOT available, network error ? No actions taken.\n"
				fi
			else
				Log=$Log"Primary present, checking service IP\n"
				if [ -z "`ip a | egrep \"inet $serviceSAN\"`" ]; then
					Log=$Log"Service IP is not on this host. Pinging service address\n"
					check_service
					if [ $? -ne 0 ];then
						Log=$Log"Service unavailable, sleeping 360 sec\n"
						sleep 360
						Log=$Log"Testing again service IP\n"
						check_service
						if [ $? -ne 0 ];then
							Log=$Log"Critical error on primary NAS, trying remote reboot\n"
							mail_admin "Primary nie ma adresu SCST, przeprowadzam zdalny reboot, pozdrawiam $node"
							reboot_primary
						fi
					else
						Log=$Log"Service present, no action taken.\n"
					fi
				else
					Log=$Log"Service IP is on THIS host -- checking DRDB and SCST\n"
					if [ "$drbdstat" -eq 0 ]; then
						Log=$Log"This node is UPTODATE and PRIMARY, cheking scst\n"
						iscst="`netstat -ntuape | grep iscsi-scstd`"
						if [ -z "$iscst" ];then #jezeli nie uslugi scstd na liscie netstata
							Log=$Log"SCST not launched -- takingover\n"
							service_takeover
						else
							Log=$Log"This node is Service, no action taken."
						fi
					else
						Log=$Log"Remote should be service, removing service IP and NOTIFYING ADMIN\n"
						if [ "$dry_run" -eq 0 ]; then
							/etc/init.d/scst stop
							ip addr del $serviceSAN/24 dev eth2
							ip addr del $serviceLOCAL/24 dev eth0
							mail_admin "Problem z adresem usługi i ustawieniami SCST w macierzy, wymagana interwencja administratora, pozrawiam $node"
						fi
					fi
				fi
			fi
		fi
		;;
esac

if [ "$dry_run" -eq 1 ];then
	echo "Log operacji:"
	echo -ne "$Log"
fi
