"""
Immutable Stock Ledger System - local web dashboard (Flask + MySQL)

Run:   python app.py        then open  http://127.0.0.1:5000
The page talks only to this server; this server talks only to MySQL.
All writes go through MySQL stored procedures, never straight into the ledger.
"""
import datetime
import decimal
import functools
import json
import os
import secrets
import statistics
import time

import pymysql
from flask import Flask, jsonify, request, send_from_directory, session
from flask.json.provider import DefaultJSONProvider
from pymysql.cursors import DictCursor

DB = dict(
    host=os.getenv("DB_HOST", "127.0.0.1"),
    port=int(os.getenv("DB_PORT", "3306")),
    user=os.getenv("DB_USER", "ledger_app"),
    password=os.getenv("DB_PASSWORD", "LedgerApp#2026"),
    database=os.getenv("DB_NAME", "stock_ledger_db"),
    charset="utf8mb4",
    autocommit=True,
    cursorclass=DictCursor,
    connect_timeout=5,
)

app = Flask(__name__, static_folder="static", static_url_path="/static")
app.config.update(
    SECRET_KEY=os.getenv("SECRET_KEY") or secrets.token_hex(32),   # signs the login cookie
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=datetime.timedelta(hours=8),
)

# What each role may open and do. The database repeats these rules inside the
# stored procedures (fn_role_can), so this is the first of two layers.
ROLES = {
    "Admin":             {"pages": ["home", "stock", "history", "record", "insights", "safety", "speed", "admin"]},
    "Warehouse Manager": {"pages": ["home", "stock", "history", "record"]},
    "Purchase Officer":  {"pages": ["home", "stock", "history", "record", "insights"]},
    "Analyst":           {"pages": ["home", "stock", "history", "insights", "safety"]},
}
ENTRY_TYPES = {   # which ledger entry types each role may post (mirrors fn_role_can in MySQL)
    "Admin":             ["PURCHASE", "SALE", "RETURN_IN", "RETURN_OUT", "WRITE_OFF", "ADJUSTMENT", "TRANSFER"],
    "Warehouse Manager": ["SALE", "RETURN_IN", "WRITE_OFF", "ADJUSTMENT", "TRANSFER"],
    "Purchase Officer":  ["PURCHASE", "RETURN_OUT"],
    "Analyst":           [],
}
_failures = {}   # client address -> list of recent failed sign-in times


class Provider(DefaultJSONProvider):
    """Make MySQL types (Decimal, datetime) JSON friendly."""

    def default(self, o):
        if isinstance(o, decimal.Decimal):
            return float(o)
        if isinstance(o, datetime.datetime):
            return o.strftime("%Y-%m-%d %H:%M:%S")
        if isinstance(o, datetime.date):
            return o.isoformat()
        if isinstance(o, datetime.timedelta):
            return str(o)
        return super().default(o)


app.json = Provider(app)


# ---------------------------------------------------------------- database
def connect():
    return pymysql.connect(**DB)


def query(sql, params=None):
    """Run one SELECT and return a list of dict rows."""
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            return list(cur.fetchall())
    finally:
        conn.close()


def call(proc, args=()):
    """CALL a stored procedure; return a list of result sets (each a list of dicts)."""
    marks = ",".join(["%s"] * len(args))
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(f"CALL {proc}({marks})", tuple(args))
            sets = []
            while True:
                if cur.description:
                    sets.append(list(cur.fetchall()))
                if not cur.nextset():
                    break
            return sets
    finally:
        conn.close()


def first(sets, default=None):
    return sets[0][0] if sets and sets[0] else default


# ---------------------------------------------------------------- errors
@app.errorhandler(pymysql.err.MySQLError)
def mysql_error(e):
    code = e.args[0] if e.args else 0
    msg = e.args[1] if len(e.args) > 1 else str(e)
    if code in (2003, 2002, 1045, 1049, 1044):
        hint = {
            2003: "Cannot reach MySQL. Is the MySQL service running?",
            2002: "Cannot reach MySQL. Is the MySQL service running?",
            1045: "MySQL refused the login. Check DB_USER / DB_PASSWORD.",
            1049: "Database not found. Run setup_all.sql first.",
            1044: "Login has no access to the database. Run sql/06_security.sql.",
        }[code]
        return jsonify(error=f"{hint} ({msg})", code=code), 503
    if code == 1146 and "ledger_lab" in msg:
        return jsonify(error="The performance lab tables are missing. Click 'Rebuild lab copies' first.",
                       code=code), 400
    status = 400 if code in (1644, 3819, 1142, 1370, 1305, 1054, 1064, 1146) else 500
    return jsonify(error=msg, code=code), status


@app.errorhandler(ValueError)
def value_error(e):
    return jsonify(error=str(e), code=0), 400


class AuthError(Exception):
    def __init__(self, msg, status=401):
        super().__init__(msg)
        self.status = status


@app.errorhandler(AuthError)
def auth_error(e):
    return jsonify(error=str(e), code=0, auth=True), e.status


def current():
    """The signed-in person, or None."""
    if "user_id" not in session:
        return None
    return dict(user_id=session["user_id"], name=session["name"], role=session["role"])


def allow(*roles):
    """Route guard: signed in, and (if roles are given) one of those roles."""
    def wrap(fn):
        @functools.wraps(fn)
        def inner(*a, **kw):
            me = current()
            if not me:
                raise AuthError("Please sign in first.")
            if roles and me["role"] not in roles:
                raise AuthError(f"The {me['role']} role is not allowed to do this.", 403)
            return fn(*a, **kw)
        return inner
    return wrap


def body():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        raise ValueError("Expected a JSON body")
    return data


def num(data, key, kind=int, required=True):
    v = data.get(key)
    if v in (None, ""):
        if required:
            raise ValueError(f"'{key}' is required")
        return None
    try:
        return kind(v)
    except (TypeError, ValueError):
        raise ValueError(f"'{key}' must be a number")


def text(data, key, limit=255):
    v = data.get(key)
    v = None if v in (None, "") else str(v).strip()[:limit]
    return v or None


# ---------------------------------------------------------------- pages
@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/health")
def health():
    row = query("SELECT VERSION() AS version, DATABASE() AS db")[0]
    return jsonify(row)


# ---------------------------------------------------------------- sign in
def client_id():
    return request.remote_addr or "?"


@app.get("/api/roles")
def roles_public():
    """Role names for the sign-in screen (nothing secret)."""
    return jsonify(roles=[dict(role=r, pages=v["pages"]) for r, v in ROLES.items()])


@app.post("/api/login")
def login():
    d = body()
    role, passkey = str(d.get("role", "")), str(d.get("passkey", ""))
    if role not in ROLES:
        raise ValueError("Choose a role first.")
    if not passkey.strip():
        raise ValueError("Enter the passkey for this role.")
    now = time.time()
    recent = [t for t in _failures.get(client_id(), []) if now - t < 300]
    if len(recent) >= 5:
        wait = int(300 - (now - recent[0]))
        raise AuthError(f"Too many wrong passkeys. Try again in {wait} seconds.", 429)
    try:
        row = first(call("sp_login", (role, passkey.strip(), client_id())))
    except pymysql.err.MySQLError as e:
        if e.args and e.args[0] == 1644:
            recent.append(now)
            _failures[client_id()] = recent
            raise AuthError(f"That passkey is not right for {role}. ({5 - len(recent)} tries left)", 401)
        raise
    _failures.pop(client_id(), None)
    session.clear()
    session.permanent = True
    session.update(user_id=int(row["user_id"]), name=row["full_name"], role=row["role_name"])
    return jsonify(me=current(), pages=ROLES[row["role_name"]]["pages"], entry_types=ENTRY_TYPES[row["role_name"]])


@app.post("/api/logout")
def logout():
    session.clear()
    return jsonify(ok=True)


@app.get("/api/me")
def me():
    u = current()
    if not u:
        return jsonify(me=None)
    return jsonify(me=u, pages=ROLES[u["role"]]["pages"], entry_types=ENTRY_TYPES[u["role"]])


@app.post("/api/admin/passkey")
@allow("Admin")
def change_passkey():
    d = body()
    role = str(d.get("role", ""))
    if role not in ROLES:
        raise ValueError("Unknown role.")
    call("sp_set_passkey", (current()["user_id"], role, str(d.get("passkey", "")).strip()))
    return jsonify(ok=True, role=role)


@app.get("/api/admin/logins")
@allow("Admin")
def recent_logins():
    return jsonify(rows=first_set(call("sp_recent_logins", (current()["user_id"],))))


# ---------------------------------------------------------------- lookups
@app.get("/api/meta")
@allow()
def meta():
    return jsonify(
        products=query("SELECT product_id, sku, product_name, standard_cost, reorder_level "
                       "FROM product WHERE is_active = 1 ORDER BY sku"),
        warehouses=query("SELECT warehouse_id, warehouse_code, warehouse_name FROM warehouse "
                         "WHERE is_active = 1 ORDER BY warehouse_id"),
        suppliers=query("SELECT supplier_id, supplier_name FROM supplier "
                        "WHERE is_active = 1 ORDER BY supplier_name"),
        types=query("SELECT type_code, description, sign_rule FROM txn_type ORDER BY type_id"),
    )


# ---------------------------------------------------------------- dashboard
@app.get("/api/dashboard")
@allow()
def dashboard():
    k = query("SELECT COALESCE(SUM(quantity_on_hand),0) AS units, "
              "COALESCE(SUM(stock_value),0) AS stock_value FROM v_current_stock")[0]
    k["ledger_entries"] = query("SELECT COUNT(*) AS n FROM stock_ledger")[0]["n"]
    k["below_reorder"] = query("SELECT COUNT(*) AS n FROM v_reorder_alerts")[0]["n"]
    rec = query("SELECT COUNT(*) AS pairs, COALESCE(SUM(difference <> 0),0) AS mismatches "
                "FROM v_reconciliation")[0]
    k["balance_pairs"] = rec["pairs"]
    k["mismatches"] = rec["mismatches"]
    weekly = query("SELECT week_start, units_sold, value_sold FROM v_weekly_sales "
                   "ORDER BY week_start DESC LIMIT 16")
    weekly.reverse()
    return jsonify(
        kpis=k,
        weekly=weekly,
        mix=query("SELECT type_code, entries, net_units FROM v_movement_summary ORDER BY entries DESC"),
        recent=query("SELECT ledger_id, entry_time, type_code, sku, product_name, warehouse_code, "
                     "quantity_change, username, is_reversed FROM v_ledger_history "
                     "ORDER BY ledger_id DESC LIMIT 8"),
        reorder=query("SELECT sku, product_name, total_qty, reorder_level, suggested_supplier, lead_time_days "
                      "FROM v_reorder_alerts ORDER BY (total_qty - reorder_level) LIMIT 6"),
    )


# ---------------------------------------------------------------- stock and ledger
@app.get("/api/stock")
@allow()
def stock():
    where, params = [], []
    if request.args.get("warehouse_id"):
        where.append("warehouse_id = %s")
        params.append(int(request.args["warehouse_id"]))
    if request.args.get("q"):
        where.append("(sku LIKE %s OR product_name LIKE %s)")
        like = f"%{request.args['q']}%"
        params += [like, like]
    sql = "SELECT * FROM v_current_stock"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY sku, warehouse_code"
    return jsonify(rows=query(sql, params))


@app.get("/api/balance")
@allow()
def balance():
    """Current quantity of one product in one warehouse (for the live preview on the Record page)."""
    rows = query("SELECT quantity_on_hand FROM stock_balance WHERE product_id = %s AND warehouse_id = %s",
                 (int(request.args["product_id"]), int(request.args["warehouse_id"])))
    return jsonify(quantity=int(rows[0]["quantity_on_hand"]) if rows else 0)


@app.get("/api/ledger")
@allow()
def ledger():
    where, params = [], []
    for arg, col in (("product_id", "product_id"), ("warehouse_id", "warehouse_id"), ("type", "type_code")):
        if request.args.get(arg):
            where.append(f"{col} = %s")
            params.append(request.args[arg])
    limit = max(1, min(int(request.args.get("limit", 100)), 500))
    sql = "SELECT * FROM v_ledger_history"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY ledger_id DESC LIMIT %s"
    return jsonify(rows=query(sql, params + [limit]))


@app.get("/api/running-balance")
@allow()
def running_balance():
    pid = int(request.args["product_id"])
    wid = int(request.args["warehouse_id"]) if request.args.get("warehouse_id") else None
    rows = first_set(call("sp_running_balance", (pid, wid)))
    return jsonify(total=len(rows), rows=rows[-200:])


def first_set(sets):
    return sets[0] if sets else []


# ---------------------------------------------------------------- writes (stored procedures)
@app.post("/api/movement")
@allow("Admin", "Warehouse Manager", "Purchase Officer")
def movement():
    d = body()
    res = call("sp_record_movement", (
        current()["user_id"], num(d, "product_id"), num(d, "warehouse_id"),
        str(d.get("type", "")), num(d, "quantity"),
        num(d, "unit_cost", float, required=False),
        num(d, "supplier_id", required=False),
        text(d, "reference", 40), text(d, "remarks"),
    ))
    return jsonify(first(res, {}))


@app.post("/api/transfer")
@allow("Admin", "Warehouse Manager")
def transfer():
    d = body()
    res = call("sp_transfer_stock", (
        current()["user_id"], num(d, "product_id"), num(d, "from_wh"), num(d, "to_wh"),
        num(d, "quantity"), text(d, "remarks"),
    ))
    return jsonify(first(res, {}))


@app.post("/api/reverse")
@allow("Admin", "Warehouse Manager", "Purchase Officer")
def reverse():
    d = body()
    reason = text(d, "reason") or "Reversed from dashboard"
    if d.get("transfer_id"):
        res = call("sp_reverse_transfer", (current()["user_id"], num(d, "transfer_id"), reason))
    else:
        res = call("sp_reverse_entry", (current()["user_id"], num(d, "ledger_id"), reason))
    return jsonify(first(res, {}))


# ---------------------------------------------------------------- analytics
@app.get("/api/analytics/abc")
@allow("Admin", "Purchase Officer", "Analyst")
def abc():
    return jsonify(rows=query("SELECT * FROM v_abc_analysis ORDER BY value_sold DESC"))


@app.get("/api/analytics/dead-stock")
@allow("Admin", "Purchase Officer", "Analyst")
def dead_stock():
    days = max(1, min(int(request.args.get("days", 90)), 3650))
    return jsonify(rows=first_set(call("sp_dead_stock", (days,))))


@app.get("/api/analytics/forecast")
@allow("Admin", "Purchase Officer", "Analyst")
def forecast():
    sets = call("sp_forecast", (int(request.args["product_id"]),))
    return jsonify(series=sets[0] if sets else [], summary=sets[1][0] if len(sets) > 1 and sets[1] else {})


@app.get("/api/analytics/as-of")
@allow("Admin", "Analyst")
def as_of():
    day = request.args.get("date", "")
    try:
        datetime.date.fromisoformat(day)
    except ValueError:
        raise ValueError("date must look like 2026-07-31")
    rows = first_set(call("sp_stock_as_of", (f"{day} 23:59:59.999999",)))
    return jsonify(rows=rows)


# ---------------------------------------------------------------- integrity
@app.get("/api/integrity")
@allow("Admin", "Analyst")
def integrity():
    rec = query("SELECT * FROM v_reconciliation WHERE difference <> 0 ORDER BY ABS(difference) DESC LIMIT 50")
    pairs = query("SELECT COUNT(*) AS n FROM v_reconciliation")[0]["n"]
    return jsonify(pairs=pairs, mismatches=rec)


@app.post("/api/integrity/tamper")
@allow("Admin")
def tamper():
    action = str(body().get("action", "")).upper()
    if action not in ("UPDATE", "DELETE"):
        raise ValueError("action must be UPDATE or DELETE")
    call("sp_demo_tamper", (action,))      # raises if the trigger blocks it (expected)
    return jsonify(blocked=False, message="The change went through - the ledger is NOT protected!")


@app.post("/api/integrity/corrupt")
@allow("Admin")
def corrupt():
    return jsonify(first(call("sp_demo_corrupt_balance"), {}))


@app.post("/api/integrity/rebuild")
@allow("Admin")
def rebuild():
    return jsonify(first(call("sp_rebuild_summaries"), {}))


# ---------------------------------------------------------------- performance lab
LAB_TABLES = [
    ("ledger_lab_plain", "No index, no partitions"),
    ("ledger_lab_indexed", "Indexes only"),
    ("stock_ledger", "Indexes + date partitions"),
]


def explain_row(sql, params):
    """EXPLAIN one query and return {partitions, type, key, rows}.
    Column names are matched case-insensitively and, if the tabular plan is
    empty or unfamiliar (newer MySQL versions), the JSON plan is read instead."""
    rows = query("EXPLAIN " + sql, params)
    r = {str(k).lower(): v for k, v in (rows[0] if rows else {}).items()}
    if r.get("type") is not None or r.get("key") is not None or r.get("rows") is not None:
        return r
    try:
        raw = query("EXPLAIN FORMAT=JSON " + sql, params)[0]
        doc = json.loads(next(iter(raw.values())))
    except Exception:
        return r

    def find(node):
        if isinstance(node, dict):
            if "table_name" in node or "access_type" in node:
                return node
            for v in node.values():
                f = find(v)
                if f:
                    return f
        elif isinstance(node, list):
            for v in node:
                f = find(v)
                if f:
                    return f
        return None

    t = find(doc) or {}
    parts = t.get("partitions")
    return {
        "partitions": ",".join(parts) if isinstance(parts, list) else parts,
        "type": t.get("access_type"),
        "key": t.get("key") or t.get("index_name"),
        "rows": t.get("rows_examined_per_scan") or t.get("estimated_rows"),
    }


def explain_and_time(sql_template, params, runs=5):
    out = []
    for table, label in LAB_TABLES:
        sql = sql_template.format(t=table)
        p = explain_row(sql, params)
        times = []
        for _ in range(runs):
            t0 = time.perf_counter()
            query(sql, params)
            times.append((time.perf_counter() - t0) * 1000)
        out.append(dict(
            table=table, label=label,
            partitions=p.get("partitions") or "all (no partitioning)",
            access=p.get("type"), key=p.get("key") or "none (full scan)",
            rows_examined=p.get("rows"), median_ms=round(statistics.median(times), 2),
        ))
    return out


@app.get("/api/perf")
@allow("Admin")
def perf():
    pid = int(request.args.get("product_id", 1))
    wid = int(request.args.get("warehouse_id", 1))
    today = datetime.date.today()
    m_start = (today.replace(day=1) - datetime.timedelta(days=1)).replace(day=1)   # first day of last month
    m_end = today.replace(day=1)
    q1 = ("SELECT COUNT(*) AS n, SUM(quantity_change) AS net FROM {t} "
          "WHERE product_id = %s AND warehouse_id = %s AND entry_time >= %s")
    q2 = ("SELECT type_id, COUNT(*) AS n, SUM(quantity_change) AS net FROM {t} "
          "WHERE entry_time >= %s AND entry_time < %s GROUP BY type_id")
    since = (today - datetime.timedelta(days=90)).isoformat()
    return jsonify(tests=[
        dict(title="Stock history of one product in one warehouse (last 90 days)",
             sql=q1.format(t="<table>"), note="Benefits from the (product, warehouse, time) index.",
             results=explain_and_time(q1, (pid, wid, since))),
        dict(title=f"Movement report for one month ({m_start} to {m_end})",
             sql=q2.format(t="<table>"), note="Benefits from partition pruning: only the quarter that holds the month is read.",
             results=explain_and_time(q2, (m_start.isoformat(), m_end.isoformat()))),
    ])


@app.post("/api/perf/rebuild")
@allow("Admin")
def perf_rebuild():
    call("sp_build_performance_lab")
    return jsonify(ok=True)


if __name__ == "__main__":
    print("Stock Ledger dashboard: http://127.0.0.1:5000")
    app.run(host="127.0.0.1", port=5000, debug=False)
