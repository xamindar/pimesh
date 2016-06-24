#!/bin/bash
# depends: NetworkManager (nmcli), grep, cut, 
# listed used access points in arrays based on desired usage. If the same SSID is listed in more than one tier, the lowest 
# allowed data one will be used. If it isn't listed at all, INGRESS will be used.
INGRESS_DATA=("RedSpaceman" "YellowSpaceman" "BlueSpaceman" "BajaBlast" "CodeRed") #only ingress data
LIMITED_DATA=("Origin Jumpworks 350R") #limited data connections, autossh active
#these will override other connections if available (not for low signal Ingress usage)
FULL_DATA=("HomeBase2022") #Priority full access connections
#try available access points in this order, with any not listed at the end
PRIORITY_LIST=("HomeBase2022" "Origin Jumpworks 350R" "RedSpaceman" "YellowSpaceman" "BlueSpaceman")

############################################################

### function to get list of available connections to try ###
#-->Sets up SORTED_USEABLE_WIFI variable
get_available_ap(){
#tell NetworkManager to rescan
nmcli device wifi rescan
#declare/reset arrays
USEABLE_WIFI=()
SORTED_USEABLE_WIFI=()
current_data_service=null
IFS=$'\n'
SAVED_WIFI=($(nmcli -t -f name,type con | grep "802-11-wireless" | cut -f1 -d":"))
AVAILAVLE_WIFI=($(nmcli -t -f ssid d wifi))


#create list of usabale wifi (both broadcasting and listed as saved networkmanager connections)
for s_wifi in "${SAVED_WIFI[@]}"
do
	for a_wifi in "${AVAILAVLE_WIFI[@]}"
	do
		if [ "$s_wifi" == "$a_wifi" ]
		then
			USEABLE_WIFI+=($s_wifi)
		fi
	done
done
#sort the list based on PRIORITY_LIST
for ap_order in "${PRIORITY_LIST[@]}"
do
	for non_order in "${USEABLE_WIFI[@]}"
	do
		if [ "$ap_order" == "$non_order" ]
		then
			SORTED_USEABLE_WIFI+=($ap_order)
			break
		fi
	done
done
#add any not listed in priority at the end of SORTED_USEABLE_WIFI
for non_priority in "${USEABLE_WIFI[@]}"
do
	ap_exists=no
	for ap_order2 in "${SORTED_USEABLE_WIFI[@]}"
	do
		if [ "$non_priority" == "$ap_order2" ]
		then
			ap_exists=yes
		fi
	done
	if [ "$ap_exists" == "no" ]
	then
		SORTED_USEABLE_WIFI+=($non_priority)
	fi
done

}
############################################################


### functions to turn off/on services based on connection ###

ingress_services(){
if [ $current_data_service == "ingress" ]
then
	echo "Ingress data limits already set"
else
	echo "Setting Ingress data restrictions"
	systemctl stop autossh.service
	systemctl stop syncthing@xamindar.service
	current_data_service=ingress
fi
}

limited_data_services(){
if [ $current_data_service == "limited" ]
then
	echo "limited data limits already set"
else
	echo "Setting limited data restrictions"
	systemctl start autossh.service
	systemctl stop syncthing@xamindar.service
	current_data_service=limited
fi
}

full_access_services(){
if [ $current_data_service == "full" ]
then
	echo "full data limits already set"
else
	echo "Setting full data usage and services"
	systemctl start autossh.service
	systemctl start syncthing@xamindar.service
	current_data_service=full
fi
}

#############################################################

### function to switch to FULL_ACCESS connection if found ###
full_connection(){
get_available_ap
#try the next available connection
already_full_con=no
current_con=$(nmcli -t -f name,type con show --active | grep "802-11-wireless" | cut -f1 -d":")
echo "current connection is: $current_con"
for f_wifi in "${FULL_DATA[@]}"
do
	if [ "$current_con" == "$f_wifi" ]
	then
		echo "Already connected to a full connection."
		already_full_con=yes
		break
	fi
done

#look for and connect to FULL_DATA connection if available
if [ $already_full_con == no ]
then
	for wifi_ap in "${SORTED_USEABLE_WIFI[@]}"
	do
		for f_wifi in "${FULL_DATA[@]}"
		do
			if [ "$wifi_ap" == "$f_wifi" ]
			then
	        		echo "Full access AP in range, connecting to $wifi_ap"
	        		nmcli con up "$wifi_ap" && sleep 5
	        		if [ "$(nmcli networking connectivity check)" == "full" ]
	        		then
	                		already_full_con=yes
	                		echo "Full connection $wifi_ap has internet!"
					full_access_services  #call function above to set full access
	                		break 2
	        		else
	                		echo "no internet, trying next one"
	        		fi
			fi
		done
	done
fi


}

#############################################################

### function to switch to the next available connection ###

next_connection(){
get_available_ap
HAVE_INTERNET=no
#try the next available connection
current_con=$(nmcli -t -f name,type con show --active | grep "802-11-wireless" | cut -f1 -d":")
echo "current connection is: $current_con"
for wifi_ap in "${SORTED_USEABLE_WIFI[@]}"
do
	echo "This is the current one testing: $wifi_ap"
	if [ "$current_con" == "$wifi_ap" ]
	then
		echo "already connected, continuing to the next one."
		continue
	else
		echo "connecting to next available AP: $wifi_ap"
		nmcli con up "$wifi_ap" && sleep 5
		if [ "$(nmcli networking connectivity check)" == "full" ]
		then
			HAVE_INTERNET=yes
			echo "WE HAVE THE INTERNETS ON: $wifi_ap"
			break
		else
			echo "no internet, trying next one"
			#continue
		fi	
		echo "does this ever run???"	
	fi
done


#mod_services(){
# and then enable/disable services based on connection listed in following arrays: INGRESS_DATA, LIMITED_DATA, FULL_DATA
current_con=$(nmcli -t -f name,type con show --active | grep "802-11-wireless" | cut -f1 -d":")
if [ ! -z "$current_con" ]
then
	data_limit_set=no
	for wifi_list in "${INGRESS_DATA[@]}"
	do
		if [ "$current_con" == "$wifi_list" ]
		then
			ingress_services
			data_limit_set=yes
		fi
	done
	
	if [ "$data_limit_set" == "no" ]
	then
		for wifi_list in "${LIMITED_DATA[@]}"
		do
		        if [ "$current_con" == "$wifi_list" ]
		        then
		                limited_data_services
		                data_limit_set=yes
		        fi
		done
	fi
	if [ "$data_limit_set" == "no" ]
	then
		for wifi_list in "${FULL_DATA[@]}"
		do
		        if [ "$current_con" == "$wifi_list" ]
		        then
		                full_access_services
		                data_limit_set=yes
		        fi
		done
	fi
	#defaults to ingress services (most restricted) if not in any list
	if [ "$data_limit_set" == "no" ]
	then
		ingress_services
	fi	
fi

}

#########################################################################################

### function to check for internet access ###
internet_check(){
if (( $(ping -c1 -w1 -n -q 8.8.8.8 | grep -c "1 received") == 1 ))
then
        return 0
else
        return 1
fi

# nmcli networking connectivity check

}

########################################################################################


### MAIN FUNCTION

while true
do
	if [ "$(nmcli networking connectivity check)" == "full" ]
	then
		echo "Internet is still up, checking for any available full-access connections."
		full_connection
		sleep 15
	else
		echo "internet appears down, trying next available ap."
		next_connection
	fi
done









