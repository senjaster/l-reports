WITH grouped_images AS (
	SELECT
	 	il.inspection_step_id,
	 	i."image_type",
	 	array_agg(cast(image_id as TEXT) || '.jpg') as image_ids
	FROM
		lesiv.inspection_image_link AS il
		INNER JOIN lesiv.image AS i
	 		ON il.image_id = i.id
    WHERE i.original_file_name NOT LIKE '%CCD%'
	GROUP BY il.inspection_step_id, i."image_type"
),
base_table AS (
    SELECT 
        -- Столбец "Диспетчерское наименование электрооборудования; узел"
        edv.facility_name || ' > ' || edv.equipment_path AS full_equipment_name,
        -- "Узел" это следующие три столбца:
        dt.name AS defect_type_name,
        dt.short_name AS defect_type_short_name,
        s.unit_name,
        -- Столбец "Фотография термоиндикатора и термограмма"
        vil.image_ids AS visual_image_ids,
        til.image_ids AS thermal_image_ids,
        -- Столбец "Выявленный дефект"
        s.is_sticker_present,     -- Есть ли ТИН (термоиндикаторная наклейка)
        st.name AS sticker_name,  -- Тип наклейки 
        s.t_sticker,              -- Показания наклейки 
        s.is_test_ready,          -- Контролепригодно или нет
        s.t_environment,          -- Температура окружающей среды
        s.t_similar_unit,         -- Температура аналогичного узла
        s.t_observed,             -- Температура, зарегистрированная тепловизором
        s.is_attention_required,  -- Необходимость внимания
        dt.t_max,                 -- Максимально допустимая температура для данного типа узла
        dt.t_excess,              -- Максимально допустимое превышение температуры над окр. средой.
        s.measured_current,       -- Измеренный ток
        s.nominal_current,        -- Номинальный ток
        s.measured_current * 1.0 / s.nominal_current as load_factor, -- Коэффициент нагрузки
        s.t_observed - s.t_environment as t_observed_excess,         -- Повышение температуры над окр. средой
        --
        edv.equipment_type_name,  -- Тип оборудования
        CASE WHEN edv.equipment_type_name LIKE '%двигатель%' THEN 'MOTOR' ELSE 'PANEL' END AS is_panel,
        ins.full_name             -- Кто проводил осмотр
    FROM 
        lesiv.inspection AS i
        INNER JOIN lesiv.inspection_step AS s
            ON s.inspection_id = i.id
        INNER JOIN lesiv.equipment_defect AS d
            ON d.id = s.defect_id
        INNER JOIN lesiv.equipment_detailed_view AS edv
            ON i.equipment_id = edv.id
        INNER JOIN lesiv.defect_type AS dt	
            ON s.defect_type_id = dt.id
        LEFT OUTER JOIN lesiv.sticker_type AS st
            ON s.sticker_type_id = st.id
        LEFT OUTER JOIN grouped_images AS vil
            ON s.id = vil.inspection_step_id AND vil.image_type = 'VISUAL'
        LEFT OUTER JOIN grouped_images AS til
            ON s.id = til.inspection_step_id AND til.image_type = 'THERMAL'	
        LEFT OUTER JOIN lesiv.inspector AS ins
            ON i.inspector_id = ins.id	
    WHERE
        i.started_at BETWEEN :period_start AND cast(:period_end as timestamp) + interval '1 day' 
        AND edv.plant_name = :plant_name
),
adjusted_temperatures AS
(
    SELECT
        *,
        -- Извлечение первой группы цифр из t_sticker (например, "100" из ">100" или "100-120")
        CASE
            WHEN t_sticker IS NOT NULL THEN
                CAST(NULLIF(substring(t_sticker from '\d+'), '') AS NUMERIC)
            ELSE NULL
        END as t_sticker_min,
        CASE
            WHEN load_factor is NULL THEN 'OVERLOAD'  -- Если токи не известны, считаем как перегрузку
            WHEN load_factor < 0.3 THEN 'LOW'
            WHEN load_factor < 0.6 THEN 'MEDIUM'
            WHEN load_factor <= 1  THEN 'HIGH'
            ELSE 'OVERLOAD'
        END as load_factor_range, --Диапазон нагрузки. Используется в дальнейших расчетах
        -- Для HIGH: пересчет на 100% нагрузки: ∆T_ном = ∆T_прев * (I_ном/I_раб)^2
        t_observed_excess / pow(load_factor, 2) as t_observed_excess_100,
        -- Для MEDIUM: пересчет на 50% нагрузки, сравнение с идентичным узлом
        -- Если t_similar_unit или load_factor пустые, то эта формула не имеет смысла пусть будет NULL
        (t_observed - t_similar_unit) / pow(load_factor, 2) / 4 as t_observed_excess_50,
        -- Для MEDIUM (резервный алгоритм): если t_similar_unit неизвестна
        -- ∆T_ном = ∆T_прев / (0.6)^2
        t_observed_excess / pow(0.6, 2) as t_observed_excess_medium_fallback
    FROM
        base_table
),
criticality_calc AS (
	SELECT
	    *,
	    -- Критичность по термоиндикаторной наклейке    
	    CASE
	        WHEN t_sticker_min >= t_max THEN 2  -- EMERGENCY
	        ELSE 3  -- DEVELOPING (нет проблем с наклейкой)
	    END as criticality_sticker_numeric,
	    -- Критичность по показаниям тепловизора
	    CASE
	        -- НИЗКАЯ нагрузка: если ∆T_прев > 10 то критический, иначе развивающийся
	        WHEN load_factor_range = 'LOW' AND t_observed_excess > 10 THEN 1  -- CRITICAL
	        WHEN load_factor_range = 'LOW' THEN 3  -- DEVELOPING
	        
	        -- СРЕДНЯЯ нагрузка: сравниваем с идентичным узлом при 50% нагрузки
	        -- Если t_similar_unit известна, используем основной алгоритм
	        WHEN load_factor_range = 'MEDIUM' AND t_similar_unit IS NOT NULL AND t_observed_excess_50 < 30 THEN 3  -- DEVELOPING
	        WHEN load_factor_range = 'MEDIUM' AND t_similar_unit IS NOT NULL AND t_observed_excess_50 >= 30 THEN 2  -- EMERGENCY
	        -- Если t_similar_unit неизвестна, используем резервный алгоритм
	        WHEN load_factor_range = 'MEDIUM' AND t_similar_unit IS NULL AND (t_observed_excess_medium_fallback - t_excess) > 0 THEN 1  -- CRITICAL
	        WHEN load_factor_range = 'MEDIUM' AND t_similar_unit IS NULL THEN 3  -- DEVELOPING
	        
	        -- ВЫСОКАЯ нагрузка: пересчитываем на 100% и сравниваем с нормативом
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) > 30 THEN 1  -- CRITICAL
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) BETWEEN 0 AND 30 THEN 2  -- EMERGENCY
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) < 0 THEN 3  -- DEVELOPING
	        
	        -- ПЕРЕГРУЗКА и неизвестные токи: сравниваем текущее превышение с нормативом
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) > 30 THEN 1  -- CRITICAL
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) BETWEEN 0 AND 30 THEN 2  -- EMERGENCY
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) < 0 THEN 3  -- DEVELOPING
	        
	        ELSE 3  -- DEVELOPING
	    END as criticality_load_numeric,
        
        -- Превышение температуры по термоиндикаторной наклейке
	    CASE
	        WHEN t_sticker_min >= t_max THEN t_sticker_min - t_max 
	        ELSE 0
        END as t_sticker_excess,

	    -- Величина превышения над допустимым (только по тепловизору)
	    CASE
	        WHEN load_factor_range = 'LOW' AND t_observed_excess > 10 THEN t_observed_excess - 10
	        WHEN load_factor_range = 'MEDIUM' AND t_similar_unit IS NOT NULL AND t_observed_excess_50 >= 30 THEN t_observed_excess_50 - 30
	        WHEN load_factor_range = 'MEDIUM' AND t_similar_unit IS NULL AND (t_observed_excess_medium_fallback - t_excess) > 0 THEN t_observed_excess_medium_fallback - t_excess
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) > 0 THEN t_observed_excess_100 - t_excess
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) > 0 THEN t_observed_excess - t_excess
	        ELSE 0
	    END as t_thermal_excess
	FROM adjusted_temperatures
),
final_criticality AS (
	SELECT
	    *,
        	    -- Величина превышения над допустимым (комбинированная: максимум из тепловизора и наклейки)
	    GREATEST(
	        t_sticker_excess, t_thermal_excess, 0
	    ) as t_over_max_excess, -- Величина превышения над допустимым превышением
	    -- Берем минимум (наиболее критичное значение): 1=CRITICAL, 2=EMERGENCY, 3=DEVELOPING
	    LEAST(criticality_sticker_numeric, criticality_load_numeric) as criticality_numeric,
	    CASE LEAST(criticality_sticker_numeric, criticality_load_numeric)
	        WHEN 1 THEN 'CRITICAL'
	        WHEN 2 THEN 'EMERGENCY'
	        ELSE 'DEVELOPING'
	    END as criticality  --Степень критичности дефекта (итоговая)
	FROM criticality_calc
)
SELECT
	*,
    criticality_numeric as criticality_sort
FROM final_criticality
WHERE
    CASE
        WHEN :include_developing THEN criticality IN ('CRITICAL', 'EMERGENCY', 'DEVELOPING')
        ELSE criticality IN ('CRITICAL', 'EMERGENCY')
    END
ORDER BY
	criticality_sort,
	full_equipment_name,
	defect_type_name,
	unit_name