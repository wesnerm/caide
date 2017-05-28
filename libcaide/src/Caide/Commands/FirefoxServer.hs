{-# LANGUAGE CPP, OverloadedStrings #-}
module Caide.Commands.FirefoxServer(
      runFirefoxServer
) where

import Control.Monad (mapM, mapM_)
import qualified Data.ByteString.Lazy as BS
import Data.HashMap.Lazy ((!))
import qualified Data.HashMap.Lazy as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import System.IO (hSetBuffering, stdout, BufferMode(NoBuffering))


import Data.Aeson (Value(Object, Array, String), eitherDecode')
import qualified Data.Aeson as Json
import Data.Binary (Binary(get, put), Get, Put, decode, encode)
import Data.Binary.Get (getWord32host, getLazyByteString, isEmpty)
import Data.Binary.Put (putWord32host, putLazyByteString)
import Filesystem.Path.CurrentOS (fromText)


import Caide.Commands.ParseProblem (saveProblem)
import Caide.Configuration (describeError)
import Caide.Registry (findHtmlParserForUrl)
import Caide.Types


processMessage :: Value -> IO Value
processMessage (Object kvMap) = do
    ret <- runInDirectory (fromText caideDir) $ case () of
        () | probType `elem` ["default", "stream"] -> processDefault url doc
           | probType == "dcj" -> processDcj probTitle (map getString $ V.toList sampleInputs)
        _ -> throw "Unexpected problem type"
    return $ case ret of
        Left err -> errorMessage . T.pack . describeError $ err
        _        -> successMessage

  where
    String probType = kvMap!"problemType"
    String probTitle = kvMap!"problemTitle"
    String caideDir = kvMap!"caideDir"
    String url = kvMap!"url"
    String doc = kvMap!"document"
    Array sampleInputs = kvMap!"sampleInputs"
    getString (String s) = s
    getString _ = error "Unexpected JSON input"

processMessage _ = error "Unexpected JSON input"


successMessage :: Value
successMessage = Object $ Map.empty

errorMessage :: Text -> Value
errorMessage err = Object $ Map.singleton "error" (String err)


processDefault :: URL -> Text -> CaideIO ()
processDefault url doc = do
    let Just htmlParser = findHtmlParserForUrl url
        parseResult = parseFromHtml htmlParser doc
    case parseResult of
        Left err -> throw . T.unlines $ ["Encountered a problem while parsing:", err]
        Right (problem, samples) -> saveProblem problem samples


processDcj :: Text -> [Text] -> CaideIO ()
processDcj probTitle sampleInputHeaders = saveProblem problem samples
  where
    problem = Problem
            { problemName = probTitle
            , problemId = probTitle
            , problemType = DCJ
            }
    samples = [TestCase input "" | input <- sampleInputHeaders]

-- In Firefox native messaging, a JSON message is preceded by its byte length in host order.
data Messages = Messages [Value]

putMessage :: Value -> Put
putMessage value = putWord32host (fromIntegral $ BS.length ser) >> putLazyByteString ser
  where ser = Json.encode value

getMessage :: Get Value
getMessage = do
    len <- getWord32host
    ser <- getLazyByteString $ fromIntegral len
    case eitherDecode' ser of
        Right value -> return value
        Left e      -> fail e

instance Binary Messages where
    put (Messages values) = mapM_ putMessage values

    get = Messages <$> getValues
      where
        getValues = do
            done <- isEmpty
            if done
                then return []
                else do
                    first <- getMessage
                    rest <- getValues
                    return (first:rest)

runFirefoxServer :: IO ()
runFirefoxServer = do
    hSetBuffering stdout NoBuffering
    input <- BS.getContents
    let Messages inputMessages = decode input
    outputMessages <- mapM processMessage inputMessages
    BS.putStr . encode $ Messages outputMessages

