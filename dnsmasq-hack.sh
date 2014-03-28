#!/bin/sh

# Run dnsmasq with
#  no-resolv
#  enable-dbus
#
# These options make dnsmasq run with the one already started by libvirt
#  listen-address=127.0.0.1
#  bind-interfaces
#
# These hopefully improve performance
#  cache-size=1024
#
# These improve reliability, especially if we happen to start in a state
# where we don't know which server maps to which network
#  all-servers
#  no-negcache

PREV=
CURR=
ARGS=

ip_to_num ()
{
	OIFS="$IFS"
	IFS="."
	set $1
	IFS="$OIFS"
	expr $1 \* 16777216 + $2 \* 65536 + $3 \* 256 + $4
}

get_entries()
{
	echo $(grep ^$1 $2 | sed -e "s/$1//g")
}

old_entries ()
{
	local old=$(get_entries $1 $PREV)
	local new=$(get_entries $1 $CURR)
	local matches

	for i in $new; do
		for j in $old; do
			if [ $i == $j ]; then
				matches="$matches $i"
			fi
		done
	done
	echo $matches
}

new_entries ()
{
	local matches=$(old_entries $1)
	local unmatches=$(get_entries $1 $CURR)

	for i in $matches; do
		unmatches=$(echo $unmatches | sed -e "s/$i//g")
	done
	echo $unmatches
}

wait_for_dnsmasq ()
{
	while (! dbus-send --print-reply --system \
		 --dest=uk.org.thekelleys.dnsmasq \
		 /uk/org/thekelleys/dnsmasq \
		 uk.org.thekelleys.GetVersion > /dev/null 2>&1); do
		sleep 1
	done
}

reload_args ()
{
	wait_for_dnsmasq

	dbus-send --system --dest=uk.org.thekelleys.dnsmasq \
		/uk/org/thekelleys/dnsmasq \
		uk.org.thekelleys.SetServers $ARGS

	dbus-send --system --dest=uk.org.thekelleys.dnsmasq \
		/uk/org/thekelleys/dnsmasq \
		uk.org.thekelleys.ClearCache
}

scrape_resolv_conf ()
{
	local uaddr
	local servers

	sed -i -e "/nameserver 127.0.0.1/D" /etc/resolv.conf

	CURR=$(mktemp)
	cat /etc/resolv.conf > $CURR

	if [ -n "$PREV" ]; then
		diff -q $CURR $PREV > /dev/null
		if [ "$?" -eq 0 ]; then
			rm $CURR
			sed -i -e "1,1 i nameserver 127.0.0.1" /etc/resolv.conf
			return 0
		fi
	fi
		
	servers=$(get_entries nameserver $CURR)

	ARGS=
	for i in $servers; do
		uaddr=$(ip_to_num $i)
		ARGS="$ARGS uint32:$uaddr"
	done

	if [ -n "$servers" -a -n "$PREV" ]; then
		local newdomain=$(new_entries domain)
		if [ -z "$newdomain" ]; then
			newdomain=$(new_entries search)
		fi
		local newservers=$(new_entries nameserver)
		local oldservers=$(old_entries nameserver)

		if [ -n "$newdomain" -a -n "$newservers" -a -n "$oldservers" ]; then
			ARGS=
			for i in $newservers; do
				uaddr=$(ip_to_num $i)
				ARGS="$ARGS uint32:$uaddr string:$newdomain"
			done
			for i in $oldservers; do
				uaddr=$(ip_to_num $i)
				ARGS="$ARGS uint32:$uaddr"
			done
		fi

	fi

	reload_args

	if [ -n "$PREV" ]; then
		rm $PREV
	fi

	PREV=$CURR

	sed -i -e "1,1 i nameserver 127.0.0.1" /etc/resolv.conf
}

scrape_resolv_conf

while (true); do
	MODDED=$(inotifywait -q -e modify -e delete_self \
		 /etc/resolv.conf /var/run/dnsmasq.pid | cut -f 1 -d ' ')
	MODDED=$(basename $MODDED)
	if [ $? == 0 ]; then
		case "$MODDED" in
			dnsmasq.pid)
				reload_args
				;;
			resolv.conf)
				sleep 0.2 # stall for changes
				scrape_resolv_conf
				;;
		esac
	fi
done
