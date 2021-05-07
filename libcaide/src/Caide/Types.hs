{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings, ScopedTypeVariables #-}

module Caide.Types(
      Problem (..)
    , ProblemID
    , ProblemType (..)
    , InputSource (..)
    , OutputTarget (..)
    , TopcoderType (..)
    , TopcoderValue (..)
    , TopcoderProblemDescriptor (..)
    , makeProblem

    , Verbosity (..)
    , CaideIO
    , CaideM
    , runInDirectory

    , throw

    , Option (..)
    , ConfigFileHandle
    , Persistent
    , Temporary
    , readConf
    , createConf
    , flushConf
    , getTemporaryConf
    , getProp
    , setProp
    , caideRoot
    , caideVerbosity
    , caideSettings

    , ProgrammingLanguage (..)
    , TestCase (..)
    , Builder
    , BuilderResult(..)
    , Feature (..)
    , noOpFeature
) where

import Control.Exception.Base (displayException)
import Control.Monad (forM_, unless, when)
import Control.Monad.Except (ExceptT, MonadError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, reader)
import Control.Monad.RWS.Strict (RWST, runRWST)
import Control.Monad.State (MonadState, gets, modify')
import Data.Char (toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import qualified Data.ConfigFile as C
import System.IO.Error (tryIOError)

import qualified Filesystem as F
import qualified Filesystem.Path as F
import qualified Filesystem.Path.CurrentOS as F
import Filesystem.Path.CurrentOS ((</>))


import Filesystem.Util (readTextFile, writeTextFile)

import Caide.Settings (Settings, readSettings)
import Caide.Types.Option (Option(..))

data TestCase = TestCase
    { testCaseInput  :: !Text
    , testCaseOutput :: !Text
    } deriving (Show, Eq)

type ProblemID = Text

data Problem = Problem
    { problemName :: !Text      -- ^ Human readable identifier, used for displaying in GUI
    , problemId   :: !ProblemID -- ^ ID used for folder names, code generation etc.
    , problemFloatTolerance :: !Double -- ^ Comparing floating-point values up to this tolerance
    , problemType :: !ProblemType
    } deriving (Show)

data ProblemType = Topcoder !TopcoderProblemDescriptor | Stream !InputSource !OutputTarget
    deriving (Show)
data InputSource = StdIn | FileInput !F.FilePath | InputFilePattern !Text
    deriving (Show)
data OutputTarget = StdOut | FileOutput !F.FilePath
    deriving (Show)

data TopcoderProblemDescriptor = TopcoderProblemDescriptor
    { tcClassName        :: !Text
    , tcMethod           :: !TopcoderValue
    , tcMethodParameters :: ![TopcoderValue]
    } deriving (Show)

data TopcoderValue = TopcoderValue
    { tcValueName      :: !Text          -- ^ Parameter/method name
    , tcValueType      :: !TopcoderType  -- ^ Base type of the parameter, e.g. int for vector<vector<int>>
    , tcValueDimension :: !Int           -- ^ Dimension, e.g. 2 for vector<vector<int>>
    } deriving (Show)

data TopcoderType = TCInt | TCLong | TCDouble | TCString
    deriving (Show)

makeProblem :: Text -> ProblemID -> ProblemType -> Problem
makeProblem name probId probType = Problem
    { problemName = name
    , problemId = probId
    , problemType = probType
    , problemFloatTolerance = 0.000001
    }


data Verbosity = Info | Debug
    deriving (Show, Enum, Ord, Eq, Bounded)

-- | The type encapsulating functions required to support particular target
--   programming language.
data ProgrammingLanguage = ProgrammingLanguage
    { generateScaffold   :: ProblemID -> CaideIO ()
    , inlineCode         :: ProblemID -> CaideIO ()
    }

newtype CaideM m a = CaideM { unCaideM :: RWST CaideEnv () CaideState (ExceptT C.CPError m) a }
    deriving (Functor, Applicative, Monad, MonadIO, MonadError C.CPError, MonadReader CaideEnv, MonadState CaideState)

type CaideIO a = CaideM IO a

-- | 'Builder' result
data BuilderResult = BuildFailed  -- ^ Build failed or program under test exited unexpectedly
                   | TestsFailed  -- ^ Build succeeded, tests have been evaluated and failed
                   | NoEvalTests  -- ^ Build succeeded, tests have not been evaluated
                   | TestsPassed  -- ^ Tests succeeded

-- | Builder is responsible for building the code and running test program
type Builder = ProblemID -> CaideIO BuilderResult

-- | A feature is a piece of optional functionality that may be run
--   at certain points, depending on the configuration. A feature doesn't
--   run by itself, but only in response to certain events.
--   The first parameter in all functions is ID of the problem that triggered the event.
data Feature = Feature
    { onProblemCreated     :: ProblemID -> CaideIO ()   -- ^ Run after `caide problem`
    , onProblemCodeCreated :: ProblemID -> CaideIO ()   -- ^ Run after `caide lang`
    , onProblemCheckedOut  :: ProblemID -> CaideIO ()   -- ^ Run after `caide checkout`
    , onProblemRemoved     :: ProblemID -> CaideIO ()   -- ^ Run after `caide archive`
    }

noOpFeature :: Feature
noOpFeature =  Feature
    { onProblemCreated     = const $ return ()
    , onProblemCodeCreated = const $ return ()
    , onProblemCheckedOut  = const $ return ()
    , onProblemRemoved     = const $ return ()
    }

-- | A tag of 'ConfigFileHandle' indicating that the config is mapped by a file on disk
data Persistent

-- | A tag of 'ConfigFileHandle' indicating that the config is temporary (for current run only)
data Temporary

-- | File handle through which it's possible to access options. See 'setProp', 'getProp'
newtype ConfigFileHandle configType = FileHandle F.FilePath

runCaideM :: Monad m => CaideM m a -> CaideEnv -> CaideState -> m (Either C.CPError (a, CaideState, ()))
runCaideM caideAction env state = runExceptT $ runRWST (unCaideM caideAction) env state

runInDirectory :: Verbosity -> F.FilePath -> CaideIO a -> IO (Either C.CPError a)
runInDirectory v dir caideAction = do
    let initialState = CaideState { files = M.empty }
        logEx e = do
            when (v >= Debug) $ print e
            return (Left e)
    ret <- tryIOError $ do
        iniSettings <- readSettings (dir </> "caide.ini")
        case iniSettings of
            Left e  -> pure $ Left (C.OtherProblem (T.unpack e), "")
            Right s -> do
                let env = CaideEnv { root = dir, verbosity = v, settings = s }
                runCaideM caideAction env initialState
    case ret of
        Left e -> logEx (C.OtherProblem $ displayException e, "")
        Right (Left e) -> logEx e
        Right (Right (a, finalState, _)) -> do
            forM_ [f | f@(filePath, fileHandle) <- M.assocs (files finalState),
                        modified fileHandle && not (F.null filePath)] $
                uncurry writeConfigParser
            return $ Right a

throw :: Monad m => Text -> CaideM m a
throw desc = throwError (C.OtherProblem $ unpack desc, "")

-- | Return root caide directory
caideRoot :: Monad m => CaideM m F.FilePath
caideRoot = reader root

caideVerbosity :: Monad m => CaideM m Verbosity
caideVerbosity = reader verbosity

caideSettings :: Monad m => CaideM m Settings
caideSettings = reader settings

-- | Creates a new config file. Throws if it already exists.
createConf :: Monad m => F.FilePath -> C.ConfigParser -> CaideM m (ConfigFileHandle Persistent)
createConf filePath cp = do
    fileMap <- gets files
    when (M.member filePath fileMap) $
        throw $ T.concat ["File ", toText filePath, " already exists"]
    modifyWithFiles $ M.insert filePath ConfigInMemory{ configParser=cp, modified=True }
    return $ FileHandle filePath

-- | Reads a config file
readConf :: F.FilePath -> CaideIO (ConfigFileHandle Persistent)
readConf filePath = do
    fileMap <- gets files
    unless (M.member filePath fileMap) $ do
        conf <- readConfigFile filePath
        let newFile = ConfigInMemory { configParser = conf, modified = False}
        modifyWithFiles $ M.insert filePath newFile
    return $ FileHandle filePath

getTemporaryConf :: CaideIO (ConfigFileHandle Temporary)
getTemporaryConf = do
    let emptyPath = F.empty
    fileMap <- gets files
    unless (M.member emptyPath fileMap) $ do
        let newFile = ConfigInMemory { configParser = C.emptyCP, modified = False }
        modifyWithFiles $ M.insert emptyPath newFile
    return $ FileHandle emptyPath

flushConf :: ConfigFileHandle Persistent -> CaideIO ()
flushConf (FileHandle filePath) = do
    fileMap <- gets files
    case M.lookup filePath fileMap of
        Nothing   -> throw $ T.concat ["File ", toText filePath, " doesn't exist"]
        Just conf -> do
            liftIO $ writeConfigParser filePath conf
            modifyWithFiles $ M.adjust (\c -> c{modified=False}) filePath


getProp :: (Monad m, Option a) => ConfigFileHandle c -> String -> String -> CaideM m a
getProp (FileHandle path) section key = do
    mf <- gets (M.lookup path . files)
    case mf of
        Nothing -> throw $ T.concat ["Unknown file handle ", toText path]
        Just f  -> do
            r <- caideRoot
            opt <- convertToCaide $ C.get (extend r $ configParser f) (map toLower section) key
            case optionFromString opt of
                Just a  -> return a
                Nothing -> throw $ T.concat ["Couldn't parse option ", pack opt]

setProp :: (Monad m, Option a) => ConfigFileHandle c -> String -> String -> a -> CaideM m ()
setProp (FileHandle path) section key value = do
    mf <- gets (M.lookup path . files)
    case mf of
        Nothing -> throw $ T.append "Unknown file handle " $ toText path
        Just f  -> do
            newConf <- convertToCaide $ C.set (configParser f) section key (optionToString value)
            let newFile = ConfigInMemory { configParser = newConf, modified = True}
            modifyWithFiles $ M.insert path newFile


{------------------ Internals ---------------------}

extend :: F.FilePath -> C.ConfigParser -> C.ConfigParser
extend r conf = conf' { C.accessfunc = C.interpolatingAccess 10, C.usedefault = True }
    where Right conf' = C.set conf "DEFAULT" "caideRoot" $ F.encodeString r

instance Option TopcoderType where
    optionToString TCInt    = "int"
    optionToString TCLong   = "long"
    optionToString TCDouble = "double"
    optionToString TCString = "String"

    optionFromString "int"    = Just TCInt
    optionFromString "long"   = Just TCLong
    optionFromString "double" = Just TCDouble
    optionFromString "String" = Just TCString
    optionFromString "string" = Just TCString
    optionFromString _        = Nothing

-- name:vvType
instance Option TopcoderValue where
    optionToString p = concat [
        unpack (tcValueName p), ":", replicate (tcValueDimension p) 'v', optionToString (tcValueType p)]

    optionFromText s = case T.splitOn ":" s of
        [paramName, paramType] -> case maybeBaseType of
            Just baseType -> Just TopcoderValue
                { tcValueName = paramName
                , tcValueType = baseType
                , tcValueDimension = dim
                }
            Nothing       -> Nothing
          where
            dim = T.length . T.takeWhile (=='v') $ paramType
            maybeBaseType = optionFromText . T.dropWhile (=='v') $ paramType
        _ -> Nothing

instance Option ProblemType where
    -- topcoder,class,method:retType,param1:type1,param2:type2
    optionToString (Topcoder desc) =
        optionToString ("topcoder" : tcClassName desc :
                        map optionToText (tcMethod desc : tcMethodParameters desc))
    optionToString (Stream input output) = concat [
        "file,", inputSourceToString input, ",", outputTargetToString output]

    optionFromText s | "topcoder," `T.isPrefixOf` s = case maybeParams of
        Just (method:params) -> Just $ Topcoder TopcoderProblemDescriptor
            { tcClassName = className
            , tcMethod = method
            , tcMethodParameters = params
            }
        _ -> Nothing
      where
        components = T.splitOn "," s
        _:className:paramsStr = components
        maybeParams = if length components >= 3
            then mapM optionFromText paramsStr
            else Nothing

    optionFromText s = case optionFromText s of
        Just [probType, inputSource, outputSource]
            | probType == "file" -> Just $ Stream (parseInput inputSource) (parseOutput outputSource)
        _ -> Nothing

data ConfigInMemory = ConfigInMemory
    { configParser :: C.ConfigParser
    , modified     :: Bool
    }

data CaideEnv = CaideEnv
    { root      :: F.FilePath
    , verbosity :: Verbosity
    , settings  :: Settings
    } deriving (Show)

data CaideState = CaideState
    { files :: Map F.FilePath ConfigInMemory
    }


convertToCaide :: Monad m => Either C.CPError a -> CaideM m a
convertToCaide (Left err) = throwError err
convertToCaide (Right a)  = return a

readConfigFile :: F.FilePath -> CaideIO C.ConfigParser
readConfigFile filePath = do
    fileReadResult <- liftIO $ readTextFile filePath
    case fileReadResult of
        Left err   -> throw err
        Right text -> convertToCaide $ C.readstring C.emptyCP $ T.unpack text

modifyWithFiles :: Monad m =>
                   (Map F.FilePath ConfigInMemory -> Map F.FilePath ConfigInMemory)
                 -> CaideM m ()
modifyWithFiles f = modify' $ \s -> s{files = f (files s)}

writeConfigParser :: F.FilePath -> ConfigInMemory -> IO ()
writeConfigParser file cp = do
    F.createTree $ F.directory file
    writeTextFile file . pack . C.to_string $ configParser cp

toText :: F.FilePath -> Text
toText path = case F.toText path of
    Left  s -> s
    Right s -> s

inputSourceToString :: InputSource -> String
inputSourceToString StdIn = "stdin"
inputSourceToString (FileInput f) = F.encodeString f
inputSourceToString (InputFilePattern p) = T.unpack $ "/" <> p <> "/"

outputTargetToString :: OutputTarget -> String
outputTargetToString StdOut = "stdout"
outputTargetToString (FileOutput f) = F.encodeString f

parseInput :: Text -> InputSource
parseInput "stdin" = StdIn
parseInput f
    | T.length f >= 2 && T.head f == '/' && T.last f == '/'
        = InputFilePattern . T.init . T.tail $ f
    | otherwise
        = FileInput . F.fromText $ f

parseOutput :: Text -> OutputTarget
parseOutput "stdout" = StdOut
parseOutput f = FileOutput . F.fromText $ f


