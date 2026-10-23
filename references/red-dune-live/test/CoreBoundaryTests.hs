{-# LANGUAGE CPP #-}

module Main where

import Core.SessionTests (sessionTests)
#ifndef mingw32_HOST_OS
import Core.SnapshotTests (snapshotTests)
#endif

main :: IO ()
main = do
  sessionTests
#ifndef mingw32_HOST_OS
  snapshotTests
  putStrLn "LIVE_CORE_BOUNDARY PASS: immutable issuer identity and captured save metadata"
#else
  putStrLn "LIVE_CORE_BOUNDARY PASS: immutable issuer identity (POSIX save boundary runs on Linux)"
#endif
