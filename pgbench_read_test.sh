#!/bin/bash

set -e

CONNSTR_TESTDB="host=/var/run/postgresql dbname=bench"

PGBENCH_SCALE="${1:-1}"
PGBENCH_DURATION="${2:-3}"
CPUS="${3:-2}"
PGBENCH_INIT_FLAGS="--unlogged -F 80"
PGBENCH_PROTOCOL=prepared
FULL_SCANS_TO_RUN=3

echo "Starting pgbench - scale: $PGBENCH_SCALE, duration: $PGBENCH_DURATION, cpus: $CPUS ..."
date

function exec_sql() {
    psql "$CONNSTR_TESTDB" -Xqc "$1"
}

BATCH_READ=$(cat <<"EOF"
-- Ca 2MB batch
\set aid_from random(1, 100000 * :scale)
\set aid_to :aid_from + 10000
SELECT abalance FROM pgbench_accounts WHERE aid BETWEEN :aid_from and :aid_to
EOF
)

FULL_SCAN='SELECT count(*) FROM pgbench_accounts WHERE abalance NOTNULL'

PGSS_RESULTS=$(cat <<"EOF"
select
  mean_exec_time::numeric(9,3), stddev_exec_time::numeric(9,3), calls, rows,
  (100::numeric * shared_blks_hit / (shared_blks_hit + shared_blks_read))::numeric(7,1) as sb_hit_pct,
  query
from pg_stat_statements
where query ~* '(INSERT|UPDATE|SELECT).*pgbench_accounts'
order by total_exec_time desc limit 5
EOF
)

SQL_PGSS_SETUP="CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
SQL_PGSS_RESET="SELECT pg_stat_statements_reset();"

echo -e "\nEnsuring pg_stat_statements extension on test instance ..."
exec_sql "$SQL_PGSS_SETUP"

echo -e "\nCreating test data using pgbench ..."
date
echo "pgbench -i -q $PGBENCH_INIT_FLAGS -s $PGBENCH_SCALE"
pgbench -i -q $PGBENCH_INIT_FLAGS -s $PGBENCH_SCALE
date

DBSIZE=`psql "$CONNSTR_TESTDB" -XAtqc "select pg_size_pretty(pg_database_size(current_database()))"`
echo -e "\nDB size = $DBSIZE"

TBLSIZE=`psql "$CONNSTR_TESTDB" -XAtqc "select pg_size_pretty(pg_table_size('pgbench_accounts'))"`
echo -e "\npgbench_accounts size = $TBLSIZE"

echo "Reseting pg_stat_statements..."
exec_sql "$SQL_PGSS_RESET" >/dev/null

echo -e "\nRunning the key read test"
echo -e "pgbench --random-seed 666 -M $PGBENCH_PROTOCOL -c $((CPUS*4)) -T $PGBENCH_DURATION -f- \"$CONNSTR_TESTDB\"\n"
pgbench --random-seed 666 -S -M $PGBENCH_PROTOCOL -c $((CPUS*4)) -T $PGBENCH_DURATION "$CONNSTR_TESTDB"

echo "sleep 120"
sleep 120

echo -e "\nRunning the batch read test"
echo -e "echo '$BATCH_READ' | pgbench -f- -n --random-seed 666 -M $PGBENCH_PROTOCOL -c $((CPUS*2)) -T $PGBENCH_DURATION \"$CONNSTR_TESTDB\"\n"
echo "$BATCH_READ" | pgbench -f- -n --random-seed 666 -s $PGBENCH_SCALE -M $PGBENCH_PROTOCOL -c $((CPUS*2)) -T $PGBENCH_DURATION "$CONNSTR_TESTDB"

echo "sleep 120"
sleep 120

echo -e "\nRunning the full scan read test"
date
echo -e "echo '$FULL_SCAN' | pgbench -f- -n -c 1 -t $FULL_SCANS_TO_RUN \"$CONNSTR_TESTDB\"\n"
echo "$FULL_SCAN" | pgbench -f- -n -c 1 -t $FULL_SCANS_TO_RUN "$CONNSTR_TESTDB"
date

echo -e "\npg_stat_statements results:"
exec_sql "$PGSS_RESULTS"
