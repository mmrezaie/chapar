#include <mpi.h>
#include <cuda_runtime.h>

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace {

long long env_ll(const char *name, long long fallback) {
    const char *value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') {
        return fallback;
    }

    char *end = nullptr;
    long long parsed = std::strtoll(value, &end, 10);
    if (end == value || *end != '\0') {
        return fallback;
    }
    return parsed;
}

int env_int_first(const char *const *names, int fallback) {
    for (const char *const *name = names; *name != nullptr; ++name) {
        const char *value = std::getenv(*name);
        if (value == nullptr || value[0] == '\0') {
            continue;
        }
        char *end = nullptr;
        long parsed = std::strtol(value, &end, 10);
        if (end != value && *end == '\0' && parsed >= 0) {
            return static_cast<int>(parsed);
        }
    }
    return fallback;
}

unsigned char pattern(int rank, std::size_t index) {
    return static_cast<unsigned char>((rank * 131 + index * 17 + index / 251) & 0xff);
}

void cuda_check(int rank, cudaError_t err, const char *expr, const char *file, int line) {
    if (err == cudaSuccess) {
        return;
    }
    std::fprintf(stderr, "rank %d CUDA error at %s:%d for %s: %s\n",
                 rank, file, line, expr, cudaGetErrorString(err));
    MPI_Abort(MPI_COMM_WORLD, 3);
}

} // namespace

#define CUDA_CHECK(rank, expr) cuda_check((rank), (expr), #expr, __FILE__, __LINE__)

int main(int argc, char **argv) {
    int provided = MPI_THREAD_SINGLE;
    MPI_Init_thread(&argc, &argv, MPI_THREAD_FUNNELED, &provided);

    int rank = 0;
    int size = 0;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size < 2) {
        if (rank == 0) {
            std::fprintf(stderr, "mpi_rdma_cuda requires at least two ranks\n");
        }
        MPI_Finalize();
        return 2;
    }

    int device_count = 0;
    CUDA_CHECK(rank, cudaGetDeviceCount(&device_count));
    if (device_count <= 0) {
        if (rank == 0) {
            std::fprintf(stderr, "mpi_rdma_cuda requires at least one CUDA device\n");
        }
        MPI_Finalize();
        return 2;
    }

    const char *const local_rank_envs[] = {
        "SLURM_LOCALID",
        "OMPI_COMM_WORLD_LOCAL_RANK",
        "I_MPI_LOCAL_RANK",
        "MPI_LOCALRANKID",
        "PMI_LOCAL_RANK",
        nullptr,
    };
    const int local_rank = env_int_first(local_rank_envs, rank);
    const int device = local_rank % device_count;
    CUDA_CHECK(rank, cudaSetDevice(device));

    cudaDeviceProp prop{};
    CUDA_CHECK(rank, cudaGetDeviceProperties(&prop, device));

    const long long bytes_ll = env_ll("MPI_RDMA_BYTES", 8LL * 1024LL * 1024LL);
    const long long iters_ll = env_ll("MPI_RDMA_ITERS", 100);
    if (bytes_ll <= 0 || bytes_ll > INT_MAX || iters_ll <= 0) {
        if (rank == 0) {
            std::fprintf(stderr, "invalid MPI_RDMA_BYTES or MPI_RDMA_ITERS\n");
        }
        MPI_Finalize();
        return 2;
    }

    const int count = static_cast<int>(bytes_ll);
    const int iterations = static_cast<int>(iters_ll);
    const std::size_t bytes = static_cast<std::size_t>(bytes_ll);

    char name[MPI_MAX_PROCESSOR_NAME] = {0};
    int name_len = 0;
    MPI_Get_processor_name(name, &name_len);

    std::vector<char> all_names(static_cast<std::size_t>(size) * MPI_MAX_PROCESSOR_NAME, '\0');
    MPI_Allgather(name, MPI_MAX_PROCESSOR_NAME, MPI_CHAR, all_names.data(), MPI_MAX_PROCESSOR_NAME, MPI_CHAR, MPI_COMM_WORLD);

    std::set<std::string> hosts;
    for (int i = 0; i < size; ++i) {
        hosts.emplace(&all_names[static_cast<std::size_t>(i) * MPI_MAX_PROCESSOR_NAME]);
    }

    std::vector<unsigned char> send_host(bytes);
    std::vector<unsigned char> recv_host(bytes, 0);
    for (std::size_t i = 0; i < bytes; ++i) {
        send_host[i] = pattern(rank, i);
    }

    void *send_device = nullptr;
    void *recv_device = nullptr;
    CUDA_CHECK(rank, cudaMalloc(&send_device, bytes));
    CUDA_CHECK(rank, cudaMalloc(&recv_device, bytes));
    CUDA_CHECK(rank, cudaMemcpy(send_device, send_host.data(), bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(rank, cudaMemset(recv_device, 0, bytes));
    CUDA_CHECK(rank, cudaDeviceSynchronize());

    const int dst = (rank + 1) % size;
    const int src = (rank + size - 1) % size;

    MPI_Barrier(MPI_COMM_WORLD);
    const double t0 = MPI_Wtime();
    for (int iter = 0; iter < iterations; ++iter) {
        MPI_Sendrecv(send_device, count, MPI_UNSIGNED_CHAR, dst, 0,
                     recv_device, count, MPI_UNSIGNED_CHAR, src, 0,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    }
    MPI_Barrier(MPI_COMM_WORLD);
    const double elapsed = MPI_Wtime() - t0;

    CUDA_CHECK(rank, cudaMemcpy(recv_host.data(), recv_device, bytes, cudaMemcpyDeviceToHost));
    CUDA_CHECK(rank, cudaDeviceSynchronize());

    unsigned long long errors = 0;
    for (std::size_t i = 0; i < bytes; ++i) {
        if (recv_host[i] != pattern(src, i)) {
            if (errors == 0) {
                std::fprintf(stderr, "rank %d first mismatch at byte %zu: got %u expected %u\n",
                             rank, i, static_cast<unsigned>(recv_host[i]), static_cast<unsigned>(pattern(src, i)));
            }
            ++errors;
        }
    }

    CUDA_CHECK(rank, cudaFree(send_device));
    CUDA_CHECK(rank, cudaFree(recv_device));

    unsigned long long global_errors = 0;
    double max_elapsed = 0.0;
    MPI_Reduce(&errors, &global_errors, 1, MPI_UNSIGNED_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);
    MPI_Reduce(&elapsed, &max_elapsed, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        const double gib = static_cast<double>(bytes) * iterations * size / (1024.0 * 1024.0 * 1024.0);
        std::printf("mpi_rdma_cuda ranks=%d hosts=%zu bytes=%zu iterations=%d time=%.6f aggregate_GiB=%.3f aggregate_GiBps=%.3f device0=%s\n",
                    size, hosts.size(), bytes, iterations, max_elapsed, gib, gib / max_elapsed, prop.name);
        if (hosts.size() < 2) {
            std::fprintf(stderr, "warning: all ranks appear to be on one host; this is not an inter-node GPU RDMA validation\n");
        }
        if (global_errors != 0) {
            std::fprintf(stderr, "mpi_rdma_cuda validation failed with %llu byte mismatches\n", global_errors);
        }
    }

    MPI_Finalize();
    return global_errors == 0 ? 0 : 1;
}
