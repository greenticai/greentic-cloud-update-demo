import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

// Tests run inside workerd against the real Durable Object implementation, not
// a mock — the monotonic-sequence behaviour is only meaningful if the storage
// and the write serialization are the real ones.
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.toml" } })],
});
