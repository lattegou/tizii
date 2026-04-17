import { overrideLogger } from '../utils/logger'
import { getAppConfig } from './app'
import { addOverrideItem, removeOverrideItem, getOverrideItem } from './override'

const SMART_OVERRIDE_ID = 'smart-core-override'

function generateSmartOverrideTemplate(
  useLightGBM: boolean,
  collectData: boolean,
  strategy: string,
  collectorSize: number
): string {
  return `
// 配置会在启用 Smart 内核时自动应用

function main(config) {
  try {
    if (!config || typeof config !== 'object') {
      console.log('[Smart Override] Invalid config object')
      return config
    }

    if (!config.profile) {
      config.profile = {}
    }
    config.profile['smart-collector-size'] = ${collectorSize}

    if (!config['proxy-groups']) {
      config['proxy-groups'] = []
    }

    if (!Array.isArray(config['proxy-groups'])) {
      console.log('[Smart Override] proxy-groups is not an array, converting...')
      config['proxy-groups'] = []
    }

    let hasUrlTestOrLoadBalance = false
    for (let i = 0; i < config['proxy-groups'].length; i++) {
      const group = config['proxy-groups'][i]
      if (group && group.type) {
        const groupType = group.type.toLowerCase()
        if (groupType === 'url-test' || groupType === 'load-balance') {
          hasUrlTestOrLoadBalance = true
          break
        }
      }
    }

    if (hasUrlTestOrLoadBalance) {
      console.log('[Smart Override] Found url-test or load-balance groups, converting to smart type')
      
      const nameMapping = new Map()
      
      for (let i = 0; i < config['proxy-groups'].length; i++) {
        const group = config['proxy-groups'][i]
        if (group && group.type) {
          const groupType = group.type.toLowerCase()
          if (groupType === 'url-test' || groupType === 'load-balance') {
            console.log('[Smart Override] Converting group:', group.name, 'from', group.type, 'to smart')
            
            const originalName = group.name
            
            group.type = 'smart'
            
            if (group.name && !group.name.includes('(Smart Group)')) {
              group.name = group.name + '(Smart Group)'
              nameMapping.set(originalName, group.name)
            }
            
            if (!group['policy-priority']) {
              group['policy-priority'] = ''
            }
            group.uselightgbm = ${useLightGBM}
            group.collectdata = ${collectData}
            group.strategy = '${strategy}'
            
            if (group.url) delete group.url
            if (group.interval) delete group.interval
            if (group.tolerance) delete group.tolerance
            if (group.lazy) delete group.lazy
            if (group.expected_status) delete group['expected-status']
          }
        }
      }
      
      if (nameMapping.size > 0) {
        console.log('[Smart Override] Updating references to renamed groups:', Array.from(nameMapping.entries()))
        
        if (config['proxy-groups'] && Array.isArray(config['proxy-groups'])) {
          config['proxy-groups'].forEach(group => {
            if (group && group.proxies && Array.isArray(group.proxies)) {
              group.proxies = group.proxies.map(proxyName => {
                if (nameMapping.has(proxyName)) {
                  console.log('[Smart Override] Updated proxy reference:', proxyName, '→', nameMapping.get(proxyName))
                  return nameMapping.get(proxyName)
                }
                return proxyName
              })
            }
          })
        }
        
        const ruleParamsSet = new Set(['no-resolve', 'force-remote-dns', 'prefer-ipv6'])
        
        if (config.rules && Array.isArray(config.rules)) {
          config.rules = config.rules.map(rule => {
            if (typeof rule === 'string') {
              const parts = rule.split(',').map(part => part.trim())
              
              if (parts.length >= 2) {
                let targetIndex = -1
                
                if (parts[0] === 'MATCH' && parts.length === 2) {
                  targetIndex = 1
                } else if (parts.length >= 3) {
                  for (let i = 2; i < parts.length; i++) {
                    if (!ruleParamsSet.has(parts[i])) {
                      targetIndex = i
                      break
                    }
                  }
                }
                
                if (targetIndex !== -1 && nameMapping.has(parts[targetIndex])) {
                  const oldName = parts[targetIndex]
                  parts[targetIndex] = nameMapping.get(oldName)
                  console.log('[Smart Override] Updated rule reference:', oldName, '→', nameMapping.get(oldName))
                  return parts.join(',')
                }
              }
              return rule
            } else if (typeof rule === 'object' && rule !== null) {
              ['target', 'proxy'].forEach(field => {
                if (rule[field] && nameMapping.has(rule[field])) {
                  console.log('[Smart Override] Updated rule object reference:', rule[field], '→', nameMapping.get(rule[field]))
                  rule[field] = nameMapping.get(rule[field])
                }
              })
            }
            return rule
          })
        }
        
        ['mode', 'proxy-mode'].forEach(field => {
          if (config[field] && nameMapping.has(config[field])) {
            console.log('[Smart Override] Updated config field', field + ':', config[field], '→', nameMapping.get(config[field]))
            config[field] = nameMapping.get(config[field])
          }
        })
      }
      
      console.log('[Smart Override] Conversion completed, skipping other operations')
      return config
    }

    console.log('[Smart Override] No url-test or load-balance groups found, executing original logic')
    
    let smartGroupExists = false
    for (let i = 0; i < config['proxy-groups'].length; i++) {
      const group = config['proxy-groups'][i]
      if (group && group.type === 'smart') {
        smartGroupExists = true
        console.log('[Smart Override] Found existing smart group:', group.name)

        if (!group['policy-priority']) {
          group['policy-priority'] = ''
        }
        group.uselightgbm = ${useLightGBM}
        group.collectdata = ${collectData}
        group.strategy = '${strategy}'
        break
      }
    }

    if (!smartGroupExists && config.proxies && Array.isArray(config.proxies) && config.proxies.length > 0) {
      console.log('[Smart Override] Creating new smart group with', config.proxies.length, 'proxies')

      const proxyNames = config.proxies
        .filter(proxy => proxy && typeof proxy === 'object' && proxy.name)
        .map(proxy => proxy.name)

      if (proxyNames.length > 0) {
        const smartGroup = {
          name: 'Smart Group',
          type: 'smart',
          'policy-priority': '',
          uselightgbm: ${useLightGBM},
          collectdata: ${collectData},
          strategy: '${strategy}',
          proxies: proxyNames
        }
        config['proxy-groups'].unshift(smartGroup)
        console.log('[Smart Override] Created smart group at first position with proxies:', proxyNames)
      } else {
        console.log('[Smart Override] No valid proxies found, skipping smart group creation')
      }
    } else if (!smartGroupExists) {
      console.log('[Smart Override] No proxies available, skipping smart group creation')
    }

    if (config.rules && Array.isArray(config.rules)) {
      console.log('[Smart Override] Processing rules, original count:', config.rules.length)

      const proxyGroupNames = new Set()
      if (config['proxy-groups'] && Array.isArray(config['proxy-groups'])) {
        config['proxy-groups'].forEach(group => {
          if (group && group.name) {
            proxyGroupNames.add(group.name)
          }
        })
      }

      const builtinTargets = new Set([
        'DIRECT',
        'REJECT',
        'REJECT-DROP',
        'PASS',
        'COMPATIBLE'
      ])

      const ruleParams = new Set(['no-resolve', 'force-remote-dns', 'prefer-ipv6'])

      console.log('[Smart Override] Found', proxyGroupNames.size, 'proxy groups:', Array.from(proxyGroupNames))

      let replacedCount = 0
      config.rules = config.rules.map(rule => {
        if (typeof rule === 'string') {
          if (rule.includes('((') || rule.includes('))')) {
            console.log('[Smart Override] Skipping complex nested rule:', rule)
            return rule
          }

          const parts = rule.split(',').map(part => part.trim())
          if (parts.length >= 2) {
            let targetIndex = -1
            let targetValue = ''

            if (parts[0] === 'MATCH' && parts.length === 2) {
              targetIndex = 1
              targetValue = parts[1]
            } else if (parts.length >= 3) {
              for (let i = 2; i < parts.length; i++) {
                const part = parts[i]
                if (!ruleParams.has(part)) {
                  targetIndex = i
                  targetValue = part
                  break
                }
              }
            }

            if (targetIndex !== -1 && targetValue) {
              const shouldReplace = !builtinTargets.has(targetValue) &&
                                   (proxyGroupNames.has(targetValue) ||
                                    !ruleParams.has(targetValue))

              if (shouldReplace) {
                parts[targetIndex] = 'Smart Group'
                replacedCount++
                console.log('[Smart Override] Replaced rule target:', targetValue, '→ Smart Group')
                return parts.join(',')
              }
            }
          }
        } else if (typeof rule === 'object' && rule !== null) {
          let targetField = ''
          let targetValue = ''

          if (rule.target) {
            targetField = 'target'
            targetValue = rule.target
          } else if (rule.proxy) {
            targetField = 'proxy'
            targetValue = rule.proxy
          }

          if (targetField && targetValue) {
            const shouldReplace = !builtinTargets.has(targetValue) &&
                                 (proxyGroupNames.has(targetValue) ||
                                  !ruleParams.has(targetValue))

            if (shouldReplace) {
              rule[targetField] = 'Smart Group'
              replacedCount++
              console.log('[Smart Override] Replaced rule target:', targetValue, '→ Smart Group')
            }
          }
        }
        return rule
      })

      console.log('[Smart Override] Rules processed, replaced', replacedCount, 'non-DIRECT rules with Smart Group')
    } else {
      console.log('[Smart Override] No rules found or rules is not an array')
    }

    console.log('[Smart Override] Configuration processed successfully')
    return config
  } catch (error) {
    console.error('[Smart Override] Error processing config:', error)
    return config
  }
}
`
}

export async function createSmartOverride(): Promise<void> {
  try {
    const {
      smartCoreUseLightGBM = false,
      smartCoreCollectData = false,
      smartCoreStrategy = 'sticky-sessions',
      smartCollectorSize = 100
    } = await getAppConfig()

    const template = generateSmartOverrideTemplate(
      smartCoreUseLightGBM,
      smartCoreCollectData,
      smartCoreStrategy,
      smartCollectorSize
    )

    await addOverrideItem({
      id: SMART_OVERRIDE_ID,
      name: 'Smart Core Override',
      type: 'local',
      ext: 'js',
      global: true,
      file: template
    })
  } catch (error) {
    await overrideLogger.error('Failed to create Smart override', error)
    throw error
  }
}

export async function removeSmartOverride(): Promise<void> {
  try {
    const existingOverride = await getOverrideItem(SMART_OVERRIDE_ID)
    if (existingOverride) {
      await removeOverrideItem(SMART_OVERRIDE_ID)
    }
  } catch (error) {
    await overrideLogger.error('Failed to remove Smart override', error)
    throw error
  }
}

export async function manageSmartOverride(): Promise<void> {
  const { enableSmartCore = true, enableSmartOverride = true, core } = await getAppConfig()

  if (enableSmartCore && enableSmartOverride && core === 'mihomo-smart') {
    await createSmartOverride()
  } else {
    await removeSmartOverride()
  }
}

export async function isSmartOverrideExists(): Promise<boolean> {
  try {
    const override = await getOverrideItem(SMART_OVERRIDE_ID)
    return !!override
  } catch {
    return false
  }
}
