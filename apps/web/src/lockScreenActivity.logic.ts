import { deadlineStore } from "@t3tools/client-runtime/clock";
import type {
  LockScreenActivity,
  LockScreenHidden,
} from "@t3tools/client-runtime/state/lock-screen-activity";
import {
  clipLockScreenText,
  LOCK_SCREEN_TEXT_MAX_CHARS,
  type ClientSettings,
  type DesktopBridge,
  type DesktopLockScreenActivity,
} from "@t3tools/contracts";
import { Atom } from "effect/reactivity";
import { msg } from "gt-react";

import { m } from "./i18n/messages";

/**
 * An atom that mirrors a store outside the registry. A change sets the value instead of
 * recomputing, because recomputing would resubscribe inside the store's own listener loop,
 * and a Set visits listeners added while it is iterated, so that loop never ends.
 */
export function externalStoreAtom<A>(
  subscribe: (listener: () => void) => () => void,
  read: () => A,
) {
  return Atom.make((get) => {
    get.addFinalizer(subscribe(() => get.setSelf(read())));
    return read();
  });
}

export function watchLockScreenSnooze(wakesAt: number, onWake: () => void): () => void {
  const deadline = deadlineStore(wakesAt);
  const unsubscribe = deadline.subscribe(onWake);
  if (!deadline.getSnapshot()) return unsubscribe;

  // A snooze may expire during selection, before the clock is subscribed.
  let subscribed = true;
  queueMicrotask(() => {
    if (subscribed) onWake();
  });
  return () => {
    subscribed = false;
    unsubscribe();
  };
}

/**
 * The visit the card judges Done and Failed by. While locked, the main window still marks the thread
 * it has open as visited when its run ends, so visits after the lock count as made at the lock.
 */
export function lockScreenVisit(
  lastVisitedAt: string | undefined,
  lockedAtMs: number | null,
): string | undefined {
  if (lastVisitedAt === undefined || lockedAtMs === null) return lastVisitedAt;
  const visitedAt = Date.parse(lastVisitedAt);
  return Number.isNaN(visitedAt) || visitedAt <= lockedAtMs
    ? lastVisitedAt
    : new Date(lockedAtMs).toISOString();
}

/**
 * Rendered project icons by identity, so a publish reads a finished icon instead of drawing it
 * again. A miss starts one render and reads null until it settles and listeners hear of it.
 */
export function createLockScreenIconCache<Source>(
  render: (source: Source) => Promise<string | null>,
  limit = 64,
) {
  const settled = new Map<string, string | null>();
  const pending = new Set<string>();
  const listeners = new Set<() => void>();
  let version = 0;
  const settle = (key: string, icon: string | null) => {
    pending.delete(key);
    settled.set(key, icon);
    for (const evicted of settled.keys()) {
      if (settled.size <= limit) break;
      settled.delete(evicted);
    }
    version++;
    for (const listener of listeners) listener();
  };
  return {
    /** Changes whenever an icon settles, so an atom can depend on the cache. */
    version: () => version,
    read: (key: string, source: Source): string | null => {
      if (settled.has(key)) {
        const icon = settled.get(key) ?? null;
        settled.delete(key);
        settled.set(key, icon);
        return icon;
      }
      if (!pending.has(key)) {
        pending.add(key);
        // Reads happen while atoms compute; drawing touches the DOM, so it waits for them to finish.
        void Promise.resolve()
          .then(() => render(source))
          .then(
            (icon) => settle(key, icon),
            () => settle(key, null),
          );
      }
      return null;
    },
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}

type LockScreenText = DesktopLockScreenActivity["text"];
type LockScreenMode = DesktopLockScreenActivity["mode"];

const clip = (value: string) => clipLockScreenText(value, LOCK_SCREEN_TEXT_MAX_CHARS);

// The helper fills these placeholders; a translation missing one would show raw text.
function template(localized: string, english: string, placeholders: readonly string[]): string {
  const clipped = clip(localized);
  return placeholders.every((placeholder) => clipped.includes(placeholder)) ? clipped : english;
}

/**
 * The card's copy in the current UI language, each line within what the card accepts.
 * Templates keep their `{placeholder}` for the helper, which fills in times and durations.
 */
export function lockScreenText(
  input: {
    readonly mode: LockScreenMode;
    readonly counts: DesktopLockScreenActivity["counts"];
    readonly hidden: LockScreenHidden;
  },
  resolve: typeof m = m,
): LockScreenText {
  const { counts } = input;
  const summary: string[] = [];
  if (counts.attention > 0) {
    summary.push(
      resolve(
        msg("{count, plural, one {{count} needs you} other {{count} need you}}", {
          count: counts.attention,
        }),
      ),
    );
  }
  if (counts.working > 0) summary.push(resolve(msg("{count} working", { count: counts.working })));
  if (counts.waiting > 0) summary.push(resolve(msg("{count} waiting", { count: counts.waiting })));
  if (counts.done > 0) summary.push(resolve(msg("{count} done", { count: counts.done })));
  const more: Record<string, string> = {};
  for (const count of Object.values(input.hidden)) {
    more[String(count)] = clip(
      input.mode === "threads"
        ? resolve(
            msg("{count, plural, one {{count} more thread} other {{count} more threads}}", {
              count,
            }),
          )
        : resolve(
            msg("{count, plural, one {{count} more project} other {{count} more projects}}", {
              count,
            }),
          ),
    );
  }
  return {
    summary: summary.map(clip),
    updated: template(resolve(msg("Updated {time}", { time: "{time}" })), "Updated {time}", [
      "{time}",
    ]),
    more,
    showFewer: clip(resolve(msg("Show fewer"))),
    expandLabel: clip(resolve(msg("Show additional sessions"))),
    collapseLabel: clip(resolve(msg("Hide additional sessions"))),
    statuses: {
      approval: clip(resolve(msg("Approval"))),
      input: clip(resolve(msg("Input"))),
      request: clip(resolve(msg("Request"))),
      limited: clip(resolve(msg("Limited"))),
      failed: clip(resolve(msg("Failed"))),
      working: clip(resolve(msg("Working"))),
      waiting: clip(resolve(msg("Waiting"))),
      done: clip(resolve(msg("Done"))),
    },
    duration: {
      seconds: template(resolve(msg("{count}s", { count: "{count}" })), "{count}s", ["{count}"]),
      minutes: template(resolve(msg("{count}m", { count: "{count}" })), "{count}m", ["{count}"]),
      hours: template(
        resolve(msg("{hours}h {minutes}m", { hours: "{hours}", minutes: "{minutes}" })),
        "{hours}h {minutes}m",
        ["{hours}", "{minutes}"],
      ),
    },
    agent: clip(resolve(msg("Agent"))),
    noProject: clip(resolve(msg("No project"))),
    untitledProject: clip(resolve(msg("Untitled project"))),
  };
}

/**
 * Builds and sends the card only while the setting is on and the screen is locked, and only when
 * what it shows changes. The host applies the same settings again before anything reaches the
 * lock screen.
 */
export function createLockScreenPublisher(input: {
  readonly bridge: Pick<
    DesktopBridge,
    "setLockScreenActivity" | "onLockScreenActivityRepublish" | "onLockScreenLockedChange"
  >;
  readonly settings: () => Pick<
    ClientSettings,
    "lockScreenActivityEnabled" | "lockScreenActivityShowTitles"
  >;
  readonly subscribeSettings: (listener: () => void) => () => void;
  readonly card: () => LockScreenActivity | null;
  readonly watchCard: (onChange: () => void) => () => void;
  /** Hears UI language switches, which change the card's copy but not its content. */
  readonly subscribeLocale: (listener: () => void) => () => void;
  readonly localize?: (input: Parameters<typeof lockScreenText>[0]) => LockScreenText;
  readonly now?: () => number;
}): () => void {
  const { setLockScreenActivity, onLockScreenActivityRepublish, onLockScreenLockedChange } =
    input.bridge;
  if (!setLockScreenActivity || !onLockScreenActivityRepublish || !onLockScreenLockedChange) {
    return () => {};
  }
  const now = input.now ?? Date.now;
  const localize = input.localize ?? ((content) => lockScreenText(content));
  let sentKey: string | null = null;
  let changed: { readonly key: string; readonly at: number } | null = null;
  let stopWatching: (() => void) | null = null;
  let locked = false;
  let sends = 0;

  const send = (activity: DesktopLockScreenActivity | null) => {
    const sequence = ++sends;
    void setLockScreenActivity(activity).catch(() => {
      // A card the host rejected must not leave the one before it showing.
      if (activity === null || sequence !== sends) return;
      sentKey = "null";
      send(null);
    });
  };
  const publish = () => {
    const card = input.card();
    const mode: LockScreenMode = input.settings().lockScreenActivityShowTitles
      ? "threads"
      : "projects";
    // A card built for the other mode is stale; the rebuilt one arrives through watchCard.
    if (card !== null && card.mode !== mode) return;
    const content =
      card === null
        ? null
        : {
            mode: card.mode,
            counts: card.counts,
            rows: card.rows.map((row) => ({
              status: row.status,
              provider: row.provider,
              title: row.title,
              since: row.since,
              projectIcon: row.projectIcon,
            })),
            projects: card.projects,
            hidden: card.hidden,
          };
    // Copy is left out of this key, so a language switch resends without moving asOf.
    const contentKey = JSON.stringify(content);
    const activity = content === null ? null : { ...content, text: localize(content) };
    const key = JSON.stringify(activity);
    if (key === sentKey) return;
    sentKey = key;
    // The card shows asOf as "last changed", so resending unchanged content keeps its time.
    if (changed?.key !== contentKey) changed = { key: contentKey, at: now() };
    send(activity === null ? null : { asOf: changed.at, ...activity });
  };
  // Clears the card without forgetting when its content last changed.
  const stop = () => {
    if (stopWatching === null) return;
    stopWatching();
    stopWatching = null;
    sentKey = null;
    send(null);
  };
  const sync = () => {
    // Unlocked, nothing is built: thread shells change many times a second while agents work.
    if (!input.settings().lockScreenActivityEnabled || !locked) return stop();
    stopWatching ??= input.watchCard(publish);
    publish();
  };

  const unsubscribeSettings = input.subscribeSettings(sync);
  const unsubscribeLocked = onLockScreenLockedChange((next) => {
    locked = next;
    sync();
  });
  const unsubscribeLocale = input.subscribeLocale(() => {
    if (stopWatching !== null) publish();
  });
  const unsubscribeRepublish = onLockScreenActivityRepublish(() => {
    if (stopWatching === null) return;
    sentKey = null;
    publish();
  });
  sync();

  return () => {
    unsubscribeSettings();
    unsubscribeLocked();
    unsubscribeLocale();
    unsubscribeRepublish();
    stop();
  };
}
