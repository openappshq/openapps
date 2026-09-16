/**
 * Six wallpapers of the kinds macPaper makes, drawn in CSS so the page carries
 * no renders it would have to keep in step with the app. Each is labelled with
 * the generator that would produce it; the labels are the content, the tiles
 * are the illustration.
 */
const papers: [string, string][] = [
  ["gradient", "Gradient · Dusk"],
  ["mesh", "Mesh · Lagoon"],
  ["pattern", "Pattern · Grid"],
  ["grain", "Solid + grain · Slate"],
  ["pixels", "Pixelize · Your photo"],
  ["stripes", "Pattern · Stripes"],
];

export default function PaperGallery() {
  return (
    <ul className="mp-gallery">
      {papers.map(([kind, label]) => (
        <li key={kind}>
          <span className={`mp-paper mp-paper-${kind}`} aria-hidden="true" />
          <span className="mp-paper-label">{label}</span>
        </li>
      ))}
    </ul>
  );
}
