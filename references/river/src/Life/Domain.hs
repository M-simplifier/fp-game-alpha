{-# LANGUAGE OverloadedStrings #-}

-- | Authoritative, pure rules for 川音の家.  All Game fields and its constructor
-- are private.  The public projections below are ordinary functions, not record
-- selectors: callers cannot use record update to bypass the invariants.
module Life.Domain
  ( Game,
    Cell (..),
    Command (..),
    BuildKind (..),
    Weather (..),
    CropStage (..),
    CropView (..),
    WoodView (..),
    DinnerStatus (..),
    Effect (..),
    SaveError (..),
    Scenario (..),
    initialGame,
    advance,
    runCommands,
    waitTicks,
    worldWidth,
    worldDepth,
    dayLengthTicks,
    homeCell,
    cookingCell,
    mailboxCell,
    cropCells,
    woodCells,
    playerPosition,
    playerCell,
    playerFacing,
    dayNumber,
    dayTicks,
    weather,
    neighborCell,
    roofs,
    paths,
    seats,
    crops,
    firewood,
    selectedBuild,
    buildTarget,
    interactionLabel,
    taskProgress,
    journal,
    lastNightReport,
    turnipCount,
    dryWoodCount,
    dinnerStatus,
    clockLabel,
    forecastLabel,
    cropStageAt,
    woodDrynessAt,
    isRoofed,
    isSheltered,
    walkableCell,
    canBuildAt,
    encodeGame,
    decodeGame,
    invariantErrors,
    scenarioGame,
    walkToCell,
  )
where

import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

-- | Cell is intentionally a plain input/view value.  Commands validate it.
data Cell = Cell !Int !Int deriving (Eq, Ord, Show, Read)

data BuildKind = NoBuild | Roof | Path | Seat deriving (Eq, Ord, Show, Read, Enum, Bounded)

data Weather = Sunny | Rainy deriving (Eq, Show)

data CropStage = Empty | Planted | Sprouting | Ripe deriving (Eq, Ord, Show, Enum, Bounded)

data CropView = CropView !Cell !CropStage !Bool deriving (Eq, Show)

-- | Percent dry (0..100), and whether a bundle is on this rack.
data WoodView = WoodView !Cell !Int !Bool deriving (Eq, Show)

data DinnerStatus = NotPromised | Promised | DinnerReady | DinnerShared
  deriving (Eq, Ord, Show, Enum, Bounded)

data Command
  = -- | One 1/30 s step; x/z inputs saturate to -1, 0, 1.
    Tick !Int !Int
  | Interact
  | ChooseBuild !BuildKind
  | BuildAt !Cell
  | RemoveAt !Cell
  deriving (Eq, Show)

data Effect = Changed !Text | SaveRecommended deriving (Eq, Show)

data SaveError
  = SaveTooLarge
  | SaveMalformed
  | SaveVersionUnsupported !Integer
  | SaveInvalid ![Text]
  deriving (Eq, Show)

data Scenario = DayOne | DayTwo | DayThree | AfterDinner deriving (Eq, Show)

data Bed = Bed !CropStage !Bool deriving (Eq, Show)

data Bundle = Bundle !Int !Bool deriving (Eq, Show) -- 0..7200 progress, loaded

-- A persisted factual report, not a pending UI effect.  Subsequent edits to
-- roofs or crops do not retroactively change what happened overnight.
data NightReport = NightReport !Int !Int !Int ![(Cell, Int, Int, Bool)]
  deriving (Eq, Show)

data Game = Game
  { gPlayerX :: !Int,
    gPlayerZ :: !Int,
    gFacingX :: !Int,
    gFacingZ :: !Int,
    gDay :: !Int,
    gTicks :: !Int,
    gBeds :: !(Map Cell Bed),
    gWood :: !(Map Cell Bundle),
    gRoofs :: !(Set Cell),
    gPaths :: !(Set Cell),
    gSeats :: !(Set Cell),
    gBuild :: !BuildKind,
    gTurnips :: !Int,
    gDryWood :: !Int,
    gDinner :: !DinnerStatus,
    gNight :: !(Maybe NightReport)
  }
  deriving (Eq, Show)

worldWidth, worldDepth, dayLengthTicks :: Int
worldWidth = 20
worldDepth = 16
dayLengthTicks = 10800

homeCell, cookingCell, mailboxCell :: Cell
homeCell = Cell 4 5
cookingCell = Cell 5 7
mailboxCell = Cell 3 6

cropCells, woodCells :: [Cell]
cropCells = [Cell 8 5, Cell 9 5, Cell 10 5]
woodCells = [Cell 7 9, Cell 8 9]

maxDay, maxInventory, dryGoal :: Int
maxDay = 1000000
maxInventory = 9999
dryGoal = 7200

initialGame :: Game
initialGame =
  Game
    { gPlayerX = 450,
      gPlayerZ = 650,
      gFacingX = 0,
      gFacingZ = 1,
      gDay = 1,
      gTicks = 0,
      gBeds = Map.fromList [(c, Bed Empty False) | c <- cropCells],
      gWood = Map.fromList [(c, Bundle 0 False) | c <- woodCells],
      gRoofs = Set.empty,
      gPaths = Set.empty,
      gSeats = Set.empty,
      gBuild = NoBuild,
      gTurnips = 0,
      gDryWood = 0,
      gDinner = NotPromised,
      gNight = Nothing
    }

playerPosition :: Game -> (Int, Int)
playerPosition g = (gPlayerX g, gPlayerZ g)

playerCell :: Game -> Cell
playerCell g = Cell (gPlayerX g `div` 100) (gPlayerZ g `div` 100)

playerFacing :: Game -> (Int, Int)
playerFacing g = (gFacingX g, gFacingZ g)

dayNumber :: Game -> Int
dayNumber = gDay

dayTicks :: Game -> Int
dayTicks = gTicks

selectedBuild :: Game -> BuildKind
selectedBuild = gBuild

turnipCount, dryWoodCount :: Game -> Int
turnipCount = gTurnips
dryWoodCount = gDryWood

dinnerStatus :: Game -> DinnerStatus
dinnerStatus = gDinner

roofs, paths, seats :: Game -> [Cell]
roofs = Set.toAscList . gRoofs
paths = Set.toAscList . gPaths
seats = Set.toAscList . gSeats

weatherFor :: Int -> Weather
weatherFor d
  | even d = Rainy
  | otherwise = Sunny

weather :: Game -> Weather
weather = weatherFor . gDay

neighborCell :: Game -> Cell
neighborCell g = if weather g == Rainy then Cell 13 4 else Cell 15 10

crops :: Game -> [CropView]
crops g = [CropView c s w | (c, Bed s w) <- Map.toAscList (gBeds g)]

firewood :: Game -> [WoodView]
firewood g =
  [ WoodView c (n * 100 `div` dryGoal) loaded
  | (c, Bundle n loaded) <- Map.toAscList (gWood g)
  ]

cropStageAt :: Cell -> Game -> Maybe CropStage
cropStageAt c g = case Map.lookup c (gBeds g) of
  Just (Bed s _) -> Just s
  Nothing -> Nothing

woodDrynessAt :: Cell -> Game -> Maybe Int
woodDrynessAt c g = case Map.lookup c (gWood g) of
  Just (Bundle n _) -> Just (n * 100 `div` dryGoal)
  Nothing -> Nothing

isRoofed :: Cell -> Game -> Bool
isRoofed c = Set.member c . gRoofs

isSheltered :: Game -> Cell -> Bool
isSheltered g c = isRoofed c g

buildTarget :: Game -> Cell
buildTarget g =
  let Cell x z = playerCell g
   in Cell (x + gFacingX g) (z + gFacingZ g)

inBounds :: Cell -> Bool
inBounds (Cell x z) = x >= 0 && z >= 0 && x < worldWidth && z < worldDepth

baseWalkable :: Cell -> Bool
baseWalkable c@(Cell x z) =
  inBounds c
    && x < 17
    && not (x >= 2 && x <= 5 && z >= 2 && z <= 4)
    && not (x >= 12 && x <= 14 && z >= 1 && z <= 3)

walkableCell :: Cell -> Game -> Bool
walkableCell c g = baseWalkable c && Set.notMember c (gSeats g)

-- Circular player's conservative square footprint: no corner-cutting through
-- houses, seats, plot boundary, or stream.  Axis-separated resolution slides.
positionClear :: (Int, Int) -> Game -> Bool
positionClear (x, z) g =
  all
    (`walkableCell` g)
    [ Cell ((x + dx) `div` 100) ((z + dz) `div` 100)
    | dx <- [-22, 22],
      dz <- [-22, 22]
    ]

center :: Cell -> (Int, Int)
center (Cell x z) = (x * 100 + 50, z * 100 + 50)

distanceSquared :: Cell -> Game -> Integer
distanceSquared c g =
  let (x, z) = center c
      dx = toInteger x - toInteger (gPlayerX g)
      dz = toInteger z - toInteger (gPlayerZ g)
   in dx * dx + dz * dz

near :: Int -> Cell -> Game -> Bool
near radius c g = distanceSquared c g <= toInteger radius * toInteger radius

reservedGround :: Cell -> Bool
reservedGround c =
  c
    `elem` ( homeCell
               : cookingCell
               : mailboxCell
               : Cell 13 4
               : Cell 15 10
               : cropCells
               ++ woodCells
           )

buildSiteAllowed :: BuildKind -> Cell -> Game -> Bool
buildSiteAllowed kind c g =
  baseWalkable c && case kind of
    NoBuild -> False
    Roof -> c /= homeCell && c /= Cell 13 4
    Path -> not (reservedGround c) && Set.notMember c (gSeats g)
    Seat ->
      not (reservedGround c)
        && Set.notMember c (gPaths g)
        && seatDoesNotTouchPlayer c g

seatDoesNotTouchPlayer :: Cell -> Game -> Bool
seatDoesNotTouchPlayer c g =
  positionClear
    (playerPosition g)
    g {gSeats = Set.insert c (gSeats g)}

-- | Check range, interaction reach, terrain and current occupancy before a
-- build. A failed command is still an in-world attempt with a notice effect.
canBuildAt :: BuildKind -> Cell -> Game -> Bool
canBuildAt kind c g = inBounds c && near 200 c g && buildSiteAllowed kind c g

-- | Authoritative command boundary. Only 'Tick' advances the in-day clock;
-- sleeping at home is the explicit overnight transition. Effects describe
-- host work and are never stored as part of 'Game'.
advance :: Command -> Game -> (Game, [Effect])
advance command g = case command of
  Tick rawX rawZ -> (tick rawX rawZ g, [])
  Interact -> interactWorld g
  ChooseBuild kind -> (g {gBuild = kind}, [])
  BuildAt c -> build c g
  RemoveAt c -> remove c g

runCommands :: [Command] -> Game -> Game
runCommands commands start = foldl' (\g c -> fst (advance c g)) start commands

waitTicks :: Int -> Game -> Game
waitTicks count = runCommands (replicate (max 0 count) (Tick 0 0))

tick :: Int -> Int -> Game -> Game
tick rawX rawZ old = waterRain moved
  where
    dx = signum rawX
    dz = signum rawZ
    speed = if dx /= 0 && dz /= 0 then 7 else 10
    px = gPlayerX old + dx * speed
    pz = gPlayerZ old + dz * speed
    xMoved = if positionClear (px, gPlayerZ old) old then px else gPlayerX old
    zMoved = if positionClear (xMoved, pz) old then pz else gPlayerZ old
    moved =
      old
        { gPlayerX = xMoved,
          gPlayerZ = zMoved,
          gFacingX = if dx == 0 && dz == 0 then gFacingX old else dx,
          gFacingZ = if dx == 0 && dz == 0 then gFacingZ old else dz,
          gTicks = min dayLengthTicks (gTicks old + 1)
        }

waterRain :: Game -> Game
waterRain g
  | weather g /= Rainy = g
  | otherwise = g {gBeds = Map.mapWithKey water (gBeds g)}
  where
    water c (Bed s w) = Bed s (w || (s /= Empty && not (isRoofed c g)))

changed :: Text -> Game -> (Game, [Effect])
changed message g = (g, [Changed message, SaveRecommended])

notice :: Text -> Game -> (Game, [Effect])
notice message g = (g, [Changed message])

build :: Cell -> Game -> (Game, [Effect])
build c g
  | not (canBuildAt (gBuild g) c g) = notice "ここには置けません。少し近づくか、場所を変えてみよう。" g
  | otherwise = case gBuild g of
      NoBuild -> notice "Bで建築を開き、1・2・3で材料を選ぼう。" g
      Roof
        | Set.member c (gRoofs g) -> notice "ここにはもう屋根があります。" g
        | otherwise -> changed "屋根を一つ置いた。真下だけ雨を防ぎます。" g {gRoofs = Set.insert c (gRoofs g)}
      Path
        | Set.member c (gPaths g) -> notice "ここにはもう小道があります。" g
        | otherwise -> changed "小道を一つ敷いた。庭が少し歩きやすそう。" g {gPaths = Set.insert c (gPaths g)}
      Seat
        | Set.member c (gSeats g) -> notice "ここにはもう椅子があります。" g
        | otherwise -> changed "椅子を一つ置いた。川音を聴く場所ができた。" g {gSeats = Set.insert c (gSeats g)}

remove :: Cell -> Game -> (Game, [Effect])
remove c g
  | not (inBounds c && near 200 c g) = notice "近くのブロックだけ片づけられます。" g
  | Set.member c (gRoofs g) = changed "屋根を片づけた。ここには雨が届きます。" g {gRoofs = Set.delete c (gRoofs g)}
  | Set.member c (gSeats g) = changed "椅子を片づけた。" g {gSeats = Set.delete c (gSeats g)}
  | Set.member c (gPaths g) = changed "小道を片づけた。" g {gPaths = Set.delete c (gPaths g)}
  | otherwise = notice "ここには片づけるブロックがありません。" g

data Interaction = AtBed !Cell | AtWood !Cell | AtNeighbor | AtCook | AtHome | AtMail
  deriving (Eq, Show)

-- | The label and the executed interaction use this same nearest-target
-- decision, including distance, facing and tie-breaking order.
interactionTarget :: Game -> Maybe Interaction
interactionTarget g = case sortOn key candidates of
  [] -> Nothing
  ((_, _, target) : _) -> Just target
  where
    entries =
      [(c, 0 :: Int, AtBed c) | c <- cropCells]
        ++ [(c, 1, AtWood c) | c <- woodCells]
        ++ [ (neighborCell g, 2, AtNeighbor),
             (cookingCell, 3, AtCook),
             (mailboxCell, 4, AtMail),
             (homeCell, 5, AtHome)
           ]
    candidates = filter (\(c, _, _) -> near 155 c g) entries
    key (c, p, _) = (distanceSquared c g, negate (alignment c), p, c)
    alignment c =
      let (x, z) = center c
       in (x - gPlayerX g) * gFacingX g + (z - gPlayerZ g) * gFacingZ g

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

interactWorld :: Game -> (Game, [Effect])
interactWorld g = case interactionTarget g of
  Nothing -> notice "もう少し近づくと、話したり作業したりできます。" g
  Just (AtBed c) -> workBed c g
  Just (AtWood c) -> workWood c g
  Just AtNeighbor -> case gDinner g of
    NotPromised -> changed "ナギ「カブが採れたら、一緒に夕ごはんにしよう。いつでも待ってるね」" g {gDinner = Promised}
    Promised -> notice "ナギ「雨の日も、晴れの日も。夕ごはんは、できたときで大丈夫」" g
    DinnerReady -> changed "温かいカブのスープを分け合った。ナギ「また、いつでも寄ってね」" g {gDinner = DinnerShared}
    DinnerShared -> notice "ナギ「庭が少しずつ、あなたの場所になってきたね」" g
  Just AtCook -> cook g
  Just AtHome -> sleep g
  Just AtMail -> notice (forecastLabel g) g

workBed :: Cell -> Game -> (Game, [Effect])
workBed c g = case Map.lookup c (gBeds g) of
  Nothing -> notice "ここには畑がありません。" g
  Just (Bed Empty _) ->
    changed "カブの種をまいた。水をやって、二晩待とう。" $
      waterRain g {gBeds = Map.insert c (Bed Planted False) (gBeds g)}
  Just (Bed Ripe _)
    | gTurnips g >= maxInventory -> notice "かごがいっぱいです。カブは畑で待っています。" g
    | otherwise ->
        changed
          "カブを収穫した！ 空いた畑にはまた種をまけます。"
          g
            { gBeds = Map.insert c (Bed Empty False) (gBeds g),
              gTurnips = gTurnips g + 1
            }
  Just (Bed s False) ->
    changed
      "じょうろで水をやった。雨が届かない場所も、これで大丈夫。"
      g
        { gBeds = Map.insert c (Bed s True) (gBeds g)
        }
  Just (Bed _ True) -> notice "土はしっとり。ひと晩眠ると、また少し育ちます。" g

workWood :: Cell -> Game -> (Game, [Effect])
workWood c g = case Map.lookup c (gWood g) of
  Nothing -> notice "ここには薪置き場がありません。" g
  Just (Bundle _ False) ->
    changed
      "新しい薪を並べた。今夜の天気で、ひと晩ごとに乾きます。屋根があると、雨でもよく乾きます。"
      g
        { gWood = Map.insert c (Bundle 0 True) (gWood g)
        }
  Just (Bundle n True)
    | n < dryGoal -> notice ("薪の乾き具合 " <> tshow (n * 100 `div` dryGoal) <> "% 。今夜の天気で、ひと晩ごとに乾きます。雨の当たらない場所のほうが早く乾きます。") g
    | gDryWood g >= maxInventory -> notice "薪かごがいっぱいです。ここに置いておこう。" g
    | otherwise ->
        changed
          "乾いた薪を一束しまった。かまどで使えます。"
          g
            { gWood = Map.insert c (Bundle 0 False) (gWood g),
              gDryWood = gDryWood g + 1
            }

cook :: Game -> (Game, [Effect])
cook g = case gDinner g of
  NotPromised -> notice "カブのスープが作れそう。先にご近所さんに声をかけてみよう。" g
  DinnerReady -> notice "夕ごはんはできています。ナギに届けよう。" g
  DinnerShared -> notice "夕ごはんの思い出が、かまどに残っています。明日も好きなように過ごそう。" g
  Promised
    | gTurnips g < 1 -> notice "カブが一つ必要です。水をやった畑で二晩育てよう。" g
    | gDryWood g < 1 -> notice "乾いた薪が一束必要です。薪置き場を見てみよう。" g
    | otherwise ->
        changed
          "カブのスープができた！ ナギに持っていこう。"
          g
            { gTurnips = gTurnips g - 1,
              gDryWood = gDryWood g - 1,
              gDinner = DinnerReady
            }

-- | One overnight update: crop growth and wood drying use the closing day's
-- weather and shelter, then the next day starts at tick zero. Repeated render
-- frames or elapsed wall time cannot run this transition by themselves.
sleep :: Game -> (Game, [Effect])
sleep closingDay = changed message nextMorning
  where
    -- Rain reaches the closing day's plots before growth consumes their water.
    wateredTonight = waterRain closingDay
    nextDay = min maxDay (gDay closingDay + 1)
    afterNight =
      wateredTonight
        { gDay = nextDay,
          gTicks = 0,
          gBeds = Map.map grow (gBeds wateredTonight),
          gWood = Map.mapWithKey dryOvernight (gWood closingDay),
          gNight = Just night
        }
    -- Apply the new day's rain only after recording the completed night.
    nextMorning = waterRain afterNight
    grownCount =
      length
        [ ()
        | Bed stage watered <- Map.elems (gBeds wateredTonight),
          watered,
          stage == Planted || stage == Sprouting
        ]
    rainCount =
      length
        [ ()
        | (c, Bed stage _) <- Map.toList (gBeds wateredTonight),
          weather closingDay == Rainy,
          stage /= Empty,
          not (isRoofed c closingDay)
        ]
    woodChanges =
      [ (c, n, after, isRoofed c closingDay)
      | (c, bundle@(Bundle n True)) <- Map.toAscList (gWood closingDay),
        let Bundle after _ = dryOvernight c bundle
      ]
    night = NightReport (gDay closingDay) grownCount rainCount woodChanges
    -- Each night is one meaningful drying step.  No wall clock, render tick,
    -- offline interval, or time spent walking can bypass the overnight care.
    dryOvernight c (Bundle n loaded) =
      let amount = if weather closingDay == Rainy && not (isRoofed c closingDay) then dryGoal `div` 8 else dryGoal `div` 2
       in Bundle (if loaded then min dryGoal (n + amount) else 0) loaded
    grow (Bed s watered) = Bed (if watered then growStage s else s) False
    growStage Empty = Empty
    growStage Planted = Sprouting
    growStage Sprouting = Ripe
    growStage Ripe = Ripe
    tomorrow = weatherFor nextDay
    message =
      if tomorrow == Rainy
        then "雨の朝。屋根のない畑には雨が届き、薪はゆっくり乾きます。"
        else "晴れの朝。今日も、急がず自分の庭を育てよう。"

clockLabel :: Game -> Text
clockLabel g =
  let minutes = 8 * 60 + gTicks g * (12 * 60) `div` dayLengthTicks
      h = minutes `div` 60
      m = minutes `mod` 60
   in tshow h <> ":" <> (if m < 10 then "0" else "") <> tshow m

forecastLabel :: Game -> Text
forecastLabel g =
  tonight
    <> if weatherFor (min maxDay (gDay g + 1)) == Rainy
      then "明日は雨。畑には恵みの雨。薪の真上には屋根を。"
      else "明日は晴れ。屋根の下の畑には、じょうろで水をやろう。"
  where
    tonight =
      if weather g == Sunny
        then "今夜は晴れ。薪は50%乾きます。"
        else "今夜は雨。薪は屋根の下で50%、雨ざらしで12.5%乾きます。"

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

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- Versioned raw transport representation.  Read exists ONLY for this private
-- DTO, never for Game.  Numeric enums allow rejecting unrecognized values.
data RawNight = RawNight !Integer !Integer !Integer ![(Integer, Integer, Integer, Integer, Bool)]
  deriving (Eq, Show, Read)

data RawSave = RawSave
  { rVersion :: !Integer,
    rX :: !Integer,
    rZ :: !Integer,
    rFX :: !Integer,
    rFZ :: !Integer,
    rDay :: !Integer,
    rTicks :: !Integer,
    rBeds :: ![(Integer, Integer, Integer, Bool)],
    rWood :: ![(Integer, Integer, Integer, Bool)],
    rRoofs :: ![(Integer, Integer)],
    rPaths :: ![(Integer, Integer)],
    rSeats :: ![(Integer, Integer)],
    rBuild :: !Integer,
    rTurnips :: !Integer,
    rDryWood :: !Integer,
    rDinner :: !Integer,
    rNight :: !(Maybe RawNight)
  }
  deriving (Eq, Show, Read)

rawGame :: Game -> RawSave
rawGame g =
  RawSave
    1
    (n (gPlayerX g))
    (n (gPlayerZ g))
    (n (gFacingX g))
    (n (gFacingZ g))
    (n (gDay g))
    (n (gTicks g))
    [(n x, n z, n (fromEnum s), w) | (Cell x z, Bed s w) <- Map.toAscList (gBeds g)]
    [(n x, n z, n amount, l) | (Cell x z, Bundle amount l) <- Map.toAscList (gWood g)]
    (map pair (roofs g))
    (map pair (paths g))
    (map pair (seats g))
    (n (fromEnum (gBuild g)))
    (n (gTurnips g))
    (n (gDryWood g))
    (n (fromEnum (gDinner g)))
    (fmap rawNight (gNight g))
  where
    pair (Cell x z) = (n x, n z)
    rawNight (NightReport d grown rainCount changes) =
      RawNight
        (n d)
        (n grown)
        (n rainCount)
        [(n x, n z, n before, n after, covered) | (Cell x z, before, after, covered) <- changes]
    n = toInteger

-- | Versioned transport data, never a public 'Game' constructor.
encodeGame :: Game -> Text
encodeGame = Text.pack . show . rawGame

-- | Size-limit and parse an untrusted save; validate all raw fields before
-- integer conversion and authoritative state reconstruction. This is a
-- snapshot restoration boundary, not a proof for arbitrary future commands.
decodeGame :: Text -> Either SaveError Game
decodeGame input
  | Text.length input > 65536 = Left SaveTooLarge
  | otherwise = case readMaybe (Text.unpack input) of
      Nothing -> Left SaveMalformed
      Just raw
        | rVersion raw /= 1 -> Left (SaveVersionUnsupported (rVersion raw))
        | not (null (validateRaw raw)) -> Left (SaveInvalid (validateRaw raw))
        | otherwise -> case fromRaw raw of
            Nothing -> Left (SaveInvalid ["unknown enum"])
            Just g -> Right g

-- Safe lookup rather than partial toEnum, even after validation.
enumValue :: (Bounded a, Enum a) => Integer -> Maybe a
enumValue n = lookup n [(toInteger (fromEnum x), x) | x <- [minBound .. maxBound]]

fromRaw :: RawSave -> Maybe Game
fromRaw r = do
  bs <- traverse bed (rBeds r)
  buildKind <- enumValue (rBuild r)
  dinner <- enumValue (rDinner r)
  pure $
    Game
      { gPlayerX = n (rX r),
        gPlayerZ = n (rZ r),
        gFacingX = n (rFX r),
        gFacingZ = n (rFZ r),
        gDay = n (rDay r),
        gTicks = n (rTicks r),
        gBeds = Map.fromList bs,
        gWood = Map.fromList [(Cell (n x) (n z), Bundle (n amount) l) | (x, z, amount, l) <- rWood r],
        gRoofs = cells (rRoofs r),
        gPaths = cells (rPaths r),
        gSeats = cells (rSeats r),
        gBuild = buildKind,
        gTurnips = n (rTurnips r),
        gDryWood = n (rDryWood r),
        gDinner = dinner,
        gNight = fmap restoreNight (rNight r)
      }
  where
    n = fromInteger
    restoreNight (RawNight d grown rainCount changes) =
      NightReport
        (n d)
        (n grown)
        (n rainCount)
        [(Cell (n x) (n z), n before, n after, covered) | (x, z, before, after, covered) <- changes]
    cells = Set.fromList . map (\(x, z) -> Cell (n x) (n z))
    bed (x, z, s, w) = do
      stage <- enumValue s
      pure (Cell (n x) (n z), Bed stage w)

validateRaw :: RawSave -> [Text]
validateRaw r =
  concat
    [ bad (rVersion r == 1) "version",
      bad
        ( rX r >= 22
            && rX r < toInteger (worldWidth * 100 - 22)
            && rZ r >= 22
            && rZ r < toInteger (worldDepth * 100 - 22)
        )
        "player range",
      bad
        ( rFX r >= -1
            && rFX r <= 1
            && rFZ r >= -1
            && rFZ r <= 1
            && (rFX r /= 0 || rFZ r /= 0)
        )
        "facing",
      bad (rDay r >= 1 && rDay r <= toInteger maxDay) "day range",
      bad (rTicks r >= 0 && rTicks r <= toInteger dayLengthTicks) "clock range",
      bad (sortOn id [(x, z) | (x, z, _, _) <- rBeds r] == sortOn id (map pair cropCells)) "crop identities/duplicates",
      bad (all (\(_, _, s, w) -> s >= 0 && s <= 3 && (s /= 0 || not w)) (rBeds r)) "crop state",
      bad (sortOn id [(x, z) | (x, z, _, _) <- rWood r] == sortOn id (map pair woodCells)) "wood identities/duplicates",
      bad (all (\(_, _, n, l) -> n >= 0 && n <= toInteger dryGoal && (l || n == 0)) (rWood r)) "wood state",
      checkCells "roofs" (rRoofs r) roofAllowed,
      checkCells "paths" (rPaths r) groundAllowed,
      checkCells "seats" (rSeats r) groundAllowed,
      bad (Set.null (Set.intersection (Set.fromList (rPaths r)) (Set.fromList (rSeats r)))) "path/seat overlap",
      bad (rBuild r >= 0 && rBuild r <= 3) "build selection",
      bad
        ( rTurnips r >= 0
            && rTurnips r <= toInteger maxInventory
            && rDryWood r >= 0
            && rDryWood r <= toInteger maxInventory
        )
        "inventory range",
      bad (rDinner r >= 0 && rDinner r <= 3) "dinner state",
      validateNight (rDay r) (rNight r),
      case fromRaw r of
        Nothing -> ["enum conversion"]
        Just g -> bad (positionClear (playerPosition g) g) "player collision"
    ]
  where
    pair (Cell x z) = (toInteger x, toInteger z)
    bad good message = [message | not good]
    roofAllowed c = baseWalkable c && c /= homeCell && c /= Cell 13 4
    groundAllowed c = baseWalkable c && not (reservedGround c)
    checkCells label xs allowed =
      bad
        ( length xs <= worldWidth * worldDepth
            && Set.size (Set.fromList xs) == length xs
            && all
              ( \(x, z) ->
                  x >= 0
                    && z >= 0
                    && x < toInteger worldWidth
                    && z < toInteger worldDepth
                    && allowed (Cell (fromInteger x) (fromInteger z))
              )
              xs
        )
        (label <> " range/duplicates")

validateNight :: Integer -> Maybe RawNight -> [Text]
validateNight currentDay night = ["last-night report" | not valid]
  where
    valid = case night of
      Nothing -> currentDay == 1
      Just (RawNight d grown rainCount changes) ->
        d >= 1
          && d <= toInteger maxDay
          && currentDay == min (toInteger maxDay) (d + 1)
          && grown >= 0
          && grown <= 3
          && rainCount >= 0
          && rainCount <= 3
          && (even d || rainCount == 0)
          && length changes <= 2
          && length changes == Set.size (Set.fromList [(x, z) | (x, z, _, _, _) <- changes])
          && all (validChange d) changes
    validChange d (x, z, before, after, covered) =
      (x, z) `elem` [(7, 9), (8, 9)]
        && before >= 0
        && before <= toInteger dryGoal
        && after == min (toInteger dryGoal) (before + amount)
      where
        amount = if even d && not covered then toInteger dryGoal `div` 8 else toInteger dryGoal `div` 2

invariantErrors :: Game -> [Text]
invariantErrors = validateRaw . rawGame

-- | Walk with real ticks along a breadth-first route.  Used by executable
-- render-checks and tests; this never directly rewrites or teleports Game.
-- Unreachable or invalid destinations leave the original state unchanged.
walkToCell :: Cell -> Game -> Game
walkToCell target start = case route (playerCell start) target start of
  Nothing -> start
  Just waypoints -> foldl' walkSegment start (playerCell start : waypoints)
  where
    walkSegment g c = go (40 :: Int) g
      where
        (tx, tz) = center c
        go 0 current = current
        go budget current
          | abs (tx - gPlayerX current) < 10 && abs (tz - gPlayerZ current) < 10 = current
          | otherwise =
              let dx = signum (tx - gPlayerX current)
                  dz = if dx == 0 then signum (tz - gPlayerZ current) else 0
               in go (budget - 1) (fst (advance (Tick dx dz) current))

route :: Cell -> Cell -> Game -> Maybe [Cell]
route start target g
  | not (walkableCell target g) = Nothing
  | otherwise = search (Seq.singleton (start, [])) (Set.singleton start)
  where
    search queue visited = case Seq.viewl queue of
      Seq.EmptyL -> Nothing
      (c, reversed) Seq.:< rest
        | c == target -> Just (reverse reversed)
        | otherwise ->
            let next = filter (\n -> walkableCell n g && Set.notMember n visited) (neighbors c)
                queue' = foldl' (\q n -> q Seq.|> (n, n : reversed)) rest next
                visited' = foldl' (flip Set.insert) visited next
             in search queue' visited'
    neighbors (Cell x z) = [Cell (x + 1) z, Cell x (z + 1), Cell (x - 1) z, Cell x (z - 1)]

-- | Representative scenes are real legal command traces.  DayTwo includes a
-- sheltered crop and a sheltered log beside exposed peers.  DayThree has ripe
-- exposed crops and a delayed roofed crop, so the tradeoff remains visible.
scenarioGame :: Scenario -> Game
scenarioGame scenario = case scenario of
  DayOne -> day1
  DayTwo -> day2
  DayThree -> day3
  AfterDinner -> finished
  where
    useAt c = fst . advance Interact . walkToCell c
    plantAndWater g c = fst (advance Interact (useAt c g))
    planted = foldl' plantAndWater initialGame cropCells
    loaded = foldl' (flip useAt) planted woodCells
    promised = useAt (neighborCell loaded) loaded
    roofAt c = fst . advance (BuildAt c) . fst . advance (ChooseBuild Roof) . walkToCell c
    day1 = roofAt (Cell 8 5) (roofAt (Cell 7 9) promised)
    day2 = useAt homeCell day1
    day3 = useAt homeCell day2
    withTurnip = useAt (Cell 9 5) day3
    withWood = useAt (Cell 7 9) withTurnip
    dinner = useAt cookingCell withWood
    finished = useAt (neighborCell dinner) dinner
