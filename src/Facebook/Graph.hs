{-# LANGUAGE DeriveDataTypeable, FlexibleContexts, OverloadedStrings #-}
module Facebook.Graph
    ( getObject
    , postObject
    , Id(..)
    ) where


import Control.Applicative
import Control.Monad.Trans.Control (MonadBaseControl)
-- import Control.Monad (mzero)
-- import Data.ByteString.Char8 (ByteString)
-- import Data.Text (Text)
import Data.Typeable (Typeable)
import Network.HTTP.Types (Ascii)

-- import qualified Control.Exception.Lifted as E
import qualified Data.Aeson as A
import qualified Data.Conduit as C
-- import qualified Data.Text as T
import qualified Network.HTTP.Conduit as H
import qualified Network.HTTP.Types as HT


import Facebook.Types
import Facebook.Monad
import Facebook.Base


-- | Make a raw @GET@ request to Facebook's Graph API.  Returns a
-- raw JSON 'A.Value'.
getObject :: (C.MonadResource m, MonadBaseControl IO m, A.FromJSON a) =>
             Ascii          -- ^ Path (should begin with a slash @\/@)
          -> [Argument]     -- ^ Arguments to be passed to Facebook
          -> Maybe (AccessToken anyKind) -- ^ Optional access token
          -> FacebookT anyAuth m a
getObject path query mtoken =
  runResourceInFb $
    asJson =<< fbhttp =<< fbreq path mtoken query


-- | Make a raw @POST@ request to Facebook's Graph API.  Returns
-- a raw JSON 'A.Value'.
postObject :: (C.MonadResource m, MonadBaseControl IO m, A.FromJSON a) =>
              Ascii               -- ^ Path (should begin with a slash @\/@)
           -> [Argument]          -- ^ Arguments to be passed to Facebook
           -> AccessToken anyKind -- ^ Access token
           -> FacebookT Auth m a
postObject path query token =
  runResourceInFb $ do
    req <- fbreq path (Just token) query
    asJson =<< fbhttp req { H.method = HT.methodPost }


-- | The identification code of an object.
newtype Id = Id { idCode :: Ascii }
    deriving (Eq, Ord, Show, Read, Typeable)

instance A.FromJSON Id where
    parseJSON (A.Object v) = Id <$> v A..: "id"
    parseJSON other        = Id <$> A.parseJSON other
