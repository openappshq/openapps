import {
  useCallback,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type KeyboardEvent,
} from "react";
import { caretRect } from "./caret";
import type { EmojiEntry } from "./matcher";
import {
  initialFieldState,
  reduceField,
  typedChar,
  viewField,
  type FieldAction,
  type FieldContext,
  type FieldResult,
} from "./fieldState";

export type Field = HTMLTextAreaElement | HTMLInputElement;

export const PILL_HEIGHT = 52;
const PILL_ITEM = 40;
const PILL_PADDING = 6;
const PILL_MAX_WIDTH = 440;
const PILL_LEADING = 26;
const LABEL_CHAR = 7.8;
const LABEL_MAX = 180;
const LABEL_TRAILING = 12;
/** Insert history kept for frecency ranking (most recent first, repeats allowed). */
export const MAX_RECENT = 50;
const CARET_GAP = 6;
const EDGE = 8;

export interface PickerPlacement {
  left: number;
  top: number;
  maxWidth: number;
  flipped: boolean;
}

export interface CaretPosition {
  left: number;
  top: number;
  height: number;
}

/** Imperative input used by the demo autoplay; it feeds the same reducer as real typing. */
export interface FieldDriver {
  type: (char: string) => void;
  /** Returns true when the picker consumed the key. */
  key: (key: string) => boolean;
}

interface Options {
  initialValue: string;
  entries: readonly EmojiEntry[];
  recent: readonly string[];
  onInsert: (emoji: string) => void;
  /** Positioned element the picker and fake caret are laid out in. */
  layer: HTMLElement | null;
  /** Typed by the autoplay rather than the user; shows the picker without focus. */
  driven: boolean;
}

/** Shortcode autocomplete behavior for a text field, mirroring the Mac app. */
export function useShortcodeField<T extends Field>({
  initialValue,
  entries,
  recent,
  onInsert,
  layer,
  driven,
}: Options) {
  const fieldRef = useRef<T>(null);
  const listId = useId();
  const [state, setState] = useState(() => initialFieldState(initialValue));
  const [focused, setFocused] = useState(false);
  const [placement, setPlacement] = useState<PickerPlacement | null>(null);
  const [caretPosition, setCaretPosition] = useState<CaretPosition | null>(null);
  const stateRef = useRef(state);
  const pendingCaret = useRef<number | null>(null);

  const active = focused || driven;
  const ctx = useMemo<FieldContext>(() => ({ entries, recent, active }), [entries, recent, active]);
  const ctxRef = useRef(ctx);
  useLayoutEffect(() => {
    ctxRef.current = ctx;
  }, [ctx]);
  const view = useMemo(() => viewField(state, ctx), [state, ctx]);

  const dispatch = useCallback(
    (action: FieldAction): FieldResult => {
      const result = reduceField(stateRef.current, action, ctxRef.current);
      stateRef.current = result.state;
      setState(result.state);
      if (result.inserted) onInsert(result.inserted);
      return result;
    },
    [onInsert],
  );

  const reset = useCallback(
    (value: string) => {
      dispatch({ type: "reset", value });
      pendingCaret.current = value.length;
    },
    [dispatch],
  );

  const driver: FieldDriver = useMemo(
    () => ({
      type: (char) => {
        dispatch(typedChar(stateRef.current, char));
      },
      key: (key) => dispatch({ type: "key", key }).handled,
    }),
    [dispatch],
  );

  // Keep the DOM caret in sync after the reducer rewrites the text, without ever taking focus.
  useLayoutEffect(() => {
    const field = fieldRef.current;
    if (!field || pendingCaret.current === null) return;
    if (document.activeElement === field) {
      field.setSelectionRange(pendingCaret.current, pendingCaret.current);
    }
    pendingCaret.current = null;
  });

  useLayoutEffect(() => {
    const field = fieldRef.current;
    if (!field || !layer) return;
    const fieldBox = field.getBoundingClientRect();
    const layerBox = layer.getBoundingClientRect();
    const originX = fieldBox.left - layerBox.left;
    const originY = fieldBox.top - layerBox.top;

    if (driven) {
      const rect = caretRect(field, state.caret);
      setCaretPosition({ left: originX + rect.left, top: originY + rect.top, height: rect.height });
    } else {
      setCaretPosition(null);
    }

    if (!view.open || !view.token) {
      setPlacement(null);
      return;
    }
    const rect = caretRect(field, view.token.start);
    const selected = view.suggestions[view.activeIndex];
    const label = selected
      ? Math.min(LABEL_MAX, (selected.name.length + 2) * LABEL_CHAR) + LABEL_TRAILING
      : 0;
    const maxWidth = Math.min(PILL_MAX_WIDTH, layer.clientWidth - 2 * EDGE);
    const width = Math.min(
      maxWidth,
      view.suggestions.length * PILL_ITEM + label + 2 * PILL_PADDING,
    );
    const below = originY + rect.top + rect.height + CARET_GAP;
    const flipped = below + PILL_HEIGHT > layer.clientHeight - EDGE;
    setPlacement({
      // Centers the first emoji under the opening colon.
      left: Math.max(
        EDGE,
        Math.min(originX + rect.left - PILL_LEADING + 6, layer.clientWidth - width - EDGE),
      ),
      top: flipped ? Math.max(EDGE, originY + rect.top - CARET_GAP - PILL_HEIGHT) : below,
      maxWidth,
      flipped,
    });
  }, [layer, driven, state, view]);

  const syncCaret = () => {
    const field = fieldRef.current;
    if (!field) return;
    const caret = field.selectionStart ?? field.value.length;
    const selectionEnd = field.selectionEnd ?? caret;
    const current = stateRef.current;
    if (caret !== current.caret || selectionEnd !== current.selectionEnd) {
      dispatch({ type: "caret", caret, selectionEnd });
    }
  };

  const onChange = (event: ChangeEvent<T>) => {
    const field = event.target;
    const caret = field.selectionStart ?? field.value.length;
    const native = event.nativeEvent as Partial<InputEvent>;
    const result = dispatch({
      type: "input",
      value: field.value,
      caret,
      selectionEnd: field.selectionEnd ?? caret,
      inputType: native.inputType,
      data: native.data,
    });
    if (result.state.value !== field.value) pendingCaret.current = result.state.caret;
  };

  /** Returns true when the key was handled by the picker. */
  const onKeyDown = (event: KeyboardEvent<T>): boolean => {
    if (event.nativeEvent.isComposing) return false;
    const modified = event.shiftKey || event.altKey || event.metaKey || event.ctrlKey;
    const result = dispatch({ type: "key", key: event.key, modified });
    if (result.handled) {
      event.preventDefault();
      if (result.state.value !== stateRef.current.value || result.inserted) {
        pendingCaret.current = result.state.caret;
      }
    }
    return result.handled;
  };

  const pick = (index: number) => {
    const result = dispatch({ type: "pick", index });
    if (result.inserted) pendingCaret.current = result.state.caret;
  };

  return {
    fieldRef,
    value: state.value,
    view,
    placement,
    caretPosition,
    listId,
    optionId: (index: number) => `${listId}-option-${index}`,
    select: (index: number) => setState((s) => (stateRef.current = { ...s, selected: index })),
    pick,
    reset,
    driver,
    onKeyDown,
    fieldProps: {
      ref: fieldRef,
      value: state.value,
      onChange,
      onSelect: syncCaret,
      onFocus: () => {
        setFocused(true);
        syncCaret();
      },
      onBlur: () => setFocused(false),
      role: "combobox",
      "aria-autocomplete": "list" as const,
      "aria-expanded": view.open,
      "aria-controls": view.open ? listId : undefined,
      "aria-activedescendant": view.open ? `${listId}-option-${view.activeIndex}` : undefined,
      autoComplete: "off",
      autoCorrect: "off",
      spellCheck: false,
    },
  };
}

export type ShortcodeField = ReturnType<typeof useShortcodeField>;
