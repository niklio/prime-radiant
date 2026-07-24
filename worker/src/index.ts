import { createApp } from "./app";
import { productionVerifier } from "./auth";
import { purgeSoftDeleted } from "./purge";
import type { Env } from "./types";

const app = createApp(productionVerifier);

export default {
  fetch: app.fetch,
  async scheduled(_controller, env, _ctx) {
    await purgeSoftDeleted(env);
  },
} satisfies ExportedHandler<Env>;
