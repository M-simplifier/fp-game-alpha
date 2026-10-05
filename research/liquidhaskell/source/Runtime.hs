module Main where
import qualified Contracts as C
import qualified CancelLoss as L
import qualified DivAssumptionProbe as D
import qualified Colony.Units as U
import qualified Colony.Jobs as J
import Control.Monad (forM_, unless)

check :: Bool -> String -> IO ()
check ok msg = unless ok (error msg)

main :: IO ()
main = do
  let values = [0,1,2,8999999999999,9000000000000]
      checked f x y = case (U.mkQty x, U.mkQty y) of
        (Right a, Right b) -> either (const Nothing) (Just . U.qtyValue) (f a b)
        _ -> error "invalid test fixture"
  forM_ [(x,y) | x<-values, y<-values] $ \(x,y) -> do
    check (C.checkedAdd x y == checked U.addQty x y) "checkedAdd bridge"
    check (C.checkedSub x y == checked U.subQty x y) "checkedSub bridge"
  let inputs = [(p,r,q) | q<-[0..32], r<-[1..16], p<-[0..r]]
  forM_ inputs $ \(p,r,q) -> do
    check (L.cancelLoss p r q == J.cancelLoss p r q) "cancelLoss bridge"
    check (0 <= L.cancelLoss p r q && L.cancelLoss p r q <= q) "cancelLoss bounds"
  check (D.divZeroProbe 0 == 0) "real Haskell div result"
  check (D.divZeroProbe 0 /= 99) "deliberate false postcondition"
  putStrLn "PASS checkedAdd/checkedSub bridge: 25 pairs, 50 comparisons"
  putStrLn ("PASS exact cancelLoss body bridge and bounds: " ++ show (length inputs) ++ " triples")
  putStrLn "DIV_PROBE_RUNTIME input=0 result=0 deliberately-claimed-result=99 isFalse=True"
