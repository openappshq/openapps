import { products } from "../../website/src/catalog.ts";

/** App ids the registry accepts: every app in the website catalog. */
export const TRIAL_APPS: ReadonlySet<string> = new Set(products.map((product) => product.id));
export const RATE_LIMIT_PERIOD_SECONDS = 60;

const FIELDS = ["app", "device", "env"];
const DEVICE = /^[0-9a-f]{64}$/;
/** A well-formed request is under 200 bytes; anything much larger is not one. */
const MAX_BODY_BYTES = 1024;
const ALLOW = "POST, OPTIONS";

export interface TrialRequest {
  app: string;
  device: string;
  env: "live" | "test";
}

export function json(body: unknown, status: number, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...headers,
    },
  });
}

/** Accepts exactly `{app, device, env}`; anything else, including extra fields, is malformed. */
export function parseTrialRequest(body: unknown): TrialRequest | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const keys = Object.keys(body);
  if (keys.length !== FIELDS.length || !FIELDS.every((field) => keys.includes(field))) return null;
  const { app, device, env } = body as Record<string, unknown>;
  if (typeof app !== "string" || !TRIAL_APPS.has(app)) return null;
  if (typeof device !== "string" || !DEVICE.test(device)) return null;
  if (env !== "live" && env !== "test") return null;
  return { app, device, env };
}

/** Reads a JSON body without buffering more than `MAX_BODY_BYTES`. */
async function readJson(request: Request): Promise<unknown> {
  if (!request.body) return undefined;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      return undefined;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    return undefined;
  }
}

/**
 * `POST /api/trial`: records the first start for an (app, env, device) and
 * always answers with that stored start, so a start never moves. Neither the
 * request body nor the caller's IP is stored or logged; the IP is only the
 * rate limit key.
 */
export async function handleTrial(request: Request, env: Env): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { Allow: ALLOW } });
  }
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405, { Allow: ALLOW });
  }

  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const { success } = await env.TRIAL_RATE_LIMIT.limit({ key: ip });
  if (!success) {
    return json({ error: "rate_limited" }, 429, {
      "Retry-After": String(RATE_LIMIT_PERIOD_SECONDS),
    });
  }

  const trial = parseTrialRequest(await readJson(request));
  if (!trial) return json({ error: "bad_request" }, 400);

  const now = new Date().toISOString();
  try {
    const [, selected] = await env.DB.batch<{ started_at: string }>([
      env.DB.prepare(
        "INSERT OR IGNORE INTO trials (app, env, device, started_at, created_at) VALUES (?1, ?2, ?3, ?4, ?4)",
      ).bind(trial.app, trial.env, trial.device, now),
      env.DB.prepare(
        "SELECT started_at FROM trials WHERE app = ?1 AND env = ?2 AND device = ?3",
      ).bind(trial.app, trial.env, trial.device),
    ]);
    const startedAt = selected?.results[0]?.started_at;
    if (!startedAt) throw new Error("Trial row missing after insert");
    return json({ started_at: startedAt, now }, 200);
  } catch {
    return json({ error: "unavailable" }, 503);
  }
}
