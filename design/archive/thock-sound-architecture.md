# Thock sound architecture and reusable recordings

Researched 2026-09-13 for OpenKlack. Recommendation: use the 18 verified MIT-declared keyboard packs below: all eight Cherry MX switch/keycap combinations and ten tplai/kbsim packs. They contain 793 WAV samples, occupying 14,881,273 bytes in their original ZIPs and 22,094,952 bytes as WAV files. This directly improves the number of distinctive sound choices; extra EQ controls are unnecessary for this objective.

## Evidence pinned for reproduction

Thock's [official documentation index](https://thockapp.com/llms.txt) identifies both the app and the separate official soundpack registry. Inspection used these public repository revisions:

| Source                                                                                                              | Revision                                   | Local research checkout                     |
| ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------- |
| [Thock app](https://github.com/kamillobinski/thock/tree/f65da30a4e4a86db5cea7a288d63d5a723cd79a9)                   | `f65da30a4e4a86db5cea7a288d63d5a723cd79a9` | `/tmp/openklack-thock-reference`            |
| [Thock soundpacks](https://github.com/kamillobinski/thock-soundpacks/tree/213e1443c5005a99d5e51b46e31e17f30e4d752a) | `213e1443c5005a99d5e51b46e31e17f30e4d752a` | `/tmp/openklack-thock-soundpacks-reference` |
| [kbsim](https://github.com/tplai/kbsim/tree/ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4)                               | `ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4` | `/tmp/openklack-kbsim-reference`            |
| [Mechvibes](https://github.com/hainguyents13/mechvibes/tree/326252a13e7bef4f1c35d08ef0189b5af6f8ba02)               | `326252a13e7bef4f1c35d08ef0189b5af6f8ba02` | `/tmp/openklack-mechvibes-reference`        |

Only this research note was added to OpenKlack by the research task. The external repositories and recordings were inspected in `/tmp`.

## Code license and audio licenses are separate

The [Thock code license](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/LICENSE) is MIT, copyright 2025 Kamil Łobiński. Its [soundpack repository explicitly assigns licensing per pack](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/README.md#license); there is no blanket MIT grant covering every audio file. Each ZIP's `config.json` contains its own `license.type`, `license.url`, and author metadata.

The recommended 18 packs have matching MIT declarations in the registry and inside their ZIPs. These declarations were checked against their upstream source repositories:

- **Eight Cherry MX ABS/PBT packs:** the original OGG recordings and per-key timing definitions are committed in [Mechvibes `src/audio`](https://github.com/hainguyents13/mechvibes/tree/326252a13e7bef4f1c35d08ef0189b5af6f8ba02/src/audio), in `cherrymx-{black,blue,brown,red}-{abs,pbt}`. The repository's [MIT license](https://github.com/hainguyents13/mechvibes/blob/326252a13e7bef4f1c35d08ef0189b5af6f8ba02/LICENSE) names **Copyright (c) 2021 Hai Nguyen**. No contrary Cherry-specific license or asset exception was found in the inspected tree.
- **Ten tplai packs:** original press/release MP3s are committed in [kbsim `src/assets/audio`](https://github.com/tplai/kbsim/tree/ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4/src/assets/audio). Its [MIT license](https://github.com/tplai/kbsim/blob/ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4/LICENSE.md) names **Copyright (c) Thomas Lai**. No separate restrictive audio license was found. Corroborating asset-specific evidence exists in Mechvibes: its [Holy Panda pack README](https://github.com/hainguyents13/mechvibes/blob/326252a13e7bef4f1c35d08ef0189b5af6f8ba02/src/audio/holy-pandas/README.md) identifies kbsim as its source and its [pack-local license](https://github.com/hainguyents13/mechvibes/blob/326252a13e7bef4f1c35d08ef0189b5af6f8ba02/src/audio/holy-pandas/LICENSE) repeats Thomas Lai's MIT terms.

**Reuse recommendation:** these declared terms permit reuse, modification, and redistribution, including concatenating recordings into sprites. Ship the complete relevant MIT copyright/permission/warranty texts with the application and source distribution; a URL alone is not the MIT notice. Credit “Mechvibes / Hai Nguyen” or “kbsim / Thomas Lai (tplai), distributed in Thock soundpacks,” retain the original pack ID and source link, and describe sprite conversion as an OpenKlack modification. If actual Thock code is copied, also include Kamil Łobiński's MIT notice. The inspected keyboard ZIPs contain license URLs but no full license text, so their ZIP contents alone do not satisfy this notice recommendation. This conclusion follows the publishers' licenses and the inspected repository provenance; it does not claim independent proof of who operated the recording equipment.

Exclude the registry's **Razer Mamba Elite** pack: its manifest says Proprietary. The **Quack** and **Unknown mouse** entries use Pixabay Content License, not MIT; they are outside the selected set. The **Razer Orochi V2** pack is declared CC0 and is a separate mouse candidate. See the [official manifest](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/manifest.json) for these distinctions.

## Inventory and asset locations

The [registry manifest](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/manifest.json) is version `1.0.0`, with `lastUpdated: 2026-03-28T12:17:11Z`. It contains 23 keyboard and three mouse entries. Each entry has `id`, `metadata`, `content.path`, `download.url`, `download.size` in bytes, and `license`. Locally it is `/tmp/openklack-thock-soundpacks-reference/manifest.json`. The downloaded ZIP is `<content.path>/<id>.zip`; its root contains `config.json` and flat audio filenames.

| Pack (source archive)                                                                                                                                                                                          | Author / license | Release | WAVs | ZIP bytes | WAV bytes |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ------- | ---: | --------: | --------: |
| [Alps SKCM Blue](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/alps/tplai/skcm_blue/52722920-07ec-45b4-91cc-6f29cad794d2.zip)                       | tplai / MIT      | Yes     |   13 |    87,715 |   111,566 |
| [Cherry MX Black ABS](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/black_abs/de401889-0ccb-4522-a213-836aad88c447.zip)         | mechvibes / MIT  | No      |   84 | 1,973,844 | 2,868,844 |
| [Cherry MX Black PBT](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/black_pbt/980c6cc1-7daf-4584-8b0e-643b3a811a6d.zip)         | mechvibes / MIT  | No      |   84 | 1,352,214 | 2,219,344 |
| [Cherry MX Blue ABS](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/blue_abs/cf535c6d-9cc7-46a0-bf53-af6d3aeef534.zip)           | mechvibes / MIT  | No      |   84 | 1,870,192 | 2,763,272 |
| [Cherry MX Blue PBT](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/blue_pbt/ca2d54d7-31d0-4177-b26a-43d99a3bcaaf.zip)           | mechvibes / MIT  | No      |   84 | 1,839,436 | 2,760,488 |
| [Cherry MX Brown ABS](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/brown_abs/186ca33e-9998-4a28-974c-c21ac353c16e.zip)         | mechvibes / MIT  | No      |   84 | 1,428,804 | 2,260,500 |
| [Cherry MX Brown PBT](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/brown_pbt/3aa3c556-ab47-4ab9-a791-498bf9910bf7.zip)         | mechvibes / MIT  | No      |   84 | 1,823,031 | 2,740,008 |
| [Cherry MX Red ABS](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/red_abs/31071be3-c9ad-44a4-8d38-aaa7fe414a58.zip)             | mechvibes / MIT  | No      |   84 | 1,895,840 | 2,751,488 |
| [Cherry MX Red PBT](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/red_pbt/e05fa018-400e-4d9c-b357-d5467b07650c.zip)             | mechvibes / MIT  | No      |   84 | 1,990,241 | 2,819,256 |
| [Drop Holy Panda](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/drop/tplai/holy_panda/4da844a6-346e-4361-84fd-5bc142ff975e.zip)                     | tplai / MIT      | Yes     |   12 |    60,283 |    80,758 |
| [Durock Alpaca](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/durock/tplai/alpaca/23d8cf7b-f99b-49fc-ae84-3f99dc728ad9.zip)                         | tplai / MIT      | Yes     |   12 |    64,959 |    82,392 |
| [Gateron Ink Black](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/gateron/tplai/ink_black/b9bfb429-16c6-449f-aa85-5da083696f68.zip)                 | tplai / MIT      | Yes     |   12 |    53,131 |    72,602 |
| [Gateron Ink Red](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/gateron/tplai/ink_red/631754b0-eafe-4b14-b86e-61842f1f195c.zip)                     | tplai / MIT      | Yes     |   12 |    62,498 |    86,488 |
| [Gateron Turquoise Tealios](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/gateron/tplai/turquoise_tealios/c556e214-5d78-4fc1-a7fe-3eb3f53152ba.zip) | tplai / MIT      | Yes     |   12 |    52,894 |    72,736 |
| [Kailh Box Navy](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/kailh/tplai/box_navy/c573d01e-2d20-4844-9286-a9e628ef8f3b.zip)                       | tplai / MIT      | Yes     |   12 |    79,099 |    94,894 |
| [NovelKeys Cream](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/novelkeys/tplai/cream/f0cc3d8e-5b1e-4412-a3f0-8a4f70912d0e.zip)                     | tplai / MIT      | Yes     |   12 |    60,605 |    78,806 |
| [Topre Unknown](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/topre/tplai/unknown/ab2657fe-dc0a-4c75-ab74-81d8f56002b0.zip)                         | tplai / MIT      | Yes     |   12 |    93,496 |   109,318 |
| [IBM Buckling Spring](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/ibm/tplai/buckling_spring/61861d39-1242-41f5-8cf9-5823c472ce28.zip)             | tplai / MIT      | Yes     |   12 |    92,991 |   122,192 |

Sizes are measured from the pinned ZIPs and checked against the manifest. All selected WAVs are 44,100 Hz, signed 16-bit PCM. Cherry files are stereo; tplai files are mono. All 793 referenced WAV names resolve inside their archives. The checked archives have flat, ordinary paths.

The other keyboard entries are **Everglide Crystal Purple** (1,257,830 ZIP bytes), **Everglide Oreo** (987,876), **Topre Purple Hybrid PBT** (1,066,740), **Unknown / webdevcody** (571,152), and **Quirky Quack** (23,885). The first four are declared MIT and Quack is Pixabay. The three Mechvibes extras have 84 WAVs each; webdevcody has 18 and Quack has one. These are additional catalog candidates, but the 18-pack recommendation above is the focused implementation set. Source: [registry and linked ZIPs](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/manifest.json).

## Exact manifest and selection semantics

The [Swift decoder](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Models/SoundpackConfig.swift) expects:

```ts
type ThockPack = {
  id: string;
  metadata: {
    name: string;
    brand: string;
    author: string;
    category?: string; // defaults to "keyboard"
    supportsKeyUp?: boolean; // defaults to false
  };
  license: { type: string; url: string };
  sounds: Record<string, { down: string[]; up: string[] }>;
};
```

`sounds` keys are human names such as `a`, `1`, `space`, `shiftLeft`, and `default`; the numeric strings are digit keys, not scan codes. A selected pack lives in `~/Library/Application Support/Thock/Soundpacks/<folder>/`. Thock scans each child folder for a decodable `config.json`. Downloads are extracted to a folder named with the pack UUID. Sources: [installed pack discovery](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Models/SoundpackDatabase.swift), [registry installation](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Services/SoundpackRegistryService.swift).

[SoundpackConfigManager](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Managers/SoundpackConfigManager.swift) chooses the requested key's `down`/`up` array, falling back to `sounds.default` only when the key is absent. **An explicitly empty array means silence; it must not trigger fallback.** [SoundEngine](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Engines/SoundEngine.swift) chooses one element with `randomElement()` per event. There is no round-robin, no prevention of immediate repeats, and no coupling of a random down variant to a corresponding up variant.

Every selected Cherry pack has 84 WAVs with per-key definitions. Most key arrays contain one sound. `default.down` is `20.wav` through `24.wav`; `command.down` contains both `3675.wav` and `3676.wav`. Every `up` array is empty. Keep these as down-only recordings; do not replay the down sample on release. Thock's registry version and current Mechvibes upstream are not identical: for example, upstream Cherry Black ABS now has `-up` sprite definitions, while the inspected Thock pack does not. Import the chosen source's actual manifest instead of mixing metadata between revisions. Sources: [Cherry Blue ABS archive](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/cherry_mx/mechvibes/blue_abs/cf535c6d-9cc7-46a0-bf53-af6d3aeef534.zip), [current upstream Black ABS config](https://github.com/hainguyents13/mechvibes/blob/326252a13e7bef4f1c35d08ef0189b5af6f8ba02/src/audio/cherrymx-black-abs/config.json).

Nine of the tplai packs have this exact shape; Alps adds `102.wav` to `default.up`:

```json
{
  "default": { "down": ["1.wav", "2.wav", "3.wav", "4.wav", "5.wav"], "up": ["101.wav"] },
  "space": { "down": ["201.wav"], "up": ["251.wav"] },
  "enter": { "down": ["301.wav"], "up": ["351.wav"] },
  "backspace": { "down": ["401.wav"], "up": ["451.wav"] }
}
```

The corresponding original kbsim generic files are `press/GENERIC_R0.mp3` through `GENERIC_R4.mp3`. Its [own playback code](https://github.com/tplai/kbsim/blob/ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4/src/features/keySimulator/KeySimulator.js) describes these as pitch-adjusted sounds for keyboard rows and selects them by row. Thock pools these variants into random defaults. Call them **sample variants**, not five independent recording takes. The [Holy Panda ZIP](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/drop/tplai/holy_panda/4da844a6-346e-4361-84fd-5bc142ff975e.zip) and [Alps ZIP](https://github.com/kamillobinski/thock-soundpacks/blob/213e1443c5005a99d5e51b46e31e17f30e4d752a/keyboard/alps/tplai/skcm_blue/52722920-07ec-45b4-91cc-6f29cad794d2.zip) establish the Thock arrays.

## Normalize keys once at import

The following maps the selected Thock packs to browser `KeyboardEvent.code` values. It is an OpenKlack import recommendation based on the [Thock hardware mapper](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Helpers/KeyMapper.swift) and inspected pack configs, not an API migration.

| Thock key                                  | OpenKlack code                                                            |
| ------------------------------------------ | ------------------------------------------------------------------------- |
| `a`…`z`                                    | `KeyA`…`KeyZ`                                                             |
| `0`…`9`                                    | `Digit0`…`Digit9`; optionally alias `Numpad0`…`Numpad9`                   |
| `space`, `enter`, `tab`, `esc`, `capsLock` | `Space`, `Enter`, `Tab`, `Escape`, `CapsLock`                             |
| `backspace`, selected Cherry packs' `del`  | `Backspace`                                                               |
| `shiftLeft`, `shiftRight`                  | `ShiftLeft`, `ShiftRight`                                                 |
| `ctrlLeft`                                 | `ControlLeft`                                                             |
| `optionLeft`, `optionRight`                | `AltLeft`, `AltRight`                                                     |
| `command`                                  | both `MetaLeft` and `MetaRight`, each retaining both choices              |
| `arrLeft`, `arrRight`, `arrUp`, `arrDown`  | `ArrowLeft`, `ArrowRight`, `ArrowUp`, `ArrowDown`                         |
| `home`, `end`, `pgUp`, `pgDn`              | `Home`, `End`, `PageUp`, `PageDown`                                       |
| `f1`…`f12`                                 | `F1`…`F12`                                                                |
| backtick, `-`, `=`, `[`, `]`, backslash    | `Backquote`, `Minus`, `Equal`, `BracketLeft`, `BracketRight`, `Backslash` |
| `;`, apostrophe, comma, period, `/`        | `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`                          |
| `*`, `+`, `clear`                          | `NumpadMultiply`, `NumpadAdd`, `NumLock` where appropriate                |
| `fn`                                       | preserve only if a platform supplies a usable Fn event; otherwise unused  |

**Backspace inconsistency to avoid:** Thock maps macOS keycode 51 to `del`, but tplai packs define `backspace`, so Thock's own playback falls back instead of playing their special backspace recordings. For the selected Cherry packs, `del` is specifically `14.wav`, the Backspace recording. Normalize both to `Backspace`. Do not globally reinterpret every third-party `del`: Thock's [conversion script](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/scripts/mechvibes2thock.py) separately uses `backspace` for scan code 14 and `del` for 3667, showing that imported packs can differ. Use pack-aware aliases rather than blindly treating filenames as browser codes.

The Thock mapper collapses several physical keys: main digits/numpad digits, both Command keys, and Return/numpad Enter. The recommended import may alias equivalent keys, but unsupported keys can simply use the pack default. Keep `Delete` distinct from `Backspace` in the new schema.

## Playback architecture worth carrying over

Thock listens to system keyboard events, tracks pressed keys so held-key repeats do not repeatedly play, handles release separately, and optionally suppresses modifier sounds. Its event tracker dispatches sound work at user-interactive priority. These behaviors come from [KeyboardEventTracker](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Services/KeyboardEventTracker.swift); browser preview should scope input appropriately and suppress `repeat` events.

The [native SoundManager](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Managers/SoundManager.swift) preloads a selected keyboard pack's flat `.wav` and `.mp3` files via `AVAudioFile` into Float32 stereo PCM, then keeps an array of active voices. An AudioQueue output callback sums all voices, allowing overlapping keystrokes, and removes finished ones. It uses three buffers; [default buffer size](https://github.com/kamillobinski/thock/blob/f65da30a4e4a86db5cea7a288d63d5a723cd79a9/Thock/Managers/SettingsManager.swift) is 256 frames. It restarts after idle and reacts to output-device changes. Optional pitch variation draws uniformly from ±a semitone range and changes playback rate through linear interpolation. This is native macOS implementation evidence, not a benchmark of browser latency.

For OpenKlack, retain the useful behavior: preload/decode only active packs, schedule overlapping samples, keep down/up independent, and route absent keys to defaults. Native AudioQueue internals do not need to be ported into a browser prototype.

## Smallest schema for compact audio sprites

One audio sprite per pack and one manifest preserve every meaningful source behavior. Keep filenames as region identifiers to simplify auditability; normalize only key names. The following is an OpenKlack recommendation, not Thock's on-disk schema:

```ts
type Pack = {
  id: string;
  name: string;
  brand: string;
  author: string;
  source: string;
  license: { type: string; url: string };
  audio: string;
  regions: Record<string, [startSeconds: number, durationSeconds: number]>;
  sounds: Record<string, { down: string[]; up: string[] }>;
};
```

The canonical key lookup remains `pack.sounds[code] ?? pack.sounds.default`; after that, choose from the requested `down` or `up` array. Derive release support from nonempty up arrays instead of duplicating a capability flag. Per-key overrides need only choose another pack ID; that pack uses the same lookup and fallback. Preserve every listed sample region and array, including the two Alps releases and two Cherry Command choices. Concatenating source audio does not lose randomization if regions remain individually addressable; flattening whole arrays into one continuous clip does.

Use decoded sample lengths to calculate region durations; retain source sample rate/channel layout or convert deliberately before measuring offsets. A little silence between regions can prevent cross-region bleed with compressed sprites. Validate that every reference exists and every region ends within the decoded sprite; check that Cherry remains silent on release and that tplai Backspace resolves to its dedicated sample. Include a source archive URL/revision and the full third-party notices with generated assets. These are implementation recommendations inferred from the inspected files, rather than claims about Thock features.
