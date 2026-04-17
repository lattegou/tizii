import { exec } from 'child_process'
import { promisify } from 'util'
import { getAppConfig, patchControledMihomoConfig } from '../config'
import { patchMihomoConfig } from '../core/mihomoApi'
import { getDefaultDevice } from '../core/manager'
import { isOnline } from '../utils/networkStatus'
import { wsBroadcast } from '../server/ws'

export async function getCurrentSSID(): Promise<string | undefined> {
  try {
    return await getSSIDByAirport()
  } catch {
    return await getSSIDByNetworksetup()
  }
}

let lastSSID: string | undefined
let ssidCheckInterval: NodeJS.Timeout | null = null

export async function checkSSID(): Promise<void> {
  try {
    const { pauseSSID = [] } = await getAppConfig()
    if (pauseSSID.length === 0) return
    const currentSSID = await getCurrentSSID()
    if (currentSSID === lastSSID) return
    lastSSID = currentSSID
    if (currentSSID && pauseSSID.includes(currentSSID)) {
      await patchControledMihomoConfig({ mode: 'direct' })
      await patchMihomoConfig({ mode: 'direct' })
      wsBroadcast({ type: 'config:mihomo', data: null })
      wsBroadcast({ type: 'tray:update', data: null })
    } else {
      await patchControledMihomoConfig({ mode: 'rule' })
      await patchMihomoConfig({ mode: 'rule' })
      wsBroadcast({ type: 'config:mihomo', data: null })
      wsBroadcast({ type: 'tray:update', data: null })
    }
  } catch {
    // ignore
  }
}

export async function startSSIDCheck(): Promise<void> {
  if (ssidCheckInterval) {
    clearInterval(ssidCheckInterval)
  }
  await checkSSID()
  ssidCheckInterval = setInterval(checkSSID, 30000)
}

export function stopSSIDCheck(): void {
  if (ssidCheckInterval) {
    clearInterval(ssidCheckInterval)
    ssidCheckInterval = null
  }
}

async function getSSIDByAirport(): Promise<string | undefined> {
  const execPromise = promisify(exec)
  const { stdout } = await execPromise(
    '/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I'
  )
  if (stdout.trim().startsWith('WARNING')) {
    throw new Error('airport cannot be used')
  }
  for (const line of stdout.split('\n')) {
    if (line.trim().startsWith('SSID')) {
      return line.split(': ')[1].trim()
    }
  }
  return undefined
}

async function getSSIDByNetworksetup(): Promise<string | undefined> {
  const execPromise = promisify(exec)
  if (await isOnline()) {
    const service = await getDefaultDevice()
    const { stdout } = await execPromise(`/usr/sbin/networksetup -listpreferredwirelessnetworks ${service}`)
    if (stdout.trim().startsWith('Preferred networks on')) {
      if (stdout.split('\n').length > 1) {
        return stdout.split('\n')[1].trim()
      }
    }
  }
  return undefined
}
