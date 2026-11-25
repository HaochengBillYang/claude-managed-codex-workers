import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionUsage } from 'claude-code'

import type {
  ClaudeUsage,
  ClaudeUsageWindow,
  CodexUsage,
  RunRecord,
  RunStatus,
  UsageWindow,
  VersionDrift,
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
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const DRIFT_INTERVAL = 60
const QUEUE_INTERVAL = 5
const UNKNOWN_USAGE: CodexUsage = {
  fiveHour: null,
  weekly: null,
  resets: null,
  advice: null,
  status: 'UNKNOWN',
  until: null,
  reason: null,
}

const runs = atom({ plugin: 'codex-workers', key: 'runs' } as const,
  { now: 0, workers: [] }, { shape: 'runs-1' })
const usage = atom({ plugin: 'codex-workers', key: 'usage' } as const,
  UNKNOWN_USAGE, { shape: 'usage-2' })
const claudeUsage = atom({ plugin: 'codex-workers', key: 'claudeUsage' } as const,
  { fiveHour: null, weekly: null, contextPercent: null, costUsd: null }, { shape: 'claude-usage-1' })
const seenIds = atom({ plugin: 'codex-workers', key: 'seenIds' } as const,
  [], { shape: 'seen-1' })
const drift = atom({ plugin: 'codex-workers', key: 'drift' } as const, null)
const paneOpen = atom({ plugin: 'codex-workers', key: 'paneOpen' } as const, false)
const queue = atom({ plugin: 'codex-workers', key: 'queue' } as const,
  { queued: 0 }, { shape: 'queue-1' })
const notified = atom({ plugin: 'codex-workers', key: 'notified' } as const,
  { status: 'UNKNOWN', advice: null }, { shape: 'notified-1' })

async function openPane($: EngineInterface) {
  const opened = await $.ui.open({ id: PANE, title: TITLE })
  await update($, paneOpen, () => true)
  return opened
}

async function readRenderState($: EngineInterface) {
  const [{ workers, now }, codex, claude, versionDrift, { queued }] = await Promise.all([
    read($, runs), read($, usage), read($, claudeUsage), read($, drift), read($, queue),
  ])
  return { workers, now, codex, claude, versionDrift, queued }
}

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

function version(value: unknown): string | undefined {
  return typeof value === 'string' && /^\d+(?:\.\d+)*$/.test(value) ? value : undefined
}

export function isNewerVersion(installed: unknown, loaded: unknown): boolean {
  const newer = version(installed)?.split('.').map(part => BigInt(part))
  const older = version(loaded)?.split('.').map(part => BigInt(part))
  if (!newer || !older) return false
  for (let i = 0; i < Math.max(newer.length, older.length); i += 1) {
    const a = newer[i] ?? 0n
    const b = older[i] ?? 0n
    if (a !== b) return a > b
  }
  return false
}

async function readJson(readFile: (path: string) => Promise<string>, path: string) {
  try {
    return json(await readFile(path))
  } catch {
    return undefined
  }
}

async function countQueued($: EngineInterface, dir: string): Promise<number> {
  const entries = await $.fs.list(dir).catch(() => [])
  const tasks = await Promise.all(entries.filter(entry => entry.kind === 'file' && entry.name.endsWith('.json'))
    .map(entry => readJson(path => $.fs.read(path), dir + '/' + entry.name)))
  return tasks.filter(task => task?.status === 'queued').length
}

export async function detectDrift(
  readFile: (path: string) => Promise<string>, home: string, loaded: string | undefined,
): Promise<VersionDrift | null> {
  if (!home || !loaded) return null
  const registry = await readJson(readFile, home + '/.claude/plugins/installed_plugins.json')
  const plugins = object(registry?.plugins)
  const key = plugins && Object.keys(plugins).find(name => name.startsWith('codex-workers@'))
  const entries = key ? plugins?.[key] : undefined
  if (!Array.isArray(entries)) return null
  const entry = entries.find(item => object(item)?.scope === 'user') ?? entries[0]
  const installed = version(object(entry)?.version)
  return installed && isNewerVersion(installed, loaded) ? { loaded, installed } : null
}

export function parseRun(text: string, id: string): RunRecord | undefined {
  const run = json(text)
  if (!run || run.id !== id) return undefined
  const { name, batch, effort, model, sandbox, pid, status, started_at, ended_at,
    exit_code, events, result } = run
  if (typeof name !== 'string' || typeof batch !== 'string'
    || (effort !== 'low' && effort !== 'medium' && effort !== 'high')
    || (sandbox !== 'read-only' && sandbox !== 'workspace-write')
    || typeof pid !== 'number' || !Number.isSafeInteger(pid) || pid <= 0
    || (status !== 'running' && status !== 'done' && status !== 'failed' && status !== 'killed')
    || typeof started_at !== 'number' || !Number.isFinite(started_at)
    || (ended_at !== null && (typeof ended_at !== 'number' || !Number.isFinite(ended_at)))
    || (exit_code !== null && (typeof exit_code !== 'number' || !Number.isInteger(exit_code)))
    || typeof events !== 'string' || !events.startsWith('/')
    || typeof result !== 'string' || !result.startsWith('/')) return undefined
  return {
    id, name, batch, effort,
    // Older records have no model; keep them and simply omit it.
    ...(typeof model === 'string' && model ? { model } : {}),
    sandbox, pid, status, started_at, ended_at, exit_code, events, result,
  }
}

/** Compact model label for the pane: "gpt-6.2-astra" -> "astra"; other ids stay whole. */
export function shortModel(model: string): string {
  return /^gpt-6\.2-./.test(model) ? model.slice('gpt-6.2-'.length) : model
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

function isCurrent(worker: Worker, finishedRecently: (endedAt: number) => boolean): boolean {
  const endedAt = finishedAt(worker)
  return workerStatus(worker) === 'running' || (endedAt !== null && finishedRecently(endedAt))
}

export function groupWorkers(workers: Worker[], now: number): { batch: string; workers: Worker[] }[] {
  const newest = [...workers].sort((a, b) => b.record.started_at - a.record.started_at
    || b.record.id.localeCompare(a.record.id))
  const isCurrentInPane = (worker: Worker) => isCurrent(worker, endedAt => endedAt >= now - PANE_WINDOW)
  const hasCurrent = newest.some(isCurrentInPane)
  const fallbackBatch = newest[0]?.record.batch
  const groups = new Map<string, Worker[]>()
  for (const worker of newest) {
    const batch = worker.record.batch
    const members = groups.get(batch) ?? []
    if (hasCurrent ? isCurrentInPane(worker) : batch === fallbackBatch) {
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
  return countStatuses(workers.filter(worker => isCurrent(worker, endedAt => now - endedAt < BAND_WINDOW)))
}

function usageWindow(match: RegExpMatchArray | null): UsageWindow | null {
  if (!match) return null
  const percent = Number(match[1])
  return percent >= 0 && percent <= 100 ? { percent, resets: match[2]?.trim() ?? '' } : null
}

export function parseUsage(text: string): CodexUsage {
  const status = text.match(/^\s*STATUS=(OK|THROTTLE|SQUEEZE|BLOCKED|UNKNOWN)\b([^\r\n]*)/m)
  const details = status?.[2] ?? ''
  const metadata = details.split(/\bREASON=/, 1)[0] ?? ''
  const until = metadata.match(/\bUNTIL=(\d+)\b/)
  const banked = text.match(/^[ \t]*Banked resets:[ \t]*(\d+)\b(?:[ \t]+\(expire ([^)\r\n]+)\))?/m)
  const count = Number(banked?.[1] ?? metadata.match(/\bRESETS=(\d+)\b/)?.[1] ?? 0)
  return {
    fiveHour: usageWindow(text.match(/^\s*5-hour window:\s*(\d+(?:\.\d+)?)% used,\s*resets ([^\r\n]+)/m)),
    weekly: usageWindow(text.match(/^\s*Weekly window:\s*(\d+(?:\.\d+)?)% used(?: \([^\r\n]*?\))?,\s*resets ([^\r\n]+)/m)),
    resets: count > 0 ? { count, expires: banked?.[2]?.trim() ?? null } : null,
    advice: metadata.match(/\bADVICE=(REDEEM_RECOMMENDED|REDEEM_OPTIONAL|REDEEM_BEFORE_EXPIRY)\b/)?.[1] ?? null,
    status: (status?.[1] ?? 'UNKNOWN') as CodexUsage['status'],
    until: until ? Number(until[1]) : null,
    reason: details.match(/\bREASON=(.+)/)?.[1]?.trim() ?? null,
  }
}

function adviceInWords(advice: string | null): string {
  return advice?.toLowerCase().replace(/_/g, ' ') ?? ''
}

async function notifyUsage($: EngineInterface, snapshot: CodexUsage, queued: number) {
  const { status, advice } = snapshot
  const previous = await read($, notified)
  if (previous.status === status && previous.advice === advice) return
  await update($, notified, () => ({ status, advice }))
  if (previous.status === 'BLOCKED' && (status === 'OK' || status === 'THROTTLE' || status === 'SQUEEZE') && queued > 0) {
    $.ui.toast(`Codex limit reset: ${queued} queued task(s) ready, ask Claude to drain the queue`)
  }
  if (advice && advice !== previous.advice) {
    $.ui.toast(`Codex: ${adviceInWords(advice)} (↺${snapshot.resets?.count ?? 0} banked)`)
  }
}

export function extractClaudeUsage(snapshot: Pick<SessionUsage, 'context' | 'rateLimits' | 'cost'>): ClaudeUsage {
  function window(kind: string): ClaudeUsageWindow | null {
    const limit = snapshot.rateLimits.find(item => item.kind === kind)
    return limit ? { percent: limit.percentUsed, resetsAt: limit.resetsAt ?? null } : null
  }
  return {
    fiveHour: window('five_hour'),
    weekly: window('seven_day'),
    contextPercent: snapshot.context.percent ?? null,
    costUsd: snapshot.cost?.usd ?? null,
  }
}

export function formatClaudeReset(resetsAt: string | null, nowMs: number): string {
  if (!resetsAt) return ''
  const reset = new Date(resetsAt)
  if (!Number.isFinite(reset.getTime())) return ''
  const time = String(reset.getHours()).padStart(2, '0') + ':' + String(reset.getMinutes()).padStart(2, '0')
  return Math.abs(reset.getTime() - nowMs) < 24 * 60 * 60 * 1000
    ? time : WEEKDAYS[reset.getDay()] + ' ' + time
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

export function workerRow(worker: Worker, now: number, columns: number, nameWidth: number): string {
  const { record } = worker
  const status = workerStatus(worker)
  const elapsed = formatElapsed(record.started_at, finishedAt(worker) ?? now)
  const sandbox = record.sandbox === 'workspace-write' ? 'ws' : 'ro'
  const activity = status === 'running' ? worker.activity
    : status === 'lost' ? 'pid ' + record.pid + ' gone'
    : worker.resultLine || (record.exit_code === null ? 'exit unknown' : 'exit ' + record.exit_code)
  const name = clip(record.name, nameWidth)
  const padding = ' '.repeat(nameWidth - Array.from(name).length + 2)
  const effort = record.model ? record.effort + ' · ' + shortModel(record.model) : record.effort
  const details = effort + ' · ' + sandbox + '  ' + elapsed
  return clip('  ' + glyph(status, now) + ' ' + name + padding + details
    + (activity ? '   ' + activity : ''), columns)
}

type UsageColor = 'yellow' | 'red'
type Segment = { text: string; color?: UsageColor; dimColor?: boolean }

function renderSegments(Text: ReturnType<EngineInterface['ui']['resolve']>['Text'], segments: Segment[]) {
  return segments.map(({ text, color, dimColor }) => (
    <Text color={color} dimColor={dimColor} wrap="truncate-end">{text}</Text>
  ))
}

export function percentColor(percent: number | null): UsageColor | undefined {
  return percent === null ? undefined : percent >= 90 ? 'red' : percent >= 70 ? 'yellow' : undefined
}

function statusColor(status: CodexUsage['status']): UsageColor | undefined {
  return status === 'BLOCKED' ? 'red' : status === 'THROTTLE' || status === 'SQUEEZE' ? 'yellow' : undefined
}

function percentage(percent: number | null): Segment {
  return { text: percent === null ? '—' : percent + '%', color: percentColor(percent) }
}

function bankedResets(codex: CodexUsage): Segment[] {
  return codex.resets && codex.resets.count > 0
    ? [{ text: '↺' + codex.resets.count, color: codex.advice ? 'yellow' : undefined }]
    : []
}

function rowWidth(segments: Segment[]): number {
  return segments.reduce((width, segment) => width + Array.from(segment.text).length, 0)
}

function clipRow(segments: Segment[], columns: number): Segment[] {
  if (rowWidth(segments) <= columns) return segments
  if (columns <= 0) return []
  const result: Segment[] = []
  let remaining = columns - 1
  for (const segment of segments) {
    const characters = Array.from(segment.text)
    if (characters.length > remaining) {
      result.push({ ...segment, text: characters.slice(0, remaining).join('') + '…' })
      break
    }
    result.push(segment)
    remaining -= characters.length
  }
  return result
}

export function layoutBand(
  workers: Worker[], now: number, claude: ClaudeUsage, codex: CodexUsage, columns: number,
  versionDrift: VersionDrift | null = null, queued = 0,
): Segment[] {
  const counts = bandCounts(workers, now)
  const labels = Object.entries(counts).filter(([, count]) => count > 0)
  const totals = labels.map(([status, count]) => count + ' ' + status).join(' · ')
  const workerSummary = (counts.running ? glyph('running', now) + ' ' : '') + (totals || 'idle')
  const context = [{ text: ' ctx ' }, percentage(claude.contextPercent)]
  const claudeFiveHour = percentage(claude.fiveHour?.percent ?? null)
  const claudeWeekly = percentage(claude.weekly?.percent ?? null)
  const claudeWindows = [
    { text: ' 5h ' }, claudeFiveHour,
    { text: ' · wk ' }, claudeWeekly,
  ]
  const codexFiveHour = percentage(codex.fiveHour?.percent ?? null)
  const codexWeekly = percentage(codex.weekly?.percent ?? null)
  const color = statusColor(codex.status)
  const hasClaudeWindows = claude.fiveHour !== null || claude.weekly !== null
  const claudeHead = [{ text: 'Claude' }, ...(hasClaudeWindows ? claudeWindows : context)]
  const resets = bankedResets(codex)
  const codexTail = [
    { text: ' │ ' }, { text: 'Codex', color }, { text: ' ' + workerSummary + ' · 5h ' },
    codexFiveHour, { text: ' · wk ' }, codexWeekly,
    ...(resets.length ? [{ text: ' · ' }, ...resets] : []),
  ]
  const hint = { text: ' │ /codex-workers' }
  const notice: Segment[] = versionDrift ? [{ text: ' │ update ready: /reload-plugins', color: 'yellow' }] : []
  const full = [...claudeHead, ...(hasClaudeWindows ? [{ text: ' ·' }, ...context] : []), ...codexTail]
  const wide = [...full, hint, ...notice]
  if (queued > 0) {
    const withQueue = [...full, { text: ' · ⧗' + queued }, hint, ...notice]
    if (rowWidth(withQueue) <= columns) return withQueue
  }
  if (rowWidth(wide) <= columns) return wide
  if (versionDrift) {
    const withContext = [...full, ...notice]
    if (rowWidth(withContext) <= columns) return withContext
  } else {
    const withoutContext = [...claudeHead, ...codexTail, hint]
    if (rowWidth(withoutContext) <= columns) return withoutContext
  }
  const withoutHint = [...claudeHead, ...codexTail, ...notice]
  if (rowWidth(withoutHint) <= columns) return withoutHint
  const compact = [
    ...(hasClaudeWindows ? [
      { text: 'C ' }, claudeFiveHour, { text: '/' }, claudeWeekly,
    ] : [{ text: 'C' }, ...context]),
    { text: ' │ ' }, { text: 'X', color }, { text: ' ' + workerSummary + ' ' },
    codexFiveHour, { text: '/' }, codexWeekly,
  ]
  const compactNotice: Segment[] = versionDrift ? [{ text: ' │ ⟳ reload', color: 'yellow' }] : []
  const compactResets = resets.length ? [{ text: ' ' }, ...resets] : []
  const tail = [...compactResets, ...compactNotice]
  const remaining = columns - rowWidth(tail)
  if (remaining > 0) return [...clipRow(compact, remaining), ...tail]
  return clipRow(versionDrift ? compactNotice : resets, columns)
}

function codexReset(label: string, resets: string): string {
  const parts = resets.split(/\s+/)
  return parts.length === 4 ? (label === 'wk' ? parts[0] + ' ' : '') + parts[3] : resets
}

type FooterWindow = { label: string; percent: number | null; reset: string }

const FOOTER_LABEL_WIDTH = 8
const FOOTER_INDENT = { text: ' '.repeat(FOOTER_LABEL_WIDTH) }
const FOOTER_GAP = { text: '   ' }

function windowSegments({ label, percent, reset }: FooterWindow): Segment[] {
  const barWidth = 10
  const bounded = percent === null ? null : Math.max(0, Math.min(100, percent))
  const value = bounded === null ? '—' : Math.round(bounded) + '%'
  const filled = Math.round((bounded ?? 0) * barWidth / 100)
  const bar = percent === null ? ' '.repeat(barWidth) : '█'.repeat(filled) + '░'.repeat(barWidth - filled)
  const resetText = percent !== null && reset ? clip('resets ' + reset, 16) : ''
  return [
    { text: label + ' ' + bar + '  ' },
    { text: value.padStart(4), color: percentColor(percent), dimColor: percent === null },
    { text: '  ' + resetText.padEnd(16) },
  ]
}

function footerRows(
  label: string, windows: FooterWindow[], tail: Segment[], columns: number,
): Segment[][] {
  const cells = windows.map(windowSegments)
  const wide = [
    { text: label.padEnd(FOOTER_LABEL_WIDTH) },
    ...cells.flatMap(cell => [...cell, FOOTER_GAP]),
    ...tail,
  ]
  if (rowWidth(wide) <= columns) return [wide]
  return [
    clipRow([{ text: label }], columns),
    ...[...cells, tail].map(part => clipRow([FOOTER_INDENT, ...part], columns)),
  ]
}

/** On-disk Claude usage for budgeting scripts (claude-budget.sh): percentages and reset epochs. */
export type ClaudeUsageFile = {
  five_hour_pct: number
  five_hour_resets_at: number | null
  weekly_pct: number
  weekly_resets_at: number | null
}

function epochSeconds(iso: string | null): number | null {
  if (!iso) return null
  const ms = Date.parse(iso)
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null
}

/** Both windows, or undefined: a partial reading (e.g. a measure event with one limit) is never written. */
export function claudeUsageFile(snapshot: ClaudeUsage): ClaudeUsageFile | undefined {
  const { fiveHour, weekly } = snapshot
  if (!fiveHour || !weekly) return undefined
  return {
    five_hour_pct: fiveHour.percent,
    five_hour_resets_at: epochSeconds(fiveHour.resetsAt),
    weekly_pct: weekly.percent,
    weekly_resets_at: epochSeconds(weekly.resetsAt),
  }
}

/** Rewrite unchanged values at least this often, so `updated_at` shows the reading is current. */
const USAGE_FILE_HEARTBEAT = 5 * 60

/** Where the usage file goes and what was last written there. */
export type UsageFileState = { path: string; lastKey: string; lastWrite: number }

export function usageFileState(path: string): UsageFileState {
  return { path, lastKey: '', lastWrite: -Infinity }
}

/** A write to perform: `text` goes to `tmp`, which is then moved onto `path`. */
export type UsageFileWrite = { tmp: string; path: string; text: string; key: string; now: number }

/**
 * Decides whether a reading should be written: both windows present, and either changed or
 * past the heartbeat. `nowSeconds` is epoch seconds.
 */
export function planUsageFileWrite(
  state: UsageFileState, snapshot: ClaudeUsage, nowSeconds: number,
): UsageFileWrite | undefined {
  const values = claudeUsageFile(snapshot)
  if (!values) return undefined
  const now = Math.floor(nowSeconds)
  const key = JSON.stringify(values)
  if (key === state.lastKey && now - state.lastWrite < USAGE_FILE_HEARTBEAT) return undefined
  return { tmp: state.path + '.tmp', path: state.path, text: JSON.stringify({ ...values, updated_at: now }) + '\n', key, now }
}

/**
 * Keeps `state.path` (~/.claude/claude-usage.json) in step with the band's Claude usage.
 * Writes atomically (temp file, then mv), and never throws. A failed write is not remembered,
 * so the next reading retries it.
 */
async function writeClaudeUsageFile(
  $: EngineInterface, state: UsageFileState | undefined, snapshot: ClaudeUsage,
): Promise<void> {
  if (!state) return
  try {
    const plan = planUsageFileWrite(state, snapshot, (await $.clock.now()) / 1000)
    if (!plan) return
    await $.fs.write(plan.tmp, plan.text)
    const moved = await $.process.run(['/bin/mv', '-f', plan.tmp, plan.path], { timeoutMs: 2000 })
    if (moved.exitCode !== 0) return
    state.lastKey = plan.key
    state.lastWrite = plan.now
  } catch {
    // The band keeps working; the next reading retries.
  }
}

let usageFile: UsageFileState | undefined

async function refreshClaudeUsage($: EngineInterface, getMeasurement: () => number) {
  const before = getMeasurement()
  try {
    const snapshot = extractClaudeUsage(await $.session.usage())
    // A measurement may arrive while the snapshot is in flight.
    if (before !== getMeasurement()) return
    await update($, claudeUsage, current => before === getMeasurement() ? snapshot : current)
    await writeClaudeUsageFile($, usageFile, snapshot)
  } catch {
    // Keep the last snapshot until a measure event or the next refresh.
  }
}

export const register: Register = on => {
  let measurement = 0
  const getMeasurement = () => measurement

  on('session.measure', async ($, e, next) => {
    const observed = ++measurement
    const snapshot = extractClaudeUsage(e)
    await update($, claudeUsage, current => observed === measurement ? snapshot : current).catch(() => {})
    if (observed === measurement) await writeClaudeUsageFile($, usageFile, snapshot)
    return next(e)
  })

  on('session.start', async ($, e, next) => {
    const home = (await $.process.run(['/usr/bin/printenv', 'HOME'], { timeoutMs: 2000 })
      .then(r => r.stdout.trim(), () => ''))
    const queueDir = home ? home + '/.claude/codex-queue' : ''
    if (home) {
      RUNS_DIR = home + '/.claude/codex-runs'
      USAGE_SCRIPT = home + '/.claude/skills/codex/scripts/codex-usage.sh'
      usageFile = usageFileState(home + '/.claude/claude-usage.json')
    }
    const manifest = await readJson(path => $.fs.read(path), $.plugin.root + '/.claude-plugin/plugin.json')
    const loaded = version(manifest?.version)
    await update($, drift, () => null).catch(() => {})
    let lastDriftCheck = -Infinity
    await $.command.register({ name: 'codex-workers', description: 'Toggle the Codex workers pane' })
    let lastClaudeUsage = (await $.clock.now()) / 1000
    await refreshClaudeUsage($, getMeasurement)

    let polling = false
    let lastLiveness = -Infinity
    let lastUsage = -Infinity
    let pendingUsage = true
    let refreshingUsage = false
    let lastQueue = -Infinity
    let queued = 0

    async function refreshUsage(now: number) {
      if (!USAGE_SCRIPT || refreshingUsage || (!pendingUsage && now - lastUsage < 30)) return
      refreshingUsage = true
      pendingUsage = false
      lastUsage = now
      try {
        const snapshot = await $.process.run([USAGE_SCRIPT], { timeoutMs: 5000 })
          .then(result => parseUsage(result.stdout), () => UNKNOWN_USAGE)
        await notifyUsage($, snapshot, queued)
        await update($, usage, () => snapshot)
      } catch {
        pendingUsage = true
      } finally {
        refreshingUsage = false
      }
    }

    async function poll() {
      if (polling) return
      polling = true
      try {
        const now = (await $.clock.now()) / 1000
        if (now - lastDriftCheck >= DRIFT_INTERVAL) {
          lastDriftCheck = now
          const detected = await detectDrift(path => $.fs.read(path), home, loaded)
          // Keep a detected update visible until the plugin reloads.
          if (detected) await update($, drift, () => detected).catch(() => {})
        }
        if (now - lastClaudeUsage >= 30) {
          lastClaudeUsage = now
          await refreshClaudeUsage($, getMeasurement)
        }
        if (queueDir && now - lastQueue >= QUEUE_INTERVAL) {
          lastQueue = now
          queued = await countQueued($, queueDir)
          await update($, queue, current => current.queued === queued ? current : { queued })
        }
        if (!RUNS_DIR) return
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
            || (!prior && isCurrent(worker, endedAt => endedAt >= now - BAND_WINDOW) && worker.record.status !== 'running')
        })
        await update($, runs, () => ({ now, workers }))
        void refreshUsage(now)
        if (newRun && (!(await read($, paneOpen)) || !(await $.ui.panes()).some(pane => pane.id === PANE))) {
          await openPane($)
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
    const opened = await openPane($)
    return { text: opened.isPlaced ? 'Codex workers pane opened.' : 'Codex workers pane is waiting for a surface.' }
  })

  on('ui.close', { id: 'codex-workers' }, async ($, e, next) => {
    const result = await next(e)
    await update($, paneOpen, () => false)
    return result
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const [{ workers, now, codex, claude, versionDrift, queued }, nowMs] = await Promise.all([
      readRenderState($), $.clock.now(),
    ])
    const groups = groupWorkers(workers, now)
    const columns = e.props.bodyColumns
    const longestName = Math.max(1, ...groups.flatMap(group =>
      group.workers.map(worker => Array.from(worker.record.name).length)))
    const nameWidth = Math.max(1, Math.min(14, longestName, columns - 25))
    const claudeWindows = ([['5h', claude.fiveHour], ['wk', claude.weekly]] as const).map(([label, window]) => ({
      label, percent: window?.percent ?? null, reset: formatClaudeReset(window?.resetsAt ?? null, nowMs),
    }))
    const codexWindows = ([['5h', codex.fiveHour], ['wk', codex.weekly]] as const).map(([label, window]) => ({
      label, percent: window?.percent ?? null, reset: codexReset(label, window?.resets ?? ''),
    }))
    const footer = [
      ...footerRows('Claude', claudeWindows, [{ text: 'ctx ' }, percentage(claude.contextPercent)], columns),
      ...footerRows('Codex', codexWindows, [{ text: codex.status, color: statusColor(codex.status) }], columns),
    ]
    const resets = codex.resets
    if (resets && resets.count > 0) {
      const count = '↺' + resets.count + (resets.count === 1 ? ' banked reset' : ' banked resets')
      const expiry = resets.expires ? ' · next expires ' + resets.expires : ''
      const adviceText = adviceInWords(codex.advice)
      const color = adviceText ? 'yellow' as const : undefined
      const oneLine = count + expiry + (adviceText ? ' · ' + adviceText : '')
      const indent = Array.from(FOOTER_INDENT.text).length
      if (indent + Array.from(oneLine).length <= columns || !adviceText) {
        footer.push(clipRow([FOOTER_INDENT, { text: oneLine, color }], columns))
      } else {
        // Narrow pane: keep the count line whole and give the advice its own line.
        footer.push(clipRow([FOOTER_INDENT, { text: count + expiry, color }], columns))
        footer.push(clipRow([FOOTER_INDENT, { text: adviceText, color }], columns))
      }
    }
    if (queued > 0) {
      const text = '⧗' + queued + (queued === 1 ? ' queued task' : ' queued tasks')
      footer.push(clipRow([FOOTER_INDENT, { text }], columns))
    }
    return (
      <Box flexDirection="column">
        {versionDrift && (
          <Text color="yellow" wrap="truncate-end">
            {`codex-workers ${versionDrift.loaded} loaded, ${versionDrift.installed} installed — run /reload-plugins`}
          </Text>
        )}
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
        {footer.map(row => (
          <Box flexDirection="row">
            {renderSegments(Text, row)}
          </Box>
        ))}
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const { workers, now, codex, claude, versionDrift, queued } = await readRenderState($)
    const row = layoutBand(workers, now, claude, codex, e.props.bodyColumns, versionDrift, queued)
    return (
      <Box flexDirection="row">
        {renderSegments(Text, row)}
      </Box>
    )
  })
}
