{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
module MicroHs.TypeCheck(
  typeCheck,
  TModule(..), showTModule,
  impossible
  ) where
import Prelude
import Data.List
import Data.Maybe
import qualified Data.IntMap as IM
import MicroHs.TCMonad as T
import qualified MicroHs.StringMap as M
import MicroHs.Parse
--Ximport Compat
--Ximport GHC.Stack
--import Debug.Trace

data TModule a = TModule IdentModule [TypeExport] [SynDef] [ValueExport] a
  --Xderiving (Show)

data TypeExport = TypeExport Ident Entry [ValueExport]
  --Xderiving (Show)

data ValueExport = ValueExport Ident Entry
  --Xderiving (Show)

data TypeInfo
  = TAbs EKind
  | TConc EKind [(Ident, ETypeScheme)]   -- constructor name, arity, and type
  | TSyn EKind ETypeScheme
  --Xderiving (Show, Eq)

type SynDef = (Ident, ETypeScheme)

data Entry = Entry Expr ETypeScheme
  --Xderiving(Show)

type ValueTable = M.Map [Entry]
type TypeTable  = M.Map [Entry]
type SynTable   = M.Map ETypeScheme

typeCheck :: forall a . [(ImportSpec, TModule a)] -> EModule -> TModule [EDef]
typeCheck imps (EModule mn exps defs) =
--  trace (show amdl) $
  let
    (ts, ss, vs) = mkTables imps
  in case runState (tcDefs defs) (initTC mn ts ss vs) of
       (tds, tcs) ->
         let
           thisMdl = (mn, mkTModule mn tds impossible)
           impMdls = [(fromMaybe m mm, tm) | (ImportSpec _ m mm, tm) <- imps]
           impMap = M.fromList (thisMdl : impMdls)
           (texps, sexps, vexps) =
             unzip3 $ map (getExps impMap (typeTable tcs) (synTable tcs) (valueTable tcs)) exps
         in  TModule mn (concat texps) (concat sexps) (concat vexps) tds

getExps :: forall a . M.Map (TModule a) -> TypeTable -> SynTable -> ValueTable -> ExportSpec ->
           ([TypeExport], [SynDef], [ValueExport])
getExps impMap _ _ _ (ExpModule m) =
  case M.lookup m impMap of
    Just (TModule _ te se ve _) -> (te, se, ve)
    _ -> expErr m
getExps _ tys _ vals (ExpTypeCon i) =
  let
    e = expLookup i tys
    qi = tyQIdent e
  in ([TypeExport i e []], [], constrsOf qi (M.toList vals))
getExps _ tys syns _ (ExpType i) =
  let
    e = expLookup i tys
    qi = tyQIdent e
    se = case M.lookup qi syns of
           Nothing -> []
           Just ts -> [(qi, ts)]
  in ([TypeExport i e []], se, [])
getExps _ _ _ vals (ExpValue i) =
    ([], [], [ValueExport i (expLookup i vals)])

expLookup :: Ident -> M.Map [Entry] -> Entry
expLookup i m =
  case M.lookup i m of
    Just [e] -> e
    Just _ -> error $ "export ambig " ++ i
    Nothing -> expErr i

tyQIdent :: Entry -> Ident
tyQIdent (Entry (EVar qi) _) = qi
tyQIdent _ = undefined

constrsOf :: Ident -> [(Ident, [Entry])] -> [ValueExport]
constrsOf qi ies =
  [ ValueExport i e | (i, es) <- ies, e@(Entry (ECon _) (ETypeScheme _ t)) <- es, eqIdent (retTyCon t) qi ]

retTyCon :: EType -> Ident
retTyCon t =
  case getArrow t of
    Nothing -> getAppCon t
    Just (_, a) -> retTyCon a

getAppCon :: EType -> Ident
getAppCon (EVar i) = i
getAppCon (EApp f _) = getAppCon f
getAppCon _ = undefined

expErr :: forall a . Ident -> a
expErr i = error $ "export: " ++ i

mkTModule :: forall a . IdentModule -> [EDef] -> a -> TModule a
mkTModule mn tds a =
  let
    con ci it vs (ic, ts) =
      let
        e = ECon $ Con ci (qual mn ic)
      in ValueExport ic $ Entry e (ETypeScheme vs (foldr tArrow (tApps (qual mn it) (map tVar vs)) ts))
    cons i vs cs =
      let
        ci = [ (qual mn c, length ts) | (c, ts) <- cs ]
      in map (con ci i vs) cs
    tentry i vs = Entry (EVar (qual mn i)) (ETypeScheme [] $ lhsKind vs)
    ves = [ ValueExport i (Entry (EVar (qual mn i)) ts) | Sign i ts <- tds ]
    tes =
      [ TypeExport i (tentry i vs) (cons i vs cs) | Data (i, vs) cs <- tds ] ++
      [ TypeExport i (tentry i vs) []             | Type (i, vs) _  <- tds ]
    ses = [ (qual mn i, ETypeScheme vs t) | Type (i, vs) t  <- tds ]
  in  TModule mn tes ses ves a

mkTables :: forall a . [(ImportSpec, TModule a)] -> (TypeTable, SynTable, ValueTable)
mkTables mdls =
  let
    qns aisp mn i =
      case aisp of
        ImportSpec q _ mas ->
          let
            m = fromMaybe mn mas
          in  if q then [qual m i] else [i, qual m i]
    --XallValues :: M.Map [Entry]
    allValues =
      let
        syms arg =
          case arg of
            (is, TModule mn tes _ ves _) ->
              [ (v, [e]) | ValueExport i e    <- ves,                        v <- qns is mn i ] ++
              [ (v, [e]) | TypeExport  _ _ cs <- tes, ValueExport i e <- cs, v <- qns is mn i ]
      in  M.fromListWith (unionBy eqEntry) $ concatMap syms mdls
    allSyns =
      let
        syns arg =
          case arg of
            (_, TModule _ _ ses _ _) -> ses
      in  M.fromList (concatMap syns mdls)
    --XallTypes :: TypeTable
    allTypes =
      let
        types arg =
          case arg of
            (is, TModule mn tes _ _ _) -> [ (v, [e]) | TypeExport i e _ <- tes, v <- qns is mn i ]
      in M.fromListWith (unionBy eqEntry) $ concatMap types mdls
  in  (allTypes, allSyns, allValues)

{-
arityOf :: EType -> Int
arityOf at =
  case getArrow at of
    Nothing -> 0
    Just (_, r) -> 1 + arityOf r

constrs :: TypeInfo -> [(Ident, ETypeScheme)]
constrs ti =
  case ti of
    TAbs _ -> []
    TConc _ cs -> cs
    TSyn _ _ -> []

kindOf :: TypeInfo -> ETypeScheme
kindOf ti =
  case ti of
    TAbs k -> ETypeScheme [] k
    TConc k _ -> ETypeScheme [] k
    TSyn k _ -> ETypeScheme [] k
-}

eqEntry :: Entry -> Entry -> Bool
eqEntry x y =
  case x of
    Entry ix _ ->
      case y of
        Entry iy _ -> eqIdent (getIdent ix) (getIdent iy)

getIdent :: Expr -> Ident
getIdent ae =
  case ae of
    EVar i -> i
    ECon c -> conIdent c
    _ -> impossible

--------------------------

type Typed a = (a, EType)

data TCState = TC IdentModule Int TypeTable SynTable ValueTable (IM.IntMap EType)
  --Xderiving (Show)

typeTable :: TCState -> TypeTable
typeTable (TC _ _ tt _ _ _) = tt

valueTable :: TCState -> ValueTable
valueTable (TC _ _ _ _ vt _) = vt

synTable :: TCState -> SynTable
synTable (TC _ _ _ st _ _) = st

uvarSubst :: TCState -> IM.IntMap EType
uvarSubst (TC _ _ _ _ _ sub) = sub

moduleName :: TCState -> IdentModule
moduleName (TC mn _ _ _ _ _) = mn

putValueTable :: ValueTable -> T ()
putValueTable venv = T.do
  TC mn n tenv senv _ m <- get
  put (TC mn n tenv senv venv m)

putTypeTable :: TypeTable -> T ()
putTypeTable tenv = T.do
  TC mn n _ senv venv m <- get
  put (TC mn n tenv senv venv m)

putSynTable :: SynTable -> T ()
putSynTable senv = T.do
  TC mn n tenv _ venv m <- get
  put (TC mn n tenv senv venv m)

-- Use the type table as the value table, and an empty type table
withTypeTable :: forall a . T a -> T a
withTypeTable ta = T.do
  TC mn n tt st vt m <- get
  put (TC mn n M.empty M.empty tt m)
  a <- ta
  TC mnr nr _ _ ttr mr <- get
  put (TC mnr nr ttr st vt mr)
  T.return a

initTC :: IdentModule -> TypeTable -> SynTable -> ValueTable -> TCState
initTC mn ts ss vs =
--  trace ("initTC " ++ show (ts, vs)) $
  let
    xts = foldr (uncurry M.insert) ts primTypes
    xvs = foldr (uncurry M.insert) vs primValues
  in TC mn 1 xts ss xvs IM.empty

-- XXX moduleOf is not correct
moduleOf :: Ident -> IdentModule
moduleOf = reverse . tail . dropWhile (neChar '.') . reverse

primTypes :: [(Ident, [Entry])]
primTypes =
  let
    entry i = Entry (EVar i)
    tuple n =
      let
        i = tupleConstr n
      in  (i, [entry i $ ETypeScheme [] $ foldr kArrow kType (replicate n kType)])
    t = ETypeScheme [] kType
    tt = ETypeScheme [] $ kArrow kType kType
    ttt = ETypeScheme [] $ kArrow kType $ kArrow kType kType
  in  
      [("IO",     [entry "Primitives.IO"       tt]),
       ("->",     [entry "Primitives.->"       ttt]),
       ("Int",    [entry "Primitives.Int"      t]),
       ("Char",   [entry "Primitives.Char"     t]),
       ("Handle", [entry "Primitives.Handle"   t]),
       ("Any",    [entry "Primitives.Any"      t]),
       ("String", [entry "Data.Char.String"    t]),
       ("[]",     [entry "Data.List.[]"        tt]),
       ("()",     [entry "Data.Tuple.()"       t]),
       ("Bool",   [entry "Data.Bool_Type.Bool" t])] ++
      map tuple (enumFromTo 2 10)

primValues :: [(Ident, [Entry])]
primValues =
  let
    tuple n =
      let
        c = tupleConstr n
        vs = ["a" ++ showInt i | i <- enumFromTo 1 n]
        ts = map tVar vs
        r = tApps c ts
      in  (c, [Entry (ECon $ Con [(c, n)] c) $ ETypeScheme vs $ foldr tArrow r ts ])
  in  map tuple (enumFromTo 2 10)

type T a = TC TCState a

tCon :: Ident -> EType
tCon = EVar

tVar :: Ident -> EType
tVar = EVar

tApp :: EType -> EType -> EType
tApp = EApp

tApps :: Ident -> [EType] -> EType
tApps i ts = foldl tApp (tCon i) ts

tArrow :: EType -> EType -> EType
tArrow a r = tApp (tApp (tCon "Primitives.->") a) r

kArrow :: EKind -> EKind -> EKind
kArrow = tArrow

kType :: EKind
kType = EVar "Type"

getArrow :: EType -> Maybe (EType, EType)
getArrow (EApp (EApp (EVar n) a) b) =
  if eqIdent n "->" || eqIdent n "Primitives.->" then Just (a, b) else Nothing
getArrow _ = Nothing

{-
getArrow2 :: EType -> (EType, EType, EType)
getArrow2 abc =
  case getArrow abc of
    Nothing -> error "getArrow2"
    Just (a, bc) ->
      case getArrow bc of
        Nothing -> error "getArrow2"
        Just (b, c) -> (a, b, c)
-}

addUVar :: Int -> EType -> T ()
addUVar i t = T.do
  let
    add = T.do
      TC mn n tenv senv venv sub <- get
      put (TC mn n tenv senv venv (IM.insert i t sub))
  case t of
    EUVar j -> if i == j then T.return () else add
    _ -> add

munify :: --XHasCallStack =>
          Maybe EType -> EType -> T ()
munify Nothing _ = T.return ()
munify (Just a) b = unify a b

expandType :: --XHasCallStack =>
              EType -> T EType
expandType at = T.do
  tt <- derefUVar at
  expandSyn tt

expandSyn :: --XHasCallStack =>
             EType -> T EType
expandSyn at =
  let
    syn ts t =
      case t of
        EApp f a -> T.do
          aa <- expandSyn a
          syn (aa:ts) f
        EVar i -> T.do
          syns <- gets synTable
          case M.lookup i syns of
            Nothing -> T.return $ foldl tApp t ts
            Just (ETypeScheme vs tt) ->
              if length vs /= length ts then error $ "bad syn app: " --X ++ show (i, vs, ts)
              else expandSyn $ subst (zip vs ts) tt
        EUVar _ -> T.return $ foldl tApp t ts
        _ -> impossible
  in syn [] at

derefUVar :: EType -> T EType
derefUVar at =
  case at of
    EApp f a -> T.do
      fx <- derefUVar f
      ax <- derefUVar a
      T.return $ EApp fx ax
    EUVar i -> T.do
      sub <- gets uvarSubst
      case IM.lookup i sub of
        Nothing -> T.return at
        Just t -> derefUVar t
    EVar _ -> T.return at
    _ -> impossible

unify :: --XHasCallStack =>
         EType -> EType -> T ()
unify a b = T.do
--  traceM ("unify1 " ++ showExpr a ++ " = " ++ showExpr b)
  aa <- expandType a
  bb <- expandType b
--  traceM ("unify2 " ++ showExpr aa ++ " = " ++ showExpr bb)
  unifyR aa bb
  
unifyR :: --XHasCallStack =>
          EType -> EType -> T ()
unifyR a b = T.do
--  venv <- gets valueTable
--  tenv <- gets typeTable
--X  senv <- gets synTable
  let
    bad = error $ "Cannot unify " ++ showExpr a ++ " and " ++ showExpr b ++ "\n"
--X                    ++ show a ++ " - " ++ show b ++ "\n"
--                    ++ show tenv ++ "\n"
--X                    ++ show senv
  case a of
    EVar ia ->
      case b of
        EVar ib  -> if eqIdent ia ib then T.return () else bad
        EApp _ _ -> bad
        EUVar i  -> addUVar i a
        _        -> impossible
    EApp fa xa ->
      case b of
        EVar _     -> bad
        EApp fb xb -> T.do { unify fa fb; unify xa xb }
        EUVar i    -> addUVar i a
        _          -> impossible
    EUVar i -> addUVar i b
    _ -> impossible

unMType :: Maybe EType -> T EType
unMType mt =
  case mt of
    Nothing -> newUVar
    Just t -> T.return t

-- Reset type variable and unification map
tcReset :: T ()
tcReset = T.do
  TC mn _ tenv senv venv _ <- get
  put (TC mn 0 tenv senv venv IM.empty)

newUVar :: T EType
newUVar = T.do
  TC mn n tenv senv venv sub <- get
  put (TC mn (n+1) tenv senv venv sub)
  T.return (EUVar n)

tLookupInst :: Ident -> T (Expr, EType)
tLookupInst i = T.do
  (e, s) <- tLookup i
--  traceM ("lookup " ++ show (i, s))
  t <- tInst s
  T.return (e, t)

tLookup :: Ident -> T (Expr, ETypeScheme)
tLookup i = T.do
  env <- gets valueTable
  case M.lookup i env of
    Nothing -> error $ "undefined variable " ++ i -- ++ "\n" ++ show env ;
    Just aes ->
      case aes of
        [] -> impossible
        eee : es ->
          case eee of   -- XXX why parse error if combined with pre
            Entry e s ->
              if null es then
                T.return (e, s)
              else
                error "ambiguous"

tInst :: ETypeScheme -> T EType
tInst as =
  case as of
    ETypeScheme vs t ->
      if null vs then T.return t
      else T.do
        us <- T.mapM (const newUVar) (replicate (length vs) ())
        T.return (subst (zip vs us) t)

extValE :: --XHasCallStack =>
           Ident -> ETypeScheme -> Expr -> T ()
extValE i t e = T.do
  venv <- gets valueTable
  putValueTable (M.insert i [Entry e t] venv)

extQVal :: --XHasCallStack =>
           Ident -> ETypeScheme -> T ()
extQVal i t = T.do
  mn <- gets moduleName
  extValE i t (EVar $ qual mn i)

extVal :: --XHasCallStack =>
          Ident -> ETypeScheme -> T ()
extVal i t = extValE i t $ EVar i

extVals :: --XHasCallStack =>
           [(Ident, ETypeScheme)] -> T ()
extVals = T.mapM_ (uncurry extVal)

extTyp :: Ident -> ETypeScheme -> T ()
extTyp i t = T.do
  tenv <- gets typeTable
  putTypeTable (M.insert i [Entry (EVar i) t] tenv)

extTyps :: [(Ident, ETypeScheme)] -> T ()
extTyps = T.mapM_ (uncurry extTyp)

extSyn :: Ident -> ETypeScheme -> T ()
extSyn i t = T.do
  senv <- gets synTable
  putSynTable (M.insert i t senv)

withExtVal :: forall a . --XHasCallStack =>
              Ident -> ETypeScheme -> T a -> T a
withExtVal i t ta = T.do
  venv <- gets valueTable
  extVal i t
  a <- ta
  putValueTable venv
  T.return a

withExtVals :: forall a . --XHasCallStack =>
               [(Ident, ETypeScheme)] -> T a -> T a
withExtVals env ta = T.do
  venv <- gets valueTable
  extVals env
  a <- ta
  putValueTable venv
  T.return a

withExtTyps :: forall a . [(Ident, ETypeScheme)] -> T a -> T a
withExtTyps env ta = T.do
  venv <- gets typeTable
  extTyps env
  a <- ta
  putTypeTable venv
  T.return a

tcDefs :: [EDef] -> T [EDef]
tcDefs ds = T.do
--  traceM ("tcDefs ds=" ++ show ds)
  dst <- tcDefsType ds
  T.mapM_ addTypeSyn dst
--  traceM ("tcDefs dst=\n" ++ showEDefs dst)
--  tenv <- gets typeTable
--  traceM ("tcDefs tenv=\n" ++ show tenv)
  tcDefsValue dst

tcDefsType :: [EDef] -> T [EDef]
tcDefsType ds = withTypeTable $ T.do
  T.mapM_ addTypeKind ds
  T.mapM (\ d -> T.do {tcReset; tcDefType d}) ds

addTypeKind :: EDef -> T ()
addTypeKind adef =
  case adef of
    Data lhs _ -> addLHSKind lhs
    Type lhs _ -> addLHSKind lhs
    _          -> T.return ()

addLHSKind :: LHS -> T ()
addLHSKind (i, vs) = extQVal i (ETypeScheme [] $ lhsKind vs)

lhsKind :: [Ident] -> EKind
lhsKind vs = foldr (\ _ -> kArrow kType) kType vs

-- Add type synonyms to the value table
addTypeSyn :: EDef -> T ()
addTypeSyn adef =
  case adef of
    Type (i, vs) t -> T.do
      extSyn i (ETypeScheme vs t)
      mn <- gets moduleName
      extSyn (qual mn i) (ETypeScheme vs t)
    _ -> T.return ()

tcDefType :: EDef -> T EDef
tcDefType d =
  case d of
    Data lhs cs -> Data lhs <$> withVars (lhsKinds lhs) (T.mapM tcConstr cs)
    Type lhs t  -> Type lhs <$> withVars (lhsKinds lhs) (fst <$> tcType (Just kType) t)
    Sign i t    -> Sign i   <$> tcTypeScheme (Just kType) t
    _ -> T.return d

tcTypeScheme :: Maybe EKind -> ETypeScheme -> T ETypeScheme
tcTypeScheme mk (ETypeScheme vs t) =
  ETypeScheme vs <$> withVars (lhsKinds (impossible, vs)) (fst <$> tcType mk t)

lhsKinds :: LHS -> [(Ident, ETypeScheme)]
lhsKinds (_, vs) = zip vs (repeat (ETypeScheme [] kType))

withVars :: forall a . [(Ident, ETypeScheme)] -> T a -> T a
withVars aiks ta =
  case aiks of
    [] -> ta
    (i,k) : iks -> withExtVal i k $ withVars iks ta

tcConstr :: Constr -> T Constr
tcConstr (i, ts) = pair i <$> T.mapM (\ t -> fst <$> tcType (Just kType) t) ts

tcDefsValue :: [EDef] -> T [EDef]
tcDefsValue ds = T.do
  T.mapM_ addValueType ds
  T.mapM (\ d -> T.do { tcReset; tcDefValue d}) ds

addValueType :: EDef -> T ()
addValueType adef = T.do
  mn <- gets moduleName
  case adef of
    Sign i t -> T.do
      extQVal i t
      extVal (qual mn i) t
    Data (i, vs) cs -> T.do
      let
        cti = [ (qual mn c, length ts) | (c, ts) <- cs ]
        tret = foldl tApp (tCon (qual mn i)) (map tVar vs)
        addCon con =
          case con of
            (c, ts) -> extValE c (ETypeScheme vs $ foldr tArrow tret ts) (ECon $ Con cti (qual mn c))
      T.mapM_ addCon cs
    _ -> T.return ()

tcDefValue :: --XHasCallStack =>
              EDef -> T EDef
tcDefValue adef =
  case adef of
    Fcn i eqns -> T.do
--      traceM $ "tcDefValue: " ++ showLHS (i, vs) ++ " = " ++ showExpr rhs
      (_, ETypeScheme tvs tfn) <- tLookup i
      let
        vks = zip tvs (repeat (ETypeScheme [] kType))
      mn <- gets moduleName
      teqns <- withExtTyps vks $ tcEqns tfn eqns
               --tcExpr (Just t) $ ELam (map EVar vs) rhs
      T.return $ Fcn (qual mn i) teqns
--      (et, _) <- withExtTyps vks (tcExpr (Just t) (foldr eLam1 rhs vs))
--      T.return (Fcn (qual mn i, vs) (dropLam (length vs) et))
    _ -> T.return adef

tcType :: Maybe EKind -> EType -> T (Typed EType)
tcType mk = tcExpr mk . dsType

tcExpr :: --XHasCallStack =>
          Maybe EType -> Expr -> T (Typed Expr)
tcExpr mt ae = T.do
--  traceM ("tcExpr enter: " ++ showExpr ae ++ " :: " ++ showMaybe showExpr mt)
  r <- tcExprR mt ae
--  t <- expandType (snd r)
--  traceM ("tcExpr exit: " ++ showExpr (fst r) ++ " :: " ++ showExpr t)
  T.return r
tcExprR :: --XHasCallStack =>
           Maybe EType -> Expr -> T (Typed Expr)
tcExprR mt ae =
  case ae of
    EVar i ->
      if isUnderscore i then
        -- this only happens with patterns translated into expressions
        pair ae <$> newUVar
      else T.do
        (e, t) <- tLookupInst i
--        traceM $ "*** " ++ i ++ " :: " ++ showExpr t ++ " = " ++ showMaybe showExpr mt
        munify mt t
        T.return (e, t)
    EApp f a -> T.do
      (ea, ta) <- tcExpr Nothing a
      tr <- unMType mt
      (ef, _) <- tcExpr (Just (tArrow ta tr)) f
      T.return (EApp ef ea, tr)
    ELam is e -> tcExprLam mt is e
    ELit l -> tcLit mt l
    ECase a arms -> T.do
      (ea, ta) <- tcExpr Nothing a
      tt <- unMType mt
      earms <- T.mapM (tcArm tt ta) arms
      T.return (ECase ea earms, tt)
    ELet bs a -> tcBinds bs $ \ ebs -> T.do { (ea, ta) <- tcExpr mt a; T.return (ELet ebs ea, ta) }
    ETuple es -> T.do
      let
        n = length es
      (ees, tes) <- T.fmap unzip (T.mapM (tcExpr Nothing) es)
      let
        ttup = tApps (tupleConstr n) tes
      munify mt ttup
      T.return (ETuple ees, ttup)
    EList es -> T.do
      (ees, ts) <- T.fmap unzip (T.mapM (tcExpr Nothing) es)
      te <- case ts of
              [] -> newUVar
              t : _ -> T.return t
      let
        tlist = tApps "Data.List.[]" [te]
      munify mt tlist
      T.return (EList ees, tlist)
    EDo mmn ass -> T.do
      case ass of
        [] -> impossible
        as : ss ->
          if null ss then
            case as of
              SThen a -> T.do
                (ea, ta) <- tcExpr mt a
                let
                  sbind = maybe ">>=" (\ mn -> qual mn ">>=") mmn
                (EVar qi, _) <- tLookupInst sbind 
                let
                  mn = moduleOf qi
                T.return (EDo (Just mn) [SThen ea], ta)
              _ -> error "bad do"
          else
            case as of
              SBind p a -> T.do
                let
                  sbind = maybe ">>=" (\ mn -> qual mn ">>=") mmn
                (EApp (EApp _ ea) (ELam _ (ECase _ ((ep, [(_, EDo mn ys)]): _)))
                 , tr) <-
                  tcExpr Nothing (EApp (EApp (EVar sbind) a)
                                       (ELam [EVar "$x"] (ECase (EVar "$x") [(p, [([], EDo mmn ss)])])))
                T.return (EDo mn (SBind ep ea : ys), tr)
              SThen a -> T.do
                let
                  sthen = maybe ">>"  (\ mn -> qual mn ">>" ) mmn
                (EApp (EApp _ ea) (EDo mn ys), tr) <-
                  tcExpr Nothing (EApp (EApp (EVar sthen) a) (EDo mmn ss))
                T.return (EDo mn (SThen ea : ys), tr)
                  
              SLet bs -> T.do
                (ELet ebs (EDo mn ys), tr) <-
                  tcExpr Nothing (ELet bs (EDo mmn ss))
                T.return (EDo mn (SLet ebs : ys), tr)

    ESectL e i -> T.do
      (EApp (EVar ii) ee, t) <- tcExpr mt (EApp (EVar i) e)
      T.return (ESectL ee ii, t)
    ESectR i e -> T.do
      (ELam _ (EApp (EApp var _) ee), t) <- tcExpr mt (ELam [EVar "$x"] (EApp (EApp (EVar i) (EVar "$x")) e))
      T.return (ESectR (getIdent var) ee, t)
    EIf e1 e2 e3 -> T.do
      (ee1, _) <- tcExpr (Just tBool) e1
      (ee2, te2) <- tcExpr mt e2
      (ee3, te3) <- tcExpr mt e3
      unify te2 te3
      T.return (EIf ee1 ee2 ee3, te2)
    ECompr eret ass -> T.do
      let
        --XdoStmts :: [EStmt] -> [EStmt] -> T ([EStmt], Typed Expr)
        doStmts rss xs =
          case xs of
            [] -> T.do
              r <- tcExpr Nothing eret
              T.return (reverse rss, r)
            as : ss ->
              case as of
                SBind p a -> T.do
                  v <- newUVar
                  (ea, _) <- tcExpr (Just $ tApp tList v) a
                  tcPat v p $ \ ep ->
                    doStmts (SBind ep ea : rss) ss
                SThen a -> T.do
                  (ea, _) <- tcExpr (Just tBool) a
                  doStmts (SThen ea : rss) ss
                SLet bs ->
                  tcBinds bs $ \ ebs ->
                    doStmts (SLet ebs : rss) ss
      (rss, (ea, ta)) <- doStmts [] ass
      let
        tr = tApp tList ta
      munify mt tr
      T.return (ECompr ea rss, tr)
    EAt i e -> T.do
      (ee, t) <- tcExpr mt e
      (_, ti) <- tLookupInst i
      unify t ti
      T.return (EAt i ee, t)
    -----
    EUVar _ -> impossible -- shouldn't happen
    ECon _ -> impossible

tcLit :: Maybe EType -> Lit -> T (Typed Expr)
tcLit mt l =
  let { lit t = T.do { munify mt t; T.return (ELit l, t) } } in
  case l of
    LInt _ -> lit (tCon "Primitives.Int")
    LChar _ -> lit (tCon "Primitives.Char")
    LStr _ -> lit (tApps "Data.List.[]" [tCon "Primitives.Char"])
    LPrim _ -> T.do
      t <- unMType mt  -- pretend it is anything
      T.return (ELit l, t)

unArrow :: Maybe EType -> T (EType, EType)
unArrow Nothing = T.do { a <- newUVar; r <- newUVar; T.return (a, r) }
unArrow (Just t) =
  case getArrow t of
    Just ar -> T.return ar
    Nothing -> T.do
      a <- newUVar
      r <- newUVar
      unify t (tArrow a r)
      T.return (a, r)

tcPats :: forall a . EType -> [EPat] -> (EType -> [Typed EPat] -> T a) -> T a
tcPats t [] ta = ta t []
tcPats t (p:ps) ta = T.do
  (tp, tr) <- unArrow (Just t)
  tcPat tp p $ \ pp -> tcPats tr ps $ \ tt pps -> ta tt ((pp, tp) : pps)

tcExprLam :: Maybe EType -> [EPat] -> Expr -> T (Typed Expr)
tcExprLam mt aps expr = T.do
  t <- unMType mt
  tcPats t aps $ \ tt pts -> T.do
    (er, tr) <- tcExpr (Just tt) expr
    T.return (ELam (map fst pts) er, foldr tArrow tr (map snd pts))

tcEqns :: EType -> [Eqn] -> T [Eqn]
tcEqns t eqns = T.mapM (tcEqn t) eqns

tcEqn :: EType -> Eqn -> T Eqn
tcEqn t eqn =
  case eqn of
    Eqn ps alts -> tcPats t ps $ \ tt tps -> T.do
      aalts <- T.mapM (tcAlt tt) alts
      T.return (Eqn (map fst tps) aalts)

tcAlt :: EType -> EAlt -> T EAlt
tcAlt t (ss, rhs) = tcGuards ss $ \ sss -> T.do { (rrhs,_) <- tcExpr (Just t) rhs; T.return (sss, rrhs) }

tcGuards :: forall a . [EStmt] -> ([EStmt] -> T a) -> T a
tcGuards [] ta = ta []
tcGuards (s:ss) ta = tcGuard s $ \ rs -> tcGuards ss $ \ rss -> ta (rs:rss)

tcGuard :: forall a . EStmt -> (EStmt -> T a) -> T a
tcGuard (SBind p e) ta = T.do
  (ee, tt) <- tcExpr Nothing e
  tcPat tt p $ \ pp -> ta (SBind pp ee)
tcGuard (SThen e) ta = T.do
  (ee, _) <- tcExpr (Just tBool) e
  ta (SThen ee)
tcGuard (SLet bs) ta = tcBinds bs $ \ bbs -> ta (SLet bbs)

tcArm :: EType -> EType -> ECaseArm -> T ECaseArm
tcArm t tpat arm =
  case arm of
    (p, alts) -> tcPat tpat p $ \ pp -> T.do
      aalts <- T.mapM (tcAlt t) alts
      T.return (pp, aalts)

tcPat ::forall a .  EType -> EPat -> (EPat -> T a) -> T a
tcPat t ap ta = T.do
--  traceM $ "tcPat: " ++ show ap
  env <- T.mapM (\ v -> (pair v . ETypeScheme []) <$> newUVar) $ filter (not . isUnderscore) $ patVars ap
  withExtVals env $ T.do
    (pp, _) <- tcExpr (Just t) ap
    () <- checkArity 0 pp
    ta pp

checkArity :: Int -> EPat -> T ()
checkArity n (EApp f _) = checkArity (n+1) f
checkArity n (ECon c) = if n == conArity c then T.return () else error "con arity"
checkArity _ _ = T.return ()

-- XXX No mutual recursion yet
tcBinds :: forall a . [EBind] -> ([EBind] -> T a) -> T a
tcBinds xbs ta = T.do
  let
    xs = concatMap getBindVars xbs
  xts <- T.mapM (\ x -> T.fmap (pair x . ETypeScheme []) newUVar) xs
  withExtVals xts $ T.do
    nbs <- T.mapM tcBind xbs
    ta nbs

tcBind :: EBind -> T EBind
tcBind abind =
  case abind of
    BFcn i eqns -> T.do
      (_, t) <- tLookupInst i
      --(ELam _avs ea, _) <- tcExpr (Just t) $ ELam (map EVar vs) a
      teqns <- tcEqns t eqns
      T.return $ BFcn i teqns
--      (ea, _) <- tcExpr (Just t) $ foldr eLam1 a vs
--      T.return $ BFcn (i, vs) $ dropLam (length vs) ea
    BPat p a -> T.do
      (ep, tp) <- tcExpr Nothing p
      (ea, _)  <- tcExpr (Just tp) a
      T.return $ BPat ep ea

getBindVars :: EBind -> [Ident]
getBindVars abind =
  case abind of
    BFcn i _ -> [i]
    BPat p _ -> patVars p

-- Desugar [T] and (T,T,...)
dsType :: EType -> EType
dsType at =
  case at of
    EVar _ -> at
    EApp f a -> EApp (dsType f) (dsType a)
    EList ts -> tApps listConstr [dsType (head ts)]  -- XXX should be [t]
    ETuple ts -> tApps (tupleConstr (length ts)) (map dsType ts)
    _ -> impossible

listConstr :: Ident
listConstr = "[]"

tList :: EType
tList = tCon "Data.List.[]"

tBool :: EType
tBool = tCon "Data.Bool_Type.Bool"

impossible :: --XHasCallStack =>
              forall a . a
impossible = error "impossible"

showTModule :: forall a . (a -> String) -> TModule a -> String
showTModule sh amdl =
  case amdl of
    TModule mn _ _ _ a -> "Tmodule " ++ mn ++ "\n" ++ sh a

isUnderscore :: Ident -> Bool
isUnderscore = eqIdent "_"
