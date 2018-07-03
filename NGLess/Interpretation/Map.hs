{- Copyright 2013-2018 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Interpretation.Map
    ( executeMap
    , executeMapStats
    , executeMergeSams
    ) where

import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import           Control.Monad
import           Control.Monad.Except

import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.Combinators as CC
import qualified Data.Conduit as C
import           Data.Conduit ((.|))
import           Control.Monad.Extra (unlessM)
import           Data.List (foldl', sort)


import System.IO
import System.IO.Error
import System.FilePath.Glob (namesMatching)
import System.Directory
import System.FilePath
import System.PosixCompat.Files (createSymbolicLink)
import System.IO.SafeWrite (withOutputFile)
import Data.Maybe (fromMaybe)

import Language
import FileManagement
import ReferenceDatabases
import Output
import NGLess
import NGLess.NGLEnvironment

import qualified StandardModules.Mappers.Bwa as Bwa
import qualified StandardModules.Mappers.Soap as Soap
import qualified StandardModules.Mappers.Minimap2 as Minimap2

import Data.Sam
import Data.Fasta
import Data.FastQ
import FileOrStream
import Utils.Utils
import Utils.Conduit
import Configuration
import Utils.LockFile

fromRight d (Left _) = d
fromRight _ (Right v) = v
-- | internal type
data ReferenceInfo = PackagedReference T.Text | FaFile FilePath

data MergeStrategy = MSBestOnly

-- | An object which represents a mapper
data Mapper = Mapper
    { createIndex :: FilePath -> NGLessIO ()
    , hasValidIndex :: FilePath -> NGLessIO Bool
    , callMapper :: forall a. FilePath -> [FilePath] -> [String] -> C.ConduitT B.ByteString C.Void IO a -> NGLessIO a
    }

bwa = Mapper Bwa.createIndex Bwa.hasValidIndex Bwa.callMapper
soap = Mapper Soap.createIndex Soap.hasValidIndex Soap.callMapper
minimap2 = Mapper Minimap2.createIndex Minimap2.hasValidIndex Minimap2.callMapper

getMapper :: T.Text -> NGLessIO Mapper
getMapper request = do
        mappers <- ngleMappersActive <$> nglEnvironment
        if request `elem` mappers
            then return $! case request of
                "minimap2" -> minimap2
                "soap" -> soap
                "bwa" -> bwa
                _ -> error "should not be possible map:getMapper"
            else throwScriptError ("Requested mapper '"++T.unpack request ++"' is not active.")


isSubPath path base = let
                        path' = splitPath path
                        base' = splitPath base
                        isSubPath' _ [] = True
                        isSubPath' [] _ = False
                        isSubPath' (p:ps) (b:bs) = p == b && isSubPath' ps bs
                    in isSubPath' path' base'


getIndexOutput createLink fafile = do
    indexDir <- nConfIndexStorePath <$> nglConfiguration
    case indexDir of
        Just d
            | not (fafile `isSubPath` d) -> liftIO $ do
                let dropSlash "" = ""
                    dropSlash ('/':r) = dropSlash r
                    dropSlash p = p
                afafile <- makeAbsolute fafile
                let fafile' = d </> dropSlash afafile
                createDirectoryIfMissing True (takeDirectory fafile')
                when createLink $
                    createSymbolicLink afafile fafile'
                        `catchIOError` (\e -> unless (isAlreadyExistsError e) (ioError e))
                return fafile'
        _ -> return fafile

-- | lazy index creation
ensureIndexExists :: Int -> Mapper -> FilePath -> NGLessIO [FilePath]
ensureIndexExists 0 mapper fafile = do
    hasIndex <- hasValidIndex mapper fafile
    if hasIndex
        then do
            outputListLno' DebugOutput ["Index for ", fafile, " already exists."]
            return [fafile]
        else do
            fafile' <- getIndexOutput True fafile
            withLockFile LockParameters
                            { lockFname = fafile' ++ ".ngless-index.lock"
                            , maxAge = hoursToDiffTime 36
                            , whenExistsStrategy = IfLockedRetry { nrLockRetries = 37*60, timeBetweenRetries = 60 }
                            , mtimeUpdate = True
                            } $
                -- recheck if index exists with the lock in place
                -- it may have been created in the meanwhile (especially if we slept waiting for the lock)
                unlessM (hasValidIndex mapper fafile') $
                    createIndex mapper fafile'
            return [fafile']
  where
    hoursToDiffTime h = fromInteger (h * 3600)

ensureIndexExists blockSize mapper fafile = do
    blocks <- ensureSplitsExist blockSize fafile
    forM_ blocks (ensureIndexExists 0 mapper)
    return blocks

ensureSplitsExist blockSize fafile = do
    fafile' <- getIndexOutput False fafile
    let ofafile = takeDirectory fafile' </> takeBaseName fafile <.> "splits_" ++ show blockSize ++ "m"
        receipt = ofafile <.> "done"
    done <- liftIO $ doesFileExist receipt
    if done
        then do
            outputListLno' TraceOutput ["Splits for FASTA file '", fafile, "' found"]
            liftIO $ sort <$> namesMatching (ofafile ++ ".*.fna")
        else do
            outputListLno' DebugOutput ["Splitting FASTA file '", fafile, "'"]
            splits <- splitFASTA blockSize fafile ofafile
            liftIO $ withOutputFile receipt $ \hout ->
                hPutStrLn hout ("FASTA file '" ++ fafile ++ "' split into blocks of " ++ show blockSize ++ " megabases.")
            outputListLno' InfoOutput ["Split FASTA file '", fafile, "' into ", show (length splits), " chunks."]
            return splits


-- | parse map() args to return a reference
lookupReference :: KwArgsValues -> NGLessIO ReferenceInfo
lookupReference args = do
    let reference = lookup "reference" args
        fafile = lookup "fafile" args
    case (reference, fafile) of
        (Nothing, Nothing) -> throwScriptError "Either reference or fafile must be passed"
        (Just _, Just _) -> throwScriptError "Reference and fafile cannot be used simmultaneously"
        (Just r, Nothing) -> PackagedReference <$> stringOrTypeError "reference in map argument" r
        (Nothing, Just fa) -> (FaFile . T.unpack) <$> stringOrTypeError "fafile in map argument" fa


mapToReference :: Mapper -> FilePath -> ReadSet -> [String] -> NGLessIO (FilePath, (Int, Int, Int))
mapToReference mapper refIndex (ReadSet pairs singletons) extraArgs = do
    (newfp, hout) <- openNGLTempFile refIndex "mapped_" ".sam"
    let out1 = CB.sinkHandle hout
        out2 :: C.ConduitT B.ByteString C.Void IO ()
        out2 = CB.lines
                .| CL.filter (\line -> not (B.null line) &&  B8.head line /= '@')
                .| CC.unlinesAscii
                .| CB.sinkHandle hout
    statsp <- forM (zip pairs (out1:repeat out2)) $ \((FastQFilePath _ fp1, FastQFilePath _ fp2), out) ->
                callMapper mapper refIndex [fp1, fp2] extraArgs (zipToStats out)
    let outs = if null statsp
                    then out1:repeat out2
                    else repeat out2
    statss <- forM (zip singletons outs) $ \(FastQFilePath _ fp, out) ->
                callMapper mapper refIndex [fp] extraArgs (zipToStats out)
    liftIO $ hClose hout
    (newfp,) <$> combinestats statsp statss
zipToStats out = snd <$> C.toConsumer (zipSink2 out (linesUnBoundedC .| samStatsC))

splitFASTA :: Int -> FilePath -> FilePath -> NGLessIO [FilePath]
splitFASTA megaBPS ifile ofileBase =
        withLockFile LockParameters
                { lockFname = ifile ++ "." ++ show megaBPS ++ "m.split.lock"
                , maxAge = 36 * 3000
                , whenExistsStrategy = IfLockedRetry { nrLockRetries = 120, timeBetweenRetries = 60 }
                , mtimeUpdate = True
                } $ C.runConduit $
            conduitPossiblyCompressedFile ifile
                .| faConduit
                .| splitWriter
    where
        maxBPS = 1000 * 1000 * megaBPS
        splitWriter = splitWriter' [] (0 :: Int)
        splitWriter' fs n = do
            let f = ofileBase ++ "." ++ show n ++ ".fna"
            getNbps
                .| faWriteC
                .| CB.sinkFileCautious f
            finished <- CC.null
            if finished
                then return $ reverse (f:fs) -- reversing is done just so that chunks are indexed "in order"
                else splitWriter' (f:fs) (n + 1)
        getNbps = awaitJust $ \fa -> do
                        C.yield fa
                        if faseqLength fa > maxBPS
                            then do
                                lift $ outputListLno' WarningOutput
                                            ["While splitting file '", ifile, ": Sequence ", B8.unpack (seqheader fa), " is ", show (faseqLength fa)
                                            ," bases long (which is longer than the block size). Note that NGLess does not split sequences."]
                                return ()
                            else getNbps' (faseqLength fa)

        getNbps' sofar = awaitJust $ \fa ->
                            if faseqLength fa + sofar > maxBPS
                                then C.leftover fa
                                else do
                                    C.yield fa
                                    getNbps' (faseqLength fa + sofar)


combinestats first second = do
        first' <- runNGLess $ sequence first
        second' <- runNGLess $ sequence second
        return $ foldl' add3 (0,0,0) (first' ++ second')
    where
        add3 :: (Int, Int, Int) -> (Int, Int, Int) -> (Int, Int, Int)
        add3 (!a,!b,!c) (!a',!b',!c') = (a + a', b + b', c + c')



performMap :: Mapper -> Int -> ReferenceInfo -> T.Text -> ReadSet -> [String] -> NGLessIO NGLessObject
performMap mapper blockSize ref name rs extraArgs = do
    (ref', mappedRef) <- indexReference ref
    case ref' of
        [single] -> do
            (samPath', (total, aligned, unique)) <- mapToReference mapper single rs extraArgs
            outputMapStatistics (MappingInfo undefined samPath' single total aligned unique)
            return $ NGOMappedReadSet name (File samPath') mappedRef
        blocks -> do
            (sam, hout) <- openNGLTempFile "merging" "merged_" ".sam"
            partials <- forM blocks (\block -> fst <$> mapToReference mapper block rs extraArgs)
            ((total, aligned, unique), ()) <- C.runConduit $
                mergeSamFiles partials
                .| zipSink2 samStatsC'
                    (CL.concat
                        .| CL.map (ByteLine . encodeSamLine)
                        .| byteLineSinkHandle hout)
            liftIO $ hClose hout
            let refname = case ref of
                    FaFile fa -> fa
                    PackagedReference r -> T.unpack r
            outputMapStatistics (MappingInfo undefined sam refname total aligned unique)
            return $! NGOMappedReadSet name (File sam) mappedRef


    where
        indexReference :: ReferenceInfo -> NGLessIO ([FilePath], Maybe T.Text)
        indexReference (FaFile fa) =
            expandPath fa >>= \case
                Just fa' -> (,Nothing) <$> ensureIndexExists blockSize mapper fa'
                Nothing -> throwDataError ("Could not find FASTA file: "++fa)
        indexReference (PackagedReference r) = do
            ReferenceFilePaths fafile _ _ <- ensureDataPresent r
            case fafile of
                Just fp -> (, Just r) <$> ensureIndexExists blockSize mapper fp
                Nothing -> throwScriptError ("Could not find reference '" ++ T.unpack r ++ "'.")

executeMap :: NGLessObject -> KwArgsValues -> NGLessIO NGLessObject
executeMap fqs args = do
    ref <- lookupReference args
    oAll <- lookupBoolOrScriptErrorDef (return False) "map() call" "mode_all" args
    extraArgs <- map T.unpack <$> lookupStringListOrScriptErrorDef (return []) "extra bwa arguments" "__extra_bwa_args" args
    mapperName <- lookupStringOrScriptErrorDef (return "bwa") "map() call" "mapper" args
    blockSize <- lookupIntegerOrScriptErrorDef (return 0) "map() call" "block_size_megabases" args
    mapper <- getMapper mapperName
    let bwaArgs = extraArgs ++ ["-a" | oAll]
        executeMap' r (NGOList es)            = NGOList <$> forM es (executeMap' r)
        executeMap' r (NGOReadSet name rs)    = performMap mapper (fromInteger blockSize) r name rs bwaArgs
        executeMap' _ v = throwShouldNotOccur ("map expects ReadSet, got " ++ show v ++ "")
    executeMap' ref fqs

executeMapStats :: NGLessObject -> KwArgsValues -> NGLessIO NGLessObject
executeMapStats (NGOMappedReadSet name sami _) _ = do
    outputListLno' TraceOutput ["Computing mapstats on ", show sami]
    let (samfp, stream) = asSamStream sami
    (t, al, u) <- C.runConduit (stream .| samStatsC) >>= runNGLess
    countfp <- makeNGLTempFile samfp "sam_stats_" ".stats" $ \hout ->
        liftIO . hPutStr hout . concat $
            [     "\t",  T.unpack name, "\n"
            ,"total\t",   show  t, "\n"
            ,"aligned\t", show al, "\n"
            ,"unique\t",  show  u, "\n"
            ]
    return $! NGOCounts (File countfp)
executeMapStats other _ = throwScriptError ("Wrong argument for mapstats: "++show other)

executeMergeSams :: NGLessObject -> KwArgsValues -> NGLessIO NGLessObject
executeMergeSams (NGOList ifnames) _ = do
    outputListLno' WarningOutput ["Calling internal function __merge_samfiles"]
    partials <- mapM (fmap T.unpack . stringOrTypeError "__merge_samfiles") ifnames
    (sam, hout) <- openNGLTempFile "merging" "merged_" ".sam"
    ((total, aligned, unique), ()) <- C.runConduit $
        mergeSamFiles partials
        .| zipSink2 samStatsC'
            (CL.concat
                .| CL.map (ByteLine . encodeSamLine)
                .| byteLineSinkHandle hout)
    outputMapStatistics (MappingInfo undefined sam "no-ref" total aligned unique)
    liftIO $ hClose hout
    return $! NGOMappedReadSet "test" (File sam) Nothing
executeMergeSams _ _ = throwScriptError "Wrong argument for internal function __merge_samfiles"



mergeSamFiles :: [FilePath] -> C.ConduitT () SamGroup NGLessIO ()
mergeSamFiles [] = lift $ throwShouldNotOccur "empty input to mergeSamFiles"
mergeSamFiles inputs = do
    lift $ outputListLno' TraceOutput ["Merging SAM files: ", show inputs]
    forM_ inputs $ \f ->
        CB.sourceFile f
            .| linesC
            .| readSamHeaders
    -- This is sub-optimal as we reparse the file.
    -- There are also obvious opportunities to make this code take advantage of parallelism
    C.sequenceSources
            [CB.sourceFile f
                .| linesC
                .| readSamGroupsC
                        | f <- inputs]

        .| CL.mapM (mergeSAMGroups MSBestOnly)

readSamHeaders :: C.ConduitT ByteLine SamGroup NGLessIO ()
readSamHeaders =
    CC.takeWhile (\(ByteLine line) -> B.null line || B.head line == 64)
                .| CL.map (\(ByteLine line) -> [SamHeader line])

mergeSAMGroups :: MergeStrategy -> [SamGroup] -> NGLessIO SamGroup
mergeSAMGroups strategy groups
        | not (allSame . fmap samQName $ concat groups) = throwDataError "Merging unsynced SAM files (not implemented yet)"
        | otherwise = return $ group group1 ++ group group2 ++ group groupS
    where
        (group1, group2, groupS) = foldl (\(g1,g2,gS) s ->
                                                (if isFirstInPair s
                                                    then (s:g1, g2, gS)
                                                    else if isSecondInPair s
                                                        then (g1, s:g2, gS)
                                                        else (g1, g2, s:gS))) ([], [], []) $ concat groups
        group :: [SamLine] -> [SamLine]
        group [] = []
        group gs = case filter isAligned gs of
            [] -> [head gs]
            gs' -> pick strategy gs'
        pick :: MergeStrategy -> [SamLine] -> [SamLine]
        pick MSBestOnly gs =
            let matchValue :: SamLine -> Int
                matchValue samline = fromRight 0 (matchSize samline) - fromMaybe 0 (samIntTag samline "NM")
                bestMatch = maximum (map matchValue gs)
            in filter (\samline -> matchValue samline == bestMatch) gs

