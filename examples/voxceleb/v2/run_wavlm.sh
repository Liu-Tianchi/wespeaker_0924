#!/bin/bash

# Copyright 2024 Hongji Wang (jijijiang77@gmail.com)

. ./path.sh || exit 1

stage=-1
stop_stage=-1

data=/scratch/users/astar/bmsi/liut1/data/VoxForWe
data_type="shard"  # shard/raw

config=conf/ecapa_tdnn_WavLM_frozen_0925.yaml #ecapa_tdnn_WavLM_frozen.yaml
exp_dir=/scratch/users/astar/bmsi/liut1/v2_2409_exp/240925_ECAPA_TDNN_GLOB_c512_ASTP_emb192_WavLM_Large_frozen_num_frms150_aug06_spTrue_saFalse_ArcMargin_intertopk_subcenter_SGD_e150
joint_ft_config=conf/ecapa_tdnn_WavLM_joint_ft_0925.yaml #ecapa_tdnn_WavLM_joint_ft.yaml
joint_ft_exp_dir=/scratch/users/astar/bmsi/liut1/v2_2409_exp/240925_ECAPA_TDNN_GLOB_c512_ASTP_emb192_WavLM_Large_joint_ft_num_frms150_aug0.6_spTrue_saFalse_ArcMargin_intertopk_subcenter_SGD_epoch20
joint_lmft_config=conf/ecapa_tdnn_WavLM_joint_lmft_0925.yaml #ecapa_tdnn_WavLM_joint_lmft.yaml
joint_lmft_exp_dir=/scratch/users/astar/bmsi/liut1/v2_2409_exp/240925_ECAPA_TDNN_GLOB_c512_ASTP_emb192_WavLM_Large_joint_lmft_num_frms300_aug0.6_spTrue_saFalse_ArcMargin_intertopk_subcenter_SGD_epoch10

# config=conf/ecapa_tdnn_WavLM_frozen_0926.yaml
# exp_dir=/scratch/users/astar/bmsi/liut1/v2_2409_exp/240926_bz768_ECAPA_TDNN_GLOB_c512_ASTP_emb192_WavLM_Large_frozen_num_frms150_aug06_spTrue_saFalse_ArcMargin_intertopk_subcenter_SGD_e150
# # setup for joint ft and lmft
# joint_ft_config=conf/ecapa_tdnn_WavLM_joint_ft_0926.yaml #ecapa_tdnn_WavLM_joint_ft.yaml
# joint_ft_exp_dir=/scratch/users/astar/bmsi/liut1/v2_2409_exp/240926_bz768_ECAPA_TDNN_GLOB_c512_ASTP_emb192_WavLM_Large_joint_ft_num_frms150_aug0.6_spTrue_saFalse_ArcMargin_intertopk_subcenter_SGD_epoch20
# joint_lmft_config=conf/ecapa_tdnn_WavLM_joint_lmft_0926.yaml #ecapa_tdnn_WavLM_joint_lmft.yaml
# joint_lmft_exp_dir=/scratch/users/astar/bmsi/liut1/v2_2409_exp/240926_bz768_ECAPA_TDNN_GLOB_c512_ASTP_emb192_WavLM_Large_joint_lmft_num_frms300_aug0.6_spTrue_saFalse_ArcMargin_intertopk_subcenter_SGD_epoch10

gpus="[0,1,2,3]"
# gpus="[0,1,2,3,4,5,6,7]"

num_avg=10
checkpoint=
#"/scratch/users/astar/bmsi/liut1/v2_2409_exp/240925_ECAPA_TDNN_GLOB_c512_ASTP_emb192_WavLM_Large_frozen_num_frms150_aug06_spTrue_saFalse_ArcMargin_intertopk_subcenter_SGD_e150/models/model_20.pt"

trials="vox1_O_cleaned.kaldi vox1_E_cleaned.kaldi vox1_H_cleaned.kaldi"
score_norm_method="asnorm"  # asnorm/snorm
top_n=300



. tools/parse_options.sh || exit 1

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
  echo "Prepare datasets ..."
  ./local/prepare_data.sh --stage 2 --stop_stage 4 --data ${data}
fi

if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
  echo "Covert train and test data to ${data_type}..."
  for dset in vox2_dev vox1; do
    if [ $data_type == "shard" ]; then
      python tools/make_shard_list.py --num_utts_per_shard 1000 \
          --num_threads 16 \
          --prefix shards \
          --shuffle \
          ${data}/$dset/wav.scp ${data}/$dset/utt2spk \
          ${data}/$dset/shards ${data}/$dset/shard.list
    else
      python tools/make_raw_list.py ${data}/$dset/wav.scp \
          ${data}/$dset/utt2spk ${data}/$dset/raw.list
    fi
  done
  # Convert all musan data to LMDB
  python tools/make_lmdb.py ${data}/musan/wav.scp ${data}/musan/lmdb
  # Convert all rirs data to LMDB
  python tools/make_lmdb.py ${data}/rirs/wav.scp ${data}/rirs/lmdb
fi

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
  echo "Start training ..."
  num_gpus=$(echo $gpus | awk -F ',' '{print NF}')
  torchrun --master_addr=localhost --master_port=29401 --nnodes=1 --nproc_per_node=$num_gpus \
    wespeaker/bin/train.py --config $config \
      --exp_dir ${exp_dir} \
      --gpus $gpus \
      --num_avg ${num_avg} \
      --data_type "${data_type}" \
      --train_data ${data}/vox2_dev/${data_type}.list \
      --train_label ${data}/vox2_dev/utt2spk \
      --reverb_data ${data}/rirs/lmdb \
      --noise_data ${data}/musan/lmdb \
      ${checkpoint:+--checkpoint $checkpoint}
fi

if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
  echo "Do model average ..."
  avg_model=$exp_dir/models/avg_model.pt
  python wespeaker/bin/average_model.py \
    --dst_model $avg_model \
    --src_path $exp_dir/models \
    --num ${num_avg}

  echo "Extract embeddings ..."
  local/extract_vox.sh \
    --exp_dir $exp_dir --model_path $avg_model \
    --nj 4 --gpus $gpus --data_type $data_type --data ${data}
fi

if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
  echo "Score ..."
  local/score.sh \
    --stage 1 --stop-stage 2 \
    --data ${data} \
    --exp_dir $exp_dir \
    --trials "$trials"
fi

if [ ${stage} -le 6 ] && [ ${stop_stage} -ge 6 ]; then
  echo "Score norm ..."
  local/score_norm.sh \
    --stage 1 --stop-stage 3 \
    --score_norm_method $score_norm_method \
    --cohort_set vox2_dev \
    --top_n $top_n \
    --data ${data} \
    --exp_dir $exp_dir \
    --trials "$trials"
fi

if [ ${stage} -le 7 ] && [ ${stop_stage} -ge 7 ]; then
  echo "Score calibration ..."
  local/score_calibration.sh \
    --stage 1 --stop-stage 5 \
    --score_norm_method $score_norm_method \
    --calibration_trial "vox2_cali.kaldi" \
    --cohort_set vox2_dev \
    --top_n $top_n \
    --data ${data} \
    --exp_dir $exp_dir \
    --trials "$trials"
fi

if [ ${stage} -le 8 ] && [ ${stop_stage} -ge 8 ]; then
  echo "Joint fine-tuning ..."
  mkdir -p ${joint_ft_exp_dir}/models
  # Use the average frozen model to initialize the joint-ft training
  cp ${exp_dir}/models/avg_model.pt ${joint_ft_exp_dir}/models/model_0.pt
  bash run_wavlm.sh --stage 3 --stop_stage 7 \
      --data ${data} \
      --data_type ${data_type} \
      --config ${joint_ft_config} \
      --exp_dir ${joint_ft_exp_dir} \
      --gpus $gpus \
      --num_avg 3 \
      --checkpoint ${joint_ft_exp_dir}/models/model_0.pt \
      --trials "$trials" \
      --score_norm_method ${score_norm_method} \
      --top_n ${top_n}
fi

if [ ${stage} -le 9 ] && [ ${stop_stage} -ge 9 ]; then
  echo "Joint LM fine-tuning ..."
  [ ! -f ${joint_ft_exp_dir}/models/avg_model.pt ] &&
      echo "Please do joint fint-tuning first" && exit 1
  mkdir -p ${joint_lmft_exp_dir}/models
  # Use the average joint_ft model to initialize the joint_lmft training
  cp ${joint_ft_exp_dir}/models/avg_model.pt ${joint_lmft_exp_dir}/models/model_0.pt
  bash run_wavlm.sh --stage 3 --stop_stage 7 \
      --data ${data} \
      --data_type ${data_type} \
      --config ${joint_lmft_config} \
      --exp_dir ${joint_lmft_exp_dir} \
      --gpus $gpus \
      --num_avg 1 \
      --checkpoint ${joint_lmft_exp_dir}/models/model_0.pt \
      --trials "$trials" \
      --score_norm_method ${score_norm_method} \
      --top_n ${top_n}
fi
