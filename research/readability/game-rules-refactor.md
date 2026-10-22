# ゲームの判断をコードから追う

ジャンプの初速だけを変えるなら、Afterlight の `initialJumpSpeed` を読む。
配送に失敗したとき何が戻るのかを調べるなら、Red Dune の
`tryInventory` と `tryVehicles` を読む。この変更では、そのような調べ方で
必要な状態・判断・結果がつながるように、計算途中の意味と処理の境目を整理した。

比較元は `7fb546cb58cc79120b1061f06bea741c4f3e9ec3`。
対象は保守中のライブラリ、参照ゲーム、ホスト、ツール、テンプレート、テストと
実行用の研究例である。既に読みやすいコードと、独立した比較元・過去のソース・
意図的にコンパイルを拒否させる例は保持した。
以下は実装者による読みやすさの説明であり、初学者や別モデルの理解度を測った結果ではない。

## Afterlight の移動とジャンプ

[`Garden.Rules`](../../references/afterlight/src/Garden/Rules.hs) の `advance` は、
移動、時間、操作、敵、決着の順に状態を渡し、それぞれの cue を同じ順に連結する。
この入口と `Motion`・`Journey` の型は保持した。

変更前の `movement` では、入力方向、加速、ダッシュ、接地、ジャンプ、飛行、
重力、衝突解決が一続きのローカル束縛だった。同じ数値 `17` の役割も、
周囲の式から見分ける必要があった。現在は次の順に読める。

| 読む箇所 | 入力から何を決めるか |
| --- | --- |
| `requestedDirection` / `requestedVelocity` | カメラに対する操作方向を求め、斜め入力の速さを抑える。ダッシュ中はその目標速度とは別の速度を使う。 |
| `coyoteTicks` / `bufferedJumpTicks` | 接地で猶予を7に戻し、離れている間は減らす。ジャンプ入力は8に戻し、入力がない間は減らす。両方が正で、飛行中でなければ発射できる。 |
| `jumpVelocity` | 発射時は `initialJumpSpeed = 8.7`。その後、ジャンプを押し続けていて上昇中なら `heldJumpGravity = 17`、それ以外は `fallingGravity = 25` を使う。 |
| `movePlanar` / `moveVertical` | X方向、Z方向、細分した垂直移動の順に衝突を解決する。垂直の当たり方から接地・空中・飛行を選ぶ。 |
| `next` と返り値 | 発射したら両タイマーを0にし、解決済みの足位置と動作を保存する。cue は Jump、Dash の順を保つ。 |

地面から少し離れても跳べる理由は、現在の接地判定だけでなく、残った
`playerCoyote` を使うためである。入力が少し早くても `playerJumpBuffer` に残る。
これらの保持と消費は `movement` の中に並んでいる。

初速だけの変更先は `initialJumpSpeed`。ダッシュの `dashSpeed`、既に飛行中の
加速速度 `fastFlightSpeed`、上昇中の重力 `heldJumpGravity` は別々に名付けた。
飛行速度の選択が前の `Motion` を参照すること、Float の式と演算順、
段差の判定、垂直探索の分割幅と探索回数は変更していない。

`Garden.World` の初期 `Player` も、11個の位置引数を既存のフィールド名で構築する。
`Garden.Raycast` は地形による遮蔽と候補の走査順を保ったまま、近い敵を選ぶ
`nearer` を名付けた。同距離なら先の敵が残る。

## Red Dune の配送と診断

[`Colony.Transport`](../../references/red-dune-live/core/Colony/Transport.hs) の
`assignReadyWithFuelPolicy` では、車両の適格性、燃料、積載、予約、読み込みを追う。
以前はこれらが長いリスト内包表記と一つの子配送生成処理に混ざっていた。

`eligibleAtSource` は、仕事を持たず、出発点にいて、同じ colony に属し、
運転手と pickup の条件を満たす車両を選ぶ。候補の巡回順と試行上限はそのまま残る。
`journeyFuel` は道の辺数と車庫への帰路から必要燃料を計算する。
既にある燃料から予約済みの分を引き、不足燃料の重さも差し引いて積載量を決める。
積載できない場合の判定は、給油場所の判定より先に行う。

`makeChild` は実際の同じ道路ノードにある燃料だけを移し、数量と到着先容量の予約を
子配送へ移してから `Shipment` を構築し、`loadShipment` で積む。
フィールド名があるため、配送元・配送先・親・車両・数量を位置の数え直しなしで読める。
試行全体は `tryInventory` で囲まれており、失敗すると燃料・予約・ID採番を含む在庫が戻る。
一方、試した回数と公平性のカーソルは外側の `TransportState` で更新される。
待つ理由と失敗の扱いの順序も保持した。

取消は `cancelDelivery` から `terminateRequest`、`createReturn` へ進む。
積載済みの荷物は独立した帰還配送へ引き継ぐ。車両の中にある現物をその場で倉庫へ
加算する処理にはしない。P1の取消とP4の到着の順序、帰還先容量の予約も保持した。

[`Native.Play.siteStatus`](../../references/red-dune-live/native/RedDune/Native/Play.hs)
では、表示する問題が複数あっても、次の優先順位で最初の状態を選ぶ。

1. 未完了の建設
2. 修理が必要な施設
3. 配給所の担当者と物資
4. 生産施設の稼働、停止方針、担当者、天然資源、投入物、出荷待ち
5. 家・発電・蓄電・備蓄場所などの説明

`firstStatus` から候補を読むと優先順位が分かり、各候補の中で数量と日本語の表示を
確かめられる。生産の不足資源は従来と同じ地図順で選ぶ。

ネイティブの `Main.loop` はQAの座標・キーの解読、previewの再利用、ボタンの
hit-testを名付けた。ボタン、通常キー、QAキーの優先順位と、重なったボタンを
逆順で選ぶ規則は保持する。`Native.View` は重なるworld labelの選択をローカルな
`prioritizedWorldLabels` へまとめ、選択順と描画順をそのまま残す。

ほかにも、`World.validateM1WorldLinks` は道路・勤務・建設資材・生産施設・車両・
作業リンクの検査を名付け、最初の失敗を返す順序を維持した。
`M1Scheduler` は仕事の種別を数値タグから private な `WorkKind` へ変えた。
`SchedulerCore` は候補と残り試行数を、`Presentation.m1Projection` は建設費・
勤務先・技能・建設候補をそれぞれ名付けた。JSONのキー・値・null・配列順は維持する。
`Game.applyAction` は操作を振り分け、各ハンドラーが解読・ガード・更新を担当する。
同じIDと本文の再送、古い境界、改訂番号、packの適用条件は共通の入口に残る。

`Content.validateContent` も、ヘッダー、一覧の形、キー、資源定義、依存関係、
レシピ、建物を読む順に分けた。`Needs.stepNeedsForDining` は、食事場所ごとの配分、
共通の配分、実際の消費、住民と食事履歴の更新を区別する。水・通常食・現地の食事を
消費する順序と余りの計算は保持する。`Campaign.advanceCampaign` は、新しく作った
食料、別の理由で失った食料、食べられた食料、目標・健康・備蓄・そのtickの配給を
別々の名前で扱い、安定時間を増やす条件を追いやすくした。

## Signal Courier の一回の入力

[`Signal.Game`](../../references/signal-courier/src/Signal/Game.hs) では、
`advance (Tick East True) initial` を追う。入口は終了済みかを確かめ、`runTick` が
`resolveMotion`、落下判定、切手の回収、配達、締切判定の順に結果を求める。
初期状態では右へ4、上へ12動き、表示は x=44、y=288、接地なし、経過1tickとなり、
イベントはまだない。

以前は移動後の高さと着地で補正する前の `rawY`、古い配達数、落下時に戻す状態を、
長い式の中で追う必要があった。現在は `resolveMotion` が `rawY` を別に返し、
`recordFall` は前のチェックポイントから復帰し、`collectStamps` と
`deliverAtBeacon` は移動後の位置を使う。
最後の `finishTick` は、締切ちょうどの配達が成功する既存の順序を保つ。

## 残した設計と確かめる範囲

共通の `Step`・`Machine`・`Arena`、admission と observation の区別、非公開の
状態構築、独立した比較用コードは保持した。Station の入力解読と River の夜から朝へ
渡す状態も既に意図を示していたため、今回の分割方式へ揃える変更は加えていない。
保存・復元・FFI資源解放・ホストの入力優先順位も、読みやすさのために意味を変えない。

既存の法則・ゲームプレイ・保存・予約と資源保存・ホスト検査に加え、Afterlight は
独立した原版との比較を使う。来歴の新しい記録は
`READABILITY-REFACTOR-MANIFEST.json` に分離し、過去のhashとoracleを保持する。
検査に通ることと、初学者が理解できること、ゲームを楽しめること、別のゲームでも
最初から同じ品質のコードを書けることは、それぞれ別の確認である。
