module Main where

import Diff
import Patch
import Term
import Syntax
import Control.Comonad.Cofree
import Control.Monad.Free hiding (unfoldM)
import Data.Map
import Data.Maybe
import Data.Set
import System.Environment

import GHC.Generics
import GHC.Prim
import Foreign
import Foreign.C
import Foreign.CStorable
import Foreign.C.Types
import Foreign.C.String
import Foreign.ForeignPtr.Unsafe

data TSLanguage = TsLanguage deriving (Show, Eq, Generic, CStorable)
foreign import ccall "prototype/doubt-difftool/doubt-difftool-Bridging-Header.h ts_language_c" ts_language_c :: IO (Ptr TSLanguage)

data TSDocument = TsDocument deriving (Show, Eq, Generic, CStorable)
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_make" ts_document_make :: IO (Ptr TSDocument)
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_set_language" ts_document_set_language :: Ptr TSDocument -> Ptr TSLanguage -> IO ()
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_set_input_string" ts_document_set_input_string :: Ptr TSDocument -> CString -> IO ()
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_parse" ts_document_parse :: Ptr TSDocument -> IO ()
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_free" ts_document_free :: Ptr TSDocument -> IO ()

data TSLength = TsLength { bytes :: CSize, chars :: CSize }
  deriving (Show, Eq, Generic, CStorable)

instance Storable TSLength where
  alignment n = 16
  sizeOf n = 16
  peek p = return $ TsLength { bytes = 0, chars = 0 }
  poke p n = return ()

data TSNode = TsNode { _data :: Ptr (), offset :: TSLength }
  deriving (Show, Eq, Generic, CStorable)

instance Storable TSNode where
  alignment n = 24
  sizeOf n = 24
  peek p = error "why are you reading from this"
  poke p n = error "why are you writing to this"

foreign import ccall "app/bridge.h ts_document_root_node_p" ts_document_root_node_p :: Ptr TSDocument -> Ptr TSNode -> IO ()
foreign import ccall "app/bridge.h ts_node_p_name" ts_node_p_name :: Ptr TSNode -> Ptr TSDocument -> IO CString
foreign import ccall "app/bridge.h ts_node_p_named_child_count" ts_node_p_named_child_count :: Ptr TSNode -> IO CSize
foreign import ccall "app/bridge.h ts_node_p_named_child" ts_node_p_named_child :: Ptr TSNode -> CSize -> Ptr TSNode -> IO CSize
foreign import ccall "app/bridge.h ts_node_p_pos_chars" ts_node_p_pos_chars :: Ptr TSNode -> IO CSize
foreign import ccall "app/bridge.h ts_node_p_size_chars" ts_node_p_size_chars :: Ptr TSNode -> IO CSize

main :: IO ()
main = do
  args <- getArgs
  let (a, b) = files args in do
    a' <- parseTreeSitterFile a
    b' <- parseTreeSitterFile b
    return (a', b')
  return ()

parseTreeSitterFile :: FilePath -> IO ()
parseTreeSitterFile file = do
  document <- ts_document_make
  language <- ts_language_c
  ts_document_set_language document language
  contents <- readFile file
  source <- newCString contents
  ts_document_set_input_string document source
  ts_document_parse document
  withAlloc (\root -> do
    ts_document_root_node_p document root
    unfoldM (toTerm document contents) root)
  ts_document_free document
  free source
  putStrLn $ "cSizeOf " ++ show (cSizeOf document)

toTerm :: Ptr TSDocument -> String -> Ptr TSNode -> IO (Info, Syntax String (Ptr TSNode))
toTerm document contents node = do
  name <- ts_node_p_name node document
  name <- peekCString name
  children <- namedChildren node
  range <- range node
  annotation <- return . Info range $ Data.Set.fromList [ name ]
  return (annotation, case children of
    [] -> Leaf $ substring range contents
    _ | Data.Set.member name fixedProductions -> Fixed children
    _ | otherwise -> Indexed children)
  where
    keyedProductions = Data.Set.fromList [ "object" ]
    fixedProductions = Data.Set.fromList [ "pair", "rel_op", "math_op", "bool_op", "bitwise_op", "type_op", "math_assignment", "assignment", "subscript_access", "member_access", "new_expression", "function_call", "function", "ternary" ]

withAlloc :: Storable a => (Ptr a -> IO b) -> IO b
withAlloc f = do
  bytes <- malloc
  f bytes

namedChildren :: Ptr TSNode -> IO [Ptr TSNode]
namedChildren node = do
  count <- ts_node_p_named_child_count node
  if count == 0
    then return []
    else mapM (withAlloc . getChild) [0..pred count] where
      getChild n out = do
        ts_node_p_named_child node n out
        return out

range :: Ptr TSNode -> IO Range
range node = do
  pos <- ts_node_p_pos_chars node
  size <- ts_node_p_size_chars node
  return Range { start = fromEnum $ toInteger pos, end = (fromEnum $ toInteger pos) + (fromEnum $ toInteger size) }

files (a : as) = (a, file as) where
  file (a : as) = a
files [] = error "expected two files to diff"

substring :: Range -> String -> String
substring range = take (end range) . drop (start range)
