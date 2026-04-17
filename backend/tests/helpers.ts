import http from 'http'
import axios, { AxiosInstance } from 'axios'
import { createHttpApp } from '../src/server/http'
import { attachWsServer } from '../src/server/ws'

export const TEST_TOKEN = 'test-token-12345'

export interface TestServer {
  server: http.Server
  port: number
  token: string
  baseUrl: string
  wsUrl: string
  client: AxiosInstance
  close: () => Promise<void>
}

export async function createTestServer(token = TEST_TOKEN): Promise<TestServer> {
  const app = createHttpApp(token)
  const server = http.createServer(app)
  attachWsServer(server, token)

  return new Promise((resolve, reject) => {
    server.listen({ host: '127.0.0.1', port: 0 }, () => {
      const addr = server.address()
      if (!addr || typeof addr === 'string') {
        reject(new Error('Failed to get server address'))
        return
      }
      const port = addr.port
      const baseUrl = `http://127.0.0.1:${port}`
      resolve({
        server,
        port,
        token,
        baseUrl,
        wsUrl: `ws://127.0.0.1:${port}/ws`,
        client: axios.create({
          baseURL: baseUrl,
          headers: { Authorization: `Bearer ${token}` },
          validateStatus: () => true
        }),
        close: () => new Promise<void>((res) => server.close(() => res()))
      })
    })
    server.on('error', reject)
  })
}

export async function rpc(
  client: AxiosInstance,
  method: string,
  params: unknown[] = []
): Promise<{ status: number; data: Record<string, unknown> }> {
  const res = await client.post('/rpc', { method, params })
  return { status: res.status, data: res.data as Record<string, unknown> }
}
