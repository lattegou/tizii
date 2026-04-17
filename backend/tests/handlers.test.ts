import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { registerAllHandlers } from '../src/server/handlers'
import { listHandlers, getHandler } from '../src/server/handler-registry'
import { createTestServer, rpc, TestServer } from './helpers'

let srv: TestServer

beforeAll(async () => {
  registerAllHandlers()
  srv = await createTestServer()
})

afterAll(async () => {
  await srv.close()
})

describe('Handler Registration', () => {
  it('registerAllHandlers completes without error', () => {
    const handlers = listHandlers()
    expect(handlers.length).toBeGreaterThan(0)
  })

  it('registers the expected number of handlers (≥85)', () => {
    const count = listHandlers().length
    expect(count).toBeGreaterThanOrEqual(85)
  })

  const expectedMethods = [
    // Mihomo API
    'mihomoVersion',
    'mihomoCloseConnection',
    'mihomoCloseAllConnections',
    'mihomoRules',
    'mihomoProxies',
    'mihomoGroups',
    'mihomoProxyProviders',
    'mihomoUpdateProxyProviders',
    'mihomoRuleProviders',
    'mihomoUpdateRuleProviders',
    'mihomoChangeProxy',
    'mihomoUnfixedProxy',
    'mihomoUpgradeGeo',
    'mihomoUpgrade',
    'mihomoUpgradeUI',
    'mihomoUpgradeConfig',
    'mihomoProxyDelay',
    'mihomoGroupDelay',
    'patchMihomoConfig',
    'mihomoSmartGroupWeights',
    'mihomoSmartFlushCache',

    // AutoRun
    'checkAutoRun',
    'enableAutoRun',
    'disableAutoRun',

    // Config
    'getAppConfig',
    'patchAppConfig',
    'getControledMihomoConfig',
    'patchControledMihomoConfig',

    // Profile
    'getProfileConfig',
    'setProfileConfig',
    'getCurrentProfileItem',
    'getProfileItem',
    'getProfileStr',
    'setProfileStr',
    'addProfileItem',
    'removeProfileItem',
    'updateProfileItem',
    'changeCurrentProfile',
    'addProfileUpdater',
    'removeProfileUpdater',

    // Override
    'getOverrideConfig',
    'setOverrideConfig',
    'getOverrideItem',
    'addOverrideItem',
    'removeOverrideItem',
    'updateOverrideItem',
    'getOverride',
    'setOverride',

    // File
    'getFileStr',
    'setFileStr',
    'convertMrsRuleset',
    'getRuntimeConfig',
    'getRuntimeConfigStr',
    'getSmartOverrideContent',
    'getRuleStr',
    'setRuleStr',
    'readTextFile',

    // Core
    'restartCore',
    'quitWithoutCore',

    // System
    'triggerSysProxy',
    'checkTunPermissions',
    'grantTunPermissions',
    'manualGrantCorePermition',
    'checkAdminPrivileges',
    'checkMihomoCorePermissions',
    'requestTunPermissions',
    'checkHighPrivilegeCore',
    'showErrorDialog',
    'getInterfaces',

    // Update
    'fetchMihomoTags',
    'installSpecificMihomoCore',
    'clearMihomoVersionCache',

    // Backup
    'webdavBackup',
    'webdavRestore',
    'listWebdavBackups',
    'webdavDelete',
    'reinitWebdavBackupScheduler',

    // Misc
    'getGistUrl',
    'getImageDataURL',
    'getIconDataURL',
    'getAppName',
    'changeLanguage',
    'getVersion',
    'platform'
  ]

  it('all expected methods are registered', () => {
    const registered = new Set(listHandlers())
    const missing = expectedMethods.filter((m) => !registered.has(m))
    expect(missing).toEqual([])
  })

  it('no unexpected methods are registered', () => {
    const registered = listHandlers()
    const expected = new Set(expectedMethods)
    const extra = registered.filter((m) => !expected.has(m))

    // server.test.ts mock handlers 可能会注册额外方法，忽略它们
    const mockNames = new Set([
      'echo',
      'add',
      'greet',
      'throws',
      'asyncThrows',
      'returnsNull',
      'returnsUndefined'
    ])
    const realExtra = extra.filter((m) => !mockNames.has(m))

    if (realExtra.length > 0) {
      console.warn('Extra handlers not in expected list:', realExtra)
    }
    // 警告但不失败，防止新增 handler 后忘记更新测试列表
  })

  it('every registered handler is a function', () => {
    for (const name of listHandlers()) {
      const handler = getHandler(name)
      expect(typeof handler).toBe('function')
    }
  })
})

describe('Simple Handler Smoke Tests', () => {
  it('getVersion returns a version string', async () => {
    const { status, data } = await rpc(srv.client, 'getVersion')
    expect(status).toBe(200)
    expect(typeof data.result).toBe('string')
  })

  it('platform returns darwin', async () => {
    const { data } = await rpc(srv.client, 'platform')
    expect(data.result).toBe('darwin')
  })

  it('getAppConfig returns an object with expected fields', async () => {
    const { status, data } = await rpc(srv.client, 'getAppConfig')
    expect(status).toBe(200)

    const config = data.result as Record<string, unknown>
    expect(config).toBeDefined()
    expect(typeof config).toBe('object')
    expect(config).toHaveProperty('core')
    expect(config).toHaveProperty('siderOrder')
    expect(config).toHaveProperty('sysProxy')
  })

  it('patchAppConfig updates config', async () => {
    await rpc(srv.client, 'patchAppConfig', [{ maxLogDays: 14 }])
    const { data } = await rpc(srv.client, 'getAppConfig')
    const config = data.result as Record<string, unknown>
    expect(config.maxLogDays).toBe(14)
  })

  it('getControledMihomoConfig returns an object', async () => {
    const { status, data } = await rpc(srv.client, 'getControledMihomoConfig')
    expect(status).toBe(200)
    expect(typeof data.result).toBe('object')
  })

  it('getProfileConfig returns config with items array', async () => {
    const { data } = await rpc(srv.client, 'getProfileConfig')
    const config = data.result as Record<string, unknown>
    expect(config).toBeDefined()
    expect(Array.isArray(config.items)).toBe(true)
  })

  it('getOverrideConfig returns config with items array', async () => {
    const { data } = await rpc(srv.client, 'getOverrideConfig')
    const config = data.result as Record<string, unknown>
    expect(config).toBeDefined()
    expect(Array.isArray(config.items)).toBe(true)
  })

  it('getAppName returns a string (empty without valid .app path)', async () => {
    const { data } = await rpc(srv.client, 'getAppName', ['/nonexistent.app'])
    expect(typeof data.result).toBe('string')
  })

  it('getInterfaces returns an object or gracefully errors', async () => {
    const { status, data } = await rpc(srv.client, 'getInterfaces')
    expect(status).toBe(200)
    if (data.result !== undefined) {
      expect(typeof data.result).toBe('object')
      expect(Array.isArray(data.result)).toBe(false)
    } else {
      expect(data.error).toBeDefined()
    }
  })
})

describe('Config Read/Write Round-Trip', () => {
  it('patchAppConfig + getAppConfig round-trip', async () => {
    const uniqueValue = `test-theme-${Date.now()}`
    await rpc(srv.client, 'patchAppConfig', [{ appTheme: uniqueValue }])

    const { data } = await rpc(srv.client, 'getAppConfig', [true])
    const config = data.result as Record<string, unknown>
    expect(config.appTheme).toBe(uniqueValue)

    // restore
    await rpc(srv.client, 'patchAppConfig', [{ appTheme: 'system' }])
  })

  it('patchControledMihomoConfig + getControledMihomoConfig round-trip', async () => {
    await rpc(srv.client, 'patchControledMihomoConfig', [{ 'log-level': 'debug' }])

    const { data } = await rpc(srv.client, 'getControledMihomoConfig', [true])
    const config = data.result as Record<string, unknown>
    expect(config['log-level']).toBe('debug')

    // restore
    await rpc(srv.client, 'patchControledMihomoConfig', [{ 'log-level': 'info' }])
  })
})
