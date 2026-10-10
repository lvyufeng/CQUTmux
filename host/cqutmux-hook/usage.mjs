// Per-agent rate-limit windows for the Usages board.
//
// Kept out of index.mjs so the rules can be checked with plain node, with no
// gateway, no port and no network — the same reason the app's model types are
// Foundation-only. The board is read at a glance to decide whether to keep
// working, so a wrong window is a wrong answer to that question, and nothing on
// screen would say so.
//
// What the windows are comes from Moshi's own documentation of the screen: the
// agents do not share a rate-limit shape. Claude Code enforces fixed 5h and 7d
// windows; Codex exposes a variable set with human labels; OpenCode's come
// from whatever provider it is driving; Kimi Code and Grok Build show weekly or
// credit windows. One window set for every agent — which is what this used to
// do — states Claude's limits on behalf of an agent that has different ones.

export const HOUR = 60 * 60 * 1000
export const DAY = 24 * HOUR

// The caps are counts of events this host has seen, not the provider's real
// limit — the gateway never learns the real one from a hook payload. They are
// the numbers the board has always used, kept per-agent so that changing one
// agent's shape cannot silently change another's.
const CLAUDE_WINDOWS = [
  { label: '5h', ms: 5 * HOUR, cap: 200 },
  { label: '7d', ms: 7 * DAY, cap: 800 },
]

const WINDOW_SETS = {
  'claude-code': CLAUDE_WINDOWS,

  // A variable set with human labels rather than the `5h`/`7d` pair. `weekly`
  // rather than `7d` is the documented label, and the label is what the user
  // reads — two agents whose windows are the same length but named differently
  // should still be named correctly.
  codex: [
    { label: '5h', ms: 5 * HOUR, cap: 200 },
    { label: 'weekly', ms: 7 * DAY, cap: 800 },
  ],

  // Weekly and rolling.
  'kimi-code': [
    { label: 'weekly', ms: 7 * DAY, cap: 800 },
  ],

  // A credit window rather than a rolling one: flagged, so the app can render it
  // as credits and not as a percentage of a rate limit. The length is a day
  // because a credit balance is not a rate over time; the window exists to give
  // it a reset, not a rate.
  'grok-build': [
    { label: 'credits', ms: DAY, cap: 100, credit: true },
  ],

  // Provider-dependent: the gateway cannot know which provider is behind an
  // OpenCode session, so it states the one thing it can — a single rolling
  // window — rather than inventing a 5h/7d pair the provider may not have.
  opencode: [
    { label: 'rolling', ms: 5 * HOUR, cap: 200 },
  ],
}

// Anything not named above. Claude's pair is the fallback because it is the
// shape the board shipped with and the one a new agent is most likely to share;
// the alternative — an empty card — would read as "no usage" rather than "we do
// not model this agent".
const DEFAULT_WINDOWS = CLAUDE_WINDOWS

export function windowsFor(source) {
  return WINDOW_SETS[source] ?? DEFAULT_WINDOWS
}

/// The windows for one agent, with the usage measured against them.
///
/// `times` are the agent's event timestamps in ms. Percent is capped at 100: a
/// host that has seen more events than the cap is over the limit, and showing
/// 140% on a ring that cannot draw past full is a number with nowhere to go.
export function windowsForSource(source, times, now) {
  return windowsFor(source).map(w => {
    const inWindow = times.filter(t => now - t < w.ms)
    const percent = Math.min(100, Math.round((inWindow.length / w.cap) * 1000) / 10)
    // Reset when the oldest event in the window ages out.
    const oldest = inWindow.sort((a, b) => a - b)[0]
    return {
      label: w.label,
      percent,
      resetIn: oldest === undefined ? null : humanize(oldest + w.ms - now),
      ...(w.credit ? { credit: true } : {}),
    }
  })
}

export function humanize(ms) {
  if (ms <= 0) return 'now'
  // Round to whole minutes first, so 59.6m carries into the hour instead of
  // printing "4h 60m".
  const totalMinutes = Math.round(ms / 60000)
  const h = Math.floor(totalMinutes / 60)
  const m = totalMinutes % 60
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}
