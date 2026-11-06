# 風景を作り、同じ形をGPUで描く

湖の向こうの木を、通常の画面、水面の反射、地面へ落ちる影に描くとします。視点は三つありますが、風が吹く時刻や木の形まで視点ごとに変えると、反射や影が本体からずれます。Stillroom では、生成した形とその時刻を先に定め、それを複数の視点から描きます。さらに、旅で現在地が変わったときだけ必要な区画を作り足します。

[この資料の入口](README.md) · [音楽と環境音](music-and-time.md)

## 場所の構造を決めてから、細部を増やす

固定した三つの自然風景は、同じ生成器の色を変えたものではありません。白樺の湖は不規則な湖盆と左右の林で水面を囲み、高山の湖は非対称な峰、溝、標高や斜面に応じた岩・雪・針葉樹を重ねます。草原の小川は、幅が変わる曲線の水路と低い岸を中心にします。視線を置く場所が決まっているため、近景には枝や個々の葉を、遠景には樹冠の形を残す選択ができます。[構図と生成規則](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/procedural-landscapes.md)に対応する実装は、[Landscape.Fixed](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Landscape/Fixed.hs)と[Landscape.Plants](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Landscape/Plants.hs)です。

植物の揺れにも構造があります。枝の付け根と親子関係を数値テクスチャに持たせ、幹・枝・葉で異なる大きさの動きを重ねます。近くの植物には共通する風の場を使います。各頂点を無関係に揺らすと、同じ枝が伸縮したり、隣の木が別の天候に見えたりするためです。これは見た目を組み立てる近似で、木の力学を解く計算ではありません。[GPU Gems 3 の樹木の風](https://developer.nvidia.com/gpugems/gpugems3/part-i-geometry/chapter-6-gpu-generated-procedural-wind-animations-trees)は、階層と風を考える先行例です。同書の手法をそのまま全部実装したという意味ではありません。

水面も役割を分けます。大きな波の形、細かな法線の変化、同じ時刻の景色を映す平面反射、深さに応じた色を組み合わせます。遠くの細かすぎる波は画素の大きさに合わせて弱めます。この平面反射は湖に適した方法で、曲面鏡や流体全体の計算を提供するものではありません。[実装した範囲と参照した研究](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/procedural-landscapes.md#research-that-changed-the-implementation)が分けて記録されています。

## seed付きの場から、見える範囲を作る

旅の地形は、seed と世界座標から高さ、生息域、線路、樹木・岩の位置を返す規則で作ります。[Landscape.Field](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Landscape/Field.hs)は seed を各問い合わせの引数に取ります。共有の乱数状態で「今選ばれている世界」を切り替えないので、異なる世界を交互に調べても結果が混ざりません。樹木と大きな岩の配置規則は、描画用の生成と歩けるかの判定が共に使います。

次の例は公開ソースの関数を使った、小さな問い合わせです。`h1` の具体的な数値を覚えるより、別世界の問い合わせが最初の世界を変えないことを確認します。

```haskell
import qualified Stillroom.Journey.World as World
import qualified Stillroom.Landscape.Field as Field

seed1 = World.seed 1
h1 = Field.ground seed1 22 (-512)
other = Field.ground (World.seed 2) 22 (-512)
unchanged = other `seq` (h1 == Field.ground seed1 22 (-512))
-- unchanged は True
```

描画用データは有限な区画に切ります。[Landscape.Chunk](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Landscape/Chunk.hs)では、近景は一辺32単位を32分割し、遠景は一辺128単位を16分割します。同じ場を違う密度で調べ、地形、植物、枝の情報、水面のデータをまとめます。区画ごとの生成器内部では `ST` による書き込みを使いますが、外へ返す結果は変更できない配列を持つ `Geometry` です。[公開する読み取り境界](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Landscape/Geometry.hs)には GPU のハンドルが入りません。

[Runtime.Graphics.Journey](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Graphics/Journey.hs)は近景49区画・遠景81区画までを保持し、不要な区画を置き換えます。新しい区画の生成と転送を終えてから、古い区画を解放します。通常は形の指紋を計算せず、再生成の比較を行う診断時にだけ全データをたどります。診断の生成時間には、その追加作業が含まれます。

ここで重要な限界が二つあります。第一に、seed は元の生成規則を再現するだけです。伐採した木まで再現するには、変更を別に保存する必要があります。第二に、キャッシュの件数が有限でも、生成の一回あたりの待ち時間が消えるわけではありません。旅の座標範囲も各軸で原点から100万地形単位までです。数学的に無限の世界や、どこへでも歩いて到達できる大陸を実証したものではありません。[旅の条件](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/journeys.md)を参照してください。

## 同じ規則から作っても、歩く高さと描く高さは完全には一致しない

歩行は `Double` の座標で解析的な高さを調べます。一方、描画は `Float` の座標で格子点を調べ、その間を三角形で補間します。共通の地形規則を使っても、格子点の間まで同じ曲面になるとは限りません。

具体例として、高さを `x² + z²` とする地面の、`0 ≤ x,z ≤ 1` の四隅を考えます。高さは `0, 1, 1, 2` です。この四隅を三角形で結んだ面の中央は高さ `1` ですが、元の式で中央を調べると `0.5` です。seed や乱数の間違いがなくても、この差は生じます。

[LandscapeChecks](https://github.com/M-simplifier/stillroom/blob/v0.12.0/test/LandscapeChecks.hs)は、この反例と、歩行が解析的な高さを使い続けること、描画が明示的に `Float` へ量子化すること、負の座標の区画境界で位置と法線がそろうことを検査します。画面と当たり判定を共通化する際は、「同じ関数を呼んでいる」だけでなく、どの座標を、どの精度で、どう補間しているかまで確認できます。

## 車体を組み立ててから、外側の面を取り出す

車体は、箱型の部品を組み合わせて作ります。一辺1の箱を二つ、面が接するように並べると、別々に外側の面を作って足した面積は `6 + 6 = 12` です。しかし、一つの立体にしてから外側を取り出すと、接して隠れる二面を除いた面積は `10` になります。「部品を足す」と「表面を足す」は、同じ操作ではありません。

[Graphics.BoxUnion](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Graphics/BoxUnion.hs)は、軸に沿う箱の重なりや接触を `Rational` のまま計算して、覆われた内部の面を除きます。外側の面が重なる部分は、後に置いた部品の材質を採用します。順序を変えると、形が同じでも色や材質が変わり得ます。[Graphics.Mesh](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Graphics/Mesh.hs)は三角形と座標・外観を分け、描画用の数値や色へ変換するまで、この区別を残します。

71個の箱の寸法、配置、色、曲面の車輪は [Journey.Railcar](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Journey/Railcar.hs)にあります。車両の意匠を箱の境界算法へ埋め込まない構成です。[GraphicsChecks](https://github.com/M-simplifier/stillroom/blob/v0.12.0/test/GraphicsChecks.hs)は矩形の差分や立体の体積などを検査します。ただし、軸に沿う箱の外面を正確に取り出せることから、任意の曲面を扱う CSG や、車輪を含む車両全体の水密性は導けません。元の車輪の蓋と側面の隙間も保持されています。

## 形の選び方と、見る方向を分ける

ある地面を影として描くとき、太陽からの距離だけで地面の細かさを選び直すと、通常画面の地面とは別の高さになる場合があります。Stillroom の基盤には、旧経路で通常画面と影の頂点に3 mの差が出た合成例が記録されています。そこで、形の細かさを決める基準と、投影する視点を分けています。[Graphics foundation](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/graphics-foundation.md#visible-stability)の結果は、この入力に対する GPU 頂点実験です。

[Journey.Frame](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Journey/Frame.hs)は、形を選ぶ基準位置、近くの描画原点、時刻を一つの `GeometryContext` にまとめます。その上で、乗客、太陽、水面で反転した視点を組み立てます。[Graphics.Observation](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Graphics/Observation.hs)は、画像の対象と、その画像を書き込み・参照する投影を一組にします。影を書いた行列と、通常画面で影を参照する行列が別々に作られないようにするためです。

座標の取り違えも一部はコンパイラが拒否します。[Graphics.Space](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Graphics/Space.hs)の変換は、入力空間と出力空間を型に持ちます。

```haskell
compose :: Transform b c -> Transform a b -> Transform a c
```

途中の空間が合う変換だけをつなぎ、`nominal` の role で空間名を `coerce` により付け替える抜け道も塞ぎます。role の意味は [使用コンパイラ GHC 9.6.7 の説明](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/exts/roles.html)で確認できます。ただし、型だけで数値の有限性や視点の妥当性までは決まりません。`planFrame` と `observe` はそれらを検査してから値を返します。

検査済みの値を後から壊せないことも必要です。実装は内部のレコード名を公開せず、普通の読み取り関数を公開します。コンストラクタだけを隠してフィールド名を公開すると、レコード更新で投影の一部を置き換えられるためです。[拒否されるクライアントの例](https://github.com/M-simplifier/stillroom/blob/v0.12.0/test/types/ReplaceObservation.hs)も公開されています。

この設計は「すべてのカメラは乗客と同じ細かさを使う」という規則ではありません。独立した監視カメラには別の形の選択が適する場合があります。三つの視点を一組にする判断は Stillroom の旅に属し、汎用の観測型はパスの列挙を知りません。

## 草の形を一度記述し、CPUとGPUで使う

v0.12.0 の草は、一枚につき15頂点、5三角形の形を保ちながら、すべての頂点属性を保存する方法を変えています。根元、高さ、幅、向き、曲がりなどを40 byteのレコードに持ち、15個の共通の角を表す180 byteのバッファを使います。以前の展開済み属性は一枚660 byteでした。これは草の属性表現の比較で、アプリ全体やドライバを含めたメモリ使用量ではありません。

[Grass.Kernel](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Landscape/Grass/Kernel.hs)の `bladeCorner` は、四則演算で草の頂点を求めます。同じ関数を `Float` で実行すると CPU の参照結果になり、式を表す値で実行すると GLSL が出力されます。任意の Haskell を GPU 向けにコンパイルする仕組みではなく、小さく定めた算術の共有です。角度の三角関数や雛形の列は CPU に残り、風や原点・投影の変換はその後に GPU が行います。

花は通常の三角形のままで、草は従来どおり影の描画対象から外れます。展開済みの比較経路も診断のために残ります。[Grass](https://github.com/M-simplifier/stillroom/blob/v0.12.0/src/Stillroom/Landscape/Grass.hs)、[GPU への転送](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Graphics/Resource.hs)と[補足の測定条件](evidence/renderer-measurements-2026-11-06.json)を併せて読むと、何を減らし、何を残したかを追えます。

## 純粋なデータとGPU資源は、別の寿命を持つ

CPU で形を作ることには OpenGL の文脈が不要です。しかし、その形を GPU に転送した後のメッシュ、シェーダー、反射用画像には、作った文脈と実行スレッドに結び付いた寿命があります。[Graphics.Resource](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Graphics/Resource.hs)の `Scope` は後始末を登録し、描画側が明示的に閉じます。GC の任意のスレッドに GPU 解放を任せません。型の付いた純粋な値を作ったことだけでは、この所有は解決しません。

[Graphics.Target](https://github.com/M-simplifier/stillroom/blob/v0.12.0/runtime/Stillroom/Runtime/Graphics/Target.hs)も、交換先の画像を作ってから古い画像を解放します。確保に失敗したら品質を落とすか、使える旧画像を保ちます。ギャラリーの中で描く際は、呼び出し元のフレームバッファや表示領域などを復元します。単独ウィンドウで描けるテストだけでは、設定画面の中へ安全に埋め込めることは分かりません。

## 一致を確かめる検査と、正しい意味を確かめる検査

通常画面と影の計算が一致していても、両方が同じ誤った車体の変換を使っていれば一致したままです。そのため、経路同士の比較に加え、別に定めた座標の期待値と比べ、故意に誤った変換で失敗するかを確かめます。独立性は、調べたい誤りに対して判断します。同じプランナーを使う高精度の参照値は GPU の分岐間違いを見つけても、プランナー自身の意味を独立に証明するわけではありません。

公開された検証は、次のように異なる問いへ答えています。

| 検証 | 得られた証拠 | その範囲で分からないこと |
| --- | --- | --- |
| 0.10基盤の GPU 頂点検査 | RTX 3050／OpenGL 3.3、車体5,394頂点、67条件、3パス。誤った行列と物体種別を検出 | 画素の可視性、全地形、全 GPU、描画速度 |
| Haskell移行の凍結比較 | 17,137個の場の標本と、固定3風景・近遠24区画。27形状のうち26は byte 一致 | C 側にもともとある誤りの不存在。高山地形の `atan2` には1 ULP差がある |
| 0.12の草の GPU 検査 | 各変種・各シェーダー系列77,760頂点。最大位置差は実測 `9.54e-7 m`。誤った風座標を拒否 | すべての Float 入力の誤差上限、別 GPU の動作、草の影 |
| 0.12の1600×900画像比較 | 12枚中8枚が完全一致。残る4枚は2〜7画素が変化 | あらゆる景色の画質保存、見る人の美的な評価 |

数値の条件と詳しい限界は [graphics-foundation.md](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/graphics-foundation.md#verification-and-limits)が正本です。凍結データは移行の回帰を見つけるために有用ですが、期待される形そのものを独立に定義する検査とは役割が異なります。

草の表現が小さくなったことから、全体が速くなったとは言えません。2026年11月6日の補足測定では、同一プロセス内で準備済みの草を描く比較に重大な退行は見つかりませんでした。一方、1,800フレームの別の連続区画生成を含む比較では、インスタンス版80.51秒、展開版73.10秒という逆転が残っています。生成・転送などの部分の時間だけでは差を説明できていません。この反例を残したまま、転送表現、描画区間、全工程の時間を分けて読みます。[機械可読の補足記録](evidence/renderer-measurements-2026-11-06.json)には、条件、除外した作業、採用しなかった候補もあります。

この JSON は、Stillroom 開発時の資料を選んで本リポジトリへ収録したものです。v0.12.0 の公開タグには含まれず、本資料の編集時に GPU 測定を再実行したものでもありません。その時の専用ハーネスと生ログの一式は収録していないため、記載の同一プロセス内の比較を、この JSON だけから再実行できるわけではありません。[収録元・ライセンスと確認範囲](README.md#この資料の確認範囲)を分けて記載しています。

## 公開ソースから確認する

Windows x64、GHC 9.6.7、Cabal 3.12.1.0 を前提に、[開発手順](https://github.com/M-simplifier/stillroom/blob/v0.12.0/docs/development.md)を使います。最初のビルドは固定した依存関係を取得します。

```powershell
git clone https://github.com/M-simplifier/stillroom.git
cd stillroom
git checkout v0.12.0
./tools/dev.ps1 Build -Online
./tools/dev.ps1 Capture
./tools/dev.ps1 Check
```

場・配列・公開型の移行比較は `./tools/check-haskell-migration.ps1 -Task Cpu`、実際の水面・転送・後始末の検査は `cabal test migration-native -fnative-graphics-tests` です。前者には固定した GHC と Python／C コンパイラの準備が必要なので、[スクリプトの引数と取得元](https://github.com/M-simplifier/stillroom/blob/v0.12.0/tools/check-haskell-migration.ps1)を確認します。後者は既定で無効の GPU 検査です。通常の `cabal test` が成功しても、この検査を実行したことにはなりません。

配布物を確かめるときは、展開した ZIP に対して `CheckPackage` を行います。ソースの素材や開発用 DLL を偶然借りない条件で、画面・音声・保存・終了を確かめるためです。過去の独立監査の数値すべてが、この日常のコマンドで再計算されるわけでもありません。別ゲームへ持ち込むなら、まずそのゲームのカメラ、変形する地面、影、資源の入れ替えで、同じ保証が必要かを決めてから再検証します。
