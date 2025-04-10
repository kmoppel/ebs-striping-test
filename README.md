# ebs-striping-test
Test effects of EBS striping with different stripe sizes on gp3 volumes.

## Tested read modes

* pgbench --read-only key fetches, CPU*4 parallelism
* pgbench index range scans, 10K row batches, CPU*2 parallelism
* full scans, no parallelism

# Prerequisites

* AWS CLI installed / configured
* [pg-spot-operator](https://github.com/pg-spot-ops/pg-spot-operator) Python CLI installed
* Ansible installed

# Running the test

1. Set target pggbench scale and needed storage size in header of `launch_vms_and_run_test.sh`
2. Inquiry which is the most affordable region currently for experimenting on EC2
  `pg_spot_operator --list-avg-spot-savings --region ^eu`
3. Run the test
```
./launch_vms_and_run_test.sh eu-south-2
```
4. Analyze logs from the `logs` folder. pg_stat_statements output at end of the file. 

## Testing on local Postgres

Just change `LOCAL_TEST=0` to `LOCAL_TEST=1` in launch_vms_and_run_test.shand Ansible / pg-spot-operator won't be called
and Postgres is expected to be at `CONNSTR_TESTDB="host=/var/run/postgresql dbname=postgres"` (pgbench_read_test.sh)
