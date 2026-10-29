-- ============================================================
-- 05 - Master data and demo ledger data
--      (plain ASCII only, so any Windows console can read it)
-- ============================================================
USE stock_ledger_db;

INSERT INTO `role` (role_name, description) VALUES
  ('Admin',             'Manages users and master data, runs backup and recovery'),
  ('Warehouse Manager', 'Posts sales, returns, write-offs, adjustments and transfers'),
  ('Purchase Officer',  'Posts purchases and supplier returns, watches reorder alerts'),
  ('Analyst',           'Read-only access to stock, history and analytics');

INSERT INTO app_user (role_id, username, full_name, email, password_hash) VALUES
  (1, 'admin',     'Asha Verma (Admin)',          'admin@stockledger.example',     SHA2('demo-admin', 256)),
  (2, 'whmgr1',    'Ravi Kumar (Warehouse)',      'ravi@stockledger.example',      SHA2('demo-whmgr1', 256)),
  (2, 'whmgr2',    'Neha Singh (Warehouse)',      'neha@stockledger.example',      SHA2('demo-whmgr2', 256)),
  (3, 'purchase1', 'Arjun Mehta (Purchasing)',    'arjun@stockledger.example',     SHA2('demo-purchase1', 256)),
  (4, 'analyst1',  'Priya Nair (Analyst)',        'priya@stockledger.example',     SHA2('demo-analyst1', 256));

INSERT INTO txn_type (type_id, type_code, description, sign_rule) VALUES
  (1, 'PURCHASE',     'Stock received from a supplier',          'POSITIVE'),
  (2, 'SALE',         'Stock sold to a customer',                'NEGATIVE'),
  (3, 'TRANSFER_OUT', 'Stock leaving a warehouse (transfer)',    'NEGATIVE'),
  (4, 'TRANSFER_IN',  'Stock arriving at a warehouse (transfer)','POSITIVE'),
  (5, 'RETURN_IN',    'Customer return, stock comes back',       'POSITIVE'),
  (6, 'RETURN_OUT',   'Return to supplier, stock goes out',      'NEGATIVE'),
  (7, 'WRITE_OFF',    'Damaged, expired or lost stock',          'NEGATIVE'),
  (8, 'ADJUSTMENT',   'Stock-count correction, plus or minus',   'EITHER'),
  (9, 'REVERSAL',     'Cancels an earlier ledger entry',         'EITHER');

INSERT INTO category (category_id, category_name, parent_category_id) VALUES
  (1, 'Electronics',          NULL),
  (2, 'Computer Peripherals', 1),
  (3, 'Mobile Accessories',   1),
  (4, 'Office Supplies',      NULL),
  (5, 'Stationery',           4),
  (6, 'Packaging',            NULL);

INSERT INTO warehouse (warehouse_code, warehouse_name, city) VALUES
  ('WH-DEL', 'Delhi Central Warehouse', 'Delhi'),
  ('WH-MUM', 'Mumbai Port Warehouse',   'Mumbai'),
  ('WH-BLR', 'Bengaluru Hub',           'Bengaluru');

INSERT INTO supplier (supplier_name, email, phone, address) VALUES
  ('TechSource Distributors', 'sales@techsource.example',  '+91-11-40001001', 'Nehru Place, Delhi'),
  ('Gadget Wholesale Co',     'orders@gadgetco.example',   '+91-22-40002002', 'Andheri East, Mumbai'),
  ('PaperPlus Traders',       'hello@paperplus.example',   '+91-80-40003003', 'Peenya, Bengaluru'),
  ('OfficeMart Supplies',     'b2b@officemart.example',    '+91-11-40004004', 'Okhla, Delhi'),
  ('PackRight Industries',    'sales@packright.example',   '+91-22-40005005', 'Bhiwandi, Thane'),
  ('Digital Imports Ltd',     'trade@digitalimports.example','+91-80-40006006','Electronic City, Bengaluru');

INSERT INTO product (product_id, sku, product_name, category_id, unit_of_measure, standard_cost, reorder_level) VALUES
  (1,  'EL-1001', 'Wireless Mouse',            2,  'pcs',   450.00,  40),
  (2,  'EL-1002', 'Mechanical Keyboard',       2,  'pcs',  1800.00,  25),
  (3,  'EL-1003', 'USB-C Hub 7-in-1',          2,  'pcs',  1350.00,  20),
  (4,  'EL-1004', '27-inch Monitor',           2,  'pcs', 11500.00,   8),
  (5,  'EL-1005', 'Webcam 1080p',              2,  'pcs',  2100.00,  15),
  (6,  'EL-1006', 'Laptop Stand',              2,  'pcs',   650.00,  30),
  (7,  'MA-2001', 'USB-C Cable 1m',            3,  'pcs',   150.00, 100),
  (8,  'MA-2002', 'Phone Charger 20W',         3,  'pcs',   480.00,  60),
  (9,  'MA-2003', 'Power Bank 10000mAh',       3,  'pcs',   900.00,  30),
  (10, 'MA-2004', 'Bluetooth Earbuds',         3,  'pcs',  1250.00,  35),
  (11, 'MA-2005', 'Phone Case Universal',      3,  'pcs',   120.00,  80),
  (12, 'MA-2006', 'Screen Guard Pack',         3,  'pack',   60.00, 120),
  (13, 'OF-3001', 'A4 Paper Ream',             4,  'ream',  260.00, 150),
  (14, 'OF-3002', 'Printer Toner Black',       4,  'pcs',  3200.00,  10),
  (15, 'OF-3003', 'Desk Organizer',            4,  'pcs',   380.00,  25),
  (16, 'OF-3004', 'Whiteboard 2x3 ft',         4,  'pcs',  1450.00,   6),
  (17, 'ST-4001', 'Ball Pen Box (50)',         5,  'box',   220.00,  60),
  (18, 'ST-4002', 'Spiral Notebook A5',        5,  'pcs',    55.00, 200),
  (19, 'ST-4003', 'Sticky Notes Pack',         5,  'pack',   90.00, 100),
  (20, 'ST-4004', 'Highlighter Set',           5,  'set',   140.00,  70),
  (21, 'PK-5001', 'Bubble Wrap Roll',          6,  'roll',  520.00,  20),
  (22, 'PK-5002', 'Carton Box Medium (10)',    6,  'pack',  310.00,  50),
  (23, 'PK-5003', 'Packing Tape 6-pack',       6,  'pack',  280.00,  40),
  (24, 'EL-1007', 'Legacy VGA Cable',          2,  'pcs',    90.00,  30);

INSERT INTO product_supplier (product_id, supplier_id, supplier_sku, lead_time_days) VALUES
  (1,1,'TS-M01',5),(1,6,'DI-M77',9),(2,1,'TS-K02',6),(3,1,'TS-H03',6),(3,6,'DI-H11',10),
  (4,6,'DI-MN4',14),(5,1,'TS-W05',7),(6,1,'TS-L06',5),(24,6,'DI-VGA',12),
  (7,2,'GW-C07',4),(8,2,'GW-P08',4),(9,2,'GW-B09',6),(9,6,'DI-B90',9),(10,2,'GW-E10',6),
  (11,2,'GW-X11',3),(12,2,'GW-S12',3),
  (13,3,'PP-A413',3),(13,4,'OM-A4',4),(14,4,'OM-T14',8),(15,4,'OM-D15',5),(16,4,'OM-W16',7),
  (17,3,'PP-B17',3),(18,3,'PP-N18',3),(19,3,'PP-S19',3),(20,3,'PP-H20',3),
  (21,5,'PR-B21',6),(22,5,'PR-C22',6),(23,5,'PR-T23',5);

-- ------------------------------------------------------------
-- Demo data generator. Writes straight into the ledger in time
-- order (the triggers still validate every row and keep the summary
-- tables in sync).  Products 22-24 are "slow movers": they are stocked
-- once and never sold, so the dead-stock report has something to find.
--   p_rows = number of random movements,  p_days = history length
-- ------------------------------------------------------------
DELIMITER $$

CREATE PROCEDURE sp_generate_demo_data(IN p_rows INT, IN p_days INT)
BEGIN
  DECLARE i        INT DEFAULT 0;
  DECLARE j        INT DEFAULT 0;
  DECLARE v_start  DATETIME(6);
  DECLARE v_ts     DATETIME(6);
  DECLARE v_step   DOUBLE;
  DECLARE v_pid    INT UNSIGNED;
  DECLARE v_wh     INT UNSIGNED;
  DECLARE v_wh2    INT UNSIGNED;
  DECLARE v_r      DOUBLE;
  DECLARE v_qty    INT;
  DECLARE v_bal    INT;
  DECLARE v_cost   DECIMAL(12,2);
  DECLARE v_sup    INT UNSIGNED;
  DECLARE v_uid    INT UNSIGNED;
  DECLARE v_tid    INT UNSIGNED;
  DECLARE v_t_pur  TINYINT UNSIGNED;
  DECLARE v_t_sale TINYINT UNSIGNED;
  DECLARE v_t_rin  TINYINT UNSIGNED;
  DECLARE v_t_wo   TINYINT UNSIGNED;
  DECLARE v_t_adj  TINYINT UNSIGNED;
  DECLARE v_t_tout TINYINT UNSIGNED;
  DECLARE v_t_tin  TINYINT UNSIGNED;
  DECLARE v_n      INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SELECT COUNT(*) INTO v_n FROM stock_ledger;
  IF v_n > 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Ledger already has data. Re-run 00_database.sql to start from scratch.';
  END IF;

  SELECT type_id INTO v_t_pur  FROM txn_type WHERE type_code = 'PURCHASE';
  SELECT type_id INTO v_t_sale FROM txn_type WHERE type_code = 'SALE';
  SELECT type_id INTO v_t_rin  FROM txn_type WHERE type_code = 'RETURN_IN';
  SELECT type_id INTO v_t_wo   FROM txn_type WHERE type_code = 'WRITE_OFF';
  SELECT type_id INTO v_t_adj  FROM txn_type WHERE type_code = 'ADJUSTMENT';
  SELECT type_id INTO v_t_tout FROM txn_type WHERE type_code = 'TRANSFER_OUT';
  SELECT type_id INTO v_t_tin  FROM txn_type WHERE type_code = 'TRANSFER_IN';

  SET v_start = NOW(6) - INTERVAL p_days DAY;
  SET v_step  = (p_days * 86400) / (p_rows + 50);

  START TRANSACTION;

  -- opening stock: every product, every warehouse
  SET j = 0;
  WHILE j < 24 DO
    SET j = j + 1;
    SELECT standard_cost INTO v_cost FROM product WHERE product_id = j;
    SELECT MIN(supplier_id) INTO v_sup FROM product_supplier WHERE product_id = j;
    INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                              unit_cost, user_id, supplier_id, reference_no, remarks)
    VALUES (v_start + INTERVAL j SECOND, j, 1, v_t_pur, IF(j >= 22, 120, 200), v_cost, 4, v_sup,
            CONCAT('PO-OPEN-', j, 'A'), 'Opening stock'),
           (v_start + INTERVAL (j + 30) SECOND, j, 2, v_t_pur, IF(j >= 22, 60, 120), v_cost, 4, v_sup,
            CONCAT('PO-OPEN-', j, 'B'), 'Opening stock'),
           (v_start + INTERVAL (j + 60) SECOND, j, 3, v_t_pur, IF(j >= 22, 60, 120), v_cost, 4, v_sup,
            CONCAT('PO-OPEN-', j, 'C'), 'Opening stock');
  END WHILE;
  COMMIT;
  START TRANSACTION;

  WHILE i < p_rows DO
    SET i    = i + 1;
    SET v_ts = v_start + INTERVAL 1 HOUR + INTERVAL FLOOR(i * v_step) SECOND;

    -- products 1-21 are active; low ids are the popular ones
    SET v_pid = 1 + FLOOR(21 * POW(RAND(), 1.8));
    SET v_wh  = 1 + FLOOR(RAND() * 3);
    SET v_r   = RAND();

    SELECT COALESCE(MAX(quantity_on_hand), 0) INTO v_bal FROM stock_balance
     WHERE product_id = v_pid AND warehouse_id = v_wh;
    SELECT standard_cost INTO v_cost FROM product WHERE product_id = v_pid;
    SELECT MIN(supplier_id) INTO v_sup FROM product_supplier WHERE product_id = v_pid;
    SET v_uid = IF(RAND() < 0.5, 2, 3);

    IF v_r < 0.60 THEN
      -- sale (becomes a restock purchase if the shelf is nearly empty)
      SET v_qty = 1 + FLOOR(RAND() * 8);
      IF v_bal < v_qty + 5 THEN
        INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                                  unit_cost, user_id, supplier_id, reference_no, remarks)
        VALUES (v_ts, v_pid, v_wh, v_t_pur, 60 + FLOOR(RAND() * 120),
                ROUND(v_cost * (0.92 + RAND() * 0.16), 2), 4, v_sup,
                CONCAT('PO-', LPAD(i, 6, '0')), 'Restock');
      ELSE
        INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                                  unit_cost, user_id, reference_no)
        VALUES (v_ts, v_pid, v_wh, v_t_sale, -v_qty, v_cost, v_uid,
                CONCAT('SO-', LPAD(i, 6, '0')));
      END IF;

    ELSEIF v_r < 0.78 THEN
      -- purchase
      INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                                unit_cost, user_id, supplier_id, reference_no)
      VALUES (v_ts, v_pid, v_wh, v_t_pur, 30 + FLOOR(RAND() * 150),
              ROUND(v_cost * (0.92 + RAND() * 0.16), 2), 4, v_sup,
              CONCAT('PO-', LPAD(i, 6, '0')));

    ELSEIF v_r < 0.82 THEN
      -- customer return
      INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                                unit_cost, user_id, reference_no, remarks)
      VALUES (v_ts, v_pid, v_wh, v_t_rin, 1 + FLOOR(RAND() * 3), v_cost, v_uid,
              CONCAT('RT-', LPAD(i, 6, '0')), 'Customer return');

    ELSEIF v_r < 0.85 THEN
      -- write-off (only if there is stock)
      IF v_bal >= 5 THEN
        INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                                  unit_cost, user_id, reference_no, remarks)
        VALUES (v_ts, v_pid, v_wh, v_t_wo, -(1 + FLOOR(RAND() * 2)), v_cost, v_uid,
                CONCAT('WO-', LPAD(i, 6, '0')), 'Damaged in handling');
      END IF;

    ELSEIF v_r < 0.88 THEN
      -- stock-count adjustment, plus or minus
      IF v_bal >= 8 AND RAND() < 0.5 THEN
        SET v_qty = -(1 + FLOOR(RAND() * 3));
      ELSE
        SET v_qty = 1 + FLOOR(RAND() * 3);
      END IF;
      INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                                unit_cost, user_id, reference_no, remarks)
      VALUES (v_ts, v_pid, v_wh, v_t_adj, v_qty, v_cost, v_uid,
              CONCAT('ADJ-', LPAD(i, 6, '0')), 'Cycle count correction');

    ELSE
      -- transfer to another warehouse (two linked ledger rows)
      SET v_wh2 = 1 + MOD(v_wh + FLOOR(RAND() * 2), 3);
      IF v_wh2 = v_wh THEN
        SET v_wh2 = 1 + MOD(v_wh, 3);
      END IF;
      SET v_qty = 5 + FLOOR(RAND() * 20);
      IF v_bal >= v_qty + 5 THEN
        INSERT INTO stock_transfer (from_warehouse_id, to_warehouse_id, created_by, created_at)
        VALUES (v_wh, v_wh2, v_uid, v_ts);
        SET v_tid = LAST_INSERT_ID();
        INSERT INTO stock_ledger (entry_time, product_id, warehouse_id, type_id, quantity_change,
                                  unit_cost, user_id, transfer_id, reference_no)
        VALUES (v_ts, v_pid, v_wh,  v_t_tout, -v_qty, v_cost, v_uid, v_tid, CONCAT('TR-', v_tid)),
               (v_ts, v_pid, v_wh2, v_t_tin,   v_qty, v_cost, v_uid, v_tid, CONCAT('TR-', v_tid));
      END IF;
    END IF;

    IF MOD(i, 500) = 0 THEN
      COMMIT;
      START TRANSACTION;
    END IF;
  END WHILE;

  COMMIT;
  SELECT COUNT(*) AS ledger_rows, MIN(entry_time) AS first_entry, MAX(entry_time) AS last_entry
    FROM stock_ledger;
END$$

DELIMITER ;

-- Generate the demo history (about 20,000 movements over one year).
-- For the performance demo, you can start fresh and use a bigger number,
-- for example CALL sp_generate_demo_data(200000, 365);
CALL sp_generate_demo_data(20000, 365);

-- A few corrections, the "accounting way": reversing entries, never edits
SELECT MAX(l.ledger_id) INTO @last_sale
  FROM stock_ledger l JOIN txn_type t ON t.type_id = l.type_id
 WHERE t.type_code = 'SALE';
CALL sp_reverse_entry(1, @last_sale, 'Demo: sale entered by mistake');

-- Copies of the ledger for the EXPLAIN / timing comparison
CALL sp_build_performance_lab();

-- Make a few products run low, so the restock alerts have something to show.
-- (Done the proper way: WRITE_OFF entries through the stored procedure.)
DELIMITER $$
CREATE PROCEDURE sp_demo_make_low(IN p_product INT UNSIGNED, IN p_keep INT)
BEGIN
  DECLARE v_wh INT UNSIGNED;
  DECLARE v_remove INT;
  DECLARE v_first TINYINT DEFAULT 1;
  DECLARE v_done TINYINT DEFAULT 0;
  DECLARE cur CURSOR FOR SELECT warehouse_id, remove_qty FROM tmp_low ORDER BY warehouse_id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

  DROP TEMPORARY TABLE IF EXISTS tmp_low;
  CREATE TEMPORARY TABLE tmp_low AS
    SELECT warehouse_id,
           quantity_on_hand - IF(warehouse_id = (SELECT MIN(warehouse_id) FROM stock_balance WHERE product_id = p_product), p_keep, 0) AS remove_qty
      FROM stock_balance WHERE product_id = p_product;

  OPEN cur;
  lp: LOOP
    FETCH cur INTO v_wh, v_remove;
    IF v_done = 1 THEN LEAVE lp; END IF;
    IF v_remove > 0 THEN
      CALL sp_record_movement(1, p_product, v_wh, 'WRITE_OFF', v_remove, NULL, NULL, 'DEMO-LOW', 'Demo: damaged batch written off');
    END IF;
  END LOOP;
  CLOSE cur;
  DROP TEMPORARY TABLE IF EXISTS tmp_low;
END$$
DELIMITER ;

CALL sp_demo_make_low(5, 6);    -- Webcam 1080p        (reorder level 15)
CALL sp_demo_make_low(8, 22);   -- Phone Charger 20W   (reorder level 60)
CALL sp_demo_make_low(6, 11);   -- Laptop Stand        (reorder level 30)
DROP PROCEDURE sp_demo_make_low;

SELECT 'Seed complete' AS status,
       (SELECT COUNT(*) FROM stock_ledger)  AS ledger_rows,
       (SELECT COUNT(*) FROM stock_balance) AS balance_rows;
