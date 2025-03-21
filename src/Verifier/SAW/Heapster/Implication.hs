{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE BangPatterns #-}

module Verifier.SAW.Heapster.Implication where

import Data.Maybe
import Data.List
import Data.Kind as Kind
import Data.Functor.Product
import Data.Functor.Compose
import qualified Data.BitVector.Sized as BV
import Data.BitVector.Sized (BV)
import GHC.TypeLits
import Control.Lens hiding ((:>))
import Control.Monad
import Data.Functor.Identity
import Control.Applicative hiding (empty)
import qualified Control.Applicative as Applicative
import Control.Monad.Trans
import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe

import qualified Data.Type.RList as RL
import Data.Binding.Hobbits.Mb (mbMap2)
import Data.Binding.Hobbits.MonadBind
import Data.Binding.Hobbits.NameMap (NameMap, NameAndElem(..))
import qualified Data.Binding.Hobbits.NameMap as NameMap
import Data.Binding.Hobbits.NameSet (NameSet, SomeName(..))
import qualified Data.Binding.Hobbits.NameSet as NameSet

import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), empty)
import qualified Text.PrettyPrint.ANSI.Leijen as PP

import Data.Parameterized.BoolRepr

import Lang.Crucible.Types
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.CFG.Core
import Lang.Crucible.FunctionHandle
import Verifier.SAW.Term.Functor (Ident)
import Verifier.SAW.OpenTerm

import Data.Binding.Hobbits
import Verifier.SAW.Heapster.CruUtil
import Verifier.SAW.Heapster.Permissions

import Debug.Trace


-- FIXME: move to Hobbits, and use BindState as in the existing instances for
-- the lazy StateT
instance (MonadBind m) => MonadBind (StateT (Closed s) m) where
  mbM mb_m = StateT $ \s ->
    mbM (fmap (\m -> runStateT m s) mb_m) >>= \mb_as ->
    return (fmap fst mb_as, mbLift (fmap snd mb_as))

-- FIXME: move to Hobbits, and use BindState as in the existing instances for
-- the lazy StateT
instance (MonadStrongBind m) => MonadStrongBind (StateT (Closed s) m) where
  strongMbM mb_m = StateT $ \s ->
    strongMbM (fmap (\m -> runStateT m s) mb_m) >>= \mb_as ->
    return (fmap fst mb_as, mbLift (fmap snd mb_as))


----------------------------------------------------------------------
-- * Permission Implications
----------------------------------------------------------------------

-- | A simple implication is an implication that does not introduce any
-- variables or act on the 'varPermMap' part of a permission set. (Compare to
-- the more general 'PermImpl'.) It has the form
--
-- > P1 * ... * Pn -o P1' * ... * Pm'
--
-- where the types of @P1@ through @Pn@ are given by the first type argument
-- @ps_in@ and those of @P1'@ through @Pm'@ are given by the second, @ps_out@.
data SimplImpl ps_in ps_out where
  -- | Drop a permission, i.e., forget about it:
  --
  -- > x:p -o .
  SImpl_Drop :: ExprVar a -> ValuePerm a -> SimplImpl (RNil :> a) RNil

  -- | Copy any copyable permission:
  --
  -- > x:p -o x:p * x:p
  SImpl_Copy :: ExprVar a -> ValuePerm a ->
                SimplImpl (RNil :> a) (RNil :> a :> a)

  -- | Swap the top two permissions on the stack:
  --
  -- > x:p1 * y:p2 -o y:p2 * x:p1
  SImpl_Swap :: ExprVar a -> ValuePerm a -> ExprVar b -> ValuePerm b ->
                SimplImpl (RNil :> a :> b) (RNil :> b :> a)

  -- | Move permission @p@ that is on the stack below two lists @ps1@ and @ps2@
  -- towards the top of the stack by moving it between @ps1@ and @ps2@. That is,
  -- change the stack
  --
  -- > x:p, ps1, ps2 -o ps1, x:p, ps2
  SImpl_MoveUp :: DistPerms ps1 -> ExprVar a -> ValuePerm a -> DistPerms ps2 ->
                  SimplImpl (RNil :> a :++: ps1 :++: ps2) (ps1 :> a :++: ps2)

  -- | @SImpl_IntroOrL x p1 p2@ applies left disjunction introduction:
  --
  -- > x:p1 -o x:(p1 \/ p2)
  SImpl_IntroOrL :: ExprVar a -> ValuePerm a -> ValuePerm a ->
                    SimplImpl (RNil :> a) (RNil :> a)

  -- | @SImpl_IntroOrR x p1 p2 pf@ applies right disjunction introduction:
  --
  -- > x:p2 -o x:(p1 \/ p2)
  SImpl_IntroOrR :: ExprVar a -> ValuePerm a -> ValuePerm a ->
                    SimplImpl (RNil :> a) (RNil :> a)

  -- | @SImpl_IntroExists x e p@ applies existential introduction:
  --
  -- > x:[e/z]p -o x:(exists z.p)
  SImpl_IntroExists :: KnownRepr TypeRepr tp => ExprVar a -> PermExpr tp ->
                       Binding tp (ValuePerm a) ->
                       SimplImpl (RNil :> a) (RNil :> a)

  -- | Cast a proof of @y:p@ to one of @x:p@ using @x:eq(y)@:
  --
  -- > x:eq(y) * y:p -o x:p
  SImpl_Cast :: ExprVar a -> ExprVar a -> ValuePerm a ->
                SimplImpl (RNil :> a :> a) (RNil :> a)

  -- | Introduce a proof that @x:eq(x)@:
  --
  -- > . -o x:eq(x)
  SImpl_IntroEqRefl :: ExprVar a -> SimplImpl RNil (RNil :> a)

  -- | Invert an @x:eq(y)@ permission into a @y:eq(x)@ permission:
  --
  -- > x:eq(y) -o y:eq(x)
  SImpl_InvertEq :: ExprVar a -> ExprVar a -> SimplImpl (RNil :> a) (RNil :> a)

  -- | Prove @x:eq(y)@ by proving equality permissions for both @x@ and @y@ to
  -- the same expression, thereby implementing a form of transitivity of
  -- equality where the second equality is inversted:
  --
  -- > x:eq(e) * y:eq(e) -o x:eq(y)
  SImpl_InvTransEq :: ExprVar a -> ExprVar a -> PermExpr a ->
                      SimplImpl (RNil :> a :> a) (RNil :> a)

  -- FIXME HERE: remove this in favor of SImpl_Copy

  -- | Copy an equality proof on the top of the stack:
  --
  -- > x:eq(e) -o x:eq(e) * x:eq(e)
  SImpl_CopyEq :: ExprVar a -> PermExpr a ->
                  SimplImpl (RNil :> a) (RNil :> a :> a)

  -- | Cast an @eq(llvmword(y))@ proof to an @eq(llvmword(e))@ proof using a
  -- proof of @y:eq(e)@:
  --
  -- > x:eq(llvmword(y)) * y:eq(e) -o x:eq(llvmword(e))
  SImpl_LLVMWordEq :: (1 <= w, KnownNat w) => ExprVar (LLVMPointerType w) ->
                      ExprVar (BVType w) -> PermExpr (BVType w) ->
                      SimplImpl (RNil :> LLVMPointerType w :> BVType w)
                      (RNil :> LLVMPointerType w)

  -- | Introduce an empty conjunction on @x@, i.e.:
  --
  -- > . -o x:true
  SImpl_IntroConj :: ExprVar a -> SimplImpl RNil (RNil :> a)

  -- | Extract the @i@th atomic permission out of a conjunct, putting it below
  -- that conjunct on the stack:
  --
  -- > x:(p0 * ... * p(n-1)) -o x:pi * x:(p0 * ... p(i-1) * p(i+1) ... * p(n-1))
  SImpl_ExtractConj :: ExprVar a -> [AtomicPerm a] -> Int ->
                       SimplImpl (RNil :> a) (RNil :> a :> a)

  -- | Copy the @i@th atomic permission out of a conjunct, assuming it is
  -- copyable, putting it below that conjunct on the stack:
  --
  -- > x:(p0 * ... * p (n-1)) -o x:pi * x:(p0 * ... * p(n-1))
  SImpl_CopyConj :: ExprVar a -> [AtomicPerm a] -> Int ->
                    SimplImpl (RNil :> a) (RNil :> a :> a)

  -- | Insert an atomic permission below the top of the stack at the @i@th
  -- position in the conjunct on the top of the stack, where @i@ must be between
  -- @0@ and @n@ (the number of conjuncts), inclusive:
  --
  -- > x:p * x:(p0 * ... * p(n-1))
  -- >   -o x:(p0 * ... * p(i-1) * p * pi * ... * p(n-1))
  SImpl_InsertConj :: ExprVar a -> AtomicPerm a -> [AtomicPerm a] -> Int ->
                      SimplImpl (RNil :> a :> a) (RNil :> a)

  -- | Combine the top two conjunctive permissions on the stack:
  --
  -- > x:(p1 * ... * pi) * x:(pi+1 * ... * pn) -o x:(p1 * ... * pn)
  SImpl_AppendConjs :: ExprVar a -> [AtomicPerm a] -> [AtomicPerm a] ->
                       SimplImpl (RNil :> a :> a) (RNil :> a)

  -- | Split the conjunctive permissions on the top of the stack in two:
  --
  -- > x:(p1 * ... * pn) -o x:(p1 * ... * pi) * x:(pi+1 * ... * pn)
  SImpl_SplitConjs :: ExprVar a -> [AtomicPerm a] -> Int ->
                      SimplImpl (RNil :> a) (RNil :> a :> a)

  -- | Prove a function permission for a statically-known function (assuming
  -- that the given entry is in the current function environment):
  --
  -- > x:eq(handle) -o x:fun_perm
  SImpl_ConstFunPerm ::
    args ~ CtxToRList cargs =>
    ExprVar (FunctionHandleType cargs ret) ->
    FnHandle cargs ret -> FunPerm ghosts (CtxToRList cargs) ret -> Ident ->
    SimplImpl (RNil :> FunctionHandleType cargs ret)
    (RNil :> FunctionHandleType cargs ret)

  -- | Cast a proof of @x:eq(word(e1))@ to one of @x:eq(word(e2))@ using an
  -- equality permission @e1=e2@ on top of the stack:
  --
  -- > x:eq(word(e1)) * x:prop(e1=e2) -o x:eq(word(e2))
  SImpl_CastLLVMWord ::
    (1 <= w, KnownNat w) => ExprVar (LLVMPointerType w) ->
    PermExpr (BVType w) -> PermExpr (BVType w) ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Invert an @x:eq(y+off)@ proof into a @y:eq(x-off)@ proof:
  --
  -- > x:eq(y+off) -o y:eq(x-off)
  SImpl_InvertLLVMOffsetEq ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> PermExpr (BVType w) ->
    ExprVar (LLVMPointerType w) ->
    SimplImpl (RNil :> LLVMPointerType w) (RNil :> LLVMPointerType w)

  -- | Cast a proof of @y:eq(word(e))@ to one of @x:eq(word(e+off))@ using an
  -- equality permission @x:eq(y+off)@ on top of the stack:
  --
  -- > x:eq(y+off) * y:eq(word(e)) -o x:eq(word(e+off))
  SImpl_OffsetLLVMWord ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> PermExpr (BVType w) ->
    PermExpr (BVType w) -> ExprVar (LLVMPointerType w) ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Cast a permission @y:p@ of LLVM type on the top of the stack to @x:(p -
  -- off)@ using a proof of @x:eq(y+off)@ just below it on the stack:
  --
  -- > x:eq(y+off) * y:p -o x:(p - off)
  --
  -- FIXME: change this to work for arbitrary types with 'offsetPerm'
  SImpl_CastLLVMPtr ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> ValuePerm (LLVMPointerType w) ->
    PermExpr (BVType w) -> ExprVar (LLVMPointerType w) ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Cast a proof of @x:free(e1)@ to one of @x:free(e2)@ using an equality
  -- permission @e1=e2@ on top of the stack:
  --
  -- > x:free(e1) * x:prop(e1=e2) -o x:free(e2)
  SImpl_CastLLVMFree ::
    (1 <= w, KnownNat w) => ExprVar (LLVMPointerType w) ->
    PermExpr (BVType w) -> PermExpr (BVType w) ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Cast the offset of a field permission from @off@ to @off'@ using an
  -- equality permission @off=off'@ on the top of the stack:
  --
  -- > x:ptr((rw,off) |-> p) * x:prop(off=off') -o x:ptr((rw,off') |-> p)
  SImpl_CastLLVMFieldOffset ::
    (1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
    ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz -> PermExpr (BVType w) ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Combine proofs of @x:ptr((rw,off) |-> eq(y))@ and @y:p@ on the top of the
  -- permission stack into a proof of @x:ptr((rw,off) |-> p)@, where the
  -- supplied 'LLVMFieldPerm' gives the required output permission:
  --
  -- > x:ptr((rw,off) |-> eq(y)) * y:p -o x:ptr((rw,off) |-> p)
  SImpl_IntroLLVMFieldContents ::
    (1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
    ExprVar (LLVMPointerType w) -> ExprVar (LLVMPointerType sz) ->
    LLVMFieldPerm w sz ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType sz)
    (RNil :> LLVMPointerType w)

  -- | Change the lifetime of a field permission to one during which the
  -- existing lifetime is current:
  --
  -- > x:[l1]ptr((rw,off) |-> p) * l1:[l2]lcurrent -o [l2]x:ptr((rw,off) |-> p)
  SImpl_LLVMFieldLifetimeCurrent ::
    (1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
    ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz ->
    ExprVar LifetimeType -> PermExpr LifetimeType ->
    SimplImpl (RNil :> LLVMPointerType w :> LifetimeType)
    (RNil :> LLVMPointerType w)

  -- | Change the lifetime of a field permission whose existing lifetime is
  -- always:
  --
  -- > x:[always]ptr((rw,off) |-> p) -o [l]x:ptr((rw,off) |-> p)
  SImpl_LLVMFieldLifetimeAlways ::
    (1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
    ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz ->
    PermExpr LifetimeType ->
    SimplImpl (RNil :> LLVMPointerType w) (RNil :> LLVMPointerType w)

  -- | Demote an LLVM field permission from write to read:
  --
  -- > x:[ls]ptr((W,off) |-> p) -o [ls]x:ptr((R,off) |-> p)
  SImpl_DemoteLLVMFieldWrite ::
    (1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
    ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz ->
    SimplImpl (RNil :> LLVMPointerType w) (RNil :> LLVMPointerType w)

  -- | Copy an array permission out of a larger array permission, assuming that
  -- all fields of the array are copyable, using a proof that the copied array
  -- permission is contained in the larger one as per 'llvmArrayContainsArray',
  -- i.e., that the range of the smaller array is contained in the larger one
  -- and that all borrows in the larger one are either preserved in the smaller
  -- or are disjoint from it:
  --
  -- > x:ar1=array(off1,<len1,*stride,fps,bs1)
  -- > * x:prop('llvmArrayContainsArray' ar1 ar2)
  -- >   -o x:ar2=array(off2,<len2,*stride,fps,bs2)
  -- >      * x:ar1=array(off1,<len1,*stride,fps,bs1)
  SImpl_LLVMArrayCopy ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w :> LLVMPointerType w)

  -- | Borrow an array permission from a larger array permission, using a proof
  -- that the borrowed array permission is contained in the larger one as per
  -- 'llvmArrayContainsArray', i.e., that the range of the smaller array is
  -- contained in the larger one and that all borrows in the larger one are
  -- either preserved in the smaller or are disjoint from it:
  --
  -- > x:ar1=array(off1,<len1,*stride,fps,bs1++bs2)
  -- > * x:prop('llvmArrayContainsArray' ar1 ar2)
  -- >   -o x:ar2=array(off2,<len2,*stride,fps, bs2+(off1-off2))
  -- >      * x:array(off1,<len1,*stride,fps,[off2,len2):bs1)
  SImpl_LLVMArrayBorrow ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w :> LLVMPointerType w)

  -- | Return a borrowed range of an array permission, undoing a borrow:
  --
  -- > x:array(off2,<len2,*stride,fps,bs2)
  -- > * x:array(off1,<len1,*stride,fps,[off2,len2):bs1)
  -- >   -o x:array(off,<len,*stride,fps,bs1++(bs2+(off2-off1)))
  SImpl_LLVMArrayReturn ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Append two array permissions, assuming one ends where the other begins
  -- and that they have the same stride and fields:
  --
  -- > x:array(off1, <len1, *stride, fps, bs1)
  -- > * x:array(off2=off1+len*stride*word_size, <len2, *stride, fps, bs2)
  -- >   -o x:array(off1,<len1+len2,*stride,fps,bs1++bs2)
  SImpl_LLVMArrayAppend ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Rearrange the order of the borrows in an array permission:
  --
  -- > x:array(off,<len,*stride,fps,bs)
  -- > -o x:array(off,<len,*stride,fps,permute(bs))
  SImpl_LLVMArrayRearrange ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
    SimplImpl (RNil :> LLVMPointerType w) (RNil :> LLVMPointerType w)

  -- | Prove an empty array with length 0:
  --
  -- > -o x:array(off,<0,*stride,fps,[])
  SImpl_LLVMArrayEmpty ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w ->
    SimplImpl RNil (RNil :> LLVMPointerType w)

  -- | Prove an array of static length from from field permissions for a single
  -- cell, leaving borrows for all the other cells:
  --
  -- > x:fps+(cell*w*stride)
  -- > -o x:array(off,<N,*stride,fps, all field borrows other than for cell)
  SImpl_LLVMArrayOneCell ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w ->
    SimplImpl (RNil :> LLVMPointerType w) (RNil :> LLVMPointerType w)

  -- | Copy out the @j@th field permission of the @i@th element of an array
  -- permission, assuming that the @j@th field permission is copyable, where @j@
  -- is a static 'Int' and @i@ is an expression. Requires a proposition
  -- permission on the top of the stack stating that @i@ is in the range of the
  -- array and that the specified field permission does not overlap with any of
  -- the existing borrows:
  --
  -- > x:array(off,<len,*stride,fps,bs)
  -- > * x:(prop(i \in [off,len)) * disjoint(bs,i*stride+offset(fp_j)))
  -- >   -o x:(fp_j + off + i*stride) * x:array(off,<len,*stride,fps,bs)
  SImpl_LLVMArrayIndexCopy ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayIndex w ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w :> LLVMPointerType w)

  -- | Borrow the @j@th field permission of the @i@th element of an array
  -- permission, where @j@ is a static 'Int' and @i@ is an expression. Requires
  -- a proposition permission on the top of the stack stating that @i@ is in the
  -- range of the array and that the specified field permission does not overlap
  -- with any of the existing borrows, and adds a borrow of the given field:
  --
  -- > x:array(off,<len,*stride,fps,bs)
  -- > * x:(prop(i \in [off,len)) * disjoint(bs,i*stride+offset(fp_j)))
  -- >   -o x:(fp_j + off + i*stride)
  -- >      * x:array(off,<len,*stride,fps,(i*stride+offset(fp_j)):bs)
  SImpl_LLVMArrayIndexBorrow ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayIndex w ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w :> LLVMPointerType w)

  -- | Return the @j@th field permission of the @i@th element of an array
  -- permission, where @j@ is a static 'Int' and @i@ is an expression, undoing a
  -- borrow:
  --
  -- > x:(fp_j + offset + i*stride)
  -- > * x:array(off,<len,*stride,fps,(i*stride+offset(fp_j)):bs)
  -- >   -o x:array(off,<len,*stride,fps,bs)
  SImpl_LLVMArrayIndexReturn ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayIndex w ->
    SimplImpl (RNil :> LLVMPointerType w :> LLVMPointerType w)
    (RNil :> LLVMPointerType w)

  -- | Apply an implication to the @i@th field of an array permission:
  --
  -- > y:fpi -o y:fpi'
  -- > ------------------------------------------------
  -- > x:array(off,<len,*stride,(fp1, ..., fpn),bs) -o
  -- >   x:array(off,<len,*stride,
  -- >           (fp1, ..., fp(i-1), fpi', fp(i+1), ..., fpn),bs)
  SImpl_LLVMArrayContents ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> Int -> LLVMArrayField w ->
    PermImpl ((:~:) (RNil :> LLVMPointerType w)) (RNil :> LLVMPointerType w) ->
    SimplImpl (RNil :> LLVMPointerType w) (RNil :> LLVMPointerType w)

  -- | Prove that @x@ is a pointer from a field permission:
  --
  -- > x:ptr((rw,off) |-> p) -o x:is_llvmptr * x:ptr((rw,off) |-> p)
  SImpl_LLVMFieldIsPtr ::
    (1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
    ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz ->
    SimplImpl (RNil :> LLVMPointerType w)
    (RNil :> LLVMPointerType w :> LLVMPointerType w)

  -- | Prove that @x@ is a pointer from a field permission:
  --
  -- > x:array(...) -o x:is_llvmptr * x:array(...)
  SImpl_LLVMArrayIsPtr ::
    (1 <= w, KnownNat w) =>
    ExprVar (LLVMPointerType w) -> LLVMArrayPerm w ->
    SimplImpl (RNil :> LLVMPointerType w)
    (RNil :> LLVMPointerType w :> LLVMPointerType w)

  -- | Save a permission for later by splitting it into part that is in the
  -- current lifetime and part that is saved in the lifetime for later:
  --
  -- > x:p * l:lowned(ps) -o x:(inLifetime l p) * l:lowned(x:p,ps)
  SImpl_SplitLifetime ::
    KnownRepr TypeRepr a => ExprVar a -> ValuePerm a ->
    ExprVar LifetimeType -> PermExpr PermListType ->
    SimplImpl (RNil :> a :> LifetimeType)
    (RNil :> a :> LifetimeType)

  -- | Reflexivity for @lcurrent@ proofs:
  --
  -- > . -o l:lcurrent(l)
  SImpl_LCurrentRefl :: ExprVar LifetimeType ->
                        SimplImpl RNil (RNil :> LifetimeType)

  -- | Transitively combine @lcurrent@ proofs:
  --
  -- > l1:lcurrent(l2) * l2:lcurrent(l3) -o l1:lcurrent(l3)
  SImpl_LCurrentTrans :: ExprVar LifetimeType -> ExprVar LifetimeType ->
                         PermExpr LifetimeType ->
                         SimplImpl (RNil :> LifetimeType :> LifetimeType)
                         (RNil :> LifetimeType)

  -- | Fold a named permission (other than an opaque permission):
  --
  -- > x:(unfold P args) -o x:P<args>
  SImpl_FoldNamed :: NameSortCanFold ns ~ 'True =>
                     ExprVar a -> NamedPerm ns args a -> PermExprs args ->
                     PermOffset a -> SimplImpl (RNil :> a) (RNil :> a)

  -- | Unfold a named permission (other than an opaque permission):
  --
  -- > x:P<args> -o x:(unfold P args)
  SImpl_UnfoldNamed :: NameSortCanFold ns ~ 'True =>
                       ExprVar a -> NamedPerm ns args a -> PermExprs args ->
                       PermOffset a -> SimplImpl (RNil :> a) (RNil :> a)

  -- | Map a named permission that is conjoinable to a conjunction:
  --
  -- > x:P<args> -o x:ValPerm_Conj [P<args>]
  SImpl_NamedToConj :: NameSortIsConj ns ~ 'True => ExprVar a ->
                       NamedPermName ns args a -> PermExprs args ->
                       PermOffset a ->
                       SimplImpl (RNil :> a) (RNil :> a)

  -- | Map a conjuctive named permission to a named permission:
  --
  -- > x:ValPerm_Conj [P<args>] -o x:P<args>
  SImpl_NamedFromConj :: NameSortIsConj ns ~ 'True => ExprVar a ->
                         NamedPermName ns args a -> PermExprs args ->
                         PermOffset a -> SimplImpl (RNil :> a) (RNil :> a)


{- FIXME HERE: Write the rule for proving one recursive perm implies another

  -- | Apply an implication to the body of a least fixed-point permission:
  --
  -- > y:p1 -o y:p2
  -- > ----------------------
  -- > x:mu X.p1 -o x:mu X.p2
  SImpl_Mu ::
    ExprVar a -> Binding (ValuePerm a) (ValuePerm a) ->
    Binding (ValuePerm a) (ValuePerm a) ->
    Binding (ValuePerm a) (PermImpl ((:~:) (RNil :> a)) (RNil :> a)) ->
    SimplImpl (RNil :> a) (RNil :> a)
-}

  -- | Weaken an @always@ lifetime argument of a named permission:
  --
  -- > x:P<args1,always,args2> -o x:P<args1,l,args2>
  SImpl_NamedArgAlways :: ExprVar a -> NamedPermName ns args a ->
                          PermExprs args -> PermOffset a ->
                          Member args LifetimeType -> PermExpr LifetimeType ->
                          SimplImpl (RNil :> a) (RNil :> a)

  -- | Weaken a lifetime argument @l1@ of a named permission:
  --
  -- > x:P<args1,l1,args2> * l1:[l2]lcurrent -o x:P<args1,l2,args2>
  SImpl_NamedArgCurrent :: ExprVar a -> NamedPermName ns args a ->
                           PermExprs args -> PermOffset a ->
                           Member args LifetimeType -> PermExpr LifetimeType ->
                           SimplImpl (RNil :> a :> LifetimeType) (RNil :> a)

  -- | Weaken a 'Write' modality argument to any other modality:
  --
  -- > x:P<args1,W,args2> -o x:P<args1,rw,args2>
  SImpl_NamedArgWrite :: ExprVar a -> NamedPermName ns args a ->
                         PermExprs args -> PermOffset a ->
                         Member args RWModalityType ->
                         PermExpr RWModalityType ->
                         SimplImpl (RNil :> a) (RNil :> a)

  -- | Weaken any modality argument to a 'Read' modality:
  --
  -- > x:P<args1,rw,args2> -o x:P<args1,R,args2>
  SImpl_NamedArgRead :: ExprVar a -> NamedPermName ns args a ->
                        PermExprs args -> PermOffset a ->
                        Member args RWModalityType ->
                        SimplImpl (RNil :> a) (RNil :> a)



-- | A single step of permission implication. These can have multiple,
-- disjunctive conclusions, each of which can bind some number of variables, and
-- can also move permissions between the primary permissions for each variable
-- and the permission stack. The general form is:
--
-- > x1::Px1 * ... * xl::Pl * P1 * ... * Pn
-- >   -o (zs1 . x1::Px1_1 * ... * xl::Pxl_1 * P1_1 * ... * P1_k1) \/
-- >      ... \/ (zsm . x1::Px1_m * ... * xl::Pxl_m * Pm_1 * ... * Pm_km)
--
-- where @zsi@ is a list of permission variables bound in the permissions @Pi_j@
-- and @xi::Pxi@ denotes the primary permission for variable @xi@. In the
-- comments below, we often omit the primary variable permissions when they do
-- not change. The types of @P1@ through @Pn@ are given by the first type
-- argument @ps_in@ of this type, while those of the @zsi@ and the @Pi_j@
-- permissions are given by the @ps_outs@ argument. The latter is an 'RList' of
-- the form
--
-- > RNil :> (bs1, ps1) :> ... :> (bsm, psm)
--
-- where each @bsi@ is itself an 'RList' of the types of the bound variables in
-- @zsi@ and @psi@ is an 'RList' of the types of @Pi_1@ through @Pi_km@.
data PermImpl1 ps_in ps_outs where
  -- | Failure of a permission implication, along with a string explanation of
  -- the failure, which is a proof of 0 disjuncts:
  --
  -- > ps -o .
  Impl1_Fail :: String -> PermImpl1 ps RNil

  -- | Catch any failure in the first branch by calling the second, passing the
  -- same input permissions to both branches:
  --
  -- > ps -o ps \/ ps
  Impl1_Catch :: PermImpl1 ps (RNil :> '(RNil, ps) :> '(RNil, ps))

  -- | Push the primary permission for variable @x@ onto the stack:
  --
  -- > x::P * ps -o x::true * ps * x:P
  Impl1_Push :: ExprVar a -> ValuePerm a ->
                PermImpl1 ps (RNil :> '(RNil, ps :> a))

  -- | Pop the a permission for variable @x@ back to the primary permission for
  -- @x@, assuming the latter is the trivial permission @true@:
  --
  -- > x::true * ps * x:P -o x::P * ps
  Impl1_Pop :: ExprVar a -> ValuePerm a ->
               PermImpl1 (ps :> a) (RNil :> '(RNil, ps))

  -- | Eliminate a disjunction on the top of the stack:
  --
  -- > ps * x:(p1 \/ p2) -o (ps * x:p1) \/ (ps * x:p2)
  Impl1_ElimOr :: ExprVar a -> ValuePerm a -> ValuePerm a ->
                  PermImpl1 (ps :> a)
                  (RNil :> '(RNil, ps :> a) :> '(RNil, ps :> a))

  -- | Eliminate an existential on the top of the stack:
  --
  -- > ps * x:(exists z.p) -o z. ps * x:p
  Impl1_ElimExists :: KnownRepr TypeRepr tp => ExprVar a ->
                      Binding tp (ValuePerm a) ->
                      PermImpl1 (ps :> a) (RNil :> '(RNil :> tp, ps :> a))

  -- | Apply a 'SimplImpl'
  Impl1_Simpl :: SimplImpl ps_in ps_out -> Proxy ps ->
                 PermImpl1 (ps :++: ps_in) (RNil :> '(RNil, ps :++: ps_out))

  -- | Let-bind a fresh variable @x@ to expression @e@, leaving an equality
  -- permission on top of the stack:
  --
  -- > ps -o x. ps * x:eq(e)
  Impl1_LetBind :: TypeRepr tp -> PermExpr tp ->
                   PermImpl1 ps (RNil :> '(RNil :> tp, ps :> tp))

  -- | Eliminate the contents of an LLVM field permission, binding a new
  -- variable to hold those permissions and changing the contents of the field
  -- permission to an equals permision for that variable:
  --
  -- > x:ptr((rw,off) -> p) -o y. x:ptr((rw,off) -> eq(y)) * y:p
  Impl1_ElimLLVMFieldContents ::
    (1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
    ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz ->
    PermImpl1 (ps :> LLVMPointerType w)
    (RNil :> '(RNil :> LLVMPointerType sz,
               ps :> LLVMPointerType w :> LLVMPointerType sz))

  -- | Try to prove a bitvector proposition, or fail (as in the 'Impl1_Fail'
  -- rule) if this is not possible, where the 'String' is a pretty-printing of
  -- the proposition (for ease of translation):
  --
  -- > . -o prop(p)
  Impl1_TryProveBVProp ::
    (1 <= w, KnownNat w) => ExprVar (LLVMPointerType w) -> BVProp w ->
    String -> PermImpl1 ps (RNil :> '(RNil, ps :> LLVMPointerType w))


-- | A @'PermImpl' r ps@ is a proof tree of the judgment
--
-- > Gamma | Pl * P |- (Gamma1 | Pl1 * P1) \/ ... \/ (Gamman | Pln * Pn)
--
-- that contains an element of type @r@ at each leaf of the proof tree. Each
-- disjunct on the right of the judgment corresponds to a different leaf in the
-- tree, while each @Gammai@ denotes the variables that are bound on the path
-- from the root to that leaf. The @ps@ argument captures the form of the
-- "distinguished" left-hand side permissions @Pl@.
--
-- FIXME: explain that @Pl@ is like a stack, and that intro rules apply to the
-- top of the stack
--
-- FIXME: it would be nice to have PermImpl r ps_out ps_in, where ps_out is
-- guaranteed to be the stack shape at any Impl_Done, but this would make our
-- generalized monad below more complicated...
data PermImpl r ps where
  PermImpl_Done :: !(r ps) -> PermImpl r ps
  PermImpl_Step :: !(PermImpl1 ps_in ps_outs) ->
                   !(MbPermImpls r ps_outs) ->
                   PermImpl r ps_in

-- | Helper type for 'PermImpl', that defines a collection of permission
-- implications, one for each element of the @bs_pss@ type argument. Each of
-- these elements are of the form @(bs,ps)@, where @ps@ determines the input
-- permissions for that implication tree and @bs@ specifies an existential
-- contexts of bound variables for that implication tree.
data MbPermImpls r bs_pss where
  MbPermImpls_Nil :: MbPermImpls r RNil
  MbPermImpls_Cons :: !(MbPermImpls r bs_pss) -> !(Mb bs (PermImpl r ps)) ->
                      MbPermImpls r (bs_pss :> '(bs,ps))

-- type IsLLVMPointerTypeList w ps = RAssign ((:~:) (LLVMPointerType w)) ps

$(mkNuMatching [t| forall ps_in ps_out. SimplImpl ps_in ps_out |])
$(mkNuMatching [t| forall ps_in ps_outs. PermImpl1 ps_in ps_outs |])
$(mkNuMatching [t| forall r bs_pss. NuMatchingAny1 r => MbPermImpls r bs_pss |])
$(mkNuMatching [t| forall r ps. NuMatchingAny1 r => PermImpl r ps |])


-- | Compile-time flag for whether to prune failure branches in 'implCatchM'
pruneFailingBranches :: Bool
pruneFailingBranches = False


-- | Apply the 'PermImpl_Step' constructor to a 'PermImpl1' rule and its
-- sub-proofs, performing the following simplifications (some of which are
-- performed by the helper function 'permImplCatch'), where @unary impl@
-- represents any unary rule applied to the implication @impl@:
--
-- > unary (fail msg) --> fail msg
-- > unary (catch impl (fail msg)) --> catch (unary impl) (fail msg)
-- > catch (fail msg1) (fail msg2) --> fail (msg1 ++ msg2)
-- > catch (catch impl1 impl2) impl3 --> catch impl1 (catch impl2 impl3)
-- > elim_or (fail msg1) (fail msg2) --> fail (msg1 ++ msg2)
permImplStep :: NuMatchingAny1 r => PermImpl1 ps_in ps_outs ->
                MbPermImpls r ps_outs -> PermImpl r ps_in

-- No need to simplify a fail
permImplStep impl1@(Impl1_Fail msg) mb_impls = PermImpl_Step impl1 mb_impls

-- Catch --> call the permImplCatch function
permImplStep Impl1_Catch ((MbPermImpls_Cons
                           (MbPermImpls_Cons _ mb_pimpl1) mb_pimpl2)) =
  permImplCatch (elimEmptyMb mb_pimpl1) (elimEmptyMb mb_pimpl2)

-- Unary rules applied to failure --> failures
--
-- NOTE: we write the cases all out explicitly in case we add a new Impl1 rule
-- that does not work this way, since not simplifying is better than
-- oversimplifying
permImplStep impl1@(Impl1_Push _ _) mb_impls =
  permImplStepUnary impl1 mb_impls
permImplStep impl1@(Impl1_Pop _ _) mb_impls =
  permImplStepUnary impl1 mb_impls
permImplStep impl1@(Impl1_ElimExists _ _) mb_impls =
  permImplStepUnary impl1 mb_impls
permImplStep impl1@(Impl1_Simpl _ _) mb_impls =
  permImplStepUnary impl1 mb_impls
permImplStep impl1@(Impl1_LetBind _ _) mb_impls =
  permImplStepUnary impl1 mb_impls
permImplStep impl1@(Impl1_ElimLLVMFieldContents _ _) mb_impls =
  permImplStepUnary impl1 mb_impls
permImplStep impl1@(Impl1_TryProveBVProp _ _ _) mb_impls =
  permImplStepUnary impl1 mb_impls

-- An or elimination fails if both branches fail
permImplStep (Impl1_ElimOr _ _ _) (MbPermImpls_Cons
                                   (MbPermImpls_Cons MbPermImpls_Nil
                                    (matchMbImplFail -> Just msg1))
                                   (matchMbImplFail -> Just msg2)) =
  PermImpl_Step (Impl1_Fail
                 (msg1 ++ "\n\n--------------------\n\n" ++ msg2))
  MbPermImpls_Nil

-- Default case: just apply PermImpl_Step
permImplStep impl1 mb_impls = PermImpl_Step impl1 mb_impls


-- | Helper for 'permImplStep': apply the 'PermImpl_Step' constructor to a unary
-- 'PermImpl1' rule and an implication that follows it, performing the necessary
-- simplifications
permImplStepUnary :: NuMatchingAny1 r =>
                     PermImpl1 ps_in (RNil :> '(bs, ps_out)) ->
                     MbPermImpls r (RNil :> '(bs, ps_out)) -> PermImpl r ps_in

-- If the continuation implication is a failure, percolate it up
permImplStepUnary _ (MbPermImpls_Cons _ (matchMbImplFail -> Just msg)) =
  PermImpl_Step (Impl1_Fail msg) MbPermImpls_Nil

-- If the continuation implication is a catch with a failure on the right-hand
-- side, percolate up the catch
{- FIXME: this exposes some weird performance bug!
permImplStepUnary impl1 (MbPermImpls_Cons MbPermImpls_Nil
                         (matchMbImplCatchFail -> Just (mb_impl, msg))) =
    PermImpl_Step Impl1_Catch
    (MbPermImpls_Cons
     (MbPermImpls_Cons MbPermImpls_Nil $
      emptyMb $ PermImpl_Step impl1 $
      MbPermImpls_Cons MbPermImpls_Nil mb_impl)
     (emptyMb $ PermImpl_Step (Impl1_Fail msg) MbPermImpls_Nil))
-}

-- Default case: just apply PermImpl_Step
permImplStepUnary impl1 mb_impls = PermImpl_Step impl1 mb_impls


-- | Pattern-match an implication inside a binding to see if it is just a
-- failure, and if so, return the failure message, all without requiring a
-- 'NuMatchingAny1' constraint on the @r@ variable
matchMbImplFail :: NuMatchingAny1 r => Mb ctx (PermImpl r ps) -> Maybe String
matchMbImplFail [nuP| PermImpl_Step (Impl1_Fail msg) _ |] = Just $ mbLift msg
matchMbImplFail _ = Nothing

-- | Pattern-matchin an implication inside a binding to see if it is a catch
-- whose right-hand side is just a failure, all without requiring a
-- 'NuMatchingAny1' constraint on the @r@ variable
matchMbImplCatchFail :: NuMatchingAny1 r =>
                        Mb (ctx :: RList CrucibleType) (PermImpl r ps) ->
                        Maybe (Mb ctx (PermImpl r ps), String)
matchMbImplCatchFail [nuP| PermImpl_Step Impl1_Catch
                         (MbPermImpls_Cons (MbPermImpls_Cons _ mb_impl1)
                         mb_impl2) |]
  | Just msg <- matchMbImplFail (mbCombine mb_impl2) =
    Just (mbCombine mb_impl1, msg)
matchMbImplCatchFail _ = Nothing

-- | Produce a branching proof tree that performs the first implication and, if
-- that one fails, falls back on the second. If 'pruneFailingBranches' is set,
-- failing branches are pruned; otherwise, catches are reorganized so that they
-- are right-nested, and any failures are combined.
permImplCatch :: PermImpl r ps -> PermImpl r ps -> PermImpl r ps
permImplCatch (PermImpl_Step (Impl1_Fail _) _) pimpl
  | pruneFailingBranches = pimpl
permImplCatch pimpl (PermImpl_Step (Impl1_Fail _) _)
  | pruneFailingBranches = pimpl
permImplCatch (PermImpl_Step (Impl1_Fail str1) _) (PermImpl_Step
                                                   (Impl1_Fail str2) mb_impls) =
  PermImpl_Step (Impl1_Fail (str1 ++ "\n\n--------------------\n\n" ++ str2)) mb_impls
permImplCatch pimpl1@(PermImpl_Step (Impl1_Fail _) _) pimpl2 =
  permImplCatch pimpl2 pimpl1
permImplCatch (PermImpl_Step Impl1_Catch
               (MbPermImpls_Cons
                (MbPermImpls_Cons _ mb_pimpl_1a) mb_pimpl_1b)) pimpl2 =
  permImplCatch (elimEmptyMb mb_pimpl_1a) $
  permImplCatch (elimEmptyMb mb_pimpl_1b) pimpl2
permImplCatch pimpl1 pimpl2 =
  PermImpl_Step Impl1_Catch $
  MbPermImpls_Cons (MbPermImpls_Cons MbPermImpls_Nil $ emptyMb pimpl1) $
  emptyMb pimpl2


-- | Test if a 'PermImpl' "succeeds", meaning there is at least one non-failing
-- branch. If it does succeed, return a heuristic number for how "well" it
-- succeeds; e.g., rate a 'PermImpl' higher if all disjunctive branches succeed,
-- that is, if both children of every 'Impl1_ElimOr' succeed. Return 0 if the
-- 'PermImpl' does not succeed at all.
permImplSucceeds :: PermImpl r ps -> Int
permImplSucceeds (PermImpl_Done _) = 2
permImplSucceeds (PermImpl_Step (Impl1_Fail _) _) = 0
permImplSucceeds (PermImpl_Step Impl1_Catch
                  (MbPermImpls_Cons (MbPermImpls_Cons _ mb_impl1) mb_impl2)) =
  max (mbLift $ fmap permImplSucceeds mb_impl1)
  (mbLift $ fmap permImplSucceeds mb_impl2)
permImplSucceeds (PermImpl_Step (Impl1_Push _ _) (MbPermImpls_Cons _ mb_impl)) =
  mbLift $ fmap permImplSucceeds mb_impl
permImplSucceeds (PermImpl_Step (Impl1_Pop _ _) (MbPermImpls_Cons _ mb_impl)) =
  mbLift $ fmap permImplSucceeds mb_impl
permImplSucceeds (PermImpl_Step (Impl1_ElimOr _ _ _)
                  (MbPermImpls_Cons (MbPermImpls_Cons _ mb_impl1) mb_impl2)) =
  max (mbLift (fmap permImplSucceeds mb_impl1))
  (mbLift (fmap permImplSucceeds mb_impl2))
permImplSucceeds (PermImpl_Step (Impl1_ElimExists _ _)
                  (MbPermImpls_Cons _ mb_impl)) =
  mbLift $ fmap permImplSucceeds mb_impl
permImplSucceeds (PermImpl_Step (Impl1_Simpl _ _)
                  (MbPermImpls_Cons _ mb_impl)) =
  mbLift $ fmap permImplSucceeds mb_impl
permImplSucceeds (PermImpl_Step (Impl1_LetBind _ _)
                  (MbPermImpls_Cons _ mb_impl)) =
  mbLift $ fmap permImplSucceeds mb_impl
permImplSucceeds (PermImpl_Step (Impl1_ElimLLVMFieldContents _ _)
                  (MbPermImpls_Cons _ mb_impl)) =
  mbLift $ fmap permImplSucceeds mb_impl
permImplSucceeds (PermImpl_Step (Impl1_TryProveBVProp _ _ _)
                  (MbPermImpls_Cons _ mb_impl)) =
  mbLift $ fmap permImplSucceeds mb_impl


-- FIXME: no longer needed...?
traversePermImpl :: MonadStrongBind m => (forall ps. r1 ps -> m (r2 ps)) ->
                    PermImpl r1 ps -> m (PermImpl r2 ps)
traversePermImpl f (PermImpl_Done r) = PermImpl_Done <$> f r
traversePermImpl f (PermImpl_Step impl1 mb_impls) =
  PermImpl_Step impl1 <$> helper f mb_impls
  where
    helper :: MonadStrongBind m => (forall ps. r1 ps -> m (r2 ps)) ->
              MbPermImpls r1 bs_pss -> m (MbPermImpls r2 bs_pss)
    helper _ MbPermImpls_Nil = return MbPermImpls_Nil
    helper f (MbPermImpls_Cons mb_impls mb_impl) =
      do mb_impls' <- helper f mb_impls
         mb_impl' <- strongMbM (fmap (traversePermImpl f) mb_impl)
         return (MbPermImpls_Cons mb_impls' mb_impl')

-- | Assert a condition and print an error message if it fails
--
-- FIXME: put this somewhere more meaningful...
permAssert :: Bool -> String -> a -> a
permAssert True _ a = a
permAssert False str _ = error str

-- | Compute the input permissions of a 'SimplImpl' implication
simplImplIn :: SimplImpl ps_in ps_out -> DistPerms ps_in
simplImplIn (SImpl_Drop x p) = distPerms1 x p
simplImplIn (SImpl_Copy x p) =
  permAssert (permIsCopyable p)
  "simplImplIn: SImpl_Copy: permission is not copyable!" $
  distPerms1 x p
simplImplIn (SImpl_Swap x p1 y p2) = distPerms2 x p1 y p2
simplImplIn (SImpl_MoveUp ps1 x p ps2) =
  appendDistPerms (distPerms1 x p) $ appendDistPerms ps1 ps2
simplImplIn (SImpl_IntroOrL x p1 p2) = distPerms1 x p1
simplImplIn (SImpl_IntroOrR x p1 p2) = distPerms1 x p2
simplImplIn (SImpl_IntroExists x e p) =
  distPerms1 x (subst (singletonSubst e) p)
simplImplIn (SImpl_Cast x y p) = distPerms2 x (ValPerm_Eq $ PExpr_Var y) y p
simplImplIn (SImpl_IntroEqRefl x) = DistPermsNil
simplImplIn (SImpl_InvertEq x y) = distPerms1 x (ValPerm_Eq $ PExpr_Var y)
simplImplIn (SImpl_InvTransEq x y e) =
  distPerms2 x (ValPerm_Eq e) y (ValPerm_Eq e)
simplImplIn (SImpl_CopyEq x e) = distPerms1 x (ValPerm_Eq e)
simplImplIn (SImpl_LLVMWordEq x y e) =
  distPerms2 x (ValPerm_Eq (PExpr_LLVMWord (PExpr_Var y))) y (ValPerm_Eq e)
simplImplIn (SImpl_IntroConj x) = DistPermsNil
simplImplIn (SImpl_ExtractConj x ps i) = distPerms1 x (ValPerm_Conj ps)
simplImplIn (SImpl_CopyConj x ps i) = distPerms1 x (ValPerm_Conj ps)
simplImplIn (SImpl_InsertConj x p ps i) =
  distPerms2 x (ValPerm_Conj [p]) x (ValPerm_Conj ps)
simplImplIn (SImpl_AppendConjs x ps1 ps2) =
  distPerms2 x (ValPerm_Conj ps1) x (ValPerm_Conj ps2)
simplImplIn (SImpl_SplitConjs x ps _) =
  distPerms1 x (ValPerm_Conj ps)
simplImplIn (SImpl_ConstFunPerm x h _ _) =
  distPerms1 x (ValPerm_Eq $ PExpr_Fun h)
simplImplIn (SImpl_CastLLVMWord x e1 e2) =
  distPerms2 x (ValPerm_Eq $ PExpr_LLVMWord e1)
  x (ValPerm_Conj [Perm_BVProp $ BVProp_Eq e1 e2])
simplImplIn (SImpl_InvertLLVMOffsetEq x off y) =
  distPerms1 x $ ValPerm_Eq $ PExpr_LLVMOffset y off
simplImplIn (SImpl_OffsetLLVMWord y e off x) =
  distPerms2 x (ValPerm_Eq $ PExpr_LLVMOffset y off)
  y (ValPerm_Eq (PExpr_LLVMWord e))
simplImplIn (SImpl_CastLLVMPtr y p off x) =
  distPerms2 x (ValPerm_Eq $ PExpr_LLVMOffset y off) y p
simplImplIn (SImpl_CastLLVMFree x e1 e2) =
  distPerms2 x (ValPerm_Conj [Perm_LLVMFree e1])
  x (ValPerm_Conj [Perm_BVProp $ BVProp_Eq e1 e2])
simplImplIn (SImpl_CastLLVMFieldOffset x fld off') =
  distPerms2 x (ValPerm_Conj [Perm_LLVMField fld])
  x (ValPerm_Conj [Perm_BVProp $ BVProp_Eq (llvmFieldOffset fld) off'])
simplImplIn (SImpl_IntroLLVMFieldContents x y fld) =
  distPerms2 x (ValPerm_Conj [Perm_LLVMField $
                              fld { llvmFieldContents =
                                    ValPerm_Eq (PExpr_Var y)}])
  y (llvmFieldContents fld)
simplImplIn (SImpl_LLVMFieldLifetimeCurrent x fld l1 l2) =
  distPerms2 x (ValPerm_Conj [Perm_LLVMField fld])
  l1 (ValPerm_Conj [Perm_LCurrent l2])
simplImplIn (SImpl_LLVMFieldLifetimeAlways x fld l) =
  permAssert (llvmFieldLifetime fld == PExpr_Always)
  "simplImplIn: SImpl_LLVMFieldLifetimeAlways: input lifetime is not always" $
  distPerms1 x (ValPerm_Conj [Perm_LLVMField fld])
simplImplIn (SImpl_DemoteLLVMFieldWrite x fld) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMField fld])
simplImplIn (SImpl_LLVMArrayCopy x ap sub_ap) =
  if isJust (llvmArrayIsOffsetArray ap sub_ap) &&
     atomicPermIsCopyable (Perm_LLVMArray ap) then
    distPerms2 x (ValPerm_Conj [Perm_LLVMArray ap])
    x (ValPerm_Conj $ map Perm_BVProp $ llvmArrayContainsArray ap sub_ap)
  else
    error "simplImplIn: SImpl_LLVMArrayCopy: array permission not copyable or not a sub-array"
simplImplIn (SImpl_LLVMArrayBorrow x ap sub_ap) =
  if isJust (llvmArrayIsOffsetArray ap sub_ap) then
    distPerms2 x (ValPerm_Conj [Perm_LLVMArray ap])
    x (ValPerm_Conj $ map Perm_BVProp $ llvmArrayContainsArray ap sub_ap)
  else
    error "simplImplIn: SImpl_LLVMArrayBorrow: array permission not a sub-array"
simplImplIn (SImpl_LLVMArrayReturn x ap ret_ap) =
  if isJust (llvmArrayIsOffsetArray ap ret_ap) &&
     elem (llvmSubArrayBorrow ap ret_ap) (llvmArrayBorrows ap) then
    distPerms2 x (ValPerm_Conj [Perm_LLVMArray ret_ap])
    x (ValPerm_Conj [Perm_LLVMArray ap])
  else
    error "simplImplIn: SImpl_LLVMArrayReturn: array not being borrowed or not a sub-array"

simplImplIn (SImpl_LLVMArrayAppend x ap1 ap2) =
  case llvmArrayIsOffsetArray ap1 ap2 of
    Just len1
      | bvEq len1 (llvmArrayLen ap1)
      , llvmArrayFields ap1 == llvmArrayFields ap2 ->
        distPerms2 x (ValPerm_Conj1 $ Perm_LLVMArray ap1)
        x (ValPerm_Conj1 $ Perm_LLVMArray ap2)
    _ -> error "simplImplIn: SImpl_LLVMArrayAppend: arrays cannot be appended"

simplImplIn (SImpl_LLVMArrayRearrange x ap1 ap2) =
  if bvEq (llvmArrayOffset ap1) (llvmArrayOffset ap2) &&
     bvEq (llvmArrayLen ap1) (llvmArrayLen ap2) &&
     llvmArrayStride ap1 == llvmArrayStride ap2 &&
     llvmArrayFields ap1 == llvmArrayFields ap2 &&
     all (flip elem (llvmArrayBorrows ap2)) (llvmArrayBorrows ap1) &&
     all (flip elem (llvmArrayBorrows ap1)) (llvmArrayBorrows ap2) then
    distPerms1 x (ValPerm_Conj1 $ Perm_LLVMArray ap1)
  else
    error "simplImplOut: SImpl_LLVMArrayRearrange: arrays not equivalent"

simplImplIn (SImpl_LLVMArrayEmpty x ap) =
  if bvEq (llvmArrayLen ap) (bvInt 0) && llvmArrayBorrows ap == [] then
    DistPermsNil
  else
    error "simplImplIn: SImpl_LLVMArrayEmpty: malformed empty array permission"

simplImplIn (SImpl_LLVMArrayOneCell x ap) =
  case llvmArrayAsFields ap of
    Just (flds, []) ->
      distPerms1 x (ValPerm_Conj $ map llvmArrayFieldToAtomicPerm flds)
    _ -> error "simplImplIn: SImpl_LLVMArrayOneCell: unexpected form of array permission"

simplImplIn (SImpl_LLVMArrayIndexCopy x ap ix) =
  if llvmArrayIndexFieldNum ix < length (llvmArrayFields ap) &&
     atomicPermIsCopyable (llvmArrayFieldToAtomicPerm $
                           llvmArrayFieldWithOffset ap ix) then
    distPerms2 x (ValPerm_Conj [Perm_LLVMArray ap])
    x (ValPerm_Conj $ map Perm_BVProp $ llvmArrayIndexInArray ap ix)
  else
    if llvmArrayIndexFieldNum ix >= length (llvmArrayFields ap) then
      error "simplImplIn: SImpl_LLVMArrayIndexCopy: index out of range"
    else
      error "simplImplIn: SImpl_LLVMArrayIndexCopy: field is not copyable"

simplImplIn (SImpl_LLVMArrayIndexBorrow x ap ix) =
  distPerms2 x (ValPerm_Conj [Perm_LLVMArray ap])
  x (ValPerm_Conj $ map Perm_BVProp $ llvmArrayIndexInArray ap ix)

simplImplIn (SImpl_LLVMArrayIndexReturn x ap ix) =
  if elem (FieldBorrow ix) (llvmArrayBorrows ap) then
    distPerms2 x (ValPerm_Conj1 $ llvmArrayFieldToAtomicPerm $
                  llvmArrayFieldWithOffset ap ix)
    x (ValPerm_Conj [Perm_LLVMArray ap])
  else
    error "simplImplIn: SImpl_LLVMArrayIndexReturn: index not being borrowed"

simplImplIn (SImpl_LLVMArrayContents x ap _ _ _) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMArray ap])
simplImplIn (SImpl_LLVMFieldIsPtr x fp) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMField fp])
simplImplIn (SImpl_LLVMArrayIsPtr x ap) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMArray ap])
simplImplIn (SImpl_SplitLifetime x p l ps) =
  distPerms2 x p l (ValPerm_Conj [Perm_LOwned ps])
simplImplIn (SImpl_LCurrentRefl _) = DistPermsNil
simplImplIn (SImpl_LCurrentTrans l1 l2 l3) =
  distPerms2 l1 (ValPerm_Conj [Perm_LCurrent $ PExpr_Var l2])
  l2 (ValPerm_Conj [Perm_LCurrent l3])
simplImplIn (SImpl_FoldNamed x np args off) =
  distPerms1 x (unfoldPerm np args off)
simplImplIn (SImpl_UnfoldNamed x np args off) =
  distPerms1 x (ValPerm_Named (namedPermName np) args off)
simplImplIn (SImpl_NamedToConj x npn args off) =
  distPerms1 x (ValPerm_Named npn args off)
simplImplIn (SImpl_NamedFromConj x npn args off) =
  distPerms1 x (ValPerm_Conj1 $ Perm_NamedConj npn args off)
-- simplImplIn (SImpl_Mu x p1 _ _) = distPerms1 x (ValPerm_Mu p1)
simplImplIn (SImpl_NamedArgAlways x npn args off memb _) =
  case nthPermExpr args memb of
    PExpr_Always -> distPerms1 x (ValPerm_Named npn args off)
    _ -> error "simplImplIn: SImplNamedArgAlways: non-always argument!"
simplImplIn (SImpl_NamedArgCurrent x npn args off memb l2) =
  case nthPermExpr args memb of
    PExpr_Var l1 ->
      distPerms2 x (ValPerm_Named npn args off)
      l1 (ValPerm_Conj1 $ Perm_LCurrent l2)
    _ -> error "simplImplIn: SImplNamedArgCurrent: non-variable argument!"
simplImplIn (SImpl_NamedArgWrite x npn args off memb _) =
  case nthPermExpr args memb of
    PExpr_RWModality Write ->
      distPerms1 x (ValPerm_Named npn args off)
    _ -> error "simplImplIn: SImplNamedArgWrite: non-Write argument!"
simplImplIn (SImpl_NamedArgRead x npn args off _) =
  distPerms1 x (ValPerm_Named npn args off)


-- | Compute the output permissions of a 'SimplImpl' implication
simplImplOut :: SimplImpl ps_in ps_out -> DistPerms ps_out
simplImplOut (SImpl_Drop x p) = DistPermsNil
simplImplOut (SImpl_Copy x p) =
  if permIsCopyable p then distPerms2 x p x p else
    error "simplImplOut: SImpl_Copy: permission is not copyable!"
simplImplOut (SImpl_Swap x p1 y p2) = distPerms2 y p2 x p1
simplImplOut (SImpl_MoveUp ps1 x p ps2) =
  appendDistPerms (DistPermsCons ps1 x p) ps2
simplImplOut (SImpl_IntroOrL x p1 p2) = distPerms1 x (ValPerm_Or p1 p2)
simplImplOut (SImpl_IntroOrR x p1 p2) = distPerms1 x (ValPerm_Or p1 p2)
simplImplOut (SImpl_IntroExists x _ p) = distPerms1 x (ValPerm_Exists p)
simplImplOut (SImpl_Cast x _ p) = distPerms1 x p
simplImplOut (SImpl_IntroEqRefl x) = distPerms1 x (ValPerm_Eq $ PExpr_Var x)
simplImplOut (SImpl_InvertEq x y) = distPerms1 y (ValPerm_Eq $ PExpr_Var x)
simplImplOut (SImpl_InvTransEq x y e) = distPerms1 x (ValPerm_Eq $ PExpr_Var y)
simplImplOut (SImpl_CopyEq x e) = distPerms2 x (ValPerm_Eq e) x (ValPerm_Eq e)
simplImplOut (SImpl_LLVMWordEq x y e) =
  distPerms1 x (ValPerm_Eq (PExpr_LLVMWord e))
simplImplOut (SImpl_IntroConj x) = distPerms1 x ValPerm_True
simplImplOut (SImpl_ExtractConj x ps i) =
  if i < length ps then
    distPerms2 x (ValPerm_Conj [ps !! i])
    x (ValPerm_Conj (take i ps ++ drop (i+1) ps))
  else
    error "simplImplOut: SImpl_ExtractConj: index out of bounds"
simplImplOut (SImpl_CopyConj x ps i) =
  if i < length ps && atomicPermIsCopyable (ps !! i) then
    distPerms2 x (ValPerm_Conj [ps !! i]) x (ValPerm_Conj ps)
  else
    if i >= length ps then
      error "simplImplOut: SImpl_CopyConj: index out of bounds"
    else
      error "simplImplOut: SImpl_CopyConj: permission not copyable"
simplImplOut (SImpl_InsertConj x p ps i) =
  distPerms1 x (ValPerm_Conj (take i ps ++ p : drop i ps))
simplImplOut (SImpl_AppendConjs x ps1 ps2) =
  distPerms1 x (ValPerm_Conj (ps1 ++ ps2))
simplImplOut (SImpl_SplitConjs x ps i) =
  distPerms2 x (ValPerm_Conj (take i ps)) x (ValPerm_Conj (drop i ps))
simplImplOut (SImpl_ConstFunPerm x _ fun_perm _) =
  distPerms1 x (ValPerm_Conj1 $ Perm_Fun fun_perm)
simplImplOut (SImpl_CastLLVMWord x _ e2) =
  distPerms1 x (ValPerm_Eq $ PExpr_LLVMWord e2)
simplImplOut (SImpl_InvertLLVMOffsetEq x off y) =
  distPerms1 y $ ValPerm_Eq $ PExpr_LLVMOffset x $ bvNegate off
simplImplOut (SImpl_OffsetLLVMWord _ e off x) =
  distPerms1 x (ValPerm_Eq $ PExpr_LLVMWord $ bvAdd e off)
simplImplOut (SImpl_CastLLVMPtr _ p off x) =
  distPerms1 x (offsetLLVMPerm (bvNegate off) p)
simplImplOut (SImpl_CastLLVMFree x _ e2) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMFree e2])
simplImplOut (SImpl_CastLLVMFieldOffset x fld off') =
  distPerms1 x (ValPerm_Conj [Perm_LLVMField $ fld { llvmFieldOffset = off' }])
simplImplOut (SImpl_IntroLLVMFieldContents x _ fld) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMField fld])
simplImplOut (SImpl_LLVMFieldLifetimeCurrent x fld l1 l2) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMField fld { llvmFieldLifetime = l2 }])
simplImplOut (SImpl_LLVMFieldLifetimeAlways x fld l) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMField $ fld { llvmFieldLifetime = l }])
simplImplOut (SImpl_DemoteLLVMFieldWrite x fld) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMField $
                              fld { llvmFieldRW = PExpr_Read }])
simplImplOut (SImpl_LLVMArrayCopy x ap sub_ap) =
  if isJust (llvmArrayIsOffsetArray ap sub_ap) &&
     atomicPermIsCopyable (Perm_LLVMArray ap) then
    distPerms2 x (ValPerm_Conj [Perm_LLVMArray sub_ap])
    x (ValPerm_Conj [Perm_LLVMArray ap])
  else
    error "simplImplOut: SImpl_LLVMArrayCopy: array permission not copyable or not a sub-array"

simplImplOut (SImpl_LLVMArrayBorrow x ap sub_ap) =
  case llvmArrayIsOffsetArray ap sub_ap of
    Just cell_num ->
      distPerms2 x (ValPerm_Conj [Perm_LLVMArray sub_ap])
      x (ValPerm_Conj
         [Perm_LLVMArray $
          llvmArrayAddBorrow (llvmSubArrayBorrow ap sub_ap) $
          llvmArrayRemArrayBorrows ap sub_ap])
    Nothing ->
      error "simplImplOut: SImpl_LLVMArrayBorrow: array permission not a sub-array"

simplImplOut (SImpl_LLVMArrayReturn x ap ret_ap) =
  if isJust (llvmArrayIsOffsetArray ap ret_ap) &&
     elem (llvmSubArrayBorrow ap ret_ap) (llvmArrayBorrows ap) then
    distPerms1 x
    (ValPerm_Conj [Perm_LLVMArray $
                   llvmArrayRemBorrow (llvmSubArrayBorrow ap ret_ap) $
                   llvmArrayAddArrayBorrows ap ret_ap])
  else
    error "simplImplOut: SImpl_LLVMArrayReturn: array not being borrowed or not a sub-array"

simplImplOut (SImpl_LLVMArrayAppend x ap1 ap2) =
  case llvmArrayIsOffsetArray ap1 ap2 of
    Just len1
      | bvEq len1 (llvmArrayLen ap1)
      , llvmArrayFields ap1 == llvmArrayFields ap2
      , ap1' <- ap1 { llvmArrayLen =
                        bvAdd (llvmArrayLen ap1) (llvmArrayLen ap2) } ->
        distPerms1 x $ ValPerm_Conj1 $ Perm_LLVMArray $
        llvmArrayAddArrayBorrows ap1' ap2
    _ -> error "simplImplOut: SImpl_LLVMArrayAppend: arrays cannot be appended"

simplImplOut (SImpl_LLVMArrayRearrange x ap1 ap2) =
  if bvEq (llvmArrayOffset ap1) (llvmArrayOffset ap2) &&
     bvEq (llvmArrayLen ap1) (llvmArrayLen ap2) &&
     llvmArrayStride ap1 == llvmArrayStride ap2 &&
     llvmArrayFields ap1 == llvmArrayFields ap2 &&
     all (flip elem (llvmArrayBorrows ap2)) (llvmArrayBorrows ap1) &&
     all (flip elem (llvmArrayBorrows ap1)) (llvmArrayBorrows ap2) then
    distPerms1 x (ValPerm_Conj1 $ Perm_LLVMArray ap2)
  else
    error "simplImplOut: SImpl_LLVMArrayRearrange: arrays not equivalent"

simplImplOut (SImpl_LLVMArrayEmpty x ap) =
  if bvEq (llvmArrayLen ap) (bvInt 0) && llvmArrayBorrows ap == [] then
    distPerms1 x (ValPerm_Conj1 $ Perm_LLVMArray ap)
  else
    error "simplImplOut: SImpl_LLVMArrayEmpty: malformed empty array permission"

simplImplOut (SImpl_LLVMArrayOneCell x ap) =
  case llvmArrayAsFields ap of
    Just (_, []) ->
      distPerms1 x (ValPerm_Conj1 $ Perm_LLVMArray ap)
    _ -> error "simplImplOut: SImpl_LLVMArrayOneCell: unexpected form of array permission"

simplImplOut (SImpl_LLVMArrayIndexCopy x ap ix) =
  if llvmArrayIndexFieldNum ix < length (llvmArrayFields ap) &&
     atomicPermIsCopyable (llvmArrayFieldToAtomicPerm $
                           llvmArrayFieldWithOffset ap ix) then
    distPerms2 x (ValPerm_Conj1 $ llvmArrayFieldToAtomicPerm $
                  llvmArrayFieldWithOffset ap ix)
    x (ValPerm_Conj [Perm_LLVMArray ap])
  else
    if llvmArrayIndexFieldNum ix >= length (llvmArrayFields ap) then
      error "simplImplOut: SImpl_LLVMArrayIndexCopy: index out of range"
    else
      error "simplImplOut: SImpl_LLVMArrayIndexCopy: field is not copyable"

simplImplOut (SImpl_LLVMArrayIndexBorrow x ap ix) =
  distPerms2 x (ValPerm_Conj1 $ llvmArrayFieldToAtomicPerm $
                llvmArrayFieldWithOffset ap ix)
  x (ValPerm_Conj [Perm_LLVMArray $
                   llvmArrayAddBorrow (FieldBorrow ix) ap])

simplImplOut (SImpl_LLVMArrayIndexReturn x ap ix) =
  if elem (FieldBorrow ix) (llvmArrayBorrows ap) then
    distPerms1 x
    (ValPerm_Conj [Perm_LLVMArray $ llvmArrayRemBorrow (FieldBorrow ix) ap])
  else
    error "simplImplOut: SImpl_LLVMArrayIndexReturn: index not being borrowed"

simplImplOut (SImpl_LLVMArrayContents x ap i fp _) =
  distPerms1 x (ValPerm_Conj [Perm_LLVMArray $
                              ap { llvmArrayFields =
                                     take i (llvmArrayFields ap) ++
                                     fp : drop (i+1) (llvmArrayFields ap)}])

simplImplOut (SImpl_LLVMFieldIsPtr x fp) =
  distPerms2 x (ValPerm_Conj1 Perm_IsLLVMPtr)
  x (ValPerm_Conj [Perm_LLVMField fp])
simplImplOut (SImpl_LLVMArrayIsPtr x ap) =
  distPerms2 x (ValPerm_Conj1 Perm_IsLLVMPtr)
  x (ValPerm_Conj [Perm_LLVMArray ap])
simplImplOut (SImpl_SplitLifetime x p l ps) =
  distPerms2 x (inLifetime (PExpr_Var l) p)
  l (ValPerm_Conj [Perm_LOwned (PExpr_PermListCons (PExpr_Var x) p ps)])
simplImplOut (SImpl_LCurrentRefl l) =
  distPerms1 l (ValPerm_Conj1 $ Perm_LCurrent $ PExpr_Var l)
simplImplOut (SImpl_LCurrentTrans l1 _ l3) =
  distPerms1 l1 (ValPerm_Conj [Perm_LCurrent l3])
simplImplOut (SImpl_FoldNamed x np args off) =
  distPerms1 x (ValPerm_Named (namedPermName np) args off)
simplImplOut (SImpl_UnfoldNamed x np args off) =
  distPerms1 x (unfoldPerm np args off)
simplImplOut (SImpl_NamedToConj x npn args off) =
  distPerms1 x (ValPerm_Conj1 $ Perm_NamedConj npn args off)
simplImplOut (SImpl_NamedFromConj x npn args off) =
  distPerms1 x (ValPerm_Named npn args off)
-- simplImplOut (SImpl_Mu x _ p2 _) = distPerms1 x (ValPerm_Mu p2)
simplImplOut (SImpl_NamedArgAlways x npn args off memb l) =
  distPerms1 x (ValPerm_Named npn (setNthPermExpr args memb l) off)
simplImplOut (SImpl_NamedArgCurrent x npn args off memb l2) =
  distPerms1 x (ValPerm_Named npn (setNthPermExpr args memb l2) off)
simplImplOut (SImpl_NamedArgWrite x npn args off memb rw) =
  distPerms1 x (ValPerm_Named npn (setNthPermExpr args memb rw) off)
simplImplOut (SImpl_NamedArgRead x npn args off memb) =
  distPerms1 x (ValPerm_Named npn
                (setNthPermExpr args memb (PExpr_RWModality Read))
                off)


-- | Apply a 'SimplImpl' implication to the permissions on the top of a
-- permission set stack, checking that they equal the 'simplImplIn' of the
-- 'SimplImpl' and then replacing them with its 'simplImplOut'
applySimplImpl :: PPInfo -> Proxy ps -> SimplImpl ps_in ps_out ->
                  PermSet (ps :++: ps_in) -> PermSet (ps :++: ps_out)
applySimplImpl pp_info prx simpl =
  modifyDistPerms $ \all_ps ->
  let (ps, ps_in) =
        splitDistPerms prx (distPermsToProxies $ simplImplIn simpl) all_ps in
  if ps_in == simplImplIn simpl then
    appendDistPerms ps (simplImplOut simpl)
  else
    error $ renderDoc $
    vsep [string "applySimplImpl: incorrect input permissions",
          string "expected: " <> permPretty pp_info (simplImplIn simpl),
          string "actual: " <> permPretty pp_info ps_in]

-- | A sequence of permission sets inside name-bindings
data MbPermSets bs_pss where
  MbPermSets_Nil :: MbPermSets RNil
  MbPermSets_Cons :: MbPermSets bs_pss -> CruCtx bs -> Mb bs (PermSet ps) ->
                     MbPermSets (bs_pss :> '(bs,ps))

-- | Helper for building a one-element 'MbPermSets' sequence
mbPermSets1 :: KnownRepr CruCtx bs =>
               Mb bs (PermSet ps) -> MbPermSets (RNil :> '(bs,ps))
mbPermSets1 = MbPermSets_Cons MbPermSets_Nil knownRepr

-- | Helper for building a two-element 'MbPermSets' sequence
mbPermSets2 :: (KnownRepr CruCtx bs1, KnownRepr CruCtx bs2) =>
               Mb bs1 (PermSet ps1) -> Mb bs2 (PermSet ps2) ->
               MbPermSets (RNil :> '(bs1,ps1) :> '(bs2,ps2))
mbPermSets2 ps1 ps2 =
  MbPermSets_Cons (MbPermSets_Cons MbPermSets_Nil knownRepr ps1) knownRepr ps2

-- | Apply a single permission implication step to a permission set
applyImpl1 :: PPInfo -> PermImpl1 ps_in ps_outs -> PermSet ps_in ->
              MbPermSets ps_outs
applyImpl1 _ (Impl1_Fail _) _ = MbPermSets_Nil
applyImpl1 _ Impl1_Catch ps = mbPermSets2 (emptyMb ps) (emptyMb ps)
applyImpl1 pp_info (Impl1_Push x p) ps =
  if ps ^. varPerm x == p then
    mbPermSets1 $ emptyMb $ pushPerm x p $ set (varPerm x) ValPerm_True ps
  else
    error $ renderDoc (string "applyImpl1: Impl1_Push" <+>
                       permPretty pp_info x <+> colon </>
                       string "expected:" <+> permPretty pp_info p </>
                       string "found:" <+>
                       permPretty pp_info (ps ^. varPerm x))
applyImpl1 pp_info (Impl1_Pop x p) ps =
  if ps ^. topDistPerm x == p && ps ^. varPerm x == ValPerm_True then
    mbPermSets1 $ emptyMb $ fst $ popPerm x $ set (varPerm x) p ps
  else
    if ps ^. varPerm x == ValPerm_True then
      error $ renderDoc $
      vsep [string "applyImpl1: Impl1_Pop: unexpected permissions on top of the stack",
            string "expected: " <> permPretty pp_info p,
            string "actual: " <> permPretty pp_info (ps ^. topDistPerm x)]
    else
      error $ renderDoc $
      vsep [string "applyImpl1: Impl1_Pop: non-empty permissions for variable"
            <+> permPretty pp_info x <> string ":",
            permPretty pp_info (ps ^. varPerm x)]
applyImpl1 _ (Impl1_ElimOr x p1 p2) ps =
  if ps ^. topDistPerm x == ValPerm_Or p1 p2 then
    mbPermSets2 (emptyMb $ set (topDistPerm x) p1 ps)
    (emptyMb $ set (topDistPerm x) p2 ps)
  else
    error "applyImpl1: Impl1_ElimOr: unexpected permission"
applyImpl1 _ (Impl1_ElimExists x p_body) ps =
  if ps ^. topDistPerm x == ValPerm_Exists p_body then
    mbPermSets1 (fmap (\p -> set (topDistPerm x) p ps) p_body)
  else
    error "applyImpl1: Impl1_ElimExists: unexpected permission"
applyImpl1 pp_info (Impl1_Simpl simpl prx) ps =
  mbPermSets1 $ emptyMb $ applySimplImpl pp_info prx simpl ps
applyImpl1 pp_info (Impl1_LetBind tp e) ps =
  MbPermSets_Cons MbPermSets_Nil (CruCtxCons CruCtxNil tp) $
  nu $ \x -> pushPerm x (ValPerm_Eq e) ps
applyImpl1 _ (Impl1_ElimLLVMFieldContents x fp) ps =
  if ps ^. topDistPerm x == ValPerm_Conj [Perm_LLVMField fp] then
    (mbPermSets1 $ nu $ \y ->
      pushPerm y (llvmFieldContents fp) $
      set (topDistPerm x) (ValPerm_Conj [Perm_LLVMField $
                                         fp { llvmFieldContents =
                                              ValPerm_Eq (PExpr_Var y) }])
      ps)
  else
    error "applyImpl1: Impl1_ElimLLVMFieldContents: unexpected permission"
applyImpl1 _ (Impl1_TryProveBVProp x prop _) ps =
  mbPermSets1 $ emptyMb $
  pushPerm x (ValPerm_Conj [Perm_BVProp prop]) ps


instance SubstVar PermVarSubst m =>
         Substable PermVarSubst (SimplImpl ps_in ps_out) m where
  genSubst s [nuP| SImpl_Drop x p |] =
    SImpl_Drop <$> genSubst s x <*> genSubst s p
  genSubst s [nuP| SImpl_Copy x p |] =
    SImpl_Copy <$> genSubst s x <*> genSubst s p
  genSubst s [nuP| SImpl_Swap x p1 y p2 |] =
    SImpl_Swap <$> genSubst s x <*> genSubst s p1 <*> genSubst s y <*> genSubst s p2
  genSubst s [nuP| SImpl_MoveUp ps1 x p ps2 |] =
    SImpl_MoveUp <$> genSubst s ps1 <*> genSubst s x <*>
    genSubst s p <*> genSubst s ps2
  genSubst s [nuP| SImpl_IntroOrL x p1 p2 |] =
    SImpl_IntroOrL <$> genSubst s x <*> genSubst s p1 <*> genSubst s p2
  genSubst s [nuP| SImpl_IntroOrR x p1 p2 |] =
    SImpl_IntroOrR <$> genSubst s x <*> genSubst s p1 <*> genSubst s p2
  genSubst s [nuP| SImpl_IntroExists x e p |] =
    SImpl_IntroExists <$> genSubst s x <*> genSubst s e <*> genSubst s p
  genSubst s [nuP| SImpl_Cast x y p |] =
    SImpl_Cast <$> genSubst s x <*> genSubst s y <*> genSubst s p
  genSubst s [nuP| SImpl_IntroEqRefl x |] =
    SImpl_IntroEqRefl <$> genSubst s x
  genSubst s [nuP| SImpl_InvertEq x y |] =
    SImpl_InvertEq <$> genSubst s x <*> genSubst s y
  genSubst s [nuP| SImpl_InvTransEq x y e |] =
    SImpl_InvTransEq <$> genSubst s x <*> genSubst s y <*> genSubst s e
  genSubst s [nuP| SImpl_CopyEq x e |] =
    SImpl_CopyEq <$> genSubst s x <*> genSubst s e
  genSubst s [nuP| SImpl_LLVMWordEq x y e |] =
    SImpl_LLVMWordEq <$> genSubst s x <*> genSubst s y <*> genSubst s e
  genSubst s [nuP| SImpl_IntroConj x |] =
    SImpl_IntroConj <$> genSubst s x
  genSubst s [nuP| SImpl_ExtractConj x ps i |] =
    SImpl_ExtractConj <$> genSubst s x <*> genSubst s ps <*> return (mbLift i)
  genSubst s [nuP| SImpl_CopyConj x ps i |] =
    SImpl_CopyConj <$> genSubst s x <*> genSubst s ps <*> return (mbLift i)
  genSubst s [nuP| SImpl_InsertConj x p ps i |] =
    SImpl_InsertConj <$> genSubst s x <*> genSubst s p <*>
    genSubst s ps <*> return (mbLift i)
  genSubst s [nuP| SImpl_AppendConjs x ps1 ps2 |] =
    SImpl_AppendConjs <$> genSubst s x <*> genSubst s ps1 <*> genSubst s ps2
  genSubst s [nuP| SImpl_SplitConjs x ps i |] =
    SImpl_SplitConjs <$> genSubst s x <*> genSubst s ps <*> return (mbLift i)
  genSubst s [nuP| SImpl_ConstFunPerm x h fun_perm ident |] =
    SImpl_ConstFunPerm <$> genSubst s x <*> return (mbLift h) <*>
    genSubst s fun_perm <*> return (mbLift ident)
  genSubst s [nuP| SImpl_CastLLVMWord x e1 e2 |] =
    SImpl_CastLLVMWord <$> genSubst s x <*> genSubst s e1 <*> genSubst s e2
  genSubst s [nuP| SImpl_InvertLLVMOffsetEq x off y |] =
    SImpl_InvertLLVMOffsetEq <$> genSubst s x <*> genSubst s off <*> genSubst s y
  genSubst s [nuP| SImpl_OffsetLLVMWord y e off x |] =
    SImpl_OffsetLLVMWord <$> genSubst s y <*> genSubst s e <*>
    genSubst s off <*> genSubst s x
  genSubst s [nuP| SImpl_CastLLVMPtr y p off x |] =
    SImpl_CastLLVMPtr <$> genSubst s y <*> genSubst s p <*>
    genSubst s off <*> genSubst s x
  genSubst s [nuP| SImpl_CastLLVMFree x e1 e2 |] =
    SImpl_CastLLVMFree <$> genSubst s x <*> genSubst s e1 <*> genSubst s e2
  genSubst s [nuP| SImpl_CastLLVMFieldOffset x fld off' |] =
    SImpl_CastLLVMFieldOffset <$> genSubst s x <*> genSubst s fld <*>
    genSubst s off'
  genSubst s [nuP| SImpl_IntroLLVMFieldContents x y fld |] =
    SImpl_IntroLLVMFieldContents <$> genSubst s x <*> genSubst s y <*>
    genSubst s fld
  genSubst s [nuP| SImpl_LLVMFieldLifetimeCurrent x fld l1 l2 |] =
    SImpl_LLVMFieldLifetimeCurrent <$> genSubst s x <*> genSubst s fld <*>
    genSubst s l1 <*> genSubst s l2
  genSubst s [nuP| SImpl_LLVMFieldLifetimeAlways x fld l |] =
    SImpl_LLVMFieldLifetimeAlways <$> genSubst s x <*> genSubst s fld <*>
    genSubst s l
  genSubst s [nuP| SImpl_DemoteLLVMFieldWrite x fld |] =
    SImpl_DemoteLLVMFieldWrite <$> genSubst s x <*> genSubst s fld
  genSubst s [nuP| SImpl_LLVMArrayCopy x ap rng |] =
    SImpl_LLVMArrayCopy <$> genSubst s x <*> genSubst s ap <*> genSubst s rng
  genSubst s [nuP| SImpl_LLVMArrayBorrow x ap rng |] =
    SImpl_LLVMArrayBorrow <$> genSubst s x <*> genSubst s ap <*> genSubst s rng
  genSubst s [nuP| SImpl_LLVMArrayReturn x ap rng |] =
    SImpl_LLVMArrayReturn <$> genSubst s x <*> genSubst s ap <*> genSubst s rng
  genSubst s [nuP| SImpl_LLVMArrayAppend x ap1 ap2 |] =
    SImpl_LLVMArrayAppend <$> genSubst s x <*> genSubst s ap1 <*> genSubst s ap2
  genSubst s [nuP| SImpl_LLVMArrayRearrange x ap1 ap2 |] =
    SImpl_LLVMArrayRearrange <$> genSubst s x <*> genSubst s ap1 <*> genSubst s ap2
  genSubst s [nuP| SImpl_LLVMArrayEmpty x ap |] =
    SImpl_LLVMArrayEmpty <$> genSubst s x <*> genSubst s ap
  genSubst s [nuP| SImpl_LLVMArrayOneCell x ap |] =
    SImpl_LLVMArrayOneCell <$> genSubst s x <*> genSubst s ap
  genSubst s [nuP| SImpl_LLVMArrayIndexCopy x ap ix |] =
    SImpl_LLVMArrayIndexCopy <$> genSubst s x <*> genSubst s ap <*> genSubst s ix
  genSubst s [nuP| SImpl_LLVMArrayIndexBorrow x ap ix |] =
    SImpl_LLVMArrayIndexBorrow <$> genSubst s x <*> genSubst s ap <*>
    genSubst s ix
  genSubst s [nuP| SImpl_LLVMArrayIndexReturn x ap ix |] =
    SImpl_LLVMArrayIndexReturn <$> genSubst s x <*> genSubst s ap <*>
    genSubst s ix
  genSubst s [nuP| SImpl_LLVMArrayContents x ap i fp impl |] =
    SImpl_LLVMArrayContents <$> genSubst s x <*> genSubst s ap <*>
    return (mbLift i) <*> genSubst s fp <*> genSubst s impl
  genSubst s [nuP| SImpl_LLVMFieldIsPtr x fp |] =
    SImpl_LLVMFieldIsPtr <$> genSubst s x <*> genSubst s fp
  genSubst s [nuP| SImpl_LLVMArrayIsPtr x ap |] =
    SImpl_LLVMArrayIsPtr <$> genSubst s x <*> genSubst s ap
  genSubst s [nuP| SImpl_SplitLifetime x p l ps |] =
    SImpl_SplitLifetime <$> genSubst s x <*> genSubst s p <*> genSubst s l <*>
    genSubst s ps
  genSubst s [nuP| SImpl_LCurrentRefl l |] =
    SImpl_LCurrentRefl <$> genSubst s l
  genSubst s [nuP| SImpl_LCurrentTrans l1 l2 l3 |] =
    SImpl_LCurrentTrans <$> genSubst s l1 <*> genSubst s l2 <*> genSubst s l3
  genSubst s [nuP| SImpl_FoldNamed x np args off |] =
    SImpl_FoldNamed <$> genSubst s x <*> genSubst s np <*> genSubst s args
     <*> genSubst s off
  genSubst s [nuP| SImpl_UnfoldNamed x np args off |] =
    SImpl_UnfoldNamed <$> genSubst s x <*> genSubst s np <*> genSubst s args
     <*> genSubst s off
  genSubst s [nuP| SImpl_NamedToConj x npn args off |] =
    SImpl_NamedToConj <$> genSubst s x <*> genSubst s npn <*> genSubst s args
     <*> genSubst s off
  genSubst s [nuP| SImpl_NamedFromConj x npn args off |] =
    SImpl_NamedFromConj <$> genSubst s x <*> genSubst s npn <*> genSubst s args
     <*> genSubst s off
  genSubst s [nuP| SImpl_NamedArgAlways x npn args off memb l |] =
    SImpl_NamedArgAlways <$> genSubst s x <*> genSubst s npn <*>
    genSubst s args <*> genSubst s off <*> genSubst s memb <*> genSubst s l
  genSubst s [nuP| SImpl_NamedArgCurrent x npn args off memb l2 |] =
    SImpl_NamedArgCurrent <$> genSubst s x <*> genSubst s npn <*>
    genSubst s args <*> genSubst s off <*> genSubst s memb <*> genSubst s l2
  genSubst s [nuP| SImpl_NamedArgWrite x npn args off memb rw |] =
    SImpl_NamedArgWrite <$> genSubst s x <*> genSubst s npn <*>
    genSubst s args <*> genSubst s off <*> genSubst s memb <*> genSubst s rw
  genSubst s [nuP| SImpl_NamedArgRead x npn args off memb |] =
    SImpl_NamedArgRead <$> genSubst s x <*> genSubst s npn <*>
    genSubst s args <*> genSubst s off <*> genSubst s memb

instance SubstVar PermVarSubst m =>
         Substable PermVarSubst (PermImpl1 ps_in ps_out) m where
  genSubst s [nuP| Impl1_Fail str |] = return (Impl1_Fail $ mbLift str)
  genSubst s [nuP| Impl1_Catch |] = return Impl1_Catch
  genSubst s [nuP| Impl1_Push x p |] =
    Impl1_Push <$> genSubst s x <*> genSubst s p
  genSubst s [nuP| Impl1_Pop x p |] =
    Impl1_Pop <$> genSubst s x <*> genSubst s p
  genSubst s [nuP| Impl1_ElimOr x p1 p2 |] =
    Impl1_ElimOr <$> genSubst s x <*> genSubst s p1 <*> genSubst s p2
  genSubst s [nuP| Impl1_ElimExists x p_body |] =
    Impl1_ElimExists <$> genSubst s x <*> genSubst s p_body
  genSubst s [nuP| Impl1_Simpl simpl prx |] =
    Impl1_Simpl <$> genSubst s simpl <*> return (mbLift prx)
  genSubst s [nuP| Impl1_LetBind tp e |] =
    Impl1_LetBind (mbLift tp) <$> genSubst s e
  genSubst s [nuP| Impl1_ElimLLVMFieldContents x fp |] =
    Impl1_ElimLLVMFieldContents <$> genSubst s x <*> genSubst s fp
  genSubst s [nuP| Impl1_TryProveBVProp x prop prop_str |] =
    Impl1_TryProveBVProp <$> genSubst s x <*> genSubst s prop <*>
    return (mbLift prop_str)

-- FIXME: shouldn't need the SubstVar PermVarSubst m assumption...
instance (NuMatchingAny1 r, SubstVar PermVarSubst m,
          Substable1 PermVarSubst r m) =>
         Substable PermVarSubst (PermImpl r ps) m where
  genSubst s [nuP| PermImpl_Done r |] = PermImpl_Done <$> genSubst1 s r
  genSubst s [nuP| PermImpl_Step impl1 mb_impls |] =
    PermImpl_Step <$> genSubst s impl1 <*> genSubst s mb_impls

-- FIXME: shouldn't need the SubstVar PermVarSubst m assumption...
instance (NuMatchingAny1 r, SubstVar PermVarSubst m,
          Substable1 PermVarSubst r m) =>
         Substable PermVarSubst (MbPermImpls r bs_pss) m where
  genSubst _ [nuP| MbPermImpls_Nil |] = return MbPermImpls_Nil
  genSubst s [nuP| MbPermImpls_Cons mb_impl mb_impls |] =
    MbPermImpls_Cons <$> genSubst s mb_impl <*> genSubst s mb_impls

instance SubstVar s m => Substable s (a :~: b) m where
  genSubst _ = return . mbLift

instance SubstVar s m => Substable1 s ((:~:) a) m where
  genSubst1 _ = return . mbLift


----------------------------------------------------------------------
-- * Generalized Monads
----------------------------------------------------------------------

-- | A generalized monad has additional "input" and "output" types, that
-- sequence together "backwards" through the generalized bind operation. Mostly
-- this is to support 'GenContM', below.
--
-- Note that a generalized monad @m@ should always be a standard monad when the
-- input and output types are the same; i.e., @m r r@ should always be a
-- monad. I do not know a nice way to encode this in Haskell, however...
class GenMonad (m :: k -> k -> Type -> Type) where
  -- | Generalized return
  greturn :: a -> m r r a
  -- | Generalized bind, that passes the output of @f@ to the input of @m@
  (>>>=) :: m r2 r3 a -> (a -> m r1 r2 b) -> m r1 r3 b

infixl 1 >>>=
infixl 1 >>>

(>>>) :: GenMonad m => m r2 r3 a -> m r1 r2 b -> m r1 r3 b
m1 >>> m2 = m1 >>>= \a -> seq a m2

class GenMonadT (t :: (k1 -> k1 -> Type -> Type) ->
                 k2 -> k2 -> Type -> Type) p1 p2 q1 q2 |
  t q1 q2 -> p1 p2 , t q1 p2 -> q2 p1 , t p1 q2 -> p2 q1 where
  glift :: GenMonad m => m p1 p2 a -> t m q1 q2 a


-- | The generalized continuation transformer, which can have different types
-- for the input vs output continuations
newtype GenContM rin rout a =
  GenContM { runGenContM :: (a -> rin) -> rout }

liftGenContM :: Monad m => m a -> GenContM (m b) (m b) a
liftGenContM m = GenContM $ \k -> m >>= k

instance Functor (GenContM r r) where
  fmap f m = m >>= return . f

instance Applicative (GenContM r r) where
  pure = return
  (<*>) = ap

instance Monad (GenContM r r) where
  return x = GenContM $ \(!k) -> k x
  GenContM m >>= f = GenContM $ \(!k) -> m $ \(!a) -> runGenContM (f a) k

instance GenMonad GenContM where
  greturn x = GenContM $ \(!k) -> k x
  (GenContM m) >>>= f = GenContM $ \(!k) -> m $ \(!a) -> runGenContM (f a) k

{-
-- | Change the return type constructor @r@ by mapping the new input type to the
-- old and mapping the old output type to the new
withAltContM :: (r2 pin2 -> r1 pin1) -> (r1 pout1 -> r2 pout2) ->
                GenContM r1 pin1 pout1 a -> GenContM r2 pin2 pout2 a
withAltContM f_in f_out (GenContM m) =
  GenContM $ \k -> f_out (m (f_in . k))
-}

-- | Typeclass for generalized monads that allow a pure capture of the CC
class GenMonad m => GenMonadCaptureCC rin rout m p1 p2 |
  m p1 -> rin , m p2 -> rout , m p1 rout -> p2 , m p2 rin -> p1 where
  gcaptureCC :: ((a -> rin) -> rout) -> m p1 p2 a

instance GenMonadCaptureCC r1 r2 GenContM r1 r2 where
  gcaptureCC f = GenContM f

instance GenMonadCaptureCC rin rout m q1 q2 =>
         GenMonadCaptureCC rin rout (GenStateT m) '(s,q1) '(s,q2) where
  gcaptureCC f = glift $ gcaptureCC f

gmapRet :: GenMonadCaptureCC rin rout m p1 p2 => (rin -> rout) -> m p1 p2 ()
gmapRet f_ret =
  gcaptureCC $ \(!k) -> f_ret $ k ()

-- | Name-binding in the generalized continuation monad (FIXME: explain)
gopenBinding :: GenMonadCaptureCC rin rout m p1 p2 =>
                (Mb ctx rin -> rout) -> Mb ctx a ->
                m p1 p2 (RAssign Name ctx, a)
gopenBinding f_ret !mb_a =
  gcaptureCC $ \ !k ->
  f_ret $ flip nuMultiWithElim1 mb_a $ \ !names !a ->
  k (names, a)

gopenBinding1 :: GenMonadCaptureCC rin rout m p1 p2 =>
                 (Binding a rin -> rout) -> Binding a b ->
                 m p1 p2 (Name a, b)
gopenBinding1 f_ret !mb_b =
  gopenBinding f_ret mb_b >>>= \(_ :>: nm, b) -> greturn (nm,b)


{-
class GenMonad m => GenMonadShift r m | m -> r where
  gshift :: ((a -> m p1 p1 (r p2)) -> m p3 p4 (r p3)) -> m p2 p4 a

instance GenMonadShift r (GenContM r) where
  gshift f = GenContM $ \k -> runGenContM (f (\a -> greturn (k a))) id
-}

{-
-- | Running generalized computations in "parallel"
class GenMonad m => GenMonadPar r m p1 p2 | m p1 p2 -> r where
  gparallel :: (r -> r -> r) -> m p1 p2 a -> m p1 p2 a -> m p1 p2 a

instance GenMonadPar r2 GenContM r1 r2 where
  gparallel f (GenContM m1) (GenContM m2) =
    GenContM $ \k -> f (m1 k) (m2 k)

instance GenMonadPar r m q1 q2 =>
         GenMonadPar r (GenStateT m) '(s1,q1) '(s2,q2) where
  gparallel f m1 m2 =
    GenStateT $ \s ->
    gparallel f
    (unGenStateT m1 s) (unGenStateT m2 s)
-}

type family Fst (p :: (k1,k2)) :: k1 where
  Fst '(x,_) = x

type family Snd (p :: (k1,k2)) :: k2 where
  Snd '(_,y) = y

-- | The generalized state monad. Don't get confused: the parameters are
-- reversed, so @p2@ is the /input/ state param type and @p1@ is the /output/.
newtype GenStateT (m :: k -> k -> Type -> Type) p1 p2 a =
  GenStateT { unGenStateT :: Fst p2 -> m (Snd p1) (Snd p2) (a, Fst p1) }

-- | This version of 'unGenStateT' tells GHC to make the parameters into actual
-- type-level pairs, i.e., it makes GHC reason extensionally about pairs
runGenStateT :: GenStateT m '(s1,q1) '(s2,q2) a -> s2 -> m q1 q2 (a, s1)
runGenStateT = unGenStateT

instance Monad (m (Snd p) (Snd p)) => Functor (GenStateT m p p) where
  fmap f m = m >>= return . f

instance Monad (m (Snd p) (Snd p)) => Applicative (GenStateT m p p) where
  pure = return
  (<*>) = ap

instance Monad (m (Snd p) (Snd p)) => Monad (GenStateT m p p) where
  return x = GenStateT $ \s -> return (x, s)
  (GenStateT m) >>= f =
    GenStateT $ \s -> m s >>= \(a, s') -> unGenStateT (f a) s'

instance GenMonadT GenStateT q1 q2 '(s,q1) '(s,q2) where
  glift m = GenStateT $ \s -> m >>>= \a -> greturn (a, s)

instance GenMonad m => GenMonad (GenStateT m) where
  greturn x = GenStateT $ \s -> greturn (x, s)
  (GenStateT m) >>>= f =
    GenStateT $ \s -> m s >>>= \(a, s') -> unGenStateT (f a) s'

-- | FIXME: documentation
gliftGenStateT :: (GenMonad m) =>
                  m q1 q2 a -> GenStateT m '(s, q1) '(s, q2) a
gliftGenStateT m = glift m

-- | Run a generalized state computation with a different state type @s2@ inside
-- one with state type @s1@, using a lens-like pair of a getter function to
-- extract out the starting inner @s2@ state from the outer @s1@ state and an
-- update function to update the resulting outer @s1@ state with the final inner
-- @s2@ state.
withAltStateM :: GenMonad m => (s2' -> s2) -> (s2' -> s1 -> s1') ->
                 GenStateT m '(s1,q1) '(s2,q2) a ->
                 GenStateT m '(s1',q1) '(s2',q2) a
withAltStateM s_get s_update m =
  gget >>>= \s ->
  gput (s_get s) >>>
  m >>>= \a ->
  gget >>>= \s' ->
  gput (s_update s s') >>>
  greturn a

instance (Monad (m (Snd p) (Snd p)), s ~ Fst p) =>
         MonadState s (GenStateT m p p) where
  get = GenStateT $ \s -> return (s, s)
  put s = GenStateT $ \_ -> return ((), s)

class GenMonad m => GenMonadGet s m p | m p -> s where
  gget :: m p p s

class GenMonad m => GenMonadPut s m p1 p2 | m p1 p2 -> s where
  gput :: s -> m p1 p2 ()

instance GenMonad m => GenMonadGet s (GenStateT m) '(s,q) where
  gget = GenStateT $ \(!s) -> greturn (s, s)

instance GenMonad m =>
         GenMonadPut s1 (GenStateT m) '(s1,q) '(s2,q) where
  gput !s = GenStateT $ \_ -> greturn ((), s)

gmodify :: (GenMonadGet s1 m p2, GenMonadPut s2 m p1 p2) =>
           (s1 -> s2) -> m p1 p2 ()
gmodify f =
  gget >>>= \(!s) -> gput $! (f s)

{-
class GenMonad m =>
      GenMonadState (s :: sk -> Type) (m :: k -> k -> Type -> Type) | m -> s where
  type GStateParam m (p :: k) :: sk
  gget :: m p p (s (GStateParam m p))
  gput :: s (GStateParam m p) -> m p p ()

instance GenMonad m => GenMonadState s (GenStateT s m) where
  type GStateParam (GenStateT s m) p = Fst p
  gget = GenStateT $ \s -> greturn (s, s)
  gput s = GenStateT $ \_ -> greturn ((), s)
-}


-- | The generalized state-continuation monad
type GenStateContM s1 r1 s2 r2 = GenStateT GenContM '(s1,r1) '(s2,r2)

{-
-- | Change both the state and return types for the state-continuation monad
withAltContStateM :: (r2 qin -> r1 qin) -> (r1 qout -> r2 qout) ->
                     (s2 pout -> s1 pout) -> (s2 pout -> s1 pin -> s2 pin) ->
                     GenStateContM s1 r1 pin qin pout qout a ->
                     GenStateContM s2 r2 pin qin pout qout a
withAltContStateM f_in f_out s_get s_update m =
  gget >>>= \s ->
  glift (withAltContM f_in f_out $
         runGenStateT m $ s_get s) >>>= \(a,s') ->
  gput (s_update s s') >>>
  greturn a
-}

-- | Map both the state and return types for the state-continuation monad
gmapRetAndState :: (s2 -> s1) -> (r1 -> r2) -> GenStateContM s1 r1 s2 r2 ()
gmapRetAndState f_st f_ret =
  gmodify f_st >>> gmapRet f_ret

-- | Run two generalized monad computations "in parallel" and combine their
-- results
--
-- FIXME: figure out an elegant way to write this as a gmonad effect
gparallel :: (r1 -> r2 -> r_out) ->
             GenStateContM s_in r_in s_out r1 a ->
             GenStateContM s_in r_in s_out r2 a ->
             GenStateContM s_in r_in s_out r_out a
gparallel f m1 m2 =
  GenStateT $ \s -> GenContM $ \k ->
  f (runGenContM (unGenStateT m1 s) k) (runGenContM (unGenStateT m2 s) k)

-- | Abort the current state-continuation computation and just return an @r2@
--
-- FIXME: figure out how to write this with something like 'gcaptureCC'...? The
-- problem is that 'gcaptureCC' will not allow us to change the state type...
--
-- IDEA: maybe we can do this with gmapRet (const $ return ret)?
gabortM :: r2 -> GenStateContM s1 r1 s2 r2 a
gabortM ret = GenStateT $ \_ -> GenContM $ \_ -> ret

-- | Lift a monadic action into a generalized state-continuation monad
liftGenStateContM :: Monad m => m a -> GenStateContM s (m b) s (m b) a
liftGenStateContM m = glift $ liftGenContM m


-- | The generalized reader transformer with a monomorphic read type
newtype GenMonoReaderT r (m :: k -> k -> Type -> Type) p1 p2 a =
  GenMonoReaderT { unGenMonoReaderT :: r -> m p1 p2 a }

instance Monad (m p p) => Functor (GenMonoReaderT r m p p) where
  fmap f m = m >>= return . f

instance Monad (m p p) => Applicative (GenMonoReaderT r m p p) where
  pure = return
  (<*>) = ap

instance Monad (m p p) => Monad (GenMonoReaderT r m p p) where
  return x = GenMonoReaderT $ \_ -> return x
  (GenMonoReaderT m) >>= f =
    GenMonoReaderT $ \r -> m r >>= \a -> unGenMonoReaderT (f a) r

instance GenMonad m => GenMonad (GenMonoReaderT r m) where
  greturn x = GenMonoReaderT $ \_ -> greturn x
  (GenMonoReaderT m) >>>= f =
    GenMonoReaderT $ \r -> m r >>>= \a -> unGenMonoReaderT (f a) r

instance GenMonadT (GenMonoReaderT r) q1 q2 q1 q2 where
  glift m = GenMonoReaderT $ \_ -> m

instance GenMonadCaptureCC rin rout m q1 q2 =>
         GenMonadCaptureCC rin rout (GenMonoReaderT r m) q1 q2 where
  gcaptureCC f = glift $ gcaptureCC f

instance GenMonadGet s m q => GenMonadGet s (GenMonoReaderT r m) q where
  gget = glift gget

instance GenMonadPut s m q1 q2 => GenMonadPut s (GenMonoReaderT r m) q1 q2 where
  gput = glift . gput

class GenMonad m => GenMonadAsk r m p | m p -> r where
  gask :: m p p r

instance GenMonad m => GenMonadAsk r (GenMonoReaderT r m) p where
  gask = GenMonoReaderT $ \r -> greturn r


----------------------------------------------------------------------
-- * Permission Implication Monad
----------------------------------------------------------------------

-- FIXME HERE: instead of having a separate PPInfo and name type map, we should
-- maybe combine all the local context into one type...?

data ImplState vars ps =
  ImplState { _implStatePerms :: PermSet ps,
              _implStateVars :: CruCtx vars,
              _implStatePSubst :: PartialSubst vars,
              _implStateLifetimes :: [ExprVar LifetimeType],
              -- ^ Stack of active lifetimes, where the first element is the
              -- current lifetime (we should have an @lowned@ permission for it)
              -- and each lifetime contains (i.e., has an @lcurrent@ permission
              -- for) the next lifetime in the stack
              _implStateRecRecurseFlag :: Maybe (Either () ()),
              -- ^ Whether we are recursing under a recursive permission, either
              -- on the left hand or the right hand side
              _implStatePermEnv :: PermEnv,
              -- ^ The current permission environment
              _implStatePPInfo :: PPInfo,
              -- ^ Pretty-printing for all variables in scope
              _implStateNameTypes :: NameMap TypeRepr,
              -- ^ Types of all the variables in scope
              _implStateFailPrefix :: String,
              -- ^ A prefix string to prepend to any failure messages
              _implStateDoTrace :: Bool
              -- ^ Whether tracing is turned on or not
            }
makeLenses ''ImplState

mkImplState :: CruCtx vars -> PermSet ps -> PermEnv ->
               PPInfo -> String -> Bool -> NameMap TypeRepr ->
               ImplState vars ps
mkImplState vars perms env info fail_prefix do_trace nameTypes =
  ImplState { _implStateVars = vars,
              _implStatePerms = perms,
              _implStatePSubst = emptyPSubst vars,
              _implStateLifetimes = [],
              _implStateRecRecurseFlag = Nothing,
              _implStatePermEnv = env,
              _implStatePPInfo = info,
              _implStateNameTypes = nameTypes,
              _implStateFailPrefix = fail_prefix,
              _implStateDoTrace = do_trace
            }

extImplState :: KnownRepr TypeRepr tp => ImplState vars ps ->
                ImplState (vars :> tp) ps
extImplState s =
  s { _implStateVars = extCruCtx (_implStateVars s),
      _implStatePSubst = extPSubst (_implStatePSubst s) }

unextImplState :: ImplState (vars :> a) ps -> ImplState vars ps
unextImplState s =
  s { _implStateVars = unextCruCtx (_implStateVars s),
      _implStatePSubst = unextPSubst (_implStatePSubst s) }

-- | The implication monad is a state-continuation monad that uses 'ImplState'
type ImplM vars s r ps_out ps_in =
  GenStateContM (ImplState vars ps_out) (State (Closed s) (PermImpl r ps_out))
  (ImplState vars ps_in) (State (Closed s) (PermImpl r ps_in))


-- | Run an 'ImplM' computation by passing it a @vars@ context, a starting
-- permission set, top-level state, and a continuation to consume the output
runImplM :: CruCtx vars -> PermSet ps_in -> PermEnv -> PPInfo ->
            String -> Bool -> NameMap TypeRepr ->
            ((a, ImplState vars ps_out) -> State (Closed s) (r ps_out)) ->
            ImplM vars s r ps_out ps_in a -> State (Closed s) (PermImpl r ps_in)
runImplM vars perms env ppInfo fail_prefix do_trace nameTypes k m =
  runGenContM (runGenStateT m (mkImplState vars perms env ppInfo
                               fail_prefix do_trace nameTypes))
  (\as -> PermImpl_Done <$> k as)

-- | Embed a sub-computation in a name-binding inside another 'ImplM'
-- computation, throwing away any state from that sub-computation and returning
-- a 'PermImpl' inside a name-binding
embedMbImplM :: Mb ctx (PermSet ps_in) ->
                Mb ctx (ImplM RNil s r' ps_out ps_in (r' ps_out)) ->
                ImplM vars s r ps ps (Mb ctx (PermImpl r' ps_in))
embedMbImplM mb_ps_in mb_m =
  gget >>>= \s ->
  liftGenStateContM $
  strongMbM (mbMap2
       (\ps_in m ->
         runImplM CruCtxNil ps_in
         (view implStatePermEnv s) (view implStatePPInfo s)
         (view implStateFailPrefix s) (view implStateDoTrace s)
         (view implStateNameTypes s) (return . fst) m)
      mb_ps_in mb_m)

-- | Look up the type of an existential variable
getExVarType :: Member vars tp -> ImplM vars s r ps ps (TypeRepr tp)
getExVarType memb =
  (view implStateVars <$> gget) >>>= \varTypes ->
  greturn (cruCtxLookup varTypes memb)

-- | Look up the current partial substitution
getPSubst :: ImplM vars s r ps ps (PartialSubst vars)
getPSubst = view implStatePSubst <$> gget

-- | Look up the current pretty-printing info
getPPInfo :: ImplM vars s r ps ps PPInfo
getPPInfo = view implStatePPInfo <$> gget

-- | Add a multi-binding for the current existential variables around a value
-- (that does not use those variables)
mbVarsM :: a -> ImplM vars s r ps ps (Mb vars a)
mbVarsM a =
  (view implStateVars <$> gget) >>>= \vars ->
  greturn $ mbPure (cruCtxProxies vars) a

-- | Apply the current partial substitution to an expression, raising an error
-- with the given string if the partial substitution is not complete enough
--
-- FIXME: this should fail instead of calling 'error', and should also have more
-- regular and meaningful messages about existential variables being unresolved
partialSubstForceM :: Substable PartialSubst a Maybe => Mb vars a -> String ->
                      ImplM vars s r ps ps a
partialSubstForceM mb_e msg =
  getPSubst >>>= \psubst ->
  greturn (partialSubstForce psubst mb_e msg)

-- | Modify the current partial substitution
modifyPSubst :: (PartialSubst vars -> PartialSubst vars) ->
                ImplM vars s r ps ps ()
modifyPSubst f = gmodify (over implStatePSubst f)

-- | Set the value for an existential variable in the current substitution,
-- raising an error if it is already set
setVarM :: Member vars a -> PermExpr a -> ImplM vars s r ps ps ()
setVarM x e = modifyPSubst (psubstSet x e)

-- | Run an implication computation with one more existential variable,
-- returning the optional expression it was bound to in the current partial
-- substitution when it is done
withExtVarsM :: KnownRepr TypeRepr tp =>
                ImplM (vars :> tp) s r ps1 ps2 a ->
                ImplM vars s r ps1 ps2 (a, Maybe (PermExpr tp))
withExtVarsM m =
  withAltStateM extImplState (const unextImplState) $
  (m >>>= \a ->
    getPSubst >>>= \psubst ->
    greturn (a, psubstLookup psubst Member_Base))

-- | Get the recursive permission recursion flag
implGetRecRecurseFlag :: ImplM vars s r ps ps (Maybe (Either () ()))
implGetRecRecurseFlag = view implStateRecRecurseFlag <$> gget

-- | Perform either the first, second, or both computations with an 'implCatchM'
-- between, depending on the recursion flag
implRecFlagCaseM :: NuMatchingAny1 r => ImplM vars s r ps_out ps_in a ->
                    ImplM vars s r ps_out ps_in a ->
                    ImplM vars s r ps_out ps_in a
implRecFlagCaseM m1 m2 =
  implGetRecRecurseFlag >>>= \flag ->
  case flag of
    Just (Left ()) -> m1
    Just (Right ()) -> m2
    Nothing -> implCatchM m1 m2

-- | Set the recursive permission recursion flag to indicate recursion on the
-- right, or fail if we are already recursing on the left
implSetRecRecurseRightM :: NuMatchingAny1 r => ImplM vars s r ps ps ()
implSetRecRecurseRightM =
  gget >>>= \s ->
  case view implStateRecRecurseFlag s of
    Just (Left ()) ->
      implFailMsgM "Tried to unfold a mu on the right after unfolding on the left"
    _ -> gmodify (set implStateRecRecurseFlag (Just (Right ())))

-- | Set the recursive recursion flag to indicate recursion on the left, or fail
-- if we are already recursing on the right
implSetRecRecurseLeftM :: NuMatchingAny1 r => ImplM vars s r ps ps ()
implSetRecRecurseLeftM =
  gget >>>= \s ->
  case view implStateRecRecurseFlag s of
    Just (Right ()) ->
      implFailMsgM "Tried to unfold a mu on the left after unfolding on the right"
    _ -> gmodify (set implStateRecRecurseFlag (Just (Left ())))

-- | Look up the 'NamedPerm' structure for a named permssion
implLookupNamedPerm :: NamedPermName ns args a ->
                       ImplM vars s r ps ps (NamedPerm ns args a)
implLookupNamedPerm npn =
  (view implStatePermEnv <$> gget) >>>= \env ->
  case lookupNamedPerm env npn of
    Just np -> greturn np
    Nothing -> error ("Named permission " ++ namedPermNameName npn
                      ++ " not defined!")

-- | Get the current 'PermSet'
getPerms :: ImplM vars s r ps ps (PermSet ps)
getPerms = view implStatePerms <$> gget

-- | Look up the current permission for a given variable
getPerm :: ExprVar a -> ImplM vars s r ps ps (ValuePerm a)
getPerm x = view (implStatePerms . varPerm x) <$> gget

-- | Get the pointer permissions for a variable @x@, assuming @x@ has LLVM
-- pointer permissions
getLLVMPtrPerms :: ExprVar (LLVMPointerType w) ->
                   ImplM vars s r ps ps [LLVMPtrPerm w]
getLLVMPtrPerms x =
  view (implStatePerms . varPerm x . llvmPtrPerms) <$> gget

-- | Get the distinguished permission stack
getDistPerms :: ImplM vars s r ps ps (DistPerms ps)
getDistPerms = view (implStatePerms . distPerms) <$> gget

-- | Get the top permission in the stack
getTopDistPerm :: ExprVar a -> ImplM vars s r (ps :> a) (ps :> a) (ValuePerm a)
getTopDistPerm x = view (implStatePerms . topDistPerm x) <$> gget

-- | Set the current 'PermSet'
setPerms :: PermSet ps -> ImplM vars s r ps ps ()
setPerms perms = modify $ set (implStatePerms) perms

-- | Set the current permission for a given variable
setPerm :: ExprVar a -> ValuePerm a -> ImplM vars s r ps ps ()
setPerm x p = modify $ set (implStatePerms . varPerm x) p

-- | Get the current lifetime
getCurLifetime :: ImplM vars s r ps ps (ExprVar LifetimeType)
getCurLifetime =
  (view implStateLifetimes <$> gget) >>>= \ls ->
  case ls of
    l:_ -> greturn l
    [] -> error "getCurLifetime: no current lifetime!"

-- | Push a lifetime onto the lifetimes stack
pushLifetime :: ExprVar LifetimeType -> ImplM vars s r ps ps ()
pushLifetime l = gmodify (over implStateLifetimes (l:))

-- | Pop a lifetime off of the lifetimes stack
popLifetime :: ImplM vars s r ps ps (ExprVar LifetimeType)
popLifetime =
  getCurLifetime >>>= \l ->
  gmodify (over implStateLifetimes tail) >>>
  greturn l

-- | Push (as in 'implPushM') the permission for the current lifetime
implPushCurLifetimePermM :: NuMatchingAny1 r => ExprVar LifetimeType ->
                            ImplM vars s r (ps :> LifetimeType) ps ()
implPushCurLifetimePermM l =
  getCurLifetime >>>= \l' ->
  (if l == l' then greturn () else
     error "implPushLifetimePermM: wrong value for the current lifetime!") >>>
  getPerm l >>>= \p ->
  case p of
    ValPerm_Conj [Perm_LOwned _] -> implPushM l p
    _ -> error "implPushLifetimePermM: no LOwned permission for the current lifetime!"

-- | Pop (as in 'implPushM') the permission for the current lifetime
implPopCurLifetimePermM :: NuMatchingAny1 r => ExprVar LifetimeType ->
                           ImplM vars s r ps (ps :> LifetimeType) ()
implPopCurLifetimePermM l =
  getCurLifetime >>>= \l' ->
  (if l == l' then greturn () else
     error "implPopLifetimePermM: wrong value for the current lifetime!") >>>
  getTopDistPerm l >>>= \p ->
  case p of
    ValPerm_Conj [Perm_LOwned _] -> implPopM l p
    _ -> error "implPopLifetimePermM: no LOwned permission for the current lifetime!"

{- FIXME: this should no longer be needed!
-- | Map the final return value and the current permissions
gmapRetAndPerms :: (PermSet ps2 -> PermSet ps1) ->
                   (PermImpl r ps1 -> PermImpl r ps2) ->
                   ImplM vars s r ps1 ps2 ()
gmapRetAndPerms f_perms f_impl =
  gmapRetAndState (over implStatePerms f_perms) f_impl
-}


-- | Look up the type of a free variable
implGetVarType :: Name a -> ImplM vars s r ps ps (TypeRepr a)
implGetVarType n =
  (view implStateNameTypes <$> gget) >>>= \varTypes ->
  case NameMap.lookup n varTypes of
    Just tp -> greturn tp
    Nothing ->
      implTraceM (\i -> string "Could not find type for variable:" <+>
                        permPretty i n) >>>
      error "implGetVarType"

-- | Find the first variable of a specific type
implFindVarOfType :: TypeRepr a -> ImplM vars s r ps ps (Maybe (Name a))
implFindVarOfType tp =
  (view implStateNameTypes <$> gget) >>>= \varTypes ->
  return (foldr (\(NameAndElem n tp') rest ->
                  case testEquality tp tp' of
                    Just Refl -> return n
                    Nothing -> rest) Nothing
          (NameMap.assocs varTypes))

-- | Remember the types associated with a list of 'Name's, and also ensure those
-- names have permissions
implSetNameTypes :: RAssign Name ctx -> CruCtx ctx -> ImplM vars s r ps ps ()
implSetNameTypes MNil _ = greturn ()
implSetNameTypes (ns :>: n) (CruCtxCons tps tp) =
  gmodify (over implStateNameTypes $ NameMap.insert n tp) >>
  gmodify (over implStatePerms $ initVarPerm n) >>
  implSetNameTypes ns tps


----------------------------------------------------------------------
-- * The Permission Implication Rules as Monadic Operations
----------------------------------------------------------------------

-- | An 'ImplM' continuation for a permission implication rule
newtype Impl1Cont vars s r ps_r a bs_ps =
  Impl1Cont (RAssign Name (Fst bs_ps) -> ImplM vars s r ps_r (Snd bs_ps) a)

-- | Apply a permission implication rule, with the given continuations in the
-- possible disjunctive branches of the result
implApplyImpl1 :: NuMatchingAny1 r => PermImpl1 ps_in ps_outs ->
                  RAssign (Impl1Cont vars s r ps_r a) ps_outs ->
                  ImplM vars s r ps_r ps_in a
implApplyImpl1 impl1 mb_ms =
  getPerms >>>= \perms ->
  (view implStatePPInfo <$> gget) >>>= \pp_info ->
  gmapRet (permImplStep impl1 <$>) >>>
  helper (applyImpl1 pp_info impl1 perms) mb_ms
  where
    helper :: MbPermSets ps_outs ->
              RAssign (Impl1Cont vars s r ps_r a) ps_outs ->
              GenStateContM (ImplState vars ps_r)
              (State (Closed s) (PermImpl r ps_r))
              (ImplState vars ps_in)
              (State (Closed s) (MbPermImpls r ps_outs)) a
    helper MbPermSets_Nil _ = gabortM (return MbPermImpls_Nil)
    helper (MbPermSets_Cons mbperms ctx mbperm) (args :>: Impl1Cont f) =
      gparallel (\m1 m2 -> MbPermImpls_Cons <$> m1 <*> m2)
      (helper mbperms args)
      (gopenBinding strongMbM mbperm >>>= \(ns, perms') ->
        gmodify (set implStatePerms perms' .
                 over implStatePPInfo (ppInfoAddExprNames "z" ns)) >>>
        implSetNameTypes ns ctx >>>
        f ns)

-- | Emit debugging output using the current 'PPInfo'
implTraceM :: (PPInfo -> Doc) -> ImplM vars s r ps ps String
implTraceM f =
  (view implStateDoTrace <$> gget) >>>= \do_trace ->
  (f <$> view implStatePPInfo <$> gget) >>>= \doc ->
  let str = renderDoc doc in fn do_trace str (greturn str)
  where fn True  = trace
        fn False = const id

-- | Terminate the current proof branch with a failure
implFailM :: NuMatchingAny1 r => String -> ImplM vars s r ps_any ps a
implFailM str =
  (view implStateFailPrefix <$> gget) >>>= \prefix ->
  implTraceM (const $ string (prefix ++ "Implication failed")) >>>
  implApplyImpl1 (Impl1_Fail (prefix ++ str)) MNil

-- | Call 'implFailM' and also output a debugging message
implFailMsgM :: NuMatchingAny1 r => String -> ImplM vars s r ps_any ps a
implFailMsgM msg =
  implTraceM (const $ string msg) >>>= implFailM

-- | Pretty print an implication @x:p -o (vars).p'@
ppImpl :: PPInfo -> ExprVar tp -> ValuePerm tp ->
          Mb (vars :: RList CrucibleType) (ValuePerm tp) -> Doc
ppImpl i x p mb_p =
  sep [permPretty i x <> colon <> align (permPretty i p),
       string "-o",
       align (permPretty i mb_p)]

-- | Terminate the current proof branch with a failure proving @x:p -o mb_p@
implFailVarM :: NuMatchingAny1 r => String -> ExprVar tp -> ValuePerm tp ->
                Mb vars (ValuePerm tp) -> ImplM vars s r ps_any ps a
implFailVarM f x p mb_p =
  implTraceM (\i ->
               sep [string f <> colon <+> string "Could not prove",
                    ppImpl i x p mb_p]) >>>=
  implFailM

-- | Produce a branching proof tree that performs the first implication and, if
-- that one fails, falls back on the second. If 'pruneFailingBranches' is set,
-- failing branches are pruned.
implCatchM :: NuMatchingAny1 r =>
              ImplM vars s r ps1 ps2 a -> ImplM vars s r ps1 ps2 a ->
              ImplM vars s r ps1 ps2 a
implCatchM m1 m2 =
  implApplyImpl1 Impl1_Catch (MNil :>: Impl1Cont (const m1)
                              :>: Impl1Cont (const m2))

-- | "Push" all of the permissions in the permission set for a variable, which
-- should be equal to the supplied permission, after deleting those permissions
-- from the input permission set. This is like a simple "proof" of @x:p@.
implPushM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
             ImplM vars s r (ps :> a) ps ()
implPushM x p =
  implApplyImpl1 (Impl1_Push x p) (MNil :>: Impl1Cont (const $ greturn ()))

-- | Call 'implPushM' for multiple @x:p@ permissions
implPushMultiM :: NuMatchingAny1 r => DistPerms ps -> ImplM vars s r ps RNil ()
implPushMultiM DistPermsNil = greturn ()
implPushMultiM (DistPermsCons ps x p) =
  implPushMultiM ps >>> implPushM x p

-- | For each permission @x:p@ in a list of permissions, either prove @x:eq(x)@
-- by reflexivity if @p=eq(x)@ or push @x:p@ if @x@ has permissions @p@
implPushOrReflMultiM :: NuMatchingAny1 r => DistPerms ps ->
                        ImplM vars s r ps RNil ()
implPushOrReflMultiM DistPermsNil = greturn ()
implPushOrReflMultiM (DistPermsCons ps x (ValPerm_Eq (PExpr_Var x')))
  | x == x' = implPushOrReflMultiM ps >>> introEqReflM x
implPushOrReflMultiM (DistPermsCons ps x p) =
  implPushOrReflMultiM ps >>> implPushM x p

-- | Pop a permission from the top of the stack back to the primary permission
-- for a variable, assuming that the primary permission for that variable is
-- empty, i.e., is the @true@ permission
implPopM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
            ImplM vars s r ps (ps :> a) ()
implPopM x p =
  implApplyImpl1 (Impl1_Pop x p) (MNil :>: Impl1Cont (const $ greturn ()))

-- | Eliminate a disjunctive permission @x:(p1 \/ p2)@, building proof trees
-- that proceed with both @x:p1@ and @x:p2@
implElimOrM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a -> ValuePerm a ->
               ImplM vars s r (ps :> a) (ps :> a) ()
implElimOrM x p1 p2 =
  implTraceM (\pp_info -> string "Eliminating or:" <+>
                          permPretty pp_info (ValPerm_Or p1 p2)) >>>
  implApplyImpl1 (Impl1_ElimOr x p1 p2)
  (MNil :>: Impl1Cont (const $ greturn ()) :>: Impl1Cont (const $ greturn ()))

-- | Eliminate an existential permission @x:(exists (y:tp).p)@ in the current
-- permission set
implElimExistsM :: (NuMatchingAny1 r, KnownRepr TypeRepr tp) =>
                   ExprVar a -> Binding tp (ValuePerm a) ->
                   ImplM vars s r (ps :> a) (ps :> a) ()
implElimExistsM x p =
  implApplyImpl1 (Impl1_ElimExists x p)
  (MNil :>: Impl1Cont (const $ greturn ()))

-- | Apply a simple implication rule to the top permissions on the stack
implSimplM :: NuMatchingAny1 r => Proxy ps -> SimplImpl ps_in ps_out ->
              ImplM vars s r (ps :++: ps_out) (ps :++: ps_in) ()
implSimplM prx simpl =
  implApplyImpl1 (Impl1_Simpl simpl prx)
  (MNil :>: Impl1Cont (const $ greturn ()))

-- | Bind a new variable @x@ that is set to the supplied expression @e@, and
-- push permissions @x:eq(e)@. Return @x@.
implLetBindVar :: NuMatchingAny1 r => TypeRepr tp -> PermExpr tp ->
                  ImplM vars s r (ps :> tp) ps (Name tp)
implLetBindVar tp e =
  implApplyImpl1 (Impl1_LetBind tp e)
  (MNil :>: Impl1Cont (\(_ :>: n) -> greturn n))

-- | Eliminate a permission @x:ptr((rw,off) |-> p)@ into permissions
-- @x:ptr((rw,off) |-> eq(y))@ and @y:p@ for a fresh variable @y@, returning the
-- fresh variable @y@ and popping the @y@ permissions off the stack. If @p@
-- already has the form @eq(y)@, then just return @y@.
implElimLLVMFieldContentsM ::
  (NuMatchingAny1 r, 1 <= w, KnownNat w, 1 <= sz, KnownNat sz) =>
  ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w)
  (ExprVar (LLVMPointerType sz))
implElimLLVMFieldContentsM _ fp
  | ValPerm_Eq (PExpr_Var y) <- llvmFieldContents fp
  = greturn y
implElimLLVMFieldContentsM x fp =
  implApplyImpl1 (Impl1_ElimLLVMFieldContents x fp)
  (MNil :>: Impl1Cont (\(_ :>: n) -> greturn n)) >>>= \y ->
  implPopM y (llvmFieldContents fp) >>>
  greturn y

-- | Try to prove a proposition about bitvectors dynamically, failing as in
-- 'implFailM' if the proposition does not hold
implTryProveBVProp :: (1 <= w, KnownNat w, NuMatchingAny1 r) =>
                      ExprVar (LLVMPointerType w) -> BVProp w ->
                      ImplM vars s r (ps :> LLVMPointerType w) ps ()
implTryProveBVProp x p =
  getPPInfo >>>= \i ->
  let str = renderDoc (permPretty i p) in
  implApplyImpl1 (Impl1_TryProveBVProp x p str)
  (MNil :>: Impl1Cont (const $ greturn ()))

-- | Try to prove a sequence of propositions using 'implTryProveBVProp'
implTryProveBVProps :: (1 <= w, KnownNat w, NuMatchingAny1 r) =>
                       ExprVar (LLVMPointerType w) -> [BVProp w] ->
                       ImplM vars s r (ps :> LLVMPointerType w) ps ()
implTryProveBVProps x [] = introConjM x
implTryProveBVProps x (prop:props) =
  implTryProveBVProp x prop >>>
  implTryProveBVProps x props >>>
  implInsertConjM x (Perm_BVProp prop) (map Perm_BVProp props) 0

-- | Drop a permission from the top of the stack
implDropM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
             ImplM vars s r ps (ps :> a) ()
implDropM x p = implSimplM Proxy (SImpl_Drop x p)

-- | Copy a permission on the top of the stack, assuming it is copyable
implCopyM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
             ImplM vars s r (ps :> a :> a) (ps :> a) ()
implCopyM x p = implSimplM Proxy (SImpl_Copy x p)

-- | Swap the top two permissions on the top of the stack
implSwapM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
             ExprVar b -> ValuePerm b ->
             ImplM vars s r (ps :> b :> a) (ps :> a :> b) ()
implSwapM x p1 y p2 = implSimplM Proxy (SImpl_Swap x p1 y p2)

-- FIXME: move to Hobbits
appendRNilConsEq :: prx1 ps1 -> prx_a a -> RAssign f ps2 ->
                    (ps1 :++: (RNil :> a :++: ps2)) :~: (ps1 :> a :++: ps2)
appendRNilConsEq _ _ MNil = Refl
appendRNilConsEq ps1 a (ps2 :>: _)
  | Refl <- appendRNilConsEq ps1 a ps2 = Refl

-- | Move permission @p@ that is on the stack below two lists @ps1@ and @ps2@
-- towards the top of the stack by moving it between @ps1@ and @ps2@. That is,
-- change the stack
--
-- > perms, p, p1_1, ..., p1_n, p2_1, ..., p2_m
--
-- to
--
-- > perms, p1_1, ..., p1_n, p, p2_1, ..., p2_m
implMoveUpM ::
  NuMatchingAny1 r =>
  prx ps -> RAssign f ps1 -> ExprVar a -> RAssign f ps2 ->
  ImplM vars s r (ps :++: ps1 :> a :++: ps2) (ps :> a :++: ps1 :++: ps2) ()
implMoveUpM (ps :: prx ps) ps1 (x :: ExprVar a) ps2 =
  -- FIXME: this is gross! Find a better way to do all this!
  getDistPerms >>>= \perms ->
  let (perms0x, perms12) =
        splitDistPerms (Proxy :: Proxy (ps :> a)) (RL.append ps1 ps2) perms
      (perms1, perms2) = splitDistPerms ps1 ps2 perms12 in
  case (perms0x, appendRNilConsEq ps x (RL.append ps1 ps2)) of
    (DistPermsCons perms0 x' p, Refl)
      | Just Refl <- testEquality x x' ->
        implSimplM (Proxy :: Proxy ps) (SImpl_MoveUp perms1 x p perms2)
    (DistPermsCons _ x' _, _) -> error "implMoveUpM: unexpected variable"

-- | Eliminate disjunctives and existentials on the top of the stack and return
-- the resulting permission
elimOrsExistsM :: NuMatchingAny1 r => ExprVar a ->
                  ImplM vars s r (ps :> a) (ps :> a) (ValuePerm a)
elimOrsExistsM x =
  getTopDistPerm x >>>= \p ->
  case p of
    ValPerm_Or p1 p2 -> implElimOrM x p1 p2 >>> elimOrsExistsM x
    ValPerm_Exists mb_p ->
      implElimExistsM x mb_p >>> elimOrsExistsM x
    _ -> greturn p

-- | Eliminate disjunctives, existentials, recusive permissions, and
-- defined permissions on the top of the stack
elimOrsExistsNamesM :: NuMatchingAny1 r => ExprVar a ->
                       ImplM vars s r (ps :> a) (ps :> a) (ValuePerm a)
elimOrsExistsNamesM x =
  getTopDistPerm x >>>= \p ->
  case p of
    ValPerm_Or p1 p2 -> implElimOrM x p1 p2 >>> elimOrsExistsM x
    ValPerm_Exists mb_p ->
      implElimExistsM x mb_p >>> elimOrsExistsM x
    ValPerm_Named npn args off ->
      case nameCanFoldRepr npn of
        TrueRepr -> implUnfoldNamedM x npn args off >>> elimOrsExistsNamesM x
        FalseRepr -> greturn p
    _ -> greturn p

-- | Eliminate any disjunctions, existentials, recursive permissions, or
-- defined permissions for a variable and then return the resulting "simple"
-- permission
getSimpleVarPerm :: NuMatchingAny1 r => ExprVar a ->
                    ImplM vars s r ps ps (ValuePerm a)
getSimpleVarPerm x =
  getPerm x >>>= \p_init ->
  implPushM x p_init >>>
  elimOrsExistsNamesM x >>>= \p ->
  implPopM x p >>> greturn p

-- | Eliminate any disjunctions, existentials, recursive permissions, or
-- defined permissions for any variables in the supplied expression and
-- substitute any equality permissions for those variables
getEqualsExpr :: NuMatchingAny1 r => PermExpr a ->
                 ImplM vars s r ps ps (PermExpr a)
getEqualsExpr e@(PExpr_Var x) =
  getSimpleVarPerm x >>>= \p ->
  case p of
    ValPerm_Eq e' -> getEqualsExpr e'
    _ -> greturn e
getEqualsExpr (PExpr_BV factors off) =
  foldr bvAdd (PExpr_BV [] off) <$>
  mapM (\(BVFactor (BV.BV i) x) ->
         bvMult i <$> getEqualsExpr (PExpr_Var x)) factors
getEqualsExpr (PExpr_LLVMWord e) =
  PExpr_LLVMWord <$> getEqualsExpr e
getEqualsExpr (PExpr_LLVMOffset x off) =
  getEqualsExpr (PExpr_Var x) >>>= \e ->
  getEqualsExpr off >>>= \off' ->
  greturn (addLLVMOffset e off)
getEqualsExpr e = greturn e


-- | Introduce a proof of @x:eq(x)@ onto the top of the stack
introEqReflM :: NuMatchingAny1 r => ExprVar a -> ImplM vars s r (ps :> a) ps ()
introEqReflM x = implSimplM Proxy (SImpl_IntroEqRefl x)

-- | Invert a proof of @x:eq(y)@ on the top of the stack to one of @y:eq(x)@
invertEqM :: NuMatchingAny1 r => ExprVar a -> ExprVar a ->
             ImplM vars s r (ps :> a) (ps :> a) ()
invertEqM x y = implSimplM Proxy (SImpl_InvertEq x y)

-- | Prove @x:eq(y)@ by proving equality permissions for both @x@ and @y@ to the
-- same expression, thereby implementing a form of transitivity of equality
-- where the second equality is inversted:
invTransEqM :: NuMatchingAny1 r => ExprVar a -> ExprVar a -> PermExpr a ->
               ImplM vars s r (ps :> a) (ps :> a :> a) ()
invTransEqM x y e = implSimplM Proxy (SImpl_InvTransEq x y e)

-- | Copy an @x:eq(e)@ permission on the top of the stack
introEqCopyM :: NuMatchingAny1 r => ExprVar a -> PermExpr a ->
                ImplM vars s r (ps :> a :> a) (ps :> a) ()
introEqCopyM x e = implSimplM Proxy (SImpl_CopyEq x e)

-- | Cast an @eq(llvmword(y))@ proof to an @eq(llvmword(e))@ proof using a
-- proof of @y:eq(e)@
llvmWordEqM :: (1 <= w, KnownNat w, NuMatchingAny1 r) =>
               ExprVar (LLVMPointerType w) ->
               ExprVar (BVType w) -> PermExpr (BVType w) ->
               ImplM vars s r (ps :> LLVMPointerType w)
               (ps :> LLVMPointerType w :> BVType w) ()
llvmWordEqM x y e = implSimplM Proxy (SImpl_LLVMWordEq x y e)

-- | Cast a @y:p@ perm on the top of the stack to an @x:p@ perm using an
-- @x:eq(y)@ just below it on the stack
introCastM :: NuMatchingAny1 r => ExprVar a -> ExprVar a -> ValuePerm a ->
              ImplM vars s r (ps :> a) (ps :> a :> a) ()
introCastM x y p = implSimplM Proxy (SImpl_Cast x y p)

-- | Introduce a proof of @x:true@ onto the top of the stack, which is the same
-- as an empty conjunction
introConjM :: NuMatchingAny1 r => ExprVar a -> ImplM vars s r (ps :> a) ps ()
introConjM x = implSimplM Proxy (SImpl_IntroConj x)

-- | Delete the @i@th atomic permission in the conjunct on the top of the stack,
-- assuming that conjunction contains the given atomic permissions, and put the
-- extracted atomic permission just below the top of the stack
implExtractConjM :: NuMatchingAny1 r => ExprVar a -> [AtomicPerm a] -> Int ->
                    ImplM vars s r (ps :> a :> a) (ps :> a) ()
implExtractConjM x ps i = implSimplM Proxy (SImpl_ExtractConj x ps i)

-- | Combine the top two conjunctive permissions on the stack
implAppendConjsM :: NuMatchingAny1 r => ExprVar a ->
                    [AtomicPerm a] -> [AtomicPerm a] ->
                    ImplM vars s r (ps :> a) (ps :> a :> a) ()
implAppendConjsM x ps1 ps2 = implSimplM Proxy (SImpl_AppendConjs x ps1 ps2)

-- | Split the conjuctive permissions on the top of the stack into the first @i@
-- and the remaining conjuncts after those
implSplitConjsM :: NuMatchingAny1 r => ExprVar a -> [AtomicPerm a] -> Int ->
                   ImplM vars s r (ps :> a :> a) (ps :> a) ()
implSplitConjsM x ps i = implSimplM Proxy (SImpl_SplitConjs x ps i)

-- | Copy @i@th atomic permission in the conjunct on the top of the stack,
-- assuming that conjunction contains the given atomic permissions and that the
-- given conjunct is copyable, and put the copied atomic permission just below
-- the top of the stack
implCopyConjM :: NuMatchingAny1 r => ExprVar a -> [AtomicPerm a] -> Int ->
                 ImplM vars s r (ps :> a :> a) (ps :> a) ()
implCopyConjM x ps i = implSimplM Proxy (SImpl_CopyConj x ps i)

-- | Insert an atomic permission below the top of the stack at the @i@th
-- position in the conjunct on the top of the stack, where @i@ must be between
implInsertConjM :: NuMatchingAny1 r => ExprVar a ->
                   AtomicPerm a -> [AtomicPerm a] -> Int ->
                   ImplM vars s r (ps :> a) (ps :> a :> a) ()
implInsertConjM x p ps i = implSimplM Proxy (SImpl_InsertConj x p ps i)

-- | Apply the left or-introduction rule to the top of the permission stack,
-- changing it from @x:p1@ to @x:(p1 \/ p2)@
introOrLM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a -> ValuePerm a ->
             ImplM vars s r (ps :> a) (ps :> a) ()
introOrLM x p1 p2 = implSimplM Proxy (SImpl_IntroOrL x p1 p2)

-- | Apply the right or-introduction rule to the top of the permission stack,
-- changing it from @x:p2@ to @x:(p1 \/ p2)@
introOrRM :: NuMatchingAny1 r => ExprVar a -> ValuePerm a -> ValuePerm a ->
             ImplM vars s r (ps :> a) (ps :> a) ()
introOrRM x p1 p2 = implSimplM Proxy (SImpl_IntroOrR x p1 p2)

-- | Apply existential introduction to the top of the permission stack, changing
-- it from @[e/x]p@ to @exists (x:tp).p@
--
-- FIXME: is there some way we could "type-check" this, to ensure that the
-- permission on the top of the stack really equals @[e/x]p@?
introExistsM :: (KnownRepr TypeRepr tp, NuMatchingAny1 r) =>
                ExprVar a -> PermExpr tp -> Binding tp (ValuePerm a) ->
                ImplM vars s r (ps :> a) (ps :> a) ()
introExistsM x e p_body = implSimplM Proxy (SImpl_IntroExists x e p_body)

-- | Cast a proof of @x:eq(LLVMWord(e1))@ to @x:eq(LLVMWord(e2))@ on the top of
-- the stack
castLLVMWordEqM ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> PermExpr (BVType w) -> PermExpr (BVType w) ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w) ()
castLLVMWordEqM x e1 e2 =
  implTryProveBVProp x (BVProp_Eq e1 e2) >>>
  implSimplM Proxy (SImpl_CastLLVMWord x e1 e2)

-- | Cast a @y:p@ on the top of the stack to @x:(p - off)@ using a
-- proof of @x:eq(y+off)@ just below it on the stack
castLLVMPtrM :: (1 <= w, KnownNat w, NuMatchingAny1 r) =>
                ExprVar (LLVMPointerType w) ->
                ValuePerm (LLVMPointerType w) -> PermExpr (BVType w) ->
                ExprVar (LLVMPointerType w) ->
                ImplM vars s r (ps :> LLVMPointerType w)
                (ps :> LLVMPointerType w :> LLVMPointerType w) ()
castLLVMPtrM y p off x = implSimplM Proxy (SImpl_CastLLVMPtr y p off x)

-- | Cast a @y:eq(word(e))@ on the top of the stack to @x:eq(word(e+off))@ using
-- a proof of @x:eq(y+off)@ just below it on the stack
offsetLLVMWordM :: (1 <= w, KnownNat w, NuMatchingAny1 r) =>
                   ExprVar (LLVMPointerType w) ->
                   PermExpr (BVType w) -> PermExpr (BVType w) ->
                   ExprVar (LLVMPointerType w) ->
                   ImplM vars s r (ps :> LLVMPointerType w)
                   (ps :> LLVMPointerType w :> LLVMPointerType w) ()
offsetLLVMWordM y e off x = implSimplM Proxy (SImpl_OffsetLLVMWord y e off x)

-- | Cast a proof of @x:free(e1)@ on the top of the stack to one of @x:free(e2)@
-- by first proving that @e1=e2@
castLLVMFreeM :: (1 <= w, KnownNat w, NuMatchingAny1 r) =>
                 ExprVar (LLVMPointerType w) ->
                 PermExpr (BVType w) -> PermExpr (BVType w) ->
                 ImplM vars s r (ps :> LLVMPointerType w)
                 (ps :> LLVMPointerType w) ()
castLLVMFreeM x e1 e2 =
  implTryProveBVProp x (BVProp_Eq e1 e2) >>>
  implSimplM Proxy (SImpl_CastLLVMFree x e1 e2)

-- | Fold a named permission (other than an opaque permission)
implFoldNamedM :: (NameSortCanFold ns ~ 'True, NuMatchingAny1 r) => ExprVar a ->
                  NamedPermName ns args a -> PermExprs args -> PermOffset a ->
                  ImplM vars s r (ps :> a) (ps :> a) ()
implFoldNamedM x npn args off =
  implLookupNamedPerm npn >>>= \np ->
  implSimplM Proxy (SImpl_FoldNamed x np args off)

-- | Unfold a named permission (other than an opaque permission), returning the
-- unfolding
implUnfoldNamedM :: (NameSortCanFold ns ~ 'True, NuMatchingAny1 r) =>
                    ExprVar a -> NamedPermName ns args a ->
                    PermExprs args -> PermOffset a ->
                    ImplM vars s r (ps :> a) (ps :> a) (ValuePerm a)
implUnfoldNamedM x npn args off =
  implLookupNamedPerm npn >>>= \np ->
  implSimplM Proxy (SImpl_UnfoldNamed x np args off) >>>
  greturn (unfoldPerm np args off)

-- | Map a named permission that is conjoinable to a conjunction
implNamedToConjM :: (NameSortIsConj ns ~ 'True, NuMatchingAny1 r) =>
                    ExprVar a -> NamedPermName ns args a ->
                    PermExprs args -> PermOffset a ->
                    ImplM vars s r (ps :> a) (ps :> a) ()
implNamedToConjM x npn args off =
  implSimplM Proxy (SImpl_NamedToConj x npn args off)

-- | Map a conjuctive named permission to a named permission
implNamedFromConjM :: (NameSortIsConj ns ~ 'True, NuMatchingAny1 r) =>
                      ExprVar a -> NamedPermName ns args a -> PermExprs args ->
                      PermOffset a -> ImplM vars s r (ps :> a) (ps :> a) ()
implNamedFromConjM x npn args off =
  implSimplM Proxy (SImpl_NamedFromConj x npn args off)

-- | FIXME: document this!
implSplitLifetimeM :: (KnownRepr TypeRepr a, NuMatchingAny1 r) =>
                      ExprVar a -> ValuePerm a -> ExprVar LifetimeType ->
                      ImplM vars s r (ps :> a :> LifetimeType)
                      (ps :> a :> LifetimeType) ()
implSplitLifetimeM x p l =
  getTopDistPerm l >>>= \lp ->
  case lp of
    ValPerm_Conj [Perm_LOwned ps] ->
      implSimplM Proxy (SImpl_SplitLifetime x p l ps)
    _ -> error "implSplitLifetimeM: top permission is not an lowned permission"

-- | Combine proofs of @x:ptr(pps,(off,spl) |-> eq(y))@ and @y:p@ on the top of
-- the permission stack into a proof of @x:ptr(pps,(off,spl |-> p))@
introLLVMFieldContentsM ::
  (1 <= w, KnownNat w, 1 <= sz, KnownNat sz, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> ExprVar (LLVMPointerType sz) ->
  LLVMFieldPerm w sz ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w :>
                                            LLVMPointerType sz) ()
introLLVMFieldContentsM x y fp =
  implSimplM Proxy (SImpl_IntroLLVMFieldContents x y fp)

-- | Borrow a field from an LLVM array permission on the top of the stack, after
-- proving (with 'implTryProveBVProps') that the index is in the array exclusive
-- of any outstanding borrows (see 'llvmArrayIndexInArray'). Return the
-- resulting array permission with the borrow and the borrowed field permission.
implLLVMArrayIndexBorrow ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayIndex w ->
  ImplM vars s r (ps :> LLVMPointerType w :> LLVMPointerType w)
  (ps :> LLVMPointerType w) (LLVMArrayPerm w, LLVMArrayField w)
implLLVMArrayIndexBorrow x ap ix =
  implTryProveBVProps x (llvmArrayIndexInArray ap ix) >>>
  implSimplM Proxy (SImpl_LLVMArrayIndexBorrow x ap ix) >>>
  greturn (llvmArrayAddBorrow (FieldBorrow ix) ap,
           llvmArrayFieldWithOffset ap ix)

-- | Copy a field from an LLVM array permission on the top of the stack, after
-- proving (with 'implTryProveBVProps') that the index is in the array exclusive
-- of any outstanding borrows (see 'llvmArrayIndexInArray')
implLLVMArrayIndexCopy ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayIndex w ->
  ImplM vars s r (ps :> LLVMPointerType w
                  :> LLVMPointerType w) (ps :> LLVMPointerType w) ()
implLLVMArrayIndexCopy x ap ix =
  implTryProveBVProps x (llvmArrayIndexInArray ap ix) >>>
  implSimplM Proxy (SImpl_LLVMArrayIndexCopy x ap ix)

-- | Return a field permission that has been borrowed from an array permission,
-- where the field permission is on the top of the stack and the array
-- permission is just below it
implLLVMArrayIndexReturn ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayIndex w ->
  ImplM vars s r (ps :> LLVMPointerType w)
  (ps :> LLVMPointerType w :> LLVMPointerType w) ()
implLLVMArrayIndexReturn x ap ix =
  implSimplM Proxy (SImpl_LLVMArrayIndexReturn x ap ix)

-- | Borrow a sub-array from an array as per 'SImpl_LLVMArrayBorrow'
implLLVMArrayBorrow ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w :> LLVMPointerType w)
  (ps :> LLVMPointerType w) ()
implLLVMArrayBorrow x ap sub_ap =
  implTryProveBVProps x (llvmArrayContainsArray ap sub_ap) >>>
  implSimplM Proxy (SImpl_LLVMArrayBorrow x ap sub_ap)

-- | Copy a sub-array from an array as per 'SImpl_LLVMArrayCopy'
implLLVMArrayCopy ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w :> LLVMPointerType w)
  (ps :> LLVMPointerType w) ()
implLLVMArrayCopy x ap sub_ap =
  implTryProveBVProps x (llvmArrayContainsArray ap sub_ap) >>>
  implSimplM Proxy (SImpl_LLVMArrayCopy x ap sub_ap)

-- | Return a borrowed sub-array to an array as per 'SImpl_LLVMArrayReturn', and
-- return the new array permission after the return that is now on the top of
-- the stack
implLLVMArrayReturn ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w)
  (ps :> LLVMPointerType w :> LLVMPointerType w)
  (LLVMArrayPerm w)
implLLVMArrayReturn x ap ret_ap =
  implSimplM Proxy (SImpl_LLVMArrayReturn x ap ret_ap) >>>
  greturn (llvmArrayRemBorrow (llvmSubArrayBorrow ap ret_ap) $
           llvmArrayAddArrayBorrows ap ret_ap)

-- | Add a borrow to an LLVM array permission, failing if that is not possible
-- because the borrow is not in range of the array. The permission that is
-- borrowed is left on top of the stack and returned as a return value.
implLLVMArrayBorrowBorrow ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayBorrow w ->
  ImplM vars s r (ps :> LLVMPointerType w :> LLVMPointerType w)
  (ps :> LLVMPointerType w) (ValuePerm (LLVMPointerType w))
implLLVMArrayBorrowBorrow x ap (FieldBorrow ix) =
  implLLVMArrayIndexBorrow x ap ix >>>= \(_,field) ->
  greturn $ ValPerm_Conj1 $ llvmArrayFieldToAtomicPerm field
implLLVMArrayBorrowBorrow x ap b@(RangeBorrow rng) =
  let p = permForLLVMArrayBorrow ap b
      ValPerm_Conj1 (Perm_LLVMArray sub_ap) = p
      ap' = llvmArrayAddBorrow b ap in
  implLLVMArrayBorrow x ap sub_ap >>>
  implSwapM x p x (ValPerm_Conj1 $ Perm_LLVMArray ap) >>>
  greturn p

-- | Return a borrow to an LLVM array permission, assuming the array is at the
-- top of the stack and the borrowed permission, which should be that returned
-- by 'permForLLVMArrayBorrow', is just below it
implLLVMArrayReturnBorrow ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayBorrow w ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w
                                            :> LLVMPointerType w) ()
implLLVMArrayReturnBorrow x ap (FieldBorrow ix) =
  implLLVMArrayIndexReturn x ap ix
implLLVMArrayReturnBorrow x ap b@(RangeBorrow rng) =
  let ValPerm_Conj1 (Perm_LLVMArray ap_ret) = permForLLVMArrayBorrow ap b in
  implLLVMArrayReturn x ap ap_ret >>>
  greturn ()


-- | Append to array permissions, assuming one ends where the other begins and
-- that they have the same stride and fields
implLLVMArrayAppend ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w
                                            :> LLVMPointerType w) ()
implLLVMArrayAppend x ap1 ap2 =
  implSimplM Proxy (SImpl_LLVMArrayAppend x ap1 ap2)


-- | Rearrange the order of the borrows in an array permission
implLLVMArrayRearrange ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w) ()
implLLVMArrayRearrange x ap_in ap_out =
  implSimplM Proxy (SImpl_LLVMArrayRearrange x ap_in ap_out)

-- | Prove an empty array with length 0
implLLVMArrayEmpty ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w) ps ()
implLLVMArrayEmpty x ap = implSimplM Proxy (SImpl_LLVMArrayEmpty x ap)

-- | Prove an array that can be expressed as the conjunction of @N@ fields from
-- those @N@ fields, assuming a proof of those fields is on the top of the stack
implLLVMArrayOneCell :: (1 <= w, KnownNat w, NuMatchingAny1 r) =>
                        ExprVar (LLVMPointerType w) -> LLVMArrayPerm w ->
                        ImplM vars s r (ps :> LLVMPointerType w)
                        (ps :> LLVMPointerType w) ()
implLLVMArrayOneCell x ap =
  implSimplM Proxy (SImpl_LLVMArrayOneCell x ap)


----------------------------------------------------------------------
-- * Support for Proving Lifetimes Are Current
----------------------------------------------------------------------

-- | Build a 'LifetimeCurrentPerms' to prove that a lifetime @l@ is current in
-- the current permission set, failing if this is not possible
getLifetimeCurrentPerms :: NuMatchingAny1 r => PermExpr LifetimeType ->
                           ImplM vars s r ps ps (Some LifetimeCurrentPerms)
getLifetimeCurrentPerms PExpr_Always = greturn $ Some AlwaysCurrentPerms
getLifetimeCurrentPerms (PExpr_Var l) =
  getPerm l >>>= \p ->
  case p of
    ValPerm_Conj [Perm_LOwned ps] -> greturn $ Some $ LOwnedCurrentPerms l ps
    ValPerm_Conj [Perm_LCurrent l'] ->
      getLifetimeCurrentPerms l' >>>= \some_cur_perms ->
      case some_cur_perms of
        Some cur_perms -> greturn $ Some $ CurrentTransPerms cur_perms l
    _ ->
      implTraceM (\i -> string "Could not prove lifetime is current:" <+>
                        permPretty i l) >>>=
      implFailM

-- | Prove the permissions represented by a 'LifetimeCurrentPerms'
proveLifetimeCurrent :: NuMatchingAny1 r => LifetimeCurrentPerms ps_l ->
                        ImplM vars s r (ps :++: ps_l) ps ()
proveLifetimeCurrent AlwaysCurrentPerms = greturn ()
proveLifetimeCurrent (LOwnedCurrentPerms l ps) =
  implPushM l (ValPerm_Conj1 $ Perm_LOwned ps)
proveLifetimeCurrent (CurrentTransPerms cur_perms l) =
  proveLifetimeCurrent cur_perms >>>
  let l' = lifetimeCurrentPermsLifetime cur_perms
      p_l_cur = ValPerm_Conj1 $ Perm_LCurrent l' in
  implPushM l p_l_cur >>>
  implCopyM l p_l_cur >>>
  implPopM l p_l_cur


----------------------------------------------------------------------
-- * Support for Ending Lifetimes
----------------------------------------------------------------------

data LifetimeEndPerm a
  = LifetimeEndPerm (ExprVar a) (ValuePerm a)
  | LifetimeEndConj (ExprVar a) [AtomicPerm a] Int

type LifetimeEndPerms ps = RAssign LifetimeEndPerm ps
type SomeLifetimeEndPerms = Some (RAssign LifetimeEndPerm)

lifetimeEndPermsToDistPerms :: LifetimeEndPerms ps -> DistPerms ps
lifetimeEndPermsToDistPerms MNil = DistPermsNil
lifetimeEndPermsToDistPerms (ps :>: LifetimeEndPerm x p) =
  DistPermsCons (lifetimeEndPermsToDistPerms ps) x p
lifetimeEndPermsToDistPerms (ps :>: LifetimeEndConj x x_ps i) =
  if i < length x_ps then
    DistPermsCons (lifetimeEndPermsToDistPerms ps)
    x (ValPerm_Conj [x_ps!!i])
  else
    error "lifetimeEndPermsToDistPerms: index too large"

-- | Search through all distinguished permissions @x:p@ and return any conjuncts
-- of @p@ that contain the lifetime @l@, if @p@ is a conjunctive permission, or
-- @p@ itself if it contains @l@ and is any other construct
buildLifetimeEndPerms :: NuMatchingAny1 r => ExprVar LifetimeType ->
                         ImplM vars s r ps ps SomeLifetimeEndPerms
buildLifetimeEndPerms l =
  getPerms >>>= \perms ->
  return $ helper (NameMap.assocs (perms ^. varPermMap)) (Some MNil)
  where
    helper :: [NameAndElem ValuePerm] -> SomeLifetimeEndPerms ->
              SomeLifetimeEndPerms
    helper [] end_perms = end_perms
    helper (NameAndElem x (ValPerm_Conj ps) : naes) (Some end_perms) =
      case findIndex (containsLifetime (PExpr_Var l)) ps of
        Just i ->
          helper (NameAndElem x
                  (ValPerm_Conj (take i ps ++ drop (i+1) ps)) : naes)
          (Some (end_perms :>: LifetimeEndConj x ps i))
        Nothing -> helper naes (Some end_perms)
    helper (NameAndElem x p : naes) (Some end_perms)
      | containsLifetime (PExpr_Var l) p
      = helper naes $ Some (end_perms :>: LifetimeEndPerm x p)
    helper (_ : naes) end_perms = helper naes end_perms


-- | Call 'implPushM' for multiple @x:p@ permissions
implPushLifetimeEndPerms :: NuMatchingAny1 r => LifetimeEndPerms ps' ->
                            ImplM vars s r (ps :++: ps') ps ()
implPushLifetimeEndPerms MNil = greturn ()
implPushLifetimeEndPerms (ps :>: LifetimeEndPerm x p) =
  implPushLifetimeEndPerms ps >>> implPushM x p
implPushLifetimeEndPerms (ps :>: LifetimeEndConj x x_ps i) =
  implPushLifetimeEndPerms ps >>>
  implPushM x (ValPerm_Conj x_ps) >>>
  implExtractConjM x x_ps i >>>
  implPopM x (ValPerm_Conj (take i x_ps ++ drop (i+1) x_ps))


----------------------------------------------------------------------
-- * Recombining Permissions
----------------------------------------------------------------------

-- | Simplify an equality permission @x:eq(e)@ that we assume is on the top of
-- the stack by substituting any equality permissions on variables in @e@,
-- returning the resulting expression
simplEqPerm :: NuMatchingAny1 r => ExprVar a -> PermExpr a ->
               ImplM vars s r (as :> a) (as :> a) (PermExpr a)
simplEqPerm x e@(PExpr_Var y) =
  getPerm y >>>= \case
  p@(ValPerm_Eq e') ->
    implPushM y p >>> implCopyM y p >>> implPopM y p >>>
    introCastM x y p >>> greturn e'
  _ -> greturn e
simplEqPerm x e@(PExpr_LLVMOffset y off) =
  getPerm y >>>= \case
  p@(ValPerm_Eq e') ->
    implPushM y p >>> implCopyM y p >>> implPopM y p >>>
    castLLVMPtrM y p off x >>> greturn (addLLVMOffset e' off)
  _ -> greturn e
simplEqPerm _ e = greturn e

-- | Recombine the permission @x:p@ on top of the stack back into the existing
-- permission for @x@
recombinePerm :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
                 ImplM vars s r as (as :> a) ()
recombinePerm x p = getPerm x >>>= \x_p -> recombinePermExpl x x_p p

-- | Recombine the permission @x:p@ on top of the stack back into the existing
-- permission @x_p@ for @x@, where @x_p@ is given explicitly as the first
-- permission argument and @p@ is the second
recombinePermExpl :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
                     ValuePerm a -> ImplM vars s r as (as :> a) ()
recombinePermExpl x x_p p =
  {-
  getPPInfo >>>= \info ->
  tracePretty (string "recombinePerm" <+> permPretty info x
               </> permPretty info x_p </> string "<-"
               </> permPretty info p) $ -}
  recombinePerm' x x_p p

recombinePerm' :: NuMatchingAny1 r => ExprVar a -> ValuePerm a -> ValuePerm a ->
                  ImplM vars s r as (as :> a) ()
recombinePerm' x _ p@ValPerm_True = implDropM x p
recombinePerm' x ValPerm_True (ValPerm_Eq e) =
  simplEqPerm x e >>>= \e' ->  implPopM x (ValPerm_Eq e')
recombinePerm' x ValPerm_True p = implPopM x p
recombinePerm' x (ValPerm_Eq (PExpr_Var y)) _
  | y == x = error "recombinePerm: variable x has permission eq(x)!"
recombinePerm' x (ValPerm_Eq e1) p@(ValPerm_Eq e2)
  | e1 == e2 = implDropM x p
recombinePerm' x x_p@(ValPerm_Eq (PExpr_Var y)) p =
  implPushM x x_p >>> introEqCopyM x (PExpr_Var y) >>> implPopM x x_p >>>
  invertEqM x y >>> implSwapM x p y (ValPerm_Eq (PExpr_Var x)) >>>
  introCastM y x p >>> getPerm y >>>= \y_p -> recombinePermExpl y y_p p
recombinePerm' x x_p@(ValPerm_Eq (PExpr_LLVMOffset y off)) (ValPerm_Conj ps) =
  implPushM x x_p >>> introEqCopyM x (PExpr_LLVMOffset y off) >>>
  implPopM x x_p >>> implSimplM Proxy (SImpl_InvertLLVMOffsetEq x off y) >>>
  implSwapM x (ValPerm_Conj ps) y (ValPerm_Eq
                                   (PExpr_LLVMOffset x (bvNegate off))) >>>
  castLLVMPtrM x (ValPerm_Conj ps) (bvNegate off) y >>>
  getPerm y >>>= \y_p ->
  recombinePermExpl y y_p (ValPerm_Conj $ mapMaybe (offsetLLVMAtomicPerm off) ps)
recombinePerm' x p p'@(ValPerm_Eq _) =
  -- NOTE: we could handle this by swapping the stack with the variable perm and
  -- calling recombinePerm again, but this could potentially create permission
  -- equality cycles with, e.g., x:eq(y) * y:eq(x). Plus, we don't expect any
  -- functions or typed instructions to return equality permissions unless it is
  -- for a new, fresh variable, in which case the above cases will handle it
  implTraceM (\i ->
               string "recombinePerm: unexpected equality permission being recombined" </>
               permPretty i x <+> colon <+> permPretty i p <+>
               string "<-" <+> permPretty i p') >>>
  error "recombinePerm: unexpected equality permission being recombined"
recombinePerm' x x_p (ValPerm_Or _ _) =
  elimOrsExistsM x >>>= \p' -> recombinePermExpl x x_p p'
recombinePerm' x x_p (ValPerm_Exists _) =
  elimOrsExistsM x >>>= \p' -> recombinePermExpl x x_p p'
recombinePerm' x x_p@(ValPerm_Or _ _) p =
  implPushM x x_p >>> elimOrsExistsM x >>>= \x_p' ->
  implPopM x x_p' >>> recombinePermExpl x x_p' p
recombinePerm' x x_p@(ValPerm_Exists _) p =
  implPushM x x_p >>> elimOrsExistsM x >>>= \x_p' ->
  implPopM x x_p' >>> recombinePermExpl x x_p' p
recombinePerm' x x_p@(ValPerm_Conj x_ps) (ValPerm_Conj (p:ps)) =
  implExtractConjM x (p:ps) 0 >>>
  implSwapM x (ValPerm_Conj1 p) x (ValPerm_Conj ps) >>>
  recombinePermConj x x_ps p >>>= \x_ps' ->
  recombinePermExpl x (ValPerm_Conj x_ps') (ValPerm_Conj ps)
recombinePerm' x _ p = implDropM x p

-- | Recombine a single conjuct @x:p@ on top of the stack back into the existing
-- conjuctive permission @x_p1 * ... * x_pn@ for @x@, returning the resulting
-- permission conjucts for @x@
recombinePermConj :: NuMatchingAny1 r => ExprVar a -> [AtomicPerm a] ->
                     AtomicPerm a -> ImplM vars s r as (as :> a) [AtomicPerm a]

-- If p is a field read permission that is already in x_ps, drop it
recombinePermConj x x_ps p@(Perm_LLVMField fp)
  | Just (Perm_LLVMField fp') <-
      find (\case Perm_LLVMField fp' ->
                    bvEq (llvmFieldOffset fp') (llvmFieldOffset fp)
                  _ -> False) x_ps
  , PExpr_Read <- llvmFieldRW fp
  , PExpr_Read <- llvmFieldRW fp' =
    implDropM x (ValPerm_Conj1 p) >>>
    greturn x_ps

-- If p is an is_llvmptr permission and x_ps already contains one, drop it
recombinePermConj x x_ps p@Perm_IsLLVMPtr
  | elem Perm_IsLLVMPtr x_ps =
    implDropM x (ValPerm_Conj1 p) >>>
    greturn x_ps

-- If p is a field that was borrowed from an array, return it; i.e., if we are
-- returning x:ptr((rw,off+i*stride+j) |-> p) and x has a permission of the form
-- x:array(off,<len,*stride,fps,(i*stride+j):bs) where the jth element of fps
-- equals ptr((rw,j) |-> p), then remove (i*stride+j) from bs
recombinePermConj x x_ps (Perm_LLVMField fp)
  | (ap,i,ix):_ <-
      flip mapMaybe (zip x_ps [0::Int ..]) $
      \case (Perm_LLVMArray ap, i)
              | Just ix <- matchLLVMArrayField ap (llvmFieldOffset fp)
              , elem (FieldBorrow ix) (llvmArrayBorrows ap) ->
                Just (ap,i,ix)
            _ -> Nothing
  , LLVMArrayField fp == llvmArrayFieldWithOffset ap ix =
    implPushM x (ValPerm_Conj x_ps) >>> implExtractConjM x x_ps i >>>
    let x_ps' = deleteNth i x_ps in
    implPopM x (ValPerm_Conj x_ps') >>>
    implLLVMArrayIndexReturn x ap ix >>>
    recombinePermConj x x_ps' (Perm_LLVMArray $
                               llvmArrayRemBorrow (FieldBorrow ix) ap)

-- If p is an array that was borrowed from some other array, return it
recombinePermConj x x_ps (Perm_LLVMArray ap)
  | ap_rng <- llvmArrayCells ap
  , (ap_bigger,i):_ <-
      flip mapMaybe (zip x_ps [0::Int ..])
      (\case (Perm_LLVMArray ap', i)
               | isJust (llvmArrayIsOffsetArray ap' ap) &&
                 elem (llvmSubArrayBorrow ap' ap) (llvmArrayBorrows ap') &&
                 llvmArrayStride ap' == llvmArrayStride ap &&
                 llvmArrayFields ap' == llvmArrayFields ap ->
                 return (ap', i)
             _ -> Nothing) =
    implPushM x (ValPerm_Conj x_ps) >>> implExtractConjM x x_ps i >>>
    let x_ps' = deleteNth i x_ps in
    implPopM x (ValPerm_Conj x_ps') >>>
    implLLVMArrayReturn x ap_bigger ap >>>= \ap_bigger' ->
    recombinePermConj x x_ps' (Perm_LLVMArray ap_bigger')

-- Default case: insert p at the end of the x_ps
recombinePermConj x x_ps p =
  implPushM x (ValPerm_Conj x_ps) >>>
  implInsertConjM x p x_ps (length x_ps) >>>
  implPopM x (ValPerm_Conj (x_ps ++ [p])) >>>
  greturn (x_ps ++ [p])


-- | Recombine the permissions on the stack back into the permission set
recombinePerms :: NuMatchingAny1 r => DistPerms ps -> ImplM vars s r RNil ps ()
recombinePerms DistPermsNil = greturn ()
recombinePerms (DistPermsCons ps' x p) =
  recombinePerm x p >>> recombinePerms ps'

-- | Recombine the permissions for a 'LifetimeCurrentPerms' list
recombineLifetimeCurrentPerms :: NuMatchingAny1 r =>
                                 LifetimeCurrentPerms ps_l ->
                                 ImplM vars s r ps (ps :++: ps_l) ()
recombineLifetimeCurrentPerms AlwaysCurrentPerms = greturn ()
recombineLifetimeCurrentPerms (LOwnedCurrentPerms l ps) =
  recombinePermExpl l ValPerm_True (ValPerm_Conj1 $ Perm_LOwned ps)
recombineLifetimeCurrentPerms (CurrentTransPerms cur_perms l) =
  implDropM l (ValPerm_Conj1 $ Perm_LCurrent $
               lifetimeCurrentPermsLifetime cur_perms) >>>
  recombineLifetimeCurrentPerms cur_perms


----------------------------------------------------------------------
-- * Proving Equality Permissions
----------------------------------------------------------------------

-- | Build a proof on the top of the stack that @x:eq(e)@. Assume that all @x@
-- permissions are on the top of the stack and given by argument @p@, and pop
-- them back to the primary permission for @x@ at the end of the proof.
proveVarEq :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
              Mb vars (PermExpr a) -> ImplM vars s r (ps :> a) (ps :> a) ()
proveVarEq x p mb_e =
  getPSubst >>>= \psubst ->
  -- Check for special cases that do not require an eq perm already for x
  case mb_e of

    -- Prove x:eq(z) for evar z by setting z=x
    [nuP| PExpr_Var z |]
      | Left memb <- mbNameBoundP z
      , Nothing <- psubstLookup psubst memb ->
        setVarM memb (PExpr_Var x) >>> implPopM x p >>> introEqReflM x

    -- Prove x:eq(x) by reflexivity
    _ | Just (PExpr_Var y) <- partialSubst psubst mb_e
      , x == y ->
        implPopM x p >>> introEqReflM x

    -- Default case: get an eq(e) perm and call proveVarEqH
    _ ->
      elimOrsExistsNamesM x >>>= \p' ->
      case p' of
        ValPerm_Eq e ->
          proveVarEqH x e psubst mb_e
        _ -> implFailVarM "proveVarEqH" x p' (fmap ValPerm_Eq mb_e)

-- | Main helper function for 'proveVarEq': prove @x:eq(e) |- x:eq(e')@ assuming
-- the LHS equality permission is on the top of the stack
proveVarEqH :: NuMatchingAny1 r => ExprVar a -> PermExpr a ->
               PartialSubst vars -> Mb vars (PermExpr a) ->
               ImplM vars s r (ps :> a) (ps :> a) ()

-- Prove x:eq(e) |- x:eq(e) using introEqCopyM
proveVarEqH x e psubst mb_e
  | Just e' <- partialSubst psubst mb_e
  , e' == e
  = introEqCopyM x e >>> implPopM x (ValPerm_Eq e)

-- Prove x:eq(word(e)) |- x:eq(word(z)) by setting z=e
proveVarEqH x (PExpr_LLVMWord e) psubst [nuP| PExpr_LLVMWord (PExpr_Var z) |]
  | Left memb <- mbNameBoundP z
  , Nothing <- psubstLookup psubst memb =
    setVarM memb e >>> introEqCopyM x (PExpr_LLVMWord e) >>>
    implPopM x (ValPerm_Eq (PExpr_LLVMWord e))

-- Prove x:eq(word(y)) |- x:eq(word(e)) by proving @y:eq(e)@
proveVarEqH x (PExpr_LLVMWord
               (PExpr_Var y)) psubst [nuP| PExpr_LLVMWord mb_e |] =
  introEqCopyM x (PExpr_LLVMWord (PExpr_Var y)) >>>
  implPopM x (ValPerm_Eq (PExpr_LLVMWord (PExpr_Var y))) >>>
  getPerm y >>>= \y_p ->
  implPushM y y_p >>> proveVarEq y y_p mb_e >>>
  partialSubstForceM mb_e
  "proveVarEqH: incomplete psubst" >>>= \e ->
  llvmWordEqM x y e

-- Prove x:eq(word(e')) |- x:eq(word(e)) for ground e by first proving
-- x:eq(word(e')) and then casting e' to e
proveVarEqH x (PExpr_LLVMWord e') psubst [nuP| PExpr_LLVMWord mb_e |]
  | Just e <- partialSubst psubst mb_e =
    introEqCopyM x (PExpr_LLVMWord e') >>>
    implPopM x (ValPerm_Eq (PExpr_LLVMWord e')) >>>
    castLLVMWordEqM x e' e

-- Prove x:eq(e) |- x:eq(N*z + M) where e - M is a multiple of N by setting z =
-- (e-M)/N
proveVarEqH x e psubst [nuP| PExpr_BV [BVFactor (BV.BV mb_n) z] (BV.BV mb_m) |]
  | Left memb <- mbNameBoundP z
  , Nothing <- psubstLookup psubst memb
  , bvIsZero (bvMod (bvSub e (bvInt $ mbLift mb_m)) (mbLift mb_n)) =
    setVarM memb (bvDiv (bvSub e (bvInt $ mbLift mb_m)) (mbLift mb_n)) >>>
    introEqCopyM x e >>> implPopM x (ValPerm_Eq e)

-- Prove x:eq(y) |- x:eq(e) by first proving y:eq(e) and then casting
proveVarEqH x (PExpr_Var y) psubst mb_e =
  introEqCopyM x (PExpr_Var y) >>>
  implPopM x (ValPerm_Eq (PExpr_Var y)) >>>
  proveVarImpl y (fmap ValPerm_Eq mb_e) >>>
  partialSubstForceM mb_e
  "proveVarEqH: incomplete psubst" >>>= \e ->
  introCastM x y (ValPerm_Eq e)

-- Prove x:eq(e) |- x:eq(y) when psubst assigned y=e' by proving x:eq(e')
-- FIXME: we should more generally apply psubst to the RHS before calling proveVarEqH
proveVarEqH x e psubst [nuP| PExpr_Var mb_y |]
  | Left memb <- mbNameBoundP mb_y
  , Just e' <- psubstLookup psubst memb =
    proveVarEqH x e psubst (fmap (const e') mb_y)

-- Prove x:eq(e) |- x:eq(y) by first proving y:eq(e) and then using inverse
-- transitivity
proveVarEqH x e psubst [nuP| PExpr_Var mb_y |]
  | Right y <- mbNameBoundP mb_y =
    introEqCopyM x e >>> implPopM x (ValPerm_Eq e) >>>
    proveVarImpl y (fmap (const $ ValPerm_Eq e) mb_y) >>>
    invTransEqM x y e

-- Otherwise give up!
proveVarEqH x e _ mb_e =
  implFailVarM "proveVarEqH" x (ValPerm_Eq e) (fmap ValPerm_Eq mb_e)


----------------------------------------------------------------------
-- * Proving Field Permissions
----------------------------------------------------------------------

-- | Prove an LLVM field permission @x:ptr((rw,off) |-> p)@ from permission @pi@
-- assuming that the the current permissions @x:(p1 * ... *pn)@ for @x@ are on
-- the top of the stack, and ensuring that any remaining permissions for @x@ get
-- popped back to the primary permissions for @x@
proveVarLLVMField ::
  (1 <= w, KnownNat w, 1 <= sz, KnownNat sz, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> [AtomicPerm (LLVMPointerType w)] -> Int ->
  PermExpr (BVType w) -> Mb vars (LLVMFieldPerm w sz) ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w) ()
proveVarLLVMField x ps i off mb_fp =
  (if i < length ps then greturn () else
     error "proveVarLLVMField: index too large") >>>= \() ->
  implExtractConjM x ps i >>>
  let ps_rem = deleteNth i ps in
  implPopM x (ValPerm_Conj ps_rem) >>>
  getPSubst >>>= \psubst ->
  extractNeededLLVMFieldPerm x (ps!!i) off psubst mb_fp >>>= \(fp,maybe_p_rem) ->
  (case maybe_p_rem of
      Just p_rem ->
        implPushM x (ValPerm_Conj ps_rem) >>>
        implInsertConjM x p_rem ps_rem i >>>
        implPopM x (ValPerm_Conj (take i ps_rem ++ [p_rem] ++ drop i ps_rem))
      Nothing -> implDropM x ValPerm_True) >>>
  proveVarLLVMFieldFromField x fp off mb_fp


-- | Prove an LLVM field permission from another one that is on the top of the
-- stack, by casting the offset, changing the lifetime if needed, and proving
-- the contents
proveVarLLVMFieldFromField ::
  (1 <= w, KnownNat w, 1 <= sz, KnownNat sz, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> LLVMFieldPerm w sz ->
  PermExpr (BVType w) -> Mb vars (LLVMFieldPerm w sz) ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w) ()
proveVarLLVMFieldFromField x fp off' mb_fp =
  -- Step 1: make sure to have a variable for the contents
  implElimLLVMFieldContentsM x fp >>>= \y ->
  let fp' = fp { llvmFieldContents = ValPerm_Eq (PExpr_Var y) } in

  -- Step 2: cast the field offset to off' if necessary
  (if bvEq (llvmFieldOffset fp') off' then
     greturn fp'
   else
     implTryProveBVProp x (BVProp_Eq (llvmFieldOffset fp') off') >>>
     implSimplM Proxy (SImpl_CastLLVMFieldOffset x fp' off') >>>
     greturn (fp' { llvmFieldOffset = off' })) >>>= \fp'' ->

  -- Step 3: change the lifetime if needed
  getPSubst >>>= \psubst ->
  (case (llvmFieldLifetime fp'', fmap llvmFieldLifetime mb_fp) of
      (l1, mb_l2) | mbLift (fmap (== l1) mb_l2) -> greturn fp''
      (l1, [nuP| PExpr_Var z |])
        | Left memb <- mbNameBoundP z
        , Nothing <- psubstLookup psubst memb ->
          setVarM memb l1 >>> greturn fp''
      (l1, [nuP| PExpr_Var z |])
        | Left memb <- mbNameBoundP z
        , Just l2 <- psubstLookup psubst memb
        , l1 == l2 -> greturn fp''
      (PExpr_Always, [nuP| PExpr_Var z |])
        | Left memb <- mbNameBoundP z
        , Just l2 <- psubstLookup psubst memb ->
          implSimplM Proxy (SImpl_LLVMFieldLifetimeAlways x fp'' l2) >>>
          greturn (fp'' { llvmFieldLifetime = l2 })
      (PExpr_Always, [nuP| PExpr_Var z |])
        | Right l2 <- mbNameBoundP z ->
          implSimplM Proxy (SImpl_LLVMFieldLifetimeAlways x fp'' $
                            PExpr_Var l2) >>>
          greturn (fp'' { llvmFieldLifetime = PExpr_Var l2 })
      (PExpr_Var l1, [nuP| PExpr_Var z |])
        | Right l2_var <- mbNameBoundP z ->
          let l2 = PExpr_Var l2_var in
          let lcur_perm = ValPerm_Conj [Perm_LCurrent l2] in
          proveVarImpl l1 (fmap (const $ lcur_perm) mb_fp) >>>
          implSimplM Proxy (SImpl_LLVMFieldLifetimeCurrent x fp'' l1 l2) >>>
          greturn (fp'' { llvmFieldLifetime = l2 })
      _ ->
        implFailVarM "proveVarLLVMFieldFromField" x (ValPerm_Conj1 $ Perm_LLVMField fp'')
        (fmap (ValPerm_Conj1 . Perm_LLVMField) mb_fp)) >>>= \fp''' ->

  -- Step 4: prove the contents
  proveVarImpl y (fmap llvmFieldContents mb_fp) >>>
  partialSubstForceM (fmap llvmFieldContents mb_fp)
  "proveVarLLVMFieldFromField: incomplete field contents" >>>= \p_y ->
  introLLVMFieldContentsM x y (fp''' { llvmFieldContents = p_y })


-- | Extract an LLVM field permission from the given atomic permission, leaving
-- as much of the original atomic permission as possible on the top of the stack
-- (which could be none of it, i.e., @true@). At the end of this function, the
-- top of the stack should look like
--
-- > x:ptr((rw,off) -> p) * x:rem
--
-- where @rem@ is the remainder of the input atomic permission, which is either
-- a single atomic permission or @true@. The field permission and remaining
-- atomic permission (if any) are the return values of this function.
extractNeededLLVMFieldPerm ::
  (1 <= w, KnownNat w, 1 <= sz, KnownNat sz, NuMatchingAny1 r) =>
  ExprVar (LLVMPointerType w) -> AtomicPerm (LLVMPointerType w) ->
  PermExpr (BVType w) -> PartialSubst vars -> Mb vars (LLVMFieldPerm w sz) ->
  ImplM vars s r (ps :> LLVMPointerType w :> LLVMPointerType w)
  (ps :> LLVMPointerType w)
  (LLVMFieldPerm w sz, Maybe (AtomicPerm (LLVMPointerType w)))

-- If proving x:ptr((rw,off) |-> p) |- x:ptr((z,off') |-> p') for an RWModality
-- variable z, set z = rw and recurse
extractNeededLLVMFieldPerm x p@(Perm_LLVMField fp) off' psubst mb_fp
  | Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp)
  , [nuP| PExpr_Var z |] <- fmap llvmFieldRW mb_fp
  , Left memb <- mbNameBoundP z
  , Nothing <- psubstLookup psubst memb =
    setVarM memb (llvmFieldRW fp) >>>
    extractNeededLLVMFieldPerm x p off' psubst
    (fmap (\fp' -> fp' { llvmFieldRW = llvmFieldRW fp }) mb_fp)

-- If proving x:ptr((rw,off) |-> p) |- x:ptr((z,off') |-> p') where z is
-- defined, substitute for z and recurse
extractNeededLLVMFieldPerm x p@(Perm_LLVMField fp) off' psubst mb_fp
  | Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp)
  , [nuP| PExpr_Var z |] <- fmap llvmFieldRW mb_fp
  , Left memb <- mbNameBoundP z
  , Just rw <- psubstLookup psubst memb =
    extractNeededLLVMFieldPerm x p off' psubst
    (fmap (\fp' -> fp' { llvmFieldRW = rw }) mb_fp)

-- If proving x:ptr((R,off) |-> p) |- x:ptr((R,off') |-> p'), just copy the read
-- permission
extractNeededLLVMFieldPerm x (Perm_LLVMField fp) off' _ mb_fp
  | Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp)
  , PExpr_Read <- llvmFieldRW fp
  , [nuP| PExpr_Read |] <- fmap llvmFieldRW mb_fp
  = implCopyConjM x [Perm_LLVMField fp] 0 >>>
    greturn (fp, Just (Perm_LLVMField fp))

-- Cannot prove x:ptr((rw,off) |-> p) |- x:ptr((W,off') |-> p') if rw is not W,
-- so fail
extractNeededLLVMFieldPerm x ap@(Perm_LLVMField fp) _ _ mb_fp
  | Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp)
  , PExpr_Write /= llvmFieldRW fp
  , [nuP| PExpr_Write |] <- fmap llvmFieldRW mb_fp
  = implFailVarM "extractNeededLLVMFieldPerm" x (ValPerm_Conj1 $ ap)
    (fmap (ValPerm_Conj1 . Perm_LLVMField) mb_fp)

-- If proving x:[l1]ptr((rw,off) |-> p) |- x:[l2]ptr((R,off') |-> p') for rw not
-- equal to R, first split the lifetime of the input permission if l2 /= l1 and
-- we have an lowned permission for l2, and then demote to read and copy the
-- read permission as in the R |- R case above
extractNeededLLVMFieldPerm x p@(Perm_LLVMField fp) off' _ mb_fp
  | Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp)
  , PExpr_Read /= llvmFieldRW fp
  , [nuP| PExpr_Read |] <- fmap llvmFieldRW mb_fp
  = partialSubstForceM (fmap llvmFieldLifetime mb_fp)
    "extractNeededLLVMFieldPerm: incomplete RHS lifetime" >>>= \l2 ->
    -- NOTE: we could allow existential lifetimes on the RHS by just adding some
    -- more cases here
    (case l2 of
        PExpr_Var l2_var ->
          getPerm l2_var >>>= \l2_perm ->
          (case l2_perm of
              ValPerm_Conj [Perm_LOwned ps] ->
                implPushM l2_var l2_perm >>>
                implSplitLifetimeM x (ValPerm_Conj1 p) l2_var >>>
                implPopM l2_var (ValPerm_Conj
                                 [Perm_LOwned
                                  (PExpr_PermListCons (PExpr_Var x)
                                   (ValPerm_Conj1 p) ps)]) >>>
                greturn (fp { llvmFieldLifetime = l2 })
              l_p ->
                implTraceM (\i ->
                             sep [ string "No lowned perm for" <+> permPretty i l2
                                   <> comma
                                 , string "instead found" <+> permPretty i l_p
                                   <> comma
                                 , string "so we must demote the RW on"
                                   <> permPretty i x]) >>>
                greturn fp)
        _ -> greturn fp) >>>= \fp' ->
    implSimplM Proxy (SImpl_DemoteLLVMFieldWrite x fp') >>>
    let fp'' = fp' { llvmFieldRW = PExpr_Read } in
    implCopyConjM x [Perm_LLVMField fp''] 0 >>>
    greturn (fp'', Just (Perm_LLVMField fp''))

-- If proving x:ptr((rw,off) |-> p) |- x:ptr((rw,off') |-> p') for any other
-- case, just push a true permission, because there is no remaining permission
extractNeededLLVMFieldPerm x (Perm_LLVMField fp) off' _ mb_fp
  | Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp)
  , mbLift (fmap ((llvmFieldRW fp ==) . llvmFieldRW) mb_fp)
  = introConjM x >>> greturn (fp, Nothing)

-- If proving x:array(off,<len,*stride,fps,bs) |- x:ptr((R,off) |-> p) such that
-- off=i*stride+j and the jth field of the ith index of the array is a read
-- containing only copyable permissions, copy that field
extractNeededLLVMFieldPerm x (Perm_LLVMArray ap) off' _ mb_fp
  | Just ix <- matchLLVMArrayField ap off'
  , LLVMArrayField fp <- llvmArrayFieldWithOffset ap ix
  , Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp)
  , PExpr_Read <- llvmFieldRW fp
  , permIsCopyable (llvmFieldContents fp)
  , [nuP| PExpr_Read |] <- fmap llvmFieldRW mb_fp =
    implLLVMArrayIndexCopy x ap ix >>>
    greturn (fp, Just (Perm_LLVMArray ap))

-- If proving x:array(off,<len,*stride,fps,bs) |- x:ptr((rw,off) |-> p) such
-- that off=i*stride+j in any other case, borrow that field
extractNeededLLVMFieldPerm x (Perm_LLVMArray ap) off' psubst mb_fp
  | Just ix <- matchLLVMArrayField ap off'
  , LLVMArrayField fp <- llvmArrayFieldWithOffset ap ix
  , Just Refl <- testEquality (llvmFieldSize fp) (mbLift $
                                                  fmap llvmFieldSize mb_fp) =
    implLLVMArrayIndexBorrow x ap ix >>>= \(ap', _) ->
    implSwapM x (ValPerm_Conj1 $ Perm_LLVMField fp) x (ValPerm_Conj1 $
                                                       Perm_LLVMArray ap') >>>
    extractNeededLLVMFieldPerm x (Perm_LLVMField fp) off' psubst mb_fp >>>=
    \(fp', maybe_p_rem) ->
    -- NOTE: it is safe to just drop the remaining permission on the stack,
    -- because it is either Nothing (for a write) or a copy of the field
    -- permission (for a read)
    implDropM x (maybe ValPerm_True ValPerm_Conj1 maybe_p_rem) >>>
    implSwapM x (ValPerm_Conj1 $
                 Perm_LLVMArray ap') x (ValPerm_Conj1 $ Perm_LLVMField fp) >>>
    greturn (fp', Just (Perm_LLVMArray ap'))

-- All other cases fail
extractNeededLLVMFieldPerm x ap _ _ mb_fp =
  implFailVarM "extractNeededLLVMFieldPerm" x (ValPerm_Conj1 $ ap)
  (fmap (ValPerm_Conj1 . Perm_LLVMField) mb_fp)


----------------------------------------------------------------------
-- * Proving LLVM Array Permissions
----------------------------------------------------------------------

-- | FIXME HERE NOW: document, especially the bool flag = first iteration and
-- that the bools with each perm are whether they can be used
proveVarLLVMArray ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) => ExprVar (LLVMPointerType w) ->
  Bool -> [AtomicPerm (LLVMPointerType w)] -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w) ()

proveVarLLVMArray x first_p ps ap =
  implTraceM (\i -> string "proveVarLLVMArray:" <+>
                    permPretty i x <> colon <>
                    permPretty i (ValPerm_Conj ps) <+> string "-o" <+>
                    permPretty i (ValPerm_Conj1 $ Perm_LLVMArray ap)) >>>
  proveVarLLVMArrayH x first_p ps ap


-- | FIXME HERE NOW: document, especially the bool flag = first iteration and
-- that the bools with each perm are whether they can be used
proveVarLLVMArrayH ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) => ExprVar (LLVMPointerType w) ->
  Bool -> [AtomicPerm (LLVMPointerType w)] -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w) ()

-- When len = 0, we are done
proveVarLLVMArrayH x _ ps ap
  | bvEq (llvmArrayLen ap) (bvInt 0) =
    implPopM x (ValPerm_Conj ps) >>> implLLVMArrayEmpty x ap

-- If the required array permission ap is equivalent to a sequence of field
-- permissions that we have all of, then prove it by proving those field
-- permissions. This is accomplished by first proving the array with the
-- un-borrowed cell that is allowed by 'implLLVMArrayOneCell' and then
-- recursively proving the desired array permission by calling proveVarImpl,
-- which will remove the necessary borrows.
proveVarLLVMArrayH x _ ps ap
  | Just (flds1, flds2) <- llvmArrayAsFields ap
  , all (\fld ->
          any (isLLVMFieldPermWithOffset
               (llvmArrayFieldOffset fld)) ps) (flds1 ++ flds2) =
    implPopM x (ValPerm_Conj ps) >>>
    mbVarsM (ValPerm_Conj $
             map llvmArrayFieldToAtomicPerm flds1) >>>= \mb_p_flds ->
    proveVarImpl x mb_p_flds >>>
    let ap' = llvmArrayAddBorrows (map (fromJust
                                        . offsetToLLVMArrayBorrow ap
                                        . llvmArrayFieldOffset) flds2) ap in
    implLLVMArrayOneCell x ap' >>>
    implPopM x (ValPerm_Conj1 $ Perm_LLVMArray ap') >>>
    mbVarsM (ValPerm_Conj1 $ Perm_LLVMArray ap) >>>= \mb_p ->
    proveVarImpl x mb_p

-- Otherwise, choose the best-matching array permission and copy, borrow, or use
-- it directly (beg, borrow, or steal it)
--
-- FIXME: need to handle the case where we have a field permission for the first
-- cell of an array and an array permission for the rest
proveVarLLVMArrayH x first_p ps ap =
  let best_elems :: [(Bool, a)] -> [a]
      best_elems xs | Just i <- findIndex fst xs = [snd $ xs !! i]
      best_elems xs = map snd xs in

  getPPInfo >>>= \pp_info ->
  mbVarsM (Perm_LLVMArray ap) >>>= \mb_p ->
  foldr1WithDefault implCatchM (proveVarAtomicImplUnfoldOrFail x ps mb_p) $
  best_elems $
  (let off = llvmArrayOffset ap in
   catMaybes $
   zipWith (\p i -> case p of
               Perm_LLVMArray ap_lhs
                 | precise <- bvEq off (llvmArrayOffset ap_lhs)
                 , (first_p || precise)
                 , Just cell_num <- llvmArrayIsOffsetArray ap_lhs ap
                 , bvCouldBeInRange cell_num (llvmArrayCells ap_lhs)
                 , llvmArrayFields ap_lhs == llvmArrayFields ap ->
                   Just (precise, proveVarLLVMArray_ArrayStep x ps ap i ap_lhs)
               _ -> Nothing)
   ps [0..])


-- | FIXME HERE NOW: document this
proveVarLLVMArray_ArrayStep ::
  (1 <= w, KnownNat w, NuMatchingAny1 r) => ExprVar (LLVMPointerType w) ->
  [AtomicPerm (LLVMPointerType w)] -> LLVMArrayPerm w ->
  Int -> LLVMArrayPerm w ->
  ImplM vars s r (ps :> LLVMPointerType w) (ps :> LLVMPointerType w) ()

-- If there is a field borrow in ap_lhs that is not in ap but might overlap with
-- ap, return it to ap_lhs
--
-- FIXME: when an array ap_ret is being borrowed from ap_lhs, this code requires
-- all of it to be returned, with no borrows, even though it could be that ap
-- allows some of ap_ret to be borrowed
proveVarLLVMArray_ArrayStep x ps ap i ap_lhs
  | Just b <-
    find (\b ->
           bvRangesCouldOverlap (llvmArrayBorrowAbsOffsets ap_lhs b)
           (llvmArrayAbsOffsets ap))
         (llvmArrayBorrows $ llvmArrayRemArrayBorrows ap_lhs ap) =

    -- Prove the rest of ap with b borrowed
    let ap' = llvmArrayAddBorrow b ap in
    proveVarLLVMArray_ArrayStep x ps ap' i ap_lhs >>>

    -- Prove the borrowed perm
    let p = permForLLVMArrayBorrow ap b in
    mbVarsM p >>>= \mb_p ->
    proveVarImpl x mb_p >>>
    implSwapM x (ValPerm_Conj1 $ Perm_LLVMArray ap') x p >>>

    -- Return the borrowed perm to ap' to get ap
    implLLVMArrayReturnBorrow x ap' b

-- If there is a borrow in ap that is not in ap_lhs, borrow it from ap_lhs. Note
-- the assymmetry with the previous case: we only add borrows if we definitely
-- have to, but we remove borrows if we might have to.
proveVarLLVMArray_ArrayStep x ps ap i ap_lhs
  | Just b <-
    find (\b -> bvRangesOverlap (llvmArrayBorrowAbsOffsets ap b)
                (llvmArrayAbsOffsets ap_lhs))
         (llvmArrayBorrows $ llvmArrayRemArrayBorrows ap ap_lhs) =

    -- Prove the rest of ap without b borrowed
    let ap' = llvmArrayRemBorrow b ap in
    proveVarLLVMArray_ArrayStep x ps ap' i ap_lhs >>>

    -- Borrow the permission if that is possible; this will fail if ap has a
    -- borrow that is not actually in its range
    implLLVMArrayBorrowBorrow x ap' b >>>= \p ->
    recombinePerm x p

-- If ap and ap_lhs are equal up to the order of their borrows, just rearrange
-- the borrows and we should be good
proveVarLLVMArray_ArrayStep x ps ap i ap_lhs
  | bvEq (llvmArrayOffset ap_lhs) (llvmArrayOffset ap)
  , bvEq (llvmArrayLen ap_lhs) (llvmArrayLen ap)
  , llvmArrayStride ap_lhs == llvmArrayStride ap
  , llvmArrayFields ap_lhs == llvmArrayFields ap =
    (if atomicPermIsCopyable (Perm_LLVMArray ap) then
       implCopyConjM x ps i >>>
       implPopM x (ValPerm_Conj ps)
     else
       implExtractConjM x ps i >>>
       implPopM x (ValPerm_Conj $ deleteNth i ps)) >>>
    implLLVMArrayRearrange x ap_lhs ap

-- If ap is contained inside ap_lhs at a cell boundary then copy or borrow ap
-- from ap_lhs depending on whether they are copyable
proveVarLLVMArray_ArrayStep x ps ap i ap_lhs
  | all bvPropCouldHold (bvPropRangeSubset
                         (llvmArrayAbsOffsets ap) (llvmArrayAbsOffsets ap_lhs))
  , llvmArrayStride ap_lhs == llvmArrayStride ap
  , llvmArrayFields ap_lhs == llvmArrayFields ap
  , Just (LLVMArrayIndex ap_cell_num 0) <-
      matchLLVMArrayField ap_lhs (llvmArrayOffset ap) =
    implExtractConjM x ps i >>>
    implPopM x (ValPerm_Conj $ deleteNth i ps) >>>
    if atomicPermIsCopyable (Perm_LLVMArray ap) then
      implLLVMArrayCopy x ap_lhs ap >>>
      recombinePerm x (ValPerm_Conj1 $ Perm_LLVMArray ap_lhs)
    else
      implLLVMArrayBorrow x ap_lhs ap >>>
      recombinePerm x (ValPerm_Conj1 $ Perm_LLVMArray $
                       llvmArrayAddBorrow (llvmSubArrayBorrow ap_lhs ap) ap_lhs)

-- If we get to this case but ap is still at a cell boundary in ap_lhs then
-- ap_lhs only satisfies some initial portion of ap, so borrow or copy that part
-- of ap_lhs and continue proving the rest of ap
proveVarLLVMArray_ArrayStep x ps ap i ap_lhs
  | llvmArrayStride ap_lhs == llvmArrayStride ap
  , llvmArrayFields ap_lhs == llvmArrayFields ap
  , Just (LLVMArrayIndex ap_cell_num 0) <-
      matchLLVMArrayField ap_lhs (llvmArrayOffset ap) =

    -- Split ap into ap_first = the portion of ap covered by ap_lhs and ap_rest
    let (ap_first, ap_rest) =
          llvmArrayPermDivide ap (bvSub (llvmArrayLen ap_lhs) ap_cell_num) in

    -- Copy or borrow ap_first from ap_lhs, leaving some ps' on top of the stack
    -- and ap_first just below it
    implExtractConjM x ps i >>>
    implPopM x (ValPerm_Conj $ deleteNth i ps) >>>
    (if atomicPermIsCopyable (Perm_LLVMArray ap_first) then
       implLLVMArrayCopy x ap_lhs ap_first >>>
       implPushM x (ValPerm_Conj $ deleteNth i ps) >>>
       implInsertConjM x (Perm_LLVMArray ap_lhs) (deleteNth i ps) i >>>
       greturn ps
     else
       implLLVMArrayBorrow x ap_lhs ap_first >>>
       implPushM x (ValPerm_Conj $ deleteNth i ps) >>>
       let ap_lhs' =
             llvmArrayAddBorrow (llvmSubArrayBorrow ap_lhs ap_first) ap_lhs in
       implInsertConjM x (Perm_LLVMArray ap_lhs') (deleteNth i ps) i >>>
       greturn (replaceNth i (Perm_LLVMArray ap_lhs') ps)) >>>= \ps' ->

    -- Recursively prove ap_rest
    proveVarLLVMArray x False ps' ap_rest >>>

    -- Combine ap_first and ap_rest to get out ap
    implLLVMArrayAppend x ap_first ap_rest


-- Otherwise we don't know what to do so we fail
proveVarLLVMArray_ArrayStep _x _ps _ap _i _ap_lhs =
  implFailMsgM "proveVarLLVMArray_ArrayStep"


----------------------------------------------------------------------
-- * Proving Named Permission Arguments
----------------------------------------------------------------------

-- | Prove @P<args1> |- P<args2>@ by weakening the arguments in @args1@ and
-- substituting for free variablers in @args2@ until the arguments are
-- equal. The weakening steps include:
--
-- * Replacing 'Write' arguments with 'Read';
--
-- * Replacing a bigger lifetime @l1@ with a smaller one @l2@, defined by the
-- existence of a @l2:[l1]lcurrent@;
--
-- * Replacing all lifetime arguments with a single @lowned@ lifetime @l@, by
-- splitting the lifetime of the input permission
--
-- FIXME: currently this does not do the lifetime splitting step
proveNamedArgs :: NuMatchingAny1 r => ExprVar a ->
                  NamedPermName ns args a -> PermExprs args ->
                  PermOffset a -> Mb vars (PermExprs args) ->
                  ImplM vars s r (ps :> a) (ps :> a) ()
proveNamedArgs x npn args off mb_args =
  getPSubst >>>= \psubst ->
  mapM_ (\case Some memb ->
                 proveNamedArg x npn args off memb psubst $
                 fmap (`nthPermExpr` memb) mb_args) $
  getPermExprsMembers args


-- | Prove @P<args1,arg,args2> |- P<args1,arg',args2>@ where @arg@ is specified
-- by a 'Member' proof in the input @args@ and @arg'@ potentially has
-- existential variables. Assume the LHS is on the top of the stack and leave
-- the RHS, if proved, on the top of the stack.
proveNamedArg :: NuMatchingAny1 r => ExprVar a ->
                 NamedPermName ns args a -> PermExprs args ->
                 PermOffset a -> Member args b -> PartialSubst vars ->
                 Mb vars (PermExpr b) ->
                 ImplM vars s r (ps :> a) (ps :> a) ()

-- If the current and required args are equal, do nothing and return
proveNamedArg x _ args _ memb _ mb_arg
  | mbLift (fmap (== nthPermExpr args memb) mb_arg) =
    greturn ()

-- If the RHS is an unassigned existential variable then set it and return
--
-- FIXME: eventually we might want to generate some sort of constraints...?
proveNamedArg x _ args _ memb psubst [nuP| PExpr_Var z |]
  | Left memb_z <- mbNameBoundP z
  , Nothing <- psubstLookup psubst memb_z =
    setVarM memb_z (nthPermExpr args memb)

-- If the RHS is an already-assigned existential variable, subst and recurse
proveNamedArg x npn args off memb psubst arg@[nuP| PExpr_Var z |]
  | Left memb_z <- mbNameBoundP z
  , Just e <- psubstLookup psubst memb_z =
    proveNamedArg x npn args off memb psubst $ fmap (const e) arg

-- Prove P<args1,always,args2> -o P<args1,l,args2>
proveNamedArg x npn args off memb _ arg@[nuP| PExpr_Var z |]
  | Right l <- mbNameBoundP z
  , PExpr_Always <- nthPermExpr args memb =
    implSimplM Proxy (SImpl_NamedArgAlways x npn args off memb (PExpr_Var l))

-- Prove P<args1,l1,args2> -o P<args1,l2,args2> using l1:[l2]lcurrent
proveNamedArg x npn args off memb _ arg@[nuP| PExpr_Var z |]
  | Right l1 <- mbNameBoundP z
  , LifetimeRepr <- cruCtxLookup (namedPermNameArgs npn) memb
  , PExpr_Var l2 <- nthPermExpr args memb =
    proveVarImpl l1 (fmap (const $ ValPerm_Conj1 $
                           Perm_LCurrent $ PExpr_Var l2) arg) >>>
    implSimplM Proxy (SImpl_NamedArgCurrent x npn args off memb (PExpr_Var l2))

-- Prove P<args1,W,args2> -o P<args1,rw,args2> for any variable rw
proveNamedArg x npn args off memb _ arg@[nuP| PExpr_Var z |]
  | Right rw <- mbNameBoundP z
  , PExpr_RWModality Write <- nthPermExpr args memb =
    implSimplM Proxy (SImpl_NamedArgWrite x npn args off memb (PExpr_Var rw))

-- Prove P<args1,rw,args2> -o P<args1,R,args2> for any rw
proveNamedArg x npn args off memb _ arg@[nuP| PExpr_RWModality Read |] =
  implSimplM Proxy (SImpl_NamedArgRead x npn args off memb)

-- Fail in any other case
proveNamedArg x npn args off memb _ mb_arg =
  implFailVarM "proveNamedArg" x
  (ValPerm_Named npn args off)
  (fmap (\args' ->
          ValPerm_Named npn (setNthPermExpr args memb args') off) mb_arg)


----------------------------------------------------------------------
-- * Proving and Eliminating Recursive Permissions
----------------------------------------------------------------------

-- | Prove @x:p1 |- x:p2@ by unfolding a foldable named permission in @p1@ and
-- then recursively proving @x:p2@ from the resulting permissions. If an 'Int'
-- @i@ is supplied, then @p1@ is a conjunctive permission whose @i@th conjunct
-- is the named permisison to be unfolded; otherwise @p1@ itself is the named
-- permission to be unfolded. Assume that @x:p1@ is on top of the stack.
proveVarImplUnfoldLeft :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
                          Mb vars (ValuePerm a) ->
                          Maybe Int -> ImplM vars s r (ps :> a) (ps :> a) ()

proveVarImplUnfoldLeft x (ValPerm_Named npn args off) mb_p Nothing
  | TrueRepr <- nameCanFoldRepr npn =
    (case namedPermNameSort npn of
        RecursiveSortRepr _ -> implSetRecRecurseLeftM
        _ -> greturn ()) >>>
    implUnfoldNamedM x npn args off >>>= \p' ->
    implPopM x p' >>>
    proveVarImpl x mb_p

proveVarImplUnfoldLeft x (ValPerm_Conj ps) mb_p (Just i)
  | i < length ps
  , p_i@(Perm_NamedConj npn args off) <- ps!!i
  , TrueRepr <- nameCanFoldRepr npn =
    (case namedPermNameSort npn of
        RecursiveSortRepr _ -> implSetRecRecurseLeftM
        _ -> greturn ()) >>>
    implExtractConjM x ps i >>> implPopM x (ValPerm_Conj $ deleteNth i ps) >>>
    implNamedFromConjM x npn args off >>>
    implUnfoldNamedM x npn args off >>>= \p' ->
    recombinePerm x p' >>>
    proveVarImpl x mb_p

proveVarImplUnfoldLeft _ _ _ _ =
  error ("proveVarImplUnfoldLeft: malformed inputs")


-- | Prove @x:p1 |- x:P<args>\@off@ where @P@ is foldable by first proving the
-- unfolding of @P@ folding it. Assume that @x:p1@ is on top of the stack.
proveVarImplFoldRight :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
                         Mb vars (ValuePerm a) ->
                         ImplM vars s r (ps :> a) (ps :> a) ()
proveVarImplFoldRight x p [nuP| ValPerm_Named mb_npn mb_args mb_off |]
  | npn <- mbLift mb_npn
  , TrueRepr <- nameCanFoldRepr npn =
    (case namedPermNameSort npn of
        RecursiveSortRepr _ -> implSetRecRecurseRightM
        _ -> greturn ()) >>>
    implLookupNamedPerm npn >>>= \np ->
    implPopM x p >>>
    proveVarImpl x (mbMap2 (unfoldPerm np) mb_args mb_off) >>>
    partialSubstForceM (mbMap2 (,) mb_args mb_off)
    "proveVarImplFoldRight: incomplete psubst: implFold" >>>= \(args,off) ->
    implFoldNamedM x npn args off

proveVarImplFoldRight _ _ _ =
  error ("proveVarImplFoldRight: malformed inputs")


----------------------------------------------------------------------
-- * Proving Atomic Permissions
----------------------------------------------------------------------

-- | We were not able to prove @x:(p1 * ... * pn) |- x:p@ as is, so try
-- unfolding named permissions in the @pi@s as a last resort. If there are none,
-- or our recursion flag does not allow it, then fail.
proveVarAtomicImplUnfoldOrFail :: NuMatchingAny1 r => ExprVar a ->
                                  [AtomicPerm a] -> Mb vars (AtomicPerm a) ->
                                  ImplM vars s r (ps :> a) (ps :> a) ()
proveVarAtomicImplUnfoldOrFail x ps mb_ap =
  let p_l = ValPerm_Conj ps
      mb_p_r = fmap ValPerm_Conj1 mb_ap in
  implGetRecRecurseFlag >>>= \flag ->
  case () of
    -- We can always unfold a defined name on the left
    _ | Just i <- findIndex isDefinedConjPerm ps ->
        proveVarImplUnfoldLeft x p_l mb_p_r (Just i)

    -- If flag allows it, we can unfold a recursive name on the left
    _ | Just i <- findIndex isRecursiveConjPerm ps
      , flag /= Just (Right ()) ->
        proveVarImplUnfoldLeft x p_l mb_p_r (Just i)

    -- Otherwise, we fail
    _ -> implFailVarM "proveVarAtomicImpl" x p_l mb_p_r

proveVarAtomicImpl :: NuMatchingAny1 r => ExprVar a -> [AtomicPerm a] ->
                      Mb vars (AtomicPerm a) ->
                      ImplM vars s r (ps :> a) (ps :> a) ()

proveVarAtomicImpl x ps mb_p@[nuP| Perm_LLVMField mb_fp |] =
  partialSubstForceM (fmap llvmFieldOffset mb_fp)
  "proveVarPtrPerms: incomplete psubst: LLVM field offset" >>>= \off ->
  foldMapWithDefault implCatchM
  (proveVarAtomicImplUnfoldOrFail x ps mb_p)
  (\(i,_) -> proveVarLLVMField x ps i off mb_fp)
  (findMaybeIndices (llvmPermContainsOffset off) ps)

proveVarAtomicImpl x ps mb_p@[nuP| Perm_LLVMArray mb_ap |] =
  partialSubstForceM mb_ap
  "proveVarPtrPerms: incomplete psubst: LLVM array" >>>= \ap ->
  proveVarLLVMArray x True ps ap

proveVarAtomicImpl x ps ap@[nuP| Perm_LLVMFree mb_e |] =
  partialSubstForceM mb_e
  "proveVarAtomicImpl: incomplete psubst: LLVM free size" >>>= \e ->
  case findMaybeIndices (\case
                            Perm_LLVMFree e' -> Just e'
                            _ -> Nothing) ps of
    (i, e'):_ ->
      implCopyConjM x ps i >>> implPopM x (ValPerm_Conj ps) >>>
      castLLVMFreeM x e' e
    _ -> proveVarAtomicImplUnfoldOrFail x ps ap

proveVarAtomicImpl x ps ap@[nuP| Perm_LLVMFunPtr tp mb_p |] =
  partialSubstForceM mb_p
  "proveVarAtomicImpl: incomplete psubst: LLVM function pointer" >>>= \p ->
  case elemIndex (Perm_LLVMFunPtr (mbLift tp) p) ps of
    Just i -> implCopyConjM x ps i >>> implPopM x (ValPerm_Conj ps)
    _ -> proveVarAtomicImplUnfoldOrFail x ps ap

proveVarAtomicImpl x ps [nuP| Perm_IsLLVMPtr |]
  | Just i <- elemIndex Perm_IsLLVMPtr ps =
    implCopyConjM x ps i >>> implPopM x (ValPerm_Conj ps)

proveVarAtomicImpl x ps [nuP| Perm_IsLLVMPtr |]
  | Just i <- findIndex isLLVMFieldPerm ps
  , p@(Perm_LLVMField fp) <- ps !! i =
    implExtractConjM x ps i >>> implPopM x (ValPerm_Conj $ deleteNth i ps) >>>
    implSimplM Proxy (SImpl_LLVMFieldIsPtr x fp) >>>
    implPushM x (ValPerm_Conj $ deleteNth i ps) >>>
    implInsertConjM x p (deleteNth i ps) i >>>
    implPopM x (ValPerm_Conj ps)

proveVarAtomicImpl x ps [nuP| Perm_IsLLVMPtr |]
  | Just i <- findIndex isLLVMArrayPerm ps
  , p@(Perm_LLVMArray ap) <- ps !! i =
    implExtractConjM x ps i >>> implPopM x (ValPerm_Conj $ deleteNth i ps) >>>
    implSimplM Proxy (SImpl_LLVMArrayIsPtr x ap) >>>
    implPushM x (ValPerm_Conj $ deleteNth i ps) >>>
    implInsertConjM x p (deleteNth i ps) i >>>
    implPopM x (ValPerm_Conj ps)

proveVarAtomicImpl x ps mb_p@[nuP| Perm_IsLLVMPtr |] =
  proveVarAtomicImplUnfoldOrFail x ps mb_p

proveVarAtomicImpl x ps [nuP| Perm_NamedConj mb_n mb_args mb_off |] =
  let n = mbLift mb_n in
  proveVarImplH x (ValPerm_Conj ps) (mbMap2 (ValPerm_Named n)
                                     mb_args mb_off) >>>
  partialSubstForceM (mbMap2 (,) mb_args mb_off)
  "proveVarAtomicImpl: incomplete named permission" >>>= \(args,off) ->
  implNamedToConjM x n args off

proveVarAtomicImpl x aps@[Perm_LLVMFrame
                          fperms] mb_ap@[nuP| Perm_LLVMFrame mb_fperms |] =
  getPSubst >>>= \psubst ->
  case matchFramePerms psubst fperms mb_fperms of
    Just psubst' -> modifyPSubst (const psubst') >>> greturn ()
    Nothing -> proveVarAtomicImplUnfoldOrFail x aps mb_ap

proveVarAtomicImpl x aps@[Perm_LOwned ps] mb_ap@[nuP| Perm_LOwned (PExpr_Var z) |]
  | Left memb <- mbNameBoundP z
  = getPSubst >>>= \psubst ->
    case psubstLookup psubst memb of
      Just ps' | ps == ps' -> greturn ()
      Just _ -> proveVarAtomicImplUnfoldOrFail x aps mb_ap
      Nothing -> setVarM memb ps

proveVarAtomicImpl x aps@[Perm_LOwned ps] mb_ap@[nuP| Perm_LOwned mb_ps |] =
  partialSubstForceM mb_ps
  "proveVarAtomicImpl: incomplete lowned perms" >>>= \ps' ->
  if ps == ps' then greturn () else proveVarAtomicImplUnfoldOrFail x aps mb_ap

proveVarAtomicImpl x ps p@[nuP| Perm_LCurrent mb_l' |] =
  partialSubstForceM mb_l'
  "proveVarAtomicImpl: incomplete lcurrent perms" >>>= \l' ->
  case ps of
    _ | l' == PExpr_Var x ->
        implPopM x (ValPerm_Conj ps) >>>
        implSimplM Proxy (SImpl_LCurrentRefl x)
    [Perm_LCurrent l] | l == l' -> greturn ()
    [Perm_LCurrent (PExpr_Var l)] ->
      proveVarImpl l (fmap ValPerm_Conj1 p) >>>
      implSimplM Proxy (SImpl_LCurrentTrans x l l')

-- NOTE: existential Perm_Fun vars don't seem to make sense, as they translate
-- to a weird form of polymorphism...
{-
proveVarAtomicImpl x [Perm_Fun fun_perm] [nuP| Perm_Fun (PExpr_Var z) |]
  | Left memb <- mbNameBoundP z
  = getPSubst >>>= \psubst ->
    case psubstLookup psubst memb of
      Just fun_perm'
        | Just Refl <- funPermEq fun_perm fun_perm' -> greturn ()
      Just _ -> implFailM
      Nothing -> setVarM memb fun_perm
-}

proveVarAtomicImpl x ps mb_p@[nuP| Perm_Fun mb_fun_perm |] =
  partialSubstForceM mb_fun_perm
  "proveVarAtomicImpl: incomplete function perm" >>>= \fun_perm' ->
  foldr (\(i::Int,p) rest ->
          case p of
            Perm_Fun fun_perm
              | Just Refl <- funPermEq fun_perm fun_perm' ->
                implCopyConjM x ps i >>> implPopM x (ValPerm_Conj ps)
            _ -> rest)
  (proveVarAtomicImplUnfoldOrFail x ps mb_p)
  (zip [0..] ps)

proveVarAtomicImpl x ps [nuP| Perm_BVProp mb_prop |] =
  implPopM x (ValPerm_Conj ps) >>>
  partialSubstForceM mb_prop
  "proveVarAtomicImpl: incomplete bitvector proposition" >>>= \prop ->
  implTryProveBVProp x prop

proveVarAtomicImpl x aps mb_ap = proveVarAtomicImplUnfoldOrFail x aps mb_ap


-- | Prove @x:(p1 * ... * pn) |- x:(p1' * ... * pm')@ assuming that the LHS
-- conjunction is on the top of the stack, and push any leftover permissions for
-- @x@ back to the primary permissions for @x@.
--
-- The main complexity here is in dealing with the fact that both the left- and
-- right-hand sides could contain recursive permissions. We can't unfold
-- recursive permissions on both sides, because this could lead to an infinite
-- loop, where proving the unfolded implication depends on proving another copy
-- of the same implication. Instead, when we get to such a case, we have to pick
-- one side or the other to unfold, and then disallow unfolding the other side.
-- The exception is when we have an instance of the same recursive name on each
-- side, in which case we can prove the right-hand one from the left-hand one
-- and not unfold either side.
--
-- Additionally, the existence of recursive names on either side could be masked
-- by the existence of defined names that unfold to recursive names, so we have
-- to resolve all the defined names first.
--
-- Most of this machinery is actually handled by the 'proveVarImplH' cases for
-- recursive and defined names. Here, we just have to make sure to prove defined
-- names first, followed by recursive names and then other permissions.
proveVarConjImpl :: NuMatchingAny1 r => ExprVar a -> [AtomicPerm a] ->
                    Mb vars [AtomicPerm a] ->
                    ImplM vars s r (ps :> a) (ps :> a) ()

-- If we are done, we are done
proveVarConjImpl x ps [nuP| [] |] =
  implPopM x (ValPerm_Conj ps) >>> introConjM x

-- If there is a defined or recursive name on the right, prove it first,
-- ensuring that we only choose recursive names if there are no defined ones;
-- otherwise just choose the head of the list, i.e., i = 0
proveVarConjImpl x ps mb_ps =
  let maybe_i = mbLift $ fmap (\ps_r ->
                                findIndex isDefinedConjPerm ps_r <|>
                                findIndex isRecursiveConjPerm ps_r) mb_ps
      i = maybe 0 id maybe_i
      mb_p = fmap (!!i) mb_ps in
  proveVarAtomicImpl x ps mb_p >>>
  let mb_ps' = fmap (deleteNth i) mb_ps in
  proveVarImpl x (fmap ValPerm_Conj mb_ps') >>>
  (partialSubstForceM (mbMap2 (,) mb_ps' mb_p)
   "Incomplete psubst in proveVarConjImpl") >>>= \(ps',p) ->
  implInsertConjM x p ps' i


----------------------------------------------------------------------
-- * Proving Permission Implications
----------------------------------------------------------------------

-- | Prove @x:p'@, where @p@ may have existentially-quantified variables in it
proveVarImpl :: NuMatchingAny1 r => ExprVar a -> Mb vars (ValuePerm a) ->
                ImplM vars s r (ps :> a) ps ()
proveVarImpl x mb_p =
  getPerm x >>>= \ !p ->
  implPushM x p >>>
  implTraceM (\i -> string "proveVarImpl:" <> line <> ppImpl i x p mb_p) >>>
  proveVarImplH x p mb_p >>>

  -- Check that the top of the stack == mb_p
  partialSubstForceM mb_p "proveVarImpl: incomplete psubst" >>>= \p_req ->
  getTopDistPerm x >>>= \p_actual ->
  if p_req == p_actual then greturn () else
    implTraceM (\i ->
                 string "proveVarImpl: incorrect permission on top of the stack" </>
                 string "expected:" <+> permPretty i p_req </>
                 string "actual:" <+> permPretty i p_actual) >>>= error

-- | Prove @x:p'@ assuming that the primary permissions for @x@ have all been
-- pushed to the top of the stack and are equal to @p@. Pop the remaining
-- permissions for @x@ back to its primary permission when we are finished.
proveVarImplH :: NuMatchingAny1 r => ExprVar a -> ValuePerm a ->
                 Mb vars (ValuePerm a) ->
                 ImplM vars s r (ps :> a) (ps :> a) ()

-- Prove an empty conjunction trivially
proveVarImplH x p [nuP| ValPerm_Conj [] |] = implPopM x p >>> introConjM x

-- Prove x:eq(e) by calling proveVarEq; note that we do not eliminate
-- disjunctive permissions first because some trivial equalities do not require
-- any eq permissions on the left, and we do not eliminate equalities on the
-- left first because that may be the equality we are trying to prove!
proveVarImplH x p [nuP| ValPerm_Eq e |] = proveVarEq x p e

-- Eliminate any disjunctions and existentials on the left
proveVarImplH x (ValPerm_Or _ _) mb_p =
  elimOrsExistsM x >>>= \ !p -> proveVarImplH x p mb_p

-- Eliminate any disjunctions and existentials on the left
proveVarImplH x (ValPerm_Exists _) mb_p =
  elimOrsExistsM x >>>= \ !p -> proveVarImplH x p mb_p

-- Eliminate an equality permission for a variable on the left, i.e., prove x:p
-- from x:eq(y) by first proving y:p and then casting
proveVarImplH x p@(ValPerm_Eq (PExpr_Var y)) mb_p =
  introEqCopyM x (PExpr_Var y) >>>
  implPopM x p >>>
  proveVarImpl y mb_p >>>
  partialSubstForceM mb_p
  "proveVarImpl: incomplete psubst: introCast" >>>= \p' ->
  introCastM x y p'

-- Prove x:eq(y &+ off) |- x:p by proving y:p@off and then casting
proveVarImplH x p@(ValPerm_Eq e@(PExpr_LLVMOffset y off)) mb_p =
    introEqCopyM x e >>> implPopM x p >>>
    proveVarImpl y (fmap (offsetLLVMPerm off) mb_p) >>>
    partialSubstForceM mb_p
    "proveVarImpl: incomplete psubst: castLLVMPtr" >>>= \p_r ->
    castLLVMPtrM y (offsetLLVMPerm off p_r) off x

-- Prove x:(p1 \/ p2) by trying to prove x:p1 and x:p2 in two branches
proveVarImplH x p [nuP| ValPerm_Or mb_p1 mb_p2 |] =
  implCatchM
  (proveVarImplH x p mb_p1 >>>
   partialSubstForceM mb_p1
   "proveVarImpl: incomplete psubst: introOrL" >>>= \p1 ->
    partialSubstForceM mb_p2
   "proveVarImpl: incomplete psubst: introOrL"  >>>= \p2 ->
    introOrLM x p1 p2)
  (proveVarImplH x p mb_p2 >>>
   partialSubstForceM mb_p1
   "proveVarImpl: incomplete psubst: introOrR" >>>= \p1 ->
    partialSubstForceM mb_p2
    "proveVarImpl: incomplete psubst: introOrR"  >>>= \p2 ->
    introOrRM x p1 p2)

-- Prove x:exists (z:tp).p by proving x:p in an extended vars context
proveVarImplH x p [nuP| ValPerm_Exists mb_p |] =
  withExtVarsM (proveVarImplH x p $ mbCombine mb_p) >>>= \((), maybe_e) ->
  let e = fromMaybe (zeroOfType knownRepr) maybe_e in
  partialSubstForceM mb_p "proveVarImpl: incomplete psubst: introExists" >>>=
  introExistsM x e

-- If proving P<args1> |- P<args2> for the same named permission, we just need
-- to equalize the arguments and the offsets using proveNamedArgs. Note that we
-- currently are *not* solving for offsets on the right, meaning that
-- proveVarImpl will fail for offsets with existential variables in them.
proveVarImplH x p@(ValPerm_Named npn args off) [nuP| ValPerm_Named
                                                   mb_npn mb_args mb_off |]
  | Just (Refl, Refl, Refl) <- testNamedPermNameEq npn (mbLift mb_npn)
  , mbLift (fmap (offsetsEq off) mb_off) =
    (if permIsCopyable p then implCopyM x p >>> implPopM x p
     else greturn ()) >>>
    proveNamedArgs x npn args off mb_args

-- If proving x:p1 * ... * pn |- P<args>@off where P<args'>@off for some args'
-- occurs as one of the pi, then reduce to the above case
--
-- FIXME: if P is a defined permission, then it is possible that we can't prove
-- P<args'> |- P<args> but could still prove x:p1 * ... |- P<args> by unfolding
-- P, so we should also check that args' is compatible in some way with args
proveVarImplH x (ValPerm_Conj ps) mb_p@[nuP| ValPerm_Named
                                           mb_npn mb_args mb_off |]
  | npn <- mbLift mb_npn
  , TrueRepr <- nameIsConjRepr npn
  , (i, (args, off)):_ <-
      findMaybeIndices (\case
                           Perm_NamedConj npn' args off
                             | Just (Refl, Refl, Refl) <-
                                 testNamedPermNameEq npn npn'
                             , mbLift (fmap (offsetsEq off) mb_off) ->
                               Just (args, off)
                           _ -> Nothing) ps =
    (if atomicPermIsCopyable (Perm_NamedConj npn args off) then
       implCopyConjM x ps i >>> implPopM x (ValPerm_Conj ps)
     else
       implExtractConjM x ps i >>>
       implPopM x (ValPerm_Conj $ deleteNth i ps)) >>>
    implNamedFromConjM x npn args off >>>
    proveNamedArgs x npn args off mb_args

-- If proving P<args> where P is defined, unfold P
proveVarImplH x p mb_p@[nuP| ValPerm_Named mb_npn _ _ |]
  | DefinedSortRepr _ <- namedPermNameSort $ mbLift mb_npn =
    proveVarImplFoldRight x p mb_p

-- If proving P<args1> |- p where P is defined, unfold P
proveVarImplH x p@(ValPerm_Named npn args off) mb_p
  | DefinedSortRepr _ <- namedPermNameSort npn =
    proveVarImplUnfoldLeft x p mb_p Nothing

-- If proving x:p1 * ... * P<args1> * ... |- p where P is defined, unfold P
proveVarImplH x p@(ValPerm_Conj ps) mb_p
  | Just i <- findIndex isDefinedConjPerm ps =
    proveVarImplUnfoldLeft x p mb_p (Just i)

-- If proving P1<args1> |- P2<args2> where both P1 and P2 are recursive, try
-- unfolding P1 or P2, depending on the recursion flags
proveVarImplH x p@(ValPerm_Named
                   npn1 _ _) mb_p@[nuP| ValPerm_Named mb_npn2 _ _ |]
  | RecursiveSortRepr _ <- namedPermNameSort npn1
  , RecursiveSortRepr _ <- namedPermNameSort $ mbLift mb_npn2 =
    implRecFlagCaseM
    (proveVarImplFoldRight x p mb_p)
    (proveVarImplUnfoldLeft x p mb_p Nothing)

-- If proving x:p1 * ... |- P<args> where both P and at least one of the pi are
-- recursive, try unfolding P or the LHS, depending on the recursion flags. Note
-- that there are no defined perms on the LHS at this point because that would
-- have been caught by one of the above cases.
proveVarImplH x p@(ValPerm_Conj ps) mb_p@[nuP| ValPerm_Named mb_npn _ _ |]
  | Just i <- findIndex isRecursiveConjPerm ps
  , RecursiveSortRepr _ <- namedPermNameSort $ mbLift mb_npn =
    implRecFlagCaseM
    (proveVarImplUnfoldLeft x p mb_p (Just i))
    (proveVarImplFoldRight x p mb_p)

-- If proving P<args> where P is recursive and we have gotten to this case, we
-- know there are no recursive perms on the left, so unfold P
proveVarImplH x p mb_p@[nuP| ValPerm_Named mb_npn _ _ |]
  | RecursiveSortRepr _ <- namedPermNameSort $ mbLift mb_npn =
    proveVarImplFoldRight x p mb_p

-- If proving P<args> |- p1 * ... * pn for a conjoinable P, then change the LHS
-- to a conjunction and recurse
proveVarImplH x (ValPerm_Named npn args off) mb_p
  | TrueRepr <- nameIsConjRepr npn =
    implNamedToConjM x npn args off >>>
    proveVarImplH x (ValPerm_Conj1 $ Perm_NamedConj npn args off) mb_p

-- If proving P<args> |- p1 * ... * pn for a non-conjoinable recursive P, then
-- we unfold P because we will have to at some point to prove a conjunction
proveVarImplH x p@(ValPerm_Named npn _ _) mb_p =
  proveVarImplUnfoldLeft x p mb_p Nothing


{- FIXME: This is an example of how we used embedMbImplM to prove the body
   of one mu from another; remove it when we have used it for arrays
proveVarImplH x (ValPerm_Mu p_body) [nuP| ValPerm_Mu mb_p'_body |] =
  partialSubstForceM mb_p'_body
  "proveVarImpl: incomplete psubst: implMu" >>>= \p'_body ->
  embedMbImplM (fmap (\p -> distPermSet $ distPerms1 x p) p_body)
  (mbMap2 (\p p' -> proveVarImplH x p (emptyMb p') >>> greturn Refl)
   p_body p'_body) >>>= \mb_impl ->
  implSimplM Proxy (SImpl_Mu x p_body p'_body mb_impl)
-}

-- If x:eq(LLVMword(e)) then we cannot prove any pointer permissions for it
proveVarImplH x p@(ValPerm_Eq (PExpr_LLVMWord _)) mb_p@[nuP| ValPerm_Conj _ |] =
  implFailVarM "proveVarImplH" x p mb_p

-- If proving a function permission for an x we know equals a constant function
-- handle f, look up the function permission for f
proveVarImplH x p@(ValPerm_Eq (PExpr_Fun f)) mb_p@[nuP| ValPerm_Conj
                                                      [Perm_Fun mb_fun_perm] |] =
  (view implStatePermEnv <$> gget) >>>= \env ->
  case lookupFunPerm env f of
    Just (SomeFunPerm fun_perm, ident)
      | [nuP| Just Refl |] <- fmap (funPermEq fun_perm) mb_fun_perm ->
        introEqCopyM x (PExpr_Fun f) >>>
        implPopM x p >>>
        implSimplM Proxy (SImpl_ConstFunPerm x f fun_perm ident)
    _ -> implFailVarM "proveVarImplH" x p mb_p

proveVarImplH x p@(ValPerm_Eq _) mb_p@[nuP| ValPerm_Conj _ |] =
  implFailVarM "proveVarImplH" x p mb_p
  -- FIXME HERE: are there other x:eq(e) |- x:pps cases?

-- For conjunction |- conjunction, call proveVarConjImpl
proveVarImplH x (ValPerm_Conj ps) [nuP| ValPerm_Conj mb_ps |] =
  proveVarConjImpl x ps mb_ps

-- Prove x:p |- x:z@off for existential variable z by setting z = p
proveVarImplH x p mb_p@[nuP| ValPerm_Var z mb_off |]
  | Left memb <- mbNameBoundP z =
    getPSubst >>>= \psubst ->
    case (partialSubst psubst mb_off, psubstLookup psubst memb) of
      (Just off, Just (PExpr_ValPerm p')) ->
        let mb_p' = fmap (const $ offsetPerm off p') z in
        implTraceM (\i -> string "proveVarImplH:" <> line <> ppImpl i x p mb_p') >>>
        proveVarImplH x p mb_p'
      (Just off, Just (PExpr_Var z')) ->
        let mb_p' = fmap (const $ ValPerm_Var z' off) z in
        implTraceM (\i -> string "proveVarImplH:" <> line <> ppImpl i x p mb_p') >>>
        proveVarImplH x p mb_p'
      (Just off, Nothing) ->
        setVarM memb (PExpr_ValPerm $ offsetPerm (negatePermOffset off) p) >>>
        if permIsCopyable p then
          implCopyM x p >>> implPopM x p
        else
          greturn ()
      (Nothing, _) ->
        implFailVarM "proveVarImplH" x p mb_p

-- Prove x:z@off |- x:z@off for variable z by reflexivity
proveVarImplH x (ValPerm_Var z off) [nuP| ValPerm_Var mb_z' mb_off |]
  | Right z' <- mbNameBoundP mb_z'
  , z' == z
  , mbLift (fmap (offsetsEq off) mb_off) = greturn ()

-- Fail if nothing else matched
proveVarImplH x p mb_p = implFailVarM "proveVarImplH" x p mb_p


----------------------------------------------------------------------
-- * Proving Permission Implications for Existential Variables
----------------------------------------------------------------------

-- | Prove an existentially-quantified permission where the variable holding the
-- permission could itself be existentially-quantified. Return the variable that
-- the potentially existentially-quantified has been set to.
proveExVarImpl :: NuMatchingAny1 r => PartialSubst vars -> Mb vars (Name tp) ->
                  Mb vars (ValuePerm tp) ->
                  ImplM vars s r (ps :> tp) ps (Name tp)

-- If the variable is instantiated to another variable, just call proveVarImpl
proveExVarImpl psubst mb_x mb_p
  | Just (PExpr_Var n) <- partialSubst psubst (fmap PExpr_Var mb_x)
  = proveVarImpl n mb_p >>> greturn n

-- If the variable is instantiated to a non-variable expression, bind a fresh
-- variable for it and then call proveVarImpl
proveExVarImpl psubst mb_x mb_p
  | Just e <- partialSubst psubst (fmap PExpr_Var mb_x) =
    (case mbNameBoundP mb_x of
        Left memb -> getExVarType memb
        Right x -> implGetVarType x) >>>= \tp ->
    implLetBindVar tp e >>>= \n ->
    implPopM n (ValPerm_Eq e) >>>
    proveVarImpl n mb_p >>> greturn n

-- Special case: if proving an LLVM frame permission, look for an LLVM frame in
-- the current context and use it
proveExVarImpl _ mb_x mb_p@[nuP| ValPerm_Conj [Perm_LLVMFrame mb_fperms] |]
  | Left memb <- mbNameBoundP mb_x =
    getExVarType memb >>>= \x_tp ->
    implFindVarOfType x_tp >>>= \maybe_n ->
    case maybe_n of
      Just n -> setVarM memb (PExpr_Var n) >>> proveVarImpl n mb_p >>> greturn n
      Nothing ->
        implFailMsgM "proveExVarImpl: No LLVM frame pointer in scope"

-- Otherwise we fail
proveExVarImpl _ mb_x mb_p =
  implTraceM (\i -> string "proveExVarImpl: existential variable" <+>
                    permPretty i mb_x <+>
                    string "not resolved when trying to prove:" </>
                    permPretty i mb_p) >>>=
  implFailM


----------------------------------------------------------------------
-- * Proving Multiple Permission Implications
----------------------------------------------------------------------

-- | A list of distinguished permissions with existential variables
type ExDistPerms vars ps = Mb vars (DistPerms ps)

-- | Existentially quantify a list of distinguished permissions over the empty
-- set of existential variables
distPermsToExDistPerms :: DistPerms ps -> ExDistPerms RNil ps
distPermsToExDistPerms = emptyMb

-- FIXME: move to Hobbits
rlistHead :: RAssign f (ctx :> a) -> f a
rlistHead (_ :>: x) = x

-- | Combine a list of names and a sequence of permissions inside a name-binding
-- to get an 'ExDistPerms'
mbValuePermsToExDistPerms :: RAssign Name ps -> Mb vars (ValuePerms ps) ->
                             ExDistPerms vars ps
mbValuePermsToExDistPerms MNil mb_ps = fmap (const DistPermsNil) mb_ps
mbValuePermsToExDistPerms (xs :>: x) mb_ps =
  mbMap2 (\ps p -> DistPermsCons ps x p)
  (mbValuePermsToExDistPerms xs (fmap RL.tail mb_ps))
  (fmap rlistHead mb_ps)

-- | Substitute arguments into a function permission to get the existentially
-- quantified input permissions needed on the arguments
funPermExDistIns :: FunPerm ghosts args ret -> RAssign Name args ->
                    ExDistPerms ghosts args
funPermExDistIns fun_perm args =
  mbValuePermsToExDistPerms args $ fmap (varSubst (permVarSubstOfNames args)) $
  funPermIns fun_perm

-- | A splitting of an existential list of permissions into a prefix, a single
-- variable plus permission, and then a suffix
data ExDistPermsSplit vars ps where
  ExDistPermsSplit :: ExDistPerms vars ps1 ->
                      Mb vars (ExprVar a) -> Mb vars (ValuePerm a) ->
                      ExDistPerms vars ps2 ->
                      ExDistPermsSplit vars (ps1 :> a :++: ps2)

-- | Extend the @ps@ argument of a 'ExDistPermsSplit'
extExDistPermsSplit :: ExDistPermsSplit vars ps ->
                       Mb vars (ExprVar b) -> Mb vars (ValuePerm b) ->
                       ExDistPermsSplit vars (ps :> b)
extExDistPermsSplit (ExDistPermsSplit ps1 mb_x mb_p ps2) y p' =
  ExDistPermsSplit ps1 mb_x mb_p $
  mbMap2 DistPermsCons ps2 y `mbApply` p'


-- | Find a permission in the supplied list where 'proveExVarImpl' will succeed,
-- given the current set of existential variables whose values have not been
-- set, and split out that permission from the list
findProvablePerm :: Mb vars (NameSet CrucibleType) -> ExDistPerms vars ps ->
                    Maybe (ExDistPermsSplit vars ps)

-- First try to recurse on the LHS and see if we can prove a permission there
findProvablePerm mbUnsetVars [nuP| DistPermsCons ps mb_x mb_p |]
  | Just ret <- findProvablePerm mbUnsetVars ps =
    Just $ extExDistPermsSplit ret mb_x mb_p

-- If not, test if x and all the needed vars in p are set so we can choose x
findProvablePerm mbUnsetVars [nuP| DistPermsCons ps mb_x mb_p |]
  | mbNeeded <- mbMap2 (\x p -> NameSet.insert x $ neededVars p) mb_x mb_p
  , mbLift $ mbMap2 (\s1 s2 ->
                      NameSet.null $
                      NameSet.intersection s1 s2) mbNeeded mbUnsetVars =
    Just $ ExDistPermsSplit ps mb_x mb_p (fmap (const DistPermsNil) mb_p)

-- Special case: an LLVMFrame permission can always be proved
findProvablePerm _ [nuP| DistPermsCons ps mb_x
                       mb_p@(ValPerm_Conj [Perm_LLVMFrame _]) |] =
  Just $ ExDistPermsSplit ps mb_x mb_p (fmap (const DistPermsNil) mb_p)

-- Otherwise we fail
findProvablePerm _ _ = Nothing


-- | Prove a list of existentially-quantified distinguished permissions, adding
-- those proofs to the top of the stack. In the case that a the variable itself
-- whose permissions are being proved is existentially-quantified --- that is,
-- if we are proving @x:p@ for existentially-quantified @x@ --- then the
-- resulting permission on top of the stack will be @y:[e/x]p@, where @y@ is a
-- fresh variable and @e@ is the expression used to instantiate @x@.
proveVarsImplAppend :: NuMatchingAny1 r => ExDistPerms vars ps ->
                       ImplM vars s r (ps_in :++: ps) ps_in ()
proveVarsImplAppend [nuP| DistPermsNil |] = return ()
proveVarsImplAppend ps =
  getPSubst >>>= \psubst ->
  getPerms >>>= \cur_perms ->
  case findProvablePerm (psubstMbUnsetVars psubst) ps of
    Just (ExDistPermsSplit ps1 mb_x mb_p ps2) ->
      proveExVarImpl psubst mb_x mb_p >>>= \x ->
      proveVarsImplAppend (mbMap2 appendDistPerms ps1 ps2) >>>
      implMoveUpM cur_perms (mbDistPermsToProxies ps1) x (mbDistPermsToProxies ps2)
    Nothing ->
      implTraceM
      (\i ->
        sep [string
             "Could not determine enough variables to prove permissions:" </>
             permPretty i ps]) >>>=
      implFailM


-- | Prove that @'RNil' :++: ctx@ equals @ctx@
--
-- FIXME: move to Hobbits
prependRNilEq :: RAssign f ctx -> RNil :++: ctx :~: ctx
prependRNilEq MNil = Refl
prependRNilEq (ctx :>: _) | Refl <- prependRNilEq ctx = Refl

-- | Prove a list of existentially-quantified distinguished permissions
proveVarsImpl :: NuMatchingAny1 r => ExDistPerms vars as ->
                 ImplM vars s r as RNil ()
proveVarsImpl ps
  | Refl <- mbLift (fmap prependRNilEq $ mbDistPermsToValuePerms ps) =
    proveVarsImplAppend ps
