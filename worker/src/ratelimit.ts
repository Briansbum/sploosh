import type { Env } from "./types";

const WINDOW_MS = 10 * 60 * 1000; // 10 minutes
const MAX_ATTEMPTS = 3;

export async function checkRateLimit(
  env: Env,
  userId: string,
  command: string,
): Promise<{ limited: boolean; retryAfterSec?: number }> {
  const now = Date.now();
  const windowStart = now - WINDOW_MS;

  const row = await env.DB.prepare(
    "SELECT attempts, window_start FROM rate_limits WHERE user_id=? AND command=?",
  )
    .bind(userId, command)
    .first<{ attempts: number; window_start: number }>();

  if (!row || row.window_start < windowStart) {
    await env.DB.prepare(
      "INSERT OR REPLACE INTO rate_limits (user_id, command, attempts, window_start) VALUES (?,?,1,?)",
    )
      .bind(userId, command, now)
      .run();
    return { limited: false };
  }

  if (row.attempts >= MAX_ATTEMPTS) {
    const retryAfterSec = Math.ceil((row.window_start + WINDOW_MS - now) / 1000);
    return { limited: true, retryAfterSec };
  }

  await env.DB.prepare(
    "UPDATE rate_limits SET attempts=attempts+1 WHERE user_id=? AND command=?",
  )
    .bind(userId, command)
    .run();
  return { limited: false };
}
