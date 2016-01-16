#include <iostream>

#include "WarpingSolverParameters.h"
#include "WarpingSolverState.h"
#include "WarpingSolverUtil.h"
#include "WarpingSolverEquations.h"

#include <assert.h>
#include <stdio.h>
#include <stdint.h>

#include "CUDATimer.h"

#ifdef _WIN32
#include <conio.h>
#endif

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

#define WARP_SIZE 32u
#define WARP_MASK (WARP_SIZE-1u)

#define DEBUG_PRINT_INFO 0

/////////////////////////////////////////////////////////////////////////
// Eval Residual
/////////////////////////////////////////////////////////////////////////

__global__ void ResetResidualDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
	if (x == 0) state.d_sumResidual[0] = 0.0f;
}

__global__ void EvalResidualDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.N; // Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

    float residual = 0.0f;
	if (x < N)
	{
		residual = evalFDevice(x, input, state, parameters);
	}
    // Must do shuffle in entire warp
    float r = warpReduce(residual);
    if ((threadIdx.x & WARP_MASK) == 0) {
        atomicAdd(state.d_sumResidual, r);
    }
}

float EvalResidual(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer& timer)
{
	float residual = 0.0f;

	const unsigned int N = input.N; // Number of block variables
	ResetResidualDevice << < 1, 1, 1 >> >(input, state, parameters);
	cutilSafeCall(cudaDeviceSynchronize());
	timer.startEvent("EvalResidual");
	EvalResidualDevice << <(N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK, THREADS_PER_BLOCK >> >(input, state, parameters);
	timer.endEvent();
	cutilSafeCall(cudaDeviceSynchronize());

#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif


    cutilSafeCall(cudaMemcpy(&residual, &state.d_sumResidual[0], sizeof(float), cudaMemcpyDeviceToHost));

	return residual;
}

// For the naming scheme of the variables see:
// http://en.wikipedia.org/wiki/Conjugate_gradient_method
// This code is an implementation of their PCG pseudo code

__global__ void PCGInit_Kernel1(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.N;
	const int x = blockIdx.x * blockDim.x + threadIdx.x;

	float d = 0.0f;
	if (x < N && state.d_mask[x] == 0)
	{
		const float4 residuum = evalMinusJTFDevice(x, input, state, parameters); // residuum = J^T x -F - A x delta_0  => J^T x -F, since A x x_0 == 0 
		state.d_r[x]  = residuum;												 // store for next iteration

		const float4 p  = state.d_precondioner[x]  * residuum;					 // apply preconditioner M^-1
		state.d_p[x] = p;

		d = dot(residuum, p);								 // x-th term of nomimator for computing alpha and denominator for computing beta
    }

    d = warpReduce(d);
    if ((threadIdx.x & WARP_MASK) == 0) {
        atomicAdd(state.d_scanAlpha, d);
    }
}

__global__ void PCGInit_Kernel2(unsigned int N, SolverState state)
{
    const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

    if (x < N) {
        state.d_rDotzOld[x] = state.d_scanAlpha[0];
        state.d_delta[x] = make_float4(0.0f, 0.0f, 0.0f, 0.0f);
    }
}

void Initialization(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer& timer)
{
	const unsigned int N = input.N;

	const int blocksPerGrid = (N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
	const int shmem_size = sizeof(float)*THREADS_PER_BLOCK;

	if (blocksPerGrid > THREADS_PER_BLOCK)
	{
		std::cout << "Too many variables for this block size. Maximum number of variables for two kernel scan: " << THREADS_PER_BLOCK*THREADS_PER_BLOCK << std::endl;
		while (1);
    }

    cutilSafeCall(cudaMemset(state.d_scanAlpha, 0, sizeof(float)));
    timer.startEvent("PCGInit_Kernel1");
	PCGInit_Kernel1 << <blocksPerGrid, THREADS_PER_BLOCK, shmem_size >> >(input, state, parameters);
    timer.endEvent();
	#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
	#endif

	timer.startEvent("PCGInit_Kernel2");
	PCGInit_Kernel2 << <blocksPerGrid, THREADS_PER_BLOCK, shmem_size >> >(N, state);
	timer.endEvent();
	#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
	#endif
}

/////////////////////////////////////////////////////////////////////////
// PCG Iteration Parts
/////////////////////////////////////////////////////////////////////////

__global__ void PCGStep_Kernel1(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.N;											// Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	float d = 0.0f;
	if (x < N && state.d_mask[x] == 0)
	{
		const float4 tmp = applyJTJDevice(x, input, state, parameters);		// A x p_k  => J^T x J x p_k 

		state.d_Ap_X[x]  = tmp;														// store for next kernel call

		d = dot(state.d_p[x], tmp);													// x-th term of denominator of alpha
	}

    d = warpReduce(d);
    if ((threadIdx.x & WARP_MASK) == 0) {
        atomicAdd(state.d_scanAlpha, d); // sum over x-th terms to compute denominator of alpha inside this block
    }
}

__global__ void PCGStep_Kernel2(SolverInput input, SolverState state)
{
	const unsigned int N = input.N;
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

    const float dotProduct = state.d_scanAlpha[0];

	float b = 0.0f;
	if (x < N && state.d_mask[x] == 0)
	{
		float alpha = 0.0f;
		if (dotProduct > FLOAT_EPSILON) alpha = state.d_rDotzOld[x] / dotProduct;  // update step size alpha

		state.d_delta[x]  = state.d_delta[x]  + alpha*state.d_p[x];				// do a decent step

		float4 r = state.d_r[x] - alpha*state.d_Ap_X[x];					// update residuum
		state.d_r[x] = r;													// store for next kernel call

		float4 z = state.d_precondioner[x] * r;								// apply preconditioner M^-1
		state.d_z[x] = z;													// save for next kernel call

		b = dot(z, r);														// compute x-th term of the nominator of beta
	}

    b = warpReduce(b);
    if ((threadIdx.x & WARP_MASK) == 0) {
        atomicAdd(state.d_scanBeta, b); // sum over x-th terms to compute denominator of alpha inside this block
    }
}

__global__ void PCGStep_Kernel3(SolverInput input, SolverState state)
{
	const unsigned int N = input.N;
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x < N && state.d_mask[x] == 0)
	{
        const float rDotzNew = state.d_scanBeta[0];									// get new nominator
		const float rDotzOld = state.d_rDotzOld[x];								// get old denominator

		float beta = 0.0f;
		if (rDotzOld > FLOAT_EPSILON) beta = rDotzNew / rDotzOld;					// update step size beta

		state.d_rDotzOld[x] = rDotzNew;												// save new rDotz for next iteration
		state.d_p[x]  = state.d_z[x]  + beta*state.d_p[x];							// update decent direction
	}
}

void PCGIteration(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer& timer)
{
	const unsigned int N = input.N;	// Number of block variables

	// Do PCG step
	const int blocksPerGrid = (N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
	const int shmem_size = sizeof(float)*THREADS_PER_BLOCK;

	if (blocksPerGrid > THREADS_PER_BLOCK)
	{
		std::cout << "Too many variables for this block size. Maximum number of variables for two kernel scan: " << THREADS_PER_BLOCK*THREADS_PER_BLOCK << std::endl;
		while (1);
	}
    cutilSafeCall(cudaMemset(state.d_scanAlpha, 0, sizeof(float)));
    timer.startEvent("PCGStep_Kernel1");
    PCGStep_Kernel1 << <blocksPerGrid, THREADS_PER_BLOCK, shmem_size >> >(input, state, parameters);
    timer.endEvent();
	#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
	#endif

    cutilSafeCall(cudaMemset(state.d_scanBeta, 0, sizeof(float)));
	timer.startEvent("PCGStep_Kernel2");
	PCGStep_Kernel2 << <blocksPerGrid, THREADS_PER_BLOCK, shmem_size >> >(input, state);
	timer.endEvent();
	#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
	#endif

	timer.startEvent("PCGStep_Kernel3");
	PCGStep_Kernel3 << <blocksPerGrid, THREADS_PER_BLOCK, shmem_size >> >(input, state);
	timer.endEvent();
	#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
	#endif
}

/////////////////////////////////////////////////////////////////////////
// Apply Update
/////////////////////////////////////////////////////////////////////////

__global__ void ApplyLinearUpdateDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.N; // Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x < N && state.d_mask[x] == 0) {
		state.d_x[x] = state.d_x[x] + state.d_delta[x];
	}
}

void ApplyLinearUpdate(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer& timer)
{
	const unsigned int N = input.N; // Number of block variables
    timer.startEvent("ApplyLinearUpdateDevice");
	ApplyLinearUpdateDevice << <(N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK, THREADS_PER_BLOCK >> >(input, state, parameters);
    timer.endEvent();
	cutilSafeCall(cudaDeviceSynchronize()); // Hm

	#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
	#endif
}

////////////////////////////////////////////////////////////////////
// Main GN Solver Loop
////////////////////////////////////////////////////////////////////

extern "C" void ImageWarpiungSolveGNStub(SolverInput& input, SolverState& state, SolverParameters& parameters)
{
    CUDATimer timer;

	for (unsigned int nIter = 0; nIter < parameters.nNonLinearIterations; nIter++)
	{
		float residual = EvalResidual(input, state, parameters, timer);
		printf("%i: cost: %f\n", nIter, residual);

		Initialization(input, state, parameters, timer);

		for (unsigned int linIter = 0; linIter < parameters.nLinIterations; linIter++) {
			PCGIteration(input, state, parameters, timer);
		}

		ApplyLinearUpdate(input, state, parameters, timer);	//this should be also done in the last PCGIteration

        timer.nextIteration();
	}

	float residual = EvalResidual(input, state, parameters, timer);
	printf("final cost: %f\n", residual);

    timer.evaluate();

}
