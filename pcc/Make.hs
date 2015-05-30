-----------------------------------------------------------------------------
--
-- Module      :  Make
-- Copyright   :  (c) 2013-14 Phil Freeman, (c) 2014 Gary Burgess, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Andy Arvanitis
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell #-}

module Make
  ( Make(..)
  , runMake
  , buildMakeActions
  ) where

import Control.Applicative
import Control.Monad
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Trans.Except
import Control.Monad.Reader
import Control.Monad.Writer

import Data.FileEmbed (embedFile)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Time.Clock
import Data.Traversable (traverse)
import Data.Version (showVersion)
import qualified Data.Map as M
import qualified Data.ByteString.UTF8 as BU

import System.Directory (doesDirectoryExist, doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory, addExtension, dropExtension, takeExtension)
import System.IO.Error (tryIOError)

import qualified Language.PureScript as P
import qualified Language.PureScript.CodeGen.Cpp as CPP
import qualified Language.PureScript.CoreFn as CF
import qualified Language.PureScript.Core as CR
import qualified Language.PureScript.CoreImp as CI
import qualified Paths_purescript as Paths

newtype Make a = Make { unMake :: ReaderT (P.Options P.Make) (WriterT P.MultipleErrors (ExceptT P.MultipleErrors IO)) a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadError P.MultipleErrors, MonadWriter P.MultipleErrors, MonadReader (P.Options P.Make))

runMake :: P.Options P.Make -> Make a -> IO (Either P.MultipleErrors (a, P.MultipleErrors))
runMake opts = runExceptT . runWriterT . flip runReaderT opts . unMake

makeIO :: (IOError -> P.ErrorMessage) -> IO a -> Make a
makeIO f io = do
  e <- liftIO $ tryIOError io
  either (throwError . P.singleError . f) return e

-- Traverse (Either e) instance (base 4.7)
traverseEither :: Applicative f => (a -> f b) -> Either e a -> f (Either e b)
traverseEither _ (Left x) = pure (Left x)
traverseEither f (Right y) = Right <$> f y

buildMakeActions :: FilePath
                 -> M.Map P.ModuleName (Either P.RebuildPolicy String)
                 -> Bool
                 -> P.MakeActions Make
buildMakeActions outputDir filePathMap usePrefix =
  P.MakeActions getInputTimestamp getOutputTimestamp readExterns codegen progress
  where

  getInputFile :: P.ModuleName -> FilePath
  getInputFile mn =
    let path = fromMaybe (error "Module has no filename in 'make'") $ M.lookup mn filePathMap in
    case path of
      Right path' -> path'
      Left _ -> error  "Module has no filename in 'make'"

  getInputTimestamp :: P.ModuleName -> Make (Either P.RebuildPolicy (Maybe UTCTime))
  getInputTimestamp mn = do
    let path = fromMaybe (error "Module has no filename in 'make'") $ M.lookup mn filePathMap
    traverseEither getTimestamp path

  getOutputTimestamp :: P.ModuleName -> Make (Maybe UTCTime)
  getOutputTimestamp mn = do

    let filePath = dotsTo '/' $ P.runModuleName mn
        fileBase = outputDir </> filePath </> (last . words . dotsTo ' ' $ P.runModuleName mn)
        srcFile = addExtension fileBase "cc"
        headerFile = addExtension fileBase "hh"
        externsFile = outputDir </> filePath </> "externs.purs"
    min <$> getTimestamp srcFile <*> getTimestamp externsFile

  readExterns :: P.ModuleName -> Make (FilePath, String)
  readExterns mn = do
    let path = outputDir </> (dotsTo '/' $ P.runModuleName mn) </> "externs.purs"
    (path, ) <$> readTextFile path

  codegen :: CR.Module (CF.Bind CR.Ann) P.ForeignCode -> P.Environment -> P.SupplyVar -> P.Externs -> Make ()
  codegen m env nextVar exts = do
    let mn = CR.moduleName m
    let filePath = dotsTo '/' $ P.runModuleName mn
        fileBase = outputDir </> filePath </> (last . words . dotsTo ' ' $ P.runModuleName mn)
        srcFile = addExtension fileBase "cc"
        headerFile = addExtension fileBase "hh"
        externsFile = outputDir </> filePath </> "externs.purs"
        prefix = ["Generated by pcc version " ++ showVersion Paths.version | usePrefix]
    cpps <- P.evalSupplyT nextVar $ (CI.moduleToCoreImp >=> CPP.moduleToCpp env) m
    let (hdrs,srcs) = span (/= CPP.CppEndOfHeader) cpps
    psrcs <- CPP.prettyPrintCpp <$> pure srcs
    phdrs <- CPP.prettyPrintCpp <$> pure hdrs
    let src = unlines $ map ("// " ++) prefix ++ [psrcs]
        hdr = unlines $ map ("// " ++) prefix ++ [phdrs]
    writeTextFile srcFile src
    writeTextFile headerFile hdr
    writeTextFile externsFile exts

    let supportDir = outputDir </> "PureScript"
    supportFilesExist <- dirExists supportDir
    when (not supportFilesExist) $ do
      writeTextFile (outputDir  </> "CMakeLists.txt") cmakeListsTxt
      writeTextFile (supportDir </> "any_map.hh")     $ BU.toString $(embedFile "pcc/include/any_map.hh")
      writeTextFile (supportDir </> "bind.hh")        $ BU.toString $(embedFile "pcc/include/bind.hh")
      writeTextFile (supportDir </> "memory.hh")      $ BU.toString $(embedFile "pcc/include/memory.hh")
      writeTextFile (supportDir </> "PureScript.hh")  $ BU.toString $(embedFile "pcc/include/purescript.hh")
      writeTextFile (supportDir </> "shared_list.hh") $ BU.toString $(embedFile "pcc/include/shared_list.hh")

    when (requiresForeign m) $ do
      let inputPath = dropExtension $ getInputFile mn
          hfile = addExtension inputPath "hh"
          sfile = addExtension inputPath "cc"
      hfileExists <- textFileExists hfile
      when (not hfileExists) (throwError . P.errorMessage $ P.MissingFFIModule mn)
      text <- readTextFile hfile
      writeTextFile (addExtension (fileBase ++ "_ffi") "hh") text
      sfileExists <- textFileExists sfile
      when (sfileExists) $ do
        text <- readTextFile sfile
        writeTextFile (addExtension (fileBase ++ "_ffi") "cc") text

  requiresForeign :: CR.Module a b -> Bool
  requiresForeign = not . null . CR.moduleForeign

  dirExists :: FilePath -> Make Bool
  dirExists path = makeIO (const (P.SimpleErrorWrapper $ P.CannotReadFile path)) $ do
    doesDirectoryExist path

  textFileExists :: FilePath -> Make Bool
  textFileExists path = makeIO (const (P.SimpleErrorWrapper $ P.CannotReadFile path)) $ do
    doesFileExist path

  getTimestamp :: FilePath -> Make (Maybe UTCTime)
  getTimestamp path = makeIO (const (P.SimpleErrorWrapper $ P.CannotGetFileInfo path)) $ do
    exists <- doesFileExist path
    traverse (const $ getModificationTime path) $ guard exists

  readTextFile :: FilePath -> Make String
  readTextFile path = makeIO (const (P.SimpleErrorWrapper $ P.CannotReadFile path)) $ do
    putStrLn $ "Reading " ++ path
    readFile path

  writeTextFile :: FilePath -> String -> Make ()
  writeTextFile path text = makeIO (const (P.SimpleErrorWrapper $ P.CannotWriteFile path)) $ do
    mkdirp path
    putStrLn $ "Writing " ++ path
    writeFile path text
    where
    mkdirp :: FilePath -> IO ()
    mkdirp = createDirectoryIfMissing True . takeDirectory

  progress :: String -> Make ()
  progress = liftIO . putStrLn

dotsTo :: Char -> String -> String
dotsTo chr = map (\c -> if c == '.' then chr else c)

-- TODO: quick and dirty for now -- explicit file list would be better
cmakeListsTxt :: String
cmakeListsTxt = intercalate "\n" lines'
  where lines' = [ "cmake_minimum_required (VERSION 3.0)"
                 , "project (Main)"
                 , "file (GLOB_RECURSE SRCS *.cc)"
                 , "file (GLOB_RECURSE HDRS *.hh)"
                 , "add_executable (Main ${SRCS} ${HDRS})"
                 , "include_directories (${CMAKE_CURRENT_SOURCE_DIR})"
                 , "set (CMAKE_CXX_FLAGS ${CMAKE_CXX_FLAGS} \"-std=c++14\")"
                 ]
