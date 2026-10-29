-- ============================================================
-- 04 - Read-side: views, window-function analytics, integrity
--      tools, and the performance lab
-- ============================================================
USE stock_ledger_db;

-- ---------- Views ----------
CREATE OR REPLACE VIEW v_current_stock AS
SELECT b.product_id, p.sku, p.product_name, c.category_name,
       b.warehouse_id, w.warehouse_code, w.warehouse_name,
       b.quantity_on_hand, p.standard_cost,
       b.quantity_on_hand * p.standard_cost AS stock_value,
       p.reorder_level,
       (b.quantity_on_hand <= p.reorder_level) AS below_reorder,
       b.updated_at
  FROM stock_balance b
  JOIN product   p ON p.product_id   = b.product_id
  JOIN category  c ON c.category_id  = p.category_id
  JOIN warehouse w ON w.warehouse_id = b.warehouse_id;

CREATE OR REPLACE VIEW v_reorder_alerts AS
SELECT p.product_id, p.sku, p.product_name, p.reorder_level,
       COALESCE(SUM(b.quantity_on_hand), 0) AS total_qty,
       (SELECT s.supplier_name
          FROM product_supplier ps JOIN supplier s ON s.supplier_id = ps.supplier_id
         WHERE ps.product_id = p.product_id
         ORDER BY ps.lead_time_days, s.supplier_id LIMIT 1) AS suggested_supplier,
       (SELECT MIN(ps.lead_time_days)
          FROM product_supplier ps WHERE ps.product_id = p.product_id) AS lead_time_days
  FROM product p
  LEFT JOIN stock_balance b ON b.product_id = p.product_id
 WHERE p.is_active = 1
 GROUP BY p.product_id
HAVING COALESCE(SUM(b.quantity_on_hand), 0) <= p.reorder_level;

CREATE OR REPLACE VIEW v_ledger_history AS
SELECT l.ledger_id, l.entry_time, l.type_id, t.type_code,
       l.product_id, p.sku, p.product_name,
       l.warehouse_id, w.warehouse_code,
       l.quantity_change, l.unit_cost,
       ABS(l.quantity_change) * COALESCE(l.unit_cost, 0) AS entry_value,
       u.username, s.supplier_name,
       l.transfer_id, l.reverses_ledger_id, l.reference_no, l.remarks,
       EXISTS (SELECT 1 FROM stock_ledger r WHERE r.reverses_ledger_id = l.ledger_id) AS is_reversed
  FROM stock_ledger l
  JOIN txn_type  t ON t.type_id      = l.type_id
  JOIN product   p ON p.product_id   = l.product_id
  JOIN warehouse w ON w.warehouse_id = l.warehouse_id
  JOIN app_user  u ON u.user_id      = l.user_id
  LEFT JOIN supplier s ON s.supplier_id = l.supplier_id;

-- ABC analysis: rank products by value sold (last 365 days) and classify
-- A = the products that make up the first 80% of value, B = next 15%, C = rest
CREATE OR REPLACE VIEW v_abc_analysis AS
WITH sales AS (
  SELECT p.product_id, p.sku, p.product_name,
         SUM(-l.quantity_change)                                  AS units_sold,
         SUM(-l.quantity_change * COALESCE(l.unit_cost, p.standard_cost)) AS value_sold
    FROM stock_ledger l
    JOIN txn_type t ON t.type_id = l.type_id
    JOIN product  p ON p.product_id = l.product_id
   WHERE t.type_code = 'SALE'
     AND l.entry_time >= NOW() - INTERVAL 365 DAY
   GROUP BY p.product_id, p.sku, p.product_name
),
ranked AS (
  SELECT sales.*,
         SUM(value_sold) OVER (ORDER BY value_sold DESC, product_id) AS cum_value,
         SUM(value_sold) OVER ()                                     AS total_value
    FROM sales
)
SELECT product_id, sku, product_name, units_sold, value_sold,
       ROUND(100 * value_sold / total_value, 2)              AS share_pct,
       ROUND(100 * cum_value / total_value, 2)               AS cumulative_pct,
       CASE WHEN (cum_value - value_sold) / total_value < 0.80 THEN 'A'
            WHEN (cum_value - value_sold) / total_value < 0.95 THEN 'B'
            ELSE 'C' END                                     AS abc_class
  FROM ranked;

CREATE OR REPLACE VIEW v_weekly_sales AS
SELECT DATE_SUB(DATE(l.entry_time), INTERVAL WEEKDAY(l.entry_time) DAY) AS week_start,
       SUM(-l.quantity_change)                                          AS units_sold,
       SUM(-l.quantity_change * COALESCE(l.unit_cost, 0))               AS value_sold
  FROM stock_ledger l JOIN txn_type t ON t.type_id = l.type_id
 WHERE t.type_code = 'SALE'
 GROUP BY DATE_SUB(DATE(l.entry_time), INTERVAL WEEKDAY(l.entry_time) DAY);

CREATE OR REPLACE VIEW v_movement_summary AS
SELECT t.type_code, COUNT(*) AS entries,
       SUM(l.quantity_change)                                AS net_units,
       SUM(ABS(l.quantity_change))                           AS gross_units
  FROM stock_ledger l JOIN txn_type t ON t.type_id = l.type_id
 GROUP BY t.type_id, t.type_code;

-- Does the summary table agree with the ledger?
CREATE OR REPLACE VIEW v_reconciliation AS
SELECT b.product_id, p.sku, b.warehouse_id, w.warehouse_code,
       b.quantity_on_hand                       AS balance_table,
       COALESCE(l.ledger_sum, 0)                AS ledger_sum,
       b.quantity_on_hand - COALESCE(l.ledger_sum, 0) AS difference
  FROM stock_balance b
  JOIN product   p ON p.product_id   = b.product_id
  JOIN warehouse w ON w.warehouse_id = b.warehouse_id
  LEFT JOIN (SELECT product_id, warehouse_id, SUM(quantity_change) AS ledger_sum
               FROM stock_ledger GROUP BY product_id, warehouse_id) l
         ON l.product_id = b.product_id AND l.warehouse_id = b.warehouse_id;

DELIMITER $$

-- ---------- Window-function analytics ----------

-- Running balance of one product (optionally one warehouse)
CREATE PROCEDURE sp_running_balance(IN p_product_id INT UNSIGNED, IN p_warehouse_id INT UNSIGNED)
BEGIN
  IF p_warehouse_id IS NULL THEN
    SELECT l.ledger_id, l.entry_time, t.type_code, w.warehouse_code, l.quantity_change,
           SUM(l.quantity_change) OVER (ORDER BY l.entry_time, l.ledger_id) AS running_balance
      FROM stock_ledger l
      JOIN txn_type  t ON t.type_id      = l.type_id
      JOIN warehouse w ON w.warehouse_id = l.warehouse_id
     WHERE l.product_id = p_product_id
     ORDER BY l.entry_time, l.ledger_id;
  ELSE
    SELECT l.ledger_id, l.entry_time, t.type_code, w.warehouse_code, l.quantity_change,
           SUM(l.quantity_change) OVER (ORDER BY l.entry_time, l.ledger_id) AS running_balance
      FROM stock_ledger l
      JOIN txn_type  t ON t.type_id      = l.type_id
      JOIN warehouse w ON w.warehouse_id = l.warehouse_id
     WHERE l.product_id = p_product_id AND l.warehouse_id = p_warehouse_id
     ORDER BY l.entry_time, l.ledger_id;
  END IF;
END$$

-- Point-in-time stock: what did we hold at a given moment?
CREATE PROCEDURE sp_stock_as_of(IN p_as_of DATETIME(6))
BEGIN
  SELECT p.sku, p.product_name, w.warehouse_code,
         SUM(l.quantity_change)                  AS quantity,
         SUM(l.quantity_change) * p.standard_cost AS value_at_cost
    FROM stock_ledger l
    JOIN product   p ON p.product_id   = l.product_id
    JOIN warehouse w ON w.warehouse_id = l.warehouse_id
   WHERE l.entry_time <= p_as_of
   GROUP BY l.product_id, l.warehouse_id, p.sku, p.product_name, w.warehouse_code, p.standard_cost
  HAVING SUM(l.quantity_change) <> 0
   ORDER BY p.sku, w.warehouse_code;
END$$

-- Dead stock: stock on hand but no sale for N days
CREATE PROCEDURE sp_dead_stock(IN p_days INT)
BEGIN
  SELECT p.sku, p.product_name, sb.qty AS quantity_on_hand,
         ls.last_sale,
         DATEDIFF(NOW(), ls.last_sale)   AS days_since_last_sale,
         sb.qty * p.standard_cost        AS capital_tied_up
    FROM product p
    JOIN (SELECT product_id, SUM(quantity_on_hand) AS qty
            FROM stock_balance GROUP BY product_id HAVING SUM(quantity_on_hand) > 0) sb
      ON sb.product_id = p.product_id
    LEFT JOIN (SELECT l.product_id, MAX(l.entry_time) AS last_sale
                 FROM stock_ledger l JOIN txn_type t ON t.type_id = l.type_id
                WHERE t.type_code = 'SALE'
                GROUP BY l.product_id) ls
      ON ls.product_id = p.product_id
   WHERE ls.last_sale IS NULL OR ls.last_sale < NOW() - INTERVAL p_days DAY
   ORDER BY capital_tied_up DESC;
END$$

-- Moving-average + linear-trend forecast of weekly sales (pure SQL, no ML)
-- Result set 1: last 12 full weeks with a 4-week moving average
-- Result set 2: next-week forecast, current stock and weeks of cover
CREATE PROCEDURE sp_forecast(IN p_product_id INT UNSIGNED)
BEGIN
  WITH RECURSIVE wk (n, week_start) AS (
    SELECT 1, DATE_SUB(DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY), INTERVAL 12 WEEK)
    UNION ALL
    SELECT n + 1, DATE_ADD(week_start, INTERVAL 1 WEEK) FROM wk WHERE n < 12
  ),
  s AS (
    SELECT DATE_SUB(DATE(l.entry_time), INTERVAL WEEKDAY(l.entry_time) DAY) AS week_start,
           SUM(-l.quantity_change) AS qty
      FROM stock_ledger l JOIN txn_type t ON t.type_id = l.type_id
     WHERE l.product_id = p_product_id
       AND t.type_code = 'SALE'
       AND l.entry_time >= DATE_SUB(DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY), INTERVAL 12 WEEK)
     GROUP BY DATE_SUB(DATE(l.entry_time), INTERVAL WEEKDAY(l.entry_time) DAY)
  )
  SELECT wk.n AS week_no, wk.week_start,
         COALESCE(s.qty, 0) AS units_sold,
         ROUND(AVG(COALESCE(s.qty, 0)) OVER (ORDER BY wk.n ROWS BETWEEN 3 PRECEDING AND CURRENT ROW), 1) AS moving_avg_4w
    FROM wk LEFT JOIN s ON s.week_start = wk.week_start
   ORDER BY wk.n;

  WITH RECURSIVE wk (n, week_start) AS (
    SELECT 1, DATE_SUB(DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY), INTERVAL 12 WEEK)
    UNION ALL
    SELECT n + 1, DATE_ADD(week_start, INTERVAL 1 WEEK) FROM wk WHERE n < 12
  ),
  s AS (
    SELECT DATE_SUB(DATE(l.entry_time), INTERVAL WEEKDAY(l.entry_time) DAY) AS week_start,
           SUM(-l.quantity_change) AS qty
      FROM stock_ledger l JOIN txn_type t ON t.type_id = l.type_id
     WHERE l.product_id = p_product_id
       AND t.type_code = 'SALE'
       AND l.entry_time >= DATE_SUB(DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY), INTERVAL 12 WEEK)
     GROUP BY DATE_SUB(DATE(l.entry_time), INTERVAL WEEKDAY(l.entry_time) DAY)
  ),
  h  AS (SELECT wk.n AS x, COALESCE(s.qty, 0) AS y FROM wk LEFT JOIN s ON s.week_start = wk.week_start),
  a  AS (SELECT COUNT(*) AS cnt, SUM(x) AS sx, SUM(y) AS sy, SUM(x * y) AS sxy, SUM(x * x) AS sxx FROM h),
  m  AS (SELECT AVG(y) AS ma4 FROM h WHERE x > 8),
  st AS (SELECT COALESCE(SUM(quantity_on_hand), 0) AS stock FROM stock_balance WHERE product_id = p_product_id)
  SELECT ROUND(m.ma4, 1) AS ma4_forecast,
         ROUND(GREATEST(0,
               (a.sy - ((a.cnt * a.sxy - a.sx * a.sy) / (a.cnt * a.sxx - a.sx * a.sx)) * a.sx) / a.cnt
               + ((a.cnt * a.sxy - a.sx * a.sy) / (a.cnt * a.sxx - a.sx * a.sx)) * 13), 1) AS trend_forecast,
         ROUND(a.sy / a.cnt, 1) AS avg_weekly_12w,
         st.stock AS current_stock,
         ROUND(st.stock / NULLIF(m.ma4, 0), 1) AS weeks_of_cover
    FROM a, m, st;
END$$

-- ---------- Integrity tools ----------

-- Rebuild both summary tables from the ledger (the ledger is the truth)
CREATE PROCEDURE sp_rebuild_summaries()
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  DELETE FROM daily_stock_summary WHERE product_id >= 0;
  DELETE FROM stock_balance       WHERE product_id >= 0;

  INSERT INTO stock_balance (product_id, warehouse_id, quantity_on_hand, last_ledger_id)
  SELECT product_id, warehouse_id, SUM(quantity_change), MAX(ledger_id)
    FROM stock_ledger
   GROUP BY product_id, warehouse_id;

  INSERT INTO daily_stock_summary (summary_date, product_id, warehouse_id, qty_in, qty_out, closing_qty)
  SELECT d.summary_date, d.product_id, d.warehouse_id, d.qty_in, d.qty_out,
         SUM(d.net) OVER (PARTITION BY d.product_id, d.warehouse_id ORDER BY d.summary_date)
    FROM (SELECT DATE(entry_time) AS summary_date, product_id, warehouse_id,
                 SUM(GREATEST(quantity_change, 0))  AS qty_in,
                 SUM(GREATEST(-quantity_change, 0)) AS qty_out,
                 SUM(quantity_change)               AS net
            FROM stock_ledger
           GROUP BY DATE(entry_time), product_id, warehouse_id) d;

  COMMIT;
  SELECT (SELECT COUNT(*) FROM stock_balance)       AS balance_rows,
         (SELECT COUNT(*) FROM daily_stock_summary) AS daily_rows;
END$$

-- Demo only: damage one summary row to show that reconciliation catches it
CREATE PROCEDURE sp_demo_corrupt_balance()
BEGIN
  UPDATE stock_balance
     SET quantity_on_hand = quantity_on_hand + 7
   WHERE quantity_on_hand > 0
   ORDER BY product_id, warehouse_id
   LIMIT 1;
  SELECT ROW_COUNT() AS rows_changed;
END$$

-- Demo only: try to tamper with the ledger. The triggers must refuse,
-- even though this procedure runs with its owner's (admin) rights.
CREATE PROCEDURE sp_demo_tamper(IN p_action VARCHAR(10))
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  SELECT MIN(ledger_id) INTO v_id FROM stock_ledger;

  IF p_action = 'UPDATE' THEN
    UPDATE stock_ledger SET quantity_change = quantity_change + 1000 WHERE ledger_id = v_id;
  ELSEIF p_action = 'DELETE' THEN
    DELETE FROM stock_ledger WHERE ledger_id = v_id;
  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Use UPDATE or DELETE';
  END IF;
  SELECT 'The change went through - the ledger is NOT protected!' AS result;
END$$

-- ---------- Performance lab ----------
-- Copies the ledger into two ordinary tables so the same query can be
-- compared: (1) no index, no partition  (2) index only  (3) index + partition
CREATE PROCEDURE sp_build_performance_lab()
BEGIN
  DROP TABLE IF EXISTS ledger_lab_plain;
  DROP TABLE IF EXISTS ledger_lab_indexed;

  CREATE TABLE ledger_lab_plain (
    ledger_id           BIGINT UNSIGNED  NOT NULL,
    entry_time          DATETIME(6)      NOT NULL,
    product_id          INT UNSIGNED     NOT NULL,
    warehouse_id        INT UNSIGNED     NOT NULL,
    type_id             TINYINT UNSIGNED NOT NULL,
    quantity_change     INT              NOT NULL,
    unit_cost           DECIMAL(12,2)    NULL,
    user_id             INT UNSIGNED     NOT NULL,
    supplier_id         INT UNSIGNED     NULL,
    transfer_id         INT UNSIGNED     NULL,
    reverses_ledger_id  BIGINT UNSIGNED  NULL,
    reference_no        VARCHAR(40)      NULL,
    remarks             VARCHAR(255)     NULL,
    PRIMARY KEY (ledger_id)
  ) ENGINE=InnoDB;

  CREATE TABLE ledger_lab_indexed LIKE ledger_lab_plain;
  ALTER TABLE ledger_lab_indexed
    ADD KEY idx_lab_prod_wh_time (product_id, warehouse_id, entry_time),
    ADD KEY idx_lab_type_time    (type_id, entry_time),
    ADD KEY idx_lab_time         (entry_time);

  INSERT INTO ledger_lab_plain
  SELECT ledger_id, entry_time, product_id, warehouse_id, type_id, quantity_change, unit_cost,
         user_id, supplier_id, transfer_id, reverses_ledger_id, reference_no, remarks
    FROM stock_ledger;

  INSERT INTO ledger_lab_indexed
  SELECT * FROM ledger_lab_plain;

  ANALYZE TABLE ledger_lab_plain, ledger_lab_indexed, stock_ledger;
END$$

DELIMITER ;
