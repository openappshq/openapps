import { beforeAll, describe, expect, it } from "vite-plus/test";
import {
  findExact,
  fuzzyMatch,
  search,
  stem,
  Tier,
  withinOneEdit,
  type EmojiEntry,
} from "./matcher";
import { readEmoji } from "./dataset";

const entry = (
  emoji: string,
  names: string[],
  keywords: string[] = [],
  name?: string,
): EmojiEntry => ({
  emoji,
  names,
  keywords,
  name,
});

describe("tiers", () => {
  const list = [
    entry("typo", ["zz_d"], ["thun"]),
    entry("fuzzy", ["t_h_u_m"]),
    entry("kwprefix", ["zz_b"], ["thumbnail"]),
    entry("kwexact", ["zz_c"], ["thum"]),
    entry("word", ["big_thumb"]),
    entry("prefix", ["+2", "thumbs"]),
    entry("exact", ["thum"]),
  ];

  // A keyword that stems to the query also prefix-matches it, so the stem tier is covered below.
  it("orders exact > shortcode prefix > word prefix > exact keyword > keyword prefix", () => {
    expect(search(list, "thum", { limit: 20 }).map((s) => [s.entry.emoji, s.tier])).toEqual([
      ["exact", Tier.Exact],
      ["prefix", Tier.ShortcodePrefix],
      ["word", Tier.WordPrefix],
      ["kwexact", Tier.ExactKeyword],
      ["kwprefix", Tier.KeywordPrefix],
    ]);
  });

  it("adds fuzzy and typo rows only when the strong tiers find fewer than four", () => {
    const weak = [
      entry("exact", ["thum"]),
      entry("fuzzy", ["t_h_u_m"]),
      entry("typo", ["zz_d"], ["thun"]),
    ];
    expect(search(weak, "thum").map((s) => [s.entry.emoji, s.tier])).toEqual([
      ["exact", Tier.Exact],
      ["fuzzy", Tier.Fuzzy],
      ["typo", Tier.Typo],
    ]);
    const strong = [
      ...weak,
      entry("a", ["thumb_a"]),
      entry("b", ["thumb_b"]),
      entry("c", ["thumb_c"]),
    ];
    expect(search(strong, "thum").map((s) => s.entry.emoji)).toEqual(["exact", "a", "b", "c"]);
  });

  it("matches words of the emoji name as word prefixes", () => {
    const named = [entry("🎉", ["tada"], ["hooray"], "party popper")];
    expect(search(named, "pop")[0]).toMatchObject({ name: "tada", tier: Tier.WordPrefix });
  });

  it("matches stems and typos only when nothing stronger does", () => {
    const stems = [entry("🎉", ["tada"], ["party"]), entry("😆", ["laughing"], ["laughing"])];
    expect(search(stems, "parties")[0]).toMatchObject({ name: "tada", tier: Tier.Stem });
    expect(search(stems, "laughed")[0]).toMatchObject({ name: "laughing", tier: Tier.Stem });
    expect(search([entry("❤️", ["heart"])], "haert")[0]).toMatchObject({ tier: Tier.Typo });
    expect(search([entry("❤️", ["heart"])], "hrx")).toEqual([]);
  });

  it("returns highlight indexes for shortcode matches", () => {
    const list2 = [entry("👨‍💻", ["man_technologist"]), entry("👍", ["+1", "thumbsup"])];
    expect(search(list2, "tech")[0].matched).toEqual([4, 5, 6, 7]);
    expect(search(list2, "thumb")[0]).toMatchObject({ name: "thumbsup", matched: [0, 1, 2, 3, 4] });
    expect(search(list2, "mtech")[0]).toMatchObject({ tier: Tier.Fuzzy, matched: [0, 4, 5, 6, 7] });
  });
});

describe("helpers", () => {
  it("stems plurals and verb forms", () => {
    expect(stem("parties")).toBe("party");
    expect(stem("laughing")).toBe("laugh");
    expect(stem("running")).toBe("run");
    expect(stem("falling")).toBe("fall");
    expect(stem("hearts")).toBe("heart");
    expect(stem("kiss")).toBe("kiss");
    expect(stem("boxes")).toBe("boxe");
    expect(stem("glasses")).toBe("glass");
    expect(stem("is")).toBe("is");
  });

  it("detects a single edit, including adjacent swaps", () => {
    expect(withinOneEdit("hart", "heart")).toBe(true);
    expect(withinOneEdit("haert", "heart")).toBe(true);
    expect(withinOneEdit("hearth", "heart")).toBe(true);
    expect(withinOneEdit("hrt", "heart")).toBe(false);
    expect(withinOneEdit("haret", "heart")).toBe(false);
  });

  it("scores fzy alignments and requires a word-start beginning", () => {
    expect(fuzzyMatch("heart", "hart")).toEqual({ score: 62.5, matched: [0, 2, 3, 4] });
    expect(fuzzyMatch("sm_cat", "scat")!.score).toBeGreaterThan(
      fuzzyMatch("smiley_cat", "scat")!.score,
    );
    expect(fuzzyMatch("red heart", "rhe", (c) => c === " ")).toMatchObject({ matched: [0, 4, 5] });
    expect(fuzzyMatch("taco", "aco")).toBeNull();
    expect(fuzzyMatch("man_technologist", "mtc")!.score).toBeLessThan(70);
    expect(fuzzyMatch("trade_mark", "tad")!.score).toBeLessThan(70);
  });
});

describe("gemoji dataset", () => {
  let all: EmojiEntry[];
  beforeAll(async () => {
    all = readEmoji();
  });
  const first = (query: string, recent: string[] = []) =>
    search(all, query, { recent })[0]?.entry.emoji;
  const top = (query: string, n = 3) =>
    search(all, query)
      .slice(0, n)
      .map((s) => s.entry.emoji);

  it.each([
    ["tada", "🎉"],
    ["+1", "👍"],
    ["thumbs", "👍"],
    ["fire", "🔥"],
    ["laughing", "😆"],
    ["hart", "❤️"],
    ["heart", "❤️"],
    ["rocket", "🚀"],
  ])(":%s ranks %s first", (query, emoji) => {
    expect(first(query)).toBe(emoji);
  });

  it("keeps weak tiers out once the strong ones have enough", () => {
    expect(top("tad", 10)).toEqual(["🎉"]);
    expect(top("tada", 10)).toEqual(["🎉"]);
    expect(search(all, "hart")[0]).toMatchObject({ tier: Tier.Typo });
    expect(search(all, "fire").every((s) => s.tier <= Tier.Stem)).toBe(true);
  });

  it("derives shortcodes from emoji names", () => {
    expect(findExact(all, "thumbs_up")?.emoji).toBe("👍");
    expect(findExact(all, "party_popper")?.emoji).toBe("🎉");
  });

  it(":party surfaces both party emoji", () => {
    expect(top("party", 2)).toEqual(expect.arrayContaining(["🥳", "🎉"]));
  });

  it(":parties finds party emoji through stemming", () => {
    expect(top("parties")).toEqual(expect.arrayContaining(["🎉"]));
  });

  it("reorders by session frecency within a tier", () => {
    expect(first("thumbs")).toBe("👍");
    expect(first("thumbs", ["👎"])).toBe("👎");
    expect(first("thumbs", ["👎", "👍", "👍"])).toBe("👍");
    expect(first("tada", ["🥳", "🥳"])).toBe("🎉");
  });

  it("stays well under a frame per keystroke", () => {
    const queries = ["ta", "tad", "tada", "hea", "hart", "thu", "party", "sunf", "xyzq", "man_te"];
    search(all, "warm");
    const start = performance.now();
    for (let i = 0; i < 20; i++) for (const q of queries) search(all, q);
    const perSearch = (performance.now() - start) / (20 * queries.length);
    expect(perSearch).toBeLessThan(8);
  });
});

describe("findExact", () => {
  const list = [entry("👍", ["+1", "thumbsup"], ["approve"]), entry("🎉", ["tada"])];
  it("matches primary names and aliases only", () => {
    expect(findExact(list, "thumbsup")?.emoji).toBe("👍");
    expect(findExact(list, "Tada")?.emoji).toBe("🎉");
    expect(findExact(list, "tad")).toBeUndefined();
    expect(findExact(list, "approve")).toBeUndefined();
  });
});
