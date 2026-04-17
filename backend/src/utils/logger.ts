import { writeFile } from 'fs/promises'
import { logPath } from './dirs'

export type LogLevel = 'debug' | 'info' | 'warn' | 'error'

class Logger {
  private moduleName: string

  constructor(moduleName: string) {
    this.moduleName = moduleName
  }

  private formatTimestamp(): string {
    const now = new Date()
    const beijing = new Date(now.getTime() + 8 * 60 * 60 * 1000)

    const year = beijing.getUTCFullYear()
    const month = String(beijing.getUTCMonth() + 1).padStart(2, '0')
    const day = String(beijing.getUTCDate()).padStart(2, '0')
    const hours = String(beijing.getUTCHours()).padStart(2, '0')
    const minutes = String(beijing.getUTCMinutes()).padStart(2, '0')
    const seconds = String(beijing.getUTCSeconds()).padStart(2, '0')
    const milliseconds = String(beijing.getUTCMilliseconds()).padStart(3, '0')

    return `${year}-${month}-${day}T${hours}:${minutes}:${seconds}.${milliseconds}+08:00`
  }

  private formatLogMessage(level: LogLevel, message: string, error?: unknown): string {
    const timestamp = this.formatTimestamp()
    const errorStr = error ? `: ${String(error)}` : ''
    return `[${timestamp}] [${level.toUpperCase()}] [${this.moduleName}] ${message}${errorStr}\n`
  }

  private async writeToFile(level: LogLevel, message: string, error?: unknown): Promise<void> {
    try {
      const appLogPath = logPath()
      const logMessage = this.formatLogMessage(level, message, error)
      await writeFile(appLogPath, logMessage, { flag: 'a' })
    } catch (logError) {
      console.error(`[Logger] Failed to write to log file:`, logError)
      console.error(
        `[Logger] Original message: [${level.toUpperCase()}] [${this.moduleName}] ${message}`,
        error
      )
    }
  }

  private logToConsole(level: LogLevel, message: string, error?: unknown): void {
    const prefix = `[${this.moduleName}] ${message}`

    switch (level) {
      case 'debug':
        console.debug(prefix, error || '')
        break
      case 'info':
        console.log(prefix, error || '')
        break
      case 'warn':
        console.warn(prefix, error || '')
        break
      case 'error':
        console.error(prefix, error || '')
        break
    }
  }

  async debug(message: string, error?: unknown): Promise<void> {
    await this.writeToFile('debug', message, error)
    this.logToConsole('debug', message, error)
  }

  async info(message: string, error?: unknown): Promise<void> {
    await this.writeToFile('info', message, error)
    this.logToConsole('info', message, error)
  }

  async warn(message: string, error?: unknown): Promise<void> {
    await this.writeToFile('warn', message, error)
    this.logToConsole('warn', message, error)
  }

  async error(message: string, error?: unknown): Promise<void> {
    await this.writeToFile('error', message, error)
    this.logToConsole('error', message, error)
  }

  async log(message: string, error?: unknown): Promise<void> {
    if (error) {
      await this.error(message, error)
    } else {
      await this.info(message)
    }
  }
}

export const createLogger = (moduleName: string): Logger => {
  return new Logger(moduleName)
}

export const appLogger = createLogger('app')
export const floatingWindowLogger = createLogger('floating-window')
export const coreLogger = createLogger('mihomo-core')
export const apiLogger = createLogger('mihomo-api')
export const configLogger = createLogger('config')
export const systemLogger = createLogger('system')
export const trafficLogger = createLogger('traffic-monitor')
export const trayLogger = createLogger('tray')
export const initLogger = createLogger('init')
export const ipcLogger = createLogger('ipc')
export const proxyLogger = createLogger('sysproxy')
export const managerLogger = createLogger('manager')
export const factoryLogger = createLogger('factory')
export const overrideLogger = createLogger('override')
export const logger = appLogger
