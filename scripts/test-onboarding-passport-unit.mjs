#!/usr/bin/env node
/**
 * Unit tests: init/setup Passport field formatting (no Podman).
 *
 * Run: node scripts/test-onboarding-passport-unit.mjs
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createTally, reportFinding } from "./lib-test-report.mjs";

const tally = createTally();
const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

function runCase(surface, fn) {
  try {
    fn();
    tally.add(reportFinding(surface, true));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    tally.add(reportFinding(surface, false, msg));
  }
}

function bashLib(script, env = {}) {
  const result = spawnSync(
    "bash",
    ["-c", `source "${repoRoot}/scripts/lib.sh"\n${script}`],
    {
      encoding: "utf8",
      env: { ...process.env, ...env },
    },
  );
  if (result.status !== 0) {
    throw new Error(
      `bash exited ${result.status}: ${(result.stderr || result.stdout || "").trim()}`,
    );
  }
  return (result.stdout || "").trim();
}

process.stdout.write("Onboarding Passport fields (unit)\n\n");

runCase("identyclaw.sh usage lists init and setup", () => {
  const src = readFileSync(join(repoRoot, "identyclaw.sh"), "utf8");
  assert.match(src, /cmd_init\(\)/);
  assert.match(src, /cmd_setup\(\)/);
  assert.match(src, /setup\) cmd_setup/);
  assert.match(src, /last: auto NEAR enroll/);
});

runCase("init no longer enrolls Passport; setup does", () => {
  const src = readFileSync(join(repoRoot, "identyclaw.sh"), "utf8");
  const initBlock = src.slice(src.indexOf("cmd_init()"), src.indexOf("cmd_setup()"));
  assert.equal(initBlock.includes("idcp_setup_one_agent"), false);
  assert.equal(initBlock.includes("ensure_app_layout"), true);
  const setupBlock = src.slice(src.indexOf("cmd_setup()"), src.indexOf("cmd_idcp_setup()"));
  assert.equal(setupBlock.includes("init_agent_from_env"), true);
  assert.equal(setupBlock.includes("idcp_setup_one_agent"), true);
  assert.equal(setupBlock.includes("setup_collect_passport_fields_one"), true);
});

runCase("identyclaw_format_contact_uri prefers explicit then telegram then email", () => {
  const explicit = bashLib(`identyclaw_format_contact_uri "telegram:telegram.com:@ops" "OtherBot" "a@identyclaw.com"`);
  const telegram = bashLib(`identyclaw_format_contact_uri "" "MyBot" "a@identyclaw.com"`);
  const email = bashLib(`identyclaw_format_contact_uri "" "" "agent-a@identyclaw.com"`);
  const empty = bashLib(`identyclaw_format_contact_uri "" "" ""; printf 'EMPTY'`);
  assert.equal(explicit, "telegram:telegram.com:@ops");
  assert.equal(telegram, "telegram:telegram.com:@MyBot");
  assert.equal(email, "email:identyclaw.com:agent-a@identyclaw.com");
  assert.equal(empty, "EMPTY");
});

runCase("print_passport_field marks selected vs collect", () => {
  const out = bashLib(`
print_passport_field "Avatar image URL" "https://example.com/a.png" "hint"
print_passport_field "ContactURI" "" "scheme:authority:identifier"
print_passport_webhook_field "A2A / webhook URL" "https://agent-a.identyclaw.com:8443"
print_passport_webhook_field "A2A / webhook URL" "http://127.0.0.1:18789"
`);
  assert.match(out, /Avatar image URL\s+\[selected\]\s+https:\/\/example.com\/a\.png/);
  assert.match(out, /ContactURI\s+\[collect\]\s+scheme:authority:identifier/);
  assert.match(out, /A2A \/ webhook URL\s+\[selected\]\s+https:\/\/agent-a\.identyclaw.com:8443/);
  assert.match(out, /\[collect\].*127\.0\.0\.1/);
});

runCase("print_passport_purchase_guide lists recipient and selected fields", () => {
  const out = bashLib(`
print_passport_purchase_guide \\
  abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \\
  "https://agent-a.identyclaw.com:8443" \\
  "https://identyclaw.com/avatar.png" \\
  "email:identyclaw.com:agent-a@identyclaw.com" \\
  agent-a
`);
  assert.match(out, /purchase\.identyclaw\.com/);
  assert.match(out, /abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789/);
  assert.match(out, /\[selected\].*https:\/\/agent-a\.identyclaw.com:8443/);
  assert.match(out, /\[selected\].*https:\/\/identyclaw.com\/avatar.png/);
  assert.match(out, /\[selected\].*email:identyclaw.com:agent-a@identyclaw.com/);
});

tally.printSummary("Onboarding passport unit");
process.exit(tally.exitCode());
