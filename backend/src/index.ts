import http from 'http'
import { randomBytes } from 'crypto'
import { writeFile, chmod } from 'fs/promises'
import { existsSync } from 'fs'
import { createHttpApp } from './server/http'
import { attachWsServer } from './server/ws'
import { registerAllHandlers } from './server/handlers'
import { initBasic, init } from './utils/init'
import { initI18n } from './common/i18n'
import { getAppConfig, patchAppConfig } from './config'
import {
  startCore,
  initCoreWatcher,
  initAdminStatus,
  checkAdminRestartForTun,
  stopCore,
  cleanupCoreWatcher
} from './core/manager'
import { initProfileUpdater } from './core/profileUpdater'
import { initWebdavBackupScheduler } from './resolve/backup'
import { mihomoCoreDir } from './utils/dirs'
import { triggerSysProxy } from './sys/sysproxy'

type RuntimeInfo = {
  port: number
  token: string
}

function createToken(): string {
  return randomBytes(32).toString('hex')
}

async function writeRuntime(runtimeFile: string, info: RuntimeInfo): Promise<void> {
  await writeFile(runtimeFile, JSON.stringify(info))
  await chmod(runtimeFile, 0o600)
}

let shuttingDown = false

async function gracefulShutdown(): Promise<void> {
  if (shuttingDown) return
  shuttingDown = true

  try {
    cleanupCoreWatcher()
    await triggerSysProxy(false)
    await stopCore()
  } catch {
    // best-effort cleanup
  }
  process.exit(0)
}

async function start(): Promise<void> {
  const token = process.env.MIHOMO_TOKEN ?? createToken()
  const portEnv = process.env.MIHOMO_PORT ?? '0'
  const parsedPort = Number.parseInt(portEnv, 10)
  const port = Number.isNaN(parsedPort) ? 0 : parsedPort

  const sidecarDir = mihomoCoreDir()
  if (!existsSync(sidecarDir)) {
    console.error(`Sidecar directory not found: ${sidecarDir}. Backend cannot start.`)
    process.exit(1)
  }

  await initBasic()

  const appConfig = await getAppConfig()
  const envLang = process.env.MIHOMO_LANGUAGE
  const validLanguages = ['zh-CN', 'zh-TW', 'en-US', 'ru-RU', 'fa-IR'] as const
  type Language = (typeof validLanguages)[number]
  const isValidLang = (v: string): v is Language => validLanguages.includes(v as Language)
  const language: Language =
    appConfig.language ?? (envLang && isValidLang(envLang) ? envLang : 'en-US')
  if (!appConfig.language) {
    await patchAppConfig({ language })
  }
  await initI18n({ lng: language })

  await initAdminStatus()
  await init()

  registerAllHandlers()

  const app = createHttpApp(token)
  const server = http.createServer(app)
  attachWsServer(server, token)

  await new Promise<void>((resolve) => {
    server.listen({ host: '127.0.0.1', port }, () => resolve())
  })

  const address = server.address()
  if (!address || typeof address === 'string') {
    throw new Error('Failed to get server address')
  }

  const info: RuntimeInfo = { port: address.port, token }

  if (process.send) {
    process.send(info)
  }

  process.on('SIGTERM', gracefulShutdown)
  process.on('SIGINT', gracefulShutdown)

  try {
    initCoreWatcher()
    const startPromises = await startCore()
    if (startPromises.length > 0) {
      startPromises[0].then(async () => {
        await initProfileUpdater()
        await initWebdavBackupScheduler()
        await checkAdminRestartForTun()
      })
    }
  } catch (e) {
    console.error('Core start failed:', e)
  }

  const runtimeFile = process.env.MIHOMO_RUNTIME_FILE
  if (runtimeFile) {
    try {
      await writeRuntime(runtimeFile, info)
    } catch (error) {
      console.error('Failed to write runtime file', error)
    }
  }
}

start().catch((error) => {
  console.error('Backend failed to start', error)
  process.exit(1)
})
