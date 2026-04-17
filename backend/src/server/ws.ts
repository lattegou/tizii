import type { IncomingMessage } from 'http'
import { WebSocketServer, WebSocket } from 'ws'

type WsPayload = {
  type: string
  data?: unknown
}

type WsCommand =
  | { action: 'subscribe'; payload?: { channels?: string[] } }
  | { action: 'unsubscribe'; payload?: { channels?: string[] } }

const subscriptions = new Map<WebSocket, Set<string>>()

function getTokenFromRequest(req: IncomingMessage): string | null {
  const auth = req.headers.authorization
  if (auth && auth.startsWith('Bearer ')) {
    return auth.slice('Bearer '.length)
  }

  const url = req.url
  if (!url || !req.headers.host) return null
  const parsed = new URL(url, `http://${req.headers.host}`)
  return parsed.searchParams.get('token')
}

function isAuthorized(req: IncomingMessage, token: string): boolean {
  const provided = getTokenFromRequest(req)
  return provided === token
}

function applyCommand(socket: WebSocket, command: WsCommand): void {
  const current = subscriptions.get(socket) ?? new Set<string>()
  const channels = command.payload?.channels ?? []
  if (command.action === 'subscribe') {
    channels.forEach((ch) => current.add(ch))
  } else {
    channels.forEach((ch) => current.delete(ch))
  }
  subscriptions.set(socket, current)
}

export function attachWsServer(server: import('http').Server, token: string): WebSocketServer {
  const wss = new WebSocketServer({ server, path: '/ws' })

  wss.on('connection', (socket, req) => {
    if (!isAuthorized(req, token)) {
      socket.close(1008, 'Unauthorized')
      return
    }

    subscriptions.set(socket, new Set())

    socket.on('message', (data) => {
      try {
        const parsed = JSON.parse(data.toString()) as WsCommand
        if (parsed.action === 'subscribe' || parsed.action === 'unsubscribe') {
          applyCommand(socket, parsed)
        }
      } catch {
        return
      }
    })

    socket.on('close', () => {
      subscriptions.delete(socket)
    })
  })

  return wss
}

export function wsBroadcast(payload: WsPayload): void {
  const message = JSON.stringify(payload)
  for (const [socket, channels] of subscriptions.entries()) {
    if (socket.readyState !== WebSocket.OPEN) continue
    if (channels.size === 0 || channels.has(payload.type)) {
      socket.send(message)
    }
  }
}
