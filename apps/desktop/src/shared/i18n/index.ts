import type { Language } from '@kuro/state'
import { en } from './en'
import { zhCN, type TranslationKey } from './zh-CN'

let currentLanguage: Language = 'en'

export function setLanguage(language: Language): void {
  currentLanguage = language
}

export function getLanguage(): Language {
  return currentLanguage
}

// Unknown keys stay visible so a missing translation is not silently hidden.
export function t(
  key: string,
  values: Record<string, string | number> = {},
  language: Language = currentLanguage
): string {
  const table = language === 'zh-CN' ? zhCN : en
  const text = Object.hasOwn(table, key) ? table[key as TranslationKey] : key
  return text.replace(/\{(\w+)\}/g, (placeholder, name: string) =>
    Object.hasOwn(values, name) ? String(values[name]) : placeholder
  )
}
