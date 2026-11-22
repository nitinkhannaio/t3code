import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import * as NodeUtil from "node:util";

// oxlint-disable-next-line t3code/no-global-process-runtime -- Build scripts use the actual compiler host.
const hostPlatform = process.platform;
// oxlint-disable-next-line t3code/no-global-process-runtime -- Build scripts use the actual compiler host.
const hostArch = process.arch;
const { values } = NodeUtil.parseArgs({
  options: { "output-dir": { type: "string" }, arch: { type: "string", default: hostArch } },
});

if (hostPlatform !== "darwin")
  throw new Error("The lock-screen activity helper builds on macOS only.");

const arch = values.arch;
const targets = { arm64: ["arm64"], x64: ["x86_64"], universal: ["arm64", "x86_64"] }[arch];
if (!targets) throw new Error(`Unsupported macOS architecture: ${arch}`);

const root = NodeURL.fileURLToPath(new URL("../../../native/lock-screen/", import.meta.url));
const outDir = values["output-dir"] ?? NodePath.join(root, "build", arch);
const swiftSources = (name) => {
  const dir = NodePath.join(root, "Sources", name);
  return NodeFS.readdirSync(dir)
    .filter((file) => file.endsWith(".swift"))
    .sort()
    .map((file) => NodePath.join(dir, file));
};
const helperName = "t3-glass-card";
const backendName = "libT3SkyLightBackend.dylib";
const outputs = [
  {
    name: helperName,
    args: [
      "-module-name",
      "T3GlassCard",
      "-framework",
      "AppKit",
      ...swiftSources("Core"),
      ...swiftSources("App"),
    ],
  },
  {
    name: backendName,
    args: [
      "-module-name",
      "T3SkyLightBackend",
      "-emit-library",
      ...swiftSources("SkyLightBackend"),
      "-Xlinker",
      "-install_name",
      "-Xlinker",
      `@rpath/${backendName}`,
    ],
  },
];

NodeFS.mkdirSync(outDir, { recursive: true });
const temporary = NodeFS.mkdtempSync(NodePath.join(outDir, ".build-"));
try {
  for (const { name, args } of outputs) {
    const output = NodePath.join(temporary, name);
    const slices = targets.map((target) => {
      const slice = targets.length === 1 ? output : `${output}.${target}`;
      NodeChildProcess.execFileSync(
        "xcrun",
        [
          "swiftc",
          "-O",
          "-swift-version",
          "5",
          "-target",
          `${target}-apple-macos26.0`,
          ...args,
          "-o",
          slice,
        ],
        { stdio: "inherit" },
      );
      return slice;
    });
    if (slices.length > 1) {
      NodeChildProcess.execFileSync("xcrun", ["lipo", "-create", ...slices, "-output", output], {
        stdio: "inherit",
      });
    }
  }
  NodeFS.copyFileSync(NodePath.join(root, "NOTICE"), NodePath.join(temporary, "NOTICE"));
  for (const name of [backendName, helperName, "NOTICE"]) {
    NodeFS.renameSync(NodePath.join(temporary, name), NodePath.join(outDir, name));
  }
} finally {
  NodeFS.rmSync(temporary, { recursive: true, force: true });
}
