(() => {
  "use strict";

  const form = document.querySelector("#research-filters");
  const query = document.querySelector("#research-search");
  const topic = document.querySelector("#research-topic");
  const status = document.querySelector("#research-status");
  const count = document.querySelector("#research-count");
  const empty = document.querySelector("#research-empty");
  const entries = [...document.querySelectorAll(".catalog-entry")];
  if (!form || !query || !topic || !status || !count || !empty) return;

  const normalize = (text) => text.normalize("NFKC").toLocaleLowerCase("ja");
  const text = new Map(entries.map((entry) => [entry, normalize(entry.textContent)]));
  const parameters = new URLSearchParams(window.location.search);
  query.value = parameters.get("q") || "";
  for (const [control, name] of [[topic, "topic"], [status, "status"]]) {
    const value = parameters.get(name) || "";
    if ([...control.options].some((option) => option.value === value)) control.value = value;
  }

  function filter() {
    const words = normalize(query.value).trim().split(/\s+/u).filter(Boolean);
    let shown = 0;
    for (const entry of entries) {
      const matches = (!topic.value || entry.dataset.topics.split(" ").includes(topic.value))
        && (!status.value || entry.dataset.status === status.value)
        && words.every((word) => text.get(entry).includes(word));
      entry.hidden = !matches;
      if (matches) shown += 1;
    }
    count.textContent = `${entries.length}件中 ${shown}件の項目`;
    empty.hidden = shown !== 0;
    const state = new URLSearchParams();
    for (const [name, value] of [["q", query.value.trim()], ["topic", topic.value], ["status", status.value]]) {
      if (value) state.set(name, value);
    }
    const search = state.toString();
    try {
      window.history.replaceState(null, "", window.location.pathname + (search ? `?${search}` : "") + window.location.hash);
    } catch {
      // Downloaded file copies can filter even when their browser forbids URL updates.
    }
  }

  form.addEventListener("submit", (event) => event.preventDefault());
  form.addEventListener("input", filter);
  form.addEventListener("change", filter);
  form.addEventListener("reset", () => {
    query.value = "";
    topic.value = "";
    status.value = "";
    filter();
  });
  form.hidden = false;
  filter();
})();
