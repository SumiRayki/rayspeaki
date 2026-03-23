import 'dotenv/config';

export const config = {
  port: parseInt(process.env.PORT ?? '4000', 10),
  redisUrl: process.env.REDIS_URL ?? 'redis://127.0.0.1:6379',
  dbUrl: process.env.DB_URL ?? 'postgres://rayspeaki:rayspeaki@127.0.0.1:5432/rayspeaki',

  // Set by startup script after fetching public IP
  announcedIp: process.env.MEDIASOUP_ANNOUNCED_IP?.trim() || '127.0.0.1',

  // MediaSoup RTP port range (keep small to limit Docker port mapping)
  rtcMinPort: parseInt(process.env.RTC_MIN_PORT ?? '40000', 10),
  rtcMaxPort: parseInt(process.env.RTC_MAX_PORT ?? '40100', 10),

  // TURN credentials (coturn)
  turnHost: process.env.TURN_HOST ?? '127.0.0.1',
  turnPort: parseInt(process.env.TURN_PORT ?? '3478', 10),
  turnUser: process.env.TURN_USER ?? 'rayspeaki',
  turnCredential: process.env.TURN_CREDENTIAL ?? 'rayspeakiturn',
};
