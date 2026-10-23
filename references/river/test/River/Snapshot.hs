{-# LANGUAGE OverloadedStrings #-}

module River.Snapshot (checks) where

import Data.Text (Text)
import Data.Text qualified as Text
import Game.Arena (observe)
import Life.Adapter
import Life.Domain

checks :: [(String, Bool)]
checks =
  [ ( "version-one save keeps its exact constructor, field order and spelling",
      encodeGame initialGame == initialSave && decodeGame initialSave == Right initialGame
    ),
    ( "save restores every scenario and its immediate observation",
      all
        ( \game ->
            decodeGame (encodeGame game) == Right game
              && fmap (observe RiverArena Villager) (decodeGame (encodeGame game)) == Right (observe RiverArena Villager game)
        )
        scenes
    ),
    ( "save continuation preserves state and effects",
      all
        ( \game ->
            all
              (\command -> fmap (advance command) (decodeGame (encodeGame game)) == Right (advance command game))
              [Tick 0 0, Interact, BuildAt (Cell 2000 2000)]
        )
        scenes
    ),
    ( "save framing accepts whitespace and rejects trailing data",
      decodeGame (" \n" <> initialSave <> "\n ") == Right initialGame
        && decodeGame (initialSave <> "x") == Left SaveMalformed
        && decodeGame "nonsense" == Left SaveMalformed
    ),
    ( "size limit is inclusive and precedes parsing",
      let atLimit = initialSave <> Text.replicate (65536 - Text.length initialSave) " "
       in decodeGame atLimit == Right initialGame
            && decodeGame (atLimit <> " ") == Left SaveTooLarge
            && decodeGame (Text.replicate 65536 "x") == Left SaveMalformed
    ),
    ( "version failure precedes invalid field diagnostics",
      decodeGame (Text.replace "rX = 450" "rX = -1" (Text.replace "rVersion = 1" "rVersion = 9" initialSave))
        == Left (SaveVersionUnsupported 9)
    ),
    ( "invalid numeric and cross-field states retain ordered diagnostics",
      all
        (\(old, new, problems) -> altered old new == Left (SaveInvalid problems))
        [ ("rX = 450", "rX = -1", ["player range", "player collision"]),
          ("rDay = 1", "rDay = 0", ["day range", "last-night report"]),
          ("rDay = 1", "rDay = 18446744073709551617", ["day range", "last-night report"]),
          ("rTicks = 0", "rTicks = 10801", ["clock range"]),
          ("rRoofs = []", "rRoofs = [(7,9),(7,9)]", ["roofs range/duplicates"]),
          ("rBeds = [(8,5,0,False)", "rBeds = [(8,5,0,True)", ["crop state"]),
          ("rWood = [(7,9,0,False)", "rWood = [(7,9,1,False)", ["wood state"]),
          ("rBuild = 0", "rBuild = 4", ["build selection", "enum conversion"]),
          ("rDinner = 0", "rDinner = -1", ["dinner state", "enum conversion"]),
          ("rBeds = [(8,5,0,False)", "rBeds = [(9,5,4,False)", ["crop identities/duplicates", "crop state", "enum conversion"])
        ]
    ),
    ( "overlapping construction errors precede player collision",
      decodeGame
        ( Text.replace "rPaths = []" "rPaths = [(4,6)]" $
            Text.replace "rSeats = []" "rSeats = [(4,6)]" initialSave
        )
        == Left (SaveInvalid ["path/seat overlap", "player collision"])
    ),
    ( "unrecognized enums preserve other failures without partial conversion",
      decodeGame
        ( Text.replace "rX = 450" "rX = -1" $
            Text.replace "rBuild = 0" "rBuild = 999999999999999999999999999999" initialSave
        )
        == Left (SaveInvalid ["player range", "build selection", "enum conversion"])
    ),
    ( "unordered transport collections restore and encode in canonical order",
      let reordered =
            Text.replace
              "rBeds = [(8,5,0,False),(9,5,0,False),(10,5,0,False)]"
              "rBeds = [(10,5,0,False),(8,5,0,False),(9,5,0,False)]"
              initialSave
       in fmap encodeGame (decodeGame reordered) == Right initialSave
    ),
    ( "factual night reports validate closing weather, amounts and identities",
      all
        (\(old, new) -> decodeGame (Text.replace old new (encodeGame (scenarioGame DayThree))) == Left (SaveInvalid ["last-night report"]))
        [ ("RawNight 2 2 2", "RawNight 1 2 2"),
          ("7,9,3600,7200,True", "7,9,3600,4500,True"),
          ("8,9,3600,4500,False", "8,9,3600,7200,False"),
          ("8,9,3600,4500,False", "7,9,3600,7200,True")
        ]
    )
  ]
  where
    altered old new = decodeGame (Text.replace old new initialSave)
    scenes = initialGame : map scenarioGame [DayOne, DayTwo, DayThree, AfterDinner]

initialSave :: Text
initialSave = "RawSave {rVersion = 1, rX = 450, rZ = 650, rFX = 0, rFZ = 1, rDay = 1, rTicks = 0, rBeds = [(8,5,0,False),(9,5,0,False),(10,5,0,False)], rWood = [(7,9,0,False),(8,9,0,False)], rRoofs = [], rPaths = [], rSeats = [], rBuild = 0, rTurnips = 0, rDryWood = 0, rDinner = 0, rNight = Nothing}"
