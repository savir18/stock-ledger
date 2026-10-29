"""
End-to-end tests for the dashboard: sign-in, passkeys, role permissions and the main workflows.
Runs against the real MySQL database (needs setup_all.sql to have been run).

    python tests/test_dashboard.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import app as dash  # noqa: E402

PASSKEYS = {"Admin": "ADMIN-4821", "Warehouse Manager": "STORE-7305",
            "Purchase Officer": "BUYER-5192", "Analyst": "VIEWER-2468"}
results = []


def check(name):
    def deco(fn):
        try:
            fn()
            results.append((name, True, ""))
            print(f"  PASS  {name}")
        except AssertionError as e:
            results.append((name, False, str(e)))
            print(f"  FAIL  {name}\n        {e}")
        except Exception as e:  # noqa: BLE001
            results.append((name, False, repr(e)))
            print(f"  FAIL  {name}\n        {e!r}")
        return fn
    return deco


def client(role=None, passkey=None):
    c = dash.app.test_client()
    if role:
        r = c.post("/api/login", json={"role": role, "passkey": passkey or PASSKEYS[role]})
        assert r.status_code == 200, f"login as {role} failed: {r.get_json()}"
    return c


def code(c, method, path, **kw):
    return getattr(c, method)(path, **kw).status_code


print("\nDashboard tests (real MySQL)\n")

# ---------------------------------------------------------------- sign-in
@check("signed-out visitors are refused on every data route")
def _():
    c = client()
    for p in ["/api/meta", "/api/dashboard", "/api/stock", "/api/ledger", "/api/balance?product_id=1&warehouse_id=1",
              "/api/analytics/abc", "/api/integrity", "/api/perf", "/api/admin/logins"]:
        assert code(c, "get", p) == 401, p
    for p in ["/api/movement", "/api/transfer", "/api/reverse", "/api/integrity/tamper", "/api/admin/passkey"]:
        assert code(c, "post", p, json={}) == 401, p
    assert c.get("/api/me").get_json()["me"] is None


@check("sign-in screen files are served without signing in")
def _():
    c = client()
    assert code(c, "get", "/") == 200
    for f in ["/static/app.js", "/static/style.css"]:
        assert code(c, "get", f) == 200, f


@check("a wrong passkey is refused and a passkey for another role does not work")
def _():
    c = client()
    r = c.post("/api/login", json={"role": "Analyst", "passkey": "nope"})
    assert r.status_code == 401 and "not right" in r.get_json()["error"]
    r = c.post("/api/login", json={"role": "Analyst", "passkey": PASSKEYS["Admin"]})
    assert r.status_code == 401
    assert c.get("/api/me").get_json()["me"] is None
    dash._failures.clear()


@check("missing role or passkey gives a clear message")
def _():
    c = client()
    assert c.post("/api/login", json={"role": "", "passkey": "x"}).status_code == 400
    assert c.post("/api/login", json={"role": "Admin", "passkey": "  "}).status_code == 400
    assert c.post("/api/login", json={"role": "Hacker", "passkey": "x"}).status_code == 400


@check("five wrong passkeys lock sign-in for a while, even for the right passkey")
def _():
    dash._failures.clear()
    c = client()
    for _i in range(5):
        c.post("/api/login", json={"role": "Admin", "passkey": "wrong"})
    r = c.post("/api/login", json={"role": "Admin", "passkey": PASSKEYS["Admin"]})
    assert r.status_code == 429, r.status_code
    dash._failures.clear()


@check("every role signs in with its own passkey and gets its own pages")
def _():
    expect = {"Admin": 8, "Warehouse Manager": 4, "Purchase Officer": 5, "Analyst": 5}
    for role, n in expect.items():
        c = client(role)
        me = c.get("/api/me").get_json()
        assert me["me"]["role"] == role and len(me["pages"]) == n, (role, me)


@check("signing out ends the session")
def _():
    c = client("Admin")
    assert code(c, "get", "/api/stock") == 200
    c.post("/api/logout", json={})
    assert code(c, "get", "/api/stock") == 401


# ---------------------------------------------------------------- permissions
MATRIX = {   # (method, path, json-body-as-string) -> roles allowed
    ("get", "/api/dashboard", None): {"Admin", "Warehouse Manager", "Purchase Officer", "Analyst"},
    ("get", "/api/stock", None): {"Admin", "Warehouse Manager", "Purchase Officer", "Analyst"},
    ("get", "/api/ledger", None): {"Admin", "Warehouse Manager", "Purchase Officer", "Analyst"},
    ("get", "/api/analytics/abc", None): {"Admin", "Purchase Officer", "Analyst"},
    ("get", "/api/analytics/forecast?product_id=1", None): {"Admin", "Purchase Officer", "Analyst"},
    ("get", "/api/analytics/dead-stock?days=90", None): {"Admin", "Purchase Officer", "Analyst"},
    ("get", "/api/analytics/as-of?date=2026-08-01", None): {"Admin", "Analyst"},
    ("get", "/api/integrity", None): {"Admin", "Analyst"},
    ("post", "/api/integrity/tamper", "UPDATE"): {"Admin"},   # allowed = reaches MySQL (then blocked there)
    ("get", "/api/perf", None): {"Admin"},
    ("get", "/api/admin/logins", None): {"Admin"},
}


@check("each role can reach exactly the routes meant for it")
def _():
    for (method, path, body), allowed in MATRIX.items():
        for role in PASSKEYS:
            c = client(role)
            r = getattr(c, method)(path, **({"json": {"action": body}} if body is not None else {}))
            if role in allowed:
                assert r.status_code != 403 and r.status_code != 401, f"{role} should reach {path}, got {r.status_code}"
            else:
                assert r.status_code == 403, f"{role} should be refused {path}, got {r.status_code}"


# ---------------------------------------------------------------- workflows
def balance(c, p, w):
    return c.get(f"/api/balance?product_id={p}&warehouse_id={w}").get_json()["quantity"]


@check("Purchase Officer receives stock; the balance rises and the entry is theirs")
def _():
    c = client("Purchase Officer")
    before = balance(c, 1, 1)
    r = c.post("/api/movement", json={"type": "PURCHASE", "product_id": 1, "warehouse_id": 1, "quantity": 40,
                                      "supplier_id": 1, "reference": "T-PO", "remarks": "test", "user_id": 1})
    assert r.status_code == 200, r.get_json()
    assert balance(c, 1, 1) == before + 40
    row = c.get("/api/ledger?limit=1").get_json()["rows"][0]
    assert row["username"] == "purchase1", f"user_id from the browser must be ignored, got {row['username']}"


@check("Warehouse Manager sells; overselling is refused by MySQL and changes nothing")
def _():
    c = client("Warehouse Manager")
    before = balance(c, 1, 1)
    r = c.post("/api/movement", json={"type": "SALE", "product_id": 1, "warehouse_id": 1, "quantity": 5})
    assert r.status_code == 200, r.get_json()
    assert balance(c, 1, 1) == before - 5
    r = c.post("/api/movement", json={"type": "SALE", "product_id": 1, "warehouse_id": 1, "quantity": 999999})
    assert r.status_code == 400 and "Insufficient stock" in r.get_json()["error"], r.get_json()
    assert balance(c, 1, 1) == before - 5


@check("MySQL itself refuses a role posting the wrong kind of entry")
def _():
    c = client("Warehouse Manager")
    r = c.post("/api/movement", json={"type": "PURCHASE", "product_id": 1, "warehouse_id": 1, "quantity": 1, "supplier_id": 1})
    assert r.status_code == 400 and "Access denied" in r.get_json()["error"], r.get_json()
    c = client("Purchase Officer")
    r = c.post("/api/movement", json={"type": "SALE", "product_id": 1, "warehouse_id": 1, "quantity": 1})
    assert r.status_code == 400 and "Access denied" in r.get_json()["error"], r.get_json()


@check("Analyst and Purchase Officer cannot post or transfer through the API")
def _():
    assert code(client("Analyst"), "post", "/api/movement", json={"type": "SALE", "product_id": 1, "warehouse_id": 1, "quantity": 1}) == 403
    assert code(client("Analyst"), "post", "/api/transfer", json={}) == 403
    assert code(client("Purchase Officer"), "post", "/api/transfer", json={"product_id": 1, "from_wh": 1, "to_wh": 2, "quantity": 1}) == 403


@check("transfer moves stock; a transfer that cannot be covered changes nothing")
def _():
    c = client("Warehouse Manager")
    a0, b0 = balance(c, 2, 1), balance(c, 2, 2)
    r = c.post("/api/transfer", json={"product_id": 2, "from_wh": 1, "to_wh": 2, "quantity": 2})
    assert r.status_code == 200, r.get_json()
    assert balance(c, 2, 1) == a0 - 2 and balance(c, 2, 2) == b0 + 2
    r = c.post("/api/transfer", json={"product_id": 2, "from_wh": 1, "to_wh": 2, "quantity": 9999999})
    assert r.status_code == 400
    assert balance(c, 2, 1) == a0 - 2 and balance(c, 2, 2) == b0 + 2
    assert c.post("/api/transfer", json={"product_id": 2, "from_wh": 1, "to_wh": 1, "quantity": 1}).status_code == 400


@check("cancelling an entry adds an opposite entry; cancelling twice is refused")
def _():
    c = client("Warehouse Manager")
    c.post("/api/movement", json={"type": "SALE", "product_id": 3, "warehouse_id": 1, "quantity": 2})
    before = balance(c, 3, 1)
    last = c.get("/api/ledger?product_id=3&warehouse_id=1&limit=1").get_json()["rows"][0]
    r = c.post("/api/reverse", json={"ledger_id": last["ledger_id"], "reason": "test"})
    assert r.status_code == 200, r.get_json()
    assert balance(c, 3, 1) == before + 2
    again = c.post("/api/reverse", json={"ledger_id": last["ledger_id"], "reason": "again"})
    assert again.status_code == 400, again.get_json()
    rows = c.get("/api/ledger?product_id=3&warehouse_id=1&limit=5").get_json()["rows"]
    assert any(x["is_reversed"] for x in rows)


@check("bad input is rejected with a message, not a crash")
def _():
    c = client("Warehouse Manager")
    assert c.post("/api/movement", json={"type": "SALE", "product_id": "abc", "warehouse_id": 1, "quantity": 1}).status_code == 400
    assert c.post("/api/movement", json={"type": "SALE", "product_id": 1, "warehouse_id": 1, "quantity": 0}).status_code == 400
    assert c.post("/api/movement", data="not json", content_type="text/plain").status_code == 400
    assert c.post("/api/movement", json={"type": "SALE", "product_id": 99999, "warehouse_id": 1, "quantity": 1}).status_code == 400


@check("Admin: tampering is blocked, corrupt then rebuild fixes the books")
def _():
    c = client("Admin")
    for action in ("UPDATE", "DELETE"):
        r = c.post("/api/integrity/tamper", json={"action": action})
        assert r.status_code == 400 and "append-only" in r.get_json()["error"], r.get_json()
    c.post("/api/integrity/corrupt", json={})
    assert len(c.get("/api/integrity").get_json()["mismatches"]) >= 1
    c.post("/api/integrity/rebuild", json={})
    assert c.get("/api/integrity").get_json()["mismatches"] == []


@check("analytics and the performance lab return data")
def _():
    c = client("Admin")
    assert len(c.get("/api/analytics/abc").get_json()["rows"]) > 5
    f = c.get("/api/analytics/forecast?product_id=1").get_json()
    assert len(f["series"]) == 12 and "ma4_forecast" in f["summary"]
    assert len(c.get("/api/analytics/dead-stock?days=90").get_json()["rows"]) >= 1
    assert len(c.get("/api/analytics/as-of?date=2026-08-01").get_json()["rows"]) > 5
    p = c.get("/api/perf").get_json()
    assert len(p["tests"]) == 2 and all(len(t["results"]) == 3 for t in p["tests"])


@check("Admin changes a passkey: old one stops, new one works; others cannot change it")
def _():
    c = client("Admin")
    assert code(client("Analyst"), "post", "/api/admin/passkey", json={"role": "Analyst", "passkey": "hackhack"}) == 403
    assert c.post("/api/admin/passkey", json={"role": "Analyst", "passkey": "abc"}).status_code == 400   # too short
    assert c.post("/api/admin/passkey", json={"role": "Analyst", "passkey": "TEMP-9911"}).status_code == 200
    dash._failures.clear()
    assert client().post("/api/login", json={"role": "Analyst", "passkey": PASSKEYS["Analyst"]}).status_code == 401
    assert client().post("/api/login", json={"role": "Analyst", "passkey": "TEMP-9911"}).status_code == 200
    assert c.post("/api/admin/passkey", json={"role": "Analyst", "passkey": PASSKEYS["Analyst"]}).status_code == 200
    assert client().post("/api/login", json={"role": "Analyst", "passkey": PASSKEYS["Analyst"]}).status_code == 200
    log = c.get("/api/admin/logins").get_json()["rows"]
    assert any(not r["succeeded"] for r in log) and any(r["succeeded"] for r in log)


@check("the app's MySQL account cannot read passkey hashes")
def _():
    try:
        dash.query("SELECT * FROM stock_ledger_auth.role_passkey")
    except Exception as e:  # noqa: BLE001
        assert "denied" in str(e).lower(), e
        return
    raise AssertionError("ledger_app could read stock_ledger_auth.role_passkey")


@check("books still balance after all tests")
def _():
    c = client("Analyst")
    assert c.get("/api/integrity").get_json()["mismatches"] == []


passed = sum(1 for _n, ok, _e in results if ok)
print(f"\n{passed} of {len(results)} tests passed.\n")
sys.exit(0 if passed == len(results) else 1)
