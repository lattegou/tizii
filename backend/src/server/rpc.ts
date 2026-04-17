import express from 'express'
import { getHandler } from './handler-registry'

type RpcRequestBody = {
  method?: unknown
  params?: unknown
}

export function createRpcRouter(): express.Router {
  const router = express.Router()

  router.post('/rpc', async (req, res) => {
    const body = (req.body ?? {}) as RpcRequestBody
    const method = typeof body.method === 'string' ? body.method : null
    const params = Array.isArray(body.params) ? body.params : []

    if (!method) {
      res.status(400).json({ error: { message: 'Invalid method' } })
      return
    }

    const handler = getHandler(method)
    if (!handler) {
      res.status(404).json({ error: { message: 'Method not found' } })
      return
    }

    try {
      const result = await handler(...params)
      res.json({ result })
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Unknown error'
      res.json({ error: { message } })
    }
  })

  return router
}
