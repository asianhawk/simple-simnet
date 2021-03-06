#!/bin/bash -e

# Script for starting several lnd in one container
# It creates simnet network
# Connect 4 lnd to it
# Send initial money
# Open channels between them
# Forward ports for lnd rpc (so you can connect to lnd from outside word)
# Note: it creates ssh server inside container.
# 0 node is used as a wallet, to mine coins in it
# Nodes have following channels 1-2, 2-3

. /simnet/bin/config.sh

function start_btcd {
    PARAMS=$(echo \
        "--$BITCOIN_NETWORK" \
        "--debuglevel=$DEBUG" \
        "--rpcuser=$RPCUSER" \
        "--rpcpass=$RPCPASS" \
        "--datadir=/simnet/btcd" \
        "--logdir=/simnet/btcd" \
        "--rpccert=/simnet/rpc/rpc.cert" \
        "--rpckey=/simnet/rpc/rpc.key" \
        "--rpclisten=0.0.0.0" \
        "--txindex"
    )
    # Set the mining flag only if address is non empty.
    if [[ -n "$MINING_ADDRESS" ]]; then
        PARAMS="$PARAMS --miningaddr=$MINING_ADDRESS"
    fi

    # Add user parameters to command.
    PARAMS="$PARAMS $@"

    # Print command and start bitcoin node.
    # Launch btcd in background
    echo "Command: btcd $PARAMS"
    btcd $PARAMS &>/dev/null
}

function start_lnd {
    lnd \
        --datadir="$1/data" \
        --logdir="$1/logs" \
        --bitcoin.active \
        "--bitcoin.$BITCOIN_NETWORK" \
        --bitcoin.rpchost="localhost" \
        --bitcoin.rpccert="/simnet/rpc/rpc.cert" \
        --bitcoin.rpcuser="$RPCUSER" \
        --bitcoin.rpcpass="$RPCPASS" \
        --debuglevel="$DEBUG" \
        --peerport="$2" \
        --rpcport="$3"\
        "$@" &>/dev/null
}

function start_btcctl {
    btcctl \
        "--$BITCOIN_NETWORK" \
        --rpccert="/simnet/rpc/rpc.cert" \
        --rpcuser="$RPCUSER" \
        --rpcpass="$RPCPASS" \
        --rpcserver="localhost" \
        "$@" &>/dev/null
}

# Start ssh for port forwarding
/usr/sbin/sshd
sleep 1
sshpass -p toor ssh -nNT -o StrictHostKeyChecking=no -R ${RPCPORT0EXT}:localhost:${RPCPORT0} root@localhost &
sshpass -p toor ssh -nNT -o StrictHostKeyChecking=no -R ${RPCPORT1EXT}:localhost:${RPCPORT1} root@localhost &
sshpass -p toor ssh -nNT -o StrictHostKeyChecking=no -R ${RPCPORT2EXT}:localhost:${RPCPORT2} root@localhost &
sshpass -p toor ssh -nNT -o StrictHostKeyChecking=no -R ${RPCPORT3EXT}:localhost:${RPCPORT3} root@localhost &

start_btcd &
start_lnd /simnet/lnd0 $PEERPORT0 $RPCPORT0 &
sleep 10
MINING_ADDRESS=$(lncli --rpcserver localhost:$RPCPORT0 newaddress p2wkh | jq  -r ".address")
echo "MINING_ADDRESS=" $MINING_ADDRESS
kill $(pgrep btcd)
sleep 3
# Now start btcd again. MINING_ADDRESS is set. So it should use it as a mining address.
start_btcd &
sleep 3
start_btcctl generate 1025
sleep 30

start_lnd /simnet/lnd1 $PEERPORT1 $RPCPORT1 &
start_lnd /simnet/lnd2 $PEERPORT2 $RPCPORT2 &
start_lnd /simnet/lnd3 $PEERPORT3 $RPCPORT3 &

sleep 15

ADDRNODE1=$(lncli --rpcserver localhost:$RPCPORT1 newaddress p2wkh | jq  -r ".address")
ADDRNODE2=$(lncli --rpcserver localhost:$RPCPORT2 newaddress p2wkh | jq  -r ".address")
ADDRNODE3=$(lncli --rpcserver localhost:$RPCPORT3 newaddress p2wkh | jq  -r ".address")

IDENTITYKEY0=$(lncli --rpcserver localhost:$RPCPORT0 getinfo | jq -r ".identity_pubkey")
IDENTITYKEY1=$(lncli --rpcserver localhost:$RPCPORT1 getinfo | jq -r ".identity_pubkey")
IDENTITYKEY2=$(lncli --rpcserver localhost:$RPCPORT2 getinfo | jq -r ".identity_pubkey")
IDENTITYKEY3=$(lncli --rpcserver localhost:$RPCPORT3 getinfo | jq -r ".identity_pubkey")

echo "Balances before send"
lncli --rpcserver localhost:$RPCPORT0 walletbalance
lncli --rpcserver localhost:$RPCPORT1 walletbalance
lncli --rpcserver localhost:$RPCPORT2 walletbalance
lncli --rpcserver localhost:$RPCPORT3 walletbalance

lncli --rpcserver localhost:$RPCPORT0 sendmany "{\"$ADDRNODE1\":${STARTBALANCE}, \"$ADDRNODE2\":${STARTBALANCE}, \"$ADDRNODE3\":${STARTBALANCE} }"
sleep 3
start_btcctl generate 20
sleep 60

echo "Balances after send"
lncli --rpcserver localhost:$RPCPORT0 walletbalance
lncli --rpcserver localhost:$RPCPORT1 walletbalance
lncli --rpcserver localhost:$RPCPORT2 walletbalance
lncli --rpcserver localhost:$RPCPORT3 walletbalance

#Connect first node to second and create a channel
lncli --rpcserver localhost:${RPCPORT1} connect ${IDENTITYKEY2}@localhost:${PEERPORT2}
sleep 1
lncli --rpcserver localhost:${RPCPORT1} openchannel --node_key ${IDENTITYKEY2} --local_amt ${CHANNELSIZE} --push_amt ${PUSHAMOUNT} --num_confs 1
sleep 1
start_btcctl generate 10
sleep 10

#Connect second node to third and create a channel
lncli --rpcserver localhost:${RPCPORT2} connect ${IDENTITYKEY3}@localhost:${PEERPORT3}
sleep 1
lncli --rpcserver localhost:${RPCPORT2} openchannel --node_key ${IDENTITYKEY3} --local_amt ${CHANNELSIZE} --push_amt ${PUSHAMOUNT} --num_confs 1
sleep 1
start_btcctl generate 10

sleep 10

lncli --rpcserver localhost:${RPCPORT1} listchannels
lncli --rpcserver localhost:${RPCPORT1} describegraph

echo "lnd0 (lncli0) is not connected to other lnd nodes, it is used as bitcoin wallet"
echo "lnd1 (lncli1) has channel and is connected to lnd2 (lncli2)"
echo "lnd2 (lncli2) has channel and is connected to lnd3 (lncli3)"

echo "CMD" "RPCPORT" "PEERPORT" "IDENTITYKEY"
echo "lncli0" ${RPCPORT0EXT} ${PEERPORT0} ${IDENTITYKEY0}
echo "lncli1" ${RPCPORT1EXT} ${PEERPORT1} ${IDENTITYKEY1}
echo "lncli2" ${RPCPORT2EXT} ${PEERPORT2} ${IDENTITYKEY2}
echo "lncli3" ${RPCPORT3EXT} ${PEERPORT3} ${IDENTITYKEY3}


echo "Sleeping for infinity"
sleep infinity