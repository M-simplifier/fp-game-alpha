{-# LANGUAGE OverloadedStrings #-}

module FpGame.Result
  ( Result (..),
    resultCode,
    resultValue,
    failure,
    render,
  )
where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as LazyBytes
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import FpGame.Error
import System.IO (stderr, stdout)

data Result
  = Executed [String] Int Text Text
  | Report Int Value
  | Failed ToolError
  deriving (Show)

failure :: ToolError -> Result
failure = Failed

resultCode :: Result -> Int
resultCode result = case result of
  Executed _ code _ _ -> code
  Report code _ -> code
  Failed _ -> 1

resultValue :: Result -> Value
resultValue result = case result of
  Executed command code output errors ->
    object ["command" .= command, "exit_code" .= code, "stdout" .= output, "stderr" .= errors]
  Report _ value -> value
  Failed (ToolError code message) ->
    object ["status" .= ("error" :: Text), "error_code" .= codeText code, "exit_code" .= (1 :: Int), "stdout" .= ("" :: Text), "stderr" .= message]

render :: Bool -> Result -> IO ()
render json result
  | json || isReport result = LazyBytes.hPutStr stdout (encode (resultValue result) <> "\n")
  | otherwise = do
      let (output, errors) = case result of
            Executed _ _ out err -> (out, err)
            Failed (ToolError _ message) -> ("", message <> "\n")
            Report {} -> ("", "")
      Bytes.hPut stdout (Text.encodeUtf8 output)
      Bytes.hPut stderr (Text.encodeUtf8 errors)
  where
    isReport Report {} = True
    isReport _ = False
