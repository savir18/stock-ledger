/* Stock Ledger dashboard - plain JavaScript, no libraries, works offline. */
"use strict";

const $ = (sel, el = document) => el.querySelector(sel);
const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const num = (n) => Number(n ?? 0).toLocaleString("en-IN", { maximumFractionDigits: 1 });
const money = (n) => "₹" + Number(n ?? 0).toLocaleString("en-IN", { maximumFractionDigits: 0 });
const signed = (n) => `<span class="${n > 0 ? "pos" : "neg"}">${n > 0 ? "+" : "−"}${num(Math.abs(n))}</span>`;
const parseTime = (s) => new Date(String(s).replace(" ", "T"));
const rtf = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
function ago(s) {
  const secs = (parseTime(s) - Date.now()) / 1000, a = Math.abs(secs);
  if (a < 60) return "just now";
  if (a < 3600) return rtf.format(Math.round(secs / 60), "minute");
  if (a < 86400) return rtf.format(Math.round(secs / 3600), "hour");
  if (a < 86400 * 45) return rtf.format(Math.round(secs / 86400), "day");
  return parseTime(s).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" });
}
const when = (s) => parseTime(s).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

const state = { me: null, pages: [], entryTypes: [], meta: null, ledgerFilter: null, recordType: null };

const ROLE_BLURB = {
  "Admin": "Full access, including safety checks and passkeys",
  "Warehouse Manager": "Record sales, returns, write-offs and transfers",
  "Purchase Officer": "Record purchases and supplier returns, see demand",
  "Analyst": "Read-only: stock, history and insights",
};
const NAV = [
  { id: "home", label: "Overview", hint: "What is happening now" },
  { id: "stock", label: "Stock", hint: "What you have, where" },
  { id: "history", label: "History", hint: "Every change, never erased" },
  { id: "record", label: "Record a change", hint: "Add or remove stock" },
  { id: "insights", label: "Insights", hint: "Sales, demand, slow movers" },
  { id: "safety", label: "Safety checks", hint: "Prove the books are honest" },
  { id: "speed", label: "Speed lab", hint: "Indexes and partitions" },
  { id: "admin", label: "Admin", hint: "Passkeys and sign-ins" },
];
const TYPE_INFO = {
  PURCHASE: { title: "Received from a supplier", text: "New stock arrived", sign: 1, verb: "Received" },
  SALE: { title: "Sold to a customer", text: "Stock left with a customer", sign: -1, verb: "Sold" },
  RETURN_IN: { title: "Customer returned items", text: "Stock came back", sign: 1, verb: "Customer returned" },
  RETURN_OUT: { title: "Sent back to a supplier", text: "Faulty or surplus stock went back", sign: -1, verb: "Sent back to supplier" },
  WRITE_OFF: { title: "Damaged or lost", text: "Remove stock that can no longer be sold", sign: -1, verb: "Wrote off" },
  ADJUSTMENT: { title: "Stock count correction", text: "The shelf count differs from the system", sign: 0, verb: "Corrected count of" },
  TRANSFER: { title: "Move between warehouses", text: "Take from one, add to another", sign: 0, verb: "Moved" },
  TRANSFER_OUT: { verb: "Sent to another warehouse:" },
  TRANSFER_IN: { verb: "Received from another warehouse:" },
  REVERSAL: { verb: "Cancelled an earlier entry for" },
};

/* ------------------------------------------------------------ plumbing */
async function api(path, options = {}) {
  const init = { headers: { "Content-Type": "application/json" }, credentials: "same-origin", ...options };
  if (init.body && typeof init.body !== "string") init.body = JSON.stringify(init.body);
  let res;
  try { res = await fetch(path, init); } catch (e) { throw new Error("Cannot reach the dashboard server. Is app.py still running?"); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    if (res.status === 401 && data.auth && state.me && path !== "/api/login") { state.me = null; showLogin("Your session ended. Please sign in again."); }
    const err = new Error(data.error || res.statusText); err.code = data.code; err.status = res.status; throw err;
  }
  return data;
}

function toast(text) {
  const t = $("#toast");
  t.textContent = text; t.hidden = false;
  clearTimeout(toast.h); toast.h = setTimeout(() => (t.hidden = true), 3600);
}
const showErr = (e) => toast(e.message);

function ask({ title, text, field, confirm = "Confirm", danger = false }) {
  return new Promise((resolve) => {
    const d = $("#dlg");
    d.innerHTML = `<form method="dialog"><h3>${esc(title)}</h3><p class="explain">${text}</p>
      ${field ? `<div class="field" style="margin-top:14px"><label for="dlgText">${esc(field.label)}</label><input id="dlgText" value="${esc(field.value || "")}" maxlength="200"></div>` : ""}
      <div class="actions"><button value="cancel" class="ghost" type="button" id="dlgNo">Keep it</button><button value="ok" class="${danger ? "danger" : ""}" id="dlgOk">${esc(confirm)}</button></div></form>`;
    $("#dlgNo").onclick = () => d.close("cancel");
    d.onclose = () => resolve(d.returnValue === "ok" ? (field ? $("#dlgText", d).value.trim() || field.value || "" : true) : null);
    d.returnValue = ""; d.showModal();
  });
}

const options = (rows, value, label, selected, blank) =>
  (blank ? `<option value="">${esc(blank)}</option>` : "") +
  rows.map((r) => `<option value="${esc(r[value])}" ${String(r[value]) === String(selected) ? "selected" : ""}>${esc(typeof label === "function" ? label(r) : r[label])}</option>`).join("");
const productLabel = (r) => `${r.product_name} (${r.sku})`;
const badge = (t, cls = "") => `<span class="badge ${esc(cls)}">${esc(t)}</span>`;
const title = (h, p, extra = "") => `<div class="page-title"><div><h2>${h}</h2>${p ? `<p>${p}</p>` : ""}</div>${extra}</div>`;
const help = (summary, text) => `<details class="help"><summary>${summary}</summary><p>${text}</p></details>`;
const tech = (text) => `<details class="tech"><summary>How MySQL does this</summary><p>${text}</p></details>`;
const kpi = (label, value, note = "", cls = "") => `<div class="card kpi ${cls}"><div class="label">${label}</div><div class="value">${value}</div><div class="note">${note}</div></div>`;
const empty = (head, text = "") => `<div class="empty"><b>${head}</b>${text}</div>`;
const skeleton = (n = 3) => `<div class="stack">${Array.from({ length: n }, () => `<div class="skeleton"></div>`).join("")}</div>`;

function table(cols, rows, opts = {}) {
  if (!rows.length) return empty(opts.emptyTitle || "Nothing to show", opts.emptyText || "");
  const head = cols.map((c) => `<th class="${c.num ? "num" : ""}" scope="col">${c.h}</th>`).join("");
  const body = rows.map((r) => `<tr class="${opts.rowClass ? opts.rowClass(r) : ""}">` +
    cols.map((c) => `<td class="${c.num ? "num" : ""}">${c.f(r)}</td>`).join("") + "</tr>").join("");
  return `<div class="scroll ${opts.noscroll ? "nomax" : ""}"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
}

/* ------------------------------------------------------------ tiny SVG charts */
const C = { bar: "#a45d1c", line: "#147d6c", grid: "#eadfd3", text: "#6a5b4d" };
function barChart({ labels, bars, line, forecast, height = 240, label = "Bar chart" }) {
  const W = 760, H = height, L = 48, R = 12, T = 14, B = 34;
  const all = [...bars, ...(line || []), ...(forecast ? [forecast.value] : [])].filter((v) => v != null);
  const max = Math.max(1, ...all) * 1.12;
  const n = labels.length + (forecast ? 1 : 0);
  const slot = (W - L - R) / n, bw = Math.min(34, slot * 0.62);
  const y = (v) => T + (H - T - B) * (1 - v / max);
  let s = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)}">`;
  for (let i = 0; i <= 4; i++) {
    const v = (max / 4) * i;
    s += `<line x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}" stroke="${C.grid}"/><text x="${L - 6}" y="${y(v) + 4}" font-size="12" text-anchor="end" fill="${C.text}">${num(Math.round(v))}</text>`;
  }
  labels.forEach((lb, i) => {
    const cx = L + slot * i + slot / 2;
    s += `<rect x="${cx - bw / 2}" y="${y(bars[i])}" width="${bw}" height="${Math.max(0, H - B - y(bars[i]))}" rx="4" fill="${C.bar}" opacity=".88"><title>${esc(lb)}: ${num(bars[i])}</title></rect>`;
    if (labels.length <= 16 || i % 2 === 0) s += `<text x="${cx}" y="${H - 12}" font-size="11.5" text-anchor="middle" fill="${C.text}">${esc(lb)}</text>`;
  });
  if (forecast) {
    const cx = L + slot * labels.length + slot / 2;
    s += `<rect x="${cx - bw / 2}" y="${y(forecast.value)}" width="${bw}" height="${Math.max(0, H - B - y(forecast.value))}" rx="4" fill="#fff" stroke="${C.line}" stroke-width="2" stroke-dasharray="4 3"><title>${esc(forecast.label)}: ${num(forecast.value)}</title></rect>` +
      `<text x="${cx}" y="${H - 12}" font-size="11.5" text-anchor="middle" fill="${C.line}" font-weight="600">${esc(forecast.label)}</text>`;
  }
  if (line) s += `<polyline points="${line.map((v, i) => `${L + slot * i + slot / 2},${y(v)}`).join(" ")}" fill="none" stroke="${C.line}" stroke-width="2.6" stroke-linejoin="round"/>`;
  return s + "</svg>";
}

function lineChart(points, { height = 230, label = "Line chart" } = {}) {
  if (points.length < 2) return empty("Not enough points to draw a chart yet");
  const W = 760, H = height, L = 48, R = 12, T = 12, B = 28;
  const vals = points.map((p) => p.v);
  const lo = Math.min(0, ...vals), hi = Math.max(1, ...vals) * 1.08;
  const x = (i) => L + ((W - L - R) * i) / (points.length - 1);
  const y = (v) => T + (H - T - B) * (1 - (v - lo) / (hi - lo));
  let s = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)}">`;
  for (let i = 0; i <= 4; i++) {
    const v = lo + ((hi - lo) / 4) * i;
    s += `<line x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}" stroke="${C.grid}"/><text x="${L - 6}" y="${y(v) + 4}" font-size="12" text-anchor="end" fill="${C.text}">${num(Math.round(v))}</text>`;
  }
  const path = points.map((p, i) => `${i ? "L" : "M"}${x(i)},${y(p.v)}`).join(" ");
  s += `<path d="${path} L${x(points.length - 1)},${y(lo)} L${x(0)},${y(lo)} Z" fill="${C.bar}" opacity=".12"/><path d="${path}" fill="none" stroke="${C.bar}" stroke-width="2.4" stroke-linejoin="round"/>`;
  const step = Math.ceil(points.length / 6);
  points.forEach((p, i) => { if (i % step === 0 || i === points.length - 1) s += `<text x="${x(i)}" y="${H - 8}" font-size="11.5" text-anchor="middle" fill="${C.text}">${esc(p.t)}</text>`; });
  return s + "</svg>";
}

/* ------------------------------------------------------------ sentences */
function describe(r) {
  const t = r.type_code, q = num(Math.abs(r.quantity_change)), p = `${esc(r.product_name)}`;
  const verb = (TYPE_INFO[t] || {}).verb || t;
  if (t === "REVERSAL") return `${verb} ${p} <small>undoes entry #${r.reverses_ledger_id}</small>`;
  return `${verb} <b>${q}</b> × ${p}${r.supplier_name && (t === "PURCHASE" || t === "RETURN_OUT") ? `<small>${t === "PURCHASE" ? "from" : "to"} ${esc(r.supplier_name)}</small>` : ""}${r.remarks ? `<small>“${esc(r.remarks)}”</small>` : ""}`;
}

/* ------------------------------------------------------------ pages */
const pages = {};

pages.home = async (view) => {
  const d = await api("/api/dashboard");
  const k = d.kpis, ok = Number(k.mismatches) === 0;
  const first = state.me.name.split(" ")[0];
  const hour = new Date().getHours();
  const hello = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening";
  const can = (p) => state.pages.includes(p);
  const quick = [];
  if (can("record") && state.entryTypes.includes("SALE")) quick.push(`<a class="btn" href="#record" data-type="SALE">Record a sale</a>`);
  if (can("record") && state.entryTypes.includes("PURCHASE")) quick.push(`<a class="btn" href="#record" data-type="PURCHASE">Receive stock</a>`);
  if (can("record") && state.entryTypes.includes("TRANSFER")) quick.push(`<a class="btn ghost" href="#record" data-type="TRANSFER">Move stock</a>`);
  quick.push(`<a class="btn ghost" href="#stock">Check stock</a>`);
  if (can("insights")) quick.push(`<a class="btn ghost" href="#insights">See insights</a>`);
  view.innerHTML =
    title(`${hello}, ${esc(first)}`, `You are signed in as <b>${esc(state.me.role)}</b>. ${esc(ROLE_BLURB[state.me.role])}.`) +
    `<div class="quick">${quick.join("")}</div>` +
    `<div class="grid g4">` +
    kpi("Items in stock", num(k.units), "units across all warehouses") +
    kpi("Stock value", money(k.stock_value), "at standard cost") +
    kpi("Need restocking", num(k.below_reorder), k.below_reorder > 0 ? "products at or below their reorder level" : "everything is above its reorder level", k.below_reorder > 0 ? "warn" : "good") +
    kpi("Books balanced", ok ? "Yes" : `${k.mismatches} off`, ok ? `all ${num(k.balance_pairs)} stock counts match the history` : "a stock count differs from the history", ok ? "good" : "bad") +
    `</div>
    <div class="grid g2 gap-top">
      <div class="card"><h3>Units sold per week</h3><div class="sub">The last ${d.weekly.length} weeks</div>
        ${barChart({ labels: d.weekly.map((w) => w.week_start.slice(5)), bars: d.weekly.map((w) => w.units_sold), label: "Units sold per week" })}</div>
      <div class="card"><h3>Running low</h3><div class="sub">Products at or below their reorder level</div>${table([
        { h: "Product", f: (r) => `<b>${esc(r.product_name)}</b><div class="muted">${esc(r.sku)}</div>` },
        { h: "In stock", num: true, f: (r) => num(r.total_qty) },
        { h: "Reorder at", num: true, f: (r) => num(r.reorder_level) },
        { h: "Usual supplier", f: (r) => esc(r.suggested_supplier || "none yet") },
      ], d.reorder, { noscroll: true, emptyTitle: "All stocked up", emptyText: "No product is below its reorder level." })}</div>
    </div>
    <div class="card gap-top"><h3>Latest activity</h3><div class="sub">The newest entries in the ledger</div>${table([
      { h: "What happened", f: (r) => `<span class="what">${describe({ ...r, remarks: null })}</span>` },
      { h: "Where", f: (r) => esc(r.warehouse_code) },
      { h: "Change", num: true, f: (r) => signed(r.quantity_change) },
      { h: "By", f: (r) => esc(r.username) },
      { h: "When", f: (r) => esc(ago(r.entry_time)) },
    ], d.recent, { noscroll: true })}<p class="explain" style="margin-top:10px"><a href="#history">See the full history</a></p></div>`;
  $$(".quick a[data-type]", view).forEach((a) => (a.onclick = () => { state.recordType = a.dataset.type; }));
};

pages.stock = async (view) => {
  const m = state.meta;
  view.innerHTML = title("Stock", "What you have right now, in each warehouse.") +
    help("What am I looking at?", "Each row is one product in one warehouse. The number on hand is worked out from every entry in the history, so it can always be traced back. “Reorder soon” means the stock is at or below the level set for that product.") +
    `<div class="card"><div class="filters">
       <div class="field wide"><label for="q">Search</label><input id="q" type="search" placeholder="Type a product name or code" autocomplete="off"></div>
       <div class="field"><label for="wh">Warehouse</label><select id="wh">${options(m.warehouses, "warehouse_id", (w) => `${w.warehouse_name}`, "", "All warehouses")}</select></div>
       <div class="field"><label for="low">Show</label><select id="low"><option value="">Everything</option><option value="1">Only low stock</option></select></div>
     </div><div id="out" style="margin-top:16px"></div></div>`;
  const load = async () => {
    const p = new URLSearchParams();
    if ($("#q").value) p.set("q", $("#q").value);
    if ($("#wh").value) p.set("warehouse_id", $("#wh").value);
    let { rows } = await api("/api/stock?" + p);
    if ($("#low").value) rows = rows.filter((r) => r.below_reorder);
    $("#out").innerHTML = table([
      { h: "Product", f: (r) => `<b>${esc(r.product_name)}</b><div class="muted">${esc(r.sku)} · ${esc(r.category_name)}</div>` },
      { h: "Warehouse", f: (r) => esc(r.warehouse_name) },
      { h: "On hand", num: true, f: (r) => `<b>${num(r.quantity_on_hand)}</b>` },
      { h: "Value", num: true, f: (r) => money(r.stock_value) },
      { h: "Status", f: (r) => (r.below_reorder ? badge("Reorder soon", "warn") : badge("Fine", "good")) },
      { h: "", f: (r) => `<button class="small ghost" data-p="${r.product_id}" data-w="${r.warehouse_id}">See history</button>` },
    ], rows, { emptyTitle: "No stock matches", emptyText: "Try a different name or warehouse." });
    $$("button[data-p]", view).forEach((b) => (b.onclick = () => { state.ledgerFilter = { product_id: b.dataset.p, warehouse_id: b.dataset.w }; location.hash = "#history"; }));
  };
  let timer; $("#q").oninput = () => { clearTimeout(timer); timer = setTimeout(() => load().catch(showErr), 250); };
  $("#wh").onchange = $("#low").onchange = () => load().catch(showErr);
  await load();
};

pages.history = async (view) => {
  const m = state.meta, f = state.ledgerFilter || {};
  state.ledgerFilter = null;
  const canUndo = ["Admin", "Warehouse Manager", "Purchase Officer"].includes(state.me.role);
  const typeOpts = m.types.map((t) => ({ code: t.type_code, label: (TYPE_INFO[t.type_code] || {}).verb || t.type_code }));
  view.innerHTML = title("History", "Every change ever made to stock. Entries are permanent: if one was a mistake, cancel it and a new entry will undo it.") +
    help("Why can’t I edit an entry?", "The ledger is append-only. Editing the past would make the numbers untrustworthy. Cancelling adds an opposite entry that points at the original, so you can always see what happened and who corrected it.") +
    `<div class="card"><div class="filters">
      <div class="field wide"><label for="fp">Product</label><select id="fp">${options(m.products, "product_id", productLabel, f.product_id, "All products")}</select></div>
      <div class="field"><label for="fw">Warehouse</label><select id="fw">${options(m.warehouses, "warehouse_id", "warehouse_name", f.warehouse_id, "All warehouses")}</select></div>
      <div class="field"><label for="ft">Kind of change</label><select id="ft">${options(typeOpts, "code", "label", "", "All kinds")}</select></div>
      <div class="field"><label for="fl">Show</label><select id="fl"><option value="50">Last 50</option><option value="100" selected>Last 100</option><option value="300">Last 300</option></select></div>
     </div><div id="chartbox"></div><div id="out" style="margin-top:16px"></div><div id="rmsg"></div></div>
     ${tech("The running-balance chart uses a window function, <code>SUM(quantity_change) OVER (ORDER BY entry_time, ledger_id)</code>. “Cancel” calls <code>sp_reverse_entry</code>, which appends a REVERSAL row; a trigger allows only one reversal per entry and checks it exactly cancels the original.")}`;
  const load = async () => {
    const p = new URLSearchParams({ limit: $("#fl").value });
    if ($("#fp").value) p.set("product_id", $("#fp").value);
    if ($("#fw").value) p.set("warehouse_id", $("#fw").value);
    if ($("#ft").value) p.set("type", $("#ft").value);
    const { rows } = await api("/api/ledger?" + p);
    $("#out").innerHTML = table([
      { h: "#", f: (r) => `<span class="muted">${r.ledger_id}</span>` },
      { h: "When", f: (r) => `${esc(when(r.entry_time))}<div class="muted">${esc(ago(r.entry_time))}</div>` },
      { h: "What happened", f: (r) => `<span class="what">${describe(r)}</span>${r.is_reversed ? " " + badge("Cancelled", "info") : ""}` },
      { h: "Where", f: (r) => esc(r.warehouse_code) },
      { h: "Change", num: true, f: (r) => signed(r.quantity_change) },
      { h: "By", f: (r) => esc(r.username) },
      { h: "", f: (r) => canUndo && r.type_code !== "REVERSAL" && !r.is_reversed ? `<button class="small ghost" data-id="${r.ledger_id}" data-t="${r.transfer_id || ""}">Cancel</button>` : "" },
    ], rows, { rowClass: (r) => (r.is_reversed ? "cancelled" : ""), emptyTitle: "No entries match", emptyText: "Change a filter to see more." });
    $$("button[data-id]", view).forEach((b) => (b.onclick = async () => {
      const reason = await ask({ title: `Cancel entry #${b.dataset.id}?`, confirm: "Cancel this entry", danger: true,
        text: b.dataset.t ? "This entry is part of a transfer, so <b>both sides of the transfer</b> will be cancelled. The originals stay in the history." : "A new opposite entry will be added. The original stays in the history, marked as cancelled.",
        field: { label: "Reason", value: "Entered by mistake" } });
      if (reason === null) return;
      b.disabled = true;
      try {
        const body = { reason };
        if (b.dataset.t) body.transfer_id = b.dataset.t; else body.ledger_id = b.dataset.id;
        await api("/api/reverse", { method: "POST", body });
        $("#rmsg").innerHTML = `<div class="msg ok"><b>Cancelled.</b> An opposite entry was added. Nothing was erased.</div>`;
        toast("Entry cancelled"); await load();
      } catch (e) { $("#rmsg").innerHTML = `<div class="msg err"><b>Could not cancel:</b> ${esc(e.message)}</div>`; b.disabled = false; }
    }));
    const box = $("#chartbox");
    if ($("#fp").value) {
      const q = new URLSearchParams({ product_id: $("#fp").value });
      if ($("#fw").value) q.set("warehouse_id", $("#fw").value);
      const rb = await api("/api/running-balance?" + q);
      box.innerHTML = `<h3 style="margin:18px 0 2px">Stock level over time</h3><div class="sub">Last ${rb.rows.length} of ${num(rb.total)} entries</div>` +
        lineChart(rb.rows.map((r) => ({ t: String(r.entry_time).slice(5, 10), v: Number(r.running_balance) })), { label: "Stock level over time" });
    } else box.innerHTML = "";
  };
  ["fp", "fw", "ft", "fl"].forEach((id) => ($("#" + id).onchange = () => load().catch(showErr)));
  await load();
};

pages.record = async (view) => {
  const m = state.meta, allowed = state.entryTypes;
  if (!allowed.length) { view.innerHTML = title("Record a change") + `<div class="msg info">The ${esc(state.me.role)} role can look but not change stock.</div>`; return; }
  if (!allowed.includes(state.recordType)) state.recordType = allowed[0];
  const prodOpts = options(m.products, "product_id", productLabel);
  view.innerHTML = title("Record a change", "Pick what happened, then fill in a few details. MySQL checks the numbers before anything is saved.") +
    `<div class="tasks" id="tasks" role="group" aria-label="What happened?">${allowed.map((t) => `<button type="button" class="task" data-t="${t}" aria-pressed="${t === state.recordType}"><strong>${TYPE_INFO[t].title}</strong><span>${TYPE_INFO[t].text}</span></button>`).join("")}</div>
     <div class="card" id="formcard"></div>`;
  const draw = () => {
    const t = state.recordType, isT = t === "TRANSFER";
    $$("#tasks .task", view).forEach((b) => b.setAttribute("aria-pressed", b.dataset.t === t));
    const sup = ["PURCHASE", "RETURN_OUT"].includes(t);
    $("#formcard").innerHTML = `<h3>${TYPE_INFO[t].title}</h3><div class="sub">${TYPE_INFO[t].text}</div>
      <form id="f" novalidate><div class="formgrid">
        <div class="field full"><label for="fprod">Product</label><select id="fprod">${prodOpts}</select></div>
        ${isT ? `<div class="field"><label for="ffrom">From warehouse</label><select id="ffrom">${options(m.warehouses, "warehouse_id", "warehouse_name", m.warehouses[0].warehouse_id)}</select></div>
                 <div class="field"><label for="fto">To warehouse</label><select id="fto">${options(m.warehouses, "warehouse_id", "warehouse_name", m.warehouses[1].warehouse_id)}</select></div>`
              : `<div class="field"><label for="fwh">Warehouse</label><select id="fwh">${options(m.warehouses, "warehouse_id", "warehouse_name")}</select></div>`}
        <div class="field"><label for="fqty">${t === "ADJUSTMENT" ? "Change in quantity" : "How many"}</label><input id="fqty" type="number" inputmode="numeric" step="1" ${t === "ADJUSTMENT" ? "" : 'min="1"'} value="${t === "ADJUSTMENT" ? "-1" : "1"}">
          ${t === "ADJUSTMENT" ? "<small>Use + to add and − to remove.</small>" : ""}</div>
        ${sup ? `<div class="field full"><label for="fsup">Supplier</label><select id="fsup">${options(m.suppliers, "supplier_id", "supplier_name", "", "Not sure")}</select></div>` : ""}
        <div class="full"><div class="preview" id="preview" aria-live="polite">Pick a product to see the effect.</div></div>
        <details class="full"><summary class="muted" style="cursor:pointer">More details (optional)</summary>
          <div class="formgrid" style="margin-top:12px"><div class="field"><label for="fref">Reference</label><input id="fref" maxlength="40" placeholder="Order or invoice number"></div>
          ${t === "PURCHASE" ? `<div class="field"><label for="fcost">Cost per unit</label><input id="fcost" type="number" min="0" step="0.01" placeholder="Leave empty to use the standard cost"></div>` : ""}
          <div class="field full"><label for="frem">Note</label><input id="frem" maxlength="200" placeholder="Anything worth remembering"></div></div></details>
        <div class="full"><button type="submit" id="fsubmit" class="wide-btn">${isT ? "Move stock" : "Save to ledger"}</button></div>
      </div></form><div id="fmsg"></div>
      ${tech(isT ? "<code>sp_transfer_stock</code> opens a transaction, locks both balance rows with <code>SELECT … FOR UPDATE</code> (always in warehouse order, so two opposite transfers cannot deadlock), writes the transfer and two linked ledger rows, then commits. If anything fails, nothing is saved." : "<code>sp_record_movement</code> checks your role, locks the balance row with <code>SELECT … FOR UPDATE</code>, refuses the entry if stock would go below zero, appends one ledger row and commits. Triggers then validate the row and update the summary tables inside the same transaction.")}`;
    const info = TYPE_INFO[t];
    const sign = () => { const q = Number($("#fqty").value) || 0; return t === "ADJUSTMENT" ? q : info.sign * Math.abs(q); };
    let seq = 0;
    const refresh = async () => {
      const my = ++seq, prod = $("#fprod").value, q = Math.abs(Number($("#fqty").value) || 0), box = $("#preview");
      try {
        if (isT) {
          const a = $("#ffrom").value, b = $("#fto").value;
          if (a === b) { box.className = "preview low"; box.innerHTML = `<span class="why">Choose two different warehouses.</span>`; return; }
          const [x, y] = await Promise.all([api(`/api/balance?product_id=${prod}&warehouse_id=${a}`), api(`/api/balance?product_id=${prod}&warehouse_id=${b}`)]);
          if (my !== seq) return;
          const na = x.quantity - q, nb = y.quantity + q, wn = (id) => m.warehouses.find((w) => String(w.warehouse_id) === String(id)).warehouse_code;
          box.className = "preview" + (na < 0 ? " low" : "");
          box.innerHTML = `<span>${esc(wn(a))}</span><span class="n">${num(x.quantity)}</span><span class="arrow">→</span><span class="n after">${num(na)}</span><span class="arrow">|</span><span>${esc(wn(b))}</span><span class="n">${num(y.quantity)}</span><span class="arrow">→</span><span class="n after">${num(nb)}</span>${na < 0 ? `<span class="why">Not enough stock in ${esc(wn(a))}: it only has ${num(x.quantity)}.</span>` : ""}`;
        } else {
          const w = $("#fwh").value, x = await api(`/api/balance?product_id=${prod}&warehouse_id=${w}`);
          if (my !== seq) return;
          const after = x.quantity + sign();
          box.className = "preview" + (after < 0 ? " low" : "");
          box.innerHTML = `<span>Now</span><span class="n">${num(x.quantity)}</span><span class="arrow">→</span><span>After</span><span class="n after">${num(after)}</span>${after < 0 ? `<span class="why">Not enough stock: only ${num(x.quantity)} on hand.</span>` : ""}`;
        }
      } catch (e) { if (my === seq) { box.className = "preview"; box.textContent = ""; } }
    };
    ["#fprod", "#fwh", "#ffrom", "#fto", "#fqty"].forEach((s) => { const el = $(s, view); if (el) el.oninput = el.onchange = refresh; });
    refresh();
    $("#f").onsubmit = async (ev) => {
      ev.preventDefault();
      const btn = $("#fsubmit"), msg = $("#fmsg"), qty = Number($("#fqty").value);
      if (!Number.isInteger(qty) || qty === 0) { msg.innerHTML = `<div class="msg err">Enter a whole number that is not zero.</div>`; return; }
      btn.disabled = true; msg.innerHTML = "";
      try {
        let r, done;
        if (isT) {
          r = await api("/api/transfer", { method: "POST", body: { product_id: $("#fprod").value, from_wh: $("#ffrom").value, to_wh: $("#fto").value, quantity: qty, remarks: $("#frem").value } });
          done = `${num(qty)} units moved. Both sides were saved together, or not at all.`;
        } else {
          r = await api("/api/movement", { method: "POST", body: { type: t, product_id: $("#fprod").value, warehouse_id: $("#fwh").value, quantity: qty, unit_cost: $("#fcost") ? $("#fcost").value : "", supplier_id: $("#fsup") ? $("#fsup").value : "", reference: $("#fref").value, remarks: $("#frem").value } });
          done = `New stock level here: <b>${num(r.new_balance)}</b>.`;
        }
        $("#formcard").innerHTML = `<div class="success"><div class="tick"><svg viewBox="0 0 24 24" fill="none" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></div>
          <h3>Saved to the ledger</h3><p class="explain">${done}</p>
          <div class="filters" style="justify-content:center;margin-top:8px"><button id="again">Record another</button><a href="#history"><button type="button" class="ghost">See history</button></a></div></div>`;
        $("#again").onclick = draw; toast("Saved");
      } catch (e) { msg.innerHTML = `<div class="msg err"><b>Not saved.</b> ${esc(e.message)}</div>`; btn.disabled = false; }
    };
  };
  $$("#tasks .task", view).forEach((b) => (b.onclick = () => { state.recordType = b.dataset.t; draw(); }));
  draw();
};

pages.insights = async (view) => {
  const m = state.meta, canAsOf = ["Admin", "Analyst"].includes(state.me.role);
  const tabs = { abc: "Best sellers", forecast: "Demand forecast", dead: "Slow movers", ...(canAsOf ? { asof: "Time machine" } : {}) };
  view.innerHTML = title("Insights", "Plain answers from the ledger: what sells, what will sell next, and what is sitting on the shelf.") +
    `<div class="tabs" id="atabs" role="tablist">${Object.entries(tabs).map(([k, v]) => `<button data-k="${k}" role="tab">${v}</button>`).join("")}</div><div id="abody"></div>`;
  const show = async (k) => {
    $$("#atabs button", view).forEach((b) => { b.classList.toggle("on", b.dataset.k === k); b.setAttribute("aria-selected", b.dataset.k === k); });
    const box = $("#abody"); box.innerHTML = skeleton(1);
    try { await analytics[k](box, m); } catch (e) { box.innerHTML = `<div class="msg err">${esc(e.message)}</div>`; }
  };
  $$("#atabs button", view).forEach((b) => (b.onclick = () => show(b.dataset.k)));
  await show("abc");
};

const analytics = {
  async abc(box) {
    const { rows } = await api("/api/analytics/abc");
    const cnt = { A: 0, B: 0, C: 0 }; rows.forEach((r) => cnt[r.abc_class]++);
    const label = { A: "Top sellers", B: "Steady", C: "Slow" };
    box.innerHTML = `<div class="card"><h3>Which products matter most?</h3>
      <p class="explain">Products ranked by sales value over the last year. <span class="badge A">A</span> ${cnt.A} products bring in the first 80% of sales. <span class="badge B">B</span> ${cnt.B} bring the next 15%. <span class="badge C">C</span> ${cnt.C} share the last 5%. Keep A products well stocked.</p>
      <div style="margin-top:12px">${table([
        { h: "Group", f: (r) => `<span class="badge ${r.abc_class}">${r.abc_class} · ${label[r.abc_class]}</span>` },
        { h: "Product", f: (r) => `<b>${esc(r.product_name)}</b><div class="muted">${esc(r.sku)}</div>` },
        { h: "Units sold", num: true, f: (r) => num(r.units_sold) },
        { h: "Sales value", num: true, f: (r) => money(r.value_sold) },
        { h: "Share of sales", num: true, f: (r) => r.share_pct + "%" },
        { h: "Running total", f: (r) => `<div style="display:flex;gap:8px;align-items:center"><div class="bar" style="flex:1"><i style="width:${r.cumulative_pct}%"></i></div><span class="num">${r.cumulative_pct}%</span></div>` },
      ], rows)}</div>${tech("The running total is <code>SUM(value_sold) OVER (ORDER BY value_sold DESC)</code> divided by the grand total. A is below 80%, B below 95%, C the rest. See view <code>v_abc_analysis</code>.")}</div>`;
  },
  async forecast(box, m) {
    box.innerHTML = `<div class="card"><div class="filters"><div class="field wide"><label for="fcp">Product</label><select id="fcp">${options(m.products, "product_id", productLabel, m.products[0].product_id)}</select></div></div><div id="fcout" style="margin-top:16px"></div></div>`;
    const go = async () => {
      const d = await api("/api/analytics/forecast?product_id=" + $("#fcp").value);
      const s = d.summary || {};
      const labels = d.series.map((r) => String(r.week_start).slice(5));
      $("#fcout").innerHTML = `<div class="grid g3">
        ${kpi("Expected next week", num(s.ma4_forecast), "units, from the last 4 weeks")}
        ${kpi("If the trend continues", num(s.trend_forecast), "units, from the 12-week trend")}
        ${kpi("Stock will last", s.weeks_of_cover == null ? "no sales yet" : num(s.weeks_of_cover) + " weeks", `${num(s.current_stock)} units on hand`, s.weeks_of_cover != null && s.weeks_of_cover < 2 ? "bad" : "")}
        </div><h3 style="margin:20px 0 2px">Units sold each week</h3>
        ${barChart({ labels, bars: d.series.map((r) => Number(r.units_sold)), line: d.series.map((r) => Number(r.moving_avg_4w)), forecast: { value: Number(s.ma4_forecast || 0), label: "next" }, label: "Weekly sales with moving average and forecast" })}
        <div class="legend"><span><i style="background:${C.bar}"></i>Units sold</span><span><i style="background:${C.line}"></i>4-week average</span><span><i style="border:2px dashed ${C.line};background:#fff"></i>Expected next week</span></div>
        ${tech("<code>sp_forecast</code> builds a 12-week calendar with a recursive CTE so empty weeks count as zero, then uses <code>AVG(…) OVER (ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)</code> for the moving average and the least-squares formula from <code>SUM(x)</code>, <code>SUM(y)</code>, <code>SUM(x*y)</code>, <code>SUM(x*x)</code> for the trend. It is a simple estimate, not machine learning.")}`;
    };
    $("#fcp").onchange = () => go().catch(showErr); await go();
  },
  async dead(box) {
    box.innerHTML = `<div class="card"><h3>What is not selling?</h3><p class="explain">Products that are sitting in the warehouse and have not been sold for a while. That money is tied up.</p>
      <div class="filters" style="margin-top:12px"><div class="field"><label for="dd">No sale for at least (days)</label><input id="dd" type="number" value="90" min="1"></div><button id="ddgo">Find slow movers</button></div><div id="ddout" style="margin-top:16px"></div></div>`;
    const go = async () => {
      const { rows } = await api("/api/analytics/dead-stock?days=" + $("#dd").value);
      const tied = rows.reduce((a, r) => a + Number(r.capital_tied_up), 0);
      $("#ddout").innerHTML = (rows.length ? `<div class="msg info" style="margin-top:0">${rows.length} product${rows.length > 1 ? "s hold" : " holds"} <b>${money(tied)}</b> of stock that has not sold in ${esc($("#dd").value)} days.</div><div style="height:12px"></div>` : "") +
        table([
          { h: "Product", f: (r) => `<b>${esc(r.product_name)}</b><div class="muted">${esc(r.sku)}</div>` },
          { h: "On hand", num: true, f: (r) => num(r.quantity_on_hand) },
          { h: "Last sale", f: (r) => (r.last_sale ? esc(when(r.last_sale)) : badge("never sold", "bad")) },
          { h: "Days idle", num: true, f: (r) => (r.days_since_last_sale == null ? "–" : num(r.days_since_last_sale)) },
          { h: "Money tied up", num: true, f: (r) => money(r.capital_tied_up) },
        ], rows, { emptyTitle: "Nothing is stuck", emptyText: "Every product has sold recently." });
    };
    $("#ddgo").onclick = () => go().catch(showErr); await go();
  },
  async asof(box) {
    const off = new Date().getTimezoneOffset() * 60000;
    const today = new Date(Date.now() - off).toISOString().slice(0, 10), past = new Date(Date.now() - 90 * 86400000 - off).toISOString().slice(0, 10);
    box.innerHTML = `<div class="card"><h3>What did we have on a past date?</h3><p class="explain">Because nothing is ever overwritten, the system can show stock exactly as it stood at the end of any earlier day.</p>
      <div class="filters" style="margin-top:12px"><div class="field"><label for="ad">Stock at the end of</label><input id="ad" type="date" value="${past}" max="${today}"></div><button id="adgo">Show stock</button></div><div id="adout" style="margin-top:16px"></div>
      ${tech("<code>sp_stock_as_of</code> adds up every ledger entry with <code>entry_time</code> up to that moment. Date partitions after that date are skipped (partition pruning).")}</div>`;
    const go = async () => {
      const { rows } = await api("/api/analytics/as-of?date=" + $("#ad").value);
      const total = rows.reduce((a, r) => a + Number(r.quantity), 0), val = rows.reduce((a, r) => a + Number(r.value_at_cost), 0);
      $("#adout").innerHTML = `<div class="msg info" style="margin-top:0"><b>${num(total)}</b> units worth <b>${money(val)}</b> at cost.</div><div style="height:12px"></div>` + table([
        { h: "Product", f: (r) => `<b>${esc(r.product_name)}</b><div class="muted">${esc(r.sku)}</div>` }, { h: "Warehouse", f: (r) => esc(r.warehouse_code) },
        { h: "Quantity", num: true, f: (r) => num(r.quantity) }, { h: "Value at cost", num: true, f: (r) => money(r.value_at_cost) },
      ], rows, { emptyTitle: "No stock on that date" });
    };
    $("#adgo").onclick = () => go().catch(showErr); await go();
  },
};

pages.safety = async (view) => {
  const isAdmin = state.me.role === "Admin";
  const load = async () => {
    const d = await api("/api/integrity");
    $("#recbox").innerHTML = d.mismatches.length
      ? `<div class="msg err"><b>${d.mismatches.length} stock count${d.mismatches.length > 1 ? "s do" : " does"} not match the history.</b></div><div style="height:12px"></div>` + table([
        { h: "Product", f: (r) => esc(r.sku) }, { h: "Warehouse", f: (r) => esc(r.warehouse_code) },
        { h: "Stock count says", num: true, f: (r) => num(r.balance_table) }, { h: "History says", num: true, f: (r) => num(r.ledger_sum) }, { h: "Gap", num: true, f: (r) => signed(r.difference) },
      ], d.mismatches, { noscroll: true })
      : `<div class="msg ok"><b>All ${num(d.pairs)} stock counts match the history.</b> Nothing is off.</div>`;
  };
  view.innerHTML = title("Safety checks", "Why you can trust the numbers: history cannot be rewritten, and every total can be checked against it.") +
    `<div class="grid ${isAdmin ? "g2" : ""}">
      ${isAdmin ? `<div class="card"><h3>1. Try to tamper with history</h3>
        <p class="explain">These buttons ask MySQL to change or delete the oldest entry. The request runs with administrator rights, and the database still refuses.</p>
        <div class="filters" style="margin-top:14px"><button class="danger" data-t="UPDATE">Try to change an entry</button><button class="danger" data-t="DELETE">Try to delete an entry</button></div><div id="tamper"></div>
        ${tech("Triggers <code>trg_ledger_no_update</code> and <code>trg_ledger_no_delete</code> run <code>SIGNAL SQLSTATE '45000'</code> before any change reaches the table.")}</div>` : ""}
      <div class="card"><h3>${isAdmin ? "2. " : ""}Check the stock counts</h3>
        <p class="explain">The stock count in each warehouse is a quick copy. The history is the truth. This check adds up the history and compares it with every count.</p>
        ${isAdmin ? `<div class="filters" style="margin:14px 0"><button class="ghost" id="corrupt">Damage one count (demo)</button><button id="rebuild">Repair from history</button></div>` : `<div style="height:12px"></div>`}<div id="recbox">${skeleton(1)}</div>
        ${tech("View <code>v_reconciliation</code> compares <code>stock_balance</code> with <code>SUM(quantity_change)</code> from the ledger. <code>sp_rebuild_summaries</code> recomputes both summary tables from the ledger.")}</div>
    </div>`;
  if (isAdmin) {
    $$("button[data-t]", view).forEach((b) => (b.onclick = async () => {
      try { const r = await api("/api/integrity/tamper", { method: "POST", body: { action: b.dataset.t } }); $("#tamper").innerHTML = `<div class="msg err"><b>Unexpected:</b> ${esc(r.message)}</div>`; }
      catch (e) { $("#tamper").innerHTML = `<div class="msg ok"><b>Blocked by MySQL.</b> ${esc(e.message)}</div>`; }
    }));
    $("#corrupt").onclick = async () => { try { await api("/api/integrity/corrupt", { method: "POST", body: {} }); toast("One count was damaged"); await load(); } catch (e) { showErr(e); } };
    $("#rebuild").onclick = async () => { try { await api("/api/integrity/rebuild", { method: "POST", body: {} }); toast("Counts repaired from history"); await load(); } catch (e) { showErr(e); } };
  }
  await load();
};

function partLabel(txt) {
  if (!txt || txt.startsWith("all")) return esc(txt || "all");
  const list = txt.split(",");
  return list.length > 3 ? `<span title="${esc(txt)}">${list.length} of 10 partitions</span>` : `${list.length} of 10<div class="muted mono">${esc(txt)}</div>`;
}

pages.speed = async (view) => {
  view.innerHTML = title("Speed lab", "The same question asked of three copies of the ledger: plain, indexed, and indexed with date partitions.",
    `<div class="filters"><button class="ghost" id="lab">Rebuild copies</button><button id="run">Run test</button></div>`) +
    help("What am I looking at?", "A database can find a row by reading everything, or by jumping straight to it using an index. “Rows examined” is how much MySQL had to read, taken from its own EXPLAIN plan. Fewer is faster. Time is the median of 5 runs.") +
    `<div id="pout"><div class="card"><p class="muted">Press <b>Run test</b> to compare the three designs.</p></div></div>`;
  $("#lab").onclick = async () => { $("#lab").disabled = true; try { await api("/api/perf/rebuild", { method: "POST", body: {} }); toast("Copies rebuilt"); } catch (e) { showErr(e); } $("#lab").disabled = false; };
  $("#run").onclick = async () => {
    $("#run").disabled = true; $("#pout").innerHTML = skeleton(2);
    try {
      const d = await api("/api/perf");
      $("#pout").innerHTML = `<div class="stack">` + d.tests.map((t) => {
        const maxMs = Math.max(0.01, ...t.results.map((r) => r.median_ms));
        return `<div class="card"><h3>${esc(t.title)}</h3><div class="sub">${esc(t.note)}</div><pre class="mono" style="margin:0 0 12px;color:#4a3d31;white-space:pre-wrap">${esc(t.sql)}</pre>` + table([
          { h: "Design", f: (r) => `<b>${esc(r.label)}</b>` },
          { h: "Partitions read", f: (r) => partLabel(r.partitions) },
          { h: "How rows were found", f: (r) => esc(r.access) },
          { h: "Index used", f: (r) => esc(r.key) },
          { h: "Rows examined", num: true, f: (r) => num(r.rows_examined) },
          { h: "Median time", f: (r) => `<div style="display:flex;gap:8px;align-items:center"><div class="bar" style="flex:1"><i style="width:${(r.median_ms / maxMs) * 100}%"></i></div><span class="num">${r.median_ms} ms</span></div>` },
        ], t.results, { noscroll: true }) + `</div>`;
      }).join("") + `</div>`;
    } catch (e) { $("#pout").innerHTML = `<div class="msg err">${esc(e.message)}</div>`; }
    $("#run").disabled = false;
  };
};

pages.admin = async (view) => {
  const roles = Object.keys(ROLE_BLURB);
  view.innerHTML = title("Admin", "Manage who can open which role, and see who has signed in.") +
    `<div class="grid g2">
      <div class="card"><h3>Change a passkey</h3><div class="sub">The old passkey stops working immediately. Use at least 6 characters.</div>
        <form id="pf" novalidate class="stack" style="gap:14px">
          <div class="field"><label for="prole">Role</label><select id="prole">${roles.map((r) => `<option>${esc(r)}</option>`).join("")}</select></div>
          <div class="field"><label for="pnew">New passkey</label><input id="pnew" type="password" autocomplete="new-password" spellcheck="false"></div>
          <div class="field"><label for="pnew2">Type it again</label><input id="pnew2" type="password" autocomplete="new-password" spellcheck="false"></div>
          <button type="submit">Save passkey</button></form><div id="pmsg"></div>
        ${tech("Passkeys are stored as <code>SHA2(salt + passkey)</code> in a separate schema, <code>stock_ledger_auth</code>. The dashboard’s MySQL account has no privilege on that schema, so it can only call <code>sp_login</code> and <code>sp_set_passkey</code>.")}</div>
      <div class="card"><h3>Recent sign-ins</h3><div class="sub">The last 20 attempts, successful or not</div><div id="logins">${skeleton(1)}</div></div>
    </div>`;
  const loadLogins = async () => {
    const { rows } = await api("/api/admin/logins");
    $("#logins").innerHTML = table([
      { h: "When", f: (r) => esc(when(r.attempt_at)) }, { h: "Role", f: (r) => esc(r.role_name) },
      { h: "Result", f: (r) => (r.succeeded ? badge("Signed in", "good") : badge("Wrong passkey", "bad")) },
    ], rows, { emptyTitle: "No sign-ins yet" });
  };
  $("#pf").onsubmit = async (ev) => {
    ev.preventDefault();
    const a = $("#pnew").value, b = $("#pnew2").value, msg = $("#pmsg");
    if (a.length < 6) { msg.innerHTML = `<div class="msg err">A passkey needs at least 6 characters.</div>`; return; }
    if (a !== b) { msg.innerHTML = `<div class="msg err">The two passkeys do not match.</div>`; return; }
    try { await api("/api/admin/passkey", { method: "POST", body: { role: $("#prole").value, passkey: a } }); msg.innerHTML = `<div class="msg ok"><b>Saved.</b> The new passkey for ${esc($("#prole").value)} works now.</div>`; $("#pnew").value = $("#pnew2").value = ""; }
    catch (e) { msg.innerHTML = `<div class="msg err">${esc(e.message)}</div>`; }
  };
  await loadLogins();
};

/* ------------------------------------------------------------ sign-in screen */
let chosenRole = null;
async function showLogin(note) {
  state.me = null;
  $("#app").hidden = true; $("#login").hidden = false; document.title = "Sign in · Stock Ledger";
  $("#passBox").hidden = true; $("#loginErr").hidden = true; $("#passkey").value = ""; chosenRole = null;
  $("#loginHint").textContent = "Step 1. Choose your role.";
  const off = $("#loginOffline");
  try {
    await api("/api/health");
    const { roles } = await api("/api/roles");
    off.hidden = !note; off.textContent = note || "";
    $("#roleGrid").innerHTML = roles.map((r) => `<button type="button" class="role-btn" role="radio" aria-checked="false" data-r="${esc(r.role)}"><strong>${esc(r.role)}</strong><span>${esc(ROLE_BLURB[r.role] || "")}</span></button>`).join("");
    $$("#roleGrid .role-btn").forEach((b) => (b.onclick = () => pickRole(b.dataset.r)));
  } catch (e) {
    $("#roleGrid").innerHTML = "";
    off.hidden = false; off.textContent = "Cannot reach MySQL: " + e.message + " Check that MySQL is running and setup_all.sql has been run (see README).";
  }
}
function pickRole(r) {
  chosenRole = r;
  $$("#roleGrid .role-btn").forEach((b) => b.setAttribute("aria-checked", b.dataset.r === r));
  $("#passRole").textContent = r; $("#passBox").hidden = false; $("#loginErr").hidden = true;
  $("#loginHint").textContent = "Step 2. Enter the passkey for this role.";
  $("#passkey").focus();
}
$("#showPass").onclick = (e) => {
  const i = $("#passkey"), show = i.type === "password";
  i.type = show ? "text" : "password"; e.target.textContent = show ? "Hide" : "Show"; e.target.setAttribute("aria-pressed", show);
};
$("#loginForm").onsubmit = async (ev) => {
  ev.preventDefault();
  const err = $("#loginErr"), btn = $("#loginBtn");
  if (!chosenRole) { err.hidden = false; err.textContent = "Choose a role first."; return; }
  if (!$("#passkey").value.trim()) { err.hidden = false; err.textContent = "Enter the passkey."; $("#passkey").focus(); return; }
  btn.disabled = true; err.hidden = true;
  try {
    const r = await api("/api/login", { method: "POST", body: { role: chosenRole, passkey: $("#passkey").value } });
    await enter(r);
  } catch (e) { err.hidden = false; err.textContent = e.message; $("#passkey").select(); }
  btn.disabled = false;
};

/* ------------------------------------------------------------ shell */
async function enter(r) {
  state.me = r.me; state.pages = r.pages; state.entryTypes = r.entry_types;
  state.meta = await api("/api/meta");
  $("#login").hidden = true; $("#app").hidden = false;
  $("#meName").textContent = r.me.name.replace(/\s*\(.*\)$/, ""); $("#meRole").textContent = r.me.role;
  $("#nav").innerHTML = NAV.filter((n) => r.pages.includes(n.id)).map((n) => `<a href="#${n.id}" data-page="${n.id}"><span>${n.label}</span><small>${n.hint}</small></a>`).join("");
  $$("#nav a").forEach((a) => (a.onclick = () => closeMenu()));
  location.hash = ""; await route(false);
}
function closeMenu() { $("#nav").classList.remove("open"); $("#menuBtn").setAttribute("aria-expanded", "false"); }
$("#menuBtn").onclick = () => { const o = $("#nav").classList.toggle("open"); $("#menuBtn").setAttribute("aria-expanded", o); };
$("#logout").onclick = async () => { try { await api("/api/logout", { method: "POST", body: {} }); } catch (e) { /* signing out anyway */ } location.hash = ""; await showLogin(); };

let routing = 0;
async function route(moveFocus = true) {
  if (!state.me) return;
  let page = (location.hash || "#home").slice(1);
  if (!pages[page] || !state.pages.includes(page)) page = "home";
  const meta = NAV.find((n) => n.id === page), my = ++routing;
  $$("#nav a").forEach((a) => { const on = a.dataset.page === page; a.classList.toggle("active", on); if (on) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
  document.title = `${meta.label} · Stock Ledger`;
  const view = $("#view");
  view.innerHTML = skeleton(3);
  try { await pages[page](view); }
  catch (e) { if (my === routing) view.innerHTML = `<div class="msg err"><b>Something went wrong:</b> ${esc(e.message)}</div>`; }
  if (moveFocus) { view.focus({ preventScroll: true }); window.scrollTo(0, 0); }
}
window.addEventListener("hashchange", () => route());

async function start() {
  try {
    const h = await api("/api/health");
    $("#dbpill").textContent = `MySQL ${h.version.split("-")[0]}`;
    const r = await api("/api/me");
    if (r.me) { await enter(r); return; }
  } catch (e) { /* fall through to the sign-in screen, which explains the problem */ }
  await showLogin();
}
start();
