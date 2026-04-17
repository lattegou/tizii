import { ChildProcess, execFile, spawn } from 'child_process'
import { randomInt } from 'crypto'
import { readFile, rm, writeFile } from 'fs/promises'
import { promisify } from 'util'
import path from 'path'
import { createWriteStream, existsSync } from 'fs'
import net from 'net'
import chokidar, { FSWatcher } from 'chokidar'
import i18next from 'i18next'
import { wsBroadcast } from '../server/ws'
import {
  getAppConfig,
  getControledMihomoConfig,
  patchControledMihomoConfig,
  manageSmartOverride
} from '../config'
import {
  dataDir,
  coreLogPath,
  mihomoCoreDir,
  mihomoCorePath,
  mihomoProfileWorkDir,
  mihomoTestDir,
  mihomoWorkConfigPath,
  mihomoWorkDir
} from '../utils/dirs'
import { uploadRuntimeConfig } from '../resolve/gistApi'
import { safeLogError } from '../utils/init'
import { managerLogger } from '../utils/logger'
import {
  startMihomoTraffic,
  startMihomoConnections,
  startMihomoLogs,
  startMihomoMemory,
  stopMihomoConnections,
  stopMihomoTraffic,
  stopMihomoLogs,
  stopMihomoMemory,
  patchMihomoConfig,
  getAxios
} from './mihomoApi'
import { generateProfile } from './factory'
import { cleanupSocketFile, waitForCoreReady } from './process'
import { setPublicDNS, recoverDNS } from './dns'

export {
  initAdminStatus,
  getSessionAdminStatus,
  checkAdminPrivileges,
  checkMihomoCorePermissions,
  checkHighPrivilegeCore,
  grantTunPermissions,
  requestTunPermissions,
  showErrorDialog,
  checkTunPermissions,
  manualGrantCorePermition
} from './permissions'

export { getDefaultDevice } from './dns'

const execFilePromise = promisify(execFile)
const ctlUnixParam = '-ext-ctl-unix'
const ctlTcpParam = '-ext-ctl'

let child: ChildProcess
let retry = 10
let isRestarting = false

export type MihomoControllerEndpoint =
  | { transport: 'unix'; socketPath: string }
  | { transport: 'tcp'; host: string; port: number }

let currentControllerEndpoint: MihomoControllerEndpoint = {
  transport: 'unix',
  socketPath: `/tmp/mihomo-party-${process.getuid?.() || 'unknown'}-${process.pid}.sock`
}

let coreWatcher: FSWatcher | null = null

export function initCoreWatcher(): void {
  if (coreWatcher) return

  coreWatcher = chokidar.watch(path.join(mihomoCoreDir(), 'meta-update'), {})
  coreWatcher.on('unlinkDir', async () => {
    await new Promise((resolve) => setTimeout(resolve, 3000))
    try {
      await stopCore(true)
      await startCore()
    } catch (e) {
      managerLogger.error(`Core start failed after self-update: ${e}`)
      wsBroadcast({
        type: 'core:error',
        data: { key: 'mihomo.error.coreStartFailed', message: `${e}` }
      })
    }
  })
}

export function cleanupCoreWatcher(): void {
  if (coreWatcher) {
    coreWatcher.close()
    coreWatcher = null
  }
}

export const getMihomoIpcPath = (): string => {
  const uid = process.getuid?.() || 'unknown'
  const processId = process.pid
  return `/tmp/mihomo-party-${uid}-${processId}.sock`
}

function shouldUseTcpController(): boolean {
  if (process.env.MIHOMO_CONTROLLER_TRANSPORT === 'tcp') return true
  if (process.env.MIHOMO_CONTROLLER_TRANSPORT === 'unix') return false
  return 'Bun' in globalThis
}

const CONTROLLER_PORT_MIN = 39000
const CONTROLLER_PORT_MAX = 58999
const CONTROLLER_PORT_PICK_ATTEMPTS = 30

function isValidTcpPort(port: number): boolean {
  return Number.isInteger(port) && port > 0 && port <= 65535
}

function pickRandomControllerPort(): number {
  try {
    return randomInt(CONTROLLER_PORT_MIN, CONTROLLER_PORT_MAX + 1)
  } catch {
    return (
      Math.floor(Math.random() * (CONTROLLER_PORT_MAX - CONTROLLER_PORT_MIN + 1)) +
      CONTROLLER_PORT_MIN
    )
  }
}

async function isPortAvailable(port: number): Promise<boolean> {
  return await new Promise((resolve) => {
    const tester = net.createServer()
    tester.once('error', () => resolve(false))
    tester.once('listening', () => {
      tester.close(() => resolve(true))
    })
    tester.listen(port, '127.0.0.1')
  })
}

async function resolveControllerPort(): Promise<number> {
  const fromEnv = Number.parseInt(process.env.MIHOMO_CONTROLLER_PORT ?? '', 10)
  if (isValidTcpPort(fromEnv)) {
    return fromEnv
  }

  const tried = new Set<number>()
  for (let i = 0; i < CONTROLLER_PORT_PICK_ATTEMPTS; i++) {
    const candidate = pickRandomControllerPort()
    if (tried.has(candidate)) continue
    tried.add(candidate)
    if (await isPortAvailable(candidate)) {
      return candidate
    }
  }

  // Fallback keeps behavior deterministic if random probing fails unexpectedly.
  return CONTROLLER_PORT_MIN + (process.pid % (CONTROLLER_PORT_MAX - CONTROLLER_PORT_MIN))
}

export function getMihomoControllerEndpoint(): MihomoControllerEndpoint {
  return currentControllerEndpoint
}

interface CoreConfig {
  corePath: string
  workDir: string
  endpoint: MihomoControllerEndpoint
  logLevel: LogLevel
  tunEnabled: boolean
  autoSetDNS: boolean
  cpuPriority: string
  detached: boolean
}

async function prepareCore(detached: boolean, skipStop = false): Promise<CoreConfig> {
  const [appConfig, mihomoConfig] = await Promise.all([getAppConfig(), getControledMihomoConfig()])

  const {
    core = 'mihomo',
    autoSetDNS = true,
    diffWorkDir = false,
    mihomoCpuPriority = 'PRIORITY_NORMAL'
  } = appConfig

  const { 'log-level': logLevel = 'info' as LogLevel, tun } = mihomoConfig

  const pidPath = path.join(dataDir(), 'core.pid')
  if (existsSync(pidPath)) {
    const pid = parseInt(await readFile(pidPath, 'utf-8'))
    try {
      process.kill(pid, 'SIGINT')
    } catch {
      // ignore
    } finally {
      await rm(pidPath)
    }
  }

  await manageSmartOverride()

  const current = await generateProfile()
  await checkProfile(current, core, diffWorkDir)
  if (!skipStop) {
    await stopCore()
  }
  await cleanupSocketFile()

  if (tun?.enable && autoSetDNS) {
    try {
      await setPublicDNS()
    } catch (error) {
      managerLogger.error('set dns failed', error)
    }
  }

  const endpoint = shouldUseTcpController()
    ? {
        transport: 'tcp' as const,
        host: '127.0.0.1',
        port: await resolveControllerPort()
      }
    : {
        transport: 'unix' as const,
        socketPath: getMihomoIpcPath()
      }
  currentControllerEndpoint = endpoint
  if (endpoint.transport === 'tcp') {
    managerLogger.info(`Using TCP controller: ${endpoint.host}:${endpoint.port}`)
  } else {
    managerLogger.info(`Using IPC path: ${endpoint.socketPath}`)
  }

  return {
    corePath: mihomoCorePath(core),
    workDir: diffWorkDir ? mihomoProfileWorkDir(current) : mihomoWorkDir(),
    endpoint,
    logLevel,
    tunEnabled: tun?.enable ?? false,
    autoSetDNS,
    cpuPriority: mihomoCpuPriority,
    detached
  }
}

function spawnCoreProcess(config: CoreConfig): ChildProcess {
  const { corePath, workDir, endpoint, detached } = config

  const stdout = createWriteStream(coreLogPath(), { flags: 'a' })
  const stderr = createWriteStream(coreLogPath(), { flags: 'a' })

  const controllerArgs =
    endpoint.transport === 'tcp'
      ? [ctlTcpParam, `${endpoint.host}:${endpoint.port}`]
      : [ctlUnixParam, endpoint.socketPath]

  const proc = spawn(corePath, ['-d', workDir, ...controllerArgs], {
    detached,
    stdio: detached ? 'ignore' : undefined
  })

  if (!detached) {
    proc.stdout?.pipe(stdout)
    proc.stderr?.pipe(stderr)
  }

  return proc
}

function setupCoreListeners(
  proc: ChildProcess,
  logLevel: LogLevel,
  resolve: (value: Promise<void>[]) => void,
  reject: (reason: unknown) => void
): void {
  proc.on('close', async (code, signal) => {
    managerLogger.info(`Core closed, code: ${code}, signal: ${signal}`)

    if (isRestarting) {
      managerLogger.info('Core closed during restart, skipping auto-restart')
      return
    }

    if (retry) {
      managerLogger.info('Try Restart Core')
      retry--
      await restartCore()
    } else {
      await stopCore()
    }
  })

  proc.stdout?.on('data', async (data) => {
    const str = data.toString()

    if (str.includes('configure tun interface: operation not permitted')) {
      patchControledMihomoConfig({ tun: { enable: false } })
      wsBroadcast({ type: 'config:mihomo', data: null })
      wsBroadcast({ type: 'tray:update', data: null })
      reject(i18next.t('tun.error.tunPermissionDenied'))
      return
    }

    const isControllerError =
      str.includes('External controller unix listen error') ||
      (str.includes('External controller') && str.includes('listen error'))

    if (isControllerError) {
      managerLogger.error('External controller listen error detected:', str)
      reject(i18next.t('mihomo.error.externalControllerListenError'))
      return
    }

    const isApiReady = str.includes('RESTful API')

    if (isApiReady) {
      resolve([
        new Promise((innerResolve) => {
          proc.stdout?.on('data', async (innerData) => {
            if (
              innerData
                .toString()
                .toLowerCase()
                .includes('start initial compatible provider default')
            ) {
              try {
                wsBroadcast({ type: 'groups:updated', data: null })
                wsBroadcast({ type: 'rules:updated', data: null })
                await uploadRuntimeConfig()
              } catch {
                // ignore
              }
              await patchMihomoConfig({ 'log-level': logLevel })
              innerResolve()
            }
          })
        })
      ])

      await waitForCoreReady()
      await getAxios(true)
      await startMihomoTraffic()
      await startMihomoConnections()
      await startMihomoLogs()
      await startMihomoMemory()
      retry = 10
    }
  })
}

export async function startCore(detached = false, skipStop = false): Promise<Promise<void>[]> {
  const config = await prepareCore(detached, skipStop)
  child = spawnCoreProcess(config)

  if (detached) {
    managerLogger.info(`Core process detached successfully, PID: ${child.pid}`)
    child.unref()
    return [new Promise(() => {})]
  }

  return new Promise((resolve, reject) => {
    setupCoreListeners(child, config.logLevel, resolve, reject)
  })
}

export async function stopCore(force = false): Promise<void> {
  try {
    if (!force) {
      await recoverDNS()
    }
  } catch (error) {
    managerLogger.error('recover dns failed', error)
  }

  if (child) {
    child.removeAllListeners()
    child.kill('SIGINT')
  }

  stopMihomoTraffic()
  stopMihomoConnections()
  stopMihomoLogs()
  stopMihomoMemory()

  try {
    await getAxios(true)
  } catch (error) {
    managerLogger.warn('Failed to refresh axios instance:', error)
  }

  await cleanupSocketFile()
}

export async function restartCore(): Promise<void> {
  if (isRestarting) {
    managerLogger.info('Core restart already in progress, skipping duplicate request')
    return
  }

  isRestarting = true
  let retryCount = 0
  const maxRetries = 3

  try {
    await stopCore()

    while (retryCount < maxRetries) {
      try {
        await startCore(false, true)
        return
      } catch (e) {
        retryCount++
        managerLogger.error(`restart core failed (attempt ${retryCount}/${maxRetries})`, e)

        if (retryCount >= maxRetries) {
          throw e
        }

        await new Promise((resolve) => setTimeout(resolve, 1000 * retryCount))
        await stopCore()
        await cleanupSocketFile()
      }
    }
  } finally {
    isRestarting = false
  }
}

export async function keepCoreAlive(): Promise<void> {
  try {
    await startCore(true)
    if (child?.pid) {
      await writeFile(path.join(dataDir(), 'core.pid'), child.pid.toString())
    }
  } catch (e) {
    safeLogError('mihomo.error.coreStartFailed', `${e}`)
  }
}

export async function quitWithoutCore(): Promise<void> {
  managerLogger.info('Starting lightweight mode')
  try {
    await startCore(true)
    if (child?.pid) {
      await writeFile(path.join(dataDir(), 'core.pid'), child.pid.toString())
      managerLogger.info(`Core started in lightweight mode with PID: ${child.pid}`)
    }
  } catch (e) {
    managerLogger.error('Failed to start core in lightweight mode:', e)
    safeLogError('mihomo.error.coreStartFailed', `${e}`)
  }

  managerLogger.info('Requesting client shutdown via lifecycle protocol')
  wsBroadcast({ type: 'lifecycle:request', data: { action: 'SHUTDOWN_CLIENT' } })
}

async function checkProfile(
  current: string | undefined,
  core: string = 'mihomo',
  diffWorkDir: boolean = false
): Promise<void> {
  const corePath = mihomoCorePath(core)

  try {
    await execFilePromise(corePath, [
      '-t',
      '-f',
      diffWorkDir ? mihomoWorkConfigPath(current) : mihomoWorkConfigPath('work'),
      '-d',
      mihomoTestDir()
    ])
  } catch (error) {
    managerLogger.error('Profile check failed', error)

    if (error instanceof Error && 'stdout' in error) {
      const { stdout, stderr } = error as { stdout: string; stderr?: string }
      managerLogger.info('Profile check stdout', stdout)
      managerLogger.info('Profile check stderr', stderr)

      const errorLines = stdout
        .split('\n')
        .filter((line) => line.includes('level=error') || line.includes('error'))
        .map((line) => {
          if (line.includes('level=error')) {
            return line.split('level=error')[1]?.trim() || line
          }
          return line.trim()
        })
        .filter((line) => line.length > 0)

      if (errorLines.length === 0) {
        const allLines = stdout.split('\n').filter((line) => line.trim().length > 0)
        throw new Error(`${i18next.t('mihomo.error.profileCheckFailed')}:\n${allLines.join('\n')}`)
      } else {
        throw new Error(
          `${i18next.t('mihomo.error.profileCheckFailed')}:\n${errorLines.join('\n')}`
        )
      }
    } else {
      throw new Error(`${i18next.t('mihomo.error.profileCheckFailed')}: ${error}`)
    }
  }
}

export async function checkAdminRestartForTun(): Promise<void> {
  const { checkAdminRestartForTun: check } = await import('./permissions')
  await check(restartCore)
}
