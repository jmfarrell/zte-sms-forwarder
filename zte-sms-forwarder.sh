#!/bin/bash
PUSHOVER_TOKEN="<token>"
PUSHOVER_USER="<user>"

# The list of blocked keywords
declare -a BLOCKED=("uber eats" "block another keyword")

# Optionally override default password and IP from command line.
# PASSWD is on on-the-wire format as captured by Wireshark or in
# Chrome Debugger Network tab. For my ZTE MF286D the encoded password
# can be generated from the PLAINTEXT with the following command:
#    "echo -n PLAINTEXT | base 64 | tr d \n | sha256sum".
PASSWD=${1-"YWRtaW4="}
IPADDR=${2-"192.168.0.1"}

URL=http://$IPADDR
REFERER="$URL/index.html"
URL_SET="$URL/goform/goform_set_cmd_process"
URL_GET="$URL/goform/goform_get_cmd_process"



command -v jq >/dev/null 2>&1 || { echo >&2 "'jq' is required but not installed. Aborting."; exit 1; }

IS_LOGGED=$(curl -s --header "Referer: $REFERER" $URL_GET\?multi_data\=1\&isTest\=false\&sms_received_flag_flag\=0\&sts_received_flag_flag\=0\&cmd\=loginfo | jq --raw-output .loginfo)

# Login
if [ "$IS_LOGGED" == "ok" ]; then
    echo "Logged in to ZTE"
else
    LOGIN=$(curl -s --header "Referer: $REFERER" -d 'isTest=false&goformId=LOGIN&password=' $PASSWD $URL_SET | jq --raw-output .result)
    echo "Loggining in to ZTE"

    # Disable wifi
    curl -s --header "Referer: $REFERER" -d 'goformId=SET_WIFI_INFO&isTest=false&m_ssid_enable=0&wifiEnabled=0' $URL_SET > /dev/null

    if [ "$LOGIN" == "0" ]; then
      echo "Logged in to ZTE"
    else
      echo "Could not login to ZTE"
      exit
    fi
fi

SMS=$(curl -s --header "Referer: $REFERER" $URL_GET\?multi_data\=1\&isTest\=false\&sms_received_flag_flag\=0\&sts_received_flag_flag\=0\&cmd\=sms_unread_num)
UNREAD_SMS=$(echo "$SMS" | jq --raw-output .sms_unread_num)

# Get unread messages
if [ "$UNREAD_SMS" == "0" ]; then
  echo "You have no unread message"
  exit
else
  echo "You have $UNREAD_SMS unread messages"

  MESSAGES=$(curl -s --header "Referer: $REFERER" $URL_GET\?isTest\=false\&cmd\=sms_data_total\&page\=0\&data_per_page\=500\&mem_store\=1\&tags\=10\&order_by\=order+by+id+desc)

  for MESSAGE in $(echo $MESSAGES | tr -d ' ' | jq -c '.messages | values []'); do
    TAG=$(echo $MESSAGE | jq --raw-output .tag)

    if [ "$TAG" == "1" ]; then
      ID=$(echo $MESSAGE | jq --raw-output .id)
      CONTENT=$(echo $MESSAGE | jq --raw-output .content | tr '\0' '\n' | xxd -r -p | tr -d '\0')

      echo "Message: $CONTENT"

      # Set message as read
      curl -s --header "Referer: $REFERER" -d "isTest=false&goformId=SET_MSG_READ&msg_id=$ID;&tag=0" $URL_SET > /dev/null

      # End right there if a blocked keyword is found
      for STR in "${BLOCKED[@]}"; do
        if [ "$(echo $CONTENT | grep -i "$STR")" ]; then
          echo "$STR is blocked"
          exit
        fi
      done

      # Send a push notification
      echo "Sending a push notification"
      curl -s \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "message=$CONTENT" \
        --form-string "title=ZTE SMS Forwarder" \
        --form-string "device=iPhone8" \
	https://api.pushover.net/1/messages.json
    fi
  done
fi
