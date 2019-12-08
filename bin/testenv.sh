#!/bin/bash
source test/prelude.sh

cat <<EOL

You can access beyondcoind and lightningd via:

  $ beyondcoin-cli --datadir=$BYND_DIR
  $ lightning-cli --lightning-dir=$LN_ALICE_PATH
  $ lightning-cli --lightning-dir=$LN_BOB_PATH

Beyondcoin Lightning Charge is available at:

  $CHARGE_URL

You can run the unit tests against the running services with:

  $ CHARGE_URL=$CHARGE_URL LN_BOB_PATH=$LN_BOB_PATH npm test

EOL

read -p 'Press enter to shutdown and clean up'
source test/teardown.sh
