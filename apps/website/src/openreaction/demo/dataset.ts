import { existsSync, readFileSync } from "node:fs";
import { toEntries, type GemojiRecord } from "./emoji";
import type { EmojiEntry } from "./matcher";

/**
 * Test-only access to the OpenReaction files that scripts/prepare-assets.mjs
 * copies: the prepared public copy first, then the app package.
 */
function sourceFile(publicPath: string | null, sourcePath: string): URL | null {
  const candidates = [
    publicPath && new URL(`../../../public/${publicPath}`, import.meta.url),
    new URL(`../../../../openreaction/${sourcePath}`, import.meta.url),
  ];
  return candidates.find((url): url is URL => !!url && existsSync(url)) ?? null;
}

export const emojiFile = sourceFile(
  "data/openreaction/emoji.json",
  "Sources/OpenReactionCore/Resources/emoji.json",
);
export const tokensFile = sourceFile(null, "design/tokens.json");

export function readEmoji(): EmojiEntry[] {
  if (!emojiFile)
    throw new Error("emoji.json not found; run `pnpm assets`");
  return toEntries(JSON.parse(readFileSync(emojiFile, "utf8")) as GemojiRecord[]);
}
