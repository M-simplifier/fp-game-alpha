{-# LANGUAGE OverloadedStrings #-}

module River.Gameplay (checks) where

import Data.Text qualified as Text
import Life.Domain

checks :: [(String, Bool)]
checks =
  [ ( "authored journey reaches each valid day and dinner",
      map dayNumber scenes == [1, 1, 2, 3, 3]
        && weather dayTwo == Rainy
        && dinnerStatus complete == DinnerShared
        && all (null . invariantErrors) scenes
    ),
    ( "roof changes an overnight crop without changing its neighbor",
      cropStageAt (Cell 8 5) dayThree == Just Sprouting
        && cropStageAt (Cell 9 5) dayThree == Just Ripe
        && woodDrynessAt (Cell 7 9) dayThree == Just 100
        && woodDrynessAt (Cell 8 9) dayThree == Just 62
    ),
    ( "overnight report persists after later roof edits",
      let edited = fst (advance (RemoveAt (Cell 7 9)) (walkToCell (Cell 7 9) dayThree))
       in lastNightReport edited == lastNightReport dayThree
            && fmap lastNightReport (decodeGame (encodeGame edited)) == Right (lastNightReport dayThree)
    ),
    ( "closing-day rain, growth and morning rain remain separate",
      crops dayTwo
        == [ CropView (Cell 8 5) Sprouting False,
             CropView (Cell 9 5) Sprouting True,
             CropView (Cell 10 5) Sprouting True
           ]
        && firewood dayTwo == [WoodView (Cell 7 9) 50 True, WoodView (Cell 8 9) 50 True]
        && any (Text.isInfixOf "50% → 62.5%（+12.5%）") (lastNightReport dayThree)
    ),
    ( "day saturates without inventing another overnight day",
      let atLimit = decodeGame $ Text.replace "rDay = 2" "rDay = 1000000" $ Text.replace "RawNight 1 " "RawNight 999999 " $ encodeGame dayTwo
       in case atLimit of
            Left _ -> False
            Right game ->
              let (morning, effects) = advance Interact (walkToCell homeCell game)
               in dayNumber morning == 1000000
                    && dayTicks morning == 0
                    && null (invariantErrors morning)
                    && case effects of
                      [Changed _, SaveRecommended] -> True
                      _ -> False
    ),
    ( "tick controls saturate before arithmetic",
      advance (Tick maxBound minBound) start == advance (Tick 1 (-1)) start
    ),
    ( "repeated logical ticks are not deduplicated and the clock caps",
      dayTicks (runCommands [Tick 0 0, Tick 0 0] start)
        == dayTicks (fst (advance (Tick 0 0) start)) + 1
        && dayTicks (waitTicks (dayLengthTicks + 1) start) == dayLengthTicks
        && waitTicks (-1) start == start
    ),
    ( "finite command prefixes preserve the state invariant",
      let path = concatMap (replicate 80) [Tick 0 (-1), Tick (-1) 0, Tick 0 1, Tick 1 0]
       in all (null . invariantErrors) (scanl (\game command -> fst (advance command game)) start path)
    ),
    ( "invalid or blocked journey targets do not consume ticks",
      all (\cell -> walkToCell cell dayOne == dayOne) [Cell (-1) 0, Cell 20 16, Cell 3 3, Cell 18 5]
    ),
    ( "build admission protects player footprint and reserved ground",
      not (canBuildAt Seat (playerCell start) start)
        && not (canBuildAt Path mailboxCell start)
        && not (canBuildAt Roof homeCell start)
        && all (\kind -> not (canBuildAt kind (Cell maxBound minBound) start)) [minBound .. maxBound]
    ),
    ( "removal resolves a roof before a seat on the same cell",
      let cell = Cell 6 6
          build kind = fst . advance (BuildAt cell) . fst . advance (ChooseBuild kind)
          built = build Roof (build Seat start)
          (withoutRoof, effects) = advance (RemoveAt cell) built
       in isRoofed cell built
            && cell `elem` seats built
            && not (isRoofed cell withoutRoof)
            && cell `elem` seats withoutRoof
            && effects == [Changed "屋根を片づけた。ここには雨が届きます。", SaveRecommended]
    ),
    ( "rejected construction retains state and emits no save recommendation",
      advance (BuildAt (Cell 2000 2000)) start
        == (start, [Changed "ここには置けません。少し近づくか、場所を変えてみよう。"])
    ),
    ( "planting prompt and action share the facing tie-break",
      let facingRight = runCommands (replicate 5 (Tick 1 0)) (walkToCell (Cell 8 5) start)
          facingLeft = runCommands (replicate 5 (Tick (-1) 0)) (walkToCell (Cell 9 5) start)
          chooses selected untouched game =
            let (planted, effects) = advance Interact game
             in playerPosition game == (900, 550)
                  && interactionLabel game == "E  カブの種をまく"
                  && cropStageAt selected planted == Just Planted
                  && cropStageAt untouched planted == Just Empty
                  && effects == [Changed "カブの種をまいた。水をやって、二晩待とう。", SaveRecommended]
       in chooses (Cell 9 5) (Cell 8 5) facingRight
            && chooses (Cell 8 5) (Cell 9 5) facingLeft
    )
  ]
  where
    start = initialGame
    dayOne = scenarioGame DayOne
    dayTwo = scenarioGame DayTwo
    dayThree = scenarioGame DayThree
    complete = scenarioGame AfterDinner
    scenes = [start, dayOne, dayTwo, dayThree, complete]
