# Haskellで共有する解析器

単体CLI、VS Code、Neovimは、同じHaskellの読取処理で宣言を取り出します。
CLIの構文読み取りはビルド済み実行ファイルだけで動きます。
エディタ側は表示、ファイル監視、キャッシュと通信を担当します。

## 構文解析と型検査を分ける理由

編集中は式が書きかけでも、既に書かれた型やデータ定義を読める必要があります。
宣言の抽出にはTree-sitter Haskell 0.23.1とCランタイム0.25.10を使い、
意味を確認する場合だけGHCを呼び出します。
構文表示は、実行時にGHCやゲームの依存を必要としません。
推論にはGHC 9.14と対象プロジェクトの依存設定、ワークスペースへの明示的な信頼が必要です。

## ビルドと配布

`editors/haskell-design`で`npm ci`、`npm run build`、`npm test`を実行します。
ソースからのビルドにはGHC 9.14.1、Cabal 3.18.2とCコンパイラを使います。
Tree-sitterは固定バージョンとSHA-256で取得し、Haskell依存はfreezeファイルに記録しています。
`npm run package:vsix`と`npm run package:neovim`はOS・CPU別の配布物を作ります。
配布物には、実際に使った依存のライセンスを同梱します。

Windowsで再ビルドするときは、その実行ファイルを使っているエディタやテストを終了します。
実行中のファイルがロックされていれば、ビルドは旧版を保って停止します。
Neovimの監視・通信アダプターにはNodeが必要です。VS Codeでは拡張ホストが担当します。
Linuxの推論ヘルパーには選択したGHCの共有ライブラリも必要です。

[導入手順](https://github.com/M-simplifier/fp-game-alpha/blob/main/docs/haskell-design.md)、
[移植元と現在の境界](../PORTING.md)、
[現在の検証手順](https://github.com/M-simplifier/fp-game-alpha/blob/main/docs/verification.md)を参照してください。
構文の未対応範囲や、型だけで実行時の振る舞いを証明できないという限界は残ります。

WSL上のLinuxプロセスでWindows側のチェックアウトを監視すると、ディレクトリ通知を
取りこぼす場合があります。Windows側のソースにはWindows版エディタを使い、
Linux版で自動監視するソースはLinux側のファイルシステムに置いてください。
