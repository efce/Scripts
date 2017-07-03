#!/bin/bash
# This is simple script to forward and masquarade IPv4 connections

if [ $# -ne 2 ]; then
	echo "Usage: $0 <INTERNETINTERFACE> <LOCALINTERFACE>"
	exit
fi
if [ $(id -u) -ne 0 ]; then
	echo "This script should be run as root.";
	exit 
fi
ipforward=/proc/sys/net/ipv4/ip_forward
if ![ -f $ipforward ]; then
	echo "File $ipforward not found. Please, check your distribution right to forward IPv4 traffic."
else
	echo 1 > $ipforward
fi
iptables -t nat -A POSTROUTING -o $1 -j MASQUERADE
iptables -A FORWARD -i $2 -o $1 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i $1 -o $2 -j ACCEPT
