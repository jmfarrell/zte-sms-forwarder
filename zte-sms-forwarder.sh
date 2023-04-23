#!/bin/bash

# Script to check ZTE MF286D router for unread SMS messages and forward
# them as an SMS message to another phone number.  Any messages forwarded
# are marked as unread so they won't be forwarded again next time the
# script runs.
#
# Usage:
#   zte-sms-fowarder <router-ip-address> <forwarding-number>
#
# The router password can be set by editing the value of PASSWD either in this
# script in a file called ~/.zterc which should not be readable by any other user.
#
# PASSWD should be in the on-the-wire format as captured by Wireshark or in
# Chrome Debugger Network tab. For my ZTE MF286D the encoded password
# can be generated from the PLAINTEXT with the following command:
#    "echo -n PLAINTEXT | base64 | tr d \n | sha256sum | tr [a-f] [A-F] | awk '{print $1}'".

PASSWD="YOUR_ENCODED_PASSWORD_HERE"

# The list of blocked keywords
declare -a BLOCKED=("uber eats" "block another keyword")

if [ $# -lt 2 ]; then
    echo "Usage: $0 <router-ip-address> <fowarding>"
    printf "\n"
    echo "Example: $0 192.168.1.1 +441234567890"
    exit 1
fi
IPADDR=$1
FWDNO=$(echo $2 |sed -e 's/^+/%2B/g')

URL=http://$IPADDR
REFERER="$URL/index.html"
URL_SET="$URL/goform/goform_set_cmd_process"
URL_GET="$URL/goform/goform_get_cmd_process"
RCFILE=~/.zterc

command -v jq >/dev/null 2>&1 || { echo >&2 "'jq' is required but not installed. Aborting."; exit 1; }

COOKIEJAR=$(mktemp --suffix .zte-sms-forwarder)

# Override PASSWD from $RCFILE if present
if [ -f "$RCFILE" ]; then
    chmod 600 "$RCFILE"
    RCPASSWD=$(awk -F= '/^PASSWD=/{print $2}' "$RCFILE")
    if [ "$RCPASSWD" ]; then
	PASSWD="$RCPASSWD"
    fi
fi

# These 3 functions for generating a one-time auth token for a SET operation come from
# https://github.com/gediz/trivial-tools-n-scripts/blob/master/superbox-hacks/v1-login-and-fetch-sms/poc.sh
# See also https://blog.aydindogm.us/posts/superbox-hacks-v1/
#
epoch() {
    date +%s%3N
}

get_cmd() {
   curl -b $COOKIEJAR -s --header "Referer: $REFERER" "$URL_GET?isTest=false&cmd=$1&_="$(epoch) \
        | jq -r ".$1"
}

# Generate a one-time auth token for a SET operation
get_AD () {
    # get RD
    RD=$(get_cmd "RD")
    # get rd0 a.k.a. rd_params0 a.k.a. wa_inner_version
    rd0=$(get_cmd "wa_inner_version")
    # get rd1 a.k.a. rd_params1 a.k.a. cr_version
    rd1=$(get_cmd "cr_version")

    # compose AD with following formula: AD = md5(md5(rd0+rd1)+RD)
    MD5_rd=$(echo -n "$rd0$rd1" \
        | md5sum \
        | awk '{print $1}')

    echo -n "$MD5_rd$RD" \
        | md5sum \
        | awk '{print $1}'
}

echo "Logging in to ZTE at" $(date)
LOGIN=$(curl -s -c $COOKIEJAR --header "Referer: $REFERER" -d 'isTest=false&goformId=LOGIN&password='$PASSWD $URL_SET | jq --raw-output .result)

if [ "$LOGIN" == "0" ]; then
    echo "Logged in to ZTE"
else
    echo "Could not login to ZTE"
    rm $COOKIEJAR
    exit
fi

# Get unread messages
SMS=$(curl -s -b $COOKIEJAR --header "Referer: $REFERER" $URL_GET\?multi_data\=1\&isTest\=false\&sms_received_flag_flag\=0\&sts_received_flag_flag\=0\&cmd\=sms_unread_num)
UNREAD_SMS=$(echo "$SMS" | jq --raw-output .sms_unread_num)

if [ "$UNREAD_SMS" == "0" ]; then
  echo "You have no unread message"
  rm $COOKIEJAR
  exit
else
  echo "You have $UNREAD_SMS unread messages"

  # Fetch messages
  MESSAGES=$(curl -s -b $COOKIEJAR --header "Referer: $REFERER" $URL_GET\?isTest\=false\&cmd\=sms_data_total\&page\=0\&data_per_page\=500\&mem_store\=1\&tags\=10\&order_by\=order+by+id+desc)

  for MESSAGE in $(echo $MESSAGES | tr -d ' ' | jq -c '.messages | values []'); do
    TAG=$(echo $MESSAGE | jq --raw-output .tag)

    if [ "$TAG" == "1" ]; then
      ID=$(echo $MESSAGE | jq --raw-output .id)
      RAW_CONTENT=$(echo $MESSAGE | jq --raw-output .content)
      CONTENT=$(echo $RAW_CONTENT | tr '\0' '\n' | xxd -r -p | tr -d '\0')

      echo "Message: $CONTENT"

      # Set message as read
      AD=$(get_AD)
      MARK=$(curl -s -b $COOKIEJAR --header "Referer: $REFERER" -d "isTest=false&goformId=SET_MSG_READ&msg_id=$ID;&tag=0&AD=$AD" $URL_SET | jq --raw-output .result)
      if [ "$MARK" != "success" ]; then
	  echo "Message could not be marked as read."
      fi;
      
      # End right there if a blocked keyword is found
      for STR in "${BLOCKED[@]}"; do
        if [ "$(echo $CONTENT | grep -i "$STR")" ]; then
          echo "$STR is blocked"
	  rm $COOKIEJAR
	  exit
        fi
      done

      # Forward the message to the SMS forwarding number
      AD=$(get_AD)
      SMS_TIME=$(date +"%y;%m;%d;%H;%M;%S;%:::z" | sed -e 's/;/%3B/g' -e 's/+/%2B/g')
  
      FWD=$(curl -s -b $COOKIEJAR --header "Referer: $REFERER" -d "isTest=false&goformId=SEND_SMS&notCallback=true&Number=$FWDNO&sms_time=$SMS_TIME&MessageBody=$RAW_CONTENT&ID=-1&encode_type=GSM7_default&AD=$AD" $URL_SET | jq --raw-output .result)
      if [ "$FWD" == "success" ]; then
	  echo "Message forwarded successfully."
      else
	  echo "Message could not be forwarded."
      fi
    fi
  done
fi

rm $COOKIEJAR
