{-# LANGUAGE DataKinds #-}
module RejectPromotedCoerce where
import Colony.Units
import Data.Coerce (coerce)
bad :: Qty 'Water -> Qty 'Ore
bad = coerce
