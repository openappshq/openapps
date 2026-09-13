# OpenKlack

A keyboard sound studio with a live 3D keyboard and 18 recorded switch packs.

## Run

Requires Vite+ (`vp`).

```sh
vp install
vp dev
```

```sh
vp test run
vp run build
```

React + TypeScript, HeroUI v3, Three.js / React Three Fiber, Drei, maath, and Howler. Vite+ handles development, bundling, formatting, linting, and Vitest. Tailwind supplies HeroUI's styles; the page theme is in `src/styles.css`.

## Behavior

- Type or click/drag across the 3D keyboard. Each key has damped travel and a local RGB pulse.
- Enable sound or choose a pack. Sound requires a user gesture and works in this page while focused.
- Search and filter 18 packs: Cherry MX Black/Blue/Brown/Red in ABS and PBT, Alps, Holy Panda, Alpaca, Gateron, Box Navy, Cream, Topre, and Buckling Spring. Preview buttons do not change assignments.
- Choose a pack for the whole keyboard or an individual key, with master, per-key, and release volume. Sample variation uses each pack's supplied alternatives.
- Finish, playback settings, and assignments persist in localStorage. Older Deep/Crisp/Clicky preferences migrate to recorded packs. Sound starts off on every visit.
- Reduced motion removes RGB animation and makes key movement immediate. Browser shortcuts and form controls keep their normal behavior.
- The accessible key selector and preview button offer an alternative to selecting keys on the canvas.

## Sound library

The MIT-declared recordings come from [Thock soundpacks](https://github.com/kamillobinski/thock-soundpacks), originally Mechvibes and kbsim. Full notices ship in `public/sounds/NOTICE.txt`; source revisions, original IDs, and licenses are retained in `src/soundpacks.json`. The [research](design/thock-sound-architecture.md) records the source format and provenance.

Each pack has OGG and MP3 audio sprites. Howler loads packs on demand and overlaps voices; mappings preserve per-key samples, alternate samples, and genuine press/release pairs. Packs without release recordings remain silent on key-up. The 793 source clips occupy about 7 MB across both formats. OpenKlack applies no pitch/EQ presets; some source alternatives were pitch-adjusted by kbsim.

To regenerate from the reviewed checkout (requires Python 3 and ffmpeg):

```sh
git clone https://github.com/kamillobinski/thock-soundpacks.git /tmp/thock-soundpacks
git -C /tmp/thock-soundpacks checkout 213e1443c5005a99d5e51b46e31e17f30e4d752a
python3 scripts/import-soundpacks.py /tmp/thock-soundpacks
```

## Keyboard reference assets

The supplied HAR's Raycast model and texture atlases are included with [provenance](public/keyboard/PROVENANCE.md). They retain the reference's key legends. Chalk and Sage recolor the base atlas. The earlier Raycast audio has been replaced by the recorded switch library above.

The original reference analysis is in [design/raycast-implementation.md](design/raycast-implementation.md). Scene calibration is centralized in `src/KeyboardScene.tsx`.

System-wide keyboard sound requires a future native companion. This app neither records typed text nor intercepts typing outside its page.
