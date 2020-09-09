/*
* Copyright 2020 NVIDIA CORPORATION.
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
*/
#include "ungapped_xdrop_kernels.cuh"

namespace claraparabricks
{

namespace genomeworks
{

namespace cudaextender
{

// extend the hits to a segment by ungapped x-drop method, adjust low-scoring
// segment scores based on entropy factor, compare resulting segment scores
// to score_threshold and update the d_hsp and d_done vectors
__global__ void find_high_scoring_segment_pairs(const char* __restrict__ d_target, const int32_t target_length, const char* __restrict__ d_query, const int32_t query_length, const int32_t* d_sub_mat, bool no_entropy, int32_t xdrop_threshold, int32_t score_threshold, SeedPair* d_seed_pairs, int32_t num_seed_pairs, int32_t start_index, ScoredSegmentPair* d_scored_segment, uint32_t* d_done)
{

    int32_t thread_id           = threadIdx.x;
    int32_t block_id            = blockIdx.x;
    int32_t num_blocks          = gridDim.x;
    int32_t warp_size           = warpSize;
    int32_t lane_id             = thread_id % warp_size;
    int32_t warp_id             = (thread_id - lane_id) / warp_size;
    constexpr int32_t num_warps = 4;  // TODO - move out?
    constexpr int32_t nuc       = 8;  // TODO - remove hardcode - pass in
    constexpr int32_t nuc2      = 64; // TODO - remove hardcode

    __shared__ uint32_t ref_loc[num_warps];
    __shared__ uint32_t query_loc[num_warps];
    __shared__ int32_t total_score[num_warps];
    __shared__ int32_t prev_score[num_warps];
    __shared__ int32_t prev_max_score[num_warps];
    __shared__ uint32_t prev_max_pos[num_warps];
    __shared__ bool edge_found[num_warps];
    __shared__ bool xdrop_found[num_warps];
    __shared__ bool new_max_found[num_warps];
    __shared__ uint32_t left_extent[num_warps];
    __shared__ uint32_t extent[num_warps];
    __shared__ uint32_t tile[num_warps];
    __shared__ double entropy[num_warps];

    int32_t thread_score;
    int32_t max_thread_score;
    uint32_t max_pos;
    uint32_t temp_pos;
    bool xdrop_done;
    int32_t temp;
    short count[4];
    short count_del[4];
    char r_chr;
    char q_chr;
    uint32_t ref_pos;
    uint32_t query_pos;
    uint32_t pos_offset;

    __shared__ int32_t sub_mat[nuc2];

    if (thread_id < nuc2)
    {
        sub_mat[thread_id] = d_sub_mat[thread_id];
    }
    __syncthreads();

    for (int32_t hid0 = block_id * num_warps; hid0 < num_seed_pairs; hid0 += num_warps * num_blocks)
    {
        int32_t hid = hid0 + warp_id + start_index;

        if (hid < num_seed_pairs)
        {
            if (lane_id == 0)
            {
                ref_loc[warp_id]     = d_seed_pairs[hid].target_position_in_read;
                query_loc[warp_id]   = d_seed_pairs[hid].query_position_in_read;
                total_score[warp_id] = 0;
            }
        }
        else
        {
            if (lane_id == 0)
            {

                ref_loc[warp_id]     = d_seed_pairs[hid0].target_position_in_read;
                query_loc[warp_id]   = d_seed_pairs[hid0].query_position_in_read;
                total_score[warp_id] = 0;
            }
        }
        __syncwarp();

        //////////////////////////////////////////////////////////////////
        //Right extension

        if (lane_id == 0)
        {
            tile[warp_id]           = 0;
            xdrop_found[warp_id]    = false;
            edge_found[warp_id]     = false;
            new_max_found[warp_id]  = false;
            entropy[warp_id]        = 1.0f;
            prev_score[warp_id]     = 0;
            prev_max_score[warp_id] = -1000;
            prev_max_pos[warp_id]   = 0;
            extent[warp_id]         = 0;
        }

        count[0]     = 0;
        count[1]     = 0;
        count[2]     = 0;
        count[3]     = 0;
        count_del[0] = 0;
        count_del[1] = 0;
        count_del[2] = 0;
        count_del[3] = 0;
        max_pos      = 0;

        __syncwarp();

        while (!xdrop_found[warp_id] && !edge_found[warp_id])
        {
            pos_offset   = lane_id + tile[warp_id];
            ref_pos      = ref_loc[warp_id] + pos_offset;
            query_pos    = query_loc[warp_id] + pos_offset;
            thread_score = 0;

            if (ref_pos < target_length && query_pos < query_length)
            {
                r_chr        = d_target[ref_pos];
                q_chr        = d_query[query_pos];
                thread_score = sub_mat[r_chr * nuc + q_chr];
            }
            __syncwarp();

#pragma unroll
            for (int32_t offset = 1; offset < warp_size; offset = offset << 1)
            {
                temp = __shfl_up_sync(0xFFFFFFFF, thread_score, offset);

                if (lane_id >= offset)
                {
                    thread_score += temp;
                }
            }

            thread_score += prev_score[warp_id];
            if (thread_score > prev_max_score[warp_id])
            {
                max_thread_score = thread_score;
                max_pos          = pos_offset;
            }
            else
            {
                max_thread_score = prev_max_score[warp_id];
                max_pos          = prev_max_pos[warp_id];
            }

            __syncwarp();

#pragma unroll
            for (int32_t offset = 1; offset < warp_size; offset = offset << 1)
            {
                temp     = __shfl_up_sync(0xFFFFFFFF, max_thread_score, offset);
                temp_pos = __shfl_up_sync(0xFFFFFFFF, max_pos, offset);

                if (lane_id >= offset)
                {
                    if (temp >= max_thread_score)
                    {
                        max_thread_score = temp;
                        max_pos          = temp_pos;
                    }
                }
            }

            xdrop_done = ((max_thread_score - thread_score) > xdrop_threshold);
            __syncwarp();

#pragma unroll
            for (int32_t offset = 1; offset < warp_size; offset = offset << 1)
            {
                xdrop_done |= __shfl_up_sync(0xFFFFFFFF, xdrop_done, offset);
            }

            if (lane_id == warp_size - 1)
            {

                if (max_pos > prev_max_pos[warp_id])
                    new_max_found[warp_id] = true;
                else
                    new_max_found[warp_id] = false;

                if (xdrop_done)
                {
                    total_score[warp_id] += max_thread_score;
                    xdrop_found[warp_id]  = true;
                    extent[warp_id]       = max_pos;
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id]         = max_pos;
                }
                else if (ref_pos >= target_length || query_pos >= query_length)
                {
                    total_score[warp_id] += max_thread_score;
                    edge_found[warp_id]   = true;
                    extent[warp_id]       = max_pos;
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id]         = max_pos;
                }
                else
                {
                    prev_score[warp_id]     = thread_score;
                    prev_max_score[warp_id] = max_thread_score;
                    prev_max_pos[warp_id]   = max_pos;
                    tile[warp_id] += warp_size;
                }
            }
            __syncwarp();

            if (new_max_found[warp_id])
            {
                for (int32_t i = 0; i < 4; i++)
                {
                    count[i]     = count[i] + count_del[i];
                    count_del[i] = 0;
                }
            }
            __syncwarp();

            if (r_chr == q_chr)
            {
                if (pos_offset <= prev_max_pos[warp_id])
                {
                    count[r_chr] += 1;
                }
                else
                {
                    count_del[r_chr] += 1;
                }
            }
            __syncwarp();
        }

        __syncwarp();

        ////////////////////////////////////////////////////////////////
        //Left extension

        if (lane_id == 0)
        {
            tile[warp_id]           = 0;
            xdrop_found[warp_id]    = false;
            edge_found[warp_id]     = false;
            new_max_found[warp_id]  = false;
            prev_score[warp_id]     = 0;
            prev_max_score[warp_id] = -1000;
            prev_max_pos[warp_id]   = 0;
            left_extent[warp_id]    = 0;
        }

        count_del[0] = 0;
        count_del[1] = 0;
        count_del[2] = 0;
        count_del[3] = 0;
        max_pos      = 0;
        __syncwarp();

        while (!xdrop_found[warp_id] && !edge_found[warp_id])
        {
            pos_offset   = lane_id + 1 + tile[warp_id];
            thread_score = 0;

            if (ref_loc[warp_id] >= pos_offset && query_loc[warp_id] >= pos_offset)
            {
                ref_pos      = ref_loc[warp_id] - pos_offset;
                query_pos    = query_loc[warp_id] - pos_offset;
                r_chr        = d_target[ref_pos];
                q_chr        = d_query[query_pos];
                thread_score = sub_mat[r_chr * nuc + q_chr];
            }

#pragma unroll
            for (int32_t offset = 1; offset < warp_size; offset = offset << 1)
            {
                temp = __shfl_up_sync(0xFFFFFFFF, thread_score, offset);

                if (lane_id >= offset)
                {
                    thread_score += temp;
                }
            }

            thread_score += prev_score[warp_id];
            if (thread_score > prev_max_score[warp_id])
            {
                max_thread_score = thread_score;
                max_pos          = pos_offset;
            }
            else
            {
                max_thread_score = prev_max_score[warp_id];
                max_pos          = prev_max_pos[warp_id];
            }
            __syncwarp();

#pragma unroll
            for (int32_t offset = 1; offset < warp_size; offset = offset << 1)
            {
                temp     = __shfl_up_sync(0xFFFFFFFF, max_thread_score, offset);
                temp_pos = __shfl_up_sync(0xFFFFFFFF, max_pos, offset);

                if (lane_id >= offset)
                {
                    if (temp >= max_thread_score)
                    {
                        max_thread_score = temp;
                        max_pos          = temp_pos;
                    }
                }
            }

            xdrop_done = ((max_thread_score - thread_score) > xdrop_threshold);
            __syncwarp();

#pragma unroll
            for (int32_t offset = 1; offset < warp_size; offset = offset << 1)
            {
                xdrop_done |= __shfl_up_sync(0xFFFFFFFF, xdrop_done, offset);
            }

            if (lane_id == warp_size - 1)
            {

                if (max_pos > prev_max_pos[warp_id])
                    new_max_found[warp_id] = true;
                else
                    new_max_found[warp_id] = false;

                if (xdrop_done)
                {
                    total_score[warp_id] += max_thread_score;
                    xdrop_found[warp_id] = true;
                    left_extent[warp_id] = max_pos;
                    extent[warp_id] += left_extent[warp_id];
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id]         = max_pos;
                }
                else if (ref_loc[warp_id] < pos_offset || query_loc[warp_id] < pos_offset)
                {
                    total_score[warp_id] += max_thread_score;
                    edge_found[warp_id]  = true;
                    left_extent[warp_id] = max_pos;
                    extent[warp_id] += left_extent[warp_id];
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id]         = max_pos;
                }
                else
                {
                    prev_score[warp_id]     = thread_score;
                    prev_max_score[warp_id] = max_thread_score;
                    prev_max_pos[warp_id]   = max_pos;
                    tile[warp_id] += warp_size;
                }
            }
            __syncwarp();

            if (new_max_found[warp_id])
            {
                for (int32_t i = 0; i < 4; i++)
                {
                    count[i]     = count[i] + count_del[i];
                    count_del[i] = 0;
                }
            }
            __syncwarp();

            if (r_chr == q_chr)
            {
                if (pos_offset <= prev_max_pos[warp_id])
                {
                    count[r_chr] += 1;
                }
                else
                {
                    count_del[r_chr] += 1;
                }
            }
            __syncwarp();
        }

        //////////////////////////////////////////////////////////////////

        if (total_score[warp_id] >= score_threshold && total_score[warp_id] <= 3 * score_threshold && !no_entropy)
        {
            for (int32_t i = 0; i < 4; i++)
            {
#pragma unroll
                for (int32_t offset = 1; offset < warp_size; offset = offset << 1)
                {
                    count[i] += __shfl_up_sync(0xFFFFFFFF, count[i], offset);
                }
            }
            __syncwarp();

            if (lane_id == warp_size - 1 && ((count[0] + count[1] + count[2] + count[3]) >= 20))
            {

                entropy[warp_id] = 0.f;
                for (int32_t i = 0; i < 4; i++)
                {
                    entropy[warp_id] += ((double)count[i]) / ((double)(extent[warp_id] + 1)) * ((count[i] != 0) ? log(((double)count[i]) / ((double)(extent[warp_id] + 1))) : 0.f);
                }
                entropy[warp_id] = -entropy[warp_id] / log(4.0f);
            }
        }
        __syncwarp();

        //////////////////////////////////////////////////////////////////

        if (hid < num_seed_pairs)
        {
            if (lane_id == 0)
            {

                if (((int32_t)(((float)total_score[warp_id]) * entropy[warp_id])) >= score_threshold)
                {
                    d_scored_segment[hid].seed_pair.target_position_in_read = ref_loc[warp_id] - left_extent[warp_id];
                    d_scored_segment[hid].seed_pair.query_position_in_read  = query_loc[warp_id] - left_extent[warp_id];
                    d_scored_segment[hid].length                            = extent[warp_id];
                    if (entropy[warp_id] > 0)
                        d_scored_segment[hid].score = total_score[warp_id] * entropy[warp_id];
                    d_done[hid - start_index] = 1;
                }
                else
                {
                    d_scored_segment[hid].seed_pair.target_position_in_read = ref_loc[warp_id];
                    d_scored_segment[hid].seed_pair.query_position_in_read  = query_loc[warp_id];
                    d_scored_segment[hid].length                            = 0;
                    d_scored_segment[hid].score                             = 0;
                    d_done[hid - start_index]                               = 0;
                }
            }
        }
        __syncwarp();
    }
}

} // namespace cudaextender

} // namespace genomeworks

} // namespace claraparabricks