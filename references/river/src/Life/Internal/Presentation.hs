{-# LANGUAGE OverloadedStrings #-}

module Life.Internal.Presentation
  ( interactionLabel,
    clockLabel,
    taskProgress,
    journal,
    lastNightReport,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Life.Internal.Core

interactionLabel :: Game -> Text
interactionLabel g = case interactionTarget g of
  Nothing -> "畑・薪・かまど・ご近所さんへ歩こう"
  Just (AtBed c) -> case Map.lookup c (gBeds g) of
    Just (Bed Empty _) -> "E  カブの種をまく"
    Just (Bed Ripe _) -> "E  カブを収穫する"
    Just (Bed _ False) -> "E  じょうろで水をやる"
    _ -> "E  カブの様子を見る"
  Just (AtWood c) -> case Map.lookup c (gWood g) of
    Just (Bundle _ False) -> "E  新しい薪を並べる"
    Just (Bundle n _) | n >= dryGoal -> "E  乾いた薪をしまう"
    _ -> "E  薪の乾き具合を見る（一晩ごとに乾く）"
  Just AtNeighbor -> case gDinner g of
    NotPromised -> "E  ご近所さんに声をかける"
    Promised -> "E  夕ごはんの約束を話す"
    DinnerReady -> "E  夕ごはんを届ける"
    DinnerShared -> "E  ご近所さんとおしゃべり"
  Just AtCook -> "E  カブと乾いた薪で夕ごはんを作る"
  Just AtHome -> "E  家に帰って眠る（次の日へ）"
  Just AtMail -> "E  明日の天気を読む"

clockLabel :: Game -> Text
clockLabel g =
  let minutes = 8 * 60 + gTicks g * (12 * 60) `div` dayLengthTicks
      h = minutes `div` 60
      m = minutes `mod` 60
   in tshow h <> ":" <> (if m < 10 then "0" else "") <> tshow m

taskProgress :: Game -> [Text]
taskProgress g = case gDinner g of
  DinnerShared -> ["✓ ナギと夕ごはんを分け合った", "これからも畑・小道・屋根・椅子で、自分の庭を。"]
  DinnerReady -> ["✓ 夕ごはんができた", "ナギに会って、温かいうちに分け合おう（期限なし）"]
  status ->
    [ if status == Promised then "✓ ナギと夕ごはんの約束" else "□ ご近所のナギに声をかける",
      if gTurnips g > 0 then "✓ カブを収穫した" else "□ 畑に種と水。二晩育ててカブを収穫",
      if gDryWood g > 0 then "✓ 乾いた薪を用意した" else "□ 乾いた薪を一束しまう",
      "□ かまどで夕ごはんを作る"
    ]

journal :: Game -> [Text]
journal g =
  [ "川音の家  ·  " <> tshow (gDay g) <> "日目",
    "朝を急ぐ必要はありません。眠ると次の日になります。",
    "カブ：種をまく → 水をやる → 二晩育てる → 収穫。",
    "雨は屋根のない畑に届きます。屋根の下はじょうろで。",
    "薪：ひと晩ごとに乾きます。晴れか屋根の下で50%、雨ざらしで12.5%。",
    "建築：屋根は真下だけを守ります。材料は好きなだけ使えます。",
    "ナギとの約束に期限はありません。好きな順で過ごして大丈夫。",
    forecastLabel g
  ]
    ++ lastNightReport g
    ++ taskProgress g

lastNightReport :: Game -> [Text]
lastNightReport g = case gNight g of
  Nothing -> ["最初の朝。種と薪を並べて、庭の明日を準備しよう。"]
  Just (NightReport d grown rainCount woodChanges) ->
    [ tshow d <> "日目の夜の記録（" <> (if weatherFor d == Rainy then "雨" else "晴れ") <> "）",
      "育った畑：" <> tshow grown <> "か所。雨が届いた畑：" <> tshow rainCount <> "か所。"
    ]
      ++ [ "薪 "
             <> cellLabel c
             <> (if covered then " 屋根あり：" else " 雨ざらし：")
             <> percentage before
             <> " → "
             <> percentage after
             <> "（+"
             <> percentage (after - before)
             <> "）"
         | (c, before, after, covered) <- woodChanges
         ]
  where
    cellLabel (Cell x z) = "(" <> tshow x <> "," <> tshow z <> ")"
    percentage value =
      let tenths = value * 1000 `div` dryGoal
       in tshow (tenths `div` 10)
            <> (if tenths `mod` 10 == 0 then "" else "." <> tshow (tenths `mod` 10))
            <> "%"
