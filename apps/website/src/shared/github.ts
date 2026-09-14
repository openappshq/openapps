/** The monorepo for every OpenApps HQ app; GitHub redirects if it is renamed. */
export const GITHUB_REPO = "openappshq/openklack";
export const GITHUB_URL = `https://github.com/${GITHUB_REPO}`;

/** Written at build time by scripts/github-stars.mjs. */
export const STARS_DATA_URL = "/data/github.json";

/** 999 → "999", 1234 → "1.2k", 12345 → "12k". */
export function formatStars(stars: number): string {
  if (stars < 1000) return String(stars);
  const thousands = Math.round(stars / 100) / 10;
  const text = thousands < 10 ? String(thousands) : String(Math.round(thousands));
  return `${text}k`;
}

/** The build-time star count, or null when none was recorded. */
export async function loadStars(fetchImpl: typeof fetch = fetch): Promise<number | null> {
  try {
    const response = await fetchImpl(STARS_DATA_URL);
    if (!response.ok) return null;
    const data = (await response.json()) as { stars?: unknown };
    return typeof data.stars === "number" ? data.stars : null;
  } catch {
    return null;
  }
}
