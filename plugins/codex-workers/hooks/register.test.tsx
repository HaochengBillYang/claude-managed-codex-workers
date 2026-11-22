import { expect, test } from 'claude-code/testing'
import {
  activityFromEvents,
  applyLiveness,
  bandCounts,
  formatElapsed,
  groupWorkers,
  parseRun,
  parseUsage,
  workerStatus,
} from './register'
import type { RunRecord, Worker } from '../types'

const RUN: RunRecord = {
  id: '20261121-193012-4242',
  name: 'impl',
  batch: 'rate-limiter smoke',
  effort: 'low',
  sandbox: 'workspace-write',
  pid: 4242,
  status: 'running',
  exit_code: null,
  started_at: 4200,
  ended_at: null,
  events: '/fixtures/impl.md.events.jsonl',
  result: '/fixtures/impl.md.result',
}

function worker(record: Partial<RunRecord>, lostAt: number | null = null): Worker {
  return { record: { ...RUN, ...record }, activity: '', lostAt, resultLine: '' }
}

function event(item: object, type = 'item.completed'): string {
  return JSON.stringify({ type, item })
}

test('a tail uses the latest meaningful item through partial and lifecycle lines', () => {
  const tail = [
    'tail of an earlier line}',
    event({ type: 'reasoning' }),
    event({ type: 'command_execution', command: "/bin/zsh -lc 'ruby -Ilib -e test'" }, 'item.started'),
    '{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":2}}',
    event({ type: 'agent_message', text: '' }),
    '{"type":"item.comp',
  ].join('\n')
  expect(activityFromEvents(tail, true)).toBe('$ ruby -Ilib -e test')
  expect(activityFromEvents(event({ type: 'reasoning' }), true)).toBe(undefined)
})

test('activity formats messages, edits, reasoning and arbitrary item types', () => {
  expect(activityFromEvents(event({ type: 'agent_message', text: 'Added tests\r\nSecond line' }))).toBe('Added tests')
  expect(activityFromEvents(event({
    type: 'file_change',
    changes: [{ path: 'lib/a.rb', kind: 'update' }, { path: 'test/a.rb', kind: 'add' }],
  }))).toBe('edit lib/a.rb, test/a.rb')
  expect(activityFromEvents(event({ type: 'reasoning' }))).toBe('thinking…')
  expect(activityFromEvents(event({ type: 'mcp_tool_call' }, 'item.updated'))).toBe('mcp_tool_call')
  expect(activityFromEvents(event({ type: 'command_execution', command: "printf 'hello'" }))).toBe("$ printf 'hello'")
})

test('elapsed clocks pad mm:ss, add hours as needed and clamp negative differences', () => {
  expect(formatElapsed(100, 183.99)).toBe('01:23')
  expect(formatElapsed(100, 3699)).toBe('59:59')
  expect(formatElapsed(100, 3700)).toBe('1:00:00')
  expect(formatElapsed(100, 99)).toBe('00:00')
})

test('the pane filters on the 30-minute boundary and sorts batches and workers', () => {
  const old = worker({ name: 'old', started_at: 2900, ended_at: 3199, status: 'done' })
  const atBoundary = worker({ name: 'tests', started_at: 3100, ended_at: 3200, status: 'done' })
  const live = worker({ name: 'impl', started_at: 4400 })
  const newest = worker({ name: 'gui', batch: 'adhoc', started_at: 4600, ended_at: 4612, status: 'failed' })
  const groups = groupWorkers([live, old, newest, atBoundary], 5000)
  expect(groups.map(group => [group.batch, group.workers.map(item => item.record.name)])).toEqual([
    ['adhoc', ['gui']],
    ['rate-limiter smoke', ['tests', 'impl']],
  ])
})

test('when all runs are old, the pane shows all members of the latest batch', () => {
  const first = worker({ name: 'first', started_at: 100, ended_at: 110, status: 'done' })
  const second = worker({ name: 'second', started_at: 300, ended_at: 330, status: 'killed' })
  const other = worker({ batch: 'other', started_at: 200, ended_at: 210, status: 'failed' })
  const groups = groupWorkers([other, second, first], 5000)
  expect(groups.map(group => [group.batch, group.workers.map(item => item.record.name)])).toEqual([
    ['rate-limiter smoke', ['first', 'second']],
  ])
  expect(groupWorkers([], 5000)).toEqual([])
})

test('the band counts running workers and outcomes at the 60-second boundary', () => {
  const done = worker({ status: 'done', ended_at: 4940 })
  const old = worker({ status: 'failed', ended_at: 4939 })
  const killed = worker({ status: 'killed', ended_at: 4999 })
  const lost = worker({}, 4998)
  expect(bandCounts([worker({}), done, old, killed, lost], 5000)).toEqual({
    running: 1, done: 1, failed: 0, killed: 1, lost: 1,
  })
})

test('usage reads percentages, reset labels and machine status details', () => {
  const windows = [
    'Codex usage (snapshot 2 min old)',
    '  5-hour window: 9% used, resets Sat Nov 21 23:10',
    '  Weekly window: 16% used (60% of week elapsed), resets Tue Nov 24 14:49',
  ].join('\n')
  expect(parseUsage(windows + '\nSTATUS=OK\n')).toEqual({
    fiveHour: { percent: 9, resets: 'Sat Nov 21 23:10' },
    weekly: { percent: 16, resets: 'Tue Nov 24 14:49' },
    status: 'OK',
    until: null,
    reason: null,
  })
  expect(parseUsage('STATUS=THROTTLE REASON=weekly ahead').status).toBe('THROTTLE')
  expect(parseUsage('STATUS=THROTTLE REASON=weekly ahead').reason).toBe('weekly ahead')
  expect(parseUsage('STATUS=BLOCKED UNTIL=1795300212 REASON=5h_limit')).toEqual({
    fiveHour: null, weekly: null, status: 'BLOCKED', until: 1795300212, reason: '5h_limit',
  })
  expect(parseUsage('No snapshot available\nSTATUS=UNKNOWN').status).toBe('UNKNOWN')
  expect(parseUsage('truncated output').status).toBe('UNKNOWN')
})

test('a dead running pid becomes lost until a live check or a final record supersedes it', () => {
  const lostAt = applyLiveness(RUN, null, false, 5000)
  expect(lostAt).toBe(5000)
  expect(workerStatus(worker({}, lostAt))).toBe('lost')
  expect(applyLiveness(RUN, lostAt, undefined, 5001)).toBe(5000)
  expect(applyLiveness(RUN, lostAt, false, 5005)).toBe(5000)
  expect(applyLiveness(RUN, lostAt, true, 5010)).toBe(null)
  const finished = { ...RUN, status: 'done', ended_at: 5011 } as const
  expect(applyLiveness(finished, lostAt, false, 5012)).toBe(null)
  expect(workerStatus(worker(finished, lostAt))).toBe('done')
})

test('run records reject partial data, mismatched ids and unsafe pids', () => {
  expect(parseRun(JSON.stringify(RUN), RUN.id)).toEqual(RUN)
  expect(parseRun('{"id":', RUN.id)).toBe(undefined)
  expect(parseRun(JSON.stringify(RUN), '20261121-193012-1111')).toBe(undefined)
  expect(parseRun(JSON.stringify({ ...RUN, pid: -1 }), RUN.id)).toBe(undefined)
})

test('the live poll drives the terminal pane, band, auto-open and command toggle', async ($, on) => {
  const pane = {
    plugin: 'codex-workers',
    component: 'Pane',
    requestId: 'codex-workers',
    surface: 'terminal',
    props: {
      title: 'Codex workers', bodyColumns: 84, isFocused: false, placement: 'dock',
      scroll: { offset: 0, bodyRows: 20 }, view: {},
    },
  } as const
  const band = {
    plugin: 'codex-workers',
    component: 'AbovePrompt',
    surface: 'terminal',
    props: {
      bodyColumns: 84, hasSurvey: false, isCollapsed: false, isWorking: false,
      maxRows: 4, scroll: { offset: 0, bodyRows: 4 }, view: {},
    },
  } as const
  let record = RUN
  let now = 5000
  let isOpen = false
  let opens = 0
  let usageCalls = 0
  let pidChecks = 0
  const tailReads: { offset?: number; length?: number }[] = []
  let tick = () => {}
  let timerRegistered = () => {}
  let paneOpened = () => {}
  const firstTimer = new Promise<void>(resolve => { timerRegistered = resolve })
  const firstOpen = new Promise<void>(resolve => { paneOpened = resolve })
  on('command.register', () => ({ value: { command: 'codex-workers' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.every', (_, e) => {
    expect(e.ms).toBe(1000)
    return new Promise<{ value: undefined }>(resolve => {
      tick = () => resolve({ value: undefined })
      timerRegistered()
    })
  })
  on('clock.now', () => ({ value: now * 1000 }))
  on('fs.list', () => ({
    value: [{ name: RUN.id + '.json', kind: 'file', size: 1, mtimeMs: 0, isLink: false }],
  }))
  on('fs.stat', (_, e) => {
    expect(e.path).toBe(RUN.events)
    return { value: { kind: 'file', size: 70000, mtimeMs: 0, isLink: false } }
  })
  on('fs.read', (_, e) => {
    if (e.path === RUN.events) {
      tailReads.push({ offset: e.offset, length: e.length })
      return { value: 'partial\n' + event({ type: 'command_execution', command: '/bin/zsh -lc "ls"' }) + '\n' }
    }
    if (e.path === RUN.result) return { value: 'Added fixture tests\nFurther details' }
    expect(e.path.endsWith('/' + RUN.id + '.json')).toBe(true)
    return { value: JSON.stringify(record) }
  })
  on('process.run', (_, e) => {
    if (e.argv[0] === '/usr/bin/printenv') {
      return { value: { exitCode: 0, stdout: '/Users/test\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    const isKill = e.argv[0] === '/bin/kill'
    if (isKill) {
      expect(e.argv.slice(1)).toEqual(['-0', '4242'])
      pidChecks += 1
    } else {
      expect(e.argv[0]?.endsWith('/codex-usage.sh')).toBe(true)
      usageCalls += 1
    }
    const stdout = isKill ? '' : [
      '5-hour window: 9% used, resets Sat Nov 21 23:10',
      'Weekly window: 16% used, resets Tue Nov 24 14:49',
      record.status === 'running' ? 'STATUS=THROTTLE REASON=weekly pace' : 'STATUS=OK',
    ].join('\n')
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', () => {
    isOpen = true
    opens += 1
    paneOpened()
    return { value: { isPlaced: true } }
  })
  on('ui.close', () => {
    isOpen = false
    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: isOpen ? [{
      id: 'codex-workers', title: 'Codex workers', isShown: true, isFocused: false, isPlaced: true,
    }] : [],
  }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await firstTimer
  tick()
  const paneUi = await $.ui.mount(pane)
  async function waitForRow(text: RegExp) {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const row = await paneUi.find({ type: 'Text', text })
      if (row) return row.text
      await paneUi.redraw()
    }
    throw new Error('Missing pane row ' + text)
  }
  expect(await waitForRow(/THROTTLE/)).toBe('THROTTLE')
  expect(await waitForRow(/\$ ls/)).toMatch(/impl.*low · ws.*13:20/)
  await firstOpen
  expect(opens).toBe(1)
  expect(pidChecks).toBe(1)
  expect(tailReads).toEqual([{ offset: 4464, length: 65536 }])
  const bandUi = await $.ui.mount(band)
  expect((await bandUi.find({ type: 'Text', text: /Codex/ }))?.text)
    .toMatch(/1 running │ 5h 9% · wk 16% │ \/codex-workers/)

  // Let the first tick see a terminal record only one second later.
  record = { ...RUN, status: 'done', exit_code: 0, ended_at: 5001 }
  now = 5001
  tick()
  expect(await waitForRow(/Added fixture tests/)).toMatch(/✓.*13:21/)
  expect(await waitForRow(/^OK$/)).toBe('OK')
  expect(pidChecks).toBe(1)
  expect(tailReads.length).toBe(1)
  expect(usageCalls).toBe(2)
  await bandUi.redraw()
  expect((await bandUi.find({ type: 'Text', text: /Codex/ }))?.text).toMatch(/Codex 1 done/)

  const command = {
    command: 'codex-workers', args: '', origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 160 },
  } as const
  expect((await $.command.run(command)).text).toBe('Codex workers pane closed.')
  expect(isOpen).toBe(false)
  expect((await $.command.run(command)).text).toBe('Codex workers pane opened.')
  expect(opens).toBe(2)
  await paneUi.unmount()
  await bandUi.unmount()
})
