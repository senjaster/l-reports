SELECT
	edv.facility_name,
	REPLACE(REPLACE(edv.equipment_path, ' > ' || name, ''),' >',' -') AS full_folder_name,
	sum(edv.total_point_count) AS total_point_count,
	sum(edv.total_sticker_count) AS total_sticker_count
FROM
    lesiv.inspection AS i
    INNER JOIN lesiv.equipment_detailed_view AS edv
        ON i.equipment_id = edv.id
	WHERE
		edv.is_container = false
        AND i.started_at BETWEEN :period_start AND :period_end
        AND edv.plant_name = :plant_name
GROUP BY
	full_folder_name,
	edv.facility_name
ORDER BY
	edv.facility_name,
	full_folder_name