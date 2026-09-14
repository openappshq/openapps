import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";
import { Autoplay, compileScenes, scenes, type AutoplayOp, type TimedOp } from "./autoplay";
import { initialFieldState, reduceField, typedChar, type FieldState } from "./fieldState";
import { readEmoji } from "./dataset";

const ops: TimedOp[] = [
  { delay: 100, op: { kind: "type", char: "a" } },
  { delay: 50, op: { kind: "type", char: "b" } },
  { delay: 200, op: { kind: "key", key: "Enter" } },
];

function setup() {
  const ran: AutoplayOp[] = [];
  const plan = vi.fn(() => ops);
  const autoplay = new Autoplay(plan, (op) => ran.push(op));
  return { autoplay, ran, plan };
}

describe("Autoplay", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("runs ops in order after their delays", () => {
    const { autoplay, ran } = setup();
    autoplay.play();
    vi.advanceTimersByTime(99);
    expect(ran).toHaveLength(0);
    vi.advanceTimersByTime(1);
    expect(ran).toEqual([ops[0].op]);
    vi.advanceTimersByTime(250);
    expect(ran).toEqual(ops.map((o) => o.op));
  });

  it("loops with a freshly planned script", () => {
    const { autoplay, ran, plan } = setup();
    autoplay.play();
    vi.advanceTimersByTime(350 + 100);
    expect(ran).toHaveLength(4);
    expect(plan).toHaveBeenCalledTimes(2);
  });

  it("pauses without losing its place and resumes from the pending op", () => {
    const { autoplay, ran } = setup();
    autoplay.play();
    vi.advanceTimersByTime(120);
    autoplay.pause();
    vi.advanceTimersByTime(10_000);
    expect(ran).toHaveLength(1);
    expect(autoplay.status).toBe("paused");
    autoplay.play();
    vi.advanceTimersByTime(50);
    expect(ran).toEqual([ops[0].op, ops[1].op]);
  });

  it("stops for good on takeover", () => {
    const { autoplay, ran } = setup();
    autoplay.play();
    vi.advanceTimersByTime(100);
    expect(autoplay.takeover()).toBe(true);
    vi.advanceTimersByTime(10_000);
    autoplay.play();
    vi.advanceTimersByTime(10_000);
    expect(ran).toHaveLength(1);
    expect(autoplay.status).toBe("stopped");
    expect(autoplay.takeover()).toBe(false);
  });

  it("never starts if taken over before playing", () => {
    const { autoplay, ran } = setup();
    expect(autoplay.takeover()).toBe(false);
    autoplay.play();
    vi.advanceTimersByTime(10_000);
    expect(ran).toHaveLength(0);
  });

  it("ignores pause and duplicate play calls while not running", () => {
    const { autoplay, ran } = setup();
    autoplay.pause();
    expect(autoplay.status).toBe("idle");
    autoplay.play();
    autoplay.play();
    vi.advanceTimersByTime(100);
    expect(ran).toHaveLength(1);
  });
});

describe("compileScenes", () => {
  it("switches app, resets, types each character, then presses keys", () => {
    const [scene] = scenes;
    const compiled = compileScenes([scene], () => 0.5);
    expect(compiled[0].op).toEqual({ kind: "app", app: scene.app });
    expect(compiled[1].op).toEqual({ kind: "reset" });
    const typed = compiled
      .filter((o) => o.op.kind === "type")
      .map((o) => (o.op as { char: string }).char);
    expect(typed.join("")).toBe(scene.text);
    const keys = compiled
      .filter((o) => o.op.kind === "key")
      .map((o) => (o.op as { key: string }).key);
    expect(keys).toEqual(scene.keys);
    expect(compiled.at(-1)!.op.kind).toBe("wait");
  });

  it("jitters typing delays", () => {
    const low = compileScenes(scenes, () => 0).map((o) => o.delay);
    const high = compileScenes(scenes, () => 0.99).map((o) => o.delay);
    expect(high.some((d, i) => d > low[i])).toBe(true);
  });

  it("every scripted scene inserts an emoji through the real field pipeline", async () => {
    const entries = readEmoji();
    const ctx = { entries, recent: [], active: true };
    for (const scene of scenes) {
      let state: FieldState = initialFieldState("");
      const inserted: string[] = [];
      for (const { op } of compileScenes([scene])) {
        const action =
          op.kind === "type"
            ? typedChar(state, op.char)
            : op.kind === "key"
              ? { type: "key" as const, key: op.key }
              : null;
        if (!action) continue;
        const result = reduceField(state, action, ctx);
        state = result.state;
        if (result.inserted) inserted.push(result.inserted);
      }
      expect(inserted, scene.text).toHaveLength(1);
      expect(state.value, scene.text).not.toContain(":");
    }
  });
});
