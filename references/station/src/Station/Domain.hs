{-# LANGUAGE OverloadedStrings #-}

-- | The complete, clock-free game rules. Only 'initialGame' and 'step' can
-- construct authoritative game states; UI drafts and effects are not part of it.
module Station.Domain
  ( GameState
  , TurnId
  , turnNumber
  , Choice (..)
  , Stats (..)
  , Order (..)
  , ChoiceCost (..)
  , ChoiceOption (..)
  , Delivery (..)
  , DomainError (..)
  , Ending (..)
  , initialGame
  , currentTurn
  , currentOrder
  , completedTurns
  , totalTurns
  , maximumEnergy
  , stats
  , allOrders
  , history
  , choices
  , choiceCost
  , choiceLabel
  , step
  , ending
  , endingTitle
  , endingStory
  , domainErrorText
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

-- No Read, Enum, Num, Generic or JSON instances can construct a TurnId.
newtype TurnId = TurnId Int
  deriving (Eq, Ord, Show)

turnNumber :: TurnId -> Int
turnNumber (TurnId n) = n

data Choice = Express | Local | Defer
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Read-only projection. Creating or updating a Stats value does not change a
-- GameState, and no public function accepts a Stats value as game authority.
data Stats = Stats
  { energy :: !Int
  , expressTickets :: !Int
  , deliveredFeelings :: !Int
  }
  deriving (Eq, Show)

data Order = Order
  { orderNumber :: !Int
  , orderName :: !Text
  , orderStory :: !Text
  , expressEnergy :: !Int
  , expressValue :: !Int
  , localValue :: !Int
  }
  deriving (Eq, Show)

data ChoiceCost = ChoiceCost
  { energyCost :: !Int
  , ticketCost :: !Int
  , valueDelivered :: !Int
  , energyRecovery :: !Int
  }
  deriving (Eq, Show)

-- | The projection is computed by the very same rule used by 'step'. A Right
-- value describes the exact resulting resources, including capped recovery.
data ChoiceOption = ChoiceOption
  { optionChoice :: !Choice
  , optionCost :: !ChoiceCost
  , optionResult :: !(Either DomainError Stats)
  }
  deriving (Eq, Show)

data Delivery = Delivery
  { deliveryTurn :: !TurnId
  , deliveryOrder :: !Order
  , deliveryChoice :: !Choice
  , deliveryBefore :: !Stats
  , deliveryAfter :: !Stats
  }
  deriving (Eq, Show)

data DomainError
  = GameFinished
  | StaleTurn !TurnId !TurnId -- ^ Expected, received.
  | InsufficientEnergy !Int !Int -- ^ Required, available.
  | InsufficientTickets !Int !Int -- ^ Required, available.
  deriving (Eq, Show)

data Ending = SunsetMaster | KindDay | LettersTomorrow
  deriving (Eq, Ord, Show)

-- Internal field labels are intentionally not exported: public record update
-- cannot bypass step. History is chronological and bounded by totalTurns.
data GameState = GameState
  { gameStats :: !Stats
  , gameHistory :: ![Delivery]
  }
  deriving (Eq, Show)

maximumEnergy :: Int
maximumEnergy = 8

allOrders :: [Order]
allOrders =
  [ Order 1 "焼きたてパンのかご" "丘のパン屋さんから、夕食を待つ家族へ。まだ少し温かいかごです。" 2 4 1
  , Order 2 "おばあちゃんへの花束" "帰省できなかった孫から、小さな花束。カードには「また会おうね」。" 3 6 2
  , Order 3 "忘れものの楽譜" "となり町の音楽会へ、練習の書き込みがいっぱいの楽譜を届けます。" 2 5 1
  , Order 4 "星見の望遠鏡" "今夜の星を楽しみにしている集会所へ。大きくて、少し重たい箱です。" 4 7 2
  , Order 5 "手編みの赤いマフラー" "山あいで働く友だちへ、一目ずつ編んだ贈りもの。夕方の風が冷えてきました。" 2 6 1
  , Order 6 "旅立ちの写真帳" "明日遠くへ引っ越す人へ。商店街のみんなの写真とひとことが詰まっています。" 3 7 2
  ]

totalTurns :: Int
totalTurns = length allOrders

initialGame :: GameState
initialGame = GameState (Stats maximumEnergy 3 0) []

stats :: GameState -> Stats
stats = gameStats

history :: GameState -> [Delivery]
history = gameHistory

completedTurns :: GameState -> Int
completedTurns = length . gameHistory

currentOrder :: GameState -> Maybe Order
currentOrder game =
  case drop (completedTurns game) allOrders of
    [] -> Nothing
    order : _ -> Just order

currentTurn :: GameState -> Maybe TurnId
currentTurn game = TurnId . orderNumber <$> currentOrder game

choiceCost :: Order -> Choice -> ChoiceCost
choiceCost order choice =
  case choice of
    Express -> ChoiceCost (expressEnergy order) 1 (expressValue order) 0
    Local -> ChoiceCost 1 0 (localValue order) 0
    Defer -> ChoiceCost 0 0 0 1

applyCost :: ChoiceCost -> Stats -> Either DomainError Stats
applyCost cost before
  | energy before < energyCost cost = Left (InsufficientEnergy (energyCost cost) (energy before))
  | expressTickets before < ticketCost cost = Left (InsufficientTickets (ticketCost cost) (expressTickets before))
  | otherwise =
      Right
        Stats
          { energy = min maximumEnergy (energy before - energyCost cost + energyRecovery cost)
          , expressTickets = expressTickets before - ticketCost cost
          , deliveredFeelings = deliveredFeelings before + valueDelivered cost
          }

choices :: GameState -> [ChoiceOption]
choices game =
  case currentOrder game of
    Nothing -> []
    Just order ->
      [ let cost = choiceCost order choice
         in ChoiceOption choice cost (applyCost cost (stats game))
      | choice <- [Express, Local, Defer]
      ]

-- | A command belongs to the currently visible turn. Reusing it after success
-- fails, including after the last turn. Failed commands never advance the game.
step :: TurnId -> Choice -> GameState -> Either DomainError GameState
step supplied choice game =
  case currentOrder game of
    Nothing -> Left GameFinished
    Just order ->
      let expected = TurnId (orderNumber order)
       in if supplied /= expected
            then Left (StaleTurn expected supplied)
            else do
              after <- applyCost (choiceCost order choice) (stats game)
              let delivery = Delivery expected order choice (stats game) after
              pure (GameState after (history game ++ [delivery]))

ending :: GameState -> Maybe Ending
ending game =
  case currentTurn game of
    Just _ -> Nothing
    Nothing
      | deliveredFeelings (stats game) >= 20 -> Just SunsetMaster
      | deliveredFeelings (stats game) >= 12 -> Just KindDay
      | otherwise -> Just LettersTomorrow

choiceLabel :: Choice -> Text
choiceLabel Express = "速達便"
choiceLabel Local = "各駅便"
choiceLabel Defer = "次の便へ"

endingTitle :: Ending -> Text
endingTitle SunsetMaster = "夕焼けの名配達"
endingTitle KindDay = "やさしい一日"
endingTitle LettersTomorrow = "明日につづく便り"

endingStory :: Ending -> Text
endingStory SunsetMaster = "たくさんの気持ちが、夕焼けの向こうへ届きました。こもれび駅の灯りが、誇らしげに揺れています。"
endingStory KindDay = "あなたが選んだ便で、いくつもの暮らしにぬくもりが届きました。今日は、やさしい一日でした。"
endingStory LettersTomorrow = "今日届けきれなかった気持ちも、駅で静かに出番を待っています。明日の便りは、ここからまた始まります。"

domainErrorText :: DomainError -> Text
domainErrorText GameFinished = "今日の6件はすべて記録済みです。もう一度遊ぶときは「最初から」を選んでください。"
domainErrorText (StaleTurn _ _) = "前の順番の操作は受け付けませんでした。いま表示されている依頼から選び直してください。"
domainErrorText (InsufficientEnergy needed available) =
  "体力が足りません（必要 " <> number needed <> " ／ 残り " <> number available <> "）。"
domainErrorText (InsufficientTickets needed available) =
  "速達札が足りません（必要 " <> number needed <> " ／ 残り " <> number available <> "）。"

number :: Int -> Text
number = Text.pack . show
