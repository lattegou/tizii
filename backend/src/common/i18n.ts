import i18next from 'i18next'
import enUS from './locales/en-US.json'
import zhCN from './locales/zh-CN.json'
import zhTW from './locales/zh-TW.json'
import ruRU from './locales/ru-RU.json'
import faIR from './locales/fa-IR.json'

export const resources = {
  'en-US': {
    translation: enUS
  },
  'zh-CN': {
    translation: zhCN
  },
  'zh-TW': {
    translation: zhTW
  },
  'ru-RU': {
    translation: ruRU
  },
  'fa-IR': {
    translation: faIR
  }
}

export const defaultConfig = {
  resources,
  lng: 'zh-CN',
  fallbackLng: 'en-US',
  interpolation: {
    escapeValue: false
  }
}

export const initI18n = async (options = {}): Promise<typeof i18next> => {
  await i18next.init({
    ...defaultConfig,
    ...options
  })
  return i18next
}

export default i18next
