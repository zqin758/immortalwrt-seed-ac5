#!/bin/sh
# Set default LAN IP to 192.168.88.1
uci batch <<-EOF
  set network.lan.ipaddr='192.168.100.1'
  commit network
