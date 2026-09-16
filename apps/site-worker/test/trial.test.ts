import { env, exports } from "cloudflare:workers";
// oxlint-disable-next-line vite-plus/prefer-vite-plus-imports
import { describe, expect, it } from "vitest";
import { RATE_LIMIT_PERIOD_SECONDS, TRIAL_APPS } from "../src/trial.ts";

const URL = "https://openapps.space/api/trial";
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const DEVICE = "a".repeat(64);

let ipCounter = 0;
/** A fresh caller IP per request unless one is given, so rate limits don't leak between tests. */
const nextIp = () => `2001:db8::${(++ipCounter).toString(16)}`;

function post(body: unknown, { ip = nextIp(), raw }: { ip?: string; raw?: string } = {}) {
  return exports.default.fetch(
    new Request(URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip },
      body: raw ?? JSON.stringify(body),
    }),
  );
}

let deviceCounter = 0;
const freshDevice = () => (++deviceCounter).toString(16).padStart(64, "0");

interface Row {
  app: string;
  env: string;
  device: string;
  started_at: string;
  created_at: string;
}
const rows = async (device: string) =>
  (
    await env.DB.prepare("SELECT * FROM trials WHERE device = ?1 ORDER BY app, env")
      .bind(device)
      .all<Row>()
  ).results;

describe("POST /api/trial", () => {
  it("starts a trial now and answers in ISO 8601 without caching", async () => {
    const device = freshDevice();
    const response = await post({ app: "openklack", device, env: "live" });
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("application/json");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
    const body = await response.json<{ started_at: string; now: string }>();
    expect(Object.keys(body).sort()).toEqual(["now", "started_at"]);
    expect(body.started_at).toMatch(ISO);
    expect(body.now).toMatch(ISO);
    expect(body.started_at).toBe(body.now);
    const stored = await rows(device);
    expect(stored).toEqual([
      {
        app: "openklack",
        env: "live",
        device,
        started_at: body.started_at,
        created_at: body.started_at,
      },
    ]);
  });

  it("is idempotent: repeating a start returns the stored start and keeps one row", async () => {
    const device = freshDevice();
    const first = await (await post({ app: "openreaction", device, env: "live" })).json<{
      started_at: string;
    }>();
    await new Promise((resolve) => setTimeout(resolve, 5));
    for (let attempt = 0; attempt < 3; attempt++) {
      const response = await post({ app: "openreaction", device, env: "live" });
      expect(response.status).toBe(200);
      const body = await response.json<{ started_at: string; now: string }>();
      expect(body.started_at).toBe(first.started_at);
      expect(Date.parse(body.now)).toBeGreaterThanOrEqual(Date.parse(body.started_at));
    }
    expect(await rows(device)).toHaveLength(1);
  });

  it("never moves an existing start, earlier or later", async () => {
    const device = freshDevice();
    const fourDaysAgo = new Date(Date.now() - 4 * 24 * 60 * 60 * 1000).toISOString();
    await env.DB.prepare(
      "INSERT INTO trials (app, env, device, started_at, created_at) VALUES ('openklack', 'live', ?1, ?2, ?2)",
    )
      .bind(device, fourDaysAgo)
      .run();

    const response = await post({ app: "openklack", device, env: "live" });
    const body = await response.json<{ started_at: string; now: string }>();
    expect(body.started_at).toBe(fourDaysAgo);
    expect(Date.parse(body.now) - Date.parse(body.started_at)).toBeGreaterThan(
      4 * 24 * 60 * 60 * 1000 - 1000,
    );
    expect(await rows(device)).toEqual([
      { app: "openklack", env: "live", device, started_at: fourDaysAgo, created_at: fourDaysAgo },
    ]);
  });

  it("keeps live, test and each app separate for the same device", async () => {
    const device = freshDevice();
    const old = "2026-01-01T00:00:00.000Z";
    await env.DB.prepare(
      "INSERT INTO trials (app, env, device, started_at, created_at) VALUES ('openklack', 'live', ?1, ?2, ?2)",
    )
      .bind(device, old)
      .run();

    const test = await (await post({ app: "openklack", device, env: "test" })).json<{
      started_at: string;
    }>();
    const otherApp = await (await post({ app: "openreaction", device, env: "live" })).json<{
      started_at: string;
    }>();
    expect(test.started_at).not.toBe(old);
    expect(otherApp.started_at).not.toBe(old);
    const live = await (await post({ app: "openklack", device, env: "live" })).json<{
      started_at: string;
    }>();
    expect(live.started_at).toBe(old);
    expect((await rows(device)).map((row) => `${row.app}/${row.env}`)).toEqual([
      "openklack/live",
      "openklack/test",
      "openreaction/live",
    ]);
  });

  it("accepts exactly the catalog's paid apps: Hertz since it went on sale, macPaper since it was added", () => {
    expect([...TRIAL_APPS].sort()).toEqual(["hertz", "macpaper", "openklack", "openreaction"]);
  });

  it("starts a macPaper trial like any other app's, in test and live", async () => {
    const device = freshDevice();
    for (const env of ["test", "live"] as const) {
      const response = await post({ app: "macpaper", device, env });
      expect(response.status).toBe(200);
      const body = await response.json<{ started_at: string; now: string }>();
      expect(body.started_at).toMatch(ISO);
    }
    expect((await rows(device)).map((row) => `${row.app}/${row.env}`)).toEqual([
      "macpaper/live",
      "macpaper/test",
    ]);
  });

  it("starts a Hertz trial like any other app's", async () => {
    const device = freshDevice();
    const response = await post({ app: "hertz", device, env: "live" });
    expect(response.status).toBe(200);
    const body = await response.json<{ started_at: string; now: string }>();
    expect(body.started_at).toMatch(ISO);
    expect((await rows(device)).map((row) => `${row.app}/${row.env}`)).toEqual(["hertz/live"]);
  });

  it.each([
    ["an unknown app", { app: "openthing", device: DEVICE, env: "live" }],
    ["an app id in another case", { app: "OpenKlack", device: DEVICE, env: "live" }],
    ["an uppercase device hash", { app: "openklack", device: "A".repeat(64), env: "live" }],
    ["a short device hash", { app: "openklack", device: "a".repeat(63), env: "live" }],
    ["a long device hash", { app: "openklack", device: "a".repeat(65), env: "live" }],
    ["a non-hex device hash", { app: "openklack", device: "g".repeat(64), env: "live" }],
    ["a device hash with a newline", { app: "openklack", device: `${DEVICE}\n`, env: "live" }],
    ["an unknown env", { app: "openklack", device: DEVICE, env: "production" }],
    ["a missing field", { app: "openklack", device: DEVICE }],
    ["an extra field", { app: "openklack", device: DEVICE, env: "live", version: "1.0" }],
    ["a non-string field", { app: "openklack", device: 1, env: "live" }],
    ["null", null],
    ["an array", ["openklack", DEVICE, "live"]],
    ["a string", "openklack"],
  ])("rejects %s with 400 and stores nothing", async (_, body) => {
    const response = await post(body);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "bad_request" });
    const { count } = (await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM trials WHERE device IN (?1, ?2)",
    )
      .bind(DEVICE, "A".repeat(64))
      .first<{ count: number }>())!;
    expect(count).toBe(0);
  });

  it.each([
    ["malformed JSON", "{app:"],
    ["an empty body", ""],
    ["an oversized body", JSON.stringify({ app: "openklack", device: DEVICE, env: "live", pad: "x".repeat(4096) })],
    ["invalid UTF-8", "�"],
  ])("rejects %s with 400", async (_, raw) => {
    expect((await post(undefined, { raw })).status).toBe(400);
  });

  it("rate limits per IP with 429 and Retry-After, without touching other callers", async () => {
    const ip = "198.51.100.7";
    const statuses: number[] = [];
    let limited: Response | undefined;
    for (let attempt = 0; attempt < 40; attempt++) {
      const response = await post({ app: "openklack", device: freshDevice(), env: "test" }, { ip });
      statuses.push(response.status);
      if (response.status === 429) {
        limited = response;
        break;
      }
    }
    expect(statuses.slice(0, 30).every((status) => status === 200)).toBe(true);
    expect(limited?.status).toBe(429);
    expect(limited?.headers.get("Retry-After")).toBe(String(RATE_LIMIT_PERIOD_SECONDS));
    expect(await limited?.json()).toEqual({ error: "rate_limited" });

    const other = await post({ app: "openklack", device: freshDevice(), env: "test" });
    expect(other.status).toBe(200);
  });
});

describe("other methods and paths", () => {
  it.each(["GET", "PUT", "PATCH", "DELETE", "HEAD"])("answers %s with 405 and Allow", async (method) => {
    const response = await exports.default.fetch(new Request(URL, { method }));
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST, OPTIONS");
  });

  it("answers OPTIONS with 204 and no CORS grant", async () => {
    const response = await exports.default.fetch(
      new Request(URL, {
        method: "OPTIONS",
        headers: { Origin: "https://example.com", "Access-Control-Request-Method": "POST" },
      }),
    );
    expect(response.status).toBe(204);
    expect(response.headers.get("Allow")).toBe("POST, OPTIONS");
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });

  it("answers unknown API paths with 404", async () => {
    for (const path of ["/api/", "/api/trials", "/api/trial/"]) {
      const response = await exports.default.fetch(
        new Request(`https://openapps.space${path}`, { method: "POST" }),
      );
      expect(response.status, path).toBe(404);
    }
  });
});
