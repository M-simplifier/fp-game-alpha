{-# LANGUAGE PatternSynonyms #-}

module PureFall.Host.Render
  ( Screen (..),
    Ui (..),
    Effects,
    emptyEffects,
    advanceEffects,
    render,
    menuHit,
    settingsHit,
  )
where

import Control.Monad (forM_, when)
import Data.Word (Word8)
import PureFall.Core (Cue (..), Kind (..), Mode (Practice), Phase (..), clearPoints, clearRows)
import PureFall.Host.Font
import PureFall.View
import Raylib.Core (clearBackground)
import Raylib.Core.Shapes (drawCircleV, drawLineEx, drawRectangleGradientV, drawRectangleLinesEx, drawRectangleRec)
import Raylib.Types

data Screen = Title | Playing | Help | Options deriving (Eq, Show)

data Ui = Ui
  { uiScreen :: Screen,
    uiMenu :: Int,
    uiSettingRow :: Int,
    uiVolume :: Int,
    uiMusic :: Bool,
    uiDas :: Int,
    uiArr :: Int,
    uiBest :: String,
    uiSaved :: Bool,
    uiMessage :: String,
    uiReplay :: Bool,
    uiWitness :: Bool,
    uiHarness :: Bool,
    uiResultReady :: Bool
  }

data Spark = Spark Float Float Float Float Float Color

data Effects = Effects
  { effectAge :: Float,
    effectRows :: [Int],
    effectText :: String,
    effectLock :: Float,
    effectDrop :: Float,
    effectSparks :: [Spark]
  }

emptyEffects :: Effects
emptyEffects = Effects 10 [] "" 0 0 []

advanceEffects :: Float -> [Cue] -> Effects -> Effects
advanceEffects seconds cues previous = foldl' add faded cues
  where
    dt = min 0.1 (max 0 seconds)
    faded =
      previous
        { effectAge = effectAge previous + dt,
          effectLock = max 0 (effectLock previous - dt),
          effectDrop = max 0 (effectDrop previous - dt),
          effectSparks =
            take
              160
              [ Spark (x + vx * dt) (y + vy * dt) vx (vy + 100 * dt) (life - dt) tint
              | Spark x y vx vy life tint <- effectSparks previous,
                life > dt
              ]
        }
    add fx cue = case cue of
      Dropped _ -> fx {effectDrop = 0.13}
      Locked points -> fx {effectLock = 0.18, effectSparks = effectSparks fx ++ concatMap lockSparks points}
      Cleared cleared ->
        fx
          { effectAge = 0,
            effectRows = map (subtract 4) (clearRows cleared),
            effectText = clearLabel cleared ++ "   +" ++ show (clearPoints cleared),
            effectDrop = 0.2
          }
      _ -> fx
    lockSparks ((x, y), kind) = [Spark (fromIntegral x + 0.5) (fromIntegral (y - 4) + 0.8) (fromIntegral n * 0.8) (-2 - fromIntegral (abs n)) 0.4 (kindColor kind) | n <- [-1, 1 :: Int]]

data Canvas = Canvas Float Float Float

canvas :: Int -> Int -> Canvas
canvas width height = Canvas scale ((fromIntegral width - 1440 * scale) / 2) ((fromIntegral height - 1000 * scale) / 2)
  where
    scale = min (fromIntegral width / 1440) (fromIntegral height / 1000)

point :: Canvas -> Float -> Float -> Vector2
point (Canvas scale ox oy) x y = Vector2 (ox + x * scale) (oy + y * scale)

rect :: Canvas -> Float -> Float -> Float -> Float -> Rectangle
rect (Canvas scale ox oy) x y width height = Rectangle (ox + x * scale) (oy + y * scale) (width * scale) (height * scale)

fill :: Canvas -> Float -> Float -> Float -> Float -> Color -> IO ()
fill c x y width height = drawRectangleRec (rect c x y width height)

line :: Canvas -> Float -> Float -> Float -> Float -> Float -> Color -> IO ()
line c@(Canvas scale _ _) x y xx yy weight = drawLineEx (point c x y) (point c xx yy) (weight * scale)

label :: Fonts -> Canvas -> Face -> Float -> Float -> Float -> Color -> String -> IO ()
label fonts c@(Canvas scale _ _) face x y size tint value = text fonts face value (point c x y) (readableSize face size * scale) tint

centered :: Fonts -> Canvas -> Face -> Float -> Float -> Float -> Color -> String -> IO ()
centered fonts c face x y size tint value = do
  let readable = readableSize face size
  width <- textWidth fonts face value readable
  label fonts c face (x - width / 2) y readable tint value

readableSize :: Face -> Float -> Float
readableSize face size
  | size < 13 = size
  | face == Body = max 21 size
  | face == Mono = max 17 size
  | otherwise = size

ink, panel, pearl, muted, cyan, amber :: Color
ink = Color 8 12 19 255
panel = Color 14 22 31 255
pearl = Color 238 241 237 255
muted = Color 127 147 163 255
cyan = Color 85 224 229 255
amber = Color 255 192 109 255

alpha :: Color -> Word8 -> Color
alpha (Color r g b _) = Color r g b

kindColor :: Kind -> Color
kindColor kind = case kind of
  I -> Color 77 216 224 255
  O -> Color 237 201 97 255
  T -> Color 181 134 229 255
  S -> Color 116 208 156 255
  Z -> Color 238 118 135 255
  J -> Color 108 155 229 255
  L -> Color 238 169 100 255

render :: Fonts -> Int -> Int -> Ui -> Effects -> RenderModel -> IO ()
render fonts width height ui fx view = do
  let c = canvas width height
  clearBackground ink
  drawRectangleGradientV 0 0 width height (Color 14 23 33 255) ink
  forM_ [0 .. 8 :: Int] $ \n -> line c (80 + fromIntegral n * 165) 0 (80 + fromIntegral n * 165) 1000 1 (Color 45 67 78 17)
  line c 80 56 1360 56 1 (alpha muted 45)
  label fonts c Mono 82 28 13 cyan "P / F"
  label fonts c Mono 1190 28 12 muted "PURE / FALL   01"
  case uiScreen ui of
    Title -> drawTitle fonts c ui view
    _ -> do
      drawGame fonts c ui fx view
      case uiScreen ui of
        Help -> drawHelp fonts c
        Options -> drawOptions fonts c ui
        Playing -> when (viewPhase view == Paused) (drawPause fonts c)
  when (uiHarness ui) $ label fonts c Mono 82 974 11 amber "NATIVE HARNESS / INJECTED COMMANDS / PRODUCTION SCHEDULER"
  when (uiScreen ui == Playing && not (null (uiMessage ui))) $ do
    fill c 390 859 660 34 (Color 21 37 47 244)
    centered fonts c Mono 720 868 14 cyan (uiMessage ui)

drawTitle :: Fonts -> Canvas -> Ui -> RenderModel -> IO ()
drawTitle fonts c ui view = do
  label fonts c Mono 180 118 14 cyan "A PRECISE LITTLE INFINITY"
  label fonts c Display 169 162 112 pearl "PURE"
  label fonts c Display 174 264 112 pearl "/ FALL"
  label fonts c Body 182 397 21 muted "Find the landing. Feel the rhythm."
  label fonts c Body 182 430 21 muted "One more piece. A different possibility."
  forM_ (zip [0 ..] modes) $ \(index, (name, description)) -> do
    let y = 511 + fromIntegral index * 69
        selected = uiMenu ui == index
    when selected $ do
      fill c 171 (y - 5) 460 62 (Color 24 44 55 255)
      fill c 171 (y - 5) 3 62 cyan
    label fonts c Display 193 y 25 (if selected then pearl else muted) name
    label fonts c Body 193 (y + 30) 17 muted description
    when selected $ label fonts c Mono 580 (y + 11) 18 cyan ">"
  label fonts c Mono 181 822 15 muted "ARROWS  SELECT     ENTER  BEGIN"
  label fonts c Mono 181 848 14 muted "F1  CONTROLS    O  SETTINGS    F11  FULLSCREEN"
  when (uiSaved ui) $ label fonts c Mono 181 884 14 cyan "F9  RESUME YOUR SAVED RUN"
  label fonts c Mono 181 937 14 muted ("LOCAL BEST   " ++ uiBest ui)
  drawTitleBlocks c
  label fonts c Mono 854 825 13 cyan "PLAY / REWIND / EXPLORE"
  label fonts c Body 854 857 18 muted "Practice keeps another path open."
  label fonts c Mono 854 920 12 muted ("UP NEXT   " ++ unwords (map show (viewNext view)))
  where
    modes =
      [ ("MARATHON", "Speed rises every 10 cleared lines."),
        ("40 LINE SPRINT", "Clear 40 lines as fast as possible."),
        ("TWO MINUTE", "Make your best score in 2 minutes."),
        ("PRACTICE", "Rewind pieces. Explore reachable landings.")
      ]

drawTitleBlocks :: Canvas -> IO ()
drawTitleBlocks c = do
  let bx = 846
      by = 164
      unit = 54
      rows =
        [ (0, 9, J),
          (1, 9, J),
          (2, 9, J),
          (2, 8, J),
          (3, 9, O),
          (4, 9, O),
          (3, 8, O),
          (4, 8, O),
          (5, 9, L),
          (6, 9, L),
          (7, 9, L),
          (7, 8, L),
          (0, 8, S),
          (1, 8, S),
          (1, 7, S),
          (2, 7, S),
          (3, 7, T),
          (4, 7, T),
          (5, 7, T),
          (4, 6, T),
          (5, 8, Z),
          (6, 8, Z),
          (6, 7, Z),
          (7, 7, Z),
          (3, 1, I),
          (3, 2, I),
          (3, 3, I),
          (3, 4, I)
        ]
  fill c (bx - 13) (by - 12) 458 576 (Color 10 16 24 255)
  forM_ [0 .. 8 :: Int] $ \n -> line c (bx + fromIntegral n * unit) by (bx + fromIntegral n * unit) (by + 540) 1 (Color 49 68 81 65)
  forM_ [0 .. 10 :: Int] $ \n -> line c bx (by + fromIntegral n * unit) (bx + 432) (by + fromIntegral n * unit) 1 (Color 49 68 81 65)
  forM_ rows $ \(x, y, k) -> block c (bx + fromIntegral (x :: Int) * unit) (by + fromIntegral (y :: Int) * unit) unit (kindColor k) ActiveCell
  forM_ [6 .. 9 :: Int] $ \y -> do
    let r = rect c (bx + 3 * unit + 4) (by + fromIntegral y * unit + 4) (unit - 8) (unit - 8)
    drawRectangleLinesEx r 1 (alpha cyan 95)

drawGame :: Fonts -> Canvas -> Ui -> Effects -> RenderModel -> IO ()
drawGame fonts c ui fx view = do
  label fonts c Display 270 77 29 pearl "PURE / FALL"
  label fonts c Mono 971 85 13 cyan (modeLabel (viewMode view))
  drawBoard c fx view
  when (effectAge fx < 1.5 && not (null (effectText fx))) $
    centered fonts c Mono 736 503 14 pearl (effectText fx)
  label fonts c Mono 277 140 14 muted "HOLD"
  when (not (viewHoldReady view)) $ label fonts c Mono 429 140 11 amber "LOCKED"
  fill c 271 174 215 116 panel
  maybe (label fonts c Mono 347 216 20 (alpha muted 90) "--") (mini c 378 227 27 (if viewHoldReady view then 255 else 95)) (viewHold view)
  stat fonts c 277 341 "SCORE" (groupNumber (viewScore view)) 39
  stat fonts c 277 450 "LINES" (show (viewLines view)) 35
  stat fonts c 277 548 "LEVEL" (twoDigit (viewLevel view)) 35
  stat fonts c 277 646 "TIME" (viewTime view) 24
  label fonts c Mono 277 751 14 muted "LOCAL BEST"
  label fonts c Display 277 777 22 pearl (uiBest ui)
  when (viewMode view == Practice) $ do
    label fonts c Mono 277 826 14 amber "Q  EXPLORE"
    label fonts c Mono 277 855 14 muted "BACKSPACE  REWIND"
  label fonts c Mono 974 140 14 muted "NEXT"
  forM_ (zip [0 ..] (viewNext view)) $ \(index, kind) -> do
    let y = 220 + fromIntegral (index :: Int) * 104
    fill c 968 (y - 39) 207 86 panel
    mini c 1070 y 25 255 kind
    label fonts c Mono 1150 (y + 21) 10 (alpha muted 100) (show (index + 1))
  label fonts c Mono 974 755 14 muted "OBJECTIVE"
  label fonts c Body 974 782 17 pearl (if viewObjective view == "REWIND / EXPLORE / TRY AGAIN" then "REWIND / EXPLORE" else viewObjective view)
  when (viewObjective view == "REWIND / EXPLORE / TRY AGAIN") $ label fonts c Body 974 807 17 muted "TRY AGAIN"
  when (viewCombo view > 0) $ label fonts c Display 974 822 19 amber (show (viewCombo view) ++ " COMBO")
  when (viewB2B view) $ label fonts c Mono 974 852 12 cyan "BACK TO BACK"
  line c 271 913 1176 913 1 (alpha muted 65)
  if uiReplay ui
    then do
      label fonts c Mono 272 933 14 muted "T TITLE   F1 CONTROLS   O SETTINGS   M MUTE   F11 FULLSCREEN"
      label fonts c Mono 272 956 13 (alpha muted 210) "WATCH YOUR RUN.  EVERY PLACEMENT IS REPLAYED IN ORDER."
    else do
      label fonts c Mono 272 933 14 muted "< > MOVE   Z / X ROTATE   SPACE DROP   C HOLD   P PAUSE   F1 HELP"
      label fonts c Mono 272 956 13 (alpha muted 210) "DOWN SOFT DROP   F5 SAVE   F9 LOAD   M MUTE   F11 FULLSCREEN"
  when (uiReplay ui) $ centered fonts c Mono 736 113 14 amber "REPLAY / WATCH YOUR RUN"
  when (viewPhase view == Studying) $ drawStudy fonts c ui view
  when (viewPhase view `elem` [Won, Lost]) $ drawResults fonts c ui view

drawBoard :: Canvas -> Effects -> RenderModel -> IO ()
drawBoard c fx view = do
  let bx = 556; by = 137 + effectDrop fx * 14; unit = 36
  fill c (bx - 10) (by - 10) 380 740 (Color 18 31 42 255)
  fill c bx by 360 720 (Color 5 10 17 255)
  forM_ [1 .. 9 :: Int] $ \x -> line c (bx + fromIntegral x * unit) by (bx + fromIntegral x * unit) (by + 720) 1 (Color 37 53 65 65)
  forM_ [1 .. 19 :: Int] $ \y -> line c bx (by + fromIntegral y * unit) (bx + 360) (by + fromIntegral y * unit) 1 (Color 37 53 65 65)
  forM_ (viewCells view) $ \cell ->
    when (cellY cell >= 0 && cellY cell < 20) $
      block c (bx + fromIntegral (cellX cell) * unit) (by + fromIntegral (cellY cell) * unit) unit (kindColor (cellKind cell)) (cellRole cell)
  when (effectAge fx < 0.3) $ forM_ (effectRows fx) $ \row -> when (row >= 0 && row < 20) $ do
    let fade = round (180 * (1 - effectAge fx / 0.3))
    fill c bx (by + fromIntegral row * unit) 360 unit (alpha pearl fade)
    fill c bx (by + fromIntegral row * unit + unit / 2 - 1) (360 * min 1 (effectAge fx * 8)) 2 pearl
  forM_ (effectSparks fx) $ \(Spark x y _ _ life tint) ->
    when (y >= 0 && y < 20.5) $
      drawCircleV (point c (bx + x * unit) (by + y * unit)) (1.6 * canvasScale c) (alpha tint (round (max 0 (min 255 (life * 450)))))
  drawRectangleLinesEx (rect c bx by 360 720) (canvasScale c) (alpha cyan 70)
  when (effectLock fx > 0) $ drawRectangleLinesEx (rect c bx by 360 720) (canvasScale c * 2) (alpha pearl (round (effectLock fx * 500)))
  forM_ [(bx, by, 1, 1), (bx + 360, by, -1, 1), (bx, by + 720, 1, -1), (bx + 360, by + 720, -1, -1)] $ \(x, y, dx, dy) -> do
    line c x y (x + dx * 16) y 2 cyan
    line c x y x (y + dy * 16) 2 cyan
  when (viewLockFraction view > 0) $ fill c bx (by + 725) (360 * max 0 (min 1 (viewLockFraction view))) 3 amber
  when (effectAge fx < 1.5 && not (null (effectText fx))) $
    fill c (bx - 7) (by + 352) 374 47 (Color 5 12 19 240)

canvasScale :: Canvas -> Float
canvasScale (Canvas scale _ _) = scale

block :: Canvas -> Float -> Float -> Float -> Color -> CellRole -> IO ()
block c x y unit tint role = case role of
  GhostCell -> do
    fill c (x + 4) (y + 4) (unit - 8) (unit - 8) (alpha tint 14)
    drawRectangleLinesEx (rect c (x + 4) (y + 4) (unit - 8) (unit - 8)) (canvasScale c * 1.4) (alpha tint 165)
  StudyCell -> do
    fill c (x + 3) (y + 3) (unit - 6) (unit - 6) (alpha amber 40)
    drawRectangleLinesEx (rect c (x + 3) (y + 3) (unit - 6) (unit - 6)) (canvasScale c * 2) amber
  _ -> do
    fill c (x + 2) (y + 2) (unit - 4) (unit - 4) (alpha tint (if role == SettledCell then 38 else 52))
    fill c (x + 4) (y + 4) (unit - 8) (unit - 8) tint
    fill c (x + 5) (y + 5) (unit - 10) 2 (alpha pearl 150)
    fill c (x + 5) (y + unit - 7) (unit - 10) 2 (Color 0 0 0 62)
    when (role == ActiveCell) $ drawRectangleLinesEx (rect c (x + 3) (y + 3) (unit - 6) (unit - 6)) (canvasScale c) (alpha pearl 155)

mini :: Canvas -> Float -> Float -> Float -> Word8 -> Kind -> IO ()
mini c centerX centerY unit opacity kind = forM_ (glyph kind) $ \(x, y) ->
  block c (centerX + (x - width / 2) * unit) (centerY + (y - 1) * unit) unit (alpha (kindColor kind) opacity) SettledCell
  where
    width = if kind == I then 4 else if kind == O then 2 else 3

glyph :: Kind -> [(Float, Float)]
glyph kind = case kind of
  I -> [(0, 0.5), (1, 0.5), (2, 0.5), (3, 0.5)]
  O -> [(0, 0), (1, 0), (0, 1), (1, 1)]
  T -> [(1, 0), (0, 1), (1, 1), (2, 1)]
  S -> [(1, 0), (2, 0), (0, 1), (1, 1)]
  Z -> [(0, 0), (1, 0), (1, 1), (2, 1)]
  J -> [(0, 0), (0, 1), (1, 1), (2, 1)]
  L -> [(2, 0), (0, 1), (1, 1), (2, 1)]

stat :: Fonts -> Canvas -> Float -> Float -> String -> String -> Float -> IO ()
stat fonts c x y name value size = do
  label fonts c Mono x y 14 muted name
  label fonts c Display x (y + 29) size pearl value

shade :: Canvas -> IO ()
shade c = fill c 80 57 1280 899 (Color 4 9 16 225)

drawPause :: Fonts -> Canvas -> IO ()
drawPause fonts c = do
  fill c 546 127 380 740 (Color 5 11 18 235)
  centered fonts c Mono 736 380 13 cyan "TAKE YOUR TIME"
  centered fonts c Display 736 416 58 pearl "PAUSED"
  centered fonts c Body 736 501 18 muted "P / ESC   Continue"
  centered fonts c Body 736 540 18 muted "F1   Controls    O   Settings"
  centered fonts c Body 736 579 18 muted "F5   Save this moment"
  centered fonts c Mono 736 659 14 muted "T   RETURN TO TITLE"

drawStudy :: Fonts -> Canvas -> Ui -> RenderModel -> IO ()
drawStudy fonts c ui view = do
  fill c 531 855 410 45 (Color 32 36 36 255)
  centered
    fonts
    c
    Mono
    736
    867
    13
    amber
    ( if uiWitness ui
        then "PLAYING THE REACHABILITY WITNESS"
        else
          "LANDING " ++ show (viewStudyIndex view + 1) ++ " / " ++ show (viewStudyCount view) ++ "   " ++ show (viewStudyPathLength view) ++ " MOVES"
    )
  fill c 250 319 256 302 (Color 17 28 36 252)
  label fonts c Mono 277 343 13 amber "PLACEMENT STUDY"
  label fonts c Body 277 377 17 pearl "Reachable, not just empty."
  label fonts c Body 277 412 15 muted "Frozen board + current piece."
  label fonts c Body 277 438 15 muted "Gravity and lock time paused."
  label fonts c Mono 277 488 13 pearl "PAGE UP / DOWN  Choose"
  label fonts c Mono 277 518 13 pearl "ENTER  Try this path"
  label fonts c Mono 277 548 13 pearl "Q  Return to play"
  label fonts c Mono 277 578 13 pearl "BACKSPACE  Rewind piece"

drawResults :: Fonts -> Canvas -> Ui -> RenderModel -> IO ()
drawResults fonts c ui view = do
  fill c 535 252 402 454 (Color 6 13 21 247)
  line c 563 280 909 280 2 (if viewPhase view == Won then cyan else amber)
  centered fonts c Mono 736 314 13 cyan (modeLabel (viewMode view))
  centered fonts c Display 736 355 48 pearl (if viewPhase view == Won then "COMPLETE" else "RUN ENDED")
  centered fonts c Display 736 428 51 pearl (groupNumber (viewScore view))
  centered fonts c Mono 736 495 14 muted (show (viewLines view) ++ " LINES   /   " ++ viewTime view)
  centered fonts c Body 736 546 18 muted "There is always another landing."
  when (uiResultReady ui) $ do
    centered fonts c Mono 736 603 14 cyan "ENTER  TRY AGAIN"
    centered fonts c Mono 736 638 14 muted "R  REPLAY    T  TITLE"

drawHelp :: Fonts -> Canvas -> IO ()
drawHelp fonts c = do
  shade c
  label fonts c Mono 299 134 14 cyan "THE CONTROLS"
  label fonts c Display 295 175 61 pearl "EVERY MOVE MATTERS."
  forM_ (zip [0 ..] controls) $ \(index, (key, action)) -> do
    let y = 289 + fromIntegral (index :: Int) * 43
    label fonts c Mono 300 y 16 cyan key
    label fonts c Body 569 y 19 pearl action
  label fonts c Body 300 855 17 muted "Practice: rewind checkpoints, compare reachable landings, then play the path."
  label fonts c Mono 300 906 14 amber "F1 / ESC   BACK"
  where
    controls =
      [ ("LEFT / RIGHT", "Move; hold to repeat"),
        ("DOWN", "Soft drop"),
        ("X / UP  -  Z", "Rotate clockwise / counterclockwise"),
        ("SPACE", "Hard drop"),
        ("C / SHIFT", "Hold once per piece"),
        ("P / ESC", "Pause / resume"),
        ("Q  -  PAGE UP / DOWN", "Practice study / select reachable landing"),
        ("ENTER  -  BACKSPACE", "Play these moves / rewind a piece"),
        ("F5  -  F9", "Save / load this exact session"),
        ("O  -  M  -  F11", "Settings / mute / fullscreen")
      ]

drawOptions :: Fonts -> Canvas -> Ui -> IO ()
drawOptions fonts c ui = do
  shade c
  label fonts c Mono 349 166 14 cyan "MAKE IT YOURS"
  label fonts c Display 344 204 64 pearl "SETTINGS"
  forM_ (zip [0 ..] rows) $ \(index, (name, value)) -> do
    let y = 342 + fromIntegral (index :: Int) * 90
    when (uiSettingRow ui == index) $ do
      fill c 331 (y - 15) 773 72 (Color 23 42 53 255)
      fill c 331 (y - 15) 3 72 cyan
    label fonts c Body 353 y 23 pearl name
    label fonts c Mono 888 (y + 3) 20 cyan value
  label fonts c Body 350 745 16 muted "Movement changes apply when a new run begins."
  label fonts c Mono 350 806 14 muted "UP / DOWN  SELECT     LEFT / RIGHT  ADJUST"
  label fonts c Mono 350 863 14 amber "O / ESC   BACK"
  where
    rows =
      [ ("Sound volume", show (uiVolume ui) ++ " %"),
        ("Quiet rhythm", if uiMusic ui then "ON" else "OFF"),
        ("DAS / initial repeat", show (uiDas ui * 1000 `div` 60) ++ " ms"),
        ("ARR / repeat interval", if uiArr ui == 0 then "INSTANT" else show (uiArr ui * 1000 `div` 60) ++ " ms")
      ]

menuHit :: Int -> Int -> Vector2 -> Maybe Int
menuHit width height position = hitRows width height position 171 506 460 69 4

settingsHit :: Int -> Int -> Vector2 -> Maybe Int
settingsHit width height position = hitRows width height position 331 327 773 90 4

hitRows :: Int -> Int -> Vector2 -> Float -> Float -> Float -> Float -> Int -> Maybe Int
hitRows width height (Vector2 xx yy) left top boxWidth rowHeight count =
  let Canvas scale ox oy = canvas width height; x = (xx - ox) / scale; y = (yy - oy) / scale; index = floor ((y - top) / rowHeight)
   in if x >= left && x < left + boxWidth && y >= top && index >= 0 && index < count then Just index else Nothing

groupNumber :: Int -> String
groupNumber number = reverse (separate (reverse (show number)))
  where
    separate values = case splitAt 3 values of (first, []) -> first; (first, rest) -> first ++ "," ++ separate rest

twoDigit :: Int -> String
twoDigit number = if number < 10 then '0' : show number else show number
