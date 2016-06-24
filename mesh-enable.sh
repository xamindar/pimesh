#!/bin/bash

MASTER_INTERFACE=wlan0
MESH_IFACE=mesh0
STANDARD_AP_NAME=blackpi-Gateway
STANDARD_AP_PASS=doyouhaveaflag?
MESH_CHANNEL=1  #Should probably stay on 1
MESHID=mesh
INTERVAL_SECS=10
MESH_IP=10.0.0.1
NETMASK=24
CLIENT_IFACE=wlan1
IS_GATEWAY=1	# 1 for gateway(dhcp server), 0 for normal mesh node

#DO NOT CHANGE
CREATE_AP=$(which create_ap)
DHCLIENT=$(which dhclient)
MESH_READY=0
NAT_AP=0

#set CLIENT_IFACE to eth0 if chosen one not available
if [[ $(ip link | grep -c "$CLIENT_IFACE:") == 0 ]]
then
	CLIENT_IFACE=eth0
fi

#########################################################
clobber_wifi_adapter() {
echo "Something is wrong, clobbering wifi adapter"
$CREATE_AP --stop $MASTER_INTERFACE
iw dev $MESH_IFACE del
ip link set dev $MASTER_INTERFACE down
MESH_READY=0
NAT_AP=0
}

#########################################################
#Launch standard NAT AP
create_standard_ap() {
if [[ $($CREATE_AP --list-running | grep "$MASTER_INTERFACE" | cut -d' ' -f1) == $NAT_AP ]]
then
        echo "Standard NAT AP is already running. Nothing to do."
else
        $CREATE_AP --stop "$MASTER_INTERFACE"
#        $CREATE_AP --daemon --no-virt -c "$MESH_CHANNEL" -w 2 -m nat -g 172.16.35.1 "$MASTER_INTERFACE" "$MESH_IFACE" "$STANDARD_AP_NAME" "$STANDARD_AP_PASS"
        $CREATE_AP --daemon --no-virt -n -c "$MESH_CHANNEL" -w 2 -g 172.16.35.1 "$MASTER_INTERFACE" "$STANDARD_AP_NAME" "$STANDARD_AP_PASS"
        echo "Standard NAT AP is now up"
        sleep 10
	if [ $(ip addr show "$MASTER_INTERFACE" | grep -c 'inet ') == 1 ]
#        if [ $(ip link | grep -c "$MASTER_INTERFACE.*UP") == 1 ]
        then
                NAT_AP=$($CREATE_AP --list-running | grep $MASTER_INTERFACE | cut -d' ' -f1)
        else
                clobber_wifi_adapter
        fi
fi
}
#########################################################
#create/recreate mesh interface and node
create_mesh_interface() {
if [[ $(ip link | grep -c "$MESH_IFACE.*state UP") == 0 ]]
then
        echo "$MESH_IFACE does not exist or is not up, creating"
	iw dev $MESH_IFACE del
        iw dev $MASTER_INTERFACE interface add $MESH_IFACE type mp
	#Create the open mesh node
	echo "Starting open mesh node: $MESHID"
	iw dev $MESH_IFACE set channel $MESH_CHANNEL
	ip link set dev $MESH_IFACE up
	iw dev $MESH_IFACE mesh join $MESHID
else
        echo "$MESH_IFACE already exists, not touching"
fi
}

#########################################################
#mesh node: attempt to get an ip from another mesh node
mesh_node() {
#attempt to release and then obtain an ip
ip link set $MESH_IFACE up
$DHCLIENT -r $MESH_IFACE
$DHCLIENT $MESH_IFACE
}

#########################################################
#gateway node: set up mesh ip, launch dnsmasq, and enable NAT to other interfaces
gateway_node() {
echo "Setting up gateway and NAT"
ip link set $MESH_IFACE up
ip addr add $MESH_IP/$NETMASK dev $MESH_IFACE
#/usr/bin/dnsmasq -C /etc/dnsmasq-mesh.conf
systemctl start dnsmasq
}

#########################################################
enable_nat(){
if [[ $IS_GATEWAY == 0 ]]
then
	echo "Setting up NAT firewall"
	sysctl net.ipv4.ip_forward=1
	iptables -t nat -A POSTROUTING -o $MESH_IFACE -j MASQUERADE
	iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -A FORWARD -i $MASTER_INTERFACE -o $MESH_IFACE -j ACCEPT
        #nat for eth0 interface to ap
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        iptables -A FORWARD -i $MASTER_INTERFACE -o eth0 -j ACCEPT
else
	echo "Setting up NAT firewall"
	sysctl net.ipv4.ip_forward=1
	iptables -t nat -A POSTROUTING -o $CLIENT_IFACE -j MASQUERADE
	iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -A FORWARD -i $MESH_IFACE -o $CLIENT_IFACE -j ACCEPT
	#nat for eth0 interface to ap
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
	iptables -A FORWARD -i $MASTER_INTERFACE -o eth0 -j ACCEPT
fi
}

##########################################################
#main program loop                                       #
##########################################################
#reset interface before startng
clobber_wifi_adapter

while true; do
	if [[ $(ip link | grep -c "$MASTER_INTERFACE:") == 1 ]]
	then
	        create_standard_ap
                if [[ $($CREATE_AP --list-running | grep "$MASTER_INTERFACE" | cut -d' ' -f1) == $NAT_AP ]]
                then
		        create_mesh_interface #only bring up mesh if wifi ap is already up
                fi
		#at this point, both interfaces should be in the UP state
		if [[ $(ip link | grep -c "$MESH_IFACE.*state UP") == 1 ]] && [[ $(ip link | grep -c "$MASTER_INTERFACE.*state UP") == 1 ]] && [[ "$MESH_READY" == 0 ]]
		then
			if [[ $IS_GATEWAY == 0 ]]
			then
				#attempt to release and then obtain an ip
				echo "Setting up mesh client node"
				mesh_node
				enable_nat
		                MESH_READY=$(ip addr show $MESH_IFACE | grep -c 'inet ')
			else
                                #set up gateway node (dhcp and nat to client interface)
				echo "Setting up mesh gateway node"
				gateway_node
				enable_nat
                                MESH_READY=$(ip addr show $MESH_IFACE | grep -c 'inet ')
                        fi
		else if [[ "$MESH_READY" > 0 ]] && [[ $IS_GATEWAY == 0 ]]
			then
				echo "ping test"
		                GATEWAY_IP=$(ip route | grep "^default.*$MESH_IFACE" | awk '{print $3}')
		                if ! ping -c 3 "$GATEWAY_IP"
		                then
                  		        echo "ping failed, renewing mesh ip!!!"
					mesh_node
        		                MESH_READY=$(ip addr show $MESH_IFACE | grep -c 'inet ')
		                fi

			fi
                fi
        else
                echo "ERROR: $MASTER_INTERFACE does not exist! Nothing to do!!!"
        fi
	sleep $INTERVAL_SECS
done


