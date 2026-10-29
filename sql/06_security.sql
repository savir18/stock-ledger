-- ============================================================
-- 06 - MySQL accounts, roles and privileges (least privilege)
--      Nobody gets INSERT / UPDATE / DELETE on the ledger directly:
--      all writes go through the stored procedures.
--      Passwords below are demo values for a local project only.
-- ============================================================
USE stock_ledger_db;

-- ---- Roles (privilege bundles) ----
CREATE ROLE IF NOT EXISTS 'ledger_admin', 'ledger_warehouse', 'ledger_purchasing', 'ledger_analyst';

GRANT SELECT ON stock_ledger_db.* TO 'ledger_admin';
GRANT EXECUTE ON stock_ledger_db.* TO 'ledger_admin';

GRANT SELECT ON stock_ledger_db.v_current_stock   TO 'ledger_warehouse', 'ledger_purchasing', 'ledger_analyst';
GRANT SELECT ON stock_ledger_db.v_reorder_alerts  TO 'ledger_warehouse', 'ledger_purchasing', 'ledger_analyst';
GRANT SELECT ON stock_ledger_db.v_ledger_history  TO 'ledger_warehouse', 'ledger_purchasing', 'ledger_analyst';
GRANT SELECT ON stock_ledger_db.v_abc_analysis    TO 'ledger_purchasing', 'ledger_analyst';
GRANT SELECT ON stock_ledger_db.v_weekly_sales    TO 'ledger_purchasing', 'ledger_analyst';
GRANT SELECT ON stock_ledger_db.v_movement_summary TO 'ledger_analyst';
GRANT SELECT ON stock_ledger_db.v_reconciliation  TO 'ledger_analyst';

GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_record_movement   TO 'ledger_warehouse', 'ledger_purchasing';
GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_transfer_stock    TO 'ledger_warehouse';
GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_reverse_entry     TO 'ledger_warehouse', 'ledger_purchasing';
GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_reverse_transfer  TO 'ledger_warehouse';
GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_running_balance   TO 'ledger_warehouse', 'ledger_purchasing', 'ledger_analyst';
GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_stock_as_of       TO 'ledger_analyst';
GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_dead_stock        TO 'ledger_purchasing', 'ledger_analyst';
GRANT EXECUTE ON PROCEDURE stock_ledger_db.sp_forecast          TO 'ledger_purchasing', 'ledger_analyst';

-- ---- Accounts used by the demo ----
-- The web application connects as ledger_app (reads + procedures only).
DROP USER IF EXISTS 'ledger_app'@'localhost';
DROP USER IF EXISTS 'ledger_app'@'127.0.0.1';
CREATE USER 'ledger_app'@'localhost'  IDENTIFIED BY 'LedgerApp#2026';
CREATE USER 'ledger_app'@'127.0.0.1'  IDENTIFIED BY 'LedgerApp#2026';
GRANT SELECT, EXECUTE ON stock_ledger_db.* TO 'ledger_app'@'localhost';
GRANT SELECT, EXECUTE ON stock_ledger_db.* TO 'ledger_app'@'127.0.0.1';

-- One login per role, for the access-control demo in the viva.
DROP USER IF EXISTS 'demo_warehouse'@'localhost';
DROP USER IF EXISTS 'demo_analyst'@'localhost';
CREATE USER 'demo_warehouse'@'localhost' IDENTIFIED BY 'Warehouse#2026';
CREATE USER 'demo_analyst'@'localhost'   IDENTIFIED BY 'Analyst#2026';
GRANT 'ledger_warehouse' TO 'demo_warehouse'@'localhost';
GRANT 'ledger_analyst'   TO 'demo_analyst'@'localhost';
SET DEFAULT ROLE 'ledger_warehouse' TO 'demo_warehouse'@'localhost';
SET DEFAULT ROLE 'ledger_analyst'   TO 'demo_analyst'@'localhost';

SELECT 'Security setup complete' AS status;
