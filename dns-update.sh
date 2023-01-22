#!/bin/bash

# Set to run hourly in cron.
#	ln -s /root/scripts/dns-update.sh /etc/cron.hourly/dns-update
# Deleting the cache file will cause script to update CloudFlare even if public ip has not changed.


## SETTINGS
email=root												      # Address for errors and confirmations
cachedir='/var/cache/dns-update'				# Directory where script saves DNS address
zone_id='your-zone-id'									# From CloudFlare Overview page
api_token='your-api-token'							# Click "Get your API token" from Overview page (Token Name: Edit zone DNS)
domains=( yourdomainnames.com )					# Space separated array of Type A Domain Records to update




## PREFLIGHT CHECK
preflight_check() {
	# Check for required executables.
	for i in curl jq;
	do
		if ! command -v "$i" &> /dev/null; then
		echo >&2 "Error: searching PATH fails to find $i executable"
		exit 1
		fi
	done

	# Test IPv4 Network Connectivity. (Send 1 packet -c, Wait 1 sec -W)
	if ! ping -q -c 1 -W 1 8.8.8.8 &>/dev/null; then
		exit 0
	fi
}




## GET PUBLIC IP
get_public_ip() {
	# Try with cloudflare nameserver
	if public_ip=$(dig -4 +short TXT CH @1.1.1.1 whoami.cloudflare 2>/dev/null | grep -Pos '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b'); then
		return
	# Try with opendns nameserver
	elif public_ip=$(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | grep -Pos '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b'); then
		return
	# Try with google nameserver
	elif public_ip=$(dig -4 +short TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null | grep -Pos '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b'); then
		return
	else
		# shellcheck disable=SC2102
		echo "$(date +[%d/%b/%Y_%H:%M]) Unable to get public ip address with cloudflare, opendns, or google resolvers." | mail -s "dns-update.sh - error get_public_ip" "$email"
	fi
}




## GET DNS RECORDS LIST:
get_dns_record() {
	local http_rc
	local curl_tmp
	local stderr_tmp
	local curl_err
	local host_msg
	unset identifier
	#unset address

	curl_tmp=$(mktemp "$cachedir/get_dns_record.XXXX")
	stderr_tmp=$(mktemp "$cachedir/get_dns_record_stderr.XXXX")

	http_rc=$(curl --silent --show-error -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${1}" \
		-H "Authorization: Bearer ${api_token}" \
		-H "Content-Type:application/json" \
		--output "$curl_tmp" \
		--write-out "%{http_code}" \
		--stderr "$stderr_tmp")

	curl_err=$(<"$stderr_tmp")
	host_msg=$(head -n 1 "$curl_tmp")	#Set here so that it is not overwritten by --output="$curl_tmp"

	if (( http_rc == 200 )); then
		identifier=$(jq -j '.result[].id' "$curl_tmp")
		#address=$(jq -j '.result[].content' "$curl_tmp")
		rm "$curl_tmp" "$stderr_tmp"
	else
		# shellcheck disable=SC2102
		echo "$(date +[%d/%b/%Y_%H:%M]) ${1}: ${curl_err}  HTTP Code: ${http_rc}  Host Msg: ${host_msg}" | mail -s "dns-update.sh - error get_dns_record" "$email"
		rm "$curl_tmp" "$stderr_tmp"
		exit 1
	fi
}




## PATCH DNS RECORD:
update_dns_record() {
	local http_rc
	local curl_tmp
	local stderr_tmp
	local curl_err
	local host_msg
	unset patched_addr

	curl_tmp=$(mktemp "$cachedir/update_dns_record.XXXX")
	stderr_tmp=$(mktemp "$cachedir/update_dns_record_stderr.XXXX")

	http_rc=$(curl --silent --show-error -X PATCH "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${identifier}" \
		-H "Authorization: Bearer ${api_token}" \
		-H "Content-Type:application/json" \
		--data "{\"type\":\"A\",\"name\":\"${1}\",\"content\":\"${public_ip}\",\"proxied\":false}" \
		--output "$curl_tmp" \
		--write-out "%{http_code}" \
		--stderr "$stderr_tmp")

	curl_err=$(<"$stderr_tmp")
	host_msg=$(head -n 1 "$curl_tmp")	#Set here so that it is not overwritten by --output="$curl_tmp"

	if (( http_rc == 200 )); then
		patched_addr=$(jq -j '.result.content' "$curl_tmp")
		rm "$curl_tmp" "$stderr_tmp"
	else
		# shellcheck disable=SC2102
		echo "$(date +[%d/%b/%Y_%H:%M]) ${1}: ${curl_err}  HTTP Code: ${http_rc}  Host Msg: ${host_msg}" | mail -s "dns-update.sh - error update_dns_record" "$email"
		rm "$curl_tmp" "$stderr_tmp"
		exit 1
	fi
}




## UPDATE SCRIPT CACHE:
update_cache() {
	cat <<- EOF > "$cachedir/${1}"
	cache_date='$(date)'
	cache_id=${identifier}
	cache_addr=${patched_addr}
	cache_timestamp=$(date +%s)

	EOF

	chmod 0600 "$cachedir/${1}"
}




## MAIN CODE
preflight_check
get_public_ip

for i in "${domains[@]}"; do
	if [[ -f "$cachedir/$i" ]]; then
		# shellcheck disable=SC1090
		source "$cachedir/$i"

		# shellcheck disable=SC2154
		if [[ "$cache_addr" != "$public_ip" ]]; then
			get_dns_record "$i"
			update_dns_record "$i"
			update_cache "$i"
			# shellcheck disable=SC2102
			echo "$(date +[%d/%b/%Y_%H:%M]) DNS Record for $i updated from $cache_addr to $patched_addr" | mail -s "dns-update.sh - DNS UPDATED" "$email"

 		# If cache_timestamp is 1 month old then force update
		elif (( cache_timestamp < $(date -d 'now - 1 months' +%s) )); then
			get_dns_record "$i"
			update_dns_record "$i"
			update_cache "$i"
			# shellcheck disable=SC2102
			echo "$(date +[%d/%b/%Y_%H:%M]) DNS Monthly Force Update for $i from $cache_addr to $patched_addr" | mail -s "dns-update.sh - DNS UPDATED" "$email"
		fi

	else
		mkdir -p "$cachedir"
		chown root:root "$cachedir"
		chmod 0700 "$cachedir"

		get_dns_record "$i"
		update_dns_record "$i"
		update_cache "$i"
		# shellcheck disable=SC2102
		echo "$(date +[%d/%b/%Y_%H:%M]) DNS Record for $i updated for first time to $patched_addr" | mail -s "dns-update.sh - DNS UPDATED" "$email"
	fi
done
