# Haskell Design

Haskellのファイルを開き、データ定義と関数の型から読み始めるためのツールです。
VS CodeとNeovimでは、必要な関数の実装を開き、同じソースの編集に戻れます。
単体コマンドでも、対象のプロジェクトを指定して宣言や関数を取得できます。

[導入・ビルド・プロジェクトへの接続](https://github.com/M-simplifier/fp-game-alpha/blob/main/docs/haskell-design.md)を参照してください。
このパッケージだけを展開した場合も、Afterlightや個人設定は必要ありません。
配布物は拡張ホストのOS・CPUに合わせます。WSLやSSHでは、デスクトップ側とは異なる場合があります。

## コマンドで読む

ビルドまたは配布物の展開後、ツールのディレクトリから次を実行できます。
Windowsでは実行ファイル名に `.exe` を付けます。

```sh
dist/haskell-design map --root examples
dist/haskell-design outline --root examples --module Domain.Order
dist/haskell-design show --root examples --module Domain.Order --symbol confirm
```

別のゲームを読むときは、`--root` をそのゲームのフォルダに替えます。
構文の読み取りにはNodeやGHCは不要です。型検査は行わず、署名のない関数は `:: ?` と表示します。
対象の絞り方、続きの取得、未対応構文は[読取コマンドの使い方](docs/reader.md)にあります。

## 編集とGHCによる確認

VS CodeではVSIXをインストールし、**Open Design View** と **Edit Source** で切り替えます。
Neovimでは配布先を `runtimepath` に追加し、次を呼びます。

```lua
require('haskell-design').setup()
```

`:HaskellDesign` で設計表示、`:HaskellDesignSource` で編集に戻ります。
ソースを既定にする場合は `setup({ design_first = false })` を使います。
補完や未保存コードの診断は、対象プロジェクトに合うHLSで行います。
このビューワーを入れるだけではHLSの設定は完了しません。

GHCによる型推論とIO表示は、信頼したプロジェクトでGHC 9.6.xと依存設定を用意した場合に使えます。
`Pure` は対応範囲でIOが見つからなかったという表示です。純粋性の証明や依存ライブラリ内部の監査ではありません。
[表示・キャッシュ・IO判定の契約](docs/automatic-design.md)に、未保存の編集や解析失敗時の扱いを記載しています。

[移植元と公開alphaの検証範囲](PORTING.md)、[旧版の検証記録](docs/verification.md)、
[ネイティブ化の理由と測定](docs/native.md)はそれぞれ分けて記録しています。
元のMIT表記と[依存物の通知](THIRD_PARTY_NOTICES.md)を保持してください。
