#!/bin/bash
#SBATCH --job-name=cuda-sm75-test
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:05:00
#SBATCH --output=/home/hpcuser/projects/cuda-sm75-%j.out

cd /home/hpcuser/projects

echo "Kompiliere CUDA-Kernel gezielt für Compute Capability 7.5 (sm_75)..."
nvcc -O3 -arch=sm_75 vec_stress.cu -o vec_stress

echo "Starte CUDA-Binary auf der RTX 2060..."
./vec_stress
