#!/bin/sh
# One machine runs both fdbserver and the load generator. FoundationDB
# 7.3 or newer is required: on 7.1 the adapter's indexed queries fail in
# erlfdb_transaction_get_mapped_range. See ADR 0005.
set -e
/usr/lib/foundationdb/fdbmonitor --conffile /etc/foundationdb/foundationdb.conf \
  --lockfile /tmp/fdbmon.pid >/tmp/fdb.log 2>&1 &
sleep 6
fdbcli --exec "configure new single ssd" >/dev/null 2>&1 || true
sleep 3
fdbcli --exec "status minimal"
elixir /scaling.exs
echo "SCALING DONE"
sleep 120
