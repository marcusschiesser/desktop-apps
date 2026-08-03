import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const app = await readFile(new URL("../app.zon", import.meta.url), "utf8");
const prompt = await readFile(new URL("../PROMPT.md", import.meta.url), "utf8");
const readme = await readFile(new URL("../README.md", import.meta.url), "utf8");

assert.match(app, /com\.marcusschiesser\.flowdictation/);
assert.match(app, /"microphone"/);
assert.match(prompt, /Marcus Schiesser/);
assert.match(prompt, /vercel-labs\/native/);
assert.match(readme, /canivibecodeit\.com\/wispr-flow/);

console.log("repository metadata tests passed");
