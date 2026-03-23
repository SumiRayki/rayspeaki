import { contextBridge, ipcRenderer } from 'electron';

// Read server URL directly from env (preload has Node.js access)
const serverUrl = process.env.RAYSPEAKI_SERVER_URL || 'http://localhost:4000';

contextBridge.exposeInMainWorld('electronAPI', {
  isElectron: true,
  platform: process.platform,
  serverUrl,
  getScreenSources: () => ipcRenderer.invoke('get-screen-sources'),
});
