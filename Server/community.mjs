// Filmo Time community: the profiles colleagues choose to show each other.
// One file, no dependencies: Node 22 (node:sqlite) behind a TLS reverse proxy.
//
// Who gets in: whoever holds a DeskTime API key of an account in ALLOWED_DOMAIN. The key is sent
// once, on registration, checked against DeskTime and thrown away: it is never stored or logged.
// From then on the app uses a token of its own, of which only the hash is kept.

import { createServer } from 'node:http'
import { createHash, randomBytes } from 'node:crypto'
import { DatabaseSync } from 'node:sqlite'

const PORT = Number(process.env.PORT ?? 3190)
const HOST = process.env.HOST ?? '127.0.0.1'
const DB_PATH = process.env.DB_PATH ?? './community.sqlite'
const ALLOWED_DOMAIN = (process.env.ALLOWED_DOMAIN ?? 'filmo.io').toLowerCase()
const DESKTIME = process.env.DESKTIME_URL ?? 'https://desktime.com/api/v2/json/employee/basic'
const MAX_JSON = 16 * 1024
const MAX_PHOTO = 200 * 1024
const SLOTS = 3

const db = new DatabaseSync(DB_PATH)
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS members (
    id INTEGER PRIMARY KEY,          -- DeskTime employee id
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    profile TEXT,                    -- JSON, as validated below
    photo BLOB,
    photo_version INTEGER NOT NULL DEFAULT 0,
    updated REAL NOT NULL
  );
  CREATE INDEX IF NOT EXISTS members_token ON members (token_hash);
`)

const hash = (s) => createHash('sha256').update(s).digest('hex')
const now = () => Date.now() / 1000

class Refusal extends Error {
  constructor(status, message) { super(message); this.status = status }
}

// Registration is the only door without a token: a few tries per address and hour.
const tries = new Map()
function allow(ip) {
  const hour = Math.floor(Date.now() / 3600e3)
  const t = tries.get(ip)
  if (!t || t.hour !== hour) { tries.set(ip, { hour, n: 1 }); return true }
  return ++t.n <= 20
}
setInterval(() => { const hour = Math.floor(Date.now() / 3600e3); for (const [k, v] of tries) if (v.hour !== hour) tries.delete(k) }, 600e3).unref()

async function body(req, limit) {
  const chunks = []
  let size = 0
  for await (const c of req) {
    size += c.length
    if (size > limit) throw new Refusal(413, 'too large')
    chunks.push(c)
  }
  return Buffer.concat(chunks)
}

function member(req) {
  const m = /^Bearer ([a-f0-9]{64})$/.exec(req.headers.authorization ?? '')
  const row = m && db.prepare('SELECT id, name FROM members WHERE token_hash = ?').get(hash(m[1]))
  if (!row) throw new Refusal(401, 'unauthorized')
  return row
}

// Only what the app shows, and only in the shape it expects: nothing free-form reaches other people's screens.
const ID = /^[a-z0-9][a-z0-9-]{0,63}$/
const int = (v, max) => Number.isInteger(v) && v >= 0 && v <= max
function slots(list, check) {
  if (!Array.isArray(list) || list.length > SLOTS) throw new Refusal(400, 'bad showcase')
  return list.map((x) => (x === null ? null : check(x)))
}
function validProfile(p) {
  if (typeof p !== 'object' || p === null) throw new Refusal(400, 'bad profile')
  const counts = ['achievementsHave', 'achievementsTotal', 'cardsHave', 'cardsTotal', 'prestige']
  for (const k of counts) if (!int(p[k], 100000)) throw new Refusal(400, `bad ${k}`)
  if (p.since != null && !/^\d{4}-\d{2}-\d{2}$/.test(p.since)) throw new Refusal(400, 'bad since')
  return {
    since: p.since ?? null,
    ...Object.fromEntries(counts.map((k) => [k, p[k]])),
    cards: slots(p.cards, (c) => {
      if (!ID.test(c?.id) || !['base', 'alt', 'alt2', 'scene'].includes(c.art) || !['normal', 'holo', 'gold'].includes(c.finish)) throw new Refusal(400, 'bad card')
      return { id: c.id, art: c.art, finish: c.finish }
    }),
    achievements: slots(p.achievements, (a) => {
      if (!ID.test(a?.id) || !(a.tier == null || int(a.tier, 5))) throw new Refusal(400, 'bad achievement')
      return { id: a.id, tier: a.tier ?? null }
    }),
  }
}

async function register(req) {
  const ip = req.headers['x-forwarded-for']?.split(',')[0].trim() ?? req.socket.remoteAddress
  if (!allow(ip)) throw new Refusal(429, 'too many tries')
  const key = req.headers['x-desktime-key']
  if (typeof key !== 'string' || !/^[A-Za-z0-9]{16,128}$/.test(key)) throw new Refusal(400, 'bad key')
  let who
  try {
    const r = await fetch(DESKTIME, { headers: { 'X-API-Key': key }, signal: AbortSignal.timeout(15000) })
    if (r.status === 401 || r.status === 403) throw new Refusal(403, 'key refused')
    if (!r.ok) throw new Refusal(502, 'desktime unavailable')
    who = await r.json()
  } catch (e) {
    throw e instanceof Refusal ? e : new Refusal(502, 'desktime unavailable')
  }
  // Identity comes from DeskTime, never from the app: nobody can register as somebody else.
  const email = String(who?.email ?? '').toLowerCase()
  if (!Number.isInteger(who?.id) || who.error || !email.endsWith('@' + ALLOWED_DOMAIN)) throw new Refusal(403, 'not a member')
  const token = randomBytes(32).toString('hex')
  const name = String(who.name ?? '').slice(0, 80)
  db.prepare(`INSERT INTO members (id, name, token_hash, updated) VALUES (?, ?, ?, ?)
              ON CONFLICT (id) DO UPDATE SET name = excluded.name, token_hash = excluded.token_hash`)
    .run(who.id, name, hash(token), now())
  return { token, id: who.id, name }
}

function listing() {
  return db.prepare('SELECT id, name, profile, photo_version, updated FROM members WHERE profile IS NOT NULL ORDER BY name COLLATE NOCASE')
    .all()
    .map((r) => ({ id: r.id, name: r.name, photo: r.photo_version, updated: r.updated, ...JSON.parse(r.profile) }))
}

async function route(req, res) {
  const url = new URL(req.url, 'http://x')
  const path = url.pathname.replace(/\/+$/, '')
  const send = (status, data, type = 'application/json') => {
    const out = Buffer.isBuffer(data) ? data : Buffer.from(data === undefined ? '' : JSON.stringify(data))
    res.writeHead(status, { 'Content-Type': type, 'Content-Length': out.length, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' })
    res.end(out)
  }

  if (req.method === 'GET' && path === '/health') return send(200, { ok: true })
  if (req.method === 'POST' && path === '/v1/register') return send(200, await register(req))

  const me = member(req)
  if (req.method === 'GET' && path === '/v1/profiles') return send(200, { me: me.id, profiles: listing() })
  if (req.method === 'PUT' && path === '/v1/profile') {
    let json
    try { json = JSON.parse((await body(req, MAX_JSON)).toString('utf8')) } catch (e) { throw e instanceof Refusal ? e : new Refusal(400, 'bad json') }
    db.prepare('UPDATE members SET profile = ?, updated = ? WHERE id = ?').run(JSON.stringify(validProfile(json)), now(), me.id)
    return send(200, { ok: true })
  }
  if (req.method === 'PUT' && path === '/v1/photo') {
    const jpg = await body(req, MAX_PHOTO)
    if (jpg.length < 4 || jpg[0] !== 0xff || jpg[1] !== 0xd8 || jpg[2] !== 0xff) throw new Refusal(400, 'not a jpeg')
    db.prepare('UPDATE members SET photo = ?, photo_version = photo_version + 1, updated = ? WHERE id = ?').run(jpg, now(), me.id)
    return send(200, { ok: true })
  }
  if (req.method === 'DELETE' && path === '/v1/photo') {
    db.prepare('UPDATE members SET photo = NULL, photo_version = 0, updated = ? WHERE id = ?').run(now(), me.id)
    return send(200, { ok: true })
  }
  // Leaving: everything of yours goes.
  if (req.method === 'DELETE' && path === '/v1/profile') {
    db.prepare('DELETE FROM members WHERE id = ?').run(me.id)
    return send(200, { ok: true })
  }
  const photo = /^\/v1\/photo\/(\d{1,12})$/.exec(path)
  if (req.method === 'GET' && photo) {
    const row = db.prepare('SELECT photo FROM members WHERE id = ?').get(Number(photo[1]))
    if (!row?.photo) throw new Refusal(404, 'no photo')
    return send(200, Buffer.from(row.photo), 'image/jpeg')
  }
  throw new Refusal(404, 'not found')
}

createServer((req, res) => {
  route(req, res).catch((e) => {
    const status = e instanceof Refusal ? e.status : 500
    if (status === 500) console.error(e)
    if (!res.headersSent) res.writeHead(status, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: e instanceof Refusal ? e.message : 'server error' }))
  })
}).listen(PORT, HOST, () => console.log(`community listening on ${HOST}:${PORT}`))
