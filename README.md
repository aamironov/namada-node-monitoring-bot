## namada-node-monitoring-bot 
Simple external monitoring bot with telegram notification. The bot is external, so it is counting uptime and can detect if node became inaccessible. Bot fetch data once in 30 seconds.

## Notification
Node is unavailable
Node became active
Node doesn't fetch blocks
Voting power changes

## Supported commands
/seturl <rpc_url> - assigning rpc url to current chat and all notification about the node will be send to this chat
/status - print node status

## Usage
1. Edit check.sh
RPC_URL="http://localhost:26657" ## Edit this if there is no local node on the host
BOT_TOKEN='***' ## Telegram bot token
2. Run ./check.sh
