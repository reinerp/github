{-# LANGUAGE OverloadedStrings, StandaloneDeriving #-}
module Github.Private where

import Github.Data
import Data.Aeson
import Data.Attoparsec.ByteString.Lazy
import Control.Applicative
import Data.List
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Network.HTTP.Types as Types
import Network.HTTP.Conduit
import Text.URI
import qualified Control.Exception as E
import Data.Maybe (fromMaybe)

githubGet :: (FromJSON b, Show b) => [String] -> IO (Either Error b)
githubGet paths =
  githubAPI (BS.pack "GET")
            (buildUrl paths)
            (Nothing :: Maybe Value)

githubGetWithQueryString :: (FromJSON b, Show b) => [String] -> String -> IO (Either Error b)
githubGetWithQueryString paths queryString =
  githubAPI (BS.pack "GET")
            (buildUrl paths ++ "?" ++ queryString)
            (Nothing :: Maybe Value)

buildUrl :: [String] -> String
buildUrl paths = "https://api.github.com/" ++ intercalate "/" paths

githubAPI :: (ToJSON a, Show a, FromJSON b, Show b) => BS.ByteString -> String -> Maybe a -> IO (Either Error b)
githubAPI method url body = do
  result <- doHttps method url (Just encodedBody)
  return $ either (Left . HTTPConnectionError)
                  (parseJson . responseBody)
                  result
  where encodedBody = RequestBodyLBS $ encode $ toJSON body

doHttps :: BS.ByteString -> String -> Maybe (RequestBody IO) -> IO (Either E.SomeException (Response LBS.ByteString))
doHttps method url body = do
  let (Just uri) = parseURI url
      (Just host) = uriRegName uri
      requestBody = fromMaybe (RequestBodyBS $ BS.pack "") body
      queryString = BS.pack $ fromMaybe "" $ uriQuery uri
      request = def { method = method
                    , secure = True
                    , host = BS.pack host
                    , port = 443
                    , path = BS.pack $ uriPath uri
                    , requestBody = requestBody
                    , queryString = queryString
                    }

  (getResponse request >>= return . Right) `E.catches` [
      -- Re-throw AsyncException, otherwise execution will not terminate on
      -- SIGINT (ctrl-c).  All AsyncExceptions are re-thrown (not just
      -- UserInterrupt) because all of them indicate severe conditions and
      -- should not occur during normal operation.
      E.Handler (\e -> E.throw (e :: E.AsyncException)),

      E.Handler (\e -> (return . Left) (e :: E.SomeException))
      ]
  where
    getResponse request = withManager $ \manager -> httpLbs request manager

parseJson :: (FromJSON b, Show b) => LBS.ByteString -> Either Error b
parseJson jsonString =
  let parsed = parse (fromJSON <$> json) jsonString in
  case parsed of
       Data.Attoparsec.ByteString.Lazy.Done _ jsonResult -> do
         case jsonResult of
              (Success s) -> Right s
              (Error e) -> Left $ JsonError $ e ++ " on the JSON: " ++ LBS.unpack jsonString
       (Fail _ _ e) -> Left $ ParseError e
