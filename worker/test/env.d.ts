import type { D1Migration } from "cloudflare:test";

// Types the `env` imported from "cloudflare:test" in tests. Mirrors
// src/types.ts Env (structural match is asserted where env is passed to app
// code), plus the migrations passed through miniflare bindings in
// vitest.config.ts.
declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      SESSIONS: KVNamespace;
      RATE_LIMIT_PER_MINUTE?: string;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

export {};
