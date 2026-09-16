import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vite-plus/test";

const tokensCss = readFileSync(new URL("./tokens.css", import.meta.url), "utf8");
const tokensFile = new URL("../../../../opennotes/design/tokens.json", import.meta.url);

interface Tokens {
  palette: Record<string, string>;
  color: Record<"light" | "dark", Record<string, string>>;
}
/* The website's coral is provisional until the app ships its own tokens.json;
   these checks run once it is on the same branch and skip until then. */
const tokens = existsSync(tokensFile)
  ? (JSON.parse(readFileSync(tokensFile, "utf8")) as Tokens)
  : null;

describe.skipIf(!tokens)("tokens.css", () => {
  it("matches every palette value it declares", () => {
    for (const [name, hex] of Object.entries(tokens!.palette)) {
      const match = tokensCss.match(
        new RegExp(`--palette-${name.replace("/", "-")}:\\s*(#[0-9a-f]+);`, "i"),
      );
      if (match) expect(match[1].toLowerCase(), name).toBe(hex.toLowerCase());
    }
  });

  it("uses the app's accent roles in both themes", () => {
    const [light, dark] = tokensCss.split('[data-theme="dark"]');
    for (const role of [
      "accent/solid",
      "accent/hover",
      "accent/subtle",
      "accent/text",
      "accent/on",
      "focus/ring",
    ]) {
      const expectRole = (css: string, theme: "light" | "dark") => {
        const palette = tokens!.color[theme][role].replace("/", "-");
        expect(css, `${theme} ${role}`).toContain(
          `--color-${role.replace("/", "-")}: var(--palette-${palette});`,
        );
      };
      expectRole(light, "light");
      expectRole(dark, "dark");
    }
    expect(tokensCss).toContain("--color-brand-opennotes: var(--palette-coral-300);");
  });
});

describe("the provisional coral", () => {
  it("carries text only where it reads: 700 on light grounds, 300 as a face", () => {
    // The light accent is the dark step; the face colour never carries the accent text.
    expect(tokensCss).toContain("--color-accent-solid: var(--palette-coral-700);");
    expect(tokensCss).toContain("--color-accent-text: var(--palette-coral-700);");
    expect(tokensCss).toContain("--brand-solid: var(--palette-coral-300);");
    expect(tokensCss).toContain("--brand-on: var(--palette-neutral-950);");
  });
});
