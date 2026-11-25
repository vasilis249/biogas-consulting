#!/usr/bin/env node
// Builds demo/index.html = the real app (../index.html) wired to the in-memory
// mock Supabase client (demo/mock.js). No backend, no keys.
//   node demo/build.js
"use strict";
const fs = require("fs"), path = require("path");
const root = path.join(__dirname, "..");
let html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const mock = fs.readFileSync(path.join(__dirname, "mock.js"), "utf8");
const red3 = fs.readFileSync(path.join(root, "lib", "red3.js"), "utf8");

function replaceOnce(from, to, what) {
  const n = typeof from === "string" ? html.split(from).length - 1 : (html.match(from) || []).length;
  if (n !== 1) throw new Error(`demo build: expected exactly one ${what}, found ${n}`);
  html = html.replace(from, to);
}
// the real supabase-js is replaced by the mock (xlsx stays: Excel export works in the demo)
replaceOnce(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@[^"]+"><\/script>\n?/, "", "supabase-js <script>");
// lib/red3.js is a sibling of index.html in the repo but not of demo/index.html,
// so inline it (the file stays the single source of truth for the unit tests).
replaceOnce('<script src="lib/red3.js"></script>', `<script>\n${red3}\n</script>`, "red3 <script>");
replaceOnce('const HARDCODED_URL = "";', 'const HARDCODED_URL = "demo://local";', "HARDCODED_URL");
replaceOnce('const HARDCODED_KEY = "";', 'const HARDCODED_KEY = "demo-anon-key";', "HARDCODED_KEY");
replaceOnce(/<title>[^<]*<\/title>/, "<title>BioGas — DEMO</title>", "<title>");
replaceOnce("<body>", `<body>
<div style="position:fixed;bottom:12px;right:12px;z-index:90;background:#b5663f;color:#fff;font:700 12px/1 -apple-system,Segoe UI,Roboto,sans-serif;padding:7px 11px;border-radius:999px;box-shadow:0 4px 14px rgba(0,0,0,.18)" title="Δεδομένα επίδειξης στη μνήμη — επαναφορά με refresh">DEMO · δεδομένα επίδειξης</div>`, "<body>");
const idx = html.lastIndexOf("<script>");          // the app script is the last one
if (idx < 0) throw new Error("demo build: app <script> not found");
html = html.slice(0, idx) + "<script>\n" + mock + "\n</script>\n" + html.slice(idx);

fs.writeFileSync(path.join(__dirname, "index.html"), html);
console.log(`demo/index.html built (${(html.length / 1024).toFixed(0)} KB)`);
