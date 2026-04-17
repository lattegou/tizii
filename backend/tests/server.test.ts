import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import axios from 'axios'
import { registerHandler } from '../src/server/handler-registry'
import { createTestServer, rpc, TestServer } from './helpers'

let srv: TestServer

beforeAll(async () => {
  registerHandler('echo', (...args: unknown[]) => args)
  registerHandler('add', (a: number, b: number) => a + b)
  registerHandler('greet', (name: string) => `hello ${name}`)
  registerHandler('throws', () => {
    throw new Error('intentional error')
  })
  registerHandler('asyncThrows', async () => {
    throw new Error('async error')
  })
  registerHandler('returnsNull', () => null)
  registerHandler('returnsUndefined', () => undefined)

  srv = await createTestServer()
})

afterAll(async () => {
  await srv.close()
})

describe('Auth Middleware', () => {
  it('rejects request without Authorization header', async () => {
    const noAuthClient = axios.create({
      baseURL: srv.baseUrl,
      validateStatus: () => true
    })
    const res = await noAuthClient.post('/rpc', { method: 'echo', params: [] })
    expect(res.status).toBe(401)
    expect(res.data.error.message).toBe('Unauthorized')
  })

  it('rejects request with wrong token', async () => {
    const badClient = axios.create({
      baseURL: srv.baseUrl,
      headers: { Authorization: 'Bearer wrong-token' },
      validateStatus: () => true
    })
    const res = await badClient.post('/rpc', { method: 'echo', params: [] })
    expect(res.status).toBe(401)
  })

  it('rejects request without Bearer prefix', async () => {
    const badClient = axios.create({
      baseURL: srv.baseUrl,
      headers: { Authorization: srv.token },
      validateStatus: () => true
    })
    const res = await badClient.post('/rpc', { method: 'echo', params: [] })
    expect(res.status).toBe(401)
  })

  it('accepts request with correct token', async () => {
    const { status } = await rpc(srv.client, 'echo', ['test'])
    expect(status).toBe(200)
  })
})

describe('RPC Dispatcher', () => {
  it('returns 400 for missing method', async () => {
    const res = await srv.client.post('/rpc', { params: [] })
    expect(res.status).toBe(400)
    expect(res.data.error.message).toBe('Invalid method')
  })

  it('returns 400 for non-string method', async () => {
    const res = await srv.client.post('/rpc', { method: 123, params: [] })
    expect(res.status).toBe(400)
  })

  it('returns 404 for unknown method', async () => {
    const { status, data } = await rpc(srv.client, 'nonexistent')
    expect(status).toBe(404)
    expect(data.error).toBeDefined()
  })

  it('calls handler and returns result', async () => {
    const { status, data } = await rpc(srv.client, 'add', [3, 7])
    expect(status).toBe(200)
    expect(data.result).toBe(10)
  })

  it('passes params correctly', async () => {
    const { data } = await rpc(srv.client, 'echo', ['a', 'b', 'c'])
    expect(data.result).toEqual(['a', 'b', 'c'])
  })

  it('handles handler with string param', async () => {
    const { data } = await rpc(srv.client, 'greet', ['world'])
    expect(data.result).toBe('hello world')
  })

  it('handles empty params array', async () => {
    const { data } = await rpc(srv.client, 'echo')
    expect(data.result).toEqual([])
  })

  it('treats missing params as empty array', async () => {
    const res = await srv.client.post('/rpc', { method: 'echo' })
    expect(res.status).toBe(200)
    expect(res.data.result).toEqual([])
  })

  it('returns error when handler throws', async () => {
    const { status, data } = await rpc(srv.client, 'throws')
    expect(status).toBe(200)
    expect(data.error).toBeDefined()
    expect((data.error as { message: string }).message).toBe('intentional error')
    expect(data.result).toBeUndefined()
  })

  it('returns error when async handler throws', async () => {
    const { data } = await rpc(srv.client, 'asyncThrows')
    expect(data.error).toBeDefined()
    expect((data.error as { message: string }).message).toBe('async error')
  })

  it('handles handler returning null', async () => {
    const { data } = await rpc(srv.client, 'returnsNull')
    expect(data.result).toBeNull()
  })

  it('handles handler returning undefined (JSON omits undefined)', async () => {
    const { status, data } = await rpc(srv.client, 'returnsUndefined')
    expect(status).toBe(200)
    expect(data.error).toBeUndefined()
  })
})
