# 新しいゲームをエディタで開けるようにする

この文書は公開 Afterlight の技術資料を移植したものです。ゲーム固有の構成・版・過去の検証は参考例であり、新作の既定構成や現行 alpha の実行保証ではありません。必要な節だけを読み、企画に合う設計を新規に行ってください。出典と変更範囲は [移植記録](../README.md) を参照。

現行 alpha が提供するのは [compiler CLI](../../tooling.md) と [editor 接続](../../editors.md) です。以下に出る元の Haskell Design / map・outline・show / 導入スクリプト一式は、この移植によって同梱・移植完了したことにはなりません。未同梱のツールの説明は上流資料として扱い、現在使える CLI とソース読取りで作業を続けてください。

Haskell Designは、Afterlight以外のHaskellコードでも型と実装を切り替えて読める。
ただし、スキルをコピーしただけでは拡張やGHCの依存パッケージはインストールされない。
新作の開発環境を用意するとき、または利用者がエディタ対応を求めたときは、
ゲームの実装に加えて、そのプロジェクトを開くところまで接続する。

現行の **[エディタ接続手順](../../editors.md)** を使う。元の haskell-editor-setup は別の上流スキルである。
別repoへ持っていく場合は `fp-gamedev`、`haskell-excellence`、`haskell-editor-setup` の
3フォルダを、references・scriptsを含めて `.agents/skills/` へコピーする。
導入スキルが見当たらなければ、[公開リポジトリ](https://github.com/M-simplifier/garden-of-afterlight/tree/main/.agents/skills)
から取得する。個人のdotfilesは不要。

利用者からの依頼例:

```text
fp-gamedevで作ったこのゲームを、VS Codeで型から読めるようにしたいです。
haskell-editor-setupを使い、このプロジェクトのGHC・HLS・Cabal設定に合わせて
セットアップしてください。フォルダを開いて、型ビュー・定義ジャンプ・補完・診断が
実際のゲームコードで動くところまで確認してください。
```

新作では、型ビュワーのフル機能も必要ならGHC 9.6.xが現行の対応範囲。
既存プロジェクトのGHCを勝手に変更しない。他の版では宣言表示とHLSの編集支援を使い、
ビュワーのGHC解析が未対応であることを伝える。

Afterlightの `setup.mjs prepare/configure` はAfterlight専用。
新作には、導入スキル内の別プロジェクト用手順と設定生成スクリプトを使う。
パッケージ名、library/executable/testの分け方、ソース配置、native/Wasmのフラグは
作ったゲームのものを使う。生成された絶対パスやパッケージIDを配布用設定としてコピーしない。

VS Codeでは拡張導入後にプロジェクトの `.vscode/settings.json` を接続すれば、
通常の「フォルダを開く」で利用できる。AIは既存設定を保って必要な項目を統合し、
実際のルールとIO側、検査用コードで動作を確かめる。ゲームを作った人の環境だけで
動く設定を残さず、次の利用者が同じスキルで自分の環境に接続できるようにする。
