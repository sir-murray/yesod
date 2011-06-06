{-# LANGUAGE QuasiQuotes, TypeFamilies, TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
module Yesod.Auth
    ( -- * Subsite
      Auth
    , AuthPlugin (..)
    , AuthRoute (..)
    , getAuth
    , YesodAuth (..)
      -- * Plugin interface
    , Creds (..)
    , setCreds
      -- * User functions
    , maybeAuthId
    , maybeAuth
    , requireAuthId
    , requireAuth
    ) where

#include "qq.h"

import Control.Monad                 (when)  
import Control.Monad.Trans.Class     (lift)

import Data.Aeson
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map as Map

import Language.Haskell.TH.Syntax hiding (lift)

import qualified Network.Wai as W
import Text.Hamlet (hamlet)

import Yesod.Core
import Yesod.Persist
import Yesod.Json
import Yesod.Auth.Message (AuthMessage, defaultMessage)
import qualified Yesod.Auth.Message as Msg
import Yesod.Form (FormMessage)

data Auth = Auth

type Method = Text
type Piece = Text

data AuthPlugin m = AuthPlugin
    { apName :: Text
    , apDispatch :: Method -> [Piece] -> GHandler Auth m ()
    , apLogin :: forall s. (Route Auth -> Route m) -> GWidget s m ()
    }

getAuth :: a -> Auth
getAuth = const Auth

-- | User credentials
data Creds m = Creds
    { credsPlugin :: Text -- ^ How the user was authenticated
    , credsIdent :: Text -- ^ Identifier. Exact meaning depends on plugin.
    , credsExtra :: [(Text, Text)]
    }

class (Yesod m, SinglePiece (AuthId m), RenderMessage m FormMessage) => YesodAuth m where
    type AuthId m

    -- | Default destination on successful login, if no other
    -- destination exists.
    loginDest :: m -> Route m

    -- | Default destination on successful logout, if no other
    -- destination exists.
    logoutDest :: m -> Route m

    getAuthId :: Creds m -> GHandler s m (Maybe (AuthId m))

    authPlugins :: [AuthPlugin m]

    -- | What to show on the login page.
    loginHandler :: GHandler Auth m RepHtml
    loginHandler = defaultLayout $ do
        setTitleI Msg.LoginTitle
        tm <- lift getRouteToMaster
        mapM_ (flip apLogin tm) authPlugins

    renderAuthMessage :: m
                      -> [Text] -- ^ languages
                      -> AuthMessage -> Text
    renderAuthMessage _ _ = defaultMessage

mkYesodSub "Auth"
    [ ClassP ''YesodAuth [VarT $ mkName "master"]
    ]
#define STRINGS *Texts
    [QQ(parseRoutes)|
/check                 CheckR      GET
/login                 LoginR      GET
/logout                LogoutR     GET POST
/page/#Text/STRINGS PluginR
|]

credsKey :: Text
credsKey = "_ID"

-- | FIXME: won't show up till redirect
setCreds :: YesodAuth m => Bool -> Creds m -> GHandler s m ()
setCreds doRedirects creds = do
    y    <- getYesod
    maid <- getAuthId creds
    case maid of
        Nothing ->
          when doRedirects $ do
            case authRoute y of
              Nothing -> do rh <- defaultLayout [QQ(hamlet)| <h1>Invalid login |]
                            sendResponse rh
              Just ar -> do setMessageI Msg.InvalidLogin
                            redirect RedirectTemporary ar
        Just aid -> do
            setSession credsKey $ toSinglePiece aid
            when doRedirects $ do
              setMessageI Msg.NowLoggedIn
              redirectUltDest RedirectTemporary $ loginDest y

getCheckR :: YesodAuth m => GHandler Auth m RepHtmlJson
getCheckR = do
    creds <- maybeAuthId
    defaultLayoutJson (do
        setTitle "Authentication Status"
        addHtml $ html creds) (json' creds)
  where
    html creds =
        [QQ(hamlet)|
<h1>Authentication Status
$maybe _ <- creds
    <p>Logged in.
$nothing
    <p>Not logged in.
|]
    json' creds =
        Object $ Map.fromList
            [ (T.pack "logged_in", Bool $ maybe False (const True) creds)
            ]

getLoginR :: YesodAuth m => GHandler Auth m RepHtml
getLoginR = loginHandler

getLogoutR :: YesodAuth m => GHandler Auth m ()
getLogoutR = postLogoutR -- FIXME redirect to post

postLogoutR :: YesodAuth m => GHandler Auth m ()
postLogoutR = do
    y <- getYesod
    deleteSession credsKey
    redirectUltDest RedirectTemporary $ logoutDest y

handlePluginR :: YesodAuth m => Text -> [Text] -> GHandler Auth m ()
handlePluginR plugin pieces = do
    env <- waiRequest
    let method = decodeUtf8With lenientDecode $ W.requestMethod env
    case filter (\x -> apName x == plugin) authPlugins of
        [] -> notFound
        ap:_ -> apDispatch ap method pieces

-- | Retrieves user credentials, if user is authenticated.
maybeAuthId :: YesodAuth m => GHandler s m (Maybe (AuthId m))
maybeAuthId = do
    ms <- lookupSession credsKey
    case ms of
        Nothing -> return Nothing
        Just s -> return $ fromSinglePiece s

maybeAuth :: ( YesodAuth m
             , Key val ~ AuthId m
             , PersistBackend (YesodDB m (GGHandler s m IO))
             , PersistEntity val
             , YesodPersist m
             ) => GHandler s m (Maybe (Key val, val))
maybeAuth = do
    maid <- maybeAuthId
    case maid of
        Nothing -> return Nothing
        Just aid -> do
            ma <- runDB $ get aid
            case ma of
                Nothing -> return Nothing
                Just a -> return $ Just (aid, a)

requireAuthId :: YesodAuth m => GHandler s m (AuthId m)
requireAuthId = maybeAuthId >>= maybe redirectLogin return

requireAuth :: ( YesodAuth m
               , Key val ~ AuthId m
               , PersistBackend (YesodDB m (GGHandler s m IO))
               , PersistEntity val
               , YesodPersist m
               ) => GHandler s m (Key val, val)
requireAuth = maybeAuth >>= maybe redirectLogin return

redirectLogin :: Yesod m => GHandler s m a
redirectLogin = do
    y <- getYesod
    setUltDest'
    case authRoute y of
        Just z -> redirect RedirectTemporary z
        Nothing -> permissionDenied "Please configure authRoute"

instance YesodAuth m => RenderMessage m AuthMessage where
    renderMessage = renderAuthMessage
