/* Copyright 2022 NVIDIA Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#include "sparse/array/csc/spmv.h"
#include "sparse/array/csc/spmv_template.inl"
#include "sparse/util/cusparse_utils.h"
#include "sparse/util/dispatch.h"

namespace sparse {

template <>
struct CSCSpMVColSplitImpl<VariantKind::GPU> {
  template <LegateTypeCode INDEX_CODE, LegateTypeCode VAL_CODE>
  void operator()(CSCSpMVColSplitArgs& args) const
  {
    using INDEX_TY = legate_type_of<INDEX_CODE>;
    using VAL_TY   = legate_type_of<VAL_CODE>;

    auto& y      = args.y;
    auto& A_pos  = args.A_pos;
    auto& A_crd  = args.A_crd;
    auto& A_vals = args.A_vals;
    auto& x      = args.x;

    // Break out early if the iteration space partition is empty.
    if (x.domain().empty()) return;

    // Get context sensitive objects.
    auto handle = get_cusparse();
    auto stream = get_cached_stream();
    CHECK_CUSPARSE(cusparseSetStream(handle, stream));

    // Construct the CUSPARSE objects from individual regions.
    auto cusparse_y = makeCuSparseDenseVec<VAL_TY>(y);
    auto cusparse_x = makeCuSparseDenseVec<VAL_TY>(x);
    auto cusparse_A =
      makeCuSparseCSC<INDEX_TY, VAL_TY>(A_pos, A_crd, A_vals, y.domain().get_volume() /* rows */);

    // Make the CUSPARSE calls.
    VAL_TY alpha   = 1.0;
    VAL_TY beta    = 0.0;
    size_t bufSize = 0;
    CHECK_CUSPARSE(cusparseSpMV_bufferSize(handle,
                                           CUSPARSE_OPERATION_NON_TRANSPOSE,
                                           &alpha,
                                           cusparse_A,
                                           cusparse_x,
                                           &beta,
                                           cusparse_y,
                                           cusparseDataType<VAL_TY>(),
#if (CUSPARSE_VER_MAJOR < 11 || CUSPARSE_VER_MINOR < 2)
                                           CUSPARSE_MV_ALG_DEFAULT,
#else
                                           CUSPARSE_SPMV_ALG_DEFAULT,
#endif
                                           &bufSize));
    // Allocate a buffer if we need to.
    void* workspacePtr = nullptr;
    if (bufSize > 0) {
      DeferredBuffer<char, 1> buf({0, bufSize - 1}, Memory::GPU_FB_MEM);
      workspacePtr = buf.ptr(0);
    }
    // Finally do the SpMV.
    CHECK_CUSPARSE(cusparseSpMV(handle,
                                CUSPARSE_OPERATION_NON_TRANSPOSE,
                                &alpha,
                                cusparse_A,
                                cusparse_x,
                                &beta,
                                cusparse_y,
                                cusparseDataType<VAL_TY>(),
#if (CUSPARSE_VER_MAJOR < 11 || CUSPARSE_VER_MINOR < 2)
                                CUSPARSE_MV_ALG_DEFAULT,
#else
                                CUSPARSE_SPMV_ALG_DEFAULT,
#endif
                                workspacePtr));
    // Destroy the created objects.
    CHECK_CUSPARSE(cusparseDestroyDnVec(cusparse_y));
    CHECK_CUSPARSE(cusparseDestroyDnVec(cusparse_x));
    CHECK_CUSPARSE(cusparseDestroySpMat(cusparse_A));
    CHECK_CUDA_STREAM(stream);
  }
};

/*static*/ void CSCSpMVColSplit::gpu_variant(legate::TaskContext& context)
{
  csc_spmv_col_split_template<VariantKind::GPU>(context);
}

}  // namespace sparse
