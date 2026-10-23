> Public alpha port: [current verification and adaptations](../PORTING.md). Historical upstream platform results below are not new alpha verification.

# Haskellで共有する解析器

CLIで型を読むときも、VS CodeやNeovimで型ビューを開くときも、同じHaskellの関数が宣言を取り出します。
0.6.0では、従来TypeScriptにあった抽出処理と読取コマンドをHaskellへ移しました。
単体CLIは、ビルド済みの実行ファイルだけで起動できます。

## 構文解析と型検査を分ける理由

編集中は式が書きかけでも、既に書かれた型やデータ定義を読める必要があります。
そのため、宣言の抽出にはTree-sitter Haskell 0.23.1とCランタイム0.25.10を使い、
意味の確認には別途GHCを使います。CLIとエディタは同じHaskellの抽出処理を呼びます。
UI、監視、キャッシュはエディタ側に残します。

構文表示はGHCやゲームの依存を実行時に必要としません。GHCによる推論を使う場合は、
対象のコンパイラと依存が必要です。この違いを[導入手順](https://github.com/M-simplifier/fp-game-alpha/blob/main/docs/haskell-design.md)でも分けて案内しています。

## 同じゲームで比べた結果

Afterlightの `src`・`tools`・`web` にある31ファイル、379宣言を使いました。
Windows x64、Core i7-13620H、Node.js 24.13.0、GHC 9.6.7の環境で、
旧0.5.0と新0.6.0を交互に実行しています。最初の2回を除き、10回の中央値を示します。

| 起動から全出力を受け取るまで | Node版 | Haskell版 | 所要時間の短縮 |
| --- | ---: | ---: | ---: |
| ファイル一覧 `map` | 217 ms | 154 ms | 約29% |
| 型・データ定義 `outline` | 219 ms | 155 ms | 約29% |
| `Garden.Change.apply` の取得 | 220 ms | 148 ms | 約33% |

プロセスの起動は毎回含み、ファイルシステムのキャッシュは温まった状態です。
GHCによる型推論は含めていません。ソースを絞る条件と出力上限を揃え、
スナップショットID以外の出力が一致することを確認してから比較しました。
CPPとTHに関する2ファイルの警告も、両版で同じです。

常駐プロセスで31ファイルを繰り返し解析する比較は **82 ms → 78 ms** でした。
Haskell側にはJSON通信の時間も含みます。こちらの差は小さく、エディタ全体の操作が
大幅に速くなるという結果ではありません。今回の速度上の利点は、繰り返し起動するCLIで明確でした。

計測値と条件は [JSON記録](benchmarks/windows-0.6.0.json) にあります。
再現するときは、0.5.0のコミット `485d376a1da3c6c33cd7b95c360569d601c1e038` を別フォルダでビルドし、
その `dist` を指定します。測定中は他のビルドやエディタ検証を止めてください。

```sh
node editors/haskell-design/scripts/benchmark-reader.mjs --baseline /path/to/old/editors/haskell-design/dist --root . --include src --include tools --include web
```

## 配布と導入で変わること

- 単体CLIの構文読み取りには、NodeもGHCも不要です。WindowsではPATHから両方を外して起動を確認しています。
- VSIXとNeovimアーカイブはOS・CPU別です。Windows x64の実行ファイルは約43 MiB、VSIXは圧縮後約9 MiBです。
- ソースからのビルドにはGHC/CabalとCコンパイラが加わります。Tree-sitterのランタイムは固定バージョン・SHA-256照合付きで取得し、Haskell側の依存はCabalのfreezeファイルに記録しています。
- Windowsで同じチェックアウトを再ビルドするときは、その解析器を使うエディタやテストを終了します。実行中のファイルがロックされている場合、ビルドは旧版を保って停止します。
- Neovimでは監視・通信のアダプターにNodeが必要です。VS Codeは自身の拡張ホストでその役割を担います。
- 推論型を追加する場合は、従来どおりGHC 9.6.xと対象プロジェクトの依存設定が必要です。

この節の測定・配布サイズは移植元のWindows x64での記録です。公開alphaの結果は[移植記録](../PORTING.md)を参照してください。

抽出処理を一か所で保守でき、CLIは起動も軽くなりました。この二点を理由にネイティブ版を採用しています。
構文の未対応範囲や、型だけでは実行時の振る舞いを証明できないという限界は引き続きあります。
