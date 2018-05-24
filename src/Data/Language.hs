{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
module Data.Language where

import Prologue
import Data.Aeson

-- | A programming language.
data Language
    = Go
    | Haskell
    | JavaScript
    | JSON
    | JSX
    | Markdown
    | Python
    | Ruby
    | TypeScript
    | PHP
    deriving (Eq, Generic, Ord, Read, Show, ToJSON)

-- | Returns a Language based on the file extension (including the ".").
languageForType :: String -> Maybe Language
languageForType mediaType = case mediaType of
    ".json" -> Just JSON
    ".hs" -> Just Haskell
    ".md" -> Just Markdown
    ".rb" -> Just Ruby
    ".go" -> Just Go
    ".js" -> Just JavaScript
    ".ts" -> Just TypeScript
    ".tsx" -> Just TypeScript
    ".jsx" -> Just JSX
    ".py" -> Just Python
    ".php" -> Just PHP
    ".phpt" -> Just PHP
    _ -> Nothing

extensionsForLanguage :: Language -> [String]
extensionsForLanguage language = case language of
  Go -> [".go"]
  Haskell -> [".hs"]
  JavaScript -> [".js"]
  PHP -> [".php"]
  Python -> [".py"]
  Ruby -> [".rb"]
  TypeScript -> [".ts", ".tsx", ".d.tsx"]
  _ -> []
