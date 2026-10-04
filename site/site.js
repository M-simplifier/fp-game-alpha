"use strict";

const brief = document.querySelector("#game-brief");
const target = document.querySelector("#game-target");
const promptBox = document.querySelector("#ai-prompt");
const status = document.querySelector("#copy-status");

function updatePrompt() {
  promptBox.value = `fp-game-alphaを使って、次のゲームを作ってください。

https://github.com/M-simplifier/fp-game-alpha

企画：${brief.value.trim() || "［ここに作りたいゲームを書く］"}
遊ぶ環境：${target.value.trim() || "相談して決めたい"}

最初に公開リポジトリを取得し、参照コミットを記録してください。README.md、docs/purpose.md、.agents/skills/new-game/SKILL.mdと、そこから必要になる資料を読んでください。スキルを呼び出せる環境では $new-game を使ってください。

「壊れないゲーム開発」を目指し、このゲームで守るルールを明確にして、Haskellの型・純粋関数・適切な検証へ落としてください。単に参考ゲームを改名するのではなく、企画に合うゲームを設計してください。

独立したゲームの保存先と必要な実行環境を確認し、企画と守るルールをGAME-SPEC.mdに整理してください。指定した環境で最初の意味のある一場面を実装して動かし、遊んだ結果から変更して再確認してください。既存の編集を保ち、次のAIセッションでも使える継続案内を残してください。分からないことは、ゲームの意味や必要な準備を左右するものに絞って確認してください。

Haskellの経験を前提にせず、作ったルールと確かめたことを具体的に説明してください。実行できたことと未確認のことを分けて報告してください。`;
}
brief.addEventListener("input", updatePrompt);
target.addEventListener("input", updatePrompt);
updatePrompt();

document.querySelector("#brief-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  updatePrompt();
  try {
    await navigator.clipboard.writeText(promptBox.value);
    status.textContent = "コピーしました。AIとの会話に貼り付けて、制作を始めてください。";
  } catch {
    document.querySelector("#prompt-details").open = true;
    promptBox.focus();
    promptBox.select();
    status.textContent = "自動コピーが使えませんでした。選択された内容を手動でコピーしてください。";
  }
});
// Enable only after the handler is installed. Unnamed fields also keep a
// JavaScript-free native submission from sending the reader's brief in a URL.
document.querySelector("#copy-brief").disabled = false;

const traceStages = [
  { label: "最初の状態", title: "1件目の依頼を待っています", command: "起動", description: "「各駅便で届ける」という、1件目への操作を送ります。", next: "1件目を届ける →" },
  { label: "操作を受け付けました", title: "配達を終えて、2件目へ", command: "act 1 local", description: "体力を1使い、届いた気持ちが1増えました。ここで、前の手番を指す同じ操作をもう一度送ります。", next: "同じ操作をもう一度送る →" },
  { label: "古い手番の操作を拒否しました", title: "2件目の状態を保ちます", command: "act 1 local", description: "操作が指すのは1件目。現在の手番は2なので拒否します。体力も、届いた気持ちも変わりません。", next: "3件の記録を確認しました" }
];
let packets = null;
let traceIndex = 0;
const nextButton = document.querySelector("#trace-next");
const resetButton = document.querySelector("#trace-reset");

function showTrace() {
  const stage = traceStages[traceIndex];
  const packet = packets[traceIndex];
  document.querySelector("#trace-count").textContent = `${traceIndex + 1} / 3`;
  for (const field of ["label", "title", "command", "description"]) {
    document.querySelector(`#trace-${field}`).textContent = stage[field];
  }
  document.querySelector("#trace-energy").textContent = packet.resources.energy;
  document.querySelector("#trace-turn").textContent = packet.turn;
  document.querySelector("#trace-delivered").textContent = packet.resources.delivered;
  nextButton.textContent = stage.next;
  nextButton.disabled = traceIndex === 2;
}
nextButton.disabled = true;
resetButton.disabled = true;
fetch("evidence/station-trace.json")
  .then(response => {
    if (!response.ok) throw new Error("Trace is unavailable");
    return response.json();
  })
  .then(trace => {
    packets = trace.packets;
    if (!Array.isArray(packets) || packets.length !== 3) throw new Error("Invalid trace");
    showTrace();
    resetButton.disabled = false;
  })
  .catch(() => {
    document.querySelector("#trace-description").textContent = "記録を読み込めませんでした。元の応答と参照版のリンクから確認できます。";
  });
nextButton.addEventListener("click", () => {
  if (packets && traceIndex < 2) { traceIndex += 1; showTrace(); }
});
resetButton.addEventListener("click", () => {
  if (packets) { traceIndex = 0; showTrace(); }
});
