import { createClient, RedisClientType } from 'redis';
import { Pool } from 'pg';
import { config } from './config.js';

export let redis: ReturnType<typeof createClient>;
export let pg: Pool;

export interface SessionData {
  identity: string;
  role: 'user' | 'admin';
  userId: number;
}

export async function connectDb(): Promise<void> {
  // Redis
  redis = createClient({ url: config.redisUrl });
  redis.on('error', (err) => console.error('[redis]', err));

  for (let i = 0; i < 10; i++) {
    try {
      await redis.connect();
      await redis.ping();
      console.log('[redis] connected');
      break;
    } catch {
      console.log(`[redis] waiting... (${i + 1}/10)`);
      await sleep(2000);
    }
  }

  // PostgreSQL
  pg = new Pool({ connectionString: config.dbUrl });
  for (let i = 0; i < 10; i++) {
    try {
      await pg.query('SELECT 1');
      console.log('[postgres] connected');
      break;
    } catch {
      console.log(`[postgres] waiting... (${i + 1}/10)`);
      await sleep(3000);
    }
  }
}

export async function getSession(token: string): Promise<SessionData | null> {
  const raw = await redis.get(`session:${token}`);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as SessionData;
  } catch {
    return null;
  }
}

export async function getChannelPassword(channelId: string): Promise<string> {
  const result = await pg.query('SELECT COALESCE(password, \'\') FROM channels WHERE id = $1', [channelId]);
  if (result.rows.length === 0) return '';
  return result.rows[0].coalesce ?? '';
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}
