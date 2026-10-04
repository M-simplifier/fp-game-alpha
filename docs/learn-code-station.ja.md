# Stationの「各駅便」で型と状態の変化を読む

Stationでは、届いた依頼に「速達便」「各駅便」「次の便へ」のいずれかを選びます。
最初の依頼を各駅便で送ると、体力は8から7へ減り、届けた気持ちは0から1へ増えます。
一方、終わった1件目の操作をもう一度渡しても、2件目は処理されません。
この二つの動きを、実際のHaskellコードで読んでみます。

ここでは公開版 `c5784f68b31c0e7810f4b8034de688821dba8aa3` の
[Station.Domain](https://github.com/M-simplifier/fp-game-alpha/blob/c5784f68b31c0e7810f4b8034de688821dba8aa3/references/station/src/Station/Domain.hs) と
[Station.Adapter](https://github.com/M-simplifier/fp-game-alpha/blob/c5784f68b31c0e7810f4b8034de688821dba8aa3/references/station/src/Station/Adapter.hs)
を使います。自分のゲームを読むときは、そのゲームの現在の定義を確かめてください。
以下のコード片は、説明する宣言をこの版から抜き出したものです。

## `step`は操作の結果を返す

```haskell
step :: TurnId -> Choice -> GameState -> Either DomainError GameState
```

`::`の右側は、`step`が受け取る値と返す値を示しています。今回は順に、
操作の対象となる依頼の番号を表す`TurnId`、選んだ便を表す`Choice`、現在の状態である
`GameState`を渡します。最後の`Either DomainError GameState`が結果の型です。
矢印はここでは、時間の流れや画面の接続を表しているわけではありません。

`Either`は、二種類の結果を区別する型です。この関数は、受け付けられない理由を
`Left problem`、操作後のゲームを`Right next`として返します。
`GameState`が結果に現れるからといって、渡した状態をその場で書き換えるわけではありません。
成功時に返された次の状態を、呼び出し側が以後の状態として使います。

`Choice`の定義には、選べる三つの値が並んでいます。

```haskell
data Choice = Express | Local | Defer
  deriving (Eq, Ord, Show, Enum, Bounded)
```

ここで`Local`が各駅便です。`|`で区切られた三つのどれかを使うので、
この型の値として別の便名を適当な文字列で渡すことはできません。
`deriving`以下は比較や表示などの実装を用意する指定です。今回の体力計算は、その指定では
なく、次に読む関数に書かれています。

## 各駅便の費用を読み、次の状態を計算する

`choiceCost`は、便ごとの費用を返します。各駅便の分岐は次の1行です。

```haskell
    Local -> ChoiceCost 1 0 (localValue order) 0
```

`ChoiceCost`の宣言と対応させると、順に「体力を1使う」「速達札は使わない」
「依頼ごとの`localValue`だけ気持ちを届ける」「体力の回復はない」と読めます。
最初の依頼の`localValue`は1です。位置だけで意味を推測せず、型のフィールドと
`allOrders`の実データを照合することが大切です。

この費用を`applyCost`が現在の体力や札と比べます。不足していれば`Left`を返し、
足りていれば計算後の`Stats`を`Right`で返します。`Stats`は体力・札・届けた気持ちを
まとめた値です。`step`は成功した結果を使って、配送履歴を1件増やした`GameState`を返します。

| 見る値 | 操作前 | 最初の各駅便の後 |
| --- | --- | --- |
| 体力 `energy` | 8 | 7 |
| 速達札 `expressTickets` | 3 | 3 |
| 届けた気持ち `deliveredFeelings` | 0 | 1 |
| 完了した依頼数 `completedTurns` | 0 | 1 |

`step`の成功経路には`do`があります。ここでは`Either`の計算をつないでいます。
途中の`applyCost`が`Left`を返せば、その後のゲーム作成には進みません。
この`do`自体は、画面描画やファイル書き込みを意味しません。

## 古い操作を拒否したあと、呼び出し側が状態を保つ

`TurnId`は、`Int`を包む別の型として定義されています。コンストラクタは公開していません。
利用側は`currentTurn`で現在の操作に使う値を受け取ります。

```haskell
currentTurn :: GameState -> Maybe TurnId
```

依頼が残っていれば`Just turn`、すべて終わっていれば`Nothing`です。
ただし、以前受け取った`turn`を保存して再利用することはできます。
**古い操作を拒否するのは、`TurnId`という名前や型だけではありません。**
`step`が現在の依頼と渡された値を比較し、異なれば`Left (StaleTurn ...)`を返します。

拒否後の状態まで知るには、呼び出し側の`stationStep`を読みます。

```haskell
stationStep :: Step Domain.GameState Dispatch [Outcome]
stationStep = Step $ \(Dispatch turn choice) game ->
  case Domain.step turn choice game of
    Left problem -> (game, [Refused problem])
    Right next -> (next, [Accepted (Domain.stats next)])
```

`Step`は、入力と状態を受け取り、次の状態と結果の組を返す関数を包む型です。
この宣言では、状態が`Domain.GameState`、入力が`Dispatch`、結果が`[Outcome]`です。
`Domain.`は、取り違えないように別モジュールの名前を添えています。
共通部分の実際の定義は
[Game.Transitionの`Step`](https://github.com/M-simplifier/fp-game-alpha/blob/c5784f68b31c0e7810f4b8034de688821dba8aa3/libraries/game-transition/src/Game/Transition.hs)
で読めます。

`\(Dispatch turn choice) game ->`は、名前を付けずに関数を書く記法です。
最初の入力を`Dispatch`の形で受け取り、中の値に`turn`と`choice`という名前を付け、
次の入力を`game`として受け取ります。`$`は、後ろの関数全体を`Step`へ渡すための記法で、
括弧で囲んで渡す代わりに使われています。

`case`は、返された値がどちらの形かによって処理を分けます。拒否の分岐では
`(game, [Refused problem])`と、受け取った`game`をそのまま返しています。
成功の分岐では`(next, ...)`を返します。括弧内の二つは「次に使う状態」と
「外側へ知らせる結果」の組です。角括弧は結果を入れたリストを表します。

1件目を終えた状態に古い1件目の操作を渡すと、`Refused`は出ますが、返される状態は
1件目を終えた状態のままです。これが、体力や配送履歴がもう一度変わらない理由です。
このアダプターは結果のデータを返すところまで担当します。ウィンドウを描く関数ではありません。
なお、端末用headless playerの文字列入力には、表示中の番号を確かめる別の拒否経路があります。
ここで説明したのはDomainとAdapterの経路です。

## 読み取り用の値を書き換えても、ゲーム本体は変わらない

`stats game`で得る`Stats`のフィールドは公開されています。
その値を使って体力を99にした別の`Stats`を作ること自体は可能です。
しかし、`GameState`のコンストラクタと内部フィールドは公開されておらず、
作った`Stats`をゲーム本体に戻す公開関数もありません。

したがって「`Stats`を変更できない」ではなく、「読み取り用の値から本体を直接
更新できない」と読むのが正確です。この境界には
[外部モジュールからの読取と更新拒否を確かめる検査](https://github.com/M-simplifier/fp-game-alpha/blob/c5784f68b31c0e7810f4b8034de688821dba8aa3/tools/test_station_api.py)
があります。ルール自体を間違えて実装しないことまで、この公開範囲だけで保証するものではありません。

## 別の入力で確かめる

最初に`Defer`を選ぶと、回復量は1です。初期体力8に足すので、9になるでしょうか。
`applyCost`の`min maximumEnergy (...)`を読むと、上限8で止まることが分かります。
このとき依頼数は1進み、届けた気持ちは0のままです。各駅便の結果と比べると、
費用の定義と状態更新を分けて読む練習になります。

この説明で使った二回の操作と、最初の`Defer`は、公開ソースのDomain/AdapterをGHC 9.6.7で
実行して照合しました。対象は次の四つです。

- 初期状態の体力・札・届けた気持ち・完了数が`(8, 3, 0, 0)`
- 最初の各駅便の後が`(7, 3, 1, 1)`
- 古い操作を再利用すると、`Refused (StaleTurn ...)`が出て状態の等値比較が`True`
- 初期状態から`Defer`を選んだ後が`(8, 3, 0, 1)`

この小さな照合は画面操作の確認ではなく、読者が理解できたことを示す結果でもありません。
全体の法則や終端については、別の
[Stationの検査](https://github.com/M-simplifier/fp-game-alpha/blob/c5784f68b31c0e7810f4b8034de688821dba8aa3/references/station/test/Laws.hs)
を参照できます。
