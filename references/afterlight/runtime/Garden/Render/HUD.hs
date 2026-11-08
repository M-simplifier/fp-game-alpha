{-# LANGUAGE RecordWildCards #-}

-- The authored HUD and photo layout is shared by the desktop and browser
-- hosts. Painters receive coordinates in the layout's viewport units.
module Garden.Render.HUD
  ( Painter (..)
  , Color (..)
  , renderInterface, renderMenu, renderSaveFeedback
  , renderPhotoFrame, renderPhotoChrome, renderPhotoToast
  ) where

import Control.Monad (forM_, when)
import qualified Data.Map.Strict as M
import Garden.Mesh (RGB (..), palette)
import Garden.Photo
import Garden.Types
import Garden.View
import Text.Printf (printf)

data Color = Color !Int !Int !Int !Int

data Painter = Painter
  { viewport :: !(Int, Int)
  , drawRectangle :: Int -> Int -> Int -> Int -> Color -> IO ()
  , drawRectangleGradientV :: Int -> Int -> Int -> Int -> Color -> Color -> IO ()
  , drawLine :: Int -> Int -> Int -> Int -> Color -> IO ()
  , textAt :: String -> Float -> Float -> Float -> Color -> IO ()
  , drawText :: String -> Int -> Int -> Int -> Color -> IO ()
  , textWidth :: String -> Float -> IO Float
  , projectPoint :: V3 -> IO (Float, Float)
  }

renderInterface :: Painter -> String -> SceneView -> Bool -> Float -> IO ()
renderInterface Painter {..} quality view debug fps = do
  let (width, height) = viewport
      wf = fromIntegral width
      hf = fromIntegral height
      ink = Color 239 241 219 255
      soft = Color 179 207 196 255
      gold = Color 234 204 139 255
      label = textAt
  drawRectangleGradientV 0 0 width 130 (Color 7 20 25 178) (Color 7 20 25 0)
  label quality 210 26 14 soft
  label (regionName view) 32 20 32 ink
  drawLine 33 64 134 64 gold
  label (sceneObjective view) 32 77 22 ink
  let lifeW = 180; lifeX = width - lifeW - 34
  label "生命" (fromIntegral lifeX) 27 15 soft
  drawRectangle lifeX 55 lifeW 4 (Color 22 46 49 220)
  drawRectangle lifeX 55 (round (fromIntegral lifeW * sceneLife view / 100)) 4 (if sceneLife view < 30 then Color 237 125 115 255 else Color 165 220 182 255)
  label ("光 " <> show (sceneCharges view) <> "   Q 使う") (fromIntegral lifeX) 70 15 soft
  -- Small ordinal markers remain readable even when gem colors coincide.
  forM_ (zip [0 :: Int ..] (sceneGems view)) $ \(i, (g, count)) -> do
    let x = wf - 213 + fromIntegral (i * 47)
    drawRectangle (round x) 108 8 8 (toColor (palette (Ore g)) 1)
    label (show count) (x + 13) 102 15 ink
  let cx = width `div` 2
      cy = height `div` 2
      targetColor = case sceneTarget view of EnemyTarget -> Color 255 130 139 240; _ -> Color 245 239 208 200
  drawLine (cx - 7) cy (cx - 3) cy targetColor
  drawLine (cx + 3) cy (cx + 7) cy targetColor
  drawLine cx (cy - 7) cx (cy - 3) targetColor
  drawLine cx (cy + 3) cx (cy + 7) targetColor
  when (sceneDashRecovery view > 0) $ do
    drawRectangle (cx - 24) (cy + 27) 48 2 (Color 22 46 49 150)
    drawRectangle (cx - 24) (cy + 27) (round (48 * (1 - sceneDashRecovery view))) 2 gold
  drawRectangleGradientV 0 (height - 172) width 172 (Color 4 18 24 0) (Color 4 18 24 185)
  let hint = sceneHint view
  hintWidth <- textWidth hint 22
  let hintX = max 25 ((wf - hintWidth) / 2)
  label hint hintX (hf - 143) 22 ink
  let slotWidth = 66; start = cx - 198
  forM_ (zip [0 ..] (sceneSlots view)) $ \(i, (m, count)) -> do
    let x = start + i * slotWidth; selected = i == sceneSelection view `mod` 6
    drawRectangle x (height - 100) 60 60 (if selected then Color 81 104 91 220 else Color 12 33 38 188)
    when selected $ drawRectangle x (height - 103) 60 3 gold
    drawRectangle (x + 23) (height - 86) 14 14 (toColor (palette m) 1)
    label (show (i + 1)) (fromIntegral (x + 5)) (hf - 96) 15 soft
    label (show count) (fromIntegral (x + 35)) (hf - 64) 17 ink
  label (materialName (slotMaterial (sceneSelection view))) (wf / 2 - 30) (hf - 30) 15 soft
  label "C  灯花を編む" 32 (hf - 74) 19 soft
  label "白石 2 ＋ 宝石 1" 32 (hf - 45) 16 soft
  label ("TAB  素材棚 " <> show (sceneSelection view `div` 6 + 1) <> " / 2") (wf / 2 + 216) (hf - 64) 16 soft
  label "ESC  一時停止" (wf - 172) (hf - 38) 14 soft
  when (not (null (sceneNotice view))) $ do
    measured <- textWidth (sceneNotice view) 20
    let noticeWidth = measured + 48
        noticeX = max 24 ((wf - noticeWidth) / 2)
    drawRectangle (round noticeX) (round (hf * 0.72 - 12)) (round noticeWidth) 47 (Color 6 27 32 210)
    label (sceneNotice view) (noticeX + 24) (hf * 0.72) 20 gold
  forM_ (sceneKin view) $ \(KinView pos g bond safe) -> do
    let d = distance (sceneEye view) pos
    when (d < 20 && dot (minus pos (sceneEye view)) (sceneForward view) > 0) $ do
      (sx, sy) <- projectPoint (plus pos (V3 0 4.4 0))
      when (sx > 50 && sx < wf - 150 && sy > 120 && sy < hf - 180) $ do
        label (if safe then "光の記憶" else kinName g <> "  ·  " <> gemName g) (sx - 85) sy 16 ink
        label (if bond >= 2 then "結ばれている" else if bond == 1 then "もうひとつの贈り物を" else "宝石を待っている") (sx - 55) (sy + 24) 15 soft
  forM_ (sceneEnemies view) $ \(EnemyView pos health windup kind) -> do
    let delta = minus (plus pos (V3 0 1.7 0)) (sceneEye view)
        d = magnitude delta
        maximumHealth = case kind of Wanderer -> 4; Custodian -> 7; Skitter -> 3; SkyMoth -> 3 :: Float
    when (d < 13 && dot (unit delta) (sceneForward view) > 0.96) $ do
      (sx, sy) <- projectPoint (plus pos (V3 0 3.5 0))
      let x = round sx - 28; y = round sy
      when (y > 120 && y < height - 175) $ do
        drawRectangle x y 56 3 (Color 32 20 38 210)
        drawRectangle x y (round (56 * fromIntegral health / maximumHealth)) 3 (if windup > 0 then Color 255 92 116 255 else Color 224 164 169 220)
  when debug $ do
    drawRectangle 24 135 330 52 (Color 0 0 0 170)
    drawText (printf "%.1f FPS  /  %.1f ms" fps (1000 / max 1 fps)) 33 143 16 ink
    drawText (printf "%.0f voxels / revision %d" (fromIntegral (M.size (sceneCells view)) :: Float) (sceneRevision view)) 33 163 15 ink

renderMenu :: Painter -> String -> Maybe Bool -> Bool -> IO ()
renderMenu Painter {..} resume saved invertY = do
  let (w, h) = viewport
      x = fromIntegral w / 2 - 440; y = fromIntegral h / 2 - 205
  drawRectangle 0 0 w h (Color 3 14 23 211)
  textAt "余光の庭" x y 38 (Color 239 235 207 255)
  textAt resume x (y + 75) 23 (Color 207 229 216 255)
  textAt "F5   記録する" x (y + 118) 23 (Color 207 229 216 255)
  textAt "ENTER  記録して終了" x (y + 161) 23 (Color 207 229 216 255)
  textAt ("I  視点の上下反転：" <> if invertY then "ON" else "OFF") x (y + 212) 18 (Color 175 200 192 255)
  textAt "F11  全画面   ·   F2  撮影表示" x (y + 246) 17 (Color 175 200 192 255)
  textAt "F6  フォトモード   ·   F12  撮影" x (y + 271) 17 (Color 175 200 192 255)
  forM_ saved $ \ok -> textAt (if ok then "保存しました" else "保存できませんでした。F5 で再試行") x (y + 296) 18 (Color 238 211 148 255)
  let guide = textAt; gx = x + 465; soft = Color 175 200 192 255
  guide "旅の手引き" gx (y + 8) 25 (Color 239 235 207 255)
  forM_
    ( zip
        [0 :: Int ..]
        [ "WASD  移動   マウス  視点",
          "SPACE  跳ぶ   SHIFT  走る",
          "E  回避   左クリック  採掘・攻撃",
          "右クリック  置く   1–6 / ホイール  切替",
          "TAB  素材棚を切り替える",
          "F  宝石を贈る・灯りの下へ迎える",
          "Q  生命の光を使う   C  灯花を編む",
          "飛翔後  SPACE 上昇 / CTRL 下降",
          "30秒ごとに自動保存"
        ]
    )
    $ \(i, line) ->
      guide line gx (y + 70 + fromIntegral i * 34) 19 soft

renderSaveFeedback :: Painter -> Maybe Bool -> IO ()
renderSaveFeedback Painter {..} status = forM_ status $ \ok ->
  let (w, h) = viewport
  in textAt
    (if ok then "記録しました" else "記録できませんでした。F5 で再試行")
    (fromIntegral w - 430)
    (fromIntegral h - 112)
    18
    (if ok then Color 211 223 183 255 else Color 245 150 139 255)

renderPhotoFrame :: Painter -> Photo -> IO ()
renderPhotoFrame Painter {..} p = when (photoCinema p) $ do
  let (w, h) = viewport
      bar = max 0 (round ((fromIntegral h - fromIntegral w / 2.39) / 2 :: Float))
  drawRectangle 0 0 w bar (Color 0 0 0 255)
  drawRectangle 0 (h - bar) w bar (Color 0 0 0 255)

renderPhotoChrome :: Painter -> Photo -> Maybe String -> IO ()
renderPhotoChrome Painter {..} p message = do
  let (w, h) = viewport
  when (photoGrid p) $ do
    let inset = if photoCinema p then max 0 (round ((fromIntegral h - fromIntegral w / 2.39) / 2 :: Float)) else 0
        ink = Color 238 234 208 65
    forM_ [1, 2] $ \n -> do
      drawLine (w * n `div` 3) inset (w * n `div` 3) (h - inset) ink
      drawLine 0 (inset + (h - 2 * inset) * n `div` 3) w (inset + (h - 2 * inset) * n `div` 3) ink
  drawRectangle 24 24 260 66 (Color 6 21 28 215)
  textAt "余光を写す" 40 31 26 (Color 243 231 191 255)
  textAt "時を止めた庭 / PHOTO MODE" 41 65 13 (Color 174 205 193 255)
  let label = printf "画角 %.0f°   傾き %+.0f°   露出 %+.1f EV" (photoFov p) (photoRoll p * 180 / pi) (photoExposure p)
      x = fromIntegral w - 440
      flag yes = if yes then "入" else "切"
  drawRectangle (w - 456) 24 432 89 (Color 6 21 28 215)
  textAt label x 36 17 (Color 237 229 200 255)
  textAt (gradeName (photoGrade p) <> "   発光 " <> flag (photoBloom p) <> "   周辺減光 " <> flag (photoVignette p)) x 65 17 (Color 174 205 193 255)
  drawRectangle 24 (h - 132) (w - 48) 108 (Color 6 21 28 225)
  textAt "ENTER / F12  撮影     F6 / ESC  戻る     F2  案内を隠す" 41 (fromIntegral h - 121) 19 (Color 243 231 191 255)
  textAt "WASD / SPACE / CTRL  移動   SHIFT  高速   ALT  微速   マウス  視点   ホイール  画角" 41 (fromIntegral h - 86) 16 (Color 185 211 200 255)
  textAt "Q / E  傾き   ↑ / ↓  露出   TAB  色味   B  発光   V  周辺減光   G  ガイド   C  映画枠   R  リセット" 41 (fromIntegral h - 57) 16 (Color 185 211 200 255)
  forM_ message $ \line -> do
    drawRectangle 24 (h - 182) (w - 48) 38 (Color 6 21 28 230)
    textAt line 40 (fromIntegral h - 175) 16 (Color 243 231 191 255)

renderPhotoToast :: Painter -> String -> IO ()
renderPhotoToast Painter {..} line = do
  let (w, h) = viewport
  drawRectangle 24 (h - 190) (w - 48) 42 (Color 6 21 28 230)
  textAt line 40 (fromIntegral h - 180) 16 (Color 243 231 191 255)


toColor :: RGB -> Float -> Color
toColor (RGB r g b) alpha = Color (channel r) (channel g) (channel b) (channel alpha)
  where
    channel = round . (* 255) . max 0 . min 1
