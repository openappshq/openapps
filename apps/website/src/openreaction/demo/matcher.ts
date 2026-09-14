export interface EmojiEntry {
  emoji: string;
  /** Shortcodes; the first is the primary name, the rest are aliases. */
  names: string[];
  /** Human-readable name, e.g. "party popper". */
  name?: string;
  /** Search keywords that are not shortcodes (tags and name words). */
  keywords: string[];
}

export interface Suggestion {
  entry: EmojiEntry;
  /** The shortcode shown for this suggestion. */
  name: string;
  /** Indexes in `name` that matched the query, for highlighting. */
  matched: number[];
  tier: Tier;
}

export const MAX_SUGGESTIONS = 7;

/** Match tiers, best first (lower wins). Tiers never mix. Mirrors the Mac app's EmojiSearch. */
export const Tier = {
  Exact: 0,
  ShortcodePrefix: 1,
  WordPrefix: 2,
  ExactKeyword: 3,
  KeywordPrefix: 4,
  Stem: 5,
  Fuzzy: 6,
  Typo: 7,
} as const;
export type Tier = (typeof Tier)[keyof typeof Tier];

const FUZZY_MIN_QUERY = 3;
const FUZZY_MIN_SCORE = 56;
const TYPO_MIN_QUERY = 4;
const STEM_MIN = 3;

/** Popularity prior, most common first; the same 100 emoji as the Mac app's EmojiPopularity. Keys ignore U+FE0F. */
const POPULAR = [
  "😂",
  "❤️",
  "🤣",
  "👍",
  "😭",
  "🙏",
  "😘",
  "🥰",
  "😍",
  "😊",
  "🎉",
  "😁",
  "💕",
  "🥺",
  "😅",
  "🔥",
  "☺️",
  "🤦",
  "♥️",
  "🤷",
  "🙄",
  "😆",
  "🤗",
  "😉",
  "🎂",
  "🤔",
  "👏",
  "🙂",
  "😳",
  "🥳",
  "😎",
  "👌",
  "💜",
  "😔",
  "💪",
  "✨",
  "💖",
  "👀",
  "😋",
  "😏",
  "😢",
  "👉",
  "💗",
  "😩",
  "💯",
  "🌹",
  "💞",
  "🎈",
  "💙",
  "😃",
  "😡",
  "💐",
  "😜",
  "🙈",
  "🤞",
  "😄",
  "🤤",
  "🙌",
  "🤪",
  "❣️",
  "😀",
  "💋",
  "💀",
  "👇",
  "💔",
  "😌",
  "💓",
  "🤩",
  "🙃",
  "😬",
  "😱",
  "😴",
  "🤭",
  "😐",
  "🌞",
  "😒",
  "😇",
  "🌸",
  "😈",
  "🎶",
  "✌️",
  "🎊",
  "🥵",
  "😞",
  "💚",
  "☀️",
  "🖤",
  "💰",
  "😚",
  "👑",
  "🎁",
  "💥",
  "🙋",
  "☹️",
  "😑",
  "🥴",
  "👈",
  "💩",
  "✅",
  "👋",
];
const stripVariation = (emoji: string) => emoji.replaceAll("\uFE0F", "");
const popularity = new Map(POPULAR.map((emoji, rank) => [stripVariation(emoji), rank]));

type Separator = (char: string) => boolean;
/** Shortcode words start after `_` or `-`. */
const shortcodeSeparator: Separator = (char) => char === "_" || char === "-";
/** Name words start after any ASCII character that is not a letter or digit. */
const nameSeparator: Separator = (char) => char.charCodeAt(0) < 0x80 && !/[a-z0-9]/i.test(char);

const utf8 = new TextEncoder();
const byteLength = (text: string) => utf8.encode(text.toLowerCase()).length;

/** Words of a shortcode or name, with their offsets. */
function words(text: string, isSeparator: Separator): { text: string; start: number }[] {
  const result: { text: string; start: number }[] = [];
  let start = 0;
  for (let i = 0; i <= text.length; i++) {
    if (i === text.length || isSeparator(text[i])) {
      if (i > start) result.push({ text: text.slice(start, i), start });
      start = i + 1;
    }
  }
  return result;
}

/** Suffix-stripping stemmer shared with the Mac app: `parties` → `party`, `laughing` → `laugh`. */
export function stem(word: string): string {
  const w = word.toLowerCase();
  const undouble = (s: string) =>
    s.length >= 2 && s.at(-1) === s.at(-2) && !"aeiouls".includes(s.at(-1)!) ? s.slice(0, -1) : s;
  let result = w;
  if (w.endsWith("ies")) result = w.slice(0, -3) + "y";
  else if (w.endsWith("ing")) result = undouble(w.slice(0, -3));
  else if (w.endsWith("ed")) result = undouble(w.slice(0, -2));
  else if (w.endsWith("es") && w.length - 2 >= 4) result = w.slice(0, -2);
  else if (w.endsWith("s") && !w.endsWith("ss")) result = w.slice(0, -1);
  return result.length < STEM_MIN ? w : result;
}

/** Optimal string alignment distance is at most one (insert, delete, substitute, or adjacent swap). */
export function withinOneEdit(a: string, b: string): boolean {
  if (a === b) return true;
  const diff = a.length - b.length;
  if (Math.abs(diff) > 1) return false;
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  if (diff === 0) {
    if (a.slice(i + 1) === b.slice(i + 1)) return true;
    return a[i] === b[i + 1] && a[i + 1] === b[i] && a.slice(i + 2) === b.slice(i + 2);
  }
  return diff > 0 ? a.slice(i + 1) === b.slice(i) : a.slice(i) === b.slice(i + 1);
}

const WORD_START_BONUS = 8;
const CONSECUTIVE_BONUS = 6;
const MAX_GAP_PENALTY = 6;

/**
 * fzy-style optimal alignment. Each matched character scores +8 at a word
 * start, +6 when consecutive (whichever is larger), otherwise +1; gaps cost
 * min(gap, 6). The match must begin at a word start. Returns a 0–100 score.
 */
export function fuzzyMatch(
  text: string,
  query: string,
  isSeparator: Separator = shortcodeSeparator,
): { score: number; matched: number[] } | null {
  const isWordStart = (t: string, i: number) => i === 0 || isSeparator(t[i - 1]);
  const n = query.length;
  const m = text.length;
  if (n === 0 || n > m) return null;
  const NONE = -Infinity;
  const score: number[][] = Array.from({ length: n }, () => new Array<number>(m).fill(NONE));
  const from: number[][] = Array.from({ length: n }, () => new Array<number>(m).fill(-1));

  for (let j = 0; j < m; j++) {
    if (text[j] === query[0] && isWordStart(text, j)) score[0][j] = WORD_START_BONUS;
  }
  for (let i = 1; i < n; i++) {
    for (let j = i; j < m; j++) {
      if (text[j] !== query[i]) continue;
      for (let k = i - 1; k < j; k++) {
        const previous = score[i - 1][k];
        if (previous === NONE) continue;
        const consecutive = k === j - 1;
        const bonus =
          Math.max(
            isWordStart(text, j) ? WORD_START_BONUS : 0,
            consecutive ? CONSECUTIVE_BONUS : 0,
          ) || 1;
        const total = previous + bonus - Math.min(j - k - 1, MAX_GAP_PENALTY);
        if (total > score[i][j]) {
          score[i][j] = total;
          from[i][j] = k;
        }
      }
    }
  }

  let bestEnd = -1;
  for (let j = 0; j < m; j++)
    if (score[n - 1][j] > (bestEnd < 0 ? NONE : score[n - 1][bestEnd])) bestEnd = j;
  if (bestEnd < 0 || score[n - 1][bestEnd] === NONE) return null;
  const matched = new Array<number>(n);
  for (let i = n - 1, j = bestEnd; i >= 0; j = from[i][j], i--) matched[i] = j;
  return { score: (score[n - 1][bestEnd] * 100) / (n * WORD_START_BONUS), matched };
}

/** True when every query character appears in order; a cheap filter before alignment. */
function isSubsequence(text: string, query: string): boolean {
  let i = 0;
  for (let j = 0; j < text.length && i < query.length; j++) if (text[j] === query[i]) i++;
  return i === query.length;
}

interface IndexedEntry {
  entry: EmojiEntry;
  order: number;
  shortcodes: { text: string; words: { text: string; start: number }[] }[];
  nameText: string;
  nameWords: string[];
  keywords: string[];
  stems: Set<string>;
  popularity: number;
}

const cache = new WeakMap<readonly EmojiEntry[], IndexedEntry[]>();

function indexFor(entries: readonly EmojiEntry[]): IndexedEntry[] {
  let index = cache.get(entries);
  if (!index) {
    index = entries.map((entry, order) => {
      const nameText = (entry.name ?? "").toLowerCase();
      const nameWords = words(nameText, nameSeparator).map((w) => w.text);
      const keywords = [...new Set([...entry.keywords.map((k) => k.toLowerCase()), ...nameWords])];
      return {
        entry,
        order,
        shortcodes: entry.names.map((text) => ({ text, words: words(text, shortcodeSeparator) })),
        nameText,
        nameWords,
        keywords,
        stems: new Set(keywords.map(stem)),
        popularity: popularity.get(stripVariation(entry.emoji)) ?? POPULAR.length,
      };
    });
    cache.set(entries, index);
  }
  return index;
}

const range = (from: number, length: number) => Array.from({ length }, (_, i) => from + i);

interface Hit {
  tier: Tier;
  name: string;
  matched: number[];
  quality: number;
  /** Length of the text that matched, for the "shorter match" tie-break. */
  matchedLength: number;
}

function matchEntry(item: IndexedEntry, query: string, queryStem: string): Hit | null {
  const primary = item.entry.names[0];
  const plain = (tier: Tier, matchedLength: number): Hit => ({
    tier,
    name: primary,
    matched: [],
    quality: 0,
    matchedLength,
  });

  for (const { text } of item.shortcodes) {
    if (text === query)
      return {
        tier: Tier.Exact,
        name: text,
        matched: range(0, query.length),
        quality: 0,
        matchedLength: byteLength(text),
      };
  }
  const prefix = item.shortcodes
    .filter(({ text }) => text.startsWith(query))
    .sort((a, b) => a.text.length - b.text.length)[0];
  if (prefix) {
    return {
      tier: Tier.ShortcodePrefix,
      name: prefix.text,
      matched: range(0, query.length),
      quality: 0,
      matchedLength: byteLength(prefix.text),
    };
  }
  for (const { text, words: parts } of item.shortcodes) {
    const word = parts.find((w, i) => i > 0 && w.text.startsWith(query));
    if (word)
      return {
        tier: Tier.WordPrefix,
        name: text,
        matched: range(word.start, query.length),
        quality: 0,
        matchedLength: byteLength(text),
      };
  }
  const nameWord = item.nameWords.find((w) => w.startsWith(query));
  if (nameWord) return plain(Tier.WordPrefix, byteLength(item.nameText));

  const exactKeyword = item.keywords.find((k) => k === query);
  if (exactKeyword) return plain(Tier.ExactKeyword, byteLength(exactKeyword));
  const keywordPrefix = item.keywords
    .filter((k) => k.startsWith(query))
    .sort((a, b) => a.length - b.length)[0];
  if (keywordPrefix) return plain(Tier.KeywordPrefix, byteLength(keywordPrefix));
  if (queryStem.length >= STEM_MIN && item.stems.has(queryStem))
    return plain(Tier.Stem, byteLength(item.nameText));

  if (query.length >= FUZZY_MIN_QUERY) {
    let best: Hit | null = null;
    for (const { text } of item.shortcodes) {
      if (!isSubsequence(text, query)) continue;
      const hit = fuzzyMatch(text, query);
      if (hit && hit.score >= FUZZY_MIN_SCORE && (!best || hit.score > best.quality)) {
        best = {
          tier: Tier.Fuzzy,
          name: text,
          matched: hit.matched,
          quality: hit.score,
          matchedLength: byteLength(text),
        };
      }
    }
    if (item.nameText && isSubsequence(item.nameText, query)) {
      const hit = fuzzyMatch(item.nameText, query, nameSeparator);
      if (hit && hit.score >= FUZZY_MIN_SCORE && (!best || hit.score > best.quality)) {
        best = { ...plain(Tier.Fuzzy, byteLength(item.nameText)), quality: hit.score };
      }
    }
    if (best) return best;
  }

  if (query.length >= TYPO_MIN_QUERY) {
    const typo =
      item.shortcodes.find(({ text }) => withinOneEdit(query, text))?.text ??
      [...item.nameWords, ...item.keywords].find((w) => withinOneEdit(query, w));
    if (typo) return plain(Tier.Typo, byteLength(typo));
  }
  return null;
}

/** Use counts from an insert history (repeats allowed); the Mac app also decays them over days. */
function frecencies(history: readonly string[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const emoji of history) counts.set(emoji, (counts.get(emoji) ?? 0) + 1);
  return counts;
}

/**
 * Ranks emoji for a shortcode query. Within a tier: fuzzy quality (fuzzy
 * tier only), session frecency, popularity, shorter matched text (UTF-8
 * bytes), dataset order.
 */
export function search(
  entries: readonly EmojiEntry[],
  rawQuery: string,
  { limit = MAX_SUGGESTIONS, recent = [] as readonly string[] } = {},
): Suggestion[] {
  const query = rawQuery.toLowerCase();
  if (!query) return [];
  const queryStem = stem(query);
  const frecency = frecencies(recent);
  const hits: (Hit & { item: IndexedEntry; frecency: number })[] = [];
  for (const item of indexFor(entries)) {
    const hit = matchEntry(item, query, queryStem);
    if (hit) hits.push({ ...hit, item, frecency: frecency.get(item.entry.emoji) ?? 0 });
  }
  hits.sort(
    (a, b) =>
      a.tier - b.tier ||
      b.quality - a.quality ||
      b.frecency - a.frecency ||
      a.item.popularity - b.item.popularity ||
      a.matchedLength - b.matchedLength ||
      a.item.order - b.item.order,
  );
  return hits
    .slice(0, limit)
    .map(({ item, name, matched, tier }) => ({ entry: item.entry, name, matched, tier }));
}

/** Exact shortcode lookup used when a closing colon is typed. */
export function findExact(entries: readonly EmojiEntry[], name: string): EmojiEntry | undefined {
  const query = name.toLowerCase();
  return entries.find((entry) => entry.names.includes(query));
}
