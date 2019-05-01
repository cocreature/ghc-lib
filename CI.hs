-- Copyright (c) 2019, Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
-- SPDX-License-Identifier: (Apache-2.0 OR BSD-3-Clause)

-- CI script, invoked by Azure

import Control.Monad
import System.Directory
import System.FilePath
import System.IO.Extra
import System.Info.Extra
import System.Process.Extra
import System.Time.Extra

main :: IO ()
main = do
    when isWindows $
        cmd "stack exec -- pacman -S autoconf automake-wrapper make patch python tar --noconfirm"

    -- Make and extract an sdist of ghc-lib-parser.
    cmd "git clone https://gitlab.haskell.org/ghc/ghc.git --recursive"

    -- withCurrentDirectory "ghc" $ do
    --     cmd $ "git remote add upstream https://github.com/digital-asset/ghc.git"
    --     cmd $ "git fetch upstream"
    --     base <- systemOutput_ $ "git merge-base upstream/da-master master"
    --     cmd $ "git checkout " ++ base
    --     cmd $ "git merge --no-edit upstream/da-master upstream/da-unit-ids"
    --     cmd "git submodule update --init --recursive"

    appendFile "ghc/hadrian/stack.yaml" $ unlines ["ghc-options:","  \"$everything\": -O0 -j"]
    cmd "stack exec -- ghc-lib-gen ghc --ghc-lib-parser"
    stackYaml <- readFile' "stack.yaml"
    writeFile "stack.yaml" $ stackYaml ++ unlines ["- ghc"]
    cmd "stack sdist ghc --tar-dir=."
    cmd "tar -xf ghc-lib-parser-0.1.0.tar.gz"
    cmd "mv ghc-lib-parser-0.1.0 ghc-lib-parser"
    cmd "cat ghc/ghc-lib-parser.cabal"
    removeFile "ghc/ghc-lib-parser.cabal"

    -- Make and extract an sdist of ghc-lib.
    cmd "cd ghc && git checkout ."
    appendFile "ghc/hadrian/stack.yaml" $ unlines ["ghc-options:","  \"$everything\": -O0 -j"]
    cmd "stack exec -- ghc-lib-gen ghc --ghc-lib"
    cmd "stack sdist ghc --tar-dir=."
    cmd "tar -xf ghc-lib-0.1.0.tar.gz"
    cmd "mv ghc-lib-0.1.0 ghc-lib"
    cmd "cat ghc/ghc-lib.cabal"
    removeFile "ghc/ghc-lib.cabal"

    -- Test the new projects.
    writeFile "stack.yaml" $
      stackYaml ++
      unlines [ "- ghc-lib-parser"
              , "- ghc-lib"
              , "- examples/mini-hlint"
              , "- examples/mini-compile"
              ]
    cmd "stack build --no-terminal --interleaved-output"
    cmd "stack exec --no-terminal -- ghc-lib --version"
    cmd "stack exec --no-terminal -- mini-hlint examples/mini-hlint/test/MiniHlintTest.hs"
    cmd "stack exec --no-terminal -- mini-hlint examples/mini-hlint/test/MiniHlintTest_error_handling.hs"
    cmd "stack exec --no-terminal -- mini-compile examples/mini-compile/test/MiniCompileTest.hs"

    -- Test everything loads in GHCi, see https://github.com/digital-asset/ghc-lib/issues/27
    cmd "stack exec --no-terminal -- ghc -package=ghc-lib-parser -e \"print 1\""
    cmd "stack exec --no-terminal -- ghc -package=ghc-lib -e \"print 1\""
    where
      dropExtensions :: String -> String
      dropExtensions = dropExtension . dropExtension

      cmd :: String -> IO ()
      cmd x = do
            putStrLn $ "\n\n# Running: " ++ x
            hFlush stdout
            (t, _) <- duration $ system_ x
            putStrLn $ "# Completed in " ++ showDuration t ++ ": " ++ x ++ "\n"
            hFlush stdout
