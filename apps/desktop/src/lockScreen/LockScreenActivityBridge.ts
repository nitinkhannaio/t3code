import {
  clampLockScreenCount,
  clipLockScreenText,
  isLockScreenProjectIcon,
  LOCK_SCREEN_TEXT_MAX_CHARS,
  lockScreenLine,
  LOCK_SCREEN_SHOWN_ROW_COUNTS,
  LOCK_SCREEN_TIMED_STATUSES,
  PROVIDER_DISPLAY_NAMES,
  type DesktopLockScreenActivity,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import * as Option from "effect/Option";

export interface LockScreenHelper {
  /** False when the pipe is full; the helper calls `onDrain` once it can take more. */
  readonly write: (line: string) => boolean;
  /** Closing stdin is how the helper learns to tear down. */
  readonly end: () => void;
}

export interface LockScreenHelperEvents {
  readonly onDrain: () => void;
  readonly onExit: () => void;
}

export interface LockScreenPolicy {
  readonly enabled: boolean;
  readonly showTitles: boolean;
}

const KNOWN_PROVIDERS: ReadonlySet<string> = new Set(Object.keys(PROVIDER_DISPLAY_NAMES));
const CLEAR = "null";
// The helper's line cap, newline included.
const MAX_LINE_BYTES = 64 * 1024;
// Keeps every timestamp a four-digit-year ISO string.
const MIN_TIME = Date.UTC(2000, 0, 1);
const MAX_TIME = Date.UTC(9999, 11, 31, 23, 59, 59);

const clip = (value: string) => clipLockScreenText(value, LOCK_SCREEN_TEXT_MAX_CHARS);
const lineBytes = (line: string) => new TextEncoder().encode(line).length + 1;

// Whole seconds, so ISO 8601 parsers without fractional-second support accept it.
function isoSeconds(epochMs: number): string | null {
  const clamped = Math.min(MAX_TIME, Math.max(MIN_TIME, epochMs));
  return Option.getOrNull(
    Option.map(DateTime.make(clamped), (at) => DateTime.formatIso(at).replace(/\.\d+Z$/, "Z")),
  );
}

function wireText(text: DesktopLockScreenActivity["text"], more: Record<string, string>) {
  const { noProject: _noProject, untitledProject: _untitled, ...shown } = text;
  return {
    ...shown,
    summary: shown.summary.map(clip),
    updated: clip(shown.updated),
    more: Object.fromEntries(Object.entries(more).map(([count, label]) => [count, clip(label)])),
    showFewer: clip(shown.showFewer),
    statuses: Object.fromEntries(
      Object.entries(shown.statuses).map(([status, label]) => [status, clip(label)]),
    ),
    duration: {
      seconds: clip(shown.duration.seconds),
      minutes: clip(shown.duration.minutes),
      hours: clip(shown.duration.hours),
    },
    agent: clip(shown.agent),
  };
}

// Drops the largest icons until the line fits; null when even an icon-free line is too long.
function fitLine(
  card: { readonly rows: ReadonlyArray<IconHolder>; readonly projects: ReadonlyArray<IconHolder> },
  build: (rows: ReadonlyArray<IconHolder>, projects: ReadonlyArray<IconHolder>) => string,
  maxBytes: number,
): string | null {
  let rows = card.rows;
  let projects = card.projects;
  let line = build(rows, projects);
  while (lineBytes(line) > maxBytes) {
    const all = [...rows, ...projects].filter((item) => item.projectIcon !== null);
    if (all.length === 0) return null;
    const largest = all.reduce((left, right) =>
      (right.projectIcon?.length ?? 0) > (left.projectIcon?.length ?? 0) ? right : left,
    );
    const strip = <A extends IconHolder>(item: A): A =>
      item === largest ? { ...item, projectIcon: null } : item;
    rows = rows.map(strip);
    projects = projects.map(strip);
    line = build(rows, projects);
  }
  return line;
}

interface IconHolder {
  readonly projectIcon: string | null;
}

function render(activity: DesktopLockScreenActivity, showTitles: boolean, maxLineBytes: number) {
  // Without titles the card may only group by project; a renderer that has not caught up with
  // the setting yet shows nothing until it republishes.
  const mode = showTitles ? "threads" : "projects";
  if (activity.mode !== mode) return null;
  const { text } = activity;
  const hidden: Partial<Record<(typeof LOCK_SCREEN_SHOWN_ROW_COUNTS)[number], number>> = {};
  const more: Record<string, string> = {};
  for (const shown of LOCK_SCREEN_SHOWN_ROW_COUNTS) {
    const left = clampLockScreenCount(activity.hidden[shown] ?? 0);
    const label = text.more[String(left)];
    // An overflow row without its copy is dropped rather than shown in a fallback language.
    if (left === 0 || label === undefined) continue;
    hidden[shown] = left;
    more[String(left)] = label;
  }
  const projects =
    mode === "projects"
      ? activity.projects.map((project) => {
          const attention =
            project.attentionStatus === null ? 0 : clampLockScreenCount(project.attention);
          return {
            // Identity, not display text, so a translation never makes the card look updated.
            name: project.noProject || project.name === null ? null : lockScreenLine(project.name),
            noProject: project.noProject,
            projectIcon: isLockScreenProjectIcon(project.projectIcon) ? project.projectIcon : null,
            attention,
            attentionStatus: attention === 0 ? null : project.attentionStatus,
            working: clampLockScreenCount(project.working),
            done: clampLockScreenCount(project.done),
          };
        })
      : [];
  const content = {
    mode,
    counts: {
      attention: clampLockScreenCount(activity.counts.attention),
      working: clampLockScreenCount(activity.counts.working),
      waiting: clampLockScreenCount(activity.counts.waiting),
      done: clampLockScreenCount(activity.counts.done),
    },
    rows:
      mode === "threads"
        ? activity.rows.map((row) => ({
            status: row.status,
            provider:
              row.provider !== null && KNOWN_PROVIDERS.has(row.provider) ? row.provider : null,
            title: row.title === null ? null : lockScreenLine(row.title),
            since:
              row.since !== null && LOCK_SCREEN_TIMED_STATUSES.has(row.status)
                ? isoSeconds(row.since)
                : null,
            projectIcon: isLockScreenProjectIcon(row.projectIcon) ? row.projectIcon : null,
          }))
        : [],
    projects,
    hidden,
  };
  const shownText = wireText(text, more);
  const display = projects.map(({ noProject, ...project }) => ({
    ...project,
    name: noProject ? clip(text.noProject) : (project.name ?? clip(text.untitledProject)),
  }));
  return {
    contentKey: JSON.stringify(content),
    key: JSON.stringify({ content, display, text: shownText }),
    asOf: activity.asOf,
    line: (asOf: number) =>
      fitLine(
        { rows: content.rows, projects: display },
        (rows, fitted) =>
          JSON.stringify({
            asOf: isoSeconds(asOf) ?? isoSeconds(MIN_TIME),
            ...content,
            rows,
            projects: fitted,
            text: shownText,
          }),
        maxLineBytes,
      ),
  };
}

/**
 * Holds the latest card in memory and forwards it to the helper only while the screen is locked.
 * The helper refuses to start on a locked screen, so it is started while unlocked and kept
 * running; one that exits during a lock is started again after unlock. One renderer owns the
 * card at a time; anything that makes it stale clears it.
 */
export function makeLockScreenActivityBridge(
  spawn: (events: LockScreenHelperEvents) => LockScreenHelper | null,
  options: { readonly maxLineBytes?: number } = {},
) {
  const maxLineBytes = options.maxLineBytes ?? MAX_LINE_BYTES;
  let policy: LockScreenPolicy = { enabled: false, showTitles: false };
  let locked = false;
  let owner: number | null = null;
  let latest: DesktopLockScreenActivity | null = null;
  let helper: LockScreenHelper | null = null;
  // A helper told to stop that has not exited yet; no second one starts beside it.
  let retiring: LockScreenHelper | null = null;
  // The key the helper last received; a fresh helper starts with nothing shown.
  let delivered = CLEAR;
  // The last card the lock screen showed and its time, kept across unlocks. A renderer that
  // reloads, or whose card flickers while unlocked, must not make an unchanged card look updated.
  let shown: { readonly contentKey: string; readonly asOf: number } | null = null;
  // At most one line waits for the pipe to drain; a newer line replaces it.
  let queued: string | null = null;
  let blocked = false;
  // One immediate restart while unlocked; after that, wait for the next unlock or setting change.
  let restarted = false;

  const write = (line: string) => {
    if (helper === null) return;
    if (blocked) {
      queued = line;
      return;
    }
    if (!helper.write(`${line}\n`)) blocked = true;
  };

  const reset = () => {
    helper = null;
    delivered = CLEAR;
    queued = null;
    blocked = false;
  };

  const stop = () => {
    const current = helper;
    if (current === null) return;
    if (delivered !== CLEAR) current.write(`${CLEAR}\n`);
    reset();
    retiring = current;
    current.end();
  };

  const arm = () => {
    if (helper !== null || retiring !== null || locked || !policy.enabled) return;
    const spawned = spawn({
      onDrain: () => {
        if (helper !== spawned) return;
        blocked = false;
        const next = queued;
        queued = null;
        if (next !== null) write(next);
      },
      onExit: () => {
        if (retiring === spawned) {
          retiring = null;
          return sync();
        }
        if (helper !== spawned) return;
        reset();
        if (!locked && !restarted) {
          restarted = true;
          arm();
        }
      },
    });
    if (spawned !== null) helper = spawned;
  };

  const sync = () => {
    if (!policy.enabled) {
      latest = null;
      shown = null;
      stop();
      return;
    }
    arm();
    const card = locked && latest !== null ? render(latest, policy.showTitles, maxLineBytes) : null;
    const key = card?.key ?? CLEAR;
    if (helper === null || key === delivered) return;
    delivered = key;
    if (card === null) return write(CLEAR);
    if (shown?.contentKey !== card.contentKey) {
      shown = { contentKey: card.contentKey, asOf: card.asOf };
    }
    write(card.line(shown.asOf) ?? CLEAR);
  };

  return {
    isLocked: () => locked,
    configure: (next: LockScreenPolicy, requestCurrentCard?: () => void) => {
      const justEnabled = next.enabled && !policy.enabled;
      if (justEnabled) restarted = false;
      policy = next;
      sync();
      if (justEnabled) requestCurrentCard?.();
    },
    setLocked: (next: boolean) => {
      if (!next && locked) restarted = false;
      locked = next;
      sync();
    },
    publish: (from: number, activity: DesktopLockScreenActivity | null) => {
      if (!policy.enabled) return;
      owner = from;
      latest = activity;
      // Emptied on purpose while locked: whatever comes next is news, even if it matches.
      if (activity === null && locked) shown = null;
      sync();
    },
    /** The owner hung, crashed, reloaded, or closed, so its last card can no longer be trusted. */
    invalidate: (from: number) => {
      if (from !== owner) return;
      owner = null;
      latest = null;
      sync();
    },
    dispose: () => {
      policy = { enabled: false, showTitles: false };
      owner = null;
      sync();
    },
  };
}

export type LockScreenActivityBridge = ReturnType<typeof makeLockScreenActivityBridge>;
