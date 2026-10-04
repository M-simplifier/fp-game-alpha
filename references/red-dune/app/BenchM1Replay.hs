{-# LANGUAGE BangPatterns #-}
-- Measure one actual mixed player NativeInput trace, without timing duplicate
-- Arena/restore runs or per-frame checkpoint hashes. Checks remain outside the
-- measured interval. This is a small reference case, never a D2/soak guarantee.
module Main(main) where
import Colony.Codec
import Colony.Scheduler
import Colony.World
import Control.DeepSeq(force)
import Control.Exception(evaluate)
import Control.Monad(unless)
import qualified Data.ByteString as BS
import Data.List(stripPrefix,sort)
import Data.Word(Word64)
import GHC.Clock(getMonotonicTimeNSec)
import GHC.Stats(getRTSStats)
import System.Directory(createDirectoryIfMissing)
import System.Environment(getArgs)
import System.Exit(die)
import Text.Read(readMaybe)
import System.IO(Handle,IOMode(ReadMode),withFile,hIsEOF,hGetLine)

main :: IO()
main=do
  args<-getArgs
  case args of
    [checkpoint,tracePath,out]->run checkpoint tracePath out
    _->die "usage: bench-m1-replay initial.cbor native.log output-directory (+RTS -T -s)"
run :: FilePath -> FilePath -> FilePath -> IO()
run checkpoint tracePath out=do
  bytes<-BS.readFile checkpoint
  (_,initial)<-either(die.show)pure(decodeCheckpoint bytes)
  initialForced<-evaluate(force initial)
  createDirectoryIfMissing True out
  (final,times,count)<-withFile tracePath ReadMode(loop 0 initialForced [])
  unless(length times>1000)(die "reference requires more than1000 measured frames after warm-up")
  digest<-either(die.show)pure(canonicalStateHash final)
  let ordered=sort times
      percentile n=ordered!!min(length ordered-1)(length ordered*n `div`100)
      limit=50000000::Word64
      above=length(filter(>limit)times)
      hex=concatMap(\b->let digits="0123456789abcdef" in[digits!!fromIntegral(b `div`16),digits!!fromIntegral(b `mod`16)]) . BS.unpack
  writeFile(out++"/native-step-times-ns.csv")("frame,elapsed_ns\n"++concat[show n++","++show t++"\n"|(n,t)<-zip[1001::Integer ..](reverse times)])
  putStrLn("M1_NATIVE_REPLAY outputs exact; boundaryCount="++show count++" warmup=1000 measured="++show(length times)++" finalTick="++show(simTick final)++" finalSHA256="++hex digest)
  putStrLn("force-included native pureStep ns: p50="++show(percentile 50)++" p95="++show(percentile 95)++" p99="++show(percentile 99)++" max="++show(maximum ordered)++" above50ms="++show above)
  getRTSStats >>= print
  putStrLn "SCOPE: one40-resident S01 player trace; command-only and advancing boundaries included.1000-frame warmup, one run, this cloud CPU; no renderer/IO inside timing. Trace is streamed, retaining only timings and current World. Input parsing, initial decoding, output comparisons and final hash excluded from per-step latency but INCLUDED in total RTS allocation/residency. Not D2/D3, not10-minute+30-minute x3 protocol, not24/72h soak or worst-case latency guarantee."
  where
    parseRow line=case reads line of
      [(input,rest)]->case stripPrefix " => " rest >>= readMaybe of
        Just output->pure(input,output)
        Nothing->die "native trace output did not parse"
      _->die "native trace input did not parse"
    loop :: Integer -> World -> [Word64] -> Handle -> IO(World,[Word64],Integer)
    loop index !world samples handle=do
      ended<-hIsEOF handle
      if ended then pure(world,samples,index)else do
        line<-hGetLine handle
        (input,expected)<-parseRow line >>= evaluate . force
        started<-getMonotonicTimeNSec
        (next,output)<-evaluate(force(pureStep input world))
        stopped<-getMonotonicTimeNSec
        unless(output==expected&&null(outputDiagnostics output))(die("replay output/diagnostic mismatch at frame "++show index))
        loop(index+1)next(if index<1000 then samples else stopped-started:samples)handle
