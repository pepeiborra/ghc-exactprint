{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
module Language.Haskell.GHC.ExactPrint.Utils
  (
    annotateLHsModule

  , ghcIsWhere
  , ghcIsLet
  , ghcIsComment
  , ghcIsMultiLine

  , srcSpanStartLine
  , srcSpanEndLine
  , srcSpanStartColumn
  , srcSpanEndColumn

  , ss2span
  , ss2pos
  , ss2posEnd
  , undelta
  , undeltaComment
  , rdrName2String
  , isSymbolRdrName

  , showGhc

  -- * For tests
  , runAP
  -- , APState(..)
  , AP(..)
  , getSrcSpanAP, pushSrcSpan, popSrcSpan
  , getSubSpans
  , getAnnotationAP
  , getComments
  , setComments
  -- , getS
  , addAnnotationsAP, addAnnValue
  ) where

import Control.Applicative (Applicative(..))
import Control.Monad (when, liftM, ap)
import Control.Exception
import Data.Data
import Data.List
import Data.Maybe
import Data.Monoid

import Language.Haskell.GHC.ExactPrint.Types

import qualified Bag           as GHC
import qualified BasicTypes    as GHC
import qualified DynFlags      as GHC
import qualified FastString    as GHC
import qualified ForeignCall   as GHC
import qualified GHC           as GHC
import qualified GHC.Paths     as GHC
import qualified Lexer         as GHC
import qualified Name          as GHC
import qualified NameSet       as GHC
import qualified Outputable    as GHC
import qualified RdrName       as GHC
import qualified SrcLoc        as GHC
import qualified StringBuffer  as GHC
import qualified UniqSet       as GHC
import qualified Unique        as GHC
import qualified Var           as GHC

import qualified Data.Map as Map

import Debug.Trace

debug :: c -> String -> c
debug = flip trace

-- ---------------------------------------------------------------------

-- | Type used in the AP Monad. The state variables maintain
--    - the current SrcSpan and the TypeRep of the thing it encloses
--      as a stack to the root of the AST as it is traversed,
--    - the matching sets of enclosed SrcSpans per entry in the first,
--    - the comment stream that has not yet been allocated to
--      annotations,
--    - the annotations provided by GH

{- -}
newtype AP x = AP ([(GHC.SrcSpan,TypeRep)] -> [[GHC.SrcSpan]] -> [GHC.SrcSpan] -> [Comment] -> GHC.ApiAnns
            -> (x, [(GHC.SrcSpan,TypeRep)],   [[GHC.SrcSpan]],   [GHC.SrcSpan],   [Comment],   GHC.ApiAnns,
                  ([(AnnKey,Annotation)],[(AnnKey,Value)])
                 ))
{- -}

{-
newtype AP x = AP (APState
            -> (x, APState,
                  ([(AnnKey,Annotation)],[(AnnKey,Value)])
                 ))

data APState = S
  { sCrumbs   :: ![(GHC.SrcSpan,TypeRep)]
  , sEnclosed :: ![[GHC.SrcSpan]]
  , sComments :: ![Comment]
  , sAnns     :: !GHC.ApiAnns
  } deriving Show
-}

instance Functor AP where
  fmap = liftM

instance Applicative AP where
  pure = return
  (<*>) = ap

instance Monad AP where
  return x = AP $ \l ss pe cs ga -> (x, l, ss, pe, cs, ga, ([],[]))
  -- return x = AP $ \st -> (x, st, ([],[]) )

  AP m >>= k = AP $ \l0 ss0 p0 c0 ga0 -> let
        (a, l1, ss1, p1, c1, ga1, s1) = m l0 ss0 p0 c0 ga0
        AP f = k a
        (b, l2, ss2, p2, c2, ga2, s2) = f l1 ss1 p1 c1 ga1
    in (b, l2, ss2, p2, c2, ga2, s1 <> s2)

  -- AP m >>= k = AP $ \st0 -> let
  --       (a, st1, s1) = m st0
  --       AP f = k a
  --       (b, st2, s2) = f st1
  --   in (b, st2, s1 <> s2)
  --      `debug` (">>= : " ++ show (st1,st2,s1 <> s2))

runAP :: AP () -> [Comment] -> GHC.ApiAnns -> Anns
runAP (AP f) cs ga
 = let (_,_,_,_,_,_,(se,su)) = f [] [] [GHC.noSrcSpan] cs ga
 -- = let -- st = S [] [] cs ga
 --       (_,st',(se,su)) = f (S [] [] cs ga) -- `debug` ("runAP:initial state=" ++ show st)
   in (Map.fromList se,Map.fromList su)
      -- `debug` ("runAP done" ++ (show (se,su)))
      -- `debug` ("runAP done")
      -- `debug` ("runAP:final state=" ++ show st')

-- -------------------------------------

-- |Note: assumes the SrcSpan stack is nonempty
getSrcSpanAP :: AP GHC.SrcSpan
getSrcSpanAP = AP (\l ss pe cs ga -> (fst $ head l,l,ss,pe,cs,ga,([],[])))
-- getSrcSpanAP = AP (\st -> (fst $ head (sCrumbs st),   st, ([],[]) ))

pushSrcSpan :: (Typeable a) => (GHC.Located a) -> AP ()
pushSrcSpan (GHC.L l a) = AP (\ls ss pe cs ga -> ((),(l,typeOf a):ls,[]:ss,pe,cs,ga,([],[])))
-- pushSrcSpan (GHC.L l a) = AP (\st ->
--    ( ()
--    , st { sCrumbs = (l,typeOf a):(sCrumbs st), sEnclosed = []:sEnclosed st }
--    , ([],[]) ))

popSrcSpan :: AP ()
popSrcSpan = AP (\(l:ls) (s:ss) pe cs ga -> ((),ls,ss,pe,cs,ga,([],[])))
-- popSrcSpan = AP (\st -> (()
--                         ,st { sCrumbs   = tail $ sCrumbs   st
--                             , sEnclosed = tail $ sEnclosed st
--                             }
--                         , ([],[]) ))

getSubSpans :: AP [Span]
getSubSpans= AP (\l (s:ss) pe cs ga -> (map ss2span s,l,s:ss,pe,cs,ga,([],[])))
-- getSubSpans= AP (\st -> (map ss2span (head $ sEnclosed st), st, ([],[]) ))

-- ---------------------------------------------------------------------

-- |Note: assumes the prior end SrcSpan stack is nonempty
getPriorEnd :: AP GHC.SrcSpan
getPriorEnd = AP (\l ss pe cs ga -> (head pe, l,ss,pe,cs,ga,([],[])))

pushPriorEnd :: GHC.SrcSpan -> AP ()
pushPriorEnd s = AP (\ls ss pe cs ga -> ((),ls,ss,s:pe,cs,ga,([],[])))

popPriorEnd :: AP ()
popPriorEnd = AP (\l ss (p:pe) cs ga -> ((),l,ss,pe,cs,ga,([],[])))

-- -------------------------------------

getAnnotationAP :: GHC.SrcSpan -> GHC.Ann -> AP (Maybe GHC.SrcSpan)
getAnnotationAP sp an = AP (\l ss pe cs ga
    -> (GHC.getAnnotation ga sp an, l,ss,pe,cs,ga,([],[])))
-- getAnnotationAP sp an = AP (\st
 --   -> (GHC.getAnnotation (sAnns st) sp an, st, ([],[])))
--  -> (GHC.getAnnotation (sAnns st) sp an, st, ([],[])))


-- -------------------------------------

getComments :: AP [Comment]
getComments = AP (\l ss pe cs ga -> (cs,l,ss,pe,cs,ga,([],[])))
-- getComments = AP (\st -> (sComments st,st,([],[])))

setComments :: [Comment] -> AP ()
setComments cs = AP (\l ss pe _ ga -> ((),l,ss,pe,cs,ga,([],[])))
-- setComments cs = AP (\st -> ((),st {sComments = cs },([],[])))

-- -------------------------------------

getToks :: AP [PosToken]
getToks = AP (\l ss pe cs ga -> ([],l,ss,pe,cs,ga,([],[])))
-- getToks = AP (\st -> ([],st,([],[])))

setToks :: [PosToken] -> AP ()
setToks toks = AP (\l ss pe cs ga -> ((),l,ss,pe,cs,ga,([],[])))
-- setToks toks = AP (\st -> ((),st,([],[])))

-- -------------------------------------

-- getS :: AP APState
-- getS = AP (\st -> (st,st,([],[])))

-- -------------------------------------

-- |Add some annotation to the currently active SrcSpan
addAnnotationsAP :: Annotation -> AP ()
addAnnotationsAP ann = AP (\l (h:r)                pe cs ga ->
                       ( (),l,((fst $ head l):h):r,pe,cs,ga,
                 ([((head l),ann)],[])))
-- addAnnotationsAP ann = AP (\st ->
--         let l     = sCrumbs    st
--             (h:r) = sEnclosed  st
--         in
--                 ( () -- `debug` ("addAnnotationsAP:(l,h,r)=" ++ show (l,h,r))
--                 , st { sEnclosed = ((fst $ head l):h):r }
--                 , ([(head l,ann)],[]) -- `debug` ("addAnnotationsAP:(l,h,r)=" ++ show (l,h,r))
--                 -- , ([],[]) -- ++AZ++ temporary
--                 ))
    -- Insert the span into the current head of the list of spans at this level

-- -------------------------------------

-- |Add some annotation to the currently active SrcSpan
addAnnValue :: (Typeable a,Show a,Eq a) => a -> AP ()
addAnnValue v = AP (\l (h:r)                pe cs ga ->
                ( (),l,((fst $ head l):h):r,pe,cs,ga,
                 ([],[( ((fst $ head l),typeOf (Just v)),newValue v)])))
-- addAnnValue v = AP (\st ->
--         let l     = sCrumbs   st
--             (h:r) = sEnclosed st
--         in
--                 ( ()  -- `debug` ("addAnnValue:(l,h,r)=" ++ show (l,h,r))
--                 , st { sEnclosed = ((fst $ head l):h):r }
--                 ,  ([] ,[( ((fst $ head l),typeOf (Just v)),newValue v)])
--                 -- , ([],[]) -- ++AZ++ temporary
--                 ))
    -- Insert the span into the current head of the list of spans at this level


-- -------------------------------------

-- | Enter a new AST element. Maintain SrcSpan stack
enterAST :: (Typeable a) => GHC.Located a -> AP ()
enterAST lss = do
  pushSrcSpan lss
  return () -- `debug` ("enterAST:" ++ show (ss2span $ GHC.getLoc lss))

-- | Pop up the SrcSpan stack, capture the annotations, and work the
-- comments in belonging to the span
-- Assumption: the annotations belong to the immediate sub elements of
-- the AST, hence relate to the current SrcSpan. They can thus be used
-- to decide which comments belong at this level,
-- The assumption is made valid by matching enterAST/leaveAST calls.
leaveAST :: Maybe GHC.SrcSpan -> AP ()
leaveAST end = do
  ss <- getSrcSpanAP `debug` ("leaveAST: entered")
  cs <- getComments
  subSpans <- getSubSpans  `debug` ("leaveAST: getting subspans")
  let (lcs,cs') = localComments (ss2span ss) cs subSpans

  priorEnd <- getPriorEnd
  popPriorEnd
  case end of
    Nothing -> pushPriorEnd priorEnd -- keep it?
    Just pe -> pushPriorEnd pe

  let dp = deltaFromSrcSpans priorEnd ss
  -- let dp = DP (0,0)
  addAnnotationsAP (Ann lcs dp) `debug` ("leaveAST:(priorEnd,ss,dp)=" ++ show (ss2span priorEnd,ss2span ss,dp))
  -- st <- getS
  setComments cs'
  popSrcSpan
  return () -- `debug` ("leaveAST:1")

-- ---------------------------------------------------------------------

class (Typeable ast) => AnnotateP ast where
  annotateP :: GHC.SrcSpan -> ast -> AP (Maybe GHC.SrcSpan)

-- |First move to the given location, then call exactP
annotatePC :: (AnnotateP ast) => GHC.Located ast -> AP ()
annotatePC a@(GHC.L l ast) = do
  enterAST a `debug` ("annotatePC:entering " ++ showGhc l)
  end <- annotateP l ast
  leaveAST end `debug` ("annotatePC:leaving " ++ showGhc (l,end))


annotateMaybe :: (AnnotateP ast) => Maybe (GHC.Located ast) -> AP ()
annotateMaybe Nothing    = return ()
annotateMaybe (Just ast) = annotatePC ast

annotateList :: (AnnotateP ast) => [GHC.Located ast] -> AP ()
annotateList xs = mapM_ annotatePC xs

-- ---------------------------------------------------------------------
-- Start of application specific part

-- ---------------------------------------------------------------------

annotateLHsModule :: GHC.Located (GHC.HsModule GHC.RdrName)
  -> [Comment] -> [PosToken] -> GHC.ApiAnns
  -> Anns
annotateLHsModule modu cs toks ghcAnns
   = runAP (annotatePC modu) cs ghcAnns

instance AnnotateP (GHC.HsModule GHC.RdrName) where
  annotateP lm (GHC.HsModule mmn mexp imps decs _depr _haddock) = do
    pushPriorEnd lm
    am <- getAnnotationAP lm GHC.AnnModule
    aw <- getAnnotationAP lm GHC.AnnWhere
    let pm = deltaFromMaybeSrcSpans (Just lm) am
        pn = deltaFromMaybeSrcSpans am (maybeSrcSpan mmn)
        po = deltaFromMaybeSrcSpans (maybeSrcSpan mmn) (maybeSrcSpan mexp)
            -- `debug` ("annotateLHsModule:(po,mmn,mexp)=" ++ show (po,maybeSrcSpan mmn,maybeSrcSpan mexp))
            -- `debug` ("annotateLHsModule:(pc,mEndExps,mCp)=" ++ show (pc,mEndExps,mCp))

    (mEndExps,mOp,mCp) <- case mexp of
      Nothing -> return (Nothing,Nothing,Nothing)
      Just (GHC.L le es) -> do
        let
          ee = if null es
                 then GHC.mkSrcSpan (GHC.srcSpanStart le) (GHC.srcSpanStart le)
                 else GHC.getLoc (last es)
          -- op = GHC.mkSrcSpan (GHC.srcSpanStart le) (GHC.srcSpanStart le)
          -- cp = GHC.mkSrcSpan (GHC.srcSpanEnd le) (GHC.srcSpanEnd le)
        Just op <- getAnnotationAP le GHC.AnnOpen
        Just cp <- getAnnotationAP le GHC.AnnClose
        return (Just ee,Just op,Just cp)

    let
        pc = deltaFromMaybeSrcSpans mEndExps mCp
        pw = deltaFromMaybeSrcSpans mCp aw

    let lpo = deltaFromSrcSpans lm lm
    case mexp of
      Nothing -> return ()
      Just exp -> do
        pushPriorEnd (fromJust mOp)
        annotatePC exp
        popPriorEnd

    -- annotateList (GHC.unLoc imps)
    addAnnValue (AnnHsModule pm pn po pc pw lpo) -- `debug` ("annotateP.HsModule:adding ann")
    return (Just lm)
-- 'module' mmn '(' mexp  ')' 'where'

{-
-- ---------------------------------------------------------------------

annotateModuleHeader ::
     Maybe (GHC.Located GHC.ModuleName)
  -> Maybe [GHC.LIE GHC.RdrName] -> Pos -> AP ()
annotateModuleHeader Nothing _ _ = return ()
annotateModuleHeader (Just (GHC.L l _mn)) mexp pos = do
  enterAST l
  lm <- getSrcSpanAP
  toks <- getToks
  let
    -- pos = ss2pos lm  -- start of the syntax fragment
    moduleTok = head $ filter ghcIsModule toks
    whereTok  = head $ filter ghcIsWhere  toks

    annSpecific = AnnModuleName mPos mnPos opPos cpPos wherePos
         `debug` ("annotateModuleHeader:" ++ show (pos,mPos,ss2span $ tokenSpan moduleTok))
    mPos  = ss2delta pos $ tokenSpan moduleTok
    -- mnPos = ss2delta pos l
    mnPos = deltaFromSrcSpans (tokenSpan moduleTok) l
    -- wherePos = ss2delta pos $ tokenSpan whereTok
    wherePos = ss2delta pos $ tokenSpan whereTok
    (opPos,cpPos) = case mexp of
      Nothing -> (Nothing,Nothing)
      Just exps -> (Just opPos',Just cpPos')
        where
          opTok = head $ filter ghcIsOParen toks
          cpSpan = case exps of
            [] -> tokenSpan opTok
            _  -> GHC.getLoc (last exps)
          cpTok   = head $ filter ghcIsCParen toks
          -- opPos'  = ss2delta pos   $ tokenSpan opTok
          opPos'  = deltaFromSrcSpans l (tokenSpan opTok)
          -- cpPos'  = ss2delta cpRel $ tokenSpan cpTok
          cpPos'  = deltaFromSrcSpans cpSpan (tokenSpan cpTok)

  case mexp of
    Nothing -> return ()
    Just exps -> mapM_ annotateLIE exps

  leaveAST annSpecific
-}
-- ---------------------------------------------------------------------

instance AnnotateP [GHC.LIE GHC.RdrName] where
   annotateP ss ls = do
     mapM_ annotatePC ls
     return Nothing

instance AnnotateP (GHC.IE GHC.RdrName) where
  annotateP l ie = do
    ma <- getAnnotationAP l GHC.AnnComma
    -- let ma = Nothing
              `debug` ("annotateP.IE entered for:" ++ showGhc l)
    let mc = deltaFromMaybeSrcSpans (Just l) ma
    annSpecific <- case ie of
      -- This receives the toks for the entire exports section.
      -- So it can scan for the separating comma if required
        (GHC.IEVar (GHC.L ln _)) -> do
          mpattern <- getAnnotationAP l GHC.AnnPattern
          let vp = case mpattern of
                Nothing -> DP (0,0)
                Just pp -> deltaFromSrcSpans pp ln
          let mp = deltaFromMaybeSrcSpans (Just l) mpattern
          return (AnnIEVar mp vp mc)

        (GHC.IEThingAbs _) -> return (AnnIEThingAbs mc)

        (GHC.IEThingWith (GHC.L ln n) ns) -> do
           Just o <- getAnnotationAP l GHC.AnnOpen
           Just c <- getAnnotationAP l GHC.AnnClose
           let op = deltaFromSrcSpans ln o
           pushPriorEnd o
           mapM_ annotatePC ns
           popPriorEnd
           let pp = if null ns then o else (GHC.getLoc $ last ns)
           let cp = deltaFromSrcSpans pp c
           return (AnnIEThingWith op cp mc)

        (GHC.IEThingAll (GHC.L ln n)) -> do
           Just o  <- getAnnotationAP l GHC.AnnOpen
           Just dd <- getAnnotationAP l GHC.AnnDotdot
           Just c  <- getAnnotationAP l GHC.AnnClose
           let op = deltaFromSrcSpans ln o
           let dp = deltaFromSrcSpans o  dd
           let cp = deltaFromSrcSpans dd c
           return (AnnIEThingAll op dp cp mc)

        x -> error $ "annotateP.IE: notimplemented for " ++ showGhc x

    let annSpecific' = annSpecific `debug` ("annotateP.IE:annSpecific=" ++ show annSpecific)
    addAnnValue annSpecific'
    return (Just (maybe l id ma)) -- `debug` ("annotateP.IE:annSpecific=" ++ show ma)

-- ---------------------------------------------------------------------

instance AnnotateP GHC.RdrName where
  annotateP l n = do
    ma <- getAnnotationAP l GHC.AnnComma
    let mc = deltaFromMaybeSrcSpans (Just l) ma
    addAnnValue (AnnListItem mc)
    return (Just (maybe l id ma))

-- ---------------------------------------------------------------------
{-
annotateImportDecl :: GHC.LImportDecl GHC.RdrName -> AP ()
annotateImportDecl (GHC.L l (GHC.ImportDecl (GHC.L ln _) _pkg _src _safe qual _impl as hiding)) = do
  enterAST l
  toksIn <- getToks
  let
    p = ss2pos l
    (_,toks,_) = splitToksForSpan l toksIn
    impPos = findPrecedingDelta ghcIsImport ln toks p

    mqual = if qual
              then Just (findPrecedingDelta ghcIsQualified ln toks p)
              else Nothing

    (mas,maspos) = case as of
      Nothing -> (Nothing,Nothing)
      Just _  -> (Just (findDelta ghcIsAs l toks p),asp)
        where
           (_,middle,_) = splitToksForSpan l toks
           asp = case filter ghcIsAnyConid (reverse middle) of
             [] -> Nothing
             (t:_) -> Just (ss2delta (ss2pos l) $ tokenSpan t)

    mhiding = case hiding of
      Nothing -> Nothing
      Just (True, _)  -> Just (findDelta ghcIsHiding l toks p)
      Just (False,_)  -> Nothing

    (ies,opPos,cpPos) = case hiding of
      Nothing -> ([],Nothing,Nothing)
      Just (_,ies') -> (ies',opPos',cpPos')
        where
          opTok = head $ filter ghcIsOParen toks
          cpTok = head $ filter ghcIsCParen toks
          opPos' = Just $ ss2delta p     $ tokenSpan opTok
          cpPos' = Just $ ss2delta cpRel $ tokenSpan cpTok
          (_toksI,_toksRest,cpRel) = case ies of
            [] -> (toks,toks,ss2posEnd $ tokenSpan opTok)
            _ -> let (_,etoks,ts) = splitToks (GHC.getLoc (head ies),
                                               GHC.getLoc (last ies)) toks
                 in (etoks,ts,ss2posEnd $ GHC.getLoc (last ies))

  mapM_ annotateLIE ies

  leaveAST $ AnnImportDecl impPos Nothing Nothing mqual mas maspos mhiding opPos cpPos


{-
ideclName :: Located ModuleName
    Module name.

ideclPkgQual :: Maybe FastString
    Package qualifier.

ideclSource :: Bool
    True = {--} import

ideclSafe :: Bool
    True => safe import

ideclQualified :: Bool
    True => qualified

ideclImplicit :: Bool
    True => implicit import (of Prelude)

ideclAs :: Maybe ModuleName
    as Module

ideclHiding :: Maybe (Bool, [LIE name])
    (True => hiding, names)

-}

-- =====================================================================
-- ---------------------------------------------------------------------


getListAnnInfo :: GHC.SrcSpan
  -> (PosToken -> Bool) -> (PosToken -> Bool)
  -> [Comment] -> [PosToken]
  -> Maybe DeltaPos
getListAnnInfo l isSeparator isTerminator cs toks = mc
  where mc = calcListOffsets isSeparator isTerminator l toks

isCommaOrCParen :: PosToken -> Bool
isCommaOrCParen t = ghcIsComma t || ghcIsCParen t

-- ---------------------------------------------------------------------

calcListOffsets :: (PosToken -> Bool) -> (PosToken -> Bool)
  -> GHC.SrcSpan
  -> [PosToken]
  -> Maybe DeltaPos
calcListOffsets isSeparator isTerminator l toks = mc
  where
    mc = case findTrailing isToken l toks of
      Nothing -> Nothing
      Just t  -> mc'
        where mc' = if isSeparator t
                      then Just (ss2delta (ss2posEnd l) (tokenSpan t))
                      else Nothing

    isToken t = isSeparator t || isTerminator t

-- ---------------------------------------------------------------------

annotateLHsDecl :: GHC.LHsDecl GHC.RdrName -> AP ()
annotateLHsDecl (GHC.L l decl) =
   case decl of
      GHC.TyClD d -> annotateLTyClDecl (GHC.L l d)
      GHC.InstD d -> error $ "annotateLHsDecl:unimplemented " ++ "InstD"
      GHC.DerivD d -> error $ "annotateLHsDecl:unimplemented " ++ "DerivD"
      GHC.ValD d -> annotateLHsBind (GHC.L l d)
      GHC.SigD d -> annotateLSig (GHC.L l d)
      GHC.DefD d -> error $ "annotateLHsDecl:unimplemented " ++ "DefD"
      GHC.ForD d -> error $ "annotateLHsDecl:unimplemented " ++ "ForD"
      GHC.WarningD d -> error $ "annotateLHsDecl:unimplemented " ++ "WarningD"
      GHC.AnnD d -> error $ "annotateLHsDecl:unimplemented " ++ "AnnD"
      GHC.RuleD d -> error $ "annotateLHsDecl:unimplemented " ++ "RuleD"
      GHC.VectD d -> error $ "annotateLHsDecl:unimplemented " ++ "VectD"
      GHC.SpliceD d -> error $ "annotateLHsDecl:unimplemented " ++ "SpliceD"
      GHC.DocD d -> error $ "annotateLHsDecl:unimplemented " ++ "DocD"
      GHC.QuasiQuoteD d -> error $ "annotateLHsDecl:unimplemented " ++ "QuasiQuoteD"
      GHC.RoleAnnotD d -> error $ "annotateLHsDecl:unimplemented " ++ "RoleAnnotD"

-- ---------------------------------------------------------------------

annotateLHsBind :: GHC.LHsBindLR GHC.RdrName GHC.RdrName -> AP ()
annotateLHsBind (GHC.L l (GHC.FunBind (GHC.L _ n) isInfix (GHC.MG matches _ _ _) _ _ _)) = do
  enterAST l
  mapM_ (\m -> annotateLMatch m n isInfix) matches
  leaveAST AnnFunBind

annotateLHsBind (GHC.L l (GHC.PatBind lhs@(GHC.L ll _) grhss@(GHC.GRHSs grhs lb) _typ _fvs _ticks)) = do
  enterAST l

  annotateLPat lhs
  mapM_ annotateLGRHS grhs
  annotateHsLocalBinds lb

  toksIn <- getToks

  let [lr] = getListSrcSpan grhs
  let el = GHC.mkSrcSpan (GHC.srcSpanEnd ll) (GHC.srcSpanStart lr)

  let eqPos = case findTokenSrcSpan ghcIsEqual el toksIn of
        Nothing -> Nothing
        Just ss -> Just $ ss2delta (ss2posEnd ll) ss

  let wherePos = getGRHSsWherePos grhss toksIn

  leaveAST (AnnPatBind eqPos wherePos)


annotateLHsBind (GHC.L l (GHC.VarBind n rhse _)) = do
  -- Note: this bind is introduced by the typechecker
  enterAST l
  annotateLHsExpr rhse
  leaveAST AnnNone

annotateLHsBind (GHC.L l (GHC.PatSynBind n _fvs args patsyndef patsyn_dir)) = do
  enterAST l
  leaveAST AnnPatSynBind

{-
PatSynBind

patsyn_id :: Located idL

    Name of the pattern synonym
bind_fvs :: NameSet

    After the renamer, this contains the locally-bound free variables of this defn. See Note [Bind free vars]
patsyn_args :: HsPatSynDetails (Located idR)

    Formal parameter names
patsyn_def :: LPat idR

    Right-hand side
patsyn_dir :: HsPatSynDir idR

    Directionality-}

-- ---------------------------------------------------------------------

annotateLMatch :: (GHC.LMatch GHC.RdrName (GHC.LHsExpr GHC.RdrName))
  -> GHC.RdrName -> Bool
  -> AP ()
annotateLMatch (GHC.L l (GHC.Match pats _typ grhss@(GHC.GRHSs grhs lb))) n isInfix = do
  enterAST l
  toksIn <- getToks
  let
    (_,matchToks,_) = splitToksForSpan l toksIn
    nPos = if isInfix
             then fromJust $ findTokenWrtPrior ghcIsFunName ln matchToks
             else findDelta ghcIsFunName l matchToks (ss2pos l)

    ln = GHC.mkSrcSpan (GHC.srcSpanEnd (GHC.getLoc (head pats)))
                       (GHC.srcSpanEnd l)

    eqPos = case grhs of
             [GHC.L _ (GHC.GRHS [] _)] -> findTokenWrtPrior ghcIsEqual l toksIn -- unguarded
             _                         -> Nothing
    wherePos = getGRHSsWherePos grhss toksIn
{-
    wherePos = case lb of
      GHC.EmptyLocalBinds -> Nothing
      GHC.HsIPBinds i -> Nothing `debug` ("annotateLMatch.wherePos:got " ++ (SYB.showData SYB.Parser 0 i))
      GHC.HsValBinds (GHC.ValBindsIn binds sigs) -> Just wp
        where
          [lbs] = getListSrcSpan $ GHC.bagToList binds
          lvb = case sigs of
            [] -> lbs
            _  -> GHC.combineSrcSpans lbs lcs
              where [lcs] = getListSrcSpan sigs
          [lg] = getListSrcSpan grhs
          wp = findPrecedingDelta ghcIsWhere lvb toksIn (ss2posEnd lg)
-}

  mapM_ annotateLPat pats
  mapM_ annotateLGRHS grhs
  annotateHsLocalBinds lb
  leaveAST (AnnMatch nPos n isInfix eqPos wherePos)

-- ---------------------------------------------------------------------

getGRHSsWherePos :: GHC.GRHSs GHC.RdrName (GHC.LHsExpr GHC.RdrName) -> [PosToken] -> Maybe DeltaPos
getGRHSsWherePos (GHC.GRHSs grhs lb) toksIn = wherePos
  where
    wherePos = case lb of
      GHC.EmptyLocalBinds -> Nothing
      GHC.HsIPBinds i -> Nothing `debug` ("annotateLMatch.wherePos:got " ++ (pp i))
      GHC.HsValBinds (GHC.ValBindsIn binds sigs) -> Just wp
        where
          [lbs] = getListSrcSpan $ GHC.bagToList binds
          lvb = case sigs of
            [] -> lbs
            _  -> GHC.combineSrcSpans lbs lcs
              where [lcs] = getListSrcSpan sigs
          [lg] = getListSrcSpan grhs
          wp = findPrecedingDelta ghcIsWhere lvb toksIn (ss2posEnd lg)

-- ---------------------------------------------------------------------
{-
rhs     :: { Located (GRHSs RdrName) }
        : '=' exp wherebinds    { sL (comb3 $1 $2 $3) $ GRHSs (unguardedRHS $2) (unLoc $3) }
        | gdrhs wherebinds      { LL $ GRHSs (reverse (unLoc $1)) (unLoc $2) }

gdrhs :: { Located [LGRHS RdrName] }
        : gdrhs gdrh            { LL ($2 : unLoc $1) }
        | gdrh                  { L1 [$1] }

gdrh :: { LGRHS RdrName }
        : '|' guardquals '=' exp        { sL (comb2 $1 $>) $ GRHS (unLoc $2) $4 }

-}

annotateLGRHS :: GHC.LGRHS GHC.RdrName (GHC.LHsExpr GHC.RdrName) -> AP ()
annotateLGRHS (GHC.L l (GHC.GRHS guards expr)) = do
  enterAST l

  toksIn <- getToks
  let
    (guardPos,eqPos) = case guards of
             [] -> (Nothing,Nothing)
             _  -> (Just $ findDelta ghcIsVbar l toksIn (ss2pos l)
                   , findTokenWrtPrior ghcIsEqual l toksIn)


  mapM_ annotateLStmt guards
  annotateLHsExpr expr

  leaveAST (AnnGRHS guardPos eqPos)

-- ---------------------------------------------------------------------

annotateLSig :: GHC.LSig GHC.RdrName -> AP ()
annotateLSig (GHC.L l (GHC.TypeSig lns typ)) = do
  enterAST l

  toks <- getToks
  let [ls] = getListSrcSpan lns

{-
  let [ls] = getListSrcSpan lns
  let (_,ltoks,_) = splitToksForSpan ls toks
  mapM_ (annotateListItem ltoks noOp) lns
-}
  annotateListItems lns noOp

  let dcolonPos = findDelta ghcIsDcolon l toks (ss2posEnd ls)

  annotateLHsType typ

  leaveAST (AnnTypeSig dcolonPos)

-- ---------------------------------------------------------------------

noOp :: a -> AP ()
noOp _ = return ()

-- ---------------------------------------------------------------------

annotateLHsType :: GHC.LHsType GHC.RdrName -> AP ()
annotateLHsType (GHC.L l (GHC.HsForAllTy f bndrs ctx@(GHC.L lc cc) typ)) = do
  enterAST l
  toks <- getToks
  annotateListItems cc annotateLHsType
  let (opPos,darrowPos,cpPos) = case cc of
        [] -> (Nothing,Nothing,Nothing)
        _  -> (op,da,cp)
          where
            [lca] = getListSrcSpan cc
            op = findPrecedingMaybeDelta ghcIsOParen lca toks (ss2pos l)
            da = Just (findDelta ghcIsDarrow l toks (ss2posEnd lc))
            cp = findTrailingMaybeDelta ghcIsCParen lca toks (ss2posEnd lca)
  annotateLHsType typ
  leaveAST (AnnHsForAllTy opPos darrowPos cpPos)

annotateLHsType (GHC.L l (GHC.HsTyVar _n)) = do
  enterAST l
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsAppTy t1 t2)) = do
  enterAST l
  annotateLHsType t1
  annotateLHsType t2
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsFunTy t1@(GHC.L l1 _) t2)) = do
  enterAST l
  toks <- getToks
  annotateLHsType t1
  let raPos = findDelta ghcIsRarrow l toks (ss2posEnd l1)
  annotateLHsType t2
  leaveAST (AnnHsFunTy raPos)

annotateLHsType (GHC.L l (GHC.HsListTy t)) = do
  enterAST l
  annotateLHsType t
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsPArrTy t)) = do
  enterAST l
  annotateLHsType t
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsTupleTy srt typs)) = do
  -- sort can be HsBoxedOrConstraintTuple for (Int,Int)
  --             HsUnboxedTuple           for (# Int, Int #)

  -- '('            { L _ IToparen }
  -- ')'            { L _ ITcparen }
  -- '(#'           { L _ IToubxparen }
  -- '#)'           { L _ ITcubxparen }

  enterAST l
  toks <- getToks
  let (isOpenTok,isCloseTok) = case srt of
        GHC.HsUnboxedTuple -> (ghcIsOubxparen,ghcIsCubxparen)
        _                  -> (ghcIsOParen,   ghcIsCParen)
  let opPos = findDelta isOpenTok  l toks (ss2pos l)

  -- mapM_ annotateLHsType typs
  annotateListItems typs annotateLHsType

  let [lt] = getListSrcSpan typs
  let cpPos = findDelta isCloseTok l toks (ss2posEnd lt)
  leaveAST (AnnHsTupleTy opPos cpPos)
    -- `debug` ("annotateLHsType.HsTupleTy:(l,cpPos):" ++ show (ss2span l,cpPos))

annotateLHsType (GHC.L l (GHC.HsOpTy t1 (_,ln) t2)) = do
  enterAST l
  annotateLHsType t1

-- type LHsTyOp name = HsTyOp (Located name)
-- type HsTyOp name = (HsTyWrapper, name)
  -- annotateLHsType op

  annotateLHsType t1
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsParTy typ)) = do
  enterAST l
  toks <- getToks
  let opPos = findDelta ghcIsOParen l toks (ss2pos l)
  annotateLHsType typ
  let cpPos = findDelta ghcIsCParen l toks (ss2posEnd l)
  leaveAST (AnnHsParTy opPos cpPos) -- `debug` ("annotateLHsType.HsParTy:(l,opPos,cpPos)=" ++ show (ss2span l,opPos,cpPos))

annotateLHsType (GHC.L l (GHC.HsIParamTy _n typ)) = do
  --  ipvar '::' type               { LL (HsIParamTy (unLoc $1) $3) }
  -- HsIParamTy HsIPName (LHsType name)
  enterAST l
  toks <- getToks
  let dcolonPos = findDelta ghcIsDcolon l toks (ss2pos l)
  annotateLHsType typ
  leaveAST (AnnHsIParamTy dcolonPos)

annotateLHsType (GHC.L l (GHC.HsEqTy t1 t2)) = do
  -- : btype '~'      btype          {% checkContext
  --                                     (LL $ HsEqTy $1 $3) }
  enterAST l
  annotateLHsType t1
  toks <- getToks
  let tildePos = findDelta ghcIsTilde l toks (ss2pos l)
  annotateLHsType t2
  leaveAST (AnnHsEqTy tildePos)

annotateLHsType (GHC.L l (GHC.HsKindSig t@(GHC.L lt _) k@(GHC.L kl _))) = do
  -- HsKindSig (LHsType name) (LHsKind name)
  --  '(' ctype '::' kind ')'        { LL $ HsKindSig $2 $4 }
  enterAST l
  toks <- getToks
  let opPos = findPrecedingDelta ghcIsOParen l toks (ss2pos l)
  annotateLHsType t
  let dcolonPos = findDelta ghcIsDcolon l toks (ss2posEnd lt)
  annotateLHsType k
  let cpPos = findTrailingDelta ghcIsCParen l toks (ss2posEnd kl)
  leaveAST (AnnHsKindSig opPos dcolonPos cpPos)

annotateLHsType (GHC.L l (GHC.HsQuasiQuoteTy qq)) = do
  -- HsQuasiQuoteTy (HsQuasiQuote name)
  enterAST l
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsSpliceTy splice _)) = do
  -- HsSpliceTy (HsSplice name) PostTcKind
  enterAST l
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsDocTy t ds)) = do
  -- HsDocTy (LHsType name) LHsDocString
  -- The docstring is treated as a normal comment
  enterAST l
  annotateLHsType t
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsBangTy _bang t)) = do
  -- HsBangTy HsBang (LHsType name)
  enterAST l
  toks <- getToks
  let bangPos = findDelta ghcIsBang l toks (ss2posEnd l)
  annotateLHsType t
  leaveAST (AnnHsBangTy bangPos)

annotateLHsType (GHC.L l (GHC.HsRecTy decs)) = do
  -- HsRecTy [ConDeclField name]
  enterAST l
  mapM_ annotateConDeclField decs
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsCoreTy typ)) = do
  -- HsCoreTy Type
  enterAST l
  leaveAST AnnNone

annotateLHsType (GHC.L l (GHC.HsExplicitListTy _ typs)) = do
  -- HsExplicitListTy PostTcKind [LHsType name]
  enterAST l
  toks <- getToks
  let obPos = findPrecedingDelta ghcIsOBrack  l toks (ss2pos l)
  annotateListItems typs annotateLHsType
  let cbPos = findTrailingDelta ghcIsCBrack l toks (ss2posEnd l)

  leaveAST (AnnHsExplicitListTy obPos cbPos)

annotateLHsType (GHC.L l (GHC.HsExplicitTupleTy _ typs)) = do
  -- HsExplicitTupleTy [PostTcKind] [LHsType name]
  enterAST l
  toks <- getToks
  let opPos = findPrecedingDelta ghcIsOParen l toks (ss2pos l)
  annotateListItems typs annotateLHsType
  let cpPos = findTrailingDelta ghcIsCParen  l toks (ss2posEnd l)

  leaveAST (AnnHsExplicitTupleTy opPos cpPos)
    -- `debug` ("AnnListItem.HsExplicitTupleTy:(l,opPos,cpPos)=" ++ show (ss2span l,opPos,cpPos))

annotateLHsType (GHC.L l (GHC.HsTyLit _lit)) = do
 -- HsTyLit HsTyLit
  enterAST l
  leaveAST AnnNone

annotateLHsType (GHC.L _l (GHC.HsWrapTy _w _t)) = return ()
  -- HsWrapTy HsTyWrapper (HsType name)
  -- These are not emitted by the parse

-- annotateLHsType (GHC.L l t) = do
--   enterAST l
--   leaveAST AnnNone `debug` ("annotateLHSType:ignoring " ++ (SYB.showData SYB.Parser 0 t))

-- ---------------------------------------------------------------------

annotateConDeclField :: GHC.ConDeclField GHC.RdrName -> AP ()
annotateConDeclField (GHC.ConDeclField ln lbang ldoc) = do
  -- enterAST l
  -- leaveAST AnnNone
  return ()

-- ---------------------------------------------------------------------

annotateListItems :: [GHC.Located a] -> (GHC.Located a -> AP ()) -> AP ()
annotateListItems lns subAnnFun = do
  toks <- getToks
  let [ls] = getListSrcSpan lns
  let (_,ltoks,_) = splitToksForSpan ls toks
  mapM_ (annotateListItem ltoks subAnnFun) lns

-- |Annotate a comma-separated list of names
annotateListItem ::  [PosToken] -> (GHC.Located a -> AP ()) -> GHC.Located a ->AP ()
annotateListItem ltoks subAnnFun a@(GHC.L l _) = do
  enterAST l
  subAnnFun a
  let commaPos = findTrailingComma l ltoks
  leaveAST (AnnListItem commaPos) -- `debug` ("annotateListItem:(ss,l,commaPos)=" ++ show (ss2span ss,ss2span l,commaPos))

-- ---------------------------------------------------------------------

findTokenWrtPrior :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe DeltaPos
findTokenWrtPrior isToken le toksIn = eqPos -- `debug` ("findTokenWrtPrior:" ++ show (ss2span le))
  where
    mspan = findTokenSrcSpan isToken le toksIn
    eqPos = findTokenWrtPriorF mspan toksIn

-- ---------------------------------------------------------------------

findTokenWrtPriorReversed :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe DeltaPos
findTokenWrtPriorReversed isToken le toksIn = eqPos -- `debug` ("findTokenWrtPrior:" ++ show (ss2span le))
  where
    mspan = findTokenSrcSpanReverse isToken le toksIn
    eqPos = findTokenWrtPriorF mspan toksIn

-- ---------------------------------------------------------------------

findTokenWrtPriorF :: Maybe GHC.SrcSpan -> [PosToken] -> Maybe DeltaPos
findTokenWrtPriorF mspan toksIn = eqPos
  where
    eqPos = case mspan of
      Just eqSpan -> Just $ ss2delta pe eqSpan
        where
          (before,_,_) = splitToksForSpan eqSpan toksIn
          prior = head $ dropWhile ghcIsBlankOrComment $ reverse before
          pe = tokenPosEnd prior
      Nothing -> Nothing

-- ---------------------------------------------------------------------

annotateLPat :: GHC.LPat GHC.RdrName -> AP ()
annotateLPat (GHC.L l pat) = do
  enterAST l

  toks <- getToks

  ann <- case pat of
    GHC.NPat ol _ _ -> annotateLHsExpr (GHC.L l (GHC.HsOverLit ol)) >> return AnnNone

    GHC.AsPat (GHC.L ln _) pat2 -> do
      let asPos = findDelta ghcIsAt l toks (ss2posEnd ln)
      annotateLPat pat2
      return (AnnAsPat asPos)

    GHC.TuplePat pats boxity _ -> do
      let (isOpen,isClose) = if boxity == GHC.Boxed
                              then (ghcIsOParen,ghcIsCParen)
                              else (ghcIsOubxparen,ghcIsCubxparen)
      let opPos = findDelta isOpen l toks (ss2pos l)
      annotateListItems pats annotateLPat
      let Just cpPos = findTokenWrtPriorReversed isClose l toks

      return (AnnTuplePat opPos cpPos)

    GHC.VarPat _ -> return AnnNone

    p -> return AnnNone
      `debug` ("annotateLPat:ignoring " ++ (pp p))

  leaveAST ann

-- ---------------------------------------------------------------------

annotateLStmt :: GHC.LStmt GHC.RdrName (GHC.LHsExpr GHC.RdrName) -> AP ()
annotateLStmt (GHC.L l (GHC.BodyStmt body _ _ _)) = do
  enterAST l
  annotateLHsExpr body
  leaveAST AnnStmtLR

annotateLStmt (GHC.L l (GHC.LetStmt lb)) = do
  enterAST l
  toksIn <- getToks
  let
    p = ss2pos l

    Just letp = findTokenSrcSpan ghcIsLet l toksIn
    -- Just inp  = findTokenSrcSpan ghcIsIn l toksIn
    letPos = Just $ ss2delta p letp
    -- inPos  = Just $ ss2delta p inp
    inPos  = Nothing

  annotateHsLocalBinds lb

  leaveAST (AnnLetStmt letPos inPos)

-- ---------------------------------------------------------------------

annotateHsLocalBinds :: (GHC.HsLocalBinds GHC.RdrName) -> AP ()
annotateHsLocalBinds (GHC.HsValBinds (GHC.ValBindsIn binds sigs)) = do
    mapM_ annotateLHsBind (GHC.bagToList binds)
    mapM_ annotateLSig sigs

annotateHsLocalBinds (GHC.HsValBinds _) = assert False undefined
annotateHsLocalBinds (GHC.HsIPBinds vb) = assert False undefined
annotateHsLocalBinds (GHC.EmptyLocalBinds) = return ()

-- ---------------------------------------------------------------------

annotateLHsExpr :: GHC.LHsExpr GHC.RdrName -> AP ()
annotateLHsExpr (GHC.L l exprIn) = do
  enterAST l
  toksIn <- getToks
  ann <- case exprIn of
    GHC.HsOverLit ov -> return (AnnOverLit str)
      where
        -- r = [(l,[Ann [] (ss2span l) (AnnOverLit str)])]
        Just tokLit = findToken ghcIsOverLit l toksIn
        str = tokenString tokLit

    GHC.OpApp e1 op _f e2 -> do
      annotateLHsExpr e1
      annotateLHsExpr op
      annotateLHsExpr e2
      return AnnNone

    GHC.HsLet lb expr -> do
      let
        p = ss2pos l

        Just letp = findTokenSrcSpan ghcIsLet l toksIn
        Just inp  = findTokenSrcSpan ghcIsIn l toksIn
        letPos = Just $ ss2delta p letp
        inPos  = Just $ ss2delta p inp

      annotateHsLocalBinds lb
      annotateLHsExpr expr

      return (AnnHsLet letPos inPos)

    -- HsDo (HsStmtContext Name) [ExprLStmt id] PostTcType
    GHC.HsDo ctx stmts _typ -> do
      let
        p = ss2pos l

        Just dop = findTokenSrcSpan ghcIsDo l toksIn
        doPos = Just $ ss2delta p dop

      mapM_ annotateLStmt stmts

      return (AnnHsDo doPos)

    GHC.ExplicitTuple args boxity -> do
      let (isOpen,isClose) = if boxity == GHC.Boxed
                              then (ghcIsOParen,ghcIsCParen)
                              else (ghcIsOubxparen,ghcIsCubxparen)
      let opPos = findDelta isOpen l toksIn (ss2pos l)
      let (_,ltoks,_) = splitToksForSpan l toksIn
      mapM_ (annotateHsTupArg ltoks) args
      let Just cpPos = findTokenWrtPriorReversed isClose l toksIn

      return (AnnExplicitTuple opPos cpPos)
        -- `debug` ("annotateLHsExpr.ExplicitTuple:(l,opPos,cpPos)=" ++ show (ss2span l,opPos,cpPos))


    GHC.HsVar _ -> return AnnNone

    -- HsApp (LHsExpr id) (LHsExpr id)
    GHC.HsApp e1 e2 -> do
      annotateLHsExpr e1
      annotateLHsExpr e2
      return AnnNone

    -- ArithSeq PostTcExpr (Maybe (SyntaxExpr id)) (ArithSeqInfo id)
    -- x| texp '..'             { LL $ ArithSeq noPostTcExpr (From $1) }
    -- x| texp ',' exp '..'     { LL $ ArithSeq noPostTcExpr (FromThen $1 $3) }
    -- x| texp '..' exp         { LL $ ArithSeq noPostTcExpr (FromTo $1 $3) }
    -- x| texp ',' exp '..' exp { LL $ ArithSeq noPostTcExpr (FromThenTo $1 $3 $5) }
    GHC.ArithSeq _ _ seqInfo -> do
      let obPos = findDelta ghcIsOBrack l toksIn (ss2pos l)
          getComma l1 l2 = Just $ findDelta ghcIsComma ll toksIn (ss2posEnd l1)
            where ll = GHC.mkSrcSpan (GHC.srcSpanEnd l1) (GHC.srcSpanStart l2)
      (ld,mcPos) <- case seqInfo of
        GHC.From e1@(GHC.L l1 _) -> annotateLHsExpr e1 >> return (l1,Nothing)
        GHC.FromTo e1@(GHC.L l1 _) e2 -> annotateLHsExpr e1 >> annotateLHsExpr e2 >> return (l1,Nothing)
        GHC.FromThen e1@(GHC.L l1 _) e2@(GHC.L l2 _) ->
          annotateLHsExpr e1 >> annotateLHsExpr e2 >> return (l2,(getComma l1 l2))
        GHC.FromThenTo e1@(GHC.L l1 _) e2@(GHC.L l2 _) e3 -> do
          annotateLHsExpr e1
          annotateLHsExpr e2
          annotateLHsExpr e3
          return (l2,(getComma l1 l2))
      let ddPos = findDelta ghcIsDotdot l toksIn (ss2posEnd ld)
      let Just cbPos = findTokenWrtPriorReversed ghcIsCBrack l toksIn

      return (AnnArithSeq obPos mcPos ddPos cbPos)

    e -> return AnnNone
       `debug` ("annotateLHsExpr:not processing:" ++ (pp e))

  leaveAST ann

-- ---------------------------------------------------------------------

annotateHsTupArg :: [PosToken] -> GHC.HsTupArg GHC.RdrName -> AP ()
annotateHsTupArg ltoks (GHC.Present e@(GHC.L l _)) = do
  enterAST l
  annotateLHsExpr e
  let commaPos = findTrailingComma l ltoks
  leaveAST (AnnListItem commaPos)

annotateHsTupArg _ (GHC.Missing _) = return ()

-- ---------------------------------------------------------------------

annotateLTyClDecl :: GHC.LTyClDecl GHC.RdrName -> AP ()
annotateLTyClDecl (GHC.L l (GHC.DataDecl _ln (GHC.HsQTvs _ns _tyVars) defn _)) = do
  enterAST l
  toksIn <- getToks
  let
    Just eqPos = findTokenWrtPrior ghcIsEqual l toksIn

  annotateHsDataDefn defn
  leaveAST (AnnDataDecl eqPos)

-- ---------------------------------------------------------------------

annotateHsDataDefn :: (GHC.HsDataDefn GHC.RdrName) -> AP ()
annotateHsDataDefn (GHC.HsDataDefn nOrD ctx mtyp mkind cons mderivs) = do
  mapM_ annotateLConDecl cons

-- ---------------------------------------------------------------------

annotateLConDecl :: (GHC.LConDecl GHC.RdrName) -> AP ()
annotateLConDecl (GHC.L l (GHC.ConDecl ln exp qvars ctx dets res _ _)) = do
  enterAST l
  toksIn <- getToks
  cs <- getComments
  let
    mc = getListAnnInfo l ghcIsVbar (const False) cs toksIn
  leaveAST (AnnConDecl mc)
-}
-- ---------------------------------------------------------------------

getListSpan :: [GHC.Located e] -> [Span]
getListSpan xs = map ss2span $ getListSrcSpan xs

getListSrcSpan :: [GHC.Located e] -> [GHC.SrcSpan]
getListSrcSpan [] = []
getListSrcSpan xs = [GHC.mkSrcSpan (GHC.srcSpanStart (GHC.getLoc (head xs)))
                                   (GHC.srcSpanEnd   (GHC.getLoc (last xs)))
                    ]

getListSpans :: [GHC.Located e] -> [Span]
getListSpans xs = map (ss2span . GHC.getLoc) xs


commentPos :: Comment -> (Pos,Pos)
commentPos (Comment _ p _) = p

dcommentPos :: DComment -> (DeltaPos,DeltaPos)
dcommentPos (DComment _ p _) = p


-- ---------------------------------------------------------------------

-- | Given an enclosing Span @(p,e)@, and a list of sub SrcSpans @ds@,
-- identify all comments that are in @(p,e)@ but not in @ds@, and convert
-- them to be DComments relative to @p@
localComments :: Span -> [Comment] -> [Span] -> ([DComment],[Comment])
localComments pin cs ds = r -- `debug` ("localComments:(p,ds,r):" ++ show ((p,e),ds,map commentPos matches,map dcommentPos r))
  where
    r = (map (\c -> deltaComment p c) matches,misses ++ missesRest)
    (p,e) = if pin == ((1,1),(1,1))
               then  ((1,1),(99999999,1))
               else pin

    (matches,misses) = partition notSub cs'
    (cs',missesRest) = partition (\(Comment _ com _) -> isSubPos com (p,e)) cs

    notSub :: Comment -> Bool
    notSub (Comment _ com _) = not $ any (\sub -> isSubPos com sub) ds

    isSubPos (subs,sube) (parents,parente)
      = parents <= subs && parente >= sube

-- ---------------------------------------------------------------------

findTokenSrcSpan :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe GHC.SrcSpan
findTokenSrcSpan isToken ss toks =
  case findToken isToken ss toks of
      Nothing -> Nothing
      Just t  -> Just (tokenSpan t)

-- ---------------------------------------------------------------------

findTokenSrcSpanReverse :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe GHC.SrcSpan
findTokenSrcSpanReverse isToken ss toks =
  case findTokenReverse isToken ss toks of
      Nothing -> Nothing
      Just t  -> Just (tokenSpan t)

-- ---------------------------------------------------------------------

findToken :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe PosToken
findToken isToken ss toks = r
  where
    (_,middle,_) = splitToksForSpan ss toks
    r = case filter isToken middle of
      [] -> Nothing
      (t:_) -> Just t

-- ---------------------------------------------------------------------

findTokenReverse :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe PosToken
findTokenReverse isToken ss toks = r
  -- `debug` ("findTokenReverse:(ss,r,middle):" ++ show (ss2span ss,r,middle))
  where
    (_,middle,_) = splitToksForSpan ss toks
    r = case filter isToken (reverse middle) of
      [] -> Nothing
      (t:_) -> Just t

-- ---------------------------------------------------------------------

findPreceding :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe GHC.SrcSpan
findPreceding isToken ss toks = r
  where
    (toksBefore,_,_) = splitToksForSpan ss toks
    r = case filter isToken (reverse toksBefore) of
      [] -> Nothing
      (t:_) -> Just (tokenSpan t)

-- ---------------------------------------------------------------------

findPrecedingMaybeDelta :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken]
 -> Pos -> Maybe DeltaPos
findPrecedingMaybeDelta isToken ln toks p =
  case findPreceding isToken ln toks of
    Nothing -> Nothing
    Just ss -> Just (ss2delta p ss)

-- ---------------------------------------------------------------------

findPrecedingDelta :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken]
 -> Pos -> DeltaPos
findPrecedingDelta isToken ln toks p =
  case findPrecedingMaybeDelta isToken ln toks p of
    Nothing -> error $ "findPrecedingDelta: No matching token preceding :" ++ show (ss2span ln)
    Just d  -> d

-- ---------------------------------------------------------------------

findTrailingMaybeDelta :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken]
 -> Pos -> Maybe DeltaPos
findTrailingMaybeDelta isToken ln toks p =
  case findTrailing isToken ln toks of
    Nothing -> Nothing
    Just t -> Just (ss2delta p (tokenSpan t))

-- ---------------------------------------------------------------------

findTrailingDelta :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken]
 -> Pos -> DeltaPos
findTrailingDelta isToken ln toks p =
  case findTrailingMaybeDelta isToken ln toks p of
    Nothing -> error $ "findTrailingDelta: No matching token trailing :" ++ show (ss2span ln)
    Just d -> d

-- ---------------------------------------------------------------------

findDelta :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken]
 -> Pos -> DeltaPos
findDelta isToken ln toks p =
  case findTokenSrcSpan isToken ln toks of
    Nothing -> error $ "findPrecedingDelta: No matching token preceding :" ++ show (ss2span ln)
    Just ss -> ss2delta p ss

-- ---------------------------------------------------------------------

findDeltaReverse :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken]
 -> Pos -> DeltaPos
findDeltaReverse isToken ln toks p =
  case findTokenSrcSpanReverse isToken ln toks of
    Nothing -> error $ "findPrecedingDelta: No matching token preceding :" ++ show (ss2span ln)
    Just ss -> ss2delta p ss

-- ---------------------------------------------------------------------

findTrailingComma :: GHC.SrcSpan -> [PosToken] -> Maybe DeltaPos
findTrailingComma ss toks = r
  where
    (_,_,toksAfter) = splitToksForSpan ss toks
    r = case filter ghcIsComma toksAfter of
      [] -> Nothing
      (t:_) -> Just (ss2delta (ss2posEnd ss) $ tokenSpan t)


-- ---------------------------------------------------------------------

findTrailingSrcSpan :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe GHC.SrcSpan
findTrailingSrcSpan isToken ss toks = r
  where
    (_,_,toksAfter) = splitToksForSpan ss toks
    r = case filter isToken toksAfter of
      [] -> Nothing
      (t:_) -> Just (tokenSpan t)

-- ---------------------------------------------------------------------

findTrailing :: (PosToken -> Bool) -> GHC.SrcSpan -> [PosToken] -> Maybe PosToken
findTrailing isToken ss toks = r
  where
    (_,_,toksAfter) = splitToksForSpan ss toks
    r = case filter isToken toksAfter of
      [] -> Nothing
      (t:_) -> Just t


-- ---------------------------------------------------------------------

undeltaComment :: Pos -> DComment -> Comment
undeltaComment l (DComment b (dps,dpe) s) = Comment b ((undelta l dps),(undelta l dpe)) s

deltaComment :: Pos -> Comment -> DComment
deltaComment l (Comment b (s,e) str)
  = DComment b ((ss2deltaP l s),(ss2deltaP l e)) str

-- ---------------------------------------------------------------------

deriving instance Eq GHC.Token

ghcIsTok :: PosToken -> GHC.Token -> Bool
ghcIsTok ((GHC.L _ t),_s) tp = t == tp

ghcIsModule :: PosToken -> Bool
ghcIsModule t = ghcIsTok t GHC.ITmodule

ghcIsWhere :: PosToken -> Bool
ghcIsWhere t = ghcIsTok t GHC.ITwhere

ghcIsLet :: PosToken -> Bool
ghcIsLet t = ghcIsTok t GHC.ITlet

ghcIsAt :: PosToken -> Bool
ghcIsAt t = ghcIsTok t GHC.ITat

ghcIsElse :: PosToken -> Bool
ghcIsElse t = ghcIsTok t GHC.ITelse

ghcIsThen :: PosToken -> Bool
ghcIsThen t = ghcIsTok t GHC.ITthen

ghcIsOf :: PosToken -> Bool
ghcIsOf t = ghcIsTok t GHC.ITof

ghcIsDo :: PosToken -> Bool
ghcIsDo t = ghcIsTok t GHC.ITdo

ghcIsIn :: PosToken -> Bool
ghcIsIn t = ghcIsTok t GHC.ITin

ghcIsOParen :: PosToken -> Bool
ghcIsOParen t = ghcIsTok t GHC.IToparen

ghcIsCParen :: PosToken -> Bool
ghcIsCParen t = ghcIsTok t GHC.ITcparen

ghcIsOBrack :: PosToken -> Bool
ghcIsOBrack t = ghcIsTok t GHC.ITobrack

ghcIsCBrack :: PosToken -> Bool
ghcIsCBrack t = ghcIsTok t GHC.ITcbrack

ghcIsOubxparen :: PosToken -> Bool
ghcIsOubxparen t = ghcIsTok t GHC.IToubxparen

ghcIsCubxparen :: PosToken -> Bool
ghcIsCubxparen t = ghcIsTok t GHC.ITcubxparen

ghcIsComma :: PosToken -> Bool
ghcIsComma t = ghcIsTok t GHC.ITcomma

ghcIsImport :: PosToken -> Bool
ghcIsImport t = ghcIsTok t GHC.ITimport

ghcIsQualified :: PosToken -> Bool
ghcIsQualified t = ghcIsTok t GHC.ITqualified

ghcIsAs :: PosToken -> Bool
ghcIsAs t = ghcIsTok t GHC.ITas

ghcIsDcolon :: PosToken -> Bool
ghcIsDcolon t = ghcIsTok t GHC.ITdcolon

ghcIsTilde :: PosToken -> Bool
ghcIsTilde t = ghcIsTok t GHC.ITtilde

ghcIsBang :: PosToken -> Bool
ghcIsBang t = ghcIsTok t GHC.ITbang

ghcIsRarrow :: PosToken -> Bool
ghcIsRarrow t = ghcIsTok t GHC.ITrarrow

ghcIsDarrow :: PosToken -> Bool
ghcIsDarrow t = ghcIsTok t GHC.ITdarrow

ghcIsDotdot :: PosToken -> Bool
ghcIsDotdot t = ghcIsTok t GHC.ITdotdot

ghcIsConid :: PosToken -> Bool
ghcIsConid ((GHC.L _ t),_) = case t of
       GHC.ITconid _ -> True
       _             -> False

ghcIsQConid :: PosToken -> Bool
ghcIsQConid((GHC.L _ t),_) = case t of
       GHC.ITqconid _ -> True
       _              -> False

ghcIsVarid :: PosToken -> Bool
ghcIsVarid ((GHC.L _ t),_) = case t of
       GHC.ITvarid _ -> True
       _             -> False

ghcIsVarsym :: PosToken -> Bool
ghcIsVarsym ((GHC.L _ t),_) = case t of
       GHC.ITvarsym _ -> True
       _              -> False

ghcIsBackquote :: PosToken -> Bool
ghcIsBackquote t = ghcIsTok t GHC.ITbackquote

ghcIsFunName :: PosToken -> Bool
ghcIsFunName t = ghcIsVarid t || ghcIsVarsym t || ghcIsBackquote t

ghcIsAnyConid :: PosToken -> Bool
ghcIsAnyConid t = ghcIsConid t || ghcIsQConid t


ghcIsHiding :: PosToken -> Bool
ghcIsHiding t = ghcIsTok t GHC.IThiding

ghcIsEqual :: PosToken -> Bool
ghcIsEqual t = ghcIsTok t GHC.ITequal

ghcIsVbar :: PosToken -> Bool
ghcIsVbar t = ghcIsTok t GHC.ITvbar


ghcIsInteger :: PosToken -> Bool
ghcIsInteger ((GHC.L _ t),_)  = case t of
      GHC.ITinteger _ -> True
      _               -> False

ghcIsRational :: PosToken -> Bool
ghcIsRational ((GHC.L _ t),_) = case t of
      GHC.ITrational _ -> True
      _                -> False

ghcIsOverLit :: PosToken -> Bool
ghcIsOverLit t = ghcIsInteger t || ghcIsRational t


ghcIsComment :: PosToken -> Bool
ghcIsComment ((GHC.L _ (GHC.ITdocCommentNext _)),_s)  = True
ghcIsComment ((GHC.L _ (GHC.ITdocCommentPrev _)),_s)  = True
ghcIsComment ((GHC.L _ (GHC.ITdocCommentNamed _)),_s) = True
ghcIsComment ((GHC.L _ (GHC.ITdocSection _ _)),_s)    = True
ghcIsComment ((GHC.L _ (GHC.ITdocOptions _)),_s)      = True
ghcIsComment ((GHC.L _ (GHC.ITdocOptionsOld _)),_s)   = True
ghcIsComment ((GHC.L _ (GHC.ITlineComment _)),_s)     = True
ghcIsComment ((GHC.L _ (GHC.ITblockComment _)),_s)    = True
ghcIsComment ((GHC.L _ _),_s)                         = False


ghcIsMultiLine :: PosToken -> Bool
ghcIsMultiLine ((GHC.L _ (GHC.ITdocCommentNext _)),_s)  = False
ghcIsMultiLine ((GHC.L _ (GHC.ITdocCommentPrev _)),_s)  = False
ghcIsMultiLine ((GHC.L _ (GHC.ITdocCommentNamed _)),_s) = False
ghcIsMultiLine ((GHC.L _ (GHC.ITdocSection _ _)),_s)    = False
ghcIsMultiLine ((GHC.L _ (GHC.ITdocOptions _)),_s)      = False
ghcIsMultiLine ((GHC.L _ (GHC.ITdocOptionsOld _)),_s)   = False
ghcIsMultiLine ((GHC.L _ (GHC.ITlineComment _)),_s)     = False
ghcIsMultiLine ((GHC.L _ (GHC.ITblockComment _)),_s)    = True
ghcIsMultiLine ((GHC.L _ _),_s)                         = False

ghcIsBlank :: PosToken -> Bool
ghcIsBlank (_,s)  = s == ""

ghcIsBlankOrComment :: PosToken -> Bool
ghcIsBlankOrComment t = ghcIsBlank t || ghcIsComment t

-- ---------------------------------------------------------------------

maybeSrcSpan :: Maybe (GHC.Located a) -> Maybe GHC.SrcSpan
maybeSrcSpan (Just (GHC.L ss _)) = Just ss
maybeSrcSpan _ = Nothing

deltaFromMaybeSrcSpans :: Maybe GHC.SrcSpan -> Maybe GHC.SrcSpan -> Maybe DeltaPos
deltaFromMaybeSrcSpans (Just ss1) (Just ss2) = Just (deltaFromSrcSpans ss1 ss2)
deltaFromMaybeSrcSpans _ _ = Nothing

-- | Create a delta covering the gap between the end of the first
-- @SrcSpan@ and the start of the second.
deltaFromSrcSpans :: GHC.SrcSpan -> GHC.SrcSpan -> DeltaPos
deltaFromSrcSpans ss1 ss2 = ss2delta (ss2posEnd ss1) ss2

ss2delta :: Pos -> GHC.SrcSpan -> DeltaPos
ss2delta ref ss = ss2deltaP ref (ss2pos ss)

-- | Convert the start of the second @Pos@ to be an offset from the
-- first. The assumption is the reference starts before the second @Pos@
ss2deltaP :: Pos -> Pos -> DeltaPos
ss2deltaP (refl,refc) (l,c) = DP (lo,co)
  where
    lo = l - refl
    co = if lo == 0 then c - refc
                    else c

undelta :: Pos -> DeltaPos -> Pos
undelta (l,c) (DP (dl,dc)) = (fl,fc)
  where
    fl = l + dl
    fc = if dl == 0 then c + dc else dc

-- prop_delta :: TODO

ss2pos :: GHC.SrcSpan -> Pos
ss2pos ss = (srcSpanStartLine ss,srcSpanStartColumn ss)

ss2posEnd :: GHC.SrcSpan -> Pos
ss2posEnd ss = (srcSpanEndLine ss,srcSpanEndColumn ss)

ss2span :: GHC.SrcSpan -> Span
ss2span ss = (ss2pos ss,ss2posEnd ss)

srcSpanStart :: GHC.SrcSpan -> Pos
srcSpanStart ss = (srcSpanStartLine ss,srcSpanStartColumn ss)

srcSpanEnd :: GHC.SrcSpan -> Pos
srcSpanEnd ss = (srcSpanEndLine ss,srcSpanEndColumn ss)


srcSpanEndColumn :: GHC.SrcSpan -> Int
srcSpanEndColumn (GHC.RealSrcSpan s) = GHC.srcSpanEndCol s
srcSpanEndColumn _ = 0

srcSpanStartColumn :: GHC.SrcSpan -> Int
srcSpanStartColumn (GHC.RealSrcSpan s) = GHC.srcSpanStartCol s
srcSpanStartColumn _ = 0

srcSpanEndLine :: GHC.SrcSpan -> Int
srcSpanEndLine (GHC.RealSrcSpan s) = GHC.srcSpanEndLine s
srcSpanEndLine _ = 0

srcSpanStartLine :: GHC.SrcSpan -> Int
srcSpanStartLine (GHC.RealSrcSpan s) = GHC.srcSpanStartLine s
srcSpanStartLine _ = 0

nullSpan :: Span
nullSpan = ((0,0),(0,0))

-- ---------------------------------------------------------------------

tokenSpan :: PosToken -> GHC.SrcSpan
tokenSpan ((GHC.L l _),_s) = l

tokenPos :: PosToken -> Pos
tokenPos ((GHC.L l _),_s) = srcSpanStart l

tokenPosEnd :: PosToken -> Pos
tokenPosEnd ((GHC.L l _),_s) = srcSpanEnd l

tokenString :: PosToken -> String
tokenString (_,s) = s

-- ---------------------------------------------------------------------

splitToks:: (GHC.SrcSpan,GHC.SrcSpan) -> [PosToken]->([PosToken],[PosToken],[PosToken])
splitToks (startPos, endPos) toks =
  let (toks1,toks2)   = break (\t -> tokenSpan t >= startPos) toks
      (toks21,toks22) = break (\t -> tokenSpan t >=   endPos) toks2
  in
    (toks1,toks21,toks22)

-- ---------------------------------------------------------------------

splitToksForSpan:: GHC.SrcSpan -> [PosToken] -> ([PosToken],[PosToken],[PosToken])
splitToksForSpan ss toks =
  let (toks1,toks2)   = break (\t -> tokenPos t >= srcSpanStart ss) toks
      (toks21,toks22) = break (\t -> tokenPos t >= srcSpanEnd   ss) toks2
  in
    (toks1,toks21,toks22)

-- ---------------------------------------------------------------------

isSymbolRdrName :: GHC.RdrName -> Bool
isSymbolRdrName n = GHC.isSymOcc $ GHC.rdrNameOcc n

rdrName2String :: GHC.RdrName -> String
rdrName2String r =
  case GHC.isExact_maybe r of
    Just n  -> name2String n
    Nothing ->  GHC.occNameString $ GHC.rdrNameOcc r

name2String :: GHC.Name -> String
name2String name = showGhc name

-- |Show a GHC API structure
showGhc :: (GHC.Outputable a) => a -> String
#if __GLASGOW_HASKELL__ > 706
showGhc x = GHC.showPpr GHC.unsafeGlobalDynFlags x
#else
#if __GLASGOW_HASKELL__ > 704
showGhc x = GHC.showSDoc GHC.tracingDynFlags $ GHC.ppr x
#else
showGhc x = GHC.showSDoc                     $ GHC.ppr x
#endif
#endif

-- ---------------------------------------------------------------------

instance Show (GHC.GenLocated GHC.SrcSpan GHC.Token) where
  show t@(GHC.L l tok) = show ((srcSpanStart l, srcSpanEnd l),tok)

-- ---------------------------------------------------------------------

pp a = GHC.showPpr GHC.unsafeGlobalDynFlags a
