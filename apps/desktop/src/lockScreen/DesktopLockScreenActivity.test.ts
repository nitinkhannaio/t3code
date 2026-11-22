import * as NodePath from "@effect/platform-node/NodePath";
import { assert, it } from "@effect/vitest";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as PlatformError from "effect/PlatformError";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import {
  resolveLockScreenHelper,
  superviseHelper,
  type HelperChild,
} from "./DesktopLockScreenActivity.ts";

const resources = "/Applications/T3 Code.app/Contents/Resources";
const executable = `${resources}/lock-screen-activity/t3-glass-card`;
const backend = `${resources}/lock-screen-activity/libT3SkyLightBackend.dylib`;
const override = "/tmp/dev-glass-card";
const packagedFiles = { [executable]: 0o755, [backend]: 0o644 };
const args = ["live-lock", "--private-skylight", "--expand-on-click"];

function resolve(
  files: Record<string, number> = {},
  options: { packaged?: boolean; release?: string; platform?: NodeJS.Platform } = {},
) {
  const environment = Layer.effect(
    DesktopEnvironment.DesktopEnvironment,
    Effect.map(
      Path.Path,
      (path) =>
        ({
          path,
          platform: options.platform ?? "darwin",
          isPackaged: options.packaged ?? true,
          resourcesPath: resources,
          rootDir: "/repo",
          processArch: "arm64",
        }) as DesktopEnvironment.DesktopEnvironment["Service"],
    ),
  ).pipe(Layer.provide(NodePath.layerPosix));
  return resolveLockScreenHelper.pipe(
    Effect.provide(
      Layer.mergeAll(
        environment,
        Layer.succeed(HostProcess.KernelRelease, options.release ?? "25.2.0"),
        Layer.succeed(HostProcess.Environment, { T3CODE_DEV_LOCK_SCREEN_HELPER: override }),
        FileSystem.layerNoop({
          stat: (path) => {
            const mode = files[path];
            return mode === undefined
              ? Effect.fail(
                  PlatformError.systemError({
                    _tag: "NotFound",
                    module: "FileSystem",
                    method: "stat",
                    pathOrDescriptor: path,
                  }),
                )
              : Effect.succeed({ type: "File", mode } as FileSystem.File.Info);
          },
        }),
      ),
    ),
  );
}

it.effect(
  "selects the bundled helper on the iMac and ignores developer overrides in a package",
  () =>
    Effect.gen(function* () {
      assert.deepEqual(yield* resolve({ ...packagedFiles, [override]: 0o755 }), {
        executable,
        args,
      });
      assert.isNull(yield* resolve({ [override]: 0o755 }));
    }),
);

it.effect(
  "hides the setting when the bundle is incomplete, unusable, or off the tested macOS versions",
  () =>
    Effect.gen(function* () {
      assert.isNull(yield* resolve({ [executable]: 0o755 }));
      assert.isNull(yield* resolve({ ...packagedFiles, [executable]: 0o644 }));
      assert.isNull(yield* resolve(packagedFiles, { release: "25.3.0" }));
      assert.isNull(yield* resolve(packagedFiles, { platform: "linux" }));
    }),
);

it.effect("preserves launching an explicitly configured developer wrapper with no arguments", () =>
  Effect.gen(function* () {
    assert.deepEqual(yield* resolve({ [override]: 0o755 }, { packaged: false }), {
      executable: override,
      args: [],
    });
  }),
);

function fakeChild() {
  const listeners = new Map<string, () => void>();
  const kills: string[] = [];
  const stdin = { writable: true, ended: false };
  const child: HelperChild = {
    stdin: {
      get writable() {
        return stdin.writable;
      },
      write: () => true,
      end: () => {
        stdin.ended = true;
      },
      on: () => undefined,
    },
    kill: (signal) => {
      kills.push(signal);
      return true;
    },
    once: (event, listener) => listeners.set(event, listener),
  };
  return { child, kills, stdin, exit: () => listeners.get("exit")?.() };
}

function timers() {
  const pending: Array<{ run: () => void; cancelled: boolean }> = [];
  return {
    schedule: (run: () => void) => {
      const timer = { run, cancelled: false };
      pending.push(timer);
      return () => {
        timer.cancelled = true;
      };
    },
    fire: () => {
      for (const timer of pending.splice(0)) if (!timer.cancelled) timer.run();
    },
  };
}

it("closes a stopped helper's stdin, then kills that child only if it outlives the grace period", () => {
  const exits: string[] = [];
  const events = { onDrain: () => undefined, onExit: () => exits.push("exit") };

  const stubborn = fakeChild();
  const stubbornTimers = timers();
  superviseHelper(stubborn.child, events, stubbornTimers.schedule).end();
  assert.isTrue(stubborn.stdin.ended);
  assert.deepEqual(stubborn.kills, []);
  stubbornTimers.fire();
  assert.deepEqual(stubborn.kills, ["SIGKILL"]);

  const polite = fakeChild();
  const politeTimers = timers();
  const helper = superviseHelper(polite.child, events, politeTimers.schedule);
  helper.end();
  polite.exit();
  politeTimers.fire();
  assert.deepEqual(polite.kills, []);
  assert.isFalse(helper.write("null\n"));
  assert.deepEqual(exits, ["exit"]);
});
