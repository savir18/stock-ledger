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
