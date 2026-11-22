// @effect-diagnostics nodeBuiltinImport:off globalTimers:off -- The helper keeps one stdin pipe open for as long as the feature is on, and a stopped one gets a grace timer before it is killed.
import * as NodeChildProcess from "node:child_process";

import type {
  ClientSettings,
  DesktopLockScreenActivity as LockScreenCard,
} from "@t3tools/contracts";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Scope from "effect/Scope";
import * as Electron from "electron";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import * as ElectronPowerMonitor from "../electron/ElectronPowerMonitor.ts";
import {
  LOCK_SCREEN_ACTIVITY_LOCKED_CHANNEL,
  LOCK_SCREEN_ACTIVITY_REPUBLISH_CHANNEL,
} from "../ipc/channels.ts";
import * as DesktopClientSettings from "../settings/DesktopClientSettings.ts";
import {
  makeLockScreenActivityBridge,
  type LockScreenHelperEvents,
} from "./LockScreenActivityBridge.ts";

const HELPER_ENV = "T3CODE_DEV_LOCK_SCREEN_HELPER";
const HELPER_ARGS = ["live-lock", "--private-skylight", "--expand-on-click"];

export class DesktopLockScreenActivity extends Context.Service<
  DesktopLockScreenActivity,
  {
    readonly available: boolean;
    /** Listens for lock and unlock; PowerMonitor only works once Electron is ready. */
    readonly start: Effect.Effect<void, never, Scope.Scope>;
    readonly configure: (settings: ClientSettings, sender?: number) => Effect.Effect<void>;
    readonly publish: (sender: number, activity: LockScreenCard | null) => Effect.Effect<void>;
    /** Sends this renderer the lock state on every change, and returns the current one. */
    readonly watchLocked: (sender: number) => Effect.Effect<boolean>;
  }
>()("@t3tools/desktop/lockScreen/DesktopLockScreenActivity") {}

export const resolveLockScreenHelper = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const fileSystem = yield* FileSystem.FileSystem;
  if (environment.platform !== "darwin") return null;

  const isFile = (path: string, executable: boolean) =>
    fileSystem.stat(path).pipe(
      Effect.map((info) => info.type === "File" && (!executable || (info.mode & 0o111) !== 0)),
      Effect.orElseSucceed(() => false),
    );
  if (!environment.isPackaged) {
    const override = (yield* HostProcess.Environment)[HELPER_ENV];
    if (override) {
      return environment.path.isAbsolute(override) && (yield* isFile(override, true))
        ? { executable: override, args: [] }
        : null;
    }
  }

  // Keep in sync with Arguments.isTestedOS in the Swift helper; macOS 26 is Darwin 25.
  const [major, minor] = (yield* HostProcess.KernelRelease).split(".");
  if (major !== "25" || (minor !== "2" && minor !== "5")) return null;
  const dir = environment.isPackaged
    ? environment.path.join(environment.resourcesPath, "lock-screen-activity")
    : environment.path.join(
        environment.rootDir,
        "native",
        "lock-screen",
        "build",
        environment.processArch,
      );
  const executable = environment.path.join(dir, "t3-glass-card");
  const backend = environment.path.join(dir, "libT3SkyLightBackend.dylib");
  if (!(yield* isFile(executable, true)) || !(yield* isFile(backend, false))) return null;
  return { executable, args: HELPER_ARGS };
});

const HELPER_EXIT_GRACE_MS = 1500;

/** The parts of a child process the supervisor uses, so tests can stand in for one. */
export interface HelperChild {
  readonly stdin: {
    readonly writable: boolean;
    readonly write: (line: string) => boolean;
    readonly end: () => void;
    readonly on: (event: "drain" | "error", listener: () => void) => unknown;
  };
  readonly kill: (signal: "SIGKILL") => boolean;
  readonly once: (event: "exit" | "error", listener: () => void) => unknown;
}

/**
 * Owns one helper process until it exits. Ending closes stdin, which tells the helper to tear
 * down, and kills this very process if it is still running after a grace period.
 */
export function superviseHelper(
  child: HelperChild,
  events: LockScreenHelperEvents,
  schedule: (run: () => void, delayMs: number) => () => void,
) {
  let exited = false;
  let cancelKill = () => {};
  const exit = Promise.withResolvers<void>();
  const onExit = () => {
    if (exited) return;
    exited = true;
    cancelKill();
    exit.resolve();
    events.onExit();
  };
  child.stdin.on("drain", events.onDrain);
  // A write after the helper exits reports EPIPE here; the exit handler already covers it.
  child.stdin.on("error", () => undefined);
  child.once("exit", onExit);
  child.once("error", onExit);
  return {
    write: (line: string) => !exited && child.stdin.writable && child.stdin.write(line),
    end: () => {
      if (exited) return;
      child.stdin.end();
      cancelKill();
      cancelKill = schedule(() => {
        if (!exited) child.kill("SIGKILL");
      }, HELPER_EXIT_GRACE_MS);
    },
    exited: exit.promise,
  };
}

function scheduleTimer(run: () => void, delayMs: number) {
  const timer = setTimeout(run, delayMs);
  return () => clearTimeout(timer);
}

function spawnHelper(
  helper: { executable: string; args: readonly string[] },
  events: LockScreenHelperEvents,
) {
  const child = NodeChildProcess.spawn(helper.executable, helper.args, {
    stdio: ["pipe", "ignore", "ignore"],
  });
  child.stdin.setDefaultEncoding("utf8");
  return superviseHelper(child, events, scheduleTimer);
}

const policyOf = (settings: ClientSettings) => ({
  enabled: settings.lockScreenActivityEnabled,
  showTitles: settings.lockScreenActivityShowTitles,
});

function requestRepublish(sender: number) {
  const contents = Electron.webContents.fromId(sender);
  if (contents && !contents.isDestroyed()) contents.send(LOCK_SCREEN_ACTIVITY_REPUBLISH_CHANNEL);
}

export const layer = Layer.effect(
  DesktopLockScreenActivity,
  Effect.gen(function* () {
    const helper = yield* resolveLockScreenHelper;
    if (helper === null) {
      return DesktopLockScreenActivity.of({
        available: false,
        start: Effect.void,
        configure: Effect.fn("DesktopLockScreenActivity.configure")(function* () {}),
        publish: Effect.fn("DesktopLockScreenActivity.publish")(function* () {}),
        watchLocked: Effect.fn("DesktopLockScreenActivity.watchLocked")(function* () {
          return false;
        }),
      });
    }
    const powerMonitor = yield* ElectronPowerMonitor.ElectronPowerMonitor;
    const clientSettings = yield* DesktopClientSettings.DesktopClientSettings;
    const runSync = Effect.runSyncWith(yield* Effect.context<never>());
    // Every helper not yet exited, so shutdown can wait for each one to go.
    const running = new Set<Promise<void>>();
    const bridge = makeLockScreenActivityBridge((events) => {
      try {
        const spawned = spawnHelper(helper, events);
        running.add(spawned.exited);
        void spawned.exited.then(() => running.delete(spawned.exited));
        return spawned;
      } catch (error) {
        runSync(Effect.logWarning("Could not start the lock-screen helper.", error));
        return null;
      }
    });
    // Listeners on the renderer that owns the card, so a hung or replaced page clears it.
    let detachOwner = () => {};
    let ownerId: number | null = null;
    const adopt = (id: number) => {
      if (id === ownerId) return;
      detachOwner();
      ownerId = id;
      const contents = Electron.webContents.fromId(id);
      if (contents === undefined) return;
      const invalidate = () => bridge.invalidate(id);
      const republish = () => requestRepublish(id);
      const forget = () => {
        invalidate();
        detachOwner();
      };
      contents.on("unresponsive", invalidate);
      contents.on("responsive", republish);
      contents.on("render-process-gone", forget);
      contents.on("did-navigate", invalidate);
      contents.once("destroyed", forget);
      detachOwner = () => {
        ownerId = null;
        detachOwner = () => {};
        if (contents.isDestroyed()) return;
        contents.off("unresponsive", invalidate);
        contents.off("responsive", republish);
        contents.off("render-process-gone", forget);
        contents.off("did-navigate", invalidate);
        contents.off("destroyed", forget);
      };
    };

    // Renderers that asked to hear the lock state; each builds its card only while locked.
    const watchers = new Set<number>();
    const setLocked = (locked: boolean) => {
      bridge.setLocked(locked);
      for (const id of watchers) {
        const contents = Electron.webContents.fromId(id);
        if (contents === undefined || contents.isDestroyed()) watchers.delete(id);
        else contents.send(LOCK_SCREEN_ACTIVITY_LOCKED_CHANNEL, locked);
      }
    };

    return DesktopLockScreenActivity.of({
      available: true,
      start: Effect.gen(function* () {
        yield* Effect.addFinalizer(() =>
          Effect.gen(function* () {
            detachOwner();
            watchers.clear();
            bridge.dispose();
            // Each stopped helper exits on its own or is killed after its grace period.
            yield* Effect.promise(() => Promise.all(running)).pipe(
              Effect.timeout(HELPER_EXIT_GRACE_MS + 1000),
              Effect.ignore,
            );
          }),
        );
        yield* powerMonitor.onSimpleEvent("lock-screen", () => setLocked(true));
        yield* powerMonitor.onSimpleEvent("unlock-screen", () => setLocked(false));
        const stored = yield* clientSettings.get.pipe(Effect.orElseSucceed(() => Option.none()));
        if (Option.isSome(stored)) bridge.configure(policyOf(stored.value));
      }).pipe(Effect.withSpan("DesktopLockScreenActivity.start")),
      configure: Effect.fn("DesktopLockScreenActivity.configure")((settings, sender) =>
        Effect.sync(() =>
          bridge.configure(
            policyOf(settings),
            sender === undefined ? undefined : () => requestRepublish(sender),
          ),
        ),
      ),
      publish: Effect.fn("DesktopLockScreenActivity.publish")((sender, activity) =>
        Effect.sync(() => {
          adopt(sender);
          bridge.publish(sender, activity);
        }),
      ),
      watchLocked: Effect.fn("DesktopLockScreenActivity.watchLocked")((sender) =>
        Effect.sync(() => {
          if (!watchers.has(sender)) {
            watchers.add(sender);
            Electron.webContents.fromId(sender)?.once("destroyed", () => watchers.delete(sender));
          }
          return bridge.isLocked();
        }),
      ),
    });
  }),
);
