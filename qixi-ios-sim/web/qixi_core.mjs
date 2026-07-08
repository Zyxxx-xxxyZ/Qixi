export const BOARD_SIZE = 19;
export const BOARD_PAD = 6.25;
export const BOARD_STEP = 840 / 18 / 960 * 100;
export const LETTERS = "ABCDEFGHJKLMNOPQRST";

export function intersectionPoint(x, y) {
  return {
    xPercent: BOARD_PAD + x * BOARD_STEP,
    yPercent: BOARD_PAD + y * BOARD_STEP,
    left: `${BOARD_PAD + x * BOARD_STEP}%`,
    top: `${BOARD_PAD + y * BOARD_STEP}%`,
  };
}

export function coordOfPoint(x, y) {
  return `${LETTERS[x]}${BOARD_SIZE - y}`;
}

export function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function lerpColor(a, b, t) {
  return [
    Math.round(lerp(a[0], b[0], t)),
    Math.round(lerp(a[1], b[1], t)),
    Math.round(lerp(a[2], b[2], t)),
  ];
}

function rgba(rgb, alpha) {
  return `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${alpha.toFixed(3)})`;
}

const GREEN = [37, 165, 106];
const YELLOW = [254, 199, 0];
const ORANGE = [243, 122, 32];
const RED = [199, 46, 77];
const BLACK_RED = [58, 10, 18];

export function candidateColor(kPercent) {
  const k = Math.min(0, kPercent);
  if (k >= -3) {
    const t = clamp((k + 3) / 3, 0, 1);
    return { css: rgba(GREEN, lerp(0.56, 0.92, t)), category: "good" };
  }
  if (k >= -5) {
    const t = clamp((-k - 3) / 2, 0, 1);
    const rgb = lerpColor(GREEN, YELLOW, t);
    return { css: rgba(rgb, lerp(0.56, 0.5, t)), category: "question" };
  }
  if (k >= -10) {
    const t = clamp((-k - 5) / 5, 0, 1);
    const rgb = lerpColor(YELLOW, ORANGE, t);
    return { css: rgba(rgb, lerp(0.5, 0.48, t)), category: "mistake" };
  }
  if (k >= -20) {
    const t = clamp((-k - 10) / 10, 0, 1);
    const rgb = lerpColor(ORANGE, RED, t);
    return { css: rgba(rgb, lerp(0.48, 0.82, t)), category: "bad" };
  }
  const t = clamp((-k - 20) / 20, 0, 1);
  const rgb = lerpColor(RED, BLACK_RED, t);
  return { css: rgba(rgb, lerp(0.82, 0.94, t)), category: "blunder" };
}

export function normalizedHistory(moves) {
  return moves.map((move, idx) => {
    const color = String(move.color || "B").toUpperCase();
    if (move.pass || move.move === "pass") {
      return { idx, color, move: "pass" };
    }
    return {
      idx,
      color,
      x: Number(move.x),
      y: Number(move.y),
      move: coordOfPoint(Number(move.x), Number(move.y)),
    };
  });
}

export function historyPayload(moves, engine = "none", komi = 7.5, rules = "Chinese") {
  return {
    boardSize: BOARD_SIZE,
    engine,
    komi,
    rules,
    history: normalizedHistory(moves),
  };
}

export function samePoint(a, b) {
  return !a.pass && !b.pass && Number(a.x) === Number(b.x) && Number(a.y) === Number(b.y);
}
