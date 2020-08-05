{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async.Lifted (async, mapConcurrently_, wait)
import Control.Exception (throwIO)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Reader (ReaderT)
import Data.Atomics (atomicModifyIORefCAS)
import qualified Data.ByteString as B
import qualified Data.HashMap.Strict as H
import Data.IORef (IORef, newIORef)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Word (Word64)
import Log.Store.Base
import qualified Streamly.Internal.Data.Fold as FL
import qualified Streamly.Prelude as S
import System.Clock (Clock (Monotonic), TimeSpec (..), getTime)
import System.Console.CmdArgs.Implicit

data Options
  = Append
      { dbPath :: FilePath,
        logNamePrefix :: T.Text,
        totalSize :: Int,
        batchSize :: Int,
        entrySize :: Int,
        logNum :: Int
      }
  | Read
      { dbPath :: FilePath,
        logName :: LogName
      }
  | Mix
      { dbPath :: FilePath,
        logNamePrefix :: T.Text,
        writeTotalSize :: Int,
        writeBatchSize :: Int,
        writeEntrySize :: Int,
        readBatchSize :: Int,
        logNum :: Int
      }
  deriving (Show, Data, Typeable)

appendOpts =
  Append
    { totalSize = 100 &= help "total kv sizes ready to append to a single log (MB)",
      batchSize = 64 &= help "number of entries in a batch",
      entrySize = 128 &= help "size of each entry (byte)",
      dbPath = "/tmp/rocksdb" &= help "which to store data",
      logNamePrefix = "log" &= help "name prefix of logs to write",
      logNum = 1 &= help "num of log to write"
    }
    &= help "append"

readOpts =
  Read
    { dbPath = "/tmp/rocksdb" &= help "db path",
      logName = "log" &= help "name of log to read"
    }
    &= help "read"

mixOpts =
  Mix
    { writeTotalSize = 1024 &= help "total kv sizes ready to append to a single log (MB)",
      writeBatchSize = 64 &= help "number of entries in a batch",
      writeEntrySize = 128 &= help "size of each entry (byte)",
      readBatchSize = 1024 &= help "num of entry each read",
      dbPath = "/tmp/rocksdb" &= help "which to store data",
      logNamePrefix = "log" &= help "name prefix of logs to write",
      logNum = 1 &= help "num of log to write"
    }
    &= help "mix"

main :: IO ()
main = do
  opts <- cmdArgs (modes [appendOpts, readOpts, mixOpts])
  case opts of
    Append {..} -> do
      numRef <- newIORef (0 :: Integer)
      let dict = H.singleton appendedEntryNumKey numRef
      printAppendSpeed dict entrySize
      withLogStore
        Config
          { rootDbPath = dbPath,
            dataCfWriteBufferSize = 200 * 1024 * 1024,
            dbWriteBufferSize = 0,
            enableDBStatistics = True,
            dbStatsDumpPeriodSec = 2
          }
        (mapConcurrently_ (appendTask dict totalSize entrySize batchSize . T.append logNamePrefix . T.pack . show) [1 .. logNum])
    Read {..} ->
      withLogStore
        Config
          { rootDbPath = dbPath,
            dataCfWriteBufferSize = 200 * 1024 * 1024,
            dbWriteBufferSize = 0,
            enableDBStatistics = True,
            dbStatsDumpPeriodSec = 30
          }
        ( do
            lh <- open logName defaultOpenOptions
            -- drainAll lh
            drainBatch 1024 lh
        )
    Mix {..} -> do
      appendedNumRef <- newIORef (0 :: Integer)
      readNumRef <- newIORef (0 :: Integer)
      let dict = H.insert readEntryNumKey readNumRef $ H.singleton appendedEntryNumKey appendedNumRef
      printAppendAndReadSpeed dict writeEntrySize
      withLogStore
        Config
          { rootDbPath = dbPath,
            dataCfWriteBufferSize = 200 * 1024 * 1024,
            dbWriteBufferSize = 0,
            enableDBStatistics = True,
            dbStatsDumpPeriodSec = 2
          }
        ( do
            appendResult <- async (mapConcurrently_ (appendTask dict writeTotalSize writeEntrySize writeBatchSize . T.append logNamePrefix . T.pack . show) [1 .. logNum])
            liftIO $ threadDelay 10000000
            readResult <- async (mapConcurrently_ (readTask dict readBatchSize . T.append logNamePrefix . T.pack . show) [1 .. logNum])
            wait appendResult
            wait readResult
        )

appendTask ::
  MonadIO m =>
  H.HashMap B.ByteString (IORef Integer) ->
  Int ->
  Int ->
  Int ->
  LogName ->
  ReaderT Context m ()
appendTask dict totalSize entrySize batchSize logName = do
  lh <- open logName defaultOpenOptions {createIfMissing = True, writeMode = True}
  let batchNum = (totalSize * 1024 * 1024) `div` (batchSize * entrySize)
  writeNBytesEntriesBatch dict lh entrySize batchSize batchNum
  return ()

readTask ::
  MonadIO m =>
  H.HashMap B.ByteString (IORef Integer) ->
  Int ->
  LogName ->
  ReaderT Context m ()
readTask dict batchSize logName = do
  lh <- open logName defaultOpenOptions
  readBatch lh 1 $ fromIntegral batchSize
  where
    readBatch :: MonadIO m => LogHandle -> EntryID -> EntryID -> ReaderT Context m ()
    readBatch lh start end = do
      stream <- readEntries lh (Just start) (Just end)
      readNum <- liftIO $ S.length stream
      if readNum == 0
        then do
          liftIO $ threadDelay 10000
          readBatch lh start end
        else do
          increaseBy dict readEntryNumKey $ toInteger readNum
          let nextStart = start + fromIntegral readNum
          let nextEnd = nextStart + fromIntegral batchSize - 1
          readBatch lh nextStart nextEnd

-- record read speed
drainAll :: MonadIO m => LogHandle -> ReaderT Context m ()
drainAll lh = do
  stream <- readEntries lh Nothing Nothing
  -- liftIO $ S.drain stream
  liftIO $ S.mapM_ (print . fromIntegral) $ S.intervalsOf 1 FL.length stream

drainBatch :: MonadIO m => EntryID -> LogHandle -> ReaderT Context m ()
drainBatch batchSize lh = drainBatch' 1 batchSize TimeSpec {sec = 0, nsec = 0} 0
  where
    sampleDuration = TimeSpec {sec = 1, nsec = 0}

    drainBatch' :: MonadIO m => EntryID -> EntryID -> TimeSpec -> Word64 -> ReaderT Context m ()
    drainBatch' start end remainingTime accItem = do
      startTime <- liftIO $ getTime Monotonic
      stream <- readEntries lh (Just start) (Just end)
      readNum <- liftIO $ S.length stream
      endTime <- liftIO $ getTime Monotonic
      let duration = endTime - startTime + remainingTime
      let total = accItem + fromIntegral readNum
      if duration >= sampleDuration
        then do
          liftIO $ print total
          drainBatch' (end + 1) (end + batchSize) 0 0
        else drainBatch' (end + 1) (end + batchSize) duration total

nBytesEntry :: Int -> B.ByteString
nBytesEntry n = B.replicate n 0xff

appendedEntryNumKey :: B.ByteString
appendedEntryNumKey = "appendedEntryNum"

readEntryNumKey :: B.ByteString
readEntryNumKey = "readEntryNum"

writeNBytesEntriesBatch ::
  MonadIO m =>
  H.HashMap B.ByteString (IORef Integer) ->
  LogHandle ->
  Int ->
  Int ->
  Int ->
  ReaderT Context m ()
writeNBytesEntriesBatch dict lh entrySize batchSize batchNum = write' lh 1
  where
    write' lh x =
      if x == batchNum
        then do
          appendEntries lh $ V.replicate batchSize entry
          increaseBy dict appendedEntryNumKey $ toInteger batchSize
          return ()
        else do
          appendEntries lh $ V.replicate batchSize entry
          increaseBy dict appendedEntryNumKey $ toInteger batchSize
          write' lh (x + 1)
    entry = nBytesEntry entrySize

increaseBy ::
  MonadIO m =>
  H.HashMap B.ByteString (IORef Integer) ->
  B.ByteString ->
  Integer ->
  m Integer
increaseBy dict key num = liftIO $ do
  let r = H.lookup key dict
  case r of
    Nothing -> throwIO $ userError "error"
    Just v ->
      atomicModifyIORefCAS v (\curNum -> (curNum + num, curNum + num))

periodRun :: Int -> Int -> IO a -> IO ()
periodRun initDelay interval action = do
  forkIO $ do
    threadDelay $ initDelay * 1000
    forever $ do
      threadDelay $ interval * 1000
      action
  return ()

printAppendSpeed :: H.HashMap B.ByteString (IORef Integer) -> Int -> IO ()
printAppendSpeed dict entrySize = do
  forkIO $ do
    printSpeed 0
  return ()
  where
    printSpeed num = do
      threadDelay 3000000
      curNum <- increaseBy dict appendedEntryNumKey 0
      print $ fromInteger ((curNum - num) * toInteger entrySize) / 1024 / 1024 / 3
      printSpeed curNum

printAppendAndReadSpeed :: H.HashMap B.ByteString (IORef Integer) -> Int -> IO ()
printAppendAndReadSpeed dict entrySize = do
  forkIO $ do
    printSpeed 0 0
  return ()
  where
    printSpeed prevAppendedNum prevReadNum = do
      threadDelay 3000000
      curAppendedNum <- increaseBy dict appendedEntryNumKey 0
      curReadNum <- increaseBy dict readEntryNumKey 0
      putStrLn $
        "append: "
          ++ show (fromInteger ((curAppendedNum - prevAppendedNum) * toInteger entrySize) / 1024 / 1024 / 3)
          ++ " MB/s, "
          ++ "read: "
          ++ show (fromInteger ((curReadNum - prevReadNum) * toInteger entrySize) / 1024 / 1024 / 3)
          ++ " MB/s"
      printSpeed curAppendedNum curReadNum
