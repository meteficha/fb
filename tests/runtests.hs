{-# LANGUAGE OverloadedStrings, Rank2Types #-}

import Control.Applicative
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Class (lift)
import Data.Int (Int8, Int16, Int32)
import Data.Text (Text)
import Data.Time (parseTime)
import Data.Word (Word8, Word16, Word32, Word)
import System.Environment (getEnv)
import System.Exit (exitFailure)
import System.IO.Error (isDoesNotExistError)

import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import qualified Data.Conduit as C
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Time as TI
import qualified Control.Exception.Lifted as E
import qualified Facebook as FB
import qualified Network.HTTP.Conduit as H

import Test.HUnit ((@?=), assertFailure)
import Test.Hspec.Monadic
import Test.Hspec.QuickCheck
import Test.Hspec.HUnit ()
import qualified Test.QuickCheck as QC


-- | Grab the Facebook credentials from the environment.
getCredentials :: IO FB.Credentials
getCredentials = tryToGet `E.catch` showHelp
    where
      tryToGet = do
        [appName, appId, appSecret] <- mapM getEnv ["APP_NAME", "APP_ID", "APP_SECRET"]
        return $ FB.Credentials (B.pack appName) (B.pack appId) (B.pack appSecret)

      showHelp exc | not (isDoesNotExistError exc) = E.throw exc
      showHelp _ = do
        putStrLn $ unlines
          [ "In order to run the tests from the 'fb' package, you need"
          , "developer access to a Facebook app.  The tests are designed"
          , "so that your app isn't going to be hurt, but we may not"
          , "create a Facebook app for this purpose and then distribute"
          , "its secret keys in the open."
          , ""
          , "Please give your app's name, id and secret on the enviroment"
          , "variables APP_NAME, APP_ID and APP_SECRET, respectively.  "
          , "For example, before running the test you could run in the shell:"
          , ""
          , "  $ export APP_NAME=\"example\""
          , "  $ export APP_ID=\"458798571203498\""
          , "  $ export APP_SECRET=\"28a9d0fa4272a14a9287f423f90a48f2304\""
          , ""
          , "Of course, these values above aren't valid and you need to"
          , "replace them with your own."
          , ""
          , "(Exiting now with a failure code.)"]
        exitFailure


invalidCredentials :: FB.Credentials
invalidCredentials = FB.Credentials "this" "isn't" "valid"

invalidUserAccessToken :: FB.UserAccessToken
invalidUserAccessToken = FB.UserAccessToken "invalid" "user" farInTheFuture
    where
      Just farInTheFuture = parseTime (error "farInTheFuture") "%Y" "3000"
      -- It's actually important to use 'farInTheFuture' since we
      -- don't want any tests rejecting this invalid user access
      -- token before even giving it to Facebook.

invalidAppAccessToken :: FB.AppAccessToken
invalidAppAccessToken = FB.AppAccessToken "invalid"


main :: IO ()
main = H.withManager $ \manager -> liftIO $ do
  creds <- getCredentials
  hspecX $ do
    -- Run the tests twice, once in Facebook's production tier...
    facebookTests "Production tier: "
                  manager
                  (C.runResourceT . FB.runFacebookT creds manager)
                  (C.runResourceT . FB.runNoAuthFacebookT manager)
    -- ...and the other in Facebook's beta tier.
    facebookTests "Beta tier: "
                  manager
                  (C.runResourceT . FB.beta_runFacebookT creds manager)
                  (C.runResourceT . FB.beta_runNoAuthFacebookT manager)

    -- Tests that don't depend on which tier is chosen.
    libraryTests

facebookTests :: String
              -> H.Manager
              -> (forall a. FB.FacebookT FB.Auth   (C.ResourceT IO) a -> IO a)
              -> (forall a. FB.FacebookT FB.NoAuth (C.ResourceT IO) a -> IO a)
              -> Specs
facebookTests pretitle manager runAuth runNoAuth = do
  let describe' = describe . (pretitle ++)
  describe' "getAppAccessToken" $ do
    it "works and returns a valid app access token" $
      runAuth $ do
        token <- FB.getAppAccessToken
        FB.isValid token #?= True
    it "throws a FacebookException on invalid credentials" $
      C.runResourceT $
      FB.runFacebookT invalidCredentials manager $ do
        ret <- E.try $ FB.getAppAccessToken
        case ret  of
          Right token                      -> fail $ show token
          Left (_ :: FB.FacebookException) -> lift $ lift (return () :: IO ())

  describe' "isValid" $ do
    it "returns False on a clearly invalid user access token" $
      runNoAuth $ FB.isValid invalidUserAccessToken #?= False
    it "returns False on a clearly invalid app access token" $
      runNoAuth $ FB.isValid invalidAppAccessToken  #?= False

  describe' "getObject" $ do
    it "is able to fetch Facebook's own page" $
      runNoAuth $ do
        A.Object obj <- FB.getObject "/19292868552" [] Nothing
        let Just r = flip A.parseMaybe () $ const $
                     (,,) <$> obj A..:? "id"
                          <*> obj A..:? "website"
                          <*> obj A..:? "name"
            just x = Just (x :: Text)
        r &?= ( just "19292868552"
              , just "http://developers.facebook.com"
              , just "Facebook Platform" )

  describe' "getUser" $ do
    it "works for Zuckerberg" $ do
      runNoAuth $ do
        user <- FB.getUser "zuck" [] Nothing
        FB.userId user         &?= "4"
        FB.userName user       &?= Just "Mark Zuckerberg"
        FB.userFirstName user  &?= Just "Mark"
        FB.userMiddleName user &?= Nothing
        FB.userLastName user   &?= Just "Zuckerberg"
        FB.userGender user     &?= Just FB.Male

  describe' "fqlQuery" $ do
    it "is able to query Facebook's page name from its page id" $
      runNoAuth $ do
        A.Object obj <- FB.fqlQuery "SELECT name FROM page WHERE page_id = 20531316728" Nothing
        let mr = flip A.parseMaybe () $ const r
            r = do
                  dataArray <- obj A..: "data"
                  (head dataArray) A..: "name"
        case mr of
          Nothing -> liftIO $ assertFailure "Could not parse FQL query response."
          Just r' -> r' &?= ("Facebook" :: Text)

        
libraryTests :: Specs
libraryTests = do
  describe "SimpleType" $ do
    it "works for Bool" $ (map FB.encodeFbParam [True, False]) @?= ["1", "0"]

    let day       = TI.fromGregorian 2012 12 21
        time      = TI.TimeOfDay 11 37 22
        diffTime  = TI.secondsToDiffTime (11*3600 + 37*60)
        utcTime   = TI.UTCTime day diffTime
        localTime = TI.LocalTime day time
        zonedTime = TI.ZonedTime localTime (TI.minutesToTimeZone 30)
    it "works for Day"       $ FB.encodeFbParam day       @?= "2012-12-21"
    it "works for UTCTime"   $ FB.encodeFbParam utcTime   @?= "20121221T1137Z"
    it "works for ZonedTime" $ FB.encodeFbParam zonedTime @?= "20121221T1107Z"

    let propShowRead :: (Show a, Read a, Eq a, FB.SimpleType a) => a -> Bool
        propShowRead x = read (B.unpack $ FB.encodeFbParam x) == x
    prop "works for Float"  (propShowRead :: Float  -> Bool)
    prop "works for Double" (propShowRead :: Double -> Bool)
    prop "works for Int"    (propShowRead :: Int    -> Bool)
    prop "works for Int8"   (propShowRead :: Int8   -> Bool)
    prop "works for Int16"  (propShowRead :: Int16  -> Bool)
    prop "works for Int32"  (propShowRead :: Int32  -> Bool)
    prop "works for Word"   (propShowRead :: Word   -> Bool)
    prop "works for Word8"  (propShowRead :: Word8  -> Bool)
    prop "works for Word16" (propShowRead :: Word16 -> Bool)
    prop "works for Word32" (propShowRead :: Word32 -> Bool)

    let propShowReadL :: (Show a, Read a, Eq a, FB.SimpleType a) => [a] -> Bool
        propShowReadL x = read ('[' : B.unpack (FB.encodeFbParam x) ++ "]") == x
    prop "works for [Float]"  (propShowReadL :: [Float]  -> Bool)
    prop "works for [Double]" (propShowReadL :: [Double] -> Bool)
    prop "works for [Int]"    (propShowReadL :: [Int]    -> Bool)
    prop "works for [Int8]"   (propShowReadL :: [Int8]   -> Bool)
    prop "works for [Int16]"  (propShowReadL :: [Int16]  -> Bool)
    prop "works for [Int32]"  (propShowReadL :: [Int32]  -> Bool)
    prop "works for [Word]"   (propShowReadL :: [Word]   -> Bool)
    prop "works for [Word8]"  (propShowReadL :: [Word8]  -> Bool)
    prop "works for [Word16]" (propShowReadL :: [Word16] -> Bool)
    prop "works for [Word32]" (propShowReadL :: [Word32] -> Bool)

    prop "works for Text" (\t -> FB.encodeFbParam t == TE.encodeUtf8 t)

    prop "works for Id" $ \i ->
      let toId :: Int -> FB.Id
          toId = FB.Id . B.pack . show
          j = abs i
      in FB.encodeFbParam (toId j) == FB.encodeFbParam j


-- Wrappers for HUnit operators using MonadIO

(&?=) :: (Eq a, Show a, MonadIO m) => a -> a -> m ()
v &?= e = liftIO (v @?= e)

(#?=) :: (Eq a, Show a, MonadIO m) => m a -> a -> m ()
m #?= e = m >>= (&?= e)


-- | Sad, orphan instance.
instance QC.Arbitrary Text where
    arbitrary = T.pack <$> QC.arbitrary
    shrink    = map T.pack . QC.shrink . T.unpack
