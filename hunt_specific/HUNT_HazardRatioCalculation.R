#Note: this script assumes the names of the phenotypes are consistent with FinnGen: 
#Refer to https://docs.google.com/spreadsheets/d/1DNKd1KzI8WOIfG2klXWskbCSyX6h5gTu/edit#gid=334983519

#Libraries
library(data.table)
library(dplyr)
library(lubridate)
library(survival)
library(broom)
library(RNOmni)
library(tidyr)

options(warn=2)

##################################################

# Set variables 
phenocols <- c("J10_ASTHMA", "C3_CANCER", "K11_APPENDACUT", "I9_AF", "C3_BREAST", "I9_CHD","C3_COLORECTAL",  "G6_EPLEPSY", "GOUT", "COX_ARTHROSIS", "KNEE_ARTHROSIS", "F5_DEPRESSIO", "C3_MELANOMA_SKIN", "C3_PROSTATE", "RHEUMA_SEROPOS_OTH", "T1D", "T2D", "ILD", "C3_BRONCHUS_LUNG")
prscols <- c("Asthma","AllCancers","Appendicitis", "Atrial_Fibrillation", "Breast_Cancer", "CHD","Colorectal_Cancer", "Epilepsy","Gout", "Hip_Osteoarthritis", "Knee_Osteoarthritis","MDD", "Melanoma", "Prostate_Cancer","Rheumatoid_Arthritis",  "T1D","T2D", "ILD", "Lung_Cancer")

pheno_file="/home/bwolford/workbench/intervene/endpointsPhenoFormatHUNT.csv" #path to phenotype file 
prs_path="/home/bwolford/scratch/brooke/scores/" #path to PRS files
pheno_file_ID="ID" #make sure this is in the right place on line 36
#output_file_dir=getwd() #set directory for output file 
output_dir="/mnt/work/workbench/bwolford/intervene/"

##################################################### All samples: logistic regression, survival regression per SD, and versus 50th percentile ###################################################
surv_results <- c()
logreg_results<-c()
surv_sd_results<-c()

for(i in 1:length(phenocols)){
  
  print(phenocols[i])
  print(prscols[i])
  
  #Read in phenotype file
  pheno <- fread(input=pheno_file, select=c("ID","DATE_OF_BIRTH","PC1","PC2","PC3","PC4","PC5","PC6","PC7","PC8","PC9","PC10","ANCESTRY",phenocols[i],paste0(phenocols[i],"_DATE"),"END_OF_FOLLOWUP","BATCH"), data.table=FALSE)
  
  pheno[,paste0(phenocols[i],"_DATE")] <- as.Date(pheno[,paste0(phenocols[i],"_DATE")], origin = "1970-01-01") 
  #if it's already in date format, this won't mess things up
  
  #Read in PRS scores
  PRS <- fread(input=paste0(prs_path,prscols[i],"_PRS.sscore"), data.table=FALSE)
  
  #Subset columns to the IDs and score only. Note: columns 1 or 2 may be redundant and can be removed if necessary. Kept in to avoid bugs.
  PRS <- PRS[,c(1,2,5)]
  
  #Rename ID column to the name of the ID column in the phenotype file
  colnames(PRS) <- c("FID", pheno_file_ID, paste0(prscols[i],"_prs"))
  
  #left_join to the phenotype file
  pheno <- left_join(pheno, PRS)
  
  pheno <- subset(pheno, !is.na(pheno[[paste0(prscols[i],"_prs")]]))
  
  #Subset to those of european ancestry/those that have principal components calculated for EUROPEAN ancestry, i.e. within ancestry principal components, not global genetic principal components.
  #As we have been unable to use the standardised method for computing ancestry, if you have this information available from your centralised QC please use this. 
  #Feel free to subset using your own code: only provided as a reminder.
  pheno <- subset(pheno, ANCESTRY=='EUR')
  
  #Assign PRS into percentiles
  q <- quantile(pheno[[paste0(prscols[i],"_prs")]], probs=c(0,0.01,0.05,0.1,0.2,0.4,0.6,0.8,0.9,0.95,0.99,1))
  
  pheno[[paste0(prscols[i],"_group")]] <- cut(pheno[[paste0(prscols[i],"_prs")]], q, include.lowest=TRUE,
                                              labels=paste("Group",1:11))
  #TODO: make flexible so if too few cases are in one group, we have fewer groups
  
  #Make all necessary variables factors
  pheno$BATCH <- as.factor(pheno$BATCH)
  pheno[[paste0(prscols[i],"_group")]] <- as.factor(pheno[[paste0(prscols[i],"_group")]])
  pheno[[paste0(prscols[i],"_group")]] <- relevel(pheno[[paste0(prscols[i],"_group")]], ref="Group 6")
  
  #Specify age as either the Age at Onset or End of Follow-up (if not a case)
  pheno$AGE <- ifelse(pheno[[phenocols[i]]]==1, time_length(difftime(pheno[[paste0(phenocols[i],"_DATE")]], pheno$DATE_OF_BIRTH), 'years'), time_length(difftime(pheno$END_OF_FOLLOWUP, pheno$DATE_OF_BIRTH), 'years'))
  
  
  #inverse normalize PRS
  pheno[[paste0(prscols[i],"_invNorm")]] <- RankNorm(pheno[[paste0(prscols[i],"_prs")]])
  
  #perform logistic regression
  logreg <- glm(as.formula(paste0(phenocols[i],"~",paste0(prscols[i],"_invNorm"),"+ PC1 + PC2 + PC3 + PC4 + PC5 + PC6 + PC7 + PC8 + PC9 + PC10 + BATCH")), 
                data=pheno, na.action=na.exclude,family="binomial")
  
  #manipulate into data frame
  lrdf<-tidy(logreg)
  lrdf$OR<-exp(lrdf$estimate)
  lrdf$LB<-exp(lrdf$estimate-1.96*lrdf$std.error)
  lrdf$UB<-exp(lrdf$estimate+1.96*lrdf$std.error)
  
  #Adjust to censor at age 80
  pheno[[paste0(phenocols[i])]] <- ifelse(pheno[[paste0(phenocols[i])]]==1 & pheno$AGE > 80, 0, pheno[[paste0(phenocols[i])]])
  pheno$AGE <- ifelse(pheno$AGE > 80, 80, pheno$AGE)
  
  #perform survival analysis HR per SD
  survival <- coxph(as.formula(paste0("Surv(AGE,",phenocols[i],") ~ ",paste0(prscols[i],"_invNorm")," + PC1 + PC2 + PC3 + PC4 + PC5 + PC6 + PC7 + PC8 + PC9 + PC10 + BATCH")), data=pheno, na.action=na.exclude)
  survdf<-tidy(survival)
  survdf$HR<-round(exp(survdf$estimate),digits=4)
  survdf$LB<-round(exp(survdf$estimate-1.96*survdf$std.error),digits=4)
  survdf$UB<-round(exp(survdf$estimate+1.96*survdf$std.error),digits=4)
  
  #Perform survival analysis
  survival <- coxph(as.formula(paste0("Surv(AGE,",phenocols[i],") ~ ",prscols[i],"_group + PC1 + PC2 + PC3 + PC4 + PC5 + PC6 + PC7 + PC8 + PC9 + PC10 + BATCH")), data=pheno, na.action=na.exclude)
  
  #Define number of cases and controls in each PRS group.
  controls <- table(pheno[[paste0(prscols[i],"_group")]], pheno[[paste0(phenocols[i])]])[2:11,1]
  cases <- if(sum(nrow(pheno[pheno[[paste0(phenocols[i])]]==0,]))==length(pheno[[paste0(phenocols[i])]])){
    rep(0,10)} else {table(pheno[[paste0(prscols[i],"_group")]], pheno[[paste0(phenocols[i])]])[2:11,2]}
  
  #Extract hazard ratios, betas, standard errors and p-vals
  phenotype <- rep(phenocols[i],10)
  prs <- rep(prscols[i],10)
  group <- c(paste0(prscols[i],"_groupGroup ",c(1:5,7:11)))
  betas <- summary(survival)$coefficients[group,"coef"]
  std_errs <- summary(survival)$coefficients[group,"se(coef)"]
  pvals <- summary(survival)$coefficients[group,"Pr(>|z|)"]
  HR <- exp(betas)
  CIpos <- exp(betas+1.96*std_errs)
  CIneg <- exp(betas-1.96*std_errs)
  result <- matrix(c(phenotype, prs, group, controls, cases, betas, std_errs, pvals, HR, CIpos, CIneg), nrow=10, ncol=11)
  surv_results <- rbind(surv_results, result)
  
  #Extract logistic regression info
  lrdf$pheno <- rep(phenocols[i],nrow(lrdf))
  logreg_results <- rbind(logreg_results, lrdf)
  
  #extract survival HR per SD
  survdf$pheno<- rep(phenocols[i],nrow(survdf))
  surv_sd_results <-rbind(surv_sd_results,survdf)
  
}

#write output
surv_results<-data.frame(surv_results)
names(surv_results)<-c("phenotype", "prs", "group", "controls", "cases", "betas", "std_errs", "pvals", "HR", "CIpos", "CIneg")
write.table(surv_results, paste0(output_dir,"/survival_analysis_all.csv"),sep=",",row.names=FALSE,col.names=TRUE)
write.table(logreg_results, paste0(output_dir,"/logistic_regression_all.csv"),sep=",",row.names=FALSE,col.names=TRUE)
write.table(surv_sd_results,paste0(output_dir,"/survival_perSD_all.csv"),sep=",",row.names=FALSE,col.names=TRUE)


###########################################################################################################################################################################################################################################################
###########################################################################################################################################################################################################################################################

#Sex specific HRs
maleresults <- c()
femaleresults <- c()

#ASSUMES SEX IS CODED 2 of female and 1 for male 

for(i in 1:length(phenocols)){
  
  print(phenocols[i])
  print(prscols[i])
  
  #Read in phenotype file
  pheno <- fread(input=pheno_file, select=c("ID","DATE_OF_BIRTH","SEX","PC1","PC2","PC3","PC4","PC5","PC6","PC7","PC8","PC9","PC10","ANCESTRY",phenocols[i],paste0(phenocols[i],"_DATE"),"END_OF_FOLLOWUP","BATCH"), data.table=FALSE)
  
  pheno[,paste0(phenocols[i],"_DATE")] <- as.Date(pheno[,paste0(phenocols[i],"_DATE")], origin = "1970-01-01")
 
  #Read in PRS scores
  PRS <- fread(input=paste0(prs_path,prscols[i],"_PRS.sscore"), data.table=FALSE)
  
  #Subset columns to the IDs and score only. Note: columns 1 or 2 may be redundant and can be removed if necessary. Kept in to avoid bugs.
  PRS <- PRS[,c(1,2,5)]
  
  #Rename ID column to the name of the ID column in the phenotype file
  colnames(PRS) <- c("FID", pheno_file_ID, paste0(prscols[i],"_prs"))
  
  #left_join to the phenotype file
  pheno <- left_join(pheno, PRS)
  
  pheno <- subset(pheno, !is.na(pheno[[paste0(prscols[i],"_prs")]]))
 
  #Subset to those of european ancestry/those that have principal components calculated for EUROPEAN ancestry, i.e. within ancestry principal components, not global genetic principal components.
  #As we have been unable to use the standardised method for computing ancestry, if you have this information available from your centralised QC please use this. 
  #Feel free to subset using your own code: only provided as a reminder.
  pheno <- subset(pheno, ANCESTRY=='EUR')
  
  #Assign PRS into percentiles
  q <- quantile(pheno[[paste0(prscols[i],"_prs")]], probs=c(0,0.01,0.05,0.1,0.2,0.4,0.6,0.8,0.9,0.95,0.99,1))
  
  pheno[[paste0(prscols[i],"_group")]] <- cut(pheno[[paste0(prscols[i],"_prs")]], q, include.lowest=TRUE,
                                              labels=paste("Group",1:11))
  
  #Make all necessary variables factors
  pheno$BATCH <- as.factor(pheno$BATCH)
  pheno[[paste0(prscols[i],"_group")]] <- as.factor(pheno[[paste0(prscols[i],"_group")]])
  pheno[[paste0(prscols[i],"_group")]] <- relevel(pheno[[paste0(prscols[i],"_group")]], ref="Group 6")
  
  #Specify age as either the Age at Onset or End of Follow-up (if not a case)
  pheno$AGE <- ifelse(pheno[[phenocols[i]]]==1, time_length(difftime(pheno[[paste0(phenocols[i],"_DATE")]], pheno$DATE_OF_BIRTH), 'years'), time_length(difftime(pheno$END_OF_FOLLOWUP, pheno$DATE_OF_BIRTH), 'years'))
  
  #Adjust to censor at age 80
  pheno[[paste0(phenocols[i])]] <- ifelse(pheno[[paste0(phenocols[i])]]==1 & pheno$AGE > 80, 0, pheno[[paste0(phenocols[i])]])
  pheno$AGE <- ifelse(pheno$AGE > 80, 80, pheno$AGE)
  
  pheno$SEX<-as.numeric(as.factor(pheno$SEX)) #this should convert male and female text to numeric, but could be flipped 
  
  males <- pheno %>% filter(SEX==1)
  #Define number of cases and controls in each PRS group for males, do for all but breast cancer
  if (phenocols[i]!="C3_BREAST"){
    controls <- table(males[[paste0(prscols[i],"_group")]], males[[paste0(phenocols[i])]])[2:11,1]
    cases <- if(sum(nrow(males[males[[paste0(phenocols[i])]]==0,]))==length(males[[paste0(phenocols[i])]])){
    
    rep(0,10)} else {table(males[[paste0(prscols[i],"_group")]], males[[paste0(phenocols[i])]])[2:11,2]}
  
  
    #Perform survival analysis
    survival <- coxph(as.formula(paste0("Surv(AGE,",phenocols[i],") ~ ",prscols[i],"_group + PC1 + PC2 + PC3 + PC4 + PC5 + PC6 + PC7 + PC8 + PC9 + PC10 + BATCH")), data=males, na.action=na.exclude)
  
    #Extract hazard ratios, betas, standard errors and p-vals
    phenotype <- rep(phenocols[i],10)
    prs <- rep(prscols[i],10)
    group <- c(paste0(prscols[i],"_groupGroup ",c(1:5,7:11)))
    betas <- summary(survival)$coefficients[group,"coef"]
    std_errs <- summary(survival)$coefficients[group,"se(coef)"]
    pvals <- summary(survival)$coefficients[group,"Pr(>|z|)"]
    OR <- exp(betas)
    CIpos <- exp(betas+1.96*std_errs)
    CIneg <- exp(betas-1.96*std_errs)
    maleresult <- matrix(c(phenotype, prs, group, controls, cases, betas, std_errs, pvals, OR, CIpos, CIneg), nrow=10, ncol=11)
    maleresults <- rbind(maleresults, maleresult)
  }
  
  females <- pheno %>% filter(SEX==2)
  #Define number of cases and controls in each PRS group, do for all but prostate cancer
  if (phenocols[i]!="C3_PROSTATE"){
    controls <- table(females[[paste0(prscols[i],"_group")]], females[[paste0(phenocols[i])]])[2:11,1]
    cases <- if(sum(nrow(females[females[[paste0(phenocols[i])]]==0,]))==length(females[[paste0(phenocols[i])]])){
     rep(0,10)} else {table(females[[paste0(prscols[i],"_group")]], females[[paste0(phenocols[i])]])[2:11,2]}

  #Perform survival analysis
    survival <- coxph(as.formula(paste0("Surv(AGE,",phenocols[i],") ~ ",prscols[i],"_group + PC1 + PC2 + PC3 + PC4 + PC5 + PC6 + PC7 + PC8 + PC9 + PC10 + BATCH")), data=females, na.action=na.exclude)
  
    #Extract hazard ratios, betas, standard errors and p-vals
    phenotype <- rep(phenocols[i],10)
    prs <- rep(prscols[i],10)
    group <- c(paste0(prscols[i],"_groupGroup ",c(1:5,7:11)))
    betas <- summary(survival)$coefficients[group,"coef"]
    std_errs <- summary(survival)$coefficients[group,"se(coef)"]
    pvals <- summary(survival)$coefficients[group,"Pr(>|z|)"]
    OR <- exp(betas)
    CIpos <- exp(betas+1.96*std_errs)
    CIneg <- exp(betas-1.96*std_errs)
    femaleresult <- matrix(c(phenotype, prs, group, controls, cases, betas, std_errs, pvals, OR, CIpos, CIneg), nrow=10, ncol=11)
    femaleresults <- rbind(femaleresults, femaleresult)
  }
}

write.csv(maleresults, paste0(output_dir,"HUNT_MaleSample.csv"))
write.csv(femaleresults, paste0(output_dir,"HUNT_FemaleSample.csv"))

###########################################################################################################################################################################################################################################################
###########################################################################################################################################################################################################################################################
######## Sex*PGS interaction ##########
results <- c()

for(i in 1:length(phenocols)){
  
  print(phenocols[i])
  print(prscols[i])
  
  #Read in phenotype file
  pheno <- fread(input=pheno_file, select=c("ID","DATE_OF_BIRTH","SEX","PC1","PC2","PC3","PC4","PC5","PC6","PC7","PC8","PC9","PC10","ANCESTRY",phenocols[i],paste0(phenocols[i],"_DATE"),"END_OF_FOLLOWUP","BATCH"), data.table=FALSE)
  
  pheno[,paste0(phenocols[i],"_DATE")] <- as.Date(pheno[,paste0(phenocols[i],"_DATE")], origin = "1970-01-01")
  
  #Read in PRS scores
  PRS <- fread(input=paste0(prs_path,prscols[i],"_PRS.sscore"), data.table=FALSE)
  
  #Subset columns to the IDs and score only. Note: columns 1 or 2 may be redundant and can be removed if necessary. Kept in to avoid bugs.
  PRS <- PRS[,c(1,2,5)]
  
  #Rename ID column to the name of the ID column in the phenotype file
  colnames(PRS) <- c("FID", pheno_file_ID, paste0(prscols[i],"_prs"))
  
  #left_join to the phenotype file
  pheno <- left_join(pheno, PRS)
  
  pheno <- subset(pheno, !is.na(pheno[[paste0(prscols[i],"_prs")]]))
 
  #Subset to those of european ancestry/those that have principal components calculated for EUROPEAN ancestry, i.e. within ancestry principal components, not global genetic principal components.
  #As we have been unable to use the standardised method for computing ancestry, if you have this information available from your centralised QC please use this. 
  #Feel free to subset using your own code: only provided as a reminder.
  pheno <- subset(pheno, ANCESTRY=='EUR')
  
  pheno[[paste0(prscols[i],"_prs")]] <- scale(pheno[[paste0(prscols[i],"_prs")]])

  #Make all necessary variables factors
  pheno$BATCH <- as.factor(pheno$BATCH)
 
  #Specify age as either the Age at Onset or End of Follow-up (if not a case)
  pheno$AGE <- ifelse(pheno[[phenocols[i]]]==1, time_length(difftime(pheno[[paste0(phenocols[i],"_DATE")]], pheno$DATE_OF_BIRTH), 'years'), time_length(difftime(pheno$END_OF_FOLLOWUP, pheno$DATE_OF_BIRTH), 'years'))
  
  #Adjust to censor at age 80
  pheno[[paste0(phenocols[i])]] <- ifelse(pheno[[paste0(phenocols[i])]]==1 & pheno$AGE > 80, 0, pheno[[paste0(phenocols[i])]])
  pheno$AGE <- ifelse(pheno$AGE > 80, 80, pheno$AGE)
  
  #Perform survival analysis
  survival <- coxph(as.formula(paste0("Surv(AGE,",phenocols[i],") ~ ",prscols[i],"_prs + SEX + ", prscols[i], "_prs:SEX + PC1 + PC2 + PC3 + PC4 + PC5 + PC6 + PC7 + PC8 + PC9 + PC10 + BATCH")), data=pheno, na.action=na.exclude)
  
  #Note: changed _prs:SEXmale to just SEX because we have 1/2 as opposed to male/female, reference should stay the same
  
  #Extract hazard ratios, betas, standard errors and p-vals
  phenotype <- rep(phenocols[i],10)
  prs <- rep(prscols[i],10)
  betas <- summary(survival)$coefficients[paste0(prscols[i],"_prs:SEX"),"coef"]
  std_errs <- summary(survival)$coefficients[paste0(prscols[i],"_prs:SEX"),"se(coef)"]
  pvals <- summary(survival)$coefficients[paste0(prscols[i],"_prs:SEX"),"Pr(>|z|)"]
  OR <- exp(betas)
  CIpos <- exp(betas+1.96*std_errs)
  CIneg <- exp(betas-1.96*std_errs)
  result <- c(phenotype, prs, betas, std_errs, pvals, OR, CIpos, CIneg)
  results <- rbind(results, result)
  
}

write.csv(results, paste0(output_dir,"HUNT_SexInteraction.csv"))

###########################################################################################################################################################################################################################################################
###########################################################################################################################################################################################################################################################
################ Age stratified ###########

#these are the phenotypes that have <1 case in the bottom PRS percentile 
#table(pheno_split$Atrial_Fibrillation_group,pheno_split$tgroup,pheno_split$event)
phenocols_10 <- c("I9_AF", "C3_BREAST","C3_COLORECTAL",  "GOUT", "C3_MELANOMA_SKIN", "RHEUMA_SEROPOS_OTH","C3_PROSTATE", "T2D","ILD","C3_BRONCHUS_LUNG")
phenocols_9<-c("G6_EPLEPSY")

phenocols <- c("J10_ASTHMA", "C3_CANCER",  "I9_AF", "C3_BREAST", "I9_CHD","C3_COLORECTAL",  "G6_EPLEPSY", "GOUT", "COX_ARTHROSIS", "KNEE_ARTHROSIS", "F5_DEPRESSIO", "C3_MELANOMA_SKIN", "C3_PROSTATE", "RHEUMA_SEROPOS_OTH", "T2D", "ILD", "C3_BRONCHUS_LUNG")
prscols <- c("Asthma","AllCancers", "Atrial_Fibrillation", "Breast_Cancer", "CHD","Colorectal_Cancer", "Epilepsy","Gout", "Hip_Osteoarthritis", "Knee_Osteoarthritis","MDD", "Melanoma", "Prostate_Cancer","Rheumatoid_Arthritis", "T2D", "ILD", "Lung_Cancer")
##"K11_APPENDACUT",
#"Appendicitis",
#c(21.27,32.49,46.77), #K11_APPENDACUT

#"I9_SAH",
#"Subarachnoid_Haemmorhage",
#c(43.46,54.54,65.66), #I9_SAH

#T1D
#T1D
#c(12.62,19.73,33.28), #T1D
#Ages are based on mean quartiles from biobanks to be used in the lifetime risk estimation
ages <- data.frame(
                   c(31.37,48.53,62.07), #J10_ASTHMA
                   c(53.34,63.54,72.24), #C3_CANCER
                   c(61.51,70.32,77.77), #I9_AF
                   c(50.68,58.83,67.26), #C3_BREAST
                   c(55.86,64.18,72.35), #I9_CHD
                   c(60.10,68.74,76.10), #C3_COLORECTAL
                   c(21.35,40.10,58.22), #G6_EPLEPSY
                   c(57.07,66.45,74.21), #GOUT
                   c(55.66,64.08,71.80), #COX_ARTHROSIS
                   c(51.35,59.64,68.27), #KNEE_ARTHROSIS
                   c(31.98,44.01,57.19), #F5_DEPRESSIO
                   c(46.51,59.02,69.38), #C3_MELANOMA_SKIN
                   c(62.60,68.25,73.89), #C3_PROSTATE
                   c(50,65,77),#RHEUMA_SEROPOS_OTH TO BE COMPLETED BASED ON REAL DATA. 
                   c(54.36,63.04,71.13), #T2D
                   c(51.22,61.59,71.48), #ILD
                   c(60.79,68.02,75.52)) #C3_BRONCHUS_LUNG

results <- c()

for(i in 1:length(phenocols)){
  age <- c(ages[1,i],ages[2,i],ages[3,i])
  print(phenocols[i])
  
  #Read in phenotype file
  pheno <- fread(input=pheno_file, select=c("ID","DATE_OF_BIRTH","SEX","PC1","PC2","PC3","PC4","PC5","PC6","PC7","PC8","PC9","PC10","ANCESTRY",phenocols[i],paste0(phenocols[i],"_DATE"),"END_OF_FOLLOWUP","BATCH"), data.table=FALSE)
  
  pheno[,paste0(phenocols[i],"_DATE")] <- as.Date(pheno[,paste0(phenocols[i],"_DATE")], origin = "1970-01-01")
  
  #Read in PRS scores
  PRS <- fread(input=paste0(prs_path,prscols[i],"_PRS.sscore"), data.table=FALSE)
  
  #Subset columns to the IDs and score only. Note: columns 1 or 2 may be redundant and can be removed if necessary. Kept in to avoid bugs.
  PRS <- PRS[,c(1,2,5)]
  
  #Rename ID column to the name of the ID column in the 
  colnames(PRS) <- c("FID", pheno_file_ID, paste0(prscols[i],"_prs"))
  
  #left_join to the phenotype file
  pheno <- left_join(pheno, PRS)
  
  pheno <- subset(pheno, !is.na(pheno[[paste0(phenocols[i])]]) | !is.na(pheno[[paste0(prscols[i],"_prs")]]))
  
  #Subset to those of european ancestry/those that have principal components calculated for EUROPEAN ancestry, i.e. within ancestry principal components, not global genetic principal components.
  #As we have been unable to use the standardised method for computing ancestry, if you have this information available from your centralised QC please use this. 
  #Feel free to subset using your own code: only provided as a reminder.
  pheno <- subset(pheno, ANCESTRY=='EUR')
  
  if (!phenocols[i] %in% phenocols_10 & !phenocols[i] %in% phenocols_9) { #if the phenotype is not in the 10 group list, proceed as normal
    #Assign PRS into percentiles
    q <- quantile(pheno[[paste0(prscols[i],"_prs")]], probs=c(0,0.01,0.05,0.1,0.2,0.4,0.6,0.8,0.9,0.95,0.99,1))
  
    pheno[[paste0(prscols[i],"_group")]] <- cut(pheno[[paste0(prscols[i],"_prs")]], q, include.lowest=TRUE,
                                              labels=paste("Group",1:11))
    #Make all necessary variables factors
    pheno$BATCH <- as.factor(pheno$BATCH)
    pheno[[paste0(prscols[i],"_group")]] <- as.factor(pheno[[paste0(prscols[i],"_group")]])
    pheno[[paste0(prscols[i],"_group")]] <- relevel(pheno[[paste0(prscols[i],"_group")]], ref="Group 6")
    
    group_nums<-c(1:5,7:11) #numbers for results printing 
    matrix_row<-10
    }else if (phenocols[i] %in% phenocols_9) { #need to collapse top and bottom groupings 
      print("use 9 groups")
      #Assign PRS into percentiles
      q <- quantile(pheno[[paste0(prscols[i],"_prs")]], probs=c(0,0.05,0.1,0.2,0.4,0.6,0.8,0.9,0.95,1))
      
      pheno[[paste0(prscols[i],"_group")]] <- cut(pheno[[paste0(prscols[i],"_prs")]], q, include.lowest=TRUE,
                                                  labels=paste("Group",1:9))
      #Make all necessary variables factors
      pheno$BATCH <- as.factor(pheno$BATCH)
      pheno[[paste0(prscols[i],"_group")]] <- as.factor(pheno[[paste0(prscols[i],"_group")]])
      pheno[[paste0(prscols[i],"_group")]] <- relevel(pheno[[paste0(prscols[i],"_group")]], ref="Group 5")
      
      group_nums<-c(1:4,6:9) #numbers for results printing 
      matrix_row<-8
  } else { #use 10 groups instead of 11
    #Assign PRS into percentiles
    print("use 10 groups")
    q <- quantile(pheno[[paste0(prscols[i],"_prs")]], probs=c(0,0.05,0.1,0.2,0.4,0.6,0.8,0.9,0.95,0.99,1))
    
    pheno[[paste0(prscols[i],"_group")]] <- cut(pheno[[paste0(prscols[i],"_prs")]], q, include.lowest=TRUE,
                                                labels=paste("Group",1:10))
    #Make all necessary variables factors
    pheno$BATCH <- as.factor(pheno$BATCH)
    pheno[[paste0(prscols[i],"_group")]] <- as.factor(pheno[[paste0(prscols[i],"_group")]])
    pheno[[paste0(prscols[i],"_group")]] <- relevel(pheno[[paste0(prscols[i],"_group")]], ref="Group 5")
    
    group_nums<-c(1:4,6:10) #numbers for results printing 
    matrix_row<-9
  }
  
  #Specify age as either the Age at Onset or End of Follow-up (if not a case)
  pheno$AGE <- ifelse(pheno[[phenocols[i]]]==1, time_length(difftime(pheno[[paste0(phenocols[i],"_DATE")]], pheno$DATE_OF_BIRTH), 'years'), time_length(difftime(pheno$END_OF_FOLLOWUP, pheno$DATE_OF_BIRTH), 'years'))
  
  #if AGE is <0 (could happen because of DOB imputation), set to 0
  pheno<-pheno %>% mutate(AGE=ifelse(AGE<0,1,AGE))
  
  #If age is greater than 80 reduce to 80 as that is when we finish estimating lifetime risk
  pheno[[paste0(phenocols[i])]] <- ifelse(pheno[[paste0(phenocols[i])]] & pheno$AGE > 80, 0, pheno[[paste0(phenocols[i])]])
  pheno$AGE <- ifelse(pheno$AGE > 80, 80, pheno$AGE)
  
  #As a check, remove any individuals who got the disease at AGE 0. 
  pheno <- subset(pheno, AGE!=0)
  
  #Split the dataset into the corresponding age intervals
  pheno_split <- survSplit(Surv(AGE, pheno[[paste0(phenocols[i])]]) ~ ., data=pheno, cut=age, episode="tgroup")
  
  pheno_split$tgroup <- factor(pheno_split$tgroup, levels=c(1,2,3,4))
  pheno_split$tgroup <- relevel(pheno_split$tgroup, ref=1)
  
  for(j in c(1,2,3,4)){
    
    pheno_split_sub <- subset(pheno_split, tgroup==j)
    
    #Perform survival analysis
    survival <- coxph(as.formula(paste0("Surv(tstart, AGE, event) ~ ",prscols[i],"_group + PC1 + PC2 + PC3 + PC4 + PC5 + PC6 + PC7 + PC8 + PC9 + PC10 + BATCH")), data=pheno_split_sub, na.action=na.exclude)
    
    #handle differing group numbers
    if (!phenocols[i] %in% phenocols_10 & !phenocols[i] %in% phenocols_9) { #if the phenotype is not in the 10 gorup list, proceed as normal
      controls <- table(pheno_split_sub[[paste0(prscols[i],"_group")]], pheno_split_sub[["event"]])[2:11,1]
      cases <- if(sum(nrow(pheno_split_sub[pheno_split_sub[["event"]]==0,])) == length(pheno_split_sub[["event"]])){ 
        rep(0,10)} else {table(pheno_split_sub[[paste0(prscols[i],"_group")]], pheno_split_sub[["event"]])[2:11,2]}
    } else if (phenocols[i] %in% phenocols_9) {
        controls <- table(pheno_split_sub[[paste0(prscols[i],"_group")]], pheno_split_sub[["event"]])[2:9,1]
        cases <- if(sum(nrow(pheno_split_sub[pheno_split_sub[["event"]]==0,])) == length(pheno_split_sub[["event"]])){ 
          rep(0,8)} else {table(pheno_split_sub[[paste0(prscols[i],"_group")]], pheno_split_sub[["event"]])[2:9,2]}
    } else {
      controls <- table(pheno_split_sub[[paste0(prscols[i],"_group")]], pheno_split_sub[["event"]])[2:10,1]
      cases <- if(sum(nrow(pheno_split_sub[pheno_split_sub[["event"]]==0,])) == length(pheno_split_sub[["event"]])){ 
        rep(0,9)} else {table(pheno_split_sub[[paste0(prscols[i],"_group")]], pheno_split_sub[["event"]])[2:10,2]}
    }
    
    #Extract hazard ratios, betas, standard errors and p-vals
    phenotype <- rep(phenocols[i],matrix_row)
    prs <- rep(prscols[i],matrix_row)
    minage <- rep(min(pheno_split_sub$tstart), matrix_row)
    maxage <- rep(max(pheno_split_sub$AGE), matrix_row)
    medianAAO <- rep(median(pheno_split_sub[pheno_split_sub$event==1,"AGE"], na.rm=TRUE),matrix_row)
    group <- c(paste0(prscols[i],"_groupGroup ",group_nums))
    betas <- summary(survival)$coefficients[group,"coef"]
    std_errs <- summary(survival)$coefficients[group,"se(coef)"]
    pvals <- summary(survival)$coefficients[group,"Pr(>|z|)"]
    OR <- exp(betas)
    CIpos <- exp(betas+1.96*std_errs)
    CIneg <- exp(betas-1.96*std_errs)
    result <- matrix(c(phenotype,prs,minage, maxage, medianAAO, controls, cases, group, betas, std_errs, pvals, OR, CIpos, CIneg), nrow=matrix_row, ncol=14)
    results <- rbind(results, result)
  }
}

results<-data.frame(results)
names(results)<-c("pheno","prs","minage", "maxage", "medianAAO", "controls", "cases", "group", "betas", "std_errs", "pvals", "HR", "CIpos", "CIneg")
write.csv(results, paste0(output_dir,"HUNT_AgeStratifiedResults.csv"),row.names=FALSE,quote=FALSE)

