#include <stdio.h>
#include <cuda_runtime.h>

__global__ void vector_fma(const float* a, const float* b, float* c, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float val = a[idx];
        // 500 Fused-Multiply-Add Operationen pro Thread für messbare GPU-Last
        for (int i = 0; i < 500; ++i) {
            val = val * b[idx] + 0.001f;
        }
        c[idx] = val;
    }
}

int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("GPU: %s (Compute Capability %d.%d, SMs: %d)\n",
           prop.name, prop.major, prop.minor, prop.multiProcessorCount);

    const int N = 64 * 1024 * 1024; // 64M Elemente (~768 MB VRAM gesamt)
    const size_t bytes = N * sizeof(float);

    float *d_a, *d_b, *d_c;
    cudaMalloc(&d_a, bytes);
    cudaMalloc(&d_b, bytes);
    cudaMalloc(&d_c, bytes);

    cudaMemset(d_a, 1, bytes);
    cudaMemset(d_b, 1, bytes);

    int threads = 256;
    int blocks = (N + threads - 1) / threads;

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start);
    for (int iter = 0; iter < 50; ++iter) {
        vector_fma<<<blocks, threads>>>(d_a, d_b, d_c, N);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms = 0.0f;
    cudaEventElapsedTime(&ms, start, stop);
    printf("50 Kernel-Durchläufe für %d Elemente abgeschlossen in %.2f ms\n", N, ms);

    cudaFree(d_a);
    cudaFree(d_b);
    cudaFree(d_c);
    return 0;
}
