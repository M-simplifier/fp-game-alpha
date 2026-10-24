{-# LANGUAGE DataKinds #-}
module Positive where
import Colony.Units
import Data.Coerce (coerce)

data WaterTag
data OreTag

water :: Qty WaterTag
water = either error id (mkQty 10)
ore :: Qty OreTag
ore = either error id (mkQty 20)
waterAdded :: Either String (Qty WaterTag)
waterAdded = addQty water water
oreSubtracted :: Either String (Qty OreTag)
oreSubtracted = subQty ore ore
sameTagCoerce :: Qty WaterTag -> Qty WaterTag
sameTagCoerce = coerce
promotedResourceWater :: Either String (Qty 'Water)
promotedResourceWater = addQty zeroQty zeroQty
