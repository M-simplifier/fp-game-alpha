{-# LANGUAGE OverloadedStrings #-}

-- | Domain failures remain data until the user-facing boundary.
module FpGame.Error
  ( ErrorCode (..),
    ToolError (..),
    failTool,
    codeText,
  )
where

import Control.Exception (Exception, throwIO)
import Data.Text (Text)
import Data.Text qualified as Text

data ErrorCode
  = InvalidArguments
  | InvalidProject
  | InvalidConfig
  | UnsafePath
  | MissingTool
  | UnsupportedRoute
  | DestinationExists
  | SourceChanged
  | ToolIO
  deriving (Eq, Show)

data ToolError = ToolError ErrorCode Text deriving (Show)

instance Exception ToolError

failTool :: ErrorCode -> String -> IO a
failTool code = throwIO . ToolError code . Text.pack

codeText :: ErrorCode -> Text
codeText code = case code of
  InvalidArguments -> "invalid-arguments"
  InvalidProject -> "invalid-project"
  InvalidConfig -> "invalid-config"
  UnsafePath -> "unsafe-path"
  MissingTool -> "missing-tool"
  UnsupportedRoute -> "unsupported-route"
  DestinationExists -> "destination-exists"
  SourceChanged -> "source-changed"
  ToolIO -> "io-error"
