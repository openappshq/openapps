import { describe, expect, it } from "vite-plus/test";
import { findActiveQuery, findClosedShortcode, findShortcodeToken, replaceRange } from "./trigger";

const at = (text: string) => findActiveQuery(text, text.length);

describe("findActiveQuery", () => {
  it("triggers after a colon at the start or after whitespace", () => {
    expect(at(":ta")).toEqual({ start: 0, end: 3, query: "ta" });
    expect(at("party time :tad")).toEqual({ start: 11, end: 15, query: "tad" });
    expect(at("line one\n:smi")?.query).toBe("smi");
  });

  it("triggers after brackets, quotes, and emoji", () => {
    expect(at("(:heart")?.query).toBe("heart");
    expect(at('":fire')?.query).toBe("fire");
    expect(at("🎉:tada")?.query).toBe("tada");
  });

  it("waits for two query characters", () => {
    expect(at(":")).toBeNull();
    expect(at(":t")).toBeNull();
    expect(findShortcodeToken(":t", 2)?.query).toBe("t");
  });

  it("ignores times, URLs, and colons glued to a token", () => {
    expect(at("meet at 12:30")).toBeNull();
    expect(at("see http://ex")).toBeNull();
    expect(at("https:ex")).toBeNull();
    expect(at("key:value")).toBeNull();
    expect(at("a.b:cd")).toBeNull();
    expect(at("user@host:dir")).toBeNull();
    expect(at("::tada")).toBeNull();
  });

  it("ends the token at characters that cannot be in a shortcode", () => {
    expect(at(":tada ")).toBeNull();
    expect(at(":ta.da")).toBeNull();
    expect(at(":)")).toBeNull();
  });

  it("supports symbols used by real shortcodes and lowercases the query", () => {
    expect(at(":+1")?.query).toBe("+1");
    expect(at(":t-rex")?.query).toBe("t-rex");
    expect(at(":Man_Tech")?.query).toBe("man_tech");
  });

  it("gives up on queries longer than 30 characters", () => {
    expect(at(":" + "a".repeat(30))).not.toBeNull();
    expect(at(":" + "a".repeat(31))).toBeNull();
  });

  it("uses the caret, not the end of the text", () => {
    const text = "hi :ta there";
    expect(findActiveQuery(text, 6)).toEqual({ start: 3, end: 6, query: "ta" });
    expect(findActiveQuery(text, text.length)).toBeNull();
  });
});

describe("findClosedShortcode", () => {
  it("finds :name: just before the caret", () => {
    expect(findClosedShortcode("yay :tada:", 10)).toEqual({ start: 4, end: 10, query: "tada" });
    expect(findClosedShortcode(":+1:", 4)?.query).toBe("+1");
  });

  it("rejects a closing colon without a valid opening", () => {
    expect(findClosedShortcode("12:30:", 6)).toBeNull();
    expect(findClosedShortcode("::", 2)).toBeNull();
    expect(findClosedShortcode(":tada", 5)).toBeNull();
  });
});

describe("replaceRange", () => {
  it("replaces the span and places the caret after the insertion", () => {
    expect(replaceRange("yay :tad!", 4, 8, "🎉")).toEqual({ text: "yay 🎉!", caret: 6 });
  });
});
