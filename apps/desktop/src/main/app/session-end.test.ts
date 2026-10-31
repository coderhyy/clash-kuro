import { EventEmitter } from 'node:events'
import { expect, test, vi } from 'vitest'
import { watchSessionEnd } from './session-end'

const sessionEvent = (reasons: string[]) => ({ reasons, preventDefault: vi.fn() })

test('query-session-end starts cleanup without delaying the session end', () => {
  const source = new EventEmitter()
  const onEnd = vi.fn()
  watchSessionEnd(source, onEnd)
  const event = sessionEvent(['logoff'])
  source.emit('query-session-end', event)
  expect(onEnd).toHaveBeenCalledWith('query-session-end', ['logoff'])
  expect(event.preventDefault).not.toHaveBeenCalled()
})

test('session-end calls cleanup again as a fallback', () => {
  const source = new EventEmitter()
  const onEnd = vi.fn()
  watchSessionEnd(source, onEnd)
  source.emit('query-session-end', sessionEvent(['shutdown']))
  const event = sessionEvent(['shutdown'])
  source.emit('session-end', event)
  expect(onEnd.mock.calls).toEqual([['query-session-end', ['shutdown']], ['session-end', ['shutdown']]])
  expect(event.preventDefault).not.toHaveBeenCalled()
})
