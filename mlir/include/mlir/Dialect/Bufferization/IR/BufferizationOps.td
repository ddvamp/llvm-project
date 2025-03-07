//===- BufferizationOps.td - Bufferization op definitions ----------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef BUFFERIZATION_OPS
#define BUFFERIZATION_OPS

include "mlir/Dialect/Bufferization/IR/AllocationOpInterface.td"
include "mlir/Dialect/Bufferization/IR/BufferizableOpInterface.td"
include "mlir/Dialect/Bufferization/IR/BufferizationBase.td"
include "mlir/Interfaces/InferTypeOpInterface.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/Interfaces/CopyOpInterface.td"

class Bufferization_Op<string mnemonic, list<Trait> traits = []>
    : Op<Bufferization_Dialect, mnemonic, traits>;

//===----------------------------------------------------------------------===//
// AllocTensorOp
//===----------------------------------------------------------------------===//

def Bufferization_AllocTensorOp : Bufferization_Op<"alloc_tensor",
    [AttrSizedOperandSegments, BufferizableOpInterface,
     DeclareOpInterfaceMethods<ReifyRankedShapedTypeOpInterface>]> {
  let summary = "allocate buffer for a tensor";

  let description = [{
    `bufferization.alloc_tensor` materializes an uninitialized tensor with a
    given shape (dynamic or static). It always bufferizes to a new buffer
    allocation of the given shape. The optional `copy` operand specifies the
    contents of the tensors. If no `copy` operand is specified, reading from the
    result of an `alloc_tensor` op yields an undefined value.

    If `copy` is specified, no dynamic sizes should be passed, since they are
    the same as the dynamic sizes of the `copy` operand.

    `alloc_tensor` is a helper op for bufferization. The operation is provided
    as an anchor that marks the beginning of a new tensor SSA use-def chain. It
    can be used to control in-place bufferization decisions during One-Shot
    Bufferize: The bufferized result of a `bufferization.alloc_tensor` does not
    alias with any other buffer, so it can be used to resolve read-after-write
    conflicts that would have been introduced by the in-place bufferization of
    another op.

    The optional `memory_space` attribute specifies the memory space when
    bufferizing this op. The memory space is inferred from `copy` if specified.
    If neither `copy` nor `memory_space` is specified, the default memory space
    is used during bufferization.

    The optional `size_hint` operand specifies the number of non-zero elements
    for sparse tensors. The value of `size_hint` should be not less than 1 and
    not larger than the linear size of the corresponding dense tensor type. If
    this requirement is not met, the behavior of the operator is undefined.

    Both dense and sparse tensor types are supported. The result of a
    `bufferization.alloc_tensor` is a tensor value that can be used like any
    other tensor value. In practice, it is often used as the "out" operand of
    another op. Sparse tensor allocations should always be used in a local
    construction operation and never escape the function boundary directly.

    Example:

    ```mlir
    %c = bufferization.alloc_tensor(%d1, %d2) : tensor<?x?xf32, #SparseMatrix>
    %0 = linalg.matmul
      ins(%a, %b: tensor<?x?xf32, #SparseMatrix>, tensor<?x?xf32, #SparseMatrix>)
      outs(%c: tensor<?x?xf32, #SparseMatrix>) -> tensor<?x?xf32, #SparseMatrix>
    return %0 : tensor<?x?xf32, #SparseMatrix>
    ```

    ```mlir
    %c = bufferization.alloc_tensor(%d1, %d2) size_hint = %noe
      : tensor<?x?xf32, #SparseMatrix>
    ```

    Note: An `alloc_tensor` with a `copy` should also be expressed as an
    `alloc_tensor` without `copy`, followed by a `copy_tensor`.
  }];

  let arguments = (ins Variadic<Index>:$dynamic_sizes,
                       Optional<AnyTensor>:$copy,
                       Optional<Index>:$size_hint,
                       OptionalAttr<AnyAttr>:$memory_space);

  let results = (outs AnyTensor:$result);

  let extraClassDeclaration = [{
    LogicalResult bufferize(RewriterBase &rewriter,
                            const BufferizationOptions &options);

    bool resultBufferizesToMemoryWrite(OpResult opResult,
                                       const AnalysisState &state);

    bool bufferizesToAllocation(OpResult opResult) { return true; }

    bool bufferizesToMemoryRead(OpOperand &opOperand,
                                const AnalysisState &state);

    bool bufferizesToMemoryWrite(OpOperand &opOperand,
                                 const AnalysisState &state);

    AliasingOpResultList getAliasingOpResults(
        OpOperand &opOperand, const AnalysisState &state);

    FailureOr<BaseMemRefType> getBufferType(
        Value value, const BufferizationOptions &options,
        const DenseMap<Value, BaseMemRefType> &fixedTypes);

    RankedTensorType getType() {
      return ::llvm::cast<RankedTensorType>(getResult().getType());
    }

    // Return true if the size of the tensor is dynamic at `idx`
    bool isDynamicDim(unsigned idx) {
      return getType().isDynamicDim(idx);
    }

    // Return the argument position that contains the dynamic size of
    // the tensor at dimension `idx`. Asserts that the shape is
    // dynamic at that `idx`.
    unsigned getIndexOfDynamicSize(unsigned idx) {
      assert(!getCopy() && "no dim sizes specified when copying a tensor");
      assert(isDynamicDim(idx) && "expected dynamic size");
      ArrayRef<int64_t> shape = getType().getShape();
      return std::count_if(
          shape.begin(), shape.begin() + idx,
          [&](int64_t size) { return ShapedType::isDynamic(size); });
    }

    // Return the Value of the dynamic size of the tensor at dimension
    // `idx`. Asserts that the shape is dynamic at that `idx.
    Value getDynamicSize(OpBuilder &b, unsigned idx);

    // Assert that the size of the result tensor is static at `idx`
    // and return the shape.
    int64_t getStaticSize(unsigned idx) {
      assert(!isDynamicDim(idx) && "expected static size");
      return getType().getShape()[idx];
    }
  }];

  let builders = [
    // Build an op without `copy` or `memory_space` or `size_hint`.
    OpBuilder<(ins "RankedTensorType":$type, "ValueRange":$dynamicSizes)>,

    // Build an op without `memory_space` or `size_hint`.
    OpBuilder<(ins "RankedTensorType":$type, "ValueRange":$dynamicSizes,
                   "Value":$copy)>,

    // Build an op without `size_hint`.
    OpBuilder<(ins "TensorType":$type, "ValueRange":$dynamicSizes,
                   "Value":$copy, "IntegerAttr":$memory_space)>,
  ];

  let hasCanonicalizer = 1;
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// CloneOp
//===----------------------------------------------------------------------===//

def Bufferization_CloneOp : Bufferization_Op<"clone", [
    CopyOpInterface,
    DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
    DeclareOpInterfaceMethods<AllocationOpInterface, ["buildDealloc", "buildClone"]>
  ]> {
  let builders = [
    OpBuilder<(ins "Value":$value), [{
      return build($_builder, $_state, value.getType(), value);
    }]>];

  let summary = "clone a memref";
  let description = [{
    Clones the data in the input view into an implicitly defined output view.

    Usage:

    ```mlir
    %arg1 = bufferization.clone %arg0 : memref<?xf32> to memref<?xf32>
    ```

    Valid implementations of this operation may alias the input and output
    views or create an actual copy. Mutating the source or result
    of the clone operation after the clone operation thus leads to undefined
    behavior.
  }];

  let arguments = (ins Arg<AnyRankedOrUnrankedMemRef, "", []>:$input);
  let results = (outs Arg<AnyRankedOrUnrankedMemRef, "", []>:$output);

  let extraClassDeclaration = [{
    Value getSource() { return getInput(); }
    Value getTarget() { return getOutput(); }
  }];

  let assemblyFormat = "$input attr-dict `:` type($input) `to` type($output)";

  let hasFolder = 1;
  let hasCanonicalizer = 1;
}

//===----------------------------------------------------------------------===//
// CopyTensorOp
//===----------------------------------------------------------------------===//

def Bufferization_CopyTensorOp : Bufferization_Op<"copy_tensor",
    [BufferizableOpInterface, SameOperandsAndResultType,
     DeclareOpInterfaceMethods<ReifyRankedShapedTypeOpInterface>]> {
  let summary = "copy a tensor";

  let description = [{
    Copy the contents of the source tensor into the destination tensor. This
    operation is guaranteed to bufferize to a memory copy.
  }];

  let arguments = (ins AnyTensor:$source,
                       AnyTensor:$dest);

  let results = (outs AnyTensor:$result);

  let extraClassDeclaration = [{
    LogicalResult bufferize(RewriterBase &rewriter,
                            const BufferizationOptions &options);

    bool bufferizesToMemoryRead(OpOperand &opOperand,
                                const AnalysisState &state);

    bool bufferizesToMemoryWrite(OpOperand &opOperand,
                                 const AnalysisState &state);

    AliasingOpResultList getAliasingOpResults(
        OpOperand &opOperand, const AnalysisState &state);

    RankedTensorType getType() {
      return ::llvm::cast<RankedTensorType>(getResult().getType());
    }
  }];

  let assemblyFormat = "$source `,` $dest attr-dict `:` type($source)";
}

//===----------------------------------------------------------------------===//
// DeallocTensorOp
//===----------------------------------------------------------------------===//

def Bufferization_DeallocTensorOp : Bufferization_Op<"dealloc_tensor",
    [BufferizableOpInterface]> {
  string summary = "release underlying storage format of given tensor";
  string description = [{
    `bufferization.dealloc_tensor` is a buffer deallocation in tensor land. This
    op can be used for manual buffer deallocation. Some bufferizations (such as
    One-Shot Bufferize) take care of buffer deallocation, in which case this op
    is usually not needed. Details can be found in the documentation of the
    respective bufferization passes.

    In case of a dense tensor, this op lowers to a `memref.dealloc` op during
    bufferization.

    In case of a sparse tensor, this op releases the underlying sparse storage
    format for a tensor that materialized earlier through a `new` operation, a
    `convert` operation with annotated destination tensor type (unless the
    convert is folded away), or a `bufferization.alloc_tensor` operation. The
    release operation should only be called once for any materialized tensor.
    After this operation, any subsequent `memref` querying operation on the
    tensor returns undefined results.

    Example:

    ```mlir
    bufferization.dealloc_tensor %tensor : tensor<1024x1024xf64, #CSR>
    ```
  }];

  let arguments = (ins AnyTensor:$tensor);
  let results = (outs);
  let assemblyFormat = "$tensor attr-dict `:` type($tensor)";

  let extraClassDeclaration = [{
    bool bufferizesToMemoryRead(OpOperand &opOperand,
                                const AnalysisState &state) const {
      return false;
    }

    bool bufferizesToMemoryWrite(OpOperand &opOperand,
                                 const AnalysisState &state) const {
      return false;
    }

    AliasingOpResultList getAliasingOpResults(
        OpOperand &opOperand, const AnalysisState &state) const {
      return {};
    }

    LogicalResult bufferize(RewriterBase &rewriter,
                            const BufferizationOptions &options);
  }];
}

//===----------------------------------------------------------------------===//
// ToTensorOp
//===----------------------------------------------------------------------===//

def Bufferization_ToTensorOp : Bufferization_Op<"to_tensor", [
    BufferizableOpInterface,
    SameOperandsAndResultShape,
    SameOperandsAndResultElementType,
    TypesMatchWith<"result type matches tensor equivalent of 'memref'",
                   "memref", "result",
                   "memref::getTensorTypeFromMemRefType($_self)">
  ]> {
  let summary = "create a tensor from a `memref`";
  let description = [{
    An operation that creates a tensor from a `memref`. The result value is a
    tensor whose shape and element type match the memref operand.

    The opposite of this op is `to_memref`. Together, these two ops are
    useful for source/target materializations when doing type conversions
    involving tensors and memrefs.

    Example:

    ```mlir
    // Produces a value of tensor<4x?xf32> type.
    %t = bufferization.to_tensor %m : memref<4x?xf32, #layout, 0>
    ```

    If the `writable` unit attribute is set, the produced tensor is considered
    "writable" during bufferization. Otherwise, every OpOperand that bufferizes
    to a write to the future buffer of the resulting tensor (or an alias
    thereof) will bufferize out-of-place to prevent emitting any writes to
    `memref` during bufferization.

    If the given memref does not alias with any other memref passed to another
    `to_tensor` op, the `restrict` unit attribute can be set. Only such
    operations are supported by One-Shot Bufferize. (Otherwise, potential memref
    aliasing relationships would have to be captured in One-Shot Bufferize.)

    Example:

    ```
    %t = bufferization.to_tensor %m restrict writable : memref<4xf32>

    // %t is writable, so the tensor.insert may bufferize in-place in the
    // absence of other conflicts.
    %r = tensor.insert %f into %t[%idx] : tensor<4xf32>
    ```

    `to_tensor` ops are not bufferized. They are expected to fold away after
    bufferization. If there are non-bufferizable ops in the IR and
    `allowUnknownOps` is set, they may be part of the resulting IR and not fold
    away. However, such IR is no longer bufferizable with One-Shot Bufferize.
  }];

  let arguments = (ins Arg<AnyRankedOrUnrankedMemRef,
                       "the reference to load from", [MemRead]>:$memref,
                       UnitAttr:$restrict, UnitAttr:$writable);
  let results = (outs AnyTensor:$result);

  let extraClassDeclaration = [{
    /// The result of a to_tensor is always a tensor.
    TensorType getType() {
      Type resultType = getResult().getType();
      if (::llvm::isa<TensorType>(resultType))
        return ::llvm::cast<TensorType>(resultType);
      return {};
    }

    //===------------------------------------------------------------------===//
    // BufferizableOpInterface implementation
    //===------------------------------------------------------------------===//

    LogicalResult bufferize(RewriterBase &rewriter,
                            const BufferizationOptions &options) const {
      // to_tensor/to_memref pairs fold away after bufferization.
      return success();
    }

    bool isWritable(Value value, const AnalysisState &state);

    FailureOr<BaseMemRefType> getBufferType(
        Value value, const BufferizationOptions &options,
        const DenseMap<Value, BaseMemRefType> &fixedTypes) {
      return ::llvm::cast<BaseMemRefType>(getMemref().getType());
    }
  }];

  let assemblyFormat = [{
    $memref (`restrict` $restrict^)? (`writable` $writable^)? attr-dict
      `:` type($memref)
  }];

  let hasCanonicalizer = 1;
  let hasFolder = 1;
}


//===----------------------------------------------------------------------===//
// ToMemrefOp
//===----------------------------------------------------------------------===//

def Bufferization_ToMemrefOp : Bufferization_Op<"to_memref", [
    BufferizableOpInterface,
    SameOperandsAndResultShape,
    SameOperandsAndResultElementType,
    Pure,
    TypesMatchWith<"type of 'tensor' is the tensor equivalent of 'memref'",
                   "memref", "tensor",
                   "memref::getTensorTypeFromMemRefType($_self)">
  ]> {
  let summary = "cast a tensor to memref";
  let description = [{
    An operation that returns the future buffer of a `tensor`.

    ```mlir
    // Result type is memref<4x?xf32, #layout, 0>
    %m = bufferization.to_memref %t : memref<4x?xf32, #layout, 0>
    ```

    This operation is a specialized variant of the built-in
    `unrealized_conversion_cast` and is used to make sure that the IR stays
    valid at any point during the bufferization.

    The `read_only` attribute can optionally be set, indicating to the
    bufferization that the buffer returned by this op (or an alias created from
    the returned buffer) will not be written to.
  }];

  let arguments = (ins AnyTensor:$tensor, UnitAttr:$read_only);
  let results = (outs AnyRankedOrUnrankedMemRef:$memref);

  let extraClassDeclaration = [{
    //===------------------------------------------------------------------===//
    // BufferizableOpInterface implementation
    //===------------------------------------------------------------------===//

    // Note: ToMemrefOp / ToTensorOp are temporary ops that are inserted at the
    // bufferization boundary. When One-Shot bufferization is complete, there
    // should be no such ops left over. If `allowUnknownOps` (or after running a
    // partial bufferization pass), such ops may be part of the resulting IR,
    // but such IR may no longer be analyzable by One-Shot analysis.

    bool bufferizesToMemoryRead(OpOperand &opOperand,
                                const AnalysisState &state) const {
      // It is unknown whether the resulting memref will be read or not.
      return true;
    }

    bool bufferizesToMemoryWrite(OpOperand &opOperand,
                                 const AnalysisState &state) {
      return !getReadOnly();
    }

    AliasingOpResultList getAliasingOpResults(
        OpOperand &opOperand, const AnalysisState &state) const {
      return {};
    }

    LogicalResult bufferize(RewriterBase &rewriter,
                            const BufferizationOptions &options);
  }];

  let assemblyFormat = [{
    $tensor (`read_only` $read_only^)? attr-dict `:` type($memref)
  }];

  let hasFolder = 1;
  let hasCanonicalizer = 1;
}

#endif // BUFFERIZATION_OPS
