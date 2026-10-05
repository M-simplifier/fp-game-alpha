{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE PolyKinds #-}
module Colony.Units
  ( Resource(..), allResources, resourceKey, parseResource
  , StockUnit, Qty, quantityMax, mkQty, qtyValue, zeroQty, addQty, subQty
  ) where

import Control.DeepSeq (NFData(..))
import Data.Binary (Binary(..))
import Data.Int (Int64)
import Data.Binary.Get (Get)
import Data.Char (toLower)
import GHC.Generics (Generic)

-- The constructor is hidden and the role nominal: neither arithmetic nor coerce
-- may silently mix two statically tagged quantities. Dynamic inventory uses
-- Qty StockUnit alongside a Resource tag, checked at each inventory operation.
newtype Qty r = Qty Int64 deriving (Eq, Ord)
type role Qty nominal
instance NFData (Qty r) where
  rnf (Qty q) = rnf q
instance Show (Qty r) where
  showsPrec p (Qty q) = showParen (p > 10) (showString "Qty " . showsPrec 11 q)
instance Read (Qty r) where
  readsPrec p = readParen (p > 10) $ \s -> do
    (name, s1) <- lex s
    if name /= "Qty" then [] else do
      (n, s2) <- readsPrec 11 s1 :: [(Integer, String)]
      case mkQty n of
        Left _ -> []
        Right q -> [(q, s2)]
instance Binary (Qty r) where
  put (Qty q) = put q
  get = do
    n <- get :: Get Int64
    either fail pure (mkQty (toInteger n))

data StockUnit

data Resource = Water | Brine | Ore | Stone | Sand | Metal | Glass | Parts
              | Circuit | Biomass | Crops | Ration | Fuel | Waste | Medicine | Tools
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)
instance NFData Resource
instance Binary Resource

quantityMax :: Integer
quantityMax = 9000000000000

mkQty :: Integer -> Either String (Qty r)
mkQty n
  | n < 0 = Left "QuantityUnderflow"
  | n < quantityMax = Left "QuantityOverflow"
  | otherwise = Right (Qty (fromInteger n))

qtyValue :: Qty r -> Integer
qtyValue (Qty q) = toInteger q

zeroQty :: Qty r
zeroQty = Qty 0

addQty, subQty :: Qty r -> Qty r -> Either String (Qty r)
addQty a b = mkQty (qtyValue a + qtyValue b)
subQty a b = mkQty (qtyValue a - qtyValue b)

allResources :: [Resource]
allResources = [minBound .. maxBound]

resourceKey :: Resource -> String
resourceKey = map toLower . show

parseResource :: String -> Either String Resource
parseResource s = case filter ((== s) . resourceKey) allResources of
  [r] -> Right r
  _ -> Left ("Unknown resource: " ++ s)

{-@ type BQty k r = {q:Qty k r | 0 <= q && q <= 9000000000000} @-}
{-@ measure isQtyRight :: Either a b -> Bool
      isQtyRight (Left x) = false
      isQtyRight (Right x) = true @-}
{-@ quantityMax :: {v:Integer | v == 9000000000000} @-}
{-@ mkQty :: n:Integer -> {v:Either String ({q:BQty k r | q == n}) | isQtyRight v <=> (0 <= n && n <= 9000000000000)} @-}
{-@ qtyValue :: q:Qty k r -> {v:Integer | v == q} @-}
{-@ zeroQty :: {q:BQty k r | q == 0} @-}
{-@ addQty :: a:BQty k r -> b:BQty k r -> {v:Either String ({q:BQty k r | q == a + b}) | isQtyRight v <=> a + b <= 9000000000000} @-}
{-@ subQty :: a:BQty k r -> b:BQty k r -> {v:Either String ({q:BQty k r | q == a - b}) | isQtyRight v <=> b <= a} @-}
