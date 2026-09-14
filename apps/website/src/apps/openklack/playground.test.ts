import { expect, test } from "vite-plus/test";
import { typingScore, typingWords } from "../../../../../packages/openklack-ui/typing";
import { recordingGain } from "./audio";
import { createInput, keyPan } from "@openklack/keyboard-layout";
test("typing scores use correct characters and elapsed time, with no phantom first word", () => {
  expect(typingScore("hello world", "hello world", 30)).toEqual({ wpm: 4, accuracy: 100 });
  expect(typingScore("hellx", "hello", 15)).toEqual({ wpm: 3, accuracy: 80 });
  expect(typingScore("helo world", "hello world", 30)).toEqual({ wpm: 4, accuracy: 90 });
  expect(typingWords(10).split(" ")).toHaveLength(10);
  expect(typingScore("", "hello", 0)).toEqual({ wpm: 0, accuracy: 100 });
});

test("recordings match levels without amplifying silence or exceeding the peak ceiling", () => {
  const quiet = new Float32Array(100).fill(0.01);
  const loud = new Float32Array(100).fill(0.5);
  expect(recordingGain([quiet], 100, [[0, 1000]]) * 0.01).toBeCloseTo(0.08);
  expect(recordingGain([loud], 100, [[0, 1000]]) * 0.5).toBeCloseTo(0.08);
  loud[0] = 1;
  expect(recordingGain([loud], 100, [[0, 1000]])).toBeLessThanOrEqual(0.8);
  expect(Number.isFinite(recordingGain([new Float32Array(100)], 100, [[0, 1000]]))).toBe(true);
});

test("key transitions wake the renderer, repeated holds do not, and stereo follows the shared layout", () => {
  const input = createInput();
  let frames = 0;
  const off = input.subscribe(() => frames++);
  input.press("KeyA", "keyboard");
  input.press("KeyA", "keyboard");
  expect(frames).toBe(1);
  input.release("KeyA", "keyboard");
  expect(frames).toBe(2);
  off();
  input.press("KeyB", "keyboard");
  expect(frames).toBe(2);
  expect(keyPan("KeyA")).toBeLessThan(0);
  expect(keyPan("Enter")).toBeGreaterThan(0);
  expect(keyPan("Char:å")).toBe(0);
});
