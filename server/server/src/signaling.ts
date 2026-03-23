/**
 * Socket.IO signaling layer.
 */

import { Server, Socket } from 'socket.io';
import type { Server as HttpServer } from 'http';
import { getSession, SessionData, getChannelPassword } from './db.js';
import { getOrCreateRoom, deleteRoomIfEmpty } from './mediasoup/room.js';
import * as mediasoup from 'mediasoup';
type RtpCapabilities = mediasoup.types.RtpCapabilities;
type DtlsParameters = mediasoup.types.DtlsParameters;
type RtpParameters = mediasoup.types.RtpParameters;
type MediaKind = mediasoup.types.MediaKind;

interface PeerState {
  session: SessionData;
  channelId?: string;
}

const peers = new Map<string, PeerState>();  // socketId → state

function requireAuth(socket: Socket): PeerState | null {
  const state = peers.get(socket.id);
  if (!state) {
    socket.emit('error', { message: 'not authenticated' });
    return null;
  }
  return state;
}

function requireChannel(socket: Socket, state: PeerState): string | null {
  if (!state.channelId) {
    socket.emit('error', { message: 'not in a channel' });
    return null;
  }
  return state.channelId;
}

let ioInstance: Server | null = null;

/** Broadcast an event to all connected sockets */
export function broadcastAll(event: string, data: unknown): void {
  ioInstance?.emit(event, data);
}

/** Broadcast channel membership update to all authenticated sockets */
function broadcastChannelMembers(channelId: string): void {
  if (!ioInstance) return;
  const members = getChannelMemberList(channelId);
  ioInstance.emit('channelMembersUpdated', { channelId, members });
}

function getChannelMemberList(channelId: string): { id: string; identity: string }[] {
  const result: { id: string; identity: string }[] = [];
  for (const [socketId, state] of peers) {
    if (state.channelId === channelId) {
      result.push({ id: socketId, identity: state.session.identity });
    }
  }
  return result;
}

/** Get deduplicated online user list (same identity may have multiple sockets) */
function getOnlineUserList(): { identity: string }[] {
  const seen = new Set<string>();
  const result: { identity: string }[] = [];
  for (const state of peers.values()) {
    if (!seen.has(state.session.identity)) {
      seen.add(state.session.identity);
      result.push({ identity: state.session.identity });
    }
  }
  return result;
}

function broadcastOnlineUsers(): void {
  if (!ioInstance) return;
  ioInstance.emit('onlineUsersUpdated', { users: getOnlineUserList() });
}

export function setupSignaling(httpServer: HttpServer): Server {
  const io = new Server(httpServer, {
    cors: { origin: '*', methods: ['GET', 'POST'] },
    transports: ['websocket', 'polling'],
  });
  ioInstance = io;

  io.on('connection', (socket: Socket) => {
    console.log(`[signaling] connected ${socket.id}`);

    // ── authenticate ──────────────────────────────────────────────────────────
    socket.on('authenticate', async ({ token }: { token: string }, cb?: Function) => {
      try {
        const session = await getSession(token);
        if (!session) {
          socket.emit('error', { message: 'invalid session' });
          cb?.({ error: 'invalid session' });
          return;
        }
        peers.set(socket.id, { session });
        socket.emit('authenticated', { identity: session.identity, role: session.role });

        // Send initial data: channel members + online users
        const channelMap: Record<string, { id: string; identity: string }[]> = {};
        for (const [socketId, peerState] of peers) {
          if (peerState.channelId) {
            if (!channelMap[peerState.channelId]) channelMap[peerState.channelId] = [];
            channelMap[peerState.channelId].push({
              id: socketId,
              identity: peerState.session.identity,
            });
          }
        }
        socket.emit('initialState', {
          channelMembers: channelMap,
          onlineUsers: getOnlineUserList(),
        });

        cb?.({ identity: session.identity, role: session.role });
        console.log(`[signaling] authenticated ${session.identity} (${socket.id})`);

        // Broadcast updated online users to everyone
        broadcastOnlineUsers();
      } catch (err) {
        socket.emit('error', { message: 'authentication error' });
      }
    });

    // ── getChannelMembers (kept for compatibility) ────────────────────────────
    socket.on('getChannelMembers', (_: unknown, cb?: Function) => {
      const state = requireAuth(socket);
      if (!state) return;
      const channelMap: Record<string, { id: string; identity: string }[]> = {};
      for (const [socketId, peerState] of peers) {
        if (peerState.channelId) {
          if (!channelMap[peerState.channelId]) channelMap[peerState.channelId] = [];
          channelMap[peerState.channelId].push({
            id: socketId,
            identity: peerState.session.identity,
          });
        }
      }
      cb?.({ channels: channelMap });
    });

    // ── joinChannel ───────────────────────────────────────────────────────────
    socket.on('joinChannel', async ({ channelId, password }: { channelId: string; password?: string }, cb?: Function) => {
      const state = requireAuth(socket);
      if (!state) return;

      // Verify channel password (admin bypasses)
      if (state.session.role !== 'admin') {
        try {
          const channelPw = await getChannelPassword(channelId);
          if (channelPw && channelPw !== (password ?? '')) {
            cb?.({ error: 'wrong_password' });
            return;
          }
        } catch (e) {
          console.error('[signaling] password check failed:', e);
          // Allow join if password check fails (column may not exist yet)
        }
      }

      const prevChannel = state.channelId;
      if (prevChannel) {
        await leaveChannel(socket, state);
      }

      const room = await getOrCreateRoom(channelId);
      room.addPeer(socket.id, state.session.identity);
      state.channelId = channelId;

      const existingPeers = room.getPeers()
        .filter((p) => p.id !== socket.id)
        .map((p) => ({
          id: p.id,
          identity: p.identity,
          producers: [...p.producers.values()].map((pr) => ({ id: pr.id, kind: pr.kind, appData: pr.appData })),
        }));

      socket.join(`channel:${channelId}`);
      socket.emit('joinedChannel', { channelId, peers: existingPeers });
      cb?.({ channelId, peers: existingPeers });

      socket.to(`channel:${channelId}`).emit('peerJoined', {
        id: socket.id,
        identity: state.session.identity,
      });

      broadcastChannelMembers(channelId);
      if (prevChannel) broadcastChannelMembers(prevChannel);

      console.log(`[signaling] ${state.session.identity} joined channel=${channelId}`);
    });

    // ── leaveChannel ──────────────────────────────────────────────────────────
    socket.on('leaveChannel', async (_: unknown, cb?: Function) => {
      const state = requireAuth(socket);
      if (!state) return;
      if (!state.channelId) { cb?.({}); return; }
      const channelId = state.channelId;
      await leaveChannel(socket, state);
      broadcastChannelMembers(channelId);
      cb?.({});
    });

    // ── getRtpCapabilities ────────────────────────────────────────────────────
    socket.on('getRtpCapabilities', async (_: unknown, cb?: Function) => {
      const state = requireAuth(socket);
      if (!state) return;
      const channelId = requireChannel(socket, state);
      if (!channelId) return;
      const room = await getOrCreateRoom(channelId);
      cb?.({ routerRtpCapabilities: room.rtpCapabilities });
    });

    // ── createTransport ───────────────────────────────────────────────────────
    socket.on('createTransport', async ({ direction }: { direction: 'send' | 'recv' }, cb?: Function) => {
      const state = requireAuth(socket);
      if (!state) return;
      const channelId = requireChannel(socket, state);
      if (!channelId) return;
      const room = await getOrCreateRoom(channelId);
      const transport = await room.createTransport(socket.id, direction);
      cb?.({
        id: transport.id,
        iceParameters: transport.iceParameters,
        iceCandidates: transport.iceCandidates,
        dtlsParameters: transport.dtlsParameters,
      });
    });

    // ── connectTransport ──────────────────────────────────────────────────────
    socket.on('connectTransport', async (
      { transportId, dtlsParameters }: { transportId: string; dtlsParameters: DtlsParameters },
      cb?: Function,
    ) => {
      const state = requireAuth(socket);
      if (!state) return;
      const channelId = requireChannel(socket, state);
      if (!channelId) return;
      const room = await getOrCreateRoom(channelId);
      await room.connectTransport(socket.id, transportId, dtlsParameters);
      cb?.({});
    });

    // ── produce ───────────────────────────────────────────────────────────────
    socket.on('produce', async (
      { transportId, kind, rtpParameters, appData }: {
        transportId: string; kind: MediaKind; rtpParameters: RtpParameters;
        appData?: Record<string, unknown>;
      },
      cb?: Function,
    ) => {
      const state = requireAuth(socket);
      if (!state) return;
      const channelId = requireChannel(socket, state);
      if (!channelId) return;
      const room = await getOrCreateRoom(channelId);
      const producer = await room.produce(socket.id, transportId, kind, rtpParameters, appData);

      socket.to(`channel:${channelId}`).emit('newProducer', {
        peerId: socket.id,
        producerId: producer.id,
        kind: producer.kind,
        appData: producer.appData,
      });
      cb?.({ producerId: producer.id });
    });

    // ── consume ───────────────────────────────────────────────────────────────
    socket.on('consume', async (
      { producerId, rtpCapabilities }: { producerId: string; rtpCapabilities: RtpCapabilities },
      cb?: Function,
    ) => {
      const state = requireAuth(socket);
      if (!state) return;
      const channelId = requireChannel(socket, state);
      if (!channelId) return;
      const room = await getOrCreateRoom(channelId);
      const consumer = await room.consume(socket.id, producerId, rtpCapabilities);
      cb?.({
        id: consumer.id,
        producerId,
        kind: consumer.kind,
        rtpParameters: consumer.rtpParameters,
      });
    });

    // ── closeProducer ─────────────────────────────────────────────────────────
    socket.on('closeProducer', async ({ producerId }: { producerId: string }, cb?: Function) => {
      const state = requireAuth(socket);
      if (!state) return;
      const channelId = requireChannel(socket, state);
      if (!channelId) return;
      const room = await getOrCreateRoom(channelId);
      room.closeProducer(socket.id, producerId);
      socket.to(`channel:${channelId}`).emit('producerClosed', {
        peerId: socket.id,
        producerId,
      });
      cb?.({});
    });

    // ── disconnect ────────────────────────────────────────────────────────────
    socket.on('disconnect', async () => {
      const state = peers.get(socket.id);
      if (state) {
        const channelId = state.channelId;
        if (channelId) {
          await leaveChannel(socket, state);
          broadcastChannelMembers(channelId);
        }
        peers.delete(socket.id);
        broadcastOnlineUsers();
      }
      console.log(`[signaling] disconnected ${socket.id}`);
    });
  });

  return io;
}

// ── helpers ──────────────────────────────────────────────────────────────────

async function leaveChannel(socket: Socket, state: PeerState): Promise<void> {
  const channelId = state.channelId;
  if (!channelId) return;

  const room = await getOrCreateRoom(channelId);
  const peer = room.removePeer(socket.id);

  if (peer) {
    socket.to(`channel:${channelId}`).emit('peerLeft', {
      id: socket.id,
      identity: state.session.identity,
    });
  }

  socket.leave(`channel:${channelId}`);
  state.channelId = undefined;

  deleteRoomIfEmpty(channelId);
  console.log(`[signaling] ${state.session.identity} left channel=${channelId}`);
}
