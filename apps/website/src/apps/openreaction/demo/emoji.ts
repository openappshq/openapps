import type { EmojiEntry } from "./matcher";

/** One record of gemoji's `db/emoji.json`. */
export interface GemojiRecord {
  emoji: string;
  description: string;
  aliases: string[];
  tags: string[];
}

/** Copied from the app package by scripts/prepare-assets.mjs. */
export const EMOJI_DATA_URL = "/openreaction/data/emoji.json";

let cache: Promise<EmojiEntry[]> | undefined;

/** Shortcode from an emoji name, as the Mac app derives it: `thumbs up` → `thumbs_up`. */
export function deriveShortcode(name: string): string {
  return name
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

export function toEntries(records: readonly GemojiRecord[]): EmojiEntry[] {
  return records.map(({ emoji, aliases, tags, description }) => {
    const derived = deriveShortcode(description);
    return {
      emoji,
      names: derived && !aliases.includes(derived) ? [...aliases, derived] : aliases,
      name: description,
      keywords: tags,
    };
  });
}

/** Fetches the gemoji database the Mac app vendors (MIT) on first use. */
export function loadEmoji(): Promise<EmojiEntry[]> {
  cache ??= fetch(EMOJI_DATA_URL)
    .then((response) => {
      if (!response.ok) throw new Error(`Emoji data failed to load: ${response.status}`);
      return response.json() as Promise<GemojiRecord[]>;
    })
    .then(toEntries);
  return cache;
}
