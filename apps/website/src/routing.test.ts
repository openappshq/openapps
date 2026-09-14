import { describe, expect, it } from "vite-plus/test";
import { classifyPath } from "./routing";

describe("classifyPath", () => {
  it("knows the site's pages in every spelling", () => {
    for (const path of [
      "/",
      "/index.html",
      "/openklack/",
      "/openklack",
      "/openklack/download/",
      "/openklack/download/index.html",
      "/openreaction/",
      "/openreaction",
      "/openreaction/thanks/",
      "/openklack/thanks/",
      "/openklack/thanks",
      "/thanks/",
      "/thanks",
    ]) {
      expect(classifyPath(path), path).toBe("page");
    }
    expect(classifyPath("/openreaction/?ref=x#try")).toBe("page");
  });

  it("treats anything with a non-HTML extension as an asset", () => {
    for (const path of [
      "/brand/openreaction/app-icon.svg",
      "/brand/missing.svg",
      "/openreaction/data/emoji.json",
      "/sounds/pack.mp3",
      "/openreaction/og.png",
      "/favicon.svg",
      "/assets/index-abc123.js",
      "/assets/home-abc123.css",
    ]) {
      expect(classifyPath(path), path).toBe("asset");
    }
  });

  it("flags unknown pages, including stray .html requests", () => {
    for (const path of [
      "/abc",
      "/abc/",
      "/openreaction/nope",
      "/foo/bar.html",
      "/home",
      "/home/",
      "/home/index.html",
      "/download/",
      "/openreaction/thanks/trial/",
      "/openklack/thanks/trial",
    ]) {
      expect(classifyPath(path), path).toBe("unknown");
    }
  });
});
