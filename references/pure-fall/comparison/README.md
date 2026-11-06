# 固定した盤面で比べる

`fixtures.json`はこの作品の6盤面について、セル座標、ピースの姿勢、
ハードドロップ、結果の盤面・得点・効果を記録しています。ルールを変更したら
`cabal run pure-fall-study -- --json`で再生成し、差を見てください。座標、
回転、終了判定が違うAPL/Prolog版と、そのまま同じ結果になるとは主張しません。
空洞には、接地したT/R0/(1,22)の`target_fits=true`、`target_supported=true`、
`target_reachable=false`も含めています。形が収まるだけの浮いた姿勢を、
到達できない着地の反例として数えていません。

`audit/RotationOracle.hs`は実装と別に記述した28姿勢のセル表とSRSのkick表を
使います。`audit/Retest.hs`は短押し、DASの再押下、偽造された保存データなどの
10件を調べます。独立監査者が作ったコードをそのまま保存し、通常ソースの
整形対象から外しています。`audit/REVIEW.md`は元の監査記録であり、
当時の検査対象と公開ソースでの再現先を区別しています。現在の版を再検査するには、
このプロジェクトから次を実行できます。

```powershell
runghc -XGHC2021 -isrc -ivendor/game-arena/src -ivendor/game-transition/src comparison/audit/Retest.hs
runghc -XGHC2021 -isrc -ivendor/game-arena/src -ivendor/game-transition/src comparison/audit/RotationOracle.hs
```

`Audit.hs`と`RepeatProbe.hs`は発見時の反例です。修正版で旧版の失敗表示を
期待して使うテストではありません。実行ログは無視対象の`.runtime/evidence`に
保持し、範囲と結果は`docs/VERIFICATION.md`にまとめています。
