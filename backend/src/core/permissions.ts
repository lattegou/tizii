import { execFile } from 'child_process'
import { promisify } from 'util'
import { stat } from 'fs/promises'
import path from 'path'
import { getAppConfig, patchControledMihomoConfig } from '../config'
import { mihomoCorePath, mihomoCoreDir } from '../utils/dirs'
import { managerLogger } from '../utils/logger'
import { wsBroadcast } from '../server/ws'

const execFilePromise = promisify(execFile)

const ALLOWED_CORES = ['mihomo', 'mihomo-alpha', 'mihomo-smart'] as const
type AllowedCore = (typeof ALLOWED_CORES)[number]

export function isValidCoreName(core: string): core is AllowedCore {
  return ALLOWED_CORES.includes(core as AllowedCore)
}

export function validateCorePath(corePath: string): void {
  if (corePath.includes('..')) {
    throw new Error('Invalid core path: directory traversal detected')
  }

  const dangerousChars = /[;&|`$(){}[\]<>'"\\]/
  if (dangerousChars.test(path.basename(corePath))) {
    throw new Error('Invalid core path: contains dangerous characters')
  }

  const normalizedPath = path.normalize(path.resolve(corePath))
  const expectedDir = path.normalize(path.resolve(mihomoCoreDir()))

  if (!normalizedPath.startsWith(expectedDir + path.sep) && normalizedPath !== expectedDir) {
    throw new Error('Invalid core path: not in expected directory')
  }
}

function shellEscape(arg: string): string {
  return "'" + arg.replace(/'/g, "'\\''") + "'"
}

let sessionAdminStatus: boolean | null = null

export async function initAdminStatus(): Promise<void> {
  if (sessionAdminStatus === null) {
    sessionAdminStatus = true
  }
}

export function getSessionAdminStatus(): boolean {
  return sessionAdminStatus ?? true
}

export async function checkAdminPrivileges(): Promise<boolean> {
  return true
}

export async function checkMihomoCorePermissions(): Promise<boolean> {
  const { core = 'mihomo' } = await getAppConfig()
  const corePath = mihomoCorePath(core)

  try {
    const stats = await stat(corePath)
    return (stats.mode & 0o4000) !== 0 && stats.uid === 0
  } catch {
    return false
  }
}

export async function checkHighPrivilegeCore(): Promise<boolean> {
  return false
}

export async function grantTunPermissions(): Promise<void> {
  const { core = 'mihomo' } = await getAppConfig()

  if (!isValidCoreName(core)) {
    throw new Error(`Invalid core name: ${core}. Allowed values: ${ALLOWED_CORES.join(', ')}`)
  }

  const corePath = mihomoCorePath(core)
  validateCorePath(corePath)

  const escapedPath = shellEscape(corePath)
  const script = `do shell script "/usr/sbin/chown root:admin ${escapedPath} && /bin/chmod +sx ${escapedPath}" with administrator privileges`
  await execFilePromise('/usr/bin/osascript', ['-e', script])
}

export async function restartAsAdmin(forTun: boolean = true): Promise<void> {
  if (forTun) {
    throw new Error('restartAsAdmin is not supported on macOS')
  }
  throw new Error('restartAsAdmin is not supported on macOS')
}

export async function requestTunPermissions(): Promise<void> {
  const hasPermissions = await checkMihomoCorePermissions()
  if (!hasPermissions) {
    await grantTunPermissions()
  }
}

export async function showErrorDialog(title: string, message: string): Promise<void> {
  managerLogger.error(`[ErrorDialog] ${title}: ${message}`)
  wsBroadcast({ type: 'core:error', data: { key: title, message } })
}

export async function validateTunPermissionsOnStartup(
  _restartCore: () => Promise<void>
): Promise<void> {
  const { getControledMihomoConfig } = await import('../config')
  const { tun } = await getControledMihomoConfig()

  if (!tun?.enable) {
    return
  }

  const hasPermissions = await checkMihomoCorePermissions()

  if (!hasPermissions) {
    managerLogger.warn(
      'TUN is enabled but insufficient permissions detected, auto-disabling TUN...'
    )
    await patchControledMihomoConfig({ tun: { enable: false } })

    wsBroadcast({ type: 'config:mihomo', data: null })
    wsBroadcast({ type: 'tray:update', data: null })

    managerLogger.info('TUN auto-disabled due to insufficient permissions on startup')
  } else {
    managerLogger.info('TUN permissions validated successfully')
  }
}

export async function checkAdminRestartForTun(restartCore: () => Promise<void>): Promise<void> {
  await validateTunPermissionsOnStartup(restartCore)
}

export function checkTunPermissions(): Promise<boolean> {
  return checkMihomoCorePermissions()
}

export function manualGrantCorePermition(): Promise<void> {
  return grantTunPermissions()
}
