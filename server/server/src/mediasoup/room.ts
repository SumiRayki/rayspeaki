import * as mediasoup from 'mediasoup';
import { getWorker, mediaCodecs } from './worker.js';
import { config } from '../config.js';

type Router = mediasoup.types.Router;
type WebRtcTransport = mediasoup.types.WebRtcTransport;
type Producer = mediasoup.types.Producer;
type Consumer = mediasoup.types.Consumer;
type RtpCapabilities = mediasoup.types.RtpCapabilities;
type DtlsParameters = mediasoup.types.DtlsParameters;
type RtpParameters = mediasoup.types.RtpParameters;
type MediaKind = mediasoup.types.MediaKind;
type DtlsState = mediasoup.types.DtlsState;

// ---- types ----

export interface PeerInfo {
  id: string;           // socket.id
  identity: string;
  sendTransport?: WebRtcTransport;
  recvTransport?: WebRtcTransport;
  producers: Map<string, Producer>;   // producerId -> Producer
  consumers: Map<string, Consumer>;   // consumerId -> Consumer
}

// ---- Room ----

export class Room {
  readonly channelId: string;
  private router!: Router;
  private peers: Map<string, PeerInfo> = new Map();

  private constructor(channelId: string) {
    this.channelId = channelId;
  }

  static async create(channelId: string): Promise<Room> {
    const room = new Room(channelId);
    room.router = await getWorker().createRouter({ mediaCodecs });
    console.log(`[room] created channel=${channelId}`);
    return room;
  }

  get rtpCapabilities(): RtpCapabilities {
    return this.router.rtpCapabilities;
  }

  addPeer(id: string, identity: string): PeerInfo {
    const peer: PeerInfo = { id, identity, producers: new Map(), consumers: new Map() };
    this.peers.set(id, peer);
    return peer;
  }

  removePeer(id: string): PeerInfo | undefined {
    const peer = this.peers.get(id);
    if (!peer) return;
    peer.producers.forEach((p) => p.close());
    peer.consumers.forEach((c) => c.close());
    peer.sendTransport?.close();
    peer.recvTransport?.close();
    this.peers.delete(id);
    return peer;
  }

  getPeer(id: string): PeerInfo | undefined {
    return this.peers.get(id);
  }

  getPeers(): PeerInfo[] {
    return [...this.peers.values()];
  }

  get isEmpty(): boolean {
    return this.peers.size === 0;
  }

  // Creates a WebRTC transport (send or recv)
  async createTransport(peerId: string, direction: 'send' | 'recv'): Promise<WebRtcTransport> {
    const transport = await this.router.createWebRtcTransport({
      listenInfos: [
        {
          protocol: 'udp',
          ip: '0.0.0.0',
          announcedAddress: config.announcedIp,
        },
        {
          protocol: 'tcp',
          ip: '0.0.0.0',
          announcedAddress: config.announcedIp,
        },
      ],
      enableUdp: true,
      enableTcp: true,
      preferUdp: true,
      initialAvailableOutgoingBitrate: 600000,
    });

    transport.on('dtlsstatechange', (state: DtlsState) => {
      if (state === 'closed') transport.close();
    });

    const peer = this.peers.get(peerId);
    if (peer) {
      if (direction === 'send') peer.sendTransport = transport;
      else peer.recvTransport = transport;
    }

    return transport;
  }

  async connectTransport(peerId: string, transportId: string, dtlsParameters: DtlsParameters): Promise<void> {
    const peer = this.peers.get(peerId);
    if (!peer) throw new Error('peer not found');
    const transport = peer.sendTransport?.id === transportId
      ? peer.sendTransport
      : peer.recvTransport;
    if (!transport) throw new Error('transport not found');
    await transport.connect({ dtlsParameters });
  }

  async produce(peerId: string, transportId: string, kind: MediaKind, rtpParameters: RtpParameters, appData?: Record<string, unknown>): Promise<Producer> {
    const peer = this.peers.get(peerId);
    if (!peer) throw new Error('peer not found');
    const transport = peer.sendTransport;
    if (!transport || transport.id !== transportId) throw new Error('send transport not found');

    const producer = await transport.produce({ kind, rtpParameters, appData: appData ?? {} });
    peer.producers.set(producer.id, producer);

    producer.on('transportclose', () => {
      peer.producers.delete(producer.id);
    });

    return producer;
  }

  // Creates a consumer on peerId's recvTransport for a producer from another peer
  async consume(
    peerId: string,
    producerId: string,
    rtpCapabilities: RtpCapabilities,
  ): Promise<Consumer> {
    const peer = this.peers.get(peerId);
    if (!peer) throw new Error('peer not found');
    const transport = peer.recvTransport;
    if (!transport) throw new Error('recv transport not found');

    if (!this.router.canConsume({ producerId, rtpCapabilities })) {
      throw new Error('cannot consume');
    }

    const consumer = await transport.consume({
      producerId,
      rtpCapabilities,
      paused: false,
    });

    peer.consumers.set(consumer.id, consumer);

    consumer.on('transportclose', () => peer.consumers.delete(consumer.id));
    consumer.on('producerclose', () => {
      peer.consumers.delete(consumer.id);
    });

    return consumer;
  }

  closeProducer(peerId: string, producerId: string): void {
    const peer = this.peers.get(peerId);
    const producer = peer?.producers.get(producerId);
    producer?.close();
    peer?.producers.delete(producerId);
  }
}

// ---- Room registry ----

const rooms = new Map<string, Room>();

export async function getOrCreateRoom(channelId: string): Promise<Room> {
  let room = rooms.get(channelId);
  if (!room) {
    room = await Room.create(channelId);
    rooms.set(channelId, room);
  }
  return room;
}

export function deleteRoomIfEmpty(channelId: string): void {
  const room = rooms.get(channelId);
  if (room?.isEmpty) {
    rooms.delete(channelId);
    console.log(`[room] destroyed channel=${channelId}`);
  }
}
