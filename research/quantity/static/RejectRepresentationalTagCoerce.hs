module RejectRepresentationalTagCoerce where
import Colony.Units
import Data.Coerce (coerce)
newtype WaterTag = WaterTag Int
newtype OreTag = OreTag Int
tagsAreRepresentationallyEqual :: WaterTag -> OreTag
tagsAreRepresentationallyEqual = coerce
bad :: Qty WaterTag -> Qty OreTag
bad = coerce
