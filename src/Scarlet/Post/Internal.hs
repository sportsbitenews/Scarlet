{-# LANGUAGE OverloadedLists,
             FlexibleContexts,
             ViewPatterns       #-}

module Scarlet.Post.Internal
where

import Control.Arrow ((&&&))
import Control.Monad (filterM, foldM, forM, join, liftM)
import Control.Monad.Logger (runStderrLoggingT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Char (isAlphaNum, toLower)
import Data.List (foldl', intercalate)
import qualified Data.Map as DM
import Data.Maybe (catMaybes, fromMaybe, maybe)
import Data.Time.Clock
import Data.Time.Format
import Database.Persist.Sqlite
import Network.HTTP (HStream, Request(..), Response(..), headRequest, simpleHTTP)
import Network.URI (isAbsoluteURI)
import qualified Network.Stream as NS
import qualified Scarlet.Entry as SE
import System.Environment (getArgs, getEnv)
import Text.Parsec
import Text.Pandoc
import Text.Pandoc.Error (handleError)
import Text.Printf

(<$$>) :: Functor f => f a -> (a -> b) -> f b     -- <$$> because it matches <**>
a <$$> f = f <$> a
infixl 4 <$$>

class Entryoid e where
  toPandoc    :: e -> Pandoc
  directives  :: e -> DM.Map String String
  entryUri    :: e -> String

data EntryError = SqliteError String
                | EntryParseError   Text.Parsec.ParseError
                | AssetNetworkError NS.ConnError
                | AssetError        String
                deriving (Show, Eq)

type EntryResult a = Either EntryError a

instance Entryoid Pandoc where
  toPandoc = id
  directives _ = []
  entryUri _ = ""

instance Entryoid SE.Entry where
  toPandoc = handleError . readMarkdown def . SE.entryContent
  directives = read . SE.entryDirectives
  entryUri = SE.entryUri

directive :: ParsecT String () IO (String, String)
directive = do
    string "<!--"                               -- the comment starts
    key <- quotedOrNotUntil (string ": ")       -- "key": or key:
    value <- quotedOrNotUntil (string "-->")    -- "value" or value
    return (key, value)
  where
    quotedUntil s = do
      openingQuote <- string "\"" <|> string "'"
      middleStuff <- manyTill anyChar (string openingQuote)
      s
      return middleStuff
    quotedOrNotUntil s = quotedUntil s <|> manyTill anyChar s

scanForAssets :: Entryoid e => e -- takes an entryoid
              -> [String]        -- returns a list of asset URIs as strings
scanForAssets (toPandoc -> Pandoc _ blocks) = scanBlockForAssets =<< blocks
  where
    scanBlockForAssets :: Block -> [String]
    scanBlockForAssets (Plain inlines)  = inlines >>= getAssets
    scanBlockForAssets (Para inlines)   = inlines >>= getAssets
    scanBlockForAssets (Div _ divBlocks)  = divBlocks >>= scanBlockForAssets
    scanBlockForAssets _                  = []
    getAssets :: Inline -> [String]
    getAssets (Image _ (uri, _))          = [uri]
    getAssets (Link _ (uri, _))           = [uri]
    getAssets _                           = []

scanForRelativeURIs :: Entryoid e => e   -- takes an entryoid
                    -> [String]          -- returns a list of relative URIs
scanForRelativeURIs = filter (not . isAbsoluteURI) . scanForAssets

scanForAbsentRelativeUris :: Entryoid e => e         -- takes an entryoid
                          -> IO [EntryResult String] -- returns a (side-effecty) list of relative URIs
scanForAbsentRelativeUris = scanForAbsentRelativeUrisWithHTTP (simpleHTTP . headRequest)

scanForAbsentRelativeUrisWithHTTP :: Entryoid entryoid
                                  => (String -> IO (NS.Result (Response String))) -- an HTTP handler
                                  -> entryoid                       -- the document to process
                                  -> IO [EntryResult String]        -- the list of absent relative URIs
scanForAbsentRelativeUrisWithHTTP httpHandler doc = let
    relativeUris :: [String]
    relativeUris = scanForRelativeURIs doc
    findAbsent :: String -> IO (Maybe (EntryResult String))
    findAbsent uri = do
        resp <- httpHandler qualifiedUri
        return $ case resp of
          Right (Response { rspCode = (2, 0, _) }) -> Nothing
          Right (Response { rspCode = (3, 0, _) }) -> Nothing
          Right (Response { rspCode = (4, 0, _) }) -> Just (Right uri)
          Right (Response { })                     -> Nothing
          Left  connError                          -> Just (Left (AssetNetworkError connError))
      where
        qualifiedUri :: String
        qualifiedUri = getQualifiedUri doc uri
  in
    catMaybes <$> mapM findAbsent relativeUris

getQualifiedUri :: Entryoid e => e -> String -> String
getQualifiedUri doc uri = fromMaybe uri $ do
  staticHost <- DM.lookup "static_host" $ directives doc
  return $ printf "http://%s/%s/%s" staticHost (entryUri doc) uri

handleAbsentUris :: Entryoid entryoid
                 => (String -> IO (NS.Result (Response String)))
                 -> (String -> String -> IO (EntryResult a))
                 -> entryoid
                 -> IO [EntryResult a]
handleAbsentUris httpGetHandler httpPutHandler doc = let
    httpPutHandlerWithError e = join <$> mapM (uncurry httpPutHandler) e
    makeHttpPutHandlerArg = fmap $ id &&& getQualifiedUri doc
  in do
    absentUris <- scanForAbsentRelativeUrisWithHTTP httpGetHandler doc
    mapM httpPutHandlerWithError (makeHttpPutHandlerArg <$> absentUris)

entryParser :: ParsecT String () IO SE.Entry
entryParser = do
    directives <- DM.fromList <$> many directiveLine
    content <- many anyChar
    ctime <- liftIO $ defaultedCtime (DM.lookup "date" directives)
    byline <- liftIO $ defaultedByline (DM.lookup "by" directives)
    return $ SE.Entry ctime
                      (defaultedUri directives)
                      (directives DM.! "title")
                      content
                      byline
                      (directives DM.! "lang")
                      (show $ otherDirectivesFrom directives)
  where
    directiveLine = do
      d <- directive
      newline
      return d
    defaultedCtime :: Maybe String -> IO UTCTime
    defaultedCtime mCtimeString = maybe getCurrentTime return $
      mCtimeString >>= parseTimeM True defaultTimeLocale "%Y-%m-%d %H:%M:%S %Z"
    defaultedUri   :: DM.Map String String -> String
    defaultedUri directives = let
        title :: String
        title = directives DM.! "title"
        mUri  :: Maybe String
        mUri  = DM.lookup "uri" directives
        makeUriFromTitle :: String -> String
        makeUriFromTitle = intercalate "-" . map (filter isAlphaNum) . words . map toLower
      in fromMaybe (makeUriFromTitle title) mUri
    defaultedByline :: Maybe String -> IO String
    defaultedByline = maybe (getEnv "USER") return
    consumedDirectives :: [String]
    consumedDirectives = ["by", "date", "lang", "title", "uri"]
    otherDirectivesFrom :: DM.Map String String -> DM.Map String String
    otherDirectivesFrom = flip (foldl' (flip DM.delete)) consumedDirectives

parseEntry :: String -> IO (EntryResult SE.Entry)
parseEntry = let
    handleParsecError :: Either ParseError SE.Entry -> EntryResult SE.Entry
    handleParsecError (Left parsecError)  = Left (EntryParseError parsecError)
    handleParsecError (Right entry)       = Right entry
  in fmap handleParsecError . runParserT entryParser () ""
