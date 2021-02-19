{-# LANGUAGE OverloadedStrings #-}
module Caide.Parsers.HackerRank(
      hackerRankParser
) where

import Control.Applicative ((<|>))
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlphaNum, isSpace)
import qualified Data.HashMap.Strict as HashMap
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import qualified Data.Aeson as Aeson
import Data.Aeson (withObject, (.:))
import Network.HTTP.Types (urlDecode)
import Network.URI (parseURI, uriAuthority, uriRegName)
import Text.HTML.TagSoup (fromAttrib, maybeTagText, parseTags, partitions, sections,
    Tag(TagText))
import Text.HTML.TagSoup.Utils

import Caide.Types


hackerRankParser :: HtmlParser
hackerRankParser = HtmlParser
    { chelperId = "hackerrank"
    , htmlParserUrlMatches = isHackerRankUrl
    , parseFromHtml = doParse
    }

isHackerRankUrl :: URL -> Bool
isHackerRankUrl url = case parseURI (T.unpack url) >>= uriAuthority of
    Nothing   -> False
    Just auth -> uriRegName auth `elem` ["hackerrank.com", "www.hackerrank.com"]

data JsonProblem = JsonProblem
    { name :: T.Text
    , htmlBody :: T.Text
    }


instance Aeson.FromJSON JsonProblem where
    parseJSON = withObject "JsonProblem" $ \v -> do
        Aeson.Object community <- v .: "community"
        Aeson.Object challenges <- community .: "challenges"
        Aeson.Object challenge <- challenges .: "challenge"
        let values = HashMap.elems challenge
        case values of
            [singleton] -> do
                let Aeson.Object prob = singleton
                Aeson.Object detail <- prob .: "detail"
                JsonProblem <$> detail .: "name" <*> detail .: "body_html"
            [] -> fail "no problems found"
            _  -> fail "multiple problems found"

testsFromHtml :: [Tag T.Text] -> [TestCase]
testsFromHtml tags = testCases where
    samples = partitions (\tag -> tag ~~== "<div class=challenge_sample_input_body>" || tag ~~== "<div class=challenge_sample_output_body>") tags

    pres = map (drop 1 . takeWhile (~/= "</pre>") . dropWhile (~/= "<pre>") ) samples
    texts = map extractText pres
    t = drop (length texts `mod` 2) texts
    testCases = [TestCase (t!!i) (t!!(i+1)) | i <- [0, 2 .. length t-2]]

problemFromName :: Maybe T.Text -> Problem
problemFromName mbName = makeProblem probName probId probType where
    probId = maybe "hrUnknown" (T.filter isAlphaNum) mbName
    probName = fromMaybe "Unknown" mbName
    probType = Stream StdIn StdOut

testsFromInitialData :: [Tag T.Text] -> Maybe (Problem, [TestCase])
testsFromInitialData tags = do
    let initialDataScript = takeWhile (~/= "</script>") . drop 1 . dropWhile (~/= "<script id=initialData>") $ tags
        urlEncodedJson = extractText initialDataScript
        json = urlDecode False . T.encodeUtf8 $ urlEncodedJson
    case Aeson.eitherDecode' $ LBS.fromStrict json of
        Left _err -> Nothing
        Right jsonProblem -> Just (problemFromName $ Just $ name jsonProblem, testsFromHtml $ parseTags $ htmlBody jsonProblem)

doParse :: T.Text -> Either T.Text (Problem, [TestCase])
doParse cont = case (testsFromInitialData tags, testCases) of
    (Just v, _) -> Right v
    (_, []) -> Left "Couldn't find test cases"
    _ -> Right (problemFromName title, testCases)
  where
    tags = parseTags cont

    metaTitle = do
        meta <- find (~== "<meta property=og:title") tags
        return $ fromAttrib "content" meta

    pageTitle = do
        titleText <- listToMaybe $ drop 1 . dropWhile (~/= "<title>") $ tags
        maybeTagText titleText

    h2Title = do
        h2Text <- listToMaybe $ drop 1 . dropWhile (~~/== "<h2 class=hr_tour-challenge-name>") $ tags
        maybeTagText h2Text

    h1Title = let
        pageLabels = sections (~~== "<h1 class=page-label") tags
        possibleTitles = mapMaybe (listToMaybe . drop 1) pageLabels
        titles = mapMaybe maybeTagText possibleTitles
        nonEmptyTitles = filter (not . T.null) $ map T.strip titles
      in
        listToMaybe nonEmptyTitles

    rawTitle = h1Title <|> pageTitle <|> metaTitle <|> h2Title
    title = T.strip . T.takeWhile (/= '|') <$> rawTitle
    testCases = testsFromHtml tags

extractText :: [Tag T.Text] -> T.Text
extractText tags = T.unlines [t | TagText t <- tags, not (T.all isSpace t)]

