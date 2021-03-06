/*******************************************************************************/
/*@file cohort_initial.sql
/*
/*in: PCORNET_CDM tables 
/*
/*params: &&cdm_db_schema, &&start_date, &&end_date
/*       
/*out: AKI_Initial
/*
/*action: write
/********************************************************************************/
create table AKI_Initial as
with age_at_admit as (
select e.ENCOUNTERID
      ,e.PATID
      ,to_date(to_char(trunc(e.ADMIT_DATE),'YYYY:MM:DD') || ' ' || to_char(e.ADMIT_TIME),
               'YYYY:MM:DD HH24:MI') ADMIT_DATE_TIME
      ,round((e.ADMIT_DATE-d.BIRTH_DATE)/365.25) age_at_admit
      ,to_date(to_char(trunc(e.DISCHARGE_DATE),'YYYY:MM:DD') || ' ' || to_char(e.DISCHARGE_TIME),
               'YYYY:MM:DD HH24:MI') DISCHARGE_DATE_TIME
      ,round(e.DISCHARGE_DATE - e.ADMIT_DATE) LOS
      ,e.ENC_TYPE
      ,e.DISCHARGE_DISPOSITION
      ,e.DISCHARGE_STATUS
      ,e.DRG
      ,e.DRG_TYPE
      ,e.ADMITTING_SOURCE
from &&cdm_db_schema.ENCOUNTER e
join &&cdm_db_schema.DEMOGRAPHIC d
on e.PATID = d.PATID
where e.DISCHARGE_DATE - e.ADMIT_DATE >= 2 and
      e.ENC_TYPE in ('EI','IP','IS') and
      e.ADMIT_DATE between Date &&start_date and Date &&end_date
)

select ENCOUNTERID
      ,PATID
      ,age_at_admit
      ,ADMIT_DATE_TIME
      ,DISCHARGE_DATE_TIME
      ,los
      ,ENC_TYPE
      ,DISCHARGE_DISPOSITION
      ,DISCHARGE_STATUS
      ,DRG
      ,DRG_TYPE
      ,ADMITTING_SOURCE
from age_at_admit
where age_at_admit >= 18



