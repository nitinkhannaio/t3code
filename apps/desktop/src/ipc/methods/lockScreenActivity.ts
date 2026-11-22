import { DesktopLockScreenActivitySchema } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import * as DesktopLockScreenActivity from "../../lockScreen/DesktopLockScreenActivity.ts";
import * as IpcChannels from "../channels.ts";
import * as DesktopIpc from "../DesktopIpc.ts";

export const getLockScreenActivityAvailable = DesktopIpc.makeSyncIpcMethod({
  channel: IpcChannels.GET_LOCK_SCREEN_ACTIVITY_AVAILABLE_CHANNEL,
  result: Schema.Boolean,
  handler: Effect.fn("desktop.ipc.lockScreenActivity.available")(function* () {
    return (yield* DesktopLockScreenActivity.DesktopLockScreenActivity).available;
  }),
});

export const setLockScreenActivity = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.SET_LOCK_SCREEN_ACTIVITY_CHANNEL,
  payload: Schema.NullOr(DesktopLockScreenActivitySchema),
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.lockScreenActivity.set")(function* (activity, event) {
    if (event === undefined) return;
    const lockScreen = yield* DesktopLockScreenActivity.DesktopLockScreenActivity;
    yield* lockScreen.publish(event.sender.id, activity);
  }),
});

export const watchLockScreenLocked = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.WATCH_LOCK_SCREEN_LOCKED_CHANNEL,
  payload: Schema.Void,
  result: Schema.Boolean,
  handler: Effect.fn("desktop.ipc.lockScreenActivity.watchLocked")(function* (_payload, event) {
    if (event === undefined) return false;
    const lockScreen = yield* DesktopLockScreenActivity.DesktopLockScreenActivity;
    return yield* lockScreen.watchLocked(event.sender.id);
  }),
});
