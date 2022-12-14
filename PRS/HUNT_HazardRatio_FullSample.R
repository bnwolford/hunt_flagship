#Note: this script assumes the names of the phenotypes are consistent with FinnGen: Refer to https://docs.google.com/spreadsheets/d/1DNKd1KzI8WOIfG2klXWskbCSyX6h5gTu/edit#gid=334983519

#Libraries
library(data.table)
library(dplyr)
library(lubridate)
library(survival)

phenocols <- c("C3_CANCER", "K11_APPENDACUT", "J10_ASTHMA", "I9_AF", "C3_BREAST", "I9_CHD", "C3_COLORECTAL", "G6_EPLEPSY", "GOUT", "COX_ARTHROSIS", "KNEE_ARTHROSIS", "F5_DEPRESSIO", "C3_MELANOMA_SKIN", "C3_PROSTATE", "RHEUMA_SEROPOS_OTH", "T1D", "T2D", "ILD", "C3_BRONCHUS_LUNG")
prscols <- c("AllCancers", "Appendicitis", "Asthma", "Atrial_Fibrillation", "Breast_Cancer", "CHD", "Colorectal_Cancer", "Epilepsy","Gout", "Hip_Osteoarthritis", "Knee_Osteoarthritis","MDD", "Melanoma", "Prostate_Cancer", "Rheumatoid_Arthritis", "T1D","T2D", "ILD", "Lung_Cancer")
#custom_covar and covariates from wrapper script

percentiles <- list(c(0,0.01,0.05,0.1,0.2,0.4), #1%
                    c(0,0.05,0.1,0.2,0.4), #5%
                    c(0,0.1,0.2,0.4), #10%
                    c(0,0.2,0.4) #20%
                )

results <- c()

for(i in 1:length(phenocols)){
  for(p in percentiles){
    
    print(phenocols[i])
    print(prscols[i])
    
    #Read in phenotype file
    pheno <- fread(input=pheno_file, select=c("ID","DATE_OF_BIRTH","PC1","PC2","PC3","PC4","PC5","PC6","PC7","PC8","PC9","PC10",custom_covar,phenocols[i],paste0(phenocols[i],"_DATE"),"END_OF_FOLLOWUP"), data.table=FALSE)
    
    pheno[,paste0(phenocols[i],"_DATE")] <- as.Date(pheno[,paste0(phenocols[i],"_DATE")], origin = "1970-01-01")
    
    #Read in PRS scores
    PRS <- fread(input=paste0(prs_path,prscols[i],"_PRS.sscore"), data.table=FALSE)
    
    #Subset columns to the IDs and score only. Note: columns FID or IID may be redundant and can be removed if necessary. Kept in to avoid bugs.
    PRS <- PRS[,c("#FID","IID","SCORE1_SUM")]
    
    #Rename ID column to the name of the ID column in the phenotype file
    colnames(PRS) <- c(ID1, ID2, paste0(prscols[i],"_prs"))
    
    #left_join to the phenotype file
    pheno <- left_join(pheno, PRS)
    
    pheno <- subset(pheno, !(is.na(pheno[[paste0(phenocols[i])]]) | is.na(pheno[[paste0(prscols[i],"_prs")]])))
    
    #Subset to those of european ancestry/those that have principal components calculated for EUROPEAN ancestry, i.e. within ancestry principal components, not global genetic principal components.
    #As we have been unable to use the standardised method for computing ancestry, if you have this information available from your centralised QC please use this. 
    #Feel free to subset using your own code: only provided as a reminder.
    #pheno <- subset(pheno, ANCESTRY=='EUR')
    
    #Assign PRS into percentiles
    q <- quantile(pheno[[paste0(prscols[i],"_prs")]], probs=c(p,rev(1-p)))
    
    pheno[[paste0(prscols[i],"_group")]] <- cut(pheno[[paste0(prscols[i],"_prs")]], q, include.lowest=TRUE,
                                                labels=paste("Group",1:(2*length(p)-1)))
    
    #Make all necessary variables factors
    pheno[[paste0(prscols[i],"_group")]] <- as.factor(pheno[[paste0(prscols[i],"_group")]])
    pheno[[paste0(prscols[i],"_group")]] <- relevel(pheno[[paste0(prscols[i],"_group")]], ref=paste("Group",length(p)))
    
    #Specify age as either the Age at Onset or End of Follow-up (if not a case)
    pheno$AGE <- ifelse(pheno[[phenocols[i]]]==1, time_length(difftime(pheno[[paste0(phenocols[i],"_DATE")]], pheno$DATE_OF_BIRTH), 'years'), time_length(difftime(pheno$END_OF_FOLLOWUP, pheno$DATE_OF_BIRTH), 'years'))
    
    #Adjust to censor at age 80
    pheno[[paste0(phenocols[i])]] <- ifelse(pheno[[paste0(phenocols[i])]]==1 & pheno$AGE > 80, 0, pheno[[paste0(phenocols[i])]])
    pheno$AGE <- ifelse(pheno$AGE > 80, 80, pheno$AGE)
    
    #Perform survival analysis
    survival <- coxph(as.formula(paste0("Surv(AGE,",phenocols[i],") ~ ",prscols[i],"_group +",covariates)), data=pheno, na.action=na.exclude)
    
    #Define number of cases and controls in each PRS group.
    controls <- table(pheno[[paste0(prscols[i],"_group")]], pheno[[paste0(phenocols[i])]])[2:(2*length(p)-1),1]
    cases <- if(sum(nrow(pheno[pheno[[paste0(phenocols[i])]]==0,]))==length(pheno[[paste0(phenocols[i])]])){
      rep(0,(2*length(p)-2))} else {table(pheno[[paste0(prscols[i],"_group")]], pheno[[paste0(phenocols[i])]])[2:(2*length(p)-1),2]}
    
    #Extract hazard ratios, betas, standard errors and p-vals - in the first instance extract all results, for the latter just take the 
    if(p[2] == 0.01){
      phenotype <- rep(phenocols[i],(2*length(p)-2))
      prs <- rep(prscols[i],(2*length(p)-2))
      group <- c(paste0(prscols[i],"_groupGroup ",c(1:(length(p)-1),(length(p)+1):(2*length(p)-1))))
      betas <- summary(survival)$coefficients[group,"coef"]
      std_errs <- summary(survival)$coefficients[group,"se(coef)"]
      pvals <- summary(survival)$coefficients[group,"Pr(>|z|)"]
      groups <- c("< 1%","1-5%","5-10%","10-20%","20-40%","60-80%","80-90%","90-95%","95-99%", "> 99%")
      OR <- exp(betas)
      CIpos <- exp(betas+1.96*std_errs)
      CIneg <- exp(betas-1.96*std_errs)
      result <- matrix(c(phenotype, prs, groups, controls, cases, betas, std_errs, pvals, OR, CIpos, CIneg), nrow=10, ncol=11)
      results <- rbind(results, result)
    } else {
      phenotype <- rep(phenocols[i],2)
      prs <- rep(prscols[i],2)
      group <- c(paste0(prscols[i],"_groupGroup 1"), paste0(prscols[i],"_groupGroup ", (2*length(p)-1)))
      betas <- summary(survival)$coefficients[group,"coef"]
      std_errs <- summary(survival)$coefficients[group,"se(coef)"]
      pvals <- summary(survival)$coefficients[group,"Pr(>|z|)"]
      groups <- c(paste0("< ",(p[2]*100),"%"),paste0("> ",((1-p[2])*100),"%"))
      OR <- exp(betas)
      CIpos <- exp(betas+1.96*std_errs)
      CIneg <- exp(betas-1.96*std_errs)
      result <- matrix(c(phenotype, prs, groups, controls[c(1,length(controls))], cases[c(1,length(cases))], betas, std_errs, pvals, OR, CIpos, CIneg), nrow=2, ncol=11)
      results <- rbind(results, result)
    }
    
  }
}
results<-data.frame(results)
names(results)<-c("phenotype", "prs", "groups", "controls", "cases", "betas", "std_errs", "pvals", "HR", "CIpos", "CIneg")
write.csv(results, paste0(output_dir,"HR_FullSample_",biobank_name,".csv"),row.names=FALSE)
