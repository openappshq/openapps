# Raycast keyboard: implementation and OpenKlack parity

Investigated 2026-09-13 using the replacement [HAR capture](/Users/anurag/Downloads/www.raycast.com.har), containing 102 requests, and the [Raycast keyboard page](https://www.raycast.com/keyboard). The original 23-request capture contained Fetch/XHR traffic only; it has been superseded. The findings below describe the code in this capture, not a measured performance benchmark.

## What creates the effect

The keyboard is a real 3D scene. React Three Fiber manages a Three.js canvas. Its renderer wrapper constructs `WebGPURenderer`, waits for initialization, and caps device pixel ratio at 2. Three.js supports WebGPU with a WebGL 2 fallback; the HAR alone does not identify which backend was active on this computer. [Renderer bundle](https://www.raycast.com/_next/static/immutable/chunks/0afenv_xkmt60.js), [Three.js renderer documentation](https://threejs.org/docs/pages/WebGPURenderer.html).

The distinctive RGB response uses two pre-rendered texture atlases on the same model: a base appearance and an RGB-lit appearance. A custom Three.js node material blends between them near the pressed key. The bright seams and reflected colors are already present in the RGB texture. The hero does not need to simulate an array of moving lights or run a bloom effect to produce that appearance. [Keyboard component bundle](https://www.raycast.com/_next/static/immutable/chunks/1iq4-hk8vxk9w.js), [base texture](https://www.raycast.com/_next/static/immutable/media/base.2rqquubqlk5zp.jpg), [RGB texture](https://www.raycast.com/_next/static/immutable/media/rgb.2b0rcidn_e7r4.jpg).

The rainbow is spatially fixed in that texture. A press reveals the color already underneath its location, rather than choosing a random new color. Dark key tops, bright gaps, and overlapping fading pulses explain the visual flow in the recording. See the independent [motion observations](./raycast-motion-observations.md).

## Asset evidence

| Resource                     | HAR entry, zero-based | Content size  | Role                                                                                            |
| ---------------------------- | --------------------- | ------------- | ----------------------------------------------------------------------------------------------- |
| `1iq4-hk8vxk9w.js`           | 52                    | 116,697 bytes | Hero component, input handling, audio sprite map, shader setup, and a bundled tuning UI         |
| `keyboard.3ro93waeap5n5.glb` | 63                    | 666,444 bytes | Draco-compressed geometry; default `hero` scene has 85 direct meshes, including the static body |
| `base.2rqquubqlk5zp.jpg`     | 64                    | 243,229 bytes | 2048 × 2048 base texture atlas                                                                  |
| `rgb.2b0rcidn_e7r4.jpg`      | 65                    | 263,575 bytes | Matching 2048 × 2048 RGB-lit atlas                                                              |
| `switches.3x255z57flf6r.ogg` | 76                    | 93,379 bytes  | Decoded once, then played in key-specific press/release segments                                |

The GLB contains several scenes and no animation clips. The hero uses its default scene and animates meshes in code. Many meshes are named after browser key codes such as `KeyA`, `KeyS`, `ArrowUp`, and `Space`. The HAR also includes separate keycap and switch models and an HDR lighting asset; these should not all be treated as requirements for the hero. [Model](https://www.raycast.com/_next/static/immutable/media/keyboard.3ro93waeap5n5.glb), [hero bundle](https://www.raycast.com/_next/static/immutable/chunks/1iq4-hk8vxk9w.js), [page component bundle](https://www.raycast.com/_next/static/immutable/chunks/2xw_xxyp1rc6m.js).

## One press, end to end

1. The input handler records the key code in a mutable pressed-key set. Already-held keys do not retrigger the press callback on OS repeat.
2. It finds the matching key mesh and places a light-pulse center at that key's resting X/Z position.
3. A fixed pool of ten pulse slots is reused in a ring. Each new press resets one slot's progress to zero.
4. Each rendered frame advances the pulses and dampens the key mesh toward its pressed or resting position. The mesh travels along its local downward axis.
5. The GPU evaluates a soft radial mask in world-space X/Z coordinates and uses it to blend the two texture atlases.
6. Release plays its own sound segment and changes the key's target depth back to rest. The light pulse continues its own decay independently.

These are direct observations of the [hero implementation](https://www.raycast.com/_next/static/immutable/chunks/1iq4-hk8vxk9w.js). Pointer presses and dragging across keys use the same press/release path.

## The RGB mask

For normalized pulse progress `p` from 0 to 1, the default eased progress is `e = 1 − (1 − p)³`. The radius expands to `0.15 × e` model units. A smooth edge extends another `0.08` units. The mask strength is multiplied by `1 − e`, so it fades while spreading.

The material takes the **maximum** mask value across the ten slots; it does not add all pulses together. At the default ambient-light setting, the texture blend amount is twice that maximum. It can exceed 1 at a pulse's bright center, so the implementation is more intense than an ordinary clamped image crossfade. The mask is a soft filled region, not a sharply outlined ring. [Shader construction in the hero bundle](https://www.raycast.com/_next/static/immutable/chunks/1iq4-hk8vxk9w.js).

| Parameter               | Captured default  | Meaning                                                                |
| ----------------------- | ----------------- | ---------------------------------------------------------------------- |
| Pulse lifetime          | 0.9 seconds       | Progress reaches completion after this much accumulated animation time |
| Pulse slots             | 10                | Reused, allowing overlapping presses                                   |
| Easing exponent         | 3                 | Fast initial spread and a fading tail                                  |
| Maximum radius          | 0.15 model units  | Local spread; scale-dependent, not pixels                              |
| Edge feather            | 0.08 model units  | Soft transition into surrounding unlit geometry                        |
| Lighting intensity      | 2                 | Strength of the texture blend                                          |
| Ambient RGB blend       | 0                 | RGB appears around presses by default                                  |
| Key travel              | 0.025 model units | Press depth along the key's local downward axis                        |
| Key damping smooth time | 0.0175 seconds    | Damping parameter, not a fixed animation duration                      |
| Press dimming           | 0.4               | Fully depressed key material is multiplied by 0.6                      |
| Frame delta clamp       | 1/30 second       | Limits a large time step; this is **not** a 30 FPS rendering cap       |

All values are from the captured [hero settings and frame loop](https://www.raycast.com/_next/static/immutable/chunks/1iq4-hk8vxk9w.js). They are useful starting points; model-space values must be retuned for our geometry.

## Why this is an efficient rendering approach

- The expensive visual detail is baked into two textures. The changing lighting mask is evaluated on the GPU with `MeshBasicNodeMaterial` and Three.js Shading Language.
- The frame loop changes mesh positions, material colors, and shader uniforms directly. It does not rerender the React component tree for every frame or key event.
- The ten pulse objects are allocated once and reused. The model and textures are preloaded.
- Continuous rendering is enabled while the keyboard is in view; it switches to demand rendering when offscreen after initialization.
- Blur and visibility changes clear held keys. Reduced-motion mode suppresses RGB pulses and makes key travel immediate; it also avoids the animated camera entrance.
- Audio uses a shared decoded buffer and a new playback source per press/release, so overlapping sounds can play without fetching a file for each key.

These implementation choices support responsive animation, but do not establish actual FPS, input-to-photon latency, or audio latency on a given device. [Hero implementation](https://www.raycast.com/_next/static/immutable/chunks/1iq4-hk8vxk9w.js), [renderer wrapper](https://www.raycast.com/_next/static/immutable/chunks/0afenv_xkmt60.js). Current node-material APIs were cross-checked through Context7 against [Three.js's official examples](https://github.com/mrdoob/three.js/blob/dev/examples/webgpu_texturegrad.html).

## What changes for OpenKlack

For close visual parity, the centerpiece should be a 3D keyboard with original OpenKlack geometry and matching unlit/RGB-lit textures. Keep the surrounding controls as ordinary accessible HTML. Our current Paper screens establish the layout and customization flow; the keycap shape, perspective, under-key lighting, and motion need a live rendering pass.

The next build milestone should isolate one keyboard scene: physical-key input, clickable key meshes, damped travel, the ten-slot texture-blend effect, and immediate sound. Validate that against the reference recording before building more settings. The required visual asset quality matters as much as the animation code.

Preserve the per-key sound override design: one global sound profile, then optional overrides keyed by physical key code. The captured Raycast physical-key handler filters to letters, digits, and arrows; OpenKlack should intentionally support Space, Enter, modifiers, and punctuation too, while preserving browser shortcuts and normal control focus.

Do not bring over the reference's product-specific tuning UI or easter eggs. Keep motion calibration values centralized so key travel, light spread, intensity, and fade can be tuned against the finished model. This is the proposed OpenKlack approach, not a claim that those controls are present in the current design implementation.

## Capture handling

Only public static response bodies were extracted for inspection. Request cookies, session responses, and tracking payloads were not copied into this project. The subsequent parity prototype includes the keyboard model, base/RGB textures, and typing audio under `public/keyboard`, with provenance there. It does not include Raycast's application bundles.
