{-# LANGUAGE OverloadedStrings #-}

-- | Player transport only. All decisions run through the original Arena.
module Main (main) where

import Data.Char (ord)
import Data.List (intercalate)
import Data.Text qualified as T
import Game.Arena (observe, play, singleton)
import Numeric (showHex)
import Station.Adapter (Clerk (..), Dispatch (..), Outcome (..), StationArena (..), StationView (..))
import Station.Domain qualified as D
import System.IO (BufferMode (LineBuffering), hIsEOF, hSetBuffering, hSetEncoding, stdin, stdout, utf8)
import Text.Read (readMaybe)

-- JSON output is deliberately projected, never derived from Show GameState.
quoted :: String -> String
quoted s = '"' : concatMap escape s ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c
      | ord c < 32 = let h = showHex (ord c) "" in "\\u" ++ replicate (4 - length h) '0' ++ h
      | otherwise = [c]

text :: T.Text -> String
text = quoted . T.unpack

object :: [(String, String)] -> String
object fields = "{" ++ intercalate "," [quoted k ++ ":" ++ v | (k, v) <- fields] ++ "}"

array :: [String] -> String
array xs = "[" ++ intercalate "," xs ++ "]"

resources :: D.Stats -> String
resources s = object [("energy", show (D.energy s)), ("tickets", show (D.expressTickets s)), ("delivered", show (D.deliveredFeelings s))]

choiceId :: D.Choice -> String
choiceId D.Express = "express"
choiceId D.Local = "local"
choiceId D.Defer = "defer"

option :: D.ChoiceOption -> String
option o =
  object
    [ ("action", quoted (choiceId (D.optionChoice o))),
      ("label", text (D.choiceLabel (D.optionChoice o))),
      ("available", either (const "false") (const "true") (D.optionResult o)),
      ("result", either (const "null") resources (D.optionResult o)),
      ("reason", either (text . D.domainErrorText) (const "null") (D.optionResult o))
    ]

packet :: String -> String -> String -> D.GameState -> String
packet result feedback category game =
  object
    [ ("protocol", "1"),
      ("game", quoted "station"),
      ("result", quoted result),
      ("feedback", quoted feedback),
      ("refusal_kind", quoted category),
      ("status", quoted (maybe "running" (const "terminal") (viewEnding v))),
      ("turn", maybe "null" (show . D.turnNumber) (viewTurn v)),
      ("completed", show (viewCompleted v)),
      ("total", show D.totalTurns),
      ("resources", resources (viewResources v)),
      ("order", maybe "null" currentOrder (D.currentOrder game)),
      ("options", array (map option (viewOptions v))),
      ("ending", maybe "null" ending (viewEnding v))
    ]
  where
    v = observe StationArena LocalClerk game
    currentOrder o = object [("name", text (D.orderName o)), ("story", text (D.orderStory o))]
    ending e = object [("title", text (D.endingTitle e)), ("story", text (D.endingStory e))]

parseChoice :: String -> Maybe D.Choice
parseChoice "express" = Just D.Express
parseChoice "local" = Just D.Local
parseChoice "defer" = Just D.Defer
parseChoice _ = Nothing

respond :: String -> D.GameState -> (D.GameState, String)
respond command game = case words command of
  ["observe"] -> (game, packet "observed" "" "none" game)
  ["act", revision, action] -> case (readMaybe revision :: Maybe Integer, parseChoice action) of
    (Just requested, Just choice) -> case D.currentTurn game of
      Nothing -> refused "The episode has ended."
      Just turn
        | requested /= toInteger (D.turnNumber turn) -> refused "Stale turn; observe again."
        | otherwise -> case play StationArena () (singleton LocalClerk (Dispatch turn choice)) game of
            Left _ -> refused "Participant admission failed."
            Right (next, outcomes) -> case outcomes of
              [Refused problem] -> (game, packet "refused" (T.unpack (D.domainErrorText problem)) "domain" game)
              [Accepted _] -> (next, packet "accepted" "" "none" next)
              _ -> refused "Unexpected domain feedback."
    _ -> refused "Expected act <visible-turn> express|local|defer."
  _ -> refused "Expected observe or act <visible-turn> express|local|defer."
  where
    refused message = (game, packet "refused" message "protocol" game)

main :: IO ()
main = do
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  hSetBuffering stdout LineBuffering
  putStrLn (packet "started" "" "none" D.initialGame)
  loop D.initialGame
  where
    loop game = do
      eof <- hIsEOF stdin
      if eof
        then pure ()
        else do
          command <- getLine
          let (next, response) = respond command game
          putStrLn response
          loop next
