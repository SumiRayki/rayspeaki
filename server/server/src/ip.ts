/**
 * Public IP detection with periodic monitoring for dynamic IP support.
 * If MEDIASOUP_ANNOUNCED_IP is explicitly set, use it and skip monitoring.
 */

const IP_CHECK_INTERVAL = 60_000; // check every 60 seconds

const endpoints = [
  'https://api.ipify.org?format=json',
  'https://api64.ipify.org?format=json',
  'https://api.my-ip.io/v2/ip.json',
];

async function detectPublicIp(): Promise<string | null> {
  for (const url of endpoints) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
      if (!res.ok) continue;
      const data = await res.json() as Record<string, string>;
      const ip = data.ip ?? data.IPv4;
      if (ip && /^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) return ip;
    } catch {
      // try next endpoint
    }
  }
  return null;
}

export async function fetchPublicIp(): Promise<string> {
  const override = process.env.MEDIASOUP_ANNOUNCED_IP?.trim();
  if (override) {
    console.log(`[ip] Using configured MEDIASOUP_ANNOUNCED_IP: ${override}`);
    return override;
  }

  const ip = await detectPublicIp();
  if (ip) {
    console.log(`[ip] Public IP detected: ${ip}`);
    return ip;
  }

  console.warn('[ip] Could not detect public IP, falling back to 127.0.0.1');
  return '127.0.0.1';
}

/**
 * Starts periodic IP monitoring. Calls onChange(newIp) when the IP changes.
 * Returns a cleanup function to stop monitoring.
 * Does nothing if MEDIASOUP_ANNOUNCED_IP is explicitly set (static mode).
 */
export function startIpWatcher(currentIp: string, onChange: (newIp: string) => void): () => void {
  if (process.env.MEDIASOUP_ANNOUNCED_IP?.trim()) {
    console.log('[ip] Static IP configured, skipping IP watcher');
    return () => {};
  }

  let lastIp = currentIp;
  console.log(`[ip] Starting IP watcher (interval=${IP_CHECK_INTERVAL / 1000}s)`);

  const timer = setInterval(async () => {
    const ip = await detectPublicIp();
    if (!ip || ip === lastIp) return;

    console.log(`[ip] Public IP changed: ${lastIp} → ${ip}`);
    lastIp = ip;
    onChange(ip);
  }, IP_CHECK_INTERVAL);

  return () => clearInterval(timer);
}
