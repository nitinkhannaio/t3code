import {
  clampLockScreenCount,
  isListedThreadLineage,
  isLockScreenProjectIcon,
  lockScreenLine,
  LOCK_SCREEN_ROW_LIMIT,
  LOCK_SCREEN_SHOWN_ROW_COUNTS,
  type LockScreenGroup,
  LOCK_SCREEN_STATUSES,
  LOCK_SCREEN_TIMED_STATUSES,
  lockScreenStatusGroup,
  type DesktopLockScreenActivity,
  type EnvironmentId,
  type LockScreenShownRowCount,
  type LockScreenStatus,
  type OrchestrationV2ThreadShell,
  type ProviderDriverKind,
} from "@t3tools/contracts";
import { monitorHoldsWakeCompletion } from "@t3tools/shared/orchestrationV2PendingBackgroundWork";
import * as DateTime from "effect/DateTime";
import * as Option from "effect/Option";

import {
  resolveThreadWorkingStartedAt,
  threadRuntimeIsActive,
  type EnvironmentThreadShell,
} from "./models.ts";
import {
  isThreadWorking,
  sortInboxThreadsByReturn,
  sortWorkingThreadsBySend,
} from "./threadInbox.ts";
import { effectiveSnoozed, hasUnseenCompletion, hasUnseenRunFailure } from "./threadSettled.ts";
import { resolveThreadActivityTimestamp, toSortableTimestamp } from "./threadSort.ts";

export type LockScreenThreadInput = Pick<
  EnvironmentThreadShell,
  | "environmentId"
  | "id"
  | "projectId"
  | "title"
  | "createdAt"
  | "unsettledAt"
  | "latestUserAuthoredMessageAt"
  | "latestUserMessageAt"
  | "updatedAt"
  | "archivedAt"
  | "deletedAt"
  | "lineage"
  | "interactionMode"
  | "hasActionableProposedPlan"
  | "hasPendingApprovals"
  | "hasPendingUserInput"
  | "pendingSubagentRequest"
  | "pendingGuestMessageCount"
  | "pendingUserInputAt"
  | "blockedOnThreadWait"
  | "settledOverride"
  | "snoozedAt"
  | "snoozedUntil"
  | "latestRun"
  | "runtime"
  | "lastVisitedAt"
> & {
  readonly source: Pick<
    OrchestrationV2ThreadShell,
    | "latestRunStopRequested"
    | "latestRunBackgroundWake"
    | "pendingBackgroundTasks"
    | "pendingRuntimeRequest"
  >;
};

const LOCK_SCREEN_GROUPS: ReadonlyArray<LockScreenGroup> = [
  "attention",
  "working",
  "waiting",
  "done",
];

type LockScreenAttentionStatus = NonNullable<
  DesktopLockScreenActivity["projects"][number]["attentionStatus"]
>;

/** Items left out when the card shows k rows, keyed by k; zero counts are left out. */
export type LockScreenHidden = Partial<Record<LockScreenShownRowCount, number>>;

export type LockScreenMode = DesktopLockScreenActivity["mode"];

/** One row per project, for when thread titles stay private. */
export type LockScreenProjectRow = DesktopLockScreenActivity["projects"][number];

/** Everything a locked screen may show in one mode. Nothing else leaves the unlocked app. */
export interface LockScreenActivity {
  readonly asOf: number;
  readonly mode: LockScreenMode;
  /** Every count here is already clamped to what the card shows. */
  readonly counts: DesktopLockScreenActivity["counts"];
  readonly hidden: LockScreenHidden;
  /** Threads mode only. */
  readonly rows: ReadonlyArray<{
    readonly status: LockScreenStatus;
    readonly provider: ProviderDriverKind | null;
    readonly title: string | null;
    /** Local-clock epoch ms a working or waiting row counts its duration from. */
    readonly since: number | null;
    /** An inline PNG the lock screen shows as is; it never fetches. */
    readonly projectIcon: string | null;
  }>;
  /** Projects mode only. */
  readonly projects: ReadonlyArray<LockScreenProjectRow>;
}

// Matches the sidebar's row status, so the card never disagrees with what the app shows.
function lockScreenStatus(thread: LockScreenThreadInput): LockScreenStatus | null {
  if (thread.hasPendingApprovals || thread.pendingSubagentRequest === "approval") return "approval";
  if (thread.hasPendingUserInput || thread.pendingSubagentRequest === "user_input") return "input";
  if ((thread.pendingGuestMessageCount ?? 0) > 0) return "request";
  const { runtime, latestRun } = thread;
  // Settling shelves an outcome; a usage limit still blocks the next turn.
  const shelved = thread.settledOverride === "settled";
  if (runtime?.status === "failed") {
    if (runtime.lastErrorClass === "usage_limit") return "limited";
    // A failed run the user has opened since is seen; a runtime failure without one has no date.
    if (latestRun?.status === "failed" && !hasUnseenRunFailure(thread)) return null;
    return shelved ? null : "failed";
  }
  // Parked on another thread, or idle while awaited background work holds the run open.
  if (runtime?.status === "idle") return "waiting";
  if (runtime?.status === "running" && thread.blockedOnThreadWait === true) return "waiting";
  if (threadRuntimeIsActive(runtime)) return isThreadWorking(thread) ? "working" : null;
  if (latestRun?.status !== "completed" || thread.source.latestRunStopRequested === true)
    return null;
  if (monitorHoldsWakeCompletion(thread.source)) return "waiting";
  return shelved || !hasUnseenCompletion(thread) ? null : "done";
}

function sinceFor(status: LockScreenStatus, thread: LockScreenThreadInput): string | null {
  if (!LOCK_SCREEN_TIMED_STATUSES.has(status)) return null;
  return status === "working"
    ? resolveThreadWorkingStartedAt(thread)
    : (thread.latestRun?.completedAt ?? null);
}

function sortByCompletion(threads: readonly LockScreenThreadInput[]): LockScreenThreadInput[] {
  const at = (thread: LockScreenThreadInput) =>
    toSortableTimestamp(thread.latestRun?.completedAt ?? undefined) ?? 0;
  return [...threads].sort(
    (left, right) =>
      at(right) - at(left) ||
      left.id.localeCompare(right.id) ||
      left.environmentId.localeCompare(right.environmentId),
  );
}

function sortForStatus(status: LockScreenStatus, threads: readonly LockScreenThreadInput[]) {
  if (status === "done") return sortByCompletion(threads);
  if (status === "working" || status === "waiting") return sortWorkingThreadsBySend(threads);
  return sortInboxThreadsByReturn(threads);
}

function hiddenFor(total: number): LockScreenHidden {
  const hidden: LockScreenHidden = {};
  for (const shown of LOCK_SCREEN_SHOWN_ROW_COUNTS) {
    const left = clampLockScreenCount(total - Number(shown));
    if (left > 0) hidden[shown] = left;
  }
  return hidden;
}

function isAttentionStatus(status: LockScreenStatus): status is LockScreenAttentionStatus {
  return lockScreenStatusGroup(status) === "attention";
}

const URGENCY: ReadonlyMap<LockScreenStatus, number> = new Map(
  LOCK_SCREEN_STATUSES.map((status, index) => [status, index]),
);

interface ProjectGroup {
  readonly key: string;
  readonly name: string | null;
  readonly noProject: boolean;
  readonly first: LockScreenThreadInput;
  attention: number;
  attentionStatus: LockScreenAttentionStatus | null;
  working: number;
  done: number;
  lastActivityAt: number;
}

/** Folds one thread into its project's counts; projects mode never sorts threads. */
function addToProject(
  groups: Map<string, ProjectGroup>,
  status: LockScreenStatus,
  thread: LockScreenThreadInput,
  input: {
    readonly projectName: (thread: LockScreenThreadInput) => string | null;
    readonly toLocalClock: (environmentId: EnvironmentId, serverMs: number) => number;
  },
) {
  const rawName = input.projectName(thread);
  const key = rawName === null ? "" : `${thread.environmentId}\u0000${thread.projectId}`;
  let group = groups.get(key);
  if (group === undefined) {
    group = {
      key,
      name: rawName === null ? null : lockScreenLine(rawName),
      noProject: rawName === null,
      first: thread,
      attention: 0,
      attentionStatus: null,
      working: 0,
      done: 0,
      lastActivityAt: Number.NEGATIVE_INFINITY,
    };
    groups.set(key, group);
  }
  if (isAttentionStatus(status)) {
    group.attention++;
    if (
      group.attentionStatus === null ||
      URGENCY.get(status)! < URGENCY.get(group.attentionStatus)!
    ) {
      group.attentionStatus = status;
    }
  } else if (status === "done") group.done++;
  else group.working++;
  const activity = toSortableTimestamp(resolveThreadActivityTimestamp(thread) ?? undefined);
  if (activity !== null) {
    // Environments' clocks differ, so recency is compared on this machine's clock.
    const local = input.toLocalClock(thread.environmentId, activity);
    group.lastActivityAt = Math.max(group.lastActivityAt, local);
  }
}

function sortProjects(groups: Iterable<ProjectGroup>): ProjectGroup[] {
  return [...groups].sort(
    (left, right) =>
      Number(right.attention > 0) - Number(left.attention > 0) ||
      right.working - left.working ||
      right.lastActivityAt - left.lastActivityAt ||
      left.key.localeCompare(right.key),
  );
}

export function buildLockScreenActivity(input: {
  /** Only shells from live environments: a disconnected one's may be stale. */
  readonly threads: ReadonlyArray<LockScreenThreadInput>;
  /** Threads mode reveals titles; projects mode reads neither titles nor drivers. */
  readonly mode: LockScreenMode;
  readonly providerDriver: (thread: LockScreenThreadInput) => ProviderDriverKind | null;
  /** Null when the thread has no project the card can name. */
  readonly projectName: (thread: LockScreenThreadInput) => string | null;
  /** Read only for rows that are sent, since drawing an icon is not free. */
  readonly projectIcon: (thread: LockScreenThreadInput) => string | null;
  /** Converts an environment's epoch ms to this machine's clock, which the lock screen runs on. */
  readonly toLocalClock: (environmentId: EnvironmentId, serverMs: number) => number;
  readonly asOf: number;
}): LockScreenActivity | null {
  const byStatus = new Map<LockScreenStatus, LockScreenThreadInput[]>();
  const groups = new Map<string, ProjectGroup>();
  const counts = { attention: 0, working: 0, waiting: 0, done: 0 };
  let total = 0;
  const now = Option.getOrNull(Option.map(DateTime.make(input.asOf), DateTime.formatIso));
  for (const thread of input.threads) {
    if (thread.archivedAt !== null || thread.deletedAt !== null) continue;
    if (!isListedThreadLineage(thread.lineage)) continue;
    if (now !== null && effectiveSnoozed(thread, { now })) continue;
    const status = lockScreenStatus(thread);
    if (status === null) continue;
    total++;
    counts[lockScreenStatusGroup(status)]++;
    if (input.mode === "projects") {
      addToProject(groups, status, thread, input);
      continue;
    }
    const list = byStatus.get(status);
    if (list === undefined) byStatus.set(status, [thread]);
    else list.push(thread);
  }
  if (total === 0) return null;
  for (const group of LOCK_SCREEN_GROUPS) counts[group] = clampLockScreenCount(counts[group]);
  const iconFor = (thread: LockScreenThreadInput) => {
    const icon = input.projectIcon(thread);
    return isLockScreenProjectIcon(icon) ? icon : null;
  };

  if (input.mode === "projects") {
    const sorted = sortProjects(groups.values());
    return {
      asOf: input.asOf,
      mode: "projects",
      counts,
      hidden: hiddenFor(sorted.length),
      rows: [],
      projects: sorted.slice(0, LOCK_SCREEN_ROW_LIMIT).map((group) => ({
        name: group.name,
        noProject: group.noProject,
        projectIcon: group.noProject ? null : iconFor(group.first),
        attention: clampLockScreenCount(group.attention),
        attentionStatus: group.attentionStatus,
        working: clampLockScreenCount(group.working),
        done: clampLockScreenCount(group.done),
      })),
    };
  }

  const ordered = LOCK_SCREEN_STATUSES.flatMap((status) =>
    sortForStatus(status, byStatus.get(status) ?? []).map((thread) => ({ status, thread })),
  );
  return {
    asOf: input.asOf,
    mode: "threads",
    counts,
    hidden: hiddenFor(total),
    projects: [],
    rows: ordered.slice(0, LOCK_SCREEN_ROW_LIMIT).map(({ status, thread }) => {
      const startedAt = sinceFor(status, thread);
      // Whole seconds, so a small clock-offset correction does not resend the card.
      const since = Option.getOrNull(
        Option.map(
          startedAt === null ? Option.none() : DateTime.make(startedAt),
          (at) =>
            Math.floor(
              input.toLocalClock(thread.environmentId, DateTime.toEpochMillis(at)) / 1000,
            ) * 1000,
        ),
      );
      return {
        status,
        provider: input.providerDriver(thread),
        title: lockScreenLine(thread.title),
        since,
        projectIcon: iconFor(thread),
      };
    }),
  };
}
