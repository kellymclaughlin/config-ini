{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Data.Ini.Config
(
-- $main
-- * Running Parsers
  parseIniFile
-- * Parser Types
, IniParser
, SectionParser
-- * Section-Level Parsing
, section
, sectionMb
, sectionDef
-- * Field-Level Parsing
, field
, fieldOf
, fieldMb
, fieldMbOf
, fieldDef
, fieldDefOf
, fieldFlag
, fieldFlagDef
-- * Reader Functions
, readable
, number
, string
, flag
) where

import           Control.Applicative (Applicative(..), Alternative(..))
import           Control.Monad.Trans.Except
import qualified Data.HashMap.Strict as HM
import           Data.Ini.Config.Raw
import           Data.String (IsString(..))
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Typeable (Typeable, Proxy(..), typeRep)
import           Text.Read (readMaybe)

addLineInformation :: Int -> Text -> StParser s a -> StParser s a
addLineInformation lineNo sec = withExceptT go
  where go e = "Line " ++ show lineNo ++
               ", in section " ++ show sec ++
               ": " ++ e

type StParser s a = ExceptT String ((->) s) a

-- | An 'IniParser' value represents a computation for parsing entire
--   INI-format files.
newtype IniParser a = IniParser (StParser Ini a)
  deriving (Functor, Applicative, Alternative, Monad)

-- | A 'SectionParser' value represents a computation for parsing a single
--   section of an INI-format file.
newtype SectionParser a = SectionParser (StParser IniSection a)
  deriving (Functor, Applicative, Alternative, Monad)

-- | Parse a 'Text' value as an INI file and run an 'IniParser' over it
parseIniFile :: Text -> IniParser a -> Either String a
parseIniFile text (IniParser mote) = do
  ini <- parseIni text
  runExceptT mote ini

-- | Find a named section in the INI file and parse it with the provided
--   section parser, failing if the section does not exist. In order to
--   support classic INI files with capitalized section names, section
--   lookup is __case-insensitive__.
--
--   >>> parseIniFile "[ONE]\nx = hello\n" $ section "ONE" (field "x")
--   Right "hello"
--   >>> parseIniFile "[ONE]\nx = hello\n" $ section "TWO" (field "x")
--   Left "No top-level section named \"TWO\""
section :: Text -> SectionParser a -> IniParser a
section name (SectionParser thunk) = IniParser $ ExceptT $ \(Ini ini) ->
  case HM.lookup (T.toLower name) ini of
    Nothing  -> Left ("No top-level section named " ++ show name)
    Just sec -> runExceptT thunk sec

-- | Find a named section in the INI file and parse it with the provided
--   section parser, returning 'Nothing' if the section does not exist.
--   In order to
--   support classic INI files with capitalized section names, section
--   lookup is __case-insensitive__.
--
--   >>> parseIniFile "[ONE]\nx = hello\n" $ sectionMb "ONE" (field "x")
--   Right (Just "hello")
--   >>> parseIniFile "[ONE]\nx = hello\n" $ sectionMb "TWO" (field "x")
--   Right Nothing
sectionMb :: Text -> SectionParser a -> IniParser (Maybe a)
sectionMb name (SectionParser thunk) = IniParser $ ExceptT $ \(Ini ini) ->
  case HM.lookup (T.toLower name) ini of
    Nothing  -> return Nothing
    Just sec -> Just `fmap` runExceptT thunk sec

-- | Find a named section in the INI file and parse it with the provided
--   section parser, returning a default value if the section does not exist.
--   In order to
--   support classic INI files with capitalized section names, section
--   lookup is __case-insensitive__.
--
--   >>> parseIniFile "[ONE]\nx = hello\n" $ sectionDef "ONE" "def" (field "x")
--   Right "hello"
--   >>> parseIniFile "[ONE]\nx = hello\n" $ sectionDef "TWO" "def" (field "x")
--   Right "def"
sectionDef :: Text -> a -> SectionParser a -> IniParser a
sectionDef name def (SectionParser thunk) = IniParser $ ExceptT $ \(Ini ini) ->
  case HM.lookup (T.toLower name) ini of
    Nothing  -> return def
    Just sec -> runExceptT thunk sec

---

throw :: String -> StParser s a
throw msg = ExceptT $ (\ _ -> Left msg)

getSectionName :: StParser IniSection Text
getSectionName = ExceptT $ (\ m -> return (isName m))

rawFieldMb :: Text -> StParser IniSection (Maybe IniValue)
rawFieldMb name = ExceptT $ \m ->
  return (HM.lookup name (isVals m))

rawField :: Text -> StParser IniSection IniValue
rawField name = do
  sec   <- getSectionName
  valMb <- rawFieldMb name
  case valMb of
    Nothing -> throw ("Missing field " ++ show name ++
                      " in section " ++ show sec)
    Just x  -> return x

-- | Retrieve a field, failing if it doesn't exist, and return its raw value.
--
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (field "x")
--   Right "hello"
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (field "y")
--   Left "Missing field \"y\" in section \"MAIN\""
field :: Text -> SectionParser Text
field name = SectionParser $ vValue `fmap` rawField name

-- | Retrieve a field and use the supplied parser to parse it as a value,
--   failing if the field does not exist, or if the parser fails to
--   produce a value.
--
--   >>> parseIniFile "[MAIN]\nx = 72\n" $ section "MAIN" (fieldOf "x" number)
--   Right 72
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldOf "x" number)
--   Left "Line 2, in section \"MAIN\": Unable to parse \"hello\" as a value of type Integer"
--   >>> parseIniFile "[MAIN]\nx = 72\n" $ section "MAIN" (fieldOf "y" number)
--   Left "Missing field \"y\" in section \"MAIN\""
fieldOf :: Text -> (Text -> Either String a) -> SectionParser a
fieldOf name parse = SectionParser $ do
  sec <- getSectionName
  val <- rawField name
  case parse (vValue val) of
    Left err -> addLineInformation (vLineNo val) sec (throw err)
    Right x  -> return x

-- | Retrieve a field, returning a @Nothing@ value if it does not exist.
--
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldMb "x")
--   Right (Just "hello")
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldMb "y")
--   Right Nothing
fieldMb :: Text -> SectionParser (Maybe Text)
fieldMb name = SectionParser $ fmap vValue `fmap` rawFieldMb name

-- | Retrieve a field and parse it according to the given parser, returning
--   @Nothing@ if it does not exist. If the parser fails, then this will
--   fail.
--
--   >>> parseIniFile "[MAIN]\nx = 72\n" $ section "MAIN" (fieldMbOf "x" number)
--   Right (Just 72)
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldMbOf "x" number)
--   Left "Line 2, in section \"MAIN\": Unable to parse \"hello\" as a value of type Integer"
--   >>> parseIniFile "[MAIN]\nx = 72\n" $ section "MAIN" (fieldMbOf "y" number)
--   Right Nothing
fieldMbOf :: Text -> (Text -> Either String a) -> SectionParser (Maybe a)
fieldMbOf name parse = SectionParser $ do
  sec <- getSectionName
  mb <- rawFieldMb name
  case mb of
    Nothing  -> return Nothing
    Just v -> case parse (vValue v) of
      Left err -> addLineInformation (vLineNo v) sec (throw err)
      Right x  -> return (Just x)

-- | Retrieve a field and supply a default value for if it doesn't exist.
--
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldDef "x" "def")
--   Right "hello"
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldDef "y" "def")
--   Right "def"
fieldDef :: Text -> Text -> SectionParser Text
fieldDef name def = SectionParser $ ExceptT $ \m ->
  case HM.lookup name (isVals m) of
    Nothing -> return def
    Just x  -> return (vValue x)

-- | Retrieve a field, parsing it according to the given parser, and returning
--   a default value if it does not exist. If the parser fails, then this will
--   fail.
--
--   >>> parseIniFile "[MAIN]\nx = 72\n" $ section "MAIN" (fieldDefOf "x" number 99)
--   Right 72
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldDefOf "x" number 99)
--   Left "Line 2, in section \"MAIN\": Unable to parse \"hello\" as a value of type Integer"
--   >>> parseIniFile "[MAIN]\nx = 72\n" $ section "MAIN" (fieldDefOf "y" number 99)
--   Right 99
fieldDefOf :: Text -> (Text -> Either String a) -> a -> SectionParser a
fieldDefOf name parse def = SectionParser $ do
  sec <- getSectionName
  mb <- rawFieldMb name
  case mb of
    Nothing  -> return def
    Just v -> case parse (vValue v) of
      Left err -> addLineInformation (vLineNo v) sec (throw err)
      Right x  -> return x

-- | Retrieve a field and treat it as a boolean, failing if it
--   does not exist.
--
--   >>> parseIniFile "[MAIN]\nx = yes\n" $ section "MAIN" (fieldFlag "x")
--   Right True
--   >>> parseIniFile "[MAIN]\nx = yes\n" $ section "MAIN" (fieldFlag "y")
--   Left "Missing field \"y\" in section \"MAIN\""
fieldFlag :: Text -> SectionParser Bool
fieldFlag name = fieldOf name flag

-- | Retrieve a field and treat it as a boolean, subsituting
--   a default value if it doesn't exist.
--
--   >>> parseIniFile "[MAIN]\nx = yes\n" $ section "MAIN" (fieldFlagDef "x" False)
--   Right True
--   >>> parseIniFile "[MAIN]\nx = hello\n" $ section "MAIN" (fieldFlagDef "x" False)
--   Left "Line 2, in section \"MAIN\": Unable to parse \"hello\" as a boolean"
--   >>> parseIniFile "[MAIN]\nx = yes\n" $ section "MAIN" (fieldFlagDef "y" False)
--   Right False
fieldFlagDef :: Text -> Bool -> SectionParser Bool
fieldFlagDef name def = fieldDefOf name flag def

---

-- | Try to use the "Read" instance for a type to parse a value, failing
--   with a human-readable error message if reading fails.
--
--   >>> readable "(5, 7)" :: Either String (Int, Int)
--   Right (5,7)
--   >>> readable "hello" :: Either String (Int, Int)
--   Left "Unable to parse \"hello\" as a value of type (Int,Int)"
readable :: forall a. (Read a, Typeable a) => Text -> Either String a
readable t = case readMaybe str of
  Just v  -> Right v
  Nothing -> Left ("Unable to parse " ++ show str ++
                   " as a value of type " ++ show typ)
  where str = T.unpack t
        typ = typeRep prx
        prx :: Proxy a
        prx = Proxy

-- | Try to use the "Read" instance for a numeric type to parse a value,
--   failing with a human-readable error message if reading fails.
--
--   >>> number "5" :: Either String Int
--   Right 5
--   >>> number "hello" :: Either String Int
--   Left "Unable to parse \"hello\" as a value of type Int"
number :: (Num a, Read a, Typeable a) => Text -> Either String a
number = readable

-- | Convert a textua value to the appropriate string type. This will
--   never fail.
--
--   >>> string "foo" :: Either String String
--   Right "foo"
string :: (IsString a) => Text -> Either String a
string = return . fromString . T.unpack

-- | Convert a string that represents a boolean to a proper boolean. This
--   is case-insensitive, and matches the words @true@, @false@, @yes@,
--   @no@, as well as single-letter abbreviations for all of the above.
--   If the input does not match, then this will fail with a human-readable
--   error message.
--
--   >>> flag "TRUE"
--   Right True
--   >>> flag "y"
--   Right True
--   >>> flag "no"
--   Right False
--   >>> flag "F"
--   Right False
--   >>> flag "That's a secret!"
--   Left "Unable to parse \"That's a secret!\" as a boolean"
flag :: Text -> Either String Bool
flag s = case T.toLower s of
  "true"  -> Right True
  "yes"   -> Right True
  "t"     -> Right True
  "y"     -> Right True
  "false" -> Right False
  "no"    -> Right False
  "f"     -> Right False
  "n"     -> Right False
  _       -> Left ("Unable to parse " ++ show s ++ " as a boolean")


-- $setup
--
-- >>> :{
-- data NetworkConfig = NetworkConfig
--    { netHost :: String, netPort :: Int }
--     deriving (Eq, Show)
-- >>> :}
--
-- >>> :{
-- data LocalConfig = LocalConfig
--   { localUser :: Text }
--     deriving (Eq, Show)
-- >>> :}
--
-- >>> :{
-- data Config = Config
--   { cfNetwork :: NetworkConfig, cfLocal :: Maybe LocalConfig }
--     deriving (Eq, Show)
-- >>> :}
--
-- >>> :{
-- let configParser = do
--       netCf <- section "NETWORK" $ do
--         host <- fieldOf "host" string
--         port <- fieldOf "port" number
--         return NetworkConfig { netHost = host, netPort = port }
--       locCf <- sectionMb "LOCAL" $
--         LocalConfig <$> field "user"
--       return Config { cfNetwork = netCf, cfLocal = locCf }
-- >>> :}
--
-- >>> :{
--    let example = "[NETWORK]\nhost = example.com\nport = 7878\n\n# here is a comment\n[LOCAL]\nuser = terry\n"
-- >>> :}

-- $main
-- The 'config-ini' library exports some simple monadic functions to
-- make parsing INI-like configuration easier. INI files have a
-- two-level structure: the top-level named chunks of configuration,
-- and the individual key-value pairs contained within those chunks.
-- For example, the following INI file has two sections, @NETWORK@
-- and @LOCAL@, and each contains its own key-value pairs. Comments,
-- which begin with @#@ or @;@, are ignored:
--
-- > [NETWORK]
-- > host = example.com
-- > port = 7878
-- >
-- > # here is a comment
-- > [LOCAL]
-- > user = terry
--
-- The combinators provided here are designed to write quick and
-- idiomatic parsers for files of this form. Sections are parsed by
-- 'IniParser' computations, like 'section' and its variations,
-- while the fields within sections are parsed by 'SectionParser'
-- computations, like 'field' and its variations. If we want to
-- parse an INI file like the one above, treating the entire
-- @LOCAL@ section as optional, we can write it like this:
--
-- > data Config = Config
-- >   { cfNetwork :: NetworkConfig, cfLocal :: Maybe LocalConfig }
-- >     deriving (Eq, Show)
-- >
-- > data NetworkConfig = NetworkConfig
-- >   { netHost :: String, netPort :: Int }
-- >     deriving (Eq, Show)
-- >
-- > data LocalConfig = LocalConfig
-- >   { localUser :: Text }
-- >     deriving (Eq, Show)
-- >
-- > configParser :: IniParser Config
-- > configParser = do
-- >   netCf <- section "NETWORK" $ do
-- >     host <- fieldOf "host" string
-- >     port <- fieldOf "port" number
-- >     return NetworkConfig { netHost = host, netPort = port }
-- >   locCf <- sectionMb "LOCAL" $
-- >     LocalConfig <$> field "user"
-- >   return Config { cfNetwork = netCf, cfLocal = locCf }
--
-- We can run our computation with 'parseIniFile', which,
-- when run on our example file above, would produce the
-- following:
--
-- >>> parseIniFile example configParser
-- Right (Config {cfNetwork = NetworkConfig {netHost = "example.com", netPort = 7878}, cfLocal = Just (LocalConfig {localUser = "terry"})})
