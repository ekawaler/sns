#!/bin/bash


##
## RNA-seq variant calling using STAR aligner and GATK
##


# script filename
script_name=$(basename "${BASH_SOURCE[0]}")
route_name=${script_name/%.sh/}
echo -e "\n ========== ROUTE: $route_name ========== \n" >&2

# check for correct number of arguments
if [ ! $# == 2 ] ; then
	echo -e "\n $script_name ERROR: WRONG NUMBER OF ARGUMENTS SUPPLIED \n" >&2
	echo -e "\n USAGE: $script_name [project dir] [sample name] \n" >&2
	exit 1
fi

# standard route arguments
proj_dir=$(readlink -f "$1")
sample=$2

# additional settings
threads=$NSLOTS
code_dir=$(dirname "$(dirname "${BASH_SOURCE[0]}")")
qsub_dir="${proj_dir}/logs-qsub"

# display settings
echo " * proj_dir: $proj_dir "
echo " * sample: $sample "
echo " * code_dir: $code_dir "
echo " * qsub_dir: $qsub_dir "
echo " * threads: $threads "


#########################


# delete empty qsub .po files
rm -f ${qsub_dir}/sns.*.po*


#########################


# segments

# rename and/or merge raw input FASTQs
segment_fastq_clean="fastq-clean"
fastq_R1=$(grep -s -m 1 "^${sample}," "${proj_dir}/samples.${segment_fastq_clean}.csv" | cut -d ',' -f 2)
fastq_R2=$(grep -s -m 1 "^${sample}," "${proj_dir}/samples.${segment_fastq_clean}.csv" | cut -d ',' -f 3)
if [ -z "$fastq_R1" ] ; then
	bash_cmd="bash ${code_dir}/segments/${segment_fastq_clean}.sh $proj_dir $sample"
	($bash_cmd)
	fastq_R1=$(grep -m 1 "^${sample}," "${proj_dir}/samples.${segment_fastq_clean}.csv" | cut -d ',' -f 2)
	fastq_R2=$(grep -m 1 "^${sample}," "${proj_dir}/samples.${segment_fastq_clean}.csv" | cut -d ',' -f 3)
fi
[ "$fastq_R1" ] || exit 1

# run STAR
segment_align="align-star"
bam_star=$(grep -s -m 1 "^${sample}," "${proj_dir}/samples.${segment_align}.csv" | cut -d ',' -f 2)
if [ -z "$bam_star" ] ; then
	bash_cmd="bash ${code_dir}/segments/${segment_align}.sh $proj_dir $sample $threads $fastq_R1 $fastq_R2"
	($bash_cmd)
	bam_star=$(grep -m 1 "^${sample}," "${proj_dir}/samples.${segment_align}.csv" | cut -d ',' -f 2)
fi
[ "$bam_star" ] || exit 1

# remove duplicates
segment_dedup="bam-dedup-sambamba"
bam_dd=$(grep -s -m 1 "^${sample}," "${proj_dir}/samples.${segment_dedup}.csv" | cut -d ',' -f 2)
if [ -z "$bam_dd" ] ; then
	bash_cmd="bash ${code_dir}/segments/${segment_dedup}.sh $proj_dir $sample $threads $bam_star"
	($bash_cmd)
	bam_dd=$(grep -m 1 "^${sample}," "${proj_dir}/samples.${segment_dedup}.csv" | cut -d ',' -f 2)
fi
[ "$bam_dd" ] || exit 1

# add read groups
segment_rg="bam-rg-picard"
bam_rg=$(grep -s -m 1 "^${sample}," "${proj_dir}/samples.${segment_rg}.csv" | cut -d ',' -f 2)
if [ -z "$bam_rg" ] ; then
	bash_cmd="bash ${code_dir}/segments/${segment_rg}.sh $proj_dir $sample $bam_dd"
	($bash_cmd)
	bam_rg=$(grep -m 1 "^${sample}," "${proj_dir}/samples.${segment_rg}.csv" | cut -d ',' -f 2)
fi
[ "$bam_rg" ] || exit 1

# split CIGAR strings
segment_splitncigar="bam-splitncigar-gatk"
bam_split=$(grep -s -m 1 "^${sample}," "${proj_dir}/samples.${segment_splitncigar}.csv" | cut -d ',' -f 2)
if [ -z "$bam_split" ] ; then
	bash_cmd="bash ${code_dir}/segments/${segment_splitncigar}.sh $proj_dir $sample $bam_rg"
	($bash_cmd)
	bam_split=$(grep -m 1 "^${sample}," "${proj_dir}/samples.${segment_splitncigar}.csv" | cut -d ',' -f 2)
fi
[ "$bam_split" ] || exit 1

# on-target (exons) coverage
segment_target_cov="qc-target-reads-gatk"
bash_cmd="bash ${code_dir}/segments/${segment_target_cov}.sh $proj_dir $sample $threads $bam_split"
($bash_cmd)

# realign and recalibrate
segment_gatk="bam-ra-rc-gatk"
bam_gatk=$(grep -s -m 1 "^${sample}," "${proj_dir}/samples.${segment_gatk}.csv" | cut -d ',' -f 2)
if [ -z "$bam_gatk" ] ; then
	bash_cmd="bash ${code_dir}/segments/${segment_gatk}.sh $proj_dir $sample $threads $bam_split"
	($bash_cmd)
	bam_gatk=$(grep -m 1 "^${sample}," "${proj_dir}/samples.${segment_gatk}.csv" | cut -d ',' -f 2)
fi
[ "$bam_gatk" ] || exit 1

# final average coverage
segment_avg_cov="qc-coverage-gatk"
bash_cmd="bash ${code_dir}/segments/${segment_avg_cov}.sh $proj_dir $sample $bam_gatk"
($bash_cmd)

# call variants
segment_gatk_hc="snvs-gatk-hc"
bash_cmd="bash ${code_dir}/segments/${segment_gatk_hc}.sh $proj_dir $sample $threads $bam_gatk"
($bash_cmd)

# call variants with LoFreq
segment_lofreq="snvs-lofreq"
bash_cmd="bash ${code_dir}/segments/${segment_lofreq}.sh $proj_dir $sample $threads $bam_gatk"
($bash_cmd)


#########################


# combine summary from each step

sleep 30

summary_csv="${proj_dir}/summary-combined.${route_name}.csv"

bash_cmd="
bash ${code_dir}/scripts/join-many.sh , X \
${proj_dir}/summary.${segment_fastq_clean}.csv \
${proj_dir}/summary.${segment_align}.csv \
${proj_dir}/summary.${segment_dedup}.csv \
${proj_dir}/summary.${segment_target_cov}.csv \
${proj_dir}/summary.${segment_avg_cov}.csv \
> $summary_csv
"
(eval $bash_cmd)


#########################


# delete empty qsub .po files
rm -f ${qsub_dir}/sns.*.po*


#########################


date



# end