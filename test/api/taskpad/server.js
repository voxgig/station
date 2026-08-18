// Taskpad test API server. Plain CRUD, one apikey. No dependencies.
//
// The auth contract mirrors the generated SDK's default: empty prefix,
// so the credential rides `authorization` as-is.

const http = require('node:http')

const PORT = parseInt(process.env.TASKPAD_PORT || '8902', 10)
const APIKEY = process.env.TASKPAD_APIKEY || 'taskpad-key-101'

let seq = 2
const todos = {
  t1: { id: 't1', title: 'first', done: false, due: '2026-09-01' },
}

function send(res, status, body, headers) {
  const out = null == body ? '' : JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json',
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

  if (auth !== APIKEY) {
    return send(res, 401, { error: { code: 'no_auth', message: 'bad key' } })
  }

  const m = url.pathname.match(/^\/api\/todo(?:\/([^/]+))?$/)
  if (!m) {
    return send(res, 404, { error: { code: 'no_route', message: url.pathname } })
  }
  const id = m[1]

  try {
    if (!id && 'GET' === req.method) {
      return send(res, 200, Object.values(todos))
    }
    if (!id && 'POST' === req.method) {
      const body = await readBody(req)
      const nid = 't' + seq++
      todos[nid] = { ...body, id: nid }
      return send(res, 201, todos[nid])
    }
    if (id && !todos[id]) {
      return send(res, 404, { error: { code: 'no_todo', message: id } })
    }
    if (id && 'GET' === req.method) {
      return send(res, 200, todos[id])
    }
    if (id && 'PUT' === req.method) {
      const body = await readBody(req)
      todos[id] = { ...todos[id], ...body, id }
      return send(res, 200, todos[id])
    }
    if (id && 'DELETE' === req.method) {
      delete todos[id]
      return send(res, 204, null)
    }
    return send(res, 405, { error: { code: 'bad_method', message: req.method } })
  }
  catch (e) {
    return send(res, 400, { error: { code: 'bad_body', message: e.message } })
  }
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`taskpad listening on 127.0.0.1:${PORT}`)
})
