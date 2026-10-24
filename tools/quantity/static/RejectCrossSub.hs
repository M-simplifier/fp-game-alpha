module RejectCrossSub where
import Colony.Units
data WaterTag
data OreTag
bad :: Qty WaterTag -> Qty OreTag -> Either String (Qty WaterTag)
bad = subQty
