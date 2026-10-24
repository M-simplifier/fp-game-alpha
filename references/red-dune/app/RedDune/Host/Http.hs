{-# LANGUAGE OverloadedStrings #-}

-- The bounded HTTP wire mechanism does not admit commands or advance the game.
module RedDune.Host.Http (HttpRequest (..), readHttp, writeResponse, jsonBytes, failure) where

import Colony.JSON qualified as J
import Colony.Presentation (encodeJSON, obj, str)
import Control.Monad (unless, when)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as C
import Data.Char (isAlphaNum, toLower)
import Data.Map.Strict qualified as M
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Network.Socket (Socket)
import Network.Socket.ByteString qualified as N
import Text.Read (readMaybe)

data HttpRequest = HttpRequest !String !String !(M.Map String String) !B.ByteString

writeResponse :: Socket -> Int -> String -> B.ByteString -> IO ()
writeResponse conn status mime payload =
  N.sendAll conn (C.pack ("HTTP/1.1 " ++ show status ++ " " ++ reason status ++ "\r\nContent-Type: " ++ mime ++ "\r\nContent-Length: " ++ show (B.length payload) ++ "\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n") <> payload)
  where
    reason 200 = "OK"; reason 400 = "Bad Request"; reason 403 = "Forbidden"; reason 404 = "Not Found"; reason 408 = "Request Timeout"; reason _ = "Service Unavailable"

jsonBytes :: J.JSON -> B.ByteString
jsonBytes = T.encodeUtf8 . T.pack . encodeJSON

readHttp :: Socket -> IO (Either String HttpRequest)
readHttp conn = headers B.empty
  where
    headers bytes = case C.breakSubstring "\r\n\r\n" bytes of
      (_, rest)
        | B.null rest ->
            if B.length bytes > 8192
              then pure (Left "Headers exceed 8 KiB")
              else do chunk <- N.recv conn 4096; if B.null chunk then pure (Left "Incomplete request") else headers (bytes <> chunk)
      (headBytes, rest)
        | B.length headBytes + 4 > 8192 -> pure (Left "Headers exceed 8 KiB")
        | otherwise -> case parseHead headBytes of
            Left err -> pure (Left err)
            Right (method, path, fields, len) -> do
              payload <- body len (B.drop 4 rest)
              pure (HttpRequest method path fields <$> payload)
    body len bytes
      | B.length bytes > len = pure (Left "Trailing/pipelined request bytes are unsupported")
      | B.length bytes == len = pure (Right bytes)
      | otherwise = do chunk <- N.recv conn (min 4096 (len - B.length bytes)); if B.null chunk then pure (Left "Incomplete body") else body len (bytes <> chunk)

parseHead :: B.ByteString -> Either String (String, String, M.Map String String, Int)
parseHead bytes = case map (filter (/= '\r') . C.unpack) (C.lines bytes) of
  first : rows -> do
    (method, path) <- case words first of [m, p, "HTTP/1.1"] | m `elem` ["GET", "POST"] -> Right (m, p); _ -> Left "Only GET/POST HTTP/1.1 are supported"
    unless (length rows <= 40 && all (\c -> fromEnum c >= 32 && fromEnum c < 127) (concat rows)) (Left "Invalid headers")
    pairs <- mapM header rows
    let fields = M.fromList pairs
    unless (M.size fields == length pairs) (Left "Duplicate headers are unsupported")
    when (M.member "transfer-encoding" fields || M.member "expect" fields) (Left "Chunking/Expect are unsupported")
    len <- case M.lookup "content-length" fields of
      Nothing | method == "GET" -> Right 0
      Just raw | not (null raw) && length raw <= 5 && all (`elem` ['0' .. '9']) raw -> maybe (Left "Invalid length") Right (readMaybe raw :: Maybe Int)
      _ -> Left "Content-Length required"
    unless (len <= 65536 && (method /= "GET" || len == 0)) (Left "Body outside bounds")
    pure (method, path, fields, len)
  _ -> Left "Empty request"
  where
    header line = case break (== ':') line of
      (key, ':' : value) | not (null key) && all (\c -> isAlphaNum c || c == '-') key -> Right (map toLower key, dropWhile (== ' ') value)
      _ -> Left "Malformed header"

failure :: Int -> String -> (Int, String, B.ByteString)
failure status message = (status, "application/json; charset=utf-8", jsonBytes (obj [("error", str message)]))
