import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import WebSocket from 'ws'
import { createTestServer, TestServer } from './helpers'
import { wsBroadcast } from '../src/server/ws'

let srv: TestServer
const openSockets: WebSocket[] = []

function connect(url: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    openSockets.push(ws)
    ws.on('open', () => resolve(ws))
    ws.on('error', reject)
  })
}

function waitForClose(ws: WebSocket): Promise<{ code: number; reason: string }> {
  return new Promise((resolve) => {
    ws.on('close', (code, reason) => {
      resolve({ code, reason: reason.toString() })
    })
  })
}

function waitForMessage(ws: WebSocket, timeoutMs = 3000): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timed out waiting for message')), timeoutMs)
    ws.once('message', (data) => {
      clearTimeout(timer)
      resolve(JSON.parse(data.toString()))
    })
  })
}

function collectMessages(ws: WebSocket, count: number, timeoutMs = 3000): Promise<unknown[]> {
  return new Promise((resolve, reject) => {
    const messages: unknown[] = []
    const timer = setTimeout(
      () => reject(new Error(`Timed out: got ${messages.length}/${count}`)),
      timeoutMs
    )
    ws.on('message', (data) => {
      messages.push(JSON.parse(data.toString()))
      if (messages.length === count) {
        clearTimeout(timer)
        resolve(messages)
      }
    })
  })
}

function expectNoMessage(ws: WebSocket, waitMs = 200): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.removeAllListeners('message')
      resolve()
    }, waitMs)
    ws.once('message', (data) => {
      clearTimeout(timer)
      reject(new Error(`Unexpected message: ${data.toString()}`))
    })
  })
}

function subscribe(ws: WebSocket, channels: string[]): void {
  ws.send(JSON.stringify({ action: 'subscribe', payload: { channels } }))
}

function unsubscribe(ws: WebSocket, channels: string[]): void {
  ws.send(JSON.stringify({ action: 'unsubscribe', payload: { channels } }))
}

beforeAll(async () => {
  srv = await createTestServer()
})

afterEach(() => {
  for (const ws of openSockets) {
    if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
      ws.close()
    }
  }
  openSockets.length = 0
})

afterAll(async () => {
  await srv.close()
})

describe('WebSocket Connection', () => {
  it('accepts connection with valid token in query', async () => {
    const ws = await connect(`${srv.wsUrl}?token=${srv.token}`)
    expect(ws.readyState).toBe(WebSocket.OPEN)
  })

  it('rejects connection without token', async () => {
    const ws = new WebSocket(srv.wsUrl)
    openSockets.push(ws)
    const { code } = await waitForClose(ws)
    expect(code).toBe(1008)
  })

  it('rejects connection with wrong token', async () => {
    const ws = new WebSocket(`${srv.wsUrl}?token=wrong`)
    openSockets.push(ws)
    const { code } = await waitForClose(ws)
    expect(code).toBe(1008)
  })
})

describe('WebSocket Subscription', () => {
  it('receives messages on subscribed channel', async () => {
    const ws = await connect(`${srv.wsUrl}?token=${srv.token}`)
    subscribe(ws, ['traffic'])

    await new Promise((r) => setTimeout(r, 50))

    const msgPromise = waitForMessage(ws)
    wsBroadcast({ type: 'traffic', data: { up: 100, down: 200 } })
    const msg = (await msgPromise) as { type: string; data: { up: number; down: number } }

    expect(msg.type).toBe('traffic')
    expect(msg.data.up).toBe(100)
    expect(msg.data.down).toBe(200)
  })

  it('does not receive messages on unsubscribed channel', async () => {
    const ws = await connect(`${srv.wsUrl}?token=${srv.token}`)
    subscribe(ws, ['traffic'])

    await new Promise((r) => setTimeout(r, 50))

    wsBroadcast({ type: 'logs', data: { level: 'info' } })
    await expectNoMessage(ws)
  })

  it('selective unsubscribe stops specific channel only', async () => {
    const ws = await connect(`${srv.wsUrl}?token=${srv.token}`)
    subscribe(ws, ['traffic', 'memory'])
    await new Promise((r) => setTimeout(r, 100))

    const initial = collectMessages(ws, 2)
    wsBroadcast({ type: 'traffic', data: { up: 1 } })
    wsBroadcast({ type: 'memory', data: { inuse: 1024 } })
    await initial

    unsubscribe(ws, ['traffic'])
    await new Promise((r) => setTimeout(r, 300))

    const memPromise = waitForMessage(ws)
    wsBroadcast({ type: 'memory', data: { inuse: 2048 } })
    const memMsg = (await memPromise) as { type: string }
    expect(memMsg.type).toBe('memory')

    wsBroadcast({ type: 'traffic', data: { up: 999 } })
    await expectNoMessage(ws, 500)
  })

  it('supports multiple channel subscriptions', async () => {
    const ws = await connect(`${srv.wsUrl}?token=${srv.token}`)
    subscribe(ws, ['traffic', 'memory', 'logs'])

    await new Promise((r) => setTimeout(r, 50))

    const msgsPromise = collectMessages(ws, 3)
    wsBroadcast({ type: 'traffic', data: { up: 1 } })
    wsBroadcast({ type: 'memory', data: { inuse: 1024 } })
    wsBroadcast({ type: 'logs', data: { level: 'info' } })

    const msgs = (await msgsPromise) as { type: string }[]
    const types = msgs.map((m) => m.type)
    expect(types).toContain('traffic')
    expect(types).toContain('memory')
    expect(types).toContain('logs')
  })
})

describe('WebSocket Broadcast', () => {
  it('delivers to multiple connected clients', async () => {
    const ws1 = await connect(`${srv.wsUrl}?token=${srv.token}`)
    const ws2 = await connect(`${srv.wsUrl}?token=${srv.token}`)
    subscribe(ws1, ['traffic'])
    subscribe(ws2, ['traffic'])

    await new Promise((r) => setTimeout(r, 50))

    const p1 = waitForMessage(ws1)
    const p2 = waitForMessage(ws2)
    wsBroadcast({ type: 'traffic', data: { up: 42 } })

    const [msg1, msg2] = (await Promise.all([p1, p2])) as { type: string }[]
    expect(msg1.type).toBe('traffic')
    expect(msg2.type).toBe('traffic')
  })

  it('only delivers to clients subscribed to the channel', async () => {
    const ws1 = await connect(`${srv.wsUrl}?token=${srv.token}`)
    const ws2 = await connect(`${srv.wsUrl}?token=${srv.token}`)
    subscribe(ws1, ['traffic'])
    subscribe(ws2, ['memory'])

    await new Promise((r) => setTimeout(r, 50))

    const msg1Promise = waitForMessage(ws1)
    wsBroadcast({ type: 'traffic', data: { up: 1 } })

    const msg1 = await msg1Promise
    expect(msg1).toBeDefined()

    await expectNoMessage(ws2)
  })

  it('handles broadcast with null data', async () => {
    const ws = await connect(`${srv.wsUrl}?token=${srv.token}`)
    subscribe(ws, ['config:app'])

    await new Promise((r) => setTimeout(r, 50))

    const msgPromise = waitForMessage(ws)
    wsBroadcast({ type: 'config:app', data: null })
    const msg = (await msgPromise) as { type: string; data: unknown }

    expect(msg.type).toBe('config:app')
    expect(msg.data).toBeNull()
  })
})
