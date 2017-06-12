{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}

module Main where

import Data.Ini.Config.Bidir
import Data.Text (Text, unpack)
import Lens.Micro.TH (makeLenses)

data Config = Config
  { _confUsername      :: Text
  , _confPort          :: Int
  , _confUseEncryption :: Bool
  , _confHostname      :: Text
  , _confConfigFile    :: Maybe Text
  } deriving (Eq, Show)

makeLenses ''Config

sampleConfig :: Config
sampleConfig = Config
  { _confUsername      = "<user>"
  , _confPort          = 8080
  , _confUseEncryption = True
  , _confHostname      = "localhost"
  , _confConfigFile    = Nothing
  }

configSpec :: IniSpec Config ()
configSpec = section "NETWORK" $ do
  confUsername .= field "user" text
    & comment [ "your username" ]
  confPort .= field "port" number
    & comment [ "the port in question" ]
  confUseEncryption .= flag "encryption"
    & defaultValue True
    & comment [ "whether to use encryption (defaults to true)" ]
  confHostname .= field "hostname" text
    & defaultValue "localhost"
    & comment [ "hostname to connect to (optional)" ]
  confConfigFile .=? field "config file" text
    & placeholderValue "<file path>"

example :: Text
example = "[NETWORK]\n\
          \# this contains a comment\n\
          \; and a semicolon comment\n\
          \user: gdritter\n\
          \port: 8888\n"

main :: IO ()
main = do
  let s = parseIniFile sampleConfig configSpec example
  print s
  case s of
    Left err -> putStrLn err
    Right p  -> do
      putStrLn "------------------------"
      putStr (unpack (emitIniFile sampleConfig configSpec))
      putStrLn "------------------------"
      putStrLn "\n"
      let p' = p { _confPort = 9191
                 , _confHostname = "argl"
                 }
      let pol = defaultUpdatePolicy
                  { updateGeneratedCommentPolicy =
                      CommentPolicyAddDefaultComment
                        [ "value added by application" ]
                  , updateIgnoreExtraneousFields = False
                  }
      let up = updateIniFile p' configSpec example pol
      case up of
        Left err  -> putStrLn err
        Right up' -> do
          putStrLn "------------------------"
          putStr (unpack up')
          putStrLn "------------------------"
