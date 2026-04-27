WITH grouped_images AS (
	SELECT DISTINCT ON (il.inspection_step_id, i."image_type")
	 	il.inspection_step_id,
	 	i."image_type",
	 	cast(image_id as TEXT) || '.jpg' as image_id --one random image. To be improved
	FROM	
		lesiv.inspection_image_link AS il	
		INNER JOIN lesiv.image AS i
	 		ON il.image_id = i.id 
),
base_table AS (
    SELECT 
        -- Столбец "Диспетчерское наименование электрооборудования; узел"
        edv.facility_name || ' > ' || edv.equipment_path AS full_equipment_name,
        -- "Узел" это следующие два столбца:
        dt.name AS defect_type_name,
        s.unit_name,
        -- Столбец "Фотография термоиндикатора и термограмма"
        vil.image_id AS visual_image_id,
        til.image_id AS thermal_image_id,
        -- Столбец "Выявленный дефект"
        s.is_sticker_present,     -- Есть ли ТИН (термоиндикаторная наклейка)
        st.name AS sticker_name,  -- Тип наклейки 
        s.t_sticker,              -- Показания наклейки 
        s.is_test_ready,          -- Контролепригодно или нет
        s.t_environment,          -- Температура окружающей среды
        s.t_similar_unit,         -- Температура аналогичного узла
        s.t_observed,             -- Температура, зарегистрированная тепловизором
        dt.t_max,                 -- Максимально допустимая температура для данного типа узла
        dt.t_excess,              -- Максимально допустимое превышение температуры над окр. средой.
        s.measured_current,       -- Измеренный ток
        s.nominal_current,        -- Номинальный ток
        s.measured_current * 1.0 / s.nominal_current as load_factor, -- Коэффициент нагрузки
        s.t_observed - s.t_environment as t_observed_excess,         -- Повышение температуры над окр. средой
        --
        edv.equipment_type_name,  -- Тип оборудования
        CASE WHEN equipment_type_name LIKE 'Электродвигатель%' THEN 'MOTOR' ELSE 'PANEL' END AS is_panel,
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
        INNER JOIN lesiv.sticker_type AS st
            ON s.sticker_type_id = st.id
        LEFT OUTER JOIN grouped_images AS vil
            ON s.id = vil.inspection_step_id AND vil.image_type = 'VISUAL'
        LEFT OUTER JOIN grouped_images AS til
            ON s.id = til.inspection_step_id AND til.image_type = 'THERMAL'	
        LEFT OUTER JOIN lesiv.inspector AS ins
            ON i.inspector_id = ins.id	
    WHERE
        i.started_at BETWEEN :period_start AND :period_end
        AND edv.plant_name = :plant_name
),
adjusted_temperatures AS
(
    SELECT
        *,
        CASE
            WHEN load_factor is NULL THEN 'OVERLOAD'  -- Если токи не известны, считаем как перегрузку
            WHEN load_factor < 0.3 THEN 'LOW'
            WHEN load_factor < 0.6 THEN 'MEDIUM'
            WHEN load_factor <= 1  THEN 'HIGH'
            ELSE 'OVERLOAD'
        END as load_factor_range, --Диапазон нагрузки. Используется в дальнейших расчетах
        -- Для HIGH: пересчет на 100% нагрузки
        t_observed_excess / pow(NULLIF(load_factor, 0), 2) as t_observed_excess_100,
        -- Для MEDIUM: пересчет на 50% нагрузки, сравнение с идентичным узлом
        -- Если t_similar_unit или load_factor пустые, то эта формула не имеет смысла пусть будет NULL
        (t_observed - t_similar_unit) / pow(load_factor, 2) / 4 as t_observed_excess_50
    FROM
        base_table
),
criticality_calc AS (
	SELECT
	    *,
	    CASE
	        -- НИЗКАЯ нагрузка: если превышает норму - критический, иначе развивающийся
	        WHEN load_factor_range = 'LOW' AND (t_observed_excess - t_excess) > 0 THEN 'CRITICAL'
	        WHEN load_factor_range = 'LOW' THEN 'DEVELOPING'
	        
	        -- СРЕДНЯЯ нагрузка: сравниваем с идентичным узлом при 50% нагрузки
	        -- Сначала проверяем критичность по превышению над окружающей средой
	        WHEN load_factor_range = 'MEDIUM' AND (t_observed_excess - t_excess) > 0 THEN 'CRITICAL'
	        -- Затем по превышению над идентичным узлом
	        WHEN load_factor_range = 'MEDIUM' AND t_observed_excess_50 > 30 THEN 'EMERGENCY'
	        WHEN load_factor_range = 'MEDIUM' AND t_observed_excess_50 <= 30 THEN 'DEVELOPING'
	        
	        -- ВЫСОКАЯ нагрузка: пересчитываем на 100% и сравниваем с нормативом
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) > 30 THEN 'CRITICAL'
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) BETWEEN 0 AND 30 THEN 'EMERGENCY'
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) < 0 THEN 'DEVELOPING'
	        
	        -- ПЕРЕГРУЗКА и неизвестные токи: сравниваем текущее превышение с нормативом
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) > 30 THEN 'CRITICAL'
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) BETWEEN 0 AND 30 THEN 'EMERGENCY'
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) < 0 THEN 'DEVELOPING'
	        
	        ELSE 'NONE'
	    END as criticality, --Степень критичности дефекта
	    CASE
	        -- Величина превышения над допустимым
	        WHEN load_factor_range = 'LOW' AND (t_observed_excess - t_excess) > 0 THEN t_observed_excess - t_excess
	        WHEN load_factor_range = 'MEDIUM' AND (t_observed_excess - t_excess) > 0 THEN t_observed_excess - t_excess
	        WHEN load_factor_range = 'MEDIUM' AND t_observed_excess_50 > 30 THEN t_observed_excess_50 - 30
	        WHEN load_factor_range = 'HIGH' AND (t_observed_excess_100 - t_excess) > 0 THEN t_observed_excess_100 - t_excess
	        WHEN load_factor_range = 'OVERLOAD' AND (t_observed_excess - t_excess) > 0 THEN t_observed_excess - t_excess
	        ELSE NULL
	    END as t_over_max_excess -- Величина превышения над допустимым превышением
	FROM adjusted_temperatures
)
SELECT 
	*
FROM criticality_calc
WHERE criticality <> 'DEVELOPING'  -- Выводим только аварийные и критические
ORDER BY 
	criticality,
	is_panel,
	full_equipment_name,
	defect_type_name,
	unit_name