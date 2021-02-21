{-# LANGUAGE OverloadedStrings #-}

module Caide.TestCases.Types (
      ComparisonResult (..)
    , isSuccessful

    , TestRunResult(..)
    , makeTestRunResult

    , TestReport
    , humanReadableReport
    , serializeTestReport
    , deserializeTestReport
    , readTestReport

    , TestState (..)
    , TestList
    , serializeTestList
    , deserializeTestList
    , readTests
    , writeTests
) where

import Prelude hiding (FilePath)
import Data.Char (isSpace)
import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Text.Parsec as Parsec

import Data.Time.Clock (DiffTime, diffTimeToPicoseconds, picosecondsToDiffTime)
import Filesystem.Path (FilePath)
import Filesystem (isFile, readTextFile, writeTextFile)
import Caide.Util (tshow)


data ComparisonResult = Success        -- ^ Test passed
                      | Ran            -- ^ Test ran but hasn't been evaluated
                      | EtalonUnknown  -- ^ Test ran but etalon is unknown
                      | Skipped        -- ^ Test was skipped
                      | Failed Text    -- ^ Test failed
                      | Error Text     -- ^ Error (e.g. exception in checker)
                      deriving (Show, Eq)

isSuccessful :: ComparisonResult -> Maybe Bool
isSuccessful (Failed _) = Just False
isSuccessful (Error _) = Just False
isSuccessful Success = Just True
isSuccessful _ = Nothing

humanReadable :: ComparisonResult -> Text
humanReadable Success = "OK"
humanReadable Ran = "ran"
humanReadable Skipped = "skipped"
humanReadable (Failed message) = "failed: " <> message
humanReadable EtalonUnknown = "unknown"
humanReadable (Error err) = err

machineReadable :: ComparisonResult -> Text
machineReadable (Failed message) = "failed " <> message
machineReadable (Error err) = "error " <> err
machineReadable res = humanReadable res


data TestRunResult = TestRunResult
    { testRunStatus :: ComparisonResult
    , testRunTime   :: Maybe DiffTime
    } deriving (Eq, Show)

type TestReport = [(Text, TestRunResult)]

makeTestRunResult :: ComparisonResult -> TestRunResult
makeTestRunResult cmp = TestRunResult cmp Nothing

serializeTestReport :: TestReport -> Text
serializeTestReport = T.unlines .
            map (\(testName, res) -> testName <> " " <> serializeTestRunResult res)

humanReadableReport :: TestReport -> Text
humanReadableReport = T.unlines .
            map (\(testName, res) -> testName <> ": " <> humanReadable (testRunStatus res))

picosecondsInMs :: Integer
picosecondsInMs = 10^(12::Int)

serializeTestRunResult :: TestRunResult -> Text
serializeTestRunResult (TestRunResult status time) = serializedTime <> machineReadable status
  where
    serializedTime = case time of
        Nothing -> ""
        Just t  -> ""
        -- Just t  -> "#time:" <> tshow (diffTimeToPicoseconds t `div` picosecondsInMs) <> "ms "


readComparisonResult :: T.Text -> Maybe T.Text -> ComparisonResult
readComparisonResult "OK" _ = Success
readComparisonResult "ran" _ = Ran
readComparisonResult "skipped" _ = Skipped
readComparisonResult "unknown" _ = EtalonUnknown
readComparisonResult "failed" err = Failed $ fromMaybe "" err
readComparisonResult "error" err = Error $ fromMaybe "" err
readComparisonResult _ _ = Error "Corrupted report file"

deserializeTestReport :: Text -> TestReport
deserializeTestReport text = map parseTest reportLines
  where
    reportLines = filter (not . T.null) $ map T.strip $ T.lines text

    parseTest :: Text -> (Text, TestRunResult)
    parseTest line = fromRight (error "Impossible happened") $
        Parsec.parse parser "" line

    parser = do
        testName <- token
        runResult <- Parsec.optionMaybe $ do
            skipSpace1
            status <- token
            errorMessage <- Parsec.optionMaybe $ do
                -- TODO: parse time
                skipSpace1
                msg <- T.pack <$> Parsec.many1 Parsec.anyToken
                Parsec.eof
                pure msg
            pure $ makeTestRunResult $ readComparisonResult status errorMessage

        return (testName, fromMaybe (makeTestRunResult $ Error "Corrupted report file") runResult)

    skipSpace1 = Parsec.skipMany1 Parsec.space
    token = T.pack <$> Parsec.many1 nonSpace
    nonSpace = Parsec.satisfy $ not.isSpace

readTestReport :: FilePath -> IO TestReport
readTestReport reportFile = do
    reportExists <- isFile reportFile
    if reportExists
        then deserializeTestReport <$> readTextFile reportFile
        else return []

data TestState = Run | Skip deriving (Read, Show)

type TestList = [(Text, TestState)]

serializeTestList :: TestList -> Text
serializeTestList = T.unlines . map (\(name, state) -> T.concat [name, " ", tshow state])

deserializeTestList :: Text -> TestList
deserializeTestList text = map toTest testLines
  where
    testLines = map T.words . T.lines $ text

    toTest [name, state] = (name, read $ T.unpack state)
    toTest _ = error "Corrupted testList file"

readTests :: FilePath -> IO TestList
readTests testListFile = do
    testListExists <- isFile testListFile
    if testListExists
    then deserializeTestList <$> readTextFile testListFile
    else return []

writeTests :: TestList -> FilePath -> IO ()
writeTests tests testListFile = writeTextFile testListFile $ serializeTestList tests

