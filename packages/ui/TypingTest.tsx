import { Button, TextArea } from "@heroui/react";
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { typingWords, typingScore } from "./typing";

export function TypingTest() {
  const [duration, setDuration] = useState(30);
  const [target, setTarget] = useState(typingWords);
  const [text, setText] = useState("");
  const [elapsed, setElapsed] = useState(0);
  const [focused, setFocused] = useState(false);
  const [running, setRunning] = useState(false);
  const started = useRef<number | null>(null);
  const field = useRef<HTMLTextAreaElement>(null);
  const focusOnRestart = useRef(false);
  const stream = useRef<HTMLDivElement>(null);
  const activeWord = useRef<HTMLSpanElement>(null);
  const description = useId();
  const done = duration > 0 && elapsed >= duration;
  const typed = text.split(" ");
  const current = typed.length - 1;
  const score = typingScore(text, target, Math.min(elapsed, duration || elapsed));
  useEffect(() => {
    if (!running || !duration) return;
    const timer = setInterval(() => {
      const time = (performance.now() - started.current!) / 1000;
      setElapsed(Math.min(time, duration));
      if (time >= duration) setRunning(false);
    }, 100);
    return () => clearInterval(timer);
  }, [running, duration]);
  useLayoutEffect(() => {
    if (focusOnRestart.current) {
      field.current?.focus({ preventScroll: true });
      focusOnRestart.current = false;
    }
    if (!stream.current || !activeWord.current) return;
    const lineHeight = parseFloat(getComputedStyle(activeWord.current).lineHeight);
    const offset = Math.max(0, activeWord.current.offsetTop - lineHeight);
    stream.current.style.transform = `translateY(${-offset}px)`;
  }, [text, target, duration]);
  function restart(nextDuration = duration) {
    setDuration(nextDuration);
    setTarget(typingWords());
    setText("");
    setElapsed(0);
    started.current = null;
    setRunning(false);
    focusOnRestart.current = true;
  }
  return (
    <section className="typing-test" aria-label="Typing playground">
      <div className="typing-toolbar">
        <div className="typing-modes" role="group" aria-label="Typing duration">
          {[15, 30, 60, 0].map((seconds) => (
            <Button
              variant="ghost"
              type="button"
              key={seconds}
              aria-pressed={seconds === duration}
              onPress={() => restart(seconds)}
            >
              {seconds ? `${seconds}s` : "Free type"}
            </Button>
          ))}
        </div>
        {!done && (
          <Button
            variant="ghost"
            className="typing-restart"
            type="button"
            onPress={() => restart()}
            aria-label="Restart typing test"
          >
            Restart ↻
          </Button>
        )}
      </div>
      <div className="typing-session">
        {!done && (
          <div className="typing-progress">
            <span className="typing-timer">
              {duration ? `${Math.ceil(duration - elapsed)}s` : "∞"}
            </span>
            <span>
              {done
                ? "Test complete"
                : running
                  ? ""
                  : focused
                    ? "Start typing"
                    : "Click the words to begin"}
            </span>
          </div>
        )}
        {done ? (
          <div className="typing-results" role="status">
            <dl>
              <div>
                <dt>WPM</dt>
                <dd>{score.wpm}</dd>
              </div>
              <div>
                <dt>Accuracy</dt>
                <dd>
                  {score.accuracy}
                  <small>%</small>
                </dd>
              </div>
            </dl>
            <Button variant="ghost" type="button" onPress={() => restart()}>
              Try again ↻
            </Button>
          </div>
        ) : (
          <div className={`typing-surface ${focused ? "typing-focused" : ""}`}>
            {duration > 0 && (
              <div ref={stream} className="typing-passage" aria-hidden="true">
                {target.split(" ").map((word, index) => {
                  const entered = typed[index] ?? "";
                  return (
                    <span
                      key={index}
                      ref={index === current ? activeWord : undefined}
                      className={`typing-word ${index < current && entered !== word ? "wrong-word" : ""}`}
                    >
                      {Array.from({ length: Math.max(word.length, entered.length) }, (_, i) => (
                        <span
                          key={i}
                          className={`${i < entered.length ? (entered[i] === word[i] ? "correct" : "incorrect") : ""} ${index === current && i === entered.length ? "typing-caret" : ""}`}
                        >
                          {word[i] ?? entered[i]}
                        </span>
                      ))}
                      {index === current && entered.length >= word.length && (
                        <span className="typing-caret end-caret" />
                      )}
                    </span>
                  );
                })}
              </div>
            )}
            <TextArea
              ref={field}
              data-sound-input
              aria-label={duration ? "Type the words" : "Try your keyboard sound"}
              aria-describedby={duration ? description : undefined}
              value={text}
              className={duration ? "timed-input" : "free-input"}
              spellCheck={false}
              autoCorrect="off"
              autoCapitalize="off"
              placeholder={duration ? undefined : "Type anything…"}
              maxLength={3000}
              onFocus={() => setFocused(true)}
              onBlur={() => setFocused(false)}
              onPaste={(event) => {
                if (duration) event.preventDefault();
              }}
              onKeyDown={(event) => {
                if (
                  duration &&
                  [
                    "ArrowLeft",
                    "ArrowRight",
                    "ArrowUp",
                    "ArrowDown",
                    "Home",
                    "End",
                    "Enter",
                  ].includes(event.key)
                )
                  event.preventDefault();
              }}
              onSelect={(event) => {
                if (duration) event.currentTarget.setSelectionRange(text.length, text.length);
              }}
              onChange={(event) => {
                const now = performance.now();
                if (
                  duration &&
                  started.current !== null &&
                  now - started.current >= duration * 1000
                ) {
                  setElapsed(duration);
                  setRunning(false);
                  return;
                }
                const next = duration
                  ? event.target.value.replace(/\s+/g, " ").trimStart()
                  : event.target.value;
                setText(next);
                if (started.current === null && next.length) {
                  started.current = now;
                  setRunning(true);
                }
              }}
            />
          </div>
        )}
      </div>
      <span className="sr-only" id={description}>
        Type these words in order. Use Space for the next word and Backspace to correct: {target}
      </span>
    </section>
  );
}
