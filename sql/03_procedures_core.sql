-- ============================================================
-- 03 - Helper functions and the write-path stored procedures
--      Every ledger insert goes through one of these procedures.
-- ============================================================
USE stock_ledger_db;

DELIMITER $$

-- Role of an active user ('' if unknown / inactive)
CREATE FUNCTION fn_user_role(p_user_id INT UNSIGNED) RETURNS VARCHAR(30)
READS SQL DATA
BEGIN
  DECLARE v_role VARCHAR(30) DEFAULT '';
  SELECT COALESCE(MAX(r.role_name), '') INTO v_role
    FROM app_user u JOIN `role` r ON r.role_id = u.role_id
   WHERE u.user_id = p_user_id AND u.is_active = 1;
  RETURN v_role;
END$$

-- Which role may post which kind of entry (role-based access control)
CREATE FUNCTION fn_role_can(p_role VARCHAR(30), p_code VARCHAR(20)) RETURNS TINYINT
DETERMINISTIC NO SQL
BEGIN
  RETURN CASE p_role
    WHEN 'Admin'             THEN 1
    WHEN 'Warehouse Manager' THEN IF(p_code IN ('SALE','RETURN_IN','WRITE_OFF','ADJUSTMENT'), 1, 0)
    WHEN 'Purchase Officer'  THEN IF(p_code IN ('PURCHASE','RETURN_OUT'), 1, 0)
    ELSE 0
  END;
END$$

-- ------------------------------------------------------------
-- Record one purchase / sale / return / write-off / adjustment
-- p_quantity is entered as a plain number; the sign is derived from the
-- type (except ADJUSTMENT, where +/- is taken as given).
-- ------------------------------------------------------------
CREATE PROCEDURE sp_record_movement(
  IN p_user_id      INT UNSIGNED,
  IN p_product_id   INT UNSIGNED,
  IN p_warehouse_id INT UNSIGNED,
  IN p_type_code    VARCHAR(20),
  IN p_quantity     INT,
  IN p_unit_cost    DECIMAL(12,2),
  IN p_supplier_id  INT UNSIGNED,
  IN p_reference    VARCHAR(40),
  IN p_remarks      VARCHAR(255)
)
BEGIN
  DECLARE v_role    VARCHAR(30);
  DECLARE v_type_id TINYINT UNSIGNED DEFAULT 0;
  DECLARE v_rule    VARCHAR(10) DEFAULT '';
  DECLARE v_qty     INT;
  DECLARE v_cur     INT DEFAULT 0;
  DECLARE v_cost    DECIMAL(12,2);
  DECLARE v_cnt     INT DEFAULT 0;
  DECLARE v_new_id  BIGINT UNSIGNED;
  DECLARE v_msg     VARCHAR(200);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  -- who is asking, and are they allowed?
  SET v_role = fn_user_role(p_user_id);
  IF v_role = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown or inactive user';
  END IF;

  SELECT COALESCE(MAX(type_id), 0), COALESCE(MAX(sign_rule), '')
    INTO v_type_id, v_rule
    FROM txn_type WHERE type_code = p_type_code;
  IF v_type_id = 0 OR p_type_code IN ('TRANSFER_OUT', 'TRANSFER_IN', 'REVERSAL') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid entry type for this procedure';
  END IF;

  IF fn_role_can(v_role, p_type_code) = 0 THEN
    SET v_msg = CONCAT('Access denied: role "', v_role, '" may not post ', p_type_code, ' entries');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  -- master data must exist and be active
  SELECT COUNT(*), COALESCE(MAX(standard_cost), 0) INTO v_cnt, v_cost
    FROM product WHERE product_id = p_product_id AND is_active = 1;
  IF v_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Product not found or inactive';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM warehouse WHERE warehouse_id = p_warehouse_id AND is_active = 1;
  IF v_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Warehouse not found or inactive';
  END IF;

  IF p_supplier_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_cnt FROM supplier WHERE supplier_id = p_supplier_id AND is_active = 1;
    IF v_cnt = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Supplier not found or inactive';
    END IF;
  END IF;

  -- signed quantity
  IF p_type_code = 'ADJUSTMENT' THEN
    SET v_qty = p_quantity;
  ELSEIF v_rule = 'NEGATIVE' THEN
    SET v_qty = -ABS(p_quantity);
  ELSE
    SET v_qty = ABS(p_quantity);
  END IF;
  IF v_qty = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must not be zero';
  END IF;

  -- transaction: lock the balance row, check stock, append to the ledger
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;

  INSERT IGNORE INTO stock_balance (product_id, warehouse_id, quantity_on_hand)
  VALUES (p_product_id, p_warehouse_id, 0);

  SELECT quantity_on_hand INTO v_cur
    FROM stock_balance
   WHERE product_id = p_product_id AND warehouse_id = p_warehouse_id
     FOR UPDATE;

  IF v_cur + v_qty < 0 THEN
    SET v_msg = CONCAT('Insufficient stock: ', v_cur, ' on hand, cannot remove ', -v_qty);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  INSERT INTO stock_ledger
         (product_id, warehouse_id, type_id, quantity_change, unit_cost,
          user_id, supplier_id, reference_no, remarks)
  VALUES (p_product_id, p_warehouse_id, v_type_id, v_qty, COALESCE(p_unit_cost, v_cost),
          p_user_id,
          IF(p_type_code IN ('PURCHASE', 'RETURN_OUT'), p_supplier_id, NULL),
          p_reference, p_remarks);
  SET v_new_id = LAST_INSERT_ID();

  COMMIT;
  SELECT v_new_id AS ledger_id, v_cur + v_qty AS new_balance;
END$$

-- ------------------------------------------------------------
-- Atomic stock transfer: two ledger rows, both or neither
-- ------------------------------------------------------------
CREATE PROCEDURE sp_transfer_stock(
  IN p_user_id    INT UNSIGNED,
  IN p_product_id INT UNSIGNED,
  IN p_from_wh    INT UNSIGNED,
  IN p_to_wh      INT UNSIGNED,
  IN p_quantity   INT,
  IN p_remarks    VARCHAR(255)
)
BEGIN
  DECLARE v_role   VARCHAR(30);
  DECLARE v_cnt    INT DEFAULT 0;
  DECLARE v_cost   DECIMAL(12,2);
  DECLARE v_lo     INT UNSIGNED;
  DECLARE v_hi     INT UNSIGNED;
  DECLARE v_lo_qty INT DEFAULT 0;
  DECLARE v_hi_qty INT DEFAULT 0;
  DECLARE v_src    INT DEFAULT 0;
  DECLARE v_out    TINYINT UNSIGNED;
  DECLARE v_in     TINYINT UNSIGNED;
  DECLARE v_tid    INT UNSIGNED;
  DECLARE v_now    DATETIME(6);
  DECLARE v_msg    VARCHAR(200);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_role = fn_user_role(p_user_id);
  IF v_role NOT IN ('Admin', 'Warehouse Manager') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Access denied: only Admin or Warehouse Manager may transfer stock';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer quantity must be positive';
  END IF;
  IF p_from_wh = p_to_wh THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source and destination warehouse must differ';
  END IF;

  SELECT COUNT(*), COALESCE(MAX(standard_cost), 0) INTO v_cnt, v_cost
    FROM product WHERE product_id = p_product_id AND is_active = 1;
  IF v_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Product not found or inactive';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM warehouse
   WHERE warehouse_id IN (p_from_wh, p_to_wh) AND is_active = 1;
  IF v_cnt <> 2 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Warehouse not found or inactive';
  END IF;

  SELECT type_id INTO v_out FROM txn_type WHERE type_code = 'TRANSFER_OUT';
  SELECT type_id INTO v_in  FROM txn_type WHERE type_code = 'TRANSFER_IN';
  SET v_lo = LEAST(p_from_wh, p_to_wh);
  SET v_hi = GREATEST(p_from_wh, p_to_wh);

  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;

  INSERT IGNORE INTO stock_balance (product_id, warehouse_id, quantity_on_hand)
  VALUES (p_product_id, v_lo, 0), (p_product_id, v_hi, 0);

  -- lock in warehouse-id order so opposite transfers cannot deadlock
  SELECT quantity_on_hand INTO v_lo_qty FROM stock_balance
   WHERE product_id = p_product_id AND warehouse_id = v_lo FOR UPDATE;
  SELECT quantity_on_hand INTO v_hi_qty FROM stock_balance
   WHERE product_id = p_product_id AND warehouse_id = v_hi FOR UPDATE;

  SET v_src = IF(p_from_wh = v_lo, v_lo_qty, v_hi_qty);
  IF v_src < p_quantity THEN
    SET v_msg = CONCAT('Insufficient stock at source warehouse: ', v_src, ' on hand, cannot transfer ', p_quantity);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  SET v_now = NOW(6);
  INSERT INTO stock_transfer (from_warehouse_id, to_warehouse_id, created_by, created_at)
  VALUES (p_from_wh, p_to_wh, p_user_id, v_now);
  SET v_tid = LAST_INSERT_ID();

  INSERT INTO stock_ledger
         (entry_time, product_id, warehouse_id, type_id, quantity_change, unit_cost,
          user_id, transfer_id, reference_no, remarks)
  VALUES (v_now, p_product_id, p_from_wh, v_out, -p_quantity, v_cost,
          p_user_id, v_tid, CONCAT('TR-', v_tid), p_remarks),
         (v_now, p_product_id, p_to_wh,   v_in,   p_quantity, v_cost,
          p_user_id, v_tid, CONCAT('TR-', v_tid), p_remarks);

  COMMIT;
  SELECT v_tid AS transfer_id;
END$$

-- ------------------------------------------------------------
-- Correct a mistake: add a reversing entry (never edit or delete)
-- ------------------------------------------------------------
CREATE PROCEDURE sp_reverse_entry(
  IN p_user_id   INT UNSIGNED,
  IN p_ledger_id BIGINT UNSIGNED,
  IN p_reason    VARCHAR(255)
)
BEGIN
  DECLARE v_role    VARCHAR(30);
  DECLARE v_o_cnt   INT DEFAULT 0;
  DECLARE v_o_prod  INT UNSIGNED DEFAULT 0;
  DECLARE v_o_wh    INT UNSIGNED DEFAULT 0;
  DECLARE v_o_qty   INT DEFAULT 0;
  DECLARE v_o_type  TINYINT UNSIGNED DEFAULT 0;
  DECLARE v_o_cost  DECIMAL(12,2);
  DECLARE v_o_sup   INT UNSIGNED;
  DECLARE v_o_code  VARCHAR(20) DEFAULT '';
  DECLARE v_rev     TINYINT UNSIGNED;
  DECLARE v_cur     INT DEFAULT 0;
  DECLARE v_cnt     INT DEFAULT 0;
  DECLARE v_new_id  BIGINT UNSIGNED;
  DECLARE v_msg     VARCHAR(200);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_role = fn_user_role(p_user_id);
  IF v_role NOT IN ('Admin', 'Warehouse Manager', 'Purchase Officer') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Access denied: this role may not reverse ledger entries';
  END IF;

  SELECT type_id INTO v_rev FROM txn_type WHERE type_code = 'REVERSAL';

  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;

  -- locking read: two people reversing the same entry are serialized here
  SELECT COUNT(*), COALESCE(MAX(product_id), 0), COALESCE(MAX(warehouse_id), 0),
         COALESCE(MAX(quantity_change), 0), COALESCE(MAX(type_id), 0),
         MAX(unit_cost), MAX(supplier_id)
    INTO v_o_cnt, v_o_prod, v_o_wh, v_o_qty, v_o_type, v_o_cost, v_o_sup
    FROM stock_ledger
   WHERE ledger_id = p_ledger_id
     FOR UPDATE;

  IF v_o_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger entry not found';
  END IF;

  SELECT type_code INTO v_o_code FROM txn_type WHERE type_id = v_o_type;
  IF v_o_code = 'REVERSAL' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reversal entry cannot be reversed';
  END IF;
  IF v_o_code IN ('TRANSFER_OUT', 'TRANSFER_IN') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer legs must be reversed together: use sp_reverse_transfer';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM stock_ledger WHERE reverses_ledger_id = p_ledger_id;
  IF v_cnt > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This entry has already been reversed';
  END IF;

  INSERT IGNORE INTO stock_balance (product_id, warehouse_id, quantity_on_hand)
  VALUES (v_o_prod, v_o_wh, 0);

  SELECT quantity_on_hand INTO v_cur FROM stock_balance
   WHERE product_id = v_o_prod AND warehouse_id = v_o_wh FOR UPDATE;

  IF v_cur - v_o_qty < 0 THEN
    SET v_msg = CONCAT('Cannot reverse: only ', v_cur, ' on hand now, reversal needs to remove ', v_o_qty);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  INSERT INTO stock_ledger
         (product_id, warehouse_id, type_id, quantity_change, unit_cost, user_id,
          supplier_id, reverses_ledger_id, reference_no, remarks)
  VALUES (v_o_prod, v_o_wh, v_rev, -v_o_qty, v_o_cost, p_user_id,
          v_o_sup, p_ledger_id, CONCAT('REV-', p_ledger_id), p_reason);
  SET v_new_id = LAST_INSERT_ID();

  COMMIT;
  SELECT v_new_id AS ledger_id, v_cur - v_o_qty AS new_balance;
END$$

-- ------------------------------------------------------------
-- Reverse a whole transfer (both legs) in one transaction
-- ------------------------------------------------------------
CREATE PROCEDURE sp_reverse_transfer(
  IN p_user_id     INT UNSIGNED,
  IN p_transfer_id INT UNSIGNED,
  IN p_reason      VARCHAR(255)
)
BEGIN
  DECLARE v_role    VARCHAR(30);
  DECLARE v_out_id  BIGINT UNSIGNED DEFAULT 0;
  DECLARE v_in_id   BIGINT UNSIGNED DEFAULT 0;
  DECLARE v_prod    INT UNSIGNED DEFAULT 0;
  DECLARE v_from    INT UNSIGNED DEFAULT 0;
  DECLARE v_to      INT UNSIGNED DEFAULT 0;
  DECLARE v_qty     INT DEFAULT 0;
  DECLARE v_cost    DECIMAL(12,2);
  DECLARE v_lo      INT UNSIGNED;
  DECLARE v_hi      INT UNSIGNED;
  DECLARE v_lo_qty  INT DEFAULT 0;
  DECLARE v_hi_qty  INT DEFAULT 0;
  DECLARE v_dest    INT DEFAULT 0;
  DECLARE v_cnt     INT DEFAULT 0;
  DECLARE v_rev     TINYINT UNSIGNED;
  DECLARE v_now     DATETIME(6);
  DECLARE v_msg     VARCHAR(200);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_role = fn_user_role(p_user_id);
  IF v_role NOT IN ('Admin', 'Warehouse Manager') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Access denied: only Admin or Warehouse Manager may reverse transfers';
  END IF;

  SELECT type_id INTO v_rev FROM txn_type WHERE type_code = 'REVERSAL';

  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;

  -- serialize concurrent reversals of the same transfer
  SELECT COUNT(*) INTO v_cnt FROM stock_transfer WHERE transfer_id = p_transfer_id FOR UPDATE;
  IF v_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer not found';
  END IF;

  SELECT COALESCE(MAX(CASE WHEN t.type_code = 'TRANSFER_OUT' THEN l.ledger_id END), 0),
         COALESCE(MAX(CASE WHEN t.type_code = 'TRANSFER_IN'  THEN l.ledger_id END), 0),
         COALESCE(MAX(l.product_id), 0),
         COALESCE(MAX(CASE WHEN t.type_code = 'TRANSFER_OUT' THEN l.warehouse_id END), 0),
         COALESCE(MAX(CASE WHEN t.type_code = 'TRANSFER_IN'  THEN l.warehouse_id END), 0),
         COALESCE(MAX(CASE WHEN t.type_code = 'TRANSFER_IN'  THEN l.quantity_change END), 0),
         MAX(l.unit_cost)
    INTO v_out_id, v_in_id, v_prod, v_from, v_to, v_qty, v_cost
    FROM stock_ledger l JOIN txn_type t ON t.type_id = l.type_id
   WHERE l.transfer_id = p_transfer_id
     AND t.type_code IN ('TRANSFER_OUT', 'TRANSFER_IN');

  IF v_out_id = 0 OR v_in_id = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer entries not found';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM stock_ledger
   WHERE reverses_ledger_id IN (v_out_id, v_in_id);
  IF v_cnt > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This transfer has already been reversed';
  END IF;

  SET v_lo = LEAST(v_from, v_to);
  SET v_hi = GREATEST(v_from, v_to);
  SELECT quantity_on_hand INTO v_lo_qty FROM stock_balance
   WHERE product_id = v_prod AND warehouse_id = v_lo FOR UPDATE;
  SELECT quantity_on_hand INTO v_hi_qty FROM stock_balance
   WHERE product_id = v_prod AND warehouse_id = v_hi FOR UPDATE;

  SET v_dest = IF(v_to = v_lo, v_lo_qty, v_hi_qty);
  IF v_dest < v_qty THEN
    SET v_msg = CONCAT('Cannot reverse transfer: destination now holds only ', v_dest, ', needs ', v_qty);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  SET v_now = NOW(6);
  INSERT INTO stock_ledger
         (entry_time, product_id, warehouse_id, type_id, quantity_change, unit_cost, user_id,
          transfer_id, reverses_ledger_id, reference_no, remarks)
  VALUES (v_now, v_prod, v_from, v_rev,  v_qty, v_cost, p_user_id,
          p_transfer_id, v_out_id, CONCAT('REV-', v_out_id), p_reason),
         (v_now, v_prod, v_to,   v_rev, -v_qty, v_cost, p_user_id,
          p_transfer_id, v_in_id,  CONCAT('REV-', v_in_id),  p_reason);

  COMMIT;
  SELECT p_transfer_id AS transfer_id, v_out_id AS reversed_out_leg, v_in_id AS reversed_in_leg;
END$$

DELIMITER ;
