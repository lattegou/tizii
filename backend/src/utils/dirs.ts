import { existsSync, mkdirSync } from 'fs'
import path from 'path'
import os from 'os'

export const homeDir = os.homedir()

function getDataDir(): string {
  const dir = process.env.MIHOMO_DATA_DIR
  if (!dir) throw new Error('MIHOMO_DATA_DIR environment variable is not set')
  return dir
}

function getResourcesDir(): string {
  const dir = process.env.MIHOMO_RESOURCES_DIR
  if (!dir) throw new Error('MIHOMO_RESOURCES_DIR environment variable is not set')
  return dir
}

export function dataDir(): string {
  return getDataDir()
}

export function taskDir(): string {
  const userDataDir = getDataDir()
  if (!existsSync(userDataDir)) {
    mkdirSync(userDataDir, { recursive: true })
  }

  const dir = path.join(userDataDir, 'tasks')
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true })
  }
  return dir
}

export function resourcesDir(): string {
  return getResourcesDir()
}

export function resourcesFilesDir(): string {
  return path.join(resourcesDir(), 'files')
}

export function themesDir(): string {
  return path.join(dataDir(), 'themes')
}

export function mihomoCoreDir(): string {
  return path.join(resourcesDir(), 'sidecar')
}

export function mihomoCorePath(core: string): string {
  if (core === 'mihomo-smart') {
    return path.join(mihomoCoreDir(), 'mihomo-smart')
  }
  return path.join(mihomoCoreDir(), core)
}

export function appConfigPath(): string {
  return path.join(dataDir(), 'config.yaml')
}

export function controledMihomoConfigPath(): string {
  return path.join(dataDir(), 'mihomo.yaml')
}

export function profileConfigPath(): string {
  return path.join(dataDir(), 'profile.yaml')
}

export function profilesDir(): string {
  return path.join(dataDir(), 'profiles')
}

export function profilePath(id: string): string {
  return path.join(profilesDir(), `${id}.yaml`)
}

export function overrideDir(): string {
  return path.join(dataDir(), 'override')
}

export function overrideConfigPath(): string {
  return path.join(dataDir(), 'override.yaml')
}

export function overridePath(id: string, ext: 'js' | 'yaml' | 'log'): string {
  return path.join(overrideDir(), `${id}.${ext}`)
}

export function mihomoWorkDir(): string {
  return path.join(dataDir(), 'work')
}

export function mihomoProfileWorkDir(id: string | undefined): string {
  return path.join(mihomoWorkDir(), id || 'default')
}

export function mihomoTestDir(): string {
  return path.join(dataDir(), 'test')
}

export function mihomoWorkConfigPath(id: string | undefined): string {
  if (id === 'work') {
    return path.join(mihomoWorkDir(), 'config.yaml')
  } else {
    return path.join(mihomoProfileWorkDir(id), 'config.yaml')
  }
}

export function logDir(): string {
  return path.join(dataDir(), 'logs')
}

export function logPath(): string {
  const date = new Date()
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  const name = `tizii-${year}-${month}-${day}`
  return path.join(logDir(), `${name}.log`)
}

export function coreLogPath(): string {
  const date = new Date()
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  const name = `core-${year}-${month}-${day}`
  return path.join(logDir(), `${name}.log`)
}

export function rulesDir(): string {
  return path.join(dataDir(), 'rules')
}

export function rulePath(id: string): string {
  return path.join(rulesDir(), `${id}.yaml`)
}

export function exePath(): string {
  return process.env.MIHOMO_EXE_PATH || ''
}

export function exeDir(): string {
  return path.dirname(exePath())
}
