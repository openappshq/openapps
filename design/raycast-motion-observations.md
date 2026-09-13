# Raycast keyboard: motion reference

Primary source: [user-supplied screen recording](/Users/anurag/Desktop/raycast-keyboard.mov), 13.052 seconds, 4064 × 2324. Timestamps below are seconds from the recording start. The file reports a 120 fps video stream; that is capture metadata, not a measurement of the website's rendering rate. No audio stream is present.

## Observed behavior

| Time                  | Visible evidence                                                                                                                                                                                                                                               |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0.0–1.7 s             | A dark, slightly perspective-tilted keyboard sits on a nearly black page. Soft neutral light beside the case and restrained highlights on keycaps establish the object before interaction.                                                                     |
| 1.8–2.4 s             | The A → S → D sequence produces yellow, yellow-green, then green illumination. New keys brighten while previous keys remain faintly lit. At roughly 2.1–2.2 s several neighboring keys are visibly illuminated together.                                       |
| 1.9–2.3 s, close crop | Light is brightest in the gaps around the active key and along adjacent key edges. Corners produce small bright flares. The key's top stays mostly dark; it does not turn into a solid neon tile. The keycap moves slightly as the surrounding light develops. |
| 2.5–3.1 s             | K and neighboring right-hand keys produce cyan/blue light while the earlier green region fades. This gives the interaction spatial continuity across the board.                                                                                                |
| 3.2–3.8 s             | Another yellow pulse appears at A while green and cyan/blue keys remain visible elsewhere. Separate regions can animate at once; a new press does not visibly reset the entire board.                                                                          |
| 6.0–10.6 s            | A second typing sequence repeats the local glow and overlap across multiple rows. The observed hues are consistent with a rainbow arranged across keyboard position, rather than every press choosing an unrelated color.                                      |
| 10.4–11.2 s           | Remaining green illumination fades through several intermediate brightness levels to the dark resting appearance. There is no abrupt global lights-off frame.                                                                                                  |

All visual claims above refer to the supplied recording at the listed timestamps. The strongest interpretation is **overlapping local under-key glows with lingering decay**. The recording does not clearly show a circular wave expanding across the whole keyboard or an RGB wash spreading over the surrounding page. The neutral light at the sides of the case is distinct from the colored light under pressed keys.

## Why it reads as smooth

These are perceptual interpretations of the observations, not verified implementation details:

- **Fast response, softer departure:** a newly active key becomes obvious quickly, while prior keys fade rather than switch off. The next press blends into an existing field of light.
- **Light belongs to the object:** perspective, occlusion by keycaps, bright seams, and illumination touching neighboring edges make it resemble LEDs below real keys.
- **Stable background:** the camera and keyboard remain steady while the local key/lighting interaction moves, making small changes easy to feel.
- **Restrained amplitude:** key travel and lit area are small. The depth and contrast of the dark keyboard supply much of the effect.

The physical keyboard and input-event timestamps are not recorded. Exact input latency, hold duration, release timing, easing curves, and whether a particular pulse is keydown- or keyup-driven cannot be measured from this clip alone.

## Recommendations for OpenKlack's design

1. Show the resting state, one pressed key, a rapid multi-key sequence, and the fading trail in the design reference. A single static neon outline misses the central behavior.
2. Put colored light beneath the keycap layer. Keep the tops legible and dark; let color escape through seams and softly touch adjacent edges.
3. Give keys independent press/release and light states. Allow older pulses to decay while new ones begin, preserving simultaneous-key feedback.
4. Start with colors anchored to keyboard position and subtle key travel. Treat a large background glow or global ripple as a separate creative choice, rather than claiming it is necessary for parity with this recording.
5. Tune timing in a small live motion prototype. Still artboards can establish shape, materials, and color, but cannot establish parity for latency, decay, or the feel of fast typing.

Temporary inspection crops: `/tmp/openklack-motion-2.5.png`, `/tmp/openklack-motion-burst.jpg`, `/tmp/openklack-motion-key-onset.jpg`, `/tmp/openklack-motion-tail.jpg`. These are analysis aids, not product assets.
