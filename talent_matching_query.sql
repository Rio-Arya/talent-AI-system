-- CREATE / REPLACE FUNCTION : get_talent_matches(benchmark_ids JSONB)
-- Returns detailed matching results per employee vs benchmark baseline
create or replace function public.get_talent_matches(benchmark_ids jsonb)
returns table(
    employee_id text,
    directorate text,
    role text,
    grade text,
    tgv_name text,
    tv_name text,
    baseline_score text,
    user_score text,
    tv_match_rate numeric,
    tgv_match_rate numeric,
    final_match_rate numeric,
    is_benchmark boolean
)
language sql
as $$
WITH 
----------------------------------------------------------
-- PHASE 1: REFERENCE DATA (MAIN EMPLOYEE + PAPI + etc)
----------------------------------------------------------
main_cleaned_imputed AS (
    SELECT 
        e.employee_id,
        ddir.name AS directorate,
        dpos.name AS position,
        dgr.name AS grade,
        dedu.name AS education,
        dma.name AS major,
        dare.name AS area,
        e.years_of_service_months,
        p.iq, p.gtq, p.pauli, p.faxtor, p.tiki,
        p.mbti, p.disc,
        COALESCE((
          SELECT score FROM papi_scores ps 
          WHERE ps.employee_id = e.employee_id AND ps.scale_code='P'
        ),0) AS papi_p,
        COALESCE((
          SELECT score FROM papi_scores ps 
          WHERE ps.employee_id = e.employee_id AND ps.scale_code='S'
        ),0) AS papi_s,
        COALESCE((
          SELECT score FROM papi_scores ps 
          WHERE ps.employee_id = e.employee_id AND ps.scale_code='G'
        ),0) AS papi_g,
        COALESCE((
          SELECT score FROM papi_scores ps 
          WHERE ps.employee_id = e.employee_id AND ps.scale_code='T'
        ),0) AS papi_t,
        COALESCE((
          SELECT score FROM papi_scores ps 
          WHERE ps.employee_id = e.employee_id AND ps.scale_code='W'
        ),0) AS papi_w,
        (SELECT theme FROM strengths s WHERE s.employee_id = e.employee_id AND s.rank=1) AS strength_1,
        (SELECT theme FROM strengths s WHERE s.employee_id = e.employee_id AND s.rank=2) AS strength_2,
        (SELECT theme FROM strengths s WHERE s.employee_id = e.employee_id AND s.rank=3) AS strength_3,
        (SELECT theme FROM strengths s WHERE s.employee_id = e.employee_id AND s.rank=4) AS strength_4,
        (SELECT theme FROM strengths s WHERE s.employee_id = e.employee_id AND s.rank=5) AS strength_5
    FROM employees e
    LEFT JOIN profiles_psych p ON p.employee_id = e.employee_id
    LEFT JOIN dim_directorates ddir ON ddir.directorate_id = e.directorate_id
    LEFT JOIN dim_positions dpos ON dpos.position_id = e.position_id
    LEFT JOIN dim_grades dgr ON dgr.grade_id = e.grade_id
    LEFT JOIN dim_education dedu ON dedu.education_id = e.education_id
    LEFT JOIN dim_majors dma ON dma.major_id = e.major_id
    LEFT JOIN dim_areas dare ON dare.area_id = e.area_id
),

competency_scores AS (
    SELECT 
        employee_id,
        avg(score) FILTER (WHERE pillar_code='SEA') AS sea,
        avg(score) FILTER (WHERE pillar_code='QDD') AS qdd,
        avg(score) FILTER (WHERE pillar_code='FTC') AS ftc,
        avg(score) FILTER (WHERE pillar_code='IDS') AS ids,
        avg(score) FILTER (WHERE pillar_code='VCU') AS vcu,
        avg(score) FILTER (WHERE pillar_code='STO') AS sto,
        avg(score) FILTER (WHERE pillar_code='LIE') AS lie,
        avg(score) FILTER (WHERE pillar_code='CSI') AS csi,
        avg(score) FILTER (WHERE pillar_code='CEX') AS cex,
        avg(score) FILTER (WHERE pillar_code='GDR') AS gdr
    FROM competencies_yearly
    GROUP BY employee_id
),

main_full AS (
    SELECT 
        m.*,
        c.sea, c.qdd, c.ftc, c.ids, c.vcu,
        (c.sto + c.lie)/2 AS sto_lie,
        (c.cex + c.gdr)/2 AS cex_gdr,
        c.csi
    FROM main_cleaned_imputed m
    LEFT JOIN competency_scores c ON c.employee_id = m.employee_id
),

----------------------------------------------------------
-- PHASE 2: TARGET VACANCY (LIST BENCHMARK IDS) from parameter
----------------------------------------------------------
target_vacancy AS (
    SELECT 
        (SELECT ARRAY_AGG(value) FROM jsonb_array_elements_text(benchmark_ids) AS t(value))
        AS selected_talent_ids
),

----------------------------------------------------------
-- PHASE 3: BASELINE FROM BENCHMARK IDS
----------------------------------------------------------
benchmark_baseline AS (
    SELECT 
        AVG(sea) AS baseline_sea,
        AVG(qdd) AS baseline_qdd,
        AVG(ftc) AS baseline_ftc,
        AVG(ids) AS baseline_ids,
        AVG(vcu) AS baseline_vcu,
        AVG(sto_lie) AS baseline_sto_lie,
        AVG(csi) AS baseline_csi,
        AVG(cex_gdr) AS baseline_cex_gdr,
        AVG(iq) AS baseline_iq,
        AVG(gtq) AS baseline_gtq,
        AVG(pauli) AS baseline_pauli,
        AVG(faxtor) AS baseline_faxtor,
        AVG(tiki) AS baseline_tiki,
        -- for categorical fields we use MIN as simple aggregator (can replace with MODE if desired)
        MIN(mbti) AS baseline_mbti,
        MIN(disc) AS baseline_disc,
        AVG(papi_p) AS baseline_papi_p,
        AVG(papi_s) AS baseline_papi_s,
        AVG(papi_g) AS baseline_papi_g,
        AVG(papi_t) AS baseline_papi_t,
        AVG(papi_w) AS baseline_papi_w,
        -- strengths baseline (simple MIN; swap to MODE if you prefer)
        MIN(strength_1) AS baseline_strength_1,
        MIN(strength_2) AS baseline_strength_2,
        MIN(strength_3) AS baseline_strength_3,
        MIN(strength_4) AS baseline_strength_4,
        MIN(strength_5) AS baseline_strength_5,
        MIN(education) AS baseline_education,
        MIN(major) AS baseline_major,
        MIN(position) AS baseline_position,
        MIN(area) AS baseline_area,
        AVG(years_of_service_months) AS baseline_tenure
    FROM main_full m
    CROSS JOIN target_vacancy tv
    WHERE m.employee_id = ANY(tv.selected_talent_ids)
),

----------------------------------------------------------
-- PHASE 4+5+6: UNPIVOT, MATCHING, WEIGHTING, AGGREGATION
----------------------------------------------------------
benchmark_unpivoted AS (
    SELECT * FROM (
        SELECT 'Competency' AS tgv_name,'SEA' AS tv_name,baseline_sea::text AS baseline_score,'numeric' AS tv_type FROM benchmark_baseline
        UNION ALL SELECT 'Competency','QDD',baseline_qdd::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Competency','FTC',baseline_ftc::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Competency','IDS',baseline_ids::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Competency','VCU',baseline_vcu::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Competency','STO_LIE',baseline_sto_lie::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Competency','CSI',baseline_csi::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Competency','CEX_GDR',baseline_cex_gdr::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Cognitive)','IQ',baseline_iq::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Cognitive)','GTQ',baseline_gtq::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Cognitive)','Pauli',baseline_pauli::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Cognitive)','Faxtor',baseline_faxtor::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Cognitive)','Tiki',baseline_tiki::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Personality)','MBTI',baseline_mbti,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Personality)','DISC',baseline_disc,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Personality)','Papi_P',baseline_papi_p::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Personality)','Papi_S',baseline_papi_s::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Personality)','Papi_G',baseline_papi_g::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Personality)','Papi_T',baseline_papi_t::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Psychometric (Personality)','Papi_W',baseline_papi_w::text,'numeric' FROM benchmark_baseline
        UNION ALL SELECT 'Behavioral (Strengths)','Strength_1',baseline_strength_1,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Behavioral (Strengths)','Strength_2',baseline_strength_2,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Behavioral (Strengths)','Strength_3',baseline_strength_3,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Behavioral (Strengths)','Strength_4',baseline_strength_4,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Behavioral (Strengths)','Strength_5',baseline_strength_5,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Contextual (Background)','Education',baseline_education,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Contextual (Background)','Major',baseline_major,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Contextual (Background)','Position',baseline_position,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Contextual (Background)','Area',baseline_area,'categorical' FROM benchmark_baseline
        UNION ALL SELECT 'Contextual (Background)','Tenure',baseline_tenure::text,'numeric' FROM benchmark_baseline
    ) t(tgv_name,tv_name,baseline_score,tv_type)
),

-- UNPIVOT EMPLOYEE FEATURES
all_employees_unpivoted AS (
    SELECT employee_id,'Competency' AS tgv_name,'SEA' AS tv_name,sea::text AS user_score,'numeric' AS tv_type FROM main_full
    UNION ALL SELECT employee_id,'Competency','QDD',qdd::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Competency','FTC',ftc::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Competency','IDS',ids::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Competency','VCU',vcu::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Competency','STO_LIE',sto_lie::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Competency','CSI',csi::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Competency','CEX_GDR',cex_gdr::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Cognitive)','IQ',iq::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Cognitive)','GTQ',gtq::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Cognitive)','Pauli',pauli::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Cognitive)','Faxtor',faxtor::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Cognitive)','Tiki',tiki::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Personality)','MBTI',mbti,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Personality)','DISC',disc,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Personality)','Papi_P',papi_p::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Personality)','Papi_S',papi_s::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Personality)','Papi_G',papi_g::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Personality)','Papi_T',papi_t::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Psychometric (Personality)','Papi_W',papi_w::text,'numeric' FROM main_full
    UNION ALL SELECT employee_id,'Behavioral (Strengths)','Strength_1',strength_1,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Behavioral (Strengths)','Strength_2',strength_2,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Behavioral (Strengths)','Strength_3',strength_3,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Behavioral (Strengths)','Strength_4',strength_4,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Behavioral (Strengths)','Strength_5',strength_5,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Contextual (Background)','Education',education,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Contextual (Background)','Major',major,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Contextual (Background)','Position',position,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Contextual (Background)','Area',area,'categorical' FROM main_full
    UNION ALL SELECT employee_id,'Contextual (Background)','Tenure',years_of_service_months::text,'numeric' FROM main_full
),

-- JOIN EMPLOYEE vs BASELINE
comparison_table AS (
    SELECT 
        u.employee_id,
        u.tgv_name,
        u.tv_name,
        u.tv_type,
        u.user_score,
        b.baseline_score
    FROM all_employees_unpivoted u
    LEFT JOIN benchmark_unpivoted b
      ON u.tgv_name=b.tgv_name AND u.tv_name=b.tv_name
),

-- MATCH SCORE
individual_scores AS (
    SELECT
        employee_id,
        tgv_name,
        tv_name,
        tv_type,
        user_score,
        baseline_score,
        CASE
            WHEN tv_type='categorical' THEN CASE WHEN user_score=baseline_score THEN 100.0 ELSE 0.0 END
            WHEN tv_type='numeric' THEN
                CASE 
                    WHEN user_score IS NULL OR baseline_score IS NULL THEN 0.0
                    WHEN tv_name IN ('Papi_T','Papi_S','Papi_G') THEN 
                        GREATEST(0.0,LEAST(100.0,((2*baseline_score::numeric - user_score::numeric)/NULLIF(baseline_score::numeric,0))*100.0))
                    ELSE GREATEST(0.0,LEAST(100.0,(user_score::numeric/NULLIF(baseline_score::numeric,0))*100.0))
                END
            ELSE 0.0
        END AS match_score
    FROM comparison_table
),

-- WEIGHTS
weights_mapping AS (
    SELECT * FROM (
        VALUES
            ('SEA',0.075),('QDD',0.075),('FTC',0.075),('IDS',0.075),
            ('VCU',0.075),('STO_LIE',0.075),('CSI',0.075),('CEX_GDR',0.075),
            ('IQ',0.01),('GTQ',0.01),('Pauli',0.01),('Faxtor',0.01),('Tiki',0.01),
            ('MBTI',0.00714),('DISC',0.00714),('Papi_P',0.00714),
            ('Papi_S',0.00714),('Papi_G',0.00714),('Papi_T',0.00714),('Papi_W',0.00714),
            ('Strength_1',0.016),('Strength_2',0.016),('Strength_3',0.016),
            ('Strength_4',0.016),('Strength_5',0.016),
            ('Education',0.054),('Major',0.054),('Position',0.054),
            ('Area',0.054),('Tenure',0.054)
    ) AS w(tv_name,weight)
),

weighted_scores AS (
    SELECT
        i.employee_id,
        i.tgv_name,
        i.tv_name,
        i.match_score,
        w.weight,
        i.match_score * w.weight AS weighted_score
    FROM individual_scores i
    JOIN weights_mapping w ON i.tv_name=w.tv_name
),

aggregated_scores AS (
    SELECT 
        employee_id,
        SUM(weighted_score) AS final_match_rate,
        SUM(weighted_score) FILTER (WHERE tgv_name='Competency') AS competency_raw_score,
        SUM(weighted_score) FILTER (WHERE tgv_name='Psychometric (Cognitive)') AS cognitive_raw_score,
        SUM(weighted_score) FILTER (WHERE tgv_name='Psychometric (Personality)') AS personality_raw_score,
        SUM(weighted_score) FILTER (WHERE tgv_name='Behavioral (Strengths)') AS strengths_raw_score,
        SUM(weighted_score) FILTER (WHERE tgv_name='Contextual (Background)') AS contextual_raw_score
    FROM weighted_scores
    GROUP BY employee_id
),

detailed_scores_with_ratio AS (
    SELECT
        c.employee_id,
        c.tgv_name,
        c.tv_name,
        c.user_score,
        c.baseline_score,
        i.match_score,
        a.final_match_rate,
        CASE 
            WHEN c.tgv_name='Competency' THEN COALESCE(a.competency_raw_score,0)::numeric / NULLIF(0.675,0)::numeric
            WHEN c.tgv_name='Psychometric (Cognitive)' THEN COALESCE(a.cognitive_raw_score,0)::numeric / NULLIF(0.05,0)::numeric
            WHEN c.tgv_name='Psychometric (Personality)' THEN COALESCE(a.personality_raw_score,0)::numeric / NULLIF(0.05,0)::numeric
            WHEN c.tgv_name='Behavioral (Strengths)' THEN COALESCE(a.strengths_raw_score,0)::numeric / NULLIF(0.08,0)::numeric
            WHEN c.tgv_name='Contextual (Background)' THEN COALESCE(a.contextual_raw_score,0)::numeric / NULLIF(0.27,0)::numeric
            ELSE 0
        END AS tgv_match_ratio
    FROM comparison_table c
    LEFT JOIN individual_scores i 
        ON c.employee_id=i.employee_id AND c.tv_name=i.tv_name
    LEFT JOIN aggregated_scores a
        ON c.employee_id=a.employee_id
)

----------------------------------------------------------
-- FINAL RESULT (returned by function)
----------------------------------------------------------
SELECT
    m.employee_id,
    m.directorate,
    m.position AS role,
    m.grade,
    dsr.tgv_name,
    dsr.tv_name,
    dsr.baseline_score,
    dsr.user_score,
    dsr.match_score AS tv_match_rate,
    ROUND(dsr.tgv_match_ratio,2) AS tgv_match_rate,
    ROUND(dsr.final_match_rate,2) AS final_match_rate,
    (m.employee_id = ANY(tv.selected_talent_ids)) AS is_benchmark
FROM detailed_scores_with_ratio dsr
LEFT JOIN main_full m ON m.employee_id = dsr.employee_id
CROSS JOIN target_vacancy tv
ORDER BY 
    is_benchmark DESC,
    final_match_rate DESC,
    m.employee_id;
$$;