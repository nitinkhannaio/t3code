import type { EnvironmentProject } from "@t3tools/client-runtime/state/shell";
import { isLockScreenProjectIcon, type ProjectIconColor } from "@t3tools/contracts";
import { isProjectFaviconFallbackUrl } from "@t3tools/shared/projectFavicon";
import { FolderCodeIcon } from "lucide-react";
import { createElement, type ComponentType } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";

import { deriveProjectIdentity } from "./projectIdentity";
import { PROJECT_ICON_COLORS } from "./projectIconColors";

/** What `ProjectFavicon` would draw for a project, reduced to what the lock screen can show. */
export type LockScreenIconSource =
  | { readonly kind: "image"; readonly src: string; readonly fallback: LockScreenIconSource }
  | { readonly kind: "monogram"; readonly text: string; readonly color: ProjectIconColor }
  | { readonly kind: "emoji"; readonly emoji: string }
  | { readonly kind: "lucide"; readonly name: string; readonly color: ProjectIconColor }
  | { readonly kind: "folder" };

export type LockScreenIconProject = Pick<EnvironmentProject, "title" | "projectIcon">;

export function lockScreenIconSource(
  project: LockScreenIconProject,
  faviconSrc: string | null,
): LockScreenIconSource {
  const icon = project.projectIcon;
  if (icon?.kind === "monogram") return { kind: "monogram", text: icon.text, color: icon.color };
  if (icon?.kind === "emoji") return { kind: "emoji", emoji: icon.emoji };
  if (icon?.kind === "lucide") return { kind: "lucide", name: icon.name, color: icon.color };
  const identity = project.title.trim().length > 0 ? deriveProjectIdentity(project.title) : null;
  const fallback: LockScreenIconSource =
    identity === null
      ? { kind: "folder" }
      : { kind: "monogram", text: identity.monogram, color: identity.color };
  if (!faviconSrc || isProjectFaviconFallbackUrl(faviconSrc)) return fallback;
  return { kind: "image", src: faviconSrc, fallback };
}

const SIZE = 32;
const RADIUS = SIZE / 4;
const monogramSegmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

function escapeXml(value: string): string {
  return value.replace(
    /[<>&"']/g,
    (char) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;" })[char]!,
  );
}

function swatchColor(className: string): string {
  const host = document.createElement("div");
  host.className = "dark";
  host.style.cssText = "position:fixed;visibility:hidden;pointer-events:none;contain:strict";
  const probe = document.createElement("span");
  probe.className = className;
  host.append(probe);
  document.body.append(host);
  try {
    return getComputedStyle(probe).backgroundColor;
  } finally {
    host.remove();
  }
}

// The card's glass turns light or dark with the wallpaper after the icon is drawn, and a tint or a
// coloured glyph washes out on one of them, so drawn icons are white on a solid tile of the
// project's swatch, deepened enough for white. The app's own theme never matters.
function tileColor(color: ProjectIconColor): string {
  const swatch = PROJECT_ICON_COLORS.find((entry) => entry.value === color)?.swatchClassName;
  return `color-mix(in oklab, ${swatchColor(swatch ?? "bg-gray-500")} 72%, black)`;
}

function drawingSurface() {
  const canvas = document.createElement("canvas");
  canvas.width = SIZE;
  canvas.height = SIZE;
  const context = canvas.getContext("2d");
  if (context === null) throw new Error("Canvas is unavailable.");
  return { canvas, context };
}

function encode(canvas: HTMLCanvasElement): string | null {
  const png = canvas.toDataURL("image/png");
  return isLockScreenProjectIcon(png) ? png : null;
}

async function loadImage(src: string): Promise<HTMLImageElement> {
  const image = new Image();
  if (!src.startsWith("data:")) image.crossOrigin = "anonymous";
  image.src = src;
  await image.decode();
  return image;
}

async function drawSvg(markup: string): Promise<string | null> {
  const image = await loadImage(`data:image/svg+xml;charset=utf-8,${encodeURIComponent(markup)}`);
  const { canvas, context } = drawingSurface();
  context.drawImage(image, 0, 0, SIZE, SIZE);
  return encode(canvas);
}

function monogramSvg(text: string, color: ProjectIconColor): string {
  const glyphs = Array.from(monogramSegmenter.segment(text)).length;
  const fontFamily =
    getComputedStyle(document.documentElement).getPropertyValue("--font-mono").trim() ||
    "ui-monospace, monospace";
  const style = escapeXml(`color: ${tileColor(color)}`);
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 16 16" style="${style}">`,
    `<rect width="16" height="16" rx="4" fill="currentColor"/>`,
    `<text x="8" y="10.8" text-anchor="middle" fill="#fff" font-size="8.25" font-weight="700"`,
    ` textLength="${glyphs === 1 ? 6 : 12}" lengthAdjust="spacingAndGlyphs" text-rendering="geometricPrecision"`,
    ` style="${escapeXml(`font-family: ${fontFamily}`)}">${escapeXml(text)}</text></svg>`,
  ].join("");
}

const GLYPH = 22;

function tiledIconSvg(icon: ComponentType, color: ProjectIconColor): string {
  const host = document.createElement("div");
  const root = createRoot(host);
  try {
    flushSync(() => root.render(createElement(icon)));
    const svg = host.querySelector("svg");
    if (svg === null) throw new Error("Icon did not render.");
    const inset = String((SIZE - GLYPH) / 2);
    svg.setAttribute("x", inset);
    svg.setAttribute("y", inset);
    svg.setAttribute("width", String(GLYPH));
    svg.setAttribute("height", String(GLYPH));
    svg.style.color = "#fff";
    const glyph = new XMLSerializer().serializeToString(svg);
    const style = escapeXml(`color: ${tileColor(color)}`);
    return [
      `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}" style="${style}">`,
      `<rect width="${SIZE}" height="${SIZE}" rx="${RADIUS}" fill="currentColor"/>${glyph}</svg>`,
    ].join("");
  } finally {
    root.unmount();
  }
}

async function lucideIcon(name: string): Promise<ComponentType> {
  const { lucideIconByName } = await import("./lib/lucideIconByName");
  return lucideIconByName(name) ?? FolderCodeIcon;
}

function drawEmoji(emoji: string): string | null {
  const { canvas, context } = drawingSurface();
  context.font = `${Math.round(SIZE * 0.8)}px "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif`;
  context.textAlign = "center";
  const metrics = context.measureText(emoji);
  const baseline = (SIZE + metrics.actualBoundingBoxAscent - metrics.actualBoundingBoxDescent) / 2;
  context.fillText(emoji, SIZE / 2, baseline);
  return encode(canvas);
}

async function drawImage(src: string): Promise<string | null> {
  const image = await loadImage(src);
  const { canvas, context } = drawingSurface();
  const scale = Math.min(SIZE / image.naturalWidth, SIZE / image.naturalHeight);
  const width = image.naturalWidth * scale;
  const height = image.naturalHeight * scale;
  context.beginPath();
  context.roundRect(0, 0, SIZE, SIZE, RADIUS);
  context.clip();
  context.drawImage(image, (SIZE - width) / 2, (SIZE - height) / 2, width, height);
  return encode(canvas);
}

/** Draws a project icon as the 32px PNG the lock screen accepts, or null when it cannot. */
export async function renderLockScreenIcon(source: LockScreenIconSource): Promise<string | null> {
  switch (source.kind) {
    case "monogram":
      return drawSvg(monogramSvg(source.text, source.color));
    case "emoji":
      return drawEmoji(source.emoji);
    case "lucide":
      return drawSvg(tiledIconSvg(await lucideIcon(source.name), source.color));
    case "folder":
      return drawSvg(tiledIconSvg(FolderCodeIcon, "gray"));
    case "image":
      // A favicon that will not load, or that would taint the canvas, shows its fallback, as in the app.
      return drawImage(source.src).catch(() => renderLockScreenIcon(source.fallback));
  }
}
