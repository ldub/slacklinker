module Slacklinker.App
  ( AppM (..),
    HasApp (..),
    RuntimeInfo (..),
    App (..),
    AppConfig (..),
    appSlackConfig,
    appStartupNoSender,
    appShutdownNoSender,
    runAppM,
    runDB,
    getConfiguration,
    makeApp,
  )
where

import Control.Monad.Logger (LogLevel (..), MonadLoggerIO, ToLogStr (..), defaultOutput)
import Control.Monad.Logger.CallStack (MonadLoggerIO (..))
import Data.ByteString.Char8 qualified as BS
import Data.Pool (Pool, destroyAllResources)
import Database.Persist.Postgresql (SqlBackend, createPostgresqlPool, runSqlPoolWithExtensibleHooks)
import Database.Persist.SqlBackend.SqlPoolHooks
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import OpenTelemetry.Instrumentation.Persistent qualified as OTel
import OpenTelemetry.Trace (TracerProvider)
import OpenTelemetry.Trace qualified as OTel
import Slacklinker.Import
import Slacklinker.Types (SlackClientSecret (..), SlackSigningSecret (..), SlackToken (..))
import System.Environment (getEnv, lookupEnv)
import Web.Slack (SlackConfig (..))

data AppConfig = AppConfig
  { slackClientSecret :: SlackClientSecret
  , slackSigningSecret :: SlackSigningSecret
  , slackClientId :: Text
  , postgresConnectionString :: ByteString
  , sqlLogLevel :: LogLevel
  , logLevel :: LogLevel
  }
  deriving stock (Show)

appSlackConfig :: HasApp m => SlackToken -> m SlackConfig
appSlackConfig (SlackToken slackConfigToken) = do
  slackConfigManager <- getsApp (.manager)
  pure SlackConfig {..}

{- | Stuff that needs to be torn down on shutdown but availability depends on
 startup mode.
-}
data RuntimeInfo = RuntimeInfo
  { tracerProvider :: TracerProvider
  , senderAction :: Async ()
  , appPool :: Pool SqlBackend
  }

appStartupNoSender :: App -> IO RuntimeInfo
appStartupNoSender app = do
  tracerProvider <- OTel.initializeGlobalTracerProvider
  -- needs to run in AppM to get our main logger
  appPool <- runAppM app $ createPostgresqlPool app.config.postgresConnectionString 5
  let senderAction = error "sender action not available, possibly because this is the sender"
  pure RuntimeInfo {..}

appShutdownNoSender :: RuntimeInfo -> IO ()
appShutdownNoSender RuntimeInfo {..} = do
  OTel.shutdownTracerProvider tracerProvider
  destroyAllResources appPool

data App = App
  { config :: AppConfig
  , manager :: Manager
  , runtimeInfo :: RuntimeInfo
  }

class (Monad m, MonadLogger m) => HasApp m where
  getApp :: m App
  getsApp :: (App -> a) -> m a
  getsApp f = f <$> getApp

newtype AppM a = AppM {unAppM :: ReaderT App IO a}
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO)

instance MonadLogger AppM where
  monadLoggerLog loc source level msg = do
    logger <- askLoggerIO
    liftIO $ logger loc source level (toLogStr msg)

instance MonadLoggerIO AppM where
  askLoggerIO = do
    logLevel <- getsApp (.config.logLevel)
    sqlLogLevel <- getsApp (.config.sqlLogLevel)
    pure \loc source level msg -> do
      case source of
        "SQL" ->
          when (level >= sqlLogLevel) $
            defaultOutput stderr loc source level msg
        _ ->
          when (level >= logLevel) $
            defaultOutput stderr loc source level msg

instance HasApp AppM where
  getApp = do
    AppM ask

runAppM :: App -> AppM a -> IO a
runAppM app act = do
  let readerT = unAppM act
  runReaderT readerT app

runDB :: (HasApp m, MonadIO m) => SqlPersistT IO a -> m a
runDB act = do
  app <- getApp
  let pool = app.runtimeInfo.appPool
  liftIO $ runSqlPoolWithExtensibleHooks act pool Nothing hooks
  where
    hooks = setAlterBackend defaultSqlPoolHooks $ OTel.wrapSqlBackend []

readLogLevel :: [Char] -> LogLevel
readLogLevel "debug" = LevelDebug
readLogLevel "info" = LevelInfo
readLogLevel "warn" = LevelWarn
readLogLevel "error" = LevelError
readLogLevel other = error $ "unknown log level " <> other

getConfiguration :: IO AppConfig
getConfiguration = do
  slackSigningSecret <- SlackSigningSecret <$> getEnvBS "SLACK_SIGNING_SECRET"
  slackClientSecret <- SlackClientSecret . cs <$> getEnvBS "SLACK_CLIENT_SECRET"
  slackClientId <- cs <$> getEnvBS "SLACK_CLIENT_ID"
  postgresConnectionString <- getEnvBS "POSTGRES_CONNECTION_STRING"
  logLevel <- maybe LevelInfo readLogLevel <$> lookupEnv "LOG_LEVEL"
  sqlLogLevel <- maybe LevelInfo readLogLevel <$> lookupEnv "LOG_SQL"

  pure AppConfig {..}
  where
    getEnvBS :: String -> IO ByteString
    getEnvBS a = BS.pack <$> getEnv a

makeApp :: IO App
makeApp = do
  -- FIXME(jadel): I want to instrument the HTTP manager for debugging
  -- purposes, but hs-opentelemetry does not support it.
  manager <- newTlsManager
  config <- getConfiguration
  let runtimeInfo = error "runtime info not initialized yet. this is a bug"
  pure App {..}
