-- Deliberately small strict JSON reader for the versioned content schema. All
-- authoritative numbers must be integral JSON literals (no float conversion).
module Colony.JSON
  ( JSON (..),
    parseJSON,
    object,
    array,
    string,
    integer,
    boolean,
    field,
    fieldsExactly,
  )
where

import Control.Monad (when)
import Data.Char (chr, digitToInt, ord)
import Data.List (foldl', group, sort)
import Data.Map.Strict qualified as M
import Text.Parsec hiding (string)
import Text.Parsec qualified as P
import Text.Parsec.String (Parser)

data JSON
  = JObject (M.Map String JSON)
  | JArray [JSON]
  | JString String
  | JInteger Integer
  | JBool Bool
  | JNull
  deriving (Eq, Show)

parseJSON :: String -> Either String JSON
parseJSON s = either (Left . show) Right (parse (ws *> value 0 <* eof) "content JSON" s)

ws :: Parser ()
ws = skipMany (oneOf " \t\r\n")

lexeme :: Parser a -> Parser a
lexeme p = p <* ws

symbol :: Char -> Parser Char
symbol = lexeme . char

value :: Integer -> Parser JSON
value depth = do
  when (depth > 64) (fail "JSON nesting limit exceeded")
  choice
    [ JObject <$> obj (depth + 1),
      JArray <$> arr (depth + 1),
      JString <$> lexeme jsonString,
      JInteger <$> lexeme jsonInteger,
      JBool True <$ lexeme (text "true"),
      JBool False <$ lexeme (text "false"),
      JNull <$ lexeme (text "null")
    ]
  where
    text = P.string

obj :: Integer -> Parser (M.Map String JSON)
obj depth = do
  pairs <- between (symbol '{') (symbol '}') (pair `sepBy` symbol ',')
  let keys = map fst pairs
  when (any ((> 1) . length) (group (sort keys))) (fail "Duplicate JSON object key")
  pure (M.fromList pairs)
  where
    pair = (,) <$> lexeme jsonString <* symbol ':' <*> value depth

arr :: Integer -> Parser [JSON]
arr depth = between (symbol '[') (symbol ']') (value depth `sepBy` symbol ',')

jsonInteger :: Parser Integer
jsonInteger = do
  sign <- option id (negate <$ char '-')
  digits <- ((: []) <$> char '0') <|> ((:) <$> oneOf "123456789" <*> many digit)
  when (length digits > 32) (fail "Content integer literal exceeds 32 digits")
  notFollowedBy (oneOf ".eE" <|> digit)
  pure (sign (foldl' (\n d -> 10 * n + toInteger (digitToInt d)) 0 digits))

jsonString :: Parser String
jsonString = char '"' *> many stringChar <* char '"'
  where
    stringChar = satisfy (\c -> ord c >= 32 && c /= '"' && c /= '\\' && not (surrogate (ord c))) <|> escaped
    escaped =
      char '\\'
        *> choice
          [ '"' <$ char '"',
            '\\' <$ char '\\',
            '/' <$ char '/',
            '\b' <$ char 'b',
            '\f' <$ char 'f',
            '\n' <$ char 'n',
            '\r' <$ char 'r',
            '\t' <$ char 't',
            char 'u' *> unicode
          ]
    unicode = do
      hi <- hex4
      if hi >= 0xd800 && hi <= 0xdbff
        then do
          _ <- P.string "\\u"
          lo <- hex4
          when (lo < 0xdc00 || lo > 0xdfff) (fail "Invalid low surrogate")
          pure (chr (0x10000 + (hi - 0xd800) * 0x400 + lo - 0xdc00))
        else if surrogate hi then fail "Unpaired low surrogate" else pure (chr hi)
    hex4 = foldl (\n d -> n * 16 + digitToInt d) 0 <$> count 4 hexDigit
    surrogate n = n >= 0xd800 && n <= 0xdfff

object :: JSON -> Either String (M.Map String JSON)
object (JObject x) = Right x
object _ = Left "Expected JSON object"

array :: JSON -> Either String [JSON]
array (JArray x) = Right x
array _ = Left "Expected JSON array"

string :: JSON -> Either String String
string (JString x) = Right x
string _ = Left "Expected JSON string"

integer :: JSON -> Either String Integer
integer (JInteger x) = Right x
integer _ = Left "Expected integer JSON number"

boolean :: JSON -> Either String Bool
boolean (JBool x) = Right x
boolean _ = Left "Expected JSON boolean"

field :: String -> M.Map String JSON -> Either String JSON
field name objValue = maybe (Left ("Missing field: " ++ name)) Right (M.lookup name objValue)

fieldsExactly :: [String] -> M.Map String JSON -> Either String ()
fieldsExactly expected objValue
  | sort expected == M.keys objValue = Right ()
  | otherwise = Left ("Unexpected/missing fields; expected " ++ show (sort expected) ++ "; found " ++ show (M.keys objValue))
