import { exec } from 'child_process'
import { promisify } from 'util'
import { exePath } from '../utils/dirs'
import { systemLogger } from '../utils/logger'

export async function checkAutoRun(): Promise<boolean> {
  const execPromise = promisify(exec)
  const { stdout } = await execPromise(
    `osascript -e 'tell application "System Events" to get the name of every login item'`
  )
  const enabled = stdout.includes(exePath().split('.app')[0].replace('/Applications/', ''))
  await systemLogger.info(`Auto run status: ${enabled ? 'enabled' : 'disabled'}`)
  return enabled
}

export async function enableAutoRun(): Promise<void> {
  const execPromise = promisify(exec)
  await systemLogger.info('Enabling auto run')
  await execPromise(
    `osascript -e 'tell application "System Events" to make login item at end with properties {path:"${exePath().split('.app')[0]}.app", hidden:false}'`
  )
  await systemLogger.info('Auto run enabled')
}

export async function disableAutoRun(): Promise<void> {
  const execPromise = promisify(exec)
  await systemLogger.info('Disabling auto run')
  await execPromise(
    `osascript -e 'tell application "System Events" to delete login item "${exePath().split('.app')[0].replace('/Applications/', '')}"'`
  )
  await systemLogger.info('Auto run disabled')
}
