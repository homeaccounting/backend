{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.UrlSpec (spec) where

import Data.Url (canonicalBaseUrl)
import RIO
import qualified RIO.Text as T
import Test.Hspec

spec :: Spec
spec = describe "canonicalBaseUrl" $ do
  let ok i o = it (T.unpack i) $ canonicalBaseUrl i `shouldBe` Right o
      bad i = it ("rejects " <> T.unpack i) $ canonicalBaseUrl i `shouldSatisfy` isLeft
  ok "HTTPS://HomeAccounting.com:443/" "https://homeaccounting.com"
  ok "http://192.168.1.10:8080/" "http://192.168.1.10:8080"
  ok "https://x.example/base/" "https://x.example/base"
  ok "http://h:80" "http://h"
  ok "https://h:80" "https://h:80"
  ok "http://[::1]:8080" "http://[::1]:8080"
  ok "  https://h  " "https://h"
  bad "ftp://h"
  bad "https://h/?q=1"
  bad "https://h/#f"
  bad "https://user@h"
  bad "not a url"
  bad "https://"
  bad "https://h:"
  bad "https://h:x"
  bad "https://h:0"
  bad "https://h:99999"
  bad "https://h_x"
  bad "https://h%41"
  bad "http:/h"
