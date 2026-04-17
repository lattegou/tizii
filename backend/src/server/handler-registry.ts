// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type RpcHandler = (...params: any[]) => unknown | Promise<unknown>

const handlers = new Map<string, RpcHandler>()

export function registerHandler(name: string, handler: RpcHandler): void {
  handlers.set(name, handler)
}

export function getHandler(name: string): RpcHandler | undefined {
  return handlers.get(name)
}

export function listHandlers(): string[] {
  return Array.from(handlers.keys())
}
