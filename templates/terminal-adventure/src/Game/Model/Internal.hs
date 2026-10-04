-- | Representation available to this game's rules. Consumers use Game.Model.
module Game.Model.Internal where

-- The wrappers distinguish axes and turns; they alone do not validate bounds.
newtype Column = Column Int deriving (Eq, Show)

newtype Row = Row Int deriving (Eq, Show)

newtype Turn = Turn Integer deriving (Eq, Show)

data Position = Position Column Row deriving (Eq, Show)

data Progress = Exploring | Escaped deriving (Eq, Show)

data World = World
  { worldPosition :: Position,
    worldTurn :: Turn,
    worldProgress :: Progress
  }
  deriving (Eq, Show)
