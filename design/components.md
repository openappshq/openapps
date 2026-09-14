# Components

Use HeroUI for React controls; semantic HTML for content; native controls for menu bars and file dialogs.
Canvas and typing surfaces remain product-specific, with accessible alternatives to canvas-only actions.
These mappings are documentation, not registered Code Connect bindings.

## Specimens and code

| HeroUI control / pattern | Figma specimen | Existing implementation |
| --- | --- | --- |
| Button: primary, secondary, ghost | [Buttons](references/components/buttons.png) | Desktop App |
| Icon Button | [Icon buttons](references/components/icon-buttons.png) | SoundLibrary |
| Switch / Slider | [Switches](references/components/switches.png) / [Sliders](references/components/sliders.png) | Toggle / Level |
| SearchField / Tabs | [Search](references/components/search.png) / [Tabs](references/components/tabs.png) | SoundBrowser |
| Independent row, Star, Play buttons | [Sound rows](references/components/sound-rows.png) | SoundLibrary |
| Semantic feedback + action | [Status](references/components/status.png) / [Empty](references/components/empty-states.png) | Desktop App / SoundLibrary |
| Product key state | [Keycaps](references/components/keycaps.png) | Keyboard3D |
| Select + ListBox / Accordion | No Figma specimen | Choice / Disclosure |
| Link | No Figma specimen | Download page |

Code: [Desktop App](../apps/openklack-desktop/src/App.tsx), [SoundLibrary](../apps/openklack-desktop/src/SoundLibrary.tsx), [Toggle/Level/Choice/Disclosure](../apps/openklack-desktop/src/controls.tsx), [SoundBrowser](../packages/openklack-ui/SoundBrowser.tsx), [Keyboard3D](../packages/openklack-ui/Keyboard3D.tsx), [Download](../apps/website/src/apps/openklack/pages/Download.tsx).
Source node IDs are in the [manifest](assets/figma-export.json).
Figma labels/interactions can be obsolete; follow [OpenKlack's contract](products/openklack.md), not specimen copy.
Slider values illustrate states, not discrete volume choices.

## State requirements

- Preserve accessible names, keyboard operation, visible focus, and default/hover/pressed/disabled/pending states.
- Selection needs more than color; retain focus when lists reorder.
- Search preserves its query and active selection; no results offers reset.
- Errors preserve working settings and provide nearby recovery.
- Popovers support Escape and trigger-focus return; disclosures retain expansion semantics and reduced motion.
- Give row, preview, and star actions separate sibling controls; never nest buttons.
- Use real destinations for links and one clear action/focus ring per search field.

Keep OpenKlack's specialized components in `@openklack/ui`; shared theme and motion belong in `@openapps/ui`.
