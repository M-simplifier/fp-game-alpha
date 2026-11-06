# 研究を辿る

ゲームの規則、生成される世界、音楽、描画、関係や配列による記述を、
一つの研究の蓄積として読むための入口です。
[全体の考え方](https://m-simplifier.github.io/fp-game-alpha/guide.html)から読み始めるか、
[研究目録](https://m-simplifier.github.io/fp-game-alpha/research.html)で問いを探してください。
目録の正本は [catalog.json](catalog.json)、収録範囲は [coverage](coverage.md) です。

## 最初の順路

1. **一つの操作を読む。** [Stationの配達](https://m-simplifier.github.io/fp-game-alpha/learn.html)
   で、入力、型、状態の変化、拒否を見ます。[遷移とArena](../docs/architecture.md)
   では、それを複数のゲームに共通する法則と観測の条件へ広げます。
2. **世界と音を読む。** [Stillroom](stillroom/README.md) の地形・自然物・描画・音楽を通して、
   純粋な記述から実際の画面と音へ至る境界を見ます。
3. **別の表現で問い直す。** [三つのテトリス](frontiers/README.md) では関数・配列・関係を、
   [解釈と合成](frontiers/composition.md) ではFreeモナドや圏論による探索を読みます。
4. **根拠と歩みを確かめる。** [研究の履歴](history/README.md)、
   [保証の範囲](../docs/guarantees.md)、各作例の検査と出典を辿ります。

## 目的に合わせて使う

実装中の問題が明確なら [技術実践](../docs/practice/README.md) と主題別の目録から
必要な箇所だけを選べます。新しいゲームを作るなら [制作手順](../docs/new-game.md)、
現在のゲームのコードを理解したいなら [learn-code](../docs/learn-code.md) へ進んでください。

目録の「実装」「作例」「実験」「問い」「歴史」は、結果の種類を示しています。
価値や確かさを一列に順位づけるものではありません。同じ項目の中にも、
実装できた部分と未検証の部分があります。各説明の根拠と範囲を併せて読みます。

この研究の目標と更新方針は [purpose](../docs/purpose.md) と
[roadmap](../docs/roadmap.md) にあります。現在の共通構造を尊重しつつ、
新しい表現によってゲームの捉え方そのものが変わる可能性も開いています。
