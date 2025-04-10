#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: ./launch_vms_and_run_test.sh REGION"
  echo "Example:"
  echo "   ./launch_vms_and_run_test.sh eu-south-2"
  exit 1
fi

mkdir logs

set -u

TEST_ID=run1  # needs to be lowercase, dashes allowed
REGION="$1"  # eu-south-2 (Spain) best in EU currently according to: pg_spot_operator --list-avg-spot-savings --region ^eu
STRIPE_COUNTS="0 2 4 8"
STRIPE_SIZES="32 64 128"
PGBENCH_DURATION=600
STORAGE_MIN=200  # GB
PGBENCH_SCALE=4000
CPU_MIN=4
RAM_MIN=4

LOCAL_TEST=0  # Uses postgres@localhost as remote host
MAX_TRIES=3  # Spots VMs can disappear ...

T1=$(date +%s)

for stripe_count in $STRIPE_COUNTS ; do

if [ "$stripe_count" -eq 0 ]; then
  STRIPE_SIZES_FINAL=64  # No effect for a single disk, just run 1 test
else
  STRIPE_SIZES_FINAL="$STRIPE_SIZES"
fi

for stripe_size in $STRIPE_SIZES_FINAL ; do

  # Launch a Spot VM with Postgres, place Ansible connstr in $INSTANCE_ID.ini
  echo "Starting the test for TEST_ID=$TEST_ID STRIPE_COUNT=$stripe_count STRIPE_SIZE=$stripe_size CPU_MIN=$CPU_MIN RAM_MIN=$RAM_MIN in region $REGION ..."

  INSTANCE_ID="${TEST_ID}-sc-${stripe_count}-ss-${stripe_size}"
  INVENTORY_FILE="${TEST_ID}-inventory-sc-${stripe_count}-ss-${stripe_size}.ini"

  TEST_SUCCESS=0
  for try in $(seq 1 $MAX_TRIES) ; do

  if [ "$LOCAL_TEST" -eq 0 ]; then
    # Prerequisite: pipx install --include-deps ansible pg_spot_operator
    # Details: https://github.com/pg-spot-ops/pg-spot-operator

    if [ "$stripe_count" -gt 0 ]; then
      pg_spot_operator --instance-name $INSTANCE_ID --region $REGION \
        --cpu-min $CPU_MIN --ram-min $RAM_MIN \
        --storage-min $STORAGE_MIN --selection-strategy eviction-rate \
        --stripes $stripe_count --stripe-size-kb $stripe_size \
        --connstr-only --connstr-format ansible \
        --os-extra-packages rsync > $INVENTORY_FILE 2>> pg_spot_operator.log
    else
      pg_spot_operator --instance-name $INSTANCE_ID --region $REGION \
        --cpu-min $CPU_MIN --ram-min $RAM_MIN \
        --storage-min $STORAGE_MIN --selection-strategy eviction-rate \
        --connstr-only --connstr-format ansible \
        --os-extra-packages rsync > $INVENTORY_FILE 2>> pg_spot_operator.log
    fi
    if [ $? -ne 0 ]; then
      echo "ERROR provisioning the VM, see pg_spot_operator.log for details"
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
    if [ "$LOCAL_TEST" -eq 0 ]; then
      echo "Shutting down the instance ..."
      echo "pg_spot_operator --region $REGION --instance-name $INSTANCE_ID --teardown &>> pg_spot_operator_teardown.log"
      TEST_SUCCESS=1
      pg_spot_operator --region $REGION --instance-name $INSTANCE_ID --teardown &>> pg_spot_operator_teardown.log
      if [ "$?" -ne 0 ]; then
        echo "WARNING: nonzero pg_spot_operator --teardown result, check the pg_spot_operator_teardown.log"
      fi
      break
    fi
  else
    echo "ERROR: Ansible failed - check the log at $ANSIBLE_LOG_PATH"
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
