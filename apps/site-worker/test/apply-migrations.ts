import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Setup files may run more than once; only unapplied migrations are applied.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
