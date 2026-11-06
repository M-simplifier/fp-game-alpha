# Prolog Tetris — 空きマス、操作列、到達先を問い合わせる

四つの空きマスを与えて、そこを覆う種類・向き・位置を求めます。続けて、いまの
ピースをそこへ運べるかを調べ、見つかった操作列を再生できます。形の関係、
通常プレイ、探索、再生は同じPrologの移動規則を使います。

[実際のProlog出力を動かす解説](https://m-simplifier.github.io/fp-game-alpha/studies/prolog-fall.html) ·
[述語の使い方](docs/IMPLEMENTATION.ja.md) ·
[数学的な考察](docs/MATHEMATICAL-LENS.ja.md) · [元の検証記録](docs/VALIDATION.ja.md)

これは2026-11-06に選別した**ソースのみの公開版**です。元の独立した試作の
Prolog規則・検査・汎用Cブリッジを含み、SWI-Prolog/raylibのバイナリは含みません。
元のソース基準は`bb97e211b231ce682abd7d92773fe876fe521d13`です。
ゲーム規則と期待値を保ち、実行器を指定する入口と公開用の再生成手順を整えました。

## 画面を開かずに問い合わせる

SWI-Prolog 10.0.2の`swipl`を用意し、このフォルダで実行します。

```powershell
swipl -q -s tests/core_tests.pl
swipl -q -s src/examples.pl
```

スクリプトを使う場合、`PROLOG_FALL_SWIPL`で実行ファイルを指定できます。
未指定なら、後述のsetupで作る`.runtime/swipl/bin/swipl.exe`を使います。

```powershell
$env:PROLOG_FALL_SWIPL = (Get-Command swipl).Source
./scripts/test.ps1
./scripts/query-demo.ps1
```

たとえば`cover_cells([6-9,5-10,5-8,5-9], Pose)`から
`Pose = pose(t,1,4,8)`を得ます。`legal_pose/3`の座標を未定にする問いでは、
有限領域制約を課すことと`labeling/2`で答えを列挙することを分けてください。
盤面が未定のまま何でも逆算できる実装ではありません。

## Windowsで遊ぶ

Windows x64、PowerShell、Visual Studio C++ x64ビルドツールとWindows SDKが必要です。
このフォルダで、固定した公式配布物を取得・検査・展開します。

```powershell
./scripts/setup.ps1
./Play.cmd
./Demo.cmd
./scripts/smoke.ps1
```

Qで到達できる固定位置を調べ、左右で候補を選び、Enterで経路を再生します。
通常の移動・回転・固定をPrologが実行し、Cは汎用の画面・入力・時刻を渡します。
初回取得の出所と固定ハッシュは[docs/SOURCES.md](docs/SOURCES.md)にあります。

## 解説をソースから作り直す

Python 3とSWI-Prologを用意して、次を実行します。Gitの元の履歴は不要です。

```powershell
python scripts/build-guide.py
python scripts/validate-guide.py
```

`docs/prolog-tetris-explained.html`が生成されます。Prologが全34候補を検査し、
全614姿勢、操作ごとのフレーム、逆向きの問い、制約と列挙の違い、元ソースの
SHA-256と抜粋を埋め込みます。ブラウザはその記録を表示し、別のゲーム規則を
JavaScriptで実装しません。`source_commit`は元のsnapshot基準を示し、生成時点の
ソースの同一性は各ファイルのSHA-256で示します。

生成器の入力として含めた`docs/guide/native-demo.png`は作者が撮影した元の試作画面です。
PlaywrightとChromeがあれば`node scripts/check-guide.cjs`で操作・小画面・印刷も検査できます。
Playwrightの取得場所は`PROLOG_GUIDE_PLAYWRIGHT`、ブラウザは`PROLOG_GUIDE_BROWSER`で指定できます。

## 到達探索の範囲

屋根のある空洞には形が収まって接地しても、出現位置から到達できません。
探索は種類・回転・原点をキーにし、表示候補だけを最後にセル集合でまとめます。
見た目が同じIでも、回転番号を消すと次の回転結果を変える場合があります。

この探索は時計を止めた有限BFSです。経路再生中も重力と固定待ちを止めます。
最短操作数、通常プレイの最短時間、未知の次ピースにも勝てる戦略は別の問いです。
回転の補正は最初に成功する独自のkickで、SRSではありません。

作者所有の新規公開コード・説明・画面図はMITです。第三者の処理系や依存物の
条件は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)に残しています。
それらのバイナリを配布する場合の通知確認と、このソース公開は別の範囲です。
