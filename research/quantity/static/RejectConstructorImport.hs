module RejectConstructorImport where
import Colony.Units (Qty(Qty), StockUnit)
bad :: Qty StockUnit
bad = Qty (-1)
