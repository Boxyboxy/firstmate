import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

let forcedThisEpisode = false;

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded() {
  if (lockOwnership() === "other") return false;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
  return true;
}

// omp shares Pi's extension surface, so this mirrors the Pi adapter's run tier
// rather than the older one-line nudge: bin/fm-sessionstart-run.sh owns what
// each session-open source means, and this maps omp's verified session_start
// reasons (startup, new, resume) onto its --source names and injects whatever it
// prints. omp 17.2.11 also emits session_compact, its compaction equivalent.
const sessionstartDeliveryBytes = 512 * 1024;
const sessionstartTruncatedMarker =
  "\n\nOMP SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";

function runSessionstartHook(source: string): Promise<string> {
  const { promise, resolve: resolveResult } = Promise.withResolvers<string>();
  const child = spawn(`${root}/bin/fm-sessionstart-run.sh`, ["--source", source], {
    stdio: ["ignore", "pipe", "ignore"],
  });
  const chunks: Buffer[] = [];
  let retainedBytes = 0;
  let truncated = false;
  child.stdout.on("data", (chunk: Buffer) => {
    if (retainedBytes >= sessionstartDeliveryBytes) {
      truncated = true;
      return;
    }
    const remaining = sessionstartDeliveryBytes - retainedBytes;
    const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
    chunks.push(retained);
    retainedBytes += retained.length;
    if (retained.length !== chunk.length) truncated = true;
  });
  child.on("error", () => resolveResult(""));
  child.on("close", (code) => {
    if (code !== 0) {
      resolveResult("");
      return;
    }
    const raw = Buffer.concat(chunks).toString("utf8").trim();
    resolveResult(truncated ? `${raw}${sessionstartTruncatedMarker}` : raw);
  });
  return promise;
}

// bin/fm-operational-input.sh is the ONE owner of the operational envelope, and
// the .pi extension lib is only a spawnSync wrapper around it. Call the owner
// directly rather than importing across adapter roots: omp auto-discovers
// .omp/extensions/ as a self-contained root, so a static import reaching into
// .pi/extensions/ would make omp's turn-end backstop fail to load anywhere that
// root is materialized on its own.
// `kind` exits nonzero on text that is not current operational input, which is
// how "already encoded" is distinguished from "needs encoding".
function operationalInput(command: "kind" | "encode", body: string, kind?: string): string | undefined {
  const args = command === "encode" ? [command, kind ?? ""] : [command];
  const result = spawnSync(`${root}/bin/fm-operational-input.sh`, args, {
    encoding: "utf8",
    input: body,
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) return undefined;
  return result.stdout;
}

async function injectSessionstart(pi: ExtensionAPI, source: string): Promise<void> {
  const raw = await runSessionstartHook(source);
  if (!raw) return;
  try {
    // Like Pi, omp injects a MESSAGE rather than hook stdout, so whatever it
    // injects must carry operational provenance or the Ahoy skill would have to
    // guess whether it was captain-authored. The wrapper already returns an
    // encoded nudge on a context-preserving open, so only an unencoded digest
    // needs the marker added here. An encoder that cannot run sends NOTHING
    // rather than unmarked text, because unmarked text reads as captain-authored.
    let content: string | undefined = raw;
    if (!operationalInput("kind", raw)) {
      content = operationalInput("encode", raw, "session-start");
    }
    if (content === undefined) return;
    pi.sendMessage({
      customType: "firstmate-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    });
  } catch {
  }
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  const { promise, resolve: resolveResult } = Promise.withResolvers<{ code: number; stderr: string }>();
  const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
    stdio: ["pipe", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  child.stdin.on("error", () => {});
  child.on("error", () => resolveResult({ code: 0, stderr: "" }));
  child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  child.stdin.end('{"stop_hook_active":false}');
  return promise;
}

// omp exposes Pi's tool_call API and honors {block: true} before bash
// execution - verified on 16.4.8 and unchanged on 17.2.2. Both shared checkers
// own their own decisions and fail open when unavailable; this extension owns
// only the harness transport.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  const { promise, resolve: resolveResult } = Promise.withResolvers<{ code: number; stderr: string }>();
  const child = spawn(`${root}/bin/${script}`, ["--command", command], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  child.on("error", () => resolveResult({ code: 0, stderr: "" }));
  child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  return promise;
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", async (event) => {
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const source = { startup: "startup", new: "clear", resume: "resume" }[reason];
    markLoaded();
    if (!source) return;
    await injectSessionstart(pi, source);
  });

  // omp's compaction equivalent. The digest is what a compacted session has just
  // lost, so re-emitting it here is the point rather than a side effect.
  pi.on?.("session_compact", async () => {
    await injectSessionstart(pi, "compact");
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("session_stop", async () => {
    if (forcedThisEpisode) {
      forcedThisEpisode = false;
      return;
    }

    const result = await runGuard();
    if (result.code !== 2) return;

    forcedThisEpisode = true;
    return {
      continue: true,
      additionalContext:
        "TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.\n\n" +
        result.stderr,
    };
  });

  markLoaded();
}
