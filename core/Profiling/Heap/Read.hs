{-|

This module defines the functions that access heap profiles both
during and after execution.

-}

module Profiling.Heap.Read
    (
    -- * Reading archived profiles
      readProfile
    , LoadProgress
    , ProfilingStop
    , readProfileAsync
    -- * Profiling running applications 
    , ProfileReader
    , ProfilingType(..)
    , ProfilingCommand
    , ProfilingInfo
    , profile
    , profileCallback
    ) where

-- The imperative bits
import Control.Applicative
import Control.Arrow
import Control.Monad
import Control.Monad.Fix
import Control.Concurrent
import Data.IORef
import System.Directory
import System.FilePath
import System.IO
import System.Process

-- Data structures
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as S
import Data.List
import Data.Maybe
import qualified Data.IntMap as IM
import Data.Trie (Trie)
import qualified Data.Trie as T
import Profiling.Heap.Types

-- Networking
import Network
import Profiling.Heap.Network

-- Stuff needed only to create a time stamp
import Data.Time.LocalTime (getZonedTime)
import Data.Time.Format (formatTime)
import System.Locale (defaultTimeLocale)

{-| The simplest case to handle is the traditional method of taking
the profiler output of an earlier run and turning it into an easy to
query structure. This is done by passing 'readProfile' the log created
by the heap profiler (a file with .hp extension). -}

readProfile :: FilePath -> IO (Maybe Profile)
readProfile file = flip catch (const (return Nothing)) $ do
  hdl <- openFile file ReadMode
  let parse stime prof = do
        stop <- hIsEOF hdl
        if not stop then do
            (stime',prof') <- accumProfile stime prof <$> S.hGetLine hdl
            parse stime' $! prof'
          else return prof

  prof <- parse Nothing emptyProfile
  return $ if null (prJob prof) then Nothing else Just prof

{-| If we want to observe the progress of loading, we can perform the
operation asynchronously. We need a query operation to check the
progress and extract the final result after the whole profile was
loaded. A 'LoadProgress' computation tells us precisely that,
representing progress with a number between 0 and 1. -}

type LoadProgress = IO (Either Double Profile)

{-| A common stopping action that can be used to cancel asynchronous
loading as well as killing the reading thread during live profiling
without touching the slave process. -}

type ProfilingStop = IO ()

{-| Read a heap profile asynchronously. Since we might want to
interrupt the loading process if it proves to be too long, a stopper
action is also returned along with the progress query action. If the
stopper action is executed, the query function will return an empty
profile as a result. -}

readProfileAsync :: FilePath -> IO (LoadProgress,ProfilingStop)
readProfileAsync file = do
  progress <- newIORef (Left 0)
  hdl <- openFile file ReadMode
  totalSize <- fromIntegral <$> hFileSize hdl

  let parse stime prof size = do
        stop <- hIsEOF hdl
        if not stop then do
            line <- S.hGetLine hdl
            let (stime',prof') = accumProfile stime prof line
                size' = size + S.length line + 1
            writeIORef progress . Left $! size'
            prof' `seq` parse stime' prof' size'
          else writeIORef progress (Right prof)

  tid <- forkIO $ parse Nothing emptyProfile 0

  return ( left (\s -> fromIntegral s/totalSize) <$> readIORef progress
         , killThread tid >> writeIORef progress (Right emptyProfile)
         )

{-| Since we want to possibly look at heap profiles during the run, we
might need an action that returns the data recorded so far. -}

type ProfileReader = IO Profile

{-| There are two basic ways of profiling: local and remote.  Local
profiling means that we directly manage the process we are monitoring.
In the case of remote profiling we connect to a server that streams
profiling information and acts as a proxy between the process to
profile and our program.  The type of profiling also determines the
kind of information available to us after initiating the process, so
we need generic labels to distinguish the alternatives. -}

data ProfilingType loc rem = Local { local :: loc }
                           | Remote { remote :: rem }

{-| The input of the profiling functions.  When we start profiling, we
need a process descriptor for the local case or a server address (of
the form \"address:port\") in the remote case.  The creation of the
process descriptor is aided by the "Profiling.Heap.Process" module. -}

type ProfilingCommand = ProfilingType CreateProcess String

{-| The return value of the profiling functions.  In the local case we
are given the handle of the process monitored.  Asking for a remote
profile gives us a handle we can use to communicate with the proxy via
the common protocol defined in the "Profiling.Heap.Network" module. -}

type ProfilingInfo = ProfilingType ProcessHandle Handle

{-| In order to perform real-time profiling, we need to fire up the
program to analyse and create an accumulator in the background that we
can look at whenever we want using the reading action returned by the
function.  We are also given a stopping action and the handle to the
slave process or network connection depending on the type of
profiling.  If there is a problem, 'Nothing' is returned. -}

profile :: ProfilingCommand -> IO (Maybe (ProfileReader,ProfilingStop,ProfilingInfo))
profile prog = do
  let getCmd p = case cmdspec p of
                   ShellCommand cmd -> cmd
                   RawCommand prg args -> intercalate " " (prg:args)
  zt <- getZonedTime
  ref <- newIORef emptyProfile
               { prJob = case prog of 
                           Local desc -> getCmd desc
                           Remote addr -> addr
               -- The time format is deliberately different from the
               -- one currently used in heap profiles. Changing it
               -- doesn't hurt anyone, and it makes more sense this
               -- way, so there.
               , prDate = formatTime defaultTimeLocale "%F %H:%M:%S %Z" zt
               }
  (fmap.fmap) (\(stop,info) -> (readIORef ref,stop,info)) $ profileCallback prog $ \pkg -> do
    prof <- readIORef ref
    case pkg of
      SinkSample t smp   -> writeIORef ref $ prof
                            { prSamples = (t,smp) : prSamples prof }
      SinkId ccid ccname -> writeIORef ref $ prof
                            { prNames = IM.insert ccid ccname (prNames prof) }
      _                  -> return ()

{-| The 'profileCallback' function initiates an observation without
maintaining any internal data other than the name mapping, passing
profile samples to the callback (provided in the second argument) as
they come.  It returns the handle of the new process or the remote
connection as well as the thread stopper action, assuming that a heap
profile could be found. -}

profileCallback :: ProfilingCommand -> ProfileSink -> IO (Maybe (ProfilingStop,ProfilingInfo))
profileCallback (Local prog) sink = do
  dir <- getCurrentDirectory
  let hpPath = fromMaybe dir (cwd prog) ++
               '/' : (takeFileName . execPath . cmdspec) prog ++ ".hp"
      -- Yes, this is extremely naive, but it will do for the time being...
      execPath (ShellCommand cmd) = takeWhile (/=' ') cmd
      execPath (RawCommand path _) = path

  -- We have to delete the .hp file and wait for the process to create it.
  catch (removeFile hpPath) (const (return ()))
  (_,_,_,phdl) <- createProcess prog

  maybeHpFile <- tryRepeatedly (openFile hpPath ReadMode) 50 10000

  case maybeHpFile of
    Nothing -> return Nothing
    Just hpFile -> do
      -- Question: do we want an alternative single-threaded interface?
      tid <- forkIO $ do
        let pass buf idmap smp = do
              case S.elemIndex '\n' buf of
                -- If there's a whole line in the buffer and we still
                -- have the green light, we'll parse it and notify the
                -- callback (sink) if necessary.
                Just len -> do
                  let (line,rest) = S.splitAt len buf
                      -- Getting rid of the line break after the first
                      -- line.
                      next = pass (S.drop 1 rest)
      
                  case parseHpLine line of
                    -- Initialising a new empty sample.
                    BeginSample _ -> next idmap []
                    -- Sending non-empty sample and forgetting it.
                    EndSample t -> do
                      when (not (null smp)) $ sink (SinkSample t smp)
                      next idmap []
                    -- Adding a cost to the current sample and checking if
                    -- we already know the name of the cost centre.
                    Cost ccname cost -> do
                      let (newid,ccid,idmap') = addCCId idmap ccname
                      when newid $ sink (SinkId ccid ccname)
                      next idmap' ((ccid,cost):smp)
                    _ -> next idmap smp
      
                -- If there's no line known to be full while the other
                -- process is still running, we keep trying to fetch more
                -- data.
                Nothing -> do
                  -- Checking if there is still hope for more data.
                  slaveCode <- getProcessExitCode phdl
      
                  if slaveCode == Nothing then do
                      eof <- hIsEOF hpFile
                      if eof then do
                          threadDelay 100000
                          pass buf idmap smp
                        else do
                          newChars <- S.hGetNonBlocking hpFile 0x10000
                          pass (S.append buf newChars) idmap smp
                    -- The other process ended, let's notify the callback.
                    else sink SinkStop
      
        pass S.empty T.empty []
      
      return (Just (profileStop tid sink,Local phdl))

profileCallback (Remote server) sink = do
  -- Yeah, we might need some error handling here...
  let (addr,_:port) = span (/=':') server
      portNum :: Int
      portNum = read port
  hdl <- connectTo addr ((PortNumber . fromIntegral) portNum)
  hSetBuffering hdl LineBuffering

  tid <- forkIO . fix $ \readLoop -> do
    -- We assume line buffering here. Also, if there seems to be
    -- any error, the profile reader is stopped.
    msg <- catch (readMsg <$> hGetLine hdl) (const . return . Just . Stream $ SinkStop)
    case msg >>= getStream of
      Just profSmp -> do
        sink profSmp
        when (profSmp /= SinkStop) readLoop
      Nothing -> readLoop

  return (Just (profileStop tid sink,Remote hdl))

profileStop :: ThreadId -> ProfileSink -> IO ()
profileStop tid sink = do
  killThread tid
  -- The sink is notified asynchronously, since it might be a blocking
  -- operation (like the MVar operations used by the grapher).
  forkIO (sink SinkStop)
  return ()

tryRepeatedly :: IO a -> Int -> Int -> IO (Maybe a)
tryRepeatedly act n d | n < 1     = return Nothing
                      | otherwise = catch (Just <$> act) (const retry)
    where retry = do threadDelay d
                     tryRepeatedly act (n-1) d

{-

JOB "command"
DATE "date"
SAMPLE_UNIT "..."
VALUE_UNIT "..."
BEGIN_SAMPLE t1
ccname1<tab>cost1
ccname2<tab>cost2
...
END_SAMPLE t1
BEGIN_SAMPLE t2
...
-}

-- The information we care about.
data ParseResult = Unknown
                 | Job String
                 | Date String
                 | BeginSample Time
                 | EndSample Time
                 | Cost CostCentreName Cost

-- Parse a single line of a .hp file.
parseHpLine :: ByteString -> ParseResult
parseHpLine line
    | S.null cost = head ([val | (key,val) <- results, key == cmd] ++ [Unknown])
    | otherwise   = Cost ccname (read . S.unpack . S.tail $ cost)
    where (ccname,cost) = S.span (/='\t') line
          (cmd,sparam) = S.span (/=' ') line
          param = S.unpack (S.tail sparam)
          results = if S.null sparam then [] else
                        [(S.pack "JOB",Job (read param)),
                         (S.pack "DATE",Date (read param)),
                         (S.pack "BEGIN_SAMPLE",BeginSample (read param)),
                         (S.pack "END_SAMPLE",EndSample (read param))]

-- Accumulate the results of parsing a single line.
accumProfile :: Maybe Time -> Profile -> ByteString -> (Maybe Time,Profile)
accumProfile time prof line = case parseHpLine line of
  Job s            -> (Nothing,prof { prJob = s })
  Date s           -> (Nothing,prof { prDate = s })
  BeginSample t    -> (Just t,prof)
  EndSample _      -> (Nothing,prof)
  Cost ccname cost -> let (newid,ccid,pnsi') = addCCId (prNamesInv prof) ccname
                          t = fromJust time
                          smps = prSamples prof
                          smps' | null smps = [(t,[(ccid,cost)])]
                                | otherwise = if t == fst (head smps) then
                                                  (fmap ((ccid,cost):) (head smps)) : tail smps
                                              else (t,[(ccid,cost)]) : smps
                      in (time,
                          prof
                          { prSamples = smps'
                          , prNames = if newid then IM.insert ccid ccname (prNames prof) else prNames prof
                          , prNamesInv = pnsi'
                          })
  Unknown          -> (Nothing,prof)

-- Get the id of a name, creating a new one when needed.
addCCId :: Trie CostCentreId -> CostCentreName -> (Bool, CostCentreId, Trie CostCentreId)
addCCId idmap ccname = if ccid /= T.size idmap then (False,ccid,idmap)
                       else (True,ccid,T.insert ccname ccid idmap)
    where ccid = fromMaybe (T.size idmap) (T.lookup ccname idmap)

-- Some tests --

-- For the time being, we assume that getCurrentDirectory returns the
-- dir of the cabal file, because we love emacs.

-- Callback test (also: stopTest <- fst . fromJust <$> _test1)
_test1 :: IO (Maybe (ProfilingStop,ProfilingInfo))
_test1 = do
  dir <- getCurrentDirectory
  profileCallback (Local (shell (dir++"/test/tester")) { cwd = Just (dir++"/test") }) print

-- Accumulation test
_test2 :: IO ()
_test2 = do
  dir <- getCurrentDirectory
  Just (reader,_,_) <- profile (Local (shell (dir++"/test/tester")) { cwd = Just (dir++"/test") })
  replicateM_ 5 $ do
    prof <- reader
    print prof
    threadDelay 1000000

-- Archive test
_test3 :: IO Profile
_test3 = do
  dir <- getCurrentDirectory
  fromJust <$> (readProfile $ dir ++ "/test/example.hp")
