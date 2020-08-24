{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Log.Store.Base
  ( -- * Exported Types
    LogName,
    Entry,
    OpenOptions (..),
    LogHandle,
    EntryID,
    Config (..),
    Context,
    LogStoreException (..),

    -- * Basic functions
    initialize,
    create,
    open,
    appendEntry,
    appendEntries,
    readEntries,
    close,
    shutDown,
    withLogStore,

    -- * Options
    defaultOpenOptions,
    defaultConfig,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel)
import qualified Control.Concurrent.ReadWriteVar as RWV
import Control.Exception (throwIO)
import Control.Monad (foldM, forever, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Resource (MonadUnliftIO, allocate, runResourceT)
import Data.Atomics (atomicModifyIORefCAS)
import Data.Bifunctor (first)
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as U
import Data.Default (def)
import Data.Function ((&))
import qualified Data.HashMap.Strict as H
import Data.Hashable (Hashable)
import Data.IORef (IORef, newIORef, readIORef)
import Data.List.NonEmpty (fromList)
import Data.Maybe (isJust)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Word (Word32, Word64)
import qualified Database.RocksDB as R
import GHC.Conc (TVar, atomically, newTVarIO, readTVar, writeTVar)
import GHC.Generics (Generic)
import Log.Store.Exception
import Log.Store.Internal
import Log.Store.Utils
import Streamly (Serial, sconcat)
import qualified Streamly.Prelude as S

-- | Config info
data Config = Config
  { rootDbPath :: FilePath,
    dataCfWriteBufferSize :: Word64,
    enableDBStatistics :: Bool,
    dbStatsDumpPeriodSec :: Word32,
    dataCfPartitionDuration :: Int, -- minutes
    dataCfPartitionSizeLimit :: Int -- GB
  }

defaultConfig :: Config
defaultConfig =
  Config
    { rootDbPath = "/tmp/log-store/rocksdb",
      dataCfWriteBufferSize = 200 * 1024 * 1024,
      enableDBStatistics = False,
      dbStatsDumpPeriodSec = 600,
      dataCfPartitionDuration = 1, -- minutes
      dataCfPartitionSizeLimit = 1 -- GB
    }

data Context = Context
  { dbPath :: FilePath,
    dbHandle :: R.DB,
    metaCFHandle :: R.ColumnFamily,
    curDataCFHandleRef :: RWV.RWVar R.ColumnFamily,
    resourcesForReadRef :: IORef [CFResourcesForRead],
    logHandleCache :: TVar (H.HashMap LogHandleKey LogHandle),
    maxLogIdRef :: IORef LogID,
    backgroundShardingTask :: Async ()
  }

shardingTask ::
  Int ->
  Int ->
  R.DB ->
  Word64 ->
  RWV.RWVar R.ColumnFamily ->
  IO ()
shardingTask
  partitionInterval
  partitionSizeLimit
  db
  cfWriteBufferSize
  curDataCfRef = forever $ do
    threadDelay $ partitionInterval * 60 * 1000000
    curCf <- RWV.with curDataCfRef return
    curDataCfSize <- getCfSize db curCf
    when
      (curDataCfSize >= fromIntegral partitionSizeLimit * 1024 * 1024 * 1024)
      $ do
        newCfName <- generateDataCfName
        newCfHandle <- createDataCf db newCfName cfWriteBufferSize
        RWV.modify_ curDataCfRef (\curCf -> R.destroyColumnFamily curCf >> return newCfHandle)
        return ()

openDBAndMetaCf :: MonadIO m => Config -> m (R.DB, R.ColumnFamily)
openDBAndMetaCf Config {..} = do
  -- first, create db if missing
  tempDb <-
    R.open
      R.defaultDBOptions
        { R.createIfMissing = True
        }
      rootDbPath
  R.close tempDb

  cfNames <- R.listColumnFamilies def rootDbPath
  if length cfNames == 1
    then -- create metacf if missing
    do
      (dbHandle, cfHandles) <-
        R.openColumnFamilies
          R.defaultDBOptions
            { R.createIfMissing = True,
              R.createMissingColumnFamilies = True,
              R.maxBackgroundCompactions = 1,
              R.maxBackgroundFlushes = 1,
              R.dbWriteBufferSize = 600 * 1024 * 1024,
              R.maxOpenFiles = 128,
              R.enableStatistics = enableDBStatistics,
              R.statsDumpPeriodSec = dbStatsDumpPeriodSec
            }
          rootDbPath
          [ R.ColumnFamilyDescriptor
              { name = defaultCFName,
                options = R.defaultDBOptions
              },
            R.ColumnFamilyDescriptor
              { name = metaCFName,
                options = R.defaultDBOptions
              }
          ]
      R.destroyColumnFamily (head cfHandles)
      return (dbHandle, cfHandles !! 1)
    else -- open metaCf, must open all cfs and then close others.
    do
      let cfDescriptors = map (\cfName -> R.ColumnFamilyDescriptor {R.name = cfName, R.options = def}) cfNames
      (dbHandle, cfHandles) <-
        R.openColumnFamilies
          R.defaultDBOptions
            { R.maxBackgroundCompactions = 1,
              R.maxBackgroundFlushes = 1,
              R.enableStatistics = enableDBStatistics,
              R.statsDumpPeriodSec = dbStatsDumpPeriodSec
            }
          rootDbPath
          cfDescriptors
      R.destroyColumnFamily (head cfHandles)
      mapM_ R.destroyColumnFamily (drop 2 cfHandles)
      return (dbHandle, cfHandles !! 1)

-- | init Context using Config
-- 1. open (or create) db, metaCF, create a new dataCF
-- 2. init context variables: logHandleCache, maxLogIdRef
-- 3. start background task: shardingTask
initialize :: MonadIO m => Config -> m Context
initialize cfg@Config {..} =
  liftIO $ do
    (db, metaCf) <- openDBAndMetaCf cfg

    newDataCfName <- generateDataCfName
    newDataCfHandle <- createDataCf db newDataCfName dataCfWriteBufferSize

    cache <- newTVarIO H.empty
    maxLogId <- getMaxLogId db metaCf
    logIdRef <- newIORef maxLogId
    newDataCfRef <- RWV.new newDataCfHandle
    resourcesForRead <- newIORef []
    bgShardingTask <-
      async $
        shardingTask
          dataCfPartitionDuration
          dataCfPartitionSizeLimit
          db
          dataCfWriteBufferSize
          newDataCfRef
    return
      Context
        { dbPath = rootDbPath,
          dbHandle = db,
          metaCFHandle = metaCf,
          curDataCFHandleRef = newDataCfRef,
          resourcesForReadRef = resourcesForRead,
          logHandleCache = cache,
          maxLogIdRef = logIdRef,
          backgroundShardingTask = bgShardingTask
        }
  where
    getMaxLogId :: R.DB -> R.ColumnFamily -> IO LogID
    getMaxLogId db cf = do
      maxLogId <- R.getCF db def cf maxLogIdKey
      case maxLogId of
        Nothing -> do
          let initLogId = 0
          R.putCF db def cf maxLogIdKey $ encodeWord64 initLogId
          return initLogId
        Just v -> return (decodeWord64 v)

-- | open options
data OpenOptions = OpenOptions
  { readMode :: Bool,
    writeMode :: Bool,
    createIfMissing :: Bool
  }
  deriving (Eq, Show, Generic)

instance Hashable OpenOptions

defaultOpenOptions =
  OpenOptions
    { readMode = True,
      writeMode = False,
      createIfMissing = False
    }

type Entry = B.ByteString

-- | LogHandle
data LogHandle = LogHandle
  { logName :: LogName,
    logID :: LogID,
    openOptions :: OpenOptions,
    maxEntryIdRef :: IORef EntryID
  }
  deriving (Eq)

data LogHandleKey
  = LogHandleKey LogName OpenOptions
  deriving (Eq, Show, Generic)

instance Hashable LogHandleKey

-- | open a log, will return a LogHandle for later operation
-- | (such as append and read)
open :: MonadIO m => LogName -> OpenOptions -> ReaderT Context m LogHandle
open name opts@OpenOptions {..} = do
  Context {..} <- ask
  res <- R.getCF dbHandle def metaCFHandle (encodeText name)
  let valid = checkOpts res
  if valid
    then do
      cacheRes <- lookupCache logHandleCache
      case cacheRes of
        Just lh ->
          return lh
        Nothing -> do
          newLh <- mkLogHandle res
          updateCache logHandleCache newLh
    else
      liftIO $
        throwIO $
          LogStoreLogNotFoundException $
            "no log named " ++ T.unpack name ++ " found"
  where
    logHandleKey = LogHandleKey name opts

    lookupCache :: MonadIO m => TVar (H.HashMap LogHandleKey LogHandle) -> m (Maybe LogHandle)
    lookupCache tc = liftIO $
      atomically $ do
        cache <- readTVar tc
        case H.lookup logHandleKey cache of
          Nothing -> return Nothing
          Just lh -> return $ Just lh

    updateCache :: MonadIO m => TVar (H.HashMap LogHandleKey LogHandle) -> LogHandle -> m LogHandle
    updateCache tc lh = liftIO $
      atomically $ do
        cache <- readTVar tc
        case H.lookup logHandleKey cache of
          Nothing -> do
            let newCache = H.insert logHandleKey lh cache
            writeTVar tc newCache
            return lh
          Just handle -> return handle

    mkLogHandle :: MonadIO m => Maybe B.ByteString -> ReaderT Context m LogHandle
    mkLogHandle res =
      case res of
        Nothing -> do
          id <- create name
          maxEntryIdRef <- liftIO $ newIORef minEntryId
          return $
            LogHandle
              { logName = name,
                logID = id,
                openOptions = opts,
                maxEntryIdRef = maxEntryIdRef
              }
        Just bId ->
          do
            let logId = decodeLogId bId
            maxEntryId <- getMaxEntryId logId
            maxEntryIdRef <- liftIO $ newIORef maxEntryId
            return $
              LogHandle
                { logName = name,
                  logID = logId,
                  openOptions = opts,
                  maxEntryIdRef = maxEntryIdRef
                }

    checkOpts :: Maybe B.ByteString -> Bool
    checkOpts res =
      case res of
        Nothing ->
          createIfMissing
        Just _ -> True

-- getDataCfHandlesForRead :: FilePath -> IO (R.DB, [R.ColumnFamily])
-- getDataCfHandlesForRead dbPath = do
--   cfNames <- R.listColumnFamilies def dbPath
--   let dataCfNames = filter (/= metaCFName) cfNames
--   let dataCfDescriptors = map (\cfName -> R.ColumnFamilyDescriptor {name = cfName, options = def}) dataCfNames
--   (dbForReadOnly, handles) <-
--     R.openForReadOnlyColumnFamilies
--       def
--       dbPath
--       dataCfDescriptors
--       False
--   return (dbForReadOnly, tail handles)
--

getMaxEntryId :: MonadIO m => LogID -> ReaderT Context m EntryID
getMaxEntryId logId = do
  Context {..} <- ask
  dataCfNames <- getDataCfNameSet dbPath
  res <- foldM (f dbPath) Nothing (reverse dataCfNames)
  case res of
    Nothing -> liftIO $ throwIO $ LogStoreIOException "getMaxEntryId found nothing"
    Just r -> return r
  where
    f dbPath prevRes curCfName =
      case prevRes of
        Nothing ->
          liftIO $
            withCfReadOnly
              dbPath
              curCfName
              (\(dbForRead, cfForRead) -> R.withIteratorCF dbForRead def cfForRead findMaxEntryIdInCf)
        Just res -> return $ Just res

    findMaxEntryIdInCf :: MonadIO m => R.Iterator -> m (Maybe EntryID)
    findMaxEntryIdInCf iterator = do
      R.seekForPrev iterator (encodeEntryKey $ EntryKey logId maxEntryId)
      isValid <- R.valid iterator
      if isValid
        then do
          entryKey <- R.key iterator
          let (EntryKey _ entryId) = decodeEntryKey entryKey
          return $ Just entryId
        else do
          errStr <- R.getError iterator
          case errStr of
            Nothing -> return Nothing
            Just str -> liftIO $ throwIO $ LogStoreIOException $ "getMaxEntryId error: " ++ str

exists :: MonadIO m => LogName -> ReaderT Context m Bool
exists name = do
  Context {..} <- ask
  logId <- R.getCF dbHandle def metaCFHandle (encodeLogName name)
  return $ isJust logId

create :: MonadIO m => LogName -> ReaderT Context m LogID
create name = do
  flag <- exists name
  if flag
    then
      liftIO $
        throwIO $
          LogStoreLogAlreadyExistsException $ "log " ++ T.unpack name ++ " already existed"
    else do
      Context {..} <- ask
      curDataCf <- liftIO $ RWV.with curDataCFHandleRef return
      R.withWriteBatch $ initLog dbHandle metaCFHandle curDataCf maxLogIdRef
  where
    initLog db metaCf dataCf maxLogIdRef batch = do
      logId <- generateLogId db metaCf maxLogIdRef
      R.batchPutCF batch metaCf (encodeLogName name) (encodeLogId logId)
      R.batchPutCF
        batch
        dataCf
        (encodeEntryKey $ EntryKey logId minEntryId)
        (U.fromString "first entry")
      R.write db def batch
      return logId

-- | append an entry to log
appendEntry :: MonadIO m => LogHandle -> Entry -> ReaderT Context m EntryID
appendEntry LogHandle {..} entry = do
  Context {..} <- ask
  if writeMode openOptions
    then do
      entryId <- generateEntryId maxEntryIdRef
      curDataCf <- liftIO $ RWV.with curDataCFHandleRef return
      R.putCF
        dbHandle
        R.defaultWriteOptions
        curDataCf
        (encodeEntryKey $ EntryKey logID entryId)
        entry
      return entryId
    else
      liftIO $
        throwIO $
          LogStoreUnsupportedOperationException $ "log named " ++ T.unpack logName ++ " is not writable."

appendEntries :: MonadIO m => LogHandle -> V.Vector Entry -> ReaderT Context m (V.Vector EntryID)
appendEntries LogHandle {..} entries = do
  Context {..} <- ask
  curDataCf <- liftIO $ RWV.with curDataCFHandleRef return
  R.withWriteBatch $ appendEntries' dbHandle curDataCf
  where
    appendEntries' db cf batch = do
      entryIds <-
        V.forM
          entries
          batchAdd
      R.write db def batch
      return entryIds
      where
        batchAdd entry = do
          entryId <- generateEntryId maxEntryIdRef
          R.batchPutCF batch cf (encodeEntryKey $ EntryKey logID entryId) entry
          return entryId

readEntries ::
  MonadIO m =>
  LogHandle ->
  Maybe EntryID ->
  Maybe EntryID ->
  ReaderT Context m (Serial (Entry, EntryID))
readEntries LogHandle {..} firstKey lastKey = do
  Context {..} <- ask
  dataCfNames <- getDataCfNameSet dbPath
  streams <- mapM (readEntriesInCf resourcesForReadRef dbPath) dataCfNames
  return $ sconcat $ fromList streams
  where
    readEntriesInCf resRef dbPath dataCfName =
      liftIO $ do
        cfr@CFResourcesForRead {..} <- openCFReadOnly dbPath dataCfName
        atomicModifyIORefCAS resRef (\res -> (res ++ [cfr], res))
        let kvStream = R.rangeCF dbHandleForRead def cfHandleForRead start end
        return $
          kvStream
            & S.map (first decodeEntryKey)
            -- & S.filter (\(EntryKey logId _, _) -> logId == logID)
            & S.map (\(EntryKey _ entryId, entry) -> (entry, entryId))

    start =
      case firstKey of
        Nothing -> Just $ encodeEntryKey $ EntryKey logID firstNormalEntryId
        Just k -> Just $ encodeEntryKey $ EntryKey logID k
    end =
      case lastKey of
        Nothing -> Just $ encodeEntryKey $ EntryKey logID maxEntryId
        Just k -> Just $ encodeEntryKey $ EntryKey logID k

-- | close log
-- |
-- | todo:
-- | what should do when call close?
-- | 1. free resource
-- | 2. once close, should forbid operation on this LogHandle
close :: MonadIO m => LogHandle -> ReaderT Context m ()
close LogHandle {..} = return ()

-- | shutDown and free resources
shutDown :: MonadIO m => ReaderT Context m ()
shutDown = do
  Context {..} <- ask
  liftIO $ cancel backgroundShardingTask
  resRef <- liftIO $ readIORef resourcesForReadRef
  mapM_ releaseCFResourcesForRead resRef
  R.destroyColumnFamily metaCFHandle
  liftIO $ RWV.with curDataCFHandleRef R.destroyColumnFamily
  R.close dbHandle

-- | function that wrap initialize and resource release.
withLogStore :: MonadUnliftIO m => Config -> ReaderT Context m a -> m a
withLogStore cfg r =
  runResourceT
    ( do
        (_, ctx) <-
          allocate
            (initialize cfg)
            (runReaderT shutDown)
        lift $ runReaderT r ctx
    )
