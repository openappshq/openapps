import type { EmojiEntry } from "./matcher";

const SIZE = 24;
const cache = new Map<string, boolean>();

/**
 * Hides emoji this browser would draw as tofu or as several glyphs (an
 * unsupported ZWJ sequence or flag), so the picker never shows broken boxes.
 * Results are cached per emoji for the session.
 */
export function filterRenderable(entries: readonly EmojiEntry[]): EmojiEntry[] {
  const canvas = typeof document === "undefined" ? null : document.createElement("canvas");
  const ctx = canvas?.getContext("2d", { willReadFrequently: true });
  if (!canvas || !ctx) return [...entries];
  canvas.width = SIZE;
  canvas.height = SIZE;
  ctx.font = `${SIZE - 4}px "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif`;
  ctx.textBaseline = "top";

  const pixels = (text: string) => {
    ctx.clearRect(0, 0, SIZE, SIZE);
    ctx.fillText(text, 0, 0);
    return ctx.getImageData(0, 0, SIZE, SIZE).data;
  };
  const same = (a: Uint8ClampedArray, b: Uint8ClampedArray) =>
    a.every((value, i) => value === b[i]);
  const tofu = pixels("\u{10FFFD}");
  const baseWidth = ctx.measureText("😀").width;

  const canRender = (emoji: string) => {
    let ok = cache.get(emoji);
    if (ok === undefined) {
      const drawn = pixels(emoji);
      ok =
        ctx.measureText(emoji).width <= baseWidth * 1.5 &&
        drawn.some((v) => v !== 0) &&
        !same(drawn, tofu);
      cache.set(emoji, ok);
    }
    return ok;
  };
  return entries.filter((entry) => canRender(entry.emoji));
}
