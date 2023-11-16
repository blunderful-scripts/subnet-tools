#!/bin/sh
# shellcheck disable=SC2154,SC2034

# aggregate-subnets.sh

# Posix-compliant shell script which calculates an efficient configuration for subnets given as an input 
# by trimming down each input subnet to its mask bits and removing subnets that are encapsulated inside other subnets on the list.
# Designed for easier automated creation of firewall rules, but perhaps someone has a different application for this functionality.
# Utilizes the trim-subnet.sh script as a library.

# arg 1 is family (inet or inet6)
# next args are subnets to aggregate. for ipv6, enclose each subnet in double quotes

#### Initial setup

#debug=true
export LC_ALL=C
me=$(basename "$0")
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
export source_trim_subnet="true"

# source the trim-subnet.sh script
# shellcheck disable=SC1091
. "$script_dir/trim-subnet.sh" || { echo "$me: Error: Can't source '$script_dir/trim-subnet.sh'." >&2; exit 1; }


#### Functions

aggregate_subnets() {
	family="$1"; input_subnets="$2"

	case "$family" in
		inet ) addr_len=32; chunk_len=16; addr_regex="$ipv4_regex" ;;
		inet6 ) addr_len=128; chunk_len=32; addr_regex="$ipv6_regex" ;;
		* ) echo "aggregate_subnets(): invalid family '$family'." >&2; return 1 ;;
	esac

	# characters representing each chunk
	char_num=$((chunk_len / 4))

	# remove duplicates from input, convert to lower case
	input_subnets="$(printf "%s" "$input_subnets" | tr ' ' '\n' | sort -u | tr '\n' ' ' | awk '{print tolower($0)}')"

	validate_ip "${input_subnets%/*}" "$addr_regex" || return 1

	for subnet in $input_subnets; do
		# get mask bits
		maskbits="$(printf "%s" "$subnet" | awk -F/ '{print $2}')"
		case "$maskbits" in ''|*[!0-9]*) echo "aggregate_subnets(): Error: input '$subnet' has no mask bits or it's not a number." >&2; return 1;;esac
		# chop off mask bits
		input_addr="${subnet%/*}"

		# shellcheck disable=SC2086
		# validate mask bits
		if [ "$maskbits" -lt 8 ] || [ "$maskbits" -gt $addr_len ]; then echo "aggregate_subnets(): Error: invalid $family mask bits '$maskbits'." >&2; return 1; fi

		# convert ip address to hex
		subnet_hex="$(ip_to_hex "$input_addr" "$family")" || return 1
		# prepend mask bits
		subnets_hex="$(printf "%s\n%s" "$maskbits/$subnet_hex" "$subnets_hex")"
	done

	# sort by mask bits, remove empty lines if any
	sorted_subnets_hex="$(printf "%s\n" "$subnets_hex" | sort -n | awk -F_ '$1{print $1}')"

	while [ -n "$sorted_subnets_hex" ]; do
		## trim the 1st (largest) subnet on the list to its mask bits

		# get the subnet
		subnet1="$(printf "%s" "$sorted_subnets_hex" | head -n 1)"
		[ "$debug" ] && echo >&2
		[ "$debug" ] && echo "processing subnet: $subnet1" >&2

		# get mask bits
		maskbits="${subnet1%/*}"
		# chop off mask bits
		ip="${subnet1#*/}"

		# shellcheck disable=SC2086
		# generate mask if it's not been generated yet
		if eval [ -z "\$mask_${family}_${maskbits}" ]; then eval mask_${family}_${maskbits}="$(generate_mask "$maskbits" $addr_len)" || return 1; fi
		eval mask=\$mask_"${family}_${maskbits}"

		# shellcheck disable=SC2086
		# calculate ip & mask
		ip1="$(bitwise_and "$ip" "$mask" "$maskbits" $addr_len $chunk_len)" || return 1
		[ "$debug" ] && echo "calculated '$ip' & '$mask' = '$ip1'" >&2

		# remove current subnet from the list
		sorted_subnets_hex="$(printf "%s" "$sorted_subnets_hex" | tail -n +2)"
		remaining_subnets_hex="$sorted_subnets_hex"

		# iterate over all remaining subnets
		while [ -n "$remaining_subnets_hex" ]; do
			subnet2_hex=$(printf "%s" "$remaining_subnets_hex" | head -n 1)
			[ "$debug" ] && echo "comparing to subnet: '$subnet2_hex'" >&2

			if [ -n "$subnet2_hex" ]; then
				# chop off mask bits
				ip2="${subnet2_hex#*/}"

				ip2_differs=""; bytes_diff=0
				bits_processed=0; char_offset=0

				# shellcheck disable=SC2086
				# compare ~ $maskbits bits of ip1 and ip2
				while [ $((bits_processed + chunk_len)) -le $maskbits ]; do
					chunk_start=$((char_offset + 1))
					chunk_end=$((char_offset + char_num))

					ip1_chunk="$(printf "%s" "$ip1" | cut -c${chunk_start}-${chunk_end} )"
					ip2_chunk="$(printf "%s" "$ip2" | cut -c${chunk_start}-${chunk_end} )"

					[ "$debug" ] && echo "comparing chunks '$ip1_chunk' - '$ip2_chunk'" >&2

					bytes_diff=$((0x$ip1_chunk - 0x$ip2_chunk)) || \
								{ echo "aggregate_subnets(): Error: failed to calculate '0x$ip1_chunk - 0x$ip2_chunk'." >&2; return 1; }
					# if there is any difference, no need to calculate further
					if [ $bytes_diff -ne 0 ]; then
						[ "$debug" ] && echo "difference found" >&2
						ip2_differs=true; break
					fi

					bits_processed=$((bits_processed + chunk_len))
					char_offset=$((char_offset + char_num))
				done

				# shellcheck disable=SC2086
				# if needed, calculate the next ip2 chunk and compare to ip1 chunk
				if [ $bits_processed -ne $maskbits ] && [ -z  "$ip2_differs" ]; then
					[ "$debug" ] && echo "calculating last chunk..." >&2
					chunk_start=$((char_offset + 1))
					chunk_end=$((char_offset + char_num))

					ip1_chunk="$(printf "%s" "$ip1" | cut -c${chunk_start}-${chunk_end} )"
					ip2_chunk="$(printf "%s" "$ip2" | cut -c${chunk_start}-${chunk_end} )"
					mask_chunk="$(printf "%s" "$mask" | cut -c${chunk_start}-${chunk_end} )"

					# bitwise $ip2_chunk & $mask_chunk
					ip2_chunk=$(printf "%0${char_num}x" $(( 0x$ip2_chunk & 0x$mask_chunk )) ) || \
						{ echo "aggregate_subnets(): Error: failed to calculate '0x$ip2_chunk & 0x$mask_chunk'."; return 1; }

					[ "$debug" ] && echo "comparing chunks '$ip1_chunk' - '$ip2_chunk'" >&2

					bytes_diff=$((0x$ip1_chunk - 0x$ip2_chunk)) || \
								{ echo "aggregate_subnets(): Error: failed to calculate '0x$ip1_chunk - 0x$ip2_chunk'." >&2; return 1; }
					if [ $bytes_diff -ne 0 ]; then
						[ "$debug" ] && echo "difference found" >&2
						ip2_differs=true
					fi
				fi

				# if no differences found, subnet2 is encapsulated in subnet1 - remove subnet2 from the list
				if [ -z "$ip2_differs" ]; then
					[ "$debug" ] && echo "No difference found" >&2
					sorted_subnets_hex="$(printf "%s\n" "$sorted_subnets_hex" | grep -vx "$subnet2_hex")"
				fi
			fi
			remaining_subnets_hex="$(printf "%s" "$remaining_subnets_hex" | tail -n +2)"
		done

		# format from hex number back to ip
		ip1="$(format_ip "$ip1" "$family")" || return 1
		if validate_ip "$ip1" "$addr_regex"; then
			# append mask bits
			subnet1="$ip1/$maskbits"
			# add current subnet to resulting list
			res_subnets="${subnet1}${newline}${res_subnets}"
		else
			return 1
		fi
	done

	printf "%s\n" "$res_subnets"
}


#### Constants
newline='
'
ipv4_regex='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])'
ipv6_regex='([0-9a-f]{0,4}:){1,7}[0-9a-f]{0,4}:?'
maskbits_regex_ipv4='(3[0-2]|([1-2][0-9])|[8-9])'

# convert to lower case
family="$(printf "%s" "$1" | awk '{print tolower($0)}')"; shift

[ -z "$family" ] && { echo "$me: Specify family (inet or inet6) in 1st argument." >&2; exit 1; }


#### Main

# check dependencies
! command -v awk >/dev/null || ! command -v sed >/dev/null || ! command -v tr >/dev/null || \
! command -v grep >/dev/null || ! command -v ip >/dev/null || ! command -v cut >/dev/null && \
	{ echo "$me: Error: missing dependencies, can not proceed" >&2; exit 1; }

# test 'grep -E'
rv=0; rv1=0; rv2=0
printf "%s" "32" | grep -E "^${maskbits_regex_ipv4}$" > /dev/null; rv1=$?
printf "%s" "0" | grep -E "^${maskbits_regex_ipv4}$" > /dev/null; rv2=$?
rv=$((rv1 || ! rv2))
[ "$rv" -ne 0 ] && { echo "$me: Error: 'grep -E' command is not working correctly on this machine." >&2; exit 1; }
unset rv rv1 rv2

test_ip_route_get "$family" || exit 1

aggregate_subnets "$family" "$*"; exit $?
