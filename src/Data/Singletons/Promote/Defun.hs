{- Data/Singletons/Promote/Defun.hs

(c) Richard Eisenberg, Jan Stolarek 2014
rae@cs.brynmawr.edu

This file creates defunctionalization symbols for types during promotion.
-}

{-# LANGUAGE TemplateHaskell #-}

module Data.Singletons.Promote.Defun where

import Language.Haskell.TH.Desugar
import Data.Singletons.Promote.Monad
import Data.Singletons.Promote.Type
import Data.Singletons.Names
import Language.Haskell.TH.Syntax
import Data.Singletons.Syntax
import Data.Singletons.Util
import Control.Monad
import Data.Maybe

defunInfo :: DInfo -> PrM [DDec]
defunInfo (DTyConI dec _instances) = buildDefunSyms dec
defunInfo (DPrimTyConI _name _numArgs _unlifted) =
  fail $ "Building defunctionalization symbols of primitive " ++
         "type constructors not supported"
defunInfo (DVarI _name _ty _mdec) =
  fail "Building defunctionalization symbols of values not supported"
defunInfo (DTyVarI _name _ty) =
  fail "Building defunctionalization symbols of type variables not supported"
defunInfo (DPatSynI {}) =
  fail "Building defunctionalization symbols of pattern synonyms not supported"

defunTypeDecls :: [TySynDecl]
               -> [ClosedTypeFamilyDecl]
               -> [OpenTypeFamilyDecl]
               -> PrM ()
defunTypeDecls ty_syns c_tyfams o_tyfams = do
  defun_ty_syns <-
    concatMapM (\(TySynDecl name tvbs) -> buildDefunSymsTySynD name tvbs) ty_syns
  defun_c_tyfams <-
    concatMapM (buildDefunSymsClosedTypeFamilyD . getTypeFamilyDecl) c_tyfams
  defun_o_tyfams <-
    concatMapM (buildDefunSymsOpenTypeFamilyD . getTypeFamilyDecl) o_tyfams
  emitDecs $ defun_ty_syns ++ defun_c_tyfams ++ defun_o_tyfams

buildDefunSyms :: DDec -> PrM [DDec]
buildDefunSyms (DDataD _new_or_data _cxt _tyName _tvbs _k ctors _derivings) =
  buildDefunSymsDataD ctors
buildDefunSyms (DClosedTypeFamilyD tf_head _) =
  buildDefunSymsClosedTypeFamilyD tf_head
buildDefunSyms (DOpenTypeFamilyD tf_head) =
  buildDefunSymsOpenTypeFamilyD tf_head
buildDefunSyms (DTySynD name tvbs _type) =
  buildDefunSymsTySynD name tvbs
buildDefunSyms (DClassD _cxt name tvbs _fundeps _members) = do
  let arg_m_kinds = map extractTvbKind tvbs
  defunReifyFixity name arg_m_kinds (Just (DConT constraintName))
buildDefunSyms _ = fail $ "Defunctionalization symbols can only be built for " ++
                          "type families and data declarations"

buildDefunSymsClosedTypeFamilyD :: DTypeFamilyHead -> PrM [DDec]
buildDefunSymsClosedTypeFamilyD = buildDefunSymsTypeFamilyHead id

buildDefunSymsOpenTypeFamilyD :: DTypeFamilyHead -> PrM [DDec]
buildDefunSymsOpenTypeFamilyD = buildDefunSymsTypeFamilyHead default_to_star
  where
    default_to_star :: Maybe DKind -> Maybe DKind
    default_to_star Nothing  = Just $ DConT typeKindName
    default_to_star (Just k) = Just k

buildDefunSymsTypeFamilyHead
  :: (Maybe DKind -> Maybe DKind) -> DTypeFamilyHead -> PrM [DDec]
buildDefunSymsTypeFamilyHead default_kind (DTypeFamilyHead name tvbs result_sig _) = do
  let arg_kinds = map (default_kind . extractTvbKind) tvbs
      res_kind  = default_kind (resultSigToMaybeKind result_sig)
  defunReifyFixity name arg_kinds res_kind

buildDefunSymsTySynD :: Name -> [DTyVarBndr] -> PrM [DDec]
buildDefunSymsTySynD name tvbs = do
  let arg_m_kinds = map extractTvbKind tvbs
  defunReifyFixity name arg_m_kinds Nothing

buildDefunSymsDataD :: [DCon] -> PrM [DDec]
buildDefunSymsDataD ctors =
  concatMapM promoteCtor ctors
  where
    promoteCtor :: DCon -> PrM [DDec]
    promoteCtor ctor@(DCon _ _ _ _ res_ty) = do
      let (name, arg_tys) = extractNameTypes ctor
      arg_kis <- mapM promoteType arg_tys
      res_ki <- promoteType res_ty
      defunReifyFixity name (map Just arg_kis) (Just res_ki)

-- Generate defunctionalization symbols for a name, using reifyFixityWithLocals
-- to determine what the fixity of each symbol should be.
-- See Note [Fixity declarations for defunctionalization symbols]
defunReifyFixity :: Name -> [Maybe DKind] -> Maybe DKind -> PrM [DDec]
defunReifyFixity name m_arg_kinds m_res_kind = do
  m_fixity <- reifyFixityWithLocals name
  defunctionalize name m_fixity m_arg_kinds m_res_kind

-- Generate data declarations and apply instances
-- required for defunctionalization.
-- For a type family:
--
-- type family Foo (m :: Nat) (n :: Nat) (l :: Nat) :: Nat
--
-- we generate data declarations that allow us to talk about partial
-- application at the type level:
--
-- type FooSym3 a b c = Foo a b c
-- data FooSym2 a b f where
--   FooSym2KindInference :: SameKind (Apply (FooSym2 a b) arg) (FooSym3 a b arg)
--                        => FooSym2 a b f
-- type instance Apply (FooSym2 a b) c = FooSym3 a b c
-- data FooSym1 a f where
--   FooSym1KindInference :: SameKind (Apply (FooSym1 a) arg) (FooSym2 a arg)
--                        => FooSym1 a f
-- type instance Apply (FooSym1 a) b = FooSym2 a b
-- data FooSym0 f where
--  FooSym0KindInference :: SameKind (Apply FooSym0 arg) (FooSym1 arg)
--                       => FooSym0 f
-- type instance Apply FooSym0 a = FooSym1 a
--
-- What's up with all the "KindInference" stuff? In some scenarios, we don't
-- know the kinds that we should be using in these symbols. But, GHC can figure
-- it out using the types of the "KindInference" dummy data constructors. A
-- bit of a hack, but it works quite nicely. The only problem is that GHC will
-- warn about an unused data constructor. So, we use the data constructor in
-- an instance of a dummy class. (See Data.Singletons.SuppressUnusedWarnings
-- for the class, which should never be seen by anyone, ever.)
--
-- The defunctionalize function takes Maybe DKinds so that the caller can
-- indicate which kinds are known and which need to be inferred.
defunctionalize :: Name
                -> Maybe Fixity -- The name's fixity, if one was declared.
                -> [Maybe DKind] -> Maybe DKind -> PrM [DDec]
defunctionalize name m_fixity m_arg_kinds' m_res_kind' = do
  let (m_arg_kinds, m_res_kind) = eta_expand (noExactTyVars m_arg_kinds')
                                             (noExactTyVars m_res_kind')
      num_args = length m_arg_kinds
      sat_name = promoteTySym name num_args
  tvbNames <- replicateM num_args $ qNewName "t"
  let  mk_rhs ns = foldType (DConT name) (map DVarT ns)
       sat_dec   = DTySynD sat_name (zipWith mk_tvb tvbNames m_arg_kinds) (mk_rhs tvbNames)
  other_decs <- go (num_args - 1) (reverse m_arg_kinds) m_res_kind mk_rhs
  return $ sat_dec : other_decs
  where
    mk_tvb :: Name -> Maybe DKind -> DTyVarBndr
    mk_tvb tvb_name Nothing  = DPlainTV tvb_name
    mk_tvb tvb_name (Just k) = DKindedTV tvb_name k

    eta_expand :: [Maybe DKind] -> Maybe DKind -> ([Maybe DKind], Maybe DKind)
    eta_expand m_arg_kinds Nothing = (m_arg_kinds, Nothing)
    eta_expand m_arg_kinds (Just res_kind) =
        let (_, _, argKs, resultK) = unravel res_kind
        in (m_arg_kinds ++ (map Just argKs), Just resultK)

    go :: Int -> [Maybe DKind] -> Maybe DKind
       -> ([Name] -> DType)  -- given the argument names, the RHS of the Apply instance
       -> PrM [DDec]
    go _ [] _ _ = return []
    go n (m_arg : m_args) m_result mk_rhs = do
      fst_name : rest_names <- replicateM (n + 1) (qNewName "l")
      extra_name <- qNewName "arg"
      let data_name   = promoteTySym name n
          next_name   = promoteTySym name (n+1)
          con_name    = prefixName "" ":" $ suffixName "KindInference" "###" data_name
          m_tyfun     = buildTyFun_maybe m_arg m_result
          arg_params  = zipWith mk_tvb rest_names (reverse m_args)
          tyfun_param = mk_tvb fst_name m_tyfun
          arg_names   = map extractTvbName arg_params
          params      = arg_params ++ [tyfun_param]
          con_eq_ct   = DConPr sameKindName `DAppPr` lhs `DAppPr` rhs
            where
              lhs = foldType (DConT data_name) (map DVarT arg_names) `apply` (DVarT extra_name)
              rhs = foldType (DConT next_name) (map DVarT (arg_names ++ [extra_name]))
          con_decl    = DCon (map dropTvbKind params ++ [DPlainTV extra_name])
                             [con_eq_ct]
                             con_name
                             (DNormalC False [])
                             (foldTypeTvbs (DConT data_name) params)
          data_decl   = DDataD Data [] data_name params
                               (Just (DConT typeKindName)) [con_decl] []
          app_eqn     = DTySynEqn [ foldType (DConT data_name)
                                             (map DVarT rest_names)
                                  , DVarT fst_name ]
                                  (mk_rhs (rest_names ++ [fst_name]))
          app_decl    = DTySynInstD applyName app_eqn
          suppress    = DInstanceD Nothing []
                          (DConT suppressClassName `DAppT` DConT data_name)
                          [DLetDec $ DFunD suppressMethodName
                                           [DClause []
                                                    ((DVarE 'snd) `DAppE`
                                                     mkTupleDExp [DConE con_name,
                                                                  mkTupleDExp []])]]

          mk_rhs' ns  = foldType (DConT data_name) (map DVarT ns)

          -- See Note [Fixity declarations for defunctionalization symbols]
          mk_fix_decl f = DLetDec $ DInfixD f data_name
          fixity_decl   = maybeToList $ fmap mk_fix_decl m_fixity

      decls <- go (n - 1) m_args (buildTyFunArrow_maybe m_arg m_result) mk_rhs'
      return $ suppress : data_decl : app_decl : fixity_decl ++ decls

-- This is a small function with large importance. When generating
-- defunctionalization data types, we often need to fill in the blank in the
-- sort of code exemplified below:
--
-- @
-- data FooSym2 a (b :: x) (c :: TyFun y z) where
--   FooSym2KindInference :: _
-- @
--
-- Where the kind of @a@ is not known. It's extremely tempting to just
-- copy-and-paste the type variable binders from the data type itself to the
-- constructor, like so:
--
-- @
-- data FooSym2 a (b :: x) (c :: TyFun y z) where
--   FooSym2KindInference :: forall a (b :: x) (c :: TyFun y z).
--                           SameKind (...) (...).
--                           FooSym2KindInference a b c
-- @
--
-- But this ends up being an untenable approach. Because @a@ lacks a kind
-- signature, @FooSym2@ does not have a complete, user-specified kind signature
-- (or CUSK), so GHC will fail to typecheck @FooSym2KindInference@.
--
-- Thankfully, there's a workaround—just don't give any of the constructor's
-- type variable binders any kinds:
--
-- @
-- data FooSym2 a (b :: x) (c :: TyFun y z) where
--   FooSym2KindInference :: forall a b c
--                           SameKind (...) (...).
--                           FooSym2KindInference a b c
-- @
--
-- GHC may be moody when it comes to CUSKs, but it's at least understanding
-- enough to typecheck this without issue. The 'dropTvbKind' function is
-- what removes the kinds used in the kind inference constructor.
dropTvbKind :: DTyVarBndr -> DTyVarBndr
dropTvbKind tvb@(DPlainTV {}) = tvb
dropTvbKind (DKindedTV n _)   = DPlainTV n

-- Shorthand for building (k1 ~> k2)
buildTyFunArrow :: DKind -> DKind -> DKind
buildTyFunArrow k1 k2 = DConT tyFunArrowName `DAppT` k1 `DAppT` k2

buildTyFunArrow_maybe :: Maybe DKind -> Maybe DKind -> Maybe DKind
buildTyFunArrow_maybe m_k1 m_k2 = do
  k1 <- m_k1
  k2 <- m_k2
  return $ DConT tyFunArrowName `DAppT` k1 `DAppT` k2

-- Shorthand for building (TyFun k1 k2 ~> Type)
--
-- We'd like to replace all uses of this with `buildTyFunArrow`, but we can't
-- do this until https://github.com/goldfirere/th-desugar/issues/68
-- is implemented.
buildTyFun :: DKind -> DKind -> DKind
buildTyFun k1 k2 = DConT tyFunName `DAppT` k1 `DAppT` k2

buildTyFun_maybe :: Maybe DKind -> Maybe DKind -> Maybe DKind
buildTyFun_maybe m_k1 m_k2 = do
  k1 <- m_k1
  k2 <- m_k2
  return $ buildTyFun k1 k2

-- Build (~>) kind from the list of kinds
ravelTyFun :: [DKind] -> DKind
ravelTyFun []    = error "Internal error: TyFun raveling nil"
ravelTyFun [k]   = k
ravelTyFun kinds = go tailK (buildTyFunArrow k2 k1)
    where (k1 : k2 : tailK) = reverse kinds
          go []     acc = acc
          go (k:ks) acc = go ks (buildTyFunArrow k acc)

{-
Note [Fixity declarations for defunctionalization symbols]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Just like we promote fixity declarations, we should also generate fixity
declarations for defunctionaliztion symbols. A primary use case is the
following scenario:

  (.) :: (b -> c) -> (a -> b) -> (a -> c)
  (f . g) x = f (g x)
  infixr 9 .

One often writes (f . g . h) at the value level, but because (.) is promoted
to a type family with three arguments, this doesn't directly translate to the
type level. Instead, one must write this:

  f .@#@$$$ g .@#@$$$ h

But in order to ensure that this associates to the right as expected, one must
generate an `infixr 9 .@#@#$$$` declaration. This is why defunctionalize accepts
a Maybe Fixity argument.
-}
