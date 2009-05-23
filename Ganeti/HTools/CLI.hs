{-| Implementation of command-line functions.

This module holds the common cli-related functions for the binaries,
separated into this module since Utils.hs is used in many other places
and this is more IO oriented.

-}

module Ganeti.HTools.CLI
    ( CLIOptions(..)
    , EToolOptions(..)
    , parseOpts
    , parseEnv
    , shTemplate
    , loadExternalData
    ) where

import System.Console.GetOpt
import System.Posix.Env
import System.IO
import System.Info
import System
import Monad
import Text.Printf (printf)
import qualified Data.Version

import qualified Ganeti.HTools.Version as Version(version)
import qualified Ganeti.HTools.Rapi as Rapi
import qualified Ganeti.HTools.Text as Text
import qualified Ganeti.HTools.Loader as Loader

import Ganeti.HTools.Types

-- | Class for types which support show help and show version
class CLIOptions a where
    showHelp    :: a -> Bool
    showVersion :: a -> Bool

-- | Class for types which support the -i/-n/-m options
class EToolOptions a where
    nodeFile   :: a -> FilePath
    nodeSet    :: a -> Bool
    instFile   :: a -> FilePath
    instSet    :: a -> Bool
    masterName :: a -> String
    silent     :: a -> Bool

-- | Command line parser, using the 'options' structure.
parseOpts :: (CLIOptions b) =>
             [String]            -- ^ The command line arguments
          -> String              -- ^ The program name
          -> [OptDescr (b -> b)] -- ^ The supported command line options
          -> b                   -- ^ The default options record
          -> IO (b, [String])    -- ^ The resulting options a leftover
                                 -- arguments
parseOpts argv progname options defaultOptions =
    case getOpt Permute options argv of
      (o, n, []) ->
          do
            let resu@(po, _) = (foldl (flip id) defaultOptions o, n)
            when (showHelp po) $ do
              putStr $ usageInfo header options
              exitWith ExitSuccess
            when (showVersion po) $ do
              printf "%s %s\ncompiled with %s %s\nrunning on %s %s\n"
                     progname Version.version
                     compilerName (Data.Version.showVersion compilerVersion)
                     os arch
              exitWith ExitSuccess
            return resu
      (_, _, errs) ->
          ioError (userError (concat errs ++ usageInfo header options))
      where header = printf "%s %s\nUsage: %s [OPTION...]"
                     progname Version.version progname

-- | Parse the environment and return the node/instance names.
-- This also hardcodes here the default node/instance file names.
parseEnv :: () -> IO (String, String)
parseEnv () = do
  a <- getEnvDefault "HTOOLS_NODES" "nodes"
  b <- getEnvDefault "HTOOLS_INSTANCES" "instances"
  return (a, b)

-- | A shell script template for autogenerated scripts
shTemplate :: String
shTemplate =
    printf "#!/bin/sh\n\n\
           \# Auto-generated script for executing cluster rebalancing\n\n\
           \# To stop, touch the file /tmp/stop-htools\n\n\
           \set -e\n\n\
           \check() {\n\
           \  if [ -f /tmp/stop-htools ]; then\n\
           \    echo 'Stop requested, exiting'\n\
           \    exit 0\n\
           \  fi\n\
           \}\n\n"

-- | External tool data loader from a variety of sources
loadExternalData :: (EToolOptions a) =>
                    a
                 -> IO (NodeList, InstanceList, String, NameList, NameList)
loadExternalData opts = do
  (env_node, env_inst) <- parseEnv ()
  let nodef = if nodeSet opts then nodeFile opts
              else env_node
      instf = if instSet opts then instFile opts
              else env_inst
  input_data <-
      case masterName opts of
        "" -> Text.loadData nodef instf
        host -> Rapi.loadData host

  let ldresult = input_data >>= Loader.mergeData
  (loaded_nl, il, csf, ktn, kti) <-
      (case ldresult of
         Ok x -> return x
         Bad s -> do
           printf "Error: failed to load data. Details:\n%s\n" s
           exitWith $ ExitFailure 1
      )
  let (fix_msgs, fixed_nl) = Loader.checkData loaded_nl il ktn kti

  unless (null fix_msgs || silent opts) $ do
         putStrLn "Warning: cluster has inconsistent data:"
         putStrLn . unlines . map (\s -> printf "  - %s" s) $ fix_msgs

  return (fixed_nl, il, csf, ktn, kti)
