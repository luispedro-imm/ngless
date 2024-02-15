{- Copyright 2013-2022 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE TemplateHaskell, QuasiQuotes, CPP #-}
module FileManagement
    ( InstallMode(..)
    , createTempDir
    , openNGLTempFile
    , openNGLTempFile'
    , makeNGLTempFile
    , removeIfTemporary
    , setupHtmlViewer
    , takeBaseNameNoExtensions

    , samtoolsBin
    , prodigalBin
    , megahitBin
    , bwaBin
    , minimap2Bin
    , expandPath

    , inferCompression
    , ensureCompressionIsOneOf
    , Compression(..)

#ifdef IS_BUILDING_TEST
    , expandPath'
#endif
    ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar
import qualified Codec.Compression.GZip as GZip
import qualified Text.RE.TDFA.String as RE
import qualified System.FilePath as FP
import qualified Data.Conduit.Algorithms.Async as CAlg
import qualified Conduit as C
import           Conduit ((.|))
import           System.FilePath (takeDirectory, (</>), (<.>), (-<.>))
import           Control.Monad (unless, forM_, when)
import           Control.Monad.Extra (firstJustM)
import           System.Posix.Files (setFileMode, createSymbolicLink)
import           System.Posix.Internals (c_getpid)
import           Data.List (isSuffixOf, isPrefixOf)
import Data.List.NonEmpty qualified as NE

import qualified System.Directory as SD
import System.IO
import System.IO.Error
import Control.Exception
import System.Environment (getExecutablePath, lookupEnv)
import Control.Monad.Trans.Resource
import Control.Monad.IO.Class (liftIO)
import Data.Maybe

import Configuration
import Version (versionStr)

import Data.FileEmbed (embedDir)
import Output
import NGLess.NGLEnvironment
import qualified Dependencies.Embedded as Deps
import NGLess.NGError
import Utils.LockFile
import Utils.Utils (withOutputFile)


{- Note on temporary files
 -
 - A big part of this module is handling temporary files. By generating
 - temporary files with the functions in this module, one guarantees that user
 - settings (wrt where to store files, whether to keep them, &c) are respected.
 - It also enables garbage collection.
 -
 -}

data InstallMode = User | Root deriving (Eq, Show)

data Compression = NoCompression
                | GzipCompression
                | BZ2Compression
                | XZCompression
                | ZStdCompression
                deriving (Eq)

inferCompression :: FilePath -> Compression
inferCompression fp
    | isSuffixOf ".gz" fp = GzipCompression
    | isSuffixOf ".bz2" fp = BZ2Compression
    | isSuffixOf ".xz"  fp = XZCompression
    | isSuffixOf ".zst" fp = ZStdCompression
    | isSuffixOf ".zstd" fp = ZStdCompression
    | otherwise = NoCompression


{- Ensure that the file is compressed using an acceptable compression format
 - (potentially by recompressing).
 -}
ensureCompressionIsOneOf :: NE.NonEmpty Compression -- ^ Acceptable formats
                                -> FilePath -- ^ input file
                                -> NGLessIO FilePath
ensureCompressionIsOneOf cs fp
        | inferCompression fp `elem` cs = return fp
        | otherwise = makeNGLTempFile fp "adjust_compression_" ext' $ \h ->
            CAlg.withPossiblyCompressedFile fp $ \src ->
                C.runConduit $
                    src .| (if GzipCompression `elem` cs
                        then CAlg.asyncGzipTo
                        else C.sinkHandle) h
    where
        ext' = case FP.takeExtensions fp of
                "" -> ""
                (_:rest)
                    | GzipCompression `elem` cs -> rest -<.> "gz"
                    | otherwise -> rest


-- | Shorten filename if longer than 240 characters
-- If base + ext is above 240 chars, avoid reaching the system limit of 255
-- by shortening the middle part of the filename
checkFilenameLength :: FilePath -> String -> String
checkFilenameLength base ext = if len > 240
                                  then shorten base
                                  else base
    where len = length base + length ext
          -- Take first 1/3 and last 1/3 of the original base name
          shorten f = take (div len 3) f ++ "..." ++ drop (div (2 * len) 3) f

-- | open a temporary file
-- This respects the preferences of the user (using the correct temporary
-- directory and deleting the file when necessary)
--
-- These files will be auto-removed when ngless exits
openNGLTempFile' :: FilePath -- ^ basename
                        -> String -- ^ prefix
                        -> String -- ^ extension
                        -> NGLessIO (ReleaseKey, (FilePath, Handle))
openNGLTempFile' base prefix ext = do
    tdir <- nConfTemporaryDirectory <$> nglConfiguration
    liftIO $ SD.createDirectoryIfMissing True tdir
    keepTempFiles <- nConfKeepTemporaryFiles <$> nglConfiguration
    let cleanupAction = if not keepTempFiles
                then deleteTempFile
                else hClose . snd

        filename = checkFilenameLength base ext
    (key,(fp,h)) <- allocate
                (openTempFileWithDefaultPermissions tdir (prefix ++ takeBaseNameNoExtensions filename ++ "." ++ ext))
                cleanupAction
    outputListLno' DebugOutput ["Created & opened temporary file ", fp]
    updateNglEnvironment $ \e -> e { ngleTemporaryFilesCreated = fp : ngleTemporaryFilesCreated e }
    return (key,(fp,h))

-- | Open a temporary file
-- See openNGLTempFile'
openNGLTempFile :: FilePath -> String -> String -> NGLessIO (FilePath, Handle)
openNGLTempFile base pre ext = snd <$> openNGLTempFile' base pre ext

deleteTempFile (fp, h) = do
    hClose h
    removeFileIfExists fp

-- | Create a temporary file
-- The Handle is closed after the action is performed
--
-- See 'openNGLTempFile'
makeNGLTempFile :: FilePath -> String -> String -> (Handle -> NGLessIO ()) -> NGLessIO FilePath
makeNGLTempFile base pre ext act = do
    (fpath, h) <- openNGLTempFile base pre ext
    act h
    liftIO $ hClose h
    return fpath

-- | removeIfTemporary removes files if (and only if):
-- 1. this was a temporary file created by 'openNGLTempFile'
-- 2. the user has not requested that temporary files be kept
--
-- It is *not necessary* to call this function, but it may save on temporary
-- disk space to clean up early.
removeIfTemporary :: FilePath -> NGLessIO ()
removeIfTemporary fp = do
    keepTempFiles <- nConfKeepTemporaryFiles <$> nglConfiguration
    createdFiles <- ngleTemporaryFilesCreated <$> nglEnvironment
    unless (keepTempFiles || fp `notElem` createdFiles) $ do
        outputListLno' DebugOutput ["Removing temporary file: ", fp]
        liftIO $ removeFileIfExists fp
        updateNglEnvironment $ \e -> e { ngleTemporaryFilesCreated = filter (/=fp) (ngleTemporaryFilesCreated e) }
{-# NOINLINE removeIfTemporary #-}


-- | This is a version of 'takeBaseName' which drops all extension
-- ('takeBaseName' only takes out the first extension)
takeBaseNameNoExtensions = FP.dropExtensions . FP.takeBaseName
{-# INLINE takeBaseNameNoExtensions #-}

-- | create a temporary directory as a sub-directory of the user-specified
-- temporary directory.
--
-- Releasing deletes the directory and all its contents (unless the user
-- requested that temporary files be preserved).
createTempDir :: String -> NGLessIO (ReleaseKey,FilePath)
createTempDir template = do
        tbase <- nConfTemporaryDirectory <$> nglConfiguration
        liftIO $ SD.createDirectoryIfMissing True tbase
        keepTempFiles <- nConfKeepTemporaryFiles <$> nglConfiguration
        allocate
            (c_getpid >>= createFirst tbase (takeBaseNameNoExtensions template))
            (if not keepTempFiles
                then SD.removeDirectoryRecursive
                else const (return ()))
    where
        createFirst :: (Num a, Show a) => FilePath -> String -> a -> IO FilePath
        createFirst dirbase t n = do
            let dirpath = dirbase </> t <.> "tmp" ++ show n
            try (SD.createDirectory dirpath) >>= \case
                Right () -> return dirpath
                Left e
                    | isAlreadyExistsError e -> createFirst dirbase t (n + 1)
                    | otherwise -> ioError e

-- This is in IO because it is run after NGLessIO has finished.
setupHtmlViewer :: FilePath -> IO ()
setupHtmlViewer dst = do
    exists <- SD.doesFileExist (dst </> "index.html")
    unless exists $ do
        SD.createDirectoryIfMissing False dst
        forM_ $(embedDir "Html") $ \(fp,bs) ->
            B.writeFile (dst </> fp) bs


-- | path to bwa
bwaBin :: NGLessIO FilePath
bwaBin = findNGLessBin "NGLESS_BWA_BIN" "bwa" Deps.bwaData

-- | path to samtools
samtoolsBin :: NGLessIO FilePath
samtoolsBin = findNGLessBin "NGLESS_SAMTOOLS_BIN" "samtools" Deps.samtoolsData
        --
-- | path to prodigal
prodigalBin :: NGLessIO FilePath
prodigalBin = findNGLessBin "NGLESS_PRODIGAL_BIN" "prodigal" Deps.prodigalData

-- | path to minimap2
minimap2Bin :: NGLessIO FilePath
minimap2Bin = findNGLessBin "NGLESS_MINIMAP2_BIN" "minimap2" Deps.minimap2Data

-- | path to megahit
megahitBin :: NGLessIO FilePath
megahitBin = liftIO (lookupEnv "NGLESS_MEGAHIT_BIN") >>= \case
    Just bin -> checkExecutable "megahit" bin
    Nothing -> do
        findBin ("ngless-"++versionStr ++ "-megahit/megahit") >>= \case
            Just bin -> return bin
            Nothing -> do
                megahitData' <- liftIO Deps.megahitData
                if B.null megahitData'
                    then findBin "megahit" >>= \case
                        Just bin -> do
                            outputListLno' WarningOutput
                                ["Could not find NGLess-specific megahit installation, using ", bin]
                            return bin
                        Nothing -> throwSystemError "Cannot find megahit on the system and this is a build without embedded dependencies."
                    else createMegahitBin megahitData'


binPath :: InstallMode -> NGLessIO FilePath
binPath Root = do
    nglessBinDirectory <- takeDirectory <$> liftIO getExecutablePath
#ifndef WINDOWS
    return (nglessBinDirectory </> "../share/ngless/bin")
#else
    return nglessBinDirectory
#endif
binPath User = ((</> "bin") . nConfUserDirectory) <$> nglConfiguration

-- | Attempts to find the absolute path for the requested binary (checks permissions)
findBin :: FilePath -> NGLessIO (Maybe FilePath)
findBin fname = do
        nglPath <- flip firstJustM [Root, User] $ \p -> do
            path <- (</> fname) <$> binPath p
            ex <- canExecute path
            if ex
                then return (Just path)
                else return Nothing
        case nglPath of
            Just p -> return (Just p)
            Nothing -> liftIO $ SD.findExecutable fname
    where
        canExecute :: FilePath -> NGLessIO Bool
        canExecute bin = do
            exists <- liftIO $ SD.doesFileExist bin
            if exists
                then do
                    isExecutable <- SD.executable <$> (liftIO $ SD.getPermissions bin)
                    unless isExecutable $
                        outputListLno' WarningOutput [
                            "Found file `", bin,
                            "`, but it is not executable by NGLess (may indicate a permission error)."]
                    return isExecutable
                else return False


findNGLessBin :: String -> FilePath -> IO B.ByteString -> NGLessIO FilePath
findNGLessBin envvar fname bindata = liftIO (lookupEnv envvar) >>= \case
    Just bin -> checkExecutable envvar bin
    Nothing -> do
        let versionTaggedFname =
                "ngless-" ++ versionStr ++ "-" ++ fname ++ binaryExtension
        findBin versionTaggedFname >>= \case
            Just bin -> return bin
            Nothing -> do
                bindata' <- liftIO bindata
                if B.null bindata'
                    then findBin fname >>= \case
                        Just bin -> do
                            outputListLno' WarningOutput
                                ["Could not find an NGLess specific executable for ", fname, ", using ", bin]
                            return bin
                        Nothing -> throwSystemError ("Cannot find " ++ fname ++ " on the system and this is a build without embedded dependencies.")
                    else writeBin versionTaggedFname bindata

writeBin :: FilePath -> IO B.ByteString -> NGLessIO FilePath
writeBin fname bindata = do
    userBinPath <- binPath User
    bindata' <- liftIO bindata
    when (B.null bindata') $
        throwSystemError ("Cannot find " ++ fname ++ " on the system and this is a build without embedded dependencies.")
    liftIO $ SD.createDirectoryIfMissing True userBinPath
    let fname' = userBinPath </> fname
    withLockFile LockParameters
                    { lockFname = fname' ++ ".expand.lock"
                    , maxAge = 300
                    , whenExistsStrategy = IfLockedRetry { nrLockRetries = 60, timeBetweenRetries = 60 }
                    , mtimeUpdate = True
                    } $ liftIO $ do
        withOutputFile fname' (flip B.hPut bindata')
        p <- SD.getPermissions fname'
        SD.setPermissions fname' (SD.setOwnerExecutable True p)
        return fname'

createMegahitBin :: B.ByteString-> NGLessIO FilePath
createMegahitBin megahitData = do
    destdir <- (</> ("ngless-" ++ versionStr ++ "-megahit")) <$> binPath User
    liftIO $ SD.createDirectoryIfMissing True destdir
    withLockFile LockParameters
                { lockFname = destdir ++ "lock.megahit-expand"
                , maxAge = 300
                , whenExistsStrategy = IfLockedRetry { nrLockRetries = 37*60, timeBetweenRetries = 60 }
                , mtimeUpdate = True
               } $ do
        outputListLno' TraceOutput ["Expanding megahit binaries into ", destdir]
        unpackMegahit destdir $ Tar.read . GZip.decompress $ BL.fromChunks [megahitData]
    return $ destdir </> "megahit"
    where
        unpackMegahit :: FilePath -> Tar.Entries Tar.FormatError -> NGLessIO ()
        unpackMegahit _ Tar.Done = return ()
        unpackMegahit _ (Tar.Fail err) = throwSystemError ("Error expanding megahit archive: " ++ show err)
        unpackMegahit destdir (Tar.Next e next) = do
            let dest = destdir </> FP.takeBaseName (Tar.entryPath e)
            case Tar.entryContent e of
                Tar.NormalFile content _ -> do
                    liftIO $ do
                        BL.writeFile dest content
                        --setModificationTime dest (posixSecondsToUTCTime (fromIntegral $ Tar.entryTime e))
                        setFileMode dest (Tar.entryPermissions e)
                Tar.Directory -> return ()
                Tar.SymbolicLink lt -> do
                    liftIO $ createSymbolicLink (Tar.fromLinkTarget lt) dest
                _ -> throwSystemError ("Unexpected entry in megahit tarball: " ++ show e)
            unpackMegahit destdir next



checkExecutable :: String -> FilePath -> NGLessIO FilePath
checkExecutable name bin = do
    exists <- liftIO $ SD.doesFileExist bin
    unless exists
        (throwSystemError $ concat [name, " binary not found!\n","Expected it at ", bin])
    is_executable <- SD.executable <$> liftIO (SD.getPermissions bin)
    unless is_executable
        (throwSystemError $ concat [name, " binary found at ", bin, ".\nHowever, it is not an executable file!"])
    return bin


expandPath :: FilePath -> NGLessIO (Maybe FilePath)
expandPath fbase = do
        searchpath <- nConfSearchPath <$> nglConfiguration
        outputListLno' TraceOutput ["Looking for file '", fbase, "' (search path is ", show searchpath, ")"]
        let candidates = expandPath' fbase searchpath
        flip firstJustM candidates $ \p -> do
            outputListLno' TraceOutput ["Looking for file (", fbase, ") in ", p]
            exists <- liftIO (SD.doesFileExist p)
            return $! if exists
                            then Just p
                            else Nothing

expandPath' :: FilePath -> [FilePath] -> [FilePath]
expandPath' fbase search = case RE.matchedText $ fbase RE.?=~ [RE.re|<(@{%id})?>|] of
        Nothing -> [fbase]
        Just c -> mapMaybe (expandPath'' $ trim c) search
    where
        trim = init . drop 1
        expandPath'' :: FilePath -> FilePath -> Maybe FilePath
        expandPath'' code path = (</> fbase') <$> simplify code path
        simplify :: FilePath -> FilePath -> Maybe FilePath
        simplify c path
            | '=' `notElem` path = Just path
            | (c++"=")`isPrefixOf` path = Just $ drop (length c + 1) path
            | otherwise = Nothing
        fbase' = removeSlash1 $ fbase RE.*=~/ [RE.ed|<(@{%id})?>///|]
        removeSlash1 "" = ""
        removeSlash1 ('/':p) = removeSlash1 p
        removeSlash1 p = p

binaryExtension :: String
#ifdef WINDOWS
binaryExtension = ".exe"
#else
binaryExtension = ""
#endif
