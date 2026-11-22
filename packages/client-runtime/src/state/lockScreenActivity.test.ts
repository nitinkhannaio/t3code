import {
  EnvironmentId,
  ProjectId,
  ProviderDriverKind,
  ProviderInstanceId,
  RunId,
  ThreadId,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import { buildLockScreenActivity, type LockScreenThreadInput } from "./lockScreenActivity.ts";
import { presentThreadShell } from "./models.ts";
import { v2Now, v2ThreadShell } from "./orchestrationV2TestFixtures.ts";

const live = EnvironmentId.make("environment-live");
const ahead = EnvironmentId.make("environment-ahead");

type Status =
  | "approval"
  | "input"
  | "subagent-approval"
  | "request"
  | "limited"
  | "working"
  | "preparing"
  | "waiting"
  | "background"
  | "never-run"
  | "done"
  | "settled-done"
  | "failed";

function thread(
  id: string,
  status: Status,
  overrides: Partial<LockScreenThreadInput> = {},
): LockScreenThreadInput {
  const active =
    status === "working" ||
    status === "waiting" ||
    status.endsWith("approval") ||
    status === "input" ||
    status === "request";
  const ran =
    status === "done" || status === "settled-done" || status === "failed" || status === "limited";
  return {
    id: ThreadId.make(`thread-${id}`),
    environmentId: live,
    projectId: ProjectId.make("project-1"),
    title: `Title ${id}`,
    createdAt: `2026-06-01T00:00:${id.padStart(2, "0")}.000Z`,
    unsettledAt: null,
    latestUserAuthoredMessageAt: null,
    archivedAt: null,
    deletedAt: null,
    lineage: {
      parentThreadId: null,
      relationshipToParent: null,
      rootThreadId: ThreadId.make(`thread-${id}`),
    },
    interactionMode: "default",
    hasActionableProposedPlan: false,
    hasPendingApprovals: status === "approval",
    hasPendingUserInput: status === "input",
    pendingSubagentRequest: status === "subagent-approval" ? "approval" : null,
    pendingGuestMessageCount: status === "request" ? 1 : 0,
    blockedOnThreadWait: status === "waiting",
    settledOverride: status === "settled-done" ? "settled" : null,
    snoozedAt: null,
    snoozedUntil: null,
    lastVisitedAt: "2026-06-01T00:00:30.000Z",
    source: { pendingBackgroundTasks: [], pendingRuntimeRequest: null },
    latestRun: ran
      ? {
          runId: RunId.make(`run-${id}`),
          status: status === "done" || status === "settled-done" ? "completed" : "failed",
          requestedAt: "2026-06-01T00:00:00.000Z",
          startedAt: "2026-06-01T00:00:00.000Z",
          completedAt: `2026-06-01T00:01:${id.padStart(2, "0")}.000Z`,
          assistantMessageId: null,
        }
      : null,
    runtime:
      status === "done" || status === "settled-done" || status === "never-run"
        ? null
        : {
            status: active
              ? "running"
              : status === "preparing"
                ? "preparing"
                : status === "failed" || status === "limited"
                  ? "failed"
                  : "idle",
            activeRunId: null,
            providerInstanceId: ProviderInstanceId.make("my-secret-instance"),
            providerName: null,
            lastError: ran ? "token sk-live-123 at /Users/me/repo" : null,
            lastErrorClass: status === "limited" ? "usage_limit" : null,
            activityStartedAt: status === "working" ? "2026-06-01T00:02:00.500Z" : undefined,
            updatedAt: "2026-06-01T00:00:00.000Z",
          },
    ...overrides,
  } as LockScreenThreadInput;
}

const codex = ProviderDriverKind.make("codex");

function build(
  threads: ReadonlyArray<LockScreenThreadInput>,
  mode: "threads" | "projects" = "threads",
  projectIcon: (projectId: ProjectId) => string | null = () => "data:image/png;base64,AAAA",
  asOf = DateTime.toEpochMillis(v2Now),
  projectName: (projectId: ProjectId) => string | null = (projectId) =>
    projectId === NO_PROJECT ? null : `Name ${projectId}`,
) {
  return buildLockScreenActivity({
    threads,
    providerDriver: () => codex,
    projectName: (input) => projectName(input.projectId),
    projectIcon: (input) => projectIcon(input.projectId),
    mode,
    toLocalClock: (environmentId, serverMs) =>
      serverMs - (environmentId === ahead ? 3_600_000 : SERVER_CLOCK_AHEAD_MS),
    asOf,
  });
}

const SERVER_CLOCK_AHEAD_MS = 60_000;
const NO_PROJECT = ProjectId.make("project-none");
const inProject = (project: string) => ({ projectId: ProjectId.make(project) });

describe("buildLockScreenActivity", () => {
  it("shows nothing when no session has a status worth showing", () => {
    expect(build([thread("1", "never-run"), thread("2", "settled-done")])).toBeNull();
  });

  it("orders every status by precedence, approval first, and keeps strictly the top rows", () => {
    const activity = build([
      thread("1", "done"),
      thread("2", "working"),
      thread("3", "approval"),
      thread("4", "waiting"),
      thread("5", "failed"),
      thread("6", "input"),
      thread("7", "limited"),
      thread("8", "request"),
      thread("9", "preparing"),
      thread("10", "background"),
      thread("11", "subagent-approval"),
      thread("12", "done"),
      thread("13", "never-run"),
      thread("14", "settled-done"),
      thread("15", "approval", { hasPendingUserInput: true }),
    ]);
    expect(activity?.rows.map((row) => row.status)).toEqual([
      "approval",
      "approval",
      "approval",
      "input",
      "request",
      "limited",
      "failed",
      "working",
    ]);
    expect(activity?.counts).toEqual({ attention: 7, working: 2, waiting: 2, done: 2 });
    expect(activity?.hidden).toEqual({ "4": 9, "5": 8, "6": 7, "7": 6, "8": 5 });
  });

  it("gives every row to attention when it fills the card, with nothing reserved for work", () => {
    const activity = build([
      ...["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((id) => thread(id, "input")),
      thread("10", "working"),
      thread("11", "done"),
    ]);
    expect(activity?.rows).toHaveLength(8);
    expect(new Set(activity?.rows.map((row) => row.status))).toEqual(new Set(["input"]));
    expect(activity?.counts).toEqual({ attention: 9, working: 1, waiting: 0, done: 1 });
  });

  it("fills spare rows with working sessions newest send first, then done newest completion first", () => {
    const activity = build([
      thread("1", "working"),
      thread("2", "approval"),
      thread("3", "done"),
      thread("4", "working", { latestUserAuthoredMessageAt: "2026-06-02T00:00:00.000Z" }),
      thread("5", "done"),
    ]);
    expect(activity?.rows.map((row) => [row.status, row.title])).toEqual([
      ["approval", "Title 2"],
      ["working", "Title 4"],
      ["working", "Title 1"],
      ["done", "Title 5"],
      ["done", "Title 3"],
    ]);
  });

  it("shows Done only for a successful latest run that nothing still holds or shelves", () => {
    const completed = thread("1", "done").latestRun;
    const monitor = {
      taskId: "monitor-1",
      kind: "monitor",
    } as NonNullable<LockScreenThreadInput["source"]["pendingBackgroundTasks"]>[number];
    const activity = build([
      thread("1", "done"),
      thread("3", "settled-done"),
      thread("4", "background", { latestRun: completed }),
      thread("5", "done", { latestRun: { ...completed!, status: "interrupted" } }),
      thread("6", "done", {
        source: {
          latestRunStopRequested: true,
          pendingBackgroundTasks: [],
          pendingRuntimeRequest: null,
        },
      }),
      thread("7", "done", {
        source: {
          latestRunBackgroundWake: true,
          pendingBackgroundTasks: [monitor],
          pendingRuntimeRequest: null,
        },
      }),
      thread("8", "never-run"),
    ]);
    expect(activity?.rows.map((row) => row.status)).toEqual(["waiting", "waiting", "done"]);
    expect(activity?.counts).toMatchObject({ done: 1, waiting: 2 });
    expect(
      build([
        thread("7", "done", {
          source: {
            latestRunBackgroundWake: true,
            pendingBackgroundTasks: [],
            pendingRuntimeRequest: null,
          },
        }),
      ])?.rows.map((row) => row.status),
    ).toEqual(["done"]);
  });

  it("hides a snoozed completion until it wakes, but lets an approval through", () => {
    const wakesAt = DateTime.toEpochMillis(v2Now) + 60_000;
    const completed = presentThreadShell(
      live,
      {
        ...v2ThreadShell,
        latestRunId: RunId.make("completed-run"),
        status: "completed",
        latestRunCompletedAt: v2Now,
        lastVisitedAt: DateTime.makeUnsafe(DateTime.toEpochMillis(v2Now) - 60_000),
        snoozedAt: v2Now,
        snoozedUntil: DateTime.makeUnsafe(wakesAt),
      },
      null,
    );
    const approval = thread("2", "approval", {
      snoozedUntil: DateTime.formatIso(DateTime.makeUnsafe(wakesAt)),
    });
    expect(build([completed, approval])?.rows.map((row) => row.status)).toEqual(["approval"]);
    expect(
      build([completed, approval], undefined, undefined, wakesAt)?.rows.map((row) => row.status),
    ).toEqual(["approval", "done"]);
  });

  it("ranks an approval, its own or a subagent's, above any input, like the sidebar", () => {
    const activity = build([
      thread("1", "input"),
      thread("2", "input", { pendingSubagentRequest: "approval" }),
      thread("3", "never-run", { pendingSubagentRequest: "user_input" }),
      thread("4", "approval"),
    ]);
    expect(activity?.rows.map((row) => [row.status, row.title])).toEqual([
      ["approval", "Title 4"],
      ["approval", "Title 2"],
      ["input", "Title 3"],
      ["input", "Title 1"],
    ]);
  });

  it("shows Done only while the completion is unread, and a failed run only until it is seen", () => {
    const statuses = (threads: ReadonlyArray<LockScreenThreadInput>) =>
      build(threads)?.rows.map((row) => [row.status, row.title]) ?? [];
    const opened = { lastVisitedAt: "2026-06-01T00:05:00.000Z" };
    expect(
      statuses([
        thread("1", "done"),
        thread("2", "done", opened),
        thread("3", "done", { lastVisitedAt: null }),
        thread("4", "failed"),
        thread("5", "failed", opened),
        thread("6", "failed", { ...opened, latestRun: null }),
        thread("7", "limited", opened),
      ]),
    ).toEqual([
      ["limited", "Title 7"],
      ["failed", "Title 4"],
      ["failed", "Title 6"],
      ["done", "Title 1"],
    ]);
  });

  it("dates working and waiting rows on this machine's clock, and no other row", () => {
    const completed = thread("1", "done").latestRun!;
    const activity = build([
      thread("1", "working"),
      thread("2", "background", { latestRun: completed }),
      thread("3", "waiting"),
      thread("4", "approval"),
      thread("5", "done"),
      thread("6", "failed"),
    ]);
    expect(activity?.rows.map((row) => [row.status, row.since])).toEqual([
      ["approval", null],
      ["failed", null],
      ["working", Date.parse("2026-06-01T00:01:00.000Z")],
      ["waiting", null],
      ["waiting", Date.parse("2026-06-01T00:00:01.000Z")],
      ["done", null],
    ]);
  });

  it("shelves a settled failure, but never a usage limit", () => {
    const activity = build([
      thread("1", "failed", { settledOverride: "settled" }),
      thread("2", "limited", { settledOverride: "settled" }),
    ]);
    expect(activity?.rows.map((row) => row.status)).toEqual(["limited"]);
  });

  it("leaves out archived, deleted and delegated sessions", () => {
    const activity = build([
      thread("2", "working", { archivedAt: "2026-06-01T00:00:00.000Z" }),
      thread("3", "working", { deletedAt: "2026-06-01T00:00:00.000Z" }),
      thread("4", "waiting"),
      thread("5", "working", {
        lineage: {
          parentThreadId: ThreadId.make("thread-6"),
          relationshipToParent: "subagent",
          rootThreadId: ThreadId.make("thread-6"),
        },
      }),
      thread("6", "working"),
    ]);
    expect(activity?.rows.map((row) => row.status)).toEqual(["working", "waiting"]);
  });

  it("builds only the rows of its mode, so projects mode never reads a title or driver", () => {
    const threads = [thread("1", "approval"), thread("2", "working")];
    const projects = build(threads, "projects");
    expect(projects?.rows).toEqual([]);
    expect(JSON.stringify(projects)).not.toContain("Title");
    expect(build(threads)?.projects).toEqual([]);
  });

  it("sends only a small inline PNG as a project icon", () => {
    for (const icon of [
      "https://example.com/favicon.ico",
      "data:image/svg+xml;base64,AAAA",
      `data:image/png;base64,${"A".repeat(6144)}`,
    ]) {
      expect(
        build([thread("1", "approval")], "threads", () => icon)?.rows[0]?.projectIcon,
      ).toBeNull();
      expect(
        build([thread("1", "approval")], "projects", () => icon)?.projects[0]?.projectIcon,
      ).toBeNull();
    }
  });

  it("flattens a revealed title to one bounded line", () => {
    const activity = build([
      thread("1", "working", { title: `  Fix\nlogin\u0007  ${"x".repeat(200)}` }),
    ]);
    const title = activity?.rows[0]?.title ?? "";
    expect(title.startsWith("Fix login x")).toBe(true);
    expect(title.length).toBeLessThanOrEqual(80);
    expect(title).not.toMatch(/[\u0000-\u001f]/);

    const prefix = "x".repeat(78);
    for (const invisible of ["\u200b", " \u2060\u200d ", "\u0007\ufeff"]) {
      expect(build([thread("1", "working", { title: invisible })])?.rows[0]?.title).toBeNull();
    }
    expect(build([thread("1", "working", { title: "a\u200bb\u2028c" })])?.rows[0]?.title).toBe(
      "ab c",
    );

    const emojiAtBoundary = build([thread("1", "working", { title: `${prefix}😀z` })]);
    expect(build([thread("1", "working", { title: `${prefix}e\u0301z` })])?.rows[0]?.title).toBe(
      `${prefix}…`,
    );
    expect(emojiAtBoundary?.rows[0]?.title).toBe(`${prefix}…`);
  });

  it("carries only allowlisted fields, without ids, errors or instance names", () => {
    const activity = build([
      thread("1", "approval"),
      thread("2", "request"),
      thread("3", "failed"),
      thread("4", "done"),
    ]);
    expect(activity?.rows).toHaveLength(4);
    for (const row of activity?.rows ?? []) expect(row.provider).toBe("codex");
    const serialized = JSON.stringify(activity);
    for (const leaked of [
      "thread-",
      "environment-live",
      '"project-1',
      "my-secret-instance",
      "sk-live",
      "/Users/",
    ]) {
      expect(serialized).not.toContain(leaked);
    }
  });

  it("groups by project, needs-you first, then most working, then latest activity", () => {
    const activity = build(
      [
        thread("1", "done", inProject("project-quiet")),
        thread("2", "working", inProject("project-busy")),
        thread("3", "waiting", inProject("project-busy")),
        thread("4", "working", inProject("project-one")),
        thread("5", "input", inProject("project-needy")),
        thread("6", "failed", inProject("project-needy")),
        thread("7", "approval", inProject("project-needy")),
        thread("8", "done", inProject("project-needy")),
        thread("9", "done", {
          ...inProject("project-needy"),
          lastVisitedAt: "2026-06-01T00:05:00.000Z",
        }),
        thread("10", "done", inProject("project-later")),
        thread("11", "working", { projectId: NO_PROJECT }),
        thread("12", "done", { projectId: NO_PROJECT }),
      ],
      "projects",
    );
    expect(activity?.projects).toEqual([
      {
        noProject: false,
        name: "Name project-needy",
        projectIcon: "data:image/png;base64,AAAA",
        attention: 3,
        attentionStatus: "approval",
        working: 0,
        done: 1,
      },
      {
        noProject: false,
        name: "Name project-busy",
        projectIcon: "data:image/png;base64,AAAA",
        attention: 0,
        attentionStatus: null,
        working: 2,
        done: 0,
      },
      {
        name: null,
        noProject: true,
        projectIcon: null,
        attention: 0,
        attentionStatus: null,
        working: 1,
        done: 1,
      },
      {
        noProject: false,
        name: "Name project-one",
        projectIcon: "data:image/png;base64,AAAA",
        attention: 0,
        attentionStatus: null,
        working: 1,
        done: 0,
      },
      {
        noProject: false,
        name: "Name project-later",
        projectIcon: "data:image/png;base64,AAAA",
        attention: 0,
        attentionStatus: null,
        working: 0,
        done: 1,
      },
      {
        noProject: false,
        name: "Name project-quiet",
        projectIcon: "data:image/png;base64,AAAA",
        attention: 0,
        attentionStatus: null,
        working: 0,
        done: 1,
      },
    ]);
    expect(activity?.counts).toEqual({ attention: 3, working: 3, waiting: 1, done: 4 });
    expect(activity?.hidden).toEqual({ "4": 2, "5": 1 });
  });

  it("names a project's needs-you count by its most urgent status", () => {
    const urgent = (statuses: ReadonlyArray<Status>) =>
      build(
        statuses.map((status, index) => thread(String(index + 1), status)),
        "projects",
      )?.projects[0]?.attentionStatus;
    expect(urgent(["failed", "limited", "request"])).toBe("request");
    expect(urgent(["failed", "input"])).toBe("input");
    expect(urgent(["failed", "limited"])).toBe("limited");
    expect(urgent(["failed", "working"])).toBe("failed");
  });

  it("sends at most eight projects, and counts the rest as hidden at every card height", () => {
    const threads = Array.from({ length: 11 }, (_, index) =>
      thread(String(index + 1), "working", inProject(`project-${index}`)),
    );
    const activity = build(threads, "projects");
    expect(activity?.projects).toHaveLength(8);
    expect(activity?.hidden).toEqual({ "4": 7, "5": 6, "6": 5, "7": 4, "8": 3 });
    expect(build(threads)?.hidden).toEqual({ "4": 7, "5": 6, "6": 5, "7": 4, "8": 3 });
    expect(build(threads.slice(0, 4), "projects")?.hidden).toEqual({});
    expect(build(threads.slice(0, 4))?.hidden).toEqual({});
  });

  it("breaks a tie between projects by the latest activity, a just-started automated run included", () => {
    const at = (time: string) => `2026-06-01T00:${time}.000Z`;
    const activity = build(
      [
        thread("1", "working", {
          ...inProject("project-typed"),
          latestUserMessageAt: at("10:00"),
          updatedAt: at("10:00"),
        }),
        thread("2", "working", {
          ...inProject("project-automated"),
          latestUserMessageAt: at("05:00"),
          updatedAt: at("05:00"),
          latestRun: {
            runId: RunId.make("run-automated"),
            status: "running",
            requestedAt: at("20:00"),
            startedAt: at("20:01"),
            completedAt: null,
            assistantMessageId: null,
          },
        }),
      ],
      "projects",
    );
    expect(activity?.projects.map((project) => project.name)).toEqual([
      "Name project-automated",
      "Name project-typed",
    ]);
  });

  it("names a project that has no visible name as untitled, apart from threads without one", () => {
    const activity = build(
      [
        thread("1", "working", inProject("project-blank")),
        thread("2", "working", { projectId: NO_PROJECT }),
      ],
      "projects",
      undefined,
      undefined,
      (projectId) => (projectId === NO_PROJECT ? null : "\u200b \u2060"),
    );
    expect(activity?.projects.map(({ name, noProject }) => ({ name, noProject }))).toEqual([
      { name: null, noProject: true },
      { name: null, noProject: false },
    ]);
  });

  it("clamps counts before deriving overflow from them", () => {
    const threads = Array.from({ length: 10_010 }, (_, index) =>
      thread(
        String(index + 1),
        "working",
        inProject(index < 10_005 ? "project-big" : `p-${index}`),
      ),
    );
    const activity = build(threads);
    expect(activity?.counts.working).toBe(9999);
    expect(activity?.hidden).toEqual({ "4": 9999, "5": 9999, "6": 9999, "7": 9999, "8": 9999 });
    expect(build(threads, "projects")?.projects[0]).toMatchObject({ working: 9999 });
  });

  it("compares project recency on this machine's clock, not each environment's", () => {
    const at = (time: string) => `2026-06-01T00:${time}.000Z`;
    const activity = build(
      [
        // Raw times sort this one first, but its environment runs an hour ahead.
        thread("1", "working", {
          ...inProject("project-ahead"),
          environmentId: ahead,
          latestUserMessageAt: at("30:00"),
        }),
        thread("2", "working", { ...inProject("project-here"), latestUserMessageAt: at("10:00") }),
      ],
      "projects",
    );
    expect(activity?.projects.map((project) => project.name)).toEqual([
      "Name project-here",
      "Name project-ahead",
    ]);
  });
});
