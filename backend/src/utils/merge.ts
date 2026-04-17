// eslint-disable-next-line @typescript-eslint/no-explicit-any
function isObject(item: any): boolean {
  return item && typeof item === 'object' && !Array.isArray(item)
}

function trimWrap(str: string): string {
  if (str.startsWith('<') && str.endsWith('>')) {
    return str.slice(1, -1)
  }
  return str
}

export function deepMerge<T extends object>(target: T, other: Partial<T>): T {
  const targetRecord = target as Record<string, unknown>
  const otherRecord = other as Record<string, unknown>

  for (const key of Object.keys(otherRecord)) {
    const value = otherRecord[key]

    if (isObject(value)) {
      if (key.endsWith('!')) {
        const k = trimWrap(key.slice(0, -1))
        targetRecord[k] = value
      } else {
        const k = trimWrap(key)
        if (!isObject(targetRecord[k])) {
          targetRecord[k] = {}
        }
        deepMerge(targetRecord[k] as object, value as object)
      }
    } else if (Array.isArray(value)) {
      if (key.startsWith('+')) {
        const k = trimWrap(key.slice(1))
        const current = Array.isArray(targetRecord[k]) ? (targetRecord[k] as unknown[]) : []
        targetRecord[k] = [...value, ...current]
      } else if (key.endsWith('+')) {
        const k = trimWrap(key.slice(0, -1))
        const current = Array.isArray(targetRecord[k]) ? (targetRecord[k] as unknown[]) : []
        targetRecord[k] = [...current, ...value]
      } else {
        const k = trimWrap(key)
        targetRecord[k] = value
      }
    } else {
      targetRecord[key] = value
    }
  }
  return target as T
}
