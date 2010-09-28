#!/bin/sh
# Copyright (C) 2008 John Crispin <blogic@openwrt.org>

. /etc/functions.sh

IPTABLES="echo iptables"
IPTABLES=iptables

config_clear
include /lib/network
scan_interfaces

CONFIG_APPEND=1
config_load firewall

config fw_zones
ZONE_LIST=$CONFIG_SECTION
ZONE_NAMES=

CUSTOM_CHAINS=1
DEF_INPUT=DROP
DEF_OUTPUT=DROP
DEF_FORWARD=DROP
CONNTRACK_ZONES=
NOTRACK_DISABLED=

add_state() {
	local var="$1"
	local item="$2"

	local val="$(uci_get_state firewall core $var)"
	uci_set_state firewall core $var "${val:+$val }$item"
}

del_state() {
	local var="$1"
	local item="$2"

	local val=" $(uci_get_state firewall core $var) "
	val="${val// $item / }"
	val="${val# }"
	val="${val% }"
	uci_set_state firewall core $var "$val"
}

find_item() {
	local item="$1"; shift
	for i in "$@"; do
		[ "$i" = "$item" ] && return 0
	done
	return 1
}

get_portrange() {
	local _var="$1"
	local _range="$2"
	local _delim="${3:-:}"

	local _min="${_range%%[:-]*}"
	local _max="${_range##*[:-]}"

	[ -n "$_min" ] && [ -n "$_max" ] && [ "$_min" != "$_max" ] && \
		export -n -- "$_var=$_min$_delim$_max" || \
		export -n -- "$_var=${_min:-$_max}"
}

get_negation() {
	local _var="$1"
	local _flag="$2"
	local _ipaddr="$3"

	[ "${_ipaddr#!}" != "$_ipaddr" ] && \
		export -n -- "$_var=! $_flag ${_ipaddr#!}" || \
		export -n -- "$_var=${_ipaddr:+$_flag $_ipaddr}"
}

load_policy() {
	config_get input $1 input
	config_get output $1 output
	config_get forward $1 forward

	DEF_INPUT="${input:-$DEF_INPUT}"
	DEF_OUTPUT="${output:-$DEF_OUTPUT}"
	DEF_FORWARD="${forward:-$DEF_FORWARD}"
}

create_zone() {
	local name="$1"
	local network="$2"
	local input="$3"
	local output="$4"
	local forward="$5"
	local mtu_fix="$6"
	local masq="$7"
	local masq_src="$8"
	local masq_dest="$9"

	local exists

	[ "$name" == "loopback" ] && return

	config_get exists $ZONE_LIST $name
	[ -n "$exists" ] && return
	config_set $ZONE_LIST $name 1

	$IPTABLES -N zone_${name}
	$IPTABLES -N zone_${name}_MSSFIX
	$IPTABLES -N zone_${name}_ACCEPT
	$IPTABLES -N zone_${name}_DROP
	$IPTABLES -N zone_${name}_REJECT
	$IPTABLES -N zone_${name}_forward
	[ "$output" ] && $IPTABLES -A output -j zone_${name}_${output}
	$IPTABLES -N zone_${name}_nat -t nat
	$IPTABLES -N zone_${name}_prerouting -t nat
	$IPTABLES -t raw -N zone_${name}_notrack
	[ "$mtu_fix" == "1" ] && $IPTABLES -I FORWARD 1 -j zone_${name}_MSSFIX

	if [ "$masq" == "1" ]; then
		local msrc mdst
		for msrc in ${masq_src:-0.0.0.0/0}; do
			get_negation msrc '-s' "$msrc"
			for mdst in ${masq_dest:-0.0.0.0/0}; do
				get_negation mdst '-d' "$mdst"
				$IPTABLES -A zone_${name}_nat -t nat $msrc $mdst -j MASQUERADE
			done
		done
	fi

	append ZONE_NAMES "$name"
}


addif() {
	local network="$1"
	local ifname="$2"
	local zone="$3"

	local n_if n_zone
	config_get n_if core "${network}_ifname"
	config_get n_zone core "${network}_zone"
	[ -n "$n_zone" ] && {
		if [ "$n_zone" != "$zone" ]; then
			delif "$network" "$n_if" "$n_zone"
		else
			return
		fi
	}

	logger "adding $network ($ifname) to firewall zone $zone"
	$IPTABLES -A input -i "$ifname" -j zone_${zone}
	$IPTABLES -I zone_${zone}_MSSFIX 1 -o "$ifname" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	$IPTABLES -I zone_${zone}_ACCEPT 1 -o "$ifname" -j ACCEPT
	$IPTABLES -I zone_${zone}_DROP 1 -o "$ifname" -j DROP
	$IPTABLES -I zone_${zone}_REJECT 1 -o "$ifname" -j reject
	$IPTABLES -I zone_${zone}_ACCEPT 1 -i "$ifname" -j ACCEPT
	$IPTABLES -I zone_${zone}_DROP 1 -i "$ifname" -j DROP
	$IPTABLES -I zone_${zone}_REJECT 1 -i "$ifname" -j reject

	$IPTABLES -I PREROUTING 1 -t nat -i "$ifname" -j zone_${zone}_prerouting
	$IPTABLES -I POSTROUTING 1 -t nat -o "$ifname" -j zone_${zone}_nat
	$IPTABLES -A forward -i "$ifname" -j zone_${zone}_forward
	$IPTABLES -I PREROUTING 1 -t raw -i "$ifname" -j zone_${zone}_notrack

	uci_set_state firewall core "${network}_ifname" "$ifname"
	uci_set_state firewall core "${network}_zone" "$zone"

	add_state "${zone}_networks" "$network"

	ACTION=add ZONE="$zone" INTERFACE="$network" DEVICE="$ifname" /sbin/hotplug-call firewall
}

delif() {
	local network="$1"
	local ifname="$2"
	local zone="$3"

	logger "removing $network ($ifname) from firewall zone $zone"
	$IPTABLES -D input -i "$ifname" -j zone_$zone
	$IPTABLES -D zone_${zone}_MSSFIX -o "$ifname" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	$IPTABLES -D zone_${zone}_ACCEPT -o "$ifname" -j ACCEPT
	$IPTABLES -D zone_${zone}_DROP -o "$ifname" -j DROP
	$IPTABLES -D zone_${zone}_REJECT -o "$ifname" -j reject
	$IPTABLES -D zone_${zone}_ACCEPT -i "$ifname" -j ACCEPT
	$IPTABLES -D zone_${zone}_DROP -i "$ifname" -j DROP
	$IPTABLES -D zone_${zone}_REJECT -i "$ifname" -j reject

	$IPTABLES -D PREROUTING -t nat -i "$ifname" -j zone_${zone}_prerouting
	$IPTABLES -D POSTROUTING -t nat -o "$ifname" -j zone_${zone}_nat
	$IPTABLES -D forward -i "$ifname" -j zone_${zone}_forward
	$IPTABLES -D PREROUTING -t raw -i "$ifname" -j zone_${zone}_notrack

	uci_revert_state firewall core "${network}_ifname"
	uci_revert_state firewall core "${network}_zone"

	del_state "${zone}_networks" "$network"

	ACTION=remove ZONE="$zone" INTERFACE="$network" DEVICE="$ifname" /sbin/hotplug-call firewall
}

load_synflood() {
	local rate=${1:-25}
	local burst=${2:-50}
	echo "Loading synflood protection"
	$IPTABLES -N syn_flood
	$IPTABLES -A syn_flood -p tcp --syn -m limit --limit $rate/second --limit-burst $burst -j RETURN
	$IPTABLES -A syn_flood -j DROP
	$IPTABLES -A INPUT -p tcp --syn -j syn_flood
}

fw_set_chain_policy() {
	local chain=$1
	local target=$2
	[ "$target" == "REJECT" ] && {
		$IPTABLES -A $chain -j reject
		target=DROP
	}
	$IPTABLES -P $chain $target
}

fw_clear() {
	$IPTABLES -F
	$IPTABLES -t nat -F
	$IPTABLES -t nat -X
	$IPTABLES -t raw -F
	$IPTABLES -t raw -X
	$IPTABLES -X
}

fw_defaults() {
	[ -n "$DEFAULTS_APPLIED" ] && {
		echo "Error: multiple defaults sections detected"
		return;
	}
	DEFAULTS_APPLIED=1

	load_policy "$1"

	echo 1 > /proc/sys/net/ipv4/tcp_syncookies
	for f in /proc/sys/net/ipv4/conf/*/accept_redirects
	do
		echo 0 > $f
	done
	for f in /proc/sys/net/ipv4/conf/*/accept_source_route
	do
		echo 0 > $f
	done

	uci_revert_state firewall core
	uci_set_state firewall core "" firewall_state

	$IPTABLES -P INPUT DROP
	$IPTABLES -P OUTPUT DROP
	$IPTABLES -P FORWARD DROP

	fw_clear
	config_get_bool drop_invalid $1 drop_invalid 0

	[ "$drop_invalid" -gt 0 ] && {
		$IPTABLES -A INPUT -m state --state INVALID -j DROP
		$IPTABLES -A OUTPUT -m state --state INVALID -j DROP
		$IPTABLES -A FORWARD -m state --state INVALID -j DROP
		NOTRACK_DISABLED=1
	}

	$IPTABLES -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
	$IPTABLES -A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
	$IPTABLES -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

	$IPTABLES -A INPUT -i lo -j ACCEPT
	$IPTABLES -A OUTPUT -o lo -j ACCEPT

	config_get syn_flood $1 syn_flood
	config_get syn_rate $1 syn_rate
	config_get syn_burst $1 syn_burst
	[ "$syn_flood" == "1" ] && load_synflood $syn_rate $syn_burst

	echo "Adding custom chains"
	fw_custom_chains

	$IPTABLES -N input
	$IPTABLES -N output
	$IPTABLES -N forward

	$IPTABLES -A INPUT -j input
	$IPTABLES -A OUTPUT -j output
	$IPTABLES -A FORWARD -j forward

	$IPTABLES -N reject
	$IPTABLES -A reject -p tcp -j REJECT --reject-with tcp-reset
	$IPTABLES -A reject -j REJECT --reject-with icmp-port-unreachable

	fw_set_chain_policy INPUT "$DEF_INPUT"
	fw_set_chain_policy OUTPUT "$DEF_OUTPUT"
	fw_set_chain_policy FORWARD "$DEF_FORWARD"
}

fw_zone_defaults() {
	local name
	local network
	local masq

	config_get name $1 name
	config_get network $1 network
	config_get_bool masq $1 masq "0"
	config_get_bool conntrack $1 conntrack "0"
	config_get_bool mtu_fix $1 mtu_fix 0

	load_policy $1
	[ "$forward" ] && $IPTABLES -A zone_${name}_forward -j zone_${name}_${forward}
	[ "$input" ] && $IPTABLES -A zone_${name} -j zone_${name}_${input}
}

fw_zone() {
	local name
	local network
	local mtu_fix
	local conntrack
	local masq
	local masq_src
	local masq_dest

	config_get name $1 name
	config_get network $1 network
	config_get_bool masq $1 masq "0"
	config_get_bool conntrack $1 conntrack "0"
	config_get_bool mtu_fix $1 mtu_fix 0
	config_get masq_src $1 masq_src
	config_get masq_dest $1 masq_dest

	load_policy $1
	[ "$conntrack" = "1" -o "$masq" = "1" ] && append CONNTRACK_ZONES "$name"
	[ -z "$network" ] && network=$name

	create_zone "$name" "$network" "$input" "$output" "$forward" "$mtu_fix" \
		"$masq" "$masq_src" "$masq_dest"

	fw_custom_chains_zone "$name"
}

fw_rule() {
	local src
	local src_ip
	local src_mac
	local src_port
	local src_mac
	local dest
	local dest_ip
	local dest_port
	local proto
	local icmp_type
	local target
	local ruleset

	config_get src $1 src
	config_get src_ip $1 src_ip
	config_get src_mac $1 src_mac
	config_get src_port $1 src_port
	config_get dest $1 dest
	config_get dest_ip $1 dest_ip
	config_get dest_port $1 dest_port
	config_get proto $1 proto
	config_get icmp_type $1 icmp_type
	config_get target $1 target
	config_get ruleset $1 ruleset

	[ "$target" != "NOTRACK" ] || [ -n "$src" ] || {
		echo "NOTRACK rule needs src"
		return
	}

	local srcaddr destaddr
	get_negation srcaddr '-s' "$src_ip"
	get_negation destaddr '-d' "$dest_ip"

	local srcports destports
	get_portrange srcports "$src_port" ":"
	get_portrange destports "$dest_port" ":"

	ZONE=input
	TABLE=filter
	TARGET="${target:-DROP}"

	if [ "$TARGET" = "NOTRACK" ]; then
		TABLE=raw
		ZONE="zone_${src}_notrack"
	else
		[ -n "$src" ] && ZONE="zone_${src}${dest:+_forward}"
		[ -n "$dest" ] && TARGET="zone_${dest}_${TARGET}"
	fi

	eval 'RULE_COUNT=$((++RULE_COUNT_'$ZONE'))'

	add_rule() {
		$IPTABLES -t $TABLE -I $ZONE $RULE_COUNT \
			$srcaddr $destaddr \
			${proto:+-p $proto} \
			${icmp_type:+--icmp-type $icmp_type} \
			${srcports:+--sport $srcports} \
			${src_mac:+-m mac --mac-source $src_mac} \
			${destports:+--dport $destports} \
			-j $TARGET
	}

	[ "$proto" == "tcpudp" ] && proto="tcp udp"
	for proto in ${proto:-tcp udp}; do
		add_rule
	done
}

fw_forwarding() {
	local src
	local dest
	local masq

	config_get src $1 src
	config_get dest $1 dest
	[ -n "$src" ] && z_src=zone_${src}_forward || z_src=forward
	[ -n "$dest" ] && z_dest=zone_${dest}_ACCEPT || z_dest=ACCEPT
	$IPTABLES -I $z_src 1 -j $z_dest

	# propagate masq zone flag
	find_item "$src" $CONNTRACK_ZONES && append CONNTRACK_ZONES $dest
	find_item "$dest" $CONNTRACK_ZONES && append CONNTRACK_ZONES $src
}

fw_redirect() {
	local src
	local src_ip
	local src_dip
	local src_port
	local src_dport
	local src_mac
	local dest
	local dest_ip
	local dest_port
	local proto
	local target

	config_get src $1 src
	config_get src_ip $1 src_ip
	config_get src_dip $1 src_dip
	config_get src_port $1 src_port
	config_get src_dport $1 src_dport
	config_get src_mac $1 src_mac
	config_get dest $1 dest
	config_get dest_ip $1 dest_ip
	config_get dest_port $1 dest_port
	config_get proto $1 proto
	config_get target $1 target

	local fwdchain natchain natopt nataddr natports srcdaddr srcdports
	if [ "${target:-DNAT}" == "DNAT" ]; then
		[ -n "$src" -a -n "$dest_ip$dest_port" ] || {
			echo "DNAT redirect needs src and dest_ip or dest_port"
			return
		}

		fwdchain="zone_${src}_forward"

		natopt="--to-destination"
		natchain="zone_${src}_prerouting"
		nataddr="$dest_ip"
		get_portrange natports "$dest_port" "-"

		get_negation srcdaddr '-d' "$src_dip"
		get_portrange srcdports "$src_dport" ":"

		find_item "$src" $CONNTRACK_ZONES || \
			append CONNTRACK_ZONES "$src"

	elif [ "$target" == "SNAT" ]; then
		[ -n "$dest" -a -n "$src_dip" ] || {
			echo "SNAT redirect needs dest and src_dip"
			return
		}

		fwdchain="${src:+zone_${src}_forward}"

		natopt="--to-source"
		natchain="zone_${dest}_nat"
		nataddr="$src_dip"
		get_portrange natports "$src_dport" "-"

		get_negation srcdaddr '-d' "$dest_ip"
		get_portrange srcdports "$dest_port" ":"

		find_item "$dest" $CONNTRACK_ZONES || \
			append CONNTRACK_ZONES "$dest"

	else
		echo "redirect target must be either DNAT or SNAT"
		return
	fi

	local srcaddr destaddr
	get_negation srcaddr '-s' "$src_ip"
	get_negation destaddr '-d' "$dest_ip"

	local srcports destports
	get_portrange srcports "$src_port" ":"
	get_portrange destports "${dest_port-$src_dport}" ":"

	add_rule() {
		$IPTABLES -I $natchain 1 -t nat \
			$srcaddr $srcdaddr \
			${proto:+-p $proto} \
			${srcports:+--sport $srcports} \
			${srcdports:+--dport $srcdports} \
			${src_mac:+-m mac --mac-source $src_mac} \
			-j ${target:-DNAT} $natopt $nataddr${natports:+:$natports}

		[ -n "$dest_ip" ] && \
		$IPTABLES -I ${fwdchain:-forward} 1 \
			$srcaddr $destaddr \
			${proto:+-p $proto} \
			${srcports:+--sport $srcports} \
			${destports:+--dport $destports} \
			${src_mac:+-m mac --mac-source $src_mac} \
			-j ACCEPT
	}

	[ "$proto" == "tcpudp" ] && proto="tcp udp"
	for proto in ${proto:-tcp udp}; do
		add_rule
	done
}

fw_include() {
	local path
	config_get path $1 path
	[ -e $path ] && . $path
}

get_interface_zones() {
	local interface="$2"
	local name
	local network
	local masq_src
	local masq_dest
	config_get name $1 name
	config_get network $1 network
	config_get masq_src $1 masq_src
	config_get masq_dest $1 masq_dest
	[ -z "$network" ] && network=$name 
	for n in $network; do
		[ "$n" = "$interface" ] && {
			append add_zone "$name"
			append add_masq_src "$masq_src"
			append add_masq_dest "$masq_dest"
		}
	done
}

fw_event() {
	local action="$1"
	local interface="$2"
	local ifname="$(sh -c ". /etc/functions.sh; include /lib/network; scan_interfaces; config_get "$interface" ifname")"
	local add_zone=
	local add_masq_src=
	local add_masq_dest=
	local up

	[ -z "$ifname" ] && return 0
	config_foreach get_interface_zones zone "$interface"
	[ -z "$add_zone" ] && return 0

	case "$action" in
		ifup)
			for z in $add_zone; do 
				local loaded masq_src masq_dest
				config_get loaded core loaded
				[ -n "$loaded" ] && addif "$interface" "$ifname" "$z" "$add_masq_src" "$add_masq_dest"
			done
		;;
		ifdown)
			config_get up "$interface" up

			for z in $ZONE; do 
				local masq_src masq_dest
				config_get masq_src core "${z}_masq_src"
				config_get masq_dest core "${z}_masq_dest"
				[ "$up" == "1" ] && delif "$interface" "$ifname" "$z" "$masq_src" "$masq_dest"
			done
		;;
	esac
}

fw_addif() {
	local up
	local ifname
	config_get up $1 up
	[ -n "$up" ] || return 0
	fw_event ifup "$1"
}

fw_custom_chains() {
	[ -n "$CUSTOM_CHAINS" ] || return 0
	$IPTABLES -N input_rule
	$IPTABLES -N output_rule
	$IPTABLES -N forwarding_rule
	$IPTABLES -N prerouting_rule -t nat
	$IPTABLES -N postrouting_rule -t nat

	$IPTABLES -A INPUT -j input_rule
	$IPTABLES -A OUTPUT -j output_rule
	$IPTABLES -A FORWARD -j forwarding_rule
	$IPTABLES -A PREROUTING -t nat -j prerouting_rule
	$IPTABLES -A POSTROUTING -t nat -j postrouting_rule
}

fw_custom_chains_zone() {
	local zone="$1"

	[ -n "$CUSTOM_CHAINS" ] || return 0
	$IPTABLES -N input_${zone}
	$IPTABLES -N forwarding_${zone}
	$IPTABLES -N prerouting_${zone} -t nat
	$IPTABLES -I zone_${zone} 1 -j input_${zone}
	$IPTABLES -I zone_${zone}_forward 1 -j forwarding_${zone}
	$IPTABLES -I zone_${zone}_prerouting 1 -t nat -j prerouting_${zone}
}

fw_check_notrack() {
	local zone="$1"
	config_get name "$zone" name
	[ -n "$NOTRACK_DISABLED" ] || \
		find_item "$name" $CONNTRACK_ZONES || \
		$IPTABLES -t raw -A zone_${name}_notrack -j NOTRACK
}

fw_init() {
	DEFAULTS_APPLIED=

	echo "Loading defaults"
	config_foreach fw_defaults defaults
	echo "Loading zones"
	config_foreach fw_zone zone
	echo "Loading forwarding"
	config_foreach fw_forwarding forwarding
	echo "Loading redirects"
	config_foreach fw_redirect redirect
	echo "Loading rules"
	config_foreach fw_rule rule
	echo "Loading includes"
	config_foreach fw_include include
	echo "Loading zone defaults"
	config_foreach fw_zone_defaults zone
	uci_set_state firewall core loaded 1
	config_set core loaded 1
	config_foreach fw_check_notrack zone
	INTERFACES="$(sh -c '
		. /etc/functions.sh; config_load network
		echo_up() { local up; config_get_bool up "$1" up 0; [ $up = 1 ] && echo "$1"; }
		config_foreach echo_up interface
	')"
	for interface in $INTERFACES; do
		fw_event ifup "$interface"
	done

	uci_set_state firewall core zones "$ZONE_NAMES"
}

fw_stop() {
	local z n i
	config_get z core zones
	for z in $z; do
		config_get n core "${z}_networks"
		for n in $n; do
			config_get i core "${n}_ifname"
			[ -n "$i" ] && env -i ACTION=remove ZONE="$z" INTERFACE="$n" DEVICE="$i" \
				/sbin/hotplug-call firewall
		done
	done

	fw_clear
	$IPTABLES -P INPUT ACCEPT
	$IPTABLES -P OUTPUT ACCEPT
	$IPTABLES -P FORWARD ACCEPT
	uci_revert_state firewall
}
