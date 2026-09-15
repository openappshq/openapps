# OpenApps HQ · Tactile Studio

Read only the documents needed for the task.

| Task | Reference |
| --- | --- |
| Any interface | [Shared rules](system.md) |
| Controls and states | [Components](components.md) |
| OpenKlack behavior | [Product contract](products/openklack.md) |
| OpenReaction behavior | [App architecture](../apps/openreaction/docs/architecture.md) |
| Hertz behavior | [Product contract](products/hertz.md) |
| Logos and icons | [Asset usage](assets/README.md) |
| Token values | [tokens.json](tokens.json) |
| New product | [Design checklist](system.md#adding-a-product), [repository setup](../docs/development.md#add-another-app) |
| Historical decisions or testing | [Archive](archive/README.md), [verification](desktop-verification.md) |

## Authority

Current user decisions override older designs.
These contracts define behavior; [Figma](https://www.figma.com/design/2fvzpabR06HanNwQIxxtm1/OpenApps-HQ-%C2%B7-Tactile-Studio) authors visual foundations.
Older screens are historical; product contracts record overrides.

## Visual references

[Brand](references/brand-sheet.png) · [Identity](references/identity-rules.png) · [Light](references/color-light.png) / [Dark](references/color-dark.png) · [Typography](references/typography.png) · [Space and motion](references/space-form-motion.png).

[Export manifest](assets/figma-export.json): source IDs, dates, status, checksums.
[Raw snapshot](references/figma-system.json): variables, styles, component definitions; query relevant entries instead of loading it wholesale.

## Updates

Record each rule once in the shared or product contract.
Refresh affected Figma exports and provenance together; synchronization is manual.
Update approved values in `tokens.json`, run `pnpm theme`, then `pnpm design:check`; never hand-edit generated `tokens.css`.
The check compares local exports, not live Figma.
Verify changed UI in its actual app across themes, keyboard focus, reduced motion, and narrow layouts; keep test evidence separate from design intent.
