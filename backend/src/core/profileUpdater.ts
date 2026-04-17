import { Cron } from 'croner'
import { addProfileItem, getCurrentProfileItem, getProfileConfig, getProfileItem } from '../config'
import { logger } from '../utils/logger'

const intervalPool: Record<string, Cron | NodeJS.Timeout> = {}
const delayedUpdatePool: Record<string, NodeJS.Timeout> = {}

async function updateProfile(id: string): Promise<void> {
  const item = await getProfileItem(id)
  if (item && item.type === 'remote') {
    await addProfileItem(item)
  }
}

export async function initProfileUpdater(): Promise<void> {
  const { items = [], current } = await getProfileConfig()
  const currentItem = await getCurrentProfileItem()

  for (const item of items.filter((i) => i.id !== current)) {
    if (item.type === 'remote' && item.autoUpdate && item.interval) {
      const itemId = item.id
      if (typeof item.interval === 'number') {
        intervalPool[itemId] = setInterval(
          async () => {
            try {
              await updateProfile(itemId)
            } catch (e) {
              await logger.warn(`[ProfileUpdater] Failed to update profile ${itemId}:`, e)
            }
          },
          item.interval * 60 * 1000
        )
      } else if (typeof item.interval === 'string') {
        intervalPool[itemId] = new Cron(item.interval, async () => {
          try {
            await updateProfile(itemId)
          } catch (e) {
            await logger.warn(`[ProfileUpdater] Failed to update profile ${itemId}:`, e)
          }
        })
      }

      try {
        await addProfileItem(item)
      } catch (e) {
        await logger.warn(`[ProfileUpdater] Failed to init profile ${item.name}:`, e)
      }
    }
  }

  if (currentItem?.type === 'remote' && currentItem.autoUpdate && currentItem.interval) {
    const currentId = currentItem.id
    if (typeof currentItem.interval === 'number') {
      intervalPool[currentId] = setInterval(
        async () => {
          try {
            await updateProfile(currentId)
          } catch (e) {
            await logger.warn(`[ProfileUpdater] Failed to update current profile:`, e)
          }
        },
        currentItem.interval * 60 * 1000
      )

      delayedUpdatePool[currentId] = setTimeout(
        async () => {
          delete delayedUpdatePool[currentId]
          try {
            await updateProfile(currentId)
          } catch (e) {
            await logger.warn(`[ProfileUpdater] Failed to update current profile:`, e)
          }
        },
        currentItem.interval * 60 * 1000 + 10000
      )
    } else if (typeof currentItem.interval === 'string') {
      intervalPool[currentId] = new Cron(currentItem.interval, async () => {
        try {
          await updateProfile(currentId)
        } catch (e) {
          await logger.warn(`[ProfileUpdater] Failed to update current profile:`, e)
        }
      })
    }

    try {
      await addProfileItem(currentItem)
    } catch (e) {
      await logger.warn(`[ProfileUpdater] Failed to init current profile:`, e)
    }
  }
}

export async function addProfileUpdater(item: IProfileItem): Promise<void> {
  if (item.type === 'remote' && item.autoUpdate && item.interval) {
    if (intervalPool[item.id]) {
      if (intervalPool[item.id] instanceof Cron) {
        ;(intervalPool[item.id] as Cron).stop()
      } else {
        clearInterval(intervalPool[item.id] as NodeJS.Timeout)
      }
    }

    const itemId = item.id
    if (typeof item.interval === 'number') {
      intervalPool[itemId] = setInterval(
        async () => {
          try {
            await updateProfile(itemId)
          } catch (e) {
            await logger.warn(`[ProfileUpdater] Failed to update profile ${itemId}:`, e)
          }
        },
        item.interval * 60 * 1000
      )
    } else if (typeof item.interval === 'string') {
      intervalPool[itemId] = new Cron(item.interval, async () => {
        try {
          await updateProfile(itemId)
        } catch (e) {
          await logger.warn(`[ProfileUpdater] Failed to update profile ${itemId}:`, e)
        }
      })
    }
  }
}

export async function removeProfileUpdater(id: string): Promise<void> {
  if (intervalPool[id]) {
    if (intervalPool[id] instanceof Cron) {
      ;(intervalPool[id] as Cron).stop()
    } else {
      clearInterval(intervalPool[id] as NodeJS.Timeout)
    }
    delete intervalPool[id]
  }
  if (delayedUpdatePool[id]) {
    clearTimeout(delayedUpdatePool[id])
    delete delayedUpdatePool[id]
  }
}
