#include <gauge_field.h>
#include <gauge_field_order.h>

#include <mdw_dslash5_tensor_core.cuh>

namespace quda {
  namespace mobius_tensor_core {

#if defined(GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700) && (__COMPUTE_CAPABILITY__ <= 750)
    
    
    /**
      @brief Parameter structure for applying the Dslash
    */
    template <class storage_type, int Ls_> // storage_type is the usual "Float" in other places in QUDA
    struct FusedDslashArg {
      static constexpr bool spin_project = true;
      static constexpr bool spinor_direct_load = false; // false means texture load
      typedef typename colorspinor_mapper<storage_type, 4, 3, spin_project, spinor_direct_load>::type
          F; // color spin field order
      typedef typename mapper<storage_type>::type real; // the compute type for the in kernel computation
      static constexpr bool gauge_direct_load = false; // false means texture load
      static constexpr QudaGhostExchange ghost = QUDA_GHOST_EXCHANGE_PAD;
      typedef typename gauge_mapper<storage_type, QUDA_RECONSTRUCT_NO, 18, QUDA_STAGGERED_PHASE_NO, gauge_direct_load,
          ghost>::type G; // gauge field order

      F out; // output vector field
      const F in; // input vector field
      F y; // auxiliary output vector field
      const F x; // auxiliary input vector field

      const G U; // The gauge field

      const int nParity; // number of parities we're working on
      const int parity; // output parity of this dslash operator
      const int volume_cb; // checkerboarded volume
      const int volume_4d_cb; // 4-d checkerboarded volume

      const int dim[4];

      const int_fastdiv Ls; // length of 5th dimension

      const int shift[4]; // sites where we actually calculate.
      const int halo_shift[4]; // halo means zero. When we are expanding we have halo of cs-field where values are zero.

      const int_fastdiv shrinked_dim[4]; // dimension after shifts are considered.

      // partial kernel and expansion parameters
      const int volume_4d_cb_shift; // number of 4d sites we need calculate
      // const int volume_4d_cb_expansive; //

      const real m_f; // fermion mass parameter
      const real m_5; // Wilson mass shift

      const bool dagger; // dagger
      //    const bool xpay;        // whether we are doing xpay or not

      real b; // real constant Mobius coefficient
      real c; // real constant Mobius coefficient
      real a; // real xpay coefficient

      real kappa;
      real fac_inv;

      // (beta + alpha*m5inv) @ in
      real alpha = 1.;
      real beta = 0.;

      const float scale; // scale factor for the input color spin field
      real m_scale = 1.; // scale factor for the matrix

      MdwfFusedDslashType type;
      FusedDslashArg(ColorSpinorField& out, const ColorSpinorField& in, const GaugeField& U, ColorSpinorField& y,
          const ColorSpinorField& x, double m_f_, double m_5_, const Complex* b_5, const Complex* c_5, bool dagger_,
          int parity, int shift_[4], int halo_shift_[4], const double scale_, MdwfFusedDslashType type_)
          : out(out)
          , in(in)
          , U(U)
          , y(y)
          , x(x)
          , nParity(in.SiteSubset())
          , parity(parity)
          , volume_cb(in.VolumeCB() > out.VolumeCB() ? in.VolumeCB() : out.VolumeCB())
          , volume_4d_cb(volume_cb / Ls_)
          , Ls(Ls_)
          , m_f(m_f_)
          , m_5(m_5_)
          , dagger(dagger_)
          , shift{shift_[0], shift_[1], shift_[2], shift_[3]}
          , halo_shift{halo_shift_[0], halo_shift_[1], halo_shift_[2], halo_shift_[3]}
          , dim{(3 - nParity) * (in.VolumeCB() > out.VolumeCB() ? in.X(0) : out.X(0)),
                in.VolumeCB() > out.VolumeCB() ? in.X(1) : out.X(1),
                in.VolumeCB() > out.VolumeCB() ? in.X(2) : out.X(2),
                in.VolumeCB() > out.VolumeCB() ? in.X(3) : out.X(3)}
          , shrinked_dim{dim[0] - 2 * shift[0], dim[1] - 2 * shift[1], dim[2] - 2 * shift[2], dim[3] - 2 * shift[3]}
          , volume_4d_cb_shift(shrinked_dim[0] * shrinked_dim[1] * shrinked_dim[2] * shrinked_dim[3] / 2)
          , scale(scale_)
          , type(type_) {
        if (in.Nspin() != 4) { errorQuda("nSpin = %d NOT supported.\n", in.Nspin()); }

        if (nParity == 2) { errorQuda("nParity = 2 NOT supported, yet.\n"); }

        if (!in.isNative() || !out.isNative())
          errorQuda("Unsupported field order out=%d in=%d\n", out.FieldOrder(), in.FieldOrder());

        b = b_5[0].real();
        c = c_5[0].real();
        kappa = -(c * (4. + m_5) - 1.) / (b * (4. + m_5) + 1.); // This is actually -kappa in my(Jiqun Tu) notes.
        fac_inv = 0.5
            / (1. + std::pow(kappa, (int)Ls) * m_f); // 0.5 to normalize the (1 +/- gamma5) in the chiral projector.
        switch (type) {
        case dslash4_dslash5pre_dslash5inv:
        case dslash4dag_dslash5predag_dslash5invdag:
          m_scale = b;
          alpha = 1. + c / (kappa * b); // b-c/kappa = b(1-c/(b*kappa))
          beta = -c / (kappa * b);
          break;
        case dslash4_dslash5inv_dslash5invdag:
          m_scale = -0.25 / ((b * (4. + m_5) + 1.) * (b * (4. + m_5) + 1.)); // -kappa_b^2
          break;
        case dslash4dag_dslash5predag:
          m_scale = -0.25 / ((b * (4. + m_5) + 1.) * (b * (4. + m_5) + 1.)) * b; // -kappa_b^2
          alpha = c / (2. * b); // 2 to compensate for the spin projection
          beta = 1.;
          break;
        case 4:
          m_scale = b;
          alpha = c / (2. * b);
          beta = 1.;
          break;
        default: errorQuda("Unknown MdwfFusedDslashType %d", type);
        }
      }
    };

    __device__ inline int index_4d_cb_from_coordinate_4d(const int coordinate[4], const int dim[4]) {
      return (((coordinate[3] * dim[2] + coordinate[2]) * dim[1] + coordinate[1]) * dim[0] + coordinate[0]) >> 1;
    }

    __device__ inline bool is_halo_4d(const int coordinate[4], const int dim[4], const int halo_shift[4]) {
      bool ret = false;
#pragma unroll
      for (int d = 0; d < 4; d++) {
        ret = ret or (coordinate[d] >= dim[d] - halo_shift[d] or coordinate[d] < halo_shift[d]);
      }
      return ret;
    }

    /**
    -> Everything should be understood in a 4d checkboarding sense.
    */
    template <class storage_type, bool dagger, bool halo, class Vector, class Arg>
    __device__ inline void apply_wilson_5d(Vector& out, int coordinate[4], Arg& arg, int s) {

      typedef typename mapper<storage_type>::type compute_type;
      typedef Matrix<complex<compute_type>, 3> Link;
      const int their_spinor_parity = arg.nParity == 2 ? 1 - arg.parity : 0;

      const int index_4d_cb = index_4d_cb_from_coordinate_4d(coordinate, arg.dim);

#pragma unroll
      for (int d = 0; d < 4; d++) // loop over dimension
      {
        coordinate[d]++;
        if (!halo || !is_halo_4d(coordinate, arg.dim, arg.halo_shift)) {
          // Forward gather - compute fwd offset for vector fetch
          const int fwd_idx = s * arg.volume_4d_cb + index_4d_cb_from_coordinate_4d(coordinate, arg.dim);
          constexpr int proj_dir = dagger ? +1 : -1;

          const Link U = arg.U(d, index_4d_cb, arg.parity);
          const Vector in = arg.in(fwd_idx, their_spinor_parity);
          out += (U * in.project(d, proj_dir)).reconstruct(d, proj_dir);
        }
        coordinate[d]-=2;
        if (!halo || !is_halo_4d(coordinate, arg.dim, arg.halo_shift)) {
          // Backward gather - compute back offset for spinor and gauge fetch
          const int gauge_idx = index_4d_cb_from_coordinate_4d(coordinate, arg.dim);
          ;
          const int back_idx = s * arg.volume_4d_cb + gauge_idx;
          constexpr int proj_dir = dagger ? -1 : +1;

          const Link U = arg.U(d, gauge_idx, 1 - arg.parity);
          const Vector in = arg.in(back_idx, their_spinor_parity);
          out += (conj(U) * in.project(d, proj_dir)).reconstruct(d, proj_dir);
        }
        coordinate[d]++;
      } // nDim
    }

    /**
    -> Everything should be understood in a 4d checkboarding sense.
    */
    template <class T>
    __device__ inline void coordinate_from_shrinked_index(int coordinate[4], int shrinked_index,
        const T shrinked_dim[4], const int shift[4], int parity) // s is the 5d stuff,
    {
      int aux[4];
      aux[0] = shrinked_index * 2;

#pragma unroll
      for (int i = 0; i < 3; i++) { aux[i + 1] = aux[i] / shrinked_dim[i]; }

      coordinate[0] = aux[0] - aux[1] * shrinked_dim[0];
      coordinate[1] = aux[1] - aux[2] * shrinked_dim[1];
      coordinate[2] = aux[2] - aux[3] * shrinked_dim[2];
      coordinate[3] = aux[3];

      // Find the full coordinate in the shrinked volume.
      coordinate[0] += (parity + coordinate[3] + coordinate[2] + coordinate[1]) & 1;

// Now go back to the extended volume.
#pragma unroll
      for (int d = 0; d < 4; d++) { coordinate[d] += shift[d]; }
    }
#if 0
    /**
      @brief Tensor core kernel for applying Wilson hopping term and then the beta + alpha*M5inv operator
      The kernels type(type_) will be specified in some documentations.
    */
    template <class storage_type, int block_dim_x, int Ls, int minBlocksPerMultiprocessor, bool reload, class Arg,
        int type_>
    __global__ void __launch_bounds__(block_dim_x*Ls, minBlocksPerMultiprocessor) fused_tensor_core(Arg arg)
    {
      const int explicit_parity = arg.nParity == 2 ? arg.parity : 0;

      TensorCoreSharedMemory<half2> shared_memory_data;

      constexpr int M = 4 * Ls;
      constexpr int N = 6 * block_dim_x;

      constexpr int sm_m_pad_size = 0;
      constexpr int sm_n_pad_size = 16;

      constexpr int N_sm = N + sm_n_pad_size;
      constexpr int M_sm = M + sm_m_pad_size;

      half2* sm_b = shared_memory_data;
      half* sm_c = reinterpret_cast<half*>(sm_b);

      half* sm_a = reload ? sm_c + M * N_sm : sm_c;
      // This is for type == 1 ONLY.
      half* sm_a_black = sm_a + M * M_sm;

      if (type_ == 0) {
        construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, false, Arg>(arg, sm_a); // dagger = false
      } else if (type_ == 2) {
        construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, true, Arg>(arg, sm_a); // dagger =  true
      } else if (type_ == 1) {
        construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, false, Arg>(arg, sm_a); // dagger = false
      } else if (type_ == 3) {
        construct_matrix_a_d5<block_dim_x, Ls, M_sm, true, Arg>(arg, sm_a); // dagger =  true
      } else if (type_ == 4) {
        construct_matrix_a_d5<block_dim_x, Ls, M_sm, false, Arg>(arg, sm_a); // dagger =  true
      }
      __syncthreads();

      bool idle = false;
      int s4_shift_base = blockIdx.x * blockDim.x; // base.
      int s4_shift, sid;

      constexpr int WMMA_M = 16;
      constexpr int WMMA_N = 16;
      constexpr int WMMA_K = 16;

      constexpr int tm_dim = M / WMMA_M;
      constexpr int tn_dim = N / WMMA_N;

      constexpr int total_warp = block_dim_x * Ls >> 5;
      const int this_warp = (threadIdx.y * block_dim_x + threadIdx.x) >> 5;

      constexpr int total_tile = tm_dim * tn_dim;

      constexpr int warp_cycle = total_tile / total_warp;
      const int warp_m = this_warp * warp_cycle / tn_dim;

      typedef
          typename nvcuda::wmma::fragment<nvcuda::wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::col_major>
              a_type;

      a_type a_frag[reload ? 1 : tm_dim];
      a_type a_frag_black[reload ? 1 : tm_dim];
      if (!reload) { // in the preload case we preload ...
#pragma unroll
        for (int k = 0; k < tm_dim; k++) {
          const int a_row = warp_m * WMMA_M;
          const int a_col = k * WMMA_K;
          // Load Matrix
          nvcuda::wmma::load_matrix_sync(a_frag[k], sm_a + a_row + a_col * M_sm, M_sm);
        }
      }

      if (type_ == 1) {
        arg.alpha = 1.;
        if (!reload) { // in the preload case we preload ...
          construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, true, Arg>(arg, sm_a); // dagger = true
          __syncthreads();
#pragma unroll
          for (int k = 0; k < tm_dim; k++) {
            const int a_row = warp_m * WMMA_M;
            const int a_col = k * WMMA_K;
            // Load Matrix
            nvcuda::wmma::load_matrix_sync(a_frag_black[k], sm_c + a_row + a_col * M_sm, M_sm);
          }
        } else {
          construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, true, Arg>(arg, sm_a_black); // dagger = true
          __syncthreads();
        }
      }

      while (s4_shift_base < arg.volume_4d_cb_shift) {
        int x[4];
        s4_shift = s4_shift_base + threadIdx.x;
        coordinate_from_shrinked_index(x, s4_shift, arg.shrinked_dim, arg.shift, arg.parity);
        sid = threadIdx.y * arg.volume_4d_cb + index_4d_cb_from_coordinate_4d(x, arg.dim);

        if (s4_shift >= arg.volume_4d_cb_shift) { idle = true; }

        typedef typename mapper<storage_type>::type real;
        typedef ColorSpinor<real, 3, 4> Vector;

        if (!idle) {
          Vector in_vec;
          // the Wilson hopping terms
          if (type_ == 0) {
            apply_wilson_5d<storage_type, false, true>(in_vec, x, arg, threadIdx.y); // dagger = false; halo =  true
          } else if (type_ == 2) {
            apply_wilson_5d<storage_type, true, false>(in_vec, x, arg, threadIdx.y); // dagger =  true; halo = false
          } else if (type_ == 1) {
            apply_wilson_5d<storage_type, false, true>(in_vec, x, arg, threadIdx.y); // dagger = false; halo =  true
          } else if (type_ == 3) {
            apply_wilson_5d<storage_type, true, false>(in_vec, x, arg, threadIdx.y); // dagger =  true; halo = false
          } else if (type_ == 4) {
            int sid_shift = threadIdx.y * arg.volume_4d_cb_shift + s4_shift;
            in_vec = arg.in(sid_shift, explicit_parity);
          }
          // store result to shared memory
          load_matrix_b_vector<N_sm / 2, false>(in_vec, sm_b, arg.scale); // acc(accumulation) = false
        }

        __syncthreads();
        // wmma_gemm<block_dim_x, Ls, M, N, M_sm, N_sm, reload>(a_frag, sm_a, sm_c, sm_c);
        mma_sync_gemm<block_dim_x, Ls, M, N, M_sm, N_sm>(sm_a, sm_c, sm_c);
        __syncthreads();

        if (type_ == 1) {

          if (!idle) {
            constexpr int in_x_shift = 2;
            int back_x[4] = {x[0] - in_x_shift, x[1] - in_x_shift, x[2] - in_x_shift, x[3] - in_x_shift};
            int back_dim[4] = {arg.dim[0] - in_x_shift*2, arg.dim[1] - in_x_shift*2, arg.dim[2] - in_x_shift*2, arg.dim[3] - in_x_shift*2};
            if (back_x[0] >= 0 && back_x[0] < back_dim[0] && back_x[1] >= 0 && back_x[1] < back_dim[1] && back_x[2] >= 0
                && back_x[2] < back_dim[2] && back_x[3] >= 0 && back_x[3] < back_dim[3]) {
              int volume_4d_cb_back = back_dim[0] * back_dim[1] * back_dim[2] * back_dim[3] >> 1;
              int sid_back_shift = threadIdx.y * volume_4d_cb_back + index_4d_cb_from_coordinate_4d(back_x, back_dim);
              Vector aux_in_vec = arg.x(sid_back_shift, explicit_parity);
              load_matrix_b_vector<N_sm / 2, true>(aux_in_vec, sm_b, arg.scale * arg.m_scale); // acc = true
            }
            store_matrix_c<storage_type, N_sm>(arg.y, sm_b, sid, arg.scale * arg.m_scale);
          }
          __syncthreads();
          wmma_gemm<block_dim_x, Ls, M, N, M_sm, N_sm, reload>(a_frag_black, sm_a_black, sm_c, sm_c);
          __syncthreads();

        } else if (type_ == 3) {

          if (!idle) {
            Vector aux_in_vec = arg.x(sid, explicit_parity);
            load_matrix_b_vector<N_sm / 2, true>(aux_in_vec, sm_b, arg.scale * arg.m_scale);
          }
        }

        if (type_ == 3) {
          if (!idle) {
            int sid_shift = threadIdx.y * arg.volume_4d_cb_shift + s4_shift;
            store_matrix_c<storage_type, N_sm>(arg.out, sm_b, sid_shift, arg.scale * arg.m_scale);
          }
        } else {
          if (!idle) { store_matrix_c<storage_type, N_sm>(arg.out, sm_b, sid, arg.scale * arg.m_scale); }
        }

        s4_shift_base += gridDim.x * blockDim.x;

      } // while
    }
#else
    /**
      @brief Tensor core kernel for applying Wilson hopping term and then the beta + alpha*M5inv operator
      The kernels type(type_) will be specified in some documentations.
    */
    template <class storage_type, int block_dim_x, int Ls, int minBlocksPerMultiprocessor, bool reload, class Arg,
        int type_>
    __global__ void __launch_bounds__(block_dim_x*Ls, minBlocksPerMultiprocessor) fused_tensor_core(Arg arg)
    {
      const int explicit_parity = arg.nParity == 2 ? arg.parity : 0;

      TensorCoreSharedMemory<half2> shared_memory_data;

      constexpr int M = 4 * Ls;
      constexpr int N = 6 * block_dim_x;

      constexpr int sm_m_pad_size = 0;
      constexpr int sm_n_pad_size = 16;

      constexpr int N_sm = N + sm_n_pad_size;
      constexpr int M_sm = M + sm_m_pad_size;

      half2* sm_b = shared_memory_data;
      half* sm_c = reinterpret_cast<half*>(sm_b);

      half* sm_a = sm_c + M * N_sm;
      // This is for type == 1 ONLY.
      half* sm_a_black = sm_a + M * M_sm;

      if (type_ == 0) {
        construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, false, Arg>(arg, sm_a); // dagger = false
      } else if (type_ == 2) {
        construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, true, Arg>(arg, sm_a); // dagger =  true
      } else if (type_ == 1) {
        construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, false, Arg>(arg, sm_a); // dagger = false
      } else if (type_ == 3) {
        construct_matrix_a_d5<block_dim_x, Ls, M_sm, true, Arg>(arg, sm_a); // dagger =  true
      } else if (type_ == 4) {
        construct_matrix_a_d5<block_dim_x, Ls, M_sm, false, Arg>(arg, sm_a); // dagger =  true
      }
      __syncthreads();

      bool idle = false;
      int s4_shift_base = blockIdx.x * blockDim.x; // base.
      int s4_shift, sid;

      if (type_ == 1) {
        arg.alpha = 1.;
        construct_matrix_a_m5inv<block_dim_x, Ls, M_sm, true, Arg>(arg, sm_a_black); // dagger = true
        __syncthreads();
      }

      while (s4_shift_base < arg.volume_4d_cb_shift) {
        int x[4];
        s4_shift = s4_shift_base + threadIdx.x;
        coordinate_from_shrinked_index(x, s4_shift, arg.shrinked_dim, arg.shift, arg.parity);
        sid = threadIdx.y * arg.volume_4d_cb + index_4d_cb_from_coordinate_4d(x, arg.dim);

        if (s4_shift >= arg.volume_4d_cb_shift) { idle = true; }

        typedef typename mapper<storage_type>::type real;
        typedef ColorSpinor<real, 3, 4> Vector;

        if (!idle) {
          Vector in_vec;
          // the Wilson hopping terms
          if (type_ == 0) {
            apply_wilson_5d<storage_type, false, true>(in_vec, x, arg, threadIdx.y); // dagger = false; halo =  true
          } else if (type_ == 2) {
            apply_wilson_5d<storage_type, true, false>(in_vec, x, arg, threadIdx.y); // dagger =  true; halo = false
          } else if (type_ == 1) {
            apply_wilson_5d<storage_type, false, true>(in_vec, x, arg, threadIdx.y); // dagger = false; halo =  true
          } else if (type_ == 3) {
            apply_wilson_5d<storage_type, true, false>(in_vec, x, arg, threadIdx.y); // dagger =  true; halo = false
          } else if (type_ == 4) {
            int sid_shift = threadIdx.y * arg.volume_4d_cb_shift + s4_shift;
            in_vec = arg.in(sid_shift, explicit_parity);
          }
          // store result to shared memory
          load_matrix_b_vector<N_sm / 2, false>(in_vec, sm_b, arg.scale); // acc(accumulation) = false
        }

        __syncthreads();
        mma_sync_gemm<block_dim_x, Ls, M, N, M_sm, N_sm>(sm_a, sm_c, sm_c);
        __syncthreads();

        if (type_ == 1) {

          if (!idle) {
            constexpr int in_x_shift = 2;
            int back_x[4] = {x[0] - in_x_shift, x[1] - in_x_shift, x[2] - in_x_shift, x[3] - in_x_shift};
            int back_dim[4] = {arg.dim[0] - in_x_shift*2, arg.dim[1] - in_x_shift*2, arg.dim[2] - in_x_shift*2, arg.dim[3] - in_x_shift*2};
            if (back_x[0] >= 0 && back_x[0] < back_dim[0] && back_x[1] >= 0 && back_x[1] < back_dim[1] && back_x[2] >= 0
                && back_x[2] < back_dim[2] && back_x[3] >= 0 && back_x[3] < back_dim[3]) {
              int volume_4d_cb_back = back_dim[0] * back_dim[1] * back_dim[2] * back_dim[3] >> 1;
              int sid_back_shift = threadIdx.y * volume_4d_cb_back + index_4d_cb_from_coordinate_4d(back_x, back_dim);
              Vector aux_in_vec = arg.x(sid_back_shift, explicit_parity);
              load_matrix_b_vector<N_sm / 2, true>(aux_in_vec, sm_b, arg.scale * arg.m_scale); // acc = true
            }
            store_matrix_c<storage_type, N_sm>(arg.y, sm_b, sid, arg.scale * arg.m_scale);
          }
          __syncthreads();
          mma_sync_gemm<block_dim_x, Ls, M, N, M_sm, N_sm>(sm_a_black, sm_c, sm_c);
          __syncthreads();

        } else if (type_ == 3) {

          if (!idle) {
            Vector aux_in_vec = arg.x(sid, explicit_parity);
            load_matrix_b_vector<N_sm / 2, true>(aux_in_vec, sm_b, arg.scale * arg.m_scale);
          }
        }

        if (type_ == 3) {
          if (!idle) {
            int sid_shift = threadIdx.y * arg.volume_4d_cb_shift + s4_shift;
            store_matrix_c<storage_type, N_sm>(arg.out, sm_b, sid_shift, arg.scale * arg.m_scale);
          }
        } else {
          if (!idle) { store_matrix_c<storage_type, N_sm>(arg.out, sm_b, sid, arg.scale * arg.m_scale); }
        }

        s4_shift_base += gridDim.x * blockDim.x;

      } // while
    }
#endif
    template <class storage_type, int Ls_, class Arg> class FusedDslash : public TunableVectorYZ {

  protected:
      Arg& arg;
      const ColorSpinorField& meta;
      static constexpr bool shared = true; // whether to use shared memory cache blocking for M5inv

      /** Whether to use variable or fixed coefficient algorithm.  Must be true if using ZMOBIUS */
      static constexpr bool var_inverse = true;

      long long flops() const {
        constexpr long long hop = 7ll * 8ll; // 8 for eight directions, 7 comes from Peter/Grid's count
        constexpr long long mat = 2ll * 4ll * Ls_ - 1ll;
        long long volume_4d_cb_halo_shift = (arg.dim[0] - 2 * arg.halo_shift[0]) * (arg.dim[1] - 2 * arg.halo_shift[1])
            * (arg.dim[2] - 2 * arg.halo_shift[2]) * (arg.dim[3] - 2 * arg.halo_shift[3]) / 2;

        long long flops_ = 0;
        switch (arg.type) {
        // I am too lazy to fix the flops count. :(
        case 0: // FIXME: flops
          flops_ = volume_4d_cb_halo_shift * 6ll * 4ll * Ls_ * hop + arg.volume_4d_cb_shift * 24ll * Ls_ * mat;
          break;
        case 1:
          flops_ = volume_4d_cb_halo_shift * 6ll * 4ll * Ls_ * hop + arg.volume_4d_cb_shift * 24ll * Ls_ * 2ll * mat;
          break;
        case 2:
        case 3:
          flops_ = arg.volume_4d_cb_shift * 6ll * 4ll * Ls_
              * (hop + mat); // for 2 and 3 we don't have the halo complication.
          break;
        case 4: flops_ = arg.volume_4d_cb_shift * 6ll * 4ll * Ls_ * (mat); break;
        default: errorQuda("Unknown MdwfFusedDslashType %d", arg.type);
        }

        return flops_;
      }

      long long bytes() const {
        switch (arg.type) {
        case 0: return arg.out.Bytes() + arg.in.Bytes() + arg.U.Bytes();
        case 1: return 3 * arg.out.Bytes() + arg.in.Bytes() + arg.U.Bytes();
        case 2: return arg.out.Bytes() + arg.in.Bytes() + arg.U.Bytes();
        case 3:
        case 4: return 2 * arg.out.Bytes() + arg.in.Bytes() + arg.U.Bytes();
        default: errorQuda("Unknown MdwfFusedDslashType %d", arg.type);
        }
        return 0ll;
      }

      virtual bool tuneGridDim() const { return true; }
      virtual bool tuneAuxDim() const { return true; }
      virtual bool tuneSharedBytes() const { return true; }
      unsigned int minThreads() const { return arg.volume_4d_cb; }

      unsigned int shared_bytes_per_block(const TuneParam& param) const {
        // (Ls*4) by (Ls*4), (Ls*4) by (volume_4d*6 + 16)
        // if (param.aux.x == 1) { // aux.x == 1 --> reload == true
        if (true) { // aux.x == 1 --> reload == true
          if (arg.type == 1) {
            return ((param.block.y * 4) * (param.block.y * 4 + 0) * 2 + (param.block.y * 4) * (param.block.x * 6 + 16))
                * sizeof(half);
          } else {
            return ((param.block.y * 4) * (param.block.y * 4 + 0) + (param.block.y * 4) * (param.block.x * 6 + 16))
                * sizeof(half);
          }
        } else {
          int a_size = (param.block.y * 4) * (param.block.y * 4 + 0);
          int b_size = (param.block.y * 4) * (param.block.x * 6 + 16);
          return (a_size > b_size ? a_size : b_size) * sizeof(half);
        }
      }

      virtual bool advanceBlockDim(TuneParam& param) const {
        if (param.block.x < max_block_size()) {
          param.block.x += step_block_size();
          param.shared_bytes = shared_bytes_per_block(param);
          return true;
        } else {
          return false;
        }
      }

      virtual bool advanceGridDim(TuneParam& param) const {
        const unsigned int max_blocks = maxGridSize();
        const int step = deviceProp.multiProcessorCount;
        param.grid.x += step;
        if (param.grid.x > max_blocks) {
          return false;
        } else {
          param.block.x = min_block_size();
          param.shared_bytes = shared_bytes_per_block(param);
          return true;
        }
      }

      virtual bool advanceAux(TuneParam& param) const {
        bool aux_advanced = false;
        if (param.aux.x == 0) { // first see if aux.x(ONLY 0(false) or 1(true))
          param.aux.x++;
          aux_advanced = true;
        } else {
          if (param.aux.y < 3) { // second see if aux.y
            param.aux.y++;
            aux_advanced = true;
            param.aux.x = 0;
          }
        }
        if (aux_advanced) {
          // We have updated the "aux" so reset all other parameters.
          param.grid.x = minGridSize();
          param.block.x = min_block_size();
          param.shared_bytes = shared_bytes_per_block(param);
          return true;
        } else {
          return false;
        }
      }

      virtual unsigned int maxGridSize() const { return 32 * deviceProp.multiProcessorCount; }
      virtual unsigned int minGridSize() const { return deviceProp.multiProcessorCount; }
      unsigned int min_block_size() const { return 8; }
      unsigned int max_block_size() const { return 32; }
      unsigned int step_block_size() const { return 8; }

      // overloaded to return max dynamic shared memory if doing shared-memory inverse
      unsigned int maxSharedBytesPerBlock() const {
        if (shared) {
          return maxDynamicSharedBytesPerBlock();
        } else {
          return TunableVectorYZ::maxSharedBytesPerBlock();
        }
      }

  public:
      FusedDslash(Arg& arg, const ColorSpinorField& meta) : TunableVectorYZ(arg.Ls, arg.nParity), arg(arg), meta(meta) {
        strcpy(aux, meta.AuxString());
        if (arg.dagger) strcat(aux, ",Dagger");
        //        if (arg.xpay) strcat(aux,",xpay");
        char config[512];
        switch (arg.type) {
        case dslash4_dslash5pre_dslash5inv:
          sprintf(config, ",f0,shift%d,%d,%d,%d,halo%d,%d,%d,%d", arg.shift[0], arg.shift[1], arg.shift[2],
              arg.shift[3], arg.halo_shift[0], arg.halo_shift[1], arg.halo_shift[2], arg.halo_shift[3]);
          strcat(aux, config);
          break;
        case dslash4dag_dslash5predag_dslash5invdag:
          sprintf(config, ",f2,shift%d,%d,%d,%d", arg.shift[0], arg.shift[1], arg.shift[2], arg.shift[3]);
          strcat(aux, config);
          break;
        case dslash4_dslash5inv_dslash5invdag:
          sprintf(config, ",f1,shift%d,%d,%d,%d,halo%d,%d,%d,%d", arg.shift[0], arg.shift[1], arg.shift[2],
              arg.shift[3], arg.halo_shift[0], arg.halo_shift[1], arg.halo_shift[2], arg.halo_shift[3]);
          strcat(aux, config);
          break;
        case dslash4dag_dslash5predag:
          sprintf(config, ",f3,shift%d,%d,%d,%d", arg.shift[0], arg.shift[1], arg.shift[2], arg.shift[3]);
          strcat(aux, config);
          break;
        case 4:
          sprintf(config, ",f4,shift%d,%d,%d,%d", arg.shift[0], arg.shift[1], arg.shift[2], arg.shift[3]);
          strcat(aux, config);
          break;
        default: errorQuda("Unknown MdwfFusedDslashType %d", arg.type);
        }
      }
      virtual ~FusedDslash() {}

      template <typename T> inline void launch(T* f, const TuneParam& tp, Arg& arg, const cudaStream_t& stream) {
        if (shared) { setMaxDynamicSharedBytesPerBlock(f); }
        void* args[] = {&arg};
        qudaLaunchKernel((const void*)f, tp.grid, tp.block, args, tp.shared_bytes, stream);
      }

      // The following apply<...> functions are used to turn the tune parameters into template arguments.
      // Specifically tp.aux.y dictates the minBlocksPerMultiprocessor in __launch_bounds__(..).
      // tp.aux.x dictates whether or not to reload.
      template <int block_dim_x, bool reload, int type>
      void apply(const TuneParam& tp, Arg& arg, const cudaStream_t& stream) {
        switch (tp.aux.y) {
        case 1: launch(fused_tensor_core<storage_type, block_dim_x, Ls_, 1, reload, Arg, type>, tp, arg, stream); break;
        case 2: launch(fused_tensor_core<storage_type, block_dim_x, Ls_, 2, reload, Arg, type>, tp, arg, stream); break;
        case 3: launch(fused_tensor_core<storage_type, block_dim_x, Ls_, 3, reload, Arg, type>, tp, arg, stream); break;
        default: errorQuda("NOT valid tp.aux.y(=%d)\n", tp.aux.y);
        }
      }

      template <bool reload, int type> void apply(const TuneParam& tp, Arg& arg, const cudaStream_t& stream) {
        switch (tp.block.x) {
          case  8: apply< 8, reload, type>(tp, arg, stream); break;
          case 16: apply<16, reload, type>(tp, arg, stream); break;
          case 24: apply<24, reload, type>(tp, arg, stream); break;
          case 32: apply<32, reload, type>(tp, arg, stream); break;
          default: errorQuda("NOT valid tp.block.x(=%d)\n", tp.block.x);
        }
      }

      template <int type> void apply(const TuneParam& tp, Arg& arg, const cudaStream_t& stream) {
        if (tp.aux.x == 0) {
          apply<false, type>(tp, arg, stream); // reload = false
        } else {
          apply<true, type>(tp, arg, stream); // reload = true
        }
      }

      void apply(const cudaStream_t& stream) {
        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
        switch (arg.type) {
          case 0: apply<0>(tp, arg, stream); break;
          case 1: apply<1>(tp, arg, stream); break;
          case 2: apply<2>(tp, arg, stream); break;
          case 3: apply<3>(tp, arg, stream); break;
          case 4: apply<4>(tp, arg, stream); break;
        default: errorQuda("Unknown MdwfFusedDslashType %d", arg.type);
        }
      }

      void initTuneParam(TuneParam& param) const {
        TunableVectorYZ::initTuneParam(param);
        param.block = dim3(min_block_size(), arg.Ls, 1); // Ls must be contained in the block
        param.grid = dim3(minGridSize(), 1, 1);
        param.shared_bytes = shared_bytes_per_block(param);
        param.aux.x = 0;
        param.aux.y = 1;
      }

      void defaultTuneParam(TuneParam& param) const { initTuneParam(param); }

      TuneKey tuneKey() const { return TuneKey(meta.VolString(), typeid(*this).name(), aux); }
    };

    // Apply the 5th dimension dslash operator to a colorspinor field
    // out = Dslash5 * in
    template <class storage_type>
    void apply_fused_dslash(ColorSpinorField& out, const ColorSpinorField& in, const GaugeField& U, ColorSpinorField& y,
        const ColorSpinorField& x, double m_f, double m_5, const Complex* b_5, const Complex* c_5, bool dagger,
        int parity, int shift[4], int halo_shift[4], const double scale, MdwfFusedDslashType type) {
      // switch for Ls
      switch (in.X(4)) {
      //      case  8:
      //        {
      //          FusedDslashArg<storage_type,  8> arg(out, in, U, y, x, m_f, m_5, b_5, c_5, dagger, parity, shift,
      //          halo_shift, scale, type);
      //          FusedDslash<storage_type,  8, FusedDslashArg<storage_type,  8> > dslash(arg, in);
      //          dslash.apply(streams[Nstream-1]);
      //        }
      //      break;
        case 12: {
          FusedDslashArg<storage_type, 12> arg(
              out, in, U, y, x, m_f, m_5, b_5, c_5, dagger, parity, shift, halo_shift, scale, type);
          FusedDslash<storage_type, 12, FusedDslashArg<storage_type, 12>> dslash(arg, in);
          dslash.apply(streams[Nstream - 1]);
        } break;
      //      case 16:
      //        {
      //          FusedDslashArg<storage_type, 16> arg(out, in, U, y, x, m_f, m_5, b_5, c_5, dagger, parity, shift,
      //          halo_shift, scale, type);
      //          FusedDslash<storage_type, 16, FusedDslashArg<storage_type, 16> > dslash(arg, in);
      //          dslash.apply(streams[Nstream-1]);
      //        }
      //      break;
      //      case 20:
      //        {
      //          FusedDslashArg<storage_type, 20> arg(out, in, U, y, x, m_f, m_5, b_5, c_5, dagger, parity, shift,
      //          halo_shift, scale, type);
      //          FusedDslash<storage_type, 20, FusedDslashArg<storage_type, 20> > dslash(arg, in);
      //          dslash.apply(streams[Nstream-1]);
      //        }
      //      break;
      //      case 24:
      //        {
      //          FusedDslashArg<storage_type, 24> arg(out, in, U, y, x, m_f, m_5, b_5, c_5, dagger, parity, shift,
      //          halo_shift, scale, type);
      //          FusedDslash<storage_type, 24, FusedDslashArg<storage_type, 24> > dslash(arg, in);
      //          dslash.apply(streams[Nstream-1]);
      //        }
      //      break;
      default: errorQuda("Ls = %d is NOT supported.\n", in.X(4));
      }
    }
#endif // defined (GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700)

    void apply_fused_dslash(ColorSpinorField& out, const ColorSpinorField& in, const GaugeField& U, ColorSpinorField& y,
        const ColorSpinorField& x, double m_f, double m_5, const Complex* b_5, const Complex* c_5, bool dagger,
        int parity, int shift[4], int halo_shift[4], const double scale, MdwfFusedDslashType type) {
#if defined(GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700)
      checkLocation(out, in); // check all locations match

      if (checkPrecision(out, in) == QUDA_HALF_PRECISION && in.Ncolor() == 3) {
        apply_fused_dslash<short>(out, in, U, y, x, m_f, m_5, b_5, c_5, dagger, parity, shift, halo_shift, scale, type);
      } else if (checkPrecision(out, in) == QUDA_QUARTER_PRECISION && in.Ncolor() == 3) {
        apply_fused_dslash<char>(out, in, U, y, x, m_f, m_5, b_5, c_5, dagger, parity, shift, halo_shift, scale, type);
      } else {
        errorQuda("Tensor core implemtation ONLY supports HALF/QUARTER precision and n_color = 3.\n");
      }

#else
      errorQuda("Domain wall dslash WITH tensor cores has not been built");
#endif
    }
  } // namespace mobius_tensor_core
} // namespace quda
