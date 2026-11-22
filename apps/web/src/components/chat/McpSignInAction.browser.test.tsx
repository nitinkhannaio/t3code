import { RegistryContext } from "@effect/atom-react";
import { EnvironmentId, ProviderThreadId, ThreadId } from "@t3tools/contracts";
import { AsyncResult, Atom, AtomRegistry } from "effect/reactivity";
import type { ReactNode } from "react";
import { expect, it, vi } from "vite-plus/test";
import { page, userEvent } from "vite-plus/test/browser";

import { render } from "../../../test/render";

const state = vi.hoisted(() => ({
  start: vi.fn(),
  allowed: null as Atom.Writable<boolean> | null,
}));

vi.mock("../../state/use-atom-command", () => ({ useAtomCommand: () => state.start }));
vi.mock("../../state/threads", async () => {
  const { Atom } = await vi.importActual<typeof import("effect/reactivity")>("effect/reactivity");
  state.allowed = Atom.make(true);
  const notSignedIn = Atom.make(false);
  return {
    threadEnvironment: {
      mcpSignInStart: { permissionAtom: () => state.allowed },
      mcpSignInComplete: {},
      mcpSignedInAtom: () => notSignedIn,
    },
  };
});

import {
  McpSignInAction,
  McpSignInDialogHost,
  mcpSignInGroupFocusProps,
  mcpSignInNoticeKey,
  mcpSignInNoticeFocusRef,
} from "./McpSignInAction";

const target = {
  environmentId: EnvironmentId.make("environment"),
  threadId: ThreadId.make("thread"),
  server: "fold",
  noticeAt: 0,
};

function setup() {
  state.start.mockReset();
  state.start.mockResolvedValue(
    AsyncResult.success({ authorizationUrl: "https://auth.example.com/authorize" }),
  );
  const registry = AtomRegistry.make();
  const ui = (rows: ReactNode, owner = "thread-view") => (
    <RegistryContext.Provider value={registry}>
      <McpSignInDialogHost owner={owner} />
      {rows}
    </RegistryContext.Provider>
  );
  // Stands in for the timeline's notice row: its disclosure, its action, and its focus ref.
  const notice = (noticeAt = target.noticeAt) => (
    <div ref={mcpSignInNoticeFocusRef(mcpSignInNoticeKey({ ...target, noticeAt }))}>
      <div role="button" tabIndex={0} aria-label="Notice details" />
      <McpSignInAction
        {...target}
        noticeAt={noticeAt}
        providerThreadId={ProviderThreadId.make("provider-thread")}
        owner="thread-view"
      />
    </div>
  );
  const summary = (
    <button type="button" {...mcpSignInGroupFocusProps([mcpSignInNoticeKey(target)])}>
      2 MCP servers need a sign-in
    </button>
  );
  return { registry, ui, notice, summary };
}

it("keeps a sign-in in progress when a later notice regroups its row", async () => {
  const { ui, notice, summary } = setup();
  await using screen = await render(ui(notice()));
  const trigger = screen.getByRole("button", { name: "Sign in to fold" });
  (await trigger.element()).focus();
  await userEvent.keyboard("{Enter}");
  const callback = page.getByRole("dialog").getByRole("textbox");
  await callback.fill("http://localhost:4567/callback?code=abc");

  await screen.rerender(ui(summary));

  await expect.element(page.getByRole("dialog")).toBeVisible();
  await expect.element(callback).toHaveValue("http://localhost:4567/callback?code=abc");
  await userEvent.keyboard("{Escape}");
  await expect.element(page.getByRole("dialog")).not.toBeInTheDocument();
  await expect
    .element(screen.getByRole("button", { name: "2 MCP servers need a sign-in" }))
    .toHaveFocus();
});

it("hides the sign-in while the environment withdraws the grant", async () => {
  const { registry, ui, notice } = setup();
  await using screen = await render(ui(notice()));
  await screen.getByRole("button", { name: "Sign in to fold" }).click();
  const callback = page.getByRole("dialog").getByRole("textbox");
  await callback.fill("http://localhost:4567/callback?code=abc");

  registry.set(state.allowed!, false);
  await expect.element(page.getByRole("dialog")).not.toBeInTheDocument();
  await expect
    .element(screen.getByRole("button", { name: "Sign in to fold" }))
    .not.toBeInTheDocument();

  registry.set(state.allowed!, true);
  await expect.element(callback).toHaveValue("http://localhost:4567/callback?code=abc");
});

it.each(["Sign in to fold", "Notice details"])(
  "moves focus from %s to the summary when a regroup removes the notice",
  async (focused) => {
    const { ui, notice, summary } = setup();
    await using screen = await render(ui(notice()));
    (await screen.getByRole("button", { name: focused, exact: true }).element()).focus();

    await screen.rerender(ui(summary));

    await expect
      .element(screen.getByRole("button", { name: "2 MCP servers need a sign-in" }))
      .toHaveFocus();
  },
);

it("ends the sign-in when its timeline view moves to another thread", async () => {
  const { ui, notice } = setup();
  await using screen = await render(ui(notice()));
  await screen.getByRole("button", { name: "Sign in to fold" }).click();
  await expect.element(page.getByRole("dialog")).toBeVisible();

  await screen.rerender(ui(null, "other-thread-view"));
  await expect.element(page.getByRole("dialog")).not.toBeInTheDocument();

  await screen.rerender(ui(notice()));
  await expect.element(screen.getByRole("button", { name: "Sign in to fold" })).toBeVisible();
  await expect.element(page.getByRole("dialog")).not.toBeInTheDocument();
});

it("returns focus to the notice that opened the sign-in when a server has several", async () => {
  const { ui, notice } = setup();
  await using screen = await render(
    ui(
      <>
        {notice(0)}
        {notice(1)}
      </>,
    ),
  );
  const later = screen.getByRole("button", { name: "Sign in to fold" }).nth(1);
  (await later.element()).focus();
  await userEvent.keyboard("{Enter}");
  await expect.element(page.getByRole("dialog")).toBeVisible();

  await userEvent.keyboard("{Escape}");

  await expect.element(page.getByRole("dialog")).not.toBeInTheDocument();
  await expect.element(later).toHaveFocus();
});
