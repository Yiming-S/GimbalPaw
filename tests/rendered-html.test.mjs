import assert from "node:assert/strict";
import { access, readdir } from "node:fs/promises";
import test from "node:test";
import { buildRotationMessage, toHex } from "../app/om3-protocol.ts";

const templateRoot = new URL("../", import.meta.url);

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("https://om3-lab.example/", {
      headers: {
        accept: "text/html",
        host: "om3-lab.example",
        "x-forwarded-host": "om3-lab.example",
        "x-forwarded-proto": "https",
      },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the OM3 test console", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<html lang="zh-CN">/);
  assert.match(html, /<title>OM3 Lab · Mac mini 联调台<\/title>/);
  assert.match(html, /先证明控制链路/);
  assert.match(html, /扫描并连接 OM3/);
  assert.match(html, /负载已配平/);
  assert.match(html, /FFF0 服务、FFF4 通知和 FFF5 写入/);
  assert.match(html, /https:\/\/om3-lab\.example\/og\.png/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape/);
});

test("encodes the known OM3 relative yaw test frame", () => {
  const frame = buildRotationMessage({ yaw: 50, pitch: 0, time: 10 });
  assert.equal(frame.byteLength, 21);
  assert.equal(
    toHex(frame),
    "55 15 04 a9 02 04 01 00 00 04 14 32 00 00 00 00 00 04 0a 39 cd",
  );
});

test("removes the disposable preview and ships the social card", async () => {
  const previewFiles = await readdir(new URL("../app/_sites-preview/", import.meta.url));
  assert.deepEqual(previewFiles, []);
  await access(new URL("../public/og.png", import.meta.url));
  await assert.rejects(access(new URL("public/_sites-preview", templateRoot)));
});
