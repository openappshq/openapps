/** Characters allowed inside a shortcode query, e.g. `+1`, `man_technologist`, `t-rex`. */
const QUERY_CHAR = /[a-z0-9_+-]/i;
/** Characters that glue a colon to the preceding token, as in `12:30`, `http://`, `a.b:c`. */
const JOINING_CHAR = /[a-z0-9:/\\._\-+@#&=?%~$]/i;

export const MIN_QUERY_LENGTH = 2;
export const MAX_QUERY_LENGTH = 30;

export interface ActiveQuery {
  /** Index of the opening colon. */
  start: number;
  /** Caret index; the query occupies `start + 1 .. end`. */
  end: number;
  query: string;
}

/**
 * Finds the shortcode being typed immediately before the caret. A colon opens
 * a shortcode only at the start of the text or after a character that cannot
 * join it to a previous token (whitespace, brackets, quotes, emoji).
 */
export function findShortcodeToken(text: string, caret: number): ActiveQuery | null {
  let i = caret;
  while (i > 0 && QUERY_CHAR.test(text[i - 1])) i--;
  const colon = i - 1;
  if (colon < 0 || text[colon] !== ":") return null;
  if (colon > 0 && JOINING_CHAR.test(text[colon - 1])) return null;
  const query = text.slice(i, caret).toLowerCase();
  if (query.length > MAX_QUERY_LENGTH) return null;
  return { start: colon, end: caret, query };
}

/** A token long enough to show suggestions for. */
export function findActiveQuery(text: string, caret: number): ActiveQuery | null {
  const token = findShortcodeToken(text, caret);
  return token && token.query.length >= MIN_QUERY_LENGTH ? token : null;
}

/**
 * When the character just before the caret closes `:name:`, returns the span
 * (both colons included) and the name so an exact shortcode can be replaced.
 */
export function findClosedShortcode(text: string, caret: number): ActiveQuery | null {
  if (caret < 1 || text[caret - 1] !== ":") return null;
  const open = findShortcodeToken(text, caret - 1);
  if (!open || open.query.length === 0) return null;
  return { start: open.start, end: caret, query: open.query };
}

export interface Replacement {
  text: string;
  caret: number;
}

export function replaceRange(
  text: string,
  start: number,
  end: number,
  insert: string,
): Replacement {
  return { text: text.slice(0, start) + insert + text.slice(end), caret: start + insert.length };
}
