// Guard a Firstmate Pi rollover until the fresh worker acknowledges the exact capsule generation.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const task = process.env.FM_ROLLOVER_TASK ?? "";
const generation = process.env.FM_ROLLOVER_GENERATION ?? "";
const capsulePath = process.env.FM_ROLLOVER_CAPSULE ?? "";
const expectedCapsuleSha = process.env.FM_ROLLOVER_CAPSULE_SHA ?? "";
const state = process.env.FM_ROLLOVER_STATE ?? "";
const livePath = `${state}/${task}.rollover-live`;
const ackPath = `${state}/${task}.rollover-ack`;

type Capsule = {
  schema: string;
  task: string;
  generation: number;
  objective_sha256: string;
};

function sha256(bytes: string): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function capsule(): { value: Capsule; bytes: string } {
  const bytes = readFileSync(capsulePath, "utf8");
  if (sha256(bytes) !== expectedCapsuleSha) throw new Error("capsule bytes do not match the launch-bound digest");
  const value = JSON.parse(bytes) as Capsule;
  if (value.schema !== "fm-rollover-capsule.v1" || value.task !== task || String(value.generation) !== generation) {
    throw new Error("capsule identity or generation mismatch");
  }
  if (!/^[a-f0-9]{64}$/.test(value.objective_sha256)) throw new Error("capsule objective digest is invalid");
  return { value, bytes };
}

function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, content, { mode: 0o600 });
  renameSync(tmp, path);
}

function acknowledged(): boolean {
  try {
    const line = readFileSync(ackPath, "utf8").trim();
    return line === `${generation}\t${expectedCapsuleSha}\t${process.pid}`;
  } catch {
    return false;
  }
}

export default function (pi: ExtensionAPI) {
  let valid = false;
  let objectiveSha = "";
  try {
    const current = capsule();
    objectiveSha = current.value.objective_sha256;
    valid = true;
    atomicWrite(livePath, `${generation}\t${expectedCapsuleSha}\t${process.pid}\n`);
  } catch {
    valid = false;
  }

  pi.registerTool?.({
    name: "fm_rollover_ack",
    label: "Acknowledge current objective",
    description: "Acknowledge the exact Firstmate rollover generation and current-objective digest before using any other tool.",
    parameters: Type.Object({
      generation: Type.Integer(),
      objective_sha256: Type.String(),
    }),
    execute: async (_toolCallId, params) => {
      if (!valid) throw new Error("rollover capsule validation failed; no action is permitted");
      const input = params as { generation: number; objective_sha256: string };
      if (String(input.generation) !== generation || input.objective_sha256 !== objectiveSha) {
        throw new Error("rollover acknowledgment does not match the current capsule generation/objective");
      }
      if (!acknowledged()) atomicWrite(ackPath, `${generation}\t${expectedCapsuleSha}\t${process.pid}\n`);
      return {
        content: [{ type: "text", text: `acknowledged rollover generation ${generation}; superseded instructions remain inactive` }],
        details: { generation: Number(generation), objective_sha256: objectiveSha },
      };
    },
  });

  pi.on("tool_call", (event) => {
    if (event.type !== "tool_call" || event.toolName === "fm_rollover_ack") return {};
    if (!valid) return { block: true, reason: "rollover capsule validation failed; stop without acting" };
    if (!acknowledged()) {
      return { block: true, reason: `acknowledge rollover generation ${generation} with fm_rollover_ack before any other tool` };
    }
    return {};
  });
}
