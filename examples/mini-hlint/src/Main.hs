-- Copyright (c) 2019, Digital Asset (Switzerland) GmbH and/or its
-- affiliates. All rights reserved.  SPDX-License-Identifier:
-- (Apache-2.0 OR BSD-3-Clause)

{-# LANGUAGE CPP #-}
{-# LANGUAGE PackageImports #-}
{-# OPTIONS_GHC -Wno-missing-fields #-}

module Main (main) where

-- We use 0.x for HEAD
#if !MIN_VERSION_ghc_lib_parser(1,0,0)
#  define GHC_MASTER
#endif

import "ghc-lib-parser" HsSyn
import "ghc-lib-parser" Config
import "ghc-lib-parser" DynFlags
import "ghc-lib-parser" StringBuffer
import "ghc-lib-parser" Fingerprint
import "ghc-lib-parser" Lexer
import "ghc-lib-parser" RdrName
import "ghc-lib-parser" ErrUtils
import qualified "ghc-lib-parser" Parser
import "ghc-lib-parser" FastString
import "ghc-lib-parser" Outputable
import "ghc-lib-parser" SrcLoc
import "ghc-lib-parser" Panic
import "ghc-lib-parser" HscTypes
import "ghc-lib-parser" HeaderInfo
import "ghc-lib-parser" ApiAnnotation

#ifdef GHC_MASTER
import "ghc-lib-parser" GHC.Platform
import "ghc-lib-parser" ToolSettings
#else
import "ghc-lib-parser" Platform
#endif

import Control.Monad
import Control.Monad.Extra
import System.Environment
import System.IO.Extra
import qualified Data.Map as Map
import Data.Generics.Uniplate.Operations
import Data.Generics.Uniplate.Data

fakeSettings :: Settings
fakeSettings = Settings
#ifdef GHC_MASTER
  { sGhcNameVersion=ghcNameVersion
  , sFileSettings=fileSettings
  , sTargetPlatform=platform
  , sPlatformMisc=platformMisc
  , sPlatformConstants=platformConstants
  , sToolSettings=toolSettings
  }
#else
  { sTargetPlatform=platform
  , sPlatformConstants=platformConstants
  , sProjectVersion=cProjectVersion
  , sProgramName="ghc"
  , sOpt_P_fingerprint=fingerprint0
  }
#endif
  where
#ifdef GHC_MASTER
    toolSettings = ToolSettings {
      toolSettings_opt_P_fingerprint=fingerprint0
      }
    fileSettings = FileSettings {}
    platformMisc = PlatformMisc {}
    ghcNameVersion =
      GhcNameVersion{ghcNameVersion_programName="ghc"
                    ,ghcNameVersion_projectVersion=cProjectVersion
                    }
#endif
    platform =
#ifdef GHC_MASTER
      Platform{platformWordSize=PW8
#else
      Platform{platformWordSize=8
#endif
              , platformOS=OSUnknown
              , platformUnregisterised=True}
    platformConstants =
      PlatformConstants{pc_DYNAMIC_BY_DEFAULT=False,pc_WORD_SIZE=8}

fakeLlvmConfig :: (LlvmTargets, LlvmPasses)
fakeLlvmConfig = ([], [])

parse :: String -> DynFlags -> String -> ParseResult (Located (HsModule GhcPs))
parse filename flags str =
  unP Parser.parseModule parseState
  where
    location = mkRealSrcLoc (mkFastString filename) 1 1
    buffer = stringToStringBuffer str
    parseState = mkPState flags buffer location

parsePragmasIntoDynFlags :: DynFlags -> FilePath -> String -> IO (Maybe DynFlags)
parsePragmasIntoDynFlags flags filepath str =
  catchErrors $ do
    let opts = getOptions flags (stringToStringBuffer str) filepath
    (flags, _, _) <- parseDynamicFilePragma flags opts
    return $ Just flags
  where
    catchErrors :: IO (Maybe DynFlags) -> IO (Maybe DynFlags)
    catchErrors act = handleGhcException reportErr
                        (handleSourceError reportErr act)
    reportErr e = do putStrLn $ "error : " ++ show e; return Nothing

idNot :: RdrName
idNot = mkVarUnqual (fsLit "not")

isNegated :: HsExpr GhcPs -> Bool
isNegated (HsApp _ (L _ (HsVar _ (L _ id))) _) = id == idNot
isNegated (HsPar _ (L _ e)) = isNegated e
isNegated _ = False

analyzeExpr :: DynFlags -> Located (HsExpr GhcPs) -> IO ()
analyzeExpr flags (L loc expr) =
  case expr of
    HsApp _ (L _ (HsVar _ (L _ id))) (L _ e)
        | id == idNot, isNegated e ->
            putStrLn (showSDoc flags (ppr loc)
                      ++ " : lint : double negation "
                      ++ "`" ++ showSDoc flags (ppr expr) ++ "'")
    _ -> return ()

analyzeModule :: DynFlags -> Located (HsModule GhcPs) -> ApiAnns -> IO ()
analyzeModule flags (L _ modu) _ =
  sequence_ [analyzeExpr flags e | e <- universeBi modu]

main :: IO ()
main = do
  args <- getArgs
  case args of
    [file] -> do
      s <- readFile' file
#ifdef GHC_MASTER
      flags <-
        parsePragmasIntoDynFlags
          (defaultDynFlags fakeSettings fakeLlvmConfig) file s
      whenJust flags $ \flags ->
         case parse file (flags `gopt_set` Opt_KeepRawTokenStream)s of
            PFailed s ->
              report flags $ snd (getMessages s flags)
            POk s m -> do
              let (wrns, errs) = getMessages s flags
              report flags wrns
              report flags errs
              when (null errs) $ analyzeModule flags m (harvestAnns s)
#else
      let flags = defaultDynFlags fakeSettings fakeLlvmConfig
      case parse file flags s of
        PFailed _ loc err ->
          putStrLn (showSDoc flags (pprLocErrMsg (mkPlainErrMsg flags loc err)))
        POk s m -> do
          let (warns, errs) = getMessages s flags
          report flags warns
          report flags errs
          when (null errs) $ analyzeModule flags m (harvestAnns s)
#endif
    _ -> fail "Exactly one file argument required"
  where
    report flags msgs =
      sequence_
        [ putStrLn $ showSDoc flags msg
        | msg <- pprErrMsgBagWithLoc msgs
        ]
    harvestAnns pst =
      ( Map.fromListWith (++) $ annotations pst
      , Map.fromList ((noSrcSpan, comment_q pst) : annotations_comments pst)
      )
