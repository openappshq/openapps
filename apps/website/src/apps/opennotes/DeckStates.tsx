/**
 * The deck's three states as three still frames: the paper edges at rest, the
 * fan when the pointer reaches the edge, one note out. Drawn in CSS with the
 * hero scene's parts, so the page keeps no screenshots it would have to keep
 * in step with the app. The labels are the content; the frames illustrate.
 */
const states: [string, string][] = [
  ["rest", "Rest · paper edges on the screen edge"],
  ["fan", "Reach · the tabs fan out"],
  ["write", "Write · one note, over everything"],
];

export default function DeckStates() {
  return (
    <ul className="on-states">
      {states.map(([state, label]) => (
        <li key={state}>
          <span className="on-frame" data-state={state} aria-hidden="true">
            <span className="on-frame-app" />
            <span className="on-rest">
              <span className="on-edge is-coral" />
              <span className="on-edge is-yellow" />
              <span className="on-edge is-green" />
              <span className="on-edge is-cobalt" />
              <span className="on-edge-add" />
            </span>
            <span className="on-fan">
              <span className="on-tab is-coral" />
              <span className="on-tab is-yellow" />
              <span className="on-tab is-green" />
              <span className="on-tab is-cobalt" />
            </span>
            <span className="on-note is-coral">
              <span className="on-note-title" />
              <span className="on-note-line" />
              <span className="on-note-line" />
            </span>
          </span>
          <span className="on-state-label">{label}</span>
        </li>
      ))}
    </ul>
  );
}
