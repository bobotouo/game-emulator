const DEFAULT_TTL_SECONDS = 86400;
const MAX_JSON_BYTES = 1024 * 1024;
const WORKER_VERSION = 'netplay-signal-2026-06-04-compat-fields';

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return withCors(new Response(null, { status: 204 }));
    }

    try {
      return await handleRequest(request, env);
    } catch (error) {
      console.error(error?.stack || error);
      return json({ error: 'internal error' }, 500);
    }
  },
};

export class RoomDurableObject {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const segments = url.pathname.split('/').filter(Boolean);
    const action = segments[0] || '';

    if (request.method === 'PUT' && action === 'room') {
      const payload = await readJson(request);
      const ttlSeconds = clampTtl(payload.ttlSeconds);
      const expiresAtMs = Date.now() + ttlSeconds * 1000;
      const offerSdp = String(payload.offerSdp || payload.offer || '');
      const roomInfo = payload.roomInfo || payload.room || {};
      await this.state.storage.put('room', {
        offerSdp,
        roomInfo,
        answerSdp: '',
        expiresAtMs,
      });
      await this.state.storage.setAlarm(expiresAtMs + 60_000);
      return json({ ok: true, expiresAtMs });
    }

    if (request.method === 'GET' && action === 'room') {
      const room = await this.state.storage.get('room');
      if (!room || isExpired(room)) {
        return json({ error: 'room not found' }, 404);
      }
      return json({
        offer: room.offerSdp,
        room: room.roomInfo,
        expiresAt: room.expiresAtMs,
        offerSdp: room.offerSdp,
        roomInfo: room.roomInfo,
        expiresAtMs: room.expiresAtMs,
      });
    }

    if (request.method === 'PUT' && action === 'answer') {
      const room = await this.state.storage.get('room');
      if (!room || isExpired(room)) {
        return json({ error: 'room not found' }, 404);
      }
      const payload = await readJson(request);
      room.answerSdp = String(payload.answerSdp || payload.answer || '');
      await this.state.storage.put('room', room);
      return json({ ok: true });
    }

    if (request.method === 'GET' && action === 'answer') {
      const room = await this.state.storage.get('room');
      if (!room || isExpired(room)) {
        return json({ error: 'room not found' }, 404);
      }
      if (!room.answerSdp) {
        return withCors(new Response(null, { status: 204 }));
      }
      return json({ answer: room.answerSdp, answerSdp: room.answerSdp });
    }

    if (request.method === 'POST' && action === 'close') {
      await this.state.storage.deleteAll();
      return json({ ok: true });
    }

    return json({ error: 'not found' }, 404);
  }

  async alarm() {
    await this.state.storage.deleteAll();
  }
}

async function handleRequest(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;

  if (request.method === 'GET' && path === '/health') {
    return json({ ok: true, version: WORKER_VERSION });
  }

  if (request.method === 'POST' && path === '/ice') {
    return await generateIceServers(request, env);
  }

  if (request.method === 'POST' && path === '/rooms') {
    const payload = await readJson(request);
    const roomId = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    const stub = getRoomStub(env, roomId);
    const response = await stub.fetch('https://room.local/room', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        offerSdp: payload.offerSdp || payload.offer,
        roomInfo: payload.roomInfo || payload.room,
        ttlSeconds: payload.ttlSeconds,
      }),
    });
    if (!response.ok) {
      return response;
    }
    const saved = await response.json();
    return json({ roomId, expiresAtMs: saved.expiresAtMs });
  }

  const roomMatch = path.match(/^\/rooms\/([^/]+)(?:\/(answer|close))?$/);
  if (roomMatch) {
    const roomId = roomMatch[1];
    const action = roomMatch[2] || '';
    const stub = getRoomStub(env, roomId);

    if (request.method === 'GET' && !action) {
      return await stub.fetch('https://room.local/room');
    }

    if (request.method === 'POST' && !action) {
      const payload = await readJson(request);
      return await stub.fetch('https://room.local/room', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          offerSdp: payload.offerSdp || payload.offer,
          roomInfo: payload.roomInfo || payload.room,
          ttlSeconds: payload.ttlSeconds,
        }),
      });
    }

    if (request.method === 'POST' && action === 'answer') {
      const payload = await readJson(request);
      return await stub.fetch('https://room.local/answer', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ answerSdp: payload.answerSdp || payload.answer }),
      });
    }

    if (request.method === 'GET' && action === 'answer') {
      return await stub.fetch('https://room.local/answer');
    }

    if (request.method === 'POST' && action === 'close') {
      return await stub.fetch('https://room.local/close', { method: 'POST' });
    }
  }

  return json({ error: 'not found' }, 404);
}

async function generateIceServers(request, env) {
  const payload = await readJson(request).catch(() => ({}));
  const ttl = clampTtl(payload.ttl || payload.ttlSeconds);
  const keyId = env.CF_TURN_KEY_ID;
  const token = env.CF_TURN_TOKEN;
  if (!keyId || !token) {
    return json({ error: 'missing Cloudflare TURN credentials' }, 500);
  }

  const response = await fetch(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ttl }),
    },
  );

  const text = await response.text();
  if (!response.ok) {
    return json(
      { error: 'cloudflare ice request failed', status: response.status, body: text },
      502,
    );
  }

  return withCors(
    new Response(text, {
      status: 200,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    }),
  );
}

function getRoomStub(env, roomId) {
  if (!env.ROOMS) {
    throw new Error('Durable Object binding ROOMS is missing');
  }
  const id = env.ROOMS.idFromName(roomId);
  return env.ROOMS.get(id);
}

async function readJson(request) {
  const text = await request.text();
  if (text.length > MAX_JSON_BYTES) {
    throw new Error('request body too large');
  }
  return text ? JSON.parse(text) : {};
}

function clampTtl(value) {
  const ttl = Number(value || DEFAULT_TTL_SECONDS);
  if (!Number.isFinite(ttl)) {
    return DEFAULT_TTL_SECONDS;
  }
  return Math.max(60, Math.min(86400, Math.floor(ttl)));
}

function isExpired(room) {
  return Number(room.expiresAtMs || 0) <= Date.now();
}

function json(data, status = 200) {
  return withCors(
    new Response(JSON.stringify(data), {
      status,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    }),
  );
}

function withCors(response) {
  const headers = new Headers(response.headers);
  headers.set('Access-Control-Allow-Origin', '*');
  headers.set('Access-Control-Allow-Methods', 'GET,POST,PUT,OPTIONS');
  headers.set('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
