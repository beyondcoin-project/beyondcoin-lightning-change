#!/bin/bash
set -eo pipefail
shopt -s expand_aliases

# check dependencies
command -v jq > /dev/null || { echo >&2 "jq is required. see https://stedolan.github.io/jq/download/"; exit 1; }
(command -v beyondcoind && command -v beyondcoin-cli) > /dev/null || { echo >&2 "beyondcoind and beyondcoin-cli must be in PATH. to install, see https://bitcoin.org/en/full-node#linux-instructions"; exit 1; }
(command -v lightningd && command -v lightning-cli) > /dev/null || { echo >&2 "lightningd and lightning-cli must be in PATH. to install, see https://github.com/ElementsProject/lightning/blob/master/README.md#getting-started"; exit 1; }

trap 'pkill -P $CHARGE_PID && kill `jobs -p` 2> /dev/null' SIGTERM

if [ -n "$VERBOSE" ]; then
  set -x
  dbgout=/dev/stderr
else
  dbgout=/dev/null
  sedq='--quiet'
fi

: ${DIR:=`mktemp -d`}
BYND_DIR=$DIR/beyondcoin

# Alice is the backend for Charge, Bob is paying customer
LN_ALICE_PATH=$DIR/lightning-alice
LN_BOB_PATH=$DIR/lightning-bob

CHARGE_DB=$DIR/charge.sqlite
CHARGE_PORT=`get-port`
CHARGE_TOKEN=`head -c 10 /dev/urandom | base64 | tr -d '+/='`
CHARGE_URL=http://api-token:$CHARGE_TOKEN@localhost:$CHARGE_PORT

alias bynd="beyondcoin-cli --datadir=$BYND_DIR"
alias lna="lightning-cli --lightning-dir=$LN_ALICE_PATH"
alias lnb="lightning-cli --lightning-dir=$LN_BOB_PATH"

echo Setting up test envirnoment in $DIR

# Setup beyondcoind

echo Setting up beyondcoind >&2
mkdir -p $BYND_DIR
cat >$BYND_DIR/beyondcoin.conf <<EOL
regtest=1
printtoconsole=0

[regtest]
rpcport=`get-port`
port=`get-port`
EOL

beyondcoind -datadir=$BYND_DIR $BEYONDCOIND_OPTS &

echo - Waiting for beyondcoind to warm up... > $dbgout
command -v inotifywait > /dev/null \
  && sed --quiet '/^\.cookie$/ q' <(inotifywait -e create,moved_to --format '%f' -qmr $BYND_DIR) \
  || sleep 2 # fallback to slower startup if inotifywait is not available

bynd -rpcwait getblockchaininfo > /dev/null

addr=`bynd getnewaddress`

echo - Generating some blocks... > $dbgout
bynd generatetoaddress 101 $addr > /dev/null

# Setup lightningd

echo Setting up lightningd >&2

LN_OPTS="$LN_OPTS --network=regtest --dev-beyondcoind-poll=1 --beyondcoin-datadir=$BYND_DIR --log-level=debug --log-file=debug.log
  --allow-deprecated-apis="$([ -n "$ALLOW_DEPRECATED" ] && echo true || echo false)

lightningd $LN_OPTS --addr=127.0.0.1:`get-port` --lightning-dir=$LN_ALICE_PATH  &> $dbgout &
lightningd $LN_OPTS --addr=127.0.0.1:`get-port` --lightning-dir=$LN_BOB_PATH &> $dbgout &

echo - Waiting for lightningd rpc unix socket... > $dbgout
sed $sedq "/Listening on 'lightning-rpc'/ q" <(tail -F -n+0 $LN_ALICE_PATH/debug.log 2> /dev/null)
sed $sedq "/Listening on 'lightning-rpc'/ q" <(tail -F -n+0 $LN_BOB_PATH/debug.log 2> /dev/null)

echo - Funding lightning wallet... > $dbgout
bynd sendtoaddress $(lnb newaddr | jq -r '.bech32 // .address') 1 > $dbgout
bynd generatetoaddress 1 $addr > /dev/null
sed $sedq '/Owning output [0-9]/ q' <(tail -F -n+0 $LN_BOB_PATH/debug.log)

echo - Connecting peers... > $dbgout
aliceid=`lna getinfo | jq -r .id`
lnb connect $aliceid 127.0.0.1 `lna getinfo | jq -r .binding[0].port` | jq -c . > $dbgout

echo - Setting up channel... > $dbgout
lnb fundchannel $aliceid 16777215 10000perkb | jq -c . > $dbgout
bynd generatetoaddress 1 $addr > /dev/null

sed $sedq '/State changed from CHANNELD_AWAITING_LOCKIN to CHANNELD_NORMAL/ q' <(tail -f -n+0 $LN_ALICE_PATH/debug.log)
sed $sedq '/State changed from CHANNELD_AWAITING_LOCKIN to CHANNELD_NORMAL/ q' <(tail -f -n+0 $LN_BOB_PATH/debug.log)

[[ -n "$VERBOSE" ]] && lna listpeers | jq -c .peers[0]

# Setup Lightning Charge

echo Setting up charged >&2

DEBUG=$DEBUG,lightning-*,knex:query,knex:bindings \
bin/charged -l $LN_ALICE_PATH -d $CHARGE_DB -t $CHARGE_TOKEN -p $CHARGE_PORT -e ${NODE_ENV:-test} &> $DIR/charge.log &

CHARGE_PID=$!
sed $sedq '/HTTP server running/ q' <(tail -F -n+0 $DIR/charge.log 2> /dev/null)

curl --silent --fail $CHARGE_URL/invoices > /dev/null

echo All services up and running > $dbgout
