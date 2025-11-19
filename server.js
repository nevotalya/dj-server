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

/**
 * Build the "users" list from the perspective of a single viewer:
 * - always includes the viewer themself
 * - includes all of the viewer's friends
 * (no global "everyone" list anymore)
 */
function usersListArrayFor(viewerId) {
  const followingMap = new Map();
  for (const [ws, uid] of sockets.entries()) {
    const meta = ws.meta || {};
    followingMap.set(uid, meta.following || null);
  }

  const viewer = users.get(viewerId);
  const friendSet = viewer?.friends || new Set();

  return Array.from(users.values())
    // ✅ Always include the viewer
    // ✅ And the viewer's friends
    .filter(u => u.id === viewerId || friendSet.has(u.id))
    .map(u => {
      const set = socketsByUser.get(u.id);
      const online = !!(set && set.size > 0);
      return {
        id: u.id,
        displayName: u.displayName || "(unnamed)",
        isDJ: currentDJs.has(u.id),
        following: followingMap.get(u.id) ?? null,
        online,
      };
    });
}

/**
 * Send a tailored "users" list to each connected socket, filtered
 * to that user's own friends (plus themself).
 */
function pushUsersList() {
  for (const [ws, uid] of sockets.entries()) {
    if (ws.readyState !== WebSocket.OPEN) continue;
    const listForViewer = usersListArrayFor(uid);
    safeSend(ws, { type: 'users', payload: listForViewer });
  }
}

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


// Serve static files (e.g. privacy policy)
const STATIC_DIR = path.join(__dirname, 'public');
app.use(express.static(STATIC_DIR));


/* ---------- AASA static (files) ---------- */
const AASA_DIR = path.join(__dirname, '.well-known');
app.use(
  '/.well-known',
  express.static(AASA_DIR, {
    setHeaders: (res, filePath) => {
      if (filePath.endsWith('apple-app-site-association')) {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Cache-Control', 'no-store');
      }
    }
  })
);
// Root fallback for some iOS versions
app.get('/apple-app-site-association', (_req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.sendFile(path.join(AASA_DIR, 'apple-app-site-association'));
});

/* ---------- Health ---------- */
app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    connected: wss?.clients?.size || 0,
    users: users.size,
    djs: Array.from(currentDJs),
  });
});

/* ---------- MusicKit developer token ---------- */
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
   Universal Links (AASA JSON) + Invite fallback pages
   ========================= */

// --- AASA JSON served dynamically as well (covers /invite and /invite/*) ---
const aasa = {
  applinks: {
    apps: [],
    details: [
      {
        appIDs: [`${TEAM_ID}.${BUNDLE_ID}`],
        paths: [
          "/invite",        // <— exact path (query form)
          "/invite/*",      // <— path param form
          "/friend", "/friend/*",
          "/addfriend", "/addfriend/*"
        ]
      }
    ]
  }
};

// Serve JSON from both places (ok to have both static + dynamic; dynamic wins)
app.get(['/.well-known/apple-app-site-association', '/apple-app-site-association'], (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.status(200).send(aasa);
});

// Helper: render fallback invite HTML
function renderInviteHTML({ id, name, currentUrl }) {
  const displayName = name || 'A friend';
  // Prefer opening via the same universal link (best for iOS); also show custom scheme
  const deepLinkScheme = `dj://addfriend?id=${encodeURIComponent(id)}${name ? `&name=${encodeURIComponent(name)}` : ''}`;

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>DJ — Invite</title>
  <style>
    body { font-family: -apple-system, system-ui, Helvetica, Arial, sans-serif; padding: 24px; line-height: 1.45; }
    .card { max-width: 560px; margin: 0 auto; border: 1px solid #eee; border-radius: 12px; padding: 20px; }
    .btn { display: inline-block; padding: 12px 16px; border-radius: 10px; text-decoration: none; }
    .primary { background: #0a84ff; color: #fff; }
    .ghost { border: 1px solid #ccc; color: #333; margin-left: 8px; }
    .muted { color: #666; font-size: 14px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Join your friend on DJ</h1>
    <p><strong>${displayName}</strong> invited you to connect.</p>
    <p>
      <!-- Universal Link to this very page (opens app if installed) -->
      <a class="btn primary" href="${currentUrl}">Open in the DJ App</a>
      <a class="btn ghost" href="${APP_STORE_URL}">Get the App</a>
    </p>
    <p class="muted">If nothing happens, tap <em>Get the App</em> to install first.</p>
  </div>
  <script>
    // Try custom scheme too—harmless if not installed
    (function(){
      var scheme = ${JSON.stringify(deepLinkScheme)};
      try { window.location = scheme; } catch (e) {}
    })();
  </script>
</body>
</html>`;
}

// Accept BOTH forms:
//   • /invite/:id?name=Talya
//   • /invite?id=...&name=...
// Plus legacy aliases /friend and /addfriend
function getIdAndName(req) {
  const id = String((req.params.id ?? req.query.id ?? '')).trim().slice(0, 128);
  const name = String(req.query.name ?? '').trim().slice(0, 128);
  return { id, name };
}

function inviteHandler(req, res) {
  const { id, name } = getIdAndName(req);
  // Compose the current URL (stays a universal link)
  const url = new URL(req.originalUrl, `${req.protocol}://${req.get('host')}`);
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.status(200).send(renderInviteHTML({ id, name, currentUrl: url.toString() }));
}

app.get(['/invite', '/friend', '/addfriend'], inviteHandler);
app.get(['/invite/:id', '/friend/:id', '/addfriend/:id'], inviteHandler);

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
        // friends list changed, so everyone’s filtered users list may change
        pushUsersList();
        break;
      }

      case 'listFriends': {
        const uid = sockets.get(ws);
        if (!uid) return;
        pushFriendsList(uid);
        break;
      }

      case 'listUsers': {
        // now sends a per-viewer filtered list
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

    if (!uid) return;

    const set = socketsByUser.get(uid);
    if (set) {
      set.delete(ws);
      if (set.size === 0) {
        // no more active sockets for this user
        socketsByUser.delete(uid);
      }
    }

    // IMPORTANT:
    // - Do NOT remove them from currentDJs here.
    // - Do NOT clear followers’ meta.following here.
    //
    // Being a DJ / stopping being a DJ is controlled *only* by the explicit
    // "setDJ" message, not by transient disconnections.
    //
    // Listeners will keep "following" the DJ ID in memory even if the DJ
    // temporarily drops offline, and will automatically resume when DJ reconnects.

    pushUsersList();
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
