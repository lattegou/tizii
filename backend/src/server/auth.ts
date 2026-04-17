import type { NextFunction, Request, Response } from 'express'

export function createAuthMiddleware(token: string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const auth = req.headers.authorization
    if (!auth || !auth.startsWith('Bearer ')) {
      res.status(401).json({ error: { message: 'Unauthorized' } })
      return
    }

    const provided = auth.slice('Bearer '.length)
    if (provided !== token) {
      res.status(401).json({ error: { message: 'Unauthorized' } })
      return
    }

    next()
  }
}
