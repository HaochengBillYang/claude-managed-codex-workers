import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type {
  CodexUsage,
  RunRecord,
  RunStatus,
  UsageWindow,
  Worker,
} from '../types'

const PANE = 'codex-workers'
const TITLE = 'Codex workers'
// Resolved from $HOME at session.start so the mod works on any machine.
let RUNS_DIR = ''
let USAGE_SCRIPT = ''
const RUN_FILE = /^\d{8}-\d{6}-\d+\.json$/
const TAIL_BYTES = 64 * 1024
const PANE_WINDOW = 30 * 60
const BAND_WINDOW = 60
const SPINNER = Array.from('⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏')
const UNKNOWN_USAGE: CodexUsage = {
  fiveHour: null,
  weekly: null,
  status: 'UNKNOWN',
  until: null,
  reason: null,
}

const runs = atom({ plugin: 'codex-workers', key: 'runs' } as const,
  { now: 0, workers: [] }, { shape: 'runs-1' })
const usage = atom({ plugin: 'codex-workers', key: 'usage' } as const,
  UNKNOWN_USAGE, { shape: 'usage-1' })
const seenIds = atom({ plugin: 'codex-workers', key: 'seenIds' } as const,
  [], { shape: 'seen-1' })
const paneOpen = atom({ plugin: 'codex-workers', key: 'paneOpen' } as const, false)

function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined
}

function json(text: string): Record<string, unknown> | undefined {
  try {
    return object(JSON.parse(text))
  } catch {
    return undefined
  }
}

export function parseRun(text: string, id: string): RunRecord | undefined {
  const run = json(text)
  if (!run || run.id !== id) return undefined
  const { name, batch, effort, sandbox, pid, status, started_at, ended_at,
    exit_code, events, result } = run
  if (typeof name !== 'string' || typeof batch !== 'string'
    || (effort !== 'low' && effort !== 'medium')
    || (sandbox !== 'read-only' && sandbox !== 'workspace-write')
    || typeof pid !== 'number' || !Number.isSafeInteger(pid) || pid <= 0
    || (status !== 'running' && status !== 'done' && status !== 'failed' && status !== 'killed')
    || typeof started_at !== 'number' || !Number.isFinite(started_at)
    || (ended_at !== null && (typeof ended_at !== 'number' || !Number.isFinite(ended_at)))
    || (exit_code !== null && (typeof exit_code !== 'number' || !Number.isInteger(exit_code)))
    || typeof events !== 'string' || !events.startsWith('/')
    || typeof result !== 'string' || !result.startsWith('/')) return undefined
  return { id, name, batch, effort, sandbox, pid, status, started_at, ended_at, exit_code, events, result }
}

function firstLine(text: string): string {
  return text.split(/\r?\n/, 1)[0]?.trim() ?? ''
}

export function activityFromEvents(tail: string, cutAtStart = false): string | undefined {
  const lines = tail.split('\n')
  for (let index = lines.length - 1; index >= Number(cutAtStart); index -= 1) {
    const event = json(lines[index] ?? '')
    if (!event || (event.type !== 'item.started' && event.type !== 'item.updated'
      && event.type !== 'item.completed')) continue
    const item = object(event.item)
    if (!item || typeof item.type !== 'string' || !item.type) continue

    switch (item.type) {
      case 'command_execution': {
        if (typeof item.command !== 'string') break
        const command = item.command.trim().replace(/^\/bin\/zsh -lc\s+/, '')
          .replace(/^(['"])([\s\S]*)\1$/, '$2')
        if (command) return '$ ' + command.replace(/\s*\r?\n\s*/g, ' ')
        break
      }
      case 'agent_message': {
        const line = typeof item.text === 'string' ? firstLine(item.text) : ''
        if (line) return line
        break
      }
      case 'file_change': {
        const paths = Array.isArray(item.changes) ? item.changes.flatMap(change => {
          const path = object(change)?.path
          return typeof path === 'string' && path ? [path] : []
        }) : []
        return paths.length ? 'edit ' + paths.join(', ') : 'file_change'
      }
      case 'reasoning':
        return 'thinking…'
      default:
        return item.type
    }
  }
  return undefined
}

export function formatElapsed(startedAt: number, endedAt: number): string {
  const seconds = Math.max(0, Math.floor(endedAt - startedAt))
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor(seconds / 60) % 60
  const clock = String(minutes).padStart(2, '0') + ':' + String(seconds % 60).padStart(2, '0')
  return hours > 0 ? hours + ':' + clock : clock
}

export function applyLiveness(
  record: RunRecord, previousLostAt: number | null, alive: boolean | undefined, now: number,
): number | null {
  if (record.status !== 'running' || alive === true) return null
  return alive === false ? previousLostAt ?? now : previousLostAt
}

export function workerStatus(worker: Worker): RunStatus | 'lost' {
  return worker.record.status === 'running' && worker.lostAt !== null
    ? 'lost'
    : worker.record.status
}

function finishedAt(worker: Worker): number | null {
  return worker.record.status === 'running' ? worker.lostAt : worker.record.ended_at
}

function isCurrent(worker: Worker, now: number, seconds: number): boolean {
  const endedAt = finishedAt(worker)
  return workerStatus(worker) === 'running' || (endedAt !== null && endedAt >= now - seconds)
}

export function groupWorkers(workers: Worker[], now: number): { batch: string; workers: Worker[] }[] {
  const newest = [...workers].sort((a, b) => b.record.started_at - a.record.started_at
    || b.record.id.localeCompare(a.record.id))
  const hasCurrent = newest.some(worker => isCurrent(worker, now, PANE_WINDOW))
  const fallbackBatch = newest[0]?.record.batch
  const groups = new Map<string, Worker[]>()
  for (const worker of newest) {
    const batch = worker.record.batch
    const members = groups.get(batch) ?? []
    if (hasCurrent ? isCurrent(worker, now, PANE_WINDOW) : batch === fallbackBatch) {
      members.push(worker)
    }
    groups.set(batch, members)
  }
  return [...groups].flatMap(([batch, members]) => members.length
    ? [{ batch, workers: members.reverse() }]
    : [])
}

function countStatuses(workers: Worker[]) {
  let running = 0
  let done = 0
  let failed = 0
  let killed = 0
  let lost = 0
  for (const worker of workers) {
    switch (workerStatus(worker)) {
      case 'running': running += 1; break
      case 'done': done += 1; break
      case 'failed': failed += 1; break
      case 'killed': killed += 1; break
      case 'lost': lost += 1; break
    }
  }
  return { running, done, failed, killed, lost }
}

export function bandCounts(workers: Worker[], now: number) {
  return countStatuses(workers.filter(worker => isCurrent(worker, now, BAND_WINDOW)))
}

function usageWindow(match: RegExpMatchArray | null): UsageWindow | null {
  if (!match) return null
  const percent = Number(match[1])
  return percent >= 0 && percent <= 100 ? { percent, resets: match[2]?.trim() ?? '' } : null
}

export function parseUsage(text: string): CodexUsage {
  const status = text.match(/^\s*STATUS=(OK|THROTTLE|BLOCKED|UNKNOWN)\b([^\r\n]*)/m)
  const details = status?.[2] ?? ''
  const until = details.match(/\bUNTIL=(\d+)\b/)
  return {
    fiveHour: usageWindow(text.match(/^\s*5-hour window:\s*(\d+(?:\.\d+)?)% used,\s*resets ([^\r\n]+)/m)),
    weekly: usageWindow(text.match(/^\s*Weekly window:\s*(\d+(?:\.\d+)?)% used(?: \([^\r\n]*?\))?,\s*resets ([^\r\n]+)/m)),
    status: (status?.[1] ?? 'UNKNOWN') as CodexUsage['status'],
    until: until ? Number(until[1]) : null,
    reason: details.match(/\bREASON=(.+)/)?.[1]?.trim() ?? null,
  }
}

async function readActivity($: EngineInterface, path: string): Promise<string | undefined> {
  const { size, kind } = await $.fs.stat(path)
  if (kind !== 'file' || size === 0) return undefined
  const offset = Math.max(0, size - TAIL_BYTES)
  const tail = await $.fs.read(path, { offset, length: size - offset })
  return activityFromEvents(tail, offset > 0)
}

async function checkPid($: EngineInterface, pid: number): Promise<boolean | undefined> {
  const result = await $.process.run(['/bin/kill', '-0', String(pid)], { timeoutMs: 1000 })
  if (result.exitCode === 0) return true
  // A permission error still establishes that the process exists.
  if (/operation not permitted|permission denied/i.test(result.stderr)) return true
  return /no such process/i.test(result.stderr) ? false : undefined
}

async function readWorker(
  $: EngineInterface, record: RunRecord, prior: Worker | undefined, now: number, checkLiveness: boolean,
): Promise<Worker> {
  const previous = prior?.record.pid === record.pid ? prior : undefined
  if (record.status !== 'running') {
    const resultLine = prior?.record.result === record.result && prior.resultLine
      ? prior.resultLine
      : await $.fs.read(record.result, { offset: 0, length: 4096 }).then(firstLine).catch(() => '')
    return { record, resultLine, activity: '', lostAt: null }
  }

  const alive = checkLiveness
    ? await checkPid($, record.pid).catch(() => undefined)
    : undefined
  const lostAt = applyLiveness(record, previous?.lostAt ?? null, alive, now)
  const activity = lostAt === null
    ? await readActivity($, record.events).catch(() => undefined)
    : undefined
  return {
    record,
    activity: activity?.slice(0, 4096) ?? previous?.activity ?? '',
    lostAt,
    resultLine: '',
  }
}

function summary(workers: Worker[]): string {
  const running = workers.filter(worker => workerStatus(worker) === 'running').length
  return running === 0 ? 'done' : running + ' running'
}

function clip(text: string, columns: number): string {
  const characters = Array.from(text.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' '))
  if (columns <= 0) return ''
  return characters.length <= columns ? characters.join('') : characters.slice(0, columns - 1).join('') + '…'
}

function glyph(status: ReturnType<typeof workerStatus>, now: number): string {
  if (status === 'running') return SPINNER[Math.floor(now) % SPINNER.length] ?? '⠋'
  return { done: '✓', failed: '✗', killed: '⊘', lost: '?' }[status]
}

function workerRow(worker: Worker, now: number, columns: number, nameWidth: number): string {
  const { record } = worker
  const status = workerStatus(worker)
  const elapsed = formatElapsed(record.started_at, finishedAt(worker) ?? now)
  const sandbox = record.sandbox === 'workspace-write' ? 'ws' : 'ro'
  const activity = status === 'running' ? worker.activity
    : status === 'lost' ? 'pid ' + record.pid + ' gone'
    : worker.resultLine || (record.exit_code === null ? 'exit unknown' : 'exit ' + record.exit_code)
  const name = clip(record.name, nameWidth)
  const padding = ' '.repeat(nameWidth - Array.from(name).length + 2)
  const details = record.effort + ' · ' + sandbox + '  ' + elapsed
  return clip('  ' + glyph(status, now) + ' ' + name + padding + details
    + (activity ? '   ' + activity : ''), columns)
}

function windowLabel(label: string, window: UsageWindow | null, columns: number): string {
  if (!window) return clip(label + ' —', columns)
  const parts = window.resets.split(/\s+/)
  const reset = parts.length === 4
    ? (label === 'wk' ? parts[0] + ' ' : '') + parts[3]
    : window.resets
  const info = window.percent + '%' + (reset ? '  resets ' + reset : '')
  const barWidth = Math.max(0, Math.min(10, columns - label.length - info.length - 4))
  const used = Math.ceil(window.percent * barWidth / 100)
  const bar = barWidth ? '  ' + '█'.repeat(used) + '░'.repeat(barWidth - used) : ''
  return clip(label + bar + '  ' + info, columns)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const home = (await $.process.run(['/usr/bin/printenv', 'HOME'], { timeoutMs: 2000 })
      .then(r => r.stdout.trim(), () => ''))
    if (home) {
      RUNS_DIR = home + '/.claude/codex-runs'
      USAGE_SCRIPT = home + '/.claude/skills/codex/scripts/codex-usage.sh'
    }
    await $.command.register({ name: 'codex-workers', description: 'Toggle the Codex workers pane' })

    let polling = false
    let lastLiveness = -Infinity
    let lastUsage = -Infinity
    let pendingUsage = true
    let refreshingUsage = false

    async function refreshUsage(now: number) {
      if (!USAGE_SCRIPT || refreshingUsage || (!pendingUsage && now - lastUsage < 30)) return
      refreshingUsage = true
      pendingUsage = false
      lastUsage = now
      try {
        const snapshot = await $.process.run([USAGE_SCRIPT], { timeoutMs: 5000 })
          .then(result => parseUsage(result.stdout), () => UNKNOWN_USAGE)
        await update($, usage, () => snapshot)
      } catch {
        pendingUsage = true
      } finally {
        refreshingUsage = false
      }
    }

    async function poll() {
      if (polling || !RUNS_DIR) return
      polling = true
      try {
        const now = (await $.clock.now()) / 1000
        const previous = await read($, runs)
        const byId = new Map(previous.workers.map(worker => [worker.record.id, worker]))
        const entries = await $.fs.list(RUNS_DIR).catch(() => undefined)
        const records = entries === undefined
          ? previous.workers.map(worker => worker.record)
          : await Promise.all(entries.filter(entry => entry.kind === 'file' && RUN_FILE.test(entry.name))
            .map(async entry => {
              const id = entry.name.slice(0, -5)
              const text = await $.fs.read(RUNS_DIR + '/' + entry.name, { length: 64 * 1024 }).catch(() => '')
              return parseRun(text, id) ?? byId.get(id)?.record
            }))
        const checkLiveness = now - lastLiveness >= 5
        const workers = await Promise.all(records.flatMap(record => record
          ? [readWorker($, record, byId.get(record.id), now, checkLiveness)]
          : []))
        if (checkLiveness && workers.some(worker => worker.record.status === 'running')) lastLiveness = now

        const seen = await read($, seenIds)
        const known = new Set(seen)
        const newRun = workers.some(worker => workerStatus(worker) === 'running' && !known.has(worker.record.id))
        pendingUsage ||= workers.some(worker => {
          const prior = byId.get(worker.record.id)
          return (prior?.record.status === 'running' && worker.record.status !== 'running')
            || (prior?.lostAt == null && worker.lostAt !== null)
            || (!prior && isCurrent(worker, now, BAND_WINDOW) && worker.record.status !== 'running')
        })
        await update($, runs, () => ({ now, workers }))
        void refreshUsage(now)
        if (newRun && (!(await read($, paneOpen)) || !(await $.ui.panes()).some(pane => pane.id === PANE))) {
          await $.ui.open({ id: PANE, title: TITLE })
          await update($, paneOpen, () => true)
        }
        const unseen = workers.map(worker => worker.record.id).filter(id => !known.has(id))
        if (unseen.length) await update($, seenIds, ids => [...new Set([...ids, ...unseen])])
      } catch {
        // A failed host call leaves the next tick free to try again.
      } finally {
        polling = false
      }
    }

    $.clock.every(1000, () => { void poll() })
    return next(e)
  })

  on('command.run', { command: 'codex-workers' }, async $ => {
    const pane = (await $.ui.panes()).find(item => item.id === PANE)
    if (pane?.isPlaced) {
      await $.ui.close({ id: PANE })
      return { text: 'Codex workers pane closed.' }
    }
    const opened = await $.ui.open({ id: PANE, title: TITLE })
    await update($, paneOpen, () => true)
    return { text: opened.isPlaced ? 'Codex workers pane opened.' : 'Codex workers pane is waiting for a surface.' }
  })

  on('ui.close', { id: 'codex-workers' }, async ($, e, next) => {
    const result = await next(e)
    await update($, paneOpen, () => false)
    return result
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const [{ workers, now }, limits] = await Promise.all([read($, runs), read($, usage)])
    const groups = groupWorkers(workers, now)
    const columns = e.props.bodyColumns
    const longestName = Math.max(1, ...groups.flatMap(group =>
      group.workers.map(worker => Array.from(worker.record.name).length)))
    const nameWidth = Math.max(1, Math.min(14, longestName, columns - 25))
    const statusColor = limits.status === 'BLOCKED' ? 'red' : limits.status === 'THROTTLE' ? 'yellow' : undefined
    const fiveHour = windowLabel('5h', limits.fiveHour, columns)
    const weekly = windowLabel('wk', limits.weekly, columns)
    const wide = columns >= fiveHour.length + weekly.length + limits.status.length + 2
    return (
      <Box flexDirection="column">
        {groups.length === 0 && <Text dimColor>No Codex workers yet.</Text>}
        {groups.map(group => {
          const count = group.workers.length
          const stats = count + (count === 1 ? ' worker · ' : ' workers · ') + summary(group.workers)
          const batch = clip('▸ ' + group.batch, Math.max(3, columns - stats.length - 2))
          const gap = Math.max(2, columns - Array.from(batch).length - stats.length)
          return (
            <Box flexDirection="column">
              <Text bold wrap="truncate-end">{clip(batch + ' '.repeat(gap) + stats, columns)}</Text>
              {group.workers.map(worker => (
                <Text wrap="truncate-end" dimColor={workerStatus(worker) !== 'running'}>
                  {workerRow(worker, now, columns, nameWidth)}
                </Text>
              ))}
            </Box>
          )
        })}
        <Text dimColor>{'─'.repeat(columns)}</Text>
        <Box flexDirection={wide ? 'row' : 'column'} gap={wide ? 1 : 0}>
          <Text wrap="truncate-end">{fiveHour}</Text>
          <Text wrap="truncate-end">{weekly}</Text>
          <Text color={statusColor}>{limits.status}</Text>
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const { workers, now } = await read($, runs)
    const counts = bandCounts(workers, now)
    const labels = Object.entries(counts).filter(([, count]) => count > 0)
    if (labels.length === 0) return next(e)
    const limits = await read($, usage)
    const fiveHour = limits.fiveHour ? limits.fiveHour.percent + '%' : '—'
    const weekly = limits.weekly ? limits.weekly.percent + '%' : '—'
    const totals = labels.map(([status, count]) => count + ' ' + status).join(' · ')
    const workersText = 'Codex ' + (counts.running ? glyph('running', now) + ' ' : '') + totals
    const usageText = ' │ 5h ' + fiveHour + ' · wk ' + weekly
    const command = ' │ /codex-workers'
    const columns = e.props.bodyColumns
    const compact = columns < Array.from(workersText + usageText + command).length
    const text = compact && columns > command.length
      ? clip(workersText + usageText, columns - command.length) + command
      : clip(workersText + usageText + command, columns)
    return <Box><Text wrap="truncate-end">{text}</Text></Box>
  })
}
