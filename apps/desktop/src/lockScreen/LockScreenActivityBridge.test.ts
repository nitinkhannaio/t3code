import { lockScreenStatusGroup, type DesktopLockScreenActivity } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  makeLockScreenActivityBridge,
  type LockScreenHelperEvents,
} from "./LockScreenActivityBridge.ts";

// Like the native helper, the fake refuses to start once the screen is already locked.
function setup(options: { maxLineBytes?: number } = {}) {
  const lines: string[] = [];
  const helpers: Array<{ ended: boolean; events: LockScreenHelperEvents }> = [];
  let full = false;
  let screenLocked = false;
  let refused = 0;
  const bridge = makeLockScreenActivityBridge((events) => {
    if (screenLocked) {
      refused++;
      return null;
    }
    const helper = { ended: false, events };
    helpers.push(helper);
    return {
      write: (line) => {
        if (helper.ended) throw new Error("wrote after EOF");
        lines.push(line.trimEnd());
        return !full;
      },
      end: () => {
        helper.ended = true;
      },
    };
  }, options);
  return {
    bridge,
    lines,
    helpers,
    refused: () => refused,
    parsed: () => lines.map((line) => JSON.parse(line)),
    lock: (next: boolean) => {
      screenLocked = next;
      bridge.setLocked(next);
    },
    setFull: (value: boolean) => {
      full = value;
    },
  };
}

const ON = { enabled: true, showTitles: true };
const ICON = "data:image/png;base64,iVBORw0KGgo=";
const OWNER = 7;

type Row = DesktopLockScreenActivity["rows"][number];

function countsOf(statuses: ReadonlyArray<Row["status"]>) {
  const counts = { ...EMPTY_COUNTS };
  for (const status of statuses) counts[lockScreenStatusGroup(status)]++;
  return counts;
}

const EMPTY_COUNTS = { attention: 0, working: 0, waiting: 0, done: 0 };

const TEXT: DesktopLockScreenActivity["text"] = {
  summary: ["1 working"],
  updated: "Updated {time}",
  more: { "1": "1 more thread", "2": "2 more threads" },
  showFewer: "Show fewer",
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
};
const { noProject: _noProject, untitledProject: _untitled, ...WIRE_TEXT } = TEXT;

function projectCard(
  overrides: Partial<DesktopLockScreenActivity> = {},
  asOf = Date.UTC(2026, 10, 21, 12, 0, 0, 250),
): DesktopLockScreenActivity {
  return {
    asOf,
    mode: "projects",
    counts: { ...EMPTY_COUNTS, attention: 1, working: 2 },
    rows: [],
    projects: [
      {
        name: "Web\napp",
        noProject: false,
        projectIcon: ICON,
        attention: 1,
        attentionStatus: "input",
        working: 2,
        done: 0,
      },
    ],
    hidden: {},
    text: TEXT,
    ...overrides,
  };
}

function card(
  status: Row["status"],
  overrides: Partial<Row> = {},
  asOf = Date.UTC(2026, 10, 21, 12, 0, 0, 250),
): DesktopLockScreenActivity {
  return {
    asOf,
    mode: "threads",
    counts: countsOf([status]),
    projects: [],
    hidden: {},
    text: TEXT,
    rows: [
      {
        status,
        provider: "codex",
        title: "Fix login",
        since: null,
        projectIcon: null,
        ...overrides,
      },
    ],
  };
}

describe("makeLockScreenActivityBridge", () => {
  it("starts the helper while unlocked with nothing to show, so the first locked update arrives", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    expect(harness.helpers).toHaveLength(1);
    expect(harness.lines).toEqual([]);

    harness.lock(true);
    harness.bridge.publish(OWNER, card("working"));
    harness.bridge.publish(OWNER, card("working", {}, Date.UTC(2026, 10, 21, 12, 5)));
    harness.bridge.publish(OWNER, card("approval"));
    harness.bridge.publish(OWNER, null);
    harness.lock(false);

    expect(harness.refused()).toBe(0);
    expect(harness.helpers).toHaveLength(1);
    expect(harness.parsed()).toEqual([
      {
        asOf: "2026-11-21T12:00:00Z",
        mode: "threads",
        counts: { ...EMPTY_COUNTS, working: 1 },
        projects: [],
        hidden: {},
        text: { ...WIRE_TEXT, more: {} },
        rows: [
          {
            status: "working",
            provider: "codex",
            title: "Fix login",
            since: null,
            projectIcon: null,
          },
        ],
      },
      {
        asOf: "2026-11-21T12:00:00Z",
        mode: "threads",
        counts: { ...EMPTY_COUNTS, attention: 1 },
        projects: [],
        hidden: {},
        text: { ...WIRE_TEXT, more: {} },
        rows: [
          {
            status: "approval",
            provider: "codex",
            title: "Fix login",
            since: null,
            projectIcon: null,
          },
        ],
      },
      null,
    ]);
  });

  it("holds the card until lock and clears it on unlock", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.bridge.publish(OWNER, card("input"));
    expect(harness.lines).toEqual([]);
    harness.lock(true);
    harness.lock(false);
    harness.lock(true);
    expect(harness.parsed().map((line) => line?.rows[0].status ?? null)).toEqual([
      "input",
      null,
      "input",
    ]);
  });

  it("requests the existing card after the host accepts an optimistic enable", () => {
    const harness = setup();
    const current = card("working");
    harness.bridge.publish(OWNER, current);
    harness.bridge.configure(ON, () => harness.bridge.publish(OWNER, current));
    expect(harness.lines).toEqual([]);

    harness.lock(true);
    expect(harness.parsed().map((line) => line?.rows[0].status)).toEqual(["working"]);
  });

  it("never starts a helper during a lock, and starts one again after unlock", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.lock(true);
    harness.helpers[0]!.events.onExit();
    harness.bridge.publish(OWNER, card("approval"));
    expect(harness.refused()).toBe(0);
    expect(harness.helpers).toHaveLength(1);

    harness.lock(false);
    expect(harness.helpers).toHaveLength(2);
    harness.lock(true);
    expect(harness.parsed().at(-1).rows[0].status).toBe("approval");
  });

  it("restarts once while unlocked, then waits for the next unlock", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.helpers[0]!.events.onExit();
    expect(harness.helpers).toHaveLength(2);
    harness.helpers[1]!.events.onExit();
    expect(harness.helpers).toHaveLength(2);
  });

  it("sends nothing while off, and turning it off clears, tears down, and forgets the card", () => {
    const harness = setup();
    harness.lock(true);
    harness.bridge.publish(OWNER, card("approval"));
    harness.lock(false);
    expect(harness.helpers).toHaveLength(0);

    harness.bridge.configure(ON);
    harness.lock(true);
    harness.bridge.publish(OWNER, card("approval"));
    harness.bridge.configure({ enabled: false, showTitles: true });
    expect(harness.lines.at(-1)).toBe("null");
    expect(harness.helpers[0]?.ended).toBe(true);

    // Turned straight back on: the stopped helper has not exited, so no second one starts yet.
    harness.lock(false);
    harness.bridge.configure(ON);
    expect(harness.helpers).toHaveLength(1);
    harness.helpers[0]!.events.onExit();
    expect(harness.helpers).toHaveLength(2);
    harness.lock(true);
    expect(harness.lines).toHaveLength(2);
  });

  it("shows only project rows without titles, dropping a thread card the renderer has not regrouped", () => {
    const harness = setup();
    harness.bridge.configure({ enabled: true, showTitles: false });
    harness.lock(true);
    harness.bridge.publish(OWNER, card("working", { since: 1_000, projectIcon: ICON }));
    expect(harness.lines).toEqual([]);

    harness.bridge.publish(
      OWNER,
      projectCard({
        // A renderer bug must not leak thread details into projects mode.
        rows: [card("working").rows[0]!],
      }),
    );
    expect(harness.lines).toHaveLength(1);
    expect(harness.lines[0]).not.toContain("Fix login");
    expect(harness.lines[0]).not.toContain("codex");
    expect(harness.parsed()[0]).toMatchObject({
      mode: "projects",
      rows: [],
      projects: [
        {
          name: "Web app",
          projectIcon: ICON,
          attention: 1,
          attentionStatus: "input",
          working: 2,
          done: 0,
        },
      ],
    });

    harness.bridge.configure(ON);
    expect(harness.lines.at(-1)).toBe("null");
    harness.bridge.publish(OWNER, card("working", { provider: "/Users/me/secret-agent" }));
    expect(harness.parsed().at(-1)).toMatchObject({
      mode: "threads",
      projects: [],
      rows: [{ title: "Fix login", provider: null }],
    });
  });

  it("sends overflow only for item counts it has copy for, and drops zero counts", () => {
    const harness = setup();
    harness.bridge.configure({ enabled: true, showTitles: false });
    harness.lock(true);
    harness.bridge.publish(
      OWNER,
      projectCard({
        hidden: { "4": 3, "5": 2, "6": 1, "7": 0 },
        text: { ...TEXT, more: { "1": "1 more project", "2": "2 more projects", "40": "x" } },
      }),
    );
    expect(harness.parsed()[0]).toMatchObject({
      hidden: { "5": 2, "6": 1 },
      text: { more: { "1": "1 more project", "2": "2 more projects" } },
    });
  });

  it("keeps an unchanged card's time across unlocks, renderer reloads and flickers", () => {
    const harness = setup();
    harness.bridge.configure({ enabled: true, showTitles: false });
    const first = Date.UTC(2026, 10, 21, 4, 13, 4);
    harness.bridge.publish(OWNER, projectCard({}, first));
    harness.lock(true);
    harness.lock(false);
    // While unlocked the renderer reloads, or the card flickers and comes back, with a new time.
    harness.bridge.invalidate(OWNER);
    harness.bridge.publish(OWNER, projectCard({}, first + 21_000));
    harness.lock(true);
    // A language switch resends the copy, still with the same time.
    harness.bridge.publish(
      OWNER,
      projectCard({ text: { ...TEXT, showFewer: "Weniger" } }, first + 40_000),
    );
    harness.bridge.publish(
      OWNER,
      projectCard({ counts: { ...EMPTY_COUNTS, working: 3 } }, first + 50_000),
    );
    expect(harness.parsed().map((line) => line?.asOf ?? null)).toEqual([
      "2026-11-21T04:13:04Z",
      null,
      "2026-11-21T04:13:04Z",
      "2026-11-21T04:13:04Z",
      "2026-11-21T04:13:54Z",
    ]);
  });

  it("dates a card shown again after the renderer emptied it while locked by its new time", () => {
    const harness = setup();
    harness.bridge.configure({ enabled: true, showTitles: false });
    harness.lock(true);
    harness.bridge.publish(OWNER, projectCard({}, Date.UTC(2026, 10, 21, 9)));
    harness.bridge.publish(OWNER, null);
    harness.bridge.publish(OWNER, projectCard({}, Date.UTC(2026, 10, 21, 11)));
    expect(harness.parsed().map((line) => line?.asOf ?? null)).toEqual([
      "2026-11-21T09:00:00Z",
      null,
      "2026-11-21T11:00:00Z",
    ]);
  });

  it("sends only small inline PNG icons, and a start time only for working and waiting rows", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.lock(true);
    const since = Date.UTC(2026, 10, 21, 11, 58, 30, 750);
    harness.bridge.publish(OWNER, {
      ...card("working"),
      counts: { ...EMPTY_COUNTS, attention: 3, working: 1, waiting: 1, done: 1 },
      rows: [
        { status: "approval", provider: "codex", title: null, since, projectIcon: ICON },
        {
          status: "input",
          provider: "codex",
          title: null,
          since: null,
          projectIcon: "https://x/a.png",
        },
        {
          status: "failed",
          provider: "codex",
          title: null,
          since: null,
          projectIcon: `data:image/png;base64,${"A".repeat(6144)}`,
        },
        { status: "working", provider: "codex", title: null, since, projectIcon: null },
        { status: "waiting", provider: "codex", title: null, since, projectIcon: null },
        { status: "done", provider: "codex", title: null, since, projectIcon: null },
      ],
    });
    expect(
      harness.parsed()[0].rows.map((row: Row) => [row.status, row.since, row.projectIcon]),
    ).toEqual([
      ["approval", null, ICON],
      ["input", null, null],
      ["failed", null, null],
      ["working", "2026-11-21T11:58:30Z", null],
      ["waiting", "2026-11-21T11:58:30Z", null],
      ["done", null, null],
    ]);
  });

  it("caps every count, overflow included, and judges freshness on the capped values", () => {
    const harness = setup();
    harness.bridge.configure({ enabled: true, showTitles: false });
    harness.lock(true);
    const huge = (asOf: number, extra: number) =>
      projectCard(
        {
          counts: { attention: 50_000 + extra, working: 3, waiting: 0, done: 20_000 },
          hidden: { "4": 50_000 + extra, "8": 9_998 },
          text: { ...TEXT, more: { "9999": "9999 more projects", "9998": "9998 more projects" } },
          projects: [
            {
              name: "Big",
              noProject: false,
              projectIcon: null,
              attention: 50_000,
              attentionStatus: "approval",
              working: 3,
              done: 20_000,
            },
            // A needs-you count without its status is not shown as one.
            {
              name: "Odd",
              noProject: false,
              projectIcon: null,
              attention: 2,
              attentionStatus: null,
              working: 1,
              done: 0,
            },
          ],
        },
        asOf,
      );
    harness.bridge.publish(OWNER, huge(0, 0));
    harness.bridge.publish(OWNER, huge(5_000, 1));
    expect(harness.lines).toHaveLength(1);
    const sent = harness.parsed()[0];
    expect(sent.counts).toEqual({ attention: 9999, working: 3, waiting: 0, done: 9999 });
    expect(sent.hidden).toEqual({ "4": 9999, "8": 9998 });
    expect(sent.text.more).toEqual({ "9999": "9999 more projects", "9998": "9998 more projects" });
    expect(sent.projects).toEqual([
      {
        name: "Big",
        projectIcon: null,
        attention: 9999,
        attentionStatus: "approval",
        working: 3,
        done: 9999,
      },
      {
        name: "Odd",
        projectIcon: null,
        attention: 0,
        attentionStatus: null,
        working: 1,
        done: 0,
      },
    ]);
  });

  it("names project rows from copy by identity, so a new translation keeps the card's time", () => {
    const harness = setup();
    harness.bridge.configure({ enabled: true, showTitles: false });
    harness.lock(true);
    const named = (text: DesktopLockScreenActivity["text"], asOf: number) =>
      projectCard(
        {
          projects: [
            { ...projectCard().projects[0]!, name: null, noProject: true, projectIcon: ICON },
            { ...projectCard().projects[0]!, name: "\u200b\u2060" },
          ],
          text,
        },
        asOf,
      );
    harness.bridge.publish(OWNER, named(TEXT, Date.UTC(2026, 10, 21, 12)));
    harness.bridge.publish(
      OWNER,
      named({ ...TEXT, noProject: "Kein Projekt" }, Date.UTC(2026, 10, 21, 13)),
    );
    expect(harness.parsed().map((line) => line.asOf)).toEqual([
      "2026-11-21T12:00:00Z",
      "2026-11-21T12:00:00Z",
    ]);
    expect(
      harness.parsed().map((line) => line.projects.map((p: { name: string }) => p.name)),
    ).toEqual([
      ["No project", "Untitled project"],
      ["Kein Projekt", "Untitled project"],
    ]);
    // An icon would tell which project a bucket is; threads without one have none.
    expect(harness.parsed()[0].projects[0].projectIcon).toBe(ICON);
    expect(harness.lines[0]).not.toContain("noProject");
    expect(harness.lines[0]).not.toContain("untitledProject");
  });

  it("clips copy to what the card accepts and keeps every time a four-digit-year ISO string", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.lock(true);
    harness.bridge.publish(OWNER, {
      ...card("working", { since: -1e14 }, 1e15),
      text: { ...TEXT, agent: "👍".repeat(130) },
    });
    const sent = harness.parsed()[0];
    expect(sent.asOf).toBe("9999-12-31T23:59:59Z");
    expect(sent.rows[0].since).toBe("2000-01-01T00:00:00Z");
    expect(sent.text.agent.length).toBeLessThanOrEqual(120);
    expect(sent.text.agent.endsWith("👍…")).toBe(true);
  });

  it("drops the largest icons until the line fits, and clears rather than sending an oversized line", () => {
    const big = `data:image/png;base64,${"A".repeat(6000)}`;
    const small = `data:image/png;base64,${"A".repeat(1000)}`;
    const many = {
      ...card("working"),
      counts: { ...EMPTY_COUNTS, working: 3 },
      rows: [big, small, null].map((projectIcon) => ({ ...card("working").rows[0]!, projectIcon })),
    };
    const fits = setup({ maxLineBytes: 4000 });
    fits.bridge.configure(ON);
    fits.lock(true);
    fits.bridge.publish(OWNER, many);
    expect(new TextEncoder().encode(fits.lines[0]!).length).toBeLessThan(4000);
    expect(fits.parsed()[0].rows.map((row: Row) => row.projectIcon)).toEqual([null, small, null]);

    const tiny = setup({ maxLineBytes: 200 });
    tiny.bridge.configure(ON);
    tiny.lock(true);
    tiny.bridge.publish(OWNER, many);
    expect(tiny.lines).toEqual(["null"]);
  });

  it("passes Request, Limited, Failed, Waiting and Done rows through without a start time", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.lock(true);
    for (const status of ["request", "limited", "failed", "waiting", "done"] as const) {
      harness.bridge.publish(OWNER, card(status));
      expect(harness.parsed().at(-1).rows).toEqual([
        { status, provider: "codex", title: "Fix login", since: null, projectIcon: null },
      ]);
    }
  });

  it("clears when the owning renderer goes away, ignoring other renderers", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.lock(true);
    harness.bridge.publish(OWNER, card("working"));
    harness.bridge.invalidate(OWNER + 1);
    expect(harness.lines).toHaveLength(1);
    harness.bridge.invalidate(OWNER);
    expect(harness.lines.at(-1)).toBe("null");

    harness.bridge.publish(OWNER, card("input"));
    harness.bridge.dispose();
    expect(harness.lines.at(-1)).toBe("null");
    expect(harness.helpers[0]?.ended).toBe(true);
  });

  it("keeps only the newest line while the pipe is full", () => {
    const harness = setup();
    harness.bridge.configure(ON);
    harness.lock(true);
    harness.setFull(true);
    harness.bridge.publish(OWNER, card("working"));
    harness.bridge.publish(OWNER, card("input"));
    harness.bridge.publish(OWNER, card("approval"));
    expect(harness.lines).toHaveLength(1);
    harness.setFull(false);
    harness.helpers[0]!.events.onDrain();
    expect(harness.lines).toHaveLength(2);
    expect(harness.parsed().at(-1).rows[0].status).toBe("approval");
  });
});
