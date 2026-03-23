import { app, BrowserWindow, ipcMain, desktopCapturer, session } from 'electron';
import path from 'path';

let mainWindow: BrowserWindow | null = null;

// Server URL — configure via env or default
const SERVER_URL = process.env.RAYSPEAKI_SERVER_URL || 'http://localhost:4000';
const isDev = process.argv.includes('--dev');

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    title: 'RaySpeaki',
    backgroundColor: '#0a0a0f',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      offscreen: false,
    },
    frame: false,
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: 'rgba(0,0,0,0)',
      symbolColor: '#9d9db5',
      height: 36,
    },
    show: false,
  });

  // Load the local renderer instead of remote server URL
  mainWindow.loadFile(path.join(__dirname, '../renderer-dist/index.html'));

  // Show window when ready to prevent white flash
  mainWindow.once('ready-to-show', () => {
    mainWindow?.show();
  });

  if (isDev) {
    mainWindow.webContents.openDevTools();
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// ─── IPC: Server URL ────────────────────────────────────────────────────────

ipcMain.handle('get-server-url', () => SERVER_URL);

// ─── IPC: Screen capture sources ─────────────────────────────────────────────

ipcMain.handle('get-screen-sources', async () => {
  const sources = await desktopCapturer.getSources({
    types: ['screen', 'window'],
    thumbnailSize: { width: 320, height: 180 },
    fetchWindowIcons: true,
  });
  return sources.map((s) => ({
    id: s.id,
    name: s.name,
    thumbnail: s.thumbnail.toDataURL(),
  }));
});

// ─── App lifecycle ────────────────────────────────────────────────────────────

// Ensure hardware acceleration is enabled (default, but explicit)
app.commandLine.appendSwitch('enable-gpu-rasterization');
app.commandLine.appendSwitch('enable-zero-copy');

// Fix for getUserMedia with desktopCapturer in newer Electron
app.commandLine.appendSwitch('enable-features', 'WebRtcHideLocalIpsWithMdns');

app.on('ready', () => {
  // Allow getUserMedia to use desktopCapturer sources
  session.defaultSession.setDisplayMediaRequestHandler((_request, callback) => {
    // This is called for getDisplayMedia; we handle it via desktopCapturer instead
    callback({ video: undefined });
  });

  createWindow();
});

app.on('window-all-closed', () => {
  app.quit();
});

app.on('activate', () => {
  if (mainWindow === null) createWindow();
});
