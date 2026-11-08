<a id="研究を辿る" name="研究を辿る"></a>

# ゲーム開発の知見と実装を辿る

配達の一手で状態がどう変わるか。風景や音楽のどこまでを、その場で作り直せるか。
ゲームを作りながら調べてきた問いを、作例や検証の記録から辿れます。
[全体の考え方](https://m-simplifier.github.io/fp-game-alpha/guide.html)から読み始めるか、
[技術目録](https://m-simplifier.github.io/fp-game-alpha/research.html)で問いを探してください。
目録の正本は [catalog.json](catalog.json)、収録範囲は [coverage](coverage.md) です。

## 最初の順路

1. **一つの操作を読む。** [Stationの配達](https://m-simplifier.github.io/fp-game-alpha/learn.html)
   で、入力、型、状態の変化、拒否を見ます。[遷移とArena](../docs/architecture.md)
   では、それを複数のゲームに共通する法則と観測の条件へ広げます。
2. **世界と音を読む。** [Stillroom](stillroom/README.md) の地形・自然物・描画・音楽を通して、
   純粋な記述から実際の画面と音へ至る境界を見ます。
3. **別の表現で問い直す。** [三つのテトリス](frontiers/README.md) では関数・配列・関係を、
   [解釈と合成](frontiers/composition.md) ではFreeモナドや圏論による探索を読みます。
4. **根拠と歩みを確かめる。** [探究の歩み](history/README.md)、
   [保証の範囲](../docs/guarantees.md)、各作例の検査と出典を辿ります。

## 目的に合わせて使う

実装中の問題が明確なら [技術実践](../docs/practice/README.md) と主題別の目録から
必要な箇所だけを選べます。新しいゲームを作るなら [制作手順](../docs/new-game.md)、
現在のゲームのコードを理解したいなら [learn-code](../docs/learn-code.md) へ進んでください。

技術目録の「実装に接続」「具体的な作品」「実験」「未解決の問い」「これまでの試み」は、項目の区分です。
価値や確かさを一列に順位づけるものではありません。同じ項目の中にも、
実装できた部分と未検証の部分があります。各説明の根拠と範囲を併せて読みます。

公開リファレンスの[目的](../docs/purpose.md)と[更新方針](../docs/roadmap.md)も読めます。
