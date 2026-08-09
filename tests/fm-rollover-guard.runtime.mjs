import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const scratch = await mkdtemp(join(tmpdir(), "fm-rollover-guard."));

async function exercise(harness) {
  const caseRoot = join(scratch, harness);
  const state = join(caseRoot, "state");
  const moduleRoot = join(caseRoot, "module");
  const capsulePath = join(caseRoot, "capsule.json");
  await mkdir(join(moduleRoot, "node_modules", "typebox"), { recursive: true });
  await mkdir(state, { recursive: true });
  await writeFile(join(moduleRoot, "package.json"), '{"type":"module"}\n');
  await writeFile(join(moduleRoot, "node_modules", "typebox", "package.json"), '{"type":"module","exports":"./index.js"}\n');
  await writeFile(
    join(moduleRoot, "node_modules", "typebox", "index.js"),
    "export const Type = { Object: value => value, Integer: () => ({}), String: () => ({}) };\n",
  );
  const guardPath = join(moduleRoot, "fm-rollover-guard.ts");
  await cp(new URL("../.pi/extensions/fm-rollover-guard.ts", import.meta.url), guardPath);

  const capsule = {
    schema: "fm-rollover-capsule.v1",
    task: "task",
    generation: 7,
    objective_sha256: createHash("sha256").update("Bounded objective").digest("hex"),
  };
  const bytes = `${JSON.stringify(capsule)}\n`;
  const capsuleSha = createHash("sha256").update(bytes).digest("hex");
  await writeFile(capsulePath, bytes);
  Object.assign(process.env, {
    FM_ROLLOVER_TASK: "task",
    FM_ROLLOVER_GENERATION: "7",
    FM_ROLLOVER_CAPSULE: capsulePath,
    FM_ROLLOVER_CAPSULE_SHA: capsuleSha,
    FM_ROLLOVER_STATE: state,
    FM_PI_HARNESS: harness,
  });

  let ackTool;
  let toolCallHandler;
  const pi = {
    registerTool(tool) { ackTool = tool; },
    on(event, handler) {
      assert.equal(event, "tool_call");
      toolCallHandler = handler;
    },
  };
  const loaded = await import(`${pathToFileURL(guardPath).href}?harness=${harness}`);
  loaded.default(pi);
  assert.ok(ackTool, `${harness}: acknowledgment tool was not registered`);
  assert.ok(toolCallHandler, `${harness}: pre-tool handler was not registered`);

  const livePath = join(state, "task.rollover-live");
  const finalizedPath = join(state, "task.rollover-finalized");
  const ackPath = join(state, "task.rollover-ack");
  const live = await readFile(livePath, "utf8");
  assert.match(toolCallHandler({ type: "tool_call", toolName: "bash" }).reason, /operator finalization is invalid/);
  await assert.rejects(
    ackTool.execute("call-1", { generation: 7, objective_sha256: capsule.objective_sha256 }),
    /not operator-finalized/,
  );

  await writeFile(finalizedPath, live);
  assert.match(toolCallHandler({ type: "tool_call", toolName: "bash" }).reason, /acknowledge rollover generation 7/);
  await assert.rejects(
    ackTool.execute("call-2", { generation: 6, objective_sha256: capsule.objective_sha256 }),
    /does not match/,
  );
  await assert.rejects(readFile(ackPath, "utf8"), /ENOENT/);

  const result = await ackTool.execute("call-3", { generation: 7, objective_sha256: capsule.objective_sha256 });
  assert.equal(result.details.generation, 7);
  assert.deepEqual(toolCallHandler({ type: "tool_call", toolName: "bash" }), {});
  assert.equal(await readFile(ackPath, "utf8"), live);

  await writeFile(finalizedPath, `8\t${capsuleSha}\t${process.pid}\t${harness}\n`);
  assert.match(toolCallHandler({ type: "tool_call", toolName: "bash" }).reason, /operator finalization is invalid/);
}

try {
  await exercise("pi");
  await exercise("pi-signed");
  console.log("ok - Pi and pi-signed runtime guards block every tool until exact finalized generation acknowledgment");
} finally {
  await rm(scratch, { recursive: true, force: true });
}
