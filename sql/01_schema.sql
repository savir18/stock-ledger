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
