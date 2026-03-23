import 'dotenv/config';
import http from 'http';
import path from 'path';
import { fileURLToPath } from 'url';
import express from 'express';
import { config } from './config.js';
import { connectDb } from './db.js';
import { createWorker } from './mediasoup/worker.js';
import { setupSignaling, broadcastAll } from './signaling.js';
import { fetchPublicIp, startIpWatcher } from './ip.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  // 1. Detect public IP and inject into config
  const publicIp = await fetchPublicIp();
  config.announcedIp = publicIp;
  config.turnHost = publicIp;

  // 2. Connect to databases
  await connectDb();

  // 3. Start MediaSoup worker
  await createWorker();

  // 4. Express HTTP server
  const app = express();
  app.use(express.json({ limit: '2mb' }));

  // Serve built web client
  const webDist = path.join(__dirname, '..', 'web-dist');
  app.use(express.static(webDist));

  // Health check
  app.get('/health', (_req, res) => res.json({ ok: true }));

  // Proxy auth endpoints to Go API
  const GO_API = process.env.GO_API_URL ?? 'http://127.0.0.1:3000';

  async function proxyToGoApi(req: express.Request, res: express.Response) {
    try {
      const url = `${GO_API}${req.path}`;
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      const sessionToken = req.headers['x-session-token'];
      if (sessionToken) headers['X-Session-Token'] = String(sessionToken);

      const fetchOpts: RequestInit = { method: req.method, headers };
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        fetchOpts.body = JSON.stringify(req.body);
      }

      const upstream = await fetch(url, fetchOpts);
      const body = await upstream.text();
      res.status(upstream.status).set('Content-Type', 'application/json').send(body);
    } catch (err) {
      console.error('[proxy] Go API unreachable:', err);
      res.status(502).json({ error: 'API server unavailable' });
    }
  }

  // All REST API calls proxy to Go API
  app.all('/api/*', proxyToGoApi);

  // Server info (debug)
  app.get('/info', (_req, res) => {
    res.json({ ip: config.announcedIp, rtcPorts: `${config.rtcMinPort}-${config.rtcMaxPort}` });
  });

  // SPA fallback
  app.get('*', (_req, res) => {
    res.sendFile(path.join(webDist, 'index.html'));
  });

  const httpServer = http.createServer(app);

  // 5. Socket.IO signaling
  setupSignaling(httpServer);

  // 6. Listen
  httpServer.listen(config.port, () => {
    console.log(`[server] listening on http://0.0.0.0:${config.port}`);
    console.log(`[server] announced IP: ${config.announcedIp}`);
    console.log(`[server] RTC ports: ${config.rtcMinPort}-${config.rtcMaxPort}`);
  });

  // 7. Start dynamic IP watcher (no-op if MEDIASOUP_ANNOUNCED_IP is set)
  startIpWatcher(config.announcedIp, (newIp) => {
    config.announcedIp = newIp;
    config.turnHost = newIp;
    console.log(`[server] announced IP updated to: ${newIp}`);
    // Tell all clients to rejoin — their transports have the old IP baked in
    broadcastAll('ipChanged', { newIp });
  });
}

main().catch((err) => {
  console.error('[server] fatal:', err);
  process.exit(1);
});
