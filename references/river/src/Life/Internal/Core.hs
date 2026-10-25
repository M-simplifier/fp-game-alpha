{-# LANGUAGE OverloadedStrings #-}

module Life.Internal.Core
  ( Game (..),
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
    turnipCount,
    dryWoodCount,
    dinnerStatus,
    forecastLabel,
    cropStageAt,
    woodDrynessAt,
    isRoofed,
    isSheltered,
    walkableCell,
    canBuildAt,
    Bed (..),
    Bundle (..),
    NightReport (..),
    Interaction (..),
    interactionTarget,
    positionClear,
    center,
    roofSiteAllowed,
    groundSiteAllowed,
    overnightDryingAmount,
    maxDay,
    maxInventory,
    dryGoal,
    weatherFor,
    tshow,
  )
where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

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
buildSiteAllowed kind c g = case kind of
  NoBuild -> False
  Roof -> roofSiteAllowed c
  Path -> groundSiteAllowed c && Set.notMember c (gSeats g)
  Seat ->
    groundSiteAllowed c
      && Set.notMember c (gPaths g)
      && seatDoesNotTouchPlayer c g

roofSiteAllowed :: Cell -> Bool
roofSiteAllowed c = baseWalkable c && c /= homeCell && c /= Cell 13 4

groundSiteAllowed :: Cell -> Bool
groundSiteAllowed c = baseWalkable c && not (reservedGround c)

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
      let amount = overnightDryingAmount (weather closingDay) (isRoofed c closingDay)
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

overnightDryingAmount :: Weather -> Bool -> Int
overnightDryingAmount closingWeather covered
  | closingWeather == Rainy && not covered = dryGoal `div` 8
  | otherwise = dryGoal `div` 2

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

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
