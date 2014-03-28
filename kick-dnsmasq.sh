#!/bin/sh

dbus-send --system --dest=uk.org.thekelleys.dnsmasq \
	/uk/org/thekelleys/dnsmasq uk.org.thekelleys.ClearCache
