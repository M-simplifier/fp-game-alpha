module RejectCrossAdd where
import Colony.Units
data WaterTag
data OreTag
bad :: Qty WaterTag -> Qty OreTag -> Either String (Qty WaterTag)
bad = addQty
