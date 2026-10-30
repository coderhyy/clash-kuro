import { useEffect, useState } from 'react'
import { ArrowDown, ArrowUp } from 'lucide-react'
import type { LogEntry, Traffic } from '@tern/api'
import type { StateBridge } from '@tern/state'
import { t } from './i18n/zh-CN'
import { formatBytes } from './display'

const VISIBLE_LOGS = 200

/** Subscribes only while mounted, so a destroyed window holds no Core stream (ADR-0004). */
export function LivePanel({ bridge, running }: { bridge: StateBridge; running: boolean }) {
  const [traffic, setTraffic] = useState<Traffic>({ up: 0, down: 0 })
  const [logs, setLogs] = useState<LogEntry[]>([])

  useEffect(() => bridge.subscribeTraffic(setTraffic), [bridge])
  useEffect(
    () => bridge.subscribeLogs((entry) => setLogs((prev) => [...prev.slice(-(VISIBLE_LOGS - 1)), entry])),
    [bridge]
  )

  return (
    <section className="live" aria-labelledby="live-title">
      <div className="section-heading">
        <h2 id="live-title">{t('live')}</h2>
        <div className="traffic" aria-live="off">
          <span><ArrowUp size={13} aria-label={t('upload')} />{t('perSecond', { value: formatBytes(traffic.up) })}</span>
          <span><ArrowDown size={13} aria-label={t('download')} />{t('perSecond', { value: formatBytes(traffic.down) })}</span>
        </div>
      </div>
      {!running && <p className="muted">{t('liveOffline')}</p>}
      <ol className="log-list" aria-label={t('logs')}>
        {logs.length === 0 && <li className="muted">{t('noLogs')}</li>}
        {logs.map((entry, i) => (
          <li key={i} className={`log-${entry.level}`}>
            <span className="log-level">{entry.level}</span>
            <span className="log-payload">{entry.payload}</span>
          </li>
        ))}
      </ol>
    </section>
  )
}
