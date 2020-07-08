{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Strict #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

module WebCheck.Run
  ( CheckOptions (..),
    check,
  )
where

import Control.Lens hiding (each)
import Control.Monad ((>=>), fail, forever, void, when)
import Control.Monad (filterM)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Loops (andM)
import Control.Monad.Trans.Class (MonadTrans)
import Control.Monad.Trans.Class (MonadTrans (lift))
import qualified Data.Aeson as JSON
import Data.Function ((&))
import Data.Functor (($>))
import Data.Generics.Product (field)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe)
import Data.String (String, fromString)
import qualified Data.Text as Text
import Data.Text (Text)
import Data.Text.Prettyprint.Doc
import Data.Text.Prettyprint.Doc.Render.Terminal
import Data.Tree
import GHC.Generics (Generic)
import Network.HTTP.Client as Http
import qualified Network.Wreq as Wreq
import Pipes ((>->), Consumer, Effect, Pipe, Producer)
import qualified Pipes
import qualified Pipes.Prelude as Pipes
import System.Environment (lookupEnv)
import qualified Test.QuickCheck as QuickCheck
import Text.URI (URI)
import qualified Text.URI as URI
import Web.Api.WebDriver hiding (Action, Selector, hPutStrLn, runIsolated)
import WebCheck.Element
import WebCheck.Prelude hiding (catchError, check, throwError, trace)
import WebCheck.Pretty
import WebCheck.Result
import WebCheck.Specification
import WebCheck.Trace
import Data.Vector (Vector)
import qualified Data.Vector as Vector

type Runner = WebDriverTT (ReaderT CheckOptions) IO

data FailingTest
  = FailingTest
      { numShrinks :: Int,
        trace :: Trace TraceElementEffect,
        reason :: Maybe (Doc AnsiStyle)
      }
  deriving (Show, Generic)

data CheckResult = CheckSuccess | CheckFailure {failedAfter :: Int, failingTest :: FailingTest}
  deriving (Show, Generic)

data CheckOptions = CheckOptions {checkTests :: Int, checkShrinkLevels :: Int, checkOrigin :: URI}

check :: Specification spec => CheckOptions -> spec -> IO ()
check opts@CheckOptions {checkTests} spec = do
  -- stdGen <- getStdGen
  logInfo ("Running " <> show checkTests <> " tests...")
  result <- runWebDriver opts (Pipes.runEffect (runAll checkTests spec))
  case result of
    CheckFailure {failedAfter, failingTest} -> do
      logInfo . renderString $
        prettyTrace
          ( {- withoutStutterStates -} (trace failingTest)
          )
          <> line
      case reason failingTest of
        Just err -> logInfo (renderString (annotate (color Red) ("Verification failed with error:" <+> err <> line)))
        Nothing -> pure ()
      logInfo (renderString (annotate (color Red) ("Failed after " <> pretty failedAfter <> " tests and " <> pretty (numShrinks failingTest) <> " levels of shrinking.")))
      exitFailure
    CheckSuccess -> logInfo ("Passed " <> show checkTests <> " tests.")

elementsToTrace :: Producer (TraceElement ()) Runner () -> Runner (Trace ())
elementsToTrace = fmap Trace . Pipes.toListM

minBy :: (Monad m, Ord b) => (a -> b) -> Producer a m () -> m (Maybe a)
minBy f = Pipes.fold step Nothing identity
  where
    step x a = Just $ case x of
      Nothing -> a
      Just a' ->
        case f a `compare` f a' of
          EQ -> a
          LT -> a
          GT -> a'

select :: Monad m => (a -> Maybe b) -> Pipe a b m ()
select f = forever do
  x <- Pipes.await
  maybe (pure ()) Pipes.yield (f x)

runSingle :: Specification spec => spec -> Int -> Runner (Either FailingTest ())
runSingle spec size = do
  result <-
    generateValidActions (actions spec)
      >-> Pipes.take size
      & runAndVerifyIsolated 0
  case result of
    Right trace -> do
      case trace ^.. traceActionFailures of
        [] -> pass
        failures -> logInfoWD (renderString ("There were" <+> pretty (length failures) <+> "action failures"))
      pure (Right ())
    f@(Left (FailingTest _ trace _)) -> do
      CheckOptions {checkShrinkLevels} <- liftWebDriverTT ask
      logInfoWD "Test failed. Shrinking..."
      let shrinks = shrinkForest (QuickCheck.shrinkList shrinkAction) checkShrinkLevels (trace ^.. traceActions)
      shrunk <- minBy (lengthOf (field @"trace" . traceElements)) (traverseShrinks runShrink shrinks >-> select (preview _Left) >-> Pipes.take 5)
      pure (fromMaybe (void f) (Left <$> shrunk))
  where
    runAndVerifyIsolated n producer = do
      trace <- annotateStutteringSteps <$> inNewPrivateWindow do
        beforeRun spec
        elementsToTrace (producer >-> runActions' spec)
      -- logInfoWD (renderString (prettyTrace ({- withoutStutterStates -} trace) <> line))
      case verify spec (trace ^.. nonStutterStates) of
        Right Accepted -> pure (Right trace)
        Right Rejected -> pure (Left (FailingTest n trace Nothing))
        Left err -> pure (Left (FailingTest n trace (Just err)))
    runShrink (Shrink n actions') = do
      logInfoWD ("Running shrunk test at level " <> show n <> "...")
      runAndVerifyIsolated n (Pipes.each actions')

runAll :: Specification spec => Int -> spec -> Effect Runner CheckResult
runAll numTests spec' = (allTests $> CheckSuccess) >-> firstFailure
  where
    runSingle' :: Int -> Producer (Either FailingTest ()) Runner ()
    runSingle' size = do
      lift (logInfoWD ("Running test with size: " <> show size))
      Pipes.yield =<< lift (runSingle spec' size)
    allTests :: Producer (Either FailingTest (), Int) Runner ()
    allTests = Pipes.for (sizes numTests) runSingle' `Pipes.zip` Pipes.each [1 ..]

firstFailure :: Functor m => Consumer (Either FailingTest (), Int) m CheckResult
firstFailure =
  Pipes.await >>= \case
    (Right {}, _) -> firstFailure
    (Left failingTest, n) -> pure (CheckFailure n failingTest)

sizes :: Functor m => Int -> Producer Int m ()
sizes numSizes = Pipes.each (map (\n -> (n * 100 `div` numSizes)) [1 .. numSizes])

beforeRun :: Specification spec => spec -> Runner ()
beforeRun spec = do
  navigateToOrigin
  awaitElement (readyWhen spec)
  initializeScript

observeManyStatesAfter :: Queries -> ObservedState -> Action Selected -> Pipe a (TraceElement ()) Runner ObservedState
observeManyStatesAfter queries' initialState action = do
  result <- lift (catchActionFailed (runAction action))
  observer <- lift (registerNextStateObserver queries')
  delta <- getNextOrFail observer
  let afterDelta = delta <> initialState
  Pipes.yield (TraceAction () action result)
  nonStutters <-
    (loop afterDelta >-> Pipes.takeWhile (/= afterDelta) >-> Pipes.take 5)
      & Pipes.toListM
      & lift
      & fmap (fromMaybe (pure afterDelta) . NonEmpty.nonEmpty)
  mapM_ (Pipes.yield . (TraceState ())) nonStutters
  pure (NonEmpty.last nonStutters)
  where
    getNextOrFail observer =
      either (fail . Text.unpack) pure
        =<< lift (getNextState observer)
    loop :: ObservedState -> Producer ObservedState Runner ()
    loop currentState = do
      Pipes.yield currentState
      delta <- getNextOrFail =<< lift (registerNextStateObserver queries')
      loop (currentState <> delta)
    toActionFailed :: Show a => a -> Runner ActionResult
    toActionFailed = pure . ActionFailed . show
    catchActionFailed ma =
      catchAnyError
        (ma)
        toActionFailed
        toActionFailed
        toActionFailed
        toActionFailed

{-# SCC runActions' "runActions'" #-}
runActions' :: Specification spec => spec -> Pipe (Action Selected) (TraceElement ()) Runner ()
runActions' spec = do
  state1 <- lift (observeStates queries')
  Pipes.yield (TraceState () state1)
  loop state1
  where
    queries' = queries spec
    loop currentState = do
      action <- Pipes.await
      -- lift (logInfoWD (renderString (prettyAction action)))
      newState <- observeManyStatesAfter queries' currentState action
      loop newState

data Shrink a = Shrink Int a

shrinkForest :: (a -> [a]) -> Int -> a -> Forest (Shrink a)
shrinkForest shrink limit = go 1
  where
    go n
      | n <= limit = map (\x -> Node (Shrink n x) (go (succ n) x)) . shrink
      | otherwise = mempty

traverseShrinks :: Monad m => ((Shrink a) -> m (Either e b)) -> Forest (Shrink a) -> Producer (Either e b) m ()
traverseShrinks test = go
  where
    go = \case
      [] -> pure ()
      Node x xs : rest -> do
        r <- lift (test x)
        Pipes.yield r
        when (isn't _Right r) do
          go xs
        go rest

shrinkAction :: Action sel -> [Action sel]
shrinkAction _ = [] -- TODO?

generate :: QuickCheck.Gen a -> Runner a
generate = liftWebDriverTT . lift . QuickCheck.generate

generateValidActions :: Vector (Int, Action Selector) -> Producer (Action Selected) Runner ()
generateValidActions actions' = forever do
  validActions <- lift $ for (Vector.toList actions') \(prob, action') -> do
    fmap (prob,) <$> selectValidAction action'
  validActions
    & catMaybes
    & map (_2 %~ pure)
    & QuickCheck.frequency
    & generate
    & lift
    & (>>= Pipes.yield)

selectValidAction :: Action Selector -> Runner (Maybe (Action Selected))
selectValidAction possibleAction = 
  case possibleAction of
    KeyPress k -> do
      active <- isActiveInput
      if active then (pure (Just (KeyPress k))) else pure Nothing
    EnterText t -> do
      active <- isActiveInput
      if active then (pure (Just (EnterText t))) else pure Nothing
    Navigate p -> pure (Just (Navigate p))
    Focus sel -> selectOne sel Focus (isNotActive . toRef)
    Click sel -> selectOne sel Click isClickable
  where
    selectOne :: Selector -> (Selected -> Action Selected) -> (Element -> Runner Bool) -> Runner (Maybe (Action Selected))
    selectOne sel ctor isValid = do
      found <- findAll sel
      validChoices <-
        ( filterM
            (\(_, e) -> isValid e `catchError` (const (pure False)))
            (zip [0 ..] found)
          )
      case validChoices of
        [] -> pure Nothing
        choices -> Just <$> generate (ctor . Selected sel <$> QuickCheck.elements (map fst choices))
    isNotActive e = (/= Just e) <$> activeElement
    activeElement = (Just <$> getActiveElement) `catchError` const (pure Nothing)
    isClickable e =
      andM [isElementEnabled (toRef e), isElementVisible e]
    isActiveInput =
        activeElement >>= \case
          Just el -> (`elem` ["input", "textarea"]) <$> getElementTagName el
          Nothing -> pure False

navigateToOrigin :: Runner ()
navigateToOrigin = do
  CheckOptions {checkOrigin} <- liftWebDriverTT ask
  navigateTo (toS (URI.renderStr checkOrigin))

tryAction :: Runner ActionResult -> Runner ActionResult
tryAction action = action `catchError` (pure . ActionFailed . Text.pack . show)

click :: Selected -> Runner ActionResult
click = findSelected >=> \case
  Just e -> tryAction (ActionSuccess <$ (elementClick (toRef e)))
  Nothing -> pure ActionImpossible

sendKeys :: Text -> Runner ActionResult
sendKeys t = tryAction (ActionSuccess <$ (getActiveElement >>= elementSendKeys (toS t)))

sendKey :: Char -> Runner ActionResult
sendKey = sendKeys . Text.singleton

focus :: Selected -> Runner ActionResult
focus = findSelected >=> \case
  Just e -> tryAction (ActionSuccess <$ (elementSendKeys "" (toRef e)))
  Nothing -> pure ActionImpossible

runAction :: Action Selected -> Runner ActionResult
runAction = \case
  Focus s -> focus s
  KeyPress c -> sendKey c
  EnterText t -> sendKeys t
  Click s -> click s
  Navigate url -> tryAction (ActionSuccess <$ navigateTo (URI.renderStr url))

runWebDriver :: CheckOptions -> Runner a -> IO a
runWebDriver opts ma = do
  mgr <- Http.newManager defaultManagerSettings
  let httpOptions :: Wreq.Options
      httpOptions = Wreq.defaults & Wreq.manager .~ Right mgr
  runReaderT (execWebDriverTT (reconfigure defaultWebDriverConfig httpOptions) ma) opts >>= \case
    (Right x, _, _) -> pure x
    (Left err, _, _) -> fail (show err)
  where
    reconfigure c httpOptions =
      c
        { _environment =
            (_environment c)
              { _logEntryPrinter = \_ _ -> Nothing
              },
          _initialState = defaultWebDriverState {_httpOptions = httpOptions}
        }

inNewPrivateWindow :: Runner a -> Runner a
inNewPrivateWindow = runIsolated (reconfigure headlessFirefoxCapabilities)
  where
    reconfigure c =
      c
        { _firefoxOptions = (_firefoxOptions c)
            <&> \o ->
              o
                { _firefoxArgs = Just ["-headless", "-private"],
                  _firefoxPrefs = Just (HashMap.singleton "Dom.storage.enabled" (JSON.Bool False)),
                  _firefoxLog = Just (FirefoxLog (Just LogWarn))
                }
        }

-- | Mostly the same as the non-exported definition in 'Web.Api.WebDriver.Endpoints'.
runIsolated ::
  (Monad eff, Monad (t eff), MonadTrans t) =>
  Capabilities ->
  WebDriverTT t eff a ->
  WebDriverTT t eff a
runIsolated caps theSession = cleanupOnError do
  sid <- newSession caps
  modifyState (setSessionId (Just sid))
  a <- theSession
  deleteSession
  modifyState (setSessionId Nothing)
  pure a

-- | Same as the non-exported definition in 'Web.Api.WebDriver.Endpoints'.
cleanupOnError ::
  (Monad eff, Monad (t eff), MonadTrans t) =>
  -- | `WebDriver` session that may throw errors
  WebDriverTT t eff a ->
  WebDriverTT t eff a
cleanupOnError x =
  catchAnyError
    x
    (\e -> deleteSession >> throwError e)
    (\e -> deleteSession >> throwHttpException e)
    (\e -> deleteSession >> throwIOException e)
    (\e -> deleteSession >> throwJsonError e)

-- | Same as the non-exported definition in 'Web.Api.WebDriver.Endpoints'.
setSessionId ::
  Maybe String ->
  S WDState ->
  S WDState
setSessionId x st = st {_userState = (_userState st) {_sessionId = x}}

findSelected :: Selected -> Runner (Maybe Element)
findSelected (Selected s i) =
  findAll s >>= \es -> pure ((es ^? ix i))

findAll :: Selector -> Runner [Element]
findAll (Selector s) = map fromRef <$> findElements CssSelector (Text.unpack s)

toRef :: Element -> ElementRef
toRef (Element ref) = ElementRef (Text.unpack ref)

fromRef :: ElementRef -> Element
fromRef (ElementRef ref) = Element (Text.pack ref)

logInfo :: MonadIO m => String -> m ()
logInfo = liftIO . hPutStrLn stderr

logInfoWD :: String -> Runner ()
logInfoWD = liftWebDriverTT . logInfo

isElementVisible :: Element -> Runner Bool
isElementVisible el =
  (== JSON.Bool True) <$> executeScript "return window.webcheck.isElementVisible(arguments[0])" [JSON.toJSON el]

awaitElement :: Selector -> Runner ()
awaitElement sel = do
  let loop = do
        findAll sel >>= \case
          [] -> liftWebDriverTT (liftIO (threadDelay 1000000)) >> loop
          _ -> pass
  loop

executeScript' :: JSON.FromJSON r => Script -> [JSON.Value] -> Runner r
executeScript' script args = do
  r <- executeScript script args
  case JSON.fromJSON r of
    JSON.Success a -> pure a
    JSON.Error e -> fail e

executeAsyncScript' :: JSON.FromJSON r => Script -> [JSON.Value] -> Runner r
executeAsyncScript' script args = do
  r <- executeAsyncScript script args
  case JSON.fromJSON r of
    JSON.Success a -> pure a
    JSON.Error e -> fail e

observeStates :: Queries -> Runner ObservedState
observeStates queries' =
  executeScript' "return window.webcheck.observeInitialStates(arguments[0])" [JSON.toJSON queries']

newtype StateObserver = StateObserver Text
  deriving (Eq, Show)

registerNextStateObserver :: Queries -> Runner StateObserver
registerNextStateObserver queries' =
  StateObserver
    <$> executeScript'
      "return window.webcheck.registerNextStateObserver(arguments[0])"
      [JSON.toJSON queries']

getNextState :: StateObserver -> Runner (Either Text ObservedState)
getNextState (StateObserver sid) =
  executeAsyncScript'
    "window.webcheck.runPromiseEither(webcheck.getNextState(arguments[0]), arguments[1])"
    [JSON.toJSON sid]

renderString :: Doc AnsiStyle -> String
renderString = Text.unpack . renderStrict . layoutPretty defaultLayoutOptions

webcheckJs :: Runner Script
webcheckJs = liftWebDriverTT . lift $ do
  let key = "WEBCHECK_CLIENT_SIDE_BUNDLE"
  bundlePath <- maybe (fail (key <> " environment variable not set")) pure =<< lookupEnv key
  fromString . toS <$> readFile bundlePath

initializeScript :: Runner ()
initializeScript = do
  js <- webcheckJs
  void (executeScript js [])
