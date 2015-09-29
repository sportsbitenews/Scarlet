{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}

module Main where

import Control.Monad.Catch (MonadThrow)
import Control.Monad.Logger (runStderrLoggingT)
import Control.Monad.Trans.Resource (runResourceT)
import Database.Persist.Sqlite
import Data.Text (Text)
import Text.Pandoc (def, readMarkdown, writeHtmlString)
import Text.Pandoc.Error (handleError)
import Yesod
import Yesod.Static
import qualified Data.Text as T

import Scarlet.Entry

data Scarlet = Scarlet { getConnPool :: ConnectionPool, getStatic :: Static }

instance Yesod Scarlet
instance YesodPersist Scarlet where
  type YesodPersistBackend Scarlet = SqlBackend
  runDB action = do
    Scarlet pool _ <- getYesod
    runSqlPool action pool

type ScarletHandler = HandlerT Scarlet IO

staticFiles "static"

mkYesod "Scarlet" [parseRoutes|
/                  AllR        GET
/just/#Integer     JustR       GET
/about             AboutR      GET
/static StaticR Static getStatic
!/#String          SingleR     GET
|]


blogTitle :: String
blogTitle = "Scarlet"

blogAuthor :: String
blogAuthor = "joshu"

formatEntry :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
            => Entity Entry
            -> WidgetT Scarlet m ()
formatEntry (Entity _ entry) = let
  htmlContent = handleError (writeHtmlString def <$> readMarkdown def (entryContent entry))
    in [whamlet|
<div class=post>
 <h1 title=#{show $ entryCtime entry}>
  <a href=@{SingleR (entryUri entry)}>
   #{entryTitle entry}
 #{preEscapedToMarkup htmlContent}|]

formatEntries :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
              => [Entity Entry]
              -> WidgetT Scarlet m ()
formatEntries = mconcat . fmap formatEntry

template title body = [whamlet|
<html>
 <head>
  <link rel=stylesheet href=@{StaticR ship_css}>
  <title>#{title}
 <body>
  <div id=title>
   <h1>
    <a href=@{AllR}>#{blogTitle}
   <br>
   by #{blogAuthor}<br>
   (
    <a href=@{AboutR}>learn more
   )
  <div id=main>
   ^{body}
|]

getJustR :: Integer -> ScarletHandler Html
getJustR aNumber = defaultLayout [whamlet|<h1>This is #{aNumber}|]

getAboutR :: ScarletHandler Html
getAboutR = defaultLayout [whamlet|About me? Why?|]

getSingleR :: String -> ScarletHandler Html
getSingleR uri = do
  results <- runDB $ selectFirst [EntryUri ==. uri] []
  case results of
    Just (Entity e entry) -> let
      in defaultLayout $ template (blogTitle ++ " - " ++ entryTitle entry) (formatEntry (Entity e entry))
    Nothing -> defaultLayout $ template blogTitle [whamlet|<p>No such post found, sorry!|]

getAllR :: ScarletHandler Html
getAllR = do
    entries <- runDB $ selectList [] [Desc EntryCtime]
    defaultLayout $ template blogTitle (formatEntries entries)

getPageR :: Int -> ScarletHandler Html
getPageR offset = do
    entries <- runDB $ selectList [] [Desc EntryCtime,
                                      LimitTo paginationNumber,
                                      OffsetBy (paginationNumber * offset)]
    defaultLayout $ template blogTitle (formatEntries entries)
  where
    paginationNumber = 10

main :: IO ()
main = runStderrLoggingT $ withSqlitePool "scarlet.sqlite"
    openConnectionCount $ \pool -> liftIO $ do
      static@(Static settings) <- static "static"
      warp 3000 $ Scarlet pool static
  where
    openConnectionCount = 10
