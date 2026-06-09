const DEFAULT_TTL_SECONDS = 86400;
const MAX_JSON_BYTES = 1024 * 1024;
const LOBBY_ROOM_STALE_MS = 90_000;
const LOBBY_MAX_ROOMS = 100;
const LOBBY_OBJECT_NAME = '__internet_lobby__';
const WORKER_VERSION = 'netplay-signal-2026-06-09-lobby';

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

    if (action === 'lobby') {
      return await this.handleLobby(request);
    }

    if (request.method === 'PUT' && action === 'room') {
      const payload = await readJson(request);
      const ttlSeconds = clampTtl(payload.ttlSeconds);
      const expiresAtMs = Date.now() + ttlSeconds * 1000;
      const offerSdp = String(payload.offerSdp || payload.offer || '');
      const roomInfo = payload.roomInfo || payload.room || {};
      const oldRoom = await this.state.storage.get('room');
      const hasPasswordPayload =
        Object.prototype.hasOwnProperty.call(payload, 'password') ||
        Object.prototype.hasOwnProperty.call(payload, 'passwordHash');
      const passwordHash = hasPasswordPayload
        ? String(payload.passwordHash || '')
        : String(oldRoom?.passwordHash || '');
      const passwordRequired = passwordHash.length > 0;
      await this.state.storage.put('room', {
        roomId: String(payload.roomId || oldRoom?.roomId || ''),
        offerSdp,
        roomInfo,
        answerSdp: '',
        expiresAtMs,
        lastSeenAtMs: Date.now(),
        passwordHash,
        passwordRequired,
      });
      await this.state.storage.setAlarm(expiresAtMs + 60_000);
      return json({ ok: true, expiresAtMs, passwordRequired });
    }

    if (request.method === 'GET' && action === 'room') {
      const room = await this.state.storage.get('room');
      if (!room || isExpired(room)) {
        return json({ error: 'room not found' }, 404);
      }
      if (room.passwordRequired) {
        return json({ error: 'password required' }, 403);
      }
      return json({
        offer: room.offerSdp,
        room: room.roomInfo,
        expiresAt: room.expiresAtMs,
        offerSdp: room.offerSdp,
        roomInfo: room.roomInfo,
        expiresAtMs: room.expiresAtMs,
        passwordRequired: false,
      });
    }

    if (request.method === 'PUT' && action === 'heartbeat') {
      const room = await this.state.storage.get('room');
      if (!room || isExpired(room)) {
        return json({ error: 'room not found' }, 404);
      }
      const payload = await readJson(request).catch(() => ({}));
      const ttlSeconds = clampTtl(payload.ttlSeconds);
      room.expiresAtMs = Date.now() + ttlSeconds * 1000;
      room.lastSeenAtMs = Date.now();
      if (payload.roomInfo || payload.room) {
        room.roomInfo = payload.roomInfo || payload.room;
      }
      await this.state.storage.put('room', room);
      await this.state.storage.setAlarm(room.expiresAtMs + 60_000);
      return json({
        ok: true,
        expiresAtMs: room.expiresAtMs,
        passwordRequired: !!room.passwordRequired,
      });
    }

    if (request.method === 'PUT' && action === 'join') {
      const room = await this.state.storage.get('room');
      if (!room || isExpired(room)) {
        return json({ error: 'room not found' }, 404);
      }
      const payload = await readJson(request).catch(() => ({}));
      if (room.passwordRequired) {
        const passwordHash = String(payload.passwordHash || '');
        if (!passwordHash || passwordHash !== room.passwordHash) {
          return json({ error: 'bad password' }, 403);
        }
      }
      if (payload.request === true) {
        const joinId = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
        const now = Date.now();
        const join = {
          joinId,
          playerName: String(payload.playerName || 'Player 2'),
          offerSdp: '',
          answerSdp: '',
          createdAtMs: now,
          expiresAtMs: now + 45_000,
        };
        await this.state.storage.put(`join:${joinId}`, join);
        await this.state.storage.setAlarm(join.expiresAtMs + 1000);
        return json({
          joinId,
          room: room.roomInfo,
          roomInfo: room.roomInfo,
          expiresAtMs: join.expiresAtMs,
        });
      }
      return json({
        offer: room.offerSdp,
        room: room.roomInfo,
        expiresAt: room.expiresAtMs,
        offerSdp: room.offerSdp,
        roomInfo: room.roomInfo,
        expiresAtMs: room.expiresAtMs,
        passwordRequired: !!room.passwordRequired,
      });
    }

    if (action === 'joins') {
      return await this.handleJoins(request, segments);
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

  async handleJoins(request, segments) {
    const room = await this.state.storage.get('room');
    if (!room || isExpired(room)) {
      return json({ error: 'room not found' }, 404);
    }
    await this.cleanupJoinRequests();

    const joinId = segments[1] || '';
    const subaction = segments[2] || '';

    if (request.method === 'GET' && !joinId) {
      const entries = await this.state.storage.list({ prefix: 'join:' });
      const joins = [];
      for (const [, value] of entries) {
        joins.push({
          joinId: value.joinId,
          playerName: value.playerName || 'Player 2',
          hasOffer: !!value.offerSdp,
          hasAnswer: !!value.answerSdp,
          createdAtMs: Number(value.createdAtMs || 0),
          expiresAtMs: Number(value.expiresAtMs || 0),
        });
      }
      joins.sort((a, b) => a.createdAtMs - b.createdAtMs);
      return json({ joins });
    }

    if (!joinId) {
      return json({ error: 'missing joinId' }, 400);
    }

    const key = `join:${joinId}`;
    const join = await this.state.storage.get(key);
    if (!join || Number(join.expiresAtMs || 0) <= Date.now()) {
      await this.state.storage.delete(key);
      return json({ error: 'join not found' }, 404);
    }

    if (request.method === 'GET' && subaction === 'offer') {
      if (!join.offerSdp) {
        return withCors(new Response(null, { status: 204 }));
      }
      return json({
        offer: join.offerSdp,
        offerSdp: join.offerSdp,
        room: room.roomInfo,
        roomInfo: room.roomInfo,
        expiresAtMs: join.expiresAtMs,
      });
    }

    if (request.method === 'PUT' && subaction === 'offer') {
      const payload = await readJson(request).catch(() => ({}));
      join.offerSdp = String(payload.offerSdp || payload.offer || '');
      join.expiresAtMs = Date.now() + 45_000;
      await this.state.storage.put(key, join);
      await this.state.storage.setAlarm(join.expiresAtMs + 1000);
      return json({ ok: true, expiresAtMs: join.expiresAtMs });
    }

    if (request.method === 'GET' && subaction === 'answer') {
      if (!join.answerSdp) {
        return withCors(new Response(null, { status: 204 }));
      }
      return json({ answer: join.answerSdp, answerSdp: join.answerSdp });
    }

    if (request.method === 'PUT' && subaction === 'answer') {
      const payload = await readJson(request).catch(() => ({}));
      join.answerSdp = String(payload.answerSdp || payload.answer || '');
      join.expiresAtMs = Date.now() + 15_000;
      await this.state.storage.put(key, join);
      await this.state.storage.setAlarm(join.expiresAtMs + 1000);
      return json({ ok: true, expiresAtMs: join.expiresAtMs });
    }

    if (request.method === 'POST' && subaction === 'complete') {
      await this.state.storage.delete(key);
      return json({ ok: true });
    }

    return json({ error: 'not found' }, 404);
  }

  async cleanupJoinRequests() {
    const entries = await this.state.storage.list({ prefix: 'join:' });
    const now = Date.now();
    const deletes = [];
    for (const [key, value] of entries) {
      if (Number(value?.expiresAtMs || 0) <= now) {
        deletes.push(key);
      }
    }
    if (deletes.length) {
      await this.state.storage.delete(deletes);
    }
  }

  async alarm() {
    const room = await this.state.storage.get('room');
    if (room && isExpired(room)) {
      await this.state.storage.delete('room');
    }

    const entries = await this.state.storage.list({ prefix: 'room:' });
    const joinEntries = await this.state.storage.list({ prefix: 'join:' });
    const now = Date.now();
    let nextAlarm = 0;
    const deletes = [];
    for (const [key, value] of joinEntries) {
      if (Number(value?.expiresAtMs || 0) <= now) {
        deletes.push(key);
      } else if (nextAlarm === 0 || Number(value.expiresAtMs) < nextAlarm) {
        nextAlarm = Number(value.expiresAtMs);
      }
    }
    for (const [key, value] of entries) {
      const expired =
        Number(value?.expiresAtMs || 0) <= now ||
        now - Number(value?.lastSeenAtMs || 0) > LOBBY_ROOM_STALE_MS;
      if (expired) {
        deletes.push(key);
      } else {
        const candidate = Math.min(
          Number(value.expiresAtMs || 0),
          Number(value.lastSeenAtMs || 0) + LOBBY_ROOM_STALE_MS,
        );
        if (candidate > now && (nextAlarm === 0 || candidate < nextAlarm)) {
          nextAlarm = candidate;
        }
      }
    }
    if (deletes.length) {
      await this.state.storage.delete(deletes);
    }
    if (nextAlarm > 0) {
      await this.state.storage.setAlarm(nextAlarm + 1000);
    }
  }

  async handleLobby(request) {
    const payload =
      request.method === 'GET' ? {} : await readJson(request).catch(() => ({}));
    const roomId = String(payload.roomId || '');

    if (request.method === 'GET') {
      const rooms = await this.listLobbyRooms();
      return json({ rooms, nowMs: Date.now(), staleMs: LOBBY_ROOM_STALE_MS });
    }

    if (request.method === 'PUT') {
      if (!roomId) {
        return json({ error: 'missing roomId' }, 400);
      }
      const roomInfo = payload.roomInfo || payload.room || {};
      const now = Date.now();
      const ttlSeconds = clampTtl(payload.ttlSeconds);
      const expiresAtMs =
        Number(payload.expiresAtMs || 0) > now
          ? Number(payload.expiresAtMs)
          : now + ttlSeconds * 1000;
      const entry = {
        roomId,
        signalRoomId: roomId,
        roomInfo,
        passwordRequired: !!payload.passwordRequired,
        currentPlayers: Number(payload.currentPlayers || roomInfo.currentPlayers || 1),
        maxPlayers: Number(payload.maxPlayers || roomInfo.maxPlayers || 2),
        lastSeenAtMs: now,
        expiresAtMs,
      };
      await this.state.storage.put(`room:${roomId}`, entry);
      await this.state.storage.setAlarm(now + LOBBY_ROOM_STALE_MS + 1000);
      return json({ ok: true, room: publicLobbyEntry(entry) });
    }

    if (request.method === 'DELETE') {
      if (!roomId) {
        return json({ error: 'missing roomId' }, 400);
      }
      await this.state.storage.delete(`room:${roomId}`);
      return json({ ok: true });
    }

    return json({ error: 'not found' }, 404);
  }

  async listLobbyRooms() {
    const entries = await this.state.storage.list({ prefix: 'room:' });
    const now = Date.now();
    const rooms = [];
    const deletes = [];
    for (const [key, value] of entries) {
      const expired =
        Number(value?.expiresAtMs || 0) <= now ||
        now - Number(value?.lastSeenAtMs || 0) > LOBBY_ROOM_STALE_MS;
      if (expired) {
        deletes.push(key);
        continue;
      }
      rooms.push(publicLobbyEntry(value));
    }
    if (deletes.length) {
      await this.state.storage.delete(deletes);
    }
    rooms.sort((a, b) => Number(b.lastSeenAtMs || 0) - Number(a.lastSeenAtMs || 0));
    return rooms.slice(0, LOBBY_MAX_ROOMS);
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

  if (request.method === 'GET' && path === '/rooms') {
    return await getLobbyStub(env).fetch('https://room.local/lobby');
  }

  if (request.method === 'POST' && path === '/rooms') {
    const payload = await readJson(request);
    const roomId = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    const passwordHash = await hashPassword(roomId, payload.password, env);
    const stub = getRoomStub(env, roomId);
    const response = await stub.fetch('https://room.local/room', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        roomId,
        offerSdp: payload.offerSdp || payload.offer,
        roomInfo: payload.roomInfo || payload.room,
        ttlSeconds: payload.ttlSeconds,
        passwordHash,
      }),
    });
    if (!response.ok) {
      return response;
    }
    const saved = await response.json();
    await upsertLobbyRoom(env, {
      roomId,
      roomInfo: payload.roomInfo || payload.room,
      passwordRequired: !!passwordHash,
      ttlSeconds: payload.ttlSeconds,
      expiresAtMs: saved.expiresAtMs,
    });
    return json({ roomId, expiresAtMs: saved.expiresAtMs });
  }

  const joinMatch = path.match(
    /^\/rooms\/([^/]+)\/joins(?:\/([^/]+)(?:\/(offer|answer|complete))?)?$/,
  );
  if (joinMatch) {
    const roomId = joinMatch[1];
    const joinId = joinMatch[2] || '';
    const action = joinMatch[3] || '';
    const stub = getRoomStub(env, roomId);
    const targetPath = joinId
      ? `https://room.local/joins/${joinId}${action ? `/${action}` : ''}`
      : 'https://room.local/joins';

    if (request.method === 'GET') {
      return await stub.fetch(targetPath);
    }

    if (request.method === 'POST' && action === 'complete') {
      return await stub.fetch(targetPath, { method: 'POST' });
    }

    if (request.method === 'POST' && (action === 'offer' || action === 'answer')) {
      const payload = await readJson(request);
      return await stub.fetch(targetPath, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
    }
  }

  const roomMatch = path.match(/^\/rooms\/([^/]+)(?:\/(answer|close|heartbeat|join))?$/);
  if (roomMatch) {
    const roomId = roomMatch[1];
    const action = roomMatch[2] || '';
    const stub = getRoomStub(env, roomId);

    if (request.method === 'GET' && !action) {
      return await stub.fetch('https://room.local/room');
    }

    if (request.method === 'POST' && !action) {
      const payload = await readJson(request);
      const response = await stub.fetch('https://room.local/room', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          roomId,
          offerSdp: payload.offerSdp || payload.offer,
          roomInfo: payload.roomInfo || payload.room,
          ttlSeconds: payload.ttlSeconds,
        }),
      });
      if (response.ok) {
        const saved = await response.clone().json();
        await upsertLobbyRoom(env, {
          roomId,
          roomInfo: payload.roomInfo || payload.room,
          passwordRequired: saved.passwordRequired,
          ttlSeconds: payload.ttlSeconds,
          expiresAtMs: saved.expiresAtMs,
        });
      }
      return response;
    }

    if (request.method === 'POST' && action === 'heartbeat') {
      const payload = await readJson(request);
      const response = await stub.fetch('https://room.local/heartbeat', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ttlSeconds: payload.ttlSeconds,
          roomInfo: payload.roomInfo || payload.room,
        }),
      });
      if (response.ok) {
        const saved = await response.clone().json();
        await upsertLobbyRoom(env, {
          roomId,
          roomInfo: payload.roomInfo || payload.room,
          passwordRequired: saved.passwordRequired,
          ttlSeconds: payload.ttlSeconds,
          expiresAtMs: saved.expiresAtMs,
        });
      }
      return response;
    }

    if (request.method === 'POST' && action === 'join') {
      const payload = await readJson(request).catch(() => ({}));
      const passwordHash = await hashPassword(roomId, payload.password, env);
      return await stub.fetch('https://room.local/join', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          passwordHash,
          request: payload.request === true,
          playerName: payload.playerName,
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
      const response = await stub.fetch('https://room.local/close', { method: 'POST' });
      await removeLobbyRoom(env, roomId);
      return response;
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

function getLobbyStub(env) {
  return getRoomStub(env, LOBBY_OBJECT_NAME);
}

async function upsertLobbyRoom(env, options) {
  const roomInfo = options.roomInfo || {};
  if (!options.roomId || !roomInfo || Object.keys(roomInfo).length === 0) {
    return;
  }
  await getLobbyStub(env).fetch('https://room.local/lobby', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      roomId: options.roomId,
      roomInfo,
      passwordRequired: !!options.passwordRequired,
      ttlSeconds: options.ttlSeconds,
      expiresAtMs: options.expiresAtMs,
    }),
  });
}

async function removeLobbyRoom(env, roomId) {
  if (!roomId) {
    return;
  }
  await getLobbyStub(env).fetch('https://room.local/lobby', {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ roomId }),
  });
}

function publicLobbyEntry(entry) {
  return {
    roomId: entry.roomId,
    signalRoomId: entry.signalRoomId || entry.roomId,
    room: entry.roomInfo || {},
    roomInfo: entry.roomInfo || {},
    passwordRequired: !!entry.passwordRequired,
    currentPlayers: Number(entry.currentPlayers || 1),
    maxPlayers: Number(entry.maxPlayers || 2),
    lastSeenAtMs: Number(entry.lastSeenAtMs || 0),
    expiresAtMs: Number(entry.expiresAtMs || 0),
  };
}

async function hashPassword(roomId, password, env) {
  const raw = String(password || '');
  if (!raw) {
    return '';
  }
  const secret = String(env.ROOM_PASSWORD_SECRET || env.CF_TURN_TOKEN || '');
  const data = new TextEncoder().encode(`${roomId}:${secret}:${raw}`);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
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
  headers.set('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
  headers.set('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
