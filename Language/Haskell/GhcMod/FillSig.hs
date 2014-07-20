{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies, FlexibleInstances, CPP #-}

module Language.Haskell.GhcMod.FillSig (
    sig
  , refine
  ) where

import Data.Char (isSymbol)
import Data.Function (on)
import Data.List (find, sortBy)
import Data.Maybe (isJust)
import Exception (ghandle, SomeException(..))
import GHC (GhcMonad, Id, ParsedModule(..), TypecheckedModule(..), DynFlags, SrcSpan, Type, GenLocated(L))
import qualified GHC as G
import qualified Language.Haskell.GhcMod.Gap as Gap
import Language.Haskell.GhcMod.Convert
import Language.Haskell.GhcMod.Monad
import Language.Haskell.GhcMod.SrcUtils
import Language.Haskell.GhcMod.Types
import CoreMonad (liftIO)
import Outputable (PprStyle)
import qualified Type as Ty
import qualified HsBinds as Ty
import qualified Class as Ty
import qualified Language.Haskell.Exts.Annotated as HE

----------------------------------------------------------------
-- INTIAL CODE FROM FUNCTION OR INSTANCE SIGNATURE
----------------------------------------------------------------

-- Possible signatures we can find: function or instance
data SigInfo = Signature SrcSpan [G.RdrName] (G.HsType G.RdrName)
             | InstanceDecl SrcSpan G.Class

-- Signature for fallback operation via haskell-src-exts
data HESigInfo = HESignature HE.SrcSpan [HE.Name HE.SrcSpanInfo] (HE.Type HE.SrcSpanInfo)

-- | Create a initial body from a signature.
sig :: IOish m
    => FilePath     -- ^ A target file.
    -> Int          -- ^ Line number.
    -> Int          -- ^ Column number.
    -> GhcModT m String
sig file lineNo colNo = ghandle handler body
  where
    body = inModuleContext file $ \dflag style -> do
        opt <- options
        modSum <- Gap.fileModSummary file
        whenFound opt (getSignature modSum lineNo colNo) $ \s -> case s of
          Signature loc names ty ->
            ("function", fourInts loc, map (initialBody dflag style ty) names)
          InstanceDecl loc cls ->
             ("instance", fourInts loc, map (\x -> initialBody dflag style (G.idType x) x)
                                            (Ty.classMethods cls))

    handler (SomeException _) = do
      opt <- options
      -- Code cannot be parsed by ghc module
      -- Fallback: try to get information via haskell-src-exts
      whenFound opt (getSignatureFromHE file lineNo colNo) $
        \(HESignature loc names ty) ->
           ("function", fourIntsHE loc, map (initialBody undefined undefined ty) names)

----------------------------------------------------------------
-- a. Code for getting the information

-- Get signature from ghc parsing and typechecking
getSignature :: GhcMonad m => G.ModSummary -> Int -> Int -> m (Maybe SigInfo)
getSignature modSum lineNo colNo = do
    p@ParsedModule{pm_parsed_source = ps} <- G.parseModule modSum
    -- Inspect the parse tree to find the signature
    case listifyParsedSpans ps (lineNo, colNo) :: [G.LHsDecl G.RdrName] of
      [L loc (G.SigD (Ty.TypeSig names (L _ ty)))] ->
        -- We found a type signature
        return $ Just $ Signature loc (map G.unLoc names) ty
      [L _ (G.InstD _)] -> do
        -- We found an instance declaration
        TypecheckedModule{tm_renamed_source = Just tcs
                         ,tm_checked_module_info = minfo} <- G.typecheckModule p
        case Gap.getClass $ listifyRenamedSpans tcs (lineNo, colNo) of
            Just (clsName,loc) -> obtainClassInfo minfo clsName loc
            Nothing            -> return Nothing
      _ -> return Nothing
  where obtainClassInfo :: GhcMonad m => G.ModuleInfo -> G.Name -> SrcSpan -> m (Maybe SigInfo)
        obtainClassInfo minfo clsName loc = do
          tyThing <- G.modInfoLookupName minfo clsName
          return $ do Ty.ATyCon clsCon <- tyThing  -- In Maybe
                      cls <- G.tyConClass_maybe clsCon
                      return $ InstanceDecl loc cls

-- Get signature from haskell-src-exts
getSignatureFromHE :: GhcMonad m => FilePath -> Int -> Int -> m (Maybe HESigInfo)
getSignatureFromHE file lineNo colNo = do
  presult <- liftIO $ HE.parseFile file
  return $ case presult of
             HE.ParseOk (HE.Module _ _ _ _ mdecls) -> do
               HE.TypeSig (HE.SrcSpanInfo s _) names ty <- find (typeSigInRangeHE lineNo colNo) mdecls
               return $ HESignature s names ty
             _ -> Nothing

----------------------------------------------------------------
-- b. Code for generating initial code

-- A list of function arguments, and whether they are functions or normal arguments
-- is built from either a function signature or an instance signature
data FnArg = FnArgFunction | FnArgNormal

initialBody :: FnArgsInfo ty name => DynFlags -> PprStyle -> ty -> name -> String
initialBody dflag style ty name = initialBody' (getFnName dflag style name) (getFnArgs ty)

initialBody' :: String -> [FnArg] -> String
initialBody' fname args = initialHead fname args ++ " = "
                          ++ (if isSymbolName fname then "" else '_':fname) ++ "_body"

initialHead :: String -> [FnArg] -> String
initialHead fname args =
  case initialBodyArgs args infiniteVars infiniteFns of
    []      -> fname
    arglist -> if isSymbolName fname
               then head arglist ++ " " ++ fname ++ " " ++ unwords (tail arglist)
               else fname ++ " " ++ unwords arglist

initialBodyArgs :: [FnArg] -> [String] -> [String] -> [String]
initialBodyArgs [] _ _ = []
initialBodyArgs (FnArgFunction:xs) vs (f:fs) = f : initialBodyArgs xs vs fs
initialBodyArgs (FnArgNormal:xs)   (v:vs) fs = v : initialBodyArgs xs vs fs
initialBodyArgs _                  _      _  = error "This should never happen" -- Lists are infinite

initialHead1 :: String -> [FnArg] -> [String] -> String
initialHead1 fname args elts =
  case initialBodyArgs1 args elts of
    []      -> fname
    arglist -> if isSymbolName fname
               then head arglist ++ " " ++ fname ++ " " ++ unwords (tail arglist)
               else fname ++ " " ++ unwords arglist

initialBodyArgs1 :: [FnArg] -> [String] -> [String]
initialBodyArgs1 args elts = take (length args) elts

-- Getting the initial body of function and instances differ
-- This is because for functions we only use the parsed file
-- (so the full file doesn't have to be type correct)
-- but for instances we need to get information about the class

class FnArgsInfo ty name | ty -> name, name -> ty where
  getFnName :: DynFlags -> PprStyle -> name -> String
  getFnArgs :: ty -> [FnArg]

instance FnArgsInfo (G.HsType G.RdrName) (G.RdrName) where
  getFnName dflag style name = showOccName dflag style $ Gap.occName name
  getFnArgs (G.HsForAllTy _ _ _ (L _ iTy))  = getFnArgs iTy
  getFnArgs (G.HsParTy (L _ iTy))           = getFnArgs iTy
  getFnArgs (G.HsFunTy (L _ lTy) (L _ rTy)) = (if fnarg lTy then FnArgFunction else FnArgNormal):getFnArgs rTy
    where fnarg ty = case ty of
              (G.HsForAllTy _ _ _ (L _ iTy)) -> fnarg iTy
              (G.HsParTy (L _ iTy))          -> fnarg iTy
              (G.HsFunTy _ _)                -> True
              _                              -> False
  getFnArgs _ = []

instance FnArgsInfo (HE.Type HE.SrcSpanInfo) (HE.Name HE.SrcSpanInfo) where
  getFnName _ _ (HE.Ident  _ s) = s
  getFnName _ _ (HE.Symbol _ s) = s
  getFnArgs (HE.TyForall _ _ _ iTy) = getFnArgs iTy
  getFnArgs (HE.TyParen _ iTy)      = getFnArgs iTy
  getFnArgs (HE.TyFun _ lTy rTy)    = (if fnarg lTy then FnArgFunction else FnArgNormal):getFnArgs rTy
    where fnarg ty = case ty of
              (HE.TyForall _ _ _ iTy) -> fnarg iTy
              (HE.TyParen _ iTy)      -> fnarg iTy
              (HE.TyFun _ _ _)        -> True
              _                       -> False
  getFnArgs _ = []

instance FnArgsInfo Type Id where
  getFnName dflag style method = showOccName dflag style $ G.getOccName method
  getFnArgs = getFnArgs' . Ty.dropForAlls
    where getFnArgs' ty | Just (lTy,rTy) <- Ty.splitFunTy_maybe ty =
            maybe (if Ty.isPredTy lTy then getFnArgs' rTy else FnArgNormal:getFnArgs' rTy)
                  (\_ -> FnArgFunction:getFnArgs' rTy)
                  $ Ty.splitFunTy_maybe lTy
          getFnArgs' ty | Just (_,iTy) <- Ty.splitForAllTy_maybe ty = getFnArgs' iTy
          getFnArgs' _ = []

-- Infinite supply of variable and function variable names
infiniteVars, infiniteFns :: [String]
infiniteVars = infiniteSupply ["x","y","z","t","u","v","w"]
infiniteFns  = infiniteSupply ["f","g","h"]
infiniteSupply :: [String] -> [String]
infiniteSupply initialSupply = initialSupply ++ concatMap (\n -> map (\v -> v ++ show n) initialSupply) ([1 .. ] :: [Integer])

-- Check whether a String is a symbol name
isSymbolName :: String -> Bool
isSymbolName (c:_) = c `elem` "!#$%&*+./<=>?@\\^|-~" || isSymbol c
isSymbolName []    = error "This should never happen"


----------------------------------------------------------------
-- REWRITE A HOLE / UNDEFINED VIA A FUNCTION
----------------------------------------------------------------

refine :: IOish m
       => FilePath     -- ^ A target file.
       -> Int          -- ^ Line number.
       -> Int          -- ^ Column number.
       -> Expression   -- ^ A Haskell expression.
       -> GhcModT m String
refine file lineNo colNo expr = ghandle handler body
  where
    body = inModuleContext file $ \dflag style -> do
        opt <- options
        modSum <- Gap.fileModSummary file
        p <- G.parseModule modSum
        tcm@TypecheckedModule{tm_typechecked_source = tcs} <- G.typecheckModule p
        ety <- G.exprType expr
        whenFound opt (findVar dflag style tcm tcs lineNo colNo) $ \(loc, name, rty, paren) ->
          let eArgs = getFnArgs ety
              rArgs = getFnArgs rty
              diffArgs' = length eArgs - length rArgs
              diffArgs  = if diffArgs' < 0 then 0 else diffArgs'
              iArgs = take diffArgs eArgs
              text = initialHead1 expr iArgs (infinitePrefixSupply name)
           in (fourInts loc, doParen paren text)
            
    handler (SomeException _) = emptyResult =<< options

-- Look for the variable in the specified position
findVar :: GhcMonad m => DynFlags -> PprStyle
                      -> G.TypecheckedModule -> G.TypecheckedSource
                      -> Int -> Int -> m (Maybe (SrcSpan, String, Type, Bool))
findVar dflag style tcm tcs lineNo colNo =
  let lst = sortBy (cmp `on` G.getLoc) $ listifySpans tcs (lineNo, colNo) :: [G.LHsExpr Id]
  in case lst of
      e@(L _ (G.HsVar i)):others ->
        do tyInfo <- Gap.getType tcm e
           let name = getFnName dflag style i
           if (name == "undefined" || head name == '_') && isJust tyInfo
              then let Just (s,t) = tyInfo
                       b = case others of  -- If inside an App, we need parenthesis
                             [] -> False
                             (L _ (G.HsApp (L _ a1) (L _ a2))):_ ->
                               isSearchedVar i a1 || isSearchedVar i a2
                             _  -> False
                    in return $ Just (s, name, t, b)
              else return Nothing
      _ -> return Nothing

infinitePrefixSupply :: String -> [String]
infinitePrefixSupply "undefined" = repeat "undefined"
infinitePrefixSupply p = map (\n -> p ++ "_" ++ show n) ([1 ..] :: [Integer])

doParen :: Bool -> String -> String
doParen False s = s
doParen True  s = if ' ' `elem` s then '(':s ++ ")" else s

isSearchedVar :: Id -> G.HsExpr Id -> Bool
isSearchedVar i (G.HsVar i2) = i == i2
isSearchedVar _ _ = False
