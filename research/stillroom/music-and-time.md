# 続く音楽と、場所に応じて変わる音

再生開始から20秒の音を、4,096サンプル分だけ作るとします。その間に新しく鳴る音だけを足すと、10秒前に弾いてまだ響いている音が消えてしまいます。Stillroom の組み込み音楽は、必要な時間区間より前も調べ、そこから続いている響きを含めて PCM を作ります。車輪音では別の問題があります。速度が変わった瞬間に音の再生位置が飛ばないよう、直前までの再生位置を引き継ぎます。

[この資料の入口](README.md) · [風景と描画](landscapes-and-graphics.md)

## 続くのは、作曲の規則から作る音楽

四つの曲調には、それぞれ和声、音域、リズム、強弱、音を置かない間隔が記述されています。既存の長い曲を順番につなぐ方式ではなく、この語彙の中で小さく変化する発音を作ります。柔らかいピアノ、温かい鍵盤、静かな拍、木の音と空気感が同じ再生体験に入っています。利用者が選んだ録音ファイルには、有限な曲のシャッフルとクロスフェードを使います。[組み込み音楽の設計](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/builtin-world.md)が、この二つの経路を説明しています。

[Audio.Composition](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Audio/Composition.hs)では、拍の位置を `Rational`、最終的な開始サンプルを `Integer` で扱います。たとえば曲調 `Linen` は66 BPMで、1.5拍後という位置はまず `3/2` 拍として持ち、最後に `floor (beat × 60 / tempo × 44100)` でサンプル番号へ移します。どの大きさのブロックで呼ばれたかによって、小節の先へ進む方式ではありません。seed と小節番号から選ぶので、後の区間を先に問い合わせても、途中の作曲結果を変えません。

これは [Tidal の時間区間へ問い合わせるパターン](https://tidalcycles.org/docs/innards/what_is_a_pattern/)と通じる考え方です。ただし Stillroom は Tidal を実行時に使っておらず、Tidal の組み合わせ演算全体を実装しているわけでもありません。実際に何を鳴らすかは、このアプリで書いた和声と声部の規則にあります。

## 前から続く響きを、区間へ含める

`compositionEvents` に曲調、seed、開始位置、長さを渡すと、その区間の終わりまでに鳴り始める発音を返します。開始より24秒前まで遡るので、すでに鳴っている音も含められます。24秒という値は万能な履歴長ではありません。読み込んだ音色の最長の長さが、それ以下であるという契約です。[Runtime.Audio.Builtin](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Audio/Builtin.hs)は、その長さを超える音源を明示的に拒否します。

```haskell
import Data.List (isPrefixOf)
import Stillroom.Audio.Composition (compositionEvents)
import Stillroom.Audio.Mix (eventKey, eventStart)
import Stillroom.Domain (Preset (Linen))

events = compositionEvents Linen 17 (20 * 44100) 4096
openingTail = any (\event ->
  eventStart event == 0 && "air-" `isPrefixOf` eventKey event) events
-- openingTail は True。開始時に鳴った音を20秒後の問い合わせも含む。
```

同じ関数の結果を、隣り合う区間ごとにそのまま連結して「曲全体の発音一覧」にすることはできません。各問い合わせは、前から続く発音を重ねて返すためです。等しいべき対象は、同じ絶対位置に対して作る最終的な PCM です。区間へ問い合わせるという似た形だけで、空間の区画と音楽の発音が同じ結合法則を持つとは言えません。

[Audio.Mix](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Audio/Mix.hs)は、検査済みの音色を発音へ結び付け、要求区間と重なる部分だけを足します。足す順序を開始サンプル、同時なら入力順に定め、`Double` で加算してから `Float` にします。音声ブロックをどこで切っても同じ順序で同じ値を足すため、代表例では Float のビットまで一致します。ミキサーは自動正規化やクリッピングで音量を揃えません。

## 分割に依存しないことだけでは、正しい音を証明できない

8,193フレームを一度で作る結果と、`17 + 4079 + 4097` フレームに分けて連結した結果を比べると、ブロックの切れ目で響きが変わる誤りを調べられます。しかし、両方とも過去の響きを捨てていたら、誤った音同士が一致します。

[AudioChecks](https://github.com/M-simplifier/stillroom/blob/v0.12.0/test/AudioChecks.hs)は、分割の比較に加えて、開始時の `air` 音が20秒後の問い合わせにも残ることを別に確かめます。ミキサー自身も、手で決めた短い二つのステレオ信号を、開始位置・左右の音量・重なりを指定して足し、期待値と比べます。WAV デコーダーは、そのデコーダーと対になるエンコーダーで作ったデータだけに頼らず、手書きの既知の RIFF バイト列と比べます。

これらは違う種類の証拠です。分割比較は呼び出し単位による違いを、短い既知の波形はチャンネルや開始位置の解釈を、長い響きの例は発音を拾う範囲を確かめます。どれか一つが、音色の美しさ、全楽器の周波数特性、実際の耳までの遅延を代表するわけではありません。

## 場所の音は、四つの値で受け渡す

旅の描画側は、音声側へ地形全体や樹木のメッシュを渡しません。[Runtime.Journey.soundscape](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Journey.hs)が旅の状態を読み、次の四つを渡します。

| 値 | v0.12.0での作り方 | 主に変わる音 |
| --- | --- | --- |
| 乗車中か徒歩か | 旅の座席状態 | 車輪・車体音の有無 |
| 速度 | 列車の速度、単位 m/s | 車輪の音量・再生速度、距離で起きる車体音 |
| 森の度合い | 現在地の主な生息域に応じた固定値。白樺林0.85、砂丘0.10など | 葉の音の量 |
| 岸までの距離 | seed と現在地で地形へ問い合わせる | 水音の量 |

「森の度合い」は、画面内の葉を数えた値でも、地形の植生密度をそのまま渡した値でもありません。生息域から音の強さを決める、この作品の対応付けです。値の不正や無限大は入力境界で個別に穏当な値へ直します。音声側は、それらをサンプルごとに滑らかに変えて、急な段差を避けます。[Audio.Environment](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Audio/Environment.hs)に入力の受付から音の合成までがあります。

この意味で音は場所に応じて変わりますが、実装は七つのステレオ素材のループ・単発音とその混合です。音源の三次元座標、頭の向き、遮蔽物、HRTF、反射経路を入力に取る空間音響ではありません。視線を回して水源の方向が変わることまで、この四値からは求められません。別ゲームに方向定位が必要なら、ここへ追加する音源・聞き手の情報と、その聴き方の検証が必要です。

## 速度が変わっても、車輪の音を飛ばさない

車輪のループ位置を `現在時刻 × 現在の再生速度` で求めると、速度を変えた瞬間に、それまで再生していた位置まで変わります。たとえば10秒間を速度1で進んだ後に0.5へ切り替えると、式の値は10から5へ戻ってしまいます。

環境音では、今の位置へ一サンプル分ずつ再生速度を加えて進めます。簡略化すると `次の位相 = 今の位相 + 今の再生速度` です。変わるのは、その先へ進む速さです。車体の小さな音も、絶対時刻ではなく走った距離で起こします。ループ位置、ゆっくり変わる風、音量の推移、乱数、最大四つの車体音を `EnvironmentState` に残します。

[EnvironmentChecks](https://github.com/M-simplifier/stillroom/blob/v0.12.0/test/EnvironmentChecks.hs)は、2秒進んだ後に速度を変え、既知の短い波形のどこを読むべきかを別計算します。誤った `絶対時刻 × 新しい速度` の式では違うサンプルになることも確かめます。間違った方式が一括／分割の比較には通ってしまう、もう一つの反例です。

環境音の分割検査が等しいとするのは、同じ入力が同じサンプル位置へ適用される場合です。操作やセンサー値をブロックの先頭で変えるなら、ブロック境界の変更とともに操作の適用時刻まで変えてしまってはいけません。ネットワークゲームやリプレイへ持ち込むときは、入力をいつ採用するかも契約に含めます。

旅を離れると1.6秒かけて消え、その後は位相や制御の状態が止まります。入り直すと1.1秒かけて現れます。音楽は旅の間も同じ位置から続き、環境音が有効な間は音楽の音量を40%へ緩やかに下げ、退出時に戻します。これはアプリのミックスの選択で、耳元の音圧や快適さを測った値ではありません。[組み込み音楽と環境音](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/builtin-world.md)が、試聴で選んだ車輪の強さも記録しています。

## 音の状態とデバイスを、誰が更新するか

時間区間から音を作る関数が純粋でも、デバイスへの供給、再生停止、曲の切り替え、資源の解放は順序を持つ処理です。[Runtime.Audio](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Audio.hs)は、bound thread で供給を続け、制御操作と複数のストリームを同じ排他境界で直列化します。供給中のストリームを別の処理が解放しないよう、終了では供給側の後始末を待ちます。描画スレッドと音声の供給スレッドの所有を分けています。

環境音の供給関数は、直前の状態から提案された PCM と次の状態を作り、PCM の長さと有限性を確かめてから次の状態を保存します。失敗した計算を、位相だけ進んだ成功として扱いません。ただし、この境界はシリアルに呼ばれる前提です。純粋な関数と `IORef` があるだけで、任意の並行呼び出しに安全になるわけではありません。[Builtin の実装](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Audio/Builtin.hs)に、その呼び出し条件が書かれています。

この構成をフィードバックのある合成器へ広げる場合、時間だけ指定して直ちに同じ音を得られるとは限りません。ディレイやフィルターの内部状態を、どこから復元し、編集時に何を引き継ぐかが追加の問題になります。Stillroom の一回鳴らす音色と有限の過去窓が解決する範囲を、そのまま音声処理全体へ広げないことが大切です。

## 音源を再生成し、実際の供給を確かめる

音源は、実行時にオンラインサービスへ作らせるものではありません。62個の音楽用素材と7個の環境音を事前生成し、アプリへ同梱します。ピアノは権利表示のある Salamander 録音から加工し、それ以外の音はコードで生成します。[音源生成の手順](https://github.com/M-simplifier/stillroom/blob/v0.12.0/tools/audio/README.md)と[来歴・ライセンス](https://github.com/M-simplifier/stillroom/blob/v0.12.0/licenses/builtin-audio.md)を確認できます。

```powershell
python -m pip install -r tools/audio/requirements.txt
python tools/audio/fetch_piano_samples.py --out rebuild/piano
python tools/audio/make_instruments.py --piano-samples rebuild/piano --out rebuild/music
python tools/audio/make_environment.py --out rebuild/environment
python tools/audio/verify_banks.py --music rebuild/music --environment rebuild/environment
```

再生成は Python 3.12 の専用環境で行い、新しい出力先を使います。固定した元録音のハッシュ、生成器、数値ライブラリの版を記録します。公開記録では69ファイルが同梱 WAV と byte 一致しましたが、seed だけで異なる FFT・リサンプリング・WAV ライブラリの出力まで等しいとは言えません。

純粋な合成と状態のテストは、Stillroom の `cabal test laws` に含まれます。ネイティブの供給、停止、切り替え、描画の停止中の進行、後始末は、[開発手順](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/development.md)の `./tools/dev.ps1 Check` と、展開済み配布物への `CheckPackage` で別に確かめます。通常の音声チェックはミュートであり、実際に聞こえたことを証明しません。

公開記録の環境音4,096フレームは約0.92 msで計算され、音としては約92.88 msぶんでした。この値は開発機での合成時間で、デバイスやドライバへの供給期限を保証しません。全音色の読み込みでは、分離した検査の最大常駐量が約288 MBでした。長時間の実聴、他機器、電力、音量の好みは、これらの信号テストとは別に確かめる対象です。[結果と限界の正本](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/builtin-world.md#evidence-and-limits)に条件があります。

## ゲームへ持ち込む際に、先に決めること

一回の発音に有限の長さがあり、作曲の選択が時刻と seed で決まるなら、時間の窓へ問い合わせる方式を候補にできます。移動の履歴で音が変わるなら、状態を残す方式が必要です。プレイヤーが世界を変えるなら、その変更も入力へ加わります。この違いを保った上で、長い響き、速度変更、停止と再開、資源の入れ替えを一件ずつ試すと、Stillroom の手法のうち何がそのゲームでも成り立つかを判断できます。
