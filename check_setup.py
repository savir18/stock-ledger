"""
Self-check for the Immutable Stock Ledger database.

    python check_setup.py

Runs ~20 checks against your real MySQL: tables, triggers, partitions,
immutability, access control, stock rules, transfers, reversals, window
functions, and a two-session concurrency test.  Each check prints PASS or FAIL.
(It adds a few test entries to the ledger - which is exactly what a ledger is for.)
"""
import os
import sys
import threading

import pymysql
from pymysql.cursors import DictCursor

DB = dict(
    host=os.getenv("DB_HOST", "127.0.0.1"), port=int(os.getenv("DB_PORT", "3306")),
    user=os.getenv("DB_USER", "ledger_app"), password=os.getenv("DB_PASSWORD", "LedgerApp#2026"),
    database=os.getenv("DB_NAME", "stock_ledger_db"), charset="utf8mb4", autocommit=True,
    cursorclass=DictCursor, connect_timeout=5,
)
ADMIN, WH_MGR, ANALYST = 1, 2, 5      # user_ids from 05_seed.sql


def connect():
    return pymysql.connect(**DB)


def query(sql, params=()):
    c = connect()
    try:
        with c.cursor() as cur:
            cur.execute(sql, params)
            return list(cur.fetchall())
    finally:
        c.close()


def call(proc, *args):
    c = connect()
    try:
        with c.cursor() as cur:
            cur.execute(f"CALL {proc}({','.join(['%s'] * len(args))})", args)
            sets = []
            while True:
                if cur.description:
                    sets.append(list(cur.fetchall()))
                if not cur.nextset():
                    break
            return sets
    finally:
        c.close()


def balance(pid, wid):
    r = query("SELECT quantity_on_hand AS q FROM stock_balance WHERE product_id=%s AND warehouse_id=%s", (pid, wid))
    return int(r[0]["q"]) if r else 0


def mismatches():
    return int(query("SELECT COUNT(*) AS n FROM v_reconciliation WHERE difference <> 0")[0]["n"])


results = []


def check(name):
    def deco(fn):
        try:
            fn()
            results.append((name, True, ""))
            print(f"  PASS  {name}")
        except Exception as e:                      # noqa: BLE001
            results.append((name, False, str(e)))
            print(f"  FAIL  {name}\n        -> {e}")
        return fn
    return deco


def expect_error(fn, text):
    try:
        fn()
    except pymysql.err.MySQLError as e:
        msg = str(e.args[1] if len(e.args) > 1 else e)
        assert text.lower() in msg.lower(), f"error was '{msg}', expected it to mention '{text}'"
        return
    raise AssertionError(f"expected MySQL to refuse (error containing '{text}') but it succeeded")


print("\nImmutable Stock Ledger - self check\n")


@check("connect as ledger_app")
def _():
    r = query("SELECT VERSION() AS v, CURRENT_USER() AS u")[0]
    print(f"        (MySQL {r['v']} as {r['u']})")


@check("all 12 tables exist")
def _():
    want = {"role", "app_user", "category", "supplier", "warehouse", "product", "product_supplier",
            "txn_type", "stock_transfer", "stock_ledger", "stock_balance", "daily_stock_summary"}
    have = {r["TABLE_NAME"].lower() for r in query(
        "SELECT TABLE_NAME FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")}
    assert want <= have, f"missing tables: {sorted(want - have)}"


@check("ledger is partitioned by date")
def _():
    n = query("SELECT COUNT(*) AS n FROM information_schema.partitions WHERE table_schema = DATABASE() "
              "AND table_name = 'stock_ledger' AND partition_name IS NOT NULL")[0]["n"]
    assert n >= 5, f"only {n} partitions"


@check("immutability triggers exist (UPDATE, DELETE, validation, summary sync)")
def _():
    # ledger_app has no TRIGGER privilege, so information_schema hides triggers from it.
    # Test the validation trigger by behaviour instead: an entry for a product that
    # does not exist must be refused (the other three triggers are proven by later checks).
    try:
        call("sp_record_movement", ADMIN, 999999, 1, "PURCHASE", 1, None, 1, "CHK-BAD", "must be refused")
    except pymysql.err.MySQLError:
        return
    raise AssertionError("an entry for a non-existent product was accepted")


@check("demo data loaded (ledger has history)")
def _():
    n = query("SELECT COUNT(*) AS n FROM stock_ledger")[0]["n"]
    assert n > 1000, f"only {n} ledger rows - did 05_seed.sql finish?"


@check("UPDATE on the ledger is blocked")
def _():
    expect_error(lambda: call("sp_demo_tamper", "UPDATE"), "append-only")


@check("DELETE on the ledger is blocked")
def _():
    expect_error(lambda: call("sp_demo_tamper", "DELETE"), "append-only")


@check("app login has no direct write access to the ledger")
def _():
    expect_error(lambda: query("INSERT INTO stock_ledger (product_id, warehouse_id, type_id, quantity_change, user_id) "
                               "VALUES (1, 1, 1, 1, 1)"), "denied")


@check("summary table matches the ledger at start")
def _():
    assert mismatches() == 0, f"{mismatches()} balances disagree with the ledger"


P, W1, W2 = 1, 1, 2
state = {}


@check("purchase adds stock (and the trigger updates the balance)")
def _():
    b = balance(P, W1)
    r = call("sp_record_movement", ADMIN, P, W1, "PURCHASE", 10, None, 1, "CHK-PO", "self-check")[0][0]
    state["purchase_id"] = r["ledger_id"]
    assert balance(P, W1) == b + 10, "balance did not rise by 10"


@check("sale removes stock; sign is automatic")
def _():
    b = balance(P, W1)
    r = call("sp_record_movement", WH_MGR, P, W1, "SALE", 4, None, None, "CHK-SO", "self-check")[0][0]
    state["sale_id"] = r["ledger_id"]
    assert int(r["new_balance"]) == b - 4 == balance(P, W1)


@check("selling more than is in stock is refused")
def _():
    expect_error(lambda: call("sp_record_movement", WH_MGR, P, W1, "SALE", balance(P, W1) + 1, None, None, "X", None),
                 "insufficient stock")


@check("role rules: analyst cannot post, warehouse manager cannot purchase")
def _():
    expect_error(lambda: call("sp_record_movement", ANALYST, P, W1, "SALE", 1, None, None, "X", None), "access denied")
    expect_error(lambda: call("sp_record_movement", WH_MGR, P, W1, "PURCHASE", 1, None, 1, "X", None), "access denied")


@check("transfer moves stock between warehouses atomically")
def _():
    a, b = balance(P, W1), balance(P, W2)
    tid = call("sp_transfer_stock", WH_MGR, P, W1, W2, 2, "self-check")[0][0]["transfer_id"]
    state["transfer_id"] = tid
    assert (balance(P, W1), balance(P, W2)) == (a - 2, b + 2)
    legs = query("SELECT COUNT(*) AS n FROM stock_ledger WHERE transfer_id = %s", (tid,))[0]["n"]
    assert legs == 2, f"{legs} ledger rows for the transfer"


@check("a transfer that cannot be covered leaves nothing behind")
def _():
    a, b = balance(P, W1), balance(P, W2)
    n = query("SELECT COUNT(*) AS n FROM stock_ledger")[0]["n"]
    expect_error(lambda: call("sp_transfer_stock", WH_MGR, P, W1, W2, a + 999, None), "insufficient")
    assert (balance(P, W1), balance(P, W2)) == (a, b), "balances changed after a failed transfer"
    assert query("SELECT COUNT(*) AS n FROM stock_ledger")[0]["n"] == n, "ledger rows leaked from a failed transfer"


@check("reversing a transfer restores both warehouses; twice is refused")
def _():
    a, b = balance(P, W1), balance(P, W2)
    call("sp_reverse_transfer", WH_MGR, state["transfer_id"], "self-check")
    assert (balance(P, W1), balance(P, W2)) == (a + 2, b - 2)
    expect_error(lambda: call("sp_reverse_transfer", WH_MGR, state["transfer_id"], "again"), "already")


@check("reversing an entry adds a counter-entry; the original stays; twice is refused")
def _():
    b = balance(P, W1)
    call("sp_reverse_entry", ADMIN, state["sale_id"], "self-check")
    assert balance(P, W1) == b + 4, "reversing the sale should put 4 units back"
    orig = query("SELECT quantity_change AS q FROM stock_ledger WHERE ledger_id = %s", (state["sale_id"],))[0]["q"]
    assert orig == -4, "original entry was altered"
    expect_error(lambda: call("sp_reverse_entry", ADMIN, state["sale_id"], "again"), "already")


@check("window function: final running balance equals the balance table")
def _():
    rows = call("sp_running_balance", P, W1)[0]
    assert int(rows[-1]["running_balance"]) == balance(P, W1)


@check("forecast returns 12 weeks and a summary")
def _():
    s = call("sp_forecast", P)
    assert len(s[0]) == 12 and s[1][0]["ma4_forecast"] is not None


@check("ABC analysis, dead stock and point-in-time stock run")
def _():
    assert query("SELECT COUNT(*) AS n FROM v_abc_analysis")[0]["n"] > 0
    assert len(call("sp_dead_stock", 90)[0]) > 0, "no dead stock found (products 22-24 should be dead)"
    assert len(call("sp_stock_as_of", "2026-01-31 23:59:59")[0]) >= 0


@check("concurrency: two sessions sell the last units at once, only one wins")
def _():
    pid, wid = 24, 3
    b = balance(pid, wid)
    assert b > 0, "test product has no stock"
    outcomes, gate = [], threading.Barrier(2)

    def seller():
        try:
            gate.wait()
            call("sp_record_movement", WH_MGR, pid, wid, "SALE", b, None, None, "CHK-RACE", "concurrency test")
            outcomes.append("sold")
        except pymysql.err.MySQLError as e:
            outcomes.append("refused: " + str(e.args[1]))
    ts = [threading.Thread(target=seller) for _ in range(2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    # put the stock back so the demo data stays intact
    call("sp_record_movement", ADMIN, pid, wid, "PURCHASE", b, None, 6, "CHK-RESTOCK", "restore after concurrency test")
    wins = outcomes.count("sold")
    assert wins == 1, f"expected exactly one sale to succeed, got {outcomes}"
    assert balance(pid, wid) == b


@check("summary table still matches the ledger after all tests")
def _():
    assert mismatches() == 0, f"{mismatches()} balances disagree with the ledger"


failed = [r for r in results if not r[1]]
print(f"\n{len(results) - len(failed)} of {len(results)} checks passed.")
if failed:
    print("Send me the FAIL lines above and I will fix them.")
sys.exit(1 if failed else 0)
