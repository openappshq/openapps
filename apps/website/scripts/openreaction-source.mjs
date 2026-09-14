import { existsSync } from "node:fs";

/** Where OpenReaction's design assets and emoji data live: the app package in this monorepo. */
export function openreactionSourceDir() {
  const inRepo = new URL("../../openreaction/", import.meta.url);
  return existsSync(inRepo) ? inRepo : null;
}

export const openreactionFiles = {
  brand: [
    "design/assets/app-icon.svg",
    "design/assets/symbol-ink.svg",
    "design/assets/symbol-paper.svg",
  ],
  emoji: "Sources/OpenReactionCore/Resources/emoji.json",
  tokens: "design/tokens.json",
};
