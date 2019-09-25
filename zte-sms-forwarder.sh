#!/bin/bash
PUSHOVER_TOKEN="<token>"
PUSHOVER_USER="<user>"

URL=http://192.168.0.1
REFERER="$URL/index.html"
URL_SET="$URL/goform/goform_set_cmd_process"
URL_GET="$URL/goform/goform_get_cmd_process"

if [ ! -z "$(apt-cache policy jq | grep Installed | grep none)" ]; then
  echo 'jq is not installed'
  exit
fi

IS_LOGGED=$(curl -s --header "Referer: $REFERER" $URL_GET\?multi_data\=1\&isTest\=false\&sms_received_flag_flag\=0\&sts_received_flag_flag\=0\&cmd\=loginfo | jq --raw-output .loginfo)

# Login
if [ "$IS_LOGGED" == "ok" ]; then
    echo "Logged in to ZTE"
else
    LOGIN=$(curl -s --header "Referer: $REFERER" -d 'isTest=false&goformId=LOGIN&password=YWRtaW4=' $URL_SET | jq --raw-output .result)
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
# NEW_SMS=$(echo "$SMS" | jq --raw-output .sms_received_flag)
UNREAD_SMS=$(echo "$SMS" | jq --raw-output .sms_unread_num)

# Get new SMS
if [ "$UNREAD_SMS" == "0" ]; then
  echo "You have no unread message"
  exit
else
  echo "You have $UNREAD_SMS unread messages"

  MESSAGES=$(curl -s --header "Referer: $REFERER" $URL_GET\?isTest\=false\&cmd\=sms_data_total\&page\=0\&data_per_page\=500\&mem_store\=1\&tags\=10\&order_by\=order+by+id+desc)

  for MESSAGE in $(echo $MESSAGES | jq -c '.messages | values []'); do
    TAG=$(echo $MESSAGE | jq --raw-output .tag)

    if [ "$TAG" == "1" ]; then
      ID=$(echo $MESSAGE | jq --raw-output .id)
      CONTENT=$(echo $MESSAGE | jq --raw-output .content | xxd -r -p)

      # Set message as read
      curl -s --header "Referer: $REFERER" -d "isTest=false&goformId=SET_MSG_READ&msg_id=$ID;&tag=0" $URL_SET

      echo "Message: $CONTENT"

      curl -s \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "message=$CONTENT" \
        --form-string "title=ZTE SMS Forwarded" \
        --form-string "device=iPhone8" \
        https://api.pushover.net/1/messages.json
    fi
  done
fi