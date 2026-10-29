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
