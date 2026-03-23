import { Device } from 'mediasoup-client';
import type { Transport, Producer, Consumer } from 'mediasoup-client/lib/types';
import { io, Socket } from 'socket.io-client';
import { startAurora } from './aurora';

// ─── Platform detection ──────────────────────────────────────────────────────

const electronAPI = (window as any).electronAPI as {
  isElectron: boolean;
  serverUrl: string;
  getScreenSources: () => Promise<{ id: string; name: string; thumbnail: string }[]>;
} | undefined;
const isElectron = !!electronAPI?.isElectron;

// ─── Server URL (injected by Electron preload, fallback for web) ────────────
const SERVER_URL = electronAPI?.serverUrl || '';

// ─── Custom dialog (replaces prompt/confirm/alert which don't work in Electron) ──

function showDialog(opts: {
  title: string;
  defaultValue?: string;
  showInput?: boolean;
  showCancel?: boolean;
}): Promise<string | null> {
  return new Promise((resolve) => {
    const overlay = document.getElementById('dialog-modal')!;
    const titleEl = document.getElementById('dialog-title')!;
    const inputWrap = document.getElementById('dialog-input-wrap')!;
    const inputEl = document.getElementById('dialog-input') as HTMLInputElement;
    const cancelBtn = document.getElementById('dialog-cancel')!;
    const okBtn = document.getElementById('dialog-ok')!;

    titleEl.textContent = opts.title;
    inputWrap.style.display = opts.showInput ? '' : 'none';
    cancelBtn.style.display = opts.showCancel !== false ? '' : 'none';
    if (opts.showInput) {
      inputEl.value = opts.defaultValue ?? '';
      inputEl.type = 'text';
    }

    overlay.classList.add('open');
    if (opts.showInput) setTimeout(() => inputEl.focus(), 50);

    const cleanup = () => {
      overlay.classList.remove('open');
      okBtn.removeEventListener('click', onOk);
      cancelBtn.removeEventListener('click', onCancel);
      inputEl.removeEventListener('keydown', onKey);
    };
    const onOk = () => { cleanup(); resolve(opts.showInput ? inputEl.value : 'ok'); };
    const onCancel = () => { cleanup(); resolve(null); };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Enter') onOk(); if (e.key === 'Escape') onCancel(); };

    okBtn.addEventListener('click', onOk);
    cancelBtn.addEventListener('click', onCancel);
    if (opts.showInput) inputEl.addEventListener('keydown', onKey);
  });
}

function dialogPrompt(title: string, defaultValue = ''): Promise<string | null> {
  return showDialog({ title, defaultValue, showInput: true, showCancel: true });
}

function dialogConfirm(title: string): Promise<boolean> {
  return showDialog({ title, showInput: false, showCancel: true }).then((v) => v !== null);
}

function dialogAlert(title: string): Promise<void> {
  return showDialog({ title, showInput: false, showCancel: false }).then(() => {});
}

// ─── Storage ─────────────────────────────────────────────────────────────────

const LS = {
  get: (k: string) => localStorage.getItem(`rs_${k}`),
  set: (k: string, v: string) => localStorage.setItem(`rs_${k}`, v),
  del: (k: string) => localStorage.removeItem(`rs_${k}`),
};

// ─── Channel backgrounds (presets, cycled by channel index) ──────────────────

const channelBgs = [
  'linear-gradient(135deg, #0f2027 0%, #203a43 50%, #2c5364 100%)',
  'linear-gradient(135deg, #1a0533 0%, #2d1b69 50%, #1a3a5c 100%)',
  'linear-gradient(135deg, #141e30 0%, #243b55 100%)',
  'linear-gradient(135deg, #0c0c1d 0%, #1a3a3a 50%, #204040 100%)',
  'linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%)',
  'linear-gradient(135deg, #1a0a2e 0%, #2b1055 50%, #3a1078 100%)',
  'linear-gradient(135deg, #0d1117 0%, #1b3a4b 50%, #0d2137 100%)',
  'linear-gradient(135deg, #0a0e27 0%, #1a1a4e 50%, #2a1a3a 100%)',
];

function getChannelBg(channelId: string): string {
  let hash = 0;
  for (let i = 0; i < channelId.length; i++) hash = ((hash << 5) - hash + channelId.charCodeAt(i)) | 0;
  return channelBgs[Math.abs(hash) % channelBgs.length];
}

// ─── State ────────────────────────────────────────────────────────────────────

let session = LS.get('session') ?? '';
let identity = LS.get('identity') ?? '';
let role = LS.get('role') ?? 'user';
let myAvatar = LS.get('avatar') ?? '';
let currentChannelId: string | null = null;
let currentChannelName: string | null = null;
let channels: { id: string; name: string; background?: string; hasPassword?: boolean }[] = [];

const channelMembers = new Map<string, { id: string; identity: string }[]>();
let onlineUsers: { identity: string }[] = [];
const avatarCache = new Map<string, string>();

let socket: Socket;
let device: Device;
let sendTransport: Transport | null = null;
let recvTransport: Transport | null = null;
let micProducer: Producer | null = null;
let screenProducer: Producer | null = null;
const consumers = new Map<string, Consumer>();

interface ProducerInfo { kind: string; appData?: Record<string, unknown> }
interface PeerData { identity: string; producers: Map<string, ProducerInfo> }
const peerMap = new Map<string, PeerData>();

let micEnabled = false;
let screenSharing = false;
let micNsCleanup: (() => void) | null = null;

// Volume per peer (peerId → 0-1)
const peerVolumes = new Map<string, number>();

// Audio device selection
let selectedInputDeviceId = LS.get('audioInput') ?? '';
let selectedOutputDeviceId = LS.get('audioOutput') ?? '';
let nsEnabled = LS.get('noiseSuppression') !== 'off';

// ─── SVG Icons ────────────────────────────────────────────────────────────────

const svgMic = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="23"/><line x1="8" y1="23" x2="16" y2="23"/></svg>`;
const svgMicOff = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="1" y1="1" x2="23" y2="23"/><path d="M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6"/><path d="M17 16.95A7 7 0 0 1 5 12v-2m14 0v2c0 .76-.13 1.49-.35 2.17"/><line x1="12" y1="19" x2="12" y2="23"/><line x1="8" y1="23" x2="16" y2="23"/></svg>`;
const svgVolume = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/></svg>`;
const svgEdit = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>`;
const svgImage = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>`;
const svgTrash = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>`;
const svgDots = `<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="12" cy="19" r="2"/></svg>`;
const svgLock = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>`;

// ─── DOM helpers ──────────────────────────────────────────────────────────────

const $ = (id: string) => document.getElementById(id)!;

let stopAurora: (() => void) | null = null;
const auroraCanvas = document.getElementById('aurora-canvas') as HTMLCanvasElement | null;
if (auroraCanvas) stopAurora = startAurora(auroraCanvas);

function showError(msg: string) { $('login-error').textContent = msg; }

function showApp() {
  if (stopAurora) { stopAurora(); stopAurora = null; }
  // Animated transition: login fades out, app fades in
  const loginCard = document.querySelector('.login-card');
  loginCard?.classList.add('slide-up');
  setTimeout(() => {
    $('login-screen').classList.add('fade-out');
    setTimeout(() => {
      $('login-screen').style.display = 'none';
      $('app').style.display = 'block';
      // Trigger reflow then animate
      void $('app').offsetHeight;
      $('app').classList.add('visible');
    }, 400);
  }, 150);
  renderUserAvatar();
  $('user-name-display').textContent = identity;
  $('user-role-display').textContent = role === 'admin' ? '管理员' : '成员';
  if (role === 'admin') $('add-channel-btn').style.display = '';
  if (isElectron) $('screen-btn').style.display = '';
}

// ─── Render batching ─────────────────────────────────────────────────────────

let renderChannelsQueued = false;
function queueRenderChannels() {
  if (renderChannelsQueued) return;
  renderChannelsQueued = true;
  requestAnimationFrame(() => { renderChannelsQueued = false; renderChannels(); });
}

let renderOnlineQueued = false;
function queueRenderOnline() {
  if (renderOnlineQueued) return;
  renderOnlineQueued = true;
  requestAnimationFrame(() => { renderOnlineQueued = false; renderOnlineUsers(); });
}

let renderMembersQueued = false;
function queueRenderMembers() {
  if (renderMembersQueued) return;
  renderMembersQueued = true;
  requestAnimationFrame(() => { renderMembersQueued = false; renderMembers(); });
}

// ─── API ──────────────────────────────────────────────────────────────────────

async function apiPost(path: string, body: unknown) {
  return fetch(`${SERVER_URL}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Session-Token': session }, body: JSON.stringify(body) });
}
async function apiGet(path: string) {
  return fetch(`${SERVER_URL}${path}`, { headers: { 'X-Session-Token': session } });
}
async function apiPut(path: string, body: unknown) {
  return fetch(`${SERVER_URL}${path}`, { method: 'PUT', headers: { 'Content-Type': 'application/json', 'X-Session-Token': session }, body: JSON.stringify(body) });
}
async function apiDelete(path: string) {
  return fetch(`${SERVER_URL}${path}`, { method: 'DELETE', headers: { 'X-Session-Token': session } });
}

// ─── Avatar ──────────────────────────────────────────────────────────────────

function renderUserAvatar() {
  const el = $('user-avatar');
  if (myAvatar) {
    el.innerHTML = `<img src="${myAvatar}" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`;
  } else {
    el.innerHTML = '';
    el.textContent = identity.charAt(0).toUpperCase();
  }
}

function pickAvatar() {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = 'image/*';
  input.onchange = async () => {
    const file = input.files?.[0];
    if (!file) return;
    const dataUrl = await resizeImage(file, 128);
    const res = await apiPut('/api/avatar', { avatar: dataUrl });
    if (res.ok) {
      myAvatar = dataUrl;
      LS.set('avatar', myAvatar);
      avatarCache.set(identity, myAvatar);
      renderUserAvatar();
      if (currentChannelId) renderMembers();
      renderOnlineUsers();
    }
  };
  input.click();
}

function resizeImage(file: File, maxSize: number, square = true): Promise<string> {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement('canvas');
      if (square) {
        canvas.width = maxSize;
        canvas.height = maxSize;
        const ctx = canvas.getContext('2d')!;
        const min = Math.min(img.width, img.height);
        const sx = (img.width - min) / 2;
        const sy = (img.height - min) / 2;
        ctx.drawImage(img, sx, sy, min, min, 0, 0, maxSize, maxSize);
      } else {
        const scale = Math.min(maxSize / img.width, maxSize / img.height, 1);
        canvas.width = Math.round(img.width * scale);
        canvas.height = Math.round(img.height * scale);
        const ctx = canvas.getContext('2d')!;
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      }
      resolve(canvas.toDataURL('image/jpeg', 0.85));
    };
    img.src = URL.createObjectURL(file);
  });
}

async function fetchAvatar(username: string): Promise<string> {
  const cached = avatarCache.get(username);
  if (cached !== undefined) return cached;
  try {
    const res = await apiGet(`/api/avatar?username=${encodeURIComponent(username)}`);
    if (res.ok) {
      const data = await res.json();
      avatarCache.set(username, data.avatar || '');
      return data.avatar || '';
    }
  } catch {}
  avatarCache.set(username, '');
  return '';
}

// ─── Login ────────────────────────────────────────────────────────────────────

async function login() {
  const username = ($('login-username') as HTMLInputElement).value.trim();
  const password = ($('login-password') as HTMLInputElement).value;
  if (!username || !password) { showError('请填写用户名和密码'); return; }
  const res = await apiPost('/api/login', { username, password }).catch(() => null);
  if (!res || !res.ok) { showError(res ? '密码错误' : '无法连接服务器'); return; }
  const data = await res.json();
  session = data.session; identity = data.identity; role = data.role;
  LS.set('session', session); LS.set('identity', identity); LS.set('role', role);
  const meRes = await apiGet('/api/me').catch(() => null);
  if (meRes?.ok) {
    const me = await meRes.json();
    myAvatar = me.avatar || '';
    LS.set('avatar', myAvatar);
    if (myAvatar) avatarCache.set(identity, myAvatar);
  }
  showApp();
  await initSignaling();
  await loadChannels();
}

async function logout() {
  await apiPost('/api/logout', {});
  ['session', 'identity', 'role', 'avatar'].forEach((k) => LS.del(k));
  window.location.reload();
}

// ─── Channels ─────────────────────────────────────────────────────────────────

async function loadChannels() {
  const res = await apiGet('/api/channels').catch(() => null);
  if (!res?.ok) return;
  channels = await res.json();
  try {
    const data: { channels: Record<string, { id: string; identity: string }[]> } = await emit('getChannelMembers', {});
    channelMembers.clear();
    for (const [chId, members] of Object.entries(data.channels)) {
      channelMembers.set(chId, members);
    }
  } catch {}
  renderChannels();
}

function renderChannels() {
  const list = $('channel-list');
  list.innerHTML = '';
  for (const ch of channels) {
    const group = document.createElement('div');
    group.className = 'channel-group';
    const members = channelMembers.get(String(ch.id)) ?? [];
    const isActive = String(ch.id) === currentChannelId;

    const el = document.createElement('div');
    el.className = 'channel-item' + (isActive ? ' active' : '');
    const lockIcon = ch.hasPassword ? `<span class="ch-lock" title="需要密码">${svgLock}</span>` : '';
    el.innerHTML = `<span class="ch-icon">${svgVolume}</span><span class="ch-name">${esc(ch.name)}</span>${lockIcon}${members.length ? `<span class="ch-count">${members.length}</span>` : ''}${role === 'admin' ? `<div class="ch-menu-wrap"><button class="ch-menu-btn" data-id="${ch.id}" title="频道设置">${svgDots}</button><div class="ch-menu" data-id="${ch.id}"><button class="ch-menu-item edit-channel" data-id="${ch.id}" data-name="${esc(ch.name)}">${svgEdit} 重命名</button><button class="ch-menu-item bg-channel" data-id="${ch.id}">${svgImage} 更换背景</button><button class="ch-menu-item pw-channel" data-id="${ch.id}">${svgLock} ${ch.hasPassword ? '修改密码' : '设置密码'}</button><button class="ch-menu-item del-channel" data-id="${ch.id}">${svgTrash} 删除频道</button></div></div>` : ''}`;
    el.addEventListener('dblclick', (e) => {
      if ((e.target as HTMLElement).closest('.ch-menu-wrap')) return;
      joinChannel(String(ch.id), ch.name);
    });
    el.addEventListener('click', (e) => {
      const menuBtn = (e.target as HTMLElement).closest('.ch-menu-btn');
      if (menuBtn) {
        e.stopPropagation();
        const menu = el.querySelector('.ch-menu') as HTMLElement;
        if (menu) {
          const wasOpen = menu.classList.contains('open');
          document.querySelectorAll('.ch-menu.open').forEach((m) => m.classList.remove('open'));
          if (!wasOpen) menu.classList.add('open');
        }
        return;
      }
      const ed = (e.target as HTMLElement).closest('.edit-channel');
      if (ed) { document.querySelectorAll('.ch-menu.open').forEach((m) => m.classList.remove('open')); renameChannel(ed.getAttribute('data-id')!, ed.getAttribute('data-name')!); return; }
      const bg = (e.target as HTMLElement).closest('.bg-channel');
      if (bg) { document.querySelectorAll('.ch-menu.open').forEach((m) => m.classList.remove('open')); changeChannelBg(bg.getAttribute('data-id')!); return; }
      const pw = (e.target as HTMLElement).closest('.pw-channel');
      if (pw) { document.querySelectorAll('.ch-menu.open').forEach((m) => m.classList.remove('open')); setChannelPassword(pw.getAttribute('data-id')!); return; }
      const d = (e.target as HTMLElement).closest('.del-channel');
      if (d) { document.querySelectorAll('.ch-menu.open').forEach((m) => m.classList.remove('open')); deleteChannel(d.getAttribute('data-id')!); return; }
    });
    group.appendChild(el);

    if (members.length > 0) {
      const ml = document.createElement('div');
      ml.className = 'channel-members';
      ml.innerHTML = members.map((m) => {
        const av = m.identity === identity ? myAvatar : avatarCache.get(m.identity);
        const avHtml = av
          ? `<div class="mini-avatar"><img src="${av}" style="width:100%;height:100%;object-fit:cover;border-radius:50%"></div>`
          : `<div class="mini-avatar">${esc(m.identity[0].toUpperCase())}</div>`;
        if (!avatarCache.has(m.identity) && m.identity !== identity) fetchAvatar(m.identity).then(() => queueRenderChannels());
        return `<div class="channel-member">${avHtml}<span>${esc(m.identity)}</span></div>`;
      }).join('');
      group.appendChild(ml);
    }
    list.appendChild(group);
  }
}

// Close channel menus on click-outside
document.addEventListener('click', (e) => {
  if (!(e.target as HTMLElement).closest('.ch-menu-wrap')) {
    document.querySelectorAll('.ch-menu.open').forEach((m) => m.classList.remove('open'));
  }
});

async function createChannel(name: string) {
  if (!(await apiPost('/api/channels', { name })).ok) return;
  await loadChannels();
}

async function renameChannel(id: string, currentName: string) {
  const newName = await dialogPrompt('修改频道名称:', currentName);
  if (!newName || newName.trim() === '' || newName.trim() === currentName) return;
  const res = await apiPut(`/api/channels/${id}`, { name: newName.trim() });
  if (!res.ok) { await dialogAlert('修改失败'); return; }
  await loadChannels();
}

async function changeChannelBg(id: string) {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = 'image/*';
  input.onchange = async () => {
    const file = input.files?.[0];
    if (!file) return;
    const dataUrl = await resizeImage(file, 1920, false);
    const res = await apiPut(`/api/channels/${id}`, { background: dataUrl });
    if (!res.ok) { await dialogAlert('更换背景失败'); return; }
    await loadChannels();
    if (currentChannelId === id) updateBackground();
  };
  input.click();
}

async function deleteChannel(id: string) {
  if (!(await dialogConfirm('确认删除该频道？'))) return;
  await apiDelete(`/api/channels/${id}`);
  if (currentChannelId === id) await leaveCurrentChannel();
  await loadChannels();
}

async function setChannelPassword(id: string) {
  const ch = channels.find((c) => String(c.id) === id);
  const pw = await dialogPrompt(ch?.hasPassword ? '输入新密码 (留空则取消密码):' : '设置频道密码:', '');
  if (pw === null) return; // cancelled
  const res = await apiPut(`/api/channels/${id}`, { password: pw });
  if (!res.ok) { await dialogAlert('设置密码失败'); return; }
  await loadChannels();
}

// ─── Online users ─────────────────────────────────────────────────────────────

function renderOnlineUsers() {
  const list = $('online-list');
  $('online-count').textContent = String(onlineUsers.length);
  list.innerHTML = onlineUsers.map((u) => {
    const av = u.identity === identity ? myAvatar : avatarCache.get(u.identity);
    const avHtml = av
      ? `<div class="online-av"><img src="${av}" style="width:100%;height:100%;object-fit:cover;border-radius:50%"><div class="online-dot"></div></div>`
      : `<div class="online-av">${esc(u.identity[0].toUpperCase())}<div class="online-dot"></div></div>`;
    if (!avatarCache.has(u.identity) && u.identity !== identity) fetchAvatar(u.identity).then(() => queueRenderOnline());
    return `<div class="online-user">${avHtml}<span class="online-name">${esc(u.identity)}</span></div>`;
  }).join('');
}

// ─── Background ───────────────────────────────────────────────────────────────

function updateBackground() {
  const bg = $('app-bg');
  if (currentChannelId) {
    const ch = channels.find((c) => String(c.id) === currentChannelId);
    if (ch?.background) {
      bg.style.background = `url(${ch.background}) center/cover no-repeat`;
    } else {
      bg.style.background = getChannelBg(currentChannelId);
    }
    bg.style.backgroundSize = 'cover';
    bg.classList.add('has-bg');
  } else {
    bg.style.background = '#0a0a0f';
    bg.classList.remove('has-bg');
  }
}

// ─── Socket.IO ────────────────────────────────────────────────────────────────

function initSignaling(): Promise<void> {
  return new Promise((resolve) => {
    socket = io(SERVER_URL, { transports: ['websocket'] });

    socket.on('connect', () => {
      socket.emit('authenticate', { token: session }, () => resolve());
    });

    socket.on('initialState', (data: { channelMembers: Record<string, { id: string; identity: string }[]>; onlineUsers: { identity: string }[] }) => {
      channelMembers.clear();
      for (const [chId, m] of Object.entries(data.channelMembers)) channelMembers.set(chId, m);
      onlineUsers = data.onlineUsers;
      renderChannels();
      renderOnlineUsers();
    });

    socket.on('peerJoined', ({ id, identity: name }: { id: string; identity: string }) => {
      peerMap.set(id, { identity: name, producers: new Map() });
      queueRenderMembers();
    });
    socket.on('peerLeft', ({ id }: { id: string }) => {
      peerMap.get(id)?.producers.forEach((info, pid) => {
        if (info.appData?.source === 'screen') hideScreenShareView(pid);
        const c = [...consumers.values()].find((x) => x.producerId === pid);
        c?.close(); if (c) consumers.delete(c.id);
      });
      peerMap.delete(id);
      queueRenderMembers();
    });
    socket.on('newProducer', async ({ peerId, producerId, kind, appData }: { peerId: string; producerId: string; kind: string; appData?: Record<string, unknown> }) => {
      const p = peerMap.get(peerId);
      if (p) p.producers.set(producerId, { kind, appData });
      if (kind === 'audio') await subscribeToProducer(producerId, peerId);
      if (kind === 'video' && appData?.source === 'screen') await subscribeToScreenShare(producerId, peerId);
      queueRenderMembers();
    });
    socket.on('producerClosed', ({ peerId, producerId }: { peerId: string; producerId: string }) => {
      const info = peerMap.get(peerId)?.producers.get(producerId);
      if (info?.appData?.source === 'screen') hideScreenShareView(producerId);
      peerMap.get(peerId)?.producers.delete(producerId);
      const c = [...consumers.values()].find((x) => x.producerId === producerId);
      c?.close(); if (c) consumers.delete(c.id);
      queueRenderMembers();
    });
    socket.on('channelMembersUpdated', ({ channelId, members }: { channelId: string; members: { id: string; identity: string }[] }) => {
      if (members.length === 0) channelMembers.delete(channelId); else channelMembers.set(channelId, members);
      queueRenderChannels();
    });
    socket.on('onlineUsersUpdated', ({ users }: { users: { identity: string }[] }) => {
      onlineUsers = users;
      queueRenderOnline();
    });
    socket.on('ipChanged', async ({ newIp }: { newIp: string }) => {
      if (currentChannelId) {
        const ch = channels.find((c) => String(c.id) === currentChannelId);
        const wasMic = micEnabled;
        await leaveCurrentChannel();
        if (ch) { await joinChannel(String(ch.id), ch.name); if (wasMic) await toggleMic(); }
      }
    });
  });
}

// ─── Channel join/leave ───────────────────────────────────────────────────────

async function joinChannel(channelId: string, channelName: string) {
  if (currentChannelId === channelId) return;

  // Check if channel has password and user is not admin
  const ch = channels.find((c) => String(c.id) === channelId);
  let password: string | undefined;
  if (ch?.hasPassword && role !== 'admin') {
    const pw = await dialogPrompt('请输入频道密码:');
    if (pw === null) return; // cancelled
    password = pw;
  }

  await leaveCurrentChannel();

  currentChannelId = channelId;
  currentChannelName = channelName;
  updateBackground();
  updateVoiceStatus();
  renderChannels();

  let joinResult: { peers: any[]; error?: string };
  try {
    joinResult = await emit('joinChannel', { channelId, password });
  } catch (e: any) {
    if (e.message === 'wrong_password') {
      await dialogAlert('密码错误');
      currentChannelId = null;
      currentChannelName = null;
      updateBackground();
      updateVoiceStatus();
      renderChannels();
      return;
    }
    throw e;
  }
  const { peers } = joinResult as { peers: { id: string; identity: string; producers: { id: string; kind: string; appData?: Record<string, unknown> }[] }[] };
  peerMap.clear();
  for (const p of peers) {
    const pm: PeerData = { identity: p.identity, producers: new Map() };
    for (const pr of p.producers) pm.producers.set(pr.id, { kind: pr.kind, appData: pr.appData });
    peerMap.set(p.id, pm);
  }

  const { routerRtpCapabilities } = await emit('getRtpCapabilities', {});
  device = new Device();
  await device.load({ routerRtpCapabilities });
  await createSendTransport();
  await createRecvTransport();

  renderVoicePanel();
  renderMembers();

  // Subscribe AFTER rendering voice panel (so screen share view can attach to .voice-panel)
  for (const p of peers) {
    for (const pr of p.producers) {
      if (pr.kind === 'audio') await subscribeToProducer(pr.id, p.id);
      if (pr.kind === 'video' && pr.appData?.source === 'screen') await subscribeToScreenShare(pr.id, p.id);
    }
  }

  // Auto-enable mic
  try { await toggleMic(); } catch {}
}

async function leaveCurrentChannel() {
  if (!currentChannelId) return;
  // Stop screen share if active
  if (screenProducer) {
    screenProducer.close();
    emit('closeProducer', { producerId: screenProducer.id }).catch(() => {});
    screenProducer = null; screenSharing = false;
  }
  if (micProducer) { micProducer.close(); micProducer = null; micEnabled = false; }
  if (micNsCleanup) { micNsCleanup(); micNsCleanup = null; }
  sendTransport?.close(); sendTransport = null;
  recvTransport?.close(); recvTransport = null;
  consumers.forEach((c) => c.close()); consumers.clear();
  peerMap.clear();
  emit('leaveChannel', {}).catch(() => {});
  currentChannelId = null; currentChannelName = null;
  updateBackground();
  updateVoiceStatus();
  $('dock').classList.remove('active');
}

// ─── Transports ───────────────────────────────────────────────────────────────

async function createSendTransport() {
  const info = await emit('createTransport', { direction: 'send' });
  sendTransport = device.createSendTransport(info);
  sendTransport.on('connect', ({ dtlsParameters }, cb, eb) => { emit('connectTransport', { transportId: sendTransport!.id, dtlsParameters }).then(cb).catch(eb); });
  sendTransport.on('produce', ({ kind, rtpParameters, appData }, cb, eb) => { emit('produce', { transportId: sendTransport!.id, kind, rtpParameters, appData }).then(({ producerId }) => cb({ id: producerId })).catch(eb); });
}

async function createRecvTransport() {
  const info = await emit('createTransport', { direction: 'recv' });
  recvTransport = device.createRecvTransport(info);
  recvTransport.on('connect', ({ dtlsParameters }, cb, eb) => { emit('connectTransport', { transportId: recvTransport!.id, dtlsParameters }).then(cb).catch(eb); });
}

async function subscribeToProducer(producerId: string, peerId?: string) {
  if (!device || !recvTransport) return;
  const ci = await emit('consume', { producerId, rtpCapabilities: device.rtpCapabilities });
  const consumer = await recvTransport.consume(ci);
  consumers.set(consumer.id, consumer);
  await consumer.resume();

  const audio = new Audio();
  audio.id = `audio-${consumer.id}`;
  if (peerId) audio.dataset.peerId = peerId;
  audio.srcObject = new MediaStream([consumer.track]);
  audio.autoplay = true;
  audio.volume = peerId ? (peerVolumes.get(peerId) ?? 1) : 1;
  if (selectedOutputDeviceId && typeof (audio as any).setSinkId === 'function') {
    (audio as any).setSinkId(selectedOutputDeviceId).catch(() => {});
  }
  document.body.appendChild(audio);
  audio.play().catch(() => {});

  const cleanup = () => document.getElementById(`audio-${consumer.id}`)?.remove();
  consumer.on('close', cleanup);
  consumer.on('transportclose', cleanup);
}

// ─── Screen sharing ───────────────────────────────────────────────────────────

async function subscribeToScreenShare(producerId: string, peerId: string) {
  if (!device || !recvTransport) return;
  const ci = await emit('consume', { producerId, rtpCapabilities: device.rtpCapabilities });
  const consumer = await recvTransport.consume(ci);
  consumers.set(consumer.id, consumer);
  await consumer.resume();

  showScreenShareView(consumer, peerId);

  consumer.on('close', () => { hideScreenShareView(producerId); consumers.delete(consumer.id); });
  consumer.on('transportclose', () => { hideScreenShareView(producerId); });
}

function showScreenShareView(consumer: Consumer, peerId: string) {
  const panel = document.querySelector('.voice-panel');
  if (!panel) return;

  let view = document.getElementById('screen-share-container') as HTMLDivElement | null;
  if (!view) {
    view = document.createElement('div');
    view.id = 'screen-share-container';
    view.className = 'screen-share-view';
    view.innerHTML = `
      <video autoplay playsinline></video>
      <div class="screen-share-label">屏幕共享中</div>
      <div class="screen-share-controls">
        <button class="ss-ctrl-btn" id="ss-web-fullscreen" title="窗口全屏">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg>
          <span>窗口全屏</span>
        </button>
        <button class="ss-ctrl-btn" id="ss-real-fullscreen" title="屏幕全屏">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" y1="3" x2="14" y2="10"/><line x1="3" y1="21" x2="10" y2="14"/></svg>
          <span>屏幕全屏</span>
        </button>
      </div>`;
    panel.insertBefore(view, panel.firstChild);

    // Web fullscreen: fill the center area
    view.querySelector('#ss-web-fullscreen')!.addEventListener('click', () => {
      view!.classList.toggle('web-fullscreen');
      const btn = view!.querySelector('#ss-web-fullscreen span')!;
      btn.textContent = view!.classList.contains('web-fullscreen') ? '退出窗口全屏' : '窗口全屏';
    });

    // Real fullscreen: browser fullscreen API
    view.querySelector('#ss-real-fullscreen')!.addEventListener('click', () => {
      const video = view!.querySelector('video')!;
      if (document.fullscreenElement) {
        document.exitFullscreen();
      } else {
        video.requestFullscreen().catch(() => {});
      }
    });
  }

  const video = view.querySelector('video')!;
  video.srcObject = new MediaStream([consumer.track]);
  video.play().catch(() => {});

  const peer = peerMap.get(peerId);
  const label = view.querySelector('.screen-share-label')!;
  label.textContent = `${peer?.identity ?? '用户'} 正在共享屏幕`;

  const panel2 = document.querySelector('.voice-panel');
  panel2?.classList.add('has-screen');
  requestAnimationFrame(() => view!.classList.add('active'));
}

function hideScreenShareView(_producerId: string) {
  const view = document.getElementById('screen-share-container');
  if (view) {
    if (view.classList.contains('web-fullscreen')) view.classList.remove('web-fullscreen');
    view.classList.remove('active');
    setTimeout(() => {
      view.remove();
      document.querySelector('.voice-panel')?.classList.remove('has-screen');
    }, 300);
  }
}

// ─── Screen share settings & produce ─────────────────────────────────────────

interface ScreenShareSettings {
  sourceId: string;
  resolution: '720p' | '1080p';
  fps: 30 | 60;
  codec: 'h264' | 'vp8' | 'vp9';
}

async function toggleScreenShare() {
  if (!sendTransport) return;

  if (screenSharing && screenProducer) {
    screenProducer.close();
    emit('closeProducer', { producerId: screenProducer.id }).catch(() => {});
    screenProducer = null;
    screenSharing = false;
    updateScreenBtn();
    return;
  }

  if (!isElectron) return;

  try {
    const sources = await electronAPI!.getScreenSources();
    const settings = await showScreenShareDialog(sources);
    if (!settings) return;

    const resMap = { '720p': { w: 1280, h: 720 }, '1080p': { w: 1920, h: 1080 } };
    const res = resMap[settings.resolution];

    const stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        mandatory: {
          chromeMediaSource: 'desktop',
          chromeMediaSourceId: settings.sourceId,
          maxWidth: res.w,
          maxHeight: res.h,
          maxFrameRate: settings.fps,
        },
      } as any,
    });

    // Find the preferred codec
    const codecMime: Record<string, string> = {
      h264: 'video/h264',
      vp8: 'video/vp8',
      vp9: 'video/vp9',
    };
    const preferredCodec = device.rtpCapabilities.codecs?.find(
      (c) => c.mimeType.toLowerCase() === codecMime[settings.codec]
    );

    // Bitrate based on resolution and fps
    const baseBitrate = settings.resolution === '1080p' ? 4000000 : 2500000;
    const bitrate = settings.fps === 60 ? baseBitrate * 1.5 : baseBitrate;

    screenProducer = await sendTransport.produce({
      track: stream.getVideoTracks()[0],
      appData: { source: 'screen' },
      ...(preferredCodec ? { codec: preferredCodec } : {}),
      encodings: [{ maxBitrate: bitrate }],
      codecOptions: { videoGoogleStartBitrate: 1000 },
    });

    stream.getVideoTracks()[0].onended = () => {
      if (screenProducer) {
        screenProducer.close();
        emit('closeProducer', { producerId: screenProducer.id }).catch(() => {});
        screenProducer = null;
        screenSharing = false;
        updateScreenBtn();
      }
    };

    screenSharing = true;
    updateScreenBtn();
  } catch (err) {
    console.error('[screen] share failed:', err);
  }
}

function showScreenShareDialog(sources: { id: string; name: string; thumbnail: string }[]): Promise<ScreenShareSettings | null> {
  return new Promise((resolve) => {
    const overlay = $('screen-picker-overlay');
    const grid = $('screen-picker-grid');

    // Build source grid
    let html = sources.map((s) =>
      `<div class="screen-source" data-id="${esc(s.id)}"><img src="${s.thumbnail}" alt=""><div class="screen-source-name">${esc(s.name)}</div></div>`
    ).join('');

    grid.innerHTML = html;

    // Show settings panel
    const settingsEl = document.getElementById('screen-share-settings')!;
    settingsEl.style.display = 'flex';

    let selectedSourceId: string | null = null;

    const cleanup = () => {
      overlay.classList.remove('open');
      grid.innerHTML = '';
      settingsEl.style.display = 'none';
      // Remove highlight
      grid.querySelectorAll('.screen-source.selected').forEach((el) => el.classList.remove('selected'));
    };

    // Source selection (click to select, not to immediately start)
    const onGridClick = (e: Event) => {
      const source = (e.target as HTMLElement).closest('.screen-source') as HTMLElement | null;
      if (source) {
        grid.querySelectorAll('.screen-source.selected').forEach((el) => el.classList.remove('selected'));
        source.classList.add('selected');
        selectedSourceId = source.dataset.id!;
        // Enable start button
        const startBtn = document.getElementById('ss-start-btn') as HTMLButtonElement;
        startBtn.disabled = false;
        startBtn.classList.add('ready');
      }
    };
    grid.addEventListener('click', onGridClick);

    // Start button
    const startBtn = document.getElementById('ss-start-btn') as HTMLButtonElement;
    startBtn.disabled = true;
    startBtn.classList.remove('ready');

    const onStart = () => {
      if (!selectedSourceId) return;
      const resolution = (document.getElementById('ss-resolution') as HTMLSelectElement).value as '720p' | '1080p';
      const fps = parseInt((document.getElementById('ss-fps') as HTMLSelectElement).value) as 30 | 60;
      const codec = (document.getElementById('ss-codec') as HTMLSelectElement).value as 'h264' | 'vp8' | 'vp9';
      cleanup();
      grid.removeEventListener('click', onGridClick);
      startBtn.removeEventListener('click', onStart);
      cancelBtn.removeEventListener('click', onCancel);
      resolve({ sourceId: selectedSourceId!, resolution, fps, codec });
    };
    startBtn.addEventListener('click', onStart);

    const cancelBtn = document.getElementById('screen-picker-cancel')!;
    const onCancel = () => {
      cleanup();
      grid.removeEventListener('click', onGridClick);
      startBtn.removeEventListener('click', onStart);
      cancelBtn.removeEventListener('click', onCancel);
      resolve(null);
    };
    cancelBtn.addEventListener('click', onCancel);

    overlay.classList.add('open');
  });
}

function updateScreenBtn() {
  const btn = $('screen-btn');
  if (!btn) return;
  if (screenSharing) {
    btn.classList.add('sharing');
    btn.title = '停止共享';
  } else {
    btn.classList.remove('sharing');
    btn.title = '共享屏幕';
  }
}

// ─── Mic with noise suppression ──────────────────────────────────────────────

// RNNoise-based deep learning noise suppression (Electron only)
async function createRNNoiseStream(rawStream: MediaStream): Promise<{ stream: MediaStream; cleanup: () => void }> {
  const { Rnnoise } = await import('@shiguredo/rnnoise-wasm');
  const rnnoise = await Rnnoise.load();
  const state = rnnoise.createDenoiseState();
  const FRAME_SIZE = rnnoise.frameSize; // 480 samples = 10ms @ 48kHz

  const audioCtx = new AudioContext({ sampleRate: 48000 });
  const source = audioCtx.createMediaStreamSource(rawStream);
  const dest = audioCtx.createMediaStreamDestination();

  // ScriptProcessorNode for frame-by-frame RNNoise processing
  const processor = audioCtx.createScriptProcessor(1024, 1, 1);

  // Ring buffers for frame size mismatch (ScriptProcessor=1024, RNNoise=480)
  const inBuf = new Float32Array(FRAME_SIZE);
  let inPos = 0;
  const outRing = new Float32Array(4096); // must be power of 2 for bitmask
  let outW = 0;
  let outR = 0;
  let vadSmooth = 0;

  processor.onaudioprocess = (e: AudioProcessingEvent) => {
    const inData = e.inputBuffer.getChannelData(0);
    const outData = e.outputBuffer.getChannelData(0);

    // Feed input samples and process complete 480-sample frames
    for (let i = 0; i < inData.length; i++) {
      inBuf[inPos++] = inData[i] * 32768; // float32 → 16-bit PCM range
      if (inPos >= FRAME_SIZE) {
        const vad = state.processFrame(inBuf); // in-place denoise, returns VAD 0-1
        vadSmooth = vadSmooth * 0.7 + vad * 0.3;
        // VAD-based soft gate: suppress when no voice detected
        const gain = vadSmooth > 0.15 ? 1 : vadSmooth / 0.15;
        for (let j = 0; j < FRAME_SIZE; j++) {
          outRing[(outW + j) & (outRing.length - 1)] = (inBuf[j] / 32768) * gain;
        }
        outW += FRAME_SIZE;
        inPos = 0;
      }
    }

    // Read processed samples to output
    for (let i = 0; i < outData.length; i++) {
      if (outR < outW) {
        outData[i] = outRing[outR & (outRing.length - 1)];
        outR++;
      } else {
        outData[i] = 0;
      }
    }
  };

  source.connect(processor);
  processor.connect(dest);

  return {
    stream: dest.stream,
    cleanup: () => {
      source.disconnect();
      processor.disconnect();
      state.destroy();
      audioCtx.close();
    },
  };
}

async function createNoiseSuppressedStream(rawStream: MediaStream): Promise<{ stream: MediaStream; cleanup: () => void }> {
  // Electron: use RNNoise deep learning noise suppression
  if (isElectron) {
    try {
      return await createRNNoiseStream(rawStream);
    } catch (e) {
      console.warn('[rnnoise] failed to load, falling back to basic chain:', e);
    }
  }

  // Web: basic Web Audio API chain (unchanged)
  try {
    const audioCtx = new AudioContext({ sampleRate: 48000 });
    const source = audioCtx.createMediaStreamSource(rawStream);

    const highpass = audioCtx.createBiquadFilter();
    highpass.type = 'highpass';
    highpass.frequency.value = 80;
    highpass.Q.value = 0.7;

    const lowpass = audioCtx.createBiquadFilter();
    lowpass.type = 'lowpass';
    lowpass.frequency.value = 18000;
    lowpass.Q.value = 0.7;

    const compressor = audioCtx.createDynamicsCompressor();
    compressor.threshold.value = -30;
    compressor.knee.value = 20;
    compressor.ratio.value = 4;
    compressor.attack.value = 0.003;
    compressor.release.value = 0.15;

    const gate = audioCtx.createGain();
    gate.gain.value = 1;

    const dest = audioCtx.createMediaStreamDestination();
    source.connect(highpass).connect(lowpass).connect(compressor).connect(gate).connect(dest);

    const analyser = audioCtx.createAnalyser();
    analyser.fftSize = 256;
    source.connect(analyser);
    const dataArr = new Float32Array(analyser.fftSize);

    let gateOpen = true;
    const gateInterval = setInterval(() => {
      analyser.getFloatTimeDomainData(dataArr);
      let rms = 0;
      for (let i = 0; i < dataArr.length; i++) rms += dataArr[i] * dataArr[i];
      rms = Math.sqrt(rms / dataArr.length);
      const dbFS = 20 * Math.log10(Math.max(rms, 1e-10));
      const shouldOpen = dbFS > -55;
      if (shouldOpen !== gateOpen) {
        gateOpen = shouldOpen;
        gate.gain.linearRampToValueAtTime(shouldOpen ? 1 : 0, audioCtx.currentTime + 0.02);
      }
    }, 20);

    return {
      stream: dest.stream,
      cleanup: () => {
        clearInterval(gateInterval);
        source.disconnect();
        highpass.disconnect();
        lowpass.disconnect();
        compressor.disconnect();
        gate.disconnect();
        analyser.disconnect();
        audioCtx.close();
      },
    };
  } catch {
    return { stream: rawStream, cleanup: () => {} };
  }
}

async function toggleMic() {
  if (!sendTransport) return;
  if (micEnabled && micProducer) {
    micProducer.close();
    emit('closeProducer', { producerId: micProducer.id }).catch(() => {});
    micProducer = null; micEnabled = false;
    if (micNsCleanup) { micNsCleanup(); micNsCleanup = null; }
    updateMicBtn(); queueRenderMembers();
    return;
  }
  const audioConstraints: MediaTrackConstraints = {
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
  };
  if (selectedInputDeviceId) audioConstraints.deviceId = { exact: selectedInputDeviceId };
  const rawStream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints, video: false });
  let finalStream: MediaStream;
  if (nsEnabled) {
    const { stream: cleanStream, cleanup } = await createNoiseSuppressedStream(rawStream);
    micNsCleanup = cleanup;
    finalStream = cleanStream;
  } else {
    finalStream = rawStream;
  }
  micProducer = await sendTransport.produce({
    track: finalStream.getAudioTracks()[0],
    codecOptions: {
      opusStereo: false,
      opusDtx: true,
      opusFec: true,
      opusMaxAverageBitrate: 64000,
      opusMaxPlaybackRate: 48000,
      opusPtime: 20,
    },
    appData: { source: 'mic' },
  });
  micEnabled = true;
  updateMicBtn(); queueRenderMembers();
}

function updateMicBtn() {
  const btn = $('mic-btn');
  if (!btn) return;
  if (micEnabled) {
    btn.innerHTML = svgMicOff + '<span class="dock-btn-label">静音</span>';
    btn.className = 'dock-btn mic-off'; btn.title = '静音';
  } else {
    btn.innerHTML = svgMic + '<span class="dock-btn-label">开麦</span>';
    btn.className = 'dock-btn mic-on'; btn.title = '开麦';
  }
}

// ─── Audio device selection ───────────────────────────────────────────────────

async function populateAudioDevices() {
  // Request mic permission first so device labels are available
  try {
    const tempStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    tempStream.getTracks().forEach((t) => t.stop());
  } catch { /* user denied — labels will be empty but IDs still work */ }

  const devices = await navigator.mediaDevices.enumerateDevices();
  const inputSelect = $('audio-input-select') as HTMLSelectElement;
  const outputSelect = $('audio-output-select') as HTMLSelectElement;

  inputSelect.innerHTML = '';
  outputSelect.innerHTML = '';

  const inputs = devices.filter((d) => d.kind === 'audioinput');
  const outputs = devices.filter((d) => d.kind === 'audiooutput');

  inputs.forEach((d, i) => {
    const opt = document.createElement('option');
    opt.value = d.deviceId;
    opt.textContent = d.label || `麦克风 ${i + 1}`;
    if (d.deviceId === selectedInputDeviceId || (!selectedInputDeviceId && d.deviceId === 'default')) opt.selected = true;
    inputSelect.appendChild(opt);
  });

  outputs.forEach((d, i) => {
    const opt = document.createElement('option');
    opt.value = d.deviceId;
    opt.textContent = d.label || `扬声器 ${i + 1}`;
    if (d.deviceId === selectedOutputDeviceId || (!selectedOutputDeviceId && d.deviceId === 'default')) opt.selected = true;
    outputSelect.appendChild(opt);
  });

  // Sync noise suppression toggle
  ($('ns-toggle') as HTMLInputElement).checked = nsEnabled;
}

function toggleAudioPopup() {
  const popup = $('audio-popup');
  const btn = $('audio-settings-btn');
  if (popup.classList.contains('open')) {
    popup.classList.remove('open');
    return;
  }
  populateAudioDevices().then(() => {
    const rect = btn.getBoundingClientRect();
    popup.style.left = `${rect.left}px`;
    popup.style.bottom = `${window.innerHeight - rect.top + 8}px`;
    popup.classList.add('open');
  });
}

function onInputDeviceChange(e: Event) {
  const sel = e.target as HTMLSelectElement;
  selectedInputDeviceId = sel.value;
  LS.set('audioInput', selectedInputDeviceId);
  // If mic is active, restart it with new device
  if (micEnabled && micProducer) {
    toggleMic().then(() => toggleMic());
  }
}

function onOutputDeviceChange(e: Event) {
  const sel = e.target as HTMLSelectElement;
  selectedOutputDeviceId = sel.value;
  LS.set('audioOutput', selectedOutputDeviceId);
  // Apply to all existing audio elements
  document.querySelectorAll<HTMLAudioElement>('audio[data-peer-id]').forEach((a) => {
    if (typeof (a as any).setSinkId === 'function') {
      (a as any).setSinkId(selectedOutputDeviceId).catch(() => {});
    }
  });
}

function onNsToggle(e: Event) {
  nsEnabled = (e.target as HTMLInputElement).checked;
  LS.set('noiseSuppression', nsEnabled ? 'on' : 'off');
  // Re-toggle mic to apply change if currently active
  if (micEnabled && micProducer) {
    toggleMic().then(() => toggleMic());
  }
}

// Close audio popup on outside click
document.addEventListener('click', (e) => {
  const popup = $('audio-popup');
  const btn = $('audio-settings-btn');
  if (popup.classList.contains('open') && !popup.contains(e.target as Node) && !btn.contains(e.target as Node)) {
    popup.classList.remove('open');
  }
});

// ─── Download popup ──────────────────────────────────────────────────────────

const dlPlatforms = [
  { key: 'windows', name: 'Windows', icon: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M0 3.449L9.75 2.1v9.451H0m10.949-9.602L24 0v11.4H10.949M0 12.6h9.75v9.451L0 20.699M10.949 12.6H24V24l-13.051-1.851"/></svg>' },
  { key: 'macos', name: 'macOS', icon: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>' },
  { key: 'linux', name: 'Linux', icon: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M12.504 0c-.155 0-.315.008-.48.021-4.226.333-3.105 4.807-3.17 6.298-.076 1.092-.3 1.953-1.05 3.02-.885 1.051-2.127 2.75-2.716 4.521-.278.832-.41 1.684-.287 2.489a.424.424 0 00-.11.135c-.26.268-.45.6-.663.839-.199.199-.485.267-.797.4-.313.136-.658.269-.864.68-.09.189-.136.394-.132.602 0 .199.027.4.055.536.058.399.116.728.04.97-.249.68-.28 1.145-.106 1.484.174.334.535.47.94.601.81.2 1.91.135 2.774.6.926.466 1.866.67 2.616.47.526-.116.97-.464 1.208-.946.587-.003 1.23-.269 2.26-.334.699-.058 1.574.267 2.577.2.025.134.063.198.114.333l.003.003c.391.778 1.113 1.312 1.975 1.312.868 0 1.593-.533 1.987-1.314.144-.3.244-.63.296-.978.013-.044.025-.088.032-.135.086-.156.173-.313.236-.475.137-.359.199-.725.164-1.065-.035-.34-.143-.654-.348-.933-.059-.084-.135-.162-.217-.233-.152-.134-.32-.247-.497-.34l-.002-.003c-.034-.025-.076-.049-.118-.074-.168-.083-.333-.14-.498-.17-.103-.018-.184-.028-.274-.03a1.365 1.365 0 00-.487.063c-.035.012-.071.025-.107.04-.12.035-.244.095-.368.163-.345.183-.682.432-.99.728-.326.307-.558.466-.753.541-.192.078-.354.082-.595.063a1.865 1.865 0 00-.13-.013l-.003-.003C17.706 19.032 17.088 18.042 16.692 17c-.127-.332-.347-.656-.624-.888a.976.976 0 00-.108-.075 2.942 2.942 0 00-.206-.105c.027-.184.049-.37.049-.555 0-2.058-1.133-3.88-2.821-4.838-.07-.04-.143-.073-.215-.107V8.168c.522-1.365.563-2.863.07-4.316-.387-1.133-1.11-2.04-2.038-2.68A5.454 5.454 0 0012.504 0z"/></svg>' },
  { key: 'android', name: 'Android', icon: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M17.523 15.341c-.583 0-1.055.472-1.055 1.055 0 .583.472 1.055 1.055 1.055.583 0 1.055-.472 1.055-1.055 0-.583-.472-1.055-1.055-1.055zm-11.046 0c-.583 0-1.055.472-1.055 1.055 0 .583.472 1.055 1.055 1.055.583 0 1.055-.472 1.055-1.055 0-.583-.472-1.055-1.055-1.055zm11.4-6.026l1.972-3.416a.41.41 0 00-.71-.41l-1.997 3.46A12.175 12.175 0 0012 7.739c-1.851 0-3.588.423-5.142 1.21L4.861 5.49a.41.41 0 00-.71.41l1.972 3.416C2.93 11.14.574 14.506.574 18.397h22.852c0-3.891-2.356-7.257-5.549-9.082z"/></svg>' },
  { key: 'ios', name: 'iOS', icon: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>' },
];

let downloadLinks: Record<string, string> = {};

async function fetchDownloadLinks() {
  const res = await apiGet('/api/downloads').catch(() => null);
  if (res?.ok) downloadLinks = await res.json();
}

function renderDownloadList() {
  const list = $('dl-list');
  const isAdmin = role === 'admin';
  const hasAny = dlPlatforms.some((p) => downloadLinks[p.key]);

  if (!hasAny && !isAdmin) {
    list.innerHTML = '<div class="dl-empty">暂无可用下载</div>';
    return;
  }

  list.innerHTML = dlPlatforms.map((p) => {
    const url = downloadLinks[p.key] || '';
    if (!url && !isAdmin) return '';
    let content = '';
    if (isAdmin) {
      content = `<div class="dl-admin-row">
        <input type="text" value="${esc(url)}" placeholder="输入下载链接..." data-platform="${p.key}">
        <button data-platform="${p.key}">保存</button>
      </div>`;
    } else {
      content = `<a href="${esc(url)}" target="_blank" rel="noopener">下载</a>`;
    }
    return `<div class="dl-item">
      <div class="dl-item-icon">${p.icon}</div>
      <div class="dl-item-info">
        <div class="dl-item-name">${p.name}</div>
        ${content}
      </div>
    </div>`;
  }).join('');

  if (isAdmin) {
    list.querySelectorAll('.dl-admin-row button').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const platform = (btn as HTMLElement).dataset.platform!;
        const input = list.querySelector(`input[data-platform="${platform}"]`) as HTMLInputElement;
        const url = input.value.trim();
        await apiPut('/api/downloads', { [platform]: url });
        downloadLinks[platform] = url;
      });
    });
  }
}

function toggleDownloadPopup() {
  const popup = $('dl-popup');
  const btn = $('download-btn');
  if (popup.classList.contains('open')) {
    popup.classList.remove('open');
    return;
  }
  fetchDownloadLinks().then(() => {
    renderDownloadList();
    const rect = btn.getBoundingClientRect();
    popup.style.left = `${rect.left}px`;
    popup.style.bottom = `${window.innerHeight - rect.top + 8}px`;
    popup.classList.add('open');
  });
}

// Close download popup on outside click
document.addEventListener('click', (e) => {
  const popup = $('dl-popup');
  const btn = $('download-btn');
  if (popup.classList.contains('open') && !popup.contains(e.target as Node) && !btn.contains(e.target as Node)) {
    popup.classList.remove('open');
  }
});

// ─── Volume popup ─────────────────────────────────────────────────────────────

let volPopupTarget: string | null = null;

function showVolPopup(targetId: string, name: string, rect: DOMRect) {
  const popup = $('vol-popup');
  const slider = $('vol-slider') as HTMLInputElement;
  volPopupTarget = targetId;
  $('vol-popup-name').textContent = name;

  if (targetId === 'self') {
    slider.value = '100';
    $('vol-label').textContent = micEnabled ? '麦克风已开启' : '麦克风已关闭';
  } else {
    const vol = Math.round((peerVolumes.get(targetId) ?? 1) * 100);
    slider.value = String(vol);
    $('vol-label').textContent = `${vol}%`;
  }

  popup.classList.add('open');
  const px = rect.left + rect.width / 2 - 90;
  const py = rect.top - 100;
  popup.style.left = Math.max(8, px) + 'px';
  popup.style.top = Math.max(8, py) + 'px';
}

function hideVolPopup() {
  $('vol-popup').classList.remove('open');
  volPopupTarget = null;
}

$('vol-slider').addEventListener('input', () => {
  const slider = $('vol-slider') as HTMLInputElement;
  const val = parseInt(slider.value);
  $('vol-label').textContent = `${val}%`;
  if (volPopupTarget && volPopupTarget !== 'self') {
    peerVolumes.set(volPopupTarget, val / 100);
    document.querySelectorAll<HTMLAudioElement>(`audio[data-peer-id="${volPopupTarget}"]`).forEach((a) => { a.volume = val / 100; });
  }
});

document.addEventListener('click', (e) => {
  const popup = $('vol-popup');
  if (popup.classList.contains('open') && !popup.contains(e.target as Node)) {
    if (!(e.target as HTMLElement).closest('.member-card')) hideVolPopup();
  }
});

// ─── UI rendering ─────────────────────────────────────────────────────────────

function updateVoiceStatus() {
  const bar = $('voice-status-bar');
  if (currentChannelId && currentChannelName) {
    bar.classList.add('active');
    $('voice-status-channel').textContent = currentChannelName;
  } else bar.classList.remove('active');
}

function showEmptyState() {
  $('main-content').innerHTML = `<div class="empty-panel"><div class="empty-icon"><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/></svg></div><p>双击左侧频道<br>开始语音聊天</p></div>`;
}

function renderVoicePanel() {
  $('main-content').innerHTML = `<div class="voice-panel"><div class="member-grid" id="member-grid"></div></div>`;
  $('dock').classList.add('active');
  updateMicBtn();
}

function renderMembers() {
  const grid = document.getElementById('member-grid');
  if (!grid) return;

  const selfAv = myAvatar
    ? `<img src="${myAvatar}" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`
    : esc(identity[0].toUpperCase());
  let html = `<div class="member-card" data-peer="self" style="animation-delay:0ms"><div class="member-avatar ${micEnabled ? 'speaking' : ''}">${selfAv}</div><div class="member-name">${esc(identity)}</div><div class="member-tag">(你)</div></div>`;

  let idx = 1;
  for (const [peerId, p] of peerMap) {
    const hasAudio = [...p.producers.values()].some(pr => pr.kind === 'audio');
    const peerAv = avatarCache.get(p.identity);
    const avContent = peerAv
      ? `<img src="${peerAv}" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`
      : esc(p.identity[0].toUpperCase());
    html += `<div class="member-card" data-peer="${esc(peerId)}" style="animation-delay:${idx * 50}ms"><div class="member-avatar ${hasAudio ? 'speaking' : ''}">${avContent}</div><div class="member-name">${esc(p.identity)}</div></div>`;
    if (!avatarCache.has(p.identity)) fetchAvatar(p.identity).then(() => queueRenderMembers());
    idx++;
  }
  grid.innerHTML = html;

  grid.querySelectorAll('.member-card').forEach((card) => {
    card.addEventListener('click', () => {
      const peerId = (card as HTMLElement).dataset.peer!;
      const avatar = card.querySelector('.member-avatar')!;
      const rect = avatar.getBoundingClientRect();
      if (peerId === 'self') {
        showVolPopup('self', identity, rect);
      } else {
        const peer = peerMap.get(peerId);
        if (peer) showVolPopup(peerId, peer.identity, rect);
      }
    });
  });
}

// ─── Socket.IO wrapper ───────────────────────────────────────────────────────

function emit<T = any>(ev: string, data: unknown): Promise<T> {
  return new Promise((resolve, reject) => {
    socket.emit(ev, data, (res: T | { error: string }) => {
      if (res && typeof res === 'object' && 'error' in res) reject(new Error((res as { error: string }).error));
      else resolve(res as T);
    });
  });
}

function esc(s: string) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }

// ─── Bootstrap ────────────────────────────────────────────────────────────────

$('login-btn').addEventListener('click', login);
$('login-password').addEventListener('keydown', (e) => { if ((e as KeyboardEvent).key === 'Enter') login(); });
$('login-username').addEventListener('keydown', (e) => { if ((e as KeyboardEvent).key === 'Enter') login(); });
$('logout-btn').addEventListener('click', logout);
$('user-avatar').addEventListener('click', pickAvatar);

$('voice-disconnect-btn').addEventListener('click', async () => { await leaveCurrentChannel(); renderChannels(); showEmptyState(); });
$('mic-btn').addEventListener('click', toggleMic);
$('screen-btn').addEventListener('click', toggleScreenShare);
$('audio-settings-btn').addEventListener('click', toggleAudioPopup);
$('download-btn').addEventListener('click', toggleDownloadPopup);
$('audio-input-select').addEventListener('change', onInputDeviceChange);
$('audio-output-select').addEventListener('change', onOutputDeviceChange);
$('ns-toggle').addEventListener('change', onNsToggle);
$('leave-btn').addEventListener('click', async () => { await leaveCurrentChannel(); renderChannels(); showEmptyState(); });

$('add-channel-btn').addEventListener('click', () => $('add-channel-modal').classList.add('open'));
$('cancel-add-channel').addEventListener('click', () => $('add-channel-modal').classList.remove('open'));
$('confirm-add-channel').addEventListener('click', async () => {
  const name = ($('new-channel-name') as HTMLInputElement).value.trim();
  if (!name) return;
  await createChannel(name);
  ($('new-channel-name') as HTMLInputElement).value = '';
  $('add-channel-modal').classList.remove('open');
});

(async () => {
  if (session && identity) {
    const res = await apiGet('/api/me').catch(() => null);
    if (res?.ok) {
      const data = await res.json();
      role = data.role; LS.set('role', role);
      if (data.avatar) { myAvatar = data.avatar; LS.set('avatar', myAvatar); avatarCache.set(identity, myAvatar); }
      showApp();
      await initSignaling();
      await loadChannels();
      return;
    }
    ['session', 'identity', 'role'].forEach((k) => LS.del(k));
    session = identity = role = '';
  }
})();
