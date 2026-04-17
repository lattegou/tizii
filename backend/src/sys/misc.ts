import { readFile } from 'fs/promises'

export async function readTextFile(filePath: string): Promise<string> {
  return await readFile(filePath, 'utf8')
}
