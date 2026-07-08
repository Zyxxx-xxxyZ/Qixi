import assert from "node:assert/strict";
import {
  BOARD_PAD,
  BOARD_STEP,
  candidateColor,
  historyPayload,
  intersectionPoint,
} from "../web/qixi_core.mjs";

function parseRgba(css) {
  const match = css.match(/rgba\((\d+), (\d+), (\d+), ([0-9.]+)\)/);
  assert(match, `not rgba: ${css}`);
  return match.slice(1).map(Number);
}

function close(a, b, eps = 1e-9) {
  assert(Math.abs(a - b) <= eps, `${a} != ${b}`);
}

close(BOARD_PAD, 6.25);
close(BOARD_STEP, 4.861111111111111, 1e-10);
close(intersectionPoint(0, 0).xPercent, 6.25);
close(intersectionPoint(0, 0).yPercent, 6.25);
close(intersectionPoint(18, 18).xPercent, 93.75);
close(intersectionPoint(18, 18).yPercent, 93.75);
close(intersectionPoint(9, 9).xPercent, 50);
close(intersectionPoint(9, 9).yPercent, 50);

for (const boundary of [-3, -5, -10, -20]) {
  const left = parseRgba(candidateColor(boundary - 1e-8).css);
  const exact = parseRgba(candidateColor(boundary).css);
  for (let i = 0; i < 4; i++) {
    assert(Math.abs(left[i] - exact[i]) <= 1, `candidate color discontinuity at ${boundary}: ${left} vs ${exact}`);
  }
}

const historyA = historyPayload([
  { color: "B", x: 3, y: 3 },
  { color: "W", x: 15, y: 15 },
  { color: "B", x: 16, y: 3 },
  { color: "W", x: 2, y: 15 },
], "b6");
const historyB = historyPayload([
  { color: "B", x: 16, y: 3 },
  { color: "W", x: 2, y: 15 },
  { color: "B", x: 3, y: 3 },
  { color: "W", x: 15, y: 15 },
], "b6");
assert.notDeepEqual(historyA.history, historyB.history);

console.log("UI contract tests passed");
