# Shared design rules

## Character

Creative tools label: expressive identities, simple utilities.
Use short oversized headlines, generous section spacing, and contrasting white, charcoal, and signature-color fields; keep settings compact and quiet.
Avoid filler copy, repetitive card grids, and decorative glow on controls.

HQ owns yellow, OpenKlack cobalt, OpenReaction orchid.
Products share typography, neutral surfaces, geometry, and behavior while owning their glyph and signature color.
For marks, use [asset masters and rules](assets/README.md).

## Color, type, and layout

Use semantic roles from [tokens.json](tokens.json), mapped by [theme.css](../packages/ui/theme.css); reserve palette values for defining roles.
Pair filled actions with `accent/on`, including dark mode; brand colors are not automatically readable text colors.
Use text, icons, or boundaries alongside state colors.
Require 4.5:1 normal-text contrast and 3:1 large-text/control/focus contrast.

- Bricolage Grotesque ExtraBold: identities and short display headings, tight tracking.
- Instrument Sans Regular/SemiBold: interface and body.
- IBM Plex Mono: short metadata and numerical readouts; tabular numbers for changing values.

Use the token type/spacing/radius scales; scale display headings down on narrow screens while retaining readable body/caption sizes.
Layout-width tokens constrain content, not viewport breakpoints.
Default controls are 40px high; touch targets need 44px, using padding where necessary.
Keep replacement states aligned and everyday surfaces mostly flat; reserve elevation for contact shadows and floating menus.
Tracking and elevation values live in the [Figma snapshot](references/figma-system.json), not generated CSS variables.

## Interaction, copy, and motion

One main task per view; reversible settings apply and save directly.
Place uncommon controls behind relevant disclosures; bound catalogs with search and useful filters.
Labels name actions or values; explain permissions before requesting them and errors beside recovery.
Copy states observed facts, without repeated reassurance or unsupported release/performance claims.

Use HeroUI transitions for controls and [shared Motion defaults](../packages/ui/motion.tsx) for views.
Never delay input/audio for animation.
Stop hidden decoration and release closed canvases.
Reduced motion removes decorative travel/glow while preserving immediate state feedback.
Control accessibility and state requirements are in [components](components.md).

## Marketing websites

Reuse [MarketingChrome](../apps/website/src/shared/MarketingChrome.tsx), [Questions](../apps/website/src/shared/Questions.tsx), and [marketing.css](../apps/website/src/shared/marketing.css) for navigation, typography, spacing, actions, FAQs, and footer. All routes follow the system theme; product styles only extend shared tokens. Keep demos product-specific. Product links must work from download pages too.

## Adding a product

1. Add `design/products/<app-id>.md`: purpose, primary task, defaults, exceptional states, and system exceptions.
2. Create its glyph and signature color in Figma; export masters with provenance to `design/assets/<app-id>/`.
3. Reuse `@openapps/ui`; keep specialized behavior in the product, sharing wrappers only when another product needs them.
4. Scope any accent/focus overrides to that product, defining both themes without changing existing brands.
5. Follow [repository setup](../docs/development.md#add-another-app) and link the contract from the design index.
