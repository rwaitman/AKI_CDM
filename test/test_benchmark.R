#------SetUp----------
source("./R/util.R")
source("./R/var_etl_surv.R")

require_libraries(c("tidyr",
                    "dplyr",
                    "magrittr",
                    "stringr",
                    "broom",
                    "Matrix",
                    "xgboost",
                    "ROCR",
                    "PRROC",
                    "ResourceSelection",
                    "knitr",
                    "kableExtra",
                    "ggplot2",
                    "openxlsx"))

# experimental design parameters
#----prediction ending point
pred_end<-7

#-----prediction point
pred_in_d_opt<-c(1,2)

#-----prediction tasks
pred_task_lst<-c("stg1up","stg2up","stg3")

#-----feature selection type
fs_type_opt<-c("no_fs","rm_scr_bun")
rm_key<-c('2160-0','38483-4','14682-9','21232-4','35203-9','44784-7','59826-8',
          '16188-5','16189-3','59826-8','35591-7','50380-5','50381-3','35592-5',
          '44784-7','11041-1','51620-3','72271-0','11042-9','51619-5','35203-9','14682-9',
          '12966-8','12965-0','6299-2','59570-2','12964-3','49071-4','72270-2',
          '11065-0','3094-0','35234-4','14937-7',
          '3097-3','44734-2','BUN_SCR')

#------PreProcess----------
tbl1<-readRDS("./data/Table1.rda") %>%
  dplyr::mutate(yr=as.numeric(format(strptime(ADMIT_DATE, "%Y-%m-%d %H:%M:%S"),"%Y")))

for(pred_in_d in pred_in_d_opt){
  #--determine update time window
  tw<-as.double(seq(0,7))
  if(pred_in_d>1){
    tw<-tw[-seq_len(pred_in_d-1)]
  } 
  
  #--by chunks: encounter year
  enc_yr<-tbl1 %>%
    dplyr::select(yr) %>%
    unique %>% arrange(yr) %>%
    filter(yr>2009) %>%
    unlist
  
  #--by variable type
  var_type<-c("demo","vital","lab","dx","px","med")
  
  #--save results as array
  for(pred_task in pred_task_lst){
    start_tsk<-Sys.time()
    cat("Start variable collection for task",pred_task,".\n")
    #---------------------------------------------------------------------------------------------
    
    var_by_yr<-list()
    var_bm<-list()
    rsample_idx<-c()
    for(i in seq_along(enc_yr)){
      start_i<-Sys.time()
      cat("...start variable collection for year",enc_yr[i],".\n")
      
      #--collect end_points
      dat_i<-tbl1 %>% filter(yr==enc_yr[i]) %>%
        dplyr::select(ENCOUNTERID,yr,
                      NONAKI_SINCE_ADMIT,
                      AKI1_SINCE_ADMIT,
                      AKI2_SINCE_ADMIT,
                      AKI3_SINCE_ADMIT) %>%
        gather(y,dsa_y,-ENCOUNTERID,-yr) %>%
        filter(!is.na(dsa_y)) %>%
        dplyr::mutate(y=recode(y,
                               "NONAKI_SINCE_ADMIT"=0,
                               "AKI1_SINCE_ADMIT"=1,
                               "AKI2_SINCE_ADMIT"=2,
                               "AKI3_SINCE_ADMIT"=3)) %>%
        dplyr::mutate(y=as.numeric(y))
      
      if(pred_task=="stg1up"){
        dat_i %<>%
          dplyr::mutate(y=as.numeric(y>0)) %>%
          group_by(ENCOUNTERID) %>% top_n(n=1L,wt=dsa_y) %>% ungroup
      }else if(pred_task=="stg2up"){
        dat_i %<>%
          # filter(y!=1) %>% # remove stage 1
          dplyr::mutate(y=as.numeric(y>1)) %>%
          group_by(ENCOUNTERID) %>% top_n(n=1L,wt=dsa_y) %>% ungroup
      }else if(pred_task=="stg3"){
        dat_i %<>%
          # filter(!(y %in% c(1,2))) %>% # remove stage 1,2
          dplyr::mutate(y=as.numeric(y>2)) %>%
          group_by(ENCOUNTERID) %>% top_n(n=1L,wt=dsa_y) %>% ungroup
      }else{
        stop("prediction task is not valid!")
      }
      
      #--random sampling
      rsample_idx %<>%
        bind_rows(dat_i %>% 
                    dplyr::select(ENCOUNTERID,yr) %>%
                    unique %>%
                    dplyr::mutate(cv10_idx=sample(1:10,n(),replace=T)))
      
      #--ETL variables
      X_surv<-c()
      y_surv<-c()
      var_etl_bm<-c()
      for(v in seq_along(var_type)){
        start_v<-Sys.time()
        
        #extract
        var_v<-readRDS(paste0("./data/AKI_",toupper(var_type[v]),".rda")) %>%
          semi_join(dat_i,by="ENCOUNTERID")
        
        if(var_type[v] != "demo"){
          if(var_type[v] == "med"){
            var_v %<>% 
              transform(value=strsplit(value,","),
                        dsa=strsplit(dsa,",")) %>%
              unnest(value,dsa) %>%
              dplyr::mutate(value=as.numeric(value),
                            dsa=as.numeric(dsa))
          }
          var_v %<>% filter(dsa <= pred_end)
        }
        
        #transform
        var_v<-format_data(dat=var_v,
                           type=var_type[v],
                           pred_end=pred_end)
        
        Xy_surv<-get_dsurv_temporal(dat=var_v,
                                    censor=dat_i,
                                    tw=tw,
                                    pred_in_d=pred_in_d)
        
        #load
        X_surv %<>% bind_rows(Xy_surv$X_surv) %>% unique
        y_surv %<>% bind_rows(Xy_surv$y_surv) %>% unique
        
        lapse_v<-Sys.time()-start_v
        var_etl_bm<-c(var_etl_bm,paste0(lapse_v,units(lapse_v)))
        cat("\n......finished ETL",var_type[v],"for year",enc_yr[i],"in",lapse_v,units(lapse_v),".\n")
      }
      var_by_yr[[i]]<-list(X_surv=X_surv,
                           y_surv=y_surv)
      
      lapse_i<-Sys.time()-start_i
      var_etl_bm<-c(var_etl_bm,paste0(lapse_i,units(lapse_i)))
      cat("\n...finished variabl collection for year",enc_yr[i],"in",lapse_i,units(lapse_i),".\n")
      flush.console() 
      
      var_bm[[i]]<-data.frame(bm_nm=c(var_type,"overall"),
                              bm_time=var_etl_bm,
                              stringsAsFactors = F)
    }
    #--save preprocessed data
    saveRDS(rsample_idx,file=paste0("./data/preproc/",pred_in_d,"d_rsample_idx_",pred_task,".rda"))
    saveRDS(var_by_yr,file=paste0("./data/preproc/",pred_in_d,"d_var_by_yr_",pred_task,".rda"))
    saveRDS(var_bm,file=paste0("./data/preproc/",pred_in_d,"d_var_bm",pred_task,".rda"))
    
    #---------------------------------------------------------------------------------------------
    lapse_tsk<-Sys.time()-start_tsk
    cat("\nFinish variable ETL for task:",pred_task,"in",pred_in_d,"days",",in",lapse_tsk,units(lapse_tsk),".\n")
  }
}


#------Benchmark-----
rm(list=c("X_surv","y_surv","dat_i")); gc() #release some memory

for(pred_in_d in pred_in_d_opt){
  
  for(pred_task in pred_task_lst){
    start_tsk<-Sys.time()
    #---------------------------------------------------------------------------------------------
    var_by_task<-readRDS(paste0("./data/preproc/",pred_in_d,"d_var_by_yr_",pred_task,".rda"))
    
    for(fs_type in fs_type_opt){
      #--prepare testing set
      yr_rg<-seq(2010,2018)
      X_ts<-c()
      y_ts<-c()
      for(i in seq_along(yr_rg)){
        var_by_yr<-var_by_task[[i]]
        
        X_ts %<>% bind_rows(var_by_yr[["X_surv"]])
        y_ts %<>% bind_rows(var_by_yr[["y_surv"]])
        
        # cat(pred_in_d,",",pred_in_d,"...finish stack data of encounters from year",yr_rg[i],".\n")
      }
      
      #--pre-filter
      if(fs_type=="rm_scr_bun"){
        X_ts %<>%
          filter(!(key %in% c(rm_key,paste0(rm_key,"_change"))))
      }
      
      #--collect variables used in training
      ref_mod<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_model_gbm_",fs_type,"_",pred_task,".rda"))
      tr_key<-data.frame(key = ref_mod$feature_names,
                         stringsAsFactors = F)
      
      #--transform testing matrix
      y_ts %<>%
        arrange(ENCOUNTERID,dsa_y) %>%
        unite("ROW_ID",c("ENCOUNTERID","dsa_y")) %>%
        arrange(ROW_ID) %>%
        unique
      
      X_ts %<>% 
        unite("ROW_ID",c("ENCOUNTERID","dsa_y")) %>%
        semi_join(y_ts,by="ROW_ID") %>%
        semi_join(tr_key,by="key")
      
      x_add<-tr_key %>%
        anti_join(data.frame(key = unique(X_ts$key),
                             stringsAsFactors = F),
                  by="key")
      
      #align with training
      if(nrow(x_add)>0){
        X_ts %<>%
          arrange(ROW_ID) %>%
          bind_rows(data.frame(ROW_ID = rep("0_0",nrow(x_add)),
                               dsa = -99,
                               key = x_add$key,
                               value = 0,
                               stringsAsFactors=F))
      }
      X_ts %<>%
        long_to_sparse_matrix(df=.,
                              id="ROW_ID",
                              variable="key",
                              val="value")
      if(nrow(x_add)>0){
        X_ts<-X_ts[-1,]
      }
      
      #check alignment
      all(row.names(X_ts)==y_ts$ROW_ID)
      all(ref_mod$feature_names==colnames(X_ts))
      
      #--covert to xgb data frame
      dtest<-xgb.DMatrix(data=X_ts,label=y_ts$y)
      
      #--validation
      valid<-data.frame(y_ts,
                        pred = predict(ref_mod,dtest),
                        stringsAsFactors = F)
      
      #--save model and other results
      saveRDS(valid,file=paste0("./data/model_kumc/pred_in_",pred_in_d,"d_valid_gbm_",fs_type,"_",pred_task,".rda"))
      #-------------------------------------------------------------------------------------------------------------
      lapse_tsk<-Sys.time()-start_tsk
      cat("\nFinish validating benchmark models for task:",pred_task,"in",pred_in_d,"with",fs_type,",in",lapse_tsk,units(lapse_tsk),".\n")
    }
  }
}
#------Performance-----
rm(list=c("X_ts","y_ts","dtest")); gc() #release some memory

pred_in_d_opt<-c(1,2)
fs_type_opt<-c("no_fs","rm_scr_bun")
pred_task<-c("stg1up","stg2up","stg3")

for(pred_in_d in pred_in_d_opt){
  for(fs_type in fs_type_opt){
    perf_tbl_full<-c()
    perf_tbl<-c()
    calib_tbl<-c()
    for(i in seq_along(pred_task)){
      valid<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_valid_gbm_",fs_type,"_",pred_task[i],".rda"))
      
      #overall summary
      perf_summ<-get_perf_summ(pred=valid$pred,
                               real=valid$y,
                               keep_all_cutoffs=T)
      perf_tbl_full %<>% 
        bind_rows(perf_summ$perf_at %>% 
                    dplyr::mutate(pred_task=pred_task[i],pred_in_d=pred_in_d,fs_type=fs_type))
      
      perf_tbl %<>% 
        bind_rows(perf_summ$perf_summ %>% 
                    dplyr::mutate(pred_task=pred_task[i],pred_in_d=pred_in_d,fs_type=fs_type))
      
      #calibration
      calib<-get_calibr(pred=valid$pred,
                        real=valid$y,
                        n_bin=20)
      
      calib_tbl %<>% 
        bind_rows(calib %>% 
                    dplyr::mutate(pred_task=pred_task[i],pred_in_d=pred_in_d,fs_type=fs_type))
    }
    
    perf_out<-list(perf_tbl_full=perf_tbl_full,
                   perf_tbl=perf_tbl,
                   calib_tbl=calib_tbl)
    
    #save results as r data.frame
    saveRDS(perf_out,file=paste0("./data/model_kumc/pred_in_",pred_in_d,"d_",fs_type,"_baseline_model_perf.rda"))
  }
}

tbl1<-readRDS("./data/Table1.rda") %>%
  dplyr::select(ENCOUNTERID,SERUM_CREAT_BASE) %>%
  inner_join(readRDS("./data/AKI_DEMO.rda") %>%
               filter(key=="AGE") %>%
               dplyr::select(ENCOUNTERID,key,value) %>%
               spread(key,value) %>%
               mutate(AGE=as.numeric(AGE)),
             by="ENCOUNTERID")

final_out<-list()

#------24-hr Prediction-----
pred_in_d<-1

fs_type_opt<-c("no_fs","rm_scr_bun")

#overall summary
perf_overall<-c()
for(fs_type in fs_type_opt){
  perf_overall %<>%
    bind_rows(readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_",fs_type,"_baseline_model_perf.rda"))$perf_tbl %>%
                filter(overall_meas %in% c("roauc",
                                           "roauc_low",
                                           "roauc_up",
                                           "prauc1",
                                           "opt_sens",
                                           "opt_spec",
                                           "opt_ppv",
                                           "opt_npv")) %>%
                dplyr::mutate(overall_meas=recode(overall_meas,
                                                  roauc="1.ROAUC",
                                                  prauc1="2.PRAUC",
                                                  opt_sens="3.Optimal Sensitivity",
                                                  opt_spec="4.Optimal Specificity",
                                                  opt_ppv="5.Optimal Positive Predictive Value",
                                                  opt_npv="6.Optimal Negative Predictive Value"),
                              grp=paste0("Overall:",fs_type)))
}

#subgroup-age
fs_type<-"no_fs"
subgrp_age<-c()
for(i in seq_along(pred_task)){
  valid<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_valid_gbm_",fs_type,"_",pred_task[i],".rda")) %>%
    mutate(ENCOUNTERID=gsub("_.*","",ROW_ID),
           day_at=as.numeric(gsub(".*_","",ROW_ID))) %>%
    inner_join(tbl1,by="ENCOUNTERID") %>%
    dplyr::select(ENCOUNTERID,day_at,y,pred,AGE) %>%
    dplyr::mutate(age=cut(AGE,breaks=c(0,45,65,Inf),include.lowest=T,right=F))
  
  grp_vec<-unique(valid$age)
  for(grp in seq_along(grp_vec)){
    valid_grp<-valid %>% filter(age==grp_vec[grp])
    grp_summ<-get_perf_summ(pred=valid_grp$pred,
                            real=valid_grp$y,
                            keep_all_cutoffs=F)$perf_summ %>%
      dplyr::filter(overall_meas %in% c("roauc",
                                        "roauc_low",
                                        "roauc_up",
                                        "prauc1",
                                        "opt_sens",
                                        "opt_spec",
                                        "opt_ppv",
                                        "opt_npv")) %>%
      dplyr::mutate(overall_meas=recode(overall_meas,
                                        roauc="1.ROAUC",
                                        prauc1="2.PRAUC",
                                        opt_sens="3.Optimal Sensitivity",
                                        opt_spec="4.Optimal Specificity",
                                        opt_ppv="5.Optimal Positive Predictive Value",
                                        opt_npv="6.Optimal Negative Predictive Value"))
    subgrp_age %<>% 
      bind_rows(grp_summ %>% 
                  dplyr::mutate(grp=paste0("Subgrp_AGE:",grp_vec[grp]),
                                pred_task=paste0("stg",i,"up")))
  }
}

#subgroup-scr
subgrp_scr<-c()
for(i in seq_along(pred_task)){
  valid<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_valid_gbm_",fs_type,"_",pred_task[i],".rda")) %>%
    mutate(ENCOUNTERID=gsub("_.*","",ROW_ID),
           day_at=as.numeric(gsub(".*_","",ROW_ID))) %>%
    inner_join(tbl1,by="ENCOUNTERID") %>%
    dplyr::select(ENCOUNTERID,day_at,y,pred,SERUM_CREAT_BASE) %>%
    mutate(admit_scr=cut(SERUM_CREAT_BASE,breaks=c(0,1,2,3,Inf),include.lowest=T,right=F))
  
  grp_vec<-unique(valid$admit_scr)
  for(grp in seq_along(grp_vec)){
    valid_grp<-valid %>% filter(admit_scr==grp_vec[grp])
    grp_summ<-get_perf_summ(pred=valid_grp$pred,
                            real=valid_grp$y,
                            keep_all_cutoffs=F)$perf_summ %>%
      filter(overall_meas %in% c("roauc",
                                 "roauc_low",
                                 "roauc_up",
                                 "prauc1",
                                 "opt_sens",
                                 "opt_spec",
                                 "opt_ppv",
                                 "opt_npv")) %>%
      dplyr::mutate(overall_meas=recode(overall_meas,
                                        roauc="1.ROAUC",
                                        prauc1="2.PRAUC",
                                        opt_sens="3.Optimal Sensitivity",
                                        opt_spec="4.Optimal Specificity",
                                        opt_ppv="5.Optimal Positive Predictive Value",
                                        opt_npv="6.Optimal Negative Predictive Value"))
    subgrp_scr %<>% 
      bind_rows(grp_summ %>% 
                  dplyr::mutate(grp=paste0("Subgrp_Scr_Base:",grp_vec[grp]),
                                pred_task=paste0("stg",i,"up")))
  }
}

perf_overall %<>%
  bind_rows(subgrp_age %>% 
              dplyr::mutate(pred_in_d=pred_in_d,fs_type=fs_type)) %>%
  bind_rows(subgrp_scr %>% 
              dplyr::mutate(pred_in_d=pred_in_d,fs_type=fs_type)) %>%
  dplyr::select(pred_in_d,fs_type,grp,pred_task,overall_meas,meas_val) %>%
  dplyr::mutate(pred_task=recode(pred_task,
                                 `stg1up`="a.AKI>=1",
                                 `stg2up`="b.AKI>=2",
                                 `stg3`="c.AKI=3",
                                 `stg3up`="c.AKI=3"),
                meas_val=round(meas_val,4)) %>%
  spread(overall_meas,meas_val) %>%
  dplyr::mutate(roauc_up=paste0(roauc_up,")")) %>%
  unite("1.ROAUC_CI",c("roauc_low","roauc_up"),sep=",") %>%
  unite("1.ROAUC",c("1.ROAUC","1.ROAUC_CI"),sep=" (")  

row_grp_pos<-perf_overall %>% 
  arrange(grp,pred_task) %>%
  mutate(rn=1:n()) %>%
  dplyr::mutate(root_grp=gsub(":.*","",grp)) %>%
  group_by(root_grp,pred_in_d) %>%
  dplyr::summarize(begin=rn[1],
                   end=rn[n()]) %>%
  ungroup

kable(perf_overall %>% arrange(grp,pred_task),
      caption="Table1 - 24-Hour Prediction of AKI1, AKI2, AKI3") %>%
  kable_styling("striped", full_width = F) %>%
  group_rows("Overall", row_grp_pos$begin[1],row_grp_pos$end[1]) %>%
  group_rows("Subgroup-Age", row_grp_pos$begin[2],row_grp_pos$end[2]) %>%
  group_rows("Subgroup-Scr_Base", row_grp_pos$begin[3],row_grp_pos$end[3])

final_out[["pred24_summ"]]<-perf_overall

#plot out sens, spec, ppv, npv on a scale of cutoff probabilities
brks<-unique(c(0,seq(0.001,0.01,by=0.001),seq(0.02,0.1,by=0.01),seq(0.2,1,by=0.1)))
pred24_cutoff_plot<-list()

for(fs_type_i in seq_along(fs_type_opt)){
  fs_type<-fs_type_opt[fs_type_i]
  
  perf_cutoff<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_",fs_type,"_baseline_model_perf.rda"))$perf_tbl_full %>%
    dplyr::select(cutoff,rec_sens,spec,ppv,npv,pred_task) %>%
    mutate(bin=cut(cutoff,breaks=brks,include.lowest=T,label=F)) %>%
    group_by(bin,pred_task) %>%
    dplyr::summarise(cutoff=round(max(cutoff),3),
                     sens_l=quantile(rec_sens,0.025,na.rm=T),
                     sens=median(rec_sens,na.rm=T),
                     sens_u=quantile(rec_sens,0.975,na.rm=T),
                     spec_l=quantile(spec,0.025,na.rm=T),
                     spec=median(spec,na.rm=T),
                     spec_u=quantile(spec,0.975,na.rm=T),
                     ppv_l=quantile(ppv,0.025,na.rm=T),
                     ppv=median(ppv,na.rm=T),
                     ppv_u=quantile(ppv,0.975,na.rm=T),
                     npv_l=quantile(npv,0.025,na.rm=T),
                     npv=median(npv,na.rm=T),
                     npv_u=quantile(npv,0.975,na.rm=T)) %>%
    ungroup %>% dplyr::select(-bin) %>%
    gather(metric_type,metric_val,-cutoff,-pred_task) %>%
    mutate(metric_type2=ifelse(grepl("_l",metric_type),"low",
                               ifelse(grepl("_u",metric_type),"up","mid")),
           metric_type=gsub("_.*","",metric_type)) %>%
    spread(metric_type2,metric_val) %>%
    mutate(pred_task=recode(pred_task,
                            `stg1up`="a.AKI>=1",
                            `stg2up`="b.AKI>=2",
                            `stg3`="c.AKI=3"))
  
  pred24_cutoff_plot[[fs_type_i]]<-ggplot(perf_cutoff %>% dplyr::filter(cutoff <=0.15),
                                          aes(x=cutoff,y=mid,color=metric_type,fill=metric_type))+
    geom_line()+ geom_ribbon(aes(ymin=low,ymax=up),alpha=0.3)+
    labs(x="cutoff probability",y="performance metrics",
         title=paste0("Figure",fs_type_i," - Metrics at different cutoff points:",fs_type))+
    facet_wrap(~pred_task,scales="free",ncol=3)
  
  final_out[[paste0("pred24_cutoff_",fs_type)]]<-perf_cutoff
}

print(pred24_cutoff_plot[[1]])
print(pred24_cutoff_plot[[2]])

pred24_calib_plot<-list()
# plot calibration
for(fs_type_i in seq_along(fs_type_opt)){
  fs_type<-fs_type_opt[fs_type_i]
  
  calib_tbl<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_",fs_type,"_baseline_model_perf.rda"))$calib_tbl %>%
    mutate(pred_task=recode(pred_task,
                            `stg1up`="a.AKI>=1",
                            `stg2up`="b.AKI>=2",
                            `stg3`="c.AKI=3"))
  
  pred24_calib_plot[[fs_type_i]]<-ggplot(calib_tbl,aes(x=y_p,y=pred_p))+
    geom_point()+geom_abline(intercept=0,slope=1)+
    geom_errorbar(aes(ymin=binCI_lower,ymax=binCI_upper))+
    labs(x="Actual Probability",y="Predicted Probability",
         title=paste0("Figure",fs_type_i+2," - Calibration:",fs_type))+
    facet_wrap(~pred_task,scales="free")
  
  final_out[[paste0("pred24_calibr_",fs_type)]]<-calib_tbl
}
print(pred24_calib_plot[[1]])
print(pred24_calib_plot[[2]])



#------48-hr Prediction-----
pred_in_d<-2
fs_type_opt<-c("no_fs","rm_scr_bun")

#overall summary
perf_overall<-c()
for(fs_type in fs_type_opt){
  perf_overall %<>%
    bind_rows(readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_",fs_type,"_baseline_model_perf.rda"))$perf_tbl %>%
                filter(overall_meas %in% c("roauc",
                                           "roauc_low",
                                           "roauc_up",
                                           "prauc1",
                                           "opt_sens",
                                           "opt_spec",
                                           "opt_ppv",
                                           "opt_npv")) %>%
                dplyr::mutate(overall_meas=recode(overall_meas,
                                                  roauc="1.ROAUC",
                                                  prauc1="2.PRAUC",
                                                  opt_sens="3.Optimal Sensitivity",
                                                  opt_spec="4.Optimal Specificity",
                                                  opt_ppv="5.Optimal Positive Predictive Value",
                                                  opt_npv="6.Optimal Negative Predictive Value"),
                              grp=paste0("Overall:",fs_type)))
}

#subgroup-age
fst_type<-"no_fs"
subgrp_age<-c()
for(i in seq_along(pred_task)){
  valid<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_valid_gbm_",fs_type,"_",pred_task[i],".rda")) %>%
    mutate(ENCOUNTERID=gsub("_.*","",ROW_ID),
           day_at=as.numeric(gsub(".*_","",ROW_ID))) %>%
    inner_join(tbl1,by="ENCOUNTERID") %>%
    dplyr::select(ENCOUNTERID,day_at,y,pred,AGE) %>%
    dplyr::mutate(age=cut(AGE,breaks=c(0,45,65,Inf),include.lowest=T,right=F))
  
  grp_vec<-unique(valid$age)
  for(grp in seq_along(grp_vec)){
    valid_grp<-valid %>% filter(age==grp_vec[grp])
    grp_summ<-get_perf_summ(pred=valid_grp$pred,
                            real=valid_grp$y,
                            keep_all_cutoffs=F)$perf_summ %>%
      dplyr::filter(overall_meas %in% c("roauc",
                                        "roauc_low",
                                        "roauc_up",
                                        "prauc1",
                                        "opt_sens",
                                        "opt_spec",
                                        "opt_ppv",
                                        "opt_npv")) %>%
      dplyr::mutate(overall_meas=recode(overall_meas,
                                        roauc="1.ROAUC",
                                        prauc1="2.PRAUC",
                                        opt_sens="3.Optimal Sensitivity",
                                        opt_spec="4.Optimal Specificity",
                                        opt_ppv="5.Optimal Positive Predictive Value",
                                        opt_npv="6.Optimal Negative Predictive Value"))
    subgrp_age %<>% 
      bind_rows(grp_summ %>% 
                  dplyr::mutate(grp=paste0("Subgrp_AGE:",grp_vec[grp]),
                                pred_task=paste0("stg",i,"up")))
  }
}

#subgroup-scr
subgrp_scr<-c()
for(i in seq_along(pred_task)){
  valid<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_valid_gbm_",fs_type,"_",pred_task[i],".rda")) %>%
    mutate(ENCOUNTERID=gsub("_.*","",ROW_ID),
           day_at=as.numeric(gsub(".*_","",ROW_ID))) %>%
    inner_join(tbl1,by="ENCOUNTERID") %>%
    dplyr::select(ENCOUNTERID,day_at,y,pred,SERUM_CREAT_BASE) %>%
    mutate(admit_scr=cut(SERUM_CREAT_BASE,breaks=c(0,1,2,3,Inf),include.lowest=T,right=F))
  
  grp_vec<-unique(valid$admit_scr)
  for(grp in seq_along(grp_vec)){
    valid_grp<-valid %>% filter(admit_scr==grp_vec[grp])
    grp_summ<-get_perf_summ(pred=valid_grp$pred,
                            real=valid_grp$y,
                            keep_all_cutoffs=F)$perf_summ %>%
      filter(overall_meas %in% c("roauc",
                                 "roauc_low",
                                 "roauc_up",
                                 "prauc1",
                                 "opt_sens",
                                 "opt_spec",
                                 "opt_ppv",
                                 "opt_npv")) %>%
      dplyr::mutate(overall_meas=recode(overall_meas,
                                        roauc="1.ROAUC",
                                        prauc1="2.PRAUC",
                                        opt_sens="3.Optimal Sensitivity",
                                        opt_spec="4.Optimal Specificity",
                                        opt_ppv="5.Optimal Positive Predictive Value",
                                        opt_npv="6.Optimal Negative Predictive Value"))
    subgrp_scr %<>% 
      bind_rows(grp_summ %>% 
                  dplyr::mutate(grp=paste0("Subgrp_Scr_Base:",grp_vec[grp]),
                                pred_task=paste0("stg",i,"up")))
  }
}

perf_overall %<>%
  bind_rows(subgrp_age %>% 
              dplyr::mutate(pred_in_d=pred_in_d,fs_type=fs_type)) %>%
  bind_rows(subgrp_scr %>% 
              dplyr::mutate(pred_in_d=pred_in_d,fs_type=fs_type)) %>%
  dplyr::select(pred_in_d,fs_type,grp,pred_task,overall_meas,meas_val) %>%
  dplyr::mutate(pred_task=recode(pred_task,
                                 `stg1up`="a.AKI>=1",
                                 `stg2up`="b.AKI>=2",
                                 `stg3`="c.AKI=3",
                                 `stg3up`="c.AKI=3"),
                meas_val=round(meas_val,4)) %>%
  spread(overall_meas,meas_val) %>%
  dplyr::mutate(roauc_up=paste0(roauc_up,")")) %>%
  unite("1.ROAUC_CI",c("roauc_low","roauc_up"),sep=",") %>%
  unite("1.ROAUC",c("1.ROAUC","1.ROAUC_CI"),sep=" (")  

row_grp_pos<-perf_overall %>% 
  arrange(grp,pred_task) %>%
  mutate(rn=1:n()) %>%
  dplyr::mutate(root_grp=gsub(":.*","",grp)) %>%
  group_by(root_grp,pred_in_d) %>%
  dplyr::summarize(begin=rn[1],
                   end=rn[n()]) %>%
  ungroup

kable(perf_overall %>% arrange(grp,pred_task),
      caption="Table1 - 48-Hour Prediction of AKI1, AKI2, AKI3") %>%
  kable_styling("striped", full_width = F) %>%
  group_rows("Overall", row_grp_pos$begin[1],row_grp_pos$end[1]) %>%
  group_rows("Subgroup-Age", row_grp_pos$begin[2],row_grp_pos$end[2]) %>%
  group_rows("Subgroup-Scr_Base", row_grp_pos$begin[3],row_grp_pos$end[3])

final_out[["pred48_summ"]]<-perf_overall


pred48_cutoff_plot<-list()

#plot out sens, spec, ppv, npv on a scale of cutoff probabilities
brks<-unique(c(0,seq(0.001,0.01,by=0.001),seq(0.02,0.1,by=0.01),seq(0.2,1,by=0.1)))
for(fs_type_i in seq_along(fs_type_opt)){
  fs_type<-fs_type_opt[fs_type_i]
  
  perf_cutoff<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_",fs_type,"_baseline_model_perf.rda"))$perf_tbl_full %>%
    dplyr::select(cutoff,size,rec_sens,spec,ppv,npv,pred_task) %>%
    mutate(bin=cut(cutoff,breaks=brks,include.lowest=T,label=F)) %>%
    group_by(bin,pred_task) %>%
    dplyr::summarise(size=sum(size),
                     cutoff=round(max(cutoff),3),
                     sens_l=quantile(rec_sens,0.025,na.rm=T),
                     sens=median(rec_sens,na.rm=T),
                     sens_u=quantile(rec_sens,0.975,na.rm=T),
                     spec_l=quantile(spec,0.025,na.rm=T),
                     spec=median(spec,na.rm=T),
                     spec_u=quantile(spec,0.975,na.rm=T),
                     ppv_l=quantile(ppv,0.025,na.rm=T),
                     ppv=median(ppv,na.rm=T),
                     ppv_u=quantile(ppv,0.975,na.rm=T),
                     npv_l=quantile(npv,0.025,na.rm=T),
                     npv=median(npv,na.rm=T),
                     npv_u=quantile(npv,0.975,na.rm=T)) %>%
    ungroup %>%
    group_by(pred_task) %>%
    dplyr::mutate(size_overall=sum(size),
                  size_cum=cumsum(size)) %>%
    ungroup %>%
    mutate(size_abv=size_overall-size_cum) %>%
    dplyr::select(-bin,-size_overall,-size_cum,-size) %>%
    gather(metric_type,metric_val,-cutoff,-size_abv,-pred_task) %>%
    mutate(metric_type2=ifelse(grepl("_l",metric_type),"low",
                               ifelse(grepl("_u",metric_type),"up","mid")),
           metric_type=gsub("_.*","",metric_type)) %>%
    spread(metric_type2,metric_val) %>%
    mutate(pred_task=recode(pred_task,
                            `stg1up`="a.At least AKI1",
                            `stg2up`="b.At least AKI2",
                            `stg3`="c.AKI3"))
  
  pred48_cutoff_plot[[fs_type_i]]<-ggplot(perf_cutoff %>% dplyr::filter(cutoff <=0.15),
                                          aes(x=cutoff,y=mid,color=metric_type,fill=metric_type))+
    geom_line()+ geom_ribbon(aes(ymin=low,ymax=up),alpha=0.3)+
    labs(x="cutoff probability",y="performance metrics",
         title=paste0("Figure",fs_type_i+6," - Metrics at different cutoff points:",fs_type))+
    facet_wrap(~pred_task,scales="free",ncol=3)
  
  final_out[[paste0("pred48_cutoff_",fs_type)]]<-perf_cutoff
}
print(pred48_cutoff_plot[[1]])
print(pred48_cutoff_plot[[2]])

pred48_calib_plot<-list()

# plot calibration
for(fs_type_i in seq_along(fs_type_opt)){
  fs_type<-fs_type_opt[fs_type_i]
  
  calib_tbl<-readRDS(paste0("./data/model_kumc/pred_in_",pred_in_d,"d_",fs_type,"_baseline_model_perf.rda"))$calib_tbl %>%
    mutate(pred_task=recode(pred_task,
                            `stg1up`="a.AKI>=1",
                            `stg2up`="b.AKI>=2",
                            `stg3`="c.AKI=3"))
  
  pred48_calib_plot[[fs_type_i]]<-ggplot(calib_tbl,aes(x=y_p,y=pred_p))+
    geom_point()+geom_abline(intercept=0,slope=1)+
    geom_errorbar(aes(ymin=binCI_lower,ymax=binCI_upper))+
    labs(x="Actual Probability",y="Predicted Probability",
         title=paste0("Figure",fs_type_i+8," - Calibration:",fs_type))+
    facet_wrap(~pred_task,scales="free")
  
  final_out[[paste0("pred48_calibr_",fs_type)]]<-calib_tbl
}
print(pred48_calib_plot[[1]])
print(pred48_calib_plot[[2]])

