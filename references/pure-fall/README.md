# PURE / FALL — 同じ純粋な一手で遊び、保存し、調べる

Windowsで遊ぶHaskell / h-raylib製の落ちものゲームです。4モード、SRS回転、
ホールド、予告、音楽・効果音、記録、保存・再開とリプレイがあります。
Practiceでは1ピース前へ戻り、現在の盤面で到達できる着地先と操作列を試せます。

[操作図つきの解説](https://m-simplifier.github.io/fp-game-alpha/studies/pure-fall.html) ·
[厳密なゲーム仕様](GAME-SPEC.md) · [設計](docs/ARCHITECTURE.md) ·
[元の検証記録](docs/VERIFICATION.md) · [独立した比較用検査](comparison/README.md)

これは2026-11-06に選別した**ソースのみの公開版**です。ゲーム規則、host、
検査と独立した回転oracleをそのまま含みます。実行ファイル、フォント、WAV、
ビルド出力は含みません。音声は元の`Audio.hs`が同じ式から生成します。

## このフォルダからビルドする

GHC 9.14.1、Cabal、WindowsのCビルド環境を用意し、このフォルダで実行します。
Haskell依存物とh-raylibのnative依存物は通常のCabal経路で取得します。
固定したパッケージ集合は`cabal.project.freeze`、出所は[DEPENDENCIES](docs/DEPENDENCIES.md)です。

```powershell
cabal build all --enable-tests
cabal test all --test-show-details=direct
./tools/check-api.ps1
cabal run pure-fall
cabal run pure-fall-study -- --json
cabal run pure-fall-study -- --policy
```

初回のnative起動は、音声がなければ元のソースから生成して再生します。
事前に生成する場合は次を使います。ファイルを省いたことによる機能削除はありません。

```powershell
cabal run pure-fall -- --generate-audio --audio-dir assets/audio
```

配布形式を作る場合は`./tools/package.ps1`を実行します。実行物と音声・通知を
ローカルの`release`へ組み立て、展開検査を行います。このソース公開自体は
完成済みのWindows ZIPを提供しません。通常の操作は[README_PLAY](README_PLAY.txt)を参照してください。

## 更新を共有する範囲

`PureFall.Core.gameStep`は`Step Game TickInput [Cue]`です。画面、headless方策、
入力再生、保存検査が同じ規則へ渡ります。描画には`RenderModel`だけを渡し、
乱数状態を隠した観測から方策が選びます。`Session`は端数の時間、短いキー押下、
巻き戻し先、履歴と通知を残します。

盤面は24行×10列、上4行は非表示、回転はSRSです。APL版・Prolog版と同じ規則では
ありません。`comparison/fixtures.json`はこの作品の規則による具体例です。
Practiceの到達探索は時計を止め、重力・固定猶予を含む実時間の攻略を解きません。

## 独立した検査を残す

```powershell
runghc -XGHC2021 -isrc -ivendor/game-arena/src -ivendor/game-transition/src comparison/audit/Retest.hs
runghc -XGHC2021 -isrc -ivendor/game-arena/src -ivendor/game-transition/src comparison/audit/RotationOracle.hs
```

`RotationOracle.hs`には本体と別に記述した28姿勢・SRSのkick表があります。
同じ本体関数を呼ぶ経路の一致だけで、回転が正しいとは判断しません。
`Audit.hs`と`RepeatProbe.hs`は不具合発見時の反例であり、現行版で旧失敗を期待する
通常テストではありません。監査記録にはその違いを保っています。

作者作成のコード・音声生成はMITです。alphaの2ライブラリは
`da3ff4de888be9ec62407d57836b075d763a7c89`からの9ファイルで、元のMIT通知と
[vendor-hashes.json](docs/vendor-hashes.json)を保持しています。h-raylib、raylibの
通知も[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)と`licenses`に残します。
Windowsのシステムフォントはコピーせず、利用できなければ内蔵フォントへ戻ります。
