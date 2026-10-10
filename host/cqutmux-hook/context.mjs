// Where is this shell running? A one-shot probe with no gateway behind it.
//
// Moshi ships this as `moshi-hook context`: it is meant to be run from the
// user's own shell — a shell hook, a prompt, a status line — and to print the
// terminal's own context as JSON. It therefore reads the *environment the shell
// was started in*, not anything from the cqutmux daemon, and it must work when
// no gateway is running at all.
//
// The detection is split from the command so it can be checked with plain node:
// getting the wrong multiplexer, or reporting a pane that belongs to another
// window, is silent — the JSON looks exactly as valid as a right answer.

/// The multiplexer this shell is inside, and the ids that name the place.
///
/// Each program marks its shells with its own variables, and they are checked
/// in a fixed order so a nested session (zellij inside tmux, say) reports the
/// innermost one — the pane the user is typing in, not the outer frame.
export function detectContext(env = process.env) {
  // zellij before tmux: zellij can be run inside a tmux pane, and the innermost
  // session is the one the keystrokes go to. zellij exports both ZELLIJ and
  // ZELLIJ_PANE_ID; tmux exports TMUX and TMUX_PANE.
  if (env.ZELLIJ_PANE_ID || env.ZELLIJ) {
    return {
      kind: 'zellij',
      session: env.ZELLIJ || null,
      pane: env.ZELLIJ_PANE_ID || null,
    }
  }
  if (env.TMUX_PANE || env.TMUX) {
    return {
      kind: 'tmux',
      // `$TMUX` is `socket,server_pid,session_index`; the index is not the name,
      // so it is a last resort the command replaces by asking tmux itself.
      session: sessionIndexFromTmux(env.TMUX),
      pane: env.TMUX_PANE || null,
    }
  }
  if (env.HERDR_ENV) {
    return {
      kind: 'herdr',
      session: env.HERDR_SESSION || env.HERDR_ENV || null,
      pane: env.HERDR_PANE || null,
    }
  }
  return { kind: null, session: null, pane: null }
}

/// The session index from `$TMUX`, or null.
///
/// `$TMUX` is `socket_path,server_pid,session_index`. It is documented as the
/// session *index*, not the name, and the two differ — so this is only a
/// fallback for when `tmux` itself cannot be asked, and the command prefers the
/// name it gets from `tmux display-message`.
export function sessionIndexFromTmux(tmux) {
  if (typeof tmux !== 'string') return null
  const parts = tmux.split(',')
  if (parts.length < 3) return null
  const index = parts[2]
  return index === '' ? null : index
}

/// The JSON the probe prints: what this shell is, and where it is.
///
/// `cwd` is the shell's own working directory — the thing the agent hooks report
/// as `data.cwd`, so the two agree about which repository a request came from.
export function contextPayload(context, cwd) {
  return {
    kind: context.kind,
    session: context.session,
    pane: context.pane,
    cwd,
  }
}
