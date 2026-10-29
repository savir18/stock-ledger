-- ============================================================
-- Immutable Stock Ledger System  |  BCSE302P Database Systems Lab
-- 00 - (Re)create the database.  WARNING: drops the old copy.
-- ============================================================
DROP DATABASE IF EXISTS stock_ledger_db;
CREATE DATABASE stock_ledger_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE stock_ledger_db;
-- ============================================================
-- 01 - Tables, keys, constraints, partitioning, indexes
-- ============================================================
USE stock_ledger_db;

-- ---------- Master data ----------
CREATE TABLE `role` (
  role_id      TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  role_name    VARCHAR(30)      NOT NULL,
  description  VARCHAR(200)     NULL,
  PRIMARY KEY (role_id),
  UNIQUE KEY uk_role_name (role_name)
) ENGINE=InnoDB;

CREATE TABLE app_user (
  user_id        INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  role_id        TINYINT UNSIGNED NOT NULL,
  username       VARCHAR(40)      NOT NULL,
  full_name      VARCHAR(80)      NOT NULL,
  email          VARCHAR(100)     NOT NULL,
  password_hash  CHAR(64)         NOT NULL,
  is_active      TINYINT(1)       NOT NULL DEFAULT 1,
  created_at     DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  UNIQUE KEY uk_user_username (username),
  UNIQUE KEY uk_user_email (email),
  CONSTRAINT fk_user_role FOREIGN KEY (role_id) REFERENCES `role` (role_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE category (
  category_id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  category_name       VARCHAR(60)  NOT NULL,
  parent_category_id  INT UNSIGNED NULL,
  PRIMARY KEY (category_id),
  UNIQUE KEY uk_category_name (category_name),
  CONSTRAINT fk_category_parent FOREIGN KEY (parent_category_id) REFERENCES category (category_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE supplier (
  supplier_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  supplier_name  VARCHAR(100) NOT NULL,
  email          VARCHAR(100) NULL,
  phone          VARCHAR(20)  NULL,
  address        VARCHAR(200) NULL,
  is_active      TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (supplier_id)
) ENGINE=InnoDB;

CREATE TABLE warehouse (
  warehouse_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  warehouse_code  VARCHAR(10)  NOT NULL,
  warehouse_name  VARCHAR(80)  NOT NULL,
  city            VARCHAR(60)  NOT NULL,
  is_active       TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (warehouse_id),
  UNIQUE KEY uk_warehouse_code (warehouse_code)
) ENGINE=InnoDB;

CREATE TABLE product (
  product_id       INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  sku              VARCHAR(20)   NOT NULL,
  product_name     VARCHAR(100)  NOT NULL,
  category_id      INT UNSIGNED  NOT NULL,
  unit_of_measure  VARCHAR(10)   NOT NULL DEFAULT 'pcs',
  standard_cost    DECIMAL(12,2) NOT NULL,
  reorder_level    INT           NOT NULL DEFAULT 0,
  is_active        TINYINT(1)    NOT NULL DEFAULT 1,
  created_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (product_id),
  UNIQUE KEY uk_product_sku (sku),
  CONSTRAINT fk_product_category FOREIGN KEY (category_id) REFERENCES category (category_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT chk_product_cost    CHECK (standard_cost >= 0),
  CONSTRAINT chk_product_reorder CHECK (reorder_level >= 0)
) ENGINE=InnoDB;

CREATE TABLE product_supplier (
  product_id     INT UNSIGNED NOT NULL,
  supplier_id    INT UNSIGNED NOT NULL,
  supplier_sku   VARCHAR(30)  NULL,
  lead_time_days SMALLINT UNSIGNED NOT NULL DEFAULT 7,
  PRIMARY KEY (product_id, supplier_id),
  CONSTRAINT fk_ps_product  FOREIGN KEY (product_id)  REFERENCES product (product_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_ps_supplier FOREIGN KEY (supplier_id) REFERENCES supplier (supplier_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE txn_type (
  type_id      TINYINT UNSIGNED NOT NULL,
  type_code    VARCHAR(20)      NOT NULL,
  description  VARCHAR(120)     NOT NULL,
  sign_rule    VARCHAR(10)      NOT NULL,
  PRIMARY KEY (type_id),
  UNIQUE KEY uk_txn_type_code (type_code),
  CONSTRAINT chk_txn_sign_rule CHECK (sign_rule IN ('POSITIVE','NEGATIVE','EITHER'))
) ENGINE=InnoDB;

CREATE TABLE stock_transfer (
  transfer_id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
  from_warehouse_id  INT UNSIGNED NOT NULL,
  to_warehouse_id    INT UNSIGNED NOT NULL,
  created_by         INT UNSIGNED NOT NULL,
  created_at         DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (transfer_id),
  -- (no explicit ON DELETE / ON UPDATE here: MySQL refuses CHECK constraints on
  --  columns that carry referential actions; the default NO ACTION behaves like RESTRICT)
  CONSTRAINT fk_transfer_from FOREIGN KEY (from_warehouse_id) REFERENCES warehouse (warehouse_id),
  CONSTRAINT fk_transfer_to   FOREIGN KEY (to_warehouse_id)   REFERENCES warehouse (warehouse_id),
  CONSTRAINT fk_transfer_user FOREIGN KEY (created_by)        REFERENCES app_user (user_id),
  CONSTRAINT chk_transfer_diff CHECK (from_warehouse_id <> to_warehouse_id)
) ENGINE=InnoDB;

-- ---------- The immutable ledger ----------
-- No FOREIGN KEYs: InnoDB does not allow them on partitioned tables.
-- The BEFORE INSERT trigger (02_triggers.sql) validates every reference instead.
CREATE TABLE stock_ledger (
  ledger_id           BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  entry_time          DATETIME(6)      NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
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
  PRIMARY KEY (ledger_id, entry_time),
  KEY idx_ledger_prod_wh_time (product_id, warehouse_id, entry_time),
  KEY idx_ledger_type_time    (type_id, entry_time),
  KEY idx_ledger_transfer     (transfer_id),
  KEY idx_ledger_reverses     (reverses_ledger_id),
  CONSTRAINT chk_ledger_qty_nonzero CHECK (quantity_change <> 0)
) ENGINE=InnoDB
PARTITION BY RANGE (TO_DAYS(entry_time)) (
  PARTITION p_before_2026 VALUES LESS THAN (TO_DAYS('2026-01-01')),
  PARTITION p2026_q1      VALUES LESS THAN (TO_DAYS('2026-04-01')),
  PARTITION p2026_q2      VALUES LESS THAN (TO_DAYS('2026-07-01')),
  PARTITION p2026_q3      VALUES LESS THAN (TO_DAYS('2026-10-01')),
  PARTITION p2026_q4      VALUES LESS THAN (TO_DAYS('2027-01-01')),
  PARTITION p2027_q1      VALUES LESS THAN (TO_DAYS('2027-04-01')),
  PARTITION p2027_q2      VALUES LESS THAN (TO_DAYS('2027-07-01')),
  PARTITION p2027_q3      VALUES LESS THAN (TO_DAYS('2027-10-01')),
  PARTITION p2027_q4      VALUES LESS THAN (TO_DAYS('2028-01-01')),
  PARTITION p_future      VALUES LESS THAN MAXVALUE
);

-- ---------- Derived (trigger-maintained) tables ----------
CREATE TABLE stock_balance (
  product_id        INT UNSIGNED    NOT NULL,
  warehouse_id      INT UNSIGNED    NOT NULL,
  quantity_on_hand  INT             NOT NULL DEFAULT 0,
  last_ledger_id    BIGINT UNSIGNED NULL,
  updated_at        DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (product_id, warehouse_id),
  CONSTRAINT fk_balance_product   FOREIGN KEY (product_id)   REFERENCES product (product_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_balance_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT chk_balance_nonneg CHECK (quantity_on_hand >= 0)
) ENGINE=InnoDB;

CREATE TABLE daily_stock_summary (
  summary_date  DATE         NOT NULL,
  product_id    INT UNSIGNED NOT NULL,
  warehouse_id  INT UNSIGNED NOT NULL,
  qty_in        INT          NOT NULL DEFAULT 0,
  qty_out       INT          NOT NULL DEFAULT 0,
  closing_qty   INT          NOT NULL DEFAULT 0,
  PRIMARY KEY (summary_date, product_id, warehouse_id),
  CONSTRAINT fk_daily_product   FOREIGN KEY (product_id)   REFERENCES product (product_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_daily_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB;
-- ============================================================
-- 02 - Triggers: validation, immutability, summary maintenance
-- ============================================================
USE stock_ledger_db;

DELIMITER $$

-- ---- Immutability: the ledger can never be changed or removed ----
CREATE TRIGGER trg_ledger_no_update BEFORE UPDATE ON stock_ledger
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'stock_ledger is append-only: UPDATE is not allowed. Add a reversing entry instead.';
END$$

CREATE TRIGGER trg_ledger_no_delete BEFORE DELETE ON stock_ledger
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'stock_ledger is append-only: DELETE is not allowed. Add a reversing entry instead.';
END$$

-- ---- Validation (replaces the foreign keys that partitioning forbids) ----
CREATE TRIGGER trg_ledger_bi BEFORE INSERT ON stock_ledger
FOR EACH ROW
BEGIN
  DECLARE v_code   VARCHAR(20) DEFAULT '';
  DECLARE v_rule   VARCHAR(10) DEFAULT '';
  DECLARE v_cnt    INT DEFAULT 0;
  DECLARE v_o_cnt  INT DEFAULT 0;
  DECLARE v_o_prod INT UNSIGNED DEFAULT 0;
  DECLARE v_o_wh   INT UNSIGNED DEFAULT 0;
  DECLARE v_o_qty  INT DEFAULT 0;
  DECLARE v_o_type TINYINT UNSIGNED DEFAULT 0;
  DECLARE v_msg    VARCHAR(200);

  -- transaction type
  SELECT COALESCE(MAX(type_code), ''), COALESCE(MAX(sign_rule), '')
    INTO v_code, v_rule
    FROM txn_type WHERE type_id = NEW.type_id;
  IF v_code = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: unknown transaction type';
  END IF;

  -- references
  SELECT COUNT(*) INTO v_cnt FROM product WHERE product_id = NEW.product_id;
  IF v_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: product does not exist';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM warehouse WHERE warehouse_id = NEW.warehouse_id;
  IF v_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: warehouse does not exist';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM app_user WHERE user_id = NEW.user_id;
  IF v_cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: user does not exist';
  END IF;

  IF NEW.supplier_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_cnt FROM supplier WHERE supplier_id = NEW.supplier_id;
    IF v_cnt = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: supplier does not exist';
    END IF;
  END IF;

  -- sign must match the transaction type
  IF v_rule = 'POSITIVE' AND NEW.quantity_change <= 0 THEN
    SET v_msg = CONCAT(v_code, ' must add stock (positive quantity)');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;
  IF v_rule = 'NEGATIVE' AND NEW.quantity_change >= 0 THEN
    SET v_msg = CONCAT(v_code, ' must remove stock (negative quantity)');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  -- transfer legs must belong to a transfer
  IF v_code IN ('TRANSFER_OUT', 'TRANSFER_IN') THEN
    SELECT COUNT(*) INTO v_cnt FROM stock_transfer WHERE transfer_id = NEW.transfer_id;
    IF NEW.transfer_id IS NULL OR v_cnt = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: transfer entries need a valid transfer_id';
    END IF;
  END IF;

  -- reversal rules
  IF v_code = 'REVERSAL' THEN
    IF NEW.reverses_ledger_id IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: a reversal must point to the entry it reverses';
    END IF;

    SELECT COUNT(*), COALESCE(MAX(product_id), 0), COALESCE(MAX(warehouse_id), 0),
           COALESCE(MAX(quantity_change), 0), COALESCE(MAX(type_id), 0)
      INTO v_o_cnt, v_o_prod, v_o_wh, v_o_qty, v_o_type
      FROM stock_ledger WHERE ledger_id = NEW.reverses_ledger_id;

    IF v_o_cnt = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: the entry to reverse does not exist';
    END IF;
    IF v_o_type = NEW.type_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: a reversal cannot be reversed again';
    END IF;
    IF v_o_prod <> NEW.product_id OR v_o_wh <> NEW.warehouse_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: reversal must use the same product and warehouse';
    END IF;
    IF NEW.quantity_change <> -v_o_qty THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: reversal quantity must exactly cancel the original';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM stock_ledger WHERE reverses_ledger_id = NEW.reverses_ledger_id;
    IF v_cnt > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: this entry has already been reversed';
    END IF;
  ELSEIF NEW.reverses_ledger_id IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger rejected: only REVERSAL entries may set reverses_ledger_id';
  END IF;
END$$

-- ---- Keep the summary tables in sync ----
-- (UPDATE-then-INSERT is used instead of INSERT .. ON DUPLICATE KEY UPDATE for
--  stock_balance, because MySQL checks the CHECK constraint on the proposed
--  insert row first, which would reject every negative movement.)
CREATE TRIGGER trg_ledger_ai AFTER INSERT ON stock_ledger
FOR EACH ROW
BEGIN
  DECLARE v_bal INT DEFAULT 0;

  UPDATE stock_balance
     SET quantity_on_hand = quantity_on_hand + NEW.quantity_change,
         last_ledger_id   = NEW.ledger_id
   WHERE product_id = NEW.product_id AND warehouse_id = NEW.warehouse_id;

  IF ROW_COUNT() = 0 THEN
    INSERT INTO stock_balance (product_id, warehouse_id, quantity_on_hand, last_ledger_id)
    VALUES (NEW.product_id, NEW.warehouse_id, NEW.quantity_change, NEW.ledger_id);
  END IF;

  SELECT quantity_on_hand INTO v_bal
    FROM stock_balance
   WHERE product_id = NEW.product_id AND warehouse_id = NEW.warehouse_id;

  INSERT INTO daily_stock_summary
         (summary_date, product_id, warehouse_id, qty_in, qty_out, closing_qty)
  VALUES (DATE(NEW.entry_time), NEW.product_id, NEW.warehouse_id,
          GREATEST(NEW.quantity_change, 0), GREATEST(-NEW.quantity_change, 0), v_bal) AS nd
  ON DUPLICATE KEY UPDATE
         qty_in      = daily_stock_summary.qty_in  + nd.qty_in,
         qty_out     = daily_stock_summary.qty_out + nd.qty_out,
         closing_qty = nd.closing_qty;
END$$

DELIMITER ;
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
-- ============================================================
-- 07 - Role passkeys: each role has its own passkey, stored salted + hashed
--      The dashboard calls sp_login; the app account never reads the hashes.
-- ============================================================
USE stock_ledger_db;

-- The secrets live in their own schema. The app account (ledger_app) has no
-- privilege there at all; only the definer-rights procedures below can touch it.
DROP DATABASE IF EXISTS stock_ledger_auth;
CREATE DATABASE stock_ledger_auth CHARACTER SET utf8mb4;

CREATE TABLE stock_ledger_auth.role_passkey (
  role_id       TINYINT UNSIGNED NOT NULL,
  passkey_salt  CHAR(16)         NOT NULL,
  passkey_hash  CHAR(64)         NOT NULL,
  changed_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (role_id)
) ENGINE=InnoDB;

CREATE TABLE stock_ledger_auth.login_audit (
  audit_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  attempt_at  DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  role_name   VARCHAR(30)     NOT NULL,
  succeeded   TINYINT(1)      NOT NULL,
  client      VARCHAR(45)     NULL,
  PRIMARY KEY (audit_id),
  KEY idx_login_time (attempt_at)
) ENGINE=InnoDB;

-- Starting passkeys (demo values; the Admin can change them in the dashboard)
-- (salt first, then hash from the stored salt, so the two can never disagree)
INSERT INTO stock_ledger_auth.role_passkey (role_id, passkey_salt, passkey_hash)
SELECT role_id, HEX(RANDOM_BYTES(8)), '' FROM `role`;

UPDATE stock_ledger_auth.role_passkey k JOIN `role` r ON r.role_id = k.role_id
   SET k.passkey_hash = SHA2(CONCAT(k.passkey_salt, CASE r.role_name
         WHEN 'Admin'             THEN 'ADMIN-4821'
         WHEN 'Warehouse Manager' THEN 'STORE-7305'
         WHEN 'Purchase Officer'  THEN 'BUYER-5192'
         WHEN 'Analyst'           THEN 'VIEWER-2468' END), 256);

DELIMITER $$

-- Check a role + passkey; on success return the person who will act (first active user of the role)
CREATE PROCEDURE sp_login(IN p_role VARCHAR(30), IN p_passkey VARCHAR(64), IN p_client VARCHAR(45))
BEGIN
  DECLARE v_ok   TINYINT DEFAULT 0;
  DECLARE v_user INT UNSIGNED DEFAULT 0;

  SELECT COUNT(*) INTO v_ok
    FROM `role` r JOIN stock_ledger_auth.role_passkey k ON k.role_id = r.role_id
   WHERE r.role_name = p_role
     AND k.passkey_hash = SHA2(CONCAT(k.passkey_salt, p_passkey), 256);

  INSERT INTO stock_ledger_auth.login_audit (role_name, succeeded, client)
  VALUES (LEFT(COALESCE(p_role, ''), 30), v_ok, p_client);

  IF v_ok = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wrong passkey for this role';
  END IF;

  SELECT COALESCE(MIN(u.user_id), 0) INTO v_user
    FROM app_user u JOIN `role` r ON r.role_id = u.role_id
   WHERE r.role_name = p_role AND u.is_active = 1;
  IF v_user = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No active user for this role';
  END IF;

  SELECT u.user_id, u.full_name, r.role_name
    FROM app_user u JOIN `role` r ON r.role_id = u.role_id
   WHERE u.user_id = v_user;
END$$

-- Only an Admin may change a role's passkey
CREATE PROCEDURE sp_set_passkey(IN p_admin_user_id INT UNSIGNED, IN p_role VARCHAR(30), IN p_new VARCHAR(64))
BEGIN
  DECLARE v_salt CHAR(16);
  IF fn_user_role(p_admin_user_id) <> 'Admin' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Access denied: only an Admin can change passkeys';
  END IF;
  IF p_new IS NULL OR CHAR_LENGTH(p_new) < 6 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A passkey needs at least 6 characters';
  END IF;
  IF (SELECT COUNT(*) FROM `role` WHERE role_name = p_role) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown role';
  END IF;
  SET v_salt = HEX(RANDOM_BYTES(8));
  UPDATE stock_ledger_auth.role_passkey k JOIN `role` r ON r.role_id = k.role_id
     SET k.passkey_salt = v_salt, k.passkey_hash = SHA2(CONCAT(v_salt, p_new), 256), k.changed_at = NOW()
   WHERE r.role_name = p_role;
  SELECT p_role AS role_name, 'changed' AS status;
END$$

-- Recent sign-in attempts for the Admin page (no hashes involved)
CREATE PROCEDURE sp_recent_logins(IN p_admin_user_id INT UNSIGNED)
BEGIN
  IF fn_user_role(p_admin_user_id) <> 'Admin' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Access denied: only an Admin can see sign-in history';
  END IF;
  SELECT attempt_at, role_name, succeeded, client
    FROM stock_ledger_auth.login_audit ORDER BY audit_id DESC LIMIT 20;
END$$

DELIMITER ;

SELECT 'Passkeys ready' AS status;
