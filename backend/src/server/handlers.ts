import { readFile, writeFile } from 'fs/promises'
import i18next from 'i18next'
import {
  mihomoVersion,
  mihomoCloseConnection,
  mihomoCloseAllConnections,
  mihomoRules,
  mihomoProxies,
  mihomoGroups,
  mihomoProxyProviders,
  mihomoUpdateProxyProviders,
  mihomoRuleProviders,
  mihomoUpdateRuleProviders,
  mihomoChangeProxy,
  mihomoUnfixedProxy,
  mihomoUpgradeGeo,
  mihomoUpgrade,
  mihomoUpgradeUI,
  mihomoUpgradeConfig,
  mihomoProxyDelay,
  mihomoGroupDelay,
  patchMihomoConfig,
  mihomoSmartGroupWeights,
  mihomoSmartFlushCache
} from '../core/mihomoApi'
import { checkAutoRun, enableAutoRun, disableAutoRun } from '../sys/autoRun'
import {
  getAppConfig,
  patchAppConfig,
  getControledMihomoConfig,
  patchControledMihomoConfig,
  getProfileConfig,
  setProfileConfig,
  getCurrentProfileItem,
  getProfileItem,
  getProfileStr,
  setProfileStr,
  addProfileItem,
  removeProfileItem,
  updateProfileItem,
  changeCurrentProfile,
  getOverrideConfig,
  setOverrideConfig,
  getOverrideItem,
  addOverrideItem,
  removeOverrideItem,
  updateOverrideItem,
  getOverride,
  setOverride,
  getFileStr,
  setFileStr,
  convertMrsRuleset
} from '../config'
import {
  restartCore,
  quitWithoutCore,
  checkTunPermissions,
  grantTunPermissions,
  manualGrantCorePermition,
  checkAdminPrivileges,
  checkMihomoCorePermissions,
  requestTunPermissions,
  checkHighPrivilegeCore,
  showErrorDialog
} from '../core/manager'
import { triggerSysProxy } from '../sys/sysproxy'
import { readTextFile } from '../sys/misc'
import { getRuntimeConfig, getRuntimeConfigStr } from '../core/factory'
import {
  listWebdavBackups,
  webdavBackup,
  webdavDelete,
  webdavRestore,
  reinitScheduler
} from '../resolve/backup'
import { getInterfaces } from '../sys/interface'
import { getGistUrl } from '../resolve/gistApi'
import { exportServiceLogs } from '../resolve/logExport'
import { addProfileUpdater, removeProfileUpdater } from '../core/profileUpdater'
import { getImageDataURL } from '../utils/image'
import { getIconDataURL } from '../utils/icon'
import { getAppName } from '../utils/appName'
import { rulePath } from '../utils/dirs'
import { installMihomoCore, getGitHubTags, clearVersionCache } from '../utils/github'
import { registerHandler } from './handler-registry'
import { wsBroadcast } from './ws'

async function fetchMihomoTags(
  forceRefresh = false
): Promise<{ name: string; zipball_url: string; tarball_url: string }[]> {
  return await getGitHubTags('MetaCubeX', 'mihomo', forceRefresh)
}

async function installSpecificMihomoCore(version: string): Promise<void> {
  clearVersionCache('MetaCubeX', 'mihomo')
  return await installMihomoCore(version)
}

async function clearMihomoVersionCache(): Promise<void> {
  clearVersionCache('MetaCubeX', 'mihomo')
}

async function getRuleStr(id: string): Promise<string> {
  return await readFile(rulePath(id), 'utf-8')
}

async function setRuleStr(id: string, str: string): Promise<void> {
  await writeFile(rulePath(id), str, 'utf-8')
}

async function getSmartOverrideContent(): Promise<string | null> {
  try {
    const override = await getOverrideItem('smart-core-override')
    return override?.file || null
  } catch {
    return null
  }
}

async function changeLanguage(lng: string): Promise<void> {
  await i18next.changeLanguage(lng)
  wsBroadcast({ type: 'tray:update', data: null })
}

export function registerAllHandlers(): void {
  // Mihomo API
  registerHandler('mihomoVersion', mihomoVersion)
  registerHandler('mihomoCloseConnection', mihomoCloseConnection)
  registerHandler('mihomoCloseAllConnections', mihomoCloseAllConnections)
  registerHandler('mihomoRules', mihomoRules)
  registerHandler('mihomoProxies', mihomoProxies)
  registerHandler('mihomoGroups', mihomoGroups)
  registerHandler('mihomoProxyProviders', mihomoProxyProviders)
  registerHandler('mihomoUpdateProxyProviders', mihomoUpdateProxyProviders)
  registerHandler('mihomoRuleProviders', mihomoRuleProviders)
  registerHandler('mihomoUpdateRuleProviders', mihomoUpdateRuleProviders)
  registerHandler('mihomoChangeProxy', mihomoChangeProxy)
  registerHandler('mihomoUnfixedProxy', mihomoUnfixedProxy)
  registerHandler('mihomoUpgradeGeo', mihomoUpgradeGeo)
  registerHandler('mihomoUpgrade', mihomoUpgrade)
  registerHandler('mihomoUpgradeUI', mihomoUpgradeUI)
  registerHandler('mihomoUpgradeConfig', mihomoUpgradeConfig)
  registerHandler('mihomoProxyDelay', mihomoProxyDelay)
  registerHandler('mihomoGroupDelay', mihomoGroupDelay)
  registerHandler('patchMihomoConfig', patchMihomoConfig)
  registerHandler('mihomoSmartGroupWeights', mihomoSmartGroupWeights)
  registerHandler('mihomoSmartFlushCache', mihomoSmartFlushCache)

  // AutoRun
  registerHandler('checkAutoRun', checkAutoRun)
  registerHandler('enableAutoRun', enableAutoRun)
  registerHandler('disableAutoRun', disableAutoRun)

  // Config
  registerHandler('getAppConfig', getAppConfig)
  registerHandler('patchAppConfig', patchAppConfig)
  registerHandler('getControledMihomoConfig', getControledMihomoConfig)
  registerHandler('patchControledMihomoConfig', patchControledMihomoConfig)

  // Profile
  registerHandler('getProfileConfig', getProfileConfig)
  registerHandler('setProfileConfig', setProfileConfig)
  registerHandler('getCurrentProfileItem', getCurrentProfileItem)
  registerHandler('getProfileItem', getProfileItem)
  registerHandler('getProfileStr', getProfileStr)
  registerHandler('setProfileStr', setProfileStr)
  registerHandler('addProfileItem', addProfileItem)
  registerHandler('removeProfileItem', removeProfileItem)
  registerHandler('updateProfileItem', updateProfileItem)
  registerHandler('changeCurrentProfile', changeCurrentProfile)
  registerHandler('addProfileUpdater', addProfileUpdater)
  registerHandler('removeProfileUpdater', removeProfileUpdater)

  // Override
  registerHandler('getOverrideConfig', getOverrideConfig)
  registerHandler('setOverrideConfig', setOverrideConfig)
  registerHandler('getOverrideItem', getOverrideItem)
  registerHandler('addOverrideItem', addOverrideItem)
  registerHandler('removeOverrideItem', removeOverrideItem)
  registerHandler('updateOverrideItem', updateOverrideItem)
  registerHandler('getOverride', getOverride)
  registerHandler('setOverride', setOverride)

  // File
  registerHandler('getFileStr', getFileStr)
  registerHandler('setFileStr', setFileStr)
  registerHandler('convertMrsRuleset', convertMrsRuleset)
  registerHandler('getRuntimeConfig', getRuntimeConfig)
  registerHandler('getRuntimeConfigStr', getRuntimeConfigStr)
  registerHandler('getSmartOverrideContent', getSmartOverrideContent)
  registerHandler('getRuleStr', getRuleStr)
  registerHandler('setRuleStr', setRuleStr)
  registerHandler('readTextFile', readTextFile)

  // Core
  registerHandler('restartCore', restartCore)
  registerHandler('quitWithoutCore', quitWithoutCore)

  // System
  registerHandler('triggerSysProxy', triggerSysProxy)
  registerHandler('checkTunPermissions', checkTunPermissions)
  registerHandler('grantTunPermissions', grantTunPermissions)
  registerHandler('manualGrantCorePermition', manualGrantCorePermition)
  registerHandler('checkAdminPrivileges', checkAdminPrivileges)
  registerHandler('checkMihomoCorePermissions', checkMihomoCorePermissions)
  registerHandler('requestTunPermissions', requestTunPermissions)
  registerHandler('checkHighPrivilegeCore', checkHighPrivilegeCore)
  registerHandler('showErrorDialog', showErrorDialog)
  registerHandler('getInterfaces', getInterfaces)

  // Update
  registerHandler('fetchMihomoTags', fetchMihomoTags)
  registerHandler('installSpecificMihomoCore', installSpecificMihomoCore)
  registerHandler('clearMihomoVersionCache', clearMihomoVersionCache)

  // Backup
  registerHandler('webdavBackup', webdavBackup)
  registerHandler('webdavRestore', webdavRestore)
  registerHandler('listWebdavBackups', listWebdavBackups)
  registerHandler('webdavDelete', webdavDelete)
  registerHandler('reinitWebdavBackupScheduler', reinitScheduler)

  // Log Export
  registerHandler('exportServiceLogs', exportServiceLogs)

  // Misc
  registerHandler('getGistUrl', getGistUrl)
  registerHandler('getImageDataURL', getImageDataURL)
  registerHandler('getIconDataURL', getIconDataURL)
  registerHandler('getAppName', getAppName)
  registerHandler('changeLanguage', changeLanguage)
  registerHandler('getVersion', () => process.env.MIHOMO_APP_VERSION || '0.0.0')
  registerHandler('platform', () => 'darwin')
}
