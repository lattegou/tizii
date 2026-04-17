import { promisify } from 'util'
import { exec, execFile } from 'child_process'
import fs from 'fs'
import axios from 'axios'
import { getAppConfig, getControledMihomoConfig } from '../config'
import { pacPort, startPacServer, stopPacServer } from '../resolve/server'
import { proxyLogger } from '../utils/logger'
import { isOnline } from '../utils/networkStatus'
import { getDefaultService } from '../core/dns'

const execPromise = promisify(exec)
const execFilePromise = promisify(execFile)

let triggerSysProxyTimer: NodeJS.Timeout | null = null
const helperSocketPath = '/tmp/mihomo-party-helper.sock'
const helperPlistPath = '/Library/LaunchDaemons/party.mihomo.helper.plist'

const defaultBypass: string[] = [
  '127.0.0.1',
  '192.168.0.0/16',
  '10.0.0.0/8',
  '172.16.0.0/12',
  'localhost',
  '*.local',
  '*.crashlytics.com',
  '<local>'
]

export async function triggerSysProxy(enable: boolean): Promise<void> {
  if (await isOnline()) {
    if (enable) {
      await disableSysProxy()
      await enableSysProxy()
    } else {
      await disableSysProxy()
    }
  } else {
    if (triggerSysProxyTimer) clearTimeout(triggerSysProxyTimer)
    triggerSysProxyTimer = setTimeout(() => triggerSysProxy(enable), 5000)
  }
}

function isHelperAvailable(): boolean {
  return isSocketFileExists() || fs.existsSync(helperPlistPath)
}

async function enableSysProxy(): Promise<void> {
  await startPacServer()
  const { sysProxy } = await getAppConfig()
  const { mode, host, bypass = defaultBypass } = sysProxy
  const { 'mixed-port': port = 7890 } = await getControledMihomoConfig()
  const proxyHost = host || '127.0.0.1'

  if (isHelperAvailable()) {
    try {
      if (mode === 'auto') {
        await helperRequest(() =>
          axios.post(
            'http://localhost/pac',
            { url: `http://${proxyHost}:${pacPort}/pac` },
            { socketPath: helperSocketPath }
          )
        )
      } else {
        await helperRequest(() =>
          axios.post(
            'http://localhost/global',
            { host: proxyHost, port: port.toString(), bypass: bypass.join(',') },
            { socketPath: helperSocketPath }
          )
        )
      }
      return
    } catch (error) {
      await proxyLogger.warn('Helper request failed, falling back to networksetup', error)
    }
  } else {
    await proxyLogger.info('Helper not available, using networksetup directly')
  }

  const service = await getDefaultService()
  const argsList: string[][] = []
  if (mode === 'auto') {
    argsList.push(['-setautoproxyurl', service, `http://${proxyHost}:${pacPort}/pac`])
    argsList.push(['-setautoproxystate', service, 'on'])
  } else {
    argsList.push(['-setwebproxy', service, proxyHost, String(port)])
    argsList.push(['-setsecurewebproxy', service, proxyHost, String(port)])
    argsList.push(['-setwebproxystate', service, 'on'])
    argsList.push(['-setsecurewebproxystate', service, 'on'])
    argsList.push(['-setproxybypassdomains', service, ...bypass])
  }
  await networkSetupBatch(argsList)
}

async function disableSysProxy(): Promise<void> {
  await stopPacServer()

  if (isHelperAvailable()) {
    try {
      await helperRequest(() => axios.get('http://localhost/off', { socketPath: helperSocketPath }))
      return
    } catch (error) {
      await proxyLogger.warn('Helper request failed for disable, falling back to networksetup', error)
    }
  } else {
    await proxyLogger.info('Helper not available for disable, using networksetup directly')
  }

  const service = await getDefaultService()
  await networkSetupBatch([
    ['-setwebproxystate', service, 'off'],
    ['-setsecurewebproxystate', service, 'off'],
    ['-setautoproxystate', service, 'off'],
    ['-setsocksfirewallproxystate', service, 'off']
  ])
}

async function networkSetupBatch(argsList: string[][]): Promise<void> {
  try {
    for (const args of argsList) {
      await execFilePromise('/usr/sbin/networksetup', args)
    }
  } catch {
    const shellEsc = (s: string): string => "'" + s.replace(/'/g, "'\\''") + "'"
    const commands = argsList
      .map((args) => `/usr/sbin/networksetup ${args.map(shellEsc).join(' ')}`)
      .join(' && ')
    const escaped = commands.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
    const script = `do shell script "${escaped}" with administrator privileges`
    await execFilePromise('/usr/bin/osascript', ['-e', script])
  }
}

function isSocketFileExists(): boolean {
  try {
    return fs.existsSync(helperSocketPath)
  } catch {
    return false
  }
}

async function isHelperRunning(): Promise<boolean> {
  try {
    const { stdout } = await execPromise('/usr/bin/pgrep -f party.mihomo.helper')
    return stdout.trim().length > 0
  } catch {
    return false
  }
}

async function startHelperService(): Promise<void> {
  const shell = `/bin/launchctl kickstart -k system/party.mihomo.helper`
  const command = `do shell script "${shell}" with administrator privileges`
  await execPromise(`/usr/bin/osascript -e '${command}'`)
  await new Promise((resolve) => setTimeout(resolve, 1500))
}

async function requestSocketRecreation(): Promise<void> {
  try {
    const shell = `/usr/bin/pkill -USR1 -f party.mihomo.helper`
    const command = `do shell script "${shell}" with administrator privileges`
    await execPromise(`/usr/bin/osascript -e '${command}'`)
    await new Promise((resolve) => setTimeout(resolve, 1000))
  } catch (error) {
    await proxyLogger.error('Failed to send signal to helper', error)
    throw error
  }
}

async function helperRequest(requestFn: () => Promise<unknown>, maxRetries = 2): Promise<unknown> {
  let lastError: Error | null = null

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await requestFn()
    } catch (error) {
      lastError = error as Error
      const errCode = (error as NodeJS.ErrnoException).code
      const errMsg = (error as Error).message || ''

      if (
        attempt < maxRetries &&
        (errCode === 'ECONNREFUSED' ||
          errCode === 'ENOENT' ||
          errMsg.includes('connect ECONNREFUSED') ||
          errMsg.includes('ENOENT'))
      ) {
        await proxyLogger.info(
          `Helper request failed (attempt ${attempt + 1}/${maxRetries + 1}), checking helper status...`
        )

        const helperRunning = await isHelperRunning()
        const socketExists = isSocketFileExists()

        if (!helperRunning) {
          if (fs.existsSync(helperPlistPath)) {
            await proxyLogger.info('Helper process not running, starting service...')
            try {
              await startHelperService()
              await proxyLogger.info('Helper service started, retrying...')
              continue
            } catch (startError) {
              await proxyLogger.warn('Failed to start helper service', startError)
            }
          } else {
            await proxyLogger.info('Helper service not registered in launchd, skipping start')
          }
        } else if (!socketExists) {
          await proxyLogger.info('Socket file missing but helper running, requesting recreation...')
          try {
            await requestSocketRecreation()
            await proxyLogger.info('Socket recreation requested, retrying...')
            continue
          } catch (signalError) {
            await proxyLogger.warn('Failed to request socket recreation', signalError)
          }
        }
      }

      if (attempt === maxRetries) {
        throw lastError
      }
    }
  }

  throw lastError
}
