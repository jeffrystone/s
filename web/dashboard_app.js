import * as THREE from "three";
import { OrbitControls } from "https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/controls/OrbitControls.js";

const host = document.getElementById("canvas-host");
const tooltip = document.getElementById("tooltip");
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b0f14);

const camera = new THREE.PerspectiveCamera(52, innerWidth / innerHeight, 0.08, 240);
camera.position.set(2.4, 1.6, 2.35);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(innerWidth, innerHeight);
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
host.appendChild(renderer.domElement);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.06;
controls.target.set(0, 0.12, 0);

scene.add(new THREE.AmbientLight(0xffffff, 0.42));
const dl = new THREE.DirectionalLight(0xffffff, 0.88);
dl.position.set(2.8, 4.2, 1.8);
scene.add(dl);

const grid = new THREE.GridHelper(4.8, 16, 0x334466, 0x1c2840);
scene.add(grid);

const spheres = {};
const scars = {};
const geo = new THREE.SphereGeometry(0.068, 22, 22);
const scarBaseGeo = new THREE.SphereGeometry(0.62, 20, 20);

const spheresGroup = new THREE.Group();
const scarsGroup = new THREE.Group();
const eventsGroup = new THREE.Group();
scene.add(spheresGroup);
scene.add(scarsGroup);
scene.add(eventsGroup);

/** Топ-K столбиков времени по узлам (по last snapshot) */
const stemMarkersGroup = new THREE.Group();
scene.add(stemMarkersGroup);
const TOP_K_STEM = 11;
const STEM_H_MAX = 0.52;
const STEM_R = 0.016;
const stemGeom = new THREE.CylinderGeometry(STEM_R, STEM_R, 1, 7);
stemGeom.translate(0, 0.5, 0);

const EVT_BAR_ORDER = [
  ["shot", "#8a9aaa"],
  ["heavy_shot", "#e07050"],
  ["resonance", "#e0b060"],
  ["analysis", "#5a98c8"],
  ["manual", "#80c8a0"],
];

function readLayerPrefs() {
  try {
    return {
      scars: localStorage.getItem("nodes_layer_scars") !== "0",
      beams: localStorage.getItem("nodes_layer_beams") !== "0",
      dormant: localStorage.getItem("nodes_layer_dormant") !== "0",
    };
  } catch (_) {
    return { scars: true, beams: true, dormant: true };
  }
}
const elLayScars = document.getElementById("layScars");
const elLayBeams = document.getElementById("layBeams");
const elLayDorm = document.getElementById("layDorm");
function persistLayerPrefs() {
  try {
    localStorage.setItem("nodes_layer_scars", elLayScars.checked ? "1" : "0");
    localStorage.setItem("nodes_layer_beams", elLayBeams.checked ? "1" : "0");
    localStorage.setItem("nodes_layer_dormant", elLayDorm.checked ? "1" : "0");
  } catch (_) {}
}
(function syncLayerChecksFromStorage() {
  const p = readLayerPrefs();
  elLayScars.checked = p.scars;
  elLayBeams.checked = p.beams;
  elLayDorm.checked = p.dormant;
})();
function applyLayerPrefsToScene() {
  scarsGroup.visible = elLayScars.checked;
  eventsGroup.visible = elLayBeams.checked;
  for (const m of Object.values(spheres)) {
    const snap = m.userData.nodeSnap;
    if (!snap) continue;
    const hp = Number(snap.hp || 0);
    const mp = Number(snap.mp || 0);
    const asleep = hp <= 1e-6 && mp > 0;
    m.visible = !asleep || elLayDorm.checked;
  }
}
function onLayerCheckboxChange() {
  persistLayerPrefs();
  applyLayerPrefsToScene();
}
elLayScars.addEventListener("change", onLayerCheckboxChange);
elLayBeams.addEventListener("change", onLayerCheckboxChange);
elLayDorm.addEventListener("change", onLayerCheckboxChange);

const raycaster = new THREE.Raycaster();
const pointer = new THREE.Vector2();

/** затухание по тактам симулятора (fallback) */
const EVENT_FADE_TICKS = 12;
/** время жизни лучей по времени браузера, мс — основной режим при дельте WS */
const BEAM_TTL_MS = 920;
/** максимум элементов журнала на клиенте */
const EVENT_RING_CAP = 64;
/** интерполяция позиций узлов между полными снимками */
let interpMsEstimate = 110;

/** @type {{ev: object, recvAt: number, anchorTick: number}[]} */
const evtRing = [];

let selectedNodeId = null;

/** Последний полный снимок для полей модалки добавления узла (N с лида и т.п.). */
let lastFullSnap = null;

let lastNodesSnap = null;
let lastRecentEvents = null;
let lastSimTick = 0;

const BURST_LS = "nodes_burst_steps";
const burstSelEl = document.getElementById("burstSel");

function sphereColor(D) {
  const t = Math.max(0, Math.min(1, Number(D) || 0));
  return new THREE.Color().setHSL(t * 0.32, 0.85, t < 0.5 ? 0.42 : 0.5);
}

function pollardXYZ(params, hp) {
  const p = params || {};
  const sx = (p.start_x != null ? Number(p.start_x) : (p.startx != null ? Number(p.startx) : 2));
  const pc = (p.poly_coeff != null ? Number(p.poly_coeff) : 1);
  const h = hp != null && hp > 0 ? Number(hp) : 1;
  const x = (sx / 1000 - 0.045) * 4;
  const y = (pc / 1000 - 0.045) * 4;
  const z = 0.06 * Math.max(0.01, h) / 120;
  return new THREE.Vector3(x, y, z);
}

function scarFailHue(flv) {
  const fl = Number(flv) || 1;
  if (fl >= 5) return 0.97;
  if (fl >= 4) return 0.93;
  if (fl >= 3) return 0.08;
  return 0.88;
}

function syncNodes(nodes) {
  const seen = new Set();
  for (const item of nodes || []) {
    const id = String(item.id);
    seen.add(id);
    const pos = pollardXYZ(item.params, item.hp);
    const newly = !spheres[id];
    if (newly) {
      const mat = new THREE.MeshStandardMaterial({
        color: 0x88ccaa,
        metalness: 0.12,
        roughness: 0.52,
        transparent: true,
      });
      const m = new THREE.Mesh(geo, mat);
      m.castShadow = false;
      m.userData.kind = "node";
      spheresGroup.add(m);
      spheres[id] = m;
    }
    const m = spheres[id];
    const nextPos = pos;
    if (!m.userData.prevPos || !m.userData.nextPos) {
      m.userData.prevPos = new THREE.Vector3();
      m.userData.nextPos = new THREE.Vector3();
    }
    if (newly) {
      m.userData.prevPos.copy(nextPos);
      m.userData.nextPos.copy(nextPos);
      m.position.copy(nextPos);
      m.userData.snapArrival = performance.now();
    } else {
      m.userData.prevPos.copy(m.position);
      m.userData.nextPos.copy(nextPos);
      m.userData.snapArrival = performance.now();
    }
    m.material.color.copy(sphereColor(item.dissonance));

    const hp = Number(item.hp || 0);
    const mp = Number(item.mp || 0);
    const frozen = !!item.mp_frozen;
    const asleep = hp <= 1e-6 && mp > 0;

    m.material.transparent = asleep;
    m.material.opacity = asleep ? 0.38 : 1;
    const mpNorm = Math.max(0, Math.min(1, mp / 90));
    if (frozen) {
      m.material.emissive.setHex(0x224466);
      m.material.emissiveIntensity = 0.35 + mpNorm * 0.25;
      m.material.metalness = 0.35;
      m.material.roughness = 0.38;
    } else {
      m.material.emissive.setHSL(0.52, 0.45, 0.12 + mpNorm * 0.38);
      m.material.emissiveIntensity = 0.15 + mpNorm * 0.55;
      m.material.metalness = 0.1;
      m.material.roughness = 0.52 + (asleep ? 0.08 : 0);
    }

    let s = Math.max(0.026, Math.min(0.24, 0.042 + hp / 360));
    if (selectedNodeId !== null && id === selectedNodeId)
      s = Math.min(0.28, s * 1.14);
    m.scale.setScalar(s);
    if (selectedNodeId !== null && id === selectedNodeId)
      m.material.emissiveIntensity =
        Math.min(1.35, m.material.emissiveIntensity + 0.26);
    m.userData.nodeSnap = item;
    m.visible = !asleep || elLayDorm.checked;
  }
  for (const k of Object.keys(spheres)) {
    if (!seen.has(k)) {
      spheresGroup.remove(spheres[k]);
      delete spheres[k];
    }
  }
}

function syncScars(list, paused) {
  const seen = new Set();
  for (const sc of list || []) {
    const id = String(sc.id ?? sc.scar_id ?? "");
    if (!id) continue;
    seen.add(id);
    const c = sc.center || {};
    const pv = pollardXYZ(c, 60);
    const pot = typeof sc.potential === "number" ? sc.potential : 0.35;
    const rad = typeof sc.radius === "number" ? sc.radius : 0.06;
    if (!scars[id]) {
      const mat = new THREE.MeshPhysicalMaterial({
        color: new THREE.Color().setHSL(scarFailHue(sc.fail_level), 0.82, 0.48),
        metalness: 0.06,
        roughness: 0.42,
        transparent: true,
        transmission: 0.35,
        thickness: 0.4,
        clearcoat: 0.08,
      });
      const mesh = new THREE.Mesh(scarBaseGeo, mat);
      mesh.userData.kind = "scar";
      mesh.userData.scarId = id;
      scarsGroup.add(mesh);
      scars[id] = mesh;
    }
    const mesh = scars[id];
    mesh.userData.scarId = id;
    mesh.position.set(pv.x, pv.y * 0.98, pv.z * 0.4 + Math.sqrt(Math.max(pot, 0.05)) * 0.06);
    const scale = Math.max(0.05, Math.min(0.9, rad * (paused ? 2.8 : 3.8)));
    mesh.scale.setScalar(scale);
    mesh.material.opacity = Math.max(0.12, Math.min(0.82, pot * 0.85));
    mesh.material.color.setHSL(scarFailHue(sc.fail_level), 0.75, 0.42 + 0.06 * Math.min(sc.fail_level || 1, 5));
    mesh.visible = pot > 0.02;
  }
  for (const k of Object.keys(scars)) {
    if (!seen.has(k)) {
      scarsGroup.remove(scars[k]);
      delete scars[k];
    }
  }
}

const shotLvlColor = ["0x8899aa","0xaabbdd","0xccaaff","0xbb66ff"];

function meshForNode(idStr) {
  return spheres[String(idStr)] || null;
}

/** Raycast по узлам (сферы); не шрамы. */
function pickNodeIdAt(cx, cy) {
  const rect = renderer.domElement.getBoundingClientRect();
  pointer.x = ((cx - rect.left) / rect.width) * 2 - 1;
  pointer.y = -((cy - rect.top) / rect.height) * 2 + 1;
  raycaster.setFromCamera(pointer, camera);
  const objs = [...Object.values(spheres)];
  const hit =
    objs.length > 0 ? raycaster.intersectObjects(objs, false)[0] : null;
  const snap = hit?.object?.userData?.nodeSnap;
  return snap?.id != null ? String(snap.id) : null;
}

function pickHitAt(cx, cy) {
  const rect = renderer.domElement.getBoundingClientRect();
  pointer.x = ((cx - rect.left) / rect.width) * 2 - 1;
  pointer.y = -((cy - rect.top) / rect.height) * 2 + 1;
  raycaster.setFromCamera(pointer, camera);
  const nodeHits = raycaster.intersectObjects([...Object.values(spheres)], false);
  const scarHits = raycaster.intersectObjects([...Object.values(scars)], false);
  const dN = nodeHits[0]?.distance ?? Infinity;
  const dS = scarHits[0]?.distance ?? Infinity;
  if (dS <= dN && scarHits.length) {
    const sid = scarHits[0]?.object?.userData?.scarId;
    if (sid != null && String(sid) !== "")
      return { kind: "scar", id: String(sid) };
  }
  const sn = nodeHits[0]?.object?.userData?.nodeSnap;
  if (sn?.id != null) return { kind: "node", id: String(sn.id) };
  return null;
}

function segmentLine(a, b, hex, opacity) {
  const geom = new THREE.BufferGeometry().setFromPoints([a.clone(), b.clone()]);
  const mat = new THREE.LineBasicMaterial({
    color: parseInt(hex, 16),
    transparent: true,
    opacity,
    linewidth: 1,
  });
  const line = new THREE.Line(geom, mat);
  eventsGroup.add(line);
  return line;
}

function trimEvtRing() {
  while (evtRing.length > EVENT_RING_CAP)
    evtRing.shift();
}

function resetEventRingFromSnapshot(eventsArr, anchorTick, recvPerf) {
  evtRing.length = 0;
  if (!Array.isArray(eventsArr) || eventsArr.length === 0) return;
  const a = Number(anchorTick) || 0;
  for (const ev of eventsArr) {
    evtRing.push({ ev, recvAt: recvPerf, anchorTick: a });
    trimEvtRing();
  }
}

function applyEventsDelta(delta) {
  if (delta.broadcast_interval_ms != null && Number.isFinite(delta.broadcast_interval_ms)) {
    interpMsEstimate = Math.max(
      48,
      Math.min(3200, Number(delta.broadcast_interval_ms)),
    );
  }
  const recv = performance.now();
  const anchorTick = Number(delta.tick != null ? delta.tick : lastSimTick);
  const arr = delta.events_append;
  if (Array.isArray(arr)) {
    for (const ev of arr) {
      evtRing.push({ ev, recvAt: recv, anchorTick });
      trimEvtRing();
    }
  }
}

function pruneStaleEvtRing(nowPerf) {
  const lim = BEAM_TTL_MS + 400;
  for (let i = evtRing.length - 1; i >= 0; i--) {
    if (nowPerf - evtRing[i].recvAt > lim)
      evtRing.splice(i, 1);
  }
}

function drawBeamRing(currentSimTick) {
  const nowPerf = performance.now();
  pruneStaleEvtRing(nowPerf);
  while (eventsGroup.children.length)
    eventsGroup.remove(eventsGroup.children[0]);
  if (!elLayBeams.checked || !evtRing.length) return;

  const T = Number(currentSimTick) || 0;
  let idx = 0;
  const nShow = evtRing.length;
  for (const w of evtRing) {
    idx++;
    const ev = w.ev;
    const ageMs = nowPerf - w.recvAt;
    const fadeMs =
      BEAM_TTL_MS <= 0
        ? 1
        : Math.max(0.08, Math.min(1, 1 - ageMs / BEAM_TTL_MS));
    const evTick = Number(ev.tick_sim ?? ev.tickSim ?? w.anchorTick ?? T);
    const ageTk = Math.max(0, T - evTick);
    const fadeTk =
      EVENT_FADE_TICKS <= 0
        ? 1
        : Math.max(0.06, Math.min(1, 1 - ageTk / EVENT_FADE_TICKS));
    const fade = fadeMs * fadeTk;
    const frac =
      fade * Math.max(0.15, Math.min(1, (idx / Math.max(nShow, 1)) * 1.05));
    const typ = String(ev.type ?? "");
    const n1 = meshForNode(ev.node_id);
    if (typ.includes("SHOT") && !typ.includes("HEAVY")) {
      const p0 = (n1 && n1.position.clone()) || new THREE.Vector3(0, 0.1, 0);
      const k = Number(ev.shot_level ?? 1) - 1;
      const hx = shotLvlColor[Math.max(0, Math.min(shotLvlColor.length - 1, k))];
      const off = new THREE.Vector3(0.18 + k * 0.04, 0.26, 0.12);
      segmentLine(p0, p0.clone().add(off), hx, 0.22 + 0.35 * frac);
    } else if (typ.includes("HEAVY")) {
      const p0 = (n1 && n1.position.clone()) || new THREE.Vector3();
      segmentLine(p0, p0.clone().add(new THREE.Vector3(-0.2, 0.55, 0.08)), "0xff6644", 0.42 + 0.25 * frac);
    } else if (typ.includes("RESONANCE")) {
      const a = meshForNode(ev.node_id);
      const b = meshForNode(ev.partner_id);
      if (a && b)
        segmentLine(a.position.clone(), b.position.clone(), "0xffcc66", 0.28 + 0.38 * frac);
    } else if (typ.includes("ANALYSIS")) {
      segmentLine(new THREE.Vector3(-0.3, 0.15, -0.2), new THREE.Vector3(0.25, 0.12, -0.15), "0x5588aa", 0.08 + 0.12 * frac);
    }
  }
}

function interpNodePositions() {
  const now = performance.now();
  const denom = Math.max(48, interpMsEstimate * 1.05);
  for (const m of Object.values(spheres)) {
    const pp = m.userData.prevPos;
    const np = m.userData.nextPos;
    if (!(pp instanceof THREE.Vector3 && np instanceof THREE.Vector3)) continue;
    const t0 = m.userData.snapArrival ?? now;
    const t = Math.min(1, Math.max(0, (now - t0) / denom));
    m.position.lerpVectors(pp, np, t);
  }
}

function cpuBarHtml(vals) {
  const el = document.getElementById("cpu-strip");
  el.innerHTML = "";
  if (!Array.isArray(vals)) return;
  for (const v of vals) {
    const t = Math.max(0, Math.min(1, Number(v) || 0));
    const sp = document.createElement("span");
    const hue = 120 - Math.round(t * 120);
    sp.style.background = `hsl(${hue} 82% ${34 + Math.round(t * 28)}%)`;
    sp.title = `core ~${Math.round(t * 100)}%`;
    el.appendChild(sp);
  }
}

function drawHudEventBars(st) {
  const cvs = document.getElementById("evtBarsHud");
  const cap = document.getElementById("evtTimeCaption");
  if (!cvs) return;
  const ctx = cvs.getContext("2d");
  const w = cvs.width;
  const h = cvs.height;
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = "rgba(80,130,200,.32)";
  ctx.lineWidth = 1;
  ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
  const dm = st.event_time_delta_s;
  const cum = st.event_time_s;
  const useDelta =
    dm &&
    typeof dm === "object" &&
    Object.keys(dm).some((k) => Number(dm[k]) > 1e-12);
  const src = useDelta ? dm : cum;
  let total = 0;
  for (const row of EVT_BAR_ORDER) {
    const v = Number(src?.[row[0]]) || 0;
    if (v > 0) total += v;
  }
  if (cap) {
    cap.textContent = useDelta
      ? "время событий: дельта между кадрами WS (сек.)"
      : "время событий (кумул., сек.)";
  }
  const pad = 6;
  const barW = w - 2 * pad;
  const barH = Math.max(10, h - 2 * pad - 22);
  if (total <= 1e-16) {
    ctx.font = "10px system-ui,sans-serif";
    ctx.fillStyle = "rgba(200,215,235,.72)";
    ctx.fillText("ожидание активности симулятора", pad, h / 2 + 3);
    return;
  }
  let acc = pad;
  for (const row of EVT_BAR_ORDER) {
    const vv = Number(src?.[row[0]]) || 0;
    if (vv <= 1e-18) continue;
    const seg = Math.max(1, (vv / total) * barW - 1e-6);
    ctx.fillStyle = row[1];
    ctx.fillRect(Math.round(acc), pad + 4, seg, barH * 0.72);
    acc += seg;
  }
  ctx.font = "9px system-ui,sans-serif";
  ctx.fillStyle = "rgba(200,215,235,.76)";
  let lx = pad;
  const baseline = pad + barH + 11;
  for (const row of EVT_BAR_ORDER) {
    ctx.fillStyle = row[1];
    const lab = `${row[0]}·${((Number(src?.[row[0]])||0)).toPrecision(3)}`;
    ctx.fillText(lab, lx, baseline);
    lx += ctx.measureText(lab).width + 7;
    if (lx > w - pad - 46) break;
  }
}

function stemSphereRadius(mesh) {
  const R = geo.parameters?.radius ?? 0.068;
  return mesh.scale.x * R;
}

function syncNodeTimeStemsFromSnapshot(st) {
  while (stemMarkersGroup.children.length)
    stemMarkersGroup.remove(stemMarkersGroup.children[0]);
  const pmap = st.per_node_time_s;
  if (!pmap || typeof pmap !== "object") return;
  const entries = [];
  for (const [k, vv] of Object.entries(pmap)) {
    entries.push({ id: String(k), t: Math.max(0, Number(vv) || 0) });
  }
  entries.sort((a, b) => b.t - a.t);
  const slice = entries.slice(0, TOP_K_STEM);
  if (!slice.length) return;
  const mx = Math.max(slice[0].t, 1e-12);
  const mat = new THREE.MeshStandardMaterial({
    color: 0x62d4aa,
    emissive: 0x112826,
    emissiveIntensity: 0.32,
    metalness: 0.1,
    roughness: 0.48,
    transparent: true,
    opacity: 0.93,
  });
  for (const e of slice) {
    const m = spheres[e.id];
    if (!m) continue;
    const h = STEM_H_MAX * (e.t / mx);
    if (h < 0.022) continue;
    const sm = new THREE.Mesh(stemGeom, mat.clone());
    sm.userData.nodeId = e.id;
    sm.userData.stemH = h;
    sm.scale.set(1, h, 1);
    stemMarkersGroup.add(sm);
  }
  syncNodeTimeStemsLayout();
}

function syncNodeTimeStemsLayout() {
  for (const sm of stemMarkersGroup.children) {
    const nid = sm.userData.nodeId;
    const h = Number(sm.userData.stemH) || 0.05;
    const m = spheres[nid];
    if (!m) continue;
    const r = stemSphereRadius(m);
    sm.position.copy(m.position);
    sm.position.y += r + h / 2;
    sm.scale.set(1, h, 1);
  }
}

function fmtLeader(lead) {
  if (!lead || lead.params == null) return "—";
  try {
    const p = lead.params;
    const N = (p.N != null ? String(p.N) : "?");
    return `id ${lead.id} · D=${(Number(lead.dissonance)||0).toFixed(3)} · N=${N}`;
  } catch (_) { return "—"; }
}

function drawHudSparklines(meanDHist, exploreRatioHist) {
  const cvs = document.getElementById("dspark");
  if (!cvs) return;
  const ctx = cvs.getContext("2d");
  const w = cvs.width;
  const h = cvs.height;
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = "rgba(80,130,200,.38)";
  ctx.lineWidth = 1;
  ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
  const pad = 5;
  const bottomLegend = 12;
  const plotH = Math.max(8, h - pad * 2 - bottomLegend);

  function xAt(i, n) {
    if (n <= 1) return pad + (w - 2 * pad) / 2;
    return pad + (i / (n - 1)) * (w - 2 * pad);
  }

  const ys = Array.isArray(meanDHist) ? meanDHist.map((v) => Number(v)) : [];

  const rVals = Array.isArray(exploreRatioHist)
    ? exploreRatioHist.map((v) => Number(v))
    : [];
  if (rVals.length >= 2) {
    ctx.strokeStyle = "#e8a050";
    ctx.lineWidth = 1.35;
    ctx.beginPath();
    for (let i = 0; i < rVals.length; i++) {
      const r = Number.isFinite(rVals[i])
        ? Math.max(0, Math.min(1, rVals[i]))
        : 0.5;
      const x = xAt(i, rVals.length);
      const y = pad + (1 - r) * plotH;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
  }

  if (ys.length >= 2) {
    let lo = Infinity;
    let hi = -Infinity;
    for (let i = 0; i < ys.length; i++) {
      const v = ys[i];
      if (!Number.isFinite(v)) continue;
      lo = Math.min(lo, v);
      hi = Math.max(hi, v);
    }
    if (Number.isFinite(lo) && Number.isFinite(hi)) {
      if (hi === lo) hi = lo + 1e-6;
      ctx.strokeStyle = "#6fd4a0";
      ctx.lineWidth = 1.55;
      ctx.beginPath();
      for (let i = 0; i < ys.length; i++) {
        const x = xAt(i, ys.length);
        const y =
          pad +
          (1 - (Math.max(lo, Math.min(hi, ys[i])) - lo) / (hi - lo)) * plotH;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.stroke();
    }
  }

  ctx.font = "10px system-ui,sans-serif";
  ctx.fillStyle = "#6fd4a0";
  ctx.fillText("D", pad, h - 3);
  ctx.fillStyle = "#e8a050";
  ctx.fillText("expl %", pad + 18, h - 3);
}

const proto = location.protocol === "https:" ? "wss" : "ws";
const ws = new WebSocket(`${proto}://${location.host}/`);
function sendJson(obj) {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(typeof obj === "string" ? obj : JSON.stringify(obj));
}
document.getElementById("btnSend").onclick = () => {
  const raw = document.getElementById("jcmd").value.trim();
  if (!raw) return;
  try { sendJson(JSON.parse(raw)); } catch (e) { alert("JSON: " + e); }
};
document.getElementById("btnDel").onclick = () => {
  const id = document.getElementById("mid").value.trim() || "1";
  sendJson({ action: "delete_node", node_id: id });
};
document.getElementById("btnFrz").onclick = () => {
  const id = document.getElementById("mid").value.trim() || "1";
  sendJson({ action: "set_mp_frozen", node_id: id, frozen: true });
};
document.getElementById("btnPause").onclick = () => sendJson({ action: "pause" });
document.getElementById("btnResume").onclick = () => sendJson({ action: "resume" });
document.getElementById("btnRefPair").onclick = () => {
  const a = document.getElementById("mid").value.trim() || "1";
  const b = document.getElementById("mid2").value.trim() || "2";
  sendJson({ action: "reference_pair", node_a: a, node_b: b });
};
(function initBurstSelFromLs() {
  if (!burstSelEl) return;
  try {
    const v = localStorage.getItem(BURST_LS);
    if (v && [...burstSelEl.options].some((o) => o.value === v))
      burstSelEl.value = v;
  } catch (_) {}
})();
if (burstSelEl) {
  burstSelEl.addEventListener("change", () => {
    try {
      localStorage.setItem(BURST_LS, burstSelEl.value);
    } catch (_) {}
    const n = Number(burstSelEl.value);
    if (!Number.isFinite(n)) return;
    sendJson({ action: "set_tick_burst", burst_steps: Math.round(n) });
  });
}
function syncBurstFromServer(wsBurst) {
  if (!burstSelEl || wsBurst == null || wsBurst === undefined) return;
  const v = String(Math.round(Number(wsBurst)));
  if (![...burstSelEl.options].some((o) => o.value === v)) return;
  if (burstSelEl.value === v) return;
  burstSelEl.value = v;
  try {
    localStorage.setItem(BURST_LS, v);
  } catch (_) {}
}
ws.onerror = () => {};
ws.onmessage = (e) => {
  try {
    const msg = JSON.parse(e.data);
    if (msg.delta === true) {
      applyEventsDelta(msg);
      return;
    }
    const st = msg;
    lastFullSnap = st;
    const paused = !!st.paused;
    document.getElementById("pauseTag").textContent = paused ? "ПАУЗА · " : "";
    document.getElementById("pauseTag").className = paused ? "warn" : "";
    document.getElementById("tick").textContent = st.tick ?? "–";
    document.getElementById("meanD").textContent =
      (typeof st.mean_D === "number") ? st.mean_D.toFixed(3) : "–";
    document.getElementById("wall").textContent =
      typeof st.t_wall_ms === "number" ? `${st.t_wall_ms} ms` : "–";
    document.getElementById("nn").textContent = st.nodes?.length ?? "–";
    document.getElementById("l34n").textContent =
      (typeof st.metric_l34_buffer_len === "number") ? String(st.metric_l34_buffer_len) : "–";
    const ta = Number(st.attention_tune_alpha ?? 1);
    const tb = Number(st.attention_tune_beta ?? 1);
    const tg = Number(st.attention_tune_gamma ?? 1);
    document.getElementById("attn").textContent =
      `${ta.toFixed(2)}/${tb.toFixed(2)}/${tg.toFixed(2)}`;
    document.getElementById("bexp").textContent =
      (typeof st.exploration_budget === "number") ? st.exploration_budget.toFixed(1) : "–";
    document.getElementById("bexo").textContent =
      (typeof st.exploitation_budget === "number") ? st.exploitation_budget.toFixed(1) : "–";
    document.getElementById("burstHud").textContent =
      typeof st.ws_burst_steps === "number" ? String(st.ws_burst_steps) : "–";
    syncBurstFromServer(st.ws_burst_steps);
    document.getElementById("leadLine").textContent =
      `лидер: ${fmtLeader(st.leader_node)}`;
    cpuBarHtml(st.cpu_usage_per_core);
    drawHudSparklines(st.mean_D_history, st.exploration_ratio_history);
    drawHudEventBars(st);
    if (Array.isArray(st.nodes)) {
      lastSimTick = st.tick;
      lastRecentEvents = st.recent_events;
      lastNodesSnap = st.nodes;
      resetEventRingFromSnapshot(st.recent_events, st.tick, performance.now());
      syncNodes(st.nodes);
      if (selectedNodeId && !spheres[selectedNodeId]) selectedNodeId = null;
      syncScars(st.scars, paused);
      applyLayerPrefsToScene();
      syncNodeTimeStemsFromSnapshot(st);
    }
  } catch (_) {}
};

function animate() {
  requestAnimationFrame(animate);
  interpNodePositions();
  syncNodeTimeStemsLayout();
  drawBeamRing(lastSimTick);
  controls.update();
  renderer.render(scene, camera);
}
animate();

addEventListener("resize", () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

function onPointerMove(ev) {
  const rect = renderer.domElement.getBoundingClientRect();
  pointer.x = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
  pointer.y = -((ev.clientY - rect.top) / rect.height) * 2 + 1;
  raycaster.setFromCamera(pointer, camera);
  const objs = [...Object.values(spheres)];
  const hit = objs.length ? raycaster.intersectObjects(objs, false)[0] : null;
  if (hit && hit.object.userData.nodeSnap) {
    const n = hit.object.userData.nodeSnap;
    tooltip.style.display = "block";
    tooltip.style.left = `${ev.clientX + 14}px`;
    tooltip.style.top = `${ev.clientY + 14}px`;
    const fz = n.mp_frozen ? "frozen" : "act";
    const params = typeof n.params === "object" && n.params ? JSON.stringify(n.params).slice(0, 420) : "";
    tooltip.innerHTML =
      `<b>#${n.id}</b> ${fz}<br/>D ${(Number(n.dissonance)||0).toFixed(4)}
      · hp ${(Number(n.hp)||0).toFixed(2)} · mp ${(Number(n.mp)||0).toFixed(2)}` +
      (params ? `<br/><span class="dim">${params}</span>` : "");
    renderer.domElement.style.cursor = "crosshair";
  } else {
    tooltip.style.display = "none";
    renderer.domElement.style.cursor = "";
  }
}
renderer.domElement.addEventListener("mousemove", onPointerMove);
renderer.domElement.addEventListener("mouseleave", () => { tooltip.style.display = "none"; });
renderer.domElement.addEventListener(
  "pointerdown",
  (ev) => {
    if (!(ev.ctrlKey || ev.metaKey) || ev.button !== 0) return;
    const idStr = pickNodeIdAt(ev.clientX, ev.clientY);
    if (!idStr) return;
    selectedNodeId = idStr;
    const mi = document.getElementById("mid");
    const mi2 = document.getElementById("mid2");
    if (ev.shiftKey && mi2) mi2.value = idStr;
    else if (mi) mi.value = idStr;
    if (lastNodesSnap) {
      syncNodes(lastNodesSnap);
      if (selectedNodeId && !spheres[selectedNodeId]) selectedNodeId = null;
      drawBeamRing(lastSimTick);
      applyLayerPrefsToScene();
    }
    ev.preventDefault();
    ev.stopPropagation();
  },
  true,
);

const ctxMenuEl = document.getElementById("ctxMenu");
const addNodeBackdrop = document.getElementById("addNodeBackdrop");

function hideCtxMenu() {
  if (!ctxMenuEl) return;
  ctxMenuEl.style.display = "none";
  ctxMenuEl.innerHTML = "";
}

function hideAddNodeModal() {
  if (addNodeBackdrop) addNodeBackdrop.style.display = "none";
}

function openAddNodeModal() {
  hideCtxMenu();
  const lead = lastFullSnap?.leader_node;
  const pn = lead?.params;
  const elN = document.getElementById("anN");
  const elSx = document.getElementById("anSx");
  const elPc = document.getElementById("anPc");
  if (pn && typeof pn === "object") {
    if (elN) elN.value = pn.N != null ? String(pn.N) : "221";
    if (elSx) elSx.value = String(pn.start_x ?? pn.startx ?? 7);
    if (elPc) elPc.value = String(pn.poly_coeff ?? 23);
  }
  if (addNodeBackdrop) addNodeBackdrop.style.display = "flex";
}

function showCtxMenuAt(clientX, clientY, defs) {
  if (!ctxMenuEl) return;
  ctxMenuEl.innerHTML = "";
  for (const d of defs) {
    if (d === "---") {
      ctxMenuEl.appendChild(document.createElement("hr"));
      continue;
    }
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = d.label;
    btn.disabled = !!d.disabled;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      hideCtxMenu();
      if (!d.disabled && d.action) d.action();
    });
    ctxMenuEl.appendChild(btn);
  }
  ctxMenuEl.style.display = "block";
  ctxMenuEl.style.left = `${clientX}px`;
  ctxMenuEl.style.top = `${clientY}px`;
  requestAnimationFrame(() => {
    const vw = innerWidth;
    const vh = innerHeight;
    const r = ctxMenuEl.getBoundingClientRect();
    let nx = clientX;
    let ny = clientY;
    if (r.right > vw - 4) nx = Math.max(4, vw - r.width - 4);
    if (r.bottom > vh - 4) ny = Math.max(4, vh - r.height - 4);
    ctxMenuEl.style.left = `${nx}px`;
    ctxMenuEl.style.top = `${ny}px`;
  });
}

renderer.domElement.addEventListener(
  "contextmenu",
  (ev) => {
    ev.preventDefault();
    hideAddNodeModal();
    const mid = document.getElementById("mid");
    const mid2 = document.getElementById("mid2");
    const hit = pickHitAt(ev.clientX, ev.clientY);
    if (!hit) {
      hideCtxMenu();
      return;
    }
    const a = mid?.value?.trim();
    const b = mid2?.value?.trim();
    const pairOk =
      !!a &&
      !!b &&
      a !== b &&
      b !== "";

    if (hit.kind === "scar") {
      showCtxMenuAt(ev.clientX, ev.clientY, [
        {
          label: "Снять шрам",
          action: () => sendJson({ action: "clear_scar", scar_id: hit.id }),
        },
      ]);
      return;
    }

    showCtxMenuAt(ev.clientX, ev.clientY, [
      {
        label: "В primary id",
        action: () => {
          mid && (mid.value = hit.id);
        },
      },
      {
        label: "В secondary id",
        action: () => {
          mid2 && (mid2.value = hit.id);
        },
      },
      "---",
      {
        label: "Удалить узел",
        action: () => sendJson({ action: "delete_node", node_id: hit.id }),
      },
      {
        label: "Новый узел…",
        action: () => openAddNodeModal(),
      },
      "---",
      {
        label: "Принудить резонанс (оба id)",
        disabled: !pairOk,
        action: () => {
          if (!pairOk) return;
          sendJson({ action: "force_resonance", node_a: a, node_b: b });
        },
      },
    ]);
  },
  false,
);

document.addEventListener(
  "pointerdown",
  (ev) => {
    if (
      ctxMenuEl &&
      ctxMenuEl.style.display === "block" &&
      ev.target instanceof Node &&
      !ctxMenuEl.contains(ev.target)
    ) {
      hideCtxMenu();
    }
    if (
      addNodeBackdrop &&
      addNodeBackdrop.style.display === "flex" &&
      ev.target === addNodeBackdrop
    ) {
      hideAddNodeModal();
    }
  },
  true,
);

addEventListener("keydown", (ev) => {
  if (ev.key === "Escape") {
    hideCtxMenu();
    hideAddNodeModal();
  }
});

document.getElementById("anCancel")?.addEventListener("click", hideAddNodeModal);
document.getElementById("anOk")?.addEventListener("click", () => {
  const nStr = document.getElementById("anN")?.value?.trim() || "221";
  const sx = Number(document.getElementById("anSx")?.value);
  const pc = Number(document.getElementById("anPc")?.value);
  sendJson({
    action: "add_node",
    params: {
      N: nStr,
      start_x: Number.isFinite(sx) ? sx : 2,
      poly_coeff: Number.isFinite(pc) ? pc : 1,
    },
  });
  hideAddNodeModal();
});