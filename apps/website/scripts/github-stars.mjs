import { mkdir, readFile, writeFile } from "node:fs/promises";

/**
 * Records the repository's star count at build time so pages can show it
 * without visitors' browsers ever calling GitHub. Failures keep the previous
 * value, or record none; they never fail the build.
 */
export async function writeGithubStars(repo, target) {
  const previous = await readFile(target, "utf8")
    .then((text) => JSON.parse(text))
    .catch(() => null);
  let stars = previous?.stars ?? null;
  let fetchedAt = previous?.fetchedAt ?? null;
  try {
    const response = await fetch(`https://api.github.com/repos/${repo}`, {
      headers: { accept: "application/vnd.github+json", "user-agent": "openapps-website-build" },
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error(`GitHub responded ${response.status}`);
    const data = await response.json();
    if (typeof data.stargazers_count === "number") {
      stars = data.stargazers_count;
      fetchedAt = new Date().toISOString();
    }
  } catch (error) {
    console.warn(`github-stars: keeping ${stars ?? "no"} stars (${error.message})`);
  }
  await mkdir(new URL("./", target), { recursive: true });
  await writeFile(target, JSON.stringify({ repo, stars, fetchedAt }, null, 2) + "\n");
}
