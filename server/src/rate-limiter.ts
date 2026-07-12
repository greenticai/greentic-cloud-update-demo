import { DurableObject } from "cloudflare:workers";

const WINDOW_MS = 60 * 60 * 1000;

/**
 * One Durable Object per client IP: a fixed-window counter for demo-session
 * creation. State is in-memory on purpose — an evicted object resets the window,
 * which is an acceptable trade for a demo sandbox and costs no storage writes.
 */
export class RateLimiter extends DurableObject {
  private windowStart = 0;
  private count = 0;

  /** Returns false once `limit` sessions have been taken inside the window. */
  take(limit: number): boolean {
    const now = Date.now();
    if (now - this.windowStart > WINDOW_MS) {
      this.windowStart = now;
      this.count = 0;
    }
    if (this.count >= limit) return false;
    this.count += 1;
    return true;
  }
}
