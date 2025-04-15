#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: ./launch_vms_and_run_test.sh REGION"
  echo "Example:"
  echo "   ./launch_vms_and_run_test.sh eu-south-2"
  exit 1
fi

if [ ! -d ./logs ]; then
  mkdir logs
fi

set -u

TEST_ID=m6idn-xlarge  # only lowercase and dashes allowed
REGION="$1"  # eu-south-2 (Spain) best in EU currently according to: pg_spot_operator --list-avg-spot-savings --region ^eu
STRIPE_COUNTS="1 2 4 8 16"
STRIPE_SIZES="8 16 32 64 128"
PGBENCH_DURATION=600
STORAGE_MIN=500  # GB
PGBENCH_SCALE=8000  # 141 GB DB size, with FF80. Aiming for ~10% RAM-to-disk ratio
CPU_MIN=4  # relevant if INSTANCE_TYPE not set
RAM_MIN=4  # relevant if INSTANCE_TYPE not set
# Resolves to something like:
# https://instances.vantage.sh/aws/ec2/c6g.xlarge?region=eu-south-2&os=linux&cost_duration=hourly&reserved_term=Standard.noUpfront
INSTANCE_TYPE=m6idn.xlarge
# Better to use something like m6idn.xlarge with max 100K IOPS though
# https://instances.vantage.sh/aws/ec2/m6idn.xlarge?region=eu-south-2&os=linux&cost_duration=hourly&reserved_term=Standard.noUpfront

LOCAL_TEST=0  # Uses postgres@localhost as remote host
MAX_TRIES=3  # Spot VMs can disappear ...

T1=$(date +%s)

for stripe_count in $STRIPE_COUNTS ; do

if [ "$stripe_count" -eq 1 ]; then
  STRIPE_SIZES_FINAL=64  # No effect for a single disk, just run 1 test
else
  STRIPE_SIZES_FINAL="$STRIPE_SIZES"
fi

for stripe_size in $STRIPE_SIZES_FINAL ; do

  # Launch a Spot VM with Postgres, place Ansible connstr in $INSTANCE_ID.ini
  echo "Starting the test for TEST_ID=$TEST_ID STRIPE_COUNT=$stripe_count STRIPE_SIZE=$stripe_size CPU_MIN=$CPU_MIN RAM_MIN=$RAM_MIN in region $REGION ..."

  INSTANCE_ID="${TEST_ID}-sc-${stripe_count}-ss-${stripe_size}"
  INVENTORY_FILE="${TEST_ID}-inventory-sc-${stripe_count}-ss-${stripe_size}.ini"
  OPERATOR_LOG=${TEST_ID}_pg_spot_operator_sc_${stripe_count}_ss_${stripe_size}.log
  TEST_SUCCESS=0
  echo "pg_spot_operator --instance-name=$INSTANCE_ID"
  echo "pg_spot_operator log: logs/$OPERATOR_LOG"

  for try in $(seq 1 $MAX_TRIES) ; do

  if [ "$LOCAL_TEST" -eq 0 ]; then
    # Prerequisite: pipx install --include-deps ansible pg_spot_operator
    # Details: https://github.com/pg-spot-ops/pg-spot-operator

    if [ -n "$INSTANCE_TYPE" ]; then
        pg_spot_operator --instance-name $INSTANCE_ID --region $REGION \
          --instance-type $INSTANCE_TYPE \
          --storage-min $STORAGE_MIN --selection-strategy eviction-rate \
          --stripes $stripe_count --stripe-size-kb $stripe_size \
          --connstr-only --connstr-format ansible \
          --os-extra-packages rsync,dstat > $INVENTORY_FILE 2>> logs/$OPERATOR_LOG
    else
        pg_spot_operator --instance-name $INSTANCE_ID --region $REGION \
          --cpu-min $CPU_MIN --ram-min $RAM_MIN \
          --storage-min $STORAGE_MIN --selection-strategy eviction-rate \
          --stripes $stripe_count --stripe-size-kb $stripe_size \
          --connstr-only --connstr-format ansible \
          --os-extra-packages rsync,dstat > $INVENTORY_FILE 2>> logs/$OPERATOR_LOG
    fi
    if [ $? -ne 0 ]; then
      echo "ERROR provisioning the VM, see logs/${OPERATOR_LOG} for details"
      continue
    fi
  else
    echo "*** In LOCAL test mode ***"
    echo "localhost ansible_user=postgres" > $INVENTORY_FILE
  fi

  echo "Using Ansible inventory file: $INVENTORY_FILE"
  cat $INVENTORY_FILE

  ANSIBLE_LOG_PATH=logs/${TEST_ID}_ansible_${INSTANCE_ID}.log
  echo "VM OK - running Ansible ..."
  ANSIBLE_LOG_PATH=${ANSIBLE_LOG_PATH} ansible-playbook -i $INVENTORY_FILE \
    -e stripe_count=${stripe_count} -e stripe_size=${stripe_size} \
    -e pgbench_scale=$PGBENCH_SCALE -e pgbench_duration=$PGBENCH_DURATION \
    -e cpus=$CPU_MIN -e test_id="$TEST_ID" \
    ebs_test_playbook.yml

  if [ "$?" -eq 0 ]; then
    echo "Ansible playbook run OK"
    TEST_SUCCESS=1
    if [ "$LOCAL_TEST" -eq 0 ]; then
      echo "Shutting down the instance ..."
      echo "pg_spot_operator --region $REGION --instance-name $INSTANCE_ID --teardown &>> logs/pg_spot_operator_teardown.log"
      pg_spot_operator --region $REGION --instance-name $INSTANCE_ID --teardown &>> logs/$OPERATOR_LOG
      if [ "$?" -ne 0 ]; then
        echo "WARNING: nonzero pg_spot_operator --teardown result, check the logs/${OPERATOR_LOG}.log"
      fi
      break
    fi
  else
    echo "ERROR: Ansible failed - check the log at $ANSIBLE_LOG_PATH"
    echo "sleep 60 before retry"
    sleep 60
    continue
  fi

  done  # MAX_TRIES

  if [ "$TEST_SUCCESS" -eq 0 ]; then
    echo "Testing stripe_size $stripe_size stripe_count $stripe_count failed"
    exit 1
  fi

done  # $STRIPE_SIZES

done  # $STRIPE_COUNTS

T2=$(date +%s)
DUR=$((T2-T1))

echo "Done in $DUR seconds"
