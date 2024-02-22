{- Copyright 2016-2024 NGLess Authors
 - License: MIT
 -}


module BuiltinModules.Checks
    ( checkOFile
    , loadModule
    ) where

import qualified Data.Text as T
import           Data.Default (def)
import Control.Monad.Extra (whenJust)
import Control.Monad
import Control.Monad.IO.Class
import System.Directory
import System.FilePath (takeDirectory)


import Language

import Modules
import Output
import NGLess
import Data.FastQ (FastQFilePath(..))
import           Utils.Suggestion (checkFileReadable)

checkOFile :: T.Text -> IO (Maybe T.Text)
checkOFile ofile = do
    let dirname = takeDirectory (T.unpack ofile)
    exists <- doesDirectoryExist dirname
    if not exists
        then return . Just $! T.concat ["File name '", ofile, "' used as output, but directory ", T.pack dirname, " does not exist."]
        else do
            canWrite <- writable <$> getPermissions dirname
            return $! if canWrite
                    then Nothing
                    else Just (T.concat ["write call to file ", ofile, ", but directory ", T.pack dirname, " is not writable."])


executeChecks :: T.Text -> NGLessObject -> KwArgsValues -> NGLessIO NGLessObject
executeChecks "__check_ofile" expr args = do
    oname <- stringOrTypeError "output file check" expr
    lno <- lookupIntegerOrScriptError "o file lno" "original_lno" args
    liftIO (checkOFile oname) >>= \case
        Nothing -> return NGOVoid
        Just err -> throwSystemError $! concat [T.unpack err, " (used in line ", show lno, ")."]
executeChecks "__check_ifile" expr args = do
    fname <- filepathOrTypeError "checking input file" expr
    lno <- lookupIntegerOrScriptError "input file lno" "original_lno" args
    merr <- liftIO (checkFileReadable fname)
    whenJust merr $ \err ->
        throwSystemError $! concat [T.unpack err, " (used in line ", show lno, ")."]
    return NGOVoid

executeChecks "__check_index_access" (NGOList vs) args = do
    lno <- lookupIntegerOrScriptError "index access check" "original_lno" args
    index1 <- lookupIntegerOrScriptError "index access check" "index1" args
    when (fromInteger index1 >= length vs) $
        throwScriptError (concat ["Index access on line ", show lno, " is invalid.\n Accessing element with index ", show index1,
                    " but list only has ", show (length vs), " elements.",
                    (if fromInteger index1 == length vs
                        then "\nPlease note that NGLess uses 0-based indexing."
                        else "")
                    ])
    return NGOVoid

executeChecks "__check_readset" (NGOReadSet name (ReadSet pairs singles)) args = do
    lno <- lookupIntegerOrScriptError "readset check" "original_lno" args
    let catPairs [] = []
        catPairs ((a,b):xs) = a:b:catPairs xs
    forM_ (catPairs pairs ++ singles) $ \(FastQFilePath _ r) -> do
        outputListLno TraceOutput (Just $ fromEnum lno) ["Checking file ", r, "."]
        merr <- liftIO (checkFileReadable r)
        whenJust merr $ \err ->
            throwSystemError $! concat ["Cannot read file '", r, "' for sample '", T.unpack name, "'. ",
                                T.unpack err, " (used in line ", show lno, ")."]
    return NGOVoid
executeChecks _ _ _ = throwShouldNotOccur "checks called in an unexpected fashion."

indexCheck = Function
    { funcName = FuncName "__check_index_access"
    , funcArgType = Nothing
    , funcArgChecks = []
    , funcRetType = NGLVoid
    , funcKwArgs =
                [ArgInformation "original_lno" True NGLInteger []
                ,ArgInformation "index1" True NGLInteger []]
    , funcAllowsAutoComprehension = False
    , funcChecks = []
    }

oFileCheck = Function
    { funcName = FuncName "__check_ofile"
    , funcArgType = Just NGLString
    , funcArgChecks = []
    , funcRetType = NGLVoid
    , funcKwArgs = [ArgInformation "original_lno" True NGLInteger []]
    , funcAllowsAutoComprehension = False
    , funcChecks = []
    }

iFileCheck = Function
    { funcName = FuncName "__check_ifile"
    , funcArgType = Just NGLString
    , funcArgChecks = []
    , funcRetType = NGLVoid
    , funcKwArgs = [ArgInformation "original_lno" True NGLInteger []]
    , funcAllowsAutoComprehension = False
    , funcChecks = []
    }
iRSCheck = Function
    { funcName = FuncName "__check_readset"
    , funcArgType = Just NGLReadSet
    , funcArgChecks = []
    , funcRetType = NGLVoid
    , funcKwArgs = [ArgInformation "original_lno" True NGLInteger []]
    , funcAllowsAutoComprehension = False
    , funcChecks = []
    }

loadModule :: T.Text -> NGLessIO Module
loadModule _ = return def
    { modInfo = ModInfo "builtin.checks" "0.0"
    , modFunctions = [oFileCheck, iFileCheck, indexCheck, iRSCheck]
    , runFunction = executeChecks
    }

