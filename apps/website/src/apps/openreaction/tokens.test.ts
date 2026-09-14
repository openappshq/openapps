import { readFileSync } from "node:fs";
import { describe, expect, it } from "vite-plus/test";
import { tokensFile } from "./demo/dataset";

const tokensCss = readFileSync(new URL("./tokens.css", import.meta.url), "utf8");

interface Tokens {
  palette: Record<string, string>;
  color: Record<"light" | "dark", Record<string, string>>;
}
const tokens = tokensFile ? (JSON.parse(readFileSync(tokensFile, "utf8")) as Tokens) : null;

describe.skipIf(!tokens)("tokens.css", () => {
  const cssVar = (name: string) => `--${name.replace("/", "-")}`;
  const declared = (name: string, value: string) =>
    new RegExp(`${cssVar(name)}:\\s*${value.replace(/[()]/g, "\\$&")};`, "i").test(tokensCss);

  it("matches every palette value it declares", () => {
    for (const [name, hex] of Object.entries(tokens!.palette)) {
      const match = tokensCss.match(
        new RegExp(`--palette-${name.replace("/", "-")}:\\s*(#[0-9a-f]+);`, "i"),
      );
      if (match) expect(match[1].toLowerCase(), name).toBe(hex.toLowerCase());
    }
  });

  it("uses the design system's accent roles in both themes", () => {
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
    expect(declared("color/brand-reaction", "var(--palette-orchid-300)")).toBe(true);
  });
});
