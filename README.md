# fp-game-alpha

**ゲーム開発研究の公開リファレンス。**

[研究の全体像](https://m-simplifier.github.io/fp-game-alpha/) ·
[主題から調べる](https://m-simplifier.github.io/fp-game-alpha/research.html) ·
[考え方を読む](https://m-simplifier.github.io/fp-game-alpha/guide.html) ·
[AIとゲームを作る](https://m-simplifier.github.io/fp-game-alpha/create.html)

ゲームのルールをどう表すか。広がる世界や音楽をどう生成するか。
作ったものを何で確かめるか。このリポジトリは、純粋関数型ゲームの研究を
出発点に、描画、自然物、音楽、論理指向、配列指向、合成の理論へと広がった
知見・実装・教材を集め、問いから辿れる形に整理しています。

具体的なゲームライブラリ・エンジン・システムが確立するまで、研究の蓄積と
その時点の最前線を参照できる場所として育てます。作例は、実際に動く成果で
あると同時に、設計を試して限界を知るための研究資料です。
[この場所の役割](docs/purpose.md)と[収録範囲](research/coverage.md)も参照してください。

## 調べたいことから読む

| 問い | 主な入口 |
| --- | --- |
| 状態、入力、時間、参加者をどう扱うか | [遷移とArena](docs/architecture.md)、[時間と状態](docs/practice/games/time-and-state.md) |
| 地形や自然物を生成し、同じ場所を再現するには | [Stillroomの風景と描画](research/stillroom/landscapes-and-graphics.md) |
| Haskellの形状からGPUの画面まで、何を一致させるか | [Stillroom研究](research/stillroom/README.md)、[空間と資源](docs/practice/games/space-and-resources.md) |
| 音楽を続けながら、時間・音・処理量をどう扱うか | [音楽と時間](research/stillroom/music-and-time.md) |
| 同じゲームを関数・配列・関係として捉えると何が変わるか | [三つのテトリスと新しい定式化](research/frontiers/README.md) |
| Freeモナドや圏論は、何を新しく記述・検査できるか | [解釈と合成の研究](research/frontiers/composition.md) |
| 型・テスト・形式手法・実機確認は、何を確かめるか | [保証の範囲](docs/guarantees.md)、[検証の実践](docs/practice/haskell/verification-review.md) |
| AIと作る手順、可読性、操作や体験をどう改善するか | [制作手順](docs/new-game.md)、[Haskellの読みやすさ](docs/haskell.md)、[ゲーム体験](docs/game-experience/design.md) |

[研究目録](research/catalog.json)には、主題、説明、実装への入口、確認した結果と
限界をまとめています。[ブラウザ版](https://m-simplifier.github.io/fp-game-alpha/research.html)
では検索・絞り込みができます。[研究案内](research/README.md)には読む順路を置いています。

## 実装と教材

純粋な遷移と参加者の観測を扱う小さなライブラリは、
[Game.Transition](libraries/game-transition/src/Game/Transition.hs) と
[Game.Arena](libraries/game-arena/src/Game/Arena.hs) にあります。
[Station](references/station/README.md)、[Lantern](references/lantern/README.md)、
[Garden](references/garden/README.md)、[Tapline](references/tapline/README.md)、
[River](references/river/README.md)、[Paper Circuit](references/paper-circuit/README.md)、
[Signal Courier](references/signal-courier/README.md)、
[Afterlight](references/afterlight/README.md)、[Red Dune](references/red-dune/README.md)
は、異なるゲームでそれらの設計を読む作例です。

続く研究では、[Haskell](references/pure-fall/README.md)、
[APL](references/apl-fall/README.md)、[Prolog](references/prolog-fall/README.md)
による独立したテトリスを収録しています。ルールと検証範囲は各作例に記し、
同一仕様による言語性能比較とはしていません。
[Stillroom](https://github.com/M-simplifier/stillroom)は、風景・描画・音楽の
実装を所有する別の公開作品です。ここから、版を指定したソースと研究解説へ進めます。

人間向けには、[Stationの一件の配達](https://m-simplifier.github.io/fp-game-alpha/learn.html)、
[APLの配列](https://m-simplifier.github.io/fp-game-alpha/studies/array-fall.html)、
[Prologの問い](https://m-simplifier.github.io/fp-game-alpha/studies/prolog-fall.html)、
[Freeモナド](https://m-simplifier.github.io/fp-game-alpha/studies/free-monad.html)
など、コードや操作図から考え方を追う教材があります。

## 自分のゲームに使う

このリポジトリを取得し、ファイルを読んで編集・実行できるAIへ、作りたい
ゲームと実行環境を伝えて [new-game](.agents/skills/new-game/SKILL.md) を渡してください。
`$new-game` を認識する環境ではその名前で呼べます。Haskell経験は必須ではありません。

研究を調べたり比較したいときは [game-research](.agents/skills/game-research/SKILL.md)、
自分のゲームの実コードを読みたいときは [learn-code](.agents/skills/learn-code/SKILL.md)
を使えます。作例の世界観や未確定の理論を、新作の仕様として自動採用することはありません。
小さな端末ゲームを試す [starter](docs/terminal-starter.md) も残しています。

## 出典、検証、更新

実装の事実はソース、検査の結果は実際に行った検査を正本とします。
教材はその理由や意味を説明します。製品での実装、有限の実験、未解決の問いを
区別し、新しい成果が出たら目録と関連する案内を更新します。
[更新の考え方](docs/roadmap.md)と[検証手順](docs/verification.md)を参照してください。

公開ソースの出自とライセンスは [publication manifest](PUBLICATION-MANIFEST.md)
で追跡します。リポジトリは [MIT](LICENSE) で公開し、個別の上流通知を保持しています。
別作品のコード、音源、依存ランタイムには、それぞれの条件が適用されます。

*A public reference for our game-development research: implementations, concepts,
interactive studies, evidence and open questions, from pure functional foundations
to graphics, procedural worlds, music, logic and arrays.*
