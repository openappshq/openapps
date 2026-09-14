import { findExact, search, type EmojiEntry, type Suggestion } from "./matcher";
import {
  findActiveQuery,
  findClosedShortcode,
  findShortcodeToken,
  replaceRange,
  type ActiveQuery,
} from "./trigger";

/** Suggestions the pill holds; about seven fit, the rest scroll. */
export const PICKER_LIMIT = 12;

/** Everything the shortcode picker needs to know about one text field. */
export interface FieldState {
  value: string;
  caret: number;
  /** End of the selection; equals `caret` when nothing is selected. */
  selectionEnd: number;
  selected: number;
  /** Opening-colon index of the token the user dismissed with Esc. */
  dismissedAt: number | null;
}

export interface FieldContext {
  entries: readonly EmojiEntry[];
  /** Insert history, most recent first, repeats allowed. */
  recent: readonly string[];
  /** Whether the field is being typed in (focused, or driven by the demo autoplay). */
  active: boolean;
}

export type FieldAction =
  /** The field's text changed, as reported by an input event. */
  | {
      type: "input";
      value: string;
      caret: number;
      selectionEnd?: number;
      inputType?: string;
      data?: string | null;
    }
  | { type: "caret"; caret: number; selectionEnd?: number }
  | { type: "key"; key: string; modified?: boolean }
  | { type: "pick"; index: number }
  | { type: "reset"; value: string };

export interface FieldView {
  token: ActiveQuery | null;
  suggestions: Suggestion[];
  open: boolean;
  activeIndex: number;
}

export interface FieldResult {
  state: FieldState;
  /** True when the picker consumed a key, so the default action must be prevented. */
  handled: boolean;
  inserted?: string;
}

export const initialFieldState = (value: string): FieldState => ({
  value,
  caret: value.length,
  selectionEnd: value.length,
  selected: 0,
  dismissedAt: null,
});

export function viewField(state: FieldState, ctx: FieldContext): FieldView {
  // A range selection means the user is editing text, not typing a shortcode.
  const collapsed = state.selectionEnd === state.caret;
  const token = ctx.active && collapsed ? findActiveQuery(state.value, state.caret) : null;
  const suggestions = token
    ? search(ctx.entries, token.query, { recent: ctx.recent, limit: PICKER_LIMIT })
    : [];
  const open = token !== null && token.start !== state.dismissedAt && suggestions.length > 0;
  const activeIndex = Math.min(state.selected, Math.max(0, suggestions.length - 1));
  return { token, suggestions, open, activeIndex };
}

/** Applies a text/caret change, resetting selection and Esc dismissal when the token changes. */
function moveTo(state: FieldState, value: string, caret: number, selectionEnd = caret): FieldState {
  const before = findActiveQuery(state.value, state.caret);
  const after = findActiveQuery(value, caret);
  const selected =
    before?.query === after?.query && before?.start === after?.start ? state.selected : 0;
  const dismissedAt =
    state.dismissedAt !== null && findShortcodeToken(value, caret)?.start === state.dismissedAt
      ? state.dismissedAt
      : null;
  return { value, caret, selectionEnd, selected, dismissedAt };
}

function insertEmoji(state: FieldState, start: number, end: number, emoji: string): FieldResult {
  const next = replaceRange(state.value, start, end, emoji);
  return { state: moveTo(state, next.text, next.caret), handled: true, inserted: emoji };
}

export function reduceField(
  state: FieldState,
  action: FieldAction,
  ctx: FieldContext,
): FieldResult {
  switch (action.type) {
    case "reset":
      return { state: initialFieldState(action.value), handled: false };
    case "caret":
      return {
        state: moveTo(state, state.value, action.caret, action.selectionEnd),
        handled: false,
      };
    case "input": {
      if (action.inputType === "insertText" && action.data === ":") {
        const closed = findClosedShortcode(action.value, action.caret);
        const match =
          closed && closed.start !== state.dismissedAt && findExact(ctx.entries, closed.query);
        if (closed && match) {
          const typed = {
            ...state,
            value: action.value,
            caret: action.caret,
            selectionEnd: action.caret,
          };
          return insertEmoji(typed, closed.start, closed.end, match.emoji);
        }
      }
      return {
        state: moveTo(state, action.value, action.caret, action.selectionEnd),
        handled: false,
      };
    }
    case "pick": {
      const view = viewField(state, ctx);
      const suggestion = view.suggestions[action.index];
      if (!view.open || !view.token || !suggestion) return { state, handled: false };
      return insertEmoji(state, view.token.start, view.token.end, suggestion.entry.emoji);
    }
    case "key": {
      const view = viewField(state, ctx);
      // Modified keys (Shift+←, ⌥→, ⌘↑, Shift+Return…) belong to the app being typed in.
      if (!view.open || !view.token || action.modified) return { state, handled: false };
      const count = view.suggestions.length;
      switch (action.key) {
        case "ArrowDown":
        case "ArrowRight":
          return { state: { ...state, selected: (view.activeIndex + 1) % count }, handled: true };
        case "ArrowUp":
        case "ArrowLeft":
          return {
            state: { ...state, selected: (view.activeIndex - 1 + count) % count },
            handled: true,
          };
        case "Enter":
        case "Tab":
          return reduceField(state, { type: "pick", index: view.activeIndex }, ctx);
        case "Escape":
          return { state: { ...state, dismissedAt: view.token.start }, handled: true };
        default:
          return { state, handled: false };
      }
    }
  }
}

/** The input action a keyboard would produce by typing `char` at the caret. */
export function typedChar(state: FieldState, char: string): FieldAction {
  const next = replaceRange(state.value, state.caret, state.caret, char);
  return {
    type: "input",
    value: next.text,
    caret: next.caret,
    inputType: "insertText",
    data: char,
  };
}
