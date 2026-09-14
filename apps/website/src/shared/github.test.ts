import { describe, expect, it } from "vite-plus/test";
import { formatStars, loadStars } from "./github";

describe("formatStars", () => {
  it("shows small counts in full and larger ones in thousands", () => {
    expect(formatStars(0)).toBe("0");
    expect(formatStars(999)).toBe("999");
    expect(formatStars(1000)).toBe("1k");
    expect(formatStars(1234)).toBe("1.2k");
    expect(formatStars(9950)).toBe("10k");
    expect(formatStars(12345)).toBe("12k");
  });
});

describe("loadStars", () => {
  const respond = (body: unknown, ok = true) =>
    (() => Promise.resolve({ ok, json: () => Promise.resolve(body) } as Response)) as typeof fetch;

  it("reads the build-time count", async () => {
    expect(await loadStars(respond({ stars: 42 }))).toBe(42);
  });

  it("returns null when the count is missing, the file is absent, or the fetch fails", async () => {
    expect(await loadStars(respond({ stars: null }))).toBeNull();
    expect(await loadStars(respond({}, false))).toBeNull();
    expect(
      await loadStars((() => Promise.reject(new Error("offline"))) as typeof fetch),
    ).toBeNull();
  });
});
