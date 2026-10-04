{-# LANGUAGE RoleAnnotations #-}
module ExposedQty (Qty(..)) where
import Data.Int (Int64)
-- Synthetic example only. Not the production module, and not a suggested patch.
newtype Qty r = Qty Int64
type role Qty nominal
