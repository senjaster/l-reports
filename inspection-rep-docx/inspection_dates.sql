SELECT DISTINCT
    DATE(i.started_at) as inspection_date
FROM
    lesiv.inspection AS i
    INNER JOIN lesiv.equipment_detailed_view AS edv
        ON i.equipment_id = edv.id
WHERE
    i.started_at BETWEEN :period_start AND :period_end
    AND edv.plant_name = :plant_name
ORDER BY
    inspection_date
