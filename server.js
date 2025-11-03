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

// Bundle ID for Universal Links
const BUNDLE_ID = process.env.BUNDLE_ID || 'talya.DJ';
// Optional App Store fallback URL for invite page
const APP_STORE_URL = process.env.APP_STORE_URL || 'https://apps.apple.com/app/idYOUR_APP_ID';

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
    const online = !!(set && set.size > 0);  // presence
    return {
      id: u.id,
      displayName: u.displayName || "(unnamed)",
      isDJ: currentDJs.has(u.id),
      following: followingMap.get(u.id) ?? null,
      online,
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
  const payload = {
    djId: djUserId,
    position: Number(update.position) || 0,
    isPlaying: !!update.isPlaying,
    songStartAtGlobal: update.songStartAtGlobal,
    serverTimestamp: update.serverTimestamp,

    songPID:          update.songPID ?? undefined,
    playlistPID:      update.playlistPID ?? undefined,
    catalogSongId:    update.catalogSongId ?? undefined,
    title:            update.title ?? undefined,
    artist:           update.artist ?? undefined,
  };

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

// ---------- Health ----------
app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    connected: wss?.clients?.size || 0,
    users: users.size,
    djs: Array.from(currentDJs),
  });
});

// ---------- MusicKit developer token ----------
async function createDeveloperToken() {
  if (!TEAM_ID || !KEY_ID) throw new Error('TEAM_ID or KEY_ID missing');

  // Load PEM
  let pem;
  if (PRIVATE_KEY_P8_PATH) {
    pem = fs.readFileSync(PRIVATE_KEY_P8_PATH, 'utf8');
  } else if (PRIVATE_KEY_P8) {
    pem = PRIVATE_KEY_P8.includes('\\n') ? PRIVATE_KEY_P8.replace(/\\n/g, '\n') : PRIVATE_KEY_P8;
  } else {
    throw new Error('No PRIVATE_KEY_P8 or PRIVATE_KEY_P8_PATH provided');
  }
  pem = pem.replace(/\r\n/g, '\n').trim() + '\n';

  const first = pem.split('\n')[0];
  const last  = pem.trim().split('\n').slice(-1)[0];
  if (first !== '-----BEGIN PRIVATE KEY-----' || last !== '-----END PRIVATE KEY-----') {
    throw new Error('PEM missing BEGIN/END PRIVATE KEY markers');
  }

  const now = Math.floor(Date.now() / 1000);
  const exp = now + 60 * 60 * 12; // 12 hours

  const privateKey = await importPKCS8(pem, 'ES256');

  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: KEY_ID })
    .setIssuer(TEAM_ID)
    .setAudience('appstoreconnect-v1')
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
   Universal Links (AASA) + Invite page
   ========================= */

// --- AASA JSON (must be served with application/json, no redirect, no .json) ---
const aasa = {
  applinks: {
    apps: [],
    details: [
      {
        appIDs: [`${TEAM_ID}.${BUNDLE_ID}`],
        // Tighten these paths later if you’d like
        paths: [
          "/invite/*",
          "/friend/*",
          "/addfriend/*",
          "/.well-known/*",
          "*"
        ]
      }
    ]
  }
};

// Serve from both well-known and root
app.get(['/.well-known/apple-app-site-association', '/apple-app-site-association'], (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.status(200).send(aasa);
});

// --- Invite landing page: https://<host>/invite/:id?name=... ---
app.get('/invite/:id', (req, res) => {
  const id = String(req.params.id || '').trim();
  const name = String(req.query.name || '').trim();
  const encodedName = encodeURIComponent(name);

  // Your custom URL scheme to open the app directly
  const deepLink = `dj://addfriend?id=${encodeURIComponent(id)}${name ? `&name=${encodedName}` : ''}`;

  // Simple HTML: try to open the app; if not installed, show a button to App Store
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.status(200).send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>DJ — Invite</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; padding: 2rem; line-height: 1.4; }
    .box { max-width: 540px; margin: 0 auto; }
    a.btn { display: inline-block; padding: 12px 18px; border-radius: 10px; text-decoration: none; background: #007aff; color: #fff; }
    .muted { color: #666; font-size: 0.95rem; }
  </style>
</head>
<body>
  <div class="box">
    <h1>Join your friend on DJ</h1>
    <p class="muted">${name ? (`${name} invited you.`) : 'Open in the DJ app.'}</p>
    <p><a class="btn" href="${deepLink}">Open in App</a></p>
    <p class="muted">Don’t have the app? <a href="${APP_STORE_URL}">Get it on the App Store</a>.</p>
  </div>
  <script>
    // Attempt auto-open
    window.location.replace(${JSON.stringify(deepLink)});
    // (Optional) If you want to auto-fallback after N ms, uncomment below:
    // setTimeout(function(){ window.location.href = ${JSON.stringify(APP_STORE_URL)}; }, 2000);
  </script>
</body>
</html>`);
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
        const uid = sockets.get(ws);
        if (!uid) return;
        const fid = payload && payload.friendId;
        if (!fid || uid === fid) return;

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
const HOST = '0.0.0.0';                    // required for Render
const PORT = process.env.PORT || 10000;
server.listen(PORT, HOST, () => {
  console.log(`⚡ DJ server (WS + HTTP) listening on ${HOST}:${PORT}`);
  console.log(`   • WS endpoint: wss://dj-server-a95a.onrender.com`);
  console.log(`   • Dev token:   https://dj-server-a95a.onrender.com/v1/developer-token`);
  console.log(`   • Health:      https://dj-server-a95a.onrender.com/health`);
  console.log(`   • AASA:        https://dj-server-a95a.onrender.com/.well-known/apple-app-site-association`);
});
