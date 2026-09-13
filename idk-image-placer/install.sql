-- Import before starting the resource: mysql -u user -p your_database < install.sql
-- Safe to re-run - CREATE TABLE IF NOT EXISTS and the ALTER TABLE below
-- won't touch existing data.

CREATE TABLE IF NOT EXISTS `idk_image_placer_placements` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `corners` LONGTEXT NOT NULL,           -- JSON-encoded array of 4 {x,y,z} corner points
    `imageUrl` VARCHAR(512) NOT NULL,
    `alpha` TINYINT UNSIGNED NOT NULL DEFAULT 255,
    `drawDistance` FLOAT UNSIGNED DEFAULT NULL, -- NULL = use the server's default draw distance
    `placedBy` VARCHAR(128) NOT NULL,
    `createdAt` INT UNSIGNED NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

ALTER TABLE `idk_image_placer_placements` ADD COLUMN IF NOT EXISTS `drawDistance` FLOAT UNSIGNED DEFAULT NULL;

-- Holds the admin panel's "Save as server default" values (single row,
-- id = 1) so a settings change survives a restart. Optional - if missing,
-- the resource just uses config.lua's defaults.
CREATE TABLE IF NOT EXISTS `idk_image_placer_settings` (
    `id` TINYINT UNSIGNED NOT NULL,
    `maxPlacementsPerPlayer` INT UNSIGNED DEFAULT NULL,
    `maxRaycastDistance` FLOAT UNSIGNED DEFAULT NULL,
    `defaultDrawDistance` FLOAT UNSIGNED DEFAULT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
