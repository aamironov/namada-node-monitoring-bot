#!/bin/bash
GREEN_COLOR='\033[0;32m'
RED_COLOR='\033[0;31m'
WITHOU_COLOR='\033[0m'

RPC_URL="http://localhost:26657"
BOT_TOKEN='***'

MIN_BLOCK_INC=6
MIN_PEERS=15
MISSED_BLOCKS_MAX=10
MISSED_BLOCKS_DELTA_MAX=2
TIMEOUT=10
TARGET_PULLING_INTERVAL=30
declare -A NODE_URLS

IFS=$'\n'

send_message() {
    echo "Send message #$1# to TG"

    curl --max-time $TIMEOUT -s -X POST https://api.telegram.org/bot$BOT_TOKEN/sendMessage \
    -d chat_id=$1 \
    -d text="$2" ;
}

#  $CHAT_ID $URL $OLD_STATUS $NEW_STATUS
compare_status_and_notify_user() {
	if [[ "$NEW_STATUS" == "" ]]; then
		if [[ "$OLD_STATUS" != "" ]]; then
			send_message $1 "Node gone offline"
		fi
		return;
	else
		if [[ "$OLD_STATUS" == "" ]]; then
			send_message $1 "Node is back online"
		fi
	fi

	OLD_VOTING_POWER=$(echo $3 | jq .result.validator_info.voting_power | xargs)
	VOTING_POWER=$(echo $4 | jq .result.validator_info.voting_power | xargs)
	if [[ "$OLD_VOTING_POWER" != "$VOTING_POWER" ]]; then
		send_message $1 "Voting power changed from $OLD_VOTING_POWER to $VOTING_POWER"
	fi

	IS_NOTIFIED_HANG=$(./db.sh get nodes.db "$URL"_hang_notification)
	if [[ "$NEW_STATUS" == "$OLD_STATUS" ]]; then
		LATEST_BLOCK_DATE=$(echo $NEW_STATUS | jq .result.sync_info.latest_block_time)
		TIMESTAMP=$(date -d "$LATEST_BLOCK_DATE" '+%s')
		CURRENT_TIMESTAMP=$(date +%s)
		TIMESTAMP_DIFF=$((CURRENT_TIMESTAMP - TIMESTAMP))
		if [[ $TIMESTAMP_DIFF -ge 1800 && "$IS_NOTIFIED_HANG" != "true" ]]; then
			send_message $1 "Node have not fetched any new blocks for last 30 minutes"
			./db.sh put nodes.db "$URL"_hang_notification true
		fi
	else
		./db.sh delete nodes.db "$URL"_hang_notification
	fi
}

get_updates() {
	LATEST_UPDATE=$(./db.sh get last.db LATEST_UPDATE)
	JSON=$(curl --max-time $TIMEOUT -s -X GET "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$LATEST_UPDATE")
	_VAR=$(echo $JSON | jq -r '.result[-1]')
	if [[ "$_VAR" != "null" ]]; then
		for i in "$(echo $JSON | jq -r '.result[]')"; do
			CHAT_ID=$(echo $i | jq -r .message.chat.id)
			URL=$(./db.sh get sub.db $CHAT_ID)
			TEXT=$(echo $i | jq -r .message.text)
			if [[ $TEXT == /seturl* ]]; then
				URL="${TEXT:8}"
				./db.sh put sub.db $CHAT_ID $URL
				./db.sh put nodes.db "$URL"_offline 0
				./db.sh put nodes.db "$URL"_active 0
				echo "/seturl $URL" 
			elif [[ $TEXT == /status ]]; then
				if [[ "$URL" == "" ]]; then
					send_message $CHAT_ID "No node assigned to this chat"
					continue;
				fi
				echo "/status $CHAT_ID $URL"
				NODE_STATUS=$(./db.sh get nodes.db $URL)
				MONIKER=$(echo $NODE_STATUS | jq -r .result.node_info.moniker)
				CHAIN_ID=$(echo $NODE_STATUS | jq -r .result.node_info.network)
				VERSION=$(echo $NODE_STATUS | jq -r .result.node_info.version)
				LATEST_BLOCK_HEIGHT=$(echo $NODE_STATUS | jq -r .result.sync_info.latest_block_height)
				LATEST_BLOCK_TIME=$(echo $NODE_STATUS | jq -r .result.sync_info.latest_block_time)
				LATEST_BLOCK_TIME=$(date -d "$LATEST_BLOCK_TIME")
				CATCHING_UP=$(echo $NODE_STATUS | jq -r .result.sync_info.catching_up)
				VOTING_POWER=$(echo $NODE_STATUS | jq -r .result.validator_info.voting_power)
				calculate_missed_blocks $URL
				ACTIVE_SAMPLES=$(./db.sh get nodes.db "$URL"_active)
				OFFLINE_SAMPLES=$(./db.sh get nodes.db "$URL"_offline)
				if [[ "$ACTIVE_SAMPLES" != "0" ]]; then
					UPTIME=$(( (ACTIVE_SAMPLES + OFFLINE_SAMPLES) / ACTIVE_SAMPLES ))
				else
					UPTIME="0"
				fi
				RESULT=""
				TEXT="Moniker: ${MONIKER}
				Chain id: ${CHAIN_ID}
				Node version: ${VERSION}
				Latest block height: ${LATEST_BLOCK_HEIGHT}
				Latest block date: ${LATEST_BLOCK_TIME}
				Catching up: ${CATCHING_UP}
				Number of missed blocks: ${RESULT}
				Voting power: ${VOTING_POWER}
				Uptime: ${UPTIME}%"
				send_message $CHAT_ID "$TEXT"
			else
				echo "Wrong command" 
			fi
		done
		LATEST_UPDATE=$(echo $JSON | jq -r '.result[-1].update_id')
		LATEST_UPDATE=$((LATEST_UPDATE+1))
		./db.sh put last.db LATEST_UPDATE $LATEST_UPDATE
	fi
}
calculate_missed_blocks() {
	VALIDATOR_ADDRESS_HASH=$(./db.sh get nodes.db $1 | jq -r .result.validator_info.address)
	if [[ "$VALIDATOR_ADDRESS_HASH" == "" ]]; then
		RESULT=50
		return
	fi
	MISSED_BLOCKS=0
	BLOCK_HEIGHT=`curl --max-time $TIMEOUT -s "{$RPC_URL}/status" 2> /dev/null | jq .result.sync_info.latest_block_height | xargs`
	for (( i = $BLOCK_HEIGHT; i>$BLOCK_HEIGHT-50 ; i-- )); do
		signatures=`curl --max-time $TIMEOUT -s "${RPC_URL}/block?height=${i}" | jq -r '.result.block.last_commit.signatures[].validator_address' `
		if ! echo "$signatures" | grep -q $VALIDATOR_ADDRESS_HASH; then
		  MISSED_BLOCKS=$((MISSED_BLOCKS+1))
		fi
	done
	RESULT=$MISSED_BLOCKS
}

get_nodes() {
	CHAT_IDS=($(./db.sh list sub.db))
	for i in "${!CHAT_IDS[@]}"; do
		CHAT_ID=${CHAT_IDS[$i]}
		if [[ "$CHAT_ID" == "null" ]]; then
			continue
		fi
		NODE_URLS[$CHAT_ID]=$(./db.sh get sub.db $CHAT_ID)
	done
}

get_rpc_status_and_store() {
	STATUS=`curl --max-time $TIMEOUT -s $1/status 2> /dev/null`
	./db.sh put nodes.db $1 $STATUS
	if [[ "$STATUS" != "" ]]; then
		_VAR=$(./db.sh get nodes.db "$1"_active)
		_VAR=$((_VAR+1))
		./db.sh put nodes.db "$1"_active $_VAR
		./db.sh put nodes.db "$1"_last $STATUS
	else
		_VAR=$(./db.sh get nodes.db "$1"_offline)
		_VAR=$((_VAR+1))
		./db.sh put nodes.db "$1"_offline $_VAR
	fi
}

./db.sh put nodes.db null null
./db.sh put last.db null null
./db.sh put sub.db null null

for (( ;; )); do
	CURRENT_TIMESTAMP=$(date +%s)
	TARGET_TIMESTAMP=$((CURRENT_TIMESTAMP+$TARGET_PULLING_INTERVAL))
	echo "Pull bot updates"
	get_updates

	echo "Fetch node statuses"
	get_nodes
	for CHAT_ID in "${!NODE_URLS[@]}"
	do
		
		URL=${NODE_URLS[$CHAT_ID]}
		LAST_STATUS=$(./db.sh get nodes.db "$URL"_last)
		OLD_STATUS=$(./db.sh get nodes.db $URL)
		get_rpc_status_and_store $URL
		NEW_STATUS=$(./db.sh get nodes.db $URL)
		if [[ "$LAST_STATUS" != "" ]]; then # if node was ever active
			compare_status_and_notify_user $CHAT_ID $URL $OLD_STATUS $NEW_STATUS
		fi
	done
	
	TIMESTAMP_DIFF=$((TARGET_TIMESTAMP - CURRENT_TIMESTAMP))
	if [[ $TIMESTAMP_DIFF -ge 0 ]]; then
		for (( timer=$TIMESTAMP_DIFF; timer>0; timer-- ))
		do
			printf "* sleep for ${RED_COLOR}%02d${WITHOUT_COLOR} sec\r" $timer
			sleep 1
		done
	fi
done
