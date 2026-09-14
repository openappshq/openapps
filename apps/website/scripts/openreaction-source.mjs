import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

/**
 * Where OpenReaction's design assets and emoji data live. Normally the app
 * package in this monorepo; `OPENREACTION_SOURCE_DIR` is a temporary override
 * for a checkout elsewhere until `apps/openreaction` is imported.
 */
export function openreactionSourceDir() {
  const override = process.env.OPENREACTION_SOURCE_DIR;
  if (override) return pathToFileURL(override.replace(/\/?$/, "/"));
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
