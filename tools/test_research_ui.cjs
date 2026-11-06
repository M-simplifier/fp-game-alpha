"use strict";

// Execute the actual progressive-enhancement script with a small DOM fixture.
// Static/no-JS completeness and all real links are checked separately in Python.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function fixture(search = "") {
  const entry = (topics, status, textContent) => ({dataset: {topics, status}, textContent, hidden: false});
  const entries = [
    entry("rules-time assurance", "implemented", "保存 Save 入力の順番"),
    entry("graphics assurance", "historical", "保存の影とGPU"),
    entry("music", "question", "音楽 MUSIC 時間区間"),
  ];
  const events = {};
  const controls = {
    "#research-filters": {hidden: true, addEventListener: (name, handler) => { events[name] = handler; }},
    "#research-search": {value: ""},
    "#research-topic": {value: "", options: ["", "rules-time", "graphics", "music", "assurance"].map(value => ({value}))},
    "#research-status": {value: "", options: ["", "implemented", "historical", "question"].map(value => ({value}))},
    "#research-count": {textContent: ""},
    "#research-empty": {hidden: true},
  };
  let url;
  const context = {URLSearchParams, document: {
    querySelector: (selector) => controls[selector], querySelectorAll: () => entries,
  }, window: {
    location: {search, pathname: "/research.html", hash: ""},
    history: {replaceState: (_data, _unused, value) => { url = value; }},
  }};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../site/research.js"), "utf8"), context);
  return {entries, controls, events, url: () => url};
}

const initial = fixture("?topic=assurance&q=保存&status=implemented");
assert.equal(initial.controls["#research-filters"].hidden, false);
assert.deepEqual(initial.entries.map(entry => entry.hidden), [false, true, true]);
assert.equal(initial.controls["#research-count"].textContent, "3件中 1件の研究");
assert.match(initial.url(), /topic=assurance/);
initial.controls["#research-search"].value = "存在しない言葉";
initial.events.input();
assert.equal(initial.controls["#research-empty"].hidden, false);
assert.ok(initial.entries.every(entry => entry.hidden));
initial.events.reset();
assert.ok(initial.entries.every(entry => !entry.hidden));
assert.equal(initial.controls["#research-empty"].hidden, true);
assert.equal(initial.url(), "/research.html");
let prevented = false;
initial.events.submit({preventDefault: () => { prevented = true; }});
assert.equal(prevented, true);

const normalized = fixture("?q=ｍｕｓｉｃ&topic=unknown&status=unknown");
assert.deepEqual(normalized.entries.map(entry => entry.hidden), [true, true, false]);
assert.equal(normalized.controls["#research-topic"].value, "");
assert.equal(normalized.controls["#research-status"].value, "");
console.log("research filtering: PASS (query, topic/status intersection, Japanese/full-width search, no results, reset and no submission)");
