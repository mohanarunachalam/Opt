#pragma once

#include "PatchSolverSFSParameters.h"
#include "../CameraParams.h"
struct TerraSolverParameters {
    float weightFitting;					// Is initialized by the solver!

    float weightRegularizer;				// Regularization weight
    float weightPrior;						// Prior weight

    float weightShading;					// Shading weight
    float weightShadingStart;				// Starting value for incremental relaxation
    float weightShadingIncrement;			// Update factor

    float weightBoundary;					// Boundary weight

    float fx;
    float fy;
    float ux;
    float uy;


    float4x4 deltaTransform;
    float lightingCoefficients[9];

    unsigned int nNonLinearIterations;		// Steps of the non-linear solver	
    unsigned int nLinIterations;			// Steps of the linear solver
    unsigned int nPatchIterations;			// Steps on linear step on block level

    TerraSolverParameters() {}
    TerraSolverParameters(const PatchSolverParameters& p, const CameraParams& cameraParams, float* deltaTransformPtr, float* d_lightCoeffs) :
        weightFitting(p.weightFitting),
        weightRegularizer(p.weightRegularizer),
        weightPrior(p.weightPrior),
        weightShading(p.weightShading),
        weightShadingStart(p.weightShadingStart),
        weightShadingIncrement(p.weightShadingIncrement),
        weightBoundary(p.weightBoundary),
        fx(cameraParams.fx),
        fy(cameraParams.fy),
        ux(cameraParams.ux),
        uy(cameraParams.uy),
        deltaTransform(deltaTransformPtr),
        nNonLinearIterations(p.nNonLinearIterations),
        nLinIterations(p.nLinIterations),
        nPatchIterations(p.nPatchIterations)
    {
        CUDA_SAFE_CALL(cudaMemcpy(lightingCoefficients, d_lightCoeffs, sizeof(float) * 9, cudaMemcpyDeviceToHost));
    }
};

struct TerraSolverParameterPointers {
    float* floatPointers[36];
    unsigned int* uintPointers[3];
    TerraSolverParameterPointers(const TerraSolverParameters& p) {
        for (int i = 0; i < 36; ++i) {
            floatPointers[i] = ((float*)(&p)) + i;
        }
        for (int i = 0; i < 3; ++i) {
            uintPointers[i] = (unsigned int*)(floatPointers[35] + 1) + i;
        }
    }
};