// Snoredle-portaal · gewone JavaScript, geen bouwstap.
// Gegevens komen uit Supabase; elke gebruiker ziet enkel zijn eigen nachten (Row Level Security).

const cfg = window.SNOREDLE_CONFIG || {};
const configured = cfg.supabaseUrl && !cfg.supabaseUrl.includes("YOUR-PROJECT");
const sb = configured ? window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
}) : null;

// ---------- Huisstijl en vertalingen ----------
const C = {
  amber: "#FFB859", maan: "#F4F1EA", muted: "#A9B0CC", lijn: "rgba(255,255,255,.08)", mid: "#141B3D",
  licht: "#FAD966", luid: "#FF8C40", episch: "#F2404D",
};
const INTENSITY = { 1: ["Licht", C.licht], 2: ["Luid", C.luid], 3: ["Episch", C.episch], 0: ["Stil", "#888"] };
const POS = {
  back: ["Rug", "#FF616B"], left: ["Linkerzij", "#4DD973"], right: ["Rechterzij", "#528CFF"],
  stomach: ["Buik", "#BF66F2"], stomachLeft: ["Buik (linkerwang)", "#BF66F2"], stomachRight: ["Buik (rechterwang)", "#FFD140"],
  upright: ["Rechtop", "#8E93A8"], unknown: ["Onbekend", "#4A5070"],
};
const FACTORS = {
  alcohol: ["Alcohol", "🍷"], lateMeal: ["Laat gegeten", "🍝"], cold: ["Verkouden", "🤧"], allergy: ["Allergie / hooikoorts", "🌼"],
  tired: ["Erg moe", "🥱"], sleepingPill: ["Slaapmiddel", "💊"], smoking: ["Gerookt", "🚬"], caffeine: ["Cafeïne", "☕️"],
  sport: ["Gesport", "🏃"], stress: ["Stress", "😣"], newPillow: ["Ander kussen", "🛏️"], sharedBed: ["Partner in bed", "👫"],
  menstruation: ["Menstruatie", "🩸"], heatwave: ["Warme nacht", "🌡️"],
};
const REMEDIES = {
  sideSleeping: "Op de zij slapen", watchNudge: "Tikje via watch", nasalStrip: "Neuspleister", nasalSpray: "Neusspray",
  mouthTape: "Mondtape", mandibularDevice: "Snurkbeugel (MRA)", chinStrap: "Kinband", raisedHead: "Hoofdeinde hoger",
  cpap: "CPAP", throatExercises: "Keeloefeningen", noAlcohol: "Geen alcohol", humidifier: "Luchtbevochtiger",
};
const STAGES = { 0: ["Wakker", "#FF9F45"], 1: ["REM", "#5AD1F0"], 2: ["Kern", "#3F7BF5"], 5: ["Kern", "#3F7BF5"], 3: ["Diep", "#7466F0"], 4: ["In bed", "#555"] };
const SOUNDS = { talking: ["Praten in je slaap", "💬"], cough: ["Hoesten", "😮‍💨"], sneeze: ["Niezen", "🤧"], laughter: ["Lachen", "😄"], gasp: ["Naar adem happen", "😮"] };
const MOODS = ["😫", "🙁", "😐", "🙂", "😄"];

const nl = "nl-BE";
const fmtTime = (d) => new Date(d).toLocaleTimeString(nl, { hour: "2-digit", minute: "2-digit" });
const fmtDate = (d, o = { weekday: "short", day: "numeric", month: "short" }) => new Date(d).toLocaleDateString(nl, o);
const mins = (m) => (m >= 60 ? `${Math.floor(m / 60)} u ${String(Math.round(m % 60)).padStart(2, "0")}` : `${Math.round(m)} min`);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const scoreLabel = (s) => (s < 10 ? "Rustig" : s < 25 ? "Matig" : s < 50 ? "Veel" : "Zeer veel");
const scoreColor = (s) => (s < 10 ? "#4DD973" : s < 25 ? C.licht : s < 50 ? C.luid : C.episch);
const avg = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0);
const $ = (sel, el = document) => el.querySelector(sel);

Chart.defaults.color = C.muted;
Chart.defaults.font.family = '-apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, sans-serif';
Chart.defaults.borderColor = C.lijn;
Chart.defaults.plugins.legend.display = false;
Chart.defaults.maintainAspectRatio = false;
Chart.defaults.animation.duration = 350;
const charts = [];
function chart(canvas, config) { const c = new Chart(canvas, config); charts.push(c); return c; }
function clearCharts() { while (charts.length) charts.pop().destroy(); }

// ---------- Gegevens ----------
let cache = null;           // lijst van nachten (zonder detail)
async function nights(force = false) {
  if (cache && !force) return cache;
  const { data, error } = await sb.from("nights").select("id,start_at,end_at,summary,updated_at").order("start_at", { ascending: false }).limit(1000);
  if (error) throw error;
  cache = data.map((n) => ({ ...n, s: n.summary || {}, start: new Date(n.start_at), end: n.end_at ? new Date(n.end_at) : null }));
  return cache;
}
async function nightDetail(id) {
  const { data, error } = await sb.from("nights").select("*").eq("id", id).single();
  if (error) throw error;
  return { ...data, s: data.summary || {}, d: data.detail || {}, start: new Date(data.start_at), end: data.end_at ? new Date(data.end_at) : new Date() };
}

// ---------- Router ----------
const app = $("#app");
const routes = { "": viewDash, nachten: viewNights, nacht: viewNight, inzichten: viewInsights, account: viewAccount, privacy: viewPrivacy, login: viewLogin };
async function route() {
  clearCharts();
  const [name, arg] = location.hash.replace(/^#\/?/, "").split("/");
  document.querySelectorAll("[data-nav]").forEach((a) => a.classList.toggle("on",
    (a.dataset.nav === "dash" && name === "") || (a.dataset.nav === "nights" && (name === "nachten" || name === "nacht")) ||
    (a.dataset.nav === "insights" && name === "inzichten") || (a.dataset.nav === "account" && name === "account")));
  if (!configured) { app.innerHTML = `<div class="center"><div class="notice">Het portaal wordt nog ingesteld. Kom binnenkort terug.</div></div>`; return; }
  const { data: { session } } = await sb.auth.getSession();
  $("#top").hidden = !session;
  if (!session && name !== "privacy") return viewLogin();
  if (session && name === "login") { location.hash = "#/"; return; }
  app.innerHTML = `<div class="loading">Laden…</div>`;
  try { await (routes[name] || viewDash)(arg); window.scrollTo(0, 0); }
  catch (e) { console.error(e); app.innerHTML = `<div class="card err">Er ging iets mis: ${esc(e.message || e)}</div>`; }
}
window.addEventListener("hashchange", route);
if (sb) sb.auth.onAuthStateChange((ev) => { if (ev === "SIGNED_IN" || ev === "SIGNED_OUT") { cache = null; route(); } });

// ---------- Aanmelden ----------
function viewLogin() {
  $("#top").hidden = true;
  app.innerHTML = `
  <div class="center">
    <svg class="hero-moon" viewBox="0 0 100 100" aria-hidden="true"><path d="M40.43 22.21A30 30 0 1 0 72.89 60.08A25 25 0 0 1 40.43 22.21Z" fill="#FFB859"/><path d="M64.6 28.3A10 10 0 0 1 72.0 38.9" fill="none" stroke="#FFB859" stroke-width="4.2" stroke-linecap="round"/><path d="M66.4 21.6A17 17 0 0 1 78.9 39.5" fill="none" stroke="#FFB859" stroke-width="4.2" stroke-linecap="round" opacity=".6"/><path d="M68.2 14.8A24 24 0 0 1 85.9 40.1" fill="none" stroke="#FFB859" stroke-width="4.2" stroke-linecap="round" opacity=".3"/></svg>
    <h1 class="wordmark" style="font-size:44px">snore<em>dle</em></h1>
    <p class="sub">Al je nachten op een groot scherm.</p>
    <form class="card stack" id="f">
      <label class="small muted" for="mail">E-mailadres (hetzelfde als in de app)</label>
      <input id="mail" type="email" autocomplete="email" required placeholder="naam@voorbeeld.be">
      <div id="codebox" hidden class="stack">
        <label class="small muted" for="code">Code uit de e-mail</label>
        <input id="code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="10" placeholder="123456">
      </div>
      <button class="btn" id="go" type="submit">Stuur me een code</button>
      <p class="small muted" id="msg" style="margin:0">Geen wachtwoord nodig. Nog geen account? Dat wordt meteen aangemaakt.</p>
    </form>
    <p class="small muted" style="margin-top:18px"><a href="#/privacy">Hoe we met je gegevens omgaan</a></p>
  </div>`;
  let sent = false;
  $("#f").onsubmit = async (e) => {
    e.preventDefault();
    const email = $("#mail").value.trim().toLowerCase();
    const btn = $("#go"); btn.disabled = true;
    try {
      if (!sent) {
        const { error } = await sb.auth.signInWithOtp({ email, options: { shouldCreateUser: true, emailRedirectTo: location.origin } });
        if (error) throw error;
        sent = true; $("#codebox").hidden = false; $("#code").focus();
        btn.textContent = "Aanmelden";
        $("#msg").textContent = `Code verstuurd naar ${email}. Kijk ook in je spam.`;
      } else {
        const { error } = await sb.auth.verifyOtp({ email, token: $("#code").value.trim(), type: "email" });
        if (error) throw error;
        location.hash = "#/";
      }
    } catch (err) { $("#msg").innerHTML = `<span class="err">${esc(err.message)}</span>`; }
    btn.disabled = false;
  };
}

// ---------- Overzicht ----------
let period = 30;
async function viewDash() {
  const all = (await nights()).filter((n) => n.end);
  if (!all.length) {
    app.innerHTML = `<h1>Welkom 👋</h1><p class="sub">Nog geen nachten in je portaal.</p>
      <div class="card stack"><h2>Zo komen je nachten hier</h2>
      <ol class="muted" style="line-height:1.8;margin:0;padding-left:20px">
        <li>Open Snoredle op je iPhone › <b>Instellingen › Portaal</b>.</li>
        <li>Meld je aan met hetzelfde e-mailadres.</li>
        <li>Zet <b>"Nachten naar het portaal sturen"</b> aan. Je bestaande nachten komen meteen door, nieuwe na elke nacht.</li>
      </ol></div>`;
    return;
  }
  const since = period ? Date.now() - period * 86400e3 : 0;
  const sel = all.filter((n) => n.start.getTime() >= since);
  const list = sel.length ? sel : all.slice(0, 7);
  const chron = [...list].reverse();
  const S = (k) => list.map((n) => +n.s[k] || 0);
  const avgScore = Math.round(avg(S("score")));
  const last = all[0];

  app.innerHTML = `
  <div class="row spread" style="margin-bottom:18px">
    <div><h1>Goeiedag 🌙</h1><p class="sub" style="margin:0">${list.length} ${list.length === 1 ? "nacht" : "nachten"} · ${fmtDate(chron[0].start, { day: "numeric", month: "long" })} – ${fmtDate(chron.at(-1).start, { day: "numeric", month: "long" })}</p></div>
    <div class="seg" id="per">${[[7, "7 d"], [30, "30 d"], [90, "90 d"], [0, "Alles"]].map(([v, l]) => `<button data-v="${v}" class="${v === period ? "on" : ""}">${l}</button>`).join("")}</div>
  </div>
  <div class="grid g4">
    <div class="card" style="grid-row:span 2;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px">
      ${ring(avgScore, "gem. score")}
      <div style="font:600 18px var(--titel)">${scoreLabel(avgScore)} gesnurkt</div>
      <div class="small muted">snurkscore · lager is beter</div>
    </div>
    ${tile(mins(avg(S("sleepMin"))), "gemiddeld geslapen")}
    ${tile(Math.round(avg(S("snorePct"))) + "%", "van je slaap gesnurkt", C.amber)}
    ${tile(Math.round(avg(S("loudMin")) + avg(S("epicMin"))) + " min", "luid + episch per nacht", C.luid)}
    ${tile(S("apnea").reduce((a, b) => a + b, 0), "mogelijke ademstops (totaal)", S("apnea").reduce((a, b) => a + b, 0) > 10 ? C.episch : null)}
    ${tile(S("nudges").reduce((a, b) => a + b, 0), "keer gewekt (tik of geluid)")}
    ${tile(Math.round(avg(S("avgDb"))) + " dB", "gemiddeld volume")}
  </div>
  <div class="grid g2" style="margin-top:14px">
    <div class="card"><h3>Snurkscore per nacht</h3><div class="chart small"><canvas id="cScore"></canvas></div></div>
    <div class="card"><h3>Snurktijd en slaap</h3><div class="chart small"><canvas id="cPct"></canvas></div></div>
  </div>
  <div class="grid g2" style="margin-top:14px">
    <div class="card"><h3>Kalender</h3>${calendar(all)}<div class="legend">${[["Rustig", "#4DD973"], ["Matig", C.licht], ["Veel", C.luid], ["Zeer veel", C.episch]].map(([l, c]) => `<span><i class="dot" style="background:${c}"></i>${l}</span>`).join("")}</div></div>
    <div class="card"><h3>Houding (deze periode)</h3><div class="chart small"><canvas id="cPos"></canvas></div><p class="small muted" style="margin:8px 0 0">Balk = tijd in die houding · amber = deel daarvan gesnurkt</p></div>
  </div>
  <div class="row spread" style="margin:26px 0 12px"><h2 style="margin:0">Laatste nachten</h2><a href="#/nachten">Alle nachten →</a></div>
  <div class="nights">${all.slice(0, 6).map(nightCard).join("")}</div>`;

  $("#per").onclick = (e) => { const v = e.target.dataset.v; if (v !== undefined) { period = +v; route(); } };
  app.querySelectorAll(".cal .has").forEach((d) => (d.onclick = () => (location.hash = "#/nacht/" + d.dataset.id)));
  const labels = chron.map((n) => n.start);
  chart($("#cScore"), { type: "bar", data: { labels, datasets: [{ data: chron.map((n) => n.s.score), backgroundColor: chron.map((n) => scoreColor(n.s.score)), borderRadius: 6 }] },
    options: { scales: timeX(labels.length), onClick: (e, el) => el[0] && (location.hash = "#/nacht/" + chron[el[0].index].id),
      plugins: { tooltip: { callbacks: { title: (i) => fmtDate(labels[i[0].dataIndex]), label: (i) => `score ${i.raw} · ${scoreLabel(i.raw)}` } } } } });
  chart($("#cPct"), { type: "bar", data: { labels, datasets: [
    { type: "line", label: "Snurktijd %", data: chron.map((n) => n.s.snorePct), borderColor: C.amber, backgroundColor: "rgba(255,184,89,.18)", fill: true, tension: .35, yAxisID: "y", pointRadius: 3 },
    { label: "Slaap (u)", data: chron.map((n) => (n.s.sleepMin || 0) / 60), backgroundColor: "rgba(90,209,240,.35)", borderRadius: 5, yAxisID: "y2" },
  ] }, options: { scales: { ...timeX(labels.length), y: { position: "left", title: { display: true, text: "% gesnurkt" }, beginAtZero: true },
    y2: { position: "right", grid: { display: false }, title: { display: true, text: "uren slaap" }, beginAtZero: true } },
    plugins: { legend: { display: true, labels: { boxWidth: 10 } } } } });
  posChart($("#cPos"), list);
}

function tile(v, l, color) { return `<div class="tile"><div class="num" ${color ? `style="color:${color}"` : ""}>${v}</div><div class="lbl">${l}</div></div>`; }
function ring(score, label) {
  return `<div class="ring" style="--p:${Math.min(100, (score / 80) * 100)};--c:${scoreColor(score)}"><div><div class="num">${score}</div><small>${label}</small></div></div>`;
}
function timeX(n) {
  return { x: { type: "time", time: { unit: n > 45 ? "week" : "day", tooltipFormat: "d MMM" }, grid: { display: false }, offset: true,
    ticks: { maxTicksLimit: 8, callback: (v) => fmtDate(v, { day: "numeric", month: "short" }) } } };
}
function nightCard(n) {
  const s = n.s, total = Math.max(1, s.sleepMin || 1);
  return `<a class="night" href="#/nacht/${n.id}">
    <div class="row spread"><span class="t">${esc(s.title || fmtDate(n.start))}</span><span class="score" style="color:${scoreColor(s.score)}">${s.score ?? "–"}</span></div>
    <div class="small muted" style="margin:2px 0 10px">${fmtTime(n.start)} – ${n.end ? fmtTime(n.end) : "…"} · ${mins(s.sleepMin || 0)} · ${scoreLabel(s.score || 0).toLowerCase()}</div>
    <div class="bar"><span style="width:${Math.min(100, ((s.snoreMin || 0) / total) * 100)}%;background:${C.amber}"></span></div>
    <div class="small muted" style="margin-top:8px">${s.snoreMin || 0} min gesnurkt${s.apnea ? ` · ${s.apnea} mogelijke ademstops` : ""}${s.rating ? " · " + MOODS[s.rating - 1] : ""}</div>
    ${(s.factors || []).length ? `<div style="margin-top:8px">${s.factors.map((f) => FACTORS[f]?.[1] || "").join(" ")}</div>` : ""}
  </a>`;
}
function calendar(all) {
  const byDay = new Map();
  all.forEach((n) => { const d = new Date(n.end || n.start); byDay.set(d.toDateString(), n); });
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const start = new Date(today); start.setDate(start.getDate() - 34 - ((start.getDay() + 6) % 7));
  let html = `<div class="cal">${["ma", "di", "wo", "do", "vr", "za", "zo"].map((d) => `<div class="h">${d}</div>`).join("")}`;
  for (let d = new Date(start); d <= today; d.setDate(d.getDate() + 1)) {
    const n = byDay.get(d.toDateString());
    html += n ? `<div class="d has" data-id="${n.id}" title="${esc(n.s.title)} · score ${n.s.score}" style="background:${scoreColor(n.s.score)}">${d.getDate()}</div>`
              : `<div class="d">${d.getDate()}</div>`;
  }
  return html + "</div>";
}
function posChart(canvas, list) {
  const agg = {};
  list.forEach((n) => (n.s.positions || []).forEach((p) => { const a = (agg[p.p] ||= { min: 0, snore: 0 }); a.min += p.min; a.snore += p.snoreMin; }));
  const rows = Object.entries(agg).filter(([, a]) => a.min >= 5).sort((a, b) => b[1].min - a[1].min);
  chart(canvas, { type: "bar", data: { labels: rows.map(([p]) => POS[p]?.[0] || p), datasets: [
    { label: "Tijd (u)", data: rows.map(([, a]) => a.min / 60), backgroundColor: rows.map(([p]) => POS[p]?.[1] || "#888"), borderRadius: 6 },
    { label: "Gesnurkt (u)", data: rows.map(([, a]) => a.snore / 60), backgroundColor: "rgba(255,184,89,.9)", borderRadius: 6 },
  ] }, options: { indexAxis: "y", scales: { x: { title: { display: true, text: "uren" } }, y: { grid: { display: false } } },
    plugins: { tooltip: { callbacks: { label: (i) => `${i.dataset.label}: ${mins(i.raw * 60)}` } } } } });
}

// ---------- Alle nachten ----------
let sortKey = "start", sortDir = -1, search = "";
async function viewNights() {
  const all = (await nights()).filter((n) => n.end);
  const cols = [["start", "Nacht"], ["sleepMin", "Slaap"], ["score", "Score"], ["snorePct", "Snurk %"], ["loud", "Luid+episch"], ["apnea", "Ademstops"], ["nudges", "Gewekt"], ["rating", "Gevoel"]];
  const val = (n, k) => (k === "start" ? n.start.getTime() : k === "loud" ? (n.s.loudMin || 0) + (n.s.epicMin || 0) : +n.s[k] || 0);
  const render = () => {
    const q = search.toLowerCase();
    const rows = all.filter((n) => !q || [n.s.title, n.s.note, ...(n.s.factors || []).map((f) => FACTORS[f]?.[0]), ...(n.s.remedies || []).map((r) => REMEDIES[r])]
      .join(" ").toLowerCase().includes(q)).sort((a, b) => (val(a, sortKey) - val(b, sortKey)) * sortDir);
    $("#tb").innerHTML = rows.map((n) => `<tr class="link" data-id="${n.id}">
      <td><b>${esc(n.s.title || fmtDate(n.start))}</b><div class="small muted">${fmtTime(n.start)}–${fmtTime(n.end)}</div></td>
      <td class="r">${mins(n.s.sleepMin || 0)}</td>
      <td class="r" style="color:${scoreColor(n.s.score)};font-weight:700">${n.s.score}</td>
      <td class="r">${n.s.snorePct ?? 0}%</td><td class="r">${(n.s.loudMin || 0) + (n.s.epicMin || 0)} min</td>
      <td class="r">${n.s.apnea || 0}</td><td class="r">${n.s.nudges || 0}</td>
      <td>${n.s.rating ? MOODS[n.s.rating - 1] : ""} ${(n.s.factors || []).map((f) => FACTORS[f]?.[1] || "").join("")}</td></tr>`).join("")
      || `<tr><td colspan="8" class="muted">Geen nachten gevonden.</td></tr>`;
    $("#count").textContent = `${rows.length} van ${all.length}`;
    app.querySelectorAll("tr.link").forEach((r) => (r.onclick = () => (location.hash = "#/nacht/" + r.dataset.id)));
  };
  app.innerHTML = `
  <div class="row spread" style="margin-bottom:16px"><div><h1>Alle nachten</h1><p class="sub" style="margin:0" id="count"></p></div>
    <div class="row noprint"><button class="btn ghost" id="csv">⬇︎ CSV</button><button class="btn ghost" onclick="print()">🖨 Afdrukken</button></div></div>
  <input type="search" id="q" placeholder="Zoek op datum, notitie, factor of middel…" value="${esc(search)}" class="noprint" style="margin-bottom:14px">
  <div class="card scroll-x"><table><thead><tr>${cols.map(([k, l]) => `<th class="${k === "start" ? "" : "r"}" data-k="${k}" style="cursor:pointer">${l}${sortKey === k ? (sortDir < 0 ? " ↓" : " ↑") : ""}</th>`).join("")}</tr></thead><tbody id="tb"></tbody></table></div>`;
  $("#q").oninput = (e) => { search = e.target.value; render(); };
  app.querySelectorAll("th[data-k]").forEach((th) => (th.onclick = () => { if (sortKey === th.dataset.k) sortDir *= -1; else { sortKey = th.dataset.k; sortDir = -1; } viewNights(); }));
  $("#csv").onclick = () => download("snoredle-nachten.csv", toCSV(all), "text/csv");
  render();
}
function toCSV(all) {
  const head = ["datum", "start", "einde", "slaap_min", "score", "snurk_min", "snurk_pct", "luid_min", "episch_min", "periodes", "gewekt", "ademstops", "gem_db", "max_db", "uit_bed", "gevoel", "factoren", "middelen", "notitie"];
  const rows = all.map((n) => { const s = n.s; return [fmtDate(n.start, { year: "numeric", month: "2-digit", day: "2-digit" }), fmtTime(n.start), fmtTime(n.end), s.sleepMin, s.score, s.snoreMin, s.snorePct, s.loudMin, s.epicMin, s.episodes, s.nudges, s.apnea, s.avgDb, s.peakDb, s.outOfBed, s.rating ?? "",
    (s.factors || []).map((f) => FACTORS[f]?.[0] || f).join(", "), (s.remedies || []).map((r) => REMEDIES[r] || r).join(", "), (s.note || "").replace(/\n/g, " ")]; });
  return "﻿" + [head, ...rows].map((r) => r.map((v) => `"${String(v ?? "").replace(/"/g, '""')}"`).join(";")).join("\n");
}
function download(name, text, type) {
  const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([text], { type })); a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

// ---------- Eén nacht ----------
async function viewNight(id) {
  const n = await nightDetail(id);
  const { s, d } = n;
  const t0 = n.start.getTime(), t1 = n.end.getTime();
  const events = d.events || [], loud = d.loudness || [], posArr = d.positions || [], stages = (d.stages || []).filter((x) => x.st !== 4);
  const vit = d.vitals || {};
  const list = (await nights()).filter((x) => x.end);
  const idx = list.findIndex((x) => x.id === id);
  const prev = list[idx + 1], next = list[idx - 1];

  app.innerHTML = `
  <div class="row spread noprint" style="margin-bottom:10px">
    <a href="#/nachten">← Alle nachten</a>
    <div class="row">${prev ? `<a class="btn ghost" href="#/nacht/${prev.id}">‹ Vorige</a>` : ""}${next ? `<a class="btn ghost" href="#/nacht/${next.id}">Volgende ›</a>` : ""}
      <button class="btn ghost" id="json">⬇︎ Gegevens</button><button class="btn" onclick="print()">🖨 Rapport</button></div>
  </div>
  <div class="grid g3" style="align-items:stretch">
    <div class="card" style="display:flex;gap:20px;align-items:center;grid-column:span 2">
      ${ring(s.score ?? 0, "snurkscore")}
      <div><h1 style="font-size:30px">${esc(s.title || fmtDate(n.start))}</h1>
        <div class="muted">${fmtTime(n.start)} – ${fmtTime(n.end)} · ${mins(s.sleepMin || 0)} geslapen${s.wearable ? " · " + esc(s.wearable) : ""}</div>
        <div style="font:600 18px var(--titel);margin-top:8px;color:${scoreColor(s.score)}">${scoreLabel(s.score || 0)} gesnurkt${s.rating ? " · " + MOODS[s.rating - 1] : ""}</div></div>
    </div>
    <div class="card stack">
      ${(s.factors || []).length ? `<div><h3>Factoren</h3><div class="chips">${s.factors.map((f) => `<span class="chip">${FACTORS[f]?.[1] || ""} ${esc(FACTORS[f]?.[0] || f)}</span>`).join("")}</div></div>` : ""}
      ${(s.remedies || []).length ? `<div><h3>Middelen</h3><div class="chips">${s.remedies.map((r) => `<span class="chip green">${esc(REMEDIES[r] || r)}</span>`).join("")}</div></div>` : ""}
      ${s.alarmNote ? `<div><h3>Wekker</h3><div class="small">${esc(s.alarmNote)}</div></div>` : ""}
      ${s.note ? `<div><h3>Notitie</h3><div class="small">${esc(s.note)}</div></div>` : ""}
      ${!(s.factors || []).length && !(s.remedies || []).length && !s.note && !s.alarmNote ? `<div class="muted small">Geen factoren, middelen of notities voor deze nacht.</div>` : ""}
    </div>
  </div>
  <div class="grid g4" style="margin-top:14px">
    ${tile((s.snoreMin || 0) + " min", `gesnurkt · ${s.snorePct ?? 0}%`, C.amber)}
    ${tile((s.loudMin || 0) + " min", "luid snurken", C.luid)}
    ${tile((s.epicMin || 0) + " min", "episch snurken", C.episch)}
    ${tile(s.episodes || 0, "snurkperiodes")}
    ${tile(s.nudges || 0, "keer gewekt")}
    ${tile(s.apnea || 0, "mogelijke ademstops", (s.apnea || 0) > 5 ? C.episch : null)}
    ${tile((s.avgDb || 0) + " / " + (s.peakDb || 0) + " dB", "gemiddeld / luidste")}
    ${tile(s.outOfBed || 0, "keer uit bed")}
  </div>

  <div class="card" style="margin-top:14px">
    <div class="row spread"><h3 style="margin:0">Volume, snurken en houding</h3>
      <div class="row noprint small muted"><span>Sleep over de grafiek om een periode te kiezen · scroll of knijp om te zoomen</span><button class="btn ghost" id="reset" style="padding:6px 12px">Hele nacht</button></div></div>
    <div class="chart" style="margin-top:10px"><canvas id="cVol"></canvas></div>
    <div class="timeline" id="tl" style="margin-top:6px" title="Houding door de nacht"></div>
    <div class="legend">${[1, 2, 3].map((i) => `<span><i class="dot" style="background:${INTENSITY[i][1]}"></i>${INTENSITY[i][0]}</span>`).join("")}
      <span style="margin-left:12px">Houding:</span>${[...new Set(posArr.map((p) => p[1]))].map((p) => `<span><i class="dot" style="background:${POS[p]?.[1]}"></i>${POS[p]?.[0] || p}</span>`).join("")}</div>
    <div id="range" style="margin-top:14px"></div>
  </div>

  ${stages.length ? `<div class="card" style="margin-top:14px"><h3>Slaapfasen <span class="muted small">· Apple Watch via Gezondheid</span></h3><div id="stg"></div></div>` : ""}

  <div class="grid g2" style="margin-top:14px">
    ${vitalBlock("hr", "Hartslag", "bpm", vit.hr)}
    ${vitalBlock("spo2", "Zuurstof (SpO₂)", "%", vit.spo2)}
    ${vit.resp?.length ? vitalBlock("resp", "Ademhaling", "/min", vit.resp) : ""}
    ${vit.movement?.length ? vitalBlock("movement", "Beweging (watch)", "", vit.movement) : ""}
  </div>

  <div class="grid g2" style="margin-top:14px">
    <div class="card"><h3>Per houding</h3>${posTable(s.positions || [])}</div>
    <div class="card"><h3>Andere geluiden</h3>${soundsList(d.sounds || [])}
      ${(d.outOfBed || []).length ? `<h3 style="margin-top:16px">Uit bed</h3>${d.outOfBed.map((o) => `<div class="small">${fmtTime(o.s)}–${fmtTime(o.e)} · ${Math.round((o.e - o.s) / 60000)} min · ${o.steps} stappen${o.alert ? " · slaapwandelalarm" : ""}</div>`).join("")}` : ""}
      ${(d.pauses || []).length ? `<h3 style="margin-top:16px">Pauzes (niet gemeten)</h3><div class="small">${d.pauses.map((p) => `${fmtTime(p[0])}–${fmtTime(p[1])}`).join(" · ")}</div>` : ""}
    </div>
  </div>

  <div class="card scroll-x" style="margin-top:14px"><h3>Snurkperiodes (${events.length})</h3>
    <table><thead><tr><th>Tijd</th><th class="r">Duur</th><th class="r">Piek</th><th>Sterkte</th><th>Houding</th><th>Gewekt</th></tr></thead>
    <tbody>${[...events].sort((a, b) => b.db - a.db).slice(0, 40).sort((a, b) => a.s - b.s).map((e) => `<tr>
      <td>${fmtTime(e.s)}</td><td class="r">${Math.round((e.e - e.s) / 1000)} s</td><td class="r">${e.db} dB</td>
      <td><i class="dot" style="background:${INTENSITY[e.i]?.[1]}"></i>${INTENSITY[e.i]?.[0] || ""}</td>
      <td><i class="dot" style="background:${POS[e.p]?.[1]}"></i>${POS[e.p]?.[0] || e.p}${e.partner ? " (partner)" : ""}</td><td>${e.n ? "✓" : ""}</td></tr>`).join("")
      || `<tr><td colspan="6" class="muted">Geen snurken gemeten.</td></tr>`}</tbody></table>
    ${events.length > 40 ? `<p class="small muted">De 40 luidste van ${events.length} periodes.</p>` : ""}
    <p class="small muted noprint">Geluidsfragmenten blijven op je iPhone (privacy) en zijn daar af te spelen.</p>
  </div>`;

  $("#json").onclick = () => download(`snoredle-${n.start_at.slice(0, 10)}.json`, JSON.stringify({ summary: s, detail: d }, null, 1), "application/json");

  // Houding: tijdlijn (elke meting telt tot de volgende, hoogstens 10 min)
  const tl = $("#tl");
  const drawTimeline = (a, b) => {
    tl.innerHTML = posArr.map((p, i) => {
      const s0 = Math.max(p[0], a), e0 = Math.min(i + 1 < posArr.length ? posArr[i + 1][0] : t1, p[0] + 600000, b);
      if (e0 <= s0) return "";
      return `<span style="position:absolute;left:${((s0 - a) / (b - a)) * 100}%;width:${((e0 - s0) / (b - a)) * 100}%;background:${POS[p[1]]?.[1]}" title="${POS[p[1]]?.[0]} · ${fmtTime(p[0])}"></span>`;
    }).join("");
  };
  tl.style.position = "relative";

  // Volume + snurkperiodes (eigen plugin tekent de periodes als gekleurde blokken)
  const spans = { id: "spans", beforeDatasetsDraw(c) {
    const { ctx, chartArea: ar, scales: { x, y } } = c;
    ctx.save(); ctx.beginPath(); ctx.rect(ar.left, ar.top, ar.width, ar.height); ctx.clip();
    for (const p of d.pauses || []) { ctx.fillStyle = "rgba(255,255,255,.05)"; ctx.fillRect(x.getPixelForValue(p[0]), ar.top, x.getPixelForValue(p[1]) - x.getPixelForValue(p[0]), ar.height); }
    for (const e of events) {
      const a = x.getPixelForValue(e.s), b = Math.max(a + 2, x.getPixelForValue(Math.max(e.e, e.s + 1000)));
      ctx.fillStyle = INTENSITY[e.i]?.[1] || C.amber; ctx.globalAlpha = .85;
      ctx.fillRect(a, y.getPixelForValue(e.db), b - a, y.getPixelForValue(0) - y.getPixelForValue(e.db));
    }
    ctx.restore();
  } };
  const vol = chart($("#cVol"), {
    type: "line",
    data: { datasets: [{ data: loud.map((l) => ({ x: l[0], y: l[1] })), borderColor: "rgba(244,241,234,.55)", backgroundColor: "rgba(244,241,234,.12)", fill: true, pointRadius: 0, borderWidth: 1.2, tension: .2 }] },
    options: {
      parsing: false, interaction: { mode: "nearest", intersect: false, axis: "x" },
      scales: { x: { type: "time", min: t0, max: t1, time: { tooltipFormat: "HH:mm" }, ticks: { callback: (v) => fmtTime(v), maxTicksLimit: 10 }, grid: { color: C.lijn } },
        y: { min: 0, suggestedMax: 70, title: { display: true, text: "dB" } } },
      plugins: {
        tooltip: { callbacks: { title: (i) => fmtTime(i[0].parsed.x), label: (i) => `${Math.round(i.parsed.y)} dB` } },
        zoom: {
          limits: { x: { min: t0, max: t1, minRange: 60000 } },
          pan: { enabled: true, mode: "x", modifierKey: "shift" },
          zoom: { wheel: { enabled: true }, pinch: { enabled: true }, drag: { enabled: true, backgroundColor: "rgba(255,184,89,.18)", borderColor: C.amber, borderWidth: 1 }, mode: "x",
            onZoomComplete: ({ chart: c }) => syncRange(c.scales.x.min, c.scales.x.max) },
        },
      },
    },
    plugins: [spans],
  });
  const vitalCharts = [];
  for (const [key, , unit] of [["hr", "", "bpm"], ["spo2", "", "%"], ["resp", "", "/min"], ["movement", "", ""]]) {
    const el = document.getElementById("c_" + key); if (!el) continue;
    const pts = (vit[key] || []).map((v) => ({ x: v[0], y: v[1] }));
    const color = { hr: "#FF5C7A", spo2: "#5AD1F0", resp: "#4DE0B0", movement: C.luid }[key];
    vitalCharts.push(chart(el, { type: "line", data: { datasets: [{ data: pts, borderColor: color, backgroundColor: color + "22", fill: key !== "spo2", pointRadius: 0, borderWidth: 1.5, tension: .3 }] },
      options: { parsing: false, scales: { x: { type: "time", min: t0, max: t1, ticks: { callback: (v) => fmtTime(v), maxTicksLimit: 8 }, grid: { color: C.lijn } },
        y: key === "spo2" ? { suggestedMin: 85, suggestedMax: 100 } : {} },
        plugins: { tooltip: { callbacks: { title: (i) => fmtTime(i[0].parsed.x), label: (i) => `${Math.round(i.parsed.y)} ${unit}` } },
          annotation: undefined } } }));
  }
  const drawStages = (a, b) => {
    const el = $("#stg"); if (!el) return;
    const rows = [[0, "Wakker"], [1, "REM"], [2, "Kern"], [3, "Diep"]];
    el.innerHTML = rows.map(([k, l]) => `<div class="row" style="gap:10px;margin:5px 0"><span class="small muted" style="width:54px">${l}</span>
      <div style="position:relative;flex:1;height:16px;background:rgba(255,255,255,.04);border-radius:6px">${stages.filter((x) => (x.st === 5 ? 2 : x.st) === k).map((x) => {
        const s0 = Math.max(x.s, a), e0 = Math.min(x.e, b); if (e0 <= s0) return "";
        return `<span style="position:absolute;top:0;bottom:0;border-radius:4px;left:${((s0 - a) / (b - a)) * 100}%;width:${Math.max(.3, ((e0 - s0) / (b - a)) * 100)}%;background:${STAGES[k][1]}"></span>`;
      }).join("")}</div></div>`).join("") +
      `<div class="grid g4" style="margin-top:12px">${[[3, "Diep"], [2, "Kern"], [1, "REM"], [0, "Wakker"]].map(([k, l]) => tile(mins(stages.filter((x) => (x.st === 5 ? 2 : x.st) === k).reduce((t, x) => t + (x.e - x.s), 0) / 60000), l, STAGES[k][1])).join("")}</div>`;
  };

  function syncRange(a, b) {
    a = Math.max(t0, a); b = Math.min(t1, b);
    for (const c of vitalCharts) { c.options.scales.x.min = a; c.options.scales.x.max = b; c.update("none"); }
    drawTimeline(a, b); drawStages(a, b);
    const whole = b - a >= t1 - t0 - 60000;
    $("#range").innerHTML = whole ? "" : rangeSummary(a, b, { events, loud, posArr, vit, sounds: d.sounds || [], t1 });
  }
  $("#reset").onclick = () => { vol.resetZoom(); syncRange(t0, t1); };
  syncRange(t0, t1);
}

function vitalBlock(key, title, unit, data) {
  const v = (data || []).map((x) => x[1]);
  if (!v.length) return `<div class="card"><h3>${title}</h3><p class="muted small">Geen metingen voor deze nacht.</p></div>`;
  const low = key === "spo2" ? v.filter((x) => x < 90).length : null;
  return `<div class="card"><h3>${title}</h3><div class="chart small"><canvas id="c_${key}"></canvas></div>
    <div class="grid g4" style="margin-top:10px">${tile(Math.round(Math.min(...v)) + " " + unit, "laagste")}${tile(Math.round(avg(v)) + " " + unit, "gemiddeld")}${tile(Math.round(Math.max(...v)) + " " + unit, "hoogste")}
    ${low !== null ? tile(low + "×", "onder 90%", low ? C.episch : null) : ""}</div></div>`;
}
function posTable(rows) {
  const r = rows.filter((p) => p.min >= 1).sort((a, b) => b.min - a.min);
  if (!r.length) return `<p class="muted small">Geen houdingsgegevens (geen watch?).</p>`;
  const tot = r.reduce((t, p) => t + p.min, 0);
  const lying = r.filter((p) => p.min >= 20 && !["upright", "unknown"].includes(p.p));
  const best = lying.reduce((m, p) => (!m || p.snoreMin / p.min < m.snoreMin / m.min ? p : m), null);
  const worst = lying.reduce((m, p) => (!m || p.snoreMin / p.min > m.snoreMin / m.min ? p : m), null);
  return `<table><thead><tr><th>Houding</th><th class="r">Tijd</th><th class="r">Deel</th><th class="r">Gesnurkt</th><th class="r">Snurkt</th></tr></thead><tbody>
    ${r.map((p) => `<tr><td><i class="dot" style="background:${POS[p.p]?.[1]}"></i>${POS[p.p]?.[0] || p.p}</td><td class="r">${mins(p.min)}</td><td class="r">${Math.round((p.min / tot) * 100)}%</td>
      <td class="r">${p.snoreMin} min</td><td class="r" style="color:${p.snoreMin / p.min > .3 ? C.episch : "inherit"}">${Math.round(Math.min(1, p.snoreMin / p.min) * 100)}%</td></tr>`).join("")}</tbody></table>
    ${best && worst && best.p !== worst.p ? `<p class="small" style="color:var(--amber);margin:10px 0 0">Je snurkte het minst op ${POS[best.p][0].toLowerCase()} en het meest op ${POS[worst.p][0].toLowerCase()}.</p>` : ""}`;
}
function soundsList(sounds) {
  if (!sounds.length) return `<p class="muted small">Geen andere geluiden.</p>`;
  return sounds.slice(0, 20).map((x) => `<div class="row" style="align-items:flex-start;gap:10px;margin:6px 0">
    <span>${SOUNDS[x.k]?.[1] || "🔊"}</span><div><div class="small"><b>${fmtTime(x.s)}</b> · ${SOUNDS[x.k]?.[0] || x.k} · ${Math.max(1, Math.round((x.e - x.s) / 1000))} s</div>
    ${x.tx ? `<div class="small muted"><i>“${esc(x.tx)}”</i></div>` : ""}</div></div>`).join("");
}
function rangeSummary(a, b, { events, loud, posArr, vit, sounds, t1 }) {
  const ov = (s, e) => Math.max(0, Math.min(e, b) - Math.max(s, a));
  const ev = events.filter((e) => ov(e.s, Math.max(e.e, e.s + 1000)) > 0);
  const snore = ev.reduce((t, e) => t + ov(e.s, e.e), 0) / 1000;
  const dbs = loud.filter((l) => l[0] >= a && l[0] <= b).map((l) => l[1]);
  const hr = (vit.hr || []).filter((v) => v[0] >= a && v[0] <= b).map((v) => v[1]);
  const ox = (vit.spo2 || []).filter((v) => v[0] >= a && v[0] <= b).map((v) => v[1]);
  const pos = {};
  posArr.forEach((p, i) => { const e = Math.min(i + 1 < posArr.length ? posArr[i + 1][0] : t1, p[0] + 600000); const o = ov(p[0], e); if (o > 0) pos[p[1]] = (pos[p[1]] || 0) + o / 60000; });
  const dur = (b - a) / 1000;
  return `<div class="notice" style="background:rgba(255,184,89,.07)">
    <div class="row spread"><b style="font:600 17px var(--titel)">Gekozen periode: ${fmtTime(a)} – ${fmtTime(b)} · ${mins(dur / 60)}</b></div>
    <div class="grid g4" style="margin-top:10px">
      ${tile(Math.round(snore / 60) + " min", `gesnurkt (${Math.round((snore / dur) * 100)}%)`, C.amber)}
      ${tile(ev.length, "snurkperiodes")}
      ${dbs.length ? tile(`${Math.round(avg(dbs))} / ${Math.round(Math.max(...dbs))} dB`, "gemiddeld / max") : ""}
      ${hr.length ? tile(`${Math.round(Math.min(...hr))}–${Math.round(Math.max(...hr))}`, `bpm (gem. ${Math.round(avg(hr))})`) : ""}
      ${ox.length ? tile(Math.round(Math.min(...ox)) + "%", "laagste SpO₂") : ""}
      ${tile(sounds.filter((x) => x.s >= a && x.s <= b).length, "andere geluiden")}
    </div>
    ${Object.keys(pos).length ? `<div class="chips" style="margin-top:10px">${Object.entries(pos).sort((x, y) => y[1] - x[1]).map(([p, m]) => `<span class="chip" style="background:${POS[p]?.[1]}22;color:${POS[p]?.[1]}">${POS[p]?.[0]} · ${Math.round(m)} min</span>`).join("")}</div>` : ""}
  </div>`;
}

// ---------- Inzichten ----------
async function viewInsights() {
  const all = (await nights()).filter((n) => n.end);
  if (all.length < 2) { app.innerHTML = `<h1>Inzichten</h1><div class="card muted">Na een paar nachten zie je hier wat het verschil maakt.</div>`; return; }
  const effect = (has) => {
    const w = all.filter(has), wo = all.filter((n) => !has(n));
    if (w.length < 2 || wo.length < 2) return null;
    const a = avg(w.map((n) => n.s.score)), b = avg(wo.map((n) => n.s.score));
    return { with: a, without: b, diff: a - b, n: w.length };
  };
  const fx = Object.keys(FACTORS).map((k) => ({ k, label: `${FACTORS[k][1]} ${FACTORS[k][0]}`, e: effect((n) => (n.s.factors || []).includes(k)) })).filter((x) => x.e);
  const rx = Object.keys(REMEDIES).map((k) => ({ k, label: REMEDIES[k], e: effect((n) => (n.s.remedies || []).includes(k)) })).filter((x) => x.e);
  const days = ["zo", "ma", "di", "wo", "do", "vr", "za"];
  const byDay = days.map((_, i) => all.filter((n) => n.start.getDay() === i).map((n) => n.s.score));
  const sorted = [...all].sort((a, b) => a.s.score - b.s.score);
  const half = Math.floor(all.length / 2);
  const recent = avg(all.slice(0, half).map((n) => n.s.score)), older = avg(all.slice(half).map((n) => n.s.score));

  app.innerHTML = `<h1>Inzichten</h1><p class="sub">Gebaseerd op ${all.length} nachten. Hoe meer nachten met en zonder een factor, hoe betrouwbaarder.</p>
  <div class="grid g3">
    ${tile((recent < older ? "↓ " : "↑ ") + Math.abs(Math.round(recent - older)), `snurkscore: recente helft vs. oudere helft (${recent < older ? "beter" : "slechter"})`, recent < older ? "#4DD973" : C.episch)}
    ${tile(esc(sorted[0].s.title), `beste nacht · score ${sorted[0].s.score}`, "#4DD973")}
    ${tile(esc(sorted.at(-1).s.title), `zwaarste nacht · score ${sorted.at(-1).s.score}`, C.episch)}
  </div>
  <div class="grid g2" style="margin-top:14px">
    <div class="card"><h3>Factoren: invloed op je snurkscore</h3>${effectList(fx, "Nog geen factor met genoeg nachten (minstens 2 met en 2 zonder).")}</div>
    <div class="card"><h3>Middelen: werken ze?</h3>${effectList(rx, "Nog geen middel met genoeg nachten (minstens 2 met en 2 zonder).")}</div>
  </div>
  <div class="grid g2" style="margin-top:14px">
    <div class="card"><h3>Houding over alle nachten</h3><div class="chart"><canvas id="cPosAll"></canvas></div></div>
    <div class="card"><h3>Per weekdag (gem. snurkscore)</h3><div class="chart"><canvas id="cDay"></canvas></div></div>
  </div>`;
  posChart($("#cPosAll"), all);
  const order = [1, 2, 3, 4, 5, 6, 0];
  chart($("#cDay"), { type: "bar", data: { labels: order.map((i) => days[i]), datasets: [{ data: order.map((i) => (byDay[i].length ? Math.round(avg(byDay[i])) : null)),
    backgroundColor: order.map((i) => scoreColor(avg(byDay[i]))), borderRadius: 8 }] }, options: { scales: { y: { beginAtZero: true }, x: { grid: { display: false } } } } });
}
function effectList(items, empty) {
  if (!items.length) return `<p class="muted small">${empty}</p>`;
  return items.sort((a, b) => b.e.diff - a.e.diff).map((x) => {
    const up = x.e.diff > 0;
    return `<div class="row spread" style="padding:8px 0;border-bottom:1px solid var(--lijn)"><div><b>${esc(x.label)}</b><div class="small muted">${x.e.n} nachten · score ${Math.round(x.e.with)} met, ${Math.round(x.e.without)} zonder</div></div>
      <span style="font:700 18px var(--titel);color:${Math.abs(x.e.diff) < 3 ? C.muted : up ? C.episch : "#4DD973"}">${up ? "+" : ""}${Math.round(x.e.diff)}</span></div>`;
  }).join("");
}

// ---------- Account ----------
async function viewAccount() {
  const { data: { user } } = await sb.auth.getUser();
  const { data: prof } = await sb.from("profiles").select("*").maybeSingle();
  const count = (await nights()).length;
  app.innerHTML = `<h1>Account</h1><p class="sub">${esc(user.email)}</p>
  <div class="grid g2">
    <div class="card stack"><h3>Je gegevens</h3>
      <div>${count} ${count === 1 ? "nacht" : "nachten"} in je portaal.</div>
      ${prof?.consent_at ? `<div class="small muted">Toestemming gegeven op ${fmtDate(prof.consent_at, { day: "numeric", month: "long", year: "numeric" })}.</div>` : ""}
      <div class="row"><button class="btn ghost" id="dl">⬇︎ Alles downloaden (JSON)</button><button class="btn ghost" id="csv">⬇︎ Overzicht (CSV)</button></div>
    </div>
    <div class="card stack"><h3>Afmelden en wissen</h3>
      <div class="row"><button class="btn ghost" id="out">Afmelden</button></div>
      <div class="row"><button class="btn danger" id="wipe">Alle nachten wissen</button><button class="btn danger" id="del">Account verwijderen</button></div>
      <p class="small muted" style="margin:0">Wissen gebeurt meteen en definitief in het portaal. De nachten op je iPhone blijven staan. Zet in de app ook "Nachten naar het portaal sturen" uit, anders komen ze terug.</p>
      <p class="small" id="msg"></p>
    </div>
  </div>`;
  $("#out").onclick = async () => { await sb.auth.signOut(); location.hash = "#/login"; };
  $("#csv").onclick = async () => download("snoredle-nachten.csv", toCSV((await nights()).filter((n) => n.end)), "text/csv");
  $("#dl").onclick = async () => {
    const { data, error } = await sb.from("nights").select("*").order("start_at");
    if (error) return ($("#msg").textContent = error.message);
    download("snoredle-alle-gegevens.json", JSON.stringify({ exported_at: new Date().toISOString(), email: user.email, nights: data }, null, 1), "application/json");
  };
  $("#wipe").onclick = async () => {
    if (!confirm("Alle nachten in het portaal definitief wissen?")) return;
    const { error } = await sb.from("nights").delete().eq("user_id", user.id);
    cache = null; $("#msg").textContent = error ? error.message : "Alle nachten zijn gewist."; if (!error) viewAccount();
  };
  $("#del").onclick = async () => {
    if (!confirm("Je account en alle gegevens in het portaal definitief verwijderen?")) return;
    const { error } = await sb.rpc("delete_my_account");
    if (error) return ($("#msg").textContent = error.message);
    await sb.auth.signOut(); location.hash = "#/login";
  };
}

function viewPrivacy() {
  app.innerHTML = `<h1>Privacy</h1><div class="card stack" style="line-height:1.65">
    <p><b>Welke gegevens?</b> Per nacht: tijden, snurkcijfers, volume per minuut, snurkperiodes, houding, hartslag, zuurstof, ademhaling, slaapfasen, andere geluiden (met uitgeschreven slaappraten als je dat aanzette), je factoren, middelen, notities en ochtendgevoel. <b>Geluidsopnames worden nooit verstuurd</b>; die blijven op je iPhone.</p>
    <p><b>Waarom?</b> Enkel om ze jou te tonen in dit portaal. Het gaat om gezondheidsgegevens: we verwerken ze alleen met je uitdrukkelijke toestemming, die je in de app geeft en altijd kunt intrekken.</p>
    <p><b>Waar?</b> In een beveiligde database in de Europese Unie (Supabase). Alleen jij kunt je gegevens zien: dat wordt in de database zelf afgedwongen. We verkopen of delen niets, en gebruiken geen trackers of advertentiecookies.</p>
    <p><b>Je rechten.</b> Je kunt je gegevens op elk moment downloaden, wissen of je account verwijderen via <a href="#/account">Account</a> of in de app (Instellingen › Portaal).</p>
    <p class="small muted">Snoredle is geen medisch hulpmiddel en stelt geen diagnose. Twijfel je over je slaap of ademhaling, raadpleeg je huisarts.</p>
  </div>`;
}

route();
