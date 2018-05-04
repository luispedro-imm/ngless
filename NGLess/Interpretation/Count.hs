{- Copyright 2015-2018 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE FlexibleContexts, CPP #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
module Interpretation.Count
    ( executeCount
    , executeCountFile
    , Annotator(..)
    , CountOpts(..)
    , AnnotationMode(..)
    , AnnotationIntersectionMode(..)
    , MMMethod(..)
    , NMode(..)
    , annotationRule
    , loadAnnotator
    , loadFunctionalMap
    , performCount
    , RSV.RefSeqInfo(..)
    ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM
import qualified Data.Vector.Algorithms.Intro as VA

import qualified Data.IntervalMap.Strict as IM
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import qualified Data.Conduit as C
import qualified Data.Conduit.Combinators as CC
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Algorithms.Utils as CAlg
import           Data.Conduit ((.|))
import qualified Data.Strict.Tuple as TU
import           Data.Strict.Tuple (Pair(..))
import           Control.Monad (when, unless, forM, forM_)


import Control.Monad.Trans.Class (lift)
import Control.Monad.IO.Class   (liftIO)
import Control.Monad.Except     (throwError)
import Data.List                (foldl1', foldl', sort)
import GHC.Conc                 (getNumCapabilities)
import Control.DeepSeq          (NFData(..))
import Control.Error            (note)
import Control.Applicative      ((<|>))
import Data.Maybe

import Data.Convertible         (convert)

import Data.GFF
import Data.Sam (SamLine(..), isSamHeaderString, samLength, isAligned, isPositive, readSamGroupsC')
import FileManagement (makeNGLTempFile, expandPath)
import NGLess.NGLEnvironment
import ReferenceDatabases
import NGLess.NGError
import FileOrStream
import Language
import Output
import NGLess

import Utils.Utils
import Utils.Vector
import Utils.Conduit
import Utils.Suggestion
import qualified Utils.IntGroups as IG
import qualified Interpretation.Count.RefSeqInfoVector as RSV

#ifndef WINDOWS
import Data.Double.Conversion.ByteString (toShortest)
#else
-- On Windows, double-conversion is problematic, so fall back on a basic
-- implementation
-- See https://github.com/bos/double-conversion/issues/7
toShortest :: Double -> B.ByteString
toShortest = B8.pack . show
#endif

{- Implementation of count()
 -
 - The main function is performCount which loops over mapped read groups
 -. annotating them with an Annotator.
 -}

-- GFFAnnotationMap maps from `References` (e.g., chromosomes) to positions to (strand/feature-id)
type AnnotationInfo = Pair GffStrand Int
type GffIMMap = IM.IntervalMap Int [AnnotationInfo]
type GFFAnnotationMap = M.Map B.ByteString GffIMMap
type AnnotationRule = GffIMMap -> GffStrand -> (Int, Int) -> [AnnotationInfo]

-- This implements MOCAT-style "gene name" -> "feature" annotation
type GeneMapAnnotation = M.Map B8.ByteString [Int]

type FeatureSizeMap = M.Map B.ByteString Double

data MMMethod = MMCountAll | MM1OverN | MMDist1 | MMUniqueOnly
    deriving (Eq)

data NMode = NMRaw | NMNormed | NMScaled | NMFpkm
    deriving (Eq)

minDouble :: Double
minDouble = (2.0 :: Double) ^^ fst (floatRange (1.0 :: Double))

data CountOpts =
    CountOpts
    { optFeatures :: [B.ByteString] -- ^ list of features to condider
    , optSubFeatures :: Maybe [B.ByteString] -- ^ list of sub-features to condider
    , optIntersectMode :: AnnotationRule
    , optStrandSpecific :: !Bool
    , optMinCount :: !Double
    , optMMMethod :: !MMMethod
    , optDelim :: !B.ByteString
    , optNormMode :: !NMode
    , optIncludeMinus1 :: !Bool
    }

data AnnotationMode = AnnotateSeqName | AnnotateGFF FilePath | AnnotateFunctionalMap FilePath
    deriving (Eq)

data Annotator =
                SeqNameAnnotator (Maybe RSV.RefSeqInfoVector) -- ^ Just annotate by sequence names
                | GFFAnnotator GFFAnnotationMap [B.ByteString] FeatureSizeMap -- ^ map reference regions to features + feature sizes
                | GeneMapAnnotator GeneMapAnnotation RSV.RefSeqInfoVector -- ^ map reference (gene names) to indices, indexing into the vector of refseqinfo
instance NFData Annotator where
    rnf (SeqNameAnnotator m) = rnf m
    rnf (GFFAnnotator amap headers szmap) = amap `seq` rnf headers `seq` rnf szmap -- amap is already strict
    rnf (GeneMapAnnotator amap szmap) = rnf amap `seq` rnf szmap

annotateReadGroup :: CountOpts -> Annotator -> [SamLine] -> Either NGError [Int]
annotateReadGroup opts ann samlines = add1 . listNub <$> case ann of
        SeqNameAnnotator Nothing -> throwShouldNotOccur "Incomplete annotator used"
        SeqNameAnnotator (Just szmap) -> mapMaybeM (getID szmap) samlines
        GFFAnnotator amap _ _ -> return . concatMap (annotateSamLineGFF opts amap) $ samlines
        GeneMapAnnotator amap _ -> return . concatMap (mapAnnotation1 amap) $ samlines
    where
        -- this is because "unmatched" is -1
        add1 [] = [0]
        add1 vs = (+ 1) <$> vs
        getID :: RSV.RefSeqInfoVector -> SamLine -> Either NGError (Maybe Int)
        getID szmap sr@SamLine{samRName = rname }
            | isAligned sr = case RSV.lookup szmap rname of
                    Nothing -> throwDataError ("Unknown sequence id: " ++ show rname)
                    ix -> return ix
        getID _ _ = Right Nothing
        mapAnnotation1 :: GeneMapAnnotation ->  SamLine -> [Int]
        mapAnnotation1 amap samline = fromMaybe [] $ M.lookup (samRName samline) amap

annSizeOf :: Annotator -> B.ByteString -> Either NGError Double
annSizeOf _ "-1" = return 0.0
annSizeOf (SeqNameAnnotator Nothing) _ = throwShouldNotOccur "Using unloaded annotator"
annSizeOf (SeqNameAnnotator (Just ix)) name = annSizeOfInRSVector name ix
annSizeOf (GFFAnnotator _ _ szmap) name = case M.lookup name szmap of
    Just s -> return s
    Nothing -> throwShouldNotOccur ("Header does not exist in sizes: "++show name)
annSizeOf (GeneMapAnnotator _ ix) name = annSizeOfInRSVector name ix
annSizeOfInRSVector name vec = RSV.retrieveSize vec <$> note (NGError DataError $ "Could not find size of item ["++B8.unpack name++"]") (RSV.lookup vec name)


annEnumerate :: Annotator -> [(B.ByteString, Int)]
annEnumerate (SeqNameAnnotator Nothing)   = error "Using unfinished annotator"
annEnumerate (SeqNameAnnotator (Just ix)) = ("-1",0):enumerateRSVector ix
annEnumerate (GeneMapAnnotator _ ix)      = ("-1",0):enumerateRSVector ix
annEnumerate (GFFAnnotator _ headers _)   = zip ("-1":headers) [0..]
enumerateRSVector rfv = [(RSV.retrieveName rfv i, i + 1) | i <- [0.. RSV.length rfv - 1]]

-- Number of elements
annSize :: Annotator -> Int
annSize (SeqNameAnnotator (Just rfv)) = RSV.length rfv + 1
annSize (GeneMapAnnotator _ rfv) = RSV.length rfv + 1
annSize ann = length (annEnumerate ann)


{- We define the type AnnotationIntersectionMode mainly to facilitate tests,
 - which depend on being able to write code such as
 -
 -      annotationRule IntersectUnion
 -}
data AnnotationIntersectionMode = IntersectUnion | IntersectStrict | IntersectNonEmpty
    deriving (Eq, Show)


annotationRule :: AnnotationIntersectionMode -> AnnotationRule
annotationRule IntersectUnion = union
annotationRule IntersectStrict = intersection_strict
annotationRule IntersectNonEmpty = intersection_non_empty


executeCountFile :: NGLessObject -> KwArgsValues -> NGLessIO NGLessObject
executeCountFile (NGOString st) _ = return $ NGOCounts (File (T.unpack st))
executeCountFile other _ = throwScriptError ("Unexpected argument to countfile(): expected str, got " ++ show other)

executeCount :: NGLessObject -> KwArgsValues -> NGLessIO NGLessObject
executeCount (NGOList e) args = NGOList <$> mapM (`executeCount` args) e
executeCount (NGOMappedReadSet rname istream mappedref) args = do
    minCount <- lookupIntegerOrScriptErrorDef (return 0) "count argument parsing" "min" args
    method <- decodeSymbolOrError "multiple argument in count() function"
                    [("1overN", MM1OverN)
                    ,("dist1", MMDist1)
                    ,("all1", MMCountAll)
                    ,("unique_only", MMUniqueOnly)
                    ] =<< lookupSymbolOrScriptErrorDef (return "dist1")
                                    "multiple argument to count " "multiple" args
    strand_specific <- lookupBoolOrScriptErrorDef (return False) "count function" "strand" args
    include_minus1 <- lookupBoolOrScriptErrorDef defaultMinus1 "count function" "include_minus1" args
    mocatMap <- lookupFilePath "functional_map argument to count()" "functional_map" args
    gffFile <- lookupFilePath "gff_file argument to count()" "gff_file" args
    discardZeros <- lookupBoolOrScriptErrorDef (return False) "count argument parsing" "discard_zeros" args
    m <- fmap annotationRule $ decodeSymbolOrError "mode argument to count"
                    [("union", IntersectUnion)
                    ,("intersection_strict", IntersectStrict)
                    ,("intersection_non_empty", IntersectNonEmpty)
                    ] =<< lookupSymbolOrScriptErrorDef (return "union") "mode argument to count" "mode" args
    delim <- T.encodeUtf8 <$> lookupStringOrScriptErrorDef (return "\t") "count hidden argument (should always be valid)" "__delim" args
    when ("norm" `elem` (fst <$> args) && "normalization" `elem` (fst <$> args)) $
        outputListLno' WarningOutput ["In count() function: both `norm` and `normalization` used. `norm` is semi-deprecated and will be ignored in favor of `normalization`"]
    normSize <- lookupBoolOrScriptErrorDef (return False) "count function" "norm" args
    normMode <- decodeSymbolOrError "normalization option"
                        [("raw", NMRaw)
                        ,("normed", NMNormed)
                        ,("scaled", NMScaled)
                        ,("fpkm", NMFpkm)] =<< lookupSymbolOrScriptErrorDef
                                                    (return $! if normSize then "normed" else "raw") "count function" "normalization" args
    fs <- case lookup "features" args of
        Nothing -> return ["gene"]
        Just (NGOString f) -> return [f]
        Just (NGOList feats') -> mapM (stringOrTypeError "count features argument") feats'
        _ -> throwShouldNotOccur "executeAnnotation: TYPE ERROR"
    subfeatures <- case lookup "subfeatures" args of
        Nothing -> return Nothing
        Just (NGOString sf) -> return $ Just [sf]
        Just (NGOList subfeats') -> Just <$> mapM (stringOrTypeError "count subfeatures argument") subfeats'
        _ -> throwShouldNotOccur "executeAnnotation: TYPE ERROR"
    refinfo <- case lookup "reference" args of
        Nothing -> return mappedref
        Just val -> Just <$> stringOrTypeError "reference for count()" val
    let opts = CountOpts
            { optFeatures = map (B8.pack . T.unpack) fs
            , optSubFeatures = map (B8.pack . T.unpack) <$> subfeatures
            , optIntersectMode = m
            , optStrandSpecific = strand_specific
            , optMinCount = if discardZeros
                                then minDouble
                                else fromInteger minCount
            , optMMMethod = method
            , optDelim = delim
            , optNormMode = normMode
            , optIncludeMinus1 = include_minus1
            }
    amode <- annotationMode (optFeatures opts) refinfo mocatMap gffFile
    annotators <- loadAnnotator amode opts
    NGOCounts . File <$> performCount istream rname annotators opts
executeCount err _ = throwScriptError ("Invalid Type. Should be used NGOList or NGOAnnotatedSet but type was: " ++ show err)

-- | The include_minus1 argument defaulted to False up to version 0.5. Now, it
-- defaults to true as it seems to be what most users expect.
defaultMinus1 :: NGLessIO Bool
defaultMinus1 = do
    v <- ngleVersion <$> nglEnvironment
    return $! v > NGLVersion 0 5

loadAnnotator :: AnnotationMode -> CountOpts -> NGLessIO [Annotator]
loadAnnotator AnnotateSeqName _ = return [SeqNameAnnotator Nothing]
loadAnnotator (AnnotateGFF gf) opts = loadGFF gf opts
loadAnnotator (AnnotateFunctionalMap mm) opts = loadFunctionalMap mm (optFeatures opts)


-- First pass over the data
performCount1Pass :: MMMethod
                        -> VUM.IOVector Double -- ^ counts vector. Will be modified
                        -> C.Sink (VU.Vector Int, IG.IntGroups) NGLessIO [IG.IntGroups]
performCount1Pass MMUniqueOnly mcounts = do
    C.awaitForever $ \(singles, _) -> liftIO (incrementAll mcounts singles)
    return []
performCount1Pass MMCountAll mcounts = do
    C.awaitForever $ \(singles, mms) -> liftIO $ do
        incrementAll mcounts singles
        IG.forM_ mms (incrementAllV mcounts)
    return []
performCount1Pass MM1OverN mcounts = do
    C.awaitForever $ \(singles, mms) -> liftIO $ do
        incrementAll mcounts singles
        IG.forM_ mms (increment1OverN mcounts)
    return []
performCount1Pass MMDist1 mcounts = loop []
    where
        loop :: [IG.IntGroups] -> C.Sink (VU.Vector Int, IG.IntGroups) NGLessIO [IG.IntGroups]
        loop acc = C.await >>= \case
            Nothing -> return acc
            Just (singles, mms) ->  do
                    liftIO $ incrementAll mcounts singles
                    loop $ if not (IG.null mms)
                                then mms:acc
                                else acc

-- | This is a version of C.sequenceSinks which optimizes the case where a
-- single element is passed (it makes a small, but noticeable difference in
-- benchmarking)
sequenceSinks :: (Monad m) => [C.Sink a m b] -> C.Sink a m [b]
sequenceSinks [s] = (:[]) <$> s
sequenceSinks ss = C.sequenceSinks ss

annSamHeaderParser :: Int -> [Annotator] -> CountOpts -> C.Sink ByteLine NGLessIO [Annotator]
annSamHeaderParser mapthreads anns opts = lineGroups .| sequenceSinks (map annSamHeaderParser1 anns)
    where
        annSamHeaderParser1 (SeqNameAnnotator Nothing) = do
            rfvm <- liftIO RSV.newRefSeqInfoVector
            asyncMapEitherC mapthreads (\(!vi, v) -> V.imapM (\ix ell -> seqNameSize (vi*32768+ix, ell)) v)
                .| CL.mapM_ (\v -> liftIO $
                                    V.forM_ v $ \(RSV.RefSeqInfo n val) ->
                                        RSV.insert rfvm n val)
            vsorted <- liftIO $ do
                RSV.sort rfvm
                RSV.unsafeFreeze rfvm
            return $! SeqNameAnnotator (Just vsorted)
        annSamHeaderParser1 (GeneMapAnnotator gmap isizes)
            | optNormMode opts == NMNormed = do
                msizes <- liftIO $ RSV.unsafeThaw isizes
                asyncMapEitherC mapthreads (\(!vi,headers) -> flattenVs <$> V.imapM (\ix ell -> indexUpdates gmap (vi*32768+ix, ell)) headers)
                    .| CL.mapM_ (liftIO . updateSizes msizes)
                GeneMapAnnotator gmap <$> liftIO (RSV.unsafeFreeze msizes)
        annSamHeaderParser1 ann = CC.sinkNull >> return ann
        lineGroups = CL.filter (B.isPrefixOf "@SQ\tSN:" . unwrapByteLine)
                    .| CC.conduitVector 32768
                    .| CAlg.enumerateC
        flattenVs :: VU.Unbox a => V.Vector [a] -> VU.Vector a
        flattenVs chunks = VU.unfoldr getNext (0,[])
            where
                getNext (!vi, v:vs) = Just (v, (vi,vs))
                getNext (vi,[])
                    | vi >= V.length chunks = Nothing
                    | otherwise = getNext (vi + 1, chunks V.! vi)

        updateSizes :: RSV.RefSeqInfoVectorMutable -> VU.Vector (Int,Double) -> IO ()
        updateSizes msizes updates =
            VU.forM_ updates $ \(ix,val) -> do
                cur <- RSV.retrieveSizeIO msizes ix
                RSV.writeSizeIO msizes ix (cur + val)

        indexUpdates :: GeneMapAnnotation -> (Int, ByteLine) -> NGLess [(Int, Double)]
        indexUpdates gmap line = do
            RSV.RefSeqInfo seqid val <- seqNameSize line
            let ixs = fromMaybe [] $ M.lookup seqid gmap
            return [(ix,val) | ix <- ixs]
        seqNameSize :: (Int, ByteLine) -> NGLess RSV.RefSeqInfo
        seqNameSize (n, ByteLine h) = case B8.split '\t' h of
                [_,seqname,sizestr] -> case B8.readInt (B.drop 3 sizestr) of
                    Just (size, _) -> return $! RSV.RefSeqInfo (B.drop 3 seqname) (convert size)
                    Nothing -> throwDataError ("Could not parse sequence length in header (line: " ++ show n ++ ")")
                _ -> throwDataError ("SAM file does not contain the right number of tokens (line: " ++ show n ++ ")")


listNub :: (Ord a) => [a] -> [a]
listNub [] = []
listNub x@[_] = x
listNub x@[a,b]
    | a == b = [a]
    | otherwise = x
listNub other = S.toList . S.fromList $ other


-- Takes a vector of [Int] and splits into singletons (which can be represented
-- as `VU.Vector Int` and the rest (represented as `IG.IntGroups`)
splitSingletons :: MMMethod -> V.Vector [Int] -> (VU.Vector Int, IG.IntGroups)
splitSingletons method values = (singles, mms)
    where
        singles = VU.create $ do
            v <- VU.unsafeThaw $ VU.unfoldr getsingle1 0
            -- We want to maximize the work performed in this function as it is
            -- being done in a worker thread:
            -- sorting is completely unnecessary for correctness, but improves
            -- cache performance as close-by indices will be accessed together
            -- when this data is processed in the main thread.
            VA.sort v

            return v
        getsingle1 :: Int -> Maybe (Int, Int)
        getsingle1 ix = do
            vs <- values V.!? ix
            case vs of
                [v] -> return (v, ix + 1)
                _ -> getsingle1 (ix + 1)
        mms -- if we are only using unique hits, then we do not need to care about non-singletons
            | method == MMUniqueOnly = IG.empty
            | otherwise = IG.fromList (filter larger1 (V.toList values))
        larger1 []  = False
        larger1 [_] = False
        larger1 _   = True


performCount :: FileOrStream -> T.Text -> [Annotator] -> CountOpts -> NGLessIO FilePath
performCount istream gname annotators0 opts = do
    outputListLno' TraceOutput ["Starting count..."]
    numCapabilities <- liftIO getNumCapabilities
    let mapthreads = max 1 (numCapabilities - 1)
        method = optMMMethod opts
        delim = optDelim opts
        (samfp, samStream) = asSamStream istream
    (toDistribute, mcounts, annotators) <- C.runConduit $
        samStream
            .| do
                annotators <-
                    CC.takeWhile (isSamHeaderString . unwrapByteLine)
                        .| annSamHeaderParser mapthreads annotators0 opts
                lift $ outputListLno' TraceOutput ["Loaded headers. Starting parsing/distribution."]
                mcounts <- forM annotators $ \ann -> do
                    let n_entries = annSize ann
                    liftIO $ VUM.replicate n_entries (0.0 :: Double)
                toDistribute <-
                    readSamGroupsC' mapthreads True
                        .| asyncMapEitherC mapthreads (\samgroup -> forM annotators $ \ann -> do
                                                                    annotated <- V.mapM (annotateReadGroup opts ann) samgroup
                                                                    return $ splitSingletons method annotated)
                        .| sequenceSinks [CL.map (!! i) .| performCount1Pass method mc | (i,mc) <- zip [0..] mcounts]
                return (toDistribute, mcounts, annotators)

    results <- distributeScaleCounts (optNormMode opts) (optMMMethod opts) annotators mcounts toDistribute
    makeNGLTempFile samfp "counts." "txt" $ \hout -> liftIO $ do
        BL.hPut hout (BL.fromChunks [delim, T.encodeUtf8 gname, "\n"])
        let maybeSkipM1
                | optIncludeMinus1 opts = id
                | otherwise = tail
        forM_ (zip annotators results) $ \(ann,result) ->
            forM_ (maybeSkipM1 $ annEnumerate ann) $ \(h,i) -> do
                let nlB :: BB.Builder
                    nlB = BB.word8 10
                    tabB :: BB.Builder
                    tabB = BB.word8 9
                    v = (VU.!) result i
                when (v >= optMinCount opts) $
                    BB.hPutBuilder hout $ mconcat [BB.byteString h, tabB, BB.byteString (toShortest v), nlB]


distributeScaleCounts :: NMode -> MMMethod -> [Annotator] -> [VUM.IOVector Double] -> [[IG.IntGroups]] -> NGLessIO [VU.Vector Double]
distributeScaleCounts NMRaw mmmethod _ counts _
    | mmmethod /= MMDist1 = liftIO $ mapM VU.unsafeFreeze counts
distributeScaleCounts norm mmmethod annotators mcountss toDistribute =
    forM (zip3 annotators mcountss toDistribute) $ \(ann, mcounts, indices) -> do
        let n_entries = annSize ann
        sizes <- liftIO $ VUM.new n_entries
        forM_ (annEnumerate ann) $ \(name,i) -> do
            s <- runNGLess $ annSizeOf ann name
            liftIO $ VUM.write sizes i s
        redistribute mmmethod mcounts sizes indices
        normalizeCounts norm mcounts sizes
        liftIO $ VU.unsafeFreeze mcounts


redistribute :: MMMethod -> VUM.IOVector Double -> VUM.IOVector Double -> [IG.IntGroups] -> NGLessIO ()
redistribute MMDist1 ocounts sizes indices = do
    outputListLno' TraceOutput ["Counts (second pass)..."]
    fractCounts' <- liftIO $ VUM.clone ocounts
    normalizeCounts NMNormed fractCounts' sizes
    fractCounts <- liftIO $ VU.unsafeFreeze fractCounts'
    forM_ indices $ \vss -> IG.forM_ vss $ \vs -> do
        let cs = VU.map (VU.unsafeIndex fractCounts) vs
            cs_sum = sum (VU.toList cs)
            n_cs = convert (VU.length cs)
            adjust :: Double -> Double
            adjust = if cs_sum > 0.0
                        then (/ cs_sum)
                        else const  (1.0 / n_cs)
        forM_ (zip (VU.toList vs) (VU.toList cs)) $ \(v,c) ->
            liftIO $ unsafeIncrement' ocounts v (adjust c)
redistribute _ _ _ _ = return ()

incrementAll :: VUM.IOVector Double -> VU.Vector Int -> IO ()
incrementAll counts vis = VU.forM_ vis $ \vi -> unsafeIncrement counts vi

incrementAllV :: VUM.IOVector Double -> VU.Vector Int -> IO ()
incrementAllV counts vis = VU.forM_ vis $ \vi -> unsafeIncrement counts vi

increment1OverN :: VUM.IOVector Double -> VU.Vector Int -> IO ()
increment1OverN counts vis = VU.forM_ vis $ \vi -> unsafeIncrement' counts vi oneOverN
    where
        oneOverN :: Double
        oneOverN = 1.0 / convert (VU.length vis)

normalizeCounts :: NMode -> VUM.IOVector Double -> VUM.IOVector Double -> NGLessIO ()
normalizeCounts NMRaw _ _ = return ()
normalizeCounts NMNormed counts sizes = do
        let n = VUM.length counts
            n' = VUM.length sizes
        unless (n == n') $
            throwShouldNotOccur ("Counts vector is of size " ++ show n ++ ", but sizes is of size " ++ show n')
        forM_ [0 .. n - 1] $ \i -> liftIO $ do
            s <- VUM.read sizes i
            when (s > 0) $
                VUM.unsafeModify counts (/ s) i
normalizeCounts nmethod counts sizes
    | nmethod `elem` [NMScaled, NMFpkm] = do
        -- count vectors always include a -1 at this point (it is
        -- ignored in output if the user does not request it, but is
        -- always computed). Thus, we compute the sum without it and do
        -- not normalize it later:
        let totalCounts v = withVector v (VU.sum . VU.tail)
        initial <- totalCounts counts
        normalizeCounts NMNormed counts sizes
        afternorm <- totalCounts counts
        let factor
                | nmethod == NMScaled = initial / afternorm
                | otherwise = 1.0e9 / initial --- 1e6 [million fragments] * 1e3 [kilo basepairs] = 1e9
        liftIO $ forM_ [1.. VUM.length counts - 1] (VUM.unsafeModify counts (* factor))
    | otherwise = error "This should be unreachable code [normalizeCounts]"

data LoadFunctionalMapState = LoadFunctionalMapState
                                        !Int -- ^ next free index
                                        !(M.Map B.ByteString [Int]) -- ^ gene -> [feature-ID]
                                        !(M.Map B.ByteString Int) -- ^ feature -> feature-ID

loadFunctionalMap :: FilePath -> [B.ByteString] -> NGLessIO [Annotator]
loadFunctionalMap fname [] = throwScriptError ("Loading annotation file '"++fname++"' but no features requested. This is probably a bug.")
loadFunctionalMap fname columns = do
        outputListLno' InfoOutput ["Loading map file ", fname]
        numCapabilities <- liftIO getNumCapabilities
        let mapthreads = max 1 (numCapabilities - 1)
        anns <- C.runConduit $
                    conduitPossiblyCompressedFile fname
                    .| linesC
                    .| CAlg.enumerateC
                    .| (do
                        hline <- CL.head
                        cis <- case hline of
                            Nothing -> throwDataError ("Empty map file: "++fname)
                            Just (_, ByteLine header) -> let headers = B8.split '\t' header
                                                    in runNGLess $ lookUpColumns headers
                        CC.conduitVector 8192
                            .| asyncMapEitherC mapthreads (V.mapM (selectColumns cis)) -- after this we have vectors of (<gene name>, [<feature-name>])
                            .| sequenceSinks
                                [finishFunctionalMap <$> CL.fold (V.foldl' (inserts1 c)) (LoadFunctionalMapState 0 M.empty M.empty) | c <- [0 .. length cis - 1]])
        outputListLno' TraceOutput ["Loading of map file '", fname, "' complete"]
        return anns
    where
        finishFunctionalMap (LoadFunctionalMapState _ gmap namemap) = GeneMapAnnotator
                                                                            (reindex gmap namemap)
                                                                            (RSV.fromList [RSV.RefSeqInfo n 0.0 | n <- M.keys namemap])
        reindex :: M.Map B.ByteString [Int] -> M.Map B.ByteString Int -> M.Map B.ByteString [Int]
        reindex gmap namemap = M.map (map (ix2ix VU.!)) gmap
            where
                ix2ix = revnamemap namemap
        inserts1 :: Int -> LoadFunctionalMapState -> (B.ByteString, [[B.ByteString]]) -> LoadFunctionalMapState
        inserts1 c (LoadFunctionalMapState first gmap namemap) (name, ids) = LoadFunctionalMapState first' gmap' namemap'
            where
                (first', namemap', ids') = foldl' insertname (first,namemap,[]) (ids !! c)
                gmap' = M.insert name ids' gmap

                insertname :: (Int, M.Map B.ByteString Int, [Int]) -> B.ByteString -> (Int, M.Map B.ByteString Int, [Int])
                insertname (!next, !curmap, ns') n = case M.lookup n curmap of
                    Just ix -> (next, curmap, ix:ns')
                    Nothing -> (next + 1, M.insert n next curmap, next:ns')


        lookUpColumns :: [B.ByteString] -> NGLess [Int]
        lookUpColumns [] = throwDataError ("Loading functional map file '" ++ fname ++ "': Header line missing!")
        lookUpColumns headers = sort <$> mapM (lookUpColumns' $ M.fromList (zip (tail headers) [0..])) columns
        lookUpColumns' :: M.Map B8.ByteString Int -> B8.ByteString -> NGLess Int
        lookUpColumns' colmap col = note notfounderror $ M.lookup col colmap
            where
                notfounderror = NGError DataError errormsg
                errormsg = concat (["Could not find column '", B8.unpack col, "'."]
                                ++ case findSuggestion (T.pack $ B8.unpack col) (map (T.pack . B8.unpack) $ M.keys colmap) of
                                        Just (Suggestion valid reason) -> [" Did you mean '", T.unpack valid, "' (", T.unpack reason, ")?"]
                                        Nothing -> []
                                ++ ["\nAvailable columns are:\n"]
                                ++ ["\t- '"++B8.unpack c ++ "'\n" | c <- M.keys colmap]
                                )
        selectColumns :: [Int] -> (Int, ByteLine) -> NGLess (B.ByteString, [[B.ByteString]])
        selectColumns cols (line_nr, ByteLine line) = case B8.split '\t' line of
                    (gene:mapped) -> (gene,) . addTags columns <$> selectIds line_nr cols (zip [0..] mapped)
                    [] -> throwDataError ("Loading functional map file '" ++ fname ++ "' [line " ++ show (line_nr + 1)++ "]: empty line.")

        addTags :: [B.ByteString] -> [B.ByteString] -> [[B.ByteString]]
        addTags [] _ = error "impossible"
        addTags [_] [v] = [B8.splitWith (\c -> c == ',' || c == '|') v] -- do not tag single features
        addTags fs vss = [[B.concat [f, ":", v] | v <- B8.splitWith (\c -> c ==',' || c == '|') vs]
                                    | (f,vs) <- zip fs vss]

        selectIds :: Int -> [Int] -> [(Int, B.ByteString)] -> NGLess [B.ByteString]
        selectIds _ [] _ = return []
        selectIds line_nr fs@(fi:rest) ((ci,v):vs)
            | fi == ci = (v:) <$> selectIds line_nr rest vs
            | otherwise = selectIds line_nr fs vs
        selectIds line_nr _ _ = throwDataError ("Loading functional map file '" ++ fname ++ "' [line " ++ show (line_nr + 1)++ "]: wrong number of columns") -- humans count lines in 1-based systems


annotationMode :: [B.ByteString] -> Maybe T.Text -> Maybe FilePath -> Maybe FilePath -> NGLessIO AnnotationMode
annotationMode _ _ (Just _) (Just _) = throwScriptError "Cannot simmultaneously pass a gff_file and an annotation_file for count() function"
annotationMode ["seqname"] _ _ _ = return AnnotateSeqName
annotationMode _ _ (Just r) _ = return (AnnotateFunctionalMap r)
annotationMode _ _ _ (Just g) = return (AnnotateGFF g)
annotationMode _ (Just ref) Nothing Nothing = do
    outputListLno' InfoOutput ["Annotate with reference: ", show ref]
    ReferenceFilePaths _ mgffpath mfuncpath <- ensureDataPresent ref
    case (mgffpath, mfuncpath) of
        (Just gffpath, Nothing) -> return $! AnnotateGFF gffpath
        (Nothing, Just fmpath) -> return $! AnnotateFunctionalMap fmpath
        (Nothing, Nothing) -> throwScriptError ("Could not find annotation file for '" ++ T.unpack ref ++ "'")
        (Just _, Just _) -> throwDataError ("Reference " ++ T.unpack ref ++ " has both a GFF and a functional map file. Cannot figure out what to do.")
annotationMode _ _ _ _ =
            throwScriptError "For counting, you must do one of\n1. use seqname mode\n2. pass in a GFF file using the argument 'gff_file'\n3. pass in a gene map using the argument 'functional_map'"


revnamemap :: M.Map B.ByteString Int -> VU.Vector Int
revnamemap namemap = VU.create $ do
                r <- VUM.new (M.size namemap)
                forM_ (zip (M.elems namemap) [0..]) $ uncurry (VUM.write r)
                return r

loadGFF :: FilePath -> CountOpts -> NGLessIO [Annotator]
loadGFF gffFp opts = do
        outputListLno' TraceOutput ["Loading GFF file '", gffFp, "'..."]
        partials <- C.runConduit $
                conduitPossiblyCompressedFile gffFp
                    .| linesC
                    .| readAnnotationOrDie
                    .| sequenceSinks
                        [CL.fold (insertg f sf) (0, M.empty, M.empty, M.empty)
                                    |  f <- optFeatures    opts
                                    , sf <- case optSubFeatures opts of
                                                Nothing -> [Nothing]
                                                Just fs -> Just <$> fs]

        outputListLno' TraceOutput ["Loading GFF file '", gffFp, "' complete."]
        return $! map finishGffAnnotator partials
    where
        singleFeature
            | length (optFeatures opts) > 1 = False
            | otherwise = case optSubFeatures opts of
                Nothing -> True
                Just [_] -> True
                _ -> False
        readAnnotationOrDie :: C.Conduit ByteLine NGLessIO GffLine
        readAnnotationOrDie = C.awaitForever $ \(ByteLine line) ->
            unless (B8.head line == '#') $
                case readGffLine line of
                    Right g -> C.yield g
                    Left err -> throwError err
        finishGffAnnotator ::  (Int, GFFAnnotationMap, M.Map B.ByteString Int, M.Map B.ByteString Double) -> Annotator
        finishGffAnnotator (_, amap,namemap,szmap) = GFFAnnotator amap' headers szmap
            where (amap' :!: headers) = reindex amap namemap
        -- The signature looks hairy, but we pass a tuple to have the state while iterating using the fold.
        --  - next: next available ID
        --  - gmap: current annotation map
        --  - namemap: str -> int name to ID
        --  - szmap: str -> double name to feature size
        insertg :: B.ByteString -- ^ feature
                        -> Maybe B.ByteString -- ^ subfeature
                        -> (Int, GFFAnnotationMap, M.Map B.ByteString Int, M.Map B.ByteString Double)
                        -> GffLine
                        -> (Int, GFFAnnotationMap, M.Map B.ByteString Int, M.Map B.ByteString Double)
        insertg f sf cur gline
                | gffType gline /= f = cur
                | otherwise = foldr subfeatureMap cur $ lookupSubFeature sf
            where
                subfeatureMap val (!next, !gmap, !namemap, !szmap) = let
                            header
                                | singleFeature = val
                                | otherwise = B.concat $ [f, "\t"] ++(case sf of { Nothing -> []; Just s -> [s,"\t"]}) ++[val]
                            (!namemap', active, !next') = case M.lookup header namemap of
                                Just v -> (namemap, v, next)
                                Nothing -> (M.insert header next namemap, next, next+1)

                            gmap' :: GFFAnnotationMap
                            gmap' = M.alter insertg' (gffSeqId gline) gmap
                            insertg' immap = Just $ IM.alter
                                                        (\vs -> Just ((gffStrand gline :!: active):fromMaybe [] vs))
                                                        asInterval
                                                        (fromMaybe IM.empty immap)

                            asInterval :: IM.Interval Int
                            asInterval = IM.ClosedInterval (gffStart gline) (gffEnd gline)

                            szmap' = M.alter inserts1 header szmap
                            inserts1 :: Maybe Double -> Maybe Double
                            inserts1 cursize = Just $! convert (gffSize gline) + fromMaybe 0.0 cursize
                        in (next', gmap', namemap', szmap')

                lookupSubFeature :: Maybe B.ByteString -> [B.ByteString]
                lookupSubFeature Nothing = filterSubFeatures "ID" (gffAttrs gline) <|> filterSubFeatures "gene_id" (gffAttrs gline)
                lookupSubFeature (Just s) = filterSubFeatures s (gffAttrs gline)

                filterSubFeatures s sf' = map snd $ (filter ((s ==) . fst)) sf'

        -- First integer IDs are assigned "first come, first served"
        -- `reindex` makes them alphabetical
        reindex :: GFFAnnotationMap -> M.Map B.ByteString Int -> Pair GFFAnnotationMap [B.ByteString]
        reindex amap namemap = (M.map (fmap (map reindexAI)) amap :!: headers)
            where
                headers = M.keys namemap -- these are sorted
                reindexAI :: AnnotationInfo -> AnnotationInfo
                reindexAI (s :!: v) = s :!: (ix2ix VU.! v)
                ix2ix :: VU.Vector Int
                ix2ix = revnamemap namemap

        gffSize :: GffLine -> Int
        gffSize g = (gffEnd g - gffStart g) + 1 -- gff format is inclusive at both ends!



annotateSamLineGFF :: CountOpts -> GFFAnnotationMap -> SamLine -> [Int]
annotateSamLineGFF opts amap samline = case M.lookup rname amap of
        Nothing -> []
        Just im ->  TU.snd <$> (optIntersectMode opts) im lineStrand (sStart, sEnd)
    where
        rname = samRName samline
        sStart = samPos samline
        sEnd   = sStart + samLength samline - 1
        lineStrand :: GffStrand
        lineStrand
            | optStrandSpecific opts = if isPositive samline
                                            then GffPosStrand
                                            else GffNegStrand
            | otherwise = GffUnStranded

filterStrand :: GffStrand -> IM.IntervalMap Int [AnnotationInfo] -> IM.IntervalMap Int [AnnotationInfo]
filterStrand GffUnStranded = id
filterStrand strand = IM.mapMaybe $ \ais -> case filter matchStrand ais of
                                                    [] -> Nothing
                                                    ais' -> Just ais'
    where
        matchStrand (s :!: _) = s == GffUnStranded || s == strand

union :: AnnotationRule
union im strand (sS, sE) =  concat . IM.elems . filterStrand strand . IM.intersecting im $ IM.ClosedInterval sS sE

intersection_strict :: AnnotationRule
intersection_strict im strand (sS, sE) = intersection' $ map (filterStrand strand . IM.containing im) [sS..sE]

intersection_non_empty :: AnnotationRule
intersection_non_empty im strand (sS, sE) = intersection' . filter (not . null) .  map (filterStrand strand . IM.containing subim) $ [sS..sE]
    where
        subim = IM.intersecting im (IM.ClosedInterval sS sE)

intersection' :: [GffIMMap] -> [AnnotationInfo]
intersection' [] = []
intersection' im = concat . IM.elems $ foldl1' IM.intersection im

lookupFilePath context name args = case lookup name args of
    Nothing -> return Nothing
    Just a -> stringOrTypeError context a >>= (expandPath . T.unpack)

