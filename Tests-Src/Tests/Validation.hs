{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}
module Tests.Validation
    ( tgroup_Validation
    ) where

import Test.Tasty.TH
import Test.Tasty.HUnit
import Control.Monad
import Data.Either.Combinators (isRight)
import qualified Data.Text as T

import Tests.Utils
import Validation
import ValidationIO
import Utils.Here
import BuiltinFunctions (builtinModule)
import NGLess.NGLEnvironment (NGLVersion(..))
import Utils.Suggestion (findSuggestion, Suggestion(..))
import BuiltinModules.QCStats qualified as ModQCStats

tgroup_Validation = $(testGroupGenerator)

-- Pure Validation

mods = [builtinModule (NGLVersion 1 3), ModQCStats.pureMod]

isValidateOk ftext = case parsetest ftext >>= validate mods of
    Right _ -> return ()
    Left err -> assertFailure ("Validation should have passed for script "++T.unpack ftext++"; instead picked up error: '"++show err++"'")
isValidateError ftext = isErrorMsg ("Validation should have picked error for script '"++T.unpack ftext++"'") (parsetest ftext >>= validate mods)

case_bad_function_attr_count = isValidateError [here|
ngless '1.5'
count(annotated, features='gene')|]

case_bad_symbol_arg = isValidateError
    [here|
ngless '1.4'
input = fastq('input.fq.gz')
write(
    map(input, reference='sacCer3'),
            ofile='result.sam',
            format={yolo})
|]

case_bad_symbol_arg0 = isValidateError [here|
ngless '1.4'
input = fastq('input.fq.gz')
output = map(input, reference='sacCer3')
write(qcstats({yolo}), ofile='result.tsv')
|]

case_good_symbol_arg0 = isValidateOk [here|
ngless '1.4'
input = fastq('input.fq.gz')
output = map(input, reference='sacCer3')
write(qcstats({mapping}), ofile='result.tsv')
|]

case_map_not_assigned = isValidateError
    [here|
ngless '1.5'
input = fasq('input.fq.gz')
map(input,reference='sacCer3')
|]

case_good_function_attr_map = isValidateOk
    [here|
ngless '1.5'
input = fastq('input.fq.gz')
write(
    map(input, reference='sacCer3'),
            ofile='result.sam',
            format={sam})
|]


-- Validate IO

validateIO_Ok script = do
    err <- testNGLessIO $ validateIO mods (fromRight . parsetest $ script)
    case err of
        Nothing -> assertBool "" True
        Just errmsg -> assertFailure (concat ["Expected no errors in validation, got ", show errmsg, ".\nScript was::\n\n", show script])

validateIO_error script = do
    err <- testNGLessIO $ validateIO mods (fromRight . parsetest $ script)
    case err of
        Nothing -> assertFailure (concat ["ValidateIO should have detected an error on the script ", show script])
        Just _ -> return ()

validate_Error script =
    when (isRight $ parsetest script >>= validate []) $
        assertFailure (concat ["Validate (pure) should have detected an error on the script ", show script])

case_fastq_inexistence_file = validateIO_error [here|
ngless '1.5'
fastq('THIS_FILE_DOES_NOT_EXIST_SURELY.fq')
|]

case_invalid_not_pure_fp_fastq_lit = validateIO_Ok [here|
ngless '1.5'
fastq('Makefile')|] --File Makefile exists

case_build_path = validateIO_Ok [here|
ngless '1.5'
part1 = 'Make'
part2 = 'file'
fastq(part1 + part2)
|]

case_valid_not_pure_fp_fastq_const = validateIO_error
    "ngless '1.5'\n\
    \x = 'fq'\n\
    \fastq(x)\n"

case_invalid_not_pure_fp_fastq_const = validateIO_Ok
    "ngless '1.5'\n\
    \x = 'Makefile'\n\
    \fastq(x)\n" --When run in source directory, Makefile exists


case_valid_not_pure_map_reference_lit = validateIO_Ok
    "ngless '1.5'\n\
    \map(x, fafile='Makefile')\n"

case_invalid_not_pure_map_def_reference_lit = validateIO_Ok
    "ngless '1.5'\n\
    \map(x, reference='sacCer3')\n"

case_invalid_not_pure_map_reference_lit = validateIO_error
    "ngless '1.5'\n\
    \map(x, fafile='THIS_FILE_DOES_NOT_EXIST_SURELY.fa')\n"

case_inexistent_reference = validateIO_error
    "ngless '1.5'\n\
    \map(x, reference='UNKNOWN_REFERENCE')\n"


case_fafile_through_variable = validateIO_Ok
    "ngless '1.5'\n\
    \v = 'Makefile'\n\
    \map(x, fafile=v)\n"

case_invalid_not_pure_map_def_reference_const = validateIO_Ok
    "ngless '1.5'\n\
    \v = 'sacCer3'\n\
    \map(x, reference=v)\n"

case_invalid_not_pure_map_reference_const = validateIO_error
    "ngless '1.5'\n\
    \v = 'THIS_FILE_DOES_NOT_EXIST_SURELY.fa'\n\
    \map(x, reference=v)\n"


case_valid_not_pure_annotate_gff_lit = validateIO_Ok
    "ngless '1.5'\n\
    \count(x, gff_file='Makefile')\n"

case_invalid_not_pure_annotate_gff_lit = validateIO_error [here|
ngless '1.5'
count(x, gff_file='THIS_FILE_DOES_NOT_EXIST_SURELY.gff')
|]

case_samfile_check_file = validateIO_error [here|
ngless '1.5'
mapped = samfile('THIS_FILE_DOES_NOT_EXIST_SURELY.sam')
write(mapped, ofile='copy.sam')
|]

case_valid_not_pure_annotate_gff_const = validateIO_Ok
    "ngless '1.5'\n\
    \v = 'Makefile'\n\
    \count(x, gff_file=v)\n"

case_invalid_not_pure_annotate_gff_const = validateIO_error
    "ngless '1.5'\n\
    \v = 'THIS_FILE_DOES_NOT_EXIST_SURELY.gff'\n\
    \count(x, gff_file=v)\n"


case_valid_not_pure_annotate_gff_const2 = validateIO_Ok
    "ngless '1.5'\n\
    \v = 'fq'\n\
    \v = 'Makefile'\n\
    \count(x, gff_file=v)\n"

case_validate_internal_call = validate_Error
    "ngless '1.5'\n\
    \write(select(samfile('f.sam'), keep_if=[{matched}]), ofile=STDOUT)\n"

case_validate_no_assign_constant = isValidateError [here|
ngless '1.5'
CONST = 1
CONST = 2
|]

case_validate_assign_variable = isValidateOk [here|
ngless '1.5'
notConst = 1
notConst = 2
|]

assertSuggested :: T.Text -> Maybe Suggestion -> Assertion
assertSuggested s Nothing = assertFailure $ "Expected suggestion " ++ show s ++ " but got Nothing"
assertSuggested s (Just (Suggestion s' _))
    | s == s' = return ()
    | otherwise = assertFailure $ "Expected suggestion " ++ show s ++ " but got " ++ show s'


case_find_suggestion_case = do
    assertSuggested "fastq" $ findSuggestion "fastQ" ["fastq", "other"]
    assertSuggested "fastq" $ findSuggestion "FASTQ" ["first", "fastq", "other"]

case_find_suggestion_prefix = do
    assertSuggested "fastq" $ findSuggestion "fast" ["first", "fastq", "other"]
    assertSuggested "reference" $ findSuggestion "ref" ["first", "reference", "other"]

case_find_suggestion_typo = do
    assertSuggested "fastq" $ findSuggestion "fqstq" ["first", "fastq", "other"]
