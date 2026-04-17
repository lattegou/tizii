import { mkdirSync, mkdtempSync, writeFileSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'

const tmp = mkdtempSync(join(tmpdir(), 'backend-test-'))

process.env.MIHOMO_DATA_DIR = tmp
process.env.MIHOMO_RESOURCES_DIR = join(tmp, 'resources')

const dirs = [
  'profiles',
  'override',
  'work',
  'logs',
  'themes',
  'rules',
  'tasks',
  'test',
  'resources/sidecar',
  'resources/files'
]

for (const d of dirs) {
  mkdirSync(join(tmp, d), { recursive: true })
}

writeFileSync(join(tmp, 'config.yaml'), 'core: mihomo\nlanguage: en\n')
writeFileSync(join(tmp, 'mihomo.yaml'), 'external-controller: ""\n')
writeFileSync(join(tmp, 'profile.yaml'), 'items: []\n')
writeFileSync(join(tmp, 'override.yaml'), 'items: []\n')
