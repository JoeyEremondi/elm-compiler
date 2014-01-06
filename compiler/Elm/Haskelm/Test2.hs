module Elm.Haskelm.Test2 where

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE  QuasiQuotes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-missing-fields #-}
{-# LANGUAGE DeriveDataTypeable #-}

import Elm.Haskelm.Quasi
import Elm.Haskelm.EToH
import Elm.Haskelm.Test

-- $(translate theTest)

-- $(translate theTest2)

$(decHaskAndElm "myGreatElmString"
    [d|
        data Foo = Baz Int | Bar String

        unFoo x = case x of
            Baz x -> Bar "3"
            Bar y -> Baz 4

        x _ = 3 + 4 - 5 * 6 / 7 `mod` 8

        y _ = if 3 < 4 then 5 else 6
    |])
