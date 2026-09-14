import { describe, expect, it } from "vite-plus/test";
import {
  initialFieldState,
  reduceField,
  typedChar,
  viewField,
  type FieldAction,
  type FieldContext,
  type FieldState,
} from "./fieldState";
import type { EmojiEntry } from "./matcher";

const entries: EmojiEntry[] = [
  { emoji: "🎉", names: ["tada"], keywords: ["party"] },
  { emoji: "🥳", names: ["partying_face"], keywords: [] },
  { emoji: "😄", names: ["smile"], keywords: [] },
  { emoji: "😃", names: ["smiley"], keywords: [] },
];
const ctx: FieldContext = { entries, recent: [], active: true };

function run(state: FieldState, ...actions: (FieldAction | string)[]) {
  let inserted: string | undefined;
  for (const action of actions) {
    if (typeof action === "string") {
      for (const char of action) {
        const result = reduceField(state, typedChar(state, char), ctx);
        state = result.state;
        inserted = result.inserted ?? inserted;
      }
    } else {
      const result = reduceField(state, action, ctx);
      state = result.state;
      inserted = result.inserted ?? inserted;
    }
  }
  return { state, view: viewField(state, ctx), inserted };
}

const key = (k: string): FieldAction => ({ type: "key", key: k });

describe("reduceField", () => {
  it("opens after two characters and inserts the selection on Return", () => {
    const typed = run(initialFieldState("yay "), ":sm");
    expect(typed.view.open).toBe(true);
    // 😃 is the more popular emoji, so :smiley ranks above :smile.
    expect(typed.view.suggestions.map((s) => s.name)).toEqual(["smiley", "smile"]);
    const done = run(typed.state, key("ArrowDown"), key("Enter"));
    expect(done.state).toMatchObject({ value: "yay 😄", caret: 6 });
    expect(done.inserted).toBe("😄");
    expect(done.view.open).toBe(false);
  });

  it("wraps selection with the arrow keys and resets it when the query changes", () => {
    const { state } = run(initialFieldState(""), ":sm", key("ArrowUp"));
    expect(state.selected).toBe(1);
    expect(run(state, "i").state.selected).toBe(0);
  });

  it("moves with left and right arrows too", () => {
    expect(run(initialFieldState(""), ":sm", key("ArrowRight")).state.selected).toBe(1);
    expect(run(initialFieldState(""), ":sm", key("ArrowLeft")).state.selected).toBe(1);
    expect(reduceField(initialFieldState("ab"), key("ArrowLeft"), ctx).handled).toBe(false);
  });

  it("lets modified arrows through so native selection and word movement keep working", () => {
    const open = run(initialFieldState(""), ":sm").state;
    for (const k of ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Escape"]) {
      const result = reduceField(open, { type: "key", key: k, modified: true }, ctx);
      expect(result.handled, k).toBe(false);
      expect(result.state, k).toBe(open);
    }
  });

  it("hides the picker while text is selected and inserts only over the token", () => {
    const typed = run(initialFieldState(""), ":ta").state;
    const selecting = reduceField(typed, { type: "caret", caret: 3, selectionEnd: 0 }, ctx).state;
    expect(viewField(selecting, ctx).open).toBe(false);
    expect(reduceField(selecting, key("Enter"), ctx).handled).toBe(false);
    const collapsed = reduceField(
      selecting,
      { type: "caret", caret: 3, selectionEnd: 3 },
      ctx,
    ).state;
    expect(viewField(collapsed, ctx).open).toBe(true);
    const inserted = reduceField(collapsed, key("Enter"), ctx);
    expect(inserted.state).toMatchObject({ value: "🎉", caret: 2, selectionEnd: 2 });
    const ranged = reduceField(
      typed,
      { type: "input", value: ":ta", caret: 1, selectionEnd: 3 },
      ctx,
    ).state;
    expect(viewField(ranged, ctx).open).toBe(false);
  });

  it("inserts on Tab but lets modified Return through", () => {
    expect(run(initialFieldState(""), ":ta", key("Tab")).state.value).toBe("🎉");
    const shifted = reduceField(
      run(initialFieldState(""), ":ta").state,
      { type: "key", key: "Enter", modified: true },
      ctx,
    );
    expect(shifted.handled).toBe(false);
  });

  it("does not consume keys while the picker is closed", () => {
    const result = reduceField(initialFieldState("hi"), key("Enter"), ctx);
    expect(result.handled).toBe(false);
  });

  it("replaces an exact :name: when the closing colon is typed", () => {
    const { state, inserted } = run(initialFieldState("so "), ":tada:");
    expect(state).toMatchObject({ value: "so 🎉", caret: 5 });
    expect(inserted).toBe("🎉");
    expect(run(initialFieldState(""), ":tad:").state.value).toBe(":tad:");
  });

  it("keeps Esc dismissal for the current token only", () => {
    const dismissed = run(initialFieldState(""), ":ta", key("Escape"));
    expect(dismissed.view.open).toBe(false);
    expect(run(dismissed.state, "d").view.open).toBe(false);
    expect(run(dismissed.state, "da:").state.value).toBe(":tada:");
    const next = run(dismissed.state, " :sm");
    expect(next.view.open).toBe(true);
  });

  it("reopens after backspacing over the dismissed colon and typing it again", () => {
    const dismissed = run(initialFieldState(""), ":ta", key("Escape")).state;
    const erased = run(dismissed, { type: "input", value: "", caret: 0 });
    expect(run(erased.state, ":ta").view.open).toBe(true);
  });

  it("stays closed while the field is inactive", () => {
    const { state } = run(initialFieldState(""), ":ta");
    expect(viewField(state, { ...ctx, active: false }).open).toBe(false);
  });

  it("resets to a given value", () => {
    const { state } = run(initialFieldState(""), ":ta", { type: "reset", value: "seed" });
    expect(state).toEqual(initialFieldState("seed"));
  });
});
