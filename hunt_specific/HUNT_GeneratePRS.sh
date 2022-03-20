#!/bin/bash

#command read-freq used to stop plink calculating allele frequencies every time the PRS is calculated.
#if you do not have an allele frequency file, i suggest creating one and then referring to this as it will save you a bunch of time. 

pheno=(Alcohol_Use_Disorder Alzheimers_Disease Asthma Atrial_Fibrillation BMI Breast_Cancer CHD Chronic_Kidney_Disease Educational_Attainment Epilepsy Focal_Epilepsy Generalised_Epilepsy Gout Heart_Failure Hip_Osteoarthritis IPF ILD Inflammatory_Bowel_Disease Knee_Osteoarthritis Lifespan Lung_Cancer MDD Melanoma Osteoporosis Pain POAG Prostate_Cancer Rheumatoid_Arthritis Sleep_Apnoea smoking Stroke Subarachnoid_Haemmorhage TAA T1D T2D Thyroid_Stimulating_Hormone)

output=/mnt/scratch/brooke/PRS
score_directory=/mnt/scratch/brooke/PRS
frequency_directory=/mnt/scratch/brooke/PRS/bcf
snplist_directory=/path/to/snplist
genotype_directory=/path/to/genotype

#Loop through phenotypes
for i in ${!pheno[@]}; do

pheno_i=${pheno[i]}

/home/bwolford/miniconda3/bin/plink2 \
--bfile ${genotype_directory}/genotype_plink_files \
--extract ${snplist_directory}/snplist_hg19 \
--read-freq ${frequency_directory}/frequency_file \
--score ${score_directory}/${pheno_i}_megaPRS_scores_hg19_varid.txt.gz 1 2 5 header \
--out ${output}/${pheno_i}_PRS
done
