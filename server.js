// server.js — Unified DJ WebSocket server + MusicKit dev token (CommonJS)

const http = require('http');
const path = require('path');
const fs = require('fs');
const express = require('express');
const WebSocket = require('ws');
require('dotenv').config();
const { importPKCS8, SignJWT } = require('jose');

// --- show which env/path we're using (helps diagnose .env loading & paths)
console.log('[dotenv] USING PATH:', process.env.PRIVATE_KEY_P8_PATH || '(env-inline)');

/* =========================
   Config
   ========================= */
const {
  TEAM_ID,
  KEY_ID,
  PRIVATE_KEY_P8,
  PRIVATE_KEY_P8_PATH,
} = process.env;

if (!TEAM_ID || !KEY_ID) {
  console.warn('⚠️ TEAM_ID / KEY_ID missing — /v1/developer-token will fail until set.');
}

/* =========================
   Persistence
   ========================= */
const STATE_FILE = path.join(__dirname, 'state.json');

function loadState() {
  try {
    const raw = fs.readFileSync(STATE_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    const users = new Map(
      (parsed.users || []).map(u => [
        u.id,
        { id: u.id, displayName: u.displayName || null, friends: new Set(u.friends || []) },
      ])
    );
    return { users };
  } catch {
    return { users: new Map() };
  }
}

let saveTimer = null;
function saveSoon() { clearTimeout(saveTimer); saveTimer = setTimeout(saveNow, 300); }
function saveNow() {
  const usersArr = Array.from(users.values()).map(u => ({
    id: u.id,
    displayName: u.displayName,
    friends: Array.from(u.friends || []),
  }));
  try { fs.writeFileSync(STATE_FILE, JSON.stringify({ users: usersArr }, null, 2), 'utf8'); }
  catch (e) { console.error('Persist error:', e); }
}

/* =========================
   Runtime state
   ========================= */
const { users } = loadState();
const sockets = new Map();        // ws -> userId
const socketsByUser = new Map();  // userId -> Set<ws>
const currentDJs = new Set();     // Set<userId>

/* =========================
   Helpers
   ========================= */
function ensureUser(id) {
  if (!users.has(id)) {
    users.set(id, { id, displayName: null, friends: new Set() });
    saveSoon();
  }
  return users.get(id);
}

function safeSend(ws, obj) {
  try { ws.send(typeof obj === 'string' ? obj : JSON.stringify(obj)); } catch {}
}

function broadcastAll(obj) {
  const text = typeof obj === 'string' ? obj : JSON.stringify(obj);
  for (const ws of wss.clients) {
    if (ws.readyState === WebSocket.OPEN) { try { ws.send(text); } catch {} }
  }
}

function usersListArray() {
  // following is tracked per-socket; compress to userId -> followedDjId|null
  const followingMap = new Map();
  for (const [ws, uid] of sockets.entries()) {
    const meta = ws.meta || {};
    followingMap.set(uid, meta.following || null);
  }

  return Array.from(users.values()).map(u => {
    const set = socketsByUser.get(u.id);
    const online = !!(set && set.size > 0);  // 👈 presence
    return {
      id: u.id,
      displayName: u.displayName || "(unnamed)",
      isDJ: currentDJs.has(u.id),
      following: followingMap.get(u.id) ?? null,
      online,                                   // 👈 NEW FIELD
    };
  });
}

function pushUsersList() { broadcastAll({ type: 'users', payload: usersListArray() }); }

function pushFriendsList(userId) {
  const u = users.get(userId); if (!u) return;
  const friends = Array.from(u.friends || []).map(fid => {
    const f = users.get(fid);
    return { id: fid, displayName: (f && f.displayName) || '(unnamed)' };
  });
  const text = JSON.stringify({ type: 'friendsList', payload: friends });
  const set = socketsByUser.get(userId) || new Set();
  for (const ws of set) {
    if (ws.readyState === WebSocket.OPEN) { try { ws.send(text); } catch {} }
  }
}

function forwardPlaybackFrom(djUserId, update) {
  // Prefer the DJ-provided global stamp (seconds).
  // If a legacy 'timestamp' exists, normalize it to seconds (it might be ms).
//  let serverTimestamp;
//  if (typeof update.serverTimestamp === 'number') {
//    serverTimestamp = update.serverTimestamp;               // already seconds (DJ stamped via NTP/offset)
//  } else if (typeof update.timestamp === 'number') {
//    serverTimestamp = update.timestamp > 1e12
//      ? update.timestamp / 1000                             // normalize ms → s
//      : update.timestamp;                                   // already seconds
//  } else {
//    serverTimestamp = undefined;                            // no stamp; listeners will fall back gracefully
//    // If you want a fallback (less accurate, adds DJ→server latency), uncomment:
//    // serverTimestamp = Date.now() / 1000;
//  }

  const payload = {
    djId: djUserId,
    position: Number(update.position) || 0,
    isPlaying: !!update.isPlaying,

    songStartAtGlobal: update.songStartAtGlobal,
    // ✅ New: send 'serverTimestamp' (seconds). Do NOT auto-generate legacy 'timestamp'.
    //serverTimestamp,
    serverTimestamp: update.serverTimestamp,


    // pass-through (keep undefined fields out of JSON)
    songPID:          update.songPID ?? undefined,
    playlistPID:      update.playlistPID ?? undefined,
    catalogSongId:    update.catalogSongId ?? undefined,
    title:            update.title ?? undefined,
    artist:           update.artist ?? undefined,

    // (optional) if you must keep legacy 'timestamp' for old clients, you can mirror seconds here:
    // timestamp: serverTimestamp
  };

  //console.log('DJ server serverTimestamp', update.serverTimestamp);
  const msg = JSON.stringify({ type: 'playback', payload });

  for (const [ws] of sockets.entries()) {
    if (ws.readyState !== WebSocket.OPEN) continue;
    const meta = ws.meta || {};
    if (meta.following === djUserId) {
      try { ws.send(msg); } catch {}
    }
  }
}

/* =========================
   Express app
   ========================= */
const app = express();

// Health
app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    connected: wss?.clients?.size || 0,
    users: users.size,
    djs: Array.from(currentDJs),
  });
});

// MusicKit developer token (with robust PEM debug)
async function createDeveloperToken() {
  if (!TEAM_ID || !KEY_ID) throw new Error('TEAM_ID or KEY_ID missing');

  // 1) Load PEM from file path or env
  let pem;
  //console.log('🔐 loading key…');
  if (PRIVATE_KEY_P8_PATH) {
    try {
      pem = fs.readFileSync(PRIVATE_KEY_P8_PATH, 'utf8');
    } catch (e) {
      throw new Error(`Failed to read PRIVATE_KEY_P8_PATH: ${e.message}`);
    }
  } else if (PRIVATE_KEY_P8) {
    pem = PRIVATE_KEY_P8.includes('\\n') ? PRIVATE_KEY_P8.replace(/\\n/g, '\n') : PRIVATE_KEY_P8;
  } else {
    throw new Error('No PRIVATE_KEY_P8 or PRIVATE_KEY_P8_PATH provided');
  }

  // 2) Normalize & sanity-check markers
  pem = pem.replace(/\r\n/g, '\n');
  // strip BOM & trailing junk, ensure newline
  if (pem.charCodeAt(0) === 0xFEFF) pem = pem.slice(1);
  pem = pem.trimEnd();
  if (pem.endsWith('%')) pem = pem.slice(0, -1);
  pem = pem.trim() + '\n';

  const first = pem.split('\n')[0];
  const last  = pem.trim().split('\n').slice(-1)[0];
//  console.log('🔐 PEM debug:', {
//    first,
//    last,
//    len: pem.length,
//    path: PRIVATE_KEY_P8_PATH || '(env-inline)',
//  });

  if (first !== '-----BEGIN PRIVATE KEY-----' || last !== '-----END PRIVATE KEY-----') {
    throw new Error('PEM missing BEGIN/END PRIVATE KEY markers');
  }

  // 3) Sign ES256 JWT
  const now = Math.floor(Date.now() / 1000);
  const exp = now + 60 * 60 * 12; // 12 hours

  const privateKey = await importPKCS8(pem, 'ES256');

  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: KEY_ID })
    .setIssuer(TEAM_ID)                 // iss = Team ID
    .setAudience('appstoreconnect-v1')  // required audience
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .sign(privateKey);

  return jwt;
}

app.get('/v1/developer-token', async (_req, res) => {
  try {
    const token = await createDeveloperToken();
    res.json({ token });
  } catch (e) {
    console.error('Token error:', e);
    res.status(500).json({ error: 'token_failed' });
  }
});

/* =========================
   HTTP + WebSocket
   ========================= */
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.meta = { following: null };
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (data) => {
    let msg = null;
    try { msg = JSON.parse(data.toString()); }
    catch { console.warn('⚠️ Bad JSON'); return; }

    const { type, payload } = msg || {};

    switch (type) {
      case 'identify': {
        const { id, displayName } = payload || {};
        if (!id) return;

        sockets.set(ws, id);
        if (!socketsByUser.has(id)) socketsByUser.set(id, new Set());
        socketsByUser.get(id).add(ws);

        const u = ensureUser(id);

        if (!u.displayName && (!displayName || !String(displayName).trim())) {
          safeSend(ws, { type: 'requireName', payload: { reason: 'displayNameRequired' } });
          return;
        }
        if (!u.displayName && displayName) {
          u.displayName = sanitizeName(displayName);
          saveSoon();
        }

        safeSend(ws, { type: 'hello', payload: { id: u.id, displayName: u.displayName } });
        pushUsersList();
        pushFriendsList(u.id);
        break;
      }

      case 'setName': {
        const uid = sockets.get(ws);
        if (!uid) return;
        const name = sanitizeName(payload && payload.displayName);
        if (!name) {
          safeSend(ws, { type: 'requireName', payload: { reason: 'invalid' } });
          return;
        }
        const u = ensureUser(uid);
        u.displayName = name;
        saveSoon();
        safeSend(ws, { type: 'hello', payload: { id: u.id, displayName: u.displayName } });
        pushUsersList();
        for (const friendId of u.friends || []) pushFriendsList(friendId);
        pushFriendsList(uid);
        break;
      }

      case 'setDJ': {
        const uid = sockets.get(ws);
        if (!uid) return;
        const u = users.get(uid);
        if (!u || !u.displayName) {
          safeSend(ws, { type: 'requireName', payload: { reason: 'displayNameRequired' } });
          return;
        }
        const on = !!(payload && payload.on);
        if (on) currentDJs.add(uid);
        else {
          if (currentDJs.has(uid)) {
            currentDJs.delete(uid);
            for (const [ws2] of sockets.entries()) {
              if (ws2.meta && ws2.meta.following === uid) ws2.meta.following = null;
            }
          }
        }
        pushUsersList();
        break;
      }

      case 'follow': {
        const uid = sockets.get(ws);
        if (!uid) return;
        const u = users.get(uid);
        if (!u || !u.displayName) {
          safeSend(ws, { type: 'requireName', payload: { reason: 'displayNameRequired' } });
          return;
        }
        const djId = payload && payload.djId;
        if (!djId) return;
        if (!currentDJs.has(djId)) return;
        ws.meta.following = djId;
        pushUsersList();
        break;
      }

      case 'unfollow': {
        const uid = sockets.get(ws);
        if (!uid) return;
        ws.meta.following = null;
        pushUsersList();
        break;
      }

      case 'addFriend': {
        console.log(`addFriend 0`);
        const uid = sockets.get(ws);
        if (!uid) return;
        const fid = payload && payload.friendId;
          
          
        console.log(`addFriend 1`, uid, fid);
        if (!fid || uid === fid) return;

        console.log(`addFriend 2`, uid, fid);

        const me = ensureUser(uid);
        const them = ensureUser(fid);

        me.friends.add(fid);
        them.friends.add(uid);
        saveSoon();

        pushFriendsList(uid);
        pushFriendsList(fid);
        break;
      }

      case 'listFriends': {
        const uid = sockets.get(ws);
        if (!uid) return;
        pushFriendsList(uid);
        break;
      }

      case 'listUsers': {
        pushUsersList();
        break;
      }

      case 'playback': {
        const uid = sockets.get(ws);
        if (!uid) return;
        if (!currentDJs.has(uid)) return;
        forwardPlaybackFrom(uid, payload || {});
        break;
      }

      case 'clockPing': {
        const now = Date.now() / 1000; // seconds
        const echo = payload && payload.clientTime;
        safeSend(ws, { type: 'clockPong', payload: { serverTime: now, echo } });
        break;
      }

      default:
        break;
    }
  });

  ws.on('close', () => {
    const uid = sockets.get(ws);
    sockets.delete(ws);
    if (uid) {
      const set = socketsByUser.get(uid);
      if (set) {
        set.delete(ws);
        if (set.size === 0) socketsByUser.delete(uid);
      }
      if (socketsByUser.get(uid) == null && currentDJs.has(uid)) {
        currentDJs.delete(uid);
        for (const [ws2] of sockets.entries()) {
          if (ws2.meta && ws2.meta.following === uid) ws2.meta.following = null;
        }
      }
      pushUsersList();
    }
  });

  ws.on('error', (err) => { console.error('WS error:', err); });
});

/* =========================
   Heartbeat
   ========================= */
const HEARTBEAT_MS = 30000;
setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) { try { ws.terminate(); } catch {} return; }
    ws.isAlive = false;
    try { ws.ping(); } catch {}
  });
}, HEARTBEAT_MS);

/* =========================
   Utilities
   ========================= */
function sanitizeName(name) {
  if (!name) return null;
  let s = String(name).trim();
  s = s.slice(0, 24);
  if (!s) return null;
  return s;
}

/* =========================
   Start server
   ========================= */
/* =========================
   Start server
   ========================= */
const HOST = '0.0.0.0';                    // 👈 important for Render
const PORT = process.env.PORT || 10000;
server.listen(PORT, HOST, () => {
  console.log(`⚡ DJ server (WS + HTTP) listening on ${HOST}:${PORT}`);
  console.log(`   • WS endpoint: wss://dj-server-a95a.onrender.com`);
  console.log(`   • Dev token:   wss://dj-server-a95a.onrender.com/v1/developer-token`);
  console.log(`   • Health:      wss://dj-server-a95a.onrender.com/health`);
});
