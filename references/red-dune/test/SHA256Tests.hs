module SHA256Tests (sha256Tests) where

import Colony.Codec.SHA256 (sha256, sha256Hex)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (digitToInt)

assert :: String -> Bool -> IO ()
assert label good = unless good (ioError (userError ("SHA256 assertion failed: " ++ label)))

sha256Tests :: IO ()
sha256Tests = do
  forM_ knownVectors $ \(label,input,expected) -> check label input expected
  forM_ paddingVectors $ \(size,expected) -> do
    let input = BS.pack [fromIntegral i | i <- [0 .. size - 1]]
    check ("binary padding length " ++ show size) input expected
    -- Exercise strict ByteString slices with nonzero underlying offsets.
    let wrapped = BS.concat [BS.replicate 7 0xff,input,BS.replicate 11 0x80]
    check ("sliced binary padding length " ++ show size)
      (BS.take size (BS.drop 7 wrapped)) expected
  putStrLn "PASS SHA256: FIPS/NIST known answers, million-a, binary padding boundaries and offset slices"
  where
    check label input expected = do
      let digest = sha256 input
      assert (label ++ " digest length") (BS.length digest == 32)
      assert (label ++ " raw digest") (digest == decodeHex expected)
      assert (label ++ " lowercase hexadecimal") (sha256Hex input == expected)

decodeHex :: String -> BS.ByteString
decodeHex = BS.pack . go
  where
    go [] = []
    go (a:b:rest) = fromIntegral (16 * digitToInt a + digitToInt b) : go rest
    go [_] = error "invalid odd-length SHA256 test fixture"

-- Published FIPS/NIST examples, independently checked with Python hashlib.
knownVectors :: [(String,BS.ByteString,String)]
knownVectors =
  [ ("empty", BS.empty,
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  , ("abc", BSC.pack "abc",
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  , ("56-byte FIPS example", BSC.pack "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  , ("112-byte multiblock example", BSC.pack
      ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" ++
       "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
      "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
  , ("million a", BS.replicate 1000000 0x61,
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  ]

-- Python hashlib.sha256(bytes(i % 256 for i in range(n))).hexdigest().
-- These fixtures cover both sides of the 56-byte padding threshold, exact
-- block boundaries, multiple blocks, embedded zero bytes, and high-bit bytes.
paddingVectors :: [(Int,String)]
paddingVectors =
  [ (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  , (1, "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")
  , (2, "b413f47d13ee2fe6c845b2ee141af81de858df4ec549a58b7970bb96645bc8d2")
  , (3, "ae4b3280e56e2faf83f414a6e3dabe9d5fbe18976544c05fed121accb85b53fc")
  , (54, "675f28acc0b90a72d1c3a570fe83ac565555db358cf01826dc8eefb2bf7ca0f3")
  , (55, "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59")
  , (56, "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562")
  , (57, "2fe741af801cc238602ac0ec6a7b0c3a8a87c7fc7d7f02a3fe03d1c12eac4d8f")
  , (62, "c89da82cbcd76ddf220e4e9091019b9866ffda72bee30de1effe6c99701a2221")
  , (63, "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488")
  , (64, "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108")
  , (65, "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781")
  , (118, "d32ab00929cb935b79d44e74c5a745db460ff794dea3b79be40c1cc5cf5388ef")
  , (119, "da18797ed7c3a777f0847f429724a2d8cd5138e6ed2895c3fa1a6d39d18f7ec6")
  , (120, "f52b23db1fbb6ded89ef42a23ce0c8922c45f25c50b568a93bf1c075420bbb7c")
  , (121, "335a461692b30bba1d647cc71604e88e676c90e4c22455d0b8c83f4bd7c8ac9b")
  , (126, "5dda7cb7c2282a55676f8ad5c448092f4a9ebd65338b07ed224fcd7b6c73f5ef")
  , (127, "92ca0fa6651ee2f97b884b7246a562fa71250fedefe5ebf270d31c546bfea976")
  , (128, "471fb943aa23c511f6f72f8d1652d9c880cfa392ad80503120547703e56a2be5")
  , (129, "5099c6a56203f9687f7d33f4bfdf576d31dc91f6b695ecea38b2770c87631135")
  , (255, "3f8591112c6bbe5c963965954e293108b7208ed2af893e500d859368c654eabe")
  , (256, "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
  , (257, "54acfbfedc4d8da40f76f275e1a98f10af8ef1fb9fb39e5a67a00aabcbe6597c")
  , (1024, "785b0751fc2c53dc14a4ce3d800e69ef9ce1009eb327ccf458afe09c242c26c9")
  ]
