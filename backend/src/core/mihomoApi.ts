import axios, { AxiosInstance } from 'axios'
import WebSocket from 'ws'
import { getAppConfig, getControledMihomoConfig } from '../config'
import { wsBroadcast } from '../server/ws'
import { calcTraffic } from '../utils/calc'
import { createLogger } from '../utils/logger'
import { getRuntimeConfig } from './factory'
import { getMihomoControllerEndpoint } from './manager'

const mihomoApiLogger = createLogger('MihomoApi')

let axiosIns: AxiosInstance | null = null
let currentControllerKey: string = ''
let mihomoTrafficWs: WebSocket | null = null
let trafficRetry = 10
let mihomoMemoryWs: WebSocket | null = null
let memoryRetry = 10
let mihomoLogsWs: WebSocket | null = null
let logsRetry = 10
let mihomoConnectionsWs: WebSocket | null = null
let connectionsRetry = 10

const MAX_RETRY = 10

function getControllerKey(): string {
  const endpoint = getMihomoControllerEndpoint()
  if (endpoint.transport === 'tcp') {
    return `tcp:${endpoint.host}:${endpoint.port}`
  }
  return `unix:${endpoint.socketPath}`
}

function buildWsUrl(pathname: string): string {
  const endpoint = getMihomoControllerEndpoint()
  if (endpoint.transport === 'tcp') {
    return `ws://${endpoint.host}:${endpoint.port}${pathname}`
  }
  return `ws+unix:${endpoint.socketPath}:${pathname}`
}

export const getAxios = async (force: boolean = false): Promise<AxiosInstance> => {
  const endpoint = getMihomoControllerEndpoint()
  const nextKey = getControllerKey()

  if (axiosIns && !force && currentControllerKey === nextKey) {
    return axiosIns
  }

  currentControllerKey = nextKey
  if (endpoint.transport === 'tcp') {
    mihomoApiLogger.info(`Creating axios instance with tcp: ${endpoint.host}:${endpoint.port}`)
    axiosIns = axios.create({
      baseURL: `http://${endpoint.host}:${endpoint.port}`,
      timeout: 15000
    })
  } else {
    mihomoApiLogger.info(`Creating axios instance with path: ${endpoint.socketPath}`)
    axiosIns = axios.create({
      baseURL: 'http://localhost',
      socketPath: endpoint.socketPath,
      timeout: 15000
    })
  }

  axiosIns.interceptors.response.use(
    (response) => {
      return response.data
    },
    (error) => {
      if (error.code === 'ENOENT') {
        mihomoApiLogger.debug(`Pipe not ready: ${error.config?.socketPath}`)
      } else {
        mihomoApiLogger.error(`Axios error with endpoint ${nextKey}: ${error.message}`)
      }

      if (error.response && error.response.data) {
        return Promise.reject(error.response.data)
      }
      return Promise.reject(error)
    }
  )
  return axiosIns
}

export async function mihomoVersion(): Promise<IMihomoVersion> {
  const instance = await getAxios()
  return await instance.get('/version')
}

export const patchMihomoConfig = async (patch: Partial<IMihomoConfig>): Promise<void> => {
  const instance = await getAxios()
  return await instance.patch('/configs', patch)
}

export const mihomoCloseConnection = async (id: string): Promise<void> => {
  const instance = await getAxios()
  return await instance.delete(`/connections/${encodeURIComponent(id)}`)
}

export const mihomoCloseAllConnections = async (): Promise<void> => {
  const instance = await getAxios()
  return await instance.delete('/connections')
}

export const mihomoRules = async (): Promise<IMihomoRulesInfo> => {
  const instance = await getAxios()
  return await instance.get('/rules')
}

export const mihomoProxies = async (): Promise<IMihomoProxies> => {
  const instance = await getAxios()
  const proxies = (await instance.get('/proxies')) as IMihomoProxies
  if (!proxies.proxies['GLOBAL']) {
    throw new Error('GLOBAL proxy not found')
  }
  return proxies
}

export const mihomoGroups = async (): Promise<IMihomoMixedGroup[]> => {
  const { mode = 'rule' } = await getControledMihomoConfig()
  if (mode === 'direct') return []
  const proxies = await mihomoProxies()
  const runtime = await getRuntimeConfig()
  const groups: IMihomoMixedGroup[] = []
  runtime?.['proxy-groups']?.forEach((group: { name: string; url?: string }) => {
    const { name, url } = group
    if (proxies.proxies[name] && 'all' in proxies.proxies[name] && !proxies.proxies[name].hidden) {
      const newGroup = proxies.proxies[name]
      newGroup.testUrl = url
      const newAll = (newGroup.all || []).map((name) => proxies.proxies[name])
      groups.push({ ...newGroup, all: newAll })
    }
  })
  if (!groups.find((group) => group.name === 'GLOBAL')) {
    const newGlobal = proxies.proxies['GLOBAL'] as IMihomoGroup
    if (!newGlobal.hidden) {
      const newAll = (newGlobal.all || []).map((name) => proxies.proxies[name])
      groups.push({ ...newGlobal, all: newAll })
    }
  }
  if (mode === 'global') {
    const global = groups.findIndex((group) => group.name === 'GLOBAL')
    groups.unshift(groups.splice(global, 1)[0])
  }
  return groups
}

export const mihomoProxyProviders = async (): Promise<IMihomoProxyProviders> => {
  const instance = await getAxios()
  return await instance.get('/providers/proxies')
}

export const mihomoUpdateProxyProviders = async (name: string): Promise<void> => {
  const instance = await getAxios()
  return await instance.put(`/providers/proxies/${encodeURIComponent(name)}`)
}

export const mihomoRuleProviders = async (): Promise<IMihomoRuleProviders> => {
  const instance = await getAxios()
  return await instance.get('/providers/rules')
}

export const mihomoUpdateRuleProviders = async (name: string): Promise<void> => {
  const instance = await getAxios()
  return await instance.put(`/providers/rules/${encodeURIComponent(name)}`)
}

export const mihomoChangeProxy = async (group: string, proxy: string): Promise<IMihomoProxy> => {
  const instance = await getAxios()
  return await instance.put(`/proxies/${encodeURIComponent(group)}`, { name: proxy })
}

export const mihomoUnfixedProxy = async (group: string): Promise<IMihomoProxy> => {
  const instance = await getAxios()
  return await instance.delete(`/proxies/${encodeURIComponent(group)}`)
}

export const mihomoUpgradeGeo = async (): Promise<void> => {
  const instance = await getAxios()
  return await instance.post('/configs/geo')
}

export const mihomoProxyDelay = async (proxy: string, url?: string): Promise<IMihomoDelay> => {
  const appConfig = await getAppConfig()
  const { delayTestUrl, delayTestTimeout } = appConfig
  const instance = await getAxios()
  return await instance.get(`/proxies/${encodeURIComponent(proxy)}/delay`, {
    params: {
      url: url || delayTestUrl || 'http://www.gstatic.com/generate_204',
      timeout: delayTestTimeout || 5000
    }
  })
}

export const mihomoGroupDelay = async (group: string, url?: string): Promise<IMihomoGroupDelay> => {
  const appConfig = await getAppConfig()
  const { delayTestUrl, delayTestTimeout } = appConfig
  const instance = await getAxios()
  return await instance.get(`/group/${encodeURIComponent(group)}/delay`, {
    params: {
      url: url || delayTestUrl || 'http://www.gstatic.com/generate_204',
      timeout: delayTestTimeout || 5000
    }
  })
}

export const mihomoUpgrade = async (): Promise<void> => {
  const instance = await getAxios()
  return await instance.post('/upgrade')
}

export const mihomoUpgradeUI = async (): Promise<void> => {
  const instance = await getAxios()
  return await instance.post('/upgrade/ui')
}

export const mihomoUpgradeConfig = async (): Promise<void> => {
  mihomoApiLogger.info('mihomoUpgradeConfig called')

  try {
    const instance = await getAxios()
    mihomoApiLogger.info('axios instance obtained')
    const { diffWorkDir = false } = await getAppConfig()
    const { getProfileConfig } = await import('../config')
    const { current } = await getProfileConfig(true)
    const { mihomoWorkConfigPath } = await import('../utils/dirs')
    const configPath = diffWorkDir ? mihomoWorkConfigPath(current) : mihomoWorkConfigPath('work')
    mihomoApiLogger.info(`config path: ${configPath}`)
    const { existsSync } = await import('fs')
    if (!existsSync(configPath)) {
      mihomoApiLogger.info('config file does not exist, generating...')
      const { generateProfile } = await import('./factory')
      await generateProfile()
    }
    const response = await instance.put('/configs?force=true', {
      path: configPath
    })
    mihomoApiLogger.info(`config upgrade request completed ${response?.status || 'no status'}`)
  } catch (error) {
    mihomoApiLogger.error('Failed to upgrade config', error)
    throw error
  }
}

export const mihomoSmartGroupWeights = async (
  groupName: string
): Promise<Record<string, number>> => {
  const instance = await getAxios()
  return await instance.get(`/group/${encodeURIComponent(groupName)}/weights`)
}

export const mihomoSmartFlushCache = async (configName?: string): Promise<void> => {
  const instance = await getAxios()
  if (configName) {
    return await instance.post(`/cache/smart/flush/${encodeURIComponent(configName)}`)
  } else {
    return await instance.post('/cache/smart/flush')
  }
}

export const startMihomoTraffic = async (): Promise<void> => {
  trafficRetry = MAX_RETRY
  await mihomoTraffic()
}

export const stopMihomoTraffic = (): void => {
  trafficRetry = 0

  if (mihomoTrafficWs) {
    mihomoTrafficWs.removeAllListeners()
    if (mihomoTrafficWs.readyState === WebSocket.OPEN) {
      mihomoTrafficWs.close()
    }
    mihomoTrafficWs = null
  }
}

const mihomoTraffic = async (): Promise<void> => {
  const wsUrl = buildWsUrl('/traffic')

  mihomoApiLogger.info(`Creating traffic WebSocket with URL: ${wsUrl}`)
  mihomoTrafficWs = new WebSocket(wsUrl)

  mihomoTrafficWs.onmessage = async (e): Promise<void> => {
    const data = e.data as string
    const json = JSON.parse(data) as IMihomoTrafficInfo
    trafficRetry = MAX_RETRY
    try {
      wsBroadcast({ type: 'traffic', data: json })
      wsBroadcast({
        type: 'tray:update',
        data: {
          tooltip:
            '↑' +
            `${calcTraffic(json.up)}/s`.padStart(9) +
            '\n↓' +
            `${calcTraffic(json.down)}/s`.padStart(9)
        }
      })
    } catch {
      // ignore
    }
  }

  mihomoTrafficWs.onclose = (): void => {
    if (trafficRetry) {
      trafficRetry--
      setTimeout(mihomoTraffic, 1000)
    }
  }

  mihomoTrafficWs.onerror = (error): void => {
    mihomoApiLogger.error('Traffic WebSocket error', error)
    if (mihomoTrafficWs) {
      mihomoTrafficWs.close()
      mihomoTrafficWs = null
    }
  }
}

export const startMihomoMemory = async (): Promise<void> => {
  memoryRetry = MAX_RETRY
  await mihomoMemory()
}

export const stopMihomoMemory = (): void => {
  memoryRetry = 0

  if (mihomoMemoryWs) {
    mihomoMemoryWs.removeAllListeners()
    if (mihomoMemoryWs.readyState === WebSocket.OPEN) {
      mihomoMemoryWs.close()
    }
    mihomoMemoryWs = null
  }
}

const mihomoMemory = async (): Promise<void> => {
  const wsUrl = buildWsUrl('/memory')
  mihomoMemoryWs = new WebSocket(wsUrl)

  mihomoMemoryWs.onmessage = (e): void => {
    const data = e.data as string
    memoryRetry = MAX_RETRY
    try {
      wsBroadcast({ type: 'memory', data: JSON.parse(data) as IMihomoMemoryInfo })
    } catch {
      // ignore
    }
  }

  mihomoMemoryWs.onclose = (): void => {
    if (memoryRetry) {
      memoryRetry--
      setTimeout(mihomoMemory, 1000)
    }
  }

  mihomoMemoryWs.onerror = (): void => {
    if (mihomoMemoryWs) {
      mihomoMemoryWs.close()
      mihomoMemoryWs = null
    }
  }
}

export const startMihomoLogs = async (): Promise<void> => {
  logsRetry = MAX_RETRY
  await mihomoLogs()
}

export const stopMihomoLogs = (): void => {
  logsRetry = 0

  if (mihomoLogsWs) {
    mihomoLogsWs.removeAllListeners()
    if (mihomoLogsWs.readyState === WebSocket.OPEN) {
      mihomoLogsWs.close()
    }
    mihomoLogsWs = null
  }
}

const mihomoLogs = async (): Promise<void> => {
  const { 'log-level': logLevel = 'info' } = await getControledMihomoConfig()
  const wsUrl = buildWsUrl(`/logs?level=${logLevel}`)

  mihomoLogsWs = new WebSocket(wsUrl)

  mihomoLogsWs.onmessage = (e): void => {
    const data = e.data as string
    logsRetry = MAX_RETRY
    try {
      wsBroadcast({ type: 'logs', data: JSON.parse(data) as IMihomoLogInfo })
    } catch {
      // ignore
    }
  }

  mihomoLogsWs.onclose = (): void => {
    if (logsRetry) {
      logsRetry--
      setTimeout(mihomoLogs, 1000)
    }
  }

  mihomoLogsWs.onerror = (): void => {
    if (mihomoLogsWs) {
      mihomoLogsWs.close()
      mihomoLogsWs = null
    }
  }
}

export const startMihomoConnections = async (): Promise<void> => {
  connectionsRetry = MAX_RETRY
  await mihomoConnections()
}

export const stopMihomoConnections = (): void => {
  connectionsRetry = 0

  if (mihomoConnectionsWs) {
    mihomoConnectionsWs.removeAllListeners()
    if (mihomoConnectionsWs.readyState === WebSocket.OPEN) {
      mihomoConnectionsWs.close()
    }
    mihomoConnectionsWs = null
  }
}

const mihomoConnections = async (): Promise<void> => {
  const wsUrl = buildWsUrl('/connections')
  mihomoConnectionsWs = new WebSocket(wsUrl)

  mihomoConnectionsWs.onmessage = (e): void => {
    const data = e.data as string
    connectionsRetry = MAX_RETRY
    try {
      wsBroadcast({ type: 'connections', data: JSON.parse(data) as IMihomoConnectionsInfo })
    } catch {
      // ignore
    }
  }

  mihomoConnectionsWs.onclose = (): void => {
    if (connectionsRetry) {
      connectionsRetry--
      setTimeout(mihomoConnections, 1000)
    }
  }

  mihomoConnectionsWs.onerror = (): void => {
    if (mihomoConnectionsWs) {
      mihomoConnectionsWs.close()
      mihomoConnectionsWs = null
    }
  }
}

export async function SysProxyStatus(): Promise<boolean> {
  const appConfig = await getAppConfig()
  return appConfig.sysProxy.enable
}

export const TunStatus = async (): Promise<boolean> => {
  const config = await getControledMihomoConfig()
  return config?.tun?.enable === true
}

export function calculateTrayIconStatus(
  sysProxyEnabled: boolean,
  tunEnabled: boolean
): 'white' | 'blue' | 'green' | 'red' {
  if (sysProxyEnabled && tunEnabled) {
    return 'red'
  } else if (sysProxyEnabled) {
    return 'blue'
  } else if (tunEnabled) {
    return 'green'
  } else {
    return 'white'
  }
}

export async function getTrayIconStatus(): Promise<'white' | 'blue' | 'green' | 'red'> {
  const [sysProxyEnabled, tunEnabled] = await Promise.all([SysProxyStatus(), TunStatus()])
  return calculateTrayIconStatus(sysProxyEnabled, tunEnabled)
}
