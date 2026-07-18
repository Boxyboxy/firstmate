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

function runSessionstartNudge(): string {
  const result = spawnSync(`${root}/bin/fm-sessionstart-nudge.sh`, [], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
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

// omp 16.4.8 exposes Pi's tool_call API and honors {block: true} before bash
// execution. Both shared checkers own their own decisions and fail open when
// unavailable; this extension owns only the harness transport.
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
  pi.on?.("session_start", (event) => {
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const nudge = ["startup", "new", "resume"].includes(reason) ? runSessionstartNudge() : "";
    markLoaded();
    if (!nudge) return;
    try {
      pi.sendMessage({ customType: "firstmate-sessionstart-nudge", content: nudge, display: false });
    } catch {
    }
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
