#!/usr/bin/env bash
# Behavior and tracked-registration tests for the native session-start nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-nudge)
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
NUDGE_TEXT="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."
fm_operational_input_encode session-start "$NUDGE_TEXT" NUDGE_LINE \
  || fail "could not construct expected session-start nudge"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out prefix_hex status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a3 ] || fail "genuine primary nudge lost its U+2063 operational marker: $prefix_hex"
  pass "fm-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.fm-secondmate-home"
  expect_silent_zero "gate common-dir nudge" env FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$root" fm/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_secondmate_primary_nudges() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked secondmate nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked secondmate printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a marked linked secondmate home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran"
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "owned lock nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a lock holder in process ancestry is already run"
}

test_opencode_plugin_delivers_exact_nudge_once() {
  local root="$TMP_ROOT/opencode-primary" out status=0
  make_primary "$root"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$root/bin/"
  chmod +x "$root/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    WORKTREE="$root" EXPECTED="$NUDGE_LINE" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimarySessionstartNudge({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = {
  type: "session.created",
  properties: { sessionID: "session-nudge-test", info: { id: "session-nudge-test" } },
};
await hooks.event({ event });
await hooks.event({ event });
if (prompts.length !== 1) throw new Error(`expected one prompt, got ${prompts.length}`);
if (prompts[0] !== process.env.EXPECTED) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
  ) || status=$?
  expect_code 0 "$status" "OpenCode exact nudge delivery"
  [ -z "$out" ] || fail "OpenCode exact nudge delivery printed output: $out"
  pass "OpenCode session.created delivers the exact wrapper nudge once per session"
}

# The hook-config harnesses (claude, codex, grok) register the wrapper through a
# tracked JSON hook whose registration - matcher, count, and invoked command - is
# the observable contract, so it is asserted through jq on the config itself.
# The extension/plugin harnesses (opencode, pi, pi-signed, omp) are covered by
# driving the tracked adapter and observing what it delivers.
test_hook_config_harness_registration() {
  local command
  jq -e '.hooks.SessionStart | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude SessionStart hook is not registered exactly once"
  jq -e '.hooks.SessionStart[0].matcher == "startup|resume|clear"' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude SessionStart matcher must include startup/resume/clear and exclude compact"
  jq -e 'any(.hooks.SessionStart[]?.hooks[]?.command?; contains("fm-sessionstart-nudge.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null || fail "Claude SessionStart hook does not invoke the wrapper"

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/.codex/hooks.json")
  assert_contains "$command" 'fm-sessionstart-nudge.sh' "Codex SessionStart hook does not invoke the wrapper"

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/.grok/hooks/fm-primary-sessionstart-nudge.json")
  assert_contains "$command" 'fm-sessionstart-nudge.sh' "Grok SessionStart hook does not invoke the wrapper"

  pass "the hook-config harnesses register the shared session-start nudge exactly once"
}

# omp has verified native session_start. Its tracked primary extension reuses the
# Pi-derived pi.sendMessage context injection, so the guarantee worth pinning is
# behavioral: for startup/new/resume it delivers exactly the wrapper's bytes as a
# non-displayed custom message, and for any other reason it delivers nothing.
test_omp_extension_delivers_exact_nudge_for_allowed_reasons() {
  local root ext out status=0
  root="$TMP_ROOT/omp-primary"
  ext="$root/.omp/extensions/fm-primary-turnend-guard.ts"
  make_primary "$root"
  mkdir -p "$root/.omp/extensions"
  git -C "$ROOT" ls-files --error-unmatch .omp/extensions/fm-primary-turnend-guard.ts >/dev/null 2>&1 \
    || fail "omp primary extension must be git-tracked so omp auto-discovers it"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$root/bin/"
  chmod +x "$root/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$ext" FM_HOME="$root" EXPECTED="$NUDGE_LINE" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const delivered = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  sendMessage(message) {
    delivered.push(message);
  },
  sendUserMessage(message) {
    delivered.push({ content: message, via: "sendUserMessage" });
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

const sessionStart = handlers.get("session_start");
if (!sessionStart) throw new Error("omp extension did not register a session_start handler");

for (const reason of ["startup", "new", "resume"]) {
  delivered.length = 0;
  await sessionStart({ type: "session_start", reason }, {});
  if (delivered.length !== 1) throw new Error(`reason ${reason} delivered ${delivered.length} messages`);
  const message = delivered[0];
  if (message.via) throw new Error(`reason ${reason} used the follow-up transport, not the context-safe one`);
  if (message.customType !== "firstmate-sessionstart-nudge") {
    throw new Error(`reason ${reason} lost the custom type: ${JSON.stringify(message)}`);
  }
  if (message.display !== false) throw new Error(`reason ${reason} displayed the operational nudge`);
  if (message.content !== process.env.EXPECTED) {
    throw new Error(`reason ${reason} delivered unexpected bytes: ${JSON.stringify(message.content)}`);
  }
}

for (const reason of ["compact", "clear", ""]) {
  delivered.length = 0;
  await sessionStart({ type: "session_start", reason }, {});
  if (delivered.length !== 0) throw new Error(`reason ${reason} is outside the allowlist but delivered a nudge`);
}
EOF
  ) || status=$?
  expect_code 0 "$status" "omp session_start nudge delivery"
  [ -z "$out" ] || fail "omp session_start nudge delivery printed output: $out"
  pass "omp session_start delivers the exact wrapper nudge for startup/new/resume only"
}

test_genuine_primary_nudges
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_secondmate_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_opencode_plugin_delivers_exact_nudge_once
test_hook_config_harness_registration
test_omp_extension_delivers_exact_nudge_for_allowed_reasons
