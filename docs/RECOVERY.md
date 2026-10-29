# Point-in-time recovery with MySQL binary logs

**Story for the viva:** the ledger can't be edited, but a careless administrator can still run
`TRUNCATE TABLE` or `DROP`, and triggers do not fire for those. The defence is (1) no such privileges
for application accounts and (2) backups plus binary logs, so the database can be rolled forward to the
second before the mistake.

Use **Command Prompt (cmd)**, not PowerShell, for the commands below. Change paths and file names to
match your PC.

## 0. Check that binary logging is on (it is by default)

In the `mysql>` prompt:

```sql
SHOW VARIABLES LIKE 'log_bin';            -- should say ON
SHOW VARIABLES LIKE 'log_bin_basename';   -- shows the folder and file prefix of the logs
SHOW BINARY LOGS;                         -- the current log is the last one listed
```

## 1. Take a full backup

```
mkdir D:\backup
mysqldump -u root -p --single-transaction --flush-logs --source-data=2 --routines --triggers --events --databases stock_ledger_db stock_ledger_auth --result-file=D:\backup\full.sql
```

* `--flush-logs` starts a fresh binary log file, so everything after the backup lives in a new file.
* `--source-data=2` writes a comment near the top of `full.sql` with the log file name and position
  (a line starting `-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE=...`). Note both values.
* On an older server use `--master-data=2` instead of `--source-data=2`.
* `--result-file` is used instead of `>` because PowerShell's `>` would save the file in the wrong encoding.

## 2. Carry on working

Use the dashboard to record a few movements. Write down the time:

```sql
SELECT NOW();
SELECT COUNT(*) FROM stock_ledger;     -- remember this number
```

## 3. The disaster

As root, in the `mysql>` prompt:

```sql
USE stock_ledger_db;
SELECT NOW();                          -- write this down: this is the moment of the disaster
TRUNCATE TABLE stock_ledger;           -- the delete trigger does NOT stop this
SELECT COUNT(*) FROM stock_ledger;     -- 0
```

## 4. Recover

1. Restore the full backup (this recreates the database as it was at backup time):

   ```
   mysql -u root -p < D:\backup\full.sql
   ```

2. Find the binary log files written since the backup (the file named in `full.sql`, and any newer ones):

   ```sql
   SHOW BINARY LOGS;
   ```

3. Replay them up to just before the disaster. The start position is the one from `full.sql`
   (use `--start-position` only on the first file), the stop time is the time you wrote down in step 3,
   minus a second:

   ```
   mysqlbinlog --database=stock_ledger_db --start-position=<POS_FROM_FULL_SQL> --stop-datetime="2026-10-25 15:41:59" "<folder from log_bin_basename>\binlog.00000X" --result-file=D:\backup\replay.sql
   mysql -u root -p < D:\backup\replay.sql
   ```

   If you prefer exact control, run `SHOW BINLOG EVENTS IN 'binlog.00000X';`, find the position of the
   `TRUNCATE` event, and use `--stop-position=<that position>` instead of `--stop-datetime`.

4. Verify:

   ```sql
   USE stock_ledger_db;
   SELECT COUNT(*) FROM stock_ledger;              -- the number from step 2 again
   SELECT COUNT(*) FROM v_reconciliation WHERE difference <> 0;   -- 0
   ```

## What to say about it

* The **backup** gives the state at one moment; the **binary log** records every change after it, so
  together they allow recovery to any chosen second ("log-based recovery").
* The ledger design helps: because rows are never updated, replaying the log can never overwrite a
  later correction with an older value, and the reconciliation view proves the result is consistent.
* Prevention is better than cure: `ledger_app` has no `DROP`, `TRUNCATE` or write privileges at all
  (see `sql/06_security.sql`).
