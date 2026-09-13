# OpenApps HQ · Tactile Studio

[Figma design system](https://www.figma.com/design/2fvzpabR06HanNwQIxxtm1/OpenApps-HQ-%C2%B7-Tactile-Studio).
Figma is the current design source for OpenApps HQ and OpenKlack.
The earlier Paper studies remain historical references only.

- [Logo assets and usage](assets/README.md): exact SVG masters, app-icon PNGs, and provenance.
- [Theme tokens](tokens.json): 89 Figma variables covering primitives, light/dark semantics, metrics, and typography.
- [Generated CSS](tokens.css): reusable bindings created by `pnpm theme`.
- [Complete OpenKlack app UI](openklack-app-ui.md): all screens, controls, defaults, interactions, recovery states, and accessibility requirements.
- [Desktop plan](desktop-plan.md): agreed product and architecture decisions.
- [Desktop verification](desktop-verification.md): implemented behavior and remaining release gates.

The marketing website in `apps/website` consumes the new tokens and exported logos.
Its desktop product images are exact exports from Figma and are labeled as the proposed app design.
The native utility in `apps/desktop` retains its existing interface until the desktop redesign is implemented.

Bricolage Grotesque leads display typography, Instrument Sans carries the interface, and IBM Plex Mono labels compact metadata.
OpenKlack uses cobalt; OpenApps HQ uses yellow; orchid supports expressive compositions.
White and charcoal surfaces share the same spacing, control geometry, and semantic states.
