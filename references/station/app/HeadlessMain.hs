{-# LANGUAGE OverloadedStrings #-}
-- | Player transport only. All decisions run through the original Arena.
module Main (main) where

import Data.Char (ord)
import Data.List (intercalate)
import qualified Data.Text as T
import Game.Arena (observe, play, singleton)
import Numeric (showHex)
import Station.Adapter (Clerk (..), Dispatch (..), StationArena (..), StationView (..), Outcome (..))
import qualified Station.Domain as D
import System.IO (BufferMode (LineBuffering), hIsEOF, hSetBuffering, hSetEncoding, utf8, stdin, stdout)
import Text.Read (readMaybe)

-- JSON output is deliberately projected, never derived from Show GameState.
quoted :: String -> String
quoted s = '"' : concatMap escape s ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c | ord c < 32 = let h = showHex (ord c) "" in "\\u" ++ replicate (4 - length h) '0' ++ h
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
option o = object
  [ ("action", quoted (choiceId (D.optionChoice o)))
  , ("label", text (D.choiceLabel (D.optionChoice o)))
  , ("available", either (const "false") (const "true") (D.optionResult o))
  , ("result", either (const "null") resources (D.optionResult o))
  , ("reason", either (text . D.domainErrorText) (const "null") (D.optionResult o))
  ]

packet :: String -> String -> String -> D.GameState -> String
packet result feedback category game = object
  [ ("protocol", "1"), ("game", quoted "station"), ("result", quoted result)
  , ("feedback", quoted feedback), ("refusal_kind", quoted category)
  , ("status", quoted (maybe "running" (const "terminal") (viewEnding v)))
  , ("turn", maybe "null" (show . D.turnNumber) (viewTurn v))
  , ("completed", show (viewCompleted v)), ("total", show D.totalTurns)
  , ("resources", resources (viewResources v))
  , ("order", maybe "null" currentOrder (D.currentOrder game))
  , ("options", array (map option (viewOptions v)))
  , ("ending", maybe "null" ending (viewEnding v))
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

-- | Decoded transport input. The requested number is not an authoritative
-- TurnId; dispatch still resolves and checks the currently visible token.
data Command = Observe | Act Integer D.Choice

parseCommand :: String -> Either String Command
parseCommand command = case words command of
  ["observe"] -> Right Observe
  ["act", revision, action] -> case (readMaybe revision :: Maybe Integer, parseChoice action) of
    (Just requested, Just choice) -> Right (Act requested choice)
    _ -> Left "Expected act <visible-turn> express|local|defer."
  _ -> Left "Expected observe or act <visible-turn> express|local|defer."

-- | Turn-number validation belongs to the transport. The Arena and domain
-- still own participant admission, resource costs and token freshness.
dispatchVisibleTurn :: Integer -> D.Choice -> D.GameState
                    -> Either String (D.GameState, [Outcome])
dispatchVisibleTurn requested choice game = case D.currentTurn game of
  Nothing -> Left "The episode has ended."
  Just turn
    | requested /= toInteger (D.turnNumber turn) -> Left "Stale turn; observe again."
    | otherwise -> case play StationArena () (singleton LocalClerk (Dispatch turn choice)) game of
        Left _ -> Left "Participant admission failed."
        Right result -> Right result

respond :: String -> D.GameState -> (D.GameState, String)
respond command game = case parseCommand command of
  Left message -> refused message
  Right Observe -> (game, packet "observed" "" "none" game)
  Right (Act requested choice) -> case dispatchVisibleTurn requested choice game of
    Left message -> refused message
    Right (_, [Refused problem]) -> (game, packet "refused" (T.unpack (D.domainErrorText problem)) "domain" game)
    Right (next, [Accepted _]) -> (next, packet "accepted" "" "none" next)
    Right _ -> refused "Unexpected domain feedback."
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
      if eof then pure () else do
        command <- getLine
        let (next, response) = respond command game
        putStrLn response
        loop next
