import { handleTrial, json } from "./trial.ts";

export default {
  async fetch(request, env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/api/trial") return handleTrial(request, env);
    if (pathname.startsWith("/api/")) return json({ error: "not_found" }, 404);
    // Only reached for `/api/*` in production (`run_worker_first`); kept for local tools.
    return env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<Env>;
