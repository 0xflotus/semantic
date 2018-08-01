{-# LANGUAGE TypeFamilies, TypeOperators #-}
{-# OPTIONS_GHC -Wno-missing-signatures -Wno-missing-export-lists #-}
module Semantic.Util where

import Prelude hiding (readFile)

import           Analysis.Abstract.Caching
import           Analysis.Abstract.Collecting
import           Control.Abstract
import           Control.Exception (displayException)
import           Control.Monad.Effect.Trace (runPrintingTrace)
import           Data.Abstract.Address
import           Data.Abstract.Evaluatable
import           Data.Abstract.Module
import qualified Data.Abstract.ModuleTable as ModuleTable
import           Data.Abstract.Package
import           Data.Abstract.Value.Concrete as Concrete
import           Data.Abstract.Value.Type as Type
import           Data.Blob
import           Data.Coerce
import           Data.Graph (topologicalSort)
import qualified Data.Language as Language
import           Data.List (uncons)
import           Data.Project hiding (readFile)
import           Data.Quieterm (quieterm)
import           Data.Sum (weaken)
import           Language.Haskell.HsColour
import           Language.Haskell.HsColour.Colourise
import           Parsing.Parser
import           Prologue hiding (weaken)
import           Semantic.Config
import           Semantic.Graph
import           Semantic.IO as IO
import           Semantic.Task
import           Semantic.Telemetry (LogQueue, StatQueue)
import           System.Exit (die)
import           System.FilePath.Posix (takeDirectory)
import           Text.Show.Pretty (ppShow)

justEvaluating
  = runM
  . runState lowerBound
  . runFresh 0
  . runPrintingTrace
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runEnvironmentError
  . runEvalError
  . runResolutionError
  . runAddressError
  . runValueError

newtype UtilEff address a = UtilEff
  { runUtilEff :: Eff '[ Function address (Value address (UtilEff address))
                       , Exc (LoopControl address)
                       , Exc (Return address)
                       , Env address
                       , Deref address (Value address (UtilEff address))
                       , Allocator address (Value address (UtilEff address))
                       , Reader ModuleInfo
                       , Modules address
                       , Reader (ModuleTable (NonEmpty (Module (ModuleResult address))))
                       , Reader Span
                       , Reader PackageInfo
                       , Resumable (ValueError address (UtilEff address))
                       , Resumable (AddressError address (Value address (UtilEff address)))
                       , Resumable ResolutionError
                       , Resumable EvalError
                       , Resumable (EnvironmentError address)
                       , Resumable (Unspecialized (Value address (UtilEff address)))
                       , Resumable (LoadError address)
                       , Trace
                       , Fresh
                       , State (Heap address Latest (Value address (UtilEff address)))
                       , Lift IO
                       ] a
  }

checking
  = runM @_ @IO
  . runState (lowerBound @(Heap Monovariant All Type))
  . runFresh 0
  . runPrintingTrace
  . runTermEvaluator @_ @Monovariant @Type
  . caching
  . providingLiveSet
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runResolutionError
  . runEnvironmentError
  . runEvalError
  . runAddressError
  . runTypes

evalGoProject         = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Go)         goParser         Language.Go
evalRubyProject       = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Ruby)       rubyParser       Language.Ruby
evalPHPProject        = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.PHP)        phpParser        Language.PHP
evalPythonProject     = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Python)     pythonParser     Language.Python
evalJavaScriptProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.JavaScript) typescriptParser Language.JavaScript
evalTypeScriptProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.TypeScript) typescriptParser Language.TypeScript

typecheckGoFile = checking <=< evaluateProjectWithCaching (Proxy :: Proxy 'Language.Go) goParser Language.Go

callGraphProject parser proxy lang opts paths = runTaskWithOptions opts $ do
  blobs <- catMaybes <$> traverse readFile (flip File lang <$> paths)
  package <- parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs lang [])
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  x <- runCallGraph proxy False modules package
  pure (x, (() <$) <$> modules)

callGraphRubyProject = callGraphProject rubyParser (Proxy @'Language.Ruby) Language.Ruby debugOptions

-- Evaluate a project consisting of the listed paths.
evaluateProject proxy parser lang paths = withOptions debugOptions $ \ config logger statter ->
  evaluateProject' (TaskConfig config logger statter) proxy parser lang paths

data TaskConfig = TaskConfig Config LogQueue StatQueue

evaluateProject' (TaskConfig config logger statter) proxy parser lang paths = either (die . displayException) pure <=< runTaskWithConfig config logger statter $ do
  blobs <- catMaybes <$> traverse readFile (flip File lang <$> paths)
  package <- fmap quieterm <$> parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs lang [])
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  trace $ "evaluating with load order: " <> show (map (modulePath . moduleInfo) modules)
  pure (runTermEvaluator @_ @_ @(Value Precise (UtilEff Precise))
       (runReader (packageInfo package)
       (runReader (lowerBound @Span)
       (runReader (lowerBound @(ModuleTable (NonEmpty (Module (ModuleResult Precise)))))
       (raiseHandler (runModules (ModuleTable.modulePaths (packageModules package)))
       (evaluate proxy id withTermSpans (Concrete.runFunction coerce coerce) modules))))))


evaluateProjectWithCaching proxy parser lang path = runTaskWithOptions debugOptions $ do
  project <- readProject Nothing path lang []
  package <- fmap quieterm <$> parsePackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  pure (runReader (packageInfo package)
       (runReader (lowerBound @Span)
       (runReader (lowerBound @(ModuleTable (NonEmpty (Module (ModuleResult Monovariant)))))
       (raiseHandler (runModules (ModuleTable.modulePaths (packageModules package)))
       (evaluate proxy id withTermSpans Type.runFunction modules)))))


parseFile :: Parser term -> FilePath -> IO term
parseFile parser = runTask . (parse parser <=< readBlob . file)

blob :: FilePath -> IO Blob
blob = runTask . readBlob . file


mergeExcs :: Either (SomeExc (Sum excs)) (Either (SomeExc exc) result) -> Either (SomeExc (Sum (exc ': excs))) result
mergeExcs = either (\ (SomeExc sum) -> Left (SomeExc (weaken sum))) (either (\ (SomeExc exc) -> Left (SomeExc (inject exc))) Right)

reassociate :: Either (SomeExc exc1) (Either (SomeExc exc2) (Either (SomeExc exc3) (Either (SomeExc exc4) (Either (SomeExc exc5) (Either (SomeExc exc6) (Either (SomeExc exc7) result)))))) -> Either (SomeExc (Sum '[exc7, exc6, exc5, exc4, exc3, exc2, exc1])) result
reassociate = mergeExcs . mergeExcs . mergeExcs . mergeExcs . mergeExcs . mergeExcs . mergeExcs . Right


prettyShow :: Show a => a -> IO ()
prettyShow = putStrLn . hscolour TTY defaultColourPrefs False False "" False . ppShow
