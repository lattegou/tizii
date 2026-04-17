import { rm } from 'fs/promises'
import { existsSync } from 'fs'
import { managerLogger } from '../utils/logger'
import { getAxios } from './mihomoApi'

const CORE_READY_MAX_RETRIES = 30
const CORE_READY_RETRY_INTERVAL_MS = 500

export async function cleanupSocketFile(): Promise<void> {
  await cleanupUnixSockets()
}

export async function cleanupUnixSockets(): Promise<void> {
  try {
    const socketPaths = [
      '/tmp/mihomo-party.sock',
      '/tmp/mihomo-party-admin.sock',
      `/tmp/mihomo-party-${process.getuid?.() || 'user'}.sock`
    ]

    for (const socketPath of socketPaths) {
      try {
        if (existsSync(socketPath)) {
          await rm(socketPath)
          managerLogger.info(`Cleaned up socket file: ${socketPath}`)
        }
      } catch (error: unknown) {
        const err = error as NodeJS.ErrnoException
        if (err?.code === 'EACCES') {
          managerLogger.warn(
            `Cannot cleanup socket ${socketPath} (permission denied, try: sudo rm ${socketPath})`
          )
        } else {
          managerLogger.warn(`Failed to cleanup socket file ${socketPath}:`, error)
        }
      }
    }
  } catch (error) {
    managerLogger.error('Unix socket cleanup failed:', error)
  }
}

export async function waitForCoreReady(): Promise<void> {
  for (let i = 0; i < CORE_READY_MAX_RETRIES; i++) {
    try {
      const axios = await getAxios(true)
      await axios.get('/')
      managerLogger.info(
        `Core ready after ${i + 1} attempts (${(i + 1) * CORE_READY_RETRY_INTERVAL_MS}ms)`
      )
      return
    } catch {
      if (i === 0) {
        managerLogger.info('Waiting for core to be ready...')
      }

      if (i === CORE_READY_MAX_RETRIES - 1) {
        managerLogger.warn(
          `Core not ready after ${CORE_READY_MAX_RETRIES} attempts, proceeding anyway`
        )
        return
      }

      await new Promise((resolve) => setTimeout(resolve, CORE_READY_RETRY_INTERVAL_MS))
    }
  }
}
