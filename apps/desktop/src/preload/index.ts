import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron'
import type { LogEntry, Traffic } from '@kuro/api'
import type { CommandInput, CommandName, CommandResult, StateBridge, StateSnapshot } from '@kuro/state'
import { IPC, type StreamKind } from '../main/ipc-channels'

// Each renderer-side subscription is one main-side subscriber, so main can ref-count Core streams.
function stream<T>(kind: StreamKind, channel: string, listener: (value: T) => void): () => void {
  const id = crypto.randomUUID()
  const handler = (_: IpcRendererEvent, subId: string, value: T) => { if (subId === id) listener(value) }
  ipcRenderer.on(channel, handler)
  ipcRenderer.send(IPC.streamSubscribe, kind, id)
  return () => {
    ipcRenderer.removeListener(channel, handler)
    ipcRenderer.send(IPC.streamUnsubscribe, id)
  }
}

const bridge: StateBridge = {
  getSnapshot: () => ipcRenderer.invoke(IPC.getSnapshot) as Promise<StateSnapshot>,
  subscribe(listener) {
    const handler = (_: IpcRendererEvent, snapshot: StateSnapshot) => listener(snapshot)
    ipcRenderer.on(IPC.snapshot, handler)
    return () => void ipcRenderer.removeListener(IPC.snapshot, handler)
  },
  run: <K extends CommandName>(name: K, input: CommandInput<K>) =>
    ipcRenderer.invoke(IPC.run, name, input) as Promise<CommandResult<K>>,
  subscribeTraffic: (listener) => stream<Traffic>('traffic', IPC.traffic, listener),
  subscribeLogs: (listener) => stream<LogEntry>('logs', IPC.logs, listener)
}

contextBridge.exposeInMainWorld('kuro', bridge)
contextBridge.exposeInMainWorld('kuroFiles', {
  pickProfileFile: () => ipcRenderer.invoke(IPC.pickProfileFile) as Promise<string | null>
})
