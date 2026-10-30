import type { HttpRequest, HttpResponse, StreamHandle, Transport } from './index'

type Handler = (req: HttpRequest) => HttpResponse | Promise<HttpResponse>

/** Scriptable Transport: register handlers by `METHOD path`, push stream frames by path. */
export class FakeTransport implements Transport {
  requests: HttpRequest[] = []
  private handlers = new Map<string, Handler>()
  private streams = new Map<string, Set<(data: unknown) => void>>()
  private closers = new Map<(data: unknown) => void, (error?: Error) => void>()

  on(method: HttpRequest['method'], path: string, handler: Handler | HttpResponse) {
    this.handlers.set(`${method} ${path}`, typeof handler === 'function' ? handler : () => handler)
    return this
  }

  async request(req: HttpRequest) {
    this.requests.push(req)
    const h = this.handlers.get(`${req.method} ${req.path}`)
    if (!h) return { status: 404, body: { message: `fake: no handler for ${req.method} ${req.path}` } }
    return h(req)
  }

  stream(path: string, onMessage: (data: unknown) => void, onClose?: (error?: Error) => void): StreamHandle {
    const set = this.streams.get(path) ?? new Set()
    this.streams.set(path, set)
    set.add(onMessage)
    if (onClose) this.closers.set(onMessage, onClose)
    return { close: () => { set.delete(onMessage); this.closers.delete(onMessage) } }
  }

  /** Test helper: simulate Core closing every stream on `path`. */
  drop(path: string, error?: Error) {
    for (const fn of [...(this.streams.get(path) ?? [])]) {
      this.streams.get(path)!.delete(fn)
      const onClose = this.closers.get(fn)
      this.closers.delete(fn)
      onClose?.(error)
    }
  }

  /** Test helper: deliver a frame to every open stream on `path`. */
  push(path: string, data: unknown) {
    for (const fn of this.streams.get(path) ?? []) fn(data)
  }

  openStreams(path: string) {
    return this.streams.get(path)?.size ?? 0
  }
}
