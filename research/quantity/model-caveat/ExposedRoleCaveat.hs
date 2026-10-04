module ExposedRoleCaveat where
import ExposedQty
import Data.Coerce (coerce)
data WaterTag
data OreTag
-- Expected to compile: constructor visibility permits newtype unwrapping.
relabelWithVisibleConstructor :: Qty WaterTag -> Qty OreTag
relabelWithVisibleConstructor = coerce
