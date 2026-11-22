import {
  buildLockScreenActivity,
  type LockScreenActivity,
  type LockScreenThreadInput,
} from "@t3tools/client-runtime/state/lock-screen-activity";
import { hasUnseenCompletion } from "@t3tools/client-runtime/state/thread-settled";
import {
  EnvironmentId,
  ProjectId,
  ProviderDriverKind,
  ProviderInstanceId,
  RunId,
  ThreadId,
  type DesktopLockScreenActivity,
} from "@t3tools/contracts";
import { Atom, AtomRegistry } from "effect/reactivity";
import { describe, expect, it, vi } from "vite-plus/test";

import { decodeOptions, gtFallback } from "gt-react";

import { resolveSidebarRowStatus } from "./components/Sidebar.logic";
import { m } from "./i18n/messages";
import en from "./i18n/translations/en.json";
import ru from "./i18n/translations/ru.json";
import {
  createLockScreenIconCache,
  createLockScreenPublisher,
  externalStoreAtom,
  lockScreenText,
  lockScreenVisit,
  watchLockScreenSnooze,
} from "./lockScreenActivity.logic";

describe("externalStoreAtom", () => {
  it("follows a store that notifies by iterating its listener Set, without resubscribing", () => {
    let value = 1;
    const listeners = new Set<() => void>();
    let notified = 0;
    const emit = () => {
      for (const listener of listeners) {
        // A listener that resubscribes mid-loop is visited again; stop instead of hanging.
        if (++notified > 10) throw new Error("listener loop");
        listener();
      }
    };
    const source = externalStoreAtom(
      (listener) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      () => value,
    );
    const card = Atom.make((get) => get(source) * 10);
    const registry = AtomRegistry.make();
    const seen: number[] = [];
    const unsubscribe = registry.subscribe(card, (next) => seen.push(next), { immediate: true });

    value = 2;
    emit();

    expect(seen).toEqual([10, 20]);
    expect(notified).toBe(1);
    expect(listeners.size).toBe(1);
    unsubscribe();
    registry.dispose();
  });
});

function setup(initial: { enabled: boolean; showTitles: boolean; locked?: boolean }) {
  let settings = {
    lockScreenActivityEnabled: initial.enabled,
    lockScreenActivityShowTitles: initial.showTitles,
  };
  let card: LockScreenActivity | null = null;
  const sent: Array<DesktopLockScreenActivity | null> = [];
  const settingsListeners = new Set<() => void>();
  const cardListeners = new Set<() => void>();
  const localeListeners = new Set<() => void>();
  let language = "en";
  let republish = () => {};
  let onLocked = (_locked: boolean) => {};
  let clock = 42;
  let reads = 0;
  const stop = createLockScreenPublisher({
    bridge: {
      setLockScreenActivity: async (activity) => {
        sent.push(activity);
      },
      onLockScreenLockedChange: (listener) => {
        onLocked = listener;
        listener(initial.locked ?? true);
        return () => {
          onLocked = () => {};
        };
      },
      onLockScreenActivityRepublish: (listener) => {
        republish = listener;
        return () => {
          republish = () => {};
        };
      },
    },
    settings: () => settings,
    subscribeSettings: (listener) => {
      settingsListeners.add(listener);
      return () => settingsListeners.delete(listener);
    },
    card: () => {
      reads++;
      return card;
    },
    watchCard: (listener) => {
      cardListeners.add(listener);
      return () => cardListeners.delete(listener);
    },
    subscribeLocale: (listener) => {
      localeListeners.add(listener);
      return () => localeListeners.delete(listener);
    },
    localize: (input) => {
      const english = lockScreenText(input);
      return language === "en" ? english : { ...english, showFewer: "Weniger" };
    },
    now: () => clock,
  });
  return {
    sent,
    stop,
    cardListeners,
    republish: () => republish(),
    lock: (next: boolean) => onLocked(next),
    reads: () => reads,
    setLanguage: (next: string) => {
      language = next;
      for (const listener of localeListeners) listener();
    },
    setNow: (next: number) => {
      clock = next;
    },
    setCard: (next: LockScreenActivity | null) => {
      card = next;
      for (const listener of cardListeners) listener();
    },
    setSettings: (next: { enabled: boolean; showTitles: boolean }) => {
      settings = {
        lockScreenActivityEnabled: next.enabled,
        lockScreenActivityShowTitles: next.showTitles,
      };
      for (const listener of settingsListeners) listener();
    },
  };
}

const NO_COUNTS = { attention: 0, working: 0, waiting: 0, done: 0 };

function card(
  status: "approval" | "done" | "working",
  asOf = 0,
  mode: LockScreenActivity["mode"] = "threads",
): LockScreenActivity {
  return {
    asOf,
    mode,
    counts: { ...NO_COUNTS, [status === "approval" ? "attention" : status]: 1 },
    hidden: {},
    projects:
      mode === "projects"
        ? [
            {
              name: null,
              noProject: true,
              projectIcon: null,
              attention: status === "approval" ? 1 : 0,
              attentionStatus: status === "approval" ? "approval" : null,
              working: status === "working" ? 1 : 0,
              done: status === "done" ? 1 : 0,
            },
          ]
        : [],
    rows:
      mode === "threads"
        ? [
            {
              status,
              provider: ProviderDriverKind.make("claudeAgent"),
              title: "Fix login",
              since: status === "working" ? 1_000 : null,
              projectIcon: ICON,
            },
          ]
        : [],
  };
}

const ICON = "data:image/png;base64,AAAA";

it("refreshes after a snooze expires before subscription unless the observer is removed", async () => {
  using _now = vi.spyOn(Date, "now").mockReturnValue(2_000);
  const onWake = vi.fn();
  const onRemovedWake = vi.fn();
  const stop = watchLockScreenSnooze(1_999, onWake);
  const remove = watchLockScreenSnooze(1_999, onRemovedWake);
  remove();
  try {
    expect(onWake).not.toHaveBeenCalled();
    await Promise.resolve();
    expect(onWake).toHaveBeenCalledTimes(1);
    expect(onRemovedWake).not.toHaveBeenCalled();
  } finally {
    stop();
  }
});

describe("createLockScreenPublisher", () => {
  it("sends a thread going from working to needing the user to clear, once per change", () => {
    const harness = setup({ enabled: true, showTitles: true });
    harness.setCard(card("working"));
    harness.setCard(card("working", 5));
    harness.setCard(card("approval"));
    harness.setCard(null);
    expect(harness.sent.map((sent) => sent && { ...sent, text: undefined })).toEqual([
      null,
      {
        asOf: 42,
        mode: "threads",
        counts: { ...NO_COUNTS, working: 1 },
        projects: [],
        hidden: {},
        text: undefined,
        rows: [
          {
            status: "working",
            provider: "claudeAgent",
            title: "Fix login",
            since: 1_000,
            projectIcon: ICON,
          },
        ],
      },
      {
        asOf: 42,
        mode: "threads",
        counts: { ...NO_COUNTS, attention: 1 },
        projects: [],
        hidden: {},
        text: undefined,
        rows: [
          {
            status: "approval",
            provider: "claudeAgent",
            title: "Fix login",
            since: null,
            projectIcon: ICON,
          },
        ],
      },
      null,
    ]);
  });

  it("builds the card only while locked, and keeps an unchanged card's time across unlocks", () => {
    const harness = setup({ enabled: true, showTitles: true, locked: false });
    harness.setCard(card("working"));
    expect(harness.reads()).toBe(0);
    expect(harness.cardListeners.size).toBe(0);
    expect(harness.sent).toEqual([]);

    harness.lock(true);
    expect(harness.reads()).toBe(1);
    expect(harness.sent.at(-1)).toMatchObject({ asOf: 42, rows: [{ status: "working" }] });

    harness.setNow(100);
    harness.lock(false);
    expect(harness.cardListeners.size).toBe(0);
    expect(harness.sent.at(-1)).toBeNull();
    harness.setCard(card("working", 5));
    expect(harness.reads()).toBe(1);

    harness.lock(true);
    expect(harness.sent.at(-1)).toMatchObject({ asOf: 42 });
  });

  it("watches and sends nothing while off, and clears and stops watching when turned off", () => {
    const harness = setup({ enabled: false, showTitles: true });
    harness.setCard(card("approval"));
    expect(harness.sent).toEqual([]);
    expect(harness.cardListeners.size).toBe(0);

    harness.setSettings({ enabled: true, showTitles: true });
    harness.setSettings({ enabled: false, showTitles: true });
    expect(harness.sent.at(-1)).toBeNull();
    expect(harness.cardListeners.size).toBe(0);

    harness.setSettings({ enabled: true, showTitles: true });
    harness.stop();
    expect(harness.sent.at(-1)).toBeNull();
    expect(harness.cardListeners.size).toBe(0);
  });

  it("sends no titles, start times or drivers without titles, nor a card built for the other mode", () => {
    const harness = setup({ enabled: true, showTitles: false });
    harness.setCard(card("working"));
    expect(harness.sent).toEqual([null]);
    harness.setCard(card("working", 0, "projects"));
    expect(harness.sent.at(-1)).toMatchObject({
      mode: "projects",
      rows: [],
      projects: [{ name: null, noProject: true, working: 1 }],
      text: { noProject: "No project" },
    });
    for (const leaked of ["Fix login", "claudeAgent", 'since":1']) {
      expect(JSON.stringify(harness.sent)).not.toContain(leaked);
    }

    harness.setSettings({ enabled: true, showTitles: true });
    expect(harness.sent.at(-1)?.mode).toBe("projects");
    harness.setCard(card("working"));
    expect(harness.sent.at(-1)).toMatchObject({
      mode: "threads",
      projects: [],
      rows: [{ title: "Fix login", provider: "claudeAgent", since: 1_000, projectIcon: ICON }],
    });
  });

  it("resends new copy on a language switch without moving asOf, and nothing when unchanged", () => {
    const harness = setup({ enabled: true, showTitles: false });
    harness.setCard(card("working", 0, "projects"));
    const count = harness.sent.length;
    harness.setNow(100);
    harness.setCard(card("working", 7, "projects"));
    harness.setLanguage("en");
    expect(harness.sent).toHaveLength(count);

    harness.setLanguage("de");
    expect(harness.sent).toHaveLength(count + 1);
    expect(harness.sent.at(-1)).toMatchObject({ asOf: 42, text: { showFewer: "Weniger" } });
  });

  it("sends the current card again when the host asks, but only while on", () => {
    const harness = setup({ enabled: true, showTitles: true });
    harness.setCard(card("working"));
    const count = harness.sent.length;
    harness.setNow(100);
    harness.republish();
    expect(harness.sent).toHaveLength(count + 1);
    expect(harness.sent.at(-1)).toMatchObject({ asOf: 42, rows: [{ status: "working" }] });

    harness.setCard(card("done"));
    expect(harness.sent.at(-1)?.asOf).toBe(100);

    harness.setSettings({ enabled: false, showTitles: true });
    harness.republish();
    expect(harness.sent.at(-1)).toBeNull();
  });
});

describe("lockScreenText", () => {
  it("writes every line of the card's copy, with one overflow label per hidden count", () => {
    const counts = { attention: 1, working: 3, waiting: 0, done: 10 };
    const threads = lockScreenText({ mode: "threads", counts, hidden: { "4": 9, "8": 1 } });
    expect(threads).toEqual({
      summary: ["1 needs you", "3 working", "10 done"],
      updated: "Updated {time}",
      more: { "9": "9 more threads", "1": "1 more thread" },
      showFewer: "Show fewer",
      expandLabel: "Show additional sessions",
      collapseLabel: "Hide additional sessions",
      statuses: {
        approval: "Approval",
        input: "Input",
        request: "Request",
        limited: "Limited",
        failed: "Failed",
        working: "Working",
        waiting: "Waiting",
        done: "Done",
      },
      duration: { seconds: "{count}s", minutes: "{count}m", hours: "{hours}h {minutes}m" },
      agent: "Agent",
      noProject: "No project",
      untitledProject: "Untitled project",
    });
    const projects = lockScreenText({
      mode: "projects",
      counts: { ...counts, attention: 2, waiting: 1 },
      hidden: { "4": 3, "5": 1 },
    });
    expect(projects.summary).toEqual(["2 need you", "3 working", "1 waiting", "10 done"]);
    expect(projects.more).toEqual({ "3": "3 more projects", "1": "1 more project" });
  });

  it("keeps the English template when a translation drops a placeholder, and clips long copy", () => {
    const broken = ((message: string, variables?: Record<string, unknown>) => {
      const english = m(message, variables);
      if (english.includes("{time}")) return "Aktualisiert";
      if (english === "{hours}h {minutes}m") return "{hours} Std.";
      if (english === "Show fewer") return "x".repeat(200);
      return english;
    }) as typeof m;
    const text = lockScreenText(
      { mode: "threads", counts: { attention: 0, working: 1, waiting: 0, done: 0 }, hidden: {} },
      broken,
    );
    expect(text.updated).toBe("Updated {time}");
    expect(text.duration.hours).toBe("{hours}h {minutes}m");
    expect(text.showFewer).toHaveLength(120);
    expect(text.showFewer.endsWith("…")).toBe(true);
  });

  it("uses each language's plural forms for the overflow row", () => {
    // The shipped Russian catalog, formatted by GT with Russian plural rules.
    const sourceKeys = new Map(Object.entries(en).map(([key, source]) => [source, key]));
    const russian = ((message: string, variables?: Record<string, unknown>) => {
      const source = decodeOptions(message)?.$_source ?? message;
      const target = (ru as Record<string, unknown>)[sourceKeys.get(source) ?? ""];
      return typeof target === "string"
        ? gtFallback(target, { ...decodeOptions(message), ...variables, $locale: "ru" })
        : m(message, variables);
    }) as typeof m;
    const text = lockScreenText(
      {
        mode: "threads",
        counts: { attention: 0, working: 13, waiting: 0, done: 0 },
        hidden: { "4": 5, "6": 2, "8": 1 },
      },
      russian,
    );
    expect(text.more).toEqual({ "1": "Ещё 1 тред", "2": "Ещё 2 треда", "5": "Ещё 5 тредов" });
    expect(text.updated).toBe("Обновлено в {time}");
  });
});

describe("createLockScreenIconCache", () => {
  it("draws each icon once, however often it is read, and tells listeners when one is ready", async () => {
    const drawn: string[] = [];
    let finish = (_icon: string | null) => {};
    const cache = createLockScreenIconCache((source: string) => {
      drawn.push(source);
      return new Promise<string | null>((resolve) => {
        finish = resolve;
      });
    });
    const ready = Promise.withResolvers<void>();
    const unsubscribe = cache.subscribe(ready.resolve);

    expect(cache.read("project-a", "a")).toBeNull();
    expect(cache.read("project-a", "a")).toBeNull();
    await Promise.resolve();
    expect(drawn).toEqual(["a"]);
    finish(ICON);
    await ready.promise;
    expect(cache.read("project-a", "a")).toBe(ICON);
    expect(cache.read("project-a", "a")).toBe(ICON);
    expect(drawn).toEqual(["a"]);

    expect(cache.read("project-b", "b")).toBeNull();
    await Promise.resolve();
    expect(drawn).toEqual(["a", "b"]);
    unsubscribe();
  });
});

describe("lock-screen status", () => {
  const visited = "2026-06-01T00:05:00.000Z";
  const run = (status: "completed" | "failed", completedAt: string) =>
    ({
      runId: RunId.make("run-1"),
      status,
      requestedAt: "2026-06-01T00:00:00.000Z",
      startedAt: "2026-06-01T00:00:00.000Z",
      completedAt,
      assistantMessageId: null,
    }) as LockScreenThreadInput["latestRun"];
  const runtime = (status: "running" | "idle" | "failed", lastErrorClass: string | null = null) =>
    ({
      status,
      activeRunId: null,
      providerInstanceId: ProviderInstanceId.make("codex"),
      providerName: null,
      lastError: null,
      lastErrorClass,
      activityStartedAt: status === "running" ? "2026-06-01T00:02:00.000Z" : undefined,
      updatedAt: "2026-06-01T00:00:00.000Z",
    }) as LockScreenThreadInput["runtime"];
  const base = {
    id: ThreadId.make("thread-1"),
    environmentId: EnvironmentId.make("environment-1"),
    projectId: ProjectId.make("project-1"),
    title: "Title",
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    unsettledAt: null,
    latestUserAuthoredMessageAt: null,
    latestUserMessageAt: null,
    archivedAt: null,
    deletedAt: null,
    lineage: {
      parentThreadId: null,
      relationshipToParent: null,
      rootThreadId: ThreadId.make("thread-1"),
    },
    interactionMode: "default",
    hasActionableProposedPlan: false,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    pendingSubagentRequest: null,
    pendingGuestMessageCount: 0,
    blockedOnThreadWait: false,
    settledOverride: null,
    snoozedAt: null,
    snoozedUntil: null,
    lastVisitedAt: "2026-06-01T00:00:30.000Z",
    source: { pendingBackgroundTasks: [], pendingRuntimeRequest: null },
    latestRun: null,
    runtime: null,
  } as unknown as LockScreenThreadInput;
  const cases: ReadonlyArray<[string, Partial<LockScreenThreadInput>]> = [
    [
      "approval over input",
      { hasPendingApprovals: true, hasPendingUserInput: true, runtime: runtime("running") },
    ],
    ["input", { hasPendingUserInput: true, runtime: runtime("running") }],
    ["subagent approval", { pendingSubagentRequest: "approval", hasPendingUserInput: true }],
    ["subagent input", { pendingSubagentRequest: "user_input" }],
    ["guest request", { pendingGuestMessageCount: 2, runtime: runtime("running") }],
    [
      "usage limit",
      { runtime: runtime("failed", "usage_limit"), latestRun: run("failed", visited) },
    ],
    [
      "unseen failure",
      { runtime: runtime("failed"), latestRun: run("failed", "2026-06-01T00:01:00.000Z") },
    ],
    [
      "seen failure",
      {
        runtime: runtime("failed"),
        latestRun: run("failed", "2026-06-01T00:01:00.000Z"),
        lastVisitedAt: visited,
      },
    ],
    ["waiting on a thread", { runtime: runtime("running"), blockedOnThreadWait: true }],
    ["idle while held open", { runtime: runtime("idle") }],
    ["working", { runtime: runtime("running") }],
    ["unread completion", { latestRun: run("completed", "2026-06-01T00:01:00.000Z") }],
    [
      "read completion",
      { latestRun: run("completed", "2026-06-01T00:01:00.000Z"), lastVisitedAt: visited },
    ],
  ];

  // What the sidebar row shows, in the card's vocabulary: Done is a ready row with an unread completion.
  function sidebarStatus(thread: typeof base) {
    const status = resolveSidebarRowStatus(thread as Parameters<typeof resolveSidebarRowStatus>[0]);
    if (status === "ready")
      return hasUnseenCompletion(thread as LockScreenThreadInput) ? "done" : null;
    return status === "preparing" ? "working" : status;
  }

  it.each(cases)("agrees with the sidebar row: %s", (_name, overrides) => {
    const thread: LockScreenThreadInput = { ...base, ...overrides };
    const card = buildLockScreenActivity({
      threads: [thread],
      mode: "threads",
      providerDriver: () => null,
      projectName: () => null,
      projectIcon: () => null,
      toLocalClock: (_environmentId, ms) => ms,
      asOf: Date.parse("2026-06-01T01:00:00.000Z"),
    });
    expect(card?.rows[0]?.status ?? null).toBe(sidebarStatus(thread));
  });

  it("shows a run that ends while locked even though the open window marked its thread visited", () => {
    const lockedAt = Date.parse("2026-06-01T00:00:45.000Z");
    const statusOf = (latestRun: LockScreenThreadInput["latestRun"], lastVisitedAt: string) =>
      buildLockScreenActivity({
        threads: [
          {
            ...base,
            latestRun,
            runtime: latestRun?.status === "failed" ? runtime("failed") : null,
            lastVisitedAt: lockScreenVisit(lastVisitedAt, lockedAt) ?? null,
          },
        ],
        mode: "threads",
        providerDriver: () => null,
        projectName: () => null,
        projectIcon: () => null,
        toLocalClock: (_environmentId, ms) => ms,
        asOf: Date.parse("2026-06-01T01:00:00.000Z"),
      })?.rows[0]?.status ?? null;
    // The window marks the thread visited as each run ends, after the lock.
    expect(statusOf(run("completed", "2026-06-01T00:01:00.000Z"), visited)).toBe("done");
    expect(statusOf(run("failed", "2026-06-01T00:01:00.000Z"), visited)).toBe("failed");
    // A visit before the lock still counts.
    expect(statusOf(run("completed", "2026-06-01T00:00:40.000Z"), "2026-06-01T00:00:42.000Z")).toBe(
      null,
    );
    expect(lockScreenVisit(visited, null)).toBe(visited);
    expect(lockScreenVisit(undefined, lockedAt)).toBe(undefined);
  });
});
