import { fromServerClock } from "@t3tools/client-runtime/clock";
import { scopedThreadKey } from "@t3tools/client-runtime/environment";
import { threadKey } from "@t3tools/client-runtime/state/entities";
import { buildLockScreenActivity } from "@t3tools/client-runtime/state/lock-screen-activity";
import {
  presentThreadShell,
  type EnvironmentProject,
  type EnvironmentThreadShell,
  type PendingSubagentRequest,
} from "@t3tools/client-runtime/state/models";
import {
  createEnvironmentThreadShellAtoms,
  isShownUnderParent,
} from "@t3tools/client-runtime/state/threads";
import type { OrchestrationV2ThreadShell, ProviderDriverKind } from "@t3tools/contracts";
import { Atom, type AtomRegistry } from "effect/reactivity";

import { resolveThreadLastVisitedAt } from "./components/Sidebar.logic";
import { environmentCatalog } from "./connection/catalog";
import { subscribeI18n } from "./i18n/runtime";
import { isLockScreenActivityAvailable } from "./env";
import { getClientSettings, subscribeClientSettings } from "./hooks/useSettings";
import {
  createLockScreenIconCache,
  createLockScreenPublisher,
  externalStoreAtom,
  watchLockScreenSnooze,
} from "./lockScreenActivity.logic";
import {
  lockScreenIconSource,
  renderLockScreenIcon,
  type LockScreenIconSource,
} from "./lockScreenProjectIcons";
import { projectFaviconUrlAtom } from "./state/assets";
import { environmentProjects } from "./state/projects";
import { providersIgnoringCheckedAtAtom, serverEnvironment } from "./state/server";
import { environmentSnapshotAtom, liveShellEnvironmentIdsAtom } from "./state/shell";
import { useUiStateStore } from "./uiStateStore";

// Not the app's shared set: that one rolls subagent requests up from offline environments' cached
// shells, which the card must not show as current. Atoms are lazy, so this set only computes
// while the card is watched, which is only while the screen is locked.
const liveThreadShells = createEnvironmentThreadShellAtoms({
  catalogValueAtom: environmentCatalog.catalogValueAtom,
  snapshotAtom: environmentSnapshotAtom,
  liveEnvironmentIdsAtom: liveShellEnvironmentIdsAtom,
  hiddenThreadTagsAtom: serverEnvironment.hiddenThreadTagsAtom,
});

type Presented = {
  readonly request: PendingSubagentRequest | null;
  readonly shell: EnvironmentThreadShell;
};

// Older servers keep no visit marks, so the sidebar reads this browser's; the card follows it.
const localVisitsAtom = externalStoreAtom(
  (listener) => useUiStateStore.subscribe(listener),
  () => useUiStateStore.getState().threadLastVisitedAtById,
).pipe(Atom.withLabel("web-lock-screen-local-visits"));

// Decided before selection, so a recompute builds and draws icons for one mode only.
const showTitlesAtom = externalStoreAtom(
  subscribeClientSettings,
  () => getClientSettings().lockScreenActivityShowTitles,
).pipe(Atom.withLabel("web-lock-screen-show-titles"));

const projectIcons = createLockScreenIconCache(renderLockScreenIcon);
const projectIconsVersionAtom = externalStoreAtom(
  projectIcons.subscribe,
  projectIcons.version,
).pipe(Atom.withLabel("web-lock-screen-project-icons"));
// A favicon is a long data URL, so its key is built once per project and favicon, not per read.
const iconKeys = new WeakMap<
  EnvironmentProject,
  { readonly favicon: string | null; readonly key: string; readonly source: LockScreenIconSource }
>();

function projectIconKey(project: EnvironmentProject, favicon: string | null) {
  const known = iconKeys.get(project);
  if (known?.favicon === favicon) return known;
  const source = lockScreenIconSource(project, favicon);
  const entry = { favicon, key: JSON.stringify(source), source };
  iconKeys.set(project, entry);
  return entry;
}

const lockScreenCardAtom = (() => {
  const presented = new WeakMap<OrchestrationV2ThreadShell, Presented>();
  return Atom.make((get) => {
    const asOf = Date.now();
    let nextSnoozeWake = Infinity;
    const delegatedUnderParent = get(liveThreadShells.delegatedUnderParentAtom);
    const hidden = get(liveThreadShells.hiddenThreadKeysAtom);
    const localVisits = get(localVisitsAtom);
    const mode = get(showTitlesAtom) ? "threads" : "projects";
    const threads: EnvironmentThreadShell[] = [];
    const drivers = new Map<string, ProviderDriverKind>();
    for (const environmentId of get(liveShellEnvironmentIdsAtom)) {
      const requests = get(liveThreadShells.pendingSubagentRequestsAtom(environmentId));
      const driverByInstance = new Map(
        get(providersIgnoringCheckedAtAtom(environmentId)).map((provider) => [
          provider.instanceId as string,
          provider.driver,
        ]),
      );
      for (const raw of get(liveThreadShells.environmentThreadsAtom(environmentId))) {
        const ref = { environmentId, threadId: raw.id };
        if (isShownUnderParent(ref, raw.lineage, delegatedUnderParent)) continue;
        const key = threadKey(ref);
        if (hidden.has(key)) continue;
        const request = requests.get(raw.id) ?? null;
        let entry = presented.get(raw);
        if (entry?.request !== request) {
          entry = { request, shell: presentThreadShell(environmentId, raw, request) };
          presented.set(raw, entry);
        }
        const lastVisitedAt = resolveThreadLastVisitedAt(
          entry.shell.lastVisitedAt,
          localVisits[scopedThreadKey(ref)],
        );
        threads.push(
          lastVisitedAt === undefined || lastVisitedAt === entry.shell.lastVisitedAt
            ? entry.shell
            : { ...entry.shell, lastVisitedAt },
        );
        const wakesAt = Date.parse(entry.shell.snoozedUntil ?? "");
        if (wakesAt > asOf) nextSnoozeWake = Math.min(nextSnoozeWake, wakesAt);
        const instanceId = entry.shell.runtime?.providerInstanceId ?? raw.modelSelection.instanceId;
        const driver = driverByInstance.get(instanceId);
        if (driver !== undefined) drivers.set(key, driver);
      }
    }
    // A thread can wake without a shell change.
    if (Number.isFinite(nextSnoozeWake)) {
      get.addFinalizer(watchLockScreenSnooze(nextSnoozeWake, () => get.refreshSelf()));
    }
    get(projectIconsVersionAtom);
    const projectOf = (thread: Pick<EnvironmentThreadShell, "environmentId" | "projectId">) =>
      get(
        environmentProjects.projectAtom({
          environmentId: thread.environmentId,
          projectId: thread.projectId,
        }),
      );
    return buildLockScreenActivity({
      threads,
      mode,
      providerDriver: (thread) =>
        drivers.get(threadKey({ environmentId: thread.environmentId, threadId: thread.id })) ??
        null,
      projectName: (thread) => {
        const project = projectOf(thread);
        return project === null || project.isScratch === true ? null : project.title;
      },
      projectIcon: (thread) => {
        const project = projectOf(thread);
        if (project === null) return null;
        const favicon =
          project.projectIcon == null
            ? get(
                projectFaviconUrlAtom({
                  environmentId: project.environmentId,
                  cwd: project.workspaceRoot,
                  faviconPath: project.faviconPath,
                }),
              )
            : null;
        const { key, source } = projectIconKey(project, favicon);
        return projectIcons.read(key, source);
      },
      toLocalClock: fromServerClock,
      asOf,
    });
  }).pipe(Atom.withLabel("web-lock-screen-card"));
})();

/** Publishes the macOS lock-screen card while the experimental setting is on. */
export function startLockScreenActivity(registry: AtomRegistry.AtomRegistry): () => void {
  const bridge = window.desktopBridge;
  if (!isLockScreenActivityAvailable || !bridge) return () => {};
  return createLockScreenPublisher({
    bridge,
    settings: getClientSettings,
    subscribeSettings: subscribeClientSettings,
    card: () => registry.get(lockScreenCardAtom),
    watchCard: (onChange) => registry.subscribe(lockScreenCardAtom, onChange),
    subscribeLocale: subscribeI18n,
  });
}
