module RejectRawCoerce where
import Colony.Units
import Data.Coerce (coerce)
import Data.Int (Int64)
bad :: Int64 -> Qty StockUnit
bad = coerce
