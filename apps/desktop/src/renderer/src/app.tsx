import { useRef, useState } from 'react'
import type { FormEvent } from 'react'
import type {
  CommandInput,
  CommandName,
  StateBridge,
  StateSnapshot
} from '@kuro/state'
import type { Profile } from '@kuro/core'
import {
  Activity,
  ArrowDownToLine,
  Check,
  ChevronRight,
  CircleAlert,
  FileText,
  FolderOpen,
  Globe,
  Plus,
  Power,
  RefreshCw,
  Settings2,
  ShieldCheck,
  Trash2,
  X
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Switch } from '@/components/ui/switch'
import { Badge } from '@/components/ui/badge'
import { t } from './i18n/zh-CN'
import { useSnapshot } from './use-snapshot'
import { LivePanel } from './live-panel'
import { date, formatBytes, releaseUrl } from './display'

type Run = <K extends CommandName>(
  name: K,
  input: CommandInput<K>
) => Promise<boolean>

function ImportForm({
  run,
  busy,
  close
}: {
  run: Run
  busy: boolean
  close: () => void
}) {
  const [kind, setKind] = useState<'remote' | 'local'>('remote')
  const [error, setError] = useState('')
  const sourceRef = useRef<HTMLInputElement>(null)
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = new FormData(event.currentTarget)
    const name = String(data.get('name') ?? '').trim()
    const value = String(data.get('source') ?? '').trim()
    if (!name) {
      setError(t('invalidName'))
      return
    }
    if (kind === 'remote') {
      try {
        if (!['http:', 'https:'].includes(new URL(value).protocol))
          throw new Error()
      } catch {
        setError(t('invalidUrl'))
        return
      }
    } else if (!/^(\/|[a-zA-Z]:[\\/]|\\\\)/.test(value)) {
      setError(t('invalidPath'))
      return
    }
    setError('')
    if (
      await run('importProfile', {
        name,
        source: kind === 'remote' ? { kind, url: value } : { kind, path: value }
      })
    )
      close()
  }
  return (
    <form className="import-form" onSubmit={(event) => void submit(event)}>
      <div className="section-heading">
        <h3>{t('import')}</h3>
        <Button
          variant="ghost"
          size="icon-sm"
          type="button"
          aria-label={t('close')}
          onClick={close}
        >
          <X />
        </Button>
      </div>
      <p className="muted">{t('importHint')}</p>
      <fieldset disabled={busy} className="form-fields">
        <label htmlFor="profile-name">{t('name')}</label>
        <Input
          id="profile-name"
          name="name"
          required
          maxLength={100}
          autoFocus
        />
        <label htmlFor="profile-source-kind">{t('source')}</label>
        <select
          id="profile-source-kind"
          value={kind}
          onChange={(event) => {
            setKind(event.target.value as typeof kind)
            setError('')
          }}
        >
          <option value="remote">{t('remote')}</option>
          <option value="local">{t('local')}</option>
        </select>
        <label htmlFor="profile-source">
          {t(kind === 'remote' ? 'url' : 'path')}
        </label>
        <div className="source-input">
          <Input
            key={kind}
            ref={sourceRef}
            id="profile-source"
            name="source"
            type={kind === 'remote' ? 'url' : 'text'}
            required
            aria-describedby={kind === 'local' ? 'path-hint' : undefined}
          />
          {kind === 'local' && window.kuroFiles && (
            <Button
              type="button"
              variant="outline"
              onClick={async () => {
                const path = await window.kuroFiles?.pickProfileFile()
                if (path && sourceRef.current) sourceRef.current.value = path
              }}
            >
              {t('browse')}
            </Button>
          )}
        </div>
        {kind === 'local' && (
          <p id="path-hint" className="muted">
            {t('pathHint')}
          </p>
        )}
        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
        <Button type="submit">{t(busy ? 'importing' : 'importSubmit')}</Button>
      </fieldset>
    </form>
  )
}

function ProfileDetails({
  profile,
  active,
  run,
  busy
}: {
  profile: Profile
  active: boolean
  run: Run
  busy: boolean
}) {
  const [confirmRemove, setConfirmRemove] = useState(false)
  const info = profile.subscriptionInfo
  const used = info ? info.upload + info.download : 0
  return (
    <section className="profile-details" aria-label={profile.name}>
      <div className="profile-actions">
        <Button
          variant="outline"
          size="sm"
          disabled={busy || active}
          onClick={() =>
            void run('setActiveProfile', { profileId: profile.id })
          }
        >
          <Check />
          {t(active ? 'active' : 'activate')}
        </Button>
        <Button
          variant="ghost"
          size="sm"
          disabled={busy}
          onClick={() => void run('updateProfile', { profileId: profile.id })}
        >
          <RefreshCw />
          {t('refresh')}
        </Button>
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label={t('remove')}
          disabled={busy}
          onClick={() => setConfirmRemove(!confirmRemove)}
        >
          <Trash2 />
        </Button>
      </div>
      {confirmRemove && (
        <div className="remove-confirm">
          <p>{t('removeConfirm')}</p>
          <Button
            variant="destructive"
            size="sm"
            disabled={busy}
            onClick={() => void run('removeProfile', { profileId: profile.id })}
          >
            {t('removeSubmit')}
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setConfirmRemove(false)}
          >
            {t('cancel')}
          </Button>
        </div>
      )}
      <p
        className="source-path"
        title={
          profile.source.kind === 'remote'
            ? profile.source.url
            : profile.source.path
        }
      >
        {profile.source.kind === 'remote'
          ? profile.source.url
          : profile.source.path}
      </p>
      <p className="muted">
        {profile.updatedAt === null
          ? t('neverUpdated')
          : t('updatedAt', { date: date(profile.updatedAt) })}
      </p>
      {profile.lastError && (
        <div role="alert" className="inline-error">
          <CircleAlert size={14} />
          <div>
            <strong>{t('updateFailed')}</strong>
            <p>{profile.lastError}</p>
          </div>
        </div>
      )}
      <h3 className="subscription-title">{t('subscriptionInfo')}</h3>
      {info ? (
        <>
          <div className="usage">
            <strong>{formatBytes(used)}</strong>
            <span>{t('used')}</span>
          </div>
          {info.total > 0 && (
            <progress
              value={Math.min(used, info.total)}
              max={info.total}
              aria-label={t('subscriptionInfo')}
            />
          )}
          <dl className="subscription-stats">
            <div>
              <dt>{t('total')}</dt>
              <dd>{info.total > 0 ? formatBytes(info.total) : t('unknown')}</dd>
            </div>
            <div>
              <dt>{t('expires')}</dt>
              <dd>
                {info.expireAt ? date(info.expireAt * 1000) : t('unknown')}
              </dd>
            </div>
          </dl>
        </>
      ) : (
        <p className="muted">{t('noSubscription')}</p>
      )}
    </section>
  )
}

function IntervalForm({
  profile,
  run,
  busy
}: {
  profile: Profile
  run: Run
  busy: boolean
}) {
  const [value, setValue] = useState(
    profile.userUpdateIntervalHours?.toString() ?? ''
  )
  const [error, setError] = useState('')
  async function submit(event: FormEvent) {
    event.preventDefault()
    const hours = value.trim() === '' ? null : Number(value)
    if (hours !== null && (!Number.isFinite(hours) || hours <= 0)) {
      setError(t('invalidInterval'))
      return
    }
    setError('')
    await run('updateSettings', {
      settings: {},
      profileUpdateIntervalHours: { profileId: profile.id, hours }
    })
  }
  return (
    <form className="interval-form" onSubmit={(event) => void submit(event)}>
      <label htmlFor={`interval-${profile.id}`}>
        {profile.name}
        <small>
          {t('intervalValue', {
            hours:
              profile.userUpdateIntervalHours ??
              profile.serverUpdateIntervalHours ??
              24
          })}
        </small>
      </label>
      <Input
        id={`interval-${profile.id}`}
        aria-label={t('intervalLabel', { name: profile.name })}
        type="number"
        min="0"
        step="any"
        value={value}
        onChange={(event) => setValue(event.target.value)}
        placeholder={String(profile.serverUpdateIntervalHours ?? 24)}
        disabled={busy}
      />
      <Button variant="outline" type="submit" size="sm" disabled={busy}>
        {t('save')}
      </Button>
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </form>
  )
}

function SettingsPanel({
  snapshot,
  run,
  busy,
  close
}: {
  snapshot: StateSnapshot
  run: Run
  busy: boolean
  close: () => void
}) {
  const [port, setPort] = useState(String(snapshot.settings.mixedPort))
  const [error, setError] = useState('')
  async function submit(event: FormEvent) {
    event.preventDefault()
    const mixedPort = Number(port)
    if (!Number.isInteger(mixedPort) || mixedPort < 1 || mixedPort > 65535) {
      setError(t('invalidPort'))
      return
    }
    setError('')
    await run('updateSettings', { settings: { mixedPort } })
  }
  return (
    <section className="settings-panel" aria-labelledby="settings-title">
      <div className="section-heading">
        <h2 id="settings-title">{t('settings')}</h2>
        <Button
          variant="ghost"
          size="icon"
          aria-label={t('close')}
          onClick={close}
        >
          <X />
        </Button>
      </div>
      <p className="muted">{t('settingsHint')}</p>
      <form className="port-form" onSubmit={(event) => void submit(event)}>
        <label htmlFor="mixed-port">
          {t('mixedPort')}
          <small id="port-hint">{t('mixedPortHint')}</small>
        </label>
        <Input
          id="mixed-port"
          type="number"
          min="1"
          max="65535"
          step="1"
          required
          aria-describedby="port-hint"
          value={port}
          onChange={(event) => setPort(event.target.value)}
          disabled={busy}
        />
        <Button type="submit" size="sm" disabled={busy}>
          {t('save')}
        </Button>
      </form>
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
      <h3>{t('interval')}</h3>
      <p className="muted">{t('intervalHint')}</p>
      {snapshot.profiles
        .filter((profile) => profile.source.kind === 'remote')
        .map((profile) => (
          <IntervalForm
            key={`${profile.id}-${profile.userUpdateIntervalHours}`}
            profile={profile}
            run={run}
            busy={busy}
          />
        ))}
    </section>
  )
}

export function App({ bridge, demo }: { bridge: StateBridge; demo: boolean }) {
  const { snapshot, error } = useSnapshot(bridge)
  const [busy, setBusy] = useState(false)
  const pending = useRef(false)
  const [notice, setNotice] = useState<{ error: boolean; text: string } | null>(
    null
  )
  const [showImport, setShowImport] = useState(false)
  const [showSettings, setShowSettings] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const run: Run = async (name, input) => {
    if (pending.current) return false
    pending.current = true
    setBusy(true)
    setNotice(null)
    try {
      const result = await bridge.run(name, input)
      setNotice({
        error: !result.ok,
        text: result.ok
          ? t(name === 'updateSettings' ? 'saved' : 'done')
          : t('operationFailed', { error: result.error })
      })
      return result.ok
    } catch (error) {
      setNotice({
        error: true,
        text: t('operationFailed', { error: String(error) })
      })
      return false
    } finally {
      pending.current = false
      setBusy(false)
    }
  }

  if (!snapshot)
    return (
      <main className="connection-state" role={error ? 'alert' : 'status'}>
        <Activity />
        <h1>{t('app')}</h1>
        <p>{error ? t('snapshotFailed', { error }) : t('loading')}</p>
        {error && (
          <Button onClick={() => window.location.reload()}>{t('retry')}</Button>
        )}
      </main>
    )
  const profile =
    snapshot.profiles.find((item) => item.id === selectedId) ??
    snapshot.profiles.find((item) => item.id === snapshot.activeProfileId) ??
    snapshot.profiles[0]
  const activeProfile = snapshot.profiles.find(
    (item) => item.id === snapshot.activeProfileId
  )
  const running = snapshot.core.status === 'running'
  const updateUrl = snapshot.update && releaseUrl(snapshot.update.url)
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <svg aria-hidden="true" viewBox="8 11 84 80">
            <path
              fill="currentColor"
              fillRule="evenodd"
              d="M19 15 39 31Q50 28.5 61 31L81 15Q86.5 11.5 86.5 18L84.5 44Q92 55 89 69Q83 90 50 90Q17 90 11 69Q8 55 15.5 44L13.5 18Q13.5 11.5 19 15ZM24.5 57Q36 49.5 44.5 61Q34 67.5 24.5 57ZM75.5 57Q64 49.5 55.5 61Q66 67.5 75.5 57Z"
            />
            <path
              fill="currentColor"
              d="M35 52.6Q37.2 58.5 35 64.6Q32.8 58.5 35 52.6ZM65 52.6Q67.2 58.5 65 64.6Q62.8 58.5 65 52.6Z"
            />
          </svg>
          <div>
            <strong>{t('app')}</strong>
            <p>{t('tagline')}</p>
          </div>
        </div>
        {demo && (
          <div className="demo-label" title={t('demoHint')}>
            <span className="status-dot" />
            {t('demo')}
          </div>
        )}
        <div className="section-heading profile-heading">
          <h2>
            {t('profiles')}
            <span className="count">{snapshot.profiles.length}</span>
          </h2>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={t('import')}
            aria-expanded={showImport}
            onClick={() => setShowImport(!showImport)}
          >
            <Plus />
          </Button>
        </div>
        {showImport && (
          <ImportForm
            run={run}
            busy={busy}
            close={() => setShowImport(false)}
          />
        )}
        <div className="profile-list" aria-label={t('profiles')}>
          {snapshot.profiles.map((item) => (
            <button
              key={item.id}
              className={`profile-row ${item.id === profile?.id ? 'is-selected' : ''}`}
              onClick={() => setSelectedId(item.id)}
              aria-pressed={item.id === profile?.id}
            >
              <span className="profile-icon">
                {item.source.kind === 'remote' ? (
                  <Globe size={17} />
                ) : (
                  <FolderOpen size={17} />
                )}
              </span>
              <span className="profile-name">
                <strong>{item.name}</strong>
                <small>
                  {item.lastError ? t('updateFailed') : t(item.source.kind)}
                </small>
              </span>
              {item.id === snapshot.activeProfileId ? (
                <Check size={15} aria-label={t('active')} />
              ) : (
                <ChevronRight size={14} />
              )}
            </button>
          ))}
          {!snapshot.profiles.length && (
            <div className="empty-profiles">
              <FileText />
              <h3>{t('noProfiles')}</h3>
              <p>{t('noProfilesHint')}</p>
              <Button size="sm" onClick={() => setShowImport(true)}>
                <Plus />
                {t('import')}
              </Button>
            </div>
          )}
        </div>
        {profile && (
          <ProfileDetails
            key={profile.id}
            profile={profile}
            active={profile.id === snapshot.activeProfileId}
            run={run}
            busy={busy}
          />
        )}
        <div className="sidebar-footer">
          <ShieldCheck size={14} />
          <span>{t('activeProfile')}</span>
          <strong>{activeProfile?.name ?? t('noActive')}</strong>
        </div>
      </aside>
      <main className="workspace">
        <header className="workspace-header">
          <div>
            <h1>{t('workspace')}</h1>
            <p>{t('overview')}</p>
          </div>
          <Button
            variant="outline"
            aria-label={t('settings')}
            aria-expanded={showSettings}
            onClick={() => setShowSettings(!showSettings)}
          >
            <Settings2 />
            <span>{t('settings')}</span>
          </Button>
        </header>
        {demo && <p className="demo-note">{t('demoHint')}</p>}
        <div aria-live="polite">
          {notice && (
            <div
              className={`notice ${notice.error ? 'is-error' : ''}`}
              role={notice.error ? 'alert' : 'status'}
            >
              <span>{notice.text}</span>
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label={t('close')}
                onClick={() => setNotice(null)}
              >
                <X />
              </Button>
            </div>
          )}
        </div>
        {error && (
          <p className="inline-error" role="alert">
            {t('snapshotFailed', { error })}
          </p>
        )}
        {snapshot.update && (
          <div className="update-notice">
            <ArrowDownToLine size={16} />
            <span>
              {t('updateAvailable', { version: snapshot.update.version })}
            </span>
            {updateUrl ? (
              <a href={updateUrl} target="_blank" rel="noreferrer">
                {t('downloadUpdate')}
              </a>
            ) : (
              <span role="alert">{t('unsafeUpdate')}</span>
            )}
          </div>
        )}
        <section className="core-strip" aria-label={t('core')}>
          <div className={`core-symbol ${running ? 'is-running' : ''}`}>
            <Activity size={22} />
          </div>
          <div className="core-summary">
            <strong>
              {t('core')} <span>mihomo</span>
            </strong>
            <p>
              <span className={`status-dot ${running ? 'is-running' : ''}`} />
              {t(snapshot.core.status)}
              <span className="port-number">
                127.0.0.1:{snapshot.settings.mixedPort}
              </span>
            </p>
          </div>
          <Button
            variant="outline"
            size="sm"
            disabled={
              busy ||
              snapshot.core.status === 'starting' ||
              (!running && !activeProfile)
            }
            onClick={() => void run(running ? 'stopCore' : 'startCore', {})}
          >
            <Power />
            {t(running ? 'stopCore' : 'startCore')}
          </Button>
        </section>
        {snapshot.core.error && (
          <p role="alert" className="inline-error">
            <CircleAlert size={16} />
            {snapshot.core.error}
          </p>
        )}
        <section className="connection-controls">
          <fieldset className="mode-control" disabled={busy}>
            <legend>{t('mode')}</legend>
            <div className="mode-options">
              {(['rule', 'global', 'direct'] as const).map((mode) => (
                <label
                  key={mode}
                  className={snapshot.settings.mode === mode ? 'is-active' : ''}
                >
                  <input
                    type="radio"
                    name="mode"
                    value={mode}
                    checked={snapshot.settings.mode === mode}
                    onChange={() => void run('setMode', { mode })}
                  />
                  <span>{t(mode)}</span>
                </label>
              ))}
            </div>
            <p className="muted">{t(`${snapshot.settings.mode}Hint`)}</p>
          </fieldset>
          <div className="system-control">
            <div className="section-heading">
              <label htmlFor="system-proxy">{t('systemProxy')}</label>
              <Switch
                id="system-proxy"
                checked={snapshot.systemProxy.enabled}
                onCheckedChange={(enabled) =>
                  void run('setSystemProxy', { enabled })
                }
                disabled={busy}
                aria-describedby="system-proxy-hint"
              />
            </div>
            <p id="system-proxy-hint" className="muted">
              {t('systemProxyHint')}
            </p>
            <span
              className={`proxy-status ${snapshot.systemProxy.enabled ? 'is-on' : ''}`}
            >
              {t(snapshot.systemProxy.enabled ? 'on' : 'off')}
            </span>
          </div>
        </section>
        {'manualRequired' in snapshot.systemProxy && (
          <p className="manual-notice" role="alert">
            {t('manualRequired', snapshot.systemProxy.manualRequired)}
          </p>
        )}
        {showSettings && (
          <SettingsPanel
            key={snapshot.settings.mixedPort}
            snapshot={snapshot}
            run={run}
            busy={busy}
            close={() => setShowSettings(false)}
          />
        )}
        <section className="groups" aria-labelledby="groups-title">
          <div className="section-heading">
            <h2 id="groups-title">{t('proxyGroups')}</h2>
            <Badge variant="secondary">{snapshot.proxyGroups.length}</Badge>
          </div>
          <p className="muted">{t(running ? 'proxyHint' : 'coreOffline')}</p>
          {!snapshot.proxyGroups.length && (
            <div className="empty-groups">
              <Globe />
              <h3>{t('noGroups')}</h3>
              <p>{t('noGroupsHint')}</p>
            </div>
          )}
          {snapshot.proxyGroups.map((group) => (
            <fieldset
              key={group.name}
              className="proxy-group"
              disabled={busy || !running}
            >
              <legend>
                {group.name}
                <span>{group.type}</span>
              </legend>
              <div className="proxy-options">
                {group.all.map((name) => {
                  const proxy = snapshot.proxies[name]
                  const selected = group.now === name
                  return (
                    <label
                      key={name}
                      className={`proxy-option ${selected ? 'is-active' : ''}`}
                    >
                      <input
                        type="radio"
                        name={`group-${group.name}`}
                        checked={selected}
                        onChange={() =>
                          void run('selectProxy', {
                            group: group.name,
                            proxy: name
                          })
                        }
                      />
                      <span className="proxy-selection">
                        {selected && <Check size={12} />}
                      </span>
                      <span className="proxy-name">
                        <strong>{name}</strong>
                        <small>{proxy?.type ?? t('unknown')}</small>
                      </span>
                      <span
                        className={`delay ${proxy?.delay != null ? 'measured' : ''}`}
                      >
                        {proxy?.delay != null
                          ? t('delay', { value: proxy.delay })
                          : t('untested')}
                      </span>
                    </label>
                  )
                })}
              </div>
            </fieldset>
          ))}
        </section>
        <LivePanel bridge={bridge} running={running} />
      </main>
    </div>
  )
}
