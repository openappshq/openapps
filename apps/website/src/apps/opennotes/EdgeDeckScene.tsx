/**
 * The idea, drawn: a Mac in a full-screen app, and OpenNotes's deck on the
 * right edge. Pure CSS, one 12-second loop: the pointer drifts to the edge,
 * the resting paper edges widen into the fan of tabs, one tab is pressed and
 * its note slides out over the app, a checklist item gets ticked, then the
 * tabs fold back into their edges. Reduced motion shows the fan with the note
 * out, the state that says the most. Decorative; the copy beside it says what
 * it shows.
 */
const notes = [
  { tone: "coral", label: "Standup" },
  { tone: "yellow", label: "Grocery" },
  { tone: "green", label: "Ideas" },
  { tone: "cobalt", label: "Later" },
] as const;

export default function EdgeDeckScene() {
  return (
    <div className="on-scene" aria-hidden="true">
      <div className="on-screen">
        {/* A full-screen app: no menu bar, the canvas goes to every edge. */}
        <div className="on-app">
          <span className="on-app-title" />
          <span className="on-app-line" />
          <span className="on-app-line is-short" />
          <div className="on-app-blocks">
            <span />
            <span />
            <span />
          </div>
        </div>
        <span className="on-pointer" />
        <div className="on-rest">
          {notes.map((note) => (
            <span key={note.label} className={`on-edge is-${note.tone}`} />
          ))}
          <span className="on-edge-add" />
        </div>
        <div className="on-fan">
          {notes.map((note, index) => (
            <span
              key={note.label}
              className={`on-tab is-${note.tone}`}
              style={{ "--i": index } as React.CSSProperties}
            >
              {note.label}
            </span>
          ))}
          <span className="on-tab-add">+</span>
        </div>
        <div className="on-note is-coral">
          <span className="on-note-title">Standup</span>
          <span className="on-note-line">
            <span className="on-tick" /> ask about the feed key
          </span>
          <span className="on-note-line">
            <span className="on-tick is-ticking" /> reply re ⌘W focus
          </span>
          <span className="on-note-line">
            release notes: paste as <b>plain</b> text
          </span>
          <span className="on-note-foot">
            <span>standup.md</span>
            <span>saved</span>
          </span>
        </div>
      </div>
    </div>
  );
}
