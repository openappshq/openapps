# OpenKlack

A mechanical-keyboard playground built from the [Paper design](https://app.paper.design/file/01M2CZA50EM9JBHN0DV4QCTW51/1-0).

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

React + TypeScript, HeroUI v3, Three.js / React Three Fiber, Drei, maath, and Web Audio. Vite+ handles development, bundling, formatting, linting, and Vitest. Tailwind supplies HeroUI's styles; the page theme is in `src/styles.css`.

## Behavior

- Type or click/drag across the 3D keyboard. Each key has damped travel and a local RGB pulse.
- Enable sound using the switch or choose a profile. Sound requires a user gesture and works in this page while focused.
- Choose Deep, Crisp, or Clicky globally; the editor can override individual keys.
- Finish, volume, global profile, and overrides persist in localStorage. Sound starts off on every visit.
- Reduced motion removes RGB animation and makes key movement immediate. Browser shortcuts and form controls keep their normal behavior.
- The accessible key selector and preview button offer an alternative to selecting keys on the canvas.

## Reference assets

This is a parity prototype. The supplied HAR's Raycast model, texture atlases, and audio are included with [provenance](public/keyboard/PROVENANCE.md). They retain the reference's key legends. Chalk and Sage recolor the base atlas. Sound profiles are three pitch/EQ treatments of the reference audio.

The original reference analysis is in [design/raycast-implementation.md](design/raycast-implementation.md). Scene calibration is centralized in `src/KeyboardScene.tsx`.

System-wide keyboard sound requires a future native companion. This app neither records typed text nor intercepts typing outside its page.
