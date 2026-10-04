-- Read-only verifier for private UI trace artifacts. Rebuilds the explicit
-- fixture using the recorded fresh session, replays actual NativeInputs, and
-- joins versioned activation records using exact preserved archive bytes.
module Main(main) where
import Colony.Codec
import Colony.Content
import Colony.Scheduler(pureStep)
import Colony.Session(bindRecordedSession)
import Colony.SessionTrace
import Colony.UIFixture
import Colony.S01Fixture
import Colony.World
import Control.DeepSeq(force)
import Control.Exception(evaluate)
import Control.Monad(unless)
import qualified Data.ByteString as BS
import Data.Char(digitToInt,isHexDigit)
import Data.List(stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe(mapMaybe)
import Data.Word(Word64)
import System.Environment(getArgs)
import System.IO
import Text.Read(readMaybe)

right :: Show e=>Either e a->IO a
right=either(fail.show)pure
assert :: String -> Bool -> IO()
assert message condition=unless condition(fail message)
hexDecode :: String -> Either String BS.ByteString
hexDecode s=BS.pack <$> go s
  where
    go []=Right[]
    go(a:b:rest)|isHexDigit a&&isHexDigit b=((fromIntegral(digitToInt a*16+digitToInt b)):) <$> go rest
    go _=Left "Invalid hex in trace"
parseNative :: String -> Either String(NativeInput,ColonyOutput)
parseNative text=case reads text of
  [(input,rest)]->case stripPrefix " => " rest >>= readMaybe of Just output->Right(input,output);_->Left "Invalid native output"
  _->Left "Invalid native input"

main :: IO()
main=do
  args<-getArgs
  directory<-case args of [one]->pure one;_->fail "Usage: replay-ui-session TRACE_DIRECTORY"
  content<-loadContent "data/content-v1.json" >>= right
  shellText<-readFile(directory++"/shell-actions.log")
  let shellLines=lines shellText
      starts=mapMaybe(stripPrefix "startup fresh branch=")shellLines
      fixtures=mapMaybe(stripPrefix "startup-fixture ")shellLines
  template<-case fixtures of
    []->snd <$> right(uiFixture content)
    ["legacy-four-colony"]->snd <$> right(uiFixture content)
    ["s01"]->snd <$> right(s01Fixture content)
    _->fail "Unknown or duplicate startup fixture tag"
  (branch,authority)<-case starts of
    [one]->case words one of [number,tagged]|Just bid<-readMaybe number,Just ident<-stripPrefix "authority=" tagged->pure(bid,ident);_->fail "Invalid startup trace"
    _->fail "Expected one startup; trace runs must have separate directories"
  initial<-right(bindRecordedSession authority(branchId template)template{branchId=branch})
  sources<-mapM(right.hexDecode)(mapMaybe(stripPrefix "activation-source-checkpoint ")shellLines)
  records<-mapM(\line->right(hexDecode line)>>=right.decodeActivationRecord)(mapMaybe(stripPrefix "activation-cbor-v1 ")shellLines)
  let sourceMap=M.fromList[(sha256 bytes,bytes)|bytes<-sources]
  assert "Trace checkpoint hashes are unique or repeated byte-identical"(all(\bytes->M.lookup(sha256 bytes)sourceMap==Just bytes)sources)
  (finished,count,left)<-withFile(directory++"/native-boundaries.log")ReadMode $ \handle->loop sourceMap handle initial(0::Word64)records
  (final,remaining)<-applyRest sourceMap finished left
  assert "Unconsumed activation records"(null remaining)
  digest<-right(canonicalStateHash final)
  putStrLn("UI trace exact replay PASS boundaries="++show count++" activations="++show(length records)++" branch="++show(branchId final)++" tick="++show(simTick final)++" canonicalSHA256="++concatMap(\byte->["0123456789abcdef"!!fromIntegral(byte `div` 16),"0123456789abcdef"!!fromIntegral(byte `mod` 16)])(BS.unpack digest))
  where
    applyOne sources world record=do
      bytes<-maybe(fail "Referenced source checkpoint bytes absent from trace")pure(M.lookup(activationSourceHash record)sources)
      right(replayActivation record world bytes)>>=evaluate.force
    applyRest _ world []=pure(world,[])
    applyRest sources world(record:rest)=do
      next<-applyOne sources world record
      applyRest sources next rest
    loop sources handle world count records=do
      ended<-hIsEOF handle
      if ended then pure(world,count,records)else do
        line<-hGetLine handle
        (input,expected)<-right(parseNative line)
        (current,pending)<-align sources world records input
        encoded<-right(encodeNativeInput input)
        decoded<-right(decodeNativeInput encoded)
        (next,actual)<-evaluate(force(pureStep decoded current))
        assert("Native output differs at ordinal "++show count)(actual==expected)
        loop sources handle next(count+1)pending
    align sources world records input@(Boundary header _ _)
      |headerWorld header==worldId world&&headerBranch header==branchId world&&headerAuthority header==worldAuthority world=pure(world,records)
      |otherwise=case records of
        []->fail "Native session changed without an activation record"
        record:rest->applyOne sources world record >>= \next->align sources next rest input
