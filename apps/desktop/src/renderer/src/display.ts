import { t } from './i18n/zh-CN'

export function formatBytes(bytes: number) {
  const unit = Math.min(
    4,
    Math.max(0, Math.floor(Math.log(Math.max(1, bytes)) / Math.log(1024)))
  )
  return t(['bytes', 'kib', 'mib', 'gib', 'tib'][unit]!, {
    value: (bytes / 1024 ** unit).toLocaleString('zh-CN', {
      maximumFractionDigits: 1
    })
  })
}

export function date(value: number) {
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).format(value)
}

export function releaseUrl(url: string): string | null {
  try {
    const parsed = new URL(url)
    return parsed.protocol === 'https:' ? parsed.href : null
  } catch {
    return null
  }
}
