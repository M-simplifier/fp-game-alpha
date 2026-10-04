module RejectCrossCoerce where
import Colony.Units
import Data.Coerce (coerce)
data WaterTag
data OreTag
bad :: Qty WaterTag -> Qty OreTag
bad = coerce
