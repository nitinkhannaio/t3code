import type { EnvironmentId, ProviderThreadId, ThreadId } from "@t3tools/contracts";
import { RegistryContext, useAtomValue } from "@effect/atom-react";
import { Atom } from "effect/reactivity";
import { T, useGT } from "gt-react";
import { CheckIcon, CopyIcon, ExternalLinkIcon } from "lucide-react";
import { useContext, useEffect, useId, useState, type KeyboardEvent } from "react";

import { useCopyToClipboard } from "../../hooks/useCopyToClipboard";
import { ensureLocalApi } from "../../localApi";
import { formatEnvironmentQueryError } from "../../state/query";
import { threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import { Button, InlineButton } from "../ui/button";
import {
  Dialog,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogPanel,
  DialogPopup,
  DialogTitle,
} from "../ui/dialog";
import { Input } from "../ui/input";
import { toastManager } from "../ui/toast";

type SignIn =
  | { readonly phase: "starting" }
  | { readonly phase: "ready" | "finishing"; readonly url: string }
  | { readonly phase: "failed"; readonly url: string | null; readonly message: string };

interface McpSignInTarget {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
  readonly providerThreadId: ProviderThreadId;
  readonly server: string;
  readonly noticeAt: number;
}

interface McpSignInFlow {
  readonly target: McpSignInTarget;
  /** The timeline view that started it; only that view shows the dialog. */
  readonly owner: string;
  /** Identifies one attempt, so a result that lands after a close or a restart changes nothing. */
  readonly attempt: object;
  readonly signIn: SignIn;
}

// Outside the notice row, which regrouping or virtualization can unmount mid sign-in.
const mcpSignInFlowAtom = Atom.make<McpSignInFlow | null>(null).pipe(
  Atom.keepAlive,
  Atom.withLabel("mcp-sign-in:flow"),
);

const stopRowToggle = (event: KeyboardEvent<HTMLElement>) => event.stopPropagation();

/** Names one server's sign-in in one thread, so the dialog can find what replaced its trigger. */
export function mcpSignInNoticeKey(target: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
  readonly server: string;
  readonly noticeAt: number;
}): string {
  return JSON.stringify([target.environmentId, target.threadId, target.server, target.noticeAt]);
}

// A notice that held focus when a regroup removed it, until the row replacing it takes focus.
let removedFocusedSignInKey: string | null = null;

/** Marks a summary row standing in for these notices, so focus on one of them moves to it. */
export function mcpSignInGroupFocusProps(keys: ReadonlyArray<string>) {
  return {
    "data-mcp-sign-in-group": JSON.stringify(keys),
    ref: (element: HTMLElement | null) => {
      if (
        element !== null &&
        removedFocusedSignInKey !== null &&
        keys.includes(removedFocusedSignInKey) &&
        (document.activeElement === null || document.activeElement === document.body)
      ) {
        removedFocusedSignInKey = null;
        element.focus();
      }
    },
  };
}

/** For the notice row: refs detach before React removes the node, so it can still see focus. */
export function mcpSignInNoticeFocusRef(key: string) {
  return (element: HTMLElement | null) => () => {
    if (element === null || !element.contains(document.activeElement)) return;
    removedFocusedSignInKey = key;
    queueMicrotask(() => {
      if (removedFocusedSignInKey === key) removedFocusedSignInKey = null;
    });
  };
}

// The trigger may be gone by the time the dialog closes: a later notice can regroup its row.
function mcpSignInReturnFocus(key: string): HTMLElement | null {
  for (const element of document.querySelectorAll<HTMLElement>("[data-mcp-sign-in]")) {
    if (element.dataset.mcpSignIn === key) return element;
  }
  for (const element of document.querySelectorAll<HTMLElement>("[data-mcp-sign-in-group]")) {
    const keys = JSON.parse(element.dataset.mcpSignInGroup ?? "[]") as ReadonlyArray<string>;
    if (keys.includes(key)) return element;
  }
  return null;
}

function useMcpSignInFlow() {
  const gt = useGT();
  const registry = useContext(RegistryContext);
  const start = useAtomCommand(threadEnvironment.mcpSignInStart, { reportFailure: false });
  const complete = useAtomCommand(threadEnvironment.mcpSignInComplete, { reportFailure: false });
  const isCurrent = (attempt: object) => registry.get(mcpSignInFlowAtom)?.attempt === attempt;
  const close = () => registry.set(mcpSignInFlowAtom, null);
  const done = (server: string) => {
    close();
    toastManager.add({ type: "success", title: gt("Signed in to {server}", { server }) });
  };
  const begin = async (target: McpSignInTarget, owner: string) => {
    const attempt = {};
    const set = (signIn: SignIn) =>
      registry.set(mcpSignInFlowAtom, { target, owner, attempt, signIn });
    set({ phase: "starting" });
    const { environmentId, threadId, providerThreadId, server } = target;
    const result = await start({ environmentId, input: { threadId, providerThreadId, server } });
    if (!isCurrent(attempt)) return;
    if (result._tag === "Failure") {
      set({ phase: "failed", url: null, message: formatEnvironmentQueryError(result.cause) });
    } else if (result.value.authorizationUrl === null) {
      done(server);
    } else {
      set({ phase: "ready", url: result.value.authorizationUrl });
    }
  };
  const finish = async (flow: McpSignInFlow, url: string, callbackUrl: string) => {
    const { target, attempt } = flow;
    if (!isCurrent(attempt)) return;
    const set = (signIn: SignIn) => registry.set(mcpSignInFlowAtom, { ...flow, signIn });
    set({ phase: "finishing", url });
    const { environmentId, threadId, providerThreadId, server } = target;
    const result = await complete({
      environmentId,
      input: { threadId, providerThreadId, server, callbackUrl },
    });
    if (!isCurrent(attempt)) return;
    if (result._tag === "Failure") {
      set({ phase: "failed", url, message: formatEnvironmentQueryError(result.cause) });
    } else {
      done(server);
    }
  };
  return { begin, finish, close };
}

/**
 * Signs an MCP server in from the notice that says it needs one. The agent
 * keeps the credential; the user approves in a browser, then pastes back the
 * address it lands on, which is often a localhost page on another machine.
 */
export function McpSignInAction({
  environmentId,
  threadId,
  providerThreadId,
  server,
  noticeAt,
  owner,
}: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
  readonly providerThreadId: ProviderThreadId;
  readonly server: string;
  /** When the environment raised the notice, in epoch milliseconds. */
  readonly noticeAt: number;
  /** The timeline view showing the notice, which hosts its dialog. */
  readonly owner: string;
}) {
  const allowed = useAtomValue(threadEnvironment.mcpSignInStart.permissionAtom(environmentId));
  const signedIn = useAtomValue(
    threadEnvironment.mcpSignedInAtom(environmentId, { threadId, server, noticeAt }),
  );
  const gt = useGT();
  const { begin } = useMcpSignInFlow();
  if (!allowed) return null;
  const key = mcpSignInNoticeKey({ environmentId, threadId, server, noticeAt });

  return signedIn ? (
    <span className="shrink-0 text-sm text-success-foreground">
      <T>Signed in</T>
    </span>
  ) : (
    <InlineButton
      data-mcp-sign-in={key}
      aria-label={gt("Sign in to {server}", { server })}
      onClick={(event) => {
        event.stopPropagation();
        void begin({ environmentId, threadId, providerThreadId, server, noticeAt }, owner);
      }}
      onKeyDown={stopRowToggle}
    >
      <T>Sign in</T>
    </InlineButton>
  );
}

/** Shows the dialog for sign-ins started from this timeline view, above its virtualized rows. */
export function McpSignInDialogHost({ owner }: { readonly owner: string }) {
  const registry = useContext(RegistryContext);
  const flow = useAtomValue(mcpSignInFlowAtom);
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- ends this view's sign-in in the shared atom when the view leaves its thread
  useEffect(
    () => () => {
      if (registry.get(mcpSignInFlowAtom)?.owner === owner) registry.set(mcpSignInFlowAtom, null);
    },
    [registry, owner],
  );
  return flow === null || flow.owner !== owner ? null : (
    <PermittedMcpSignInDialog key={mcpSignInNoticeKey(flow.target)} flow={flow} />
  );
}

// The notice drops its Sign in button without the grant, so the dialog hides until it returns.
function PermittedMcpSignInDialog({ flow }: { readonly flow: McpSignInFlow }) {
  const allowed = useAtomValue(
    threadEnvironment.mcpSignInStart.permissionAtom(flow.target.environmentId),
  );
  return <McpSignInDialog flow={flow} open={allowed} />;
}

function McpSignInDialog({ flow, open }: { readonly flow: McpSignInFlow; readonly open: boolean }) {
  const gt = useGT();
  const formId = useId();
  const { begin, finish, close } = useMcpSignInFlow();
  const { copyToClipboard, isCopied } = useCopyToClipboard();
  const [callbackUrl, setCallbackUrl] = useState("");
  const { signIn, target } = flow;
  const { server } = target;
  const url = signIn.phase !== "starting" ? signIn.url : null;
  const submit = (url: string) => {
    if (callbackUrl.trim().length === 0) return;
    void finish(flow, url, callbackUrl.trim());
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) close();
      }}
    >
      <DialogPopup
        className="max-w-lg"
        finalFocus={() => mcpSignInReturnFocus(mcpSignInNoticeKey(target))}
      >
        <DialogHeader>
          <DialogTitle>{gt("Sign in to {server}", { server })}</DialogTitle>
          <DialogDescription>
            <T>
              Approve access in your browser. It then opens a page that may not load: copy that
              page's address and paste it here.
            </T>
          </DialogDescription>
        </DialogHeader>
        <DialogPanel>
          {signIn.phase === "starting" ? (
            <p className="text-sm text-muted-foreground">
              <T>Starting the sign-in…</T>
            </p>
          ) : null}
          {url !== null ? (
            <form
              id={formId}
              className="grid gap-4"
              onSubmit={(event) => {
                event.preventDefault();
                submit(url);
              }}
            >
              <div className="flex flex-wrap gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => void ensureLocalApi().shell.openExternal(url)}
                >
                  <ExternalLinkIcon aria-hidden />
                  <T>Open sign-in page</T>
                </Button>
                <Button variant="ghost" size="sm" onClick={() => copyToClipboard(url)}>
                  {isCopied ? <CheckIcon aria-hidden /> : <CopyIcon aria-hidden />}
                  <T>Copy link</T>
                </Button>
              </div>
              <label className="grid gap-1.5 text-sm">
                <T>Address of the page your browser opened</T>
                <Input
                  // Browsers can hide `http://`, which the environment adds back.
                  inputMode="url"
                  autoComplete="off"
                  spellCheck={false}
                  value={callbackUrl}
                  maxLength={16_384}
                  disabled={signIn.phase === "finishing"}
                  onChange={(event) => setCallbackUrl(event.target.value)}
                />
              </label>
            </form>
          ) : null}
          {signIn.phase === "failed" ? (
            <p role="alert" className="mt-3 text-sm text-destructive-foreground">
              {signIn.message}
            </p>
          ) : null}
        </DialogPanel>
        <DialogFooter variant="bare">
          <Button variant="outline" onClick={close}>
            <T>Cancel</T>
          </Button>
          {url === null && signIn.phase === "failed" ? (
            <Button
              onClick={() => {
                setCallbackUrl("");
                void begin(target, flow.owner);
              }}
            >
              <T>Try again</T>
            </Button>
          ) : (
            <Button
              type="submit"
              form={formId}
              disabled={
                url === null || signIn.phase === "finishing" || callbackUrl.trim().length === 0
              }
            >
              <T>Finish sign-in</T>
            </Button>
          )}
        </DialogFooter>
      </DialogPopup>
    </Dialog>
  );
}
