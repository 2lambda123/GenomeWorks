/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include <iostream>
#include <fstream>
#include <string>
#include <claraparabricks/genomeworks/cudapoa/utils.hpp> // for get_multi_batch_sizes()
#include "application_parameters.hpp"

namespace claraparabricks
{

namespace genomeworks
{

namespace cudapoa
{

std::unique_ptr<Batch> initialize_batch(bool msa, bool banded_alignment, const double gpu_mem_allocation, const BatchSize& batch_size)
{
    // Get device information.
    int32_t device_count = 0;
    CGA_CU_CHECK_ERR(cudaGetDeviceCount(&device_count));
    assert(device_count > 0);

    size_t total = 0, free = 0;
    cudaSetDevice(0); // Using first GPU for sample.
    cudaMemGetInfo(&free, &total);

    // Initialize internal logging framework.
    Init();

    // Initialize CUDAPOA batch object for batched processing of POAs on the GPU.
    const int32_t device_id      = 0;
    cudaStream_t stream          = 0;
    size_t mem_per_batch         = gpu_mem_allocation * free; // Using 90% of GPU available memory for CUDAPOA batch.
    const int32_t mismatch_score = -6, gap_score = -8, match_score = 8;

    std::unique_ptr<Batch> batch = create_batch(device_id,
                                                stream,
                                                mem_per_batch,
                                                msa ? OutputType::msa : OutputType::consensus,
                                                batch_size,
                                                gap_score,
                                                mismatch_score,
                                                match_score,
                                                banded_alignment);

    return std::move(batch);
}

void process_batch(Batch* batch, bool msa, bool print)
{
    batch->generate_poa();

    StatusType status = StatusType::success;
    if (msa)
    {
        // Grab MSA results for all POA groups in batch.
        std::vector<std::vector<std::string>> msa; // MSA per group
        std::vector<StatusType> output_status;     // Status of MSA generation per group

        status = batch->get_msa(msa, output_status);
        if (status != StatusType::success)
        {
            std::cerr << "Could not generate MSA for batch : " << status << std::endl;
        }

        for (int32_t g = 0; g < get_size(msa); g++)
        {
            if (output_status[g] != StatusType::success)
            {
                std::cerr << "Error generating  MSA for POA group " << g << ". Error type " << output_status[g] << std::endl;
            }
            else
            {
                if (print)
                {
                    for (const auto& alignment : msa[g])
                    {
                        std::cout << alignment << std::endl;
                    }
                }
            }
        }
    }
    else
    {
        // Grab consensus results for all POA groups in batch.
        std::vector<std::string> consensus;          // Consensus string for each POA group
        std::vector<std::vector<uint16_t>> coverage; // Per base coverage for each consensus
        std::vector<StatusType> output_status;       // Status of consensus generation per group

        status = batch->get_consensus(consensus, coverage, output_status);
        if (status != StatusType::success)
        {
            std::cerr << "Could not generate consensus for batch : " << status << std::endl;
        }

        for (int32_t g = 0; g < get_size(consensus); g++)
        {
            if (output_status[g] != StatusType::success)
            {
                std::cerr << "Error generating consensus for POA group " << g << ". Error type " << output_status[g] << std::endl;
            }
            else
            {
                if (print)
                {
                    std::cout << consensus[g] << std::endl;
                }
            }
        }
    }
}

int main(int argc, char* argv[])
{
    // Parse input parameters
    const ApplicationParameters parameters(argc, argv);

    // Load input data. Each window is represented as a vector of strings. The sample
    // data has many such windows to process, hence the data is loaded into a vector
    // of vector of strings.
    std::vector<std::vector<std::string>> windows;
    if (parameters.all_fasta)
    {
        parse_fasta_windows(windows, parameters.input_paths, parameters.max_windows);
    }
    else
    {
        parse_window_data_file(windows, parameters.input_paths[0], parameters.max_windows);
    }

    std::ofstream graph_output;
    if (!parameters.graph_output_path.empty())
    {
        graph_output.open(parameters.graph_output_path);
        if (!graph_output)
        {
            std::cerr << "Error opening " << parameters.graph_output_path << " for graph output" << std::endl;
            return -1;
        }
    }

    // Create a vector of POA groups based on windows
    std::vector<Group> poa_groups(windows.size());
    for (int32_t i = 0; i < get_size(windows); ++i)
    {
        Group& group = poa_groups[i];
        // Create a new entry for each sequence and add to the group.
        for (const auto& seq : windows[i])
        {
            Entry poa_entry{};
            poa_entry.seq     = seq.c_str();
            poa_entry.length  = seq.length();
            poa_entry.weights = nullptr;
            group.push_back(poa_entry);
        }
    }

    // analyze the POA groups and create a minimal set of batches to process them all
    std::vector<BatchSize> list_of_batch_sizes;
    std::vector<std::vector<int32_t>> list_of_groups_per_batch;

    get_multi_batch_sizes(list_of_batch_sizes, list_of_groups_per_batch, poa_groups, parameters.banded, parameters.consensus_mode == 1);

    int32_t group_count_offset = 0;

    for (int32_t b = 0; b < get_size(list_of_batch_sizes); b++)
    {
        auto& batch_size      = list_of_batch_sizes[b];
        auto& batch_group_ids = list_of_groups_per_batch[b];

        // Initialize batch.
        std::unique_ptr<Batch> batch = initialize_batch(parameters.consensus_mode == 1, parameters.banded, parameters.gpu_mem_allocation, batch_size);

        // Loop over all the POA groups for the current batch, add them to the batch and process them.
        int32_t group_count = 0;

        for (int32_t i = 0; i < get_size(batch_group_ids);)
        {
            Group& group = poa_groups[batch_group_ids[i]];
            std::vector<StatusType> seq_status;
            StatusType status = batch->add_poa_group(seq_status, group);

            // NOTE: If number of batch groups smaller than batch capacity, then run POA generation
            // once last POA group is added to batch.
            if (status == StatusType::exceeded_maximum_poas || (i == get_size(batch_group_ids) - 1))
            {
                // at least one POA should have been added before processing the batch
                if (batch->get_total_poas() > 0)
                {
                    // No more POA groups can be added to batch. Now process batch.
                    process_batch(batch.get(), parameters.consensus_mode == 1, true);

                    if (graph_output.good())
                    {
                        std::vector<DirectedGraph> graph;
                        std::vector<StatusType> graph_status;
                        batch->get_graphs(graph, graph_status);
                        for (auto& g : graph)
                        {
                            graph_output << g.serialize_to_dot() << std::endl;
                        }
                    }

                    // After MSA/consensus is generated for batch, reset batch to make room for next set of POA groups.
                    batch->reset();

                    // In case that number of batch groups is more than the capacity available on GPU, the for loop breaks into smaller number of groups.
                    // if adding group i in batch->add_poa_group is not successful, it wont be processed in this iteration, therefore we print i-1
                    // to account for the fact that group i was excluded at this round.
                    if (status == StatusType::success)
                    {
                        std::cout << "Processed groups " << group_count + group_count_offset << " - " << i + group_count_offset << " (batch " << b << ")" << std::endl;
                    }
                    else
                    {
                        std::cout << "Processed groups " << group_count + group_count_offset << " - " << i - 1 + group_count_offset << " (batch " << b << ")" << std::endl;
                    }
                }
                else
                {
                    // the POA was too large to be added to the GPU, skip and move on
                    std::cout << "Could not add POA group " << batch_group_ids[i] << " to batch " << b << std::endl;
                    i++;
                }

                group_count = i;
            }

            if (status == StatusType::success)
            {
                // Check if all sequences in POA group wre added successfully.
                for (const auto& s : seq_status)
                {
                    if (s == StatusType::exceeded_maximum_sequence_size)
                    {
                        std::cerr << "Dropping sequence because sequence exceeded maximum size" << std::endl;
                    }
                }
                i++;
            }

            if (status != StatusType::exceeded_maximum_poas && status != StatusType::success)
            {
                std::cout << "Could not add POA group " << batch_group_ids[i] << " to batch " << b << ". Error code " << status << std::endl;
                i++;
            }
        }

        group_count_offset += get_size(batch_group_ids);
    }

    return 0;
}

} // namespace cudapoa

} // namespace genomeworks

} // namespace claraparabricks

/// \brief main function
/// main function cannot be in a namespace so using this function to call actual main function
int main(int argc, char* argv[])
{
    return claraparabricks::genomeworks::cudapoa::main(argc, argv);
}
