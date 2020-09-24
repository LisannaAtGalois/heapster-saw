
From Coq          Require Import Lists.List.
From Coq          Require Import String.
From Coq          Require Import Vectors.Vector.
From CryptolToCoq Require Import SAWCoreScaffolding.
From CryptolToCoq Require Import SAWCoreVectorsAsCoqVectors.

From CryptolToCoq Require Import SAWCorePrelude.

Import ListNotations.

Module loops.

Definition add_loop__tuple_fun : ((@CompM.lrtTupleType) (((@CompM.LRT_Cons) (((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm1 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Ret) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))))))))))) (((@CompM.LRT_Nil)))))) :=
  ((@CompM.multiFixM) (((@CompM.LRT_Cons) (((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm1 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Ret) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))))))))))) (((@CompM.LRT_Nil))))) ((fun (add_loop : ((@CompM.lrtToType) (((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm1 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Ret) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))))))))))))) => ((pair) ((fun (p0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) (p1 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.letRecM) (((@CompM.LRT_Cons) (((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (p0_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (p1_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Ret) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))))))))))) (((@CompM.LRT_Nil))))) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (f : ((@CompM.lrtToType) (((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (p0_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (p1_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Ret) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))))))))))))) => ((pair) ((fun (p0_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) (p1_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => if ((@SAWCoreScaffolding.not) (((@SAWCorePrelude.bvEq) (1) (if ((@SAWCoreVectorsAsCoqVectors.bvult) (64) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.nil) (_))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) (((@projT1) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_elimEx0 : ((@SAWCorePrelude.bitvector) (64))) => unit)) (p1_0)))) then ((Vector.cons) (_) (((@SAWCoreScaffolding.true))) (_) (((Vector.nil) (_)))) else ((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.nil) (_))))) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.nil) (_)))))))) then if ((@SAWCoreScaffolding.not) (((@SAWCorePrelude.bvSCarry) (63) (((@projT1) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_elimEx0 : ((@SAWCorePrelude.bitvector) (64))) => unit)) (p0_0))) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.false))) (_) (((Vector.cons) (_) (((@SAWCoreScaffolding.true))) (_) (((Vector.nil) (_)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) then ((((@errorM) (CompM) (_))) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) (("proveVarEqH: Could not prove
  x11:true -o (z28,z27,z26,z25,z24,z23,z22). eq((1*x11+1))")%string)) else ((((@errorM) (CompM) (_))) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) (("Failed Assert at ProgramLoc {plFunction = add_loop, plSourceLoc = /Users/eddy/galois/saw-script/deps/heapster-saw/examples/loop.c:8:8}")%string)) else ((((@returnM) (CompM) (_))) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) (p0_0)))) (tt)))) ((fun (f : ((@CompM.lrtToType) (((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (p0_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (p1_0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Ret) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))))))))))))) => ((f) (p0) (p1))))))) (tt))))).

Definition add_loop : ((@CompM.lrtToType) (((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm0 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Fun) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) ((fun (perm1 : ((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit)))) => ((@CompM.LRT_Ret) (((@sigT) (((@SAWCorePrelude.bitvector) (64))) ((fun (x_ex0 : ((@SAWCorePrelude.bitvector) (64))) => unit))))))))))))) :=
  ((SAWCoreScaffolding.fst) (((@add_loop__tuple_fun)))).

End loops.
