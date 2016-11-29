module Main where

import           Data.Char
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import qualified Data.Ini as I1
import qualified Data.Ini.Config.Raw as I2
import           Data.Text (Text)
import qualified Data.Text as T

import           Test.QuickCheck

iniEquiv :: ArbIni -> Bool
iniEquiv (ArbIni raw) = case (i1, i2) of
   (Right i1', Right i2') ->
     let i1'' = lower i1'
         i2'' = toMaps i2'
     in i1'' == i2''
   _ -> False
  where pr = I1.printIniWith I1.defaultWriteIniSettings raw
        i2 = I2.parseIni pr
        i1 = I1.parseIni pr

lower :: I1.Ini -> HashMap Text (HashMap Text Text)
lower (I1.Ini hm) =
  HM.fromList [ (T.toLower k, v) | (k, v) <- HM.toList hm ]

toMaps :: I2.Ini -> HashMap Text (HashMap Text Text)
toMaps (I2.Ini m) = fmap (fmap I2.vValue . I2.isVals) m

newtype ArbIni = ArbIni I1.Ini deriving (Show)

instance Arbitrary ArbIni where
  arbitrary = (ArbIni . I1.Ini . HM.fromList) `fmap` listOf sections
    where sections = do
            name <- str
            sec  <- section
            return (name, sec)
          str = (T.pack `fmap` arbitrary) `suchThat` (\ t ->
                   T.all (\ c -> isAlphaNum c || c == ' ')
                   t && not (T.null t))
          section = HM.fromList `fmap` listOf kv
          kv = do
            name <- str
            val  <- str
            return (name, val)

main :: IO ()
main = quickCheck iniEquiv
