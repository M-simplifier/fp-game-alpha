# ブラウザで遊び始めるまでの設計判断

ページを開くと準備が自動で進み、最後のクリックでマウスを捕捉して遊び始める。
AfterlightのHaskell/raylib実装を保ったまま、そのために採る方針と判断理由をまとめる。
ビルド手順は[README](README.md)、WASM・FS・FFIの契約は[host/README](host/README.md)を参照。
以下は設計判断と現実装の対応です。実際の操作は、対象ブラウザで別途確認します。

1. **ロード: ダウンロード完了と、操作できる準備完了を分ける。**

   **採用する:** 軽いHTMLの起動画面を先に表示し、クリックを待たず取得・コンパイル・ワールド生成・GPU準備を進める。
   取得はmanifestの展開後バイト数、チャンク生成は実際の完了数を進捗にする。総量不明の段階は不定進捗にする。
   Afterlightではチャンク作成と最初の描画を小さな処理単位に分け、全て終わってからPlayを表示する。
   各単位の間は`scheduler.yield()`でブラウザへ戻る。未対応時は`setTimeout`へ戻すが、
   [入れ子タイマーの最低4ms](https://developer.mozilla.org/en-US/docs/Web/API/Window/setTimeout#nested_timeouts)が多数の単位に累積するため、対応ブラウザではyieldを優先する。

   **条件付き:** 大きな任意アセットは後から読む。ただし、取得完了前にHaskellが同期的に読むパスには適用しない。
   Workerへの移動は、処理分割後にも残る停止時間を測ってから判断する。
   **採用しない:** 実処理と無関係な百分率、初期化前のReady表示、同期WASM呼出をPromiseで囲むだけの非同期化。

   根拠: [Godotの進捗通知](https://docs.godotengine.org/en/stable/tutorials/platform/web/customizing_html5_shell.html)は総量不明も扱う。
   [MDNの処理分割](https://developer.mozilla.org/en-US/docs/Web/API/Scheduler/yield)は、ブラウザへ実行権を返して表示・入力を進める。
   [PlayCanvasの公開事例](https://developer.playcanvas.com/user-manual/optimization/load-time/)では、Virtual Voodooがタイトル画面中に本編を準備する。

2. **入力: Playの新しいクリックで、マウス捕捉と音声を開始する。**

   **採用する:** 自動準備後の新しいクリックで、直ちにPointer Lockを要求し、音声を開始・再開する。
   捕捉成功を確認して操作を始める。全画面も同時に要求する場合はPointer Lockを先に呼ぶ。
   Escapeによる捕捉解除は再捕捉の契機にせず、Pauseとして扱う。再開操作で改めて捕捉する。
   ゲームが望む捕捉状態と、ブラウザが実際に許可した状態を別々に持つ。

   **条件付き:** iframeの許可設定や実行環境固有の拒否は、要求時の状態と例外名を見て診断する。
   **採用しない:** `event.isTrusted`を保存して権限が続いていると判断すること、毎フレームの再要求、拒否を無視したプレイ開始。

   [HTMLのtransient activation](https://html.spec.whatwg.org/multipage/interaction.html#tracking-user-activation)は長い同期処理中も延長されない。
   拒否は要求直前のactivation、クリックからの時間、focus・visibility、例外の`name`を記録する。
   `WrongDocumentError`と`root document ... not valid`の組は[Chromiumの`kWrongDocument`](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/page/pointer_lock_controller.cc)であり、gesture不足の`NotAllowedError`、権限拒否の`SecurityError`と区別する。
   調査したChromium mainのWindows実装では[要求時・許可後のnative viewのfocus確認や、要求中の非表示化](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/renderer_host/render_widget_host_impl.cc)でこの結果が返る。
   [focusの模擬は`document.hasFocus()`をtrueにできる](https://raw.githubusercontent.com/chromium/chromium/main/content/public/test/scoped_page_focus_override.h)ため、その値だけで実ウィンドウの状態や自動操作環境の問題を断定しない。
   通常タブを実際に前面へ出したユーザーのクリックで、`pointerlockchange`とcanvasの捕捉を記録することを、通常プレイの確認境界とする。
   [Pointer Lockの条件と呼出順](https://developer.mozilla.org/en-US/docs/Web/API/Element/requestPointerLock)、[音声開始の条件](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API/Best_practices)も参照。

3. **表示: 画面に合う画質を既定にし、軽量化は選べるようにする。**

   **採用する:** viewport全体をゲーム領域にし、読み込み表示や操作ボタンを重ねる。
   canvasの描画バッファはCSS表示寸法×DPRに合わせ、ディスプレイの実ピクセルを保つ。
   画質は「高」100%を既定にし、「標準」75%・「軽量」50%を選べる。選択は次の訪問にも引き継ぐ。
   縮小するのは3D用RenderTextureだけ。canvas・HUD・メニュー・入力座標は表示密度に保つ。
   品質を単にcanvas寸法へ掛けると、既存UIの最小サイズ規則と干渉して文字の見かけの大きさまで変わるため、分離した。
   ハードウェアのtexture/renderbuffer上限だけは取得時に調べ、必要なら縦横比を保って収める。
   Afterlightで使用するEmscripten出力はcanvasの矩形全体からマウス座標を換算するため、`object-fit`だけで要素内部に余白を作らない。
   描画サイズの所有者もhostへ揃える。固定版GLFWは全画面中のresizeでcanvasを`screen`寸法へ上書きするため、
   `host/refresh-memory.js`でその暗黙操作を分離する。CSS・canvas・raylib/FBOの寸法が食い違うと、庭が画面の一隅にだけ描かれる。

   **条件付き:** 軽量設定は、実際の場面の応答と文字・細部の見え方を比べて選ぶ。解像度はマウス感度やゲーム規則を変えない。
   **採用しない:** 負荷を測る前の一律720p上限、利用者に分からない画質低下、品質設定で入力や保存の意味を変えること。
   [Unityの表示・描画解像度の分離](https://docs.unity.com/en-us/engine/6000.0/manual/platform-specific/webgl/develop/canvas-size)と
   [PlayCanvasのDPRと負荷](https://developer.playcanvas.com/user-manual/optimization/runtime-devicepixelratio/)を根拠とする。
   [MDN](https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/WebGL_best_practices#consider_rendering_to_a_smaller_back_buffer)も低解像度化を画質と速度の交換として扱う。
   3Dの解像度とUIを分ける構成は[Godotの公式文書](https://docs.godotengine.org/en/stable/tutorials/rendering/multiple_resolutions.html#scaling-2d-and-3d-elements-differently)も参照した。
   当初の固定720p方針は、この交換を既定で強制し、景色とHUDを一緒に拡大していた。実際の利用者の画質指摘を受けて撤回した。

4. **配信: 取得・コンパイルを並行化し、再訪時には再取得を減らす。**

   **採用する:** WASMの`compileStreaming`とアセット取得を早く始め、必要なimportsが揃ってからinstantiateする。
   アセット取得のqueueはraylibの初期化から独立させる。各取得workerがfilesystem待ちで止まると、並行数だけ取得して残りが直列待ちになる。
   WASMはfetchの元の`Response`をコンパイラへ渡し、`clone()`側で取得進捗を測る。
   [ChromiumはレスポンスのURLとキャッシュメタデータを使う](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/bindings/core/v8/v8_wasm_response_extensions.cc)ため、進捗表示用の`new Response(stream)`で置き換えない。
   `.wasm`は`application/wasm`、圧縮済みファイルは実体に合う`Content-Encoding`で配信する。
   内容が変わるとURLも変わるファイルだけを長期キャッシュし、HTML・manifestは再検証する。異なるビルドのWASM・JSを混ぜない。

   **条件付き:** 使用文字を列挙できるフォントはサブセット化する。AfterlightではASCII・`glyphs.txt`を必須とし、`uiCorpus`を含むソース内の文字を保守的な候補にする。
   候補は元フォントが持つ文字と共通する部分だけを採り、未収録の絵文字がコメントにあるだけでビルドを止めない。全UIの欠字検査は別に必要。
   `checks/assets.py`で、生成フォントの輪郭・metrics・収録文字と元フォントを照合する。
   自由入力や翻訳を加えるゲームでは、その文字集合に合わせて作り直す。
   大きなキャッシュの保持やオフライン動作が必要になった場合に、Cache API等を追加する。
   **採用しない:** 最初からService Workerを必須にすること、キャッシュでワールド生成時間まで短くなると見なすこと。

   根拠: [WASM streaming](https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/instantiateStreaming_static)、
   [Unityの圧縮・MIME設定](https://docs.unity3d.com/6000.0/Documentation/Manual/webgl-deploying.html)、
   [HTTPキャッシュと内容別URL](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Caching)、
   [fontToolsのOTFサブセット](https://fonttools.readthedocs.io/en/stable/subset/)。

5. **中断・保存・失敗: 続けられる状態と、止めるべき状態を区別する。**

   **採用する:** focus・visibility・捕捉解除を実際のホスト入力として扱い、Pauseは重複通知でも一度の状態変更にする。
   復帰時は押下状態と時計を整え、非表示中の経過時間を大量のゲームtickへ変換しない。
   保存成功は永続化成功後に示す。容量不足・拒否時は失敗をHaskellへ返し、以前の保存を保持する。
   読み込み・WASM・WebGL障害は停止した段階を示し、セーブを消さずに再読込できるようにする。
   Pointer Lock・音声の拒否は、その操作をやり直せる状態として扱う。

   **条件付き:** 自動保存のタイミングはゲームの仕様で決める。終了直前のイベントを唯一の保存契機にはしない。
   **採用しない:** 捕捉拒否をプログラム障害として終了すること、プログラム障害や保存失敗を握り潰して成功を表示すること。
   根拠: [非表示時のrAF制限](https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API)、
   [beforeunloadの限界](https://developer.mozilla.org/en-US/docs/Web/API/Window/beforeunload_event)、
   [ブラウザ保存の容量と例外](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)。

## 対象ブラウザで確認すること

ビルドとNode検査のあと、実際の画面で準備中の表示、Playクリック、捕捉拒否と再試行、
移動・採掘・建築、保存と再読込、Pauseと復帰、音声、写真の取得を確かめます。
描画設定を比較するなら、同じ場面と画面サイズで表示と処理時間を見ます。
圧縮やキャッシュの検査だけでは、ワールド生成の待ち時間や操作感は分かりません。
実行コマンドと現在確認できた範囲は[検証ガイド](../../../docs/verification.md)を参照してください。
