/********************************************************************************/
/*@file collect_med.sql
/*
/*in: AKI_onsets
/*
/*params: &&cdm_db_schema
/*
/*out: AKI_MED
/*
/*action: query
/********************************************************************************/
select distinct
       pat.PATID
      ,pat.ENCOUNTERID
      ,to_date(to_char(trunc(p.RX_ORDER_DATE),'YYYY:MM:DD') || ' ' || to_char(p.RX_ORDER_TIME),
               'YYYY:MM:DD HH24:MI') RX_ORDER_DATE_TIME
      ,p.RX_START_DATE
      ,least(pat.DISCHARGE_DATE,p.RX_END_DATE) RX_END_DATE
      ,p.RX_BASIS
      ,p.RXNORM_CUI
      ,p.RAW_RX_NDC
      --,regexp_substr(p.RAW_RX_MED_NAME,'[^\[]+',1,1) RX_MED_NAME
      ,p.RX_QUANTITY
      --,p.RX_QUANTITY_UNIT
      ,p.RX_REFILLS
      ,p.RX_DAYS_SUPPLY
      ,p.RX_FREQUENCY
      ,case when p.RX_DAYS_SUPPLY > 0 and p.RX_QUANTITY is not null then round(p.RX_QUANTITY/p.RX_DAYS_SUPPLY) 
            else null end as RX_QUANTITY_DAILY
      ,round(p.RX_START_DATE-pat.ADMIT_DATE,2) DAYS_SINCE_ADMIT
from AKI_onsets pat
join &&cdm_db_schema.PRESCRIBING p
on pat.ENCOUNTERID = p.ENCOUNTERID
where coalesce(p.RXNORM_CUI,p.RAW_RX_NDC) is not null and 
      p.RX_START_DATE is not null and
      p.RX_ORDER_DATE is not null and 
      p.RX_ORDER_TIME is not null and
      p.RX_ORDER_DATE between pat.ADMIT_DATE-30 and
                              pat.DISCHARGE_DATE
order by PATID, ENCOUNTERID, RXNORM_CUI, RX_START_DATE


