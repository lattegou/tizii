import { existsSync } from 'fs'
import path from 'path'
import dayjs from 'dayjs'
import AdmZip from 'adm-zip'
import { logDir } from '../utils/dirs'

export async function exportServiceLogs(days = 7): Promise<{ filename: string; data: string }> {
  const resolvedDays = Math.max(days, 1)
  const dir = logDir()

  if (!existsSync(dir)) {
    throw new Error('未找到日志目录')
  }

  const today = dayjs().startOf('day')
  const files: string[] = []

  for (let offset = resolvedDays - 1; offset >= 0; offset--) {
    const date = today.subtract(offset, 'day')
    const suffix = date.format('YYYY-MM-DD')
    const nodLog = path.join(dir, `tizii-${suffix}.log`)
    const coreLog = path.join(dir, `core-${suffix}.log`)
    const swiftLog = path.join(dir, `swift-${suffix}.log`)
    if (existsSync(nodLog)) files.push(nodLog)
    if (existsSync(coreLog)) files.push(coreLog)
    if (existsSync(swiftLog)) files.push(swiftLog)
  }

  if (files.length === 0) {
    throw new Error(`最近${resolvedDays}天未找到可导出的日志`)
  }

  const zip = new AdmZip()
  for (const file of files) {
    zip.addLocalFile(file)
  }

  const dateStamp = dayjs().format('YYYYMMDD')
  const filename = `service-logs-last-${resolvedDays}-days-${dateStamp}.zip`
  const buffer = zip.toBuffer()

  return { filename, data: buffer.toString('base64') }
}
