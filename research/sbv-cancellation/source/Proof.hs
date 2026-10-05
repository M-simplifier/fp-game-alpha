module Main where
import Data.SBV hiding (safe, name, partition)
import qualified Colony.Jobs as Core
import Control.Monad (unless, when, forM)
import Data.List (intercalate)
import System.Directory (createDirectoryIfMissing)
import System.IO (hSetBuffering, BufferMode(..), stdout)

-- One SInteger total, no machine-width arithmetic; matches the Integer helper.
loss :: SInteger -> SInteger -> SInteger -> SInteger
loss q p r = ite (r .== 0) 0 ((q * p) `sDiv` r)
valid :: SInteger -> SInteger -> SInteger -> SBool
valid q p r = q .>= 0 .&& r .> 0 .&& p .>= 0 .&& p .<= r
safe :: SInteger -> SInteger -> SInteger -> SBool
safe q p r = let l = loss q p r; refund = q - l
             in l .>= 0 .&& l .<= q .&& refund .>= 0 .&& l + refund .== q
cfg :: String -> SMTConfig
cfg name = z3 { transcript = Just ("logs/smt/" ++ name ++ ".smt2"), validateModel = True }
status :: SMTResult -> String
status (Unsatisfiable _ _) = "unsat"
status (Satisfiable _ _) = "sat"
status (Unknown _ _) = "unknown"
status (ProofError _ _ _) = "error"
status _ = "other"
record :: String -> String -> String -> IO ()
record name state raw = do
  putStrLn (name ++ ": " ++ state ++ "\n" ++ raw)
  writeFile ("logs/" ++ name ++ ".txt") (raw ++ "\n")
proveCase :: String -> Symbolic SBool -> IO (String,String)
proveCase name prop = do
  r@(ThmResult smt) <- proveWith (cfg name) (setTimeOut 15000 >> prop)
  record name (status smt) (show r)
  pure (name,status smt)
satCase :: String -> Symbolic SBool -> IO (String,String)
satCase name prop = do
  r@(SatResult smt) <- satWith (cfg name) (setTimeOut 15000 >> prop)
  record name (status smt) (show r)
  unless (status smt == "sat") (fail (name ++ " did not produce the required counterexample"))
  when (name == "legacy_eight_lots_counterexample") $ do
    let integer key = maybe (fail ("Missing solver model value: " ++ key)) pure
                            (getModelValue key r :: Maybe Integer)
    q <- integer "Q"; p <- integer "p"; denom <- integer "R"
    qs <- forM [1..8::Int] (integer . ("q"++) . show)
    old <- integer "legacyLoss"; new <- integer "aggregateLoss"
    let actualOld = sum (map (Core.cancelLoss p denom) qs)
        actualNew = Core.cancelLoss p denom q
    unless (sum qs == q && actualOld == old && actualNew == new && old /= new)
      (fail "Solver witness did not replay through imported cancelLoss")
    writeFile "logs/solver-witness-core-replay.txt"
      ("PASS solver-extracted witness -> imported Colony.Jobs.cancelLoss\n" ++
       show (q,p,denom,qs,old,new,actualOld,actualNew) ++ "\n")
  pure (name,status smt)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  createDirectoryIfMissing True "logs/smt"
  let concreteInputs = [(q,p,r) | q <- [0..64], r <- [1..32], p <- [0..r]]
      bridges = [unliteral (loss (literal q) (literal p) (literal r)) == Just (Core.cancelLoss p r q)
                | (q,p,r) <- concreteInputs]
  unless (and bridges) (fail "SBV literal/core cancelLoss bridge mismatch")
  writeFile "logs/sbv-core-bridge.txt" ("PASS SBV loss literal evaluation equals imported frozen Colony.Jobs.cancelLoss: " ++ show (length bridges) ++ " inputs\n")
  putStrLn ("SBV_CORE_BRIDGE_PASS " ++ show (length bridges))
  bounds <- proveCase "integer_bounds_general" $ do
    q <- sInteger "Q"; p <- sInteger "p"; r <- sInteger "R"
    pure (valid q p r .=> safe q p r)
  conservation <- proveCase "integer_conservation_general" $ do
    q <- sInteger "Q"; p <- sInteger "p"; r <- sInteger "R"
    let l = loss q p r
    pure (valid q p r .=> l + (q-l) .== q)
  partition <- proveCase "eight_slot_partition_general" $ do
    qs <- sIntegers ["q" ++ show n | n <- [1..8::Int]]
    q <- sInteger "Q"; p <- sInteger "p"; r <- sInteger "R"
    pure ((valid q p r .&& sAnd (map (.>=0) qs) .&& sum qs .== q)
          .=> loss (sum qs) p r .== loss q p r)
  monotone <- proveCase "integer_monotonicity_general" $ do
    q <- sInteger "Q"; lo <- sInteger "p_low"; hi <- sInteger "p_high"; r <- sInteger "R"
    pure ((valid q lo r .&& valid q hi r .&& lo .<= hi) .=> loss q lo r .<= loss q hi r)
  -- Always run the explicitly finite fallback as separately scoped evidence.
  -- All variables remain SInteger; only the assumptions bound their values.
  -- A successful solver result covers the entire finite domain, not samples.
  bounded <- proveCase "integer_bounds_bounded" $ do
    q <- sInteger "Q"; p <- sInteger "p"; r <- sInteger "R"
    pure ((valid q p r .&& q .<= 64 .&& r .<= 32) .=> safe q p r)
  boundedMono <- proveCase "integer_monotonicity_bounded" $ do
    q <- sInteger "Q"; lo <- sInteger "p_low"; hi <- sInteger "p_high"; r <- sInteger "R"
    pure ((valid q lo r .&& valid q hi r .&& lo .<= hi .&& q .<= 64 .&& r .<= 32)
          .=> loss q lo r .<= loss q hi r)
  old <- satCase "legacy_eight_lots_counterexample" $ do
    qs <- sIntegers ["q" ++ show n | n <- [1..8::Int]]
    q <- sInteger "Q"; p <- sInteger "p"; r <- sInteger "R"
    oldLoss <- sInteger "legacyLoss"; newLoss <- sInteger "aggregateLoss"
    pure (q .== 8 .&& p .== 60000 .&& r .== 120000
       .&& sAnd (map (.==1) qs) .&& sum qs .== q
       .&& oldLoss .== sum (map (\v -> loss v p r) qs)
       .&& newLoss .== loss q p r .&& oldLoss ./= newLoss)
  missing <- satCase "negative_missing_progress_upper_bound" $ do
    q <- sInteger "Q"; p <- sInteger "p"; r <- sInteger "R"
    l <- sInteger "loss"; refund <- sInteger "refund"
    pure (q .>= 0 .&& r .> 0 .&& p .>= 0 .&& l .== loss q p r
          .&& refund .== q-l .&& sNot (safe q p r))
  -- Separate bit-vector demonstration: safety above does not imply Word64
  -- multiplication agrees with arbitrary-precision Integer multiplication.
  overflow <- satCase "word64_overflow_separate_counterexample" $ do
    q <- sWord64 "Q64"; p <- sWord64 "p64"; r <- sWord64 "R64"
    let narrow = (q*p) `sDiv` r
        wide = (sFromIntegral q * sFromIntegral p :: SInteger) `sDiv` sFromIntegral r
    narrowResult <- sWord64 "wrappedLoss64"
    wideResult <- sInteger "mathematicalLoss"
    pure (q .== maxBound .&& p .== 2 .&& r .== 2
          .&& narrowResult .== narrow .&& wideResult .== wide .&& sFromIntegral narrow ./= wide)
  let results = [bounds,conservation,partition,monotone,bounded,boundedMono,old,missing,overflow]
  writeFile "metadata/proof-results.json" ("{\n" ++ intercalate ",\n" ["  "++show n++": "++show s | (n,s)<-results] ++ "\n}\n")
  unless (snd conservation == "unsat" && snd partition == "unsat") (fail "Required theorem not proved")
  unless (snd bounds == "unsat" || snd bounded == "unsat") (fail "Neither general nor bounded safety proved")
  unless (snd monotone == "unsat" || snd boundedMono == "unsat") (fail "Neither general nor bounded monotonicity proved")
  putStrLn "SBV_CANCELLATION_ACCEPTANCE_PASS"
