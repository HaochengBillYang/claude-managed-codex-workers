export type RunStatus = 'running' | 'done' | 'failed' | 'killed'

export type RunRecord = {
  id: string
  name: string
  batch: string
  effort: 'low' | 'medium' | 'high'
  /** Codex model id (e.g. gpt-6.2-sol); absent in records written before codex-run.sh recorded it. */
  model?: string
  sandbox: 'read-only' | 'workspace-write'
  pid: number
  status: RunStatus
  exit_code: number | null
  started_at: number
  ended_at: number | null
  events: string
  result: string
}

export type Worker = {
  record: RunRecord
  activity: string
  lostAt: number | null
  resultLine: string
}

export type WorkersSnapshot = { now: number; workers: Worker[] }

export type UsageWindow = { percent: number; resets: string }

export type CodexUsage = {
  fiveHour: UsageWindow | null
  weekly: UsageWindow | null
  resets: { count: number; expires: string | null } | null
  advice: string | null
  status: 'OK' | 'THROTTLE' | 'BLOCKED' | 'UNKNOWN'
  until: number | null
  reason: string | null
}

export type ClaudeUsageWindow = { percent: number; resetsAt: string | null }

export type ClaudeUsage = {
  fiveHour: ClaudeUsageWindow | null
  weekly: ClaudeUsageWindow | null
  contextPercent: number | null
  costUsd: number | null
}

export type VersionDrift = { loaded: string; installed: string }

declare module 'claude-code' {
  interface PluginState {
    'codex-workers': {
      runs: Shaped<WorkersSnapshot>
      usage: Shaped<CodexUsage>
      claudeUsage: Shaped<ClaudeUsage>
      seenIds: Shaped<string[]>
      paneOpen: boolean
      drift: VersionDrift | null
    }
  }
}
