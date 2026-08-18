// Gnarly Pets test API server. Deliberately awkward, one behavior per
// station design claim. No dependencies.
//
//  - 401 responses ECHO the presented credential in the error envelope
//    (the §7/§15 redaction case: an upstream leaking a key back).
//  - GET /api/pet/redirect-me answers 302 to another host (the §8.2
//    redirect-policy case).
//  - Every response carries several sizable Set-Cookie headers (the
//    §8.2 per-header metadata case).
//  - list paginates via ?page=&size= and reports totals in headers.
//  - Errors use an envelope: { error: { code, message } }.

const http = require('node:http')

const PORT = parseInt(process.env.GNARLY_PETS_PORT || '8903', 10)
const APIKEY = process.env.GNARLY_PETS_APIKEY || 'gnarly-pet-key-3'

let seq = 3
const pets = {
  p1: { id: 'p1', name: 'Grendel', species: 'cat', grumpy: true },
  p2: { id: 'p2', name: 'Blob', species: 'axolotl', grumpy: false },
}
const visits = {
  p1: [{ id: 'v1', reason: 'claws', when: '2026-08-01' }],
}

const FAT = 'x'.repeat(512)
function cookies() {
  return [
    `gp_session=${FAT}; Path=/; HttpOnly`,
    `gp_pref=${FAT}; Path=/`,
    `gp_track=${FAT}; Path=/; SameSite=Lax`,
  ]
}

function send(res, status, body, headers) {
  const out = null == body ? '' : JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json',
    'set-cookie': cookies(),
    ...headers,
  })
  res.end(out)
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = ''
    req.on('data', (c) => (data += c))
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}) }
      catch (e) { reject(e) }
    })
    req.on('error', reject)
  })
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  const auth = req.headers['authorization']

  if (auth !== 'Bearer ' + APIKEY) {
    // Deliberate: the presented credential comes back in the body.
    return send(res, 401, {
      error: { code: 'no_auth', message: `bad key '${auth || ''}'` },
    })
  }

  if ('/api/pet/redirect-me' === url.pathname) {
    return send(res, 302, null, { location: 'http://offsite.example.com/pet' })
  }

  let m = url.pathname.match(/^\/api\/pet\/([^/]+)\/visit(?:\/([^/]+))?$/)
  if (m) {
    const [, petId, visitId] = m
    if (!pets[petId]) {
      return send(res, 404, { error: { code: 'no_pet', message: petId } })
    }
    const list = visits[petId] || (visits[petId] = [])
    try {
      if (!visitId && 'GET' === req.method) return send(res, 200, list)
      if (!visitId && 'POST' === req.method) {
        const body = await readBody(req)
        const v = { ...body, id: 'v' + seq++ }
        list.push(v)
        return send(res, 201, v)
      }
      const v = list.find((x) => x.id === visitId)
      if (!v) return send(res, 404, { error: { code: 'no_visit', message: visitId } })
      if ('GET' === req.method) return send(res, 200, v)
      return send(res, 405, { error: { code: 'bad_method', message: req.method } })
    }
    catch (e) {
      return send(res, 400, { error: { code: 'bad_body', message: e.message } })
    }
  }

  m = url.pathname.match(/^\/api\/pet(?:\/([^/]+))?$/)
  if (!m) {
    return send(res, 404, { error: { code: 'no_route', message: url.pathname } })
  }
  const id = m[1]

  try {
    if (!id && 'GET' === req.method) {
      const page = parseInt(url.searchParams.get('page') || '0', 10)
      const size = parseInt(url.searchParams.get('size') || '10', 10)
      const all = Object.values(pets)
      return send(res, 200, all.slice(page * size, (page + 1) * size), {
        'x-total-count': String(all.length),
        'x-page': String(page),
      })
    }
    if (!id && 'POST' === req.method) {
      const body = await readBody(req)
      const nid = 'p' + seq++
      pets[nid] = { ...body, id: nid }
      return send(res, 201, pets[nid])
    }
    if (id && !pets[id]) {
      return send(res, 404, { error: { code: 'no_pet', message: id } })
    }
    if (id && 'GET' === req.method) return send(res, 200, pets[id])
    if (id && 'PUT' === req.method) {
      const body = await readBody(req)
      pets[id] = { ...pets[id], ...body, id }
      return send(res, 200, pets[id])
    }
    if (id && 'DELETE' === req.method) {
      delete pets[id]
      return send(res, 204, null)
    }
    return send(res, 405, { error: { code: 'bad_method', message: req.method } })
  }
  catch (e) {
    return send(res, 400, { error: { code: 'bad_body', message: e.message } })
  }
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`gnarly-pets listening on 127.0.0.1:${PORT}`)
})
