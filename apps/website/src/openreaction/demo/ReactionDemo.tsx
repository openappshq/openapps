import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
  type RefObject,
  type SyntheticEvent,
} from "react";
import { createPortal } from "react-dom";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { Mail, MessageCircle, NotebookPen, SendHorizontal } from "lucide-react";
import { Autoplay, compileScenes, scenes, type AppId, type AutoplayOp } from "./autoplay";
import { loadEmoji } from "./emoji";
import { filterRenderable } from "./renderable";
import type { EmojiEntry, Suggestion } from "./matcher";
import {
  MAX_RECENT,
  useShortcodeField,
  type Field,
  type ShortcodeField,
} from "./useShortcodeField";

const apps: { id: AppId; label: string; icon: ReactNode }[] = [
  { id: "messages", label: "Messages", icon: <MessageCircle size={16} /> },
  { id: "notes", label: "Notes", icon: <NotebookPen size={16} /> },
  { id: "mail", label: "Mail", icon: <Mail size={16} /> },
];

const tryCodes = [":tada", ":+1", ":sparkles", ":heart_eyes", ":rocket"];

/** What the autoplay and Try chips can do to the app on screen. */
interface AppDriver {
  type: (char: string) => void;
  key: (key: string) => void;
  /** Restores the app's starting content. */
  reset: () => void;
  /** Types text at the caret as a real input event, focusing the field. */
  insertText: (text: string) => void;
}

interface Shared {
  entries: readonly EmojiEntry[];
  recent: readonly string[];
  onInsert: (emoji: string) => void;
  layer: HTMLElement | null;
  driven: boolean;
  driverRef: RefObject<AppDriver | null>;
}

function Highlighted({ suggestion }: { suggestion: Suggestion }) {
  const matched = new Set(suggestion.matched);
  return (
    <span className="picker-name">
      :
      {Array.from(suggestion.name).map((char, i) =>
        matched.has(i) ? <b key={i}>{char}</b> : <span key={i}>{char}</span>,
      )}
      :
    </span>
  );
}

/** The parts of a field the overlays read; independent of the element type. */
type OverlayModel = Pick<
  ShortcodeField,
  "view" | "placement" | "caretPosition" | "listId" | "optionId" | "pick" | "select"
>;

function Picker({ field, layer }: { field: OverlayModel; layer: HTMLElement | null }) {
  const { view, placement, listId, optionId, pick, select } = field;
  const reducedMotion = useReducedMotion();
  const listRef = useRef<HTMLUListElement>(null);

  // Keep the selected emoji in view, leaving room for its neighbour to peek.
  useLayoutEffect(() => {
    const list = listRef.current;
    const item = list?.children[view.activeIndex] as HTMLElement | undefined;
    if (!list || !item) return;
    const peek = 14;
    const start = item.offsetLeft - peek;
    const end = item.offsetLeft + item.offsetWidth + peek - list.clientWidth;
    const target = list.scrollLeft > start ? start : list.scrollLeft < end ? end : list.scrollLeft;
    if (target !== list.scrollLeft) {
      list.scrollTo({ left: Math.max(0, target), behavior: reducedMotion ? "auto" : "smooth" });
    }
  }, [view.activeIndex, view.suggestions, reducedMotion]);

  if (!layer) return null;
  return createPortal(
    <AnimatePresence>
      {view.open && placement && (
        <motion.div
          key={view.token!.start}
          className="picker"
          style={{
            left: placement.left,
            top: placement.top,
            maxWidth: placement.maxWidth,
            transformOrigin: placement.flipped ? "24px 100%" : "24px 0",
          }}
          initial={{ opacity: 0, scale: 0.96 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: 0.98, transition: { duration: 0.1 } }}
          transition={{ type: "spring", duration: 0.18, bounce: 0.2 }}
        >
          <ul
            ref={listRef}
            id={listId}
            role="listbox"
            aria-orientation="horizontal"
            aria-label="Emoji suggestions"
          >
            {view.suggestions.map((suggestion, index) => {
              const selected = index === view.activeIndex;
              return (
                <motion.li
                  key={suggestion.entry.emoji}
                  layout
                  transition={{ type: "spring", duration: 0.24, bounce: 0.12 }}
                  id={optionId(index)}
                  role="option"
                  aria-selected={selected}
                  aria-label={`${suggestion.entry.emoji} :${suggestion.name}:`}
                  onPointerDown={(event) => event.preventDefault()}
                  onPointerEnter={(event) => event.pointerType === "mouse" && select(index)}
                  onClick={() => pick(index)}
                >
                  {selected && (
                    <motion.span
                      layoutId={`${listId}-highlight`}
                      className="picker-highlight"
                      transition={{ type: "spring", duration: 0.24, bounce: 0.12 }}
                    />
                  )}
                  <motion.span layout="position" className="picker-emoji" aria-hidden="true">
                    {suggestion.entry.emoji}
                  </motion.span>
                  {selected && (
                    <motion.span
                      className="picker-label"
                      aria-hidden="true"
                      initial={{ opacity: 0 }}
                      animate={{ opacity: 1 }}
                      transition={{ duration: 0.12, delay: 0.04 }}
                    >
                      <Highlighted suggestion={suggestion} />
                    </motion.span>
                  )}
                </motion.li>
              );
            })}
          </ul>
        </motion.div>
      )}
    </AnimatePresence>,
    layer,
  );
}

function FakeCaret({ field, layer }: { field: OverlayModel; layer: HTMLElement | null }) {
  const position = field.caretPosition;
  if (!layer || !position) return null;
  return createPortal(
    <span
      className="fake-caret"
      aria-hidden="true"
      style={{ left: position.left, top: position.top + 2, height: position.height - 4 }}
    />,
    layer,
  );
}

function insertAtCaret(el: Field | null, text: string) {
  if (!el) return;
  const start = el.selectionStart ?? el.value.length;
  const end = el.selectionEnd ?? start;
  const before = el.value.slice(0, start);
  const spacer = before && !/\s$/.test(before) ? " " : "";
  el.focus();
  el.setRangeText(spacer + text, start, end, "end");
  el.dispatchEvent(new Event("input", { bubbles: true }));
}

/** The app's main field: the one the autoplay types into and the Try chips target. */
function usePrimaryField<T extends Field>(
  shared: Shared,
  seed: string,
  extra: { onKey?: (key: string, handled: boolean) => void; onReset?: () => void } = {},
) {
  const field = useShortcodeField<T>({ ...shared, initialValue: seed });
  const extraRef = useRef(extra);
  useLayoutEffect(() => {
    extraRef.current = extra;
  });
  const { driver, reset, fieldRef } = field;
  const { driverRef } = shared;
  useLayoutEffect(() => {
    driverRef.current = {
      type: driver.type,
      key: (key) => extraRef.current.onKey?.(key, driver.key(key)),
      reset: () => {
        reset(seed);
        extraRef.current.onReset?.();
      },
      insertText: (text) => insertAtCaret(fieldRef.current, text),
    };
  }, [driver, reset, fieldRef, seed, driverRef]);
  return field;
}

interface Message {
  id: number;
  text: string;
  mine: boolean;
}

const seedMessages: Message[] = [
  { id: 1, text: "We shipped it. Launch is live!", mine: false },
  { id: 2, text: "No way. Congrats 🎉", mine: true },
  { id: 3, text: "Drinks later? Bring your best emoji game", mine: false },
];

function MessagesApp(shared: Shared) {
  const [messages, setMessages] = useState(seedMessages);
  const threadRef = useRef<HTMLOListElement>(null);
  const sendRef = useRef(() => {});
  const field = usePrimaryField<HTMLTextAreaElement>(shared, "", {
    onKey: (key, handled) => {
      if (!handled && key === "Enter") sendRef.current();
    },
    onReset: () => setMessages(seedMessages),
  });
  const send = () => {
    const text = field.value.trim();
    if (!text) return;
    setMessages((list) => [...list, { id: Date.now(), text, mine: true }]);
    field.reset("");
  };
  useLayoutEffect(() => {
    sendRef.current = send;
  });

  useEffect(() => {
    threadRef.current?.scrollTo({ top: threadRef.current.scrollHeight });
  }, [messages.length]);

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (field.onKeyDown(event)) return;
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      send();
    }
  };

  return (
    <div className="app-messages">
      <div className="messages-to">
        <span className="avatar" aria-hidden="true">
          MK
        </span>
        <span>Maya</span>
      </div>
      <ol className="thread" ref={threadRef} aria-label="Conversation with Maya">
        {messages.map((message) => (
          <motion.li
            key={message.id}
            className={message.mine ? "bubble mine" : "bubble"}
            initial={{ opacity: 0, y: 8, scale: 0.98 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
          >
            {message.text}
          </motion.li>
        ))}
      </ol>
      <div className="compose">
        <label className="sr-only" htmlFor="demo-messages">
          Message
        </label>
        <textarea
          id="demo-messages"
          rows={1}
          placeholder="iMessage · try :tada"
          {...field.fieldProps}
          onKeyDown={onKeyDown}
        />
        <button
          type="button"
          className="send"
          aria-label="Send"
          onClick={send}
          disabled={!field.value.trim()}
        >
          <SendHorizontal size={15} />
        </button>
      </div>
      <Picker field={field} layer={shared.layer} />
      <FakeCaret field={field} layer={shared.layer} />
    </div>
  );
}

const notesSeed = "Weekend plans\n\nFarmers market, then a picnic 🌻\n";

function NotesApp(shared: Shared) {
  const field = usePrimaryField<HTMLTextAreaElement>(shared, notesSeed);
  return (
    <div className="app-notes">
      <aside className="notes-list" aria-hidden="true">
        <span className="notes-group">Today</span>
        <div className="note-row is-active">
          <b>Weekend plans</b>
          <span>10:24 · Farmers market…</span>
        </div>
        <div className="note-row">
          <b>Gift ideas</b>
          <span>Yesterday · Record player</span>
        </div>
      </aside>
      <div className="note-body">
        <span className="note-date">September 14, 2026 at 10:24</span>
        <label className="sr-only" htmlFor="demo-notes">
          Note
        </label>
        <textarea id="demo-notes" {...field.fieldProps} onKeyDown={field.onKeyDown} />
      </div>
      <Picker field={field} layer={shared.layer} />
      <FakeCaret field={field} layer={shared.layer} />
    </div>
  );
}

const mailSeed = "Hi team,\n\nThanks for a great week. ";
const subjectSeed = "Offsite recap";

function MailApp(shared: Shared) {
  const subject = useShortcodeField<HTMLInputElement>({
    ...shared,
    driven: false,
    initialValue: subjectSeed,
  });
  const body = usePrimaryField<HTMLTextAreaElement>(shared, mailSeed, {
    onReset: () => subject.reset(subjectSeed),
  });
  return (
    <div className="app-mail">
      <div className="mail-row">
        <span>To:</span> <span className="token-chip">Design Team</span>
      </div>
      <div className="mail-row">
        <label htmlFor="demo-subject">Subject:</label>
        <input id="demo-subject" {...subject.fieldProps} onKeyDown={subject.onKeyDown} />
      </div>
      <label className="sr-only" htmlFor="demo-mail">
        Message body
      </label>
      <textarea id="demo-mail" {...body.fieldProps} onKeyDown={body.onKeyDown} />
      <Picker field={subject} layer={shared.layer} />
      <Picker field={body} layer={shared.layer} />
      <FakeCaret field={body} layer={shared.layer} />
    </div>
  );
}

const isField = (target: EventTarget) =>
  target instanceof HTMLTextAreaElement || target instanceof HTMLInputElement;

export default function ReactionDemo() {
  const reducedMotion = useReducedMotion();
  const [app, setApp] = useState<AppId>("messages");
  const [entries, setEntries] = useState<readonly EmojiEntry[]>([]);
  const [recent, setRecent] = useState<readonly string[]>([]);
  const [announcement, setAnnouncement] = useState("");
  const [autoplaying, setAutoplaying] = useState(true);
  const [layer, setLayer] = useState<HTMLDivElement | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const driverRef = useRef<AppDriver | null>(null);
  const autoplayingRef = useRef(true);

  const runOp = useCallback((op: AutoplayOp) => {
    const driver = driverRef.current;
    if (op.kind === "app") setApp(op.app);
    else if (op.kind === "reset") {
      driver?.reset();
      setRecent([]);
    } else if (op.kind === "type") driver?.type(op.char);
    else if (op.kind === "key") driver?.key(op.key);
  }, []);
  const autoplayRef = useRef<Autoplay | null>(null);
  // Created in an effect so the ref-reading runner is never touched during render.
  useEffect(() => {
    autoplayRef.current ??= new Autoplay(() => compileScenes(scenes), runOp);
    if (!autoplayingRef.current) autoplayRef.current.takeover();
  }, [runOp]);

  /** The visitor's first interaction ends the autoplay for good and hands over a clean app. */
  const takeOver = useCallback(() => {
    if (!autoplayingRef.current) return;
    autoplayingRef.current = false;
    autoplayRef.current?.takeover();
    setAutoplaying(false);
    driverRef.current?.reset();
    setRecent([]);
  }, []);

  useEffect(() => {
    let live = true;
    loadEmoji()
      .then((list) => live && setEntries(filterRenderable(list)))
      .catch((error: unknown) =>
        console.error("OpenReaction demo: emoji data failed to load", error),
      );
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => {
    if (reducedMotion) takeOver();
  }, [reducedMotion, takeOver]);

  useEffect(() => {
    const root = rootRef.current;
    const autoplay = autoplayRef.current;
    if (!root || !autoplay || entries.length === 0 || !autoplaying) return;
    let visible = false;
    const update = () => {
      if (visible && document.visibilityState === "visible") autoplay.play();
      else autoplay.pause();
    };
    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        update();
      },
      { threshold: 0.35 },
    );
    observer.observe(root);
    document.addEventListener("visibilitychange", update);
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", update);
      autoplay.pause();
    };
  }, [autoplaying, entries.length]);

  const onInsert = useCallback((emoji: string) => {
    setRecent((list) => [emoji, ...list].slice(0, MAX_RECENT));
    if (!autoplayingRef.current) setAnnouncement(`Inserted ${emoji}`);
  }, []);
  const shared: Shared = { entries, recent, layer, driven: autoplaying, driverRef, onInsert };
  const current = apps.find((a) => a.id === app)!;
  const onFieldFocus = (event: SyntheticEvent) => {
    if (isField(event.target)) takeOver();
  };

  return (
    <div
      className="demo"
      ref={rootRef}
      onPointerDownCapture={takeOver}
      onKeyDownCapture={takeOver}
      onFocusCapture={onFieldFocus}
    >
      <div className="demo-toolbar">
        <div className="app-choice" role="group" aria-label="Demo app">
          {apps.map(({ id, label, icon }) => (
            <button key={id} type="button" aria-pressed={app === id} onClick={() => setApp(id)}>
              {icon}
              {label}
            </button>
          ))}
        </div>
        <div className="try-codes">
          <span>Try</span>
          {tryCodes.map((code) => (
            <button
              key={code}
              type="button"
              onPointerDown={(event) => event.preventDefault()}
              onClick={() => {
                takeOver();
                requestAnimationFrame(() => driverRef.current?.insertText(code));
              }}
            >
              {code}
            </button>
          ))}
        </div>
      </div>
      <div className="demo-stage" ref={setLayer}>
        <div className="mac-window" data-app={app}>
          <div className="titlebar">
            <span className="traffic" aria-hidden="true">
              <i />
              <i />
              <i />
            </span>
            <span className="window-title">
              {current.icon}
              {current.label}
            </span>
            {autoplaying && entries.length > 0 && (
              <span className="autoplay-badge" aria-hidden="true">
                Demo · tap to type
              </span>
            )}
          </div>
          <div className="window-body">
            {entries.length === 0 ? (
              <p className="demo-loading">Loading emoji…</p>
            ) : app === "messages" ? (
              <MessagesApp key="messages" {...shared} />
            ) : app === "notes" ? (
              <NotesApp key="notes" {...shared} />
            ) : (
              <MailApp key="mail" {...shared} />
            )}
          </div>
        </div>
      </div>
      <p className="demo-caption">
        A browser recreation of the Mac app. Type <kbd>:</kbd> and two letters, choose with{" "}
        <kbd>←</kbd> <kbd>→</kbd>, insert with <kbd>Return</kbd> or <kbd>Tab</kbd>. Type the closing{" "}
        <kbd>:</kbd> to insert an exact match.
      </p>
      <p className="sr-only" aria-live="polite">
        {announcement}
      </p>
    </div>
  );
}
