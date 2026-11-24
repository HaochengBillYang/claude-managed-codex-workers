import { expect, test } from 'claude-code/testing'
import type { SessionUsage } from 'claude-code'
import {
  activityFromEvents,
  applyLiveness,
  bandCounts,
  claudeUsageFile,
  detectDrift,
  isNewerVersion,
  usageFileState,
  planUsageFileWrite,
  extractClaudeUsage,
  formatClaudeReset,
  formatElapsed,
  groupWorkers,
  layoutBand,
  parseRun,
  parseUsage,
  percentColor,
  shortModel,
  workerRow,
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

const CLAUDE_USAGE: SessionUsage = {
  startedAt: 4200000,
  context: { window: 200000, percent: 38 },
  rateLimits: [{ kind: 'five_hour', percentUsed: 23 }, { kind: 'seven_day', percentUsed: 41 }],
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

test('the band counts running workers and outcomes less than 60 seconds old', () => {
  const done = worker({ status: 'done', ended_at: 4941 })
  const old = worker({ status: 'failed', ended_at: 4940 })
  const killed = worker({ status: 'killed', ended_at: 4999 })
  const lost = worker({}, 4998)
  expect(bandCounts([worker({}), done, old, killed, lost], 5000)).toEqual({
    running: 1, done: 1, failed: 0, killed: 1, lost: 1,
  })
})

test('the band drops context, drops the hint, compacts and then truncates', () => {
  const claude = extractClaudeUsage(CLAUDE_USAGE)
  const codex = parseUsage('5-hour window: 17% used, resets 23:10\nWeekly window: 17% used, resets Tue 14:49\nSTATUS=OK')
  const layout = (columns: number) => layoutBand([], 5000, claude, codex, columns).map(segment => segment.text).join('')
  const wide = 'Claude 5h 23% · wk 41% · ctx 38% │ Codex idle · 5h 17% · wk 17% │ /codex-workers'
  const noContext = 'Claude 5h 23% · wk 41% │ Codex idle · 5h 17% · wk 17% │ /codex-workers'
  const noHint = 'Claude 5h 23% · wk 41% │ Codex idle · 5h 17% · wk 17%'
  const compact = 'C 23%/41% │ X idle 17%/17%'
  expect(layout(wide.length)).toBe(wide)
  expect(layout(wide.length - 1)).toBe(noContext)
  expect(layout(noContext.length - 1)).toBe(noHint)
  expect(layout(noHint.length - 1)).toBe(compact)
  expect(layout(compact.length)).toBe(compact)
  expect(layout(compact.length - 1)).toBe('C 23%/41% │ X idle 17%/1…')
  expect(layout(1)).toBe('…')
  expect(layout(0)).toBe('')

  const withResets = parseUsage('5-hour window: 17% used, resets 23:10\nWeekly window: 17% used, resets Tue 14:49\nSTATUS=OK RESETS=2 ADVICE=REDEEM_OPTIONAL')
  const resetLayout = (columns: number) => layoutBand([], 5000, claude, withResets, columns)
  const wideWithResets = wide.replace(' │ /codex-workers', ' · ↺2 │ /codex-workers')
  for (const [columns, expected] of [
    [wideWithResets.length, wideWithResets],
    [wide.length, noContext.replace(' │ /codex-workers', ' · ↺2 │ /codex-workers')],
    [noContext.length - 1, noHint + ' · ↺2'],
    [noHint.length - 1, compact + ' ↺2'],
    [compact.length, 'C 23%/41% │ X idle 17%… ↺2'],
  ] as const) {
    const row = resetLayout(columns)
    expect(row.map(segment => segment.text).join('')).toBe(expected)
    expect(row.find(segment => segment.text === '↺2')?.color).toBe('yellow')
  }
})

test('the band keeps worker summaries and displays missing figures', () => {
  const claude = extractClaudeUsage({ ...CLAUDE_USAGE, rateLimits: [CLAUDE_USAGE.rateLimits[0]!] })
  const codex = parseUsage('')
  const active = [worker({}), worker({}), worker({ status: 'done', ended_at: 4999 })]
  const text = (row: ReturnType<typeof layoutBand>) => row.map(segment => segment.text).join('')
  expect(text(layoutBand(active, 5000, claude, codex, 100)))
    .toBe('Claude 5h 23% · wk — · ctx 38% │ Codex ⠋ 2 running · 1 done · 5h — · wk — │ /codex-workers')
  expect(text(layoutBand(active, 5000, claude, codex, 40))).toBe('C 23%/— │ X ⠋ 2 running · 1 done —/—')
  const api = extractClaudeUsage({ ...CLAUDE_USAGE, rateLimits: [] })
  expect(text(layoutBand([], 5000, api, codex, 84)))
    .toBe('Claude ctx 38% │ Codex idle · 5h — · wk — │ /codex-workers')
  expect(text(layoutBand([], 5000, api, codex, 28))).toBe('C ctx 38% │ X idle —/—')
})

test('usage thresholds color every percentage and the Codex status label', () => {
  expect([null, 0, 69.9, 70, 89.9, 90, 100].map(percentColor))
    .toEqual([undefined, undefined, undefined, 'yellow', 'yellow', 'red', 'red'])
  const claude = extractClaudeUsage({
    ...CLAUDE_USAGE,
    context: { window: 200000, percent: 91 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 70 }, { kind: 'seven_day', percentUsed: 69.9 }],
  })
  const codex = parseUsage('5-hour window: 90% used, resets 23:10\nWeekly window: 89% used, resets Tue 14:49\nSTATUS=THROTTLE')
  const colored = (row: ReturnType<typeof layoutBand>) => row.filter(segment => segment.color)
    .map(({ text, color }) => [text, color])
  expect(colored(layoutBand([], 5000, claude, codex, 100))).toEqual([
    ['70%', 'yellow'], ['91%', 'red'], ['Codex', 'yellow'], ['90%', 'red'], ['89%', 'yellow'],
  ])
  expect(colored(layoutBand([], 5000, claude, { ...codex, status: 'BLOCKED' }, 35))).toEqual([
    ['70%', 'yellow'], ['X', 'red'], ['90%', 'red'], ['89%', 'yellow'],
  ])
})

test('Claude usage extracts the supported windows, context and USD cost', () => {
  const snapshot: SessionUsage = {
    ...CLAUDE_USAGE,
    rateLimits: [
      { kind: 'spend_limit', percentUsed: 102 },
      { kind: 'seven_day', percentUsed: 0, resetsAt: '2026-11-24T20:49:00Z' },
    ],
    cost: { usd: 1.25, hasUnknownPrice: true },
  }
  expect(extractClaudeUsage(snapshot)).toEqual({
    fiveHour: null, weekly: { percent: 0, resetsAt: '2026-11-24T20:49:00Z' }, contextPercent: 38, costUsd: 1.25,
  })
  expect(extractClaudeUsage(CLAUDE_USAGE)).toEqual({
    fiveHour: { percent: 23, resetsAt: null }, weekly: { percent: 41, resetsAt: null }, contextPercent: 38, costUsd: null,
  })
  expect(extractClaudeUsage({ context: { window: 200000 }, rateLimits: [] })).toEqual({
    fiveHour: null, weekly: null, contextPercent: null, costUsd: null,
  })
})

test('Claude resets use local time and add the weekday at 24 hours', () => {
  const reset = new Date(2026, 10, 24, 4, 9)
  const iso = reset.toISOString()
  const day = 24 * 60 * 60 * 1000
  expect(formatClaudeReset(iso, reset.getTime() - day + 1)).toBe('04:09')
  expect(formatClaudeReset(iso, reset.getTime() - day)).toBe('Tue 04:09')
  expect(formatClaudeReset(iso, reset.getTime() - 2 * day)).toBe('Tue 04:09')
  expect(formatClaudeReset('invalid', reset.getTime())).toBe('')
  expect(formatClaudeReset(null, reset.getTime())).toBe('')
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
    resets: null,
    advice: null,
    status: 'OK',
    until: null,
    reason: null,
  })
  expect(parseUsage('STATUS=THROTTLE REASON=weekly ahead').status).toBe('THROTTLE')
  expect(parseUsage('STATUS=THROTTLE REASON=weekly ahead').reason).toBe('weekly ahead')
  expect(parseUsage('STATUS=BLOCKED UNTIL=1795300212 REASON=5h_limit')).toEqual({
    fiveHour: null, weekly: null, resets: null, advice: null,
    status: 'BLOCKED', until: 1795300212, reason: '5h_limit',
  })
  expect(parseUsage('No snapshot available\nSTATUS=UNKNOWN').status).toBe('UNKNOWN')
  expect(parseUsage('truncated output').status).toBe('UNKNOWN')
})

test('usage reads banked resets, optional expiry and redemption advice', () => {
  const usage = parseUsage([
    '  Banked resets: 2 (expire Tue Dec 01) - restore 5h + weekly; user redeems via Codex Usage settings or /usage',
    'STATUS=BLOCKED UNTIL=1795300212 RESETS=3 ADVICE=REDEEM_BEFORE_EXPIRY REASON=5h limit',
  ].join('\n'))
  expect(usage.resets).toEqual({ count: 2, expires: 'Tue Dec 01' })
  expect(usage.advice).toBe('REDEEM_BEFORE_EXPIRY')
  expect(usage.until).toBe(1795300212)
  expect(usage.reason).toBe('5h limit')
  expect(parseUsage('  Banked resets: 1 - restore 5h + weekly\nSTATUS=OK').resets)
    .toEqual({ count: 1, expires: null })
  expect(parseUsage('STATUS=OK RESETS=3').resets).toEqual({ count: 3, expires: null })
  expect(parseUsage('STATUS=OK RESETS=0').resets).toBe(null)
  const reasonOnly = parseUsage('STATUS=OK REASON=mentions RESETS=3 ADVICE=REDEEM_OPTIONAL')
  expect(reasonOnly.resets).toBe(null)
  expect(reasonOnly.advice).toBe(null)
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

test('high-effort records show their model compactly; records without a model still load', () => {
  const high = parseRun(JSON.stringify({ ...RUN, effort: 'high', model: 'gpt-6.2-astra' }), RUN.id)
  expect(high).toEqual({ ...RUN, effort: 'high', model: 'gpt-6.2-astra' })
  const highRow = workerRow({ record: high!, activity: 'drafting', lostAt: null, resultLine: '' }, 4260, 120, 8)
  expect(highRow).toMatch(/impl\s+high · astra · ws\s+01:00\s+drafting/)

  // RUN predates codex-run.sh recording the model: it has no model key at all.
  const old = parseRun(JSON.stringify(RUN), RUN.id)
  expect(old).toEqual(RUN)
  expect(old && 'model' in old).toBe(false)
  const oldRow = workerRow({ record: old!, activity: '', lostAt: null, resultLine: '' }, 4260, 120, 8)
  expect(oldRow).toMatch(/impl\s+low · ws\s+01:00/)
  expect(oldRow).not.toMatch(/·\s*·/)

  expect(shortModel('gpt-6.2-sol')).toBe('sol')
  expect(shortModel('gpt-6.2-')).toBe('gpt-6.2-')
  expect(shortModel('o5-mini')).toBe('o5-mini')
  expect(parseRun(JSON.stringify({ ...RUN, effort: 'max' }), RUN.id)).toBe(undefined)
  expect(parseRun(JSON.stringify({ ...RUN, model: 42 }), RUN.id)).toEqual(RUN)
})

test('the Claude usage file plan needs both windows, skips unchanged values and refreshes on a heartbeat', () => {
  const reset5h = '2026-11-23T10:00:00.000Z'
  const resetWk = '2026-11-28T00:00:00.000Z'
  const usage = (fivePct: number) => extractClaudeUsage({
    context: { window: 200000, percent: 10 },
    rateLimits: [
      { kind: 'five_hour', percentUsed: fivePct, resetsAt: reset5h },
      { kind: 'seven_day', percentUsed: 30, resetsAt: resetWk },
    ],
  })
  const state = usageFileState('/home/u/.claude/claude-usage.json')
  // What writeClaudeUsageFile records after a successful mv.
  const written = (plan: ReturnType<typeof planUsageFileWrite>) => {
    state.lastKey = plan!.key
    state.lastWrite = plan!.now
    return JSON.parse(plan!.text)
  }

  const first = planUsageFileWrite(state, usage(12), 1000.7)
  expect(first?.tmp).toBe('/home/u/.claude/claude-usage.json.tmp')
  expect(first?.path).toBe('/home/u/.claude/claude-usage.json')
  expect(first?.text.endsWith('\n')).toBe(true)
  expect(written(first)).toEqual({
    five_hour_pct: 12, five_hour_resets_at: Date.parse(reset5h) / 1000,
    weekly_pct: 30, weekly_resets_at: Date.parse(resetWk) / 1000, updated_at: 1000,
  })

  expect(planUsageFileWrite(state, usage(12), 1100)).toBe(undefined)   // unchanged, inside the heartbeat
  expect(written(planUsageFileWrite(state, usage(13), 1100)).five_hour_pct).toBe(13)   // changed
  expect(planUsageFileWrite(state, usage(13), 1399)).toBe(undefined)
  expect(written(planUsageFileWrite(state, usage(13), 1400)).updated_at).toBe(1400)   // heartbeat due

  // Without a recorded success (a failed mv), the same values are planned again.
  expect(planUsageFileWrite(state, usage(14), 1401)).not.toBe(undefined)
  expect(planUsageFileWrite(state, usage(14), 1402)).not.toBe(undefined)

  // A partial reading (one window) is never written; unparseable resets become null.
  const partial = extractClaudeUsage({ context: { window: 1, percent: 1 }, rateLimits: [{ kind: 'five_hour', percentUsed: 99 }] })
  expect(planUsageFileWrite(state, partial, 2000)).toBe(undefined)
  expect(claudeUsageFile(extractClaudeUsage({
    context: { window: 1, percent: 1 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 1, resetsAt: 'soon' }, { kind: 'seven_day', percentUsed: 2 }],
  }))).toEqual({ five_hour_pct: 1, five_hour_resets_at: null, weekly_pct: 2, weekly_resets_at: null })
})

test('plugin versions compare dotted numeric components', () => {
  expect(isNewerVersion('0.2.10', '0.2.9')).toBe(true)
  expect(isNewerVersion('0.2.9', '0.2.10')).toBe(false)
  expect(isNewerVersion('0.2.5', '0.2.5')).toBe(false)
  expect(isNewerVersion(undefined, '0.2.5')).toBe(false)
  expect(isNewerVersion('0.2.5', undefined)).toBe(false)
  expect(isNewerVersion('garbage', '0.2.5')).toBe(false)
  expect(isNewerVersion('0.2.5', '0.2.x')).toBe(false)
})

test('drift reads the installed registry and prefers the user scope', async () => {
  let registry: string | undefined
  let pathRead = ''
  const fs = {
    async read(path: string) {
      pathRead = path
      if (registry === undefined) throw new Error('File missing')
      return registry
    },
  }
  const check = () => detectDrift(fs.read, '/home/u', '0.2.9')
  expect(await check()).toBe(null)
  expect(pathRead).toBe('/home/u/.claude/plugins/installed_plugins.json')
  registry = '{'
  expect(await check()).toBe(null)
  registry = JSON.stringify({ plugins: { 'another-plugin@market': [{ version: '9.0.0' }] } })
  expect(await check()).toBe(null)
  const project = { scope: 'project', version: '0.2.11' }
  const user = { scope: 'user', version: '0.2.10' }
  registry = JSON.stringify({ plugins: { 'codex-workers@market': [project, user] } })
  expect(await check()).toEqual({ loaded: '0.2.9', installed: '0.2.10' })
  registry = JSON.stringify({ plugins: { 'codex-workers@market': [project, { ...user, version: 'bad' }] } })
  expect(await check()).toBe(null)
  registry = JSON.stringify({ plugins: { 'codex-workers@market': [project, { scope: 'local', version: '0.2.12' }] } })
  expect(await check()).toEqual({ loaded: '0.2.9', installed: '0.2.11' })
})

test('the live poll drives the terminal pane, band, auto-open and command toggle', async ($, on) => {
  const pane = {
    plugin: 'codex-workers',
    component: 'Pane',
    requestId: 'codex-workers',
    surface: 'terminal',
    props: {
      title: 'Codex workers', bodyColumns: 120, isFocused: false, placement: 'dock',
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
  let claudeUsageCalls = 0
  let measured = 0
  let claudeSnapshot = CLAUDE_USAGE
  let pidChecks = 0
  let manifestReads = 0
  let registryReads = 0
  let installed = '0.2.4'
  const tailReads: { offset?: number; length?: number }[] = []
  const usageFileWrites: { path: string; text: string }[] = []
  const moves: string[][] = []
  let tick = () => {}
  let timerRegistered = () => {}
  let paneOpened = () => {}
  const firstTimer = new Promise<void>(resolve => { timerRegistered = resolve })
  const firstOpen = new Promise<void>(resolve => { paneOpened = resolve })
  on('command.register', () => ({ value: { command: 'codex-workers' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.usage', () => {
    claudeUsageCalls += 1
    return { value: claudeSnapshot }
  })
  on('session.measure', (_, e) => {
    measured += 1
    expect(e.context.percent).toBe(91)
    return { changed: e.changed }
  })
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
    if (e.path.endsWith('/.claude-plugin/plugin.json')) {
      manifestReads += 1
      return { value: JSON.stringify({ version: '0.2.4' }) }
    }
    if (e.path === '/Users/test/.claude/plugins/installed_plugins.json') {
      registryReads += 1
      return { value: JSON.stringify({ plugins: { 'codex-workers@market': [{ scope: 'user', version: installed }] } }) }
    }
    if (e.path === RUN.events) {
      tailReads.push({ offset: e.offset, length: e.length })
      return { value: 'partial\n' + event({ type: 'command_execution', command: '/bin/zsh -lc "ls"' }) + '\n' }
    }
    if (e.path === RUN.result) return { value: 'Added fixture tests\nFurther details' }
    expect(e.path.endsWith('/' + RUN.id + '.json')).toBe(true)
    return { value: JSON.stringify(record) }
  })
  on('fs.write', (_, e) => {
    usageFileWrites.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('process.run', (_, e) => {
    if (e.argv[0] === '/usr/bin/printenv') {
      return { value: { exitCode: 0, stdout: '/Users/test\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (e.argv[0] === '/bin/mv') {
      moves.push([...e.argv])
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
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
      ...(record.status === 'running' ? [
        '  Banked resets: 2 (expire Tue Dec 01) - restore 5h + weekly',
        'STATUS=THROTTLE RESETS=2 ADVICE=REDEEM_BEFORE_EXPIRY REASON=weekly pace',
      ] : ['STATUS=OK RESETS=1']),
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
  expect(claudeUsageCalls).toBe(1)
  // The start-up reading has both windows, so it lands on disk via a temp file and mv.
  expect(usageFileWrites).toEqual([{
    path: '/Users/test/.claude/claude-usage.json.tmp',
    text: JSON.stringify({ five_hour_pct: 23, five_hour_resets_at: null, weekly_pct: 41, weekly_resets_at: null, updated_at: 5000 }) + '\n',
  }])
  expect(moves).toEqual([['/bin/mv', '-f', '/Users/test/.claude/claude-usage.json.tmp', '/Users/test/.claude/claude-usage.json']])
  const bandUi = await $.ui.mount(band)
  async function bandText() {
    return (await bandUi.findAll({ type: 'Text' })).map(item => item.text).join('')
  }
  expect(await bandText()).toBe('Claude 5h 23% · wk 41% · ctx 38% │ Codex idle · 5h — · wk — │ /codex-workers')
  await bandUi.redraw({ ...band.props, hasSurvey: true })
  expect(await bandUi.find({ type: 'Text', text: /Codex/ })).toBe(undefined)
  await bandUi.redraw(band.props)

  const measure = {
    context: { window: 200000, percent: 91 },
    rateLimits: [
      { kind: 'five_hour', percentUsed: 70, resetsAt: new Date((now + 600) * 1000).toISOString() },
      { kind: 'seven_day', percentUsed: 90, resetsAt: new Date((now + 2 * 86400) * 1000).toISOString() },
    ],
    cost: { usd: 1 },
    changed: ['context', 'rateLimits', 'cost'],
  } satisfies Parameters<typeof $.session.measure>[0]
  expect(await $.session.measure(measure)).toEqual({ changed: measure.changed })
  expect(measured).toBe(1)
  expect(claudeUsageCalls).toBe(1)
  await bandUi.redraw()
  expect(await bandText()).toBe('Claude 5h 70% · wk 90% · ctx 91% │ Codex idle · 5h — · wk — │ /codex-workers')
  expect((await bandUi.find({ type: 'Text', text: /^70%$/ }))?.props.color).toBe('yellow')
  expect((await bandUi.find({ type: 'Text', text: /^91%$/ }))?.props.color).toBe('red')

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
  const claudeRow = (await paneUi.find({ type: 'Box', text: /^Claude {2}5h/ }))?.text ?? ''
  const codexRow = (await paneUi.find({ type: 'Box', text: /^Codex {3}5h/ }))?.text ?? ''
  const resetsRow = '        ↺2 banked resets · next expires Tue Dec 01 · redeem before expiry'
  expect(claudeRow).toMatch(/^Claude  5h █{7}░{3}   70%  resets \d{2}:\d{2} {7}wk █{9}░   90%  resets [A-Za-z]{3} \d{2}:\d{2}   ctx 91%$/)
  expect(codexRow).toBe('Codex   5h █░░░░░░░░░    9%  resets 23:10       wk ██░░░░░░░░   16%  resets Tue 14:49   THROTTLE')
  for (const column of ['5h', 'wk']) {
    expect(claudeRow.indexOf(column)).toBe(codexRow.indexOf(column))
  }
  expect(claudeRow.indexOf('%')).toBe(codexRow.indexOf('%'))
  expect(claudeRow.indexOf('%', claudeRow.indexOf('wk'))).toBe(codexRow.lastIndexOf('%'))
  expect((await paneUi.find({ type: 'Box', text: /^ {8}↺/ }))?.text).toBe(resetsRow)
  expect((await paneUi.find({ type: 'Text', text: /^↺2 banked resets/ }))?.props.color).toBe('yellow')
  expect((await paneUi.find({ type: 'Text', text: /^ 70%$/ }))?.props.color).toBe('yellow')
  expect((await paneUi.find({ type: 'Text', text: /^THROTTLE$/ }))?.props.color).toBe('yellow')
  expect((await paneUi.find({ type: 'Text', text: /^ 90%$/ }))?.props.color).toBe('red')

  await paneUi.redraw({ ...pane.props, bodyColumns: 60 })
  const stackedRows = await paneUi.findAll({ type: 'Box', text: /^(?:Claude|Codex)$|^ {8}(?:5h|wk|ctx|THROTTLE|↺|redeem)/ })
  expect(stackedRows.map(row => row.text)).toEqual([
    'Claude',
    '        ' + claudeRow.slice(8, 45),
    '        ' + claudeRow.slice(48, 85),
    '        ctx 91%',
    'Codex',
    '        ' + codexRow.slice(8, 45),
    '        ' + codexRow.slice(48, 85),
    '        THROTTLE',
    '        ↺2 banked resets · next expires Tue Dec 01',
    '        redeem before expiry',
  ])
  await paneUi.redraw(pane.props)
  await firstOpen
  expect(opens).toBe(1)
  expect(pidChecks).toBe(1)
  expect(tailReads).toEqual([{ offset: 4464, length: 65536 }])
  await bandUi.redraw()
  expect(await bandText()).toMatch(/Codex ⠋ 1 running · 5h 9% · wk 16% · ↺2/)
  expect((await bandUi.find({ type: 'Text', text: /^Codex$/ }))?.props.color).toBe('yellow')

  // Let the first tick see a terminal record only one second later.
  record = { ...RUN, status: 'done', exit_code: 0, ended_at: 5001 }
  now = 5001
  tick()
  expect(await waitForRow(/Added fixture tests/)).toMatch(/✓.*13:21/)
  expect(await waitForRow(/^OK$/)).toBe('OK')
  expect((await paneUi.find({ type: 'Box', text: /^ {8}↺/ }))?.text).toBe('        ↺1 banked reset')
  expect((await paneUi.find({ type: 'Text', text: /^↺1 banked reset$/ }))?.props.color).toBe(undefined)
  expect(pidChecks).toBe(1)
  expect(tailReads.length).toBe(1)
  expect(usageCalls).toBe(2)
  await bandUi.redraw()
  expect(await bandText()).toMatch(/Codex 1 done/)
  expect(claudeUsageCalls).toBe(1)

  installed = '0.2.5'
  now = 5030
  claudeSnapshot = { ...CLAUDE_USAGE, context: { window: 200000, percent: 42 }, rateLimits: [] }
  tick()
  expect(await waitForRow(/^42%$/)).toBe('42%')
  const placeholder = (label: string) => label + ' '.repeat(16) + '—' + ' '.repeat(18)
  expect((await paneUi.find({ type: 'Box', text: /^Claude {2}5h/ }))?.text)
    .toBe('Claude  ' + placeholder('5h') + '   ' + placeholder('wk') + '   ctx 42%')
  expect(claudeUsageCalls).toBe(2)
  await bandUi.redraw()
  expect(await bandText()).toBe('Claude ctx 42% │ Codex 1 done · 5h 9% · wk 16% · ↺1 │ /codex-workers')
  expect((await paneUi.find({ type: 'Text', text: /^   —$/ }))?.props.dimColor).toBe(true)
  // Only the initial and measured snapshots have both windows.
  expect(usageFileWrites.length).toBe(2)

  expect(manifestReads).toBe(1)
  expect(registryReads).toBe(1)
  now = 5060
  claudeSnapshot = CLAUDE_USAGE
  tick()
  const notice = 'codex-workers 0.2.4 loaded, 0.2.5 installed — run /reload-plugins'
  expect(await waitForRow(/^codex-workers /)).toBe(notice)
  const [firstLine] = await paneUi.findAll({ type: 'Text' })
  expect(firstLine?.text).toBe(notice)
  expect(firstLine?.props.color).toBe('yellow')
  expect(await waitForRow(/^38%$/)).toBe('38%')
  expect(registryReads).toBe(2)

  await bandUi.redraw({ ...band.props, bodyColumns: 140 })
  expect(await bandText()).toBe('Claude 5h 23% · wk 41% · ctx 38% │ Codex 1 done · 5h 9% · wk 16% · ↺1 │ /codex-workers │ update ready: /reload-plugins')
  expect((await bandUi.find({ type: 'Text', text: /update ready/ }))?.props.color).toBe('yellow')
  await bandUi.redraw({ ...band.props, bodyColumns: 105 })
  expect(await bandText()).toBe('Claude 5h 23% · wk 41% · ctx 38% │ Codex 1 done · 5h 9% · wk 16% · ↺1 │ update ready: /reload-plugins')
  await bandUi.redraw({ ...band.props, bodyColumns: 70 })
  expect(await bandText()).toBe('C 23%/41% │ X 1 done 9%/16% ↺1 │ ⟳ reload')
  expect((await bandUi.find({ type: 'Text', text: /⟳ reload/ }))?.props.color).toBe('yellow')

  installed = 'invalid'
  now = 5120
  claudeSnapshot = { ...CLAUDE_USAGE, context: { window: 200000, percent: 42 } }
  tick()
  expect(await waitForRow(/^42%$/)).toBe('42%')
  expect(registryReads).toBe(3)
  expect(await waitForRow(/^codex-workers /)).toBe(notice)

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
