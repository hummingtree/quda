#pragma once

#include <color_spinor_field.h>
#include <dslash_quda.h>
#include <color_spinor_field_order.h>
#include <index_helper.cuh>
#include <dslash_quda.h>
#include <inline_ptx.h>
#include <shared_memory_cache_helper.cuh>
#include <math_helper.cuh>

#if (__COMPUTE_CAPABILITY__ >= 700)
#include <cublas_v2.h>
#include <mma.h>
#endif

namespace quda {

#if defined (GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700)
  
  template<class T>
  struct TensorCoreSharedMemory
  {
    __device__ inline operator T*()
    {
      extern __shared__ int __smem[];
      return (T*)__smem;
    }

    __device__ inline operator const T*() const
    {
      extern __shared__ int __smem[];
      return (T*)__smem;
    }
  };
  
  // matrix a for a generic matrix: column major, M/M_sm(size/padded size) by k
  // (spin,Ls) by (spin,Ls), where left most index is the fastest changing one(spin).
  // x by y
  // For now, assuming it's trivial in spin
  template<int block_dim_x, int Ls_, int M_sm, class compute_type>
  __device__ inline void construct_matrix_a_generic(half* sm_a, compute_type* generic){
    
    int offset_k = threadIdx.y*4;
    int x = threadIdx.x;
    
    while(x < Ls_){
      int offset_m = x*4;
      float value = generic[x*Ls_+threadIdx.y]; // Assuming the input matrix is row major

      // exp = 0 means we are on the diagonal.
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+0) ] = value;
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+1) ] = value;
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+2) ] = value;
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+3) ] = value;
        
      // sm_a[ (offset_k+0)*(M_sm)+(offset_m+0) ] = factorR + factorL;
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+1) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+2) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+3) ] = static_cast<half>(0.0f);
      
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+0) ] = static_cast<half>(0.0f);
      // sm_a[ (offset_k+1)*(M_sm)+(offset_m+1) ] = factorR + factorL;
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+2) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+3) ] = static_cast<half>(0.0f);
      
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+0) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+1) ] = static_cast<half>(0.0f);
      // sm_a[ (offset_k+2)*(M_sm)+(offset_m+2) ] = factorR + factorL;
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+3) ] = static_cast<half>(0.0f);
      
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+0) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+1) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+2) ] = static_cast<half>(0.0f);
      // sm_a[ (offset_k+3)*(M_sm)+(offset_m+3) ] = factorR + factorL; 
    
      x += block_dim_x;
    }

  }
  
  // matrix a for m5inv: column major, M/M_sm(size/padded size) by k
  // (spin,Ls) by (spin,Ls), where left most index is the fastest changing one(spin).
  // x by y
  template<int block_dim_x, int Ls_, int M_sm, bool dagger, class Arg>
  __device__ inline void construct_matrix_a_m5inv(Arg& arg, half* sm_a, const float* pow_table = nullptr){
    // if we rescale, then the actual matrix is alpha*m5inv+beta.
    // Otherwise a = 1., b = 0.;
    const float b = arg.beta; 
    
    int offset_k = threadIdx.y*4;
    int x = threadIdx.x;
    
    while(x < Ls_){
      int offset_m = x*2;
      float factorR, factorL;
      int exp;
      if(pow_table){
        if(dagger){
          exp = x>threadIdx.y ? Ls_-x+threadIdx.y : threadIdx.y-x;
          factorR = pow_table[exp]*(x>threadIdx.y ? -arg.m_f : 1.f);
        }else{
          exp = x<threadIdx.y ? Ls_-threadIdx.y+x : x-threadIdx.y;
          factorR = pow_table[exp]*(x<threadIdx.y ? -arg.m_f : 1.f);
        }
        
        if(dagger){
          exp = x<threadIdx.y ? Ls_-threadIdx.y+x : x-threadIdx.y;
          factorL = pow_table[exp]*(x<threadIdx.y ? -arg.m_f : 1.f);
        }else{
          exp = x>threadIdx.y ? Ls_-x+threadIdx.y : threadIdx.y-x;
          factorL = pow_table[exp]*(x>threadIdx.y ? -arg.m_f : 1.f);
        }
      }else{
        const float k = arg.kappa;
        const float inv = arg.alpha*arg.fac_inv;
        if(dagger){
          exp = x>threadIdx.y ? Ls_-x+threadIdx.y : threadIdx.y-x;
          factorR = inv*powf(k, __int2float_rn(exp))*(x>threadIdx.y ? -arg.m_f : 1.f);
        }else{
          exp = x<threadIdx.y ? Ls_-threadIdx.y+x : x-threadIdx.y;
          factorR = inv*powf(k, __int2float_rn(exp))*(x<threadIdx.y ? -arg.m_f : 1.f);
        }
        
        if(dagger){
          exp = x<threadIdx.y ? Ls_-threadIdx.y+x : x-threadIdx.y;
          factorL = inv*powf(k, __int2float_rn(exp))*(x<threadIdx.y ? -arg.m_f : 1.f);
        }else{
          exp = x>threadIdx.y ? Ls_-x+threadIdx.y : threadIdx.y-x;
          factorL = inv*powf(k, __int2float_rn(exp))*(x>threadIdx.y ? -arg.m_f : 1.f);
        }
      }

      float RpL = x==threadIdx.y ? factorR+factorL+b : factorR+factorL;
      float RmL = factorR - factorL;
      
      // exp = 0 means we are on the diagonal.
     
      half2* A = reinterpret_cast<half2*>(sm_a);

      A[ (offset_k+0)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(RpL, 0.0f);
      A[ (offset_k+0)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(RmL, 0.0f);
      
      A[ (offset_k+1)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(0.0f, RpL);
      A[ (offset_k+1)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(0.0f, RmL);
      
      A[ (offset_k+2)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(RmL, 0.0f);
      A[ (offset_k+2)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(RpL, 0.0f);
      
      A[ (offset_k+3)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(0.0f, RmL);
      A[ (offset_k+3)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(0.0f, RpL);
    
      x += block_dim_x;
    }

  } 

  // matrix a for m5pre: column major, M/M_sm(size/padded size) by k
  // (spin,Ls) by (spin,Ls), where left most index is the fastest changing one(spin).
  // x by y
  template<int block_dim_x, int Ls_, int M_sm, bool dagger, class Arg>
  __device__ inline void construct_matrix_a_d5(Arg& arg, half* sm_a){
    // if we rescale, then the actual matrix is alpha*m5inv+beta.
    // Otherwise a = 1., b = 0.;
    const float b = arg.beta; 

    int offset_k = threadIdx.y*4;
    int x = threadIdx.x;
    
    while(x < Ls_){
      int offset_m = x*2;
      int exp = x-threadIdx.y;
      float factorR, factorL;
      
      if(dagger){
        factorR = (exp==-1?1.f:(exp==+Ls_-1?-arg.m_f:0.f)); 
      }else{
        factorR = (exp==+1?1.f:(exp==-Ls_+1?-arg.m_f:0.f)); 
      }
      
      if(dagger){
        factorL = (exp==+1?1.f:(exp==-Ls_+1?-arg.m_f:0.f)); 
      }else{
        factorL = (exp==-1?1.f:(exp==+Ls_-1?-arg.m_f:0.f)); 
      }
      
      // exp = 0 means we are on the diagonal.
      float RpL = exp==0 ? arg.alpha*(factorR+factorL)+b : arg.alpha*(factorR+factorL);
      float RmL = arg.alpha*(factorR-factorL);
     
      half2* A = reinterpret_cast<half2*>(sm_a);

      A[ (offset_k+0)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(RpL, 0.0f);
      A[ (offset_k+0)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(RmL, 0.0f);
      
      A[ (offset_k+1)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(0.0f, RpL);
      A[ (offset_k+1)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(0.0f, RmL);
      
      A[ (offset_k+2)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(RmL, 0.0f);
      A[ (offset_k+2)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(RpL, 0.0f);
      
      A[ (offset_k+3)*(M_sm/2)+(offset_m+0) ] = __floats2half2_rn(0.0f, RmL);
      A[ (offset_k+3)*(M_sm/2)+(offset_m+1) ] = __floats2half2_rn(0.0f, RpL);
    
      x += block_dim_x;
    }
  } 

  // Load data(scaled short values and scale) from global memory to shared memroy.
  // (spin,Ls) by (complex,color,4d), where left most index is the fastest changing one(spin and complex).
  // WARNING: This only works for half precision output!
  template<int N_sm, class Input>
  __device__ inline void load_matrix_b_tex(Input& input, half2* sm_b, int sid, const float scale){
    constexpr int N_sm_d2 = N_sm/2;
    
    float f = __fdividef( tex1Dfetch<float>(input.texNorm, sid), scale );
    
    float4 in_tex;
    
    in_tex = tex1Dfetch<float4>(input.tex, 0*input.volumeCB + sid); 
    sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.x*f, in_tex.y*f);
    sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.z*f, in_tex.w*f);
    
    in_tex = tex1Dfetch<float4>(input.tex, 1*input.volumeCB + sid); 
    sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.x*f, in_tex.y*f);
    sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.z*f, in_tex.w*f);
    
    in_tex = tex1Dfetch<float4>(input.tex, 2*input.volumeCB + sid); 
    sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.x*f, in_tex.y*f);
    sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.z*f, in_tex.w*f);
    
    in_tex = tex1Dfetch<float4>(input.tex, 3*input.volumeCB + sid); 
    sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.x*f, in_tex.y*f);
    sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.z*f, in_tex.w*f);
    
    in_tex = tex1Dfetch<float4>(input.tex, 4*input.volumeCB + sid); 
    sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.x*f, in_tex.y*f);
    sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.z*f, in_tex.w*f);
    
    in_tex = tex1Dfetch<float4>(input.tex, 5*input.volumeCB + sid); 
    sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.x*f, in_tex.y*f);
    sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.z*f, in_tex.w*f);
  } 
  
  template<class integer_vec>
  __device__ inline integer_vec __2half22integer4_rn(const half2& a, const half2& b){
    integer_vec c;
    c.x = __half2short_rn(a.x);
    c.y = __half2short_rn(a.y);
    c.z = __half2short_rn(b.x);
    c.w = __half2short_rn(b.y);
    return c;
  }
  
  __device__ inline void __half_max_abs_half2__(half& max, half2& input){
    static_assert(sizeof(half2) == sizeof(uint32_t));
    // Just mask the exponent part
    static constexpr uint32_t is_normal_mask_l = 0x83ffffffu;  // 10000011 11111111 11111111 11111111 
    static constexpr uint32_t is_normal_mask_h = 0xffff83ffu;  // 11111111 11111111 10000011 11111111 
    
    uint32_t is_normal_masked_l = *reinterpret_cast<uint32_t*>(&input) | is_normal_mask_l;
    uint32_t is_normal_masked_h = *reinterpret_cast<uint32_t*>(&input) | is_normal_mask_h;
    
    // Check if the halves are normal
    if(is_normal_masked_l == 0xffffffffu){                     // 10000011 11111111 11111111 11111111
      *reinterpret_cast<uint32_t*>(&input) = *reinterpret_cast<uint32_t*>(&input) & is_normal_mask_l;
    }
    if(is_normal_masked_h == 0xffffffffu){                     // 10000011 11111111 11111111 11111111
      *reinterpret_cast<uint32_t*>(&input) = *reinterpret_cast<uint32_t*>(&input) & is_normal_mask_h;
    }
    
    // Set the fisrt bit of the halves to 0.
    static constexpr uint32_t maximum_mask = 0x7fff7fffu;      // 01111111 11111111 01111111 11111111 
    
    uint32_t input_masked = *reinterpret_cast<uint32_t*>(&input) & maximum_mask;
    half2 lh = *reinterpret_cast<half2*>(&input_masked);
    if(__hgt(lh.x, max)){
      max = lh.x;
    }
    if(__hgt(lh.y, max)){
      max = lh.y;
    }
  }

  __device__ inline int permute(int n){
    int n32 = n & 31;
    return (n>>5)*32 + ((n32>>2)&1)*16 + (n32>>3)*4 + (n&3);
  }

  // Actually does more than the function name suggests.
  // will find the maximum absolute value among the vector, scale that, and store to sm_b
  template<int N_sm_d2, bool acc, class Vector>
  __device__ inline void load_matrix_b_vector(const Vector& v, half2* sm_b, const float scale){
    #pragma unroll
    for(int spin = 0; spin < 4; spin++){
      #pragma unroll
      for(int color = 0; color < 3; color++){
        float real = __fdividef(v(spin, color).real(), scale); // real = real>H_MAX?H_MAX:real;
        float imag = __fdividef(v(spin, color).imag(), scale); // imag = imag>H_MAX?H_MAX:imag;
        int idx = (threadIdx.y*4+spin)*N_sm_d2 + permute(3*threadIdx.x+color);
        if(acc){
          sm_b[idx] = __hadd2(sm_b[idx], __floats2half2_rn(real, imag));
        }else{
          sm_b[idx] = __floats2half2_rn(real, imag);
        }
      }
    }
  }

  // Store results(scaled short/char values and scale) in shared memroy to global memroy.
  template<class storage_type, int N_sm, class Output>
  __device__ inline void store_matrix_c(Output& output, half2* sm_b, int sid, const float scale){
    half max_ = 0.0f;
    constexpr int N_sm_d2 = N_sm/2;
    #pragma unroll
    for(int spin = 0; spin < 4; spin++){
      #pragma unroll
      for(int color = 0; color < 3; color++){
        int idx = (threadIdx.y*4+spin)*N_sm_d2+ + permute(3*threadIdx.x+color);
        __half_max_abs_half2__(max_, sm_b[idx]);
      }
    }

    output.norm[sid] = __half2float(max_)*scale;
    
    const half2 max_i_div_max2_ = __half2half2( __hdiv(fixedMaxValue<storage_type>::value, max_) );

    typedef typename VectorType<storage_type, 4>::type storage_vec;
    storage_vec* out = reinterpret_cast<storage_vec*>(output.field);
    half2 a, b;

    a = __hmul2(sm_b[ (threadIdx.y*4+0)*N_sm_d2+permute(3*threadIdx.x+0) ], max_i_div_max2_);
    b = __hmul2(sm_b[ (threadIdx.y*4+0)*N_sm_d2+permute(3*threadIdx.x+1) ], max_i_div_max2_);
    out[sid + 0*output.volumeCB] = __2half22integer4_rn<storage_vec>(a, b); 
    
    a = __hmul2(sm_b[ (threadIdx.y*4+0)*N_sm_d2+permute(3*threadIdx.x+2) ], max_i_div_max2_);
    b = __hmul2(sm_b[ (threadIdx.y*4+1)*N_sm_d2+permute(3*threadIdx.x+0) ], max_i_div_max2_);
    out[sid + 1*output.volumeCB] = __2half22integer4_rn<storage_vec>(a, b); 
    
    a = __hmul2(sm_b[ (threadIdx.y*4+1)*N_sm_d2+permute(3*threadIdx.x+1) ], max_i_div_max2_);
    b = __hmul2(sm_b[ (threadIdx.y*4+1)*N_sm_d2+permute(3*threadIdx.x+2) ], max_i_div_max2_);
    out[sid + 2*output.volumeCB] = __2half22integer4_rn<storage_vec>(a, b); 
    
    a = __hmul2(sm_b[ (threadIdx.y*4+2)*N_sm_d2+permute(3*threadIdx.x+0) ], max_i_div_max2_);
    b = __hmul2(sm_b[ (threadIdx.y*4+2)*N_sm_d2+permute(3*threadIdx.x+1) ], max_i_div_max2_);
    out[sid + 3*output.volumeCB] = __2half22integer4_rn<storage_vec>(a, b); 
    
    a = __hmul2(sm_b[ (threadIdx.y*4+2)*N_sm_d2+permute(3*threadIdx.x+2) ], max_i_div_max2_);
    b = __hmul2(sm_b[ (threadIdx.y*4+3)*N_sm_d2+permute(3*threadIdx.x+0) ], max_i_div_max2_);
    out[sid + 4*output.volumeCB] = __2half22integer4_rn<storage_vec>(a, b); 
    
    a = __hmul2(sm_b[ (threadIdx.y*4+3)*N_sm_d2+permute(3*threadIdx.x+1) ], max_i_div_max2_);
    b = __hmul2(sm_b[ (threadIdx.y*4+3)*N_sm_d2+permute(3*threadIdx.x+2) ], max_i_div_max2_);
    out[sid + 5*output.volumeCB] = __2half22integer4_rn<storage_vec>(a, b); 
  } 

  // For "reload" version(reload == true) of wmma gemm, matrix a is loaded when needed.
  // It is a waste of time but has less register usage.
  // For "preload" version(reload == false) of wmma gemm, matrix a is preloaded before hand.
  // It saves time but uses more registers.
  template<int block_dim_x, int Ls_, int M, int N, int M_sm, int N_sm, bool reload, class T>
  __device__ inline void wmma_gemm(T* a_frag, half* sm_a, half* sm_b, half* sm_c){
    constexpr int WMMA_M = 16;
    constexpr int WMMA_N = 16;
    constexpr int WMMA_K = 16;
    
    constexpr int tm_dim = M/WMMA_M;
    constexpr int tn_dim = N/WMMA_N;
    
    constexpr int total_warp = block_dim_x*Ls_/32;
    
    static_assert( (tm_dim*tn_dim)%total_warp==0, "(tm_dim*tn_dim)%%total_warp==0\n" );
    static_assert( tn_dim%(tm_dim*tn_dim/total_warp)==0, "tn_dim%%(tm_dim*tn_dim/total_warp)==0\n" );
    
    const int this_warp = (threadIdx.y*block_dim_x+threadIdx.x) >> 5;
    
    constexpr int total_tile = tm_dim*tn_dim;
    
    constexpr int warp_cycle = total_tile/total_warp;
    const int warp_m = this_warp*warp_cycle/tn_dim;
    #pragma unroll
    for(int c = 0; c < warp_cycle; c++){
      // Set up the wmma stuff
      nvcuda::wmma::fragment<nvcuda::wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::row_major> b_frag;
      nvcuda::wmma::fragment<nvcuda::wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, half> c_frag;

      // The logical warp assigned to each part of the matrix.
      const int phys_warp_index = this_warp*warp_cycle+c;
      const int warp_n = phys_warp_index-warp_m*tn_dim;
      // eg. for 12 warps:
      // 000|111|222|333
      // 444|555|666|777
      // 888|999|000|111
      
      // Zero the initial acc.
      nvcuda::wmma::fill_fragment(c_frag, static_cast<half>(0.0f));
      
      #pragma unroll
      for( int k = 0; k < tm_dim; k++ ){
        const int a_row = warp_m*WMMA_M;
        const int a_col = k*WMMA_K;
        const int b_row = k*WMMA_K;
        const int b_col = warp_n*WMMA_N;
    
        // Load Matrix
        if(reload){
          nvcuda::wmma::load_matrix_sync(a_frag[0], sm_a+a_row+a_col*M_sm, M_sm);
        }
        nvcuda::wmma::load_matrix_sync(b_frag, sm_c+b_col+b_row*N_sm, N_sm);
        // Perform the matrix multiplication
        if(reload){
          nvcuda::wmma::mma_sync(c_frag, a_frag[0], b_frag, c_frag);
        }else{
          nvcuda::wmma::mma_sync(c_frag, a_frag[k], b_frag, c_frag);
        }
      } 
    
      __syncthreads();
      
      int c_row = warp_m*WMMA_M;
      int c_col = warp_n*WMMA_N;

      nvcuda::wmma::store_matrix_sync(sm_c+c_col+c_row*N_sm, c_frag, N_sm, nvcuda::wmma::mem_row_major);
    }
  } 
  
  template<int block_dim_x, int Ls, int M, int N, int M_sm, int N_sm> 
  __device__ inline void mma_sync_gemm(half* sm_a, half* sm_b, half* sm_c){
    constexpr int WMMA_M = 16;
    constexpr int WMMA_N = 16;
    
    constexpr int tm_dim = M/WMMA_M;
    constexpr int tn_dim = N/WMMA_N;
    
    constexpr int total_warp = block_dim_x*Ls >> 5;
    
    static_assert( (tm_dim*tn_dim)%total_warp==0, "(tm_dim*tn_dim)%%total_warp==0\n" );
    static_assert( tn_dim%(tm_dim*tn_dim/total_warp)==0, "tn_dim%%(tm_dim*tn_dim/total_warp)==0\n" );
    static_assert( N%64==0, "N%%64==0\n" );
    
    constexpr int total_tile = tm_dim*tn_dim;
    
    constexpr int warp_cycle = total_tile/total_warp;

    const int thread_num = threadIdx.y*block_dim_x+threadIdx.x; 
    const int this_warp = thread_num >> 5; // warp_id
    const int warp_m = this_warp*warp_cycle/tn_dim;

    const int lane_id = thread_num & 0x1f;
    const int octl_id = (lane_id >> 2);
    const int quad_id = (octl_id & 0x3);
    const int quad_row = (quad_id & 1);
    const int quad_col = (quad_id >> 1);
    const int quad_hilo = (octl_id >> 2) & 1; // quad higher or lower.
    const int quad_thread = (lane_id & 0x3); // 0,1,2,3

    #pragma unroll
    for(int c = 0; c < warp_cycle; c++){
      unsigned rc[4] = {0x0u, 0x0u, 0x0u, 0x0u};
      // The logical warp assigned to each part of the matrix.
      const int phys_warp_index = this_warp*warp_cycle+c;
      const int warp_n = phys_warp_index-warp_m*tn_dim;
      // eg. for 12 warps:
      // 000|111|222|333
      // 444|555|666|777
      // 888|999|000|111
      
      #pragma unroll
      for( int k = 0; k < tm_dim; k++ ){
        // performa the mma.sync
        #pragma unroll
        for(int kC = 0; kC < 4; kC++){
          unsigned* A = reinterpret_cast<unsigned*>(sm_a);
          unsigned* B = reinterpret_cast<unsigned*>(sm_b);
          int ldi = k*16 + kC*4 + quad_thread;
          int thread_offset_a = ldi * (M_sm/2) + warp_m*8 + quad_row*4 + quad_hilo*2;
          int thread_offset_b = ldi * (N_sm/2) + permute(warp_n*8 + quad_col*4 + quad_hilo*2);
          asm volatile(
              "mma.sync.aligned.m8n8k4.col.row.f16.f16.f16.f16 {%0,%1,%2,%3}, {%4,%5}, {%6,%7}, {%0,%1,%2,%3};"
            : "+r"(rc[0]), "+r"(rc[1]), "+r"(rc[2]), "+r"(rc[3])
            : "r"(A[thread_offset_a + 0]),  "r"(A[thread_offset_a + 1]),  
              "r"(B[thread_offset_b + 0]),  "r"(B[thread_offset_b + 1])
          );
        }
      } 
    
      __syncthreads();
      
      unsigned* C = reinterpret_cast<unsigned*>(sm_c);
      int thread_offset_c = (warp_m*16 + quad_row*8 + quad_hilo*4 + quad_thread) * (N_sm/2) + permute(warp_n*8 + quad_col*4);
      
      // Now store the results to shared memory
      #pragma unroll
      for(int i = 0; i < 4; i++){
        C[thread_offset_c + i] = rc[i];
      }
    }
  } 

#endif // defined (GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700)

} // namespace quda

