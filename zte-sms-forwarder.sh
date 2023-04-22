#!/bin/bash
DEFAULT_PASSWD="YWRtaW4="
DEFAULT_IPADDR="192.168.0.1"
DEFAULT_FORWARDING_NUMBER="<phone number>"

# The list of blocked keywords
declare -a BLOCKED=("uber eats" "block another keyword")

# Optionally override default password, IP and SMS forwaring number from command line.
# PASSWD is on on-the-wire format as captured by Wireshark or in
# Chrome Debugger Network tab. For my ZTE MF286D the encoded password
# can be generated from the PLAINTEXT with the following command:
#    "echo -n PLAINTEXT | base64 | tr d \n | sha256sum | tr [a-f] [A-F] | awk '{print $1}'".
PASSWD=${1-$DEFAULT_PASSWD}
IPADDR=${2-$DEFAULT_IPADDR}
FWDNO=${3-$DEFAULT_FORWARDING_NUMBER}

URL=http://$IPADDR
REFERER="$URL/index.html"
URL_SET="$URL/goform/goform_set_cmd_process"
URL_GET="$URL/goform/goform_get_cmd_process"

command -v jq >/dev/null 2>&1 || { echo >&2 "'jq' is required but not installed. Aborting."; exit 1; }

COOKIEJAR=$(mktemp --suffix .zte-sms-forwarder)


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

echo "Logging in to ZTE"
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
