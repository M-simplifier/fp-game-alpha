# 出典、制作時の観察、残った仮説

2026-10-08編集。10月7日のRed Dune勉強会を、次のAI制作で使うために圧縮した。
制作に使う判断は[遊びの設計](design.md)と[画面と日本語](ui-and-japanese.md)に
置き、ここでは何を材料にし、どこまで確かめたかを残す。

## 根拠の種類を区別する

- **理論上の主張**：経験を考える枠組みや説明。個別機能の効果を実証した結果とは扱わない。
- **開発者の制作記録**：ある作品で何が問題になり、何を変えたか。別作品で同じ効果が出る保証ではない。
- **制作時の観察・検査**：画面、コード、再現操作、CIから確認・報告された範囲。人間の気持ちは決めない。
- **人間の試遊反応**：その人、その版、その期間での経験の証拠。長期の価値や一般的な成功へ広げない。
- **今後の仮説**：材料から導いた制作案。反例や次の観察で修正する。

例えば、実在庫を消費する住民がいること、その利用を本人が読み取ること、
その人や場所を大切に思うことは別々の主張である。順に自動的に成立すると
見なさない。

## 公開原典を今回読んだ範囲

各項目は本稿作成時の取得・読書範囲である。勉強会記録にある、より広い読了
範囲を自分の再読として数えていない。動画、全図表、参照された別論文や
現在のゲーム全仕様まで確認したという意味でもない。

| 出典 | 今回読んだ範囲と用途 |
| --- | --- |
| [Hunickeほか：MDA（2004）](https://cdn.aaai.org/Workshops/2004/WS-04-04/WS04-04-001.pdf) | 規則・実行時の関係・経験の定義と設計者／プレイヤーの視点（主に本文1–2頁）。設計の往復に使い、楽しさの公式にはしない。 |
| [Wardrip-Fruinほか：Agency Reconsidered（2009）](https://cs.uky.edu/~sgware/reading/papers/wardripfruin2009agency.pdf) | 要旨と導入。望む行為、可能な行為、モデルとUIの対応。9頁全文の再読や実験の追試はしていない。 |
| [Dan Cook：Value Chains（2021）](https://lostgarden.com/2021/12/12/value-chains/) | 導入のCozy Grove制作例と第一章の基本構造・入出力。採取の先の用途を試す理由。後半の数理分類や全図表は未確認。12か月は開発期間で、プレイヤー追跡期間ではない。 |
| [Factorio FFF261（2018）](https://www.factorio.com/blog/post/fff-261) | 導入二方式の欠点、局所エラー、関係する対象の強調。性能節や埋込動画を今回の設計根拠にはしていない。 |
| [Factorio FFF342（2020）](https://www.factorio.com/blog/post/fff-342) | 本文の情報経路の分担と、好反応だった導入の撤回理由。関連記事・動画は未読。 |
| [Factorio FFF399（2024）](https://www.factorio.com/blog/post/fff-399) | 初回試遊の反復問題と、混合出力の選別・余剰処理へ変えた経緯。動画と全図表は未確認。 |
| [Eremite Games：Hubs Update（2022）](https://eremitegames.com/hubs-update/) | Developer Notesと関連する住宅・Hearth・hubの変更。距離管理の不安という反例。全changelogの監査や実ゲーム試遊はしていない。 |
| [Xbox Accessibility Guideline 101](https://learn.microsoft.com/en-us/xbox/accessibility/xbox-accessibility-guidelines/101) | 文字表示の調整と実画面でのサイズ測定に関する取得本文。アクセシビリティの指針であり、好感や面白さの実験ではない。 |
| [文化庁：公用文作成の考え方（解説）](https://www.bunka.go.jp/seisaku/bunkashingikai/kokugo/hokoku/pdf/93731901_01.pdf) | 標題・見出し、文の書き方（冊子31–33頁／PDF43–45頁）。係り受け、論点、短文化の限界、受身の用途。公用文の形式をゲームへ強制しない。 |
| [SmartHR：伝わる文章](https://smarthr.design/basics/text/) | 読み手に応じた情報の選択、一文一義、主語、助詞、重複の修正例。ブランドの語彙・口調は採用しない。 |

[Zach Gageの講演本文](https://stfj.net/DesigningForSubwayLegibility/)の三段階の
読み方は、勉強会の整理を介して参照した。今回はWeb取得が失敗し、直接取得も
証明書の期限エラーで完了しなかった。原文を独立に再読したとは扱わない。
この構成案は試して改める指針として残す。

## 勉強会記録と既存の知識を読んだ範囲

共有brainの次の四文書を全文読んだ。非公開の研究・批評記録であり、原文を
ここへ転載せず、一般化できる制作判断と留保を自分の文で編集した。brainは
読み取りだけに使った。各文書内のPro回答へのリンクをすべて開いたわけでは
なく、それらの数値や結論を独立確認済みとして採用していない。

- `red-dune-game-design-study-2026-10-07.md`：公開理論、三企画、議論による修正、試作報告、原典の読了範囲。
- `red-dune-long-term-choice-study-2026-10-07.md`：最初の成功後の選択、反復、鑑賞、満足して終えることへの留保。
- `red-dune-pro-study-synthesis-2026-10-07.md`：研究回答を受けた批評と企画変更。一次資料を確認した箇所と、回答を介した整理の区別。
- `game-experience-design-hypotheses-2026-10-07.md`：操作から結果・次の意図、即興、手間、履歴、仮説を弱める観察。

既存の `clarify-reader-surface/SKILL.md`、`references/japanese-writing.md`、
`references/japanese-writing-research.md`を全文読んだ。具体的な行為から説明し、
自然な日本語へ戻しながら条件を保持する判断を編集した。私的な依頼文や
原文、未確認のLLM研究の効果量を公開したものではない。

このcheckoutの技能一覧を調べ、関連する
[new-game](https://github.com/M-simplifier/fp-game-alpha/blob/d398bc98437d425a0eff0524c66fc3fa2c19d775/.agents/skills/new-game/SKILL.md)、
[fp-gamedev](https://github.com/M-simplifier/fp-game-alpha/blob/d398bc98437d425a0eff0524c66fc3fa2c19d775/.agents/skills/fp-gamedev/SKILL.md)、
[play-game](https://github.com/M-simplifier/fp-game-alpha/blob/d398bc98437d425a0eff0524c66fc3fa2c19d775/.agents/skills/play-game/SKILL.md)と制作入口の文書を読んだ。
無関係なSKILL.mdは読み込んでいない。Codexの記憶要約には関連語の一致が
なく、今回の証拠として使用していない。

## Red Duneで起きたことと、まだ分からないこと

事例は[PR41](https://github.com/M-simplifier/fp-game-alpha/pull/41)の最終head
`c0c91abbdf46503739195e1dc630db39d32b6d98`に固定する。2026-10-08の確認時点で
PR41は未merge。以下はPR41の事例であり、今回の変更対象は文書とスキルである。

初回のフィードバックとして今回の依頼に提供されたのは、危機へ対処し続ける
より、安定した暮らしを自分から広げたいという希望だった。そこから、場所を
選ぶ、建設する、実際に料理が届く、既存住民が食べる、周りを飾るという
遊びへ変更した。配置を認めるだけでなく、選んだ場の実在庫と実利用まで
つないだ点が、この設計仮説を試す範囲だった。

固定headの[技術証拠](https://github.com/M-simplifier/fp-game-alpha/blob/c0c91abbdf46503739195e1dc630db39d32b6d98/references/red-dune-live/evidence/native-windows.json)
と[HELP本文](https://github.com/M-simplifier/fp-game-alpha/blob/c0c91abbdf46503739195e1dc630db39d32b6d98/references/red-dune-live/native/RedDune/Native/Help.hs)
を読んだ。次は前担当の検査記録であり、今回ゲームを再実行した結果ではない。

- 通常のUI経路を使う合成入力で、建設・配送・既存住民の実食と装飾の保存／再開を確認。短縮したドメイン試験と、標準規則の実機試行を分けて記録している。
- 七章HELP、単位付きの現在量／目標量、連続生産の停止と班解除、任意の再表示可能な案内を実装。HELPの75操作比較で完全なGameStateが一致し、読書後の時間の追いつきがないことを記録。後続の農場文言修正にも別の2比較がある。
- 元の試遊保存領域の21ファイルと既存実行物の保全を記録。一か所の食事の場、確定後の移設・取消なし、住民の通勤シミュレーションなし、装飾の生産ボーナスなしという制限もある。

固定headの[alpha CI](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37661486495)
と[Red Dune CI](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37661485721)
について、GitHubのcheck-runsで11件のsuccessと公開ページ配信1件のskipを
今回確認した。これは技術検査の結果であり、楽しさの合格数ではない。

その後、今回の文書化依頼に先立って、オーナーは最新版を試遊して高く評価
した。同時に文言とUIには改善の余地があると述べた。この反応の原文は
読み取りで確認し、公開向けに要約した。固定headの証拠ファイルに残る
「夜間HELP修正の試遊待ち」は、それ以前の検査時点の記録である。

今回の肯定的な反応は、その試遊で提供した体験がよかったという有効な証拠
である。ただし、どの変更がどれだけ効いたかを分離した比較実験ではなく、
長期の楽しさ、初見の全プレイヤー、別ジャンルでの成功を証明していない。
「望む場所へ実利用が返ると次の制作意欲が生まれる」は今後も試す仮説として
残す。後日の再訪や、景観より物流を選ぶ反例で判断を改める。

## 一つの技能と二つの資料にした理由

[game-experience](../../.agents/skills/game-experience/SKILL.md)は新規制作と
改良の両方から見つかる短い入口にした。楽しさだけ、ラベルだけを直す依頼
でも、現在の問題に応じて一つの資料から着手できる。
画面と日本語は同じ操作の意味を伝えるため一緒に置き、企画・進行・試遊の
判断は別資料へ分けた。出典はこの台帳で一元化した。

Red Duneの建設順、七章HELP、特定の数値を普遍的な手順にしない。
一般理論の名称一覧、全項目の採点、必須の試遊人数・時間を増やす代わりに、
適用条件、反例、判断を変える観察を残した。公開原典の文章、個人会話、
私的ノート、セーブそのものはこの資料に含めていない。
