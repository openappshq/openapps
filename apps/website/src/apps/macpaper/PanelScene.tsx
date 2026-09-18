/**
 * The idea, drawn: a Mac's screen, and macPaper's panel dropping out of the
 * notch to change the wallpaper behind it. Pure CSS: the panel drops, two
 * swatches get pressed and the wallpaper crossfades each time, the panel goes
 * back up, and the loop starts over. Reduced motion shows the panel open on the
 * first wallpaper. Decorative; the copy beside it says what it shows.
 */
const wallpapers = ["gradient", "mesh", "pattern"] as const;

export default function NotchScene() {
  return (
    <div className="mp-scene" aria-hidden="true">
      <div className="mp-screen">
        {wallpapers.map((wallpaper) => (
          <div key={wallpaper} className={`mp-wall mp-wall-${wallpaper}`} />
        ))}
        <div className="mp-panel">
          <div className="mp-panel-tabs">
            <span className="is-active">Gradient</span>
            <span>Mesh</span>
            <span>Pattern</span>
            <span>Pixels</span>
          </div>
          <div className="mp-swatches">
            <span className="mp-swatch mp-swatch-1" />
            <span className="mp-swatch mp-swatch-2" />
            <span className="mp-swatch mp-swatch-3" />
            <span className="mp-swatch mp-swatch-4" />
            <span className="mp-swatch mp-swatch-5" />
            <span className="mp-swatch mp-swatch-6" />
          </div>
          <div className="mp-panel-actions">
            <span className="mp-panel-button is-primary">Apply</span>
            <span className="mp-panel-button">Shuffle</span>
            <span className="mp-panel-star">★</span>
          </div>
        </div>
        <div className="mp-menubar">
          <span className="mp-notch" />
        </div>
        <div className="mp-dock">
          <span />
          <span />
          <span />
          <span />
          <span />
        </div>
      </div>
    </div>
  );
}
