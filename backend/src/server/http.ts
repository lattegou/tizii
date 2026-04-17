import type { NextFunction, Request, Response } from 'express'
import express from 'express'
import { createAuthMiddleware } from './auth'
import { createRpcRouter } from './rpc'

function corsMiddleware(req: Request, res: Response, next: NextFunction): void {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization')

  if (req.method === 'OPTIONS') {
    res.status(204).end()
    return
  }
  next()
}

export function createHttpApp(token: string): express.Express {
  const app = express()
  app.use(corsMiddleware)
  app.use(express.json({ limit: '50mb' }))
  app.use(createAuthMiddleware(token))
  app.use(createRpcRouter())
  return app
}
