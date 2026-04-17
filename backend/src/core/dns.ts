import { exec } from 'child_process'
import { promisify } from 'util'
import axios from 'axios'
import { getAppConfig, patchAppConfig } from '../config'
import { isOnline } from '../utils/networkStatus'

const execPromise = promisify(exec)
const helperSocketPath = '/tmp/mihomo-party-helper.sock'
const macExecOpts = { env: { ...process.env, PATH: `/sbin:/usr/sbin:/usr/bin:${process.env.PATH}` } }

let setPublicDNSTimer: NodeJS.Timeout | null = null
let recoverDNSTimer: NodeJS.Timeout | null = null

export async function getDefaultDevice(): Promise<string> {
  const { stdout: deviceOut } = await execPromise(`route -n get default`, macExecOpts)
  let device = deviceOut.split('\n').find((s) => s.includes('interface:'))
  device = device?.trim().split(' ').slice(1).join(' ')
  if (!device) throw new Error('Get device failed')
  return device
}

export async function getDefaultService(): Promise<string> {
  const device = await getDefaultDevice()
  const { stdout: order } = await execPromise(`networksetup -listnetworkserviceorder`, macExecOpts)
  const block = order.split('\n\n').find((s) => s.includes(`Device: ${device}`))
  if (!block) throw new Error('Get networkservice failed')
  for (const line of block.split('\n')) {
    if (line.match(/^\(\d+\).*/)) {
      return line.trim().split(' ').slice(1).join(' ')
    }
  }
  throw new Error('Get service failed')
}

async function getOriginDNS(): Promise<void> {
  const service = await getDefaultService()
  const { stdout: dns } = await execPromise(`networksetup -getdnsservers "${service}"`, macExecOpts)
  if (dns.startsWith("There aren't any DNS Servers set on")) {
    await patchAppConfig({ originDNS: 'Empty' })
  } else {
    await patchAppConfig({ originDNS: dns.trim().replace(/\n/g, ' ') })
  }
}

async function setDNS(dns: string): Promise<void> {
  const service = await getDefaultService()
  try {
    await axios.post('http://localhost/dns', { service, dns }, { socketPath: helperSocketPath })
  } catch {
    const shell = `PATH=/sbin:/usr/sbin:/usr/bin:/bin networksetup -setdnsservers "${service}" ${dns}`
    const command = `do shell script "${shell}" with administrator privileges`
    await execPromise(`osascript -e '${command}'`, macExecOpts)
  }
}

export async function setPublicDNS(): Promise<void> {
  if (await isOnline()) {
    const { originDNS } = await getAppConfig()
    if (!originDNS) {
      await getOriginDNS()
      await setDNS('223.5.5.5')
    }
  } else {
    if (setPublicDNSTimer) clearTimeout(setPublicDNSTimer)
    setPublicDNSTimer = setTimeout(() => setPublicDNS(), 5000)
  }
}

export async function recoverDNS(): Promise<void> {
  if (await isOnline()) {
    const { originDNS } = await getAppConfig()
    if (originDNS) {
      await setDNS(originDNS)
      await patchAppConfig({ originDNS: undefined })
    }
  } else {
    if (recoverDNSTimer) clearTimeout(recoverDNSTimer)
    recoverDNSTimer = setTimeout(() => recoverDNS(), 5000)
  }
}
