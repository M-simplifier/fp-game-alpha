{-# OPTIONS_GHC -Wno-orphans #-}
module Colony.ContentCodec(contentIdentity, RecipeCatalogs, knownRecipeCatalogs, knownRecipeCatalogsForContent, knownV1ContentId, knownV2ContentId) where
import Colony.Content
import Colony.KnownCatalog(knownCatalogV1,knownCatalogV2)
import Colony.Ruleset
import Colony.Units
import Colony.Codec.Value
import Colony.Codec.SHA256(sha256)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M

instance ValueCodec Resource
instance ValueCodec ResourceDef
instance ValueCodec Recipe
instance ValueCodec Building
instance ValueCodec NaturalSource
instance ValueCodec Tech
instance ValueCodec Campaign
instance ValueCodec Content

-- Shared by recipe-start snapshots and checkpoint headers. This is a digest of
-- the same canonical validated content bytes, not a filename or mutable label.
contentIdentity :: Content -> Either String BS.ByteString
contentIdentity content
  | content==knownCatalogV1=Right knownV1ContentId
  | content==knownCatalogV2=Right knownV2ContentId
  | otherwise=do
      validateContent content
      bytes<-either(Left . show)Right(encodeValue content)
      pure(sha256 bytes)

-- This executable supports exactly the two declared catalogs. Fingerprints are
-- generated from content-v1 and its specified two-field cook migration; they
-- are an allowlist, not values supplied by an incoming checkpoint.
knownV1ContentId, knownV2ContentId :: BS.ByteString
knownV1ContentId=BS.pack [185,227,39,118,242,201,156,56,137,160,6,151,51,21,82,177,142,60,75,223,92,23,156,194,201,0,126,154,47,14,172,220]
knownV2ContentId=BS.pack [184,241,38,115,108,1,46,156,225,236,246,164,215,144,248,78,119,98,246,169,52,111,245,141,222,84,173,221,109,132,88,171]

type RecipeCatalogs = M.Map BS.ByteString (M.Map String Recipe)

knownRecipeCatalogs :: String -> Content -> Either String RecipeCatalogs
knownRecipeCatalogs ruleset content=do
  digest<-contentIdentity content
  (catalog,_)<-rulesetProfile ruleset
  let expected=case catalog of CatalogV1->knownV1ContentId;CatalogV2->knownV2ContentId
  if digest/=expected then Left "Content is not a known catalog for this ruleset" else catalogsForDigest digest content

knownRecipeCatalogsForContent :: Content -> Either String RecipeCatalogs
knownRecipeCatalogsForContent content=do
  digest<-contentIdentity content
  catalogsForDigest digest content

catalogsForDigest :: BS.ByteString -> Content -> Either String RecipeCatalogs
catalogsForDigest digest content
  | digest==knownV1ContentId=Right(M.singleton digest(contentRecipes content))
  | digest==knownV2ContentId=do
      cook<-lookupRecipe content "cook"
      let oldCook=cook {recipeInputs=M.insert Fuel 1000(recipeInputs cook),recipeOutputs=M.insert Ration 18000(recipeOutputs cook)}
          previous=content {contentRecipes=M.insert "cook" oldCook(contentRecipes content)}
      oldDigest<-contentIdentity previous
      if oldDigest/=knownV1ContentId then Left "Unrecognized predecessor catalog" else
        Right(M.fromList[(digest,contentRecipes content),(oldDigest,contentRecipes previous)])
  | otherwise=Left "Unknown content catalog"
