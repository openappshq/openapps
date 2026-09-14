export type AppId = "messages" | "notes" | "mail";

export type AutoplayOp =
  | { kind: "app"; app: AppId }
  | { kind: "reset" }
  | { kind: "type"; char: string }
  | { kind: "key"; key: string }
  | { kind: "wait" };

export interface TimedOp {
  /** Milliseconds to wait before running the op. */
  delay: number;
  op: AutoplayOp;
}

export interface Scene {
  app: AppId;
  text: string;
  /** Keys pressed after typing, e.g. arrows then Return. */
  keys: string[];
  /** Pause after the scene, in milliseconds. */
  hold: number;
}

export const scenes: Scene[] = [
  {
    app: "messages",
    text: "Launch is live :tad",
    keys: ["ArrowRight", "ArrowLeft", "Enter", "Enter"],
    hold: 1800,
  },
  { app: "notes", text: "Picnic on Saturday :sunf", keys: ["Enter"], hold: 1800 },
  { app: "mail", text: "You all rock :+1:", keys: [], hold: 2200 },
  {
    app: "messages",
    text: "See you there :hear",
    keys: ["ArrowRight", "ArrowRight", "Tab", "Enter"],
    hold: 1800,
  },
];

/** Turns scenes into timed ops with human-ish per-key jitter. */
export function compileScenes(
  list: readonly Scene[],
  random: () => number = Math.random,
): TimedOp[] {
  const ops: TimedOp[] = [];
  for (const scene of list) {
    ops.push({ delay: 500, op: { kind: "app", app: scene.app } });
    ops.push({ delay: 250, op: { kind: "reset" } });
    Array.from(scene.text).forEach((char, i) => {
      const base = i === 0 ? 700 : char === " " ? 110 : char === ":" ? 260 : 60;
      ops.push({ delay: Math.round(base + random() * 70), op: { kind: "type", char } });
    });
    for (const key of scene.keys) {
      ops.push({ delay: Math.round(520 + random() * 180), op: { kind: "key", key } });
    }
    ops.push({ delay: scene.hold, op: { kind: "wait" } });
  }
  return ops;
}

export type AutoplayStatus = "idle" | "running" | "paused" | "stopped";

export interface Timers {
  setTimeout: (callback: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

const defaultTimers: Timers = {
  setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
  clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/**
 * Plays timed ops in a loop. It can pause and resume (e.g. off-screen), and a
 * takeover stops it for good.
 */
export class Autoplay {
  status: AutoplayStatus = "idle";
  private ops: TimedOp[] = [];
  private index = 0;
  private timer: unknown = null;
  private readonly plan: () => TimedOp[];
  private readonly run: (op: AutoplayOp) => void;
  private readonly timers: Timers;

  constructor(
    plan: () => TimedOp[],
    run: (op: AutoplayOp) => void,
    timers: Timers = defaultTimers,
  ) {
    this.plan = plan;
    this.run = run;
    this.timers = timers;
  }

  /** Starts or resumes playback. Does nothing after a takeover. */
  play() {
    if (this.status === "running" || this.status === "stopped") return;
    if (this.status === "idle") {
      this.ops = this.plan();
      this.index = 0;
    }
    this.status = "running";
    this.scheduleNext();
  }

  pause() {
    if (this.status !== "running") return;
    this.clear();
    this.status = "paused";
  }

  /** Stops permanently. Returns true if playback had started. */
  takeover(): boolean {
    if (this.status === "stopped") return false;
    const started = this.status !== "idle";
    this.clear();
    this.status = "stopped";
    return started;
  }

  private clear() {
    if (this.timer !== null) this.timers.clearTimeout(this.timer);
    this.timer = null;
  }

  private scheduleNext() {
    const next = this.ops[this.index];
    if (!next) return;
    this.timer = this.timers.setTimeout(() => {
      this.timer = null;
      this.run(next.op);
      this.index += 1;
      if (this.index >= this.ops.length) {
        this.ops = this.plan();
        this.index = 0;
      }
      if (this.status === "running") this.scheduleNext();
    }, next.delay);
  }
}
