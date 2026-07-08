import {
  BOARD_PAD,
  BOARD_SIZE,
  BOARD_STEP,
  candidateColor,
  coordOfPoint,
  historyPayload,
  intersectionPoint,
  samePoint,
} from "./qixi_core.mjs";

const BLACK_STONE = "/assets/black-02-matte-ceramic.svg";
const WHITE_STONE = "/assets/white-02-matte-ceramic.svg";
const SAVE_KEY = "qixi.sim.state.v2";
const ANALYSIS_KEY_PREFIX = "qixi.sim.analysis.";

const boardEl = document.getElementById("board");
const stoneLayer = document.getElementById("stoneLayer");
const candidateLayer = document.getElementById("candidateLayer");
const territoryLayer = document.getElementById("territoryLayer");
const statusEl = document.getElementById("engineStatus");
const chartCanvas = document.getElementById("chartCanvas");
const treeSvg = document.getElementById("treeSvg");
const treeScrollX = document.getElementById("treeScrollX");
const treeScrollY = document.getElementById("treeScrollY");
const komiInput = document.getElementById("komiInput");
const rootNoiseInput = document.getElementById("rootNoiseInput");
const passButton = document.getElementById("passButton");
const territoryButton = document.getElementById("territoryButton");
const autoReplayButton = document.getElementById("autoReplayButton");
const loadingOverlay = document.getElementById("loadingOverlay");
const loadingBar = document.getElementById("loadingBar");
const loadingText = document.getElementById("loadingText");
const languageGate = document.getElementById("languageGate");
const skipIcloudButton = document.getElementById("skipIcloudButton");

const sampleLine = [
  { color: "B", x: 3, y: 15 },
  { color: "W", x: 15, y: 3 },
  { color: "B", x: 15, y: 15 },
  { color: "W", x: 3, y: 3 },
  { color: "B", x: 9, y: 15 },
  { color: "W", x: 9, y: 3 },
  { color: "B", x: 6, y: 12 },
  { color: "W", x: 12, y: 6 },
  { color: "B", x: 10, y: 14 },
  { color: "W", x: 8, y: 4 },
  { color: "B", x: 4, y: 10 },
  { color: "W", x: 14, y: 8 },
];

const state = {
  mainLine: sampleLine.slice(),
  currentPly: 0,
  activeEngine: "none",
  analysisCache: new Map(),
  lastResult: null,
  territoryVisible: false,
  autoReplay: false,
  autoTimer: null,
  holdTimer: null,
  analyzing: false,
  language: null,
};

function movesAtCurrentPly() {
  return state.mainLine.slice(0, state.currentPly);
}

function nextColor() {
  return state.currentPly % 2 === 0 ? "B" : "W";
}

function boardOccupancy(moves = movesAtCurrentPly()) {
  const board = new Array(BOARD_SIZE * BOARD_SIZE).fill(null);
  for (const move of moves) {
    if (move.pass) {
      continue;
    }
    board[move.y * BOARD_SIZE + move.x] = move.color;
  }
  return board;
}

async function digest(payload) {
  const text = JSON.stringify(payload);
  const bytes = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function currentHistoryKey(engine = state.activeEngine) {
  return digest(historyPayload(movesAtCurrentPly(), engine, Number(komiInput.value || 7.5)));
}

function setStatus(engine, text) {
  statusEl.textContent = `${engine} · ${text}`;
}

function saveAnalysisForEngine(engine) {
  const serializable = Object.fromEntries(state.analysisCache.entries());
  localStorage.setItem(`${ANALYSIS_KEY_PREFIX}${engine}`, JSON.stringify(serializable));
}

function loadAnalysisForEngine(engine) {
  try {
    const raw = localStorage.getItem(`${ANALYSIS_KEY_PREFIX}${engine}`);
    state.analysisCache = new Map(raw ? Object.entries(JSON.parse(raw)) : []);
  } catch {
    state.analysisCache = new Map();
  }
}

function saveAppState(reason = "autosave") {
  saveAnalysisForEngine(state.activeEngine);
  localStorage.setItem(SAVE_KEY, JSON.stringify({
    reason,
    savedAt: new Date().toISOString(),
    mainLine: state.mainLine,
    currentPly: state.currentPly,
    activeEngine: state.activeEngine,
    language: state.language,
    komi: Number(komiInput.value || 7.5),
  }));
}

function loadAppState() {
  try {
    const raw = localStorage.getItem(SAVE_KEY);
    if (!raw) {
      return;
    }
    const saved = JSON.parse(raw);
    if (Array.isArray(saved.mainLine)) {
      state.mainLine = saved.mainLine;
    }
    state.currentPly = Math.max(0, Math.min(Number(saved.currentPly || 0), state.mainLine.length));
    state.activeEngine = saved.activeEngine || "none";
    state.language = saved.language || null;
    if (Number.isFinite(saved.komi)) {
      komiInput.value = String(saved.komi);
    }
  } catch {
    state.currentPly = 0;
  }
  loadAnalysisForEngine(state.activeEngine);
}

function styleAtPoint(element, x, y) {
  const point = intersectionPoint(x, y);
  element.style.setProperty("--x", point.left);
  element.style.setProperty("--y", point.top);
}

function renderStones() {
  stoneLayer.replaceChildren();
  const fragment = document.createDocumentFragment();
  for (const move of movesAtCurrentPly()) {
    if (move.pass) {
      continue;
    }
    const stone = document.createElement("div");
    stone.className = "stone";
    styleAtPoint(stone, move.x, move.y);
    const img = document.createElement("img");
    img.alt = "";
    img.src = move.color === "B" ? BLACK_STONE : WHITE_STONE;
    stone.appendChild(img);
    fragment.appendChild(stone);
  }
  stoneLayer.appendChild(fragment);
}

function renderCandidates(result = state.lastResult) {
  candidateLayer.replaceChildren();
  if (!result || !Array.isArray(result.moves) || result.moves.length === 0) {
    renderNextMoveGhost(new Set());
    return;
  }

  const best = Math.max(...result.moves.map((move) => Number(move.winrate ?? 0)));
  const fragment = document.createDocumentFragment();
  const renderedPoints = new Set();

  result.moves.slice(0, 10).forEach((move, index) => {
    if (move.x == null || move.y == null) {
      return;
    }
    const k = (Number(move.winrate ?? 0) - best) * 100;
    if (k <= -5) {
      return;
    }
    const marker = document.createElement("div");
    marker.className = "candidate";
    marker.style.setProperty("--candidate-color", candidateColor(k).css);
    styleAtPoint(marker, move.x, move.y);
    marker.innerHTML = `
      <span class="candidate-rank">${index + 1}</span>
      <span>${((Number(move.winrate ?? 0)) * 100).toFixed(1)}%</span>
      <span class="visits">${Number(move.visits ?? 0)}</span>
      <span class="score">${formatScore(move.scoreMean ?? result.scoreMean)}</span>
    `;
    renderedPoints.add(`${move.x},${move.y}`);
    fragment.appendChild(marker);
  });

  candidateLayer.appendChild(fragment);
  renderNextMoveGhost(renderedPoints);
}

async function renderNextMoveGhost(renderedPoints) {
  const next = state.mainLine[state.currentPly];
  if (!next || next.pass || renderedPoints.has(`${next.x},${next.y}`)) {
    return;
  }
  const nextMoves = state.mainLine.slice(0, state.currentPly + 1);
  const key = await digest(historyPayload(nextMoves, state.activeEngine, Number(komiInput.value || 7.5)));
  if (!state.analysisCache.has(key)) {
    return;
  }
  const marker = document.createElement("div");
  marker.className = "candidate is-ghost";
  marker.style.setProperty("--candidate-color", "rgba(33, 82, 244, 0.72)");
  styleAtPoint(marker, next.x, next.y);
  marker.innerHTML = `<span class="candidate-rank">›</span><span>${coordOfPoint(next.x, next.y)}</span><span class="visits">已析</span><span class="score">下一手</span>`;
  candidateLayer.appendChild(marker);
}

function renderTerritory(result = state.lastResult) {
  territoryLayer.replaceChildren();
  if (!state.territoryVisible || !result || !Array.isArray(result.ownership)) {
    return;
  }
  const stones = boardOccupancy();
  const fragment = document.createDocumentFragment();
  result.ownership.forEach((value, index) => {
    const ownership = Number(value);
    if (!Number.isFinite(ownership) || Math.abs(ownership) < 0.16) {
      return;
    }
    const x = index % BOARD_SIZE;
    const y = Math.floor(index / BOARD_SIZE);
    const stone = stones[y * BOARD_SIZE + x];
    if ((stone === "B" && ownership < 0) || (stone === "W" && ownership > 0)) {
      return;
    }
    const dot = document.createElement("div");
    dot.className = "territory-point";
    styleAtPoint(dot, x, y);
    const alpha = Math.min(0.72, 0.18 + Math.abs(ownership) * 0.5);
    dot.style.setProperty("--territory-color", ownership > 0 ? `rgba(255,255,255,${alpha})` : `rgba(0,0,0,${alpha})`);
    fragment.appendChild(dot);
  });
  territoryLayer.appendChild(fragment);
}

function formatScore(value) {
  if (!Number.isFinite(Number(value))) {
    return "--";
  }
  const score = Number(value);
  return `${score >= 0 ? "+" : ""}${score.toFixed(1)}`;
}

function drawChart() {
  const canvas = chartCanvas;
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = "rgba(255,255,255,0.54)";
  ctx.fillRect(0, 0, width, height);
  const pad = 30;
  const usableW = width - pad * 2;
  const usableH = height - pad * 2;
  ctx.strokeStyle = "rgba(22,25,34,0.18)";
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(pad, pad + usableH / 2);
  ctx.lineTo(width - pad, pad + usableH / 2);
  ctx.stroke();

  const points = [];
  for (let ply = 0; ply <= state.mainLine.length; ply++) {
    const moves = state.mainLine.slice(0, ply);
    points.push({
      ply,
      winrate: 0.5 + Math.sin(ply * 0.7) * 0.06,
      score: Math.cos(ply * 0.53) * 4.8,
    });
  }

  drawLine(ctx, points, (p) => pad + (p.ply / Math.max(1, state.mainLine.length)) * usableW, (p) => pad + (1 - p.winrate) * usableH, "#2152f4", 2.4);
  drawLine(ctx, points, (p) => pad + (p.ply / Math.max(1, state.mainLine.length)) * usableW, (p) => pad + usableH / 2 - p.score * 7, "#c72e4d", 2.2);

  const refX = pad + (state.currentPly / Math.max(1, state.mainLine.length)) * usableW;
  ctx.strokeStyle = "rgba(22,25,34,0.42)";
  ctx.setLineDash([4, 5]);
  ctx.beginPath();
  ctx.moveTo(refX, pad);
  ctx.lineTo(refX, height - pad);
  ctx.stroke();
  ctx.setLineDash([]);
}

function drawLine(ctx, points, xOf, yOf, color, width) {
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.beginPath();
  points.forEach((point, index) => {
    const x = xOf(point);
    const y = yOf(point);
    if (index === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  });
  ctx.stroke();
}

function renderTree() {
  treeSvg.replaceChildren();
  const ns = "http://www.w3.org/2000/svg";
  const gap = 54;
  const baseX = 34;
  const baseY = 42;
  const nodes = [];
  for (let ply = 0; ply <= state.mainLine.length; ply++) {
    nodes.push({ ply, x: baseX + ply * gap, y: baseY });
  }
  const branchStart = Math.min(5, state.mainLine.length);
  const branchNodes = [
    { ply: branchStart + 1, x: baseX + (branchStart + 1) * gap, y: baseY + gap },
    { ply: branchStart + 2, x: baseX + (branchStart + 2) * gap, y: baseY + gap * 2 },
  ];

  appendPath(`M ${baseX} ${baseY} H ${baseX + state.mainLine.length * gap}`, "tree-line");
  if (state.mainLine.length > branchStart) {
    const x0 = baseX + branchStart * gap;
    appendPath(`M ${x0} ${baseY} V ${baseY + gap} L ${x0 + gap} ${baseY + gap * 2}`, "tree-line");
  }

  for (const node of [...nodes, ...branchNodes]) {
    const shape = document.createElementNS(ns, node.ply === 0 ? "rect" : "circle");
    if (node.ply === 0) {
      shape.setAttribute("x", String(node.x - 8));
      shape.setAttribute("y", String(node.y - 8));
      shape.setAttribute("width", "16");
      shape.setAttribute("height", "16");
      shape.setAttribute("rx", "2");
      shape.setAttribute("fill", "#fff");
    } else {
      shape.setAttribute("cx", String(node.x));
      shape.setAttribute("cy", String(node.y));
      shape.setAttribute("r", node.ply === state.currentPly ? "8" : "6");
      shape.setAttribute("fill", node.ply === state.currentPly ? "#2152f4" : "#fff");
    }
    shape.setAttribute("stroke", "rgba(22,25,34,0.5)");
    shape.setAttribute("data-ply", String(Math.min(node.ply, state.mainLine.length)));
    shape.classList.add("tree-node");
    treeSvg.appendChild(shape);
  }

  treeScrollX.hidden = state.mainLine.length * gap < 720;
  treeScrollY.hidden = true;

  function appendPath(d, className) {
    const path = document.createElementNS(ns, "path");
    path.setAttribute("d", d);
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", "rgba(22,25,34,0.42)");
    path.setAttribute("stroke-width", "2");
    path.setAttribute("class", className);
    treeSvg.appendChild(path);
  }
}

async function postJson(path, payload) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.error || `${response.status} ${response.statusText}`);
  }
  return body;
}

async function analyzeCurrent() {
  renderAllStatic();
  if (state.activeEngine === "none" || state.analyzing) {
    state.lastResult = null;
    renderCandidates(null);
    renderTerritory(null);
    return;
  }
  state.analyzing = true;
  const moves = movesAtCurrentPly();
  const localKey = await currentHistoryKey();
  if (state.analysisCache.has(localKey)) {
    state.lastResult = state.analysisCache.get(localKey);
    renderCandidates();
    renderTerritory();
  }
  try {
    const result = await postJson("/api/analyze", {
      moves,
      maxVisits: 64,
      komi: Number(komiInput.value || 7.5),
      rootNoise: Number(rootNoiseInput.value || 0),
    });
    state.lastResult = result;
    state.analysisCache.set(localKey, result);
    setStatus(result.engine, result.state);
    renderCandidates(result);
    renderTerritory(result);
    saveAppState("analysis");
  } catch (error) {
    setStatus(state.activeEngine, error.message);
  } finally {
    state.analyzing = false;
  }
}

function renderAllStatic() {
  renderStones();
  drawChart();
  renderTree();
}

function stepBy(delta) {
  state.currentPly = Math.max(0, Math.min(state.mainLine.length, state.currentPly + delta));
  void analyzeCurrent();
}

function appendMove(move) {
  state.mainLine = state.mainLine.slice(0, state.currentPly);
  state.mainLine.push(move);
  state.currentPly = state.mainLine.length;
  void analyzeCurrent();
}

function startHold(button, delta) {
  clearHold();
  stepBy(delta);
  const interval = Math.abs(delta) === 5 ? 190 : 330;
  state.holdTimer = setInterval(() => stepBy(delta), interval);
  button.classList.add("is-active");
}

function clearHold() {
  if (state.holdTimer) {
    clearInterval(state.holdTimer);
    state.holdTimer = null;
  }
  document.querySelectorAll("[data-step].is-active").forEach((button) => button.classList.remove("is-active"));
}

function toggleAutoReplay() {
  state.autoReplay = !state.autoReplay;
  autoReplayButton.classList.toggle("is-active", state.autoReplay);
  if (state.autoTimer) {
    clearInterval(state.autoTimer);
    state.autoTimer = null;
  }
  if (state.autoReplay) {
    state.autoTimer = setInterval(() => {
      if (state.currentPly >= state.mainLine.length) {
        toggleAutoReplay();
      } else {
        stepBy(1);
      }
    }, 2000);
  }
}

async function switchEngine(engine) {
  saveAnalysisForEngine(state.activeEngine);
  document.querySelectorAll(".engine-switch button").forEach((button) => button.classList.toggle("is-selected", button.dataset.engine === engine));
  setStatus(engine, "loading");
  try {
    const result = await postJson("/api/engine", { engine });
    state.activeEngine = engine;
    loadAnalysisForEngine(engine);
    setStatus(result.engine, result.state);
    await analyzeCurrent();
  } catch (error) {
    setStatus(engine, error.message);
  }
}

function wireEvents() {
  boardEl.addEventListener("click", (event) => {
    const rect = boardEl.getBoundingClientRect();
    const px = ((event.clientX - rect.left) / rect.width) * 100;
    const py = ((event.clientY - rect.top) / rect.height) * 100;
    const x = Math.round((px - BOARD_PAD) / BOARD_STEP);
    const y = Math.round((py - BOARD_PAD) / BOARD_STEP);
    if (x < 0 || x >= BOARD_SIZE || y < 0 || y >= BOARD_SIZE) {
      return;
    }
    const point = intersectionPoint(x, y);
    if (Math.abs(px - point.xPercent) > BOARD_STEP * 0.52 || Math.abs(py - point.yPercent) > BOARD_STEP * 0.52) {
      return;
    }
    if (boardOccupancy()[y * BOARD_SIZE + x] !== null) {
      return;
    }
    appendMove({ color: nextColor(), x, y });
  });

  passButton.addEventListener("click", () => appendMove({ color: nextColor(), pass: true }));
  territoryButton.addEventListener("click", () => {
    state.territoryVisible = !state.territoryVisible;
    territoryButton.classList.toggle("is-active", state.territoryVisible);
    renderTerritory();
  });
  autoReplayButton.addEventListener("click", toggleAutoReplay);

  document.querySelectorAll("[data-step]").forEach((button) => {
    const delta = Number(button.dataset.step);
    button.addEventListener("pointerdown", () => startHold(button, delta));
    button.addEventListener("pointerup", clearHold);
    button.addEventListener("pointerleave", clearHold);
    button.addEventListener("pointercancel", clearHold);
  });

  document.querySelectorAll(".engine-switch button").forEach((button) => {
    button.addEventListener("click", () => switchEngine(button.dataset.engine));
  });

  treeSvg.addEventListener("click", (event) => {
    const target = event.target;
    if (target instanceof SVGElement && target.dataset.ply) {
      state.currentPly = Number(target.dataset.ply);
      void analyzeCurrent();
    }
  });

  komiInput.addEventListener("change", () => {
    saveAppState("komi");
    void analyzeCurrent();
  });

  rootNoiseInput.addEventListener("change", () => {
    void analyzeCurrent();
  });

  document.querySelectorAll("[data-lang]").forEach((button) => {
    button.addEventListener("click", () => {
      state.language = button.dataset.lang;
      languageGate.hidden = true;
      saveAppState("language");
    });
  });
  skipIcloudButton.addEventListener("click", () => {
    if (!state.language) {
      state.language = "zh-Hans";
    }
    languageGate.hidden = true;
    saveAppState("skip-icloud");
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      saveAppState("background");
    }
  });
  window.addEventListener("pagehide", () => saveAppState("pagehide"));
  window.addEventListener("beforeunload", () => saveAppState("beforeunload"));
  setInterval(() => saveAppState("twenty-minute"), 20 * 60 * 1000);
}

async function boot() {
  loadingText.textContent = "正在加载上一次的存档";
  loadingBar.style.width = "28%";
  loadAppState();
  renderAllStatic();
  await new Promise((resolve) => setTimeout(resolve, 180));
  loadingText.textContent = "正在恢复分析缓存";
  loadingBar.style.width = "68%";
  await new Promise((resolve) => setTimeout(resolve, 180));
  document.querySelectorAll(".engine-switch button").forEach((button) => button.classList.toggle("is-selected", button.dataset.engine === state.activeEngine));
  loadingText.textContent = "正在准备棋盘";
  loadingBar.style.width = "100%";
  await new Promise((resolve) => setTimeout(resolve, 180));
  loadingOverlay.classList.add("is-hidden");
  if (!state.language) {
    languageGate.hidden = false;
  }
  try {
    const response = await fetch("/api/status");
    const result = await response.json();
    setStatus(result.engine, result.state);
  } catch {
    setStatus("backend", "offline");
  }
  wireEvents();
  if (state.activeEngine !== "none") {
    await switchEngine(state.activeEngine);
  } else {
    await analyzeCurrent();
  }
}

void boot();
