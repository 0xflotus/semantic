{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DataKinds, TypeOperators #-}
module TOCSpec where

import Data.Aeson
import Data.Bifunctor
import Data.Blob
import Data.ByteString (ByteString)
import Data.Diff
import Data.Functor.Both
import Data.Functor.Listable
import Data.Maybe (fromMaybe)
import Data.Monoid (Last(..))
import Data.Output
import Data.Patch
import Data.Range
import Data.Record
import Data.Semigroup ((<>))
import Data.Source
import Data.Span
import Data.Syntax.Algebra (constructorNameAndConstantFields)
import Data.Term
import Data.Text (Text)
import Data.These
import Interpreter
import Language
import Prelude hiding (readFile)
import Renderer
import Renderer.TOC
import RWS
import Semantic
import Semantic.Task
import Semantic.Util
import SpecHelpers
import Test.Hspec (Spec, describe, it, parallel)
import Test.Hspec.Expectations.Pretty
import Test.Hspec.LeanCheck
import Test.LeanCheck
import Parser

spec :: Spec
spec = parallel $ do
  describe "tableOfContentsBy" $ do
    prop "drops all nodes with the constant Nothing function" $
      \ diff -> tableOfContentsBy (const Nothing :: a -> Maybe ()) (diff :: Diff ListableSyntax () ()) `shouldBe` []

    let diffSize = max 1 . length . diffPatches
    let lastValue a = fromMaybe (extract a) (getLast (foldMap (Last . Just) a))
    prop "includes all nodes with a constant Just function" $
      \ diff -> let diff' = (diff :: Diff ListableSyntax () ()) in entryPayload <$> tableOfContentsBy (const (Just ())) diff' `shouldBe` replicate (diffSize diff') ()

    prop "produces an unchanged entry for identity diffs" $
      \ term -> tableOfContentsBy (Just . termAnnotation) (diffTerms term term) `shouldBe` [Unchanged (lastValue (term :: Term ListableSyntax (Record '[String])))]

    prop "produces inserted/deleted/replaced entries for relevant nodes within patches" $
      \ p -> tableOfContentsBy (Just . termAnnotation) (patch deleting inserting replacing p)
      `shouldBe`
      patch (fmap Deleted) (fmap Inserted) (const (fmap Replaced)) (bimap (foldMap pure) (foldMap pure) (p :: Patch (Term ListableSyntax Int) (Term ListableSyntax Int)))

    prop "produces changed entries for relevant nodes containing irrelevant patches" $
      \ diff -> let diff' = merge (0, 0) (Indexed [bimap (const 1) (const 1) (diff :: Diff ListableSyntax Int Int)]) in
        tableOfContentsBy (\ (n `In` _) -> if n == (0 :: Int) then Just n else Nothing) diff' `shouldBe`
        if null (diffPatches diff') then [Unchanged 0]
                                    else replicate (length (diffPatches diff')) (Changed 0)

  describe "diffTOC" $ do
    it "blank if there are no methods" $
      diffTOC blankDiff `shouldBe` [ ]

    it "summarizes changed methods" $ do
      sourceBlobs <- blobsForPaths (both "ruby/methods.A.rb" "ruby/methods.B.rb")
      diff <- runTask $ diffWithParser rubyParser sourceBlobs
      diffTOC diff `shouldBe`
        [ JSONSummary "Method" "self.foo" (sourceSpanBetween (1, 1) (2, 4)) "modified"
        , JSONSummary "Method" "bar" (sourceSpanBetween (4, 1) (6, 4)) "modified" ]

    it "dedupes changes in same parent method" $ do
      sourceBlobs <- blobsForPaths (both "javascript/duplicate-parent.A.js" "javascript/duplicate-parent.B.js")
      diff <- runTask $ diffWithParser typescriptParser sourceBlobs
      diffTOC diff `shouldBe`
        [ JSONSummary "Function" "myFunction" (sourceSpanBetween (1, 1) (6, 2)) "modified" ]

    it "dedupes similar methods" $ do
      sourceBlobs <- blobsForPaths (both "javascript/erroneous-duplicate-method.A.js" "javascript/erroneous-duplicate-method.B.js")
      diff <- runTask $ diffWithParser typescriptParser sourceBlobs
      diffTOC diff `shouldBe`
        [ JSONSummary "Function" "performHealthCheck" (sourceSpanBetween (8, 1) (29, 2)) "modified" ]

    it "summarizes Go methods with receivers with special formatting" $ do
      sourceBlobs <- blobsForPaths (both "go/method-with-receiver.A.go" "go/method-with-receiver.B.go")
      diff <- runTask $ diffWithParser goParser sourceBlobs
      diffTOC diff `shouldBe`
        [ JSONSummary "Method" "(*apiClient) CheckAuth" (sourceSpanBetween (3,1) (3,101)) "added" ]

    it "summarizes Ruby methods that start with two identifiers" $ do
      sourceBlobs <- blobsForPaths (both "ruby/method-starts-with-two-identifiers.A.rb" "ruby/method-starts-with-two-identifiers.B.rb")
      diff <- runTask $ diffWithParser rubyParser sourceBlobs
      diffTOC diff `shouldBe`
        [ JSONSummary "Method" "foo" (sourceSpanBetween (1, 1) (4, 4)) "modified" ]

    it "handles unicode characters in file" $ do
      sourceBlobs <- blobsForPaths (both "ruby/unicode.A.rb" "ruby/unicode.B.rb")
      diff <- runTask $ diffWithParser rubyParser sourceBlobs
      diffTOC diff `shouldBe`
        [ JSONSummary "Method" "foo" (sourceSpanBetween (6, 1) (7, 4)) "added" ]

    it "properly slices source blob that starts with a newline and has multi-byte chars" $ do
      sourceBlobs <- blobsForPaths (both "javascript/starts-with-newline.js" "javascript/starts-with-newline.js")
      diff <- runTask $ diffWithParser rubyParser sourceBlobs
      diffTOC diff `shouldBe` []

    prop "inserts of methods and functions are summarized" $
      \name body ->
        let diff = programWithInsert name body
        in numTocSummaries diff `shouldBe` 1

    prop "deletes of methods and functions are summarized" $
      \name body ->
        let diff = programWithDelete name body
        in numTocSummaries diff `shouldBe` 1

    prop "replacements of methods and functions are summarized" $
      \name body ->
        let diff = programWithReplace name body
        in numTocSummaries diff `shouldBe` 1

    prop "changes inside methods and functions are summarizied" . forAll (isMeaningfulTerm `filterT` tiers) $
      \body ->
        let diff = programWithChange body
        in numTocSummaries diff `shouldBe` 1

    prop "other changes don't summarize" . forAll ((not . isMethodOrFunction) `filterT` tiers) $
      \body ->
        let diff = programWithChangeOutsideFunction body
        in numTocSummaries diff `shouldBe` 0

    prop "equal terms produce identity diffs" $
      \a -> let term = defaultFeatureVectorDecorator constructorNameAndConstantFields (a :: Term') in
        diffTOC (diffTerms term term) `shouldBe` []

  describe "JSONSummary" $ do
    it "encodes modified summaries to JSON" $ do
      let summary = JSONSummary "Method" "foo" (sourceSpanBetween (1, 1) (4, 4)) "modified"
      encode summary `shouldBe` "{\"span\":{\"start\":[1,1],\"end\":[4,4]},\"category\":\"Method\",\"term\":\"foo\",\"changeType\":\"modified\"}"

    it "encodes added summaries to JSON" $ do
      let summary = JSONSummary "Method" "self.foo" (sourceSpanBetween (1, 1) (2, 4)) "added"
      encode summary `shouldBe` "{\"span\":{\"start\":[1,1],\"end\":[2,4]},\"category\":\"Method\",\"term\":\"self.foo\",\"changeType\":\"added\"}"

  describe "diff with ToCDiffRenderer'" $ do
    it "produces JSON output" $ do
      blobs <- blobsForPaths (both "ruby/methods.A.rb" "ruby/methods.B.rb")
      output <- runTask (diffBlobPair ToCDiffRenderer blobs)
      toOutput output `shouldBe` ("{\"changes\":{\"test/fixtures/toc/ruby/methods.A.rb -> test/fixtures/toc/ruby/methods.B.rb\":[{\"span\":{\"start\":[1,1],\"end\":[2,4]},\"category\":\"Method\",\"term\":\"self.foo\",\"changeType\":\"modified\"},{\"span\":{\"start\":[4,1],\"end\":[6,4]},\"category\":\"Method\",\"term\":\"bar\",\"changeType\":\"modified\"}]},\"errors\":{}}\n" :: ByteString)

    it "produces JSON output if there are parse errors" $ do
      blobs <- blobsForPaths (both "ruby/methods.A.rb" "ruby/methods.X.rb")
      output <- runTask (diffBlobPair ToCDiffRenderer blobs)
      toOutput output `shouldBe` ("{\"changes\":{\"test/fixtures/toc/ruby/methods.A.rb -> test/fixtures/toc/ruby/methods.X.rb\":[{\"span\":{\"start\":[1,1],\"end\":[2,4]},\"category\":\"Method\",\"term\":\"bar\",\"changeType\":\"removed\"},{\"span\":{\"start\":[4,1],\"end\":[5,4]},\"category\":\"Method\",\"term\":\"baz\",\"changeType\":\"removed\"}]},\"errors\":{\"test/fixtures/toc/ruby/methods.A.rb -> test/fixtures/toc/ruby/methods.X.rb\":[{\"span\":{\"start\":[1,1],\"end\":[3,1]},\"error\":\"expected end of input nodes, but got ParseError\",\"language\":\"Ruby\"}]}}\n" :: ByteString)

    it "ignores anonymous functions" $ do
      blobs <- blobsForPaths (both "ruby/lambda.A.rb" "ruby/lambda.B.rb")
      output <- runTask (diffBlobPair ToCDiffRenderer blobs)
      toOutput output `shouldBe` ("{\"changes\":{},\"errors\":{}}\n" :: ByteString)

    it "summarizes Markdown headings" $ do
      blobs <- blobsForPaths (both "markdown/headings.A.md" "markdown/headings.B.md")
      output <- runTask (diffBlobPair ToCDiffRenderer blobs)
      toOutput output `shouldBe` ("{\"changes\":{\"test/fixtures/toc/markdown/headings.A.md -> test/fixtures/toc/markdown/headings.B.md\":[{\"span\":{\"start\":[5,1],\"end\":[7,10]},\"category\":\"Heading 2\",\"term\":\"Two\",\"changeType\":\"added\"},{\"span\":{\"start\":[9,1],\"end\":[10,4]},\"category\":\"Heading 1\",\"term\":\"Final\",\"changeType\":\"added\"}]},\"errors\":{}}\n" :: ByteString)


type Diff' = Diff ListableSyntax (Record '[Maybe Declaration, Range, Span]) (Record '[Maybe Declaration, Range, Span])
type Term' = Term ListableSyntax (Record '[Maybe Declaration, Range, Span])

numTocSummaries :: Diff' -> Int
numTocSummaries diff = length $ filter isValidSummary (diffTOC diff)

-- Return a diff where body is inserted in the expressions of a function. The function is present in both sides of the diff.
programWithChange :: Term' -> Diff'
programWithChange body = merge (programInfo, programInfo) (Indexed [ function' ])
  where
    function' = merge ((Just (FunctionDeclaration "foo") :. functionInfo, Just (FunctionDeclaration "foo") :. functionInfo)) (S.Function name' [] [ inserting body ])
    name' = let info = Nothing :. Range 0 0 :. sourceSpanBetween (0,0) (0,0) :. Nil in merge (info, info) (Leaf "foo")

-- Return a diff where term is inserted in the program, below a function found on both sides of the diff.
programWithChangeOutsideFunction :: Term' -> Diff'
programWithChangeOutsideFunction term = merge (programInfo, programInfo) (Indexed [ function', term' ])
  where
    function' = merge (Just (FunctionDeclaration "foo") :. functionInfo, Just (FunctionDeclaration "foo") :. functionInfo) (S.Function name' [] [])
    name' = let info = Nothing :. Range 0 0 :. sourceSpanBetween (0,0) (0,0) :. Nil in  merge (info, info) (Leaf "foo")
    term' = inserting term

programWithInsert :: Text -> Term' -> Diff'
programWithInsert name body = programOf $ inserting (functionOf name body)

programWithDelete :: Text -> Term' -> Diff'
programWithDelete name body = programOf $ deleting (functionOf name body)

programWithReplace :: Text -> Term' -> Diff'
programWithReplace name body = programOf $ replacing (functionOf name body) (functionOf (name <> "2") body)

programOf :: Diff' -> Diff'
programOf diff = merge (programInfo, programInfo) (Indexed [ diff ])

functionOf :: Text -> Term' -> Term'
functionOf name body = Term $ (Just (FunctionDeclaration name) :. functionInfo) `In` S.Function name' [] [body]
  where
    name' = Term $ (Nothing :. Range 0 0 :. sourceSpanBetween (0,0) (0,0) :. Nil) `In` Leaf name

programInfo :: Record '[Maybe Declaration, Range, Span]
programInfo = Nothing :. Range 0 0 :. sourceSpanBetween (0,0) (0,0) :. Nil

functionInfo :: Record '[Range, Span]
functionInfo = Range 0 0 :. sourceSpanBetween (0,0) (0,0) :. Nil

-- Filter tiers for terms that we consider "meaniningful" in TOC summaries.
isMeaningfulTerm :: Term Syntax a -> Bool
isMeaningfulTerm a
  | (_:_) <- prj (termOut (unTerm a)) = False
  | [] <- prj (termOut (unTerm a)) = False
  | otherwise = True

-- Filter tiers for terms if the Syntax is a Method or a Function.
isMethodOrFunction :: HasField fields Category => Term Syntax (Record fields) -> Bool
isMethodOrFunction a = case unTerm a of
  (_ `In` S.Method{}) -> True
  (_ `In` S.Function{}) -> True
  (a `In` _) | getField a == C.Function -> True
  (a `In` _) | getField a == C.Method -> True
  (a `In` _) | getField a == C.SingletonMethod -> True
  _ -> False

blobsForPaths :: Both FilePath -> IO (Both Blob)
blobsForPaths = traverse (readFile . ("test/fixtures/toc/" <>))

sourceSpanBetween :: (Int, Int) -> (Int, Int) -> Span
sourceSpanBetween (s1, e1) (s2, e2) = Span (Pos s1 e1) (Pos s2 e2)

blankDiff :: Diff'
blankDiff = merge (arrayInfo, arrayInfo) (Indexed [ inserting (Term $ literalInfo `In` Leaf "\"a\"") ])
  where
    arrayInfo = Nothing :. Range 0 3 :. sourceSpanBetween (1, 1) (1, 5) :. Nil
    literalInfo = Nothing :. Range 1 2 :. sourceSpanBetween (1, 2) (1, 4) :. Nil

blankDiffBlobs :: Both Blob
blankDiffBlobs = both (Blob (fromText "[]") nullOid "a.js" (Just defaultPlainBlob) (Just TypeScript)) (Blob (fromText "[a]") nullOid "b.js" (Just defaultPlainBlob) (Just TypeScript))
